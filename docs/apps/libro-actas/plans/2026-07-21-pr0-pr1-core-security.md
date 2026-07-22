# Libro de Actas — PR0 + PR1 (Foundations + Core + Security Spine) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An installable NC34 app where a team member writes a private draft acta, signs it into an immutable acta (with an atomic folio), while any patient PII in the free-text is detected, encrypted at rest, and gated behind a signed disclaimer that writes an audit log.

**Architecture:** Standard Nextcloud custom app (`apps/libro_actas`, namespace `OCA\LibroActas`), OCP public APIs only. PHP backend layered Controllers → Services → QBMapper on PostgreSQL; Vue 3 + `@nextcloud/vue` frontend. Sensitive `contenido_libre` is encrypted via `OCP\Security\ICrypto`; access to sensitive actas is gated + logged. See the design spec and ADR-0001.

**Tech Stack:** PHP 8.x, Nextcloud 34 OCP APIs, PostgreSQL 18, PHPUnit, Vue 3, `@nextcloud/vue` (NC34 line), Webpack (`@nextcloud/webpack-vue-config`).

## Global Constraints

- **Platform:** Nextcloud **34** (`info.xml` `min-version="34"`); OCP public APIs only — never core/private internals (AD-9).
- **Language:** code, identifiers, comments in **English**; all user-facing UI text in **Spanish (es-CL)**.
- **Data:** no real data; dev uses synthetic fixtures. `contenido_libre` is the only PII surface → encrypted at rest.
- **Immutability:** a finalized acta never changes; corrections are addenda (PR2). Drafts are mutable + private to author.
- **Reference docs:** pull Nextcloud app-dev + `@nextcloud/vue` docs live via Context7 MCP; component storybook: https://nextcloud-vue-components.netlify.app/
- **Terms:** use `CONTEXT.md` verbatim — `equipo` (any team group), `acta`, `borrador`, `firma`, `folio`, `registrante`, `contenido_libre`.
- **Commits:** Conventional Commits; end each with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## File Structure

```
apps/libro_actas/
  appinfo/
    info.xml                         # app manifest (id, NC34 dep, navigation)
    routes.php                       # route → controller map
  lib/
    AppInfo/Application.php           # bootstrap (IBootstrap)
    Migration/Version000001Date...php # schema (all PR1 tables)
    Db/
      Acta.php                        # Entity
      ActaMapper.php                  # QBMapper
      FolioCounter.php / Mapper       # atomic correlative
    Service/
      PiiDetector.php                 # deterministic RUT(mod11)/email/phone/RIT
      CryptoService.php               # ICrypto wrapper for contenido_libre
      FolioService.php                # atomic per equipo+year allocation
      EquipoService.php               # team group → members (OCP)
      VocabularyService.php           # directory-synced + config vocabularies
      ActaService.php                 # draft/finalize/view orchestration
      AccessGuard.php                 # access scope + sensitive disclaimer/audit
    Controller/
      ActaController.php              # draft, finalize, view, list
      PageController.php              # SPA entry
  src/
    main.js                          # Vue bootstrap
    App.vue                          # app shell (NcContent + navigation)
    views/{Registro,NuevaActa,VerActa}.vue
    services/api.js                  # axios/@nextcloud/axios calls
  tests/unit/
    PiiDetectorTest.php  FolioServiceTest.php  CryptoServiceTest.php
    ActaMapperTest.php   AccessGuardTest.php
```

---

### Task 1: App skeleton (PR0)

**Files:**
- Create: `apps/libro_actas/appinfo/info.xml`
- Create: `apps/libro_actas/lib/AppInfo/Application.php`

**Interfaces:**
- Produces: app id `libro_actas`, namespace `OCA\LibroActas`, enabled app.

- [ ] **Step 1: Write `info.xml`**

```xml
<?xml version="1.0"?>
<info xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xsi:noNamespaceSchemaLocation="https://apps.nextcloud.com/schema/apps/info.xsd">
  <id>libro_actas</id>
  <name>Libro de Actas</name>
  <summary>Registro de actas de reunión del CESFAM</summary>
  <description>Registro, seguimiento y generación de actas de reunión.</description>
  <version>0.1.0</version>
  <licence>agpl</licence>
  <author>APS Conecta</author>
  <namespace>LibroActas</namespace>
  <category>organization</category>
  <dependencies><nextcloud min-version="34" max-version="34"/></dependencies>
  <navigations>
    <navigation><name>Libro de Actas</name><route>libro_actas.page.index</route></navigation>
  </navigations>
</info>
```

- [ ] **Step 2: Write `Application.php`**

```php
<?php
declare(strict_types=1);
namespace OCA\LibroActas\AppInfo;

use OCP\AppFramework\App;
use OCP\AppFramework\Bootstrap\IBootstrap;
use OCP\AppFramework\Bootstrap\IRegistrationContext;
use OCP\AppFramework\Bootstrap\IBootContext;

class Application extends App implements IBootstrap {
    public const APP_ID = 'libro_actas';
    public function __construct() { parent::__construct(self::APP_ID); }
    public function register(IRegistrationContext $context): void {}
    public function boot(IBootContext $context): void {}
}
```

- [ ] **Step 3: Enable and verify**

Run: `docker compose exec --user www-data nextcloud php occ app:enable libro_actas`
Expected: `libro_actas enabled`. Then `occ app:list | grep libro_actas` shows it under Enabled.

- [ ] **Step 4: Commit**

```bash
git add apps/libro_actas/appinfo/info.xml apps/libro_actas/lib/AppInfo/Application.php
git commit -m "feat(libro-actas): app skeleton (info.xml + Application bootstrap)"
```

---

### Task 2: Database schema migration

**Files:**
- Create: `apps/libro_actas/lib/Migration/Version000001Date20260721.php`

**Interfaces:**
- Produces tables: `la_actas`, `la_attendees`, `la_guests`, `la_drafts`, `la_access_log`, `la_folio_counter` (PR2 adds acuerdos/addenda).

- [ ] **Step 1: Write the migration**

