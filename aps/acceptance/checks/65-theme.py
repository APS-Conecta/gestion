#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""After «Listo» on a test build, every page staff see wears the APS Conecta theme and says «APS Conecta Gestión», in
Chromium and in Firefox. The login page loads the theme's stylesheet in the brand token file's colours, with the
theme's fonts, and names the establishment above its heading. A staff member who signs in sees no «Nextcloud» and no
link to nextcloud.com on the login page, the dashboard, Files, Talk or the personal settings, which link the suite's
source code and its licence; the custom menu is there, in the token file's dark violet. No page reports a content
security policy violation, and no request or script of our layer fails: the theme's, theming's and the custom menu's;
each page's console errors and failed requests are printed, Nextcloud's own among them, such as a new account's
missing status. Nextcloud's announcements, first-run wizard, usage survey and support app
are off, and stay off when Nextcloud's container restarts, whose start keeps the theme and rebuilds the browser's texts
of the apps the theme overrides: Talk's, left stale before the restart, are Talk's own Spanish with the theme's
overrides on top. Any other candidate's names and certificates are production ones, which a run never claims: there it
says so and passes."""

import json
import os
import re
import secrets
import ssl
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from browser import STAGING_ROOTS, chromium, firefox, machine, mastercontainer_file, suite_name  # noqa: E402

TOKENS = Path(__file__).resolve().parents[3] / "themes" / "apsconecta" / "core" / "css" / "tokens.css"
STATE = "/mnt/docker-aio-config/provisionador/state.json"
NEXTCLOUD = "sudo docker exec --interactive --user www-data nextcloud-aio-nextcloud"
OCC = f"{NEXTCLOUD} php /var/www/html/occ --no-ansi"
USER = "prueba.tema"
SOURCE = "https://github.com/APS-Conecta/gestion"
LICENCE = "https://www.gnu.org/licenses/agpl-3.0.html"
OFF = ("nextcloud_announcements", "firstrunwizard", "survey_client", "support")
WINDOW = {"locale": "es-CL", "viewport": {"width": 1280, "height": 900}}
PAGES = {"dashboard": ("/apps/dashboard/", "#app-dashboard"), "files": ("/apps/files/", "#app-navigation-vue"),
         "talk": ("/apps/spreed/", "#app-navigation-vue"), "settings": ("/settings/user", ".development-notice")}
OURS = ("/themes/", "/apps/theming/", "/apps/side_menu/")  # what our layer serves or sets: a failure there is ours
TALK = "/var/www/html/custom_apps/spreed/l10n/es"  # Talk's own Spanish, .json and .js
OVERRIDES = "/var/www/html/themes/apsconecta/custom_apps/spreed/l10n/es.json"  # the theme's overrides of Talk's texts
BROWSER = "/var/www/html/themes/apsconecta/core/spreed/l10n/es.js"  # Talk's browser texts, loaded in place of its own
# Each document's content security policy violations, as the page reports them.
VIOLATIONS = """window.violations = [];
document.addEventListener('securitypolicyviolation',
  event => window.violations.push(`${event.disposition} ${event.violatedDirective} ${event.blockedURI}`));"""
# What a page shows of the theme: its stylesheet, theming's colours, the fonts it loaded and the establishment's name.
THEMED = """async () => {
  await document.fonts.ready;
  const style = getComputedStyle(document.body), headline = document.querySelector('.login-form__headline');
  return {
    stylesheet: [...document.styleSheets].some(s => (s.href || '').includes('/themes/apsconecta/core/css/server.css')),
    primary: style.getPropertyValue('--color-primary').trim().toLowerCase(),
    backdrop: style.getPropertyValue('--color-background-plain').trim().toLowerCase(),
    fonts: [...new Set([...document.fonts].filter(f => f.status === 'loaded').map(f => f.family.replaceAll('"', '')))],
    establishment: headline ? getComputedStyle(headline, '::before').content : null,
  };
}"""
TEXT = "url => fetch(url, {cache: 'no-store'}).then(r => r.text())"  # in the page, with its session

if os.environ["TEST_BUILD"] != "true":
    print(f"the theme check runs on a v0.0.0-ci.N test build only: {os.environ['TAG']}'s names and certificates are "
          "production ones")
    sys.exit()

tokens = dict(re.findall(r"(--aps-[a-z0-9-]+)\s*:\s*([^;]+?)\s*;", TOKENS.read_text(encoding="utf-8")))
evidence = Path(os.environ["EVIDENCE"])
suite = f"https://{suite_name()}"
centre = json.loads(mastercontainer_file(STATE))["centre"]["name"]
password = secrets.token_urlsafe(18)  # the staff account's, on stdin only
print(f"::add-mask::{password}", flush=True)
machine(f"{NEXTCLOUD} sh -c 'read -r OC_PASS && export OC_PASS && php /var/www/html/occ user:add --password-from-env "
        f"--display-name \"Prueba Tema\" {USER}'", stdin=f"{password}\n")
errors, failures = [], []  # the console and uncaught errors, and the failed requests, of the page the check has open


def watched(context):
    """A page of the context whose console and uncaught errors go to `errors`, and its failed requests to `failures`."""
    page = context.new_page()
    page.on("console", lambda message: message.type == "error" and errors.append(message.text))
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.on("response", lambda answer: answer.status >= 400 and failures.append(f"{answer.status} {answer.url}"))
    page.on("requestfailed", lambda request: "ABORTED" not in (request.failure or "")  # not when the page moves on
            and failures.append(f"{request.failure} {request.url}"))
    return page


def shows(page, label):
    """The page shows no «Nextcloud», links no nextcloud.com, reports no policy violation, and no request or script of
    our layer fails on it; its screenshot goes to the evidence."""
    page.wait_for_timeout(3000)  # the app's own requests fill it in
    page.screenshot(path=evidence / f"{label}.png", full_page=True)
    text = page.title() + "\n" + page.inner_text("body")
    named = [line.strip() for line in text.splitlines() if "Nextcloud" in line]
    links = page.eval_on_selector_all("a[href*='nextcloud.com']",
                                      "links => links.filter(a => a.offsetParent).map(a => a.href)")
    violations, reported, failed = page.evaluate("window.violations"), errors[:], failures[:]
    errors.clear()
    failures.clear()
    ours = [line for line in failed if any(path in line for path in OURS)] + [line for line in reported
                                                                              if "/themes/" in line]
    print(f"{label}: title {page.title()!r}, lines naming Nextcloud {named}, links to nextcloud.com {links}, "
          f"policy violations {violations}, console errors {reported}, failed requests {failed}")
    return ([f"{label} shows «Nextcloud»: {named}"] if named else []) + (
        [f"{label} links nextcloud.com: {links}"] if links else []) + (
        [f"{label} reports content security policy violations: {violations}"] if violations else []) + (
        [f"{label}: our layer's requests or scripts fail: {ours}"] if ours else [])


def themed(page, label):
    """The page wears the theme in the brand token file's colours, with Nunito Sans; the login page also with Fraunces,
    above its heading the establishment's name."""
    found = page.evaluate(THEMED)
    print(f"{label}: {found}")
    wrong = [] if found["stylesheet"] else [f"{label} does not load the theme's stylesheet"]
    if (found["primary"], found["backdrop"]) != (tokens["--aps-violet"], tokens["--aps-violet-dark"]):
        wrong.append(f"{label}'s colours {found['primary']} and {found['backdrop']} are not the brand token file's")
    login = found["establishment"] is not None
    wrong += [f"{label} did not load {font}" for font in ("Nunito Sans", "Fraunces")[:2 if login else 1]
              if font not in found["fonts"]]
    if login and found["establishment"] != json.dumps(centre, ensure_ascii=False):
        wrong.append(f"{label} names {found['establishment']}, not the establishment {centre!r}")
    return wrong


