// L4-03 pin: the destructive-drag validators (js/desktop-drag-rules.js).
// These functions are the ONLY guards before WebDAV MOVE/COPY fire — they had zero
// tests. Pure functions, exercised directly through the module's Node export.
//
//   node drag-rules.test.cjs <patched-tree>/js/desktop-drag-rules.js
const assert = require('node:assert/strict');
const path = require('path');

const R = require(path.resolve(process.argv[2]));

let n = 0;
const ok = (c, m) => { assert.ok(c, m); n++; };

// ---- validPath ----
ok(R.validPath('/') === true, 'root allowed by default');
ok(R.validPath('') === true, 'empty means root');
ok(R.validPath('/a/b') === true, 'nested path');
ok(R.validPath('/a//b') === false, 'empty segment refused');
ok(R.validPath('/', false) === false, 'root refused when allowRoot=false');
ok(R.validPath('/a/../b') === false, 'traversal refused');
ok(R.validPath('/a/b\x00') === false, 'control chars refused');
ok(R.validPath(42) === false, 'non-string refused');
ok(R.validPath('/.') === false, 'dot segment refused');

// ---- validBasename / cleanPath / parentPath / itemName ----
ok(R.validBasename('Informe.docx') === true, 'plain name');
ok(R.validBasename('') === false && R.validBasename('.') === false && R.validBasename('..') === false, 'special names refused');
ok(R.validBasename('a/b') === false && R.validBasename('a\\b') === false, 'separators refused');
ok(R.cleanPath('//a/b//') === 'a/b', 'cleanPath strips slashes');
ok(R.parentPath('/a/b/c.txt') === 'a/b', 'parentPath');
ok(R.parseFilesystemPayload(JSON.stringify(R.createFilesystemPayload([{ path: '/a/b/c.txt', isFolder: false }]))).items[0].name === 'c.txt', 'itemName derived from path');
ok(R.parseFilesystemPayload(JSON.stringify(R.createFilesystemPayload([{ path: '/y', name: 'y', isFolder: false }]))).items[0].name === 'y', 'name must match the path leaf (mismatch is refused above)');

// ---- payload round-trip + rejection ----
const items = [
    { path: '/docs/a.txt', isFolder: false },
    { path: '/docs/sub', isFolder: true },
];
const payload = R.createFilesystemPayload(items, 'win-1');
ok(payload.version === 1 && payload.sourceWindowId === 'win-1', 'payload shape');
ok(payload.items[0].path === '/docs/a.txt' && payload.items[0].name === 'a.txt', 'items normalized');
const parsed = R.parseFilesystemPayload(JSON.stringify(payload));
ok(parsed !== null && parsed.items.length === 2, 'round-trip parses');
ok(R.parseFilesystemPayload(JSON.stringify({ version: 2, items })) === null, 'wrong version refused');
ok(R.parseFilesystemPayload(JSON.stringify({ version: 1, items: [{ path: '/a/../b', name: 'b', isFolder: false }] })) === null, 'traversal item refused');
ok(R.parseFilesystemPayload(JSON.stringify({ version: 1, items: [{ path: '/a', name: 'WRONG', isFolder: false }] })) === null, 'name/path mismatch refused');

// ---- filesystemOperation (the pre-MOVE/COPY gate) ----
const op = R.filesystemOperation([{ path: '/docs/a.txt', name: 'a.txt', isFolder: false }], '/target');
ok(op && op.method === 'MOVE' && op.targetPath === 'target', 'move operation built');
ok(R.filesystemOperation([{ path: '/docs/a.txt', name: 'a.txt' }], '/target', true).method === 'COPY', 'copy flag');
ok(R.filesystemOperation([{ path: '/docs/a.txt', name: 'a.txt', canMove: false }], '/target') === null, 'canMove=false blocks');
ok(R.filesystemOperation([{ path: '/docs/a.txt', name: 'a.txt', canCopy: false }], '/target', true) === null, 'canCopy=false blocks copy');
ok(R.filesystemOperation([{ path: '/target/a.txt', name: 'a.txt' }], '/target') === null, 'same-folder move refused');
ok(R.filesystemOperation([{ path: '/target', name: 'target', isFolder: true }, { path: '/target/sub/x', name: 'x' }], '/target/sub') === null, 'nested source refused (folder contains sibling)');
ok(R.filesystemOperation([{ path: '/a', name: 'a', isFolder: true }], '/a/b') === null, 'into own descendant refused');
ok(R.filesystemOperation([{ path: '/x/a.txt', name: 'a.txt' }, { path: '/x/a.txt', name: 'a.txt' }], '/t') === null, 'duplicate paths refused');
ok(R.filesystemOperation([{ path: '/a/../../etc', name: 'etc' }], '/t') === null, 'invalid source path refused');

// ---- isDesktopFilesystemSource / dropOperation ----
ok(R.isDesktopFilesystemSource({ kind: 'file', path: '/desktop/a.txt' }, '/desktop') === true, 'direct child qualifies');
ok(R.isDesktopFilesystemSource({ kind: 'file', path: '/other/a.txt' }, '/desktop') === false, 'foreign folder refused');
ok(R.isDesktopFilesystemSource({ kind: 'fav', path: '/desktop/a.txt' }, '/desktop') === false, 'favorites never initiate filesystem ops');
const drop = R.dropOperation([{ kind: 'file', path: '/desktop/a.txt', name: 'a.txt' }], { isFolder: true, path: '/desktop/sub' }, '/desktop');
ok(drop && drop.method === 'MOVE' && drop.targetPath === 'desktop/sub', 'drop onto subfolder');
ok(R.dropOperation([{ kind: 'file', path: '/desktop/a.txt' }], { isFolder: true, special: 'trash' }, '/desktop') === null, 'trash is not a filesystem drop target');
ok(R.dropOperation([{ kind: 'file', path: '/desktop/sub/a.txt' }], { isFolder: true, path: '/desktop/sub' }, '/desktop') === null, 'drop into own parent refused');

// ---- transferWithConflicts (non-dialog paths; the 412→dialog loop needs a browser) ----
(async () => {
    const r1 = await R.transferWithConflicts({ path: '/desktop/a.txt', name: 'a.txt' }, '/target', async () => null);
    ok(r1.destination === '/target/a.txt', 'success returns destination');
    await assert.rejects(
        () => R.transferWithConflicts({ path: '/desktop/../a.txt', name: 'a.txt' }, '/target', async () => null),
        (e) => e.code === 'Invalid transfer path', 'invalid source path throws');
    await assert.rejects(
        () => R.transferWithConflicts({ path: '/a', name: 'a', isFolder: true }, '/a/b', async () => null),
        (e) => e.code === 'Invalid transfer destination', 'ancestor destination throws');
    await assert.rejects(
        () => R.transferWithConflicts({ path: '/desktop/a.txt', name: 'a.txt' }, '/target', async () => ({ ok: false, status: 403 })),
        (e) => e.status === 403, '4xx propagates');
    n++;
    await assert.rejects(
        () => R.transferWithConflicts({ path: '/desktop/a.txt', name: 'a.txt' }, '/target', async () => { throw Object.assign(new Error('HTTP 500'), { status: 500 }); }),
        (e) => e.status === 500, 'non-412 error propagates untouched');
    n++;
    console.log(`PASS: drag-rules pins (${n} assertions)`);
    process.exit(0);
})().catch((e) => { console.error('FAIL:', e.message); process.exit(1); });
