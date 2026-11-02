#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Native Office and Talk acceptance on a disposable, provisioned IP suite only.

No certificate bypass, SDK document mutations, or simulated media statistics.
Credentials and editor configurations are never written to evidence artifacts.
"""
import argparse
import base64
import csv
import io
import json
import math
import os
from pathlib import Path
import ssl
import struct
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import uuid
import wave
import xml.etree.ElementTree as ET
import zipfile

from playwright.sync_api import sync_playwright

OBSERVE = r"""(() => {
  window.acceptancePeers = [];
  window.RTCPeerConnection = new Proxy(window.RTCPeerConnection, {
    construct(target, args, newTarget) {
      const peer = Reflect.construct(target, args, newTarget);
      window.acceptancePeers.push(peer); return peer;
    }
  });
  window.acceptanceOfficeReady = false;
  window.addEventListener('message', event => {
    const frame = [...document.querySelectorAll('iframe[name="frameEditor"]')]
      .find(frame => frame.contentWindow === event.source);
    if (!frame || event.origin !== new URL(frame.src, location.href).origin) return;
    try {
      const data = typeof event.data === 'string' ? JSON.parse(event.data) : event.data;
      if (data.event === 'onDocumentReady') window.acceptanceOfficeReady = true;
    } catch (error) { /* unrelated native messages */ }
  });
})();"""
STATS = r"""async () => {
  const streams = {}, pairs = [];
  for (const [index, pc] of window.acceptancePeers.entries()) {
    if (pc.connectionState === 'closed') continue;
    const report = await pc.getStats();
    for (const s of report.values()) {
      if (['inbound-rtp', 'outbound-rtp'].includes(s.type) && (s.kind || s.mediaType) === 'audio') {
        streams[index + ':' + s.id] = {type: s.type, bytes: s.bytesReceived ?? s.bytesSent,
          packets: s.packetsReceived ?? s.packetsSent, energy: s.totalAudioEnergy,
          duration: s.totalSamplesDuration};
      }
      if (s.type === 'transport' && s.selectedCandidatePairId) {
        const pair = report.get(s.selectedCandidatePairId);
        const local = report.get(pair.localCandidateId), remote = report.get(pair.remoteCandidateId);
        pairs.push({state: pair.state, local: local?.candidateType, remote: remote?.candidateType,
          protocol: local?.protocol});
      }
    }
  }
  return {streams, pairs};
}"""


def audio_progress(before, after):
    good = set()
    for key, current in after['streams'].items():
        old = before['streams'].get(key)
        if not old or current['bytes'] <= old['bytes'] or current['packets'] <= old['packets']:
            continue
        if current['type'] == 'inbound-rtp' and not (
                current.get('energy', 0) > old.get('energy', 0)
                and current.get('duration', 0) > old.get('duration', 0)):
            continue
        good.add(current['type'])
    return good == {'inbound-rtp', 'outbound-rtp'} and any(p['state'] == 'succeeded' for p in after['pairs'])


def wait_for(page, predicate, seconds=60):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        page.wait_for_timeout(500)
    raise AssertionError('Acceptance deadline exceeded')


def editor(context, page):
    def find():
        for candidate in context.pages:
            for frame in candidate.frames:
                if '/web-apps/apps/documenteditor/' not in frame.url:
                    continue
                parent = frame.parent_frame
                if parent and parent.evaluate('window.acceptanceOfficeReady === true'):
                    if frame.locator('#editor_sdk').is_visible():
                        return candidate, frame
        return None
    return wait_for(page, find, 90)


def edit_document(context, page, marker):
    editor_page, frame = editor(context, page)
    frame.locator('#editor_sdk').click(position={'x': 300, 'y': 200})
    frame.locator('#area_id').focus()
    editor_page.keyboard.press('Control+End')
    editor_page.keyboard.press('Enter')
    editor_page.keyboard.type(marker, delay=30)
    editor_page.keyboard.press('Control+s')
    # Give native synchronization time to clear its modified title; DAV is the storage oracle.
    editor_page.wait_for_timeout(3000)
    wait_for(editor_page, lambda: all(' *' not in f.title() for f in context.pages), 30)
    for opened in list(context.pages):
        opened.goto('about:blank')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True)
    parser.add_argument('--ca', required=True)
    parser.add_argument('--credentials', default='/opt/aps-conecta/credentials.txt')
    parser.add_argument('--output', required=True)
    parser.add_argument('--untrusted-check', action='store_true')
    args = parser.parse_args()
    if os.environ.get('APS_DISPOSABLE_ACCEPTANCE') != '1':
        parser.error('Set APS_DISPOSABLE_ACCEPTANCE=1 only on a disposable suite')
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    stage = 'launching a browser with normal certificate verification'
    with sync_playwright() as pw, tempfile.TemporaryDirectory() as temporary:
        wav = Path(temporary) / 'audio.wav'
        with wave.open(str(wav), 'wb') as stream:
            stream.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
            stream.writeframes(b''.join(struct.pack('<h', int(12000 * math.sin(2 * math.pi * 440 * n / 48000)))
                                       for n in range(48000 * 5)))
        browser = pw.chromium.launch(args=['--use-fake-device-for-media-stream',
            '--use-file-for-fake-audio-capture=' + str(wav), '--autoplay-policy=no-user-gesture-required'])
        if args.untrusted_check:
            try:
                browser.new_page().goto(args.url, timeout=30000)
            except Exception as error:
                if 'ERR_CERT_AUTHORITY_INVALID' not in str(error):
                    raise AssertionError('Untrusted browser failed for a different reason') from None
                print('PASS: browser without the installation CA rejects suite HTTPS')
                browser.close()
                return
            raise AssertionError('Browser unexpectedly trusted the private CA before import')
        users = ('beto.prueba', 'carla.chat')
        with open(args.credentials, newline='', encoding='utf-8') as stream:
            rows = list(csv.reader(stream, delimiter=';'))
        credentials = {user: next(row[2] for row in rows if row[0] == user) for user in users}
        tls = ssl.create_default_context(cafile=args.ca)
        token = None
        filename = 'acceptance-' + uuid.uuid4().hex + '.docx'
        dav = '/remote.php/dav/files/' + users[0] + '/' + filename
        created = False
        permissions = {}
        pages = []

        def request(user, method, path, data=None):
            headers = {'Authorization': 'Basic ' + base64.b64encode(
                (user + ':' + credentials[user]).encode()).decode(), 'OCS-APIRequest': 'true',
                'Accept': 'application/json'}
            body = urllib.parse.urlencode(data).encode() if data is not None else None
            with urllib.request.urlopen(urllib.request.Request(args.url + path, data=body,
                    headers=headers, method=method), context=tls, timeout=30) as response:
                return response.read()

        def ocs(user, method, path, data=None):
            return json.loads(request(user, method, '/ocs/v2.php' + path, data))['ocs']['data']

        def stored(markers):
            with zipfile.ZipFile(io.BytesIO(request(users[0], 'GET', dav))) as archive:
                document = ET.fromstring(archive.read('word/document.xml'))
            text = ''.join(document.itertext())
            return all(marker in text for marker in markers)

        try:
            contexts = []
            for user in users:
                stage = 'trusted browser login for a staff account'
                context = browser.new_context(locale='en-US', viewport={'width': 1440, 'height': 1000},
                                              permissions=['microphone', 'camera'])
                def record_permissions(response, user=user):
                    if '/apps/eurooffice/api/v1/config/' in response.url and response.ok:
                        config = response.json()
                        permissions[user] = (config.get('document', {}).get('permissions', {}).get('edit'),
                                             config.get('editorConfig', {}).get('mode'))
                context.on('response', record_permissions)
                context.add_init_script(OBSERVE)
                page = context.new_page()
                page.goto(args.url + '/login')
                page.locator('#user').fill(user)
                page.locator('#password').fill(credentials[user])
                page.locator('#submit-form').click()
                page.wait_for_url(lambda url: '/login' not in url, timeout=60000)
                contexts.append(context)
                pages.append(page)
            print('PASS: both staff browsers use trusted suite HTTPS', flush=True)
            page = pages[0]
            stage = 'opening the visible Office icon'
            office_link = page.locator('a[href*="/apps/office"]:visible').first
            if not office_link.is_visible():
                page.locator('button.cm-opener:not(.cm-closer):visible').first.click()
                office_link = page.locator('#side-menu a[href*="/apps/office"]:visible').first
            office_link.wait_for()
            icon = office_link.locator('img').first
            assert icon.is_visible() and icon.evaluate('(image) => image.complete && image.naturalWidth > 0')
            page.screenshot(path=str(output / 'office-navigation.png'))
            office_link.click()
            stage = 'creating a document through the native Office hub'
            page.get_by_text('Documents', exact=True).first.click()
            page.locator('.template-card').filter(has_text='Blank').first.click()
            page.locator('.office-overview__create-form input').fill(filename)
            with page.expect_response(lambda response: '/api/v1/templates/create' in response.url) as creation:
                page.get_by_role('button', name='Create', exact=True).click()
            assert creation.value.ok
            created = True
            first, second = 'APS-FIRST-' + uuid.uuid4().hex, 'APS-SECOND-' + uuid.uuid4().hex
            stage = 'editing and saving a new document in Euro-Office'
            edit_document(contexts[0], page, first)
            wait_for(page, lambda: stored([first]), 90)
            stage = 'reopening the saved document from Office'
            page.goto(args.url + '/apps/office/')
            page.get_by_text(filename, exact=True).first.click()
            edit_document(contexts[0], page, second)
            wait_for(page, lambda: stored([first, second]), 90)
            print('PASS: Office icon → create → Euro-Office edit → saved DOCX → reopen → further saved edit', flush=True)
            assert permissions[users[0]] == (True, 'edit')
            stage = 'opening a read-only shared document from Office'
            ocs(users[0], 'POST', '/apps/files_sharing/api/v1/shares',
                {'path': '/' + filename, 'shareType': 0, 'shareWith': users[1], 'permissions': 1})
            shared = pages[1]
            shared.goto(args.url + '/apps/office/')
            shared.get_by_role('button', name='Shared with me', exact=True).click()
            shared.get_by_text(filename, exact=True).first.click()
            viewer_page, viewer = editor(contexts[1], shared)
            assert permissions[users[1]] == (False, 'view')
            denied = 'APS-DENIED-' + uuid.uuid4().hex
            viewer.locator('#editor_sdk').click(position={'x': 300, 'y': 200})
            viewer_page.keyboard.type(denied)
            viewer_page.wait_for_timeout(1000)
            for opened in list(contexts[1].pages):
                opened.goto('about:blank')
            assert stored([first, second]) and not stored([denied])
            print('PASS: shared Office document opens in view mode and preserves read-only permission', flush=True)


            stage = 'creating a staff Talk conversation'
            room = ocs(users[0], 'POST', '/apps/spreed/api/v4/room',
                       {'roomType': 2, 'roomName': 'Acceptance ' + uuid.uuid4().hex})
            token = room['token']
            ocs(users[0], 'POST', '/apps/spreed/api/v4/room/' + token + '/participants',
                {'newParticipant': users[1], 'source': 'users'})
            for page in pages:
                stage = 'joining Talk through its native microphone preview'
                page.goto(args.url + '/apps/spreed/call/' + token)
                page.locator('.join-call:visible').first.click()
                wait_for(page, lambda: page.locator('.media-settings:visible, .leave-call:visible').count())
                preview = page.locator('.media-settings:visible')
                scope = preview if preview.count() else page
                unmute = scope.get_by_role('button', name='Unmute audio', exact=True)
                if unmute.is_visible():
                    unmute.click()
                scope.get_by_role('button', name='Mute audio', exact=True).wait_for()
                video = scope.get_by_role('button', name='Disable video', exact=True)
                if video.is_visible():
                    video.click()
                if preview.count():
                    preview.locator('.join-call:visible').click()
                page.locator('.leave-call:visible').first.wait_for()
            stage = 'proving bidirectional decoded audio on both browsers'
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                before = [page.evaluate(STATS) for page in pages]
                pages[0].wait_for_timeout(3000)
                after = [page.evaluate(STATS) for page in pages]
                if all(audio_progress(a, b) for a, b in zip(before, after)):
                    break
            else:
                raise AssertionError('No bidirectional decoded audio')
            (output / 'talk-audio.json').write_text(json.dumps({'before': before, 'after': after}, indent=2))
            for number, page in enumerate(pages):
                page.screenshot(path=str(output / f'talk-{number + 1}.png'))
            print('PASS: both browsers send/receive increasing audio RTP and decode non-silent audio', flush=True)
            print('LIMIT: same-host browser media; physical devices and external WAN are not certified', flush=True)
        except Exception as error:
            for number, page in enumerate(pages):
                if not page.is_closed():
                    page.screenshot(path=str(output / f'failure-{number + 1}.png'))
            print('FAIL: ' + stage + ' (' + type(error).__name__ + ')', file=sys.stderr)
            raise SystemExit(1) from None
        finally:
            browser.close()
            if token:
                ocs(users[0], 'DELETE', '/apps/spreed/api/v4/room/' + token)
            if created:
                request(users[0], 'DELETE', dav)


if __name__ == '__main__':
    main()
