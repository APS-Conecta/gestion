#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Office as in any Nextcloud, on a test build. Nextcloud's Office entry is on, with our Office defaults, and neither
Collabora's nor OnlyOffice's connector is (40-install holds their containers off). A staff member signed in at the
suite's name opens the Office entry from its navigation icon, in Nextcloud's app menu, and creates a blank DOCX in its
document hub, which opens in Euro-Office; they type a line, save and close it, and the DOCX Nextcloud keeps holds the
line. Reopened from the Office entry, Euro-Office shows it. Any other candidate's names and certificates are production ones, which a run
never claims: there it says so and passes."""

import base64
import contextlib
import io
import json
import os
import re
import secrets
import sys
import time
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from browser import chromium, machine, suite_name  # noqa: E402
from playwright.sync_api import Error  # noqa: E402

NEXTCLOUD = "sudo docker exec --interactive --user www-data nextcloud-aio-nextcloud"
OCC = f"{NEXTCLOUD} php /var/www/html/occ"
ODF = '{"odt":true,"ods":true,"odp":true}'
DEFAULTS = {"office": {"enabled": "yes"}, "eurooffice": {"defFormats": ODF, "editFormats": ODF,
                                                         "customizationTheme": "default-light", "sameTab": "false"}}
OTHER_OFFICES = {"richdocuments", "onlyoffice"}  # the connectors of Collabora and OnlyOffice
USER, FILE = "prueba.oficina", "acta-de-prueba.docx"
# In every frame, each message it receives that names an event, as Euro-Office's Gateway.js posts DocsAPI's events
# (onDocumentReady, onDocumentStateChange, ...) to the frame holding its iframe "frameEditor": the event, its data, the
# second since the frame loaded, and whether that iframe sent it.
EDITOR_EVENTS = """window.editorEvents = [];
window.addEventListener('message', event => {
  let message;
  try { message = typeof event.data === 'string' ? JSON.parse(event.data) : event.data; } catch (error) { return; }
  const name = message?.event ?? message?.method;
  if (typeof name !== 'string') return;
  const editors = [...document.querySelectorAll('iframe[name="frameEditor"]')];
  const editor = editors.some(f => f.contentWindow === event.source);
  window.editorEvents.push([name, message.data ?? null, Math.round(performance.now() / 1000), editor]);
});"""
# What the editor reported: its document loaded; it held an edit, and then the document server had every edit.
READY = "its document ready", "editorEvents.some(([name, , , editor]) => editor && name === 'onDocumentReady')"
SAVED = "the edit saved", """(() => {
  const states = editorEvents.filter(([name, , , editor]) => editor && name === 'onDocumentStateChange');
  return states.some(([, unsaved]) => unsaved) && states.at(-1)[1] === false;
})()"""

if os.environ["TEST_BUILD"] != "true":
    print(f"the Office check runs on a v0.0.0-ci.N test build only: {os.environ['TAG']}'s names and certificates are "
          "production ones")
    sys.exit()
evidence = Path(os.environ["EVIDENCE"])
suite = f"https://{suite_name()}"

held = json.loads(machine(f"{OCC} config:list --output=json"))["apps"]
settings = {app: {key: held.get(app, {}).get(key) for key in values} for app, values in DEFAULTS.items()}
print(f"Nextcloud holds {settings}")
if settings != DEFAULTS:
    sys.exit("Nextcloud does not hold the Office entry and the Office defaults the Office step declares")
others = sorted(OTHER_OFFICES & set(json.loads(machine(f"{OCC} app:list --output=json"))["enabled"]))
if others:
    sys.exit(f"Nextcloud has another office suite's connector on: {', '.join(others)}")

password = secrets.token_urlsafe(18)  # the staff account's, on stdin only
print(f"::add-mask::{password}", flush=True)
machine(f"{NEXTCLOUD} sh -c 'read -r OC_PASS && export OC_PASS && php /var/www/html/occ user:add --password-from-env "
        f"--display-name \"Prueba Oficina\" {USER}'", stdin=f"{password}\n")
machine(f"{OCC} user:setting {USER} firstrunwizard show 999.0.0")  # no first-run wizard over the Office entry


def until(read, wait, failure, pause=time.sleep):
    deadline = time.monotonic() + wait
    while not (answer := read()):
        if time.monotonic() > deadline:
            sys.exit(failure() if callable(failure) else failure)
        pause(1)
    return answer


def served(frame):
    """Whether the frame is Euro-Office's document editor, served under the suite's name."""
    return frame.url.startswith(f"{suite}/eurooffice/") and "/documenteditor/" in frame.url


def editor(context, state=READY):
    """The page and frame of the Euro-Office editor, once it reported `state` to the frame that holds it."""
    reported, holds = state

    def found():
        for page in context.pages:
            for frame in filter(served, page.frames):
                with contextlib.suppress(Error):  # a frame that navigates away
                    if frame.parent_frame.evaluate(holds) and frame.locator("#editor_sdk").is_visible():
                        return page, frame
        return None
    # Playwright's sync API takes in the browser's frames and their navigations only while it waits on the browser, so
    # the pause waits there: in time.sleep, page.frames would stay as it was before the editor opened.
    return until(found, 120, lambda: f"Euro-Office under {suite}/eurooffice/ did not report {reported} within 2 "
                                     f"minutes. The frames, nested, and the events each received:\n{seen(context)}",
                 lambda seconds: context.pages[0].wait_for_timeout(seconds * 1000))


def seen(context):
    """Each page's frames by URL without its query, nested, with the events each received (data that is no link or
    token) and, for the editor, whether its document shows."""
    lines = []
    for n, page in enumerate(context.pages):
        for frame in page.frames:
            depth, parent = 0, frame.parent_frame
            while parent:
                depth, parent = depth + 1, parent.parent_frame
            events, shows = None, ""
            with contextlib.suppress(Error):
                events = frame.evaluate("window.editorEvents")
                if served(frame):
                    shows = f" [#editor_sdk visible: {frame.locator('#editor_sdk').is_visible()}]"
            received = "no listener" if events is None else "; ".join(
                f"{name}{'' if data in (None, {}) else ' ' + json.dumps(shown(data))} at {second} s"
                f"{'' if editor else ' (not from frameEditor)'}" for name, data, second, editor in events) or "none"
            lines.append(f"{'  ' * depth}page {n} {frame.url.split('?')[0]}{shows}: {received}")
    return "\n".join(lines)


def shown(data):
    if not isinstance(data, dict):
        return data
    return {k: v for k, v in data.items() if not (isinstance(v, (dict, list)) or re.search("url|token|link", k, re.I))}


def office(page):
    """Nextcloud's Office entry, opened from its icon in Nextcloud's app menu as staff open it, at its documents."""
    page.goto(suite)
    page.locator(".app-menu__waffle").click()  # the app menu's button, beside the logo
    page.locator('a[role="menuitem"][href*="/apps/office"]').click()
    page.get_by_text("Documentos", exact=True).first.click()


def edit(context, line):
    """Type the line at the document's end, save and close it: Euro-Office stores the document once its editor
    closes."""
    page, frame = editor(context)
    for tip in frame.get_by_text("Entendido", exact=True).all():  # the editor's «Nuevo» tips, closed as a person does
        if tip.is_visible():
            tip.click()
    frame.locator("#editor_sdk").click(position={"x": 300, "y": 200})
    frame.locator("#area_id").focus()
    for key in ("Control+End", "Enter"):
        page.keyboard.press(key)
    page.keyboard.type(line, delay=30)
    page.keyboard.press("Control+s")
    editor(context, SAVED)
    for opened in context.pages:
        opened.goto("about:blank")


def kept():
    """The text of the DOCX Nextcloud keeps."""
    docx = base64.b64decode(machine(f"{NEXTCLOUD} base64 /mnt/ncdata/{USER}/files/{FILE}"))
    with zipfile.ZipFile(io.BytesIO(docx)) as archive:
        return "".join(ET.fromstring(archive.read("word/document.xml")).itertext())


line = f"APS-OFICINA-{secrets.token_hex(4)}"
with chromium() as browser:
    context = browser.new_context(locale="es-CL", viewport={"width": 1600, "height": 1000})
    # Right after «Listo» the suite is still settling (full-text search's first index, ClamAV's signatures), and a
    # staff member's first sign-in copies Nextcloud's sample files: each step may take longer than Playwright's 30 s.
    context.set_default_timeout(120_000)
    context.add_init_script(EDITOR_EVENTS)
    page = context.new_page()
    try:
        page.goto(f"{suite}/login")
        page.fill("#user", USER)
        page.fill("#password", password)
        page.click("[data-login-form-submit]")
        page.wait_for_url(lambda url: "/login" not in url)
        office(page)
        page.get_by_role("button", name="Vacío", exact=True).first.click()
        page.get_by_role("dialog").get_by_role("textbox").fill(FILE)
        with page.expect_response(lambda response: "/apps/files/api/v1/templates/create" in response.url) as created:
            page.get_by_role("button", name="Crear", exact=True).click()
        if not created.value.ok:
            sys.exit(f"the Office entry did not create {FILE}: HTTP {created.value.status}")
        editor(context)[0].screenshot(path=evidence / "creado.png")
        edit(context, line)
        until(lambda: line in kept(), 120, f"Nextcloud does not keep {line} in {FILE}")
        print(f"{FILE} keeps {line}")

        page = context.pages[0]
        office(page)
        page.get_by_text(FILE, exact=True).first.click()
        page, frame = editor(context)
        frame.locator("#editor_sdk").click(position={"x": 300, "y": 200})
        page.keyboard.press("Control+f")
        search = frame.locator("#search-bar-text")
        search.fill(line)
        search.press("Enter")
        until(lambda: frame.locator("#search-bar-results").inner_text().rsplit("/", 1)[-1].strip() not in ("", "0"),
              30, f"the reopened document does not show {line}")
        page.screenshot(path=evidence / "reabierto.png")
    except BaseException:
        for n, opened in enumerate(context.pages):
            with contextlib.suppress(Error):
                opened.screenshot(path=evidence / f"fallo-{n}.png")
        raise
print(f"{USER} created {FILE} from the Office entry, edited, saved and closed it in Euro-Office, and reopened it there "
      "showing the saved line")
