# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Dirección» with the establishment's own domain instead of the APS name: vanilla's domain check, the
settings AIO keeps, Talk's port notice and the switch between the two."""

from test_provisionador import NAME, ProvisionadorTest, claimed

DOMAIN = "gestion.cesfam.example"  # a fixture domain: no real establishment is named here
# AIO's vanilla setup for an own domain, as AIO's settings file keeps it: no community container, Apache on 443 on every
# address of the host, Talk on 3478 at the domain, and none of an APS name's secrets.
VANILLA = {"domain": DOMAIN, "aio_community_containers": "", "apache_ip_binding": "", "apache_port": "443",
           "turn_domain": "", "talk_port": "3478", "secrets": {}}
# Vanilla's domain check refusing a domain, in AIO's own words (php/src/Data/ConfigurationManager.php, setDomain).
REFUSALS = [
    "¡El dominio debe contener al menos un punto!",
    "¡El DNS de este dominio no está configurado o el dominio no es válido! (Se encontró configurado en '')",
    "Parece que la dirección IP del dominio es una dirección interna o reservada, lo que la validación del dominio no "
    "admite. (Se encontró configurada en '192.168.1.10'). ¡Configure una dirección IP pública para que la validación "
    "del dominio funcione u omita la validación del dominio!",
]


class OwnDomain(ProvisionadorTest):
    def use(self, browser):
        """«Centro» confirmed, then the own domain typed at «Dirección»."""
        self.assertEqual(browser.request("POST", "/api/centre", {"code": "999001"})[0], 200)
        return browser.request("POST", "/api/address", {"domain": DOMAIN})

    def test_a_domain_that_passes_vanillas_check_sets_aio_up_the_vanilla_way_without_our_caddy(self):
        status, body = self.use(self.operator())
        self.assertEqual((status, body["address"]["name"]), (200, DOMAIN), body)
        self.assertEqual(self.suite.aio, VANILLA)
        self.assertEqual(self.suite.claims, [], "no APS name is claimed")

    def test_each_refusal_of_vanillas_check_shows_its_reason_with_reintentar_which_checks_again(self):
        browser = self.operator()
        self.assertEqual(browser.request("POST", "/api/centre", {"code": "999001"})[0], 200)
        for reason in REFUSALS:
            with self.subTest(reason):
                self.suite.refused[DOMAIN] = reason
                status, body = browser.request("POST", "/api/address", {"domain": DOMAIN})
                self.assertEqual(status, 409, body)
                self.assertIn(reason, body["error"])
                self.assertIn("«Reintentar»", body["error"])
                self.assertIsNone(browser.get("/api/state")[1]["address"])
                self.assertNotIn("domain", self.suite.aio, "AIO keeps no domain the check refused")
        del self.suite.refused[DOMAIN]  # the operator fixed what the check found
        status, body = browser.request("POST", "/api/address", {"domain": DOMAIN})  # «Reintentar»
        self.assertEqual((status, body["address"]["name"]), (200, DOMAIN), body)
        self.assertEqual(self.suite.aio, VANILLA)

    def test_a_domain_that_is_not_text_is_refused_and_changes_nothing(self):
        browser = self.operator()
        claimed(browser)
        for domain in (None, 42, [DOMAIN]):
            with self.subTest(domain):
                status, body = browser.request("POST", "/api/address", {"domain": domain})
                self.assertEqual(status, 400, body)
                self.assertEqual(browser.get("/api/state")[1]["address"]["name"], NAME)
                self.assertEqual(self.suite.aio["domain"], NAME)

    def test_before_instalar_the_page_tells_that_talk_also_needs_port_3478_over_tcp_and_udp(self):
        browser = self.operator()
        self.assertEqual(self.use(browser)[0], 200)
        state = browser.get("/api/state")[1]
        self.assertIsNone(state["install"], "before «Instalar»")
        self.assertIsNotNone(state["review"], "«Revisar» follows")
        notice = state["address"].get("notice", "")
        for words in ("Talk", "3478", "TCP", "UDP"):
            self.assertIn(words, notice)

    def test_an_own_domain_after_the_aps_name_frees_the_name_with_its_credential_and_keeps_none_of_its_settings(self):
        browser = self.operator()
        claimed(browser)
        password = self.suite.credentials[NAME]["password"]
        status, body = browser.request("POST", "/api/address", {"domain": DOMAIN})
        self.assertEqual((status, body["address"]["name"]), (200, DOMAIN), body)
        self.assertEqual(self.suite.credentials, {}, "the name service freed the name for its own credential")
        self.assertEqual(self.suite.aio, VANILLA, "AIO keeps none of the APS name's settings")
        kept = [f.name for f in self.state.iterdir() if password in f.read_text(encoding="utf-8")]
        self.assertEqual(kept, [], "no file keeps the name's credential")

    def test_an_outage_while_the_aps_name_is_freed_comes_with_reintentar_which_frees_it(self):
        browser = self.operator()
        claimed(browser)
        self.suite.outage = True
        status, body = browser.request("POST", "/api/address", {"domain": DOMAIN})
        self.assertEqual(status, 503, body)
        self.assertIn("servicio de nombres de APS Conecta", body["error"])
        self.assertIn("«Reintentar»", body["error"])
        self.assertIsNone(browser.get("/api/state")[1]["address"])
        self.suite.outage = False
        status, body = browser.request("POST", "/api/address", {"domain": DOMAIN})  # «Reintentar»
        self.assertEqual((status, body["address"]["name"]), (200, DOMAIN), body)
        self.assertEqual(self.suite.credentials, {})

    def test_a_refused_domain_keeps_the_aps_name_so_that_it_comes_back_without_a_new_claim(self):
        browser = self.operator()
        claimed(browser)
        self.suite.refused[DOMAIN] = REFUSALS[1]
        self.assertEqual(browser.request("POST", "/api/address", {"domain": DOMAIN})[0], 409)
        self.assertIn(NAME, self.suite.credentials, "the name stays this installation's")
        status, body = browser.request("POST", "/api/address", {})
        self.assertEqual((status, body["address"]["name"]), (200, NAME), body)
        self.assertEqual(self.suite.claims, ["999001"], "a name is claimed once")

    def test_the_aps_name_after_an_own_domain_keeps_none_of_its_settings(self):
        browser = self.operator()
        self.assertEqual(self.use(browser)[0], 200)
        status, body = browser.request("POST", "/api/address", {})
        self.assertEqual(status, 200, body)
        self.assertEqual(body["address"], {"name": NAME, "published": False, "opened": False},
                         "the APS name opens no port: no notice")
        credential = self.suite.credentials[NAME]
        self.assertEqual(self.suite.aio, {
            "domain": NAME, "aio_community_containers": "caddy", "apache_port": "11000",
            "apache_ip_binding": "@INTERNAL", "turn_domain": NAME, "talk_port": "443",
            "secrets": {"ACMEDNS_USERNAME": "999001", "ACMEDNS_PASSWORD": credential["password"],
                        "ACMEDNS_SUBDOMAIN": "centro-999001", "ACMEDNS_SERVER_URL": "https://nombres.example"}})
