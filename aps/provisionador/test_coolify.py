# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Dirección» on a Coolify server, where the suite runs as a Coolify resource behind Coolify's proxy: AIO's
Traefik settings, which the admin pastes once into Coolify's proxy configuration and the Provisionador checks first,
and the route from the address to AIO's Apache, which it writes into Coolify's dynamic folder. A fake Coolify folder
and a fake proxy stand for Coolify's."""

import json
import tempfile
from pathlib import Path
from unittest import mock

import provisionador
import steps
from suite import FakeSuite
from test_provisionador import NAME, ProvisionadorTest, printed

PUBLIC = "203.0.113.10"  # TEST-NET-3: the server's public address, where the internet reaches it
DOMAIN = "gestion.cesfam.example"  # a fixture domain: no real establishment is named here
# Coolify's own proxy, as Coolify 4.6.0 starts it (bootstrap/helpers/proxy.php, generateDefaultProxyConfiguration).
COOLIFY_PROXY = [
    "--ping=true", "--ping.entrypoint=http", "--api.dashboard=true", "--entrypoints.http.address=:80",
    "--entrypoints.https.address=:443", "--entrypoints.http.http.encodequerysemicolons=true",
    "--entryPoints.http.http2.maxConcurrentStreams=250", "--entrypoints.https.http.encodequerysemicolons=true",
    "--entryPoints.https.http2.maxConcurrentStreams=250", "--entrypoints.https.http3",
    "--providers.file.directory=/traefik/dynamic/", "--providers.file.watch=true",
    "--certificatesresolvers.letsencrypt.acme.httpchallenge=true",
    "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=http",
    "--certificatesresolvers.letsencrypt.acme.storage=/traefik/acme.json", "--api.insecure=false",
    "--providers.docker=true", "--providers.docker.exposedbydefault=false",
]
# AIO's Traefik settings (reverse-proxy.md, «Traefik 3»), on Coolify's https entry point: the read timeout just above
# Nextcloud's own 3600 seconds, and the encoded characters Nextcloud's paths carry.
SETTINGS = [
    "--entrypoints.https.transport.respondingTimeouts.readTimeout=3610s",
    "--entrypoints.https.http.encodedCharacters.allowEncodedSlash=true",
    "--entrypoints.https.http.encodedCharacters.allowEncodedQuestionMark=true",
    "--entrypoints.https.http.encodedCharacters.allowEncodedPercent=true",
]
# The route for the name, as AIO's «Traefik 3» sample (reverse-proxy.md) declares it: the name on Coolify's https entry
# point, with Coolify's certificate resolver, to AIO's Apache on its reverse-proxy port, which AIO joins to Coolify's
# network, through AIO's headers; and on the http entry point, a redirect to https.
ROUTE = {"http": {
    "routers": {
        "nextcloud-aio": {"rule": f"Host(`{NAME}`)", "entryPoints": ["https"], "service": "nextcloud-aio",
                          "middlewares": ["nextcloud-aio-headers"], "tls": {"certResolver": "letsencrypt"}},
        "nextcloud-aio-http": {"rule": f"Host(`{NAME}`)", "entryPoints": ["http"], "service": "nextcloud-aio",
                               "middlewares": ["nextcloud-aio-https"]},
    },
    "services": {"nextcloud-aio": {"loadBalancer": {"servers": [{"url": "http://nextcloud-aio-apache:11000"}]}}},
    "middlewares": {
        "nextcloud-aio-headers": {"headers": {"hostsProxyHeaders": ["X-Forwarded-Host"],
                                              "referrerPolicy": "same-origin",
                                              "customRequestHeaders": {"X-Forwarded-Proto": "https"}}},
        "nextcloud-aio-https": {"redirectScheme": {"scheme": "https"}},
    },
}}