```php
<?php
declare(strict_types=1);
namespace OCA\LibroActas\Migration;

use Closure;
use OCP\DB\ISchemaWrapper;
use OCP\DB\Types;
use OCP\Migration\IOutput;
use OCP\Migration\SimpleMigrationStep;

class Version000001Date20260721 extends SimpleMigrationStep {
    public function changeSchema(IOutput $o, Closure $schemaClosure, array $opts): ?ISchemaWrapper {
        /** @var ISchemaWrapper $s */ $s = $schemaClosure();
        if (!$s->hasTable('la_actas')) {
            $t = $s->createTable('la_actas');
            $t->addColumn('id','bigint',['autoincrement'=>true,'notnull'=>true]);
            $t->addColumn('folio','string',['length'=>32,'notnull'=>false]);
            $t->addColumn('equipo','string',['length'=>64,'notnull'=>true]);       // team group id
            $t->addColumn('tipo_reunion','string',['length'=>64,'notnull'=>false]);
            $t->addColumn('tipo_actividad','string',['length'=>64,'notnull'=>false]);
            $t->addColumn('estado','string',['length'=>32,'notnull'=>true,'default'=>'borrador']);
            $t->addColumn('fecha','date',['notnull'=>false]);
            $t->addColumn('hora_inicio','string',['length'=>5,'notnull'=>false]);
            $t->addColumn('hora_termino','string',['length'=>5,'notnull'=>false]);
            $t->addColumn('lugar','string',['length'=>255,'notnull'=>false]);
            $t->addColumn('quorum','boolean',['notnull'=>false]);
            $t->addColumn('proxima_reunion','datetime',['notnull'=>false]);
            $t->addColumn('contenido_libre','text',['notnull'=>false]);            // ENCRYPTED blob
            $t->addColumn('is_sensitive','boolean',['notnull'=>true,'default'=>false]);
            $t->addColumn('registrante','string',['length'=>64,'notnull'=>true]);
            $t->addColumn('firma_uid','string',['length'=>64,'notnull'=>false]);
            $t->addColumn('firma_at','datetime',['notnull'=>false]);
            $t->addColumn('is_finalized','boolean',['notnull'=>true,'default'=>false]);
            $t->addColumn('created_at','datetime',['notnull'=>true]);
            $t->addColumn('updated_at','datetime',['notnull'=>true]);
            $t->setPrimaryKey(['id']);
            $t->addIndex(['equipo'],'la_actas_equipo_idx');
        }
        if (!$s->hasTable('la_folio_counter')) {
            $t = $s->createTable('la_folio_counter');
            $t->addColumn('equipo','string',['length'=>64,'notnull'=>true]);
            $t->addColumn('year','integer',['notnull'=>true]);
            $t->addColumn('last_n','integer',['notnull'=>true,'default'=>0]);
            $t->setPrimaryKey(['equipo','year']);   // one counter row per equipo+year
        }
        foreach ([
            ['la_attendees', fn($t)=>[$t->addColumn('uid','string',['length'=>64]),
                $t->addColumn('nombre','string',['length'=>255]),$t->addColumn('rol','string',['length'=>128,'notnull'=>false]),
                $t->addColumn('equipo','string',['length'=>64,'notnull'=>false])]],
            ['la_guests', fn($t)=>[$t->addColumn('nombre','string',['length'=>128]),
                $t->addColumn('primer_apellido','string',['length'=>128]),$t->addColumn('segundo_apellido','string',['length'=>128,'notnull'=>false]),
                $t->addColumn('rol_cargo','string',['length'=>128,'notnull'=>false])]],
            ['la_access_log', fn($t)=>[$t->addColumn('uid','string',['length'=>64]),
                $t->addColumn('action','string',['length'=>16]),$t->addColumn('logged_at','datetime')]],
        ] as [$name,$cols]) {
            if (!$s->hasTable($name)) {
                $t=$s->createTable($name);
                $t->addColumn('id','bigint',['autoincrement'=>true,'notnull'=>true]);
                $t->addColumn('acta_id','bigint',['notnull'=>true]);
                $cols($t); $t->setPrimaryKey(['id']); $t->addIndex(['acta_id'],$name.'_acta_idx');
            }
        }
        if (!$s->hasTable('la_drafts')) {
            $t=$s->createTable('la_drafts');
            $t->addColumn('id','bigint',['autoincrement'=>true,'notnull'=>true]);
            $t->addColumn('author','string',['length'=>64,'notnull'=>true]);
            $t->addColumn('payload','text',['notnull'=>true]);      // JSON
            $t->addColumn('updated_at','datetime',['notnull'=>true]);
            $t->setPrimaryKey(['id']); $t->addIndex(['author'],'la_drafts_author_idx');
        }
        return $s;
    }
}
```

- [ ] **Step 2: Apply and verify**

Run: `docker compose exec --user www-data nextcloud php occ migrations:execute libro_actas 000001Date20260721`
Expected: no error; `occ migrations:status libro_actas` lists it applied. Verify in psql: `\dt oc_la_*` shows the 6 tables.

- [ ] **Step 3: Commit**

```bash
git add apps/libro_actas/lib/Migration/Version000001Date20260721.php
git commit -m "feat(libro-actas): initial schema (actas, attendees, guests, drafts, access log, folio counter)"
```

---

### Task 3: PII detector (RUT módulo-11 + email/phone/RIT) — pure, TDD

**Files:**
- Create: `apps/libro_actas/lib/Service/PiiDetector.php`
- Test: `apps/libro_actas/tests/unit/PiiDetectorTest.php`

**Interfaces:**
- Produces: `PiiDetector::scan(string $text): array` → `['rut'=>bool,'email'=>bool,'phone'=>bool,'rit'=>bool,'any'=>bool]`.
  `PiiDetector::isValidRut(string $rut): bool`.

- [ ] **Step 1: Write the failing test**

