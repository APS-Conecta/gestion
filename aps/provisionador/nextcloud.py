# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Nextcloud's part of the suite port (suite.py), in the Nextcloud container: its command line, occ, the CAs that its
own requests trust, the apps in its apps folder, the accounts the install creates and what it seeds in group folders.
`Suite` holds the real one as `suite.nextcloud` and `FakeSuite` the fake one, which the Seam 2 tests drive."""

import io
import json
import subprocess
import sys
import tarfile
import xml.etree.ElementTree as ET

from suite import Unreachable

CONTAINER = "nextcloud-aio-nextcloud"
DOWN = ("El servidor de aplicaciones de la suite no responde. Presione «Reintentar»; si vuelve a ocurrir, contacte a "
        "APS Conecta.")
FAILED = "Nextcloud no completó «occ {}». Presione «Reintentar»; si vuelve a ocurrir, contacte a APS Conecta."
ISSUER_FAILED = "No se pudo obtener ni verificar el certificado intermedio de {}."
INSTALL_FAILED = "Nextcloud no pudo instalarla. Presione «Reintentar»; si vuelve a ocurrir, contacte a APS Conecta."
SEED_FAILED = ("Nextcloud no pudo guardar las carpetas y las páginas iniciales en las carpetas de equipo. Presione "
               "«Reintentar»; si vuelve a ocurrir, contacte a APS Conecta.")
# Nextcloud's command line with its input from a file: config:import reads its input without waiting for it.
OCC = """input=$(mktemp) && cat > "$input" && php /var/www/html/occ --no-ansi --no-interaction "$@" < "$input"
status=$?; rm -f "$input"; exit $status"""
# For the host in $1, which serves only its leaf certificate: the CA its certificate names (its CA Issuers pointer) is
# imported into Nextcloud's trusted certificates once it is verified to chain the leaf to a root the container trusts,
# as Nextcloud's own requests then do. An import already there is kept.
ISSUER = r"""
set -eu
host=$1
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
timeout 20 openssl s_client -connect "$host:443" -servername "$host" < /dev/null 2> /dev/null \
  | openssl x509 > "$dir/leaf"
issuer=$(openssl x509 -in "$dir/leaf" -noout -ext authorityInfoAccess | sed -n 's/^ *CA Issuers - URI://p' | head -n 1)
name=$(basename "$issuer" .crt).pem
case "$issuer" in http://*.crt | https://*.crt) ;; *) echo "no CA Issuers pointer: $issuer" >&2; exit 1 ;; esac
case "$name" in *[!A-Za-z0-9._-]*) echo "unexpected issuer name: $name" >&2; exit 1 ;; esac
php /var/www/html/occ security:certificates --output=json | grep -qF "\"$name\"" && exit 0
curl -fsS --max-time 20 --proto =http,https -o "$dir/issuer" "$issuer"
openssl x509 -inform DER -in "$dir/issuer" -out "$dir/$name" 2> /dev/null \
  || openssl x509 -in "$dir/issuer" -out "$dir/$name"
