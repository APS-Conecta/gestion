#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The spreed fork's refresh (ADR-0020, #145): upstream's newest stable release for a
Nextcloud major, proven against upstream's own checksums and repacked as the App release the
suite installs. Two verbs, one resolver, run from two places — the fork repo's refresh
workflow (which signs and publishes) and instalador's release chain (which names the release
it expects before it dispatches the fork):

  scripts/spreed-refresh.py resolve --nextcloud 34
      The appstore record's newest STABLE spreed release whose Nextcloud range covers the
      major — the same record `occ app:install` consults, so "what the store would install"
      is the candidate, never a list we keep here. TSV on stdout:
      version<TAB>tag<TAB>download-url<TAB>sha256<TAB>repo, where sha256 is the release
      asset digest GitHub publishes for exactly those bytes.
  scripts/spreed-refresh.py refresh --nextcloud 34 --out dist
      dist/ as the four fixed-name assets minus the signature: spreed.tar.gz (upstream's
      tarball with exactly one difference — appinfo/signature.json dropped, the one file a
      release of ours never carries, ADR-0017), info.xml (the tarball's own), and SHA256SUMS
      over both. Nothing is written until upstream's digest has proven the download and the
      tarball's own info.xml has proven id, version and the range (fail closed, everywhere).
  scripts/spreed-refresh.py --self-test
      Hermetic: a fixture store, a fixture GitHub API and fixture tarballs over local HTTP —
      real redirects, real checksums, no network.

Standard library only, on Python 3.10 (Ubuntu 22.04's), like releases.py beside it. The knobs
are read at call time (APS_SPREED_STORE, APS_APPS_GH, APS_APPS_API) so the self-test points the
whole tool at its fixtures; production never overrides them. APS_APPS_GH and APS_APPS_API are
the same knobs releases.py reads, so one environment points both resolvers.
"""
import gzip
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

APP = "spreed"
STORE_DEFAULT = "https://apps.nextcloud.com/api/v1/apps.json"
GH_DEFAULT = "https://github.com"
API_DEFAULT = "https://api.github.com"
UA = "aps-conecta-instalador"   # GitHub answers 403 to a bare urllib UA on some routes
TIMEOUT = 120                   # upstream's tarball is ~54 MB; bounded, never hung
VERSION = re.compile(r"(\d+)\.(\d+)\.(\d+)$")          # stable only — no -rc, no -alpha
DOWNLOAD = re.compile(r"^(https?://[^/]+)/([^/]+/[^/]+)/releases/download/([^/]+)/([^/?#]+)$")
SPEC = re.compile(r">=\s*(\d+)\s*<=\s*(\d+)")          # the store's own form: both bounds, always


class Refusal(Exception):
    """One English line — this tool's reader is a release pipeline log, not an operator."""


def store_url():
    return os.environ.get("APS_SPREED_STORE", STORE_DEFAULT)


def api_base():
    return os.environ.get("APS_APPS_API", API_DEFAULT)


def _get(url, accept=None):
    headers = {"User-Agent": UA}
    if accept:
        headers["Accept"] = accept
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        raise Refusal(f"HTTP {e.code} fetching {url}") from None
    except (urllib.error.URLError, OSError) as e:
        raise Refusal(f"could not fetch {url} "
                      f"({e.reason if isinstance(e, urllib.error.URLError) else e})") from None


def covers(spec, major):
    """Whether a rawPlatformVersionSpec (">=34 <=34") covers a major — the record's own words,
    parsed minimally; a spec this cannot read covers nothing (fail closed, never guess)."""
    m = SPEC.fullmatch(spec.strip())
    if not m:
        return False
    return int(m.group(1)) <= major <= int(m.group(2))


def newest(releases, major):
    """The record's newest stable spreed release covering the major: (version, download url)."""
    best = None
    for r in releases:
        if not isinstance(r, dict) or r.get("isNightly"):
            continue
        m = VERSION.fullmatch(r.get("version", ""))
        if not m:   # -rc, -alpha, malformed: upstream's prereleases are not our candidates
            continue
        if not covers(r.get("rawPlatformVersionSpec") or "", major):
            continue
        key = tuple(int(g) for g in m.groups())
        if best is None or key > best[0]:
            best = (key, r["version"], r.get("download", ""))
    if best is None:
        raise Refusal(f"the appstore record names no stable spreed release for Nextcloud {major}")
    return best[1], best[2]


def asset_digest(url):
    """The sha256 GitHub publishes for a release asset URL (upstream's own checksum): parse the
    URL back into repo/tag/name, ask the releases API for the asset, require its digest. The
    download URL and the digest must agree on the same release entry or nothing moves."""
    m = DOWNLOAD.match(url)
    if not m:
        raise Refusal(f"the record's download URL is not a GitHub release asset: {url}")
    _scheme, repo, tag, name = m.group(1), m.group(2), m.group(3), m.group(4)
    data = json.loads(_get(f"{api_base()}/repos/{repo}/releases/tags/{tag}",
                           accept="application/vnd.github+json"))
    for a in data.get("assets", []):
        if a.get("name") in (name, urllib.parse.quote(name, safe="")):
            digest = a.get("digest") or ""
            if not digest.startswith("sha256:"):
                raise Refusal(f"the release {tag} of {repo} publishes no sha256 asset digest — "
                              "upstream's own checksum is the refresh's floor, never skipped")
            return digest[len("sha256:"):], repo
    raise Refusal(f"the release {tag} of {repo} does not carry the asset {name} the record names")


def resolve(major):
    data = json.loads(_get(store_url()))
    app = next((a for a in data if isinstance(a, dict) and a.get("id") == APP), None)
    if app is None:
        raise Refusal(f"the appstore record names no {APP} at all")
    version, url = newest(app.get("releases") or [], major)
    sha256, repo = asset_digest(url)
    return {"version": version, "tag": f"v{version}", "url": url, "sha256": sha256, "repo": repo}


# ── the refresh: proven bytes in, the App release's three unsigned files out ──────────────


def info_of(data):
    """info.xml as the facts the refresh proves: id, version, the Nextcloud range."""
    try:
        root = ET.fromstring(data)
        deps = root.find("dependencies/nextcloud")
        return {"id": (root.findtext("id") or "").strip(),
                "version": (root.findtext("version") or "").strip(),
                "min": int(deps.get("min-version")) if deps is not None and deps.get("min-version") else None,
                "max": int(deps.get("max-version")) if deps is not None and deps.get("max-version") else None}
    except (ET.ParseError, ValueError, TypeError):
        return None


def repack(data, version, major):
    """Upstream's tarball, proven and rewritten: every member under one top directory equal to
    the app id; the inner info.xml declaring the same version and a range covering the major;
    the one member that changes — appinfo/signature.json — dropped (a release of ours never
    carries one, ADR-0017; the store's signature would be false over our tarball anyway).
    The gzip is written with mtime 0 so one upstream tarball always refreshes to the same
    bytes. Returns (spreed.tar.gz bytes, info.xml bytes)."""
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
            members = tar.getmembers()
            tops = {m.name.split("/")[0] for m in members}
            if len(tops) != 1 or APP not in tops:
                raise Refusal(f"upstream's tarball unpacks «{sorted(tops)[0] if tops else 'nada'}/», "
                              f"not «{APP}/» — the release's shape refuses it")
            names = {m.name for m in members}
            if f"{APP}/appinfo/info.xml" not in names:
                raise Refusal(f"upstream's tarball carries no {APP}/appinfo/info.xml — the "
                              "release's version and range cannot be proven")
            info = info_of(tar.extractfile(f"{APP}/appinfo/info.xml").read())
            if not info or info["id"] != APP:
                raise Refusal(f"the tarball's info.xml declares the id "
                              f"«{info['id'] if info else '?'}», not «{APP}»")
            if info["version"] != version:
                raise Refusal(f"the tarball's info.xml declares version «{info['version']}», "
                              f"not the «{version}» the record resolved")
            if info["min"] is None or not info["min"] <= major <= (info["max"] or 99):
                raise Refusal(f"the tarball's info.xml declares a range that does not cover "
                              f"Nextcloud {major} — the record and the bytes disagree")
            inner = tar.extractfile(f"{APP}/appinfo/info.xml").read()
            out = io.BytesIO()
            # mtime 0 in the gzip header: one upstream tarball, one refresh, always the same
            # bytes; the gzip layer closes (its trailer) before the bytes are read back
            with gzip.GzipFile(fileobj=out, mode="wb", mtime=0) as gz, \
                    tarfile.open(fileobj=gz, mode="w") as nuevo:
                for member in members:
                    if member.name == f"{APP}/appinfo/signature.json":
                        continue
                    nuevo.addfile(member, tar.extractfile(member) if member.isfile() else None)
    except tarfile.TarError as e:
        raise Refusal(f"upstream's tarball is not a legible tar.gz ({e})") from None
    return out.getvalue(), inner


def refresh(major, out):
    r = resolve(major)
    data = _get(r["url"])
    got = hashlib.sha256(data).hexdigest()
    if got != r["sha256"]:
        raise Refusal(f"the downloaded tarball's sha256 {got} is not the digest GitHub publishes "
                      f"for that asset ({r['sha256']}) — upstream's own checksum refused it")
    tgz, info = repack(data, r["version"], major)
    os.makedirs(out, exist_ok=True)
    sha_tgz, sha_info = hashlib.sha256(tgz).hexdigest(), hashlib.sha256(info).hexdigest()
    with open(os.path.join(out, f"{APP}.tar.gz"), "wb") as fh:
        fh.write(tgz)
    with open(os.path.join(out, "info.xml"), "wb") as fh:
        fh.write(info)
    with open(os.path.join(out, "SHA256SUMS"), "w", encoding="utf-8") as fh:
        fh.write(f"{sha_tgz}  {APP}.tar.gz\n{sha_info}  info.xml\n")
    return r


# ── the CLI ───────────────────────────────────────────────────────────────────────────────


def main(argv):
    if argv == ["--self-test"]:
        return selftest()
    if len(argv) == 3 and argv[0] == "resolve" and argv[1] == "--nextcloud" and argv[2].isdigit():
        try:
            r = resolve(int(argv[2]))
        except (Refusal, ValueError) as e:
            print(f"no upstream spreed for this suite: {e}", file=sys.stderr)
            return 1
        print("\t".join((r["version"], r["tag"], r["url"], r["sha256"], r["repo"])))
        return 0
    if (len(argv) == 5 and argv[0] == "refresh" and argv[1] == "--nextcloud" and argv[2].isdigit()
            and argv[3] == "--out" and argv[4]):
        try:
            r = refresh(int(argv[2]), argv[4])
        except (Refusal, ValueError) as e:
            print(f"the spreed refresh refused: {e}", file=sys.stderr)
            return 1
        print(f"✓ spreed {r['version']} ({r['tag']}) proven against upstream's own checksum "
              f"and repacked in {argv[4]}")
        return 0
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


# ── the self-test: a fixture store, a fixture GitHub API and fixture tarballs over HTTP ───


def selftest():
    """Hermetic: the store's apps.json, the releases API and the tarballs themselves served
    from 127.0.0.1 with the shapes upstream answers (the rawPlatformVersionSpec grammar, the
    asset digest, the tarball's members), one arm per behaviour the refresh leans on."""
    import http.server
    import tempfile
    import threading

    n = failed = 0

    def check(label, ok):
        nonlocal n, failed
        n += 1
        if not ok:
            failed += 1
            print(f"  FAIL: {label}", file=sys.stderr)

    def refused(fn, *args, **kw):
        try:
            fn(*args, **kw)
            return ""
        except Refusal as e:
            return str(e)

    def sha(b):
        return hashlib.sha256(b).hexdigest()

    # one fixture release: a real tar.gz over members shaped like upstream's (one top dir,
    # appinfo/info.xml declaring the range, appinfo/signature.json — the one file dropped)
    def tgz_fixture(version, lo="34", hi="34", top=APP, con_firma=True, id_xml=APP,
                    version_xml=None):
        info = (f'<?xml version="1.0"?>\n<info><id>{id_xml}</id>'
                f"<version>{version_xml or version}</version>"
                f'<dependencies><nextcloud min-version="{lo}"'
                + (f' max-version="{hi}"' if hi else "") + "/></dependencies></info>\n").encode()
        files = [(f"{top}/appinfo/info.xml", info), (f"{top}/lib/App.php", b"<?php\n")]
        if con_firma:
            files.append((f"{top}/appinfo/signature.json", b"{}\n"))
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as tar:
            for name, blob in files:
                member = tarfile.TarInfo(name)
                member.size = len(blob)
                tar.addfile(member, io.BytesIO(blob))
        return buf.getvalue(), info

    cuerpo, info34 = tgz_fixture("24.0.6")
    cuerpo35, _ = tgz_fixture("25.0.6", lo="35", hi="35")
    cuerpo33, _ = tgz_fixture("22.2.4", lo="31", hi="33")
    # the defects: each knob is one of the refusals the refresh owes
    t_mala_suma, _ = tgz_fixture("24.0.6")   # bytes right, digest column lied about below
    t_otro_dir, _ = tgz_fixture("24.0.6", top="otro")
    t_otra_id, _ = tgz_fixture("24.0.6", id_xml="distinto")
    t_otra_version, _ = tgz_fixture("24.0.6", version_xml="24.0.5")
    t_fuera_rango, _ = tgz_fixture("24.0.6", lo="35", hi="35")

    def fila(base, version, spec, digesto="x" * 64, cuerpo=None, nightly=False):
        return {"version": version, "isNightly": nightly, "rawPlatformVersionSpec": spec,
                "download": f"{base}/nextcloud-releases/spreed/releases/download/"
                            f"v{version}/spreed-v{version}.tar.gz",
                "_digest": digesto, "_bytes": cuerpo or cuerpo}

    # the store's rows are built once the hub is up: their download URLs must ride the local
    # hub, never github.com — the whole refresh (downloads included) stays hermetic
    def build_store(base):
        return [{"id": APP, "releases": [
                     fila(base, "24.0.6", ">=34 <=34", sha(cuerpo), cuerpo),
                     fila(base, "25.0.6", ">=35 <=35", sha(cuerpo35), cuerpo35),
                     fila(base, "24.0.7-rc1", ">=34 <=34", cuerpo=cuerpo),
                     fila(base, "25.0.7", ">=35 <=35", cuerpo=cuerpo35, nightly=True),
                     fila(base, "22.2.4", ">=31 <=33", sha(cuerpo33), cuerpo33),
                     fila(base, "24.0.5", ">=34 <=34", "0" * 64, cuerpo),  # digest lies about bytes
                     fila(base, "24.0.4", ">=34 <=34", sha(cuerpo), t_otro_dir),
                     fila(base, "24.0.3", ">=34 <=34", sha(cuerpo), t_otra_id),
                     fila(base, "24.0.2", ">=34 <=34", sha(cuerpo), t_otra_version),
                     fila(base, "24.0.1", ">=34 <=34", sha(cuerpo), t_fuera_rango)]},
                 {"id": "calendar", "releases": [fila(base, "5.0.0", ">=31 <=35", cuerpo=cuerpo)]}]

    class Hub(http.server.BaseHTTPRequestHandler):
        def _serve(self, head):
            path = urllib.parse.urlparse(self.path).path
            if path == "/store.json":
                # the store's own shape, private fixture knobs (_digest, _bytes) stripped per release
                cuerpo_store = [{"id": a["id"],
                                 "releases": [{k: v for k, v in f.items()
                                               if not k.startswith("_")}
                                              for f in a["releases"]]} for a in store]
                body, kind = json.dumps(cuerpo_store).encode(), "application/json"
            elif path.startswith("/repos/"):
                # repos/{owner}/{repo}/releases/tags/{tag} — the owner never carries a slash
                partes = path.strip("/").split("/")
                repo, tag = f"{partes[1]}/{partes[2]}", partes[5]
                assets = [{"name": nombre, "digest": digesto}
                          for nombre, digesto in api.get(repo, {}).get(tag, [])]
                body, kind = json.dumps({"assets": assets}).encode(), "application/json"
            else:
                self.server.hits["download"] += 1
                name = path.rsplit("/", 1)[-1]
                tag = path.rsplit("/", 2)[-2]
                blob = files.get(tag[1:] if tag.startswith("v") else tag, b"")
                if not blob:
                    self.send_error(404)
                    return
                body, kind = blob, "application/octet-stream"
            self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if not head:
                self.wfile.write(body)

        def do_GET(self):
            self._serve(False)

        def do_HEAD(self):
            self._serve(True)

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Hub)
    server.hits = {"download": 0}
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ)
    base = f"http://127.0.0.1:{server.server_address[1]}"
    os.environ["APS_SPREED_STORE"] = f"{base}/store.json"
    os.environ["APS_APPS_API"] = base
    os.environ["APS_APPS_GH"] = base
    store = build_store(base)
    api = {"nextcloud-releases/spreed": {}}
    files = {}
    for fila_release in store[0]["releases"]:
        api["nextcloud-releases/spreed"][f"v{fila_release['version']}"] = [
            (f"spreed-v{fila_release['version']}.tar.gz", "sha256:" + fila_release["_digest"])]
        files[fila_release["version"]] = fila_release["_bytes"]
    tmp = tempfile.mkdtemp(prefix="spreed-refresh-selftest-")
    try:
        r = resolve(34)
        check("resolve: the newest stable release for the major, with GitHub's own digest",
              r["version"] == "24.0.6" and r["tag"] == "v24.0.6" and r["sha256"] == sha(cuerpo)
              and r["repo"] == "nextcloud-releases/spreed")
        check("resolve: another major gets its own newest — and a covered-by-nothing one refuses",
              resolve(35)["version"] == "25.0.6" and resolve(33)["version"] == "22.2.4"
              and "names no stable spreed release" in refused(resolve, 36))
        check("resolve: prereleases and nightlies are never candidates",
              r["version"] == "24.0.6" and resolve(35)["version"] == "25.0.6")
        check("covers: a spec this cannot read covers nothing",
              not covers(">=34", 34) and not covers("", 34) and covers(">=34 <=34", 34)
              and covers(">=31 <=35", 33) and not covers(">=35 <=35", 34))

        out = os.path.join(tmp, "dist")
        rr = refresh(34, out)
        tgz_path = os.path.join(out, "spreed.tar.gz")
        sums = open(os.path.join(out, "SHA256SUMS"), encoding="utf-8").read()
        with tarfile.open(tgz_path) as tar:
            names = tar.getnames()
        check("refresh: dist carries the three unsigned assets — upstream's tarball minus "
              "signature.json, the appinfo info.xml, and SHA256SUMS naming both by their sha",
              rr["version"] == "24.0.6"
              and open(os.path.join(out, "info.xml"), "rb").read() == info34
              and f"{sha(open(tgz_path, 'rb').read())}  spreed.tar.gz" in sums
              and f"{sha(info34)}  info.xml" in sums
              and f"{APP}/appinfo/signature.json" not in names
              and f"{APP}/appinfo/info.xml" in names and f"{APP}/lib/App.php" in names)
        # the deterministic repack: the same upstream bytes always refresh to the same dist
        with open(tgz_path, "rb") as fh:
            first = fh.read()
        shutil.rmtree(out)
        refresh(34, out)
        check("refresh: one upstream tarball always refreshes to the same bytes (gzip mtime 0)",
              open(tgz_path, "rb").read() == first)
        shutil.rmtree(out)

        # the digest floor: bytes that do not match the digest GitHub publishes — the store
        # re-ordered in place so the lying 24.0.5 row is the newest covering 34, then restored
        filas = store[0]["releases"]
        guardadas = [dict(f) for f in filas]
        for f in filas:
            if f["version"] != "24.0.5":
                f["rawPlatformVersionSpec"] = ">=1 <=1"   # nothing else covers 34
        out_mala = os.path.join(tmp, "digest-mentira")
        causa = refused(refresh, 34, out_mala)
        store[0]["releases"][:] = guardadas
        check("refresh: a download that fails upstream's own digest is refused — the floor "
              "upstream's checksum owes, never skipped",
              "not the digest GitHub publishes" in causa and not os.path.exists(out_mala))

        out2 = os.path.join(tmp, "d2")
        check("refresh: a wrong top directory, a foreign id, a disagreeing version and a range "
              "that misses the major are each refused — via the rows that carry them",
              "not «spreed/»" in refused(repack, files["24.0.4"], "24.0.6", 34)
              and "«distinto»" in refused(repack, files["24.0.3"], "24.0.6", 34)
              and "«24.0.5»" in refused(repack, files["24.0.2"], "24.0.6", 34)
              and "does not cover" in refused(repack, files["24.0.1"], "24.0.6", 34))
        check("refresh: a refusal writes no dist",
              not os.path.exists(out2) and not os.path.exists(os.path.join(tmp, "x")))

        run = subprocess.run([sys.executable, os.path.abspath(__file__), "resolve",
                              "--nextcloud", "34"], capture_output=True, text=True, timeout=60)
        check("cli resolve: the TSV the release chain reads — version, tag, url, sha256, repo",
              run.returncode == 0 and run.stdout.rstrip("\n").split("\t")
              == ["24.0.6", "v24.0.6",
                  f"{base}/nextcloud-releases/spreed/releases/download/v24.0.6/"
                  f"spreed-v24.0.6.tar.gz", sha(cuerpo), "nextcloud-releases/spreed"])
        cli_out = os.path.join(tmp, "cli-dist")
        run = subprocess.run([sys.executable, os.path.abspath(__file__), "refresh",
                              "--nextcloud", "34", "--out", cli_out],
                             capture_output=True, text=True, timeout=60)
        check("cli refresh: exit 0, the ✓ line, and the three assets laid out",
              run.returncode == 0 and "✓ spreed 24.0.6 (v24.0.6)" in run.stdout
              and os.path.isfile(os.path.join(cli_out, "spreed.tar.gz"))
              and os.path.isfile(os.path.join(cli_out, "info.xml"))
              and os.path.isfile(os.path.join(cli_out, "SHA256SUMS")))
        run = subprocess.run([sys.executable, os.path.abspath(__file__), "refresh",
                              "--nextcloud", "36", "--out", os.path.join(tmp, "nada")],
                             capture_output=True, text=True, timeout=60)
        check("cli refresh: a refusal exits 1 with the one line and writes nothing",
              run.returncode == 1 and run.stderr.startswith("the spreed refresh refused")
              and not os.path.exists(os.path.join(tmp, "nada")))
        run = subprocess.run([sys.executable, os.path.abspath(__file__)],
                             capture_output=True, text=True, timeout=60)
        check("cli: no arguments is a usage error, never a guess", run.returncode == 2)

        server.shutdown()
        print(f"self-test: {n} checks OK" if not failed
              else f"self-test: {failed} of {n} checks FAILED")
        return 1 if failed else 0
    finally:
        os.environ.clear()
        os.environ.update(env)
        server.server_close()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
