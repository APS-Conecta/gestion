// L4-03 pin: saveState → restoreWindows round-trip through the REAL split shell.
// Boots js/desktop-shell.js (+ the five modules) under Node against permissive DOM
// stubs, opens two windows with known geometry, captures what saveState POSTs,
// then re-boots with that payload as the served windowStates and asserts the
// restored windows carry the same geometry and app identity.
//
//   node shell-roundtrip.test.cjs <patched-tree>/js
const assert = require('node:assert/strict');
const path = require('path');
const { bootSplit } = require('./dom-stubs.cjs');

const jsDir = path.resolve(process.argv[2]);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
    // ---- phase 1: boot, open two windows, save ----
    const s1 = bootSplit(jsDir, {
        rootDataset: { windowSaveUrl: 'https://x.test/capture/windowstates' },
        OC: { requestToken: 'tok' },
    });
    assert.equal(typeof s1.DW.boot, 'function', 'hub exports boot()');
    assert.equal(typeof s1.DW.saveState, 'function', 'hub namespace carries windows.js members');
    assert.equal(typeof s1.DW.getApps, 'function', 'hub namespace carries hub members');
    assert.ok(s1.DW.windows, 'windows Map published');

    s1.DW.openWindow({ id: 'files', name: 'Files', href: 'https://x.test/index.php/apps/files?dir=/docs', icon: '', multiInstance: true });
    s1.DW.openWindow({ id: 'dashboard', name: 'Dashboard', href: 'https://x.test/index.php/apps/dashboard', icon: '' });
    assert.equal(s1.DW.windows.size, 2, 'two windows opened');

    // distinct geometry so a restore mix-up cannot pass
    const filesWin = s1.DW.windows.get('files').window;
    const dashWin = s1.DW.windows.get('dashboard').window;
    Object.assign(filesWin.style, { left: '111px', top: '61px', width: '640px', height: '480px', zIndex: '41' });
    Object.assign(dashWin.style, { left: '222px', top: '122px', width: '800px', height: '600px', zIndex: '42' });
    filesWin.classList.add('is-maximized');

    s1.DW.saveState();
    await sleep(650); // saveState debounces 500ms before POSTing

    const post = s1.g.captured.posts.find(([url]) => String(url).includes('/capture/windowstates'));
    assert.ok(post, 'saveState POSTed to the capture URL');
    const body = post[1] && post[1].body;
    assert.ok(body, 'POST carries a body');
    const saved = JSON.parse(body.get('windows'));
    assert.equal(saved.windows.length, 2, 'both windows serialized');
    const savedFiles = saved.windows.find((w) => w.appId === 'files');
    const savedDash = saved.windows.find((w) => w.appId === 'dashboard');
    assert.ok(savedFiles && savedDash, 'app ids preserved');
    assert.equal(savedFiles.left, '111px', 'files geometry serialized');
    assert.equal(savedFiles.maximized, true, 'maximized flag serialized');
    assert.equal(savedFiles.checkPath, '/docs', 'files window stores its dir as checkPath');
    assert.equal(savedDash.zIndex, '42', 'dashboard z serialized');

    // ---- phase 2: fresh boot with the payload as served state ----
    const s2 = bootSplit(jsDir, {
        rootDataset: { windowStates: JSON.stringify(saved), windowSaveUrl: '' },
    });
    // boot() ran restoreWindows during require (favorites.js tail) — it awaits targetExists
    await sleep(20);
    assert.equal(s2.DW.windows.size, 2, 'both windows restored on boot');
    const rFiles = s2.DW.windows.get('files');
    const rDash = s2.DW.windows.get('dashboard');
    assert.ok(rFiles && rDash, 'same window ids restored');
    assert.equal(rFiles.window.style.left, '111px', 'files left restored');
    assert.equal(rFiles.window.style.top, '61px', 'files top restored');
    assert.equal(rFiles.window.style.width, '640px', 'files size restored');
    assert.equal(rFiles.window.classList.contains('is-maximized'), true, 'maximized restored');
    assert.equal(rFiles.app.href, 'https://x.test/index.php/apps/files?dir=/docs', 'files restores at its last URL');
    assert.equal(rDash.window.style.left, '222px', 'dashboard left restored');
    // z is re-derived on restore (focusWindow bumps it: last-restored wins) — assert ORDER, not the saved value
    assert.ok(Number(rDash.window.style.zIndex) > Number(rFiles.window.style.zIndex), 'restore order keeps dashboard above files');

    // ---- phase 3: a window whose target folder is gone (404 on PROPFIND) is dropped ----
    const savedWithGone = JSON.parse(JSON.stringify(saved));
    savedWithGone.windows.push({
        appId: 'files', sourceAppId: 'files', name: 'Files', icon: '', fileApp: true, multiInstance: true,
        href: 'https://x.test/index.php/apps/files?dir=/gone', checkPath: '/gone',
        left: '10px', top: '10px', width: '100px', height: '100px', zIndex: '43', hidden: false, minimized: false,
        restoreLeft: '', restoreTop: '', restoreWidth: '', restoreHeight: '', maximized: false,
    });
    const s3 = bootSplit(jsDir, {
        rootDataset: { windowStates: JSON.stringify(savedWithGone), windowSaveUrl: '' },
        OC: { requestToken: 'tok', getCurrentUser: () => ({ uid: 'seat' }) },
    });
    // targetExists 404s under our fetch stub? the stub answers ok:true — so patch it for this phase:
    // (the stub's fetch resolves ok — re-run restoreWindows with a 404-ing fetch)
    globalThis.fetch = () => Promise.resolve({ ok: false, status: 404 });
    s3.DW.windows.clear();
    await s3.DW.restoreWindows(s3.DW.getApps());
    assert.equal(s3.DW.windows.size, 2, 'window targeting a missing folder is not restored (checkPath 404)');

    console.log('PASS: saveState→restoreWindows round-trip (' + path.basename(jsDir) + ')');
    process.exit(0);
}

main().catch((e) => { console.error('FAIL:', e.message); process.exit(1); });