openssl verify -untrusted "$dir/$name" -verify_hostname "$host" "$dir/leaf"
php /var/www/html/occ --no-ansi --no-interaction security:certificates:import "$dir/$name"
"""
# Each CA file of AIO's own folder of trusted CAs, which AIO mounts here only when it has one (a test build's Let's
# Encrypt staging roots), imported into Nextcloud's trusted certificates: the container's own trust store holds them,
# and Nextcloud's HTTP client reads its own.
CACERTS = r"""
set -eu
[ -n "${TRUSTED_CACERTS_DIR:-}" ] || exit 0
for ca in /usr/local/share/ca-certificates/*.crt; do
  [ -e "$ca" ] || continue
  php /var/www/html/occ --no-ansi --no-interaction security:certificates:import "$ca"
done
"""
# The app $1 from the App release tarball on stdin, in place of any copy in Nextcloud's apps folder: Nextcloud upgrades
# the app it held as it enables it again. The app's folder gets a .git folder, so that Nextcloud's app store takes it for
# an app installed from git, which it never updates (Installer::isUpdateAvailable): no store update, from the Apps page,
# occ app:update or AIO's, replaces it.
INSTALL = r"""
set -eu
app=$1
apps=/var/www/html/custom_apps
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
tar -xzf - -C "$dir"
[ -f "$dir/$app/appinfo/info.xml" ] || { echo "the tarball holds no $app/appinfo/info.xml" >&2; exit 1; }
mkdir -p "$dir/$app/.git"
if [ -d "$apps/$app" ]; then
  php /var/www/html/occ --no-ansi --no-interaction app:disable "$app"
fi
rm -rf "${apps:?}/$app"
mv "$dir/$app" "$apps/"
php /var/www/html/occ --no-ansi --no-interaction app:enable "$app"
"""

# The group folder $1's missing folders and files, from the JSON object on stdin that holds each file's text, or null
# for a folder, by its path in the group folder; whatever the folder holds stays as staff left it. Groupfolders then
# scans the folder, so that Nextcloud lists what was added.
SEED = r"""
set -eu
files="$(php /var/www/html/occ --no-ansi config:system:get datadirectory)/__groupfolders/$1/files"
[ -d "$files" ] || { echo "the group folder $1 has no folder $files" >&2; exit 1; }
php -r '
foreach (json_decode(stream_get_contents(STDIN), true, 3, JSON_THROW_ON_ERROR) as $path => $text) {
    $target = $argv[1] . "/" . $path;
    $folder = $text === null ? $target : dirname($target);
    if (in_array("..", explode("/", $path), true) || !(is_dir($folder) || mkdir($folder, 0755, true))) {
        exit(1);
    }
    if ($text !== null && !file_exists($target) && file_put_contents($target, $text) === false) {
        exit(1);
    }
}' -- "$files"
php /var/www/html/occ --no-ansi --no-interaction groupfolders:scan "$1" > /dev/null
"""

# The account $1 named $2, unless it exists, with its first password on stdin, which occ reads from its environment.
ADD_USER = r"""
set -eu
php /var/www/html/occ --no-ansi user:info "$1" > /dev/null 2>&1 && exit 0
OC_PASS=$(cat)
export OC_PASS
php /var/www/html/occ --no-ansi --no-interaction user:add --password-from-env --display-name="$2" "$1" > /dev/null
"""


class Nextcloud:
    """The real one: each command runs in the Nextcloud container as its web user, through the Docker socket."""

    @staticmethod
    def execute(script, *args, stdin="", failed, timeout=120):
        """What the shell script printed in the container, run with `args` and `stdin`, text or bytes; Unreachable with
        `failed` when it fails, or with DOWN when the container does not answer. Only the errors are logged."""
        try:
            run = subprocess.run(["docker", "exec", "--interactive", "--user", "www-data", CONTAINER, "sh", "-c",
                                  script, "sh", *args], input=stdin.encode() if isinstance(stdin, str) else stdin,
                                 capture_output=True, timeout=timeout, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f"{CONTAINER}: {error}", file=sys.stderr, flush=True)
            raise Unreachable(DOWN) from None
        errors = run.stderr.decode(errors="replace")
        if run.returncode:
            print(f"{CONTAINER} {args[:1]}: {errors}", file=sys.stderr, flush=True)
            answered = "Error response from daemon" not in errors and "No such container" not in errors
            raise Unreachable(failed if answered else DOWN)
        return run.stdout.decode()

    def occ(self, *args, stdin=""):
        """What Nextcloud's command line printed."""
        return self.execute(OCC, *args, stdin=stdin, failed=FAILED.format(" ".join(args)))

    def trust_issuer(self, host):
        """Nextcloud's own requests verify `host`, which serves only its leaf certificate: the CA that issued it is
        among Nextcloud's trusted certificates."""
        self.execute(ISSUER, host, failed=ISSUER_FAILED.format(host))

    def trust_cacerts(self):
        """Nextcloud's own requests trust the CAs of AIO's folder of trusted CAs, as Talk does; a release has none."""
        self.execute(CACERTS, failed=FAILED.format("security:certificates:import"))

    def install_app(self, app, tarball):
        """The app `app` runs from `tarball`, an App release's, in place of any copy Nextcloud held."""
        self.execute(INSTALL, app, stdin=tarball, failed=INSTALL_FAILED, timeout=600)

    def add_user(self, user, name, password):
        """The account `user` named `name`, with its first password, unless it exists: an existing account keeps its
        own."""
        self.execute(ADD_USER, user, name, stdin=password, failed=FAILED.format(f"user:add {user}"))

    def seed(self, folder, files):
        """The group folder `folder` holds each of `files` it does not hold yet, their text by their path in it, None
        for a folder; what it holds stays as staff left it."""
        self.execute(SEED, str(folder), stdin=json.dumps(files), failed=SEED_FAILED)


class FakeNextcloud:
    """The fake one: Nextcloud's settings, `system` and `apps` by app, the latter for every app it has, and the CAs its
    own requests trust beside the ones it ships: the files of AIO's folder of trusted CAs, and the issuers of the hosts
    that serve only their leaf. It does not answer while `down` is set, an import silently keeps the `ignored` settings
    out, the issuers of the `unreachable` hosts cannot be fetched, and Euro-Office answers Nextcloud while `editor` is
    set. Its app store has the apps of `store`, and an app installed from a tarball runs the version its info.xml
    declares. Its groups are kept by id, each with its name and its members, and its group folders by id, each with
    its mount point, each group's permissions and its files, while Groupfolders is enabled. IntraVox's setup makes its
    group folder, and its page index lists the pages of that folder. Its accounts are kept by username, each with its
    name, its password and whether the password policy looked the password up at the breached-password service."""

    def __init__(self):
        self.down = False
        self.editor = True  # Euro-Office's document server answers Nextcloud: its connector's own check passes
        self.system = {}
        self.apps = {"core": {}, "admin_audit": {"enabled": "no"}, "office": {"enabled": "yes"},  # as Nextcloud ships
                     **{app: {"enabled": "yes"} for app in (
                         "updatenotification", "serverinfo", "recommendations", "related_resources", "weather_status",
                         "survey_client", "nextcloud_announcements", "firstrunwizard", "password_policy")}}
        self.ignored = set()
        self.cacerts = []  # the files of AIO's folder of trusted CAs: a test build's; a release has none
        self.trusted = set()  # those among Nextcloud's trusted certificates
        self.issuers = set()  # the hosts whose issuer is among them
        self.unreachable = set()
        self.store = {}  # the app store's apps, by id: the version it installs
        self.groups = {"admin": {"name": "admin", "members": ["admin"]}}  # as Nextcloud's setup leaves them
        self.folders = {}
        self.indexed = set()  # the pages IntraVox lists, by their id
        self.users = {"admin": {"name": "admin", "password": None, "looked_up": False}}

    def occ(self, *args, stdin=""):
        """The commands the install steps run: settings out and in, an app on, from the app store when Nextcloud does
        not have it, on for the admin group alone or off, Euro-Office's connector's check, groups and their members,
        and Groupfolders' and IntraVox's commands."""
        if self.down:
            raise Unreachable(DOWN)
        if args == ("eurooffice:documentserver", "--check"):
            if not self.editor:
                raise Unreachable(FAILED.format(" ".join(args)))
            return ""
        if args == ("config:list",):
            return json.dumps({"system": self.system, "apps": self.apps})
        if args == ("config:import",):
            settings = json.loads(stdin)
            self.system.update({k: v for k, v in settings.get("system", {}).items() if k not in self.ignored})
            for app, values in settings.get("apps", {}).items():
                self.apps.setdefault(app, {}).update({k: v for k, v in values.items() if k not in self.ignored})
            return ""
        if args == ("group:list", "--output=json"):
            return json.dumps({group: held["members"] for group, held in self.groups.items()})
        if args[0] == "group:add" and args[1].startswith("--display-name=") and args[2] not in self.groups:
            self.groups[args[2]] = {"name": args[1].removeprefix("--display-name="), "members": []}
            return ""
        if args[0] == "group:adduser" and args[1] in self.groups and args[2] in self.users:
            self.groups[args[1]]["members"] = sorted({*self.groups[args[1]]["members"], args[2]})
            return ""
        if args[0].startswith("groupfolders:"):
            return self.groupfolders(*args)
        if args[0].startswith("intravox:"):
            return self.intravox(*args)
        if args[0] == "app:enable" and args[1] == "--groups=admin" and args[2] in self.apps:
            self.apps[args[2]]["enabled"] = '["admin"]'
            return ""
        if args[0] == "app:disable" and len(args) == 2:
            self.apps.get(args[1], {}).update(enabled="no")
            return ""
        if args[0] == "app:enable" and len(args) == 2:
            app = args[1]
            if app not in self.apps and app not in self.store:
                raise Unreachable(FAILED.format(" ".join(args)))
            self.apps.setdefault(app, {"installed_version": self.store.get(app)})["enabled"] = "yes"
            return ""
        raise AssertionError(f"the fake Nextcloud runs no occ {args}")

    def groupfolders(self, command, *args):
        """Groupfolders' commands: its folders out, a folder made, a group's permissions in a folder set or removed."""
        if not self.enabled("groupfolders"):
            raise Unreachable(FAILED.format(" ".join((command, *args))))
        if (command, *args) == ("groupfolders:list", "--output=json"):
            return json.dumps([{"id": number, "mountPoint": folder["mount"], "groups_list": folder["groups"] or []}
                               for number, folder in self.folders.items()])
        if command == "groupfolders:create" and all(f["mount"] != args[0] for f in self.folders.values()):
            self.folders[len(self.folders) + 1] = {"mount": args[0], "groups": {}, "files": {}}
            return f"{len(self.folders)}\n"
        if command == "groupfolders:group" and int(args[0]) in self.folders and args[1] in self.groups:
            granted = self.folders[int(args[0])]["groups"]
            if args[2:] == ("--delete",):
                granted.pop(args[1], None)
            else:
                granted[args[1]] = 1 | sum({"write": 6, "delete": 8, "share": 16}.get(word, 0) for word in args[2:])
            return ""
        raise AssertionError(f"the fake Nextcloud runs no occ {(command, *args)}")

    def intravox(self, command, *args):
        """IntraVox's commands: its setup without demo pages, which makes its groups and its group folder, named as its
        settings name it, with its groups' permissions; and its page index, rebuilt from the pages in that folder."""
        if not (self.enabled("intravox") and self.enabled("groupfolders")):
            raise Unreachable(FAILED.format(" ".join((command, *args))))
        mount = self.apps["intravox"].get("groupfolder_name", "IntraVox")
        folder = next((f for f in self.folders.values() if f["mount"] == mount), None)
        if (command, *args) == ("intravox:setup", "--skip-demo"):
            own = {"admin": 31, "IntraVox Admins": 31, "IntraVox Editors": 7, "IntraVox Users": 1}
            for group in own.keys() - self.groups.keys():
                self.groups[group] = {"name": group, "members": []}
            if folder is None:
                self.folders[len(self.folders) + 1] = {"mount": mount, "groups": own, "files": {}}
            return ""
        if (command, *args) == ("intravox:reindex",) and folder is not None:
            pages = [json.loads(text) for text in folder["files"].values() if text is not None]
            self.indexed = {page["uniqueId"] for page in pages if "uniqueId" in page}
            return ""
        raise AssertionError(f"the fake Nextcloud runs no occ {(command, *args)}")

    def add_user(self, user, name, password):
        if self.down:
            raise Unreachable(DOWN)
        policy = self.apps.get("password_policy", {})
        self.users.setdefault(user, {"name": name, "password": password, "looked_up": policy.get("enabled") == "yes"
                                     and policy.get("enforceHaveIBeenPwned", "1") != "0"})

    def enabled(self, app):
        return self.apps.get(app, {}).get("enabled") == "yes"

    def seed(self, folder, files):
        if self.down:
            raise Unreachable(DOWN)
        held = self.folders[folder]["files"]
        held.update({path: text for path, text in files.items() if path not in held})

    def trust_issuer(self, host):
        if self.down:
            raise Unreachable(DOWN)
        if host in self.unreachable:
            raise Unreachable(ISSUER_FAILED.format(host))
        self.issuers.add(host)

    def trust_cacerts(self):
        if self.down:
            raise Unreachable(DOWN)
        self.trusted |= set(self.cacerts)

    def from_store(self, apps):
        """Each of the apps the app store has, installed from it and enabled."""
        for app in apps:
            if app in self.store:
                self.apps[app] = {"enabled": "yes", "installed_version": self.store[app]}

    def install_app(self, app, tarball):
        if self.down:
            raise Unreachable(DOWN)
        try:
            with tarfile.open(fileobj=io.BytesIO(tarball), mode="r:gz") as tar:
                version = ET.parse(tar.extractfile(f"{app}/appinfo/info.xml")).findtext("version")
        except (tarfile.TarError, KeyError, ET.ParseError):
            raise Unreachable(INSTALL_FAILED) from None
        self.apps.setdefault(app, {}).update(enabled="yes", installed_version=version)
