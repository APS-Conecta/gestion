# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Nextcloud's part of the suite port (suite.py), in the Nextcloud container: its command line, occ, and the CAs that
its own requests trust. `Suite` holds the real one as `suite.nextcloud` and `FakeSuite` the fake one, which the Seam 2
tests drive."""

import json
import subprocess
import sys

from suite import Unreachable

CONTAINER = "nextcloud-aio-nextcloud"
DOWN = ("El servidor de aplicaciones de la suite no responde. Presione «Reintentar»; si vuelve a ocurrir, contacte a "
        "APS Conecta.")
FAILED = "Nextcloud no completó «occ {}». Presione «Reintentar»; si vuelve a ocurrir, contacte a APS Conecta."
ISSUER_FAILED = "No se pudo obtener ni verificar el certificado intermedio de {}."
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


class Nextcloud:
    """The real one: each command runs in the Nextcloud container as its web user, through the Docker socket."""

    @staticmethod
    def execute(script, *args, stdin="", failed):
        """What the shell script printed in the container, run with `args`; Unreachable with `failed` when it fails, or
        with DOWN when the container does not answer. Only the errors are logged."""
        try:
            run = subprocess.run(["docker", "exec", "--interactive", "--user", "www-data", CONTAINER, "sh", "-c",
                                  script, "sh", *args], input=stdin, capture_output=True, text=True, timeout=120,
                                 check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f"{CONTAINER}: {error}", file=sys.stderr, flush=True)
            raise Unreachable(DOWN) from None
        if run.returncode:
            print(f"{CONTAINER} {args[:1]}: {run.stderr}", file=sys.stderr, flush=True)
            answered = "Error response from daemon" not in run.stderr and "No such container" not in run.stderr
            raise Unreachable(failed if answered else DOWN)
        return run.stdout

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


class FakeNextcloud:
    """The fake one: Nextcloud's settings, `system` and `apps` by app, the latter for every app it has, and the CAs its
    own requests trust beside the ones it ships: the files of AIO's folder of trusted CAs, and the issuers of the hosts
    that serve only their leaf. It does not answer while `down` is set, an import silently keeps the `ignored` settings
    out, and the issuers of the `unreachable` hosts cannot be fetched."""

    def __init__(self):
        self.down = False
        self.system = {}
        self.apps = {"core": {}, "admin_audit": {"enabled": "no"}}
        self.ignored = set()
        self.cacerts = []  # the files of AIO's folder of trusted CAs: a test build's; a release has none
        self.trusted = set()  # those among Nextcloud's trusted certificates
        self.issuers = set()  # the hosts whose issuer is among them
        self.unreachable = set()

    def occ(self, *args, stdin=""):
        """The commands the install steps run: settings out and in, and an app on."""
        if self.down:
            raise Unreachable(DOWN)
        if args == ("config:list",):
            return json.dumps({"system": self.system, "apps": self.apps})
        if args == ("config:import",):
            settings = json.loads(stdin)
            self.system.update({k: v for k, v in settings.get("system", {}).items() if k not in self.ignored})
            for app, values in settings.get("apps", {}).items():
                self.apps.setdefault(app, {}).update({k: v for k, v in values.items() if k not in self.ignored})
            return ""
        if args[0] == "app:enable" and len(args) == 2:
            if args[1] not in self.apps:
                raise Unreachable(FAILED.format(" ".join(args)))
            self.apps[args[1]]["enabled"] = "yes"
            return ""
        raise AssertionError(f"the fake Nextcloud runs no occ {args}")

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
