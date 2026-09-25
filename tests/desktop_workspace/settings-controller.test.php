<?php
// L4-03/L4-01/L4-05/L4-06 pins on the patched PHP surface (PinService, both settings
// controllers, FolderPolicy, saveWindowStates cap). No phpunit — a plain assert script
// in gestion's self-test style (D2: the seat runs against the unpacked patched tree).
//
//   php settings-controller.test.php <patched-tree>
declare(strict_types=1);

$tree = realpath($argv[1] ?? die("usage: php settings-controller.test.php <patched-tree>\n"));
require __DIR__ . '/stubs-ocp.php';

// PSR-4 load the patched app classes against the stubs.
spl_autoload_register(function (string $class) use ($tree) {
    if (!str_starts_with($class, 'OCA\\DesktopWorkspace\\')) return;
    $rel = str_replace('\\', '/', substr($class, strlen('OCA\\DesktopWorkspace\\')));
    foreach (["{$tree}/lib/{$rel}.php", "{$tree}/lib/{$rel}/{$rel}.php"] as $f) {
        if (is_file($f)) { require $f; return; }
    }
});

$n = 0;
function ok(bool $c, string $m): void { global $n; if (!$c) { fwrite(STDERR, "FAIL: {$m}\n"); exit(1); } $n++; }

// ---------- fakes ----------
class FakeConfig implements \OCP\IConfig {
    public array $app = [];
    public array $user = [];
    public array $userKeys = [];
    public function getAppValue(string $a, string $k, string $d = ''): string { return $this->app["$a|$k"] ?? $d; }
    public function setAppValue(string $a, string $k, string $v): void { $this->app["$a|$k"] = $v; }
    public function getUserValue(string $u, string $a, string $k, string $d = ''): string { return $this->user["$u|$a|$k"] ?? $d; }
    public function setUserValue(string $u, string $a, string $k, string $v): void { $this->user["$u|$a|$k"] = $v; }
    public function deleteUserValue(string $u, string $a, string $k): void { unset($this->user["$u|$a|$k"]); }
    public function getUserKeys(string $u, string $a): array { return $this->userKeys["$u|$a"] ?? []; }
}
class FakeUser implements \OCP\IUser {
    public function __construct(private string $uid) {}
    public function getUID(): string { return $this->uid; }
}
class FakeSession implements \OCP\IUserSession {
    public ?\OCP\IUser $user = null;
    public function getUser(): ?\OCP\IUser { return $this->user; }
}
class FakeQueryBuilder implements \OCP\DB\IQueryBuilder {
    public static ?\Throwable $nextError = null;
    public array $rows = [];
    public function insert(string $t): \OCP\DB\IQueryBuilder { return $this; }
    public function values(array $v): \OCP\DB\IQueryBuilder { $this->rows[] = $v; return $this; }
    public function createNamedParameter(mixed $v): mixed { return $v; }
    public function executeStatement(): int { if (self::$nextError) { $e = self::$nextError; self::$nextError = null; throw $e; } return 1; }
}
class FakeDb implements \OCP\IDBConnection {
    public FakeQueryBuilder $qb;
    public function __construct() { $this->qb = new FakeQueryBuilder(); }
    public function getQueryBuilder(): \OCP\DB\IQueryBuilder { return $this->qb; }
}
class FakeCacheFactory implements \OCP\ICacheFactory {
    public function isAvailable(): bool { return false; }
    public function createDistributed(string $ns): \OCP\ICache { throw new Exception('no cache'); }
}
function statsService(FakeConfig $c): \OCA\DesktopWorkspace\Service\StatsService {
    return new \OCA\DesktopWorkspace\Service\StatsService($c, new FakeCacheFactory());
}
function personalController(FakeConfig $c, ?\OCP\IUser $u): \OCA\DesktopWorkspace\Controller\PersonalSettingsController {
    $sess = new FakeSession(); $sess->user = $u;
    $root = new FakeRootFolder();
    $deco = new \OCA\DesktopWorkspace\Service\DecorationService($c);
    return new \OCA\DesktopWorkspace\Controller\PersonalSettingsController(
        'desktop_workspace', new FakeRequest(), $c, $sess, statsService($c), $root, $deco,
        new \OCA\DesktopWorkspace\Service\PinService($c, new FakeDb()), new \OCA\DesktopWorkspace\Service\FolderPolicy($root));
}
class FakeRequest implements \OCP\IRequest {
    public function getParam(string $k, string $d = ''): string { return $d; }
}
class FakeStorage implements \OCP\IStorage {
    /** @var array<string,bool> */
    public array $is = [];
    public function __construct(private string $id) {}
    public function instanceOfStorage(string $class): bool { return $this->is[ltrim($class, '\\')] ?? false; }
    public function getId(): string { return $this->id; }
}
class FakeMount implements \OCP\Files\IMountPoint {
    public function __construct(private string $type) {}
    public function getMountType(): string { return $this->type; }
}
class FakeNode implements \OCP\Files\Folder {
    public function __construct(private string $path, private FakeStorage $storage, private FakeMount $mount, private ?FakeUser $owner, private ?string $userPrefix = null) {}
    public function getPath(): string { return $this->path; }
    public function getRelativePath(string $path): ?string {
        // user-folder semantics: strip the folder prefix; null when outside
        if ($this->userPrefix === null) return $path === $this->path ? '' : null;
        return str_starts_with($path, $this->userPrefix) ? substr($path, strlen($this->userPrefix)) : null;
    }
    public function getStorage(): \OCP\IStorage { return $this->storage; }
    public function getMountPoint(): \OCP\Files\IMountPoint { return $this->mount; }
    public function getOwner(): ?\OCP\IUser { return $this->owner; }
    public function get(string $path): \OCP\Files\INode { throw new \OCP\Files\NotFoundException(); }
}
class FakeRootFolder extends FakeNode implements \OCP\Files\IRootFolder {
    public array $children = [];
    public function __construct(string $userPrefix = '/me/files') { parent::__construct('__root__', new FakeStorage('root'), new FakeMount('local'), null, $userPrefix); }
    public function getUserFolder(string $uid): \OCP\Files\Folder { return $this; }
    public function get(string $path): \OCP\Files\INode {
        $node = $this->children[$path] ?? null;
        if (!$node) throw new \OCP\Files\NotFoundException();
        return $node;
    }
}
function node(string $path, array $is = [], string $mountType = 'local', ?FakeUser $owner = null): FakeNode {
    $storage = new FakeStorage('home::user');
    foreach ($is as $cls => $v) $storage->is[$cls] = $v;
    return new FakeNode($path, $storage, new FakeMount($mountType), $owner);
}