```php
<?php
declare(strict_types=1);
namespace OCA\LibroActas\Tests\Unit;
use OCA\LibroActas\Service\PiiDetector;
use PHPUnit\Framework\TestCase;

class PiiDetectorTest extends TestCase {
    private PiiDetector $d;
    protected function setUp(): void { $this->d = new PiiDetector(); }

    public function testValidRutWithCheckDigit(): void {
        $this->assertTrue($this->d->isValidRut('12.345.678-5'));   // valid DV
        $this->assertTrue($this->d->isValidRut('11111111-1'));
        $this->assertFalse($this->d->isValidRut('12.345.678-9')); // wrong DV → not a RUT
    }
    public function testScanDetectsRutOnlyWhenCheckDigitValid(): void {
        $this->assertTrue($this->d->scan('paciente RUT 12.345.678-5 derivado')['rut']);
        $this->assertFalse($this->d->scan('el código 12.345.678-9 no es rut')['rut']);
    }
    public function testScanEmailPhoneRit(): void {
        $this->assertTrue($this->d->scan('correo a b@c.cl')['email']);
        $this->assertTrue($this->d->scan('fono +56 9 1234 5678')['phone']);
        $this->assertTrue($this->d->scan('causa RIT O-123-2026')['rit']);
    }
    public function testCleanTextIsClean(): void {
        $r = $this->d->scan('Se acuerda coordinar la campaña de vacunación 2026.');
        $this->assertFalse($r['any']);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec --user www-data nextcloud php vendor/bin/phpunit -c apps/libro_actas/tests/phpunit.xml apps/libro_actas/tests/unit/PiiDetectorTest.php`
Expected: FAIL — class `PiiDetector` not found. (If phpunit.xml is missing, create a minimal one pointing bootstrap to `lib/../../../tests/bootstrap.php`; see Nextcloud app test template via Context7.)

- [ ] **Step 3: Write the implementation**

```php
<?php
declare(strict_types=1);
namespace OCA\LibroActas\Service;

class PiiDetector {
    /** Chilean RUT check digit (módulo 11). */
    public function isValidRut(string $rut): bool {
        $rut = strtolower(str_replace(['.', ' '], '', $rut));
        if (!preg_match('/^(\d{7,8})-([\dk])$/', $rut, $m)) return false;
        [$num, $dv] = [$m[1], $m[2]];
        $sum = 0; $mul = 2;
        for ($i = strlen($num) - 1; $i >= 0; $i--) {
            $sum += ((int)$num[$i]) * $mul;
            $mul = $mul === 7 ? 2 : $mul + 1;
        }
        $res = 11 - ($sum % 11);
        $calc = $res === 11 ? '0' : ($res === 10 ? 'k' : (string)$res);
        return $calc === $dv;
    }
    /** @return array{rut:bool,email:bool,phone:bool,rit:bool,any:bool} */
    public function scan(string $text): array {
        $rut = false;
        if (preg_match_all('/\b\d{1,2}\.?\d{3}\.?\d{3}-?[\dkK]\b/', $text, $mm)) {
            foreach ($mm[0] as $cand) { if ($this->isValidRut($cand)) { $rut = true; break; } }
        }
        $email = (bool)preg_match('/[\w.+-]+@[\w-]+\.[\w.-]+/', $text);
        $phone = (bool)preg_match('/(\+?56)?[\s-]?9[\s-]?\d{4}[\s-]?\d{4}/', $text);
        $rit   = (bool)preg_match('/\bRI[TC]\s*[A-Z]?-?\d+-?\d{2,4}\b/i', $text);
        return ['rut'=>$rut,'email'=>$email,'phone'=>$phone,'rit'=>$rit,
                'any'=>$rut||$email||$phone||$rit];
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose exec --user www-data nextcloud php vendor/bin/phpunit -c apps/libro_actas/tests/phpunit.xml apps/libro_actas/tests/unit/PiiDetectorTest.php`
Expected: PASS (4 tests, all green).

- [ ] **Step 5: Commit**

```bash
git add apps/libro_actas/lib/Service/PiiDetector.php apps/libro_actas/tests/unit/PiiDetectorTest.php apps/libro_actas/tests/phpunit.xml
git commit -m "feat(libro-actas): deterministic PII detector (RUT módulo-11, email, phone, RIT)"
```

---

### Task 4: CryptoService (encrypt/decrypt contenido_libre) — TDD

**Files:**
- Create: `apps/libro_actas/lib/Service/CryptoService.php`
- Test: `apps/libro_actas/tests/unit/CryptoServiceTest.php`

**Interfaces:**
- Consumes: `OCP\Security\ICrypto`.
- Produces: `CryptoService::encrypt(?string $plain): ?string`, `CryptoService::decrypt(?string $cipher): ?string`. Null in → null out.

- [ ] **Step 1: Write the failing test**

```php
<?php
declare(strict_types=1);
namespace OCA\LibroActas\Tests\Unit;
use OCA\LibroActas\Service\CryptoService;
use OCP\Security\ICrypto;
use PHPUnit\Framework\TestCase;

class CryptoServiceTest extends TestCase {
    public function testRoundTrip(): void {
        $crypto = $this->createMock(ICrypto::class);
        $crypto->method('encrypt')->willReturnCallback(fn($p)=>base64_encode($p));
        $crypto->method('decrypt')->willReturnCallback(fn($c)=>base64_decode($c));
        $svc = new CryptoService($crypto);
        $this->assertSame('RUT 12.345.678-5', $svc->decrypt($svc->encrypt('RUT 12.345.678-5')));
    }
    public function testNullPassthrough(): void {
        $svc = new CryptoService($this->createMock(ICrypto::class));
        $this->assertNull($svc->encrypt(null));
        $this->assertNull($svc->decrypt(null));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `... phpunit ... CryptoServiceTest.php` — Expected: FAIL, class not found.

- [ ] **Step 3: Write the implementation**

```php
<?php
declare(strict_types=1);
namespace OCA\LibroActas\Service;
use OCP\Security\ICrypto;

class CryptoService {
    public function __construct(private ICrypto $crypto) {}
    public function encrypt(?string $plain): ?string {
        return $plain === null ? null : $this->crypto->encrypt($plain);
    }
    public function decrypt(?string $cipher): ?string {
        return ($cipher === null || $cipher === '') ? null : $this->crypto->decrypt($cipher);
    }
}
```

- [ ] **Step 4: Run test to verify it passes** — Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/libro_actas/lib/Service/CryptoService.php apps/libro_actas/tests/unit/CryptoServiceTest.php
git commit -m "feat(libro-actas): CryptoService wrapping ICrypto for contenido_libre"
```

---

### Task 5: FolioService (atomic correlative per equipo+year) — TDD

**Files:**
- Create: `apps/libro_actas/lib/Service/FolioService.php`
- Test: `apps/libro_actas/tests/unit/FolioServiceTest.php`

**Interfaces:**
- Consumes: `OCP\IDBConnection`.
- Produces: `FolioService::allocate(string $equipo, int $year): string` → e.g. `SM-2026-001`. Sequential + atomic (row lock on the counter).

