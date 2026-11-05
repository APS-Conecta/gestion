# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Office con Euro-Office», the Office step: Nextcloud's Office entry, our Office defaults and Euro-Office
answering Nextcloud."""

import time
from unittest import mock

import steps
from test_provisionador import Installing

OFFICE = "Office con Euro-Office"
SILENT = ("Euro-Office no responde a Nextcloud. Presione «Reintentar» en unos minutos; si vuelve a ocurrir, contacte a "
          "APS Conecta.")
ODF = '{"odt":true,"ods":true,"odp":true}'


class Office(Installing):
    def test_odf_documents_open_and_edit_in_euro_office_in_its_light_theme_each_in_a_tab_of_its_own(self):
        self.install_the_suite()
        self.eventually(self.listo, "«Listo»")
        expected = {"defFormats": ODF, "editFormats": ODF, "customizationTheme": "default-light", "sameTab": "false"}
        connector = self.suite.nextcloud.apps.get("eurooffice", {})
        self.assertEqual({key: connector.get(key) for key in expected}, expected)

    def test_listo_waits_until_euro_office_answers_nextcloud(self):
        self.suite.nextcloud.editor = False  # Euro-Office's document server does not answer Nextcloud yet
        self.install_the_suite()
        self.eventually(lambda: self.listo() or self.steps().get(OFFICE) == ("running", None),
                        "the Office step waiting for Euro-Office")
        time.sleep(0.3)  # many looks at Euro-Office
        self.assertFalse(self.listo(), "«Listo» came while Euro-Office did not answer Nextcloud")
        self.suite.nextcloud.editor = True
        self.eventually(self.listo, "«Listo»")

    def test_a_euro_office_that_never_answers_fails_the_step_until_reintentar_finds_it_answering(self):
        self.enterContext(mock.patch.object(steps.office, "WAIT", 0.3))
        self.suite.nextcloud.editor = False
        self.install_the_suite()
        self.eventually(lambda: self.listo() or self.status() == "failed", "a failed install")
        self.assertFalse(self.listo(), "«Listo» came while Euro-Office did not answer Nextcloud")
        self.assertEqual(self.steps()[OFFICE], ("failed", SILENT))
        self.suite.nextcloud.editor = True
        self.assertEqual(self.install()[0], 202)  # «Reintentar»
        self.eventually(self.listo, "«Listo»")

    def test_a_nextcloud_without_its_office_entry_fails_the_step_with_its_reason(self):
        del self.suite.nextcloud.apps["office"]  # the app of Nextcloud's own Office entry, which Nextcloud ships on
        self.install_the_suite()
        self.eventually(lambda: self.listo() or self.status() == "failed", "a failed install")
        self.assertFalse(self.listo(), "«Listo» came without Nextcloud's Office entry")
        self.assertEqual(self.steps()[OFFICE], ("failed", "Nextcloud no completó «occ app:enable office». Presione "
                                                          "«Reintentar»; si vuelve a ocurrir, contacte a APS Conecta."))

    def test_the_end_of_install_check_turns_the_step_red_again_when_nextcloud_lost_a_default(self):
        del self.suite.nextcloud.apps["admin_audit"]  # the security step fails, so the end-of-install check waits
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.suite.nextcloud.apps["eurooffice"]["sameTab"] = "true"  # meanwhile, documents open in the entry's tab
        self.suite.nextcloud.apps["admin_audit"] = {"enabled": "no"}
        self.install()  # «Reintentar»
        self.eventually(lambda: self.listo() or self.status() == "failed", "a failed end-of-install check")
        self.assertFalse(self.listo(), "«Listo» came while Nextcloud did not hold the Office defaults")
        self.assertEqual(self.steps()[OFFICE], ("failed", "Nextcloud no conserva estos ajustes: eurooffice.sameTab. "
                                                          "Presione «Reintentar»; si vuelve a ocurrir, contacte a APS "
                                                          "Conecta."))