// ---------- L4-05 reflection posture ----------
$adminRefl = new ReflectionClass(\OCA\DesktopWorkspace\Controller\AdminSettingsController::class);
foreach ($adminRefl->getMethods(ReflectionMethod::IS_PUBLIC) as $m) {
    foreach ($m->getAttributes() as $a) {
        ok($a->getName() !== \OCP\AppFramework\Http\Attribute\NoAdminRequired::class,
            "admin action {$m->name} must NOT opt out of the admin gate");
    }
}
$personalRefl = new ReflectionClass(\OCA\DesktopWorkspace\Controller\PersonalSettingsController::class);
foreach ($personalRefl->getMethods(ReflectionMethod::IS_PUBLIC) as $m) {
    if ($m->name === '__construct') continue;
    ok(count($m->getAttributes(\OCP\AppFramework\Http\Attribute\NoAdminRequired::class)) === 1,
        "personal action {$m->name} must carry NoAdminRequired");
}

// ---------- PinService::cleanPinList ----------
$c = new FakeConfig();
$ps = new \OCA\DesktopWorkspace\Service\PinService($c, new FakeDb());
ok($ps->cleanPinList(['files', 'dashboard']) === ['files', 'dashboard'], 'valid list passes');
ok($ps->cleanPinList('nope') === null, 'non-list refused');
ok($ps->cleanPinList(['a b']) === null, 'space refused');
ok($ps->cleanPinList([str_repeat('x', 256)]) === null, '>255 refused');
ok($ps->cleanPinList(['a', 'a', 'b']) === ['a', 'b'], 'duplicates dropped');
ok(count($ps->cleanPinList(array_map('strval', range(0, 150)))) === 100, 'capped at 100');

// ---------- saveAppPins / saveIconPositions / saveWindowStates ----------
$me = new FakeUser('me');
$pc = personalController($c, $me);
$r = $pc->saveAppPins('bogus', '["files"]');
ok($r->getStatus() === 400, 'invalid location → 400');
$r = $pc->saveAppPins('taskbar', '{"not":"a list"}');
ok($r->getStatus() === 400 && $r->getData()['message'] === 'invalid pins', 'non-list pins → 400');
$r = $pc->saveAppPins('desktop', '["files","calendar"]');
ok($r->getStatus() === 200, 'valid pins stored');
ok(($c->user['me|desktop_workspace|desktop_pins'] ?? '') === '["files","calendar"]', 'stored JSON matches');
ok($r->getData()['pins']['desktop'] === ['files', 'calendar'], 'response echoes stored pins');