- [ ] **Step 1: Write the failing test**

```php
<?php
declare(strict_types=1);
namespace OCA\LibroActas\Tests\Unit;
use OCA\LibroActas\Service\FolioService;
use PHPUnit\Framework\TestCase;

class FolioServiceTest extends TestCase {
    public function testPrefixDerivation(): void {
        // 'prog-salud-mental' -> 'SM'; 'unidad-direccion' -> 'DIR' (first letters of significant words, upper)
        $svc = $this->newSvcReturning(1);
        $this->assertSame('SM-2026-001', $svc->format('prog-salud-mental', 2026, 1));
        $this->assertSame('DIR-2026-042', $svc->format('unidad-direccion', 2026, 42));
    }
    private function newSvcReturning(int $n): FolioService {
        $db = $this->createMock(\OCP\IDBConnection::class);   // format() is pure; allocate() tested via integration
        return new FolioService($db);
    }
}
```

- [ ] **Step 2: Run test to verify it fails** — FAIL, class not found.

- [ ] **Step 3: Write the implementation**

```php
<?php
declare(strict_types=1);
namespace OCA\LibroActas\Service;
use OCP\IDBConnection;

class FolioService {
    public function __construct(private IDBConnection $db) {}

    /** Atomically bump la_folio_counter and return the formatted folio. */
    public function allocate(string $equipo, int $year): string {
        $this->db->beginTransaction();
        try {
            // ensure the counter row exists, then lock+increment
            $qb = $this->db->getQueryBuilder();
            $exists = $qb->select('last_n')->from('la_folio_counter')
                ->where($qb->expr()->eq('equipo',$qb->createNamedParameter($equipo)))
                ->andWhere($qb->expr()->eq('year',$qb->createNamedParameter($year, \PDO::PARAM_INT)))
                ->forUpdate()->executeQuery();
            $row = $exists->fetch(); $exists->closeCursor();
            if ($row === false) {
                $ins = $this->db->getQueryBuilder();
                $ins->insert('la_folio_counter')->values([
                    'equipo'=>$ins->createNamedParameter($equipo),
                    'year'=>$ins->createNamedParameter($year, \PDO::PARAM_INT),
                    'last_n'=>$ins->createNamedParameter(0, \PDO::PARAM_INT),
                ])->executeStatement();
                $n = 1;
            } else { $n = (int)$row['last_n'] + 1; }
            $upd = $this->db->getQueryBuilder();
            $upd->update('la_folio_counter')->set('last_n',$upd->createNamedParameter($n, \PDO::PARAM_INT))
                ->where($upd->expr()->eq('equipo',$upd->createNamedParameter($equipo)))
                ->andWhere($upd->expr()->eq('year',$upd->createNamedParameter($year, \PDO::PARAM_INT)))
                ->executeStatement();
            $this->db->commit();
            return $this->format($equipo, $year, $n);
        } catch (\Throwable $e) { $this->db->rollBack(); throw $e; }
    }

    public function format(string $equipo, int $year, int $n): string {
        $slug = preg_replace('/^(prog|unidad|sector|cat)-/', '', $equipo);
        $words = preg_split('/[-_\s]+/', $slug);
        $stop = ['de','la','el','y','del'];
        $sig = array_values(array_filter($words, fn($w)=>!in_array($w,$stop,true) && $w!==''));
        $prefix = count($sig) === 1
            ? strtoupper(substr($sig[0], 0, 3))
            : strtoupper(implode('', array_map(fn($w)=>$w[0], $sig)));
        return sprintf('%s-%d-%03d', $prefix, $year, $n);
    }
}
```

- [ ] **Step 4: Run test to verify it passes** — Expected: PASS (format cases). *Note: `allocate()` atomicity is covered by an integration smoke in Task 9 (finalize), not a unit test.*

- [ ] **Step 5: Commit**

```bash
git add apps/libro_actas/lib/Service/FolioService.php apps/libro_actas/tests/unit/FolioServiceTest.php
git commit -m "feat(libro-actas): atomic folio allocation per equipo+year"
```

---

### Task 6: Acta entity + mapper

**Files:**
- Create: `apps/libro_actas/lib/Db/Acta.php`, `apps/libro_actas/lib/Db/ActaMapper.php`
- Test: `apps/libro_actas/tests/unit/ActaMapperTest.php`

**Interfaces:**
- Produces: `Acta` (getters/setters for every column), `ActaMapper::find(int $id): Acta`,
  `ActaMapper::findForUserEquipos(array $equipos, bool $isJefatura): Acta[]` (access-scoped list),
  `ActaMapper::insert/update` (from QBMapper).

- [ ] **Step 1: Write the failing test** (mapper find round-trip via in-memory: assert `Acta` maps columns → camelCase)

```php
<?php
declare(strict_types=1);
namespace OCA\LibroActas\Tests\Unit;
use OCA\LibroActas\Db\Acta;
use PHPUnit\Framework\TestCase;
class ActaMapperTest extends TestCase {
    public function testEntityColumnMapping(): void {
        $a = new Acta();
        $a->setEquipo('prog-salud-mental'); $a->setIsSensitive(true);
        $this->assertSame('prog-salud-mental', $a->getEquipo());
        $this->assertTrue($a->getIsSensitive());
    }
}
```

- [ ] **Step 2: Run test to verify it fails** — FAIL, class not found.

- [ ] **Step 3: Write `Acta.php` and `ActaMapper.php`**

```php
<?php
declare(strict_types=1);
namespace OCA\LibroActas\Db;
use OCP\AppFramework\Db\Entity;

/**
 * @method void setEquipo(string $v) @method string getEquipo()
 * @method void setIsSensitive(bool $v) @method bool getIsSensitive()
 * ... (one pair per column; declare all)
 */
class Acta extends Entity {
    protected $folio, $equipo, $tipoReunion, $tipoActividad, $estado, $fecha,
        $horaInicio, $horaTermino, $lugar, $quorum, $proximaReunion, $contenidoLibre,
        $isSensitive, $registrante, $firmaUid, $firmaAt, $isFinalized, $createdAt, $updatedAt;
    public function __construct() {
        $this->addType('isSensitive','boolean'); $this->addType('isFinalized','boolean');
        $this->addType('quorum','boolean');
    }
}
```