def login_page(page, label):
    page.goto(f"{suite}/login")
    page.wait_for_selector("#user", timeout=60_000)
    return themed(page, label) + shows(page, label)


def log_in(page):
    page.fill("#user", USER)
    page.fill("#password", password)
    page.click("[data-login-form-submit]")
    page.wait_for_url(lambda url: "/login" not in url, timeout=120_000)


def tour(context, browser):
    """The login page, then each page staff open, signed in, in one browser."""
    context.add_init_script(VIOLATIONS)
    context.set_default_timeout(120_000)  # right after «Listo», a first sign-in can take long
    page = watched(context)
    problems = login_page(page, f"{browser}-login")
    log_in(page)
    for name, (path, ready) in PAGES.items():
        page.goto(f"{suite}{path}")
        page.wait_for_selector(ready, timeout=60_000)
        label = f"{browser}-{name}"
        problems += (themed(page, label) if name == "dashboard" else []) + shows(page, label)
        if name == "dashboard" and not page.locator("#header .cm-opener").is_visible():
            problems.append(f"{browser}: the dashboard's header has no custom menu")
    for what, href in (("source code", SOURCE), ("licence", LICENCE)):
        if not page.locator(f'.development-notice a[href="{href}"]').is_visible():
            problems.append(f"{browser}: the personal settings do not link the suite's {what}")
    menu = page.evaluate(TEXT, f"{suite}/apps/side_menu/css/stylesheet")
    if f"--side-menu-background-color: {tokens['--aps-violet-dark']}" not in menu:
        problems.append(f"{browser}: the custom menu's stylesheet does not paint it in the token file's dark violet")
    return problems