class Coolify(ProvisionadorTest):
    ADDRESS = f"{PUBLIC}:8443"  # AIO's interface on the free host port the Coolify compose file publishes

    def setUp(self):
        super().setUp()
        self.suite.dynamic = Path(self.enterContext(tempfile.TemporaryDirectory()))  # Coolify's dynamic proxy folder
        self.suite.traefik = list(COOLIFY_PROXY)
        self.enterContext(mock.patch.object(self.suite, "published", side_effect=self.nameservers))

    def nameservers(self, name, address):
        """The zone's nameservers, which publish what the name service holds by the time «Dirección» asks them."""
        self.suite.propagate()
        return FakeSuite.published(self.suite, name, address)

    def direccion(self, browser, body=None):
        """«Centro» confirmed, then «Dirección»."""
        self.assertEqual(browser.request("POST", "/api/centre", {"code": "999001"})[0], 200)
        return browser.request("POST", "/api/address", body or {})

    def test_direccion_shows_aios_traefik_settings_and_goes_on_only_once_coolifys_proxy_runs_with_them(self):
        browser = self.operator()
        status, body = self.direccion(browser)
        self.assertEqual(status, 409, body)
        self.assertEqual(body["settings"], SETTINGS)
        self.assertIn("«Reintentar»", body["error"])
        self.assertEqual((self.suite.claims, list(self.suite.dynamic.iterdir()), self.suite.aio), ([], [], {}),
                         "nothing is claimed, routed or set up before the proxy runs with them")
        self.suite.traefik += SETTINGS  # the admin pasted them into Coolify's proxy configuration and restarted it
        status, body = browser.request("POST", "/api/address", {})  # «Reintentar»
        self.assertEqual((status, body["address"]["name"]), (200, NAME), body)

    def test_settings_pasted_in_another_case_count_as_traefik_reads_its_flags_whatever_their_case(self):
        self.suite.traefik += [setting.replace("entrypoints", "entryPoints") for setting in SETTINGS]
        self.assertEqual(self.direccion(self.operator())[0], 200)

    def test_a_proxy_that_cannot_be_read_comes_with_reintentar_and_changes_nothing(self):
        self.suite.traefik = None  # no coolify-proxy container: the proxy is stopped, or it is not Traefik
        status, body = self.direccion(self.operator())
        self.assertEqual(status, 503, body)
        self.assertIn("«Reintentar»", body["error"])
        self.assertEqual((self.suite.claims, list(self.suite.dynamic.iterdir()), self.suite.aio), ([], [], {}))

    def test_direccion_routes_the_name_only_once_its_nameservers_publish_it_and_comes_with_reintentar_until_then(self):
        self.suite.traefik += SETTINGS
        self.enterContext(mock.patch.object(provisionador, "PUBLISHING", 0.05))
        self.enterContext(mock.patch.object(steps, "POLL", 0.01))
        browser = self.operator()
        with mock.patch.object(self.suite, "published", return_value=False):  # the zone's nameservers lag
            status, body = self.direccion(browser)
        self.assertEqual(status, 503, body)
        self.assertIn("«Reintentar»", body["error"])
        self.assertEqual(list(self.suite.dynamic.iterdir()), [],
                         "no route yet: Traefik's challenge, like the suite's own calls, would ask a resolver too early")
        self.assertIsNone(browser.get("/api/state")[1]["address"])
        status, body = browser.request("POST", "/api/address", {})  # «Reintentar», once they publish it
        self.assertEqual((status, body["address"]["published"]), (200, True), body)
        self.assertEqual(self.suite.claims, ["999001"], "the name is claimed once")
        self.assertEqual(self.route(), ROUTE)

    def test_the_route_from_the_name_to_aios_apache_goes_into_coolifys_dynamic_folder(self):
        self.suite.traefik += SETTINGS
        self.assertEqual(self.direccion(self.operator())[0], 200)
        self.assertEqual([path.name for path in self.suite.dynamic.iterdir()], ["nextcloud-aio.yaml"])
        # JSON is YAML too, which Traefik's file provider reads.
        self.assertEqual(json.loads((self.suite.dynamic / "nextcloud-aio.yaml").read_text(encoding="utf-8")), ROUTE)

    def test_aio_serves_the_name_behind_coolifys_proxy_the_vanilla_way_and_talk_needs_port_3478(self):
        self.suite.traefik += SETTINGS
        browser = self.operator()
        self.assertEqual(self.direccion(browser)[0], 200)
        # As for an own domain: no community container, Apache and Talk on AIO's own values, none of the name's
        # acme-dns secrets; the compose file's reverse-proxy settings come from the mastercontainer's environment.
        self.assertEqual(self.suite.aio, {"domain": NAME, "aio_community_containers": "", "apache_ip_binding": "",
                                          "apache_port": "443", "turn_domain": "", "talk_port": "3478", "secrets": {}})
        state = browser.get("/api/state")[1]
        self.assertIsNotNone(state["review"], "«Revisar» follows")
        for words in ("Talk", "3478", "TCP", "UDP"):
            self.assertIn(words, state["address"].get("notice", ""))

    def test_the_name_points_at_the_address_the_internet_reaches_the_interface_at_and_the_updater_keeps_it(self):
        self.suite.traefik += SETTINGS
        self.suite.server = "10.0.0.5"  # the server's own address on its network: a cloud's private one
        browser = self.operator()
        self.assertEqual(self.direccion(browser)[0], 200)
        self.assertEqual(self.suite.addresses, {NAME: PUBLIC})
        self.suite.propagate()
        self.assertTrue(browser.get("/api/state")[1]["address"]["published"], "its nameservers publish that address")
        self.suite.server = "10.0.0.6"  # DHCP moves the private one
        printed(lambda: provisionador.update_address(self.state, self.suite, provisionador.interface(self.ADDRESS)))
        self.assertEqual(self.suite.addresses, {NAME: PUBLIC})

    def test_an_own_domain_waits_for_the_settings_too_then_takes_the_route_before_vanillas_check(self):
        browser = self.operator()
        status, body = self.direccion(browser, {"domain": DOMAIN})
        self.assertEqual((status, body.get("settings")), (409, SETTINGS), body)
        self.assertEqual((list(self.suite.dynamic.iterdir()), self.suite.aio), ([], {}))
        self.suite.traefik += SETTINGS
        status, body = browser.request("POST", "/api/address", {"domain": DOMAIN})  # «Reintentar»
        self.assertEqual((status, body["address"]["name"]), (200, DOMAIN), body)
        self.assertEqual(self.route(), routed(DOMAIN))
        self.assertEqual(self.suite.aio["domain"], DOMAIN)

    def test_a_switch_between_the_aps_name_and_an_own_domain_moves_the_route_and_frees_the_name(self):
        self.suite.traefik += SETTINGS
        browser = self.operator()
        self.assertEqual(self.direccion(browser)[0], 200)
        status, body = browser.request("POST", "/api/address", {"domain": DOMAIN})
        self.assertEqual((status, body["address"]["name"]), (200, DOMAIN), body)
        self.assertEqual((self.route(), self.suite.credentials), (routed(DOMAIN), {}), "the name is freed")
        status, body = browser.request("POST", "/api/address", {})  # «Usar el nombre APS»
        self.assertEqual((status, body["address"]["name"]), (200, NAME), body)
        self.assertEqual(self.route(), ROUTE)

    def route(self):
        """The route in Coolify's dynamic folder, which holds no other file of the suite's."""
        self.assertEqual([path.name for path in self.suite.dynamic.iterdir()], ["nextcloud-aio.yaml"])
        return json.loads((self.suite.dynamic / "nextcloud-aio.yaml").read_text(encoding="utf-8"))


def routed(host):
    """ROUTE, for `host` instead of the name."""
    return json.loads(json.dumps(ROUTE).replace(NAME, host))