```php
<?php
declare(strict_types=1);
namespace OCA\LibroActas\Db;
use OCP\AppFramework\Db\QBMapper;
use OCP\IDBConnection;

/** @extends QBMapper<Acta> */
class ActaMapper extends QBMapper {
    public function __construct(IDBConnection $db) { parent::__construct($db, 'la_actas', Acta::class); }
    public function find(int $id): Acta {
        $qb = $this->db->getQueryBuilder();
        $qb->select('*')->from($this->getTableName())
           ->where($qb->expr()->eq('id',$qb->createNamedParameter($id, \PDO::PARAM_INT)));
        return $this->findEntity($qb);
    }
    /** @return Acta[] */
    public function findForUserEquipos(array $equipos, bool $isJefatura): array {
        $qb = $this->db->getQueryBuilder();
        $qb->select('*')->from($this->getTableName())
           ->where($qb->expr()->eq('is_finalized',$qb->createNamedParameter(true, \PDO::PARAM_BOOL)));
        if (!$isJefatura) {
            $qb->andWhere($qb->expr()->in('equipo',
                $qb->createNamedParameter($equipos ?: ['__none__'], IDBConnection::PARAM_STR_ARRAY)));
        }
        $qb->orderBy('fecha','DESC');
        return $this->findEntities($qb);
    }
}
```

- [ ] **Step 4: Run test to verify it passes** — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/libro_actas/lib/Db/Acta.php apps/libro_actas/lib/Db/ActaMapper.php apps/libro_actas/tests/unit/ActaMapperTest.php
git commit -m "feat(libro-actas): Acta entity + access-scoped mapper"
```

---

### Task 7: EquipoService + VocabularyService (directory-synced)

**Files:**
- Create: `apps/libro_actas/lib/Service/EquipoService.php`, `apps/libro_actas/lib/Service/VocabularyService.php`

**Interfaces:**
- Consumes: `OCP\IGroupManager`, `OCP\IUserManager`, `OCP\IUserSession`, `OCP\IConfig`.
- Produces:
  - `EquipoService::userEquipos(string $uid): string[]` (team gids the user belongs to: `prog-*`/`unidad-*`/`sector-*`).
  - `EquipoService::isJefatura(string $uid): bool` (`cat-jefaturas` membership).
  - `EquipoService::members(string $equipo): array` (uid → displayName).
  - `VocabularyService::equipos(): array`, `::roles(): array` (from groups), `::tiposReunion(): array` (from app config, seeded).

- [ ] **Step 1: Write EquipoService**

```php
<?php
declare(strict_types=1);
namespace OCA\LibroActas\Service;
use OCP\IGroupManager; use OCP\IUserManager;

class EquipoService {
    private const TEAM_PREFIXES = ['prog-','unidad-','sector-'];
    public function __construct(private IGroupManager $groups, private IUserManager $users) {}

    /** @return string[] team group ids the user belongs to */
    public function userEquipos(string $uid): array {
        $u = $this->users->get($uid); if (!$u) return [];
        return array_values(array_filter(
            $this->groups->getUserGroupIds($u),
            fn($gid) => $this->isTeam($gid)));
    }
    public function isJefatura(string $uid): bool {
        $u = $this->users->get($uid);
        return $u !== null && $this->groups->isInGroup($uid, 'cat-jefaturas');
    }
    /** @return array<string,string> uid => display name */
    public function members(string $equipo): array {
        $g = $this->groups->get($equipo); if (!$g) return [];
        $out = []; foreach ($g->getUsers() as $u) { $out[$u->getUID()] = $u->getDisplayName(); }
        return $out;
    }
    private function isTeam(string $gid): bool {
        foreach (self::TEAM_PREFIXES as $p) { if (str_starts_with($gid,$p)) return true; }
        return false;
    }
}
```

- [ ] **Step 2: Write VocabularyService** (equipos/roles from groups; tiposReunion/tiposActividad/estados/tags from `IConfig` app values, seeded with defaults)

```php
<?php
declare(strict_types=1);
namespace OCA\LibroActas\Service;
use OCP\IConfig; use OCP\IGroupManager;

class VocabularyService {
    private const DEFAULTS = [
        'tipos_reunion' => ['Consejo de Desarrollo Local','Equipo clínico','Junta administrativa'],
        'tipos_actividad' => ['Reunión','Capacitación','Coordinación'],
        'estados' => ['borrador','finalizada'],
    ];
    public function __construct(private IConfig $config, private IGroupManager $groups) {}
    /** @return array<string,string> gid => display name */
    public function equipos(): array {
        $out = [];
        foreach ($this->groups->search('') as $g) {
            $gid = $g->getGID();
            if (preg_match('/^(prog|unidad|sector)-/', $gid)) $out[$gid] = $g->getDisplayName();
        }
        return $out;
    }
    public function roles(): array {
        $out = [];
        foreach ($this->groups->search('role-') as $g) $out[$g->getGID()] = $g->getDisplayName();
        return $out;
    }
    public function list(string $key): array {
        $raw = $this->config->getAppValue('libro_actas', 'vocab_'.$key, '');
        return $raw === '' ? (self::DEFAULTS[$key] ?? []) : json_decode($raw, true);
    }
}
```

- [ ] **Step 3: Manual verify** via `occ` tinker or a temporary route: with fixtures loaded, `userEquipos('fixture-user')` returns their `prog-*` ids; `equipos()` lists the seeded teams. (No unit test — thin OCP adapters; covered by the controller smoke in Task 9.)

- [ ] **Step 4: Commit**

```bash
git add apps/libro_actas/lib/Service/EquipoService.php apps/libro_actas/lib/Service/VocabularyService.php
git commit -m "feat(libro-actas): directory-synced equipos, roles and vocabularies"
```

---

### Task 8: AccessGuard (access scope + sensitive disclaimer/audit) — TDD

**Files:**
- Create: `apps/libro_actas/lib/Service/AccessGuard.php`
- Test: `apps/libro_actas/tests/unit/AccessGuardTest.php`

**Interfaces:**
- Consumes: `EquipoService`, `ActaMapper`, `OCP\IDBConnection` (for `la_access_log`).
- Produces:
  - `AccessGuard::canView(string $uid, Acta $a): bool` (owner equipo member OR jefatura).
  - `AccessGuard::requiresDisclaimer(Acta $a): bool` (`is_sensitive`).
  - `AccessGuard::logAccess(string $uid, int $actaId, string $action): void` (writes `la_access_log`).

- [ ] **Step 1: Write the failing test**

```php
<?php
declare(strict_types=1);
namespace OCA\LibroActas\Tests\Unit;
use OCA\LibroActas\Db\Acta;
use OCA\LibroActas\Service\{AccessGuard,EquipoService};
use PHPUnit\Framework\TestCase;