$r = $pc->saveIconPositions('{"k1":{"col":"3","row":7},"bad":{"col":"x"},"no":5}');
ok($r->getStatus() === 200, 'positions accepted');
$stored = json_decode($c->user['me|desktop_workspace|icon_positions'] ?? '', true);
ok(($stored['k1'] ?? null) === ['col' => 3, 'row' => 7], 'string numerics coerced to int');
ok(!isset($stored['bad']) && !isset($stored['no']), 'garbage entries dropped');

$big = json_encode(['windows' => array_fill(0, 60, ['pad' => str_repeat('a', 1000)])]);
$r = $pc->saveWindowStates($big);
ok($r->getStatus() === 400 && $r->getData()['message'] === 'window_states_too_large', '>32KB windowStates refused (L4-06)');
$ok60 = json_encode(['windows' => array_fill(0, 60, ['i' => 1])]);
$r = $pc->saveWindowStates($ok60);
ok($r->getStatus() === 200, 'small payload accepted');
ok(count(json_decode($c->user['me|desktop_workspace|window_states'], true)['windows']) === 40, 'window count capped at 40');

$anon = personalController($c, null);
ok($anon->saveIconPositions('{}')->getStatus() === 403, 'no session → 403');

// ---------- migrateBrowserState claim/validation (L4-03) ----------
$db = new FakeDb();
$ps2 = new \OCA\DesktopWorkspace\Service\PinService($c, $db);
$sess = new FakeSession(); $sess->user = $me;
$pc2 = new \OCA\DesktopWorkspace\Controller\PersonalSettingsController('desktop_workspace', new FakeRequest(), $c, $sess, statsService($c), new FakeRootFolder(), new \OCA\DesktopWorkspace\Service\DecorationService($c), $ps2, new \OCA\DesktopWorkspace\Service\FolderPolicy(new FakeRootFolder()));
$r = $pc2->migrateBrowserState('{"taskbar":["files"],"desktop":"nope"}');
ok($r->getStatus() === 400, 'invalid migration state → 400');
// first claim wins
$c->user = [];
$r = $pc2->migrateBrowserState('{"taskbar":["files"],"desktop":["dashboard"]}', 800, 600);
ok($r->getStatus() === 200 && $r->getData()['status'] === 'ok', 'first claim migrates');
ok(($c->user['me|desktop_workspace|taskbar_pins'] ?? '') === '["files"]', 'pins written');
ok(($c->user['me|desktop_workspace|browser_state_migration'] ?? '') === '1', 'migration marked done');
ok(($r->getData()['size'] ?? []) === ['width' => 800, 'height' => 600], 'size clamped and echoed');
// duplicate claim → 409 pending (a fresh pending row answers 'not yours' before claiming)
$c->user['me|desktop_workspace|browser_state_migration'] = 'pending:' . (time() - 1);
$r = $pc2->migrateBrowserState('{"taskbar":[],"desktop":[]}');
ok($r->getStatus() === 409 && $r->getData()['status'] === 'pending', 'pending row answers 409 without claiming');
// the DB-level race: no row visible yet, insert collides (1062) → false → 409
$c->user['me|desktop_workspace|browser_state_migration'] = '';
FakeQueryBuilder::$nextError = new \OC\DB\Exceptions\DbalException('dup', 1062);
$r = $pc2->migrateBrowserState('{"taskbar":[],"desktop":[]}');
ok($r->getStatus() === 409, 'lost insert race → 409');
FakeQueryBuilder::$nextError = null;
// stale claim (>300s) is reclaimed
$c->user['me|desktop_workspace|browser_state_migration'] = 'pending:' . (time() - 301);
$r = $pc2->migrateBrowserState('{"taskbar":["files"],"desktop":[]}');
ok($r->getStatus() === 200, 'stale claim reclaimed');
// non-1062 DB error propagates
$c->user['me|desktop_workspace|browser_state_migration'] = '';
FakeQueryBuilder::$nextError = new \OC\DB\Exceptions\DbalException('boom', 500);
try { $pc2->migrateBrowserState('{"taskbar":[],"desktop":[]}'); ok(false, 'non-1062 DB error must propagate'); }
catch (\OC\DB\Exceptions\DbalException $e) { ok(true, 'non-1062 DB error propagates'); }