def quiet():
    """Nextcloud's own voice: its announcements, first-run wizard, usage survey and support app, each off."""
    held = json.loads(machine(f"{OCC} config:list --output=json"))["apps"]
    found = {app: held.get(app, {}).get("enabled") for app in OFF}
    print(f"Nextcloud's own apps: {found}")
    return [f"{app} is not off" for app, enabled in found.items() if enabled != "no"]


def answers():
    """Whether Nextcloud answers at the suite's name, installed and out of maintenance."""
    try:
        with urllib.request.urlopen(f"{suite}/status.php", timeout=30,
                                    context=ssl.create_default_context(cafile=STAGING_ROOTS)) as answer:
            status = json.load(answer)
    except (OSError, ValueError):
        return False
    return status.get("installed") and not status.get("maintenance")


def stale_talk_texts():
    """Where Talk's browser texts are not Talk's own Spanish, as Nextcloud holds it now, with the theme's overrides on
    top: the texts that differ, or a wrong app id or plural form."""
    own = json.loads(machine(f"{NEXTCLOUD} cat {TALK}.json"))
    overrides = json.loads(machine(f"{NEXTCLOUD} cat {OVERRIDES}"))["translations"]
    script = machine(f"{NEXTCLOUD} cat {BROWSER}").strip().removeprefix("OC.L10N.register(").removesuffix(");")
    app, texts, plural = json.loads(f"[{script}]")
    expected = {**own["translations"], **overrides}
    differ = sorted(key for key in expected.keys() | texts.keys() if texts.get(key) != expected.get(key))
    stale = [f"Talk's browser texts register the app {app!r}, not 'spreed'"] if app != "spreed" else []
    if plural != own["pluralForm"]:
        stale.append(f"Talk's browser texts have the plural form {plural!r}, not Talk's {own['pluralForm']!r}")
    if differ:
        stale.append(f"Talk's browser texts are not its own Spanish with the theme's overrides on top for: {differ}")
    print("Talk's browser texts after the restart:", "; ".join(stale) or "its own Spanish with the overrides on top")
    return stale


problems = quiet()
with chromium() as browser:
    problems += tour(browser.new_context(**WINDOW), "chromium")
with firefox(**WINDOW) as context:
    problems += tour(context, "firefox")
if problems:
    sys.exit("\n".join(problems))

machine(f"{NEXTCLOUD} cp {TALK}.js {BROWSER}")  # stale browser texts for Talk: its own, which name «Nextcloud»
machine("sudo docker restart nextcloud-aio-nextcloud")
deadline = time.monotonic() + 10 * 60
while not answers():
    if time.monotonic() > deadline:
        sys.exit("Nextcloud did not answer within 10 minutes of its container's restart")
    time.sleep(10)
with chromium() as browser:
    context = browser.new_context(**WINDOW)  # no cookie and no cached file
    context.add_init_script(VIOLATIONS)
    context.set_default_timeout(120_000)
    page = watched(context)
    problems = login_page(page, "restarted-login")
    log_in(page)
    page.goto(f"{suite}{PAGES['talk'][0]}")
    page.wait_for_selector(PAGES["talk"][1], timeout=60_000)
    problems += shows(page, "restarted-talk")
problems += stale_talk_texts() + quiet()
if problems:
    sys.exit("after a restart of Nextcloud's container:\n" + "\n".join(problems))
print("in Chromium and Firefox the theme is on every page staff open, with no «Nextcloud», the source code and licence "
      "linked and the custom menu in the brand's dark violet; Nextcloud's own voice is off, and stays off after a "
      "restart of its container, whose start keeps the theme and rebuilds Talk's browser texts")