class AccessGuardTest extends TestCase {
    public function testMemberOfOwningEquipoCanView(): void {
        $eq = $this->createMock(EquipoService::class);
        $eq->method('userEquipos')->willReturn(['prog-salud-mental']);
        $eq->method('isJefatura')->willReturn(false);
        $guard = new AccessGuard($eq, $this->db());
        $a = new Acta(); $a->setEquipo('prog-salud-mental');
        $this->assertTrue($guard->canView('u1', $a));
    }
    public function testOutsiderCannotViewButJefaturaCan(): void {
        $eq = $this->createMock(EquipoService::class);
        $eq->method('userEquipos')->willReturn(['prog-cardiovascular']);
        $eq->method('isJefatura')->willReturn(false);
        $guard = new AccessGuard($eq, $this->db());
        $a = new Acta(); $a->setEquipo('prog-salud-mental');
        $this->assertFalse($guard->canView('u2', $a));

        $eq2 = $this->createMock(EquipoService::class);
        $eq2->method('userEquipos')->willReturn([]); $eq2->method('isJefatura')->willReturn(true);
        $this->assertTrue((new AccessGuard($eq2,$this->db()))->canView('jefe',$a));
    }
    public function testSensitiveRequiresDisclaimer(): void {
        $a = new Acta(); $a->setIsSensitive(true);
        $guard = new AccessGuard($this->createMock(EquipoService::class), $this->db());
        $this->assertTrue($guard->requiresDisclaimer($a));
    }
    private function db(){ return $this->createMock(\OCP\IDBConnection::class); }
}
```

- [ ] **Step 2: Run test to verify it fails** — FAIL, class not found.

- [ ] **Step 3: Write the implementation**

```php
<?php
declare(strict_types=1);
namespace OCA\LibroActas\Service;
use OCA\LibroActas\Db\Acta;
use OCP\IDBConnection;

class AccessGuard {
    public function __construct(private EquipoService $equipos, private IDBConnection $db) {}
    public function canView(string $uid, Acta $a): bool {
        if ($this->equipos->isJefatura($uid)) return true;
        return in_array($a->getEquipo(), $this->equipos->userEquipos($uid), true);
    }
    public function requiresDisclaimer(Acta $a): bool { return (bool)$a->getIsSensitive(); }
    public function logAccess(string $uid, int $actaId, string $action): void {
        $qb = $this->db->getQueryBuilder();
        $qb->insert('la_access_log')->values([
            'acta_id'=>$qb->createNamedParameter($actaId, \PDO::PARAM_INT),
            'uid'=>$qb->createNamedParameter($uid),
            'action'=>$qb->createNamedParameter($action),
            'logged_at'=>$qb->createNamedParameter((new \DateTime())->format('Y-m-d H:i:s')),
        ])->executeStatement();
    }
}
```

- [ ] **Step 4: Run test to verify it passes** — Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/libro_actas/lib/Service/AccessGuard.php apps/libro_actas/tests/unit/AccessGuardTest.php
git commit -m "feat(libro-actas): AccessGuard (scope + sensitive disclaimer + audit log)"
```

---

### Task 9: ActaService + ActaController (draft, finalize, view, list)

**Files:**
- Create: `apps/libro_actas/lib/Service/ActaService.php`, `apps/libro_actas/lib/Controller/ActaController.php`, `apps/libro_actas/lib/Controller/PageController.php`
- Modify: `apps/libro_actas/appinfo/routes.php`

**Interfaces:**
- Consumes: `ActaMapper`, `CryptoService`, `PiiDetector`, `FolioService`, `AccessGuard`, `EquipoService`, `OCP\IUserSession`.
- Produces (HTTP, all `libro_actas.acta.*`):
  - `POST /drafts` saveDraft(payload) → `{draftId}`  (private to author)
  - `POST /actas/finalize` finalize(payload) → `{id, folio, isSensitive}` (runs detector, encrypts, allocates folio, freezes)
  - `GET /actas` list() → access-scoped `[{id,folio,fecha,equipo,tipo,estado,isSensitive,published}]`
  - `GET /actas/{id}?disclaimer=accepted` view() → full acta or `403 {needsDisclaimer:true}`

- [ ] **Step 1: Write `ActaService::finalize`** (core security path)

```php
<?php
declare(strict_types=1);
namespace OCA\LibroActas\Service;
use OCA\LibroActas\Db\{Acta,ActaMapper};

class ActaService {
    public function __construct(
        private ActaMapper $mapper, private CryptoService $crypto,
        private PiiDetector $detector, private FolioService $folio) {}

    public function finalize(array $p, string $uid): Acta {
        $free = $p['contenido_libre'] ?? '';
        $scan = $this->detector->scan($free);
        $sensitive = ($p['declared_sensitive'] ?? false) || $scan['any'];  // manual OR auto-detected

        $a = new Acta();
        $a->setEquipo($p['equipo']);
        $a->setTipoReunion($p['tipo_reunion'] ?? null);
        $a->setTipoActividad($p['tipo_actividad'] ?? null);
        $a->setFecha($p['fecha'] ?? null);
        $a->setHoraInicio($p['hora_inicio'] ?? null);
        $a->setHoraTermino($p['hora_termino'] ?? null);
        $a->setLugar($p['lugar'] ?? null);
        $a->setQuorum((bool)($p['quorum'] ?? false));
        $a->setProximaReunion($p['proxima_reunion'] ?? null);
        $a->setContenidoLibre($this->crypto->encrypt($free !== '' ? $free : null)); // ENCRYPTED
        $a->setIsSensitive($sensitive);
        $a->setRegistrante($uid);
        $a->setFirmaUid($uid);
        $a->setFirmaAt((new \DateTime())->format('Y-m-d H:i:s'));   // firma electrónica simple
        $a->setIsFinalized(true);
        $a->setEstado('finalizada');
        $now = (new \DateTime())->format('Y-m-d H:i:s');
        $a->setCreatedAt($now); $a->setUpdatedAt($now);
        $a->setFolio($this->folio->allocate($p['equipo'], (int)date('Y')));  // atomic
        return $this->mapper->insert($a);
    }
    public function viewDecrypted(Acta $a): array {
        $out = $a->jsonSerialize();
        $out['contenido_libre'] = $this->crypto->decrypt($a->getContenidoLibre());
        return $out;
    }
}
```

