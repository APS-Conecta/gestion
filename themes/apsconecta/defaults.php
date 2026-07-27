<?php
/**
 * APS Conecta Gestión — tema de servidor de Nextcloud.
 *
 * Coloca esta carpeta en  nextcloud/themes/apsconecta/  y activa el tema en
 * config/config.php:   'theme' => 'apsconecta',
 * Reinicia el contenedor / PHP-FPM después de cualquier cambio aquí (opcache).
 *
 * Solo capa blanda: NO edites el core ni apps de terceros (AGPL §13).
 *
 * ALCANCE: la identidad (nombre/eslogan/URL/color) la fija la app Theming vía
 * occ-theming.sh — esa es la fuente de verdad y se expone a los clientes por
 * la capabilities API. Los métodos de abajo son un FALLBACK del tema; el único
 * valor que el panel NO puede fijar es getiTunesAppId() (neutraliza el banner
 * "Nextcloud — Abrir" en iOS). No dupliques aquí lo que ya fija occ.
 */
class OC_Theme {
	public function getName() {
		return 'APS Conecta Gestión';
	}

	public function getTitle() {
		return 'APS Conecta Gestión';
	}

	public function getHTMLName() {
		return 'APS Conecta Gestión';
	}

	public function getBaseUrl() {
		return 'https://apsconecta.cl';
	}

	public function getSlogan() {
		return 'La salud primaria que compartimos es la que mejora';
	}

	public function getShortFooter() {
		return '<a href="https://apsconecta.cl" target="_blank" rel="noreferrer noopener">APS Conecta Gestión</a>'
			. ' · La salud primaria que compartimos es la que mejora';
	}

	/**
	 * Neutraliza el banner iOS "Nextcloud — Abrir".
	 * Por defecto getiTunesAppId() devuelve 1125420102 (la app oficial de
	 * Nextcloud). Devolver cadena vacía elimina el meta apple-itunes-app.
	 */
	public function getiTunesAppId() {
		return '';
	}
}
