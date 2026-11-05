# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Idioma y formato regional», the locale step."""

from test_provisionador import Installing


class Locale(Installing):
    def test_everyone_gets_spanish_with_chiles_formats_whatever_the_browser_asks_for(self):
        self.install_the_suite()
        self.eventually(self.listo, "«Listo»")
        self.assertEqual({key: self.suite.nextcloud.system.get(key) for key in (
            "default_language", "force_language", "default_locale", "default_phone_region")},
            {"default_language": "es", "force_language": "es", "default_locale": "es_CL", "default_phone_region": "CL"})