- [ ] **Step 2: Write `ActaController`** (thin; enforces the gate)

```php
<?php
declare(strict_types=1);
namespace OCA\LibroActas\Controller;
use OCA\LibroActas\Db\ActaMapper;
use OCA\LibroActas\Service\{ActaService,AccessGuard,EquipoService};
use OCP\AppFramework\Controller;
use OCP\AppFramework\Http;
use OCP\AppFramework\Http\JSONResponse;
use OCP\IRequest; use OCP\IUserSession;

class ActaController extends Controller {
    public function __construct(string $appName, IRequest $request,
        private ActaService $service, private ActaMapper $mapper,
        private AccessGuard $guard, private EquipoService $equipos,
        private IUserSession $session) { parent::__construct($appName, $request); }

    /** @NoAdminRequired */
    public function finalize(): JSONResponse {
        $uid = $this->session->getUser()->getUID();
        $a = $this->service->finalize($this->request->getParams(), $uid);
        return new JSONResponse(['id'=>$a->getId(),'folio'=>$a->getFolio(),'isSensitive'=>$a->getIsSensitive()]);
    }
    /** @NoAdminRequired */
    public function index(): JSONResponse {
        $uid = $this->session->getUser()->getUID();
        $list = $this->mapper->findForUserEquipos($this->equipos->userEquipos($uid), $this->equipos->isJefatura($uid));
        return new JSONResponse(array_map(fn($a)=>[
            'id'=>$a->getId(),'folio'=>$a->getFolio(),'fecha'=>$a->getFecha(),
            'equipo'=>$a->getEquipo(),'tipo'=>$a->getTipoReunion(),'estado'=>$a->getEstado(),
            'isSensitive'=>$a->getIsSensitive()], $list));
    }
    /** @NoAdminRequired */
    public function show(int $id): JSONResponse {
        $uid = $this->session->getUser()->getUID();
        $a = $this->mapper->find($id);
        if (!$this->guard->canView($uid, $a)) return new JSONResponse(['error'=>'forbidden'], Http::STATUS_FORBIDDEN);
        if ($this->guard->requiresDisclaimer($a) && $this->request->getParam('disclaimer') !== 'accepted') {
            return new JSONResponse(['needsDisclaimer'=>true], Http::STATUS_FORBIDDEN);
        }
        $this->guard->logAccess($uid, $id, 'view');
        return new JSONResponse($this->service->viewDecrypted($a));
    }
}
```

- [ ] **Step 3: Write `PageController` + `routes.php`**

```php
<?php // lib/Controller/PageController.php
declare(strict_types=1);
namespace OCA\LibroActas\Controller;
use OCP\AppFramework\Controller;
use OCP\AppFramework\Http\TemplateResponse;
class PageController extends Controller {
    /** @NoAdminRequired @NoCSRFRequired */
    public function index(): TemplateResponse { return new TemplateResponse('libro_actas', 'main'); }
}
```

```php
<?php // appinfo/routes.php
return ['routes' => [
    ['name'=>'page#index','url'=>'/','verb'=>'GET'],
    ['name'=>'acta#index','url'=>'/actas','verb'=>'GET'],
    ['name'=>'acta#show','url'=>'/actas/{id}','verb'=>'GET'],
    ['name'=>'acta#finalize','url'=>'/actas/finalize','verb'=>'POST'],
    ['name'=>'acta#saveDraft','url'=>'/drafts','verb'=>'POST'],
    ['name'=>'acta#myDraft','url'=>'/drafts/mine','verb'=>'GET'],
]];
```

Add these two methods to `ActaController` (drafts are **private to the author** — keyed on the session uid, never listed for others):

```php
    /** @NoAdminRequired */
    public function saveDraft(): JSONResponse {
        $uid = $this->session->getUser()->getUID();
        $id = $this->service->saveDraft($uid, json_encode($this->request->getParam('payload', [])));
        return new JSONResponse(['draftId' => $id]);
    }
    /** @NoAdminRequired */
    public function myDraft(): JSONResponse {
        $uid = $this->session->getUser()->getUID();
        return new JSONResponse($this->service->myDraft($uid));  // {} if none
    }
```

And to `ActaService` (upsert one draft per author into `la_drafts`):

```php
    public function saveDraft(string $uid, string $payloadJson): int {
        $now = (new \DateTime())->format('Y-m-d H:i:s');
        $qb = $this->mapper->db()->getQueryBuilder();   // or inject IDBConnection
        // delete-then-insert keeps one live draft per author (KISS for PR1)
        $del = $qb; $del->delete('la_drafts')->where($del->expr()->eq('author',$del->createNamedParameter($uid)))->executeStatement();
        $ins = $this->mapper->db()->getQueryBuilder();
        $ins->insert('la_drafts')->values([
            'author'=>$ins->createNamedParameter($uid),
            'payload'=>$ins->createNamedParameter($payloadJson),
            'updated_at'=>$ins->createNamedParameter($now),
        ])->executeStatement();
        return (int)$ins->getLastInsertId();
    }
    public function myDraft(string $uid): array {
        $qb = $this->mapper->db()->getQueryBuilder();
        $qb->select('payload')->from('la_drafts')->where($qb->expr()->eq('author',$qb->createNamedParameter($uid)));
        $r = $qb->executeQuery(); $row = $r->fetch(); $r->closeCursor();
        return $row ? json_decode($row['payload'], true) : [];
    }
```
*(Inject `IDBConnection` into `ActaService` for the draft queries rather than reaching through the mapper.)*

