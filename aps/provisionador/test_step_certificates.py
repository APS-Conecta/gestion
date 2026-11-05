# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Certificados de confianza», the certificates step: the CAs that Nextcloud's own requests trust beside the
ones it ships."""

from test_provisionador import Installing

CERTIFICATES = "Certificados de confianza"
ISP = "www.ispch.gob.cl"
ISP_UNTRUSTED = ("No se pudo obtener ni verificar el certificado intermedio de www.ispch.gob.cl, así que Nextcloud no "
                 "podrá descargar las alertas sanitarias del ISP. La instalación continúa sin él; contacte a APS "
                 "Conecta.")


class Certificates(Installing):
    def test_nextcloud_trusts_the_isps_issuer_and_the_cas_of_aios_folder_a_test_builds_staging_roots(self):
        self.suite.nextcloud.cacerts = ["ca.crt"]  # the one file of a test build's Bootstrap
        self.install_the_suite()
        self.eventually(self.listo, "«Listo»")
        self.assertEqual((self.suite.nextcloud.trusted, self.suite.nextcloud.issuers), ({"ca.crt"}, {ISP}))

    def test_an_isp_that_cannot_be_reached_only_warns_so_listo_comes_and_the_log_keeps_the_warning(self):
        self.suite.nextcloud.unreachable = {ISP}
        self.install_the_suite()
        self.eventually(self.listo, "«Listo»")
        self.assertIn(ISP_UNTRUSTED, self.log.getvalue())

    def test_the_progress_shows_the_warning_beside_the_green_step(self):
        self.suite.nextcloud.unreachable = {ISP}
        del self.suite.nextcloud.apps["admin_audit"]  # another step fails, so the progress stays
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.assertEqual(self.steps()[CERTIFICATES], ("green", ISP_UNTRUSTED))
