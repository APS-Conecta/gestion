#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""«Revisar» and «Instalar» on a test build. «Centro» confirms one of gestion's reserved DEIS codes and «Dirección»
claims its CI name (claim.py); the page goes on to «Revisar», which summarises the centre, the name, its timezone, the
components and the backup. «Instalar» shows each container's progress as AIO reads it, while AIO's interface still
answers with the Provisionador alone, and «Listo» shows the suite's address once every container runs: exactly the
suite's, the components on. Then AIO's interface serves AIO's page, which keeps the settings «Instalar» wrote."""

import json
import os
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit

ACCEPTANCE = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ACCEPTANCE), str(ACCEPTANCE.parent / "provisionador")]
from browser import chromium, machine, mastercontainer_file, printed_link, verified  # noqa: E402
from claim import api, claim, reserved  # noqa: E402
from playwright.sync_api import expect  # noqa: E402
from steps import backups, components  # noqa: E402

LISTO_WAIT = 20 * 60  # seconds: AIO's start, Nextcloud's first setup and each component's own
PROBE = 60  # seconds between two looks at AIO's pages during the install
LISTO = "/mnt/docker-aio-config/provisionador/listo"
# The suite «Instalar» starts: AIO's core, our Caddy, and Talk, Euro-Office, ClamAV, Imaginary, full-text search and
# HaRP; Talk's recording server waits for #290.
SUITE = sorted(f"nextcloud-aio-{c}" for c in ("apache", "caddy", "clamav", "database", "eurooffice", "fulltextsearch",
                                              "harp", "imaginary", "nextcloud", "notify-push", "redis", "talk"))

link, printed = printed_link(Path(os.environ["CONSOLE"]).read_text(encoding="utf-8"))
url = urlsplit(link)
interface = f"https://{url.netloc}"  # AIO's interface, where the Provisionador answers until «Listo»
evidence = Path(os.environ["EVIDENCE"])


def aio_hidden(page):
    """AIO's own pages answer with the Provisionador's JSON for a route it does not know, until «Listo»."""
    for path in ("/login", "/containers", "/setup"):
        status, answer = api(page, "GET", path)
        if status == 404 and isinstance(answer, dict) and "error" in answer:
            continue
        if machine(f"sudo docker exec nextcloud-aio-mastercontainer sh -c 'test -e {LISTO} && echo listo || true'"):
            return  # «Listo» came meanwhile
        sys.exit(f"before «Listo», {interface}{path} answers HTTP {status}, not as the Provisionador does: AIO's page "
                 "shows")


with chromium(pinned=[verified(url.hostname, url.port, printed)]) as browser:
    page = browser.new_page(viewport={"width": 1280, "height": 900})
    page.goto(link)
    expect(page.get_by_role("heading", name="Centro", exact=True)).to_be_visible(timeout=30_000)
    aio_hidden(page)
    name = claim(page, reserved())
    page.reload()
    expect(page.locator("#address-name")).to_have_text(f"https://{name}", timeout=30_000)
    page.click("#to-revisar")
    expect(page.get_by_role("heading", name="Revisar", exact=True)).to_be_visible()
    centre = api(page, "GET", "/api/state")[1]["centre"]
    expect(page.locator("#summary-centre")).to_contain_text(f"{centre['name']}, {centre['comuna']}")
    expect(page.locator("#summary-address")).to_have_text(f"https://{name}")
    expect(page.locator("#summary-timezone")).to_have_text(centre["timezone"])
    expect(page.locator("#summary-components li")).to_have_text(components.NAMES)
    expect(page.locator("#summary-backup")).to_contain_text(f"{backups.TIME} UTC, en la carpeta {backups.FOLDER}")
    page.screenshot(path=evidence / "revisar.png")
    page.click("#install")
    expect(page.locator("#progress li")).not_to_have_count(0, timeout=60_000)
    seen = {}  # each container's states, in the order the page showed them
    deadline, probed = time.monotonic() + LISTO_WAIT, time.monotonic()
    while not page.locator("#listo").is_visible():
        for container, state in page.eval_on_selector_all(
                "#progress li", "items => items.map(i => [i.querySelector('strong').textContent, i.dataset.state])"):
            if seen.setdefault(container, [state])[-1] != state:
                seen[container].append(state)
        if page.locator("#install").is_enabled() or time.monotonic() > deadline:  # «Reintentar», or too long
            page.screenshot(path=evidence / "instalar.png")
            sys.exit(f"no «Listo» within {LISTO_WAIT // 60} minutes: {page.inner_text('#install-status')}")
        if time.monotonic() > probed + PROBE:
            aio_hidden(page)
            probed = time.monotonic()
        if len(seen) > 1 and not (evidence / "progreso.png").exists():
            page.screenshot(path=evidence / "progreso.png")
        page.wait_for_timeout(2000)
    progress = "".join(f"{container}: {' → '.join(states)}\n" for container, states in seen.items())
    (evidence / "progreso.txt").write_text(progress, encoding="utf-8")
    print(progress, end="")
    expect(page.locator("#suite-address")).to_have_text(f"https://{name}")
    expect(page.locator("#suite-address")).to_have_attribute("href", f"https://{name}")
    page.screenshot(path=evidence / "listo.png")
    aio = browser.new_page()  # a context of its own: no session of the Provisionador's
    aio.goto(f"{interface}/")
    if urlsplit(aio.url).path != "/login":
        sys.exit(f"after «Listo», {interface}/ leads to {aio.url}, not to AIO's login")

running = machine("sudo docker ps --all --filter name=^nextcloud-aio- --format '{{.Names}} {{.State}}'").split("\n")
started = dict(line.split() for line in running if line and not line.startswith("nextcloud-aio-mastercontainer "))
print("".join(f"{container} {state}\n" for container, state in sorted(started.items())), end="")
if sorted(started) != SUITE or set(started.values()) != {"running"}:
    sys.exit(f"at «Listo», these containers do not run exactly the suite's: {started}")
if len(seen) != len(SUITE) or not any(len(states) > 1 for states in seen.values()):
    sys.exit(f"the page did not show the progress of each of the suite's {len(SUITE)} containers: {seen}")
config = json.loads(mastercontainer_file("/mnt/docker-aio-config/data/configuration.json"))  # its secrets stay unprinted
written = {key: config.get(key) for key in ("domain", "officeSuite", "isTalkEnabled", "isClamavEnabled",
                                            "isImaginaryEnabled", "isFulltextsearchEnabled", "isHarpEnabled",
                                            "isTalkRecordingEnabled", "isDockerSocketProxyEnabled",
                                            "isWhiteboardEnabled", "timezone", "borg_backup_host_location")}
backup = mastercontainer_file("/mnt/docker-aio-config/data/daily_backup_time").splitlines()
print(f"AIO keeps {written}; its daily backup file: {backup}")
if written != {"domain": name, "officeSuite": "eurooffice", "isTalkEnabled": True, "isClamavEnabled": True,
               "isImaginaryEnabled": True, "isFulltextsearchEnabled": True, "isHarpEnabled": True,
               "isTalkRecordingEnabled": False, "isDockerSocketProxyEnabled": False, "isWhiteboardEnabled": False,
               "timezone": centre["timezone"], "borg_backup_host_location": "/var/backups/apsconecta-gestion"} \
        or backup[:2] != ["06:00", "automaticUpdatesAreNotEnabled"]:
    sys.exit("AIO does not keep the settings «Instalar» wrote for each choice")
print(f"«Listo» shows https://{name} once the suite's {len(started)} containers run; AIO's page was hidden until then")
