<?php

declare(strict_types=1);

/**
 * APS Conecta Gestión — identity for the screens ThemingDefaults never serves.
 *
 * WHY THIS FILE EXISTS AGAIN. ADR-0001 deleted it and said "No defaults.php": every value here also
 * lives in the theming app, config-as-code, and a second copy is a second place to drift. That held
 * for as long as the theming app was always the thing answering. It is not:
 *
 *   lib/private/Server.php:1052-1056 hands out ThemingDefaults only when FOUR conditions hold —
 *   the class autoloads (it does not when the app is disabled or the instance is in maintenance),
 *   `installed` is true, theming is enabled for anyone, AND the request host is a TRUSTED DOMAIN.
 *   Otherwise it returns a raw \OC_Defaults, whose identity strings are hardcoded literals with no
 *   system key behind them. Measured on this instance: the untrusted-domain screen serves
 *   theme-color #00679e and an initial state reading name/productName/title = "Nextcloud".
 *
 * Two of the screens in that class are reached by definition rather than by accident — the
 * untrusted-domain warning fails the trusted-host test as its whole purpose, and the three setup
 * screens run with `installed` false. No amount of CSS reaches those strings.
 *
 * Separately, lib/base.php:387-395 builds `new \OC_Defaults()` DIRECTLY for the two upgrade
 * screens' productName, bypassing the container and therefore ThemingDefaults even on a healthy
 * trusted host. Only this file can answer there.
 *
 * WHY THIS CANNOT LEAK ANYWHERE ELSE. \OC_Defaults is constructed directly in exactly two places
 * (lib/base.php:390 and lib/private/Server.php:1102) and ThemingDefaults overrides every method
 * defined below, so on a framework-rendered screen this file is unreachable. OC_Defaults consults
 * it method by method (`method_exists`), so anything NOT defined here keeps upstream's value.
 *
 * DELIBERATELY NOT OVERRIDDEN: getDocBaseUrl and the sync-client URLs. They point at real
 * destinations — documentation that exists and clients that can actually be installed — and
 * renaming them would ship a lie. That is the vendor-reference exemption in CONTEXT.md, not an
 * oversight. The iTunes banner is already gone by another route: 15-branding.sh writes
 * customclient_ios_appid "" and OC_Defaults reads that system key.
 *
 * getBaseUrl IS overridden, and the distinction is the whole of the exemption rule. A doc link
 * reading "documentación" and pointing at docs.nextcloud.com NAMES a real external system, which is
 * what makes it true. getBaseUrl is different: getShortFooter() wraps getEntity() in it, so leaving
 * it upstream renders `<a href="https://nextcloud.com">APS Conecta Gestión</a>` — our name on the
 * vendor's homepage. That is not a vendor reference, it is a mislabelled outbound vendor link, and
 * it failed the third predicate of "branded". Observed on the untrusted-domain screen.
 *
 * COST, and it is the reason ADR-0001 dropped this file: PHP caches it in opcache, so editing it
 * needs a container restart. Static and committed, so that is an install-time cost, never a
 * runtime one — but it is why the identity below must stay the PRODUCT's. A clinic name here would
 * make the theme per-install and reintroduce a restart on every seed. Values are duplicated from
 * provisioning/phases/15-branding.sh, which stays the source of truth; scripts/test.sh asserts the
 * two agree.
 *
 * Record: docs/adr/0004-branding-the-legacy-render-path.md
 */
class OC_Theme {
	/** Short name, used when referring to the software. Also what lib/base.php's getProductName()
	 *  reads for the two upgrade screens. */
	public function getName(): string {
		return 'APS Conecta Gestión';
	}

	/** Longer name, for titles — the guest layout puts this in <title>. */
	public function getTitle(): string {
		return 'APS Conecta Gestión';
	}

	/** Organisation, used in footers and copyright notices. */
	public function getEntity(): string {
		return 'APS Conecta Gestión';
	}

	public function getProductName(): string {
		return 'APS Conecta Gestión';
	}

	public function getSlogan(?string $lang = null): string {
		return 'La salud primaria que compartimos es la que mejora';
	}

	/** Where getShortFooter() sends the entity link. Same value as theming's `url` key. */
	public function getBaseUrl(): string {
		return 'https://apsconecta.cl';
	}

	/** Read by the guest layout for <meta name="theme-color"> and the mask-icon colour — both of
	 *  which rendered as #00679e on the untrusted-domain screen before this file existed. */
	public function getColorPrimary(): string {
		return '#7f21fe';
	}

	/** Must stay the dominant tone of background.svg: Nextcloud derives the plain-text colour from
	 *  it, and a bright value here computes BLACK text over the violet backdrop. Same trap
	 *  15-branding.sh documents for the theming key. */
	public function getColorBackground(): string {
		return '#5315a8';
	}
}
