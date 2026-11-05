# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Nextcloud's part of the suite port (suite.py), in the Nextcloud container: its command line, occ, the CAs that its
own requests trust, the apps in its apps folder and the theme in its themes folder. `Suite` holds the real one as
`suite.nextcloud` and `FakeSuite` the fake one, which the Seam 2 tests drive."""

import io
import json
import subprocess
import sys
import tarfile
import time
import xml.etree.ElementTree as ET

from suite import Unreachable

CONTAINER = "nextcloud-aio-nextcloud"
DOWN = ("El servidor de aplicaciones de la suite no responde. Presione «Reintentar»; si vuelve a ocurrir, contacte a "
        "APS Conecta.")
FAILED = "Nextcloud no completó «occ {}». Presione «Reintentar»; si vuelve a ocurrir, contacte a APS Conecta."
ISSUER_FAILED = "No se pudo obtener ni verificar el certificado intermedio de {}."
INSTALL_FAILED = "Nextcloud no pudo instalarla. Presione «Reintentar»; si vuelve a ocurrir, contacte a APS Conecta."
THEME_FAILED = ("Nextcloud no pudo instalar el tema de APS Conecta. Presione «Reintentar»; si vuelve a ocurrir, "
                "contacte a APS Conecta.")
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


# The theme $1 from the tarball on stdin, in place of any copy in Nextcloud's themes folder, which upstream's updates
# keep; then the browser's texts of the apps it overrides texts of, as our Nextcloud image builds them
# (aps/images/nextcloud/browser-texts.php).
THEME = r"""
set -eu
theme=$1
themes=/var/www/html/themes
dir=$(mktemp -d "$themes/.$theme.XXXXXX")
trap 'rm -rf "$dir"' EXIT
tar -xzf - -C "$dir"
rm -rf "${themes:?}/$theme"
mv "$dir/$theme" "$themes/$theme"
php /browser-texts.php
"""


def packed(folder, files):
    """A gzipped tarball of `files`, each by its path in `folder`, dated now so that no browser keeps an older copy."""
    data, now = io.BytesIO(), time.time()
    with tarfile.open(fileobj=data, mode="w:gz") as tar:
        for name, content in sorted(files.items()):
            member = tarfile.TarInfo(f"{folder}/{name}")
            member.size, member.mtime = len(content), now
            tar.addfile(member, io.BytesIO(content))
    return data.getvalue()


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

    def place_theme(self, theme, files):
        """Nextcloud runs the theme `theme` from `files`, each by its path in the theme's folder, in place of any copy
        it held, its text overrides in the browser too."""
        self.execute(THEME, theme, stdin=packed(theme, files), failed=THEME_FAILED)


# What occ theming:config sets (UpdateConfig::SUPPORTED_KEYS), and its images (ImageManager::SUPPORTED_IMAGE_KEYS).
THEMING = ("name", "url", "imprintUrl", "privacyUrl", "slogan", "color", "primary_color", "background_color",
           "disable-user-theming")
IMAGES = ("background", "logo", "logoheader", "favicon")


class FakeNextcloud:
    """The fake one: Nextcloud's settings, `system` and `apps` by app, the latter for every app it has, and the CAs its
    own requests trust beside the ones it ships: the files of AIO's folder of trusted CAs, and the issuers of the hosts
    that serve only their leaf. It does not answer while `down` is set, an import silently keeps the `ignored` settings
    out, the issuers of the `unreachable` hosts cannot be fetched, and Euro-Office answers Nextcloud while `editor` is
    set. Its app store has the apps of `store`, and an app installed from a tarball runs the version its info.xml
    declares. Its themes folder keeps each theme placed in it, and theming takes an image only from a file of one."""

    def __init__(self):
        self.down = False
        self.editor = True  # Euro-Office's document server answers Nextcloud: its connector's own check passes
        self.system = {}
        self.apps = {"core": {}, "admin_audit": {"enabled": "no"}, "office": {"enabled": "yes"},  # as Nextcloud ships
                     **{app: {"enabled": "yes"} for app in ("nextcloud_announcements", "firstrunwizard",
                                                             "survey_client", "support")}}  # support: as AIO's start
        self.ignored = set()
        self.cacerts = []  # the files of AIO's folder of trusted CAs: a test build's; a release has none
        self.trusted = set()  # those among Nextcloud's trusted certificates
        self.issuers = set()  # the hosts whose issuer is among them
        self.unreachable = set()
        self.store = {}  # the app store's apps, by id: the version it installs
        self.themes = {}  # the themes in its themes folder, by name: their files, by their path in the theme's folder
        self.images = {}  # theming's images, by key: the file each came from

    def occ(self, *args, stdin=""):
        """The commands the install steps run: settings out and in, an app on, from the app store when Nextcloud does
        not have it, an app off, theming, and Euro-Office's connector's check."""
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
        if args[0] == "app:disable" and len(args) == 2:
            if args[1] in self.apps:  # occ answers alike for an app it does not have
                self.apps[args[1]]["enabled"] = "no"
            return ""
        if args[0] == "theming:config" and len(args) == 3:
            return self.theming(*args[1:])
        if args[0] == "app:enable" and len(args) == 2:
            app = args[1]
            if app not in self.apps and app not in self.store:
                raise Unreachable(FAILED.format(" ".join(args)))
            self.apps.setdefault(app, {"installed_version": self.store.get(app)})["enabled"] = "yes"
            return ""
        raise AssertionError(f"the fake Nextcloud runs no occ {args}")

    def theming(self, key, value):
        """occ theming:config: an image from a file of a theme in its themes folder, which it must find; a flag as a
        boolean; any other key as text."""
        theming = self.apps.setdefault("theming", {})
        if key in IMAGES:
            theme, _, path = value.removeprefix("/var/www/html/themes/").partition("/")
            if path not in self.themes.get(theme, {}):
                raise Unreachable(FAILED.format(f"theming:config {key} {value}"))
            self.images[key] = value
            theming[f"{key}Mime"] = "image/svg+xml" if value.endswith(".svg") else "image/png"
        elif key == "disable-user-theming":
            theming[key] = value in ("1", "true", "yes", "on")
        elif key in THEMING:
            theming[key] = value
        else:
            raise Unreachable(FAILED.format(f"theming:config {key} {value}"))
        return ""

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

    def place_theme(self, theme, files):
        if self.down:
            raise Unreachable(DOWN)
        self.themes[theme] = dict(files)

    def install_app(self, app, tarball):
        if self.down:
            raise Unreachable(DOWN)
        try:
            with tarfile.open(fileobj=io.BytesIO(tarball), mode="r:gz") as tar:
                version = ET.parse(tar.extractfile(f"{app}/appinfo/info.xml")).findtext("version")
        except (tarfile.TarError, KeyError, ET.ParseError):
            raise Unreachable(INSTALL_FAILED) from None
        self.apps[app] = {"enabled": "yes", "installed_version": version}
