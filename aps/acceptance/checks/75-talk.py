#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""A Talk call on a test build, as staff on the clinic network hold one: two staff members, each in a browser on the
runner, which shares the machine's network as a laptop shares the clinic's, join one call from Talk's page with a fake
camera and a microphone that plays a tone, and each browser decodes the other's audio through the TURN server at the
suite's name on Talk's port: 443, where ADR 0028 puts Talk behind our Caddy, or, on the Coolify way in, 3478, which Talk
publishes itself (ADR 0029). On this network a direct path through Docker's NAT also reaches
Talk, so the browsers take relay candidates only: audio they decode went through TURN. The browsers trust Let's
Encrypt's staging roots alone, as staff's browsers trust its production ones: no certificate of the suite's own is
installed. Any other candidate's names and certificates are production ones, which a run never claims: there it says
so and passes."""

import base64
import json
import os
import re
import secrets
import ssl
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from browser import STAGING_ROOTS, chromium, machine, suite_name  # noqa: E402
from playwright.sync_api import Error, expect  # noqa: E402

STAFF = ("llamada.uno", "llamada.dos")
TURN_PORT = 3478 if os.environ["WAY"] == "coolify" else 443  # Talk's port, where ADR 0029 or ADR 0028 puts it
NEXTCLOUD = "sudo docker exec --interactive --user www-data nextcloud-aio-nextcloud"
# Before Talk loads: every peer connection Talk opens, on relay candidates only.
OBSERVE = """window.talkPeers = [];
window.RTCPeerConnection = new Proxy(window.RTCPeerConnection, {
  construct(target, [configuration, ...rest], newTarget) {
    const peer = Reflect.construct(target, [{...configuration, iceTransportPolicy: 'relay'}, ...rest], newTarget);
    window.talkPeers.push(peer);
    return peer;
  }
});"""
# Each open peer connection's audio RTP, sent and received (with the energy and duration of the audio decoded), the
# video frames decoded, and the candidate pair in use, with the type of its local candidate and that one's TURN server.
STATS = """async () => {
  const audio = {}, video = {}, pairs = [];
  for (const [n, peer] of window.talkPeers.entries()) {
    if (peer.connectionState === 'closed') continue;
    const report = await peer.getStats();
    for (const s of report.values()) {
      if (s.type === 'inbound-rtp' && s.kind === 'video') video[n + ':' + s.id] = s.framesDecoded;
      if (['inbound-rtp', 'outbound-rtp'].includes(s.type) && s.kind === 'audio') {
        audio[n + ':' + s.id] = {type: s.type, bytes: s.bytesReceived ?? s.bytesSent,
          packets: s.packetsReceived ?? s.packetsSent, energy: s.totalAudioEnergy, duration: s.totalSamplesDuration};
      }
      const pair = s.type === 'transport' && report.get(s.selectedCandidatePairId);
      if (pair) {
        const local = report.get(pair.localCandidateId);
        pairs.push({state: pair.state, local: local?.candidateType, url: local?.url ?? null,
          remote: report.get(pair.remoteCandidateId)?.candidateType});
      }
    }
  }
  return {audio, video, pairs};
}"""


def decoded(before, after):
    """Whether, between two readings, the browser sent audio and received audio that it decoded, not silence, over a
    candidate pair in use."""
    flowing = set()
    for key, now in after["audio"].items():
        then = before["audio"].get(key)
        if not then or (now["bytes"] or 0) <= (then["bytes"] or 0) or (now["packets"] or 0) <= (then["packets"] or 0):
            continue
        heard = (now["energy"] or 0) > (then["energy"] or 0) and (now["duration"] or 0) > (then["duration"] or 0)
        if now["type"] == "inbound-rtp" and not heard:
            continue
        flowing.add(now["type"])
    return flowing == {"inbound-rtp", "outbound-rtp"} and any(p["state"] == "succeeded" for p in after["pairs"])


def relayed(reading, turn):
    """Whether each candidate pair the browser uses relays through the TURN server `turn` matches, whose URL a browser
    gives a relayed local candidate alone."""
    used = [pair for pair in reading["pairs"] if pair["state"] == "succeeded"]
    return bool(used) and all(turn.match(pair["url"] or "") for pair in used)


def conversation(user, password, invited):
    """The one-to-one conversation `user` opens with `invited` through Talk's API, as their own client does, over TLS
    that trusts the staging roots alone: its token."""
    login = base64.b64encode(f"{user}:{password}".encode()).decode()
    request = urllib.request.Request(f"{suite}/ocs/v2.php/apps/spreed/api/v4/room",
                                     json.dumps({"roomType": 1, "invite": invited}).encode(),
                                     {"Authorization": f"Basic {login}", "OCS-APIRequest": "true",
                                      "Accept": "application/json", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=120,
                                    context=ssl.create_default_context(cafile=STAGING_ROOTS)) as answer:
            return json.load(answer)["ocs"]["data"]["token"]
    except urllib.error.HTTPError as error:
        sys.exit(f"{user} does not open a conversation with {invited}: HTTP {error.code}")


def log_in(page, user, password):
    """Sign `user` in on the suite's login page, as staff do."""
    page.goto(f"{suite}/login")
    page.fill("#user", user)
    page.fill("#password", password)
    page.click("[data-login-form-submit]")
    page.wait_for_url(lambda url: "/login" not in url, timeout=60_000)