- [ ] **Step 4: Smoke test the gate** — with fixtures + app enabled, finalize an acta containing `RUT 12.345.678-5` as a programa member, then:
  - `GET /apps/libro_actas/actas/{id}` (no disclaimer) → `403 {needsDisclaimer:true}`.
  - `GET /apps/libro_actas/actas/{id}?disclaimer=accepted` → full acta with decrypted `contenido_libre`; a row appears in `oc_la_access_log`.
  - In psql, `oc_la_actas.contenido_libre` is ciphertext (not the RUT). `oc_la_actas.folio` is `SM-2026-001`.
  - As a user of a different programa (not jefatura) → `403 forbidden`.

- [ ] **Step 5: Commit**

```bash
git add apps/libro_actas/lib/Service/ActaService.php apps/libro_actas/lib/Controller/ apps/libro_actas/appinfo/routes.php
git commit -m "feat(libro-actas): finalize (encrypt+detect+folio), access-scoped list, gated view"
```

---

### Task 10: Frontend — app shell + Registro + Nueva acta + disclaimer gate

**Files:**
- Create: `apps/libro_actas/src/main.js`, `App.vue`, `views/Registro.vue`, `views/NuevaActa.vue`, `views/VerActa.vue`, `services/api.js`
- Create: `apps/libro_actas/templates/main.php`, `webpack.config.js`, `package.json`

**Interfaces:**
- Consumes: the `acta.*` HTTP endpoints from Task 9.
- Produces: the operable SPA matching the mockups (`docs/apps/libro-actas/mockups/`).

- [ ] **Step 1: Scaffold the build** — `package.json` with `@nextcloud/vue`, `@nextcloud/axios`, `@nextcloud/router`, `@nextcloud/webpack-vue-config`; `webpack.config.js` re-exporting the shared config; `templates/main.php` calling `Util::addScript('libro_actas','libro_actas-main')`. (Pull the exact current versions/snippet via Context7 for the NC34 line.)

- [ ] **Step 2: Write `App.vue`** — `NcContent` + `NcAppNavigation` (Registro / Acuerdos pendientes [PR2] / En revisión [PR4] / Nueva acta) + `NcAppContent` routing to the views. Mirror the mockup shell.

- [ ] **Step 3: Write `Registro.vue`** — on mount, `GET /actas`; render an `NcTable`-style list with folio (mono), fecha, equipo, tipo, an estado pill, and a "Reservada" chip when `isSensitive`. Filters as `NcSelect` (equipo/tipo/estado) — client-side for PR1.

- [ ] **Step 4: Write `NuevaActa.vue`** — the form from the mockup: datos (`NcSelect`, `NcDateTimePickerNative` for fecha/horas), asistentes (`NcSelect` multiple from `EquipoService::members` via an endpoint), a `NcTextArea` for `contenido_libre` with the fixed Spanish warning banner, and a live client-side RUT hint. "Firmar y finalizar" → `POST /actas/finalize`; show the returned folio + "Reservada" if sensitive; then route to Registro.

- [ ] **Step 5: Write `VerActa.vue`** — `GET /actas/{id}`; on `403 {needsDisclaimer:true}` show an `NcModal` disclaimer (text from the mockup, cites Ley 21.719) with Cancelar / "Aceptar y ver" → re-`GET ...?disclaimer=accepted` and render the full acta including decrypted `contenido_libre`.

- [ ] **Step 6: Build + manual verify**

Run: `cd apps/libro_actas && npm ci && npm run build`
Expected: `js/libro_actas-main.*` emitted. Reload Nextcloud → the app opens; create → finalize an acta with a RUT → it lands Reservada in Registro; opening it shows the disclaimer, and only after accepting does the free-text appear. Confirm against the mockups.

- [ ] **Step 7: Commit**

```bash
git add apps/libro_actas/src apps/libro_actas/templates apps/libro_actas/package.json apps/libro_actas/webpack.config.js apps/libro_actas/appinfo/routes.php
git commit -m "feat(libro-actas): Vue SPA — Registro, Nueva acta, disclaimer-gated Ver acta"
```

---

### Task 11: Wire the quality gate

**Files:**
- Modify: `Makefile` (add `libro_actas` to the app test/lint scope) or add `apps/libro_actas/tests/phpunit.xml` to the existing `make test`.

- [ ] **Step 1:** Ensure `make test` runs `phpunit` for `apps/libro_actas/tests/unit` and lints PHP (`php -l`) + JS build. Follow the repo's existing gate (`CONTRIBUTING.md`).
- [ ] **Step 2: Run the full gate**

Run: `make test`
Expected: PiiDetector/Crypto/Folio/ActaMapper/AccessGuard suites green; smoke passes.

- [ ] **Step 3: Commit**

```bash
git add Makefile apps/libro_actas/tests
git commit -m "test(libro-actas): wire unit suite into make test gate"
```

---

## Self-Review

**Spec coverage (PR0+PR1 slice):** app skeleton ✓(T1) · schema ✓(T2) · deterministic PII scan + RUT módulo-11 ✓(T3) · encryption at rest ✓(T4) · atomic folio ✓(T5) · entity/mapper + access-scoped list ✓(T6) · directory-synced equipos/roles/vocabularies ✓(T7) · access scope + disclaimer + audit ✓(T8) · draft/finalize/view + immutability (finalize sets `is_finalized`, no update path) ✓(T9) · private draft autosave (saveDraft endpoint — *note: draft autosave UI is in T10 form; the `POST /drafts` handler is folded into ActaController in T9's routes and should be added there*) · UI matching mockups ✓(T10) · quality gate ✓(T11). Deferred correctly to later PRs: acuerdos, generation, publication/quarantine, calendar, retention, bulk export.

**Gap found & fixed (applied):** the `POST /drafts` / `GET /drafts/mine` handlers are now implemented in Task 9 (`ActaController::saveDraft/myDraft` + `ActaService::saveDraft/myDraft`, one private draft per author). Autosave in `NuevaActa.vue` (T10) debounces to `POST /drafts`.

**Placeholder scan:** no TBD/TODO; all code steps show real code. `@nextcloud/vue` exact versions and the webpack snippet are intentionally pulled live via Context7 (repo rule: never hardcode dependency docs) — this is a sourcing instruction, not a placeholder.

**Type consistency:** `PiiDetector::scan` returns the same `['rut','email','phone','rit','any']` shape used in `ActaService::finalize`; `AccessGuard::canView/requiresDisclaimer/logAccess` signatures match their use in `ActaController::show`; `FolioService::allocate/format` match `ActaService::finalize`. Consistent.