// ---------- L4-01/L4-04-adjacent: saveAdminSettings answers, response has NO logFile ----------
class FakeUserManager implements \OCP\IUserManager {
    /** @var array<string,FakeUser> */
    public array $users = [];
    public function get(string $uid): ?\OCP\IUser { return $this->users[$uid] ?? null; }
}
$c2 = new FakeConfig();
$um = new FakeUserManager();
$ac = new \OCA\DesktopWorkspace\Controller\AdminSettingsController('desktop_workspace', new FakeRequest(), $c2, $um, new \OCA\DesktopWorkspace\Service\PinService($c2, new FakeDb()));
$src = file_get_contents($tree . '/lib/Controller/AdminSettingsController.php');
ok(!str_contains($src, 'getLogPath'), 'patched tree has no getLogPath call (L4-01)');
$r = $ac->save('yes', '["staff"]', '["files"]', 'no');
ok($r->getStatus() === 200, 'save() answers 200 (the live bug answered 500)');
$d = $r->getData();
ok(!array_key_exists('logFile', $d), 'response carries no logFile key');
ok($d['experimentalGroups'] === ['staff'] && $d['multiWindowApps'] === ['files'], 'arrays cleaned and echoed');
ok($c2->app['desktop_workspace|experimental_files_disabled'] === 'yes', 'disabled written');
$r = $ac->resetUserSettings('ghost');
ok($r->getStatus() === 404 && $r->getData()['message'] === 'unknown_user', 'unknown user → 404');
$um->users['jane'] = new FakeUser('jane');
$c2->user['jane|desktop_workspace|show_favorites'] = 'yes';
$c2->userKeys['jane|desktop_workspace'] = ['show_favorites'];
$r = $ac->resetUserSettings('jane');
ok($r->getStatus() === 200, 'known user reset');
ok(!isset($c2->user['jane|desktop_workspace|show_favorites']), 'user values wiped');
ok(($c2->user['jane|desktop_workspace|browser_state_migration'] ?? '') === '1', 'reset marks migration done');

// ---------- FolderPolicy (L4-09 extraction) ----------
$root = new FakeRootFolder();
$fp = new \OCA\DesktopWorkspace\Service\FolderPolicy($root);
$me2 = new FakeUser('me');
$root->children['Docs'] = node('/me/files/Docs', [], 'local', $me2);
$v = $fp->validateDesktopFolder('me', 'Docs');
ok($v['ok'] === true && $v['path'] === '/Docs', 'own folder accepted, path normalized');
$root->children['a.txt'] = node('/me/files/a.txt', [], 'local', null);
// (the not_a_folder case needs a non-Folder node — the stub tree always yields Folder, so
//  cover shared/group/not-owned/missing which ARE reachable through node attributes)
$root->children['Shared'] = node('/me/files/Shared', ['OCA\Files_Sharing\SharedStorage' => true], 'shared', null);
$v = $fp->validateDesktopFolder('me', 'Shared');
ok($v['ok'] === false && $v['error'] === 'shared_not_allowed' && $v['status'] === 400, 'incoming share refused');
$root->children['Team'] = node('/me/files/Team', ['OCA\\GroupFolders\\Mount\\GroupFolderStorage' => true], 'group', null);
$v = $fp->validateDesktopFolder('me', 'Team');
ok($v['ok'] === false && $v['error'] === 'group_folder_not_allowed', 'group folder refused');
$other = new FakeUser('other');
$root->children['other/Their'] = node('/other/files/Their', [], 'local', $other);
$root->children['Their'] = node('/me/files/Their', [], 'local', $other);
$v = $fp->validateDesktopFolder('me', 'Their');
ok($v['ok'] === false && $v['error'] === 'not_owned', "someone else's folder refused");
$v = $fp->validateDesktopFolder('me', 'Missing');
ok($v['ok'] === false && $v['error'] === 'not_found' && $v['status'] === 404, 'missing folder → not_found 404');

// ---------- personal writer: desktop_folder policy is wired (L4-09) ----------
$pc3 = personalController($c, $me); // reuses $root? no — its own root; build fresh
$root2 = new FakeRootFolder();
$root2->children['Shared'] = node('/me/files/Shared', ['OCA\\Files_Sharing\\SharedStorage' => true], 'shared', null);
$sess3 = new FakeSession(); $sess3->user = $me;
$pc3 = new \OCA\DesktopWorkspace\Controller\PersonalSettingsController('desktop_workspace', new FakeRequest(), $c, $sess3, statsService($c), $root2, new \OCA\DesktopWorkspace\Service\DecorationService($c), $ps, new \OCA\DesktopWorkspace\Service\FolderPolicy($root2));
$r = $pc3->save(null, null, null, null, null, 'Shared');
ok($r->getStatus() === 400 && $r->getData()['message'] === 'shared_not_allowed', 'personal writer routes folder policy (shared refused)');
$r = $pc3->save(null, null, null, null, null, '');
ok($r->getStatus() === 200 && ($r->getData()['desktopFolder'] ?? '') === '', 'empty folder clears the key');

echo "PASS: settings-controller pins ({$n} assertions)\n";
exit(0);
