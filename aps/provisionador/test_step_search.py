# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Búsqueda de texto completo», the search step: vanilla's full-text search, which AIO's start sets up, with
our files provider, which the apps step installs."""

import steps
from test_provisionador import Installing

SEARCH = "Búsqueda de texto completo"
OFF = ("La búsqueda de texto completo no quedó activa en Nextcloud: AIO la desactiva cuando su contenedor no responde "
       "a tiempo al iniciarse Nextcloud. Contacte a APS Conecta.")


class Search(Installing):
    def test_a_search_aio_left_off_at_nextclouds_start_fails_the_step_with_its_reason(self):
        self.suite.nextcloud.late = {"isFulltextsearchEnabled"}  # Elasticsearch does not answer Nextcloud's start
        self.install_the_suite()
        self.eventually(lambda: self.listo() or self.status() == "failed", "a failed install")
        self.assertFalse(self.listo(), "«Listo» came without full-text search")
        self.assertEqual(self.steps()[SEARCH], ("failed", OFF))

    def test_the_step_waits_for_our_files_provider_from_the_apps_step(self):
        fork = next(app for app in steps.apps.MANIFEST if app["id"] == "files_fulltextsearch")
        asset = (fork["repo"], fork["pin"], "files_fulltextsearch.tar.gz")
        release = self.suite.releases.pop(asset)  # GitHub fails its download
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.assertEqual(self.steps()[SEARCH], ("waiting", "Espera a que se complete «Aplicaciones»."))
        self.suite.releases[asset] = release
        self.assertEqual(self.install()[0], 202)  # «Reintentar»
        self.eventually(self.listo, "«Listo»")

    def test_the_end_of_install_check_turns_the_step_red_again_when_nextcloud_left_search_off(self):
        del self.suite.nextcloud.apps["admin_audit"]  # the security step fails, so the end-of-install check waits
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        # Meanwhile Nextcloud restarted while Elasticsearch did not answer: vanilla's start turned the three apps off.
        for app in ("fulltextsearch", "fulltextsearch_elasticsearch", "files_fulltextsearch"):
            self.suite.nextcloud.apps[app]["enabled"] = "no"
        self.suite.nextcloud.apps["admin_audit"] = {"enabled": "no"}
        self.install()  # «Reintentar»
        self.eventually(lambda: self.listo() or self.status() == "failed", "a failed end-of-install check")
        self.assertFalse(self.listo(), "«Listo» came without full-text search")
        self.assertEqual(self.steps()[SEARCH], ("failed", OFF))
