// Permissive DOM stubs for booting the split desktop-shell under Node (L4-03 pin seat).
// Philosophy: the shell's own guards handle absent nodes; where they don't, a permissive
// fake (never-null querySelector/getElementById) keeps the boot path running so the
// saveState→restoreWindows round-trip exercises the REAL functions, not a mock of them.
function fakeElement(tag = 'div') {
    const el = {
        tagName: String(tag).toUpperCase(),
        nodeType: 1,
        children: [],
        dataset: {},
        style: { setProperty() {}, removeProperty() {}, },
        hidden: false,
        title: '',
        type: 'button',
        draggable: false,
        tabIndex: 0,
        textContent: '',
        innerHTML: '',
        value: '',
        offsetWidth: 0,
        offsetHeight: 0,
        offsetLeft: 0,
        offsetTop: 0,
        clientWidth: 0,
        clientHeight: 0,
        scrollWidth: 0,
        scrollHeight: 0,
        scrollTop: 0,
        scrollLeft: 0,
        isConnected: true,
        classList: {
            _set: new Set(),
            add(...c) { c.forEach((x) => this._set.add(x)); },
            remove(...c) { c.forEach((x) => this._set.delete(x)); },
            toggle(c, force) { const on = force === undefined ? !this._set.has(c) : force; on ? this._set.add(c) : this._set.delete(c); return on; },
            contains(c) { return this._set.has(c); },
        },
        setAttribute() {}, removeAttribute() {}, getAttribute() { return null; },
        hasAttribute() { return false; },
        appendChild(child) { this.children.push(child); return child; },
        insertBefore(child) { this.children.push(child); return child; },
        removeChild(child) { const i = this.children.indexOf(child); if (i >= 0) this.children.splice(i, 1); return child; },
        remove() {},
        replaceChildren(...nodes) { this.children = nodes; },
        cloneNode() { return fakeElement(this.tagName); },
        addEventListener() {}, removeEventListener() {},
        dispatchEvent() { return true; },
        closest() { return null; },
        matches() { return false; },
        querySelector() { return fakeElement('span'); },
        querySelectorAll() { return []; },
        getElementsByTagNameNS() { return []; },
        getBoundingClientRect() { return { left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 }; },
        scrollIntoView() {},
        setPointerCapture() {}, releasePointerCapture() {},
        focus() {}, blur() {}, click() {},
        get defaultView() { return globalThis.window; },
        get ownerDocument() { return globalThis.document; },
        get firstElementChild() { return this.children[0] || null; },
        get parentElement() { return null; },
    };
    return el;
}

function makeGlobals(overrides = {}) {
    const captured = { posts: [], intervals: 0, timeouts: [] };
    const realSetTimeout = globalThis.setTimeout;
    const root = fakeElement('main');
    Object.assign(root.dataset, {
        apps: JSON.stringify([
            { id: 'files', name: 'Files', href: 'https://x.test/index.php/apps/files', icon: '', target: false },
            { id: 'dashboard', name: 'Dashboard', href: 'https://x.test/index.php/apps/dashboard', icon: '', target: false },
        ]),
        windowStates: '{"windows":[]}',
        appPins: '{}',
        appsMenuSize: '{}',
        browserStateMigrated: 'true',
        firstVisit: 'false',
        shellMode: 'taskbar',
        desktopfilesEnabled: 'false',
        clockHourCycle: '24',
        showFavorites: 'false',
        showTrash: 'false',
        showHome: 'false',
        ...overrides.rootDataset,
    });
    const document = {
        defaultView: null, // wired after windowObj exists
        documentElement: fakeElement('html'),
        body: fakeElement('body'),
        hidden: false,
        title: '',
        querySelector: (sel) => (sel === '[data-desktop-app-root]' ? root : fakeElement()),
        getElementById: () => fakeElement(),
        createElement: (tag) => fakeElement(tag),
        querySelectorAll: () => [],
        createTextNode: () => fakeElement('#text'),
        importNode: (n) => fakeElement(),
        addEventListener() {}, removeEventListener() {},
        dispatchEvent() { return true; },
        elementFromPoint() { return null; },
    };
    document.documentElement.lang = 'en';
    const listeners = {};
    const windowObj = {
        location: { origin: 'https://x.test', href: 'https://x.test/index.php/apps/desktop_workspace/', protocol: 'https:', pathname: '/index.php/apps/desktop_workspace/', search: '' },
        innerWidth: 1440, innerHeight: 900,
        OC: overrides.OC,
        addEventListener(type, fn) { (listeners[type] ||= []).push(fn); },
        removeEventListener() {},
        dispatchEvent() { return true; },
        matchMedia: () => ({ matches: false }),
        getComputedStyle: () => ({ getPropertyValue: () => '', backgroundColor: '', backgroundImage: 'none', display: 'block', visibility: 'visible', left: '0px' }),
        requestAnimationFrame: (fn) => realSetTimeout(fn, 0),
        setTimeout: (fn, ms) => { captured.timeouts.push({ fn, ms }); return captured.timeouts.length; },
        clearTimeout: () => {},
        setInterval: () => { captured.intervals++; return 0; },
        clearInterval: () => {},
        open: () => null,
        Event: class { constructor(type) { this.type = type; } },
        parent: null,
    };
    const globals = {
        document,
        window: windowObj,
        navigator: { language: 'en', userAgent: 'node-seat' },
        localStorage: {
            _m: new Map(),
            getItem(k) { return this._m.has(k) ? this._m.get(k) : null; },
            setItem(k, v) { this._m.set(k, String(v)); },
            removeItem(k) { this._m.delete(k); },
        },
        MutationObserver: class { constructor() {} observe() {} disconnect() {} },
        ResizeObserver: class { constructor() {} observe() {} disconnect() {} },
        requestAnimationFrame: windowObj.requestAnimationFrame,
        getComputedStyle: windowObj.getComputedStyle,
        fetch: (...args) => { captured.posts.push(args); return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({}) }); },
        URL, URLSearchParams,
        captured,
        root,
    };
    windowObj.localStorage = globals.localStorage;
    document.defaultView = windowObj;
    return globals;
}

// Install globals into globalThis (require()d scripts see them), boot the hub + modules,
// return the DW namespace (the hub's module.exports).
function bootSplit(treeDir, overrides = {}) {
    const g = makeGlobals(overrides);
    for (const [k, v] of Object.entries(g)) {
        if (k === 'captured' || k === 'root') continue;
        globalThis[k] = v;
    }
    if (overrides.OC) globalThis.OC = overrides.OC;
    // bare setInterval/clearInterval in app code resolve to Node's real timers under the
    // seat and keep the event loop alive forever after the assertions pass — capture, don't run.
    globalThis.setInterval = () => 0;
    globalThis.clearInterval = () => {};
    globalThis.window.DW = undefined;
    // clear module cache so a second boot in one process starts clean
    const files = ['escape.js', 'desktop-shell.js', 'theming.js', 'windows.js', 'pins.js', 'iframe-chrome.js', 'favorites.js'];
    for (const f of files) {
        try { delete require.cache[require.resolve(treeDir + '/' + f)]; } catch (e) { /* first boot */ }
    }
    // browser script order: hub first, favorites last (its tail calls DW.boot())
    for (const f of files) require(treeDir + '/' + f);
    const DW = globalThis.window.DW;
    return { DW, g };
}

module.exports = { fakeElement, makeGlobals, bootSplit };
