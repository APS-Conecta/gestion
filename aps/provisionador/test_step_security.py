# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Sesiones y registro de auditoría», the security step: sessions on shared clinical workstations, and the
audit log."""

from test_provisionador import Installing

SECURITY = "Sesiones y registro de auditoría"


class Security(Installing):
    def test_sessions_end_after_15_idle_minutes_without_remember_me_and_the_audit_log_records(self):
        self.install_the_suite()
        self.eventually(self.listo, "«Listo»")
        nextcloud = self.suite.nextcloud
        self.assertEqual({key: nextcloud.system.get(key) for key in ("remember_login_cookie_lifetime",
                                                                      "session_lifetime", "session_keepalive")},
                         {"remember_login_cookie_lifetime": 0, "session_lifetime": 900, "session_keepalive": False})
        self.assertEqual(nextcloud.apps["admin_audit"]["enabled"], "yes")

    def test_without_the_audit_app_the_step_fails_loudly(self):
        del self.suite.nextcloud.apps["admin_audit"]
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.assertEqual(self.steps()[SECURITY], ("failed", "Nextcloud no completó «occ app:enable admin_audit». "
                                                            "Presione «Reintentar»; si vuelve a ocurrir, contacte a "
                                                            "APS Conecta."))