def join(page):
    """Join the call from the conversation's own button, through Talk's device check, with camera and microphone on.
    Talk tells a headless browser it is not fully supported, in a notice over the page: it is closed first, as a person
    would close it."""
    call = page.locator(".join-call:visible").first  # «Comenzar llamada» or «Unirse a la llamada»
    expect(call).to_be_visible(timeout=60_000)
    for notice in page.locator(".toastify .toast-close").all():
        notice.click()
    call.click()
    devices, joined = page.locator(".media-settings"), page.locator(".leave-call:visible").first
    expect(devices.or_(joined).first).to_be_visible(timeout=60_000)
    if devices.is_visible():
        for off, on in (("Activar audio", "Silenciar audio"), ("Activar vídeo", "Desactivar video")):
            toggle = devices.get_by_role("button", name=re.compile(f"^({off}|{on})$"))
            expect(toggle).to_be_visible(timeout=30_000)
            if toggle.get_attribute("aria-label") == off:
                toggle.click()
            expect(devices.get_by_role("button", name=on, exact=True)).to_be_visible()
        devices.locator(".join-call").click()
    expect(joined).to_be_visible(timeout=60_000)


if os.environ["TEST_BUILD"] != "true":
    print(f"the Talk call runs on a v0.0.0-ci.N test build only: {os.environ['TAG']}'s names and certificates are "
          "production ones")
    sys.exit()

name = suite_name()
suite = f"https://{name}"
evidence = Path(os.environ["EVIDENCE"])
password = secrets.token_urlsafe(18)
print(f"::add-mask::{password}", flush=True)
for user in STAFF:  # the password goes on stdin: the host's ps shows the arguments of every process in a container
    machine(f"{NEXTCLOUD} sh -c 'read -r OC_PASS && export OC_PASS && php /var/www/html/occ user:add "
            f"--password-from-env {user}'", stdin=f"{password}\n")
    machine(f"{NEXTCLOUD} php /var/www/html/occ user:setting {user} firstrunwizard show 999.0.0")  # no wizard over Talk
token = conversation(STAFF[0], password, STAFF[1])

with chromium(media=True) as browser:
    pages = []
    for user in STAFF:  # each signs in, then each opens the conversation and joins its call
        context = browser.new_context(viewport={"width": 1280, "height": 900})
        context.add_init_script(OBSERVE)
        page = context.new_page()
        log_in(page, user, password)
        pages.append(page)
    for user, page in zip(STAFF, pages):  # the invited one joins once the first one's call rings
        page.goto(f"{suite}/call/{token}")
        try:
            join(page)
        except (AssertionError, Error):
            page.screenshot(path=evidence / f"{user}-sin-unirse.png")
            sys.exit(f"{user} did not join the call from Talk's page")

    deadline = time.monotonic() + 120
    while True:
        before = [page.evaluate(STATS) for page in pages]
        pages[0].wait_for_timeout(3000)
        after = [page.evaluate(STATS) for page in pages]
        (evidence / "talk-media.json").write_text(json.dumps({"before": before, "after": after}, indent=1))
        flowing = all(decoded(*readings) for readings in zip(before, after))
        if flowing or time.monotonic() > deadline:
            break
    for user, page, reading in zip(STAFF, pages, after):
        page.screenshot(path=evidence / f"{user}.png")
        print(f"{user}: candidate pairs {reading['pairs']}, video frames decoded {list(reading['video'].values())}")

if not flowing:
    sys.exit("within two minutes the two browsers, on relay candidates only, did not each send audio and decode the "
             "other's")
turn = re.compile(rf"turns?:{re.escape(name)}:{TURN_PORT}(\?|$)")
if not all(relayed(reading, turn) for reading in after):
    sys.exit(f"the call's media does not run through the TURN server at {name}:{TURN_PORT}")
print(f"both browsers send audio and decode the other's, not silence, through the TURN server at {name}:{TURN_PORT}, "
      "with no certificate of the suite's own installed")
