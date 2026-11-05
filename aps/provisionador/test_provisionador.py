# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: the Provisionador's HTTP API, in-process, against the fake suite port.

Each test starts a real Provisionador over a throwaway state directory and a register written here, reads the link
from what it prints to the mastercontainer's log, and drives the API as the page does. Caddy, which terminates TLS
on AIO's interface in the image, is not here: the image test covers it. No browser, no Docker.
"""

import contextlib
import http.client
import io
import json
import os
import re
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock
from urllib.parse import urlencode, urlsplit

import provisionador
import steps
from suite import FakeSuite

ADDRESS = "192.168.1.10"
# The fingerprints of FakeSuite's certificate for ADDRESS, and of the one after a renewal, computed with sha256sum.
FINGERPRINT = ("B6:FD:69:DC:D6:49:74:A5:71:24:7C:01:9B:A4:81:9D:"
               "A1:FB:09:99:9A:A1:F3:76:82:1C:5C:5F:C2:3E:10:F2")
RENEWED = ("FB:AA:97:FC:A8:28:2E:B6:23:D2:E5:67:61:E3:F6:3B:"
           "79:DF:F6:45:8A:E7:BC:65:D8:9A:7B:F2:6C:AE:CF:FA")
# A qrencode that shows what it was given: its arguments, then its input.
QRENCODE = "#!/bin/sh\nprintf 'QR-ARGV:%s\\n' \"$*\"\nprintf 'QR-STDIN:'\ncat\nprintf '\\n'\n"

# Fixture codes only: no real establishment is named here.
HEADER = ("codigo,tipo,nombre,direccion,comuna_codigo,comuna,region_codigo,region,servicio_salud,dependencia,"
          "latitud,longitud\r\n")
REGISTER = HEADER + """\
999001,CESFAM,Centro de Salud Familiar Los Castaños,Calle Uno 100,13101,Santiago,13,Metropolitana de Santiago,\
Servicio de Salud Metropolitano Central,Municipal,-33.45,-70.66\r
999002,CECOSF,CECOSF Estrecho,Avenida Dos 200,12101,Punta Arenas,12,Magallanes y de la Antártica Chilena,\
Servicio de Salud Magallanes,Municipal,-53.16,-70.91\r
999003,SAPU,SAPU Rapa Nui,Calle Tres 300,05201,Isla de Pascua,05,Valparaíso,Servicio de Salud Viña del Mar Quillota,\
Municipal,-27.15,-109.43\r
999004,CESFAM,Centro de Salud Familiar Doctor Juan Pérez,"Calle Cuatro 400, Villa Sur",13101,Santiago,13,\
Metropolitana de Santiago,Servicio de Salud Metropolitano Central,Municipal,-33.47,-70.64\r
"""


def printed(call):
    """What `call` prints to the mastercontainer's log."""
    log = io.StringIO()
    with contextlib.redirect_stdout(log):
        call()
    return log.getvalue()


class Link:
    """What the Provisionador printed at its start: the link, its QR code and the certificate's fingerprint."""

    def __init__(self, log):
        self.log = log
        found = re.search(r"https://\S+", log)
        self.url = found and found.group(0)
        self.secret = self.url and urlsplit(self.url).fragment
        found = re.search(r"(?:[0-9A-F]{2}:){31}[0-9A-F]{2}", log)
        self.fingerprint = found and found.group(0)


class Browser:
    """The operator's browser behind Caddy: it keeps the session cookie and opens a link as the page does. It reaches
    whichever Provisionador runs now, as Caddy does."""

    def __init__(self, test):
        self.test = test
        self.cookie = None
        self.headers = {}

    def request(self, method, path, body=None, content_type="application/json"):
        """`body` is sent as JSON, or as is when it is bytes."""
        headers = {"Cookie": self.cookie} if self.cookie else {}
        data = None
        if body is not None:
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            headers["Content-Type"] = content_type
        conn = http.client.HTTPConnection("127.0.0.1", self.test.server.server_address[1], timeout=10)
        try:
            conn.request(method, path, body=data, headers=headers)
            response = conn.getresponse()
            raw = response.read()
            self.headers = dict(response.getheaders())
        finally:
            conn.close()
        if "Set-Cookie" in self.headers:
            self.cookie = self.headers["Set-Cookie"].split(";", 1)[0]
        is_json = self.headers.get("Content-Type", "").startswith("application/json")
        return response.status, json.loads(raw) if is_json else raw

    def get(self, path):
        return self.request("GET", path)

    def open(self, link):
        return self.request("POST", "/api/session", {"link": link.secret})


class ProvisionadorTest(unittest.TestCase):
    ADDRESS = ADDRESS

    def setUp(self):
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.state = tmp / "state"
        self.register = self.register_file(tmp)
        tools = tmp / "bin"
        tools.mkdir()
        (tools / "qrencode").write_text(QRENCODE, encoding="utf-8")
        (tools / "qrencode").chmod(0o755)
        self.enterContext(mock.patch.dict(os.environ, {"PATH": f"{tools}{os.pathsep}{os.environ['PATH']}"}))
        self.suite = FakeSuite()
        self.server = None
        self.addCleanup(self.stop)
        self.link = self.start()

    def register_file(self, folder):
        path = folder / "establecimientos-deis-2026-07-23.csv"
        path.write_text(REGISTER, encoding="utf-8", newline="")
        return path

    def start(self):
        """Start the Provisionador over the state directory, as the mastercontainer does at every start, and read the
        link it printed."""
        self.app = provisionador.Provisionador(self.state, self.register, self.suite, self.ADDRESS)
        self.server = self.app.server(("127.0.0.1", 0))
        link = Link(printed(self.app.announce))
        self.app.resume()
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05},
                                       daemon=True)
        self.thread.start()
        return link

    def stop(self):
        if self.server:
            self.server.shutdown()
            self.server.server_close()
            self.thread.join()
            self.server = None

    def restart(self):
        self.stop()
        return self.start()

    def browser(self):
        return Browser(self)

    def operator(self):
        """A browser that opened the link."""
        browser = self.browser()
        status, body = browser.open(self.link)
        self.assertEqual(status, 200, body)
        return browser


class TheLog(ProvisionadorTest):
    def test_the_log_prints_the_link_its_qr_code_and_the_certificate_fingerprint(self):
        url = urlsplit(self.link.url)
        self.assertEqual((url.scheme, url.hostname, url.port, url.path), ("https", ADDRESS, 8080, "/"))
        self.assertGreaterEqual(len(self.link.secret), 43, "256 random bits")
        self.assertIn(f"QR-STDIN:{self.link.url}\n", self.link.log)
        self.assertEqual(self.link.fingerprint, FINGERPRINT)

    def test_no_tool_receives_the_link_on_its_command_line(self):
        argv = re.search(r"QR-ARGV:(.*)", self.link.log).group(1)
        self.assertNotIn(self.link.secret, argv)

    def test_the_secret_appears_only_in_the_link_and_its_qr_code(self):
        lines = [line for line in self.link.log.splitlines() if self.link.secret in line]
        self.assertEqual(len(lines), 2, lines)
        self.assertTrue(all(self.link.url in line for line in lines), lines)


class TheAddress(ProvisionadorTest):
    ADDRESS = "gestion.example.cl:8443"

    def test_the_link_takes_the_interface_address_and_its_port(self):
        url = urlsplit(self.link.url)
        self.assertEqual((url.hostname, url.port), ("gestion.example.cl", 8443))
        self.assertEqual(self.link.fingerprint, "BB:60:23:3C:0F:AF:8B:AC:4E:9B:A8:1B:CC:09:82:E9:"
                                                "C2:09:BE:83:DF:13:F6:FF:7A:7C:66:FF:52:37:3C:D8")


class NoAddress(ProvisionadorTest):
    ADDRESS = ""

    def test_without_the_interface_address_the_log_says_how_to_give_it_and_prints_no_link(self):
        self.assertIsNone(self.link.url)
        self.assertIn(provisionador.ADDRESS, self.link.log)

    def test_an_address_that_is_not_a_host_and_port_prints_no_link_either(self):
        for address in ("192.168.1.10/instalar", "gestion.example.cl:99999", "user@gestion.example.cl", "a b"):
            log = printed(provisionador.Provisionador(self.state, self.register, self.suite, address).announce)
            self.assertNotIn("https://", log, address)
            self.assertIn(provisionador.ADDRESS, log, address)


class ThePage(ProvisionadorTest):
    def test_the_link_opens_the_spanish_page_and_its_own_files_load(self):
        browser = self.browser()
        status, page = browser.get("/")
        self.assertEqual(status, 200)
        self.assertTrue(browser.headers["Content-Type"].startswith("text/html"))
        page = page.decode()
        self.assertIn('<html lang="es-CL">', page)
        self.assertIn("<h1>Centro</h1>", page)
        # /aps/ holds the brand files AIO's page serves; Caddy hands them out, and the image test loads them.
        own = [path for path in re.findall(r'(?:src|href)="(/[^"]+)"', page) if not path.startswith("/aps/")]
        self.assertEqual(sorted(own), ["/app.css", "/app.js"])
        for path in own:
            self.assertEqual(browser.get(path)[0], 200, path)
        self.assertEqual(browser.get("/provisionador.py")[0], 404)


class TheSession(ProvisionadorTest):
    def test_the_link_opens_a_session_in_a_secure_http_only_strict_cookie(self):
        browser = self.browser()
        status, _ = browser.open(self.link)
        self.assertEqual(status, 200)
        cookie = browser.headers["Set-Cookie"]
        self.assertTrue(cookie.startswith(f"{provisionador.COOKIE}="), cookie)
        for attribute in ("Path=/", "Secure", "HttpOnly", "SameSite=Strict"):
            self.assertIn(attribute, cookie)
        self.assertEqual(browser.get("/api/state")[0], 200)

    def test_every_call_without_a_session_is_refused(self):
        browser = self.browser()
        for method, path in (("GET", "/api/state"), ("GET", "/api/register"),
                             ("GET", "/api/establishments?name=castanos"), ("POST", "/api/centre"),
                             ("POST", "/api/address")):
            status, body = browser.request(method, path, {} if method == "POST" else None)
            self.assertEqual(status, 401, path)
            self.assertIn("enlace", body["error"])
        browser.cookie = f"{provisionador.COOKIE}=forged"
        self.assertEqual(browser.get("/api/state")[0], 401)

    def test_a_wrong_secret_opens_nothing(self):
        for secret in ("wrong", "", 42, None, ["x"]):
            browser = self.browser()
            status, body = browser.request("POST", "/api/session", {"link": secret})
            self.assertEqual(status, 401, secret)
            self.assertNotIn("Set-Cookie", browser.headers)

    def test_the_link_stays_valid_so_a_second_browser_opens_its_own_session(self):
        first, second = self.operator(), self.operator()
        self.assertNotEqual(first.cookie, second.cookie)
        self.assertEqual(first.get("/api/state")[0], 200)
        self.assertEqual(second.get("/api/state")[0], 200)

    def test_a_post_that_is_not_json_is_refused_so_another_origin_needs_a_preflight(self):
        browser = self.browser()
        status, body = browser.request("POST", "/api/session", json.dumps({"link": self.link.secret}).encode(),
                                       content_type="text/plain")
        self.assertEqual(status, 415)
        self.assertNotIn("Set-Cookie", browser.headers)

    def test_the_state_keeps_neither_the_secret_nor_a_session_in_clear(self):
        browser = self.operator()
        session = browser.cookie.split("=", 1)[1]
        for file in self.state.iterdir():
            text = file.read_text(encoding="utf-8")
            self.assertNotIn(self.link.secret, text, file.name)
            self.assertNotIn(session, text, file.name)


class TheRestart(ProvisionadorTest):
    def test_a_restart_prints_a_fresh_link_and_the_one_before_still_opens_a_session(self):
        before = self.link
        self.link = self.restart()
        self.assertNotEqual(self.link.secret, before.secret)
        self.assertEqual(self.link.fingerprint, FINGERPRINT)
        self.assertEqual(self.browser().open(before)[0], 200)
        self.assertEqual(self.browser().open(self.link)[0], 200)

    def test_a_session_survives_a_restart(self):
        browser = self.operator()
        self.restart()
        self.assertEqual(browser.get("/api/state")[0], 200)


class TheRenewal(ProvisionadorTest):
    def test_a_renewed_certificate_prints_its_fingerprint_once_without_the_link(self):
        self.assertEqual(printed(self.app.check_certificate), "", "the certificate is unchanged")
        self.suite.renew()
        log = printed(self.app.check_certificate)
        self.assertEqual(Link(log).fingerprint, RENEWED)
        self.assertNotIn(self.link.secret, log)
        self.assertNotIn("https://", log)
        self.assertEqual(printed(self.app.check_certificate), "", "printed once")

    def test_a_check_while_the_interface_does_not_answer_is_not_fatal(self):
        with mock.patch.object(self.suite, "certificate", side_effect=provisionador.Unreachable("no answer")):
            self.assertEqual(printed(self.app.check_certificate), "")
        self.suite.renew()
        self.assertEqual(Link(printed(self.app.check_certificate)).fingerprint, RENEWED)


class Listo(ProvisionadorTest):
    def listo(self):
        """«Listo», as the install's last step reaches it."""
        (self.state / provisionador.LISTO).touch()

    def test_listo_ends_every_session(self):
        browser = self.operator()
        self.listo()
        status, body = browser.get("/api/state")
        self.assertEqual(status, 410)
        self.assertIn("«Listo»", body["error"])

    def test_listo_ends_the_link(self):
        self.listo()
        browser = self.browser()
        self.assertEqual(browser.open(self.link)[0], 410)
        self.assertNotIn("Set-Cookie", browser.headers)


class CentroSearch(ProvisionadorTest):
    def codes(self, browser, **query):
        status, body = browser.get("/api/establishments?" + urlencode(query))
        self.assertEqual(status, 200, body)
        return [row["code"] for row in body["rows"]]

    def test_the_register_offers_its_regions_north_to_south_their_comunas_and_the_types(self):
        status, register = self.operator().get("/api/register")
        self.assertEqual(status, 200)
        self.assertEqual(register["date"], "2026-07-23")
        self.assertEqual(register["regions"], [{"code": "05", "name": "Valparaíso"},
                                               {"code": "13", "name": "Metropolitana de Santiago"},
                                               {"code": "12", "name": "Magallanes y de la Antártica Chilena"}])
        self.assertEqual(register["comunas"], [{"code": "05201", "name": "Isla de Pascua", "region": "05"},
                                               {"code": "12101", "name": "Punta Arenas", "region": "12"},
                                               {"code": "13101", "name": "Santiago", "region": "13"}])
        self.assertEqual(register["types"], [{"code": "CESFAM", "name": "Centro de Salud Familiar"},
                                             {"code": "CECOSF", "name": "Centro Comunitario de Salud Familiar"},
                                             {"code": "SAPU", "name": "Servicio de Atención Primaria de Urgencia"}])

    def test_search_by_region_comuna_type_or_name(self):
        browser = self.operator()
        self.assertEqual(self.codes(browser, region="12"), ["999002"])
        self.assertEqual(self.codes(browser, comuna="13101"), ["999004", "999001"], "by name")
        self.assertEqual(self.codes(browser, type="SAPU"), ["999003"])
        self.assertEqual(self.codes(browser, name="CASTANOS"), ["999001"])
        self.assertEqual(self.codes(browser, name="juan perez", type="CESFAM", comuna="13101"), ["999004"])
        self.assertEqual(self.codes(browser, region="12", type="SAPU"), [])
        status, body = browser.get("/api/establishments?" + urlencode({"name": "los castaños"}))
        self.assertEqual(body, {"total": 1, "rows": [{
            "code": "999001", "type": "CESFAM", "name": "Centro de Salud Familiar Los Castaños",
            "address": "Calle Uno 100", "comuna": "Santiago", "region": "Metropolitana de Santiago",
            "point": {"latitude": -33.45, "longitude": -70.66}}]})


class CentroChoice(ProvisionadorTest):
    def choose(self, browser, **body):
        return browser.request("POST", "/api/centre", body)

    def test_choosing_an_establishment_keeps_its_identity_its_official_point_and_its_timezone(self):
        browser = self.operator()
        self.assertIsNone(browser.get("/api/state")[1]["centre"])
        status, body = self.choose(browser, code="999004")
        self.assertEqual(status, 200, body)
        official = {"latitude": -33.47, "longitude": -70.64}
        self.assertEqual(body["centre"], {
            "code": "999004", "type": "CESFAM", "name": "Centro de Salud Familiar Doctor Juan Pérez",
            "address": "Calle Cuatro 400, Villa Sur", "comuna": "Santiago", "comuna_code": "13101",
            "region": "Metropolitana de Santiago", "region_code": "13",
            "health_service": "Servicio de Salud Metropolitano Central", "dependency": "Municipal",
            "official_point": official, "point": official, "timezone": "America/Santiago"})
        self.assertEqual(browser.get("/api/state")[1]["centre"], body["centre"])

    def test_a_point_moved_on_the_map_is_kept_beside_the_official_one(self):
        browser = self.operator()
        status, body = self.choose(browser, code="999001", point={"latitude": -33.4512, "longitude": -70.6634})
        self.assertEqual(status, 200, body)
        self.assertEqual(body["centre"]["point"], {"latitude": -33.4512, "longitude": -70.6634})
        self.assertEqual(body["centre"]["official_point"], {"latitude": -33.45, "longitude": -70.66})
        self.assertEqual(browser.get("/api/state")[1]["centre"]["point"], body["centre"]["point"])

    def test_an_unknown_establishment_or_a_point_off_the_map_is_refused_and_changes_nothing(self):
        browser = self.operator()
        for code in ("999999", 999001, ["999001"], None):
            status, body = self.choose(browser, code=code)
            self.assertEqual(status, 404, code)
            self.assertIn("registro DEIS", body["error"])
        for point in ({"latitude": 91, "longitude": 0}, {"latitude": 0, "longitude": -181},
                      {"latitude": "-33", "longitude": -70}, {"latitude": True, "longitude": -70},
                      {"latitude": -33}, {"latitude": -33, "longitude": -70, "altitude": 0}, "-33,-70"):
            status, body = self.choose(browser, code="999001", point=point)
            self.assertEqual(status, 400, point)
            self.assertIn("punto", body["error"])
        self.assertIsNone(browser.get("/api/state")[1]["centre"])

    def test_the_timezone_follows_magallanes_and_isla_de_pascua(self):
        browser = self.operator()
        for code, timezone in (("999002", "America/Punta_Arenas"), ("999003", "Pacific/Easter"),
                               ("999001", "America/Santiago")):
            status, body = self.choose(browser, code=code)
            self.assertEqual((status, body["centre"]["timezone"]), (200, timezone), code)

    def test_the_chosen_centre_survives_a_restart(self):
        browser = self.operator()
        centre = self.choose(browser, code="999002")[1]["centre"]
        self.restart()
        self.assertEqual(browser.get("/api/state")[1]["centre"], centre)


NAME = "centro-999001.gestion.apsconecta.cl"  # the name FakeSuite's name service gives 999001


class Direccion(ProvisionadorTest):
    def claim(self, browser, code="999001"):
        """«Centro» confirmed, then «Dirección», as the page goes from one to the other."""
        self.assertEqual(browser.request("POST", "/api/centre", {"code": code})[0], 200)
        return browser.request("POST", "/api/address", {})

    def test_the_name_is_claimed_once_by_the_centres_deis_code_and_its_credential_is_reused(self):
        browser = self.operator()
        status, body = self.claim(browser)
        self.assertEqual(status, 200, body)
        self.assertEqual(body["address"]["name"], NAME)
        self.restart()
        status, body = browser.request("POST", "/api/address", {})
        self.assertEqual((status, body["address"]["name"]), (200, NAME))
        self.assertEqual(self.suite.claims, ["999001"], "a name is claimed once")
        self.assertEqual(self.suite.addresses, {NAME: "192.168.1.10"}, "published with the stored credential")
        password = self.suite.credentials[NAME]["password"]
        stored = [f for f in self.state.iterdir() if password in f.read_text(encoding="utf-8")]
        self.assertEqual([oct(f.stat().st_mode & 0o777) for f in stored], ["0o600"], "one file, its owner's only")

    def test_after_direccion_aios_settings_name_the_name_reverse_proxy_mode_and_our_caddy(self):
        self.assertEqual(self.claim(self.operator())[0], 200)
        credential = self.suite.credentials[NAME]
        self.assertEqual(self.suite.aio, {
            "domain": NAME, "aio_community_containers": "caddy", "apache_port": "11000",
            "apache_ip_binding": "@INTERNAL", "turn_domain": NAME, "talk_port": "443",
            "secrets": {"ACMEDNS_USERNAME": "999001", "ACMEDNS_PASSWORD": credential["password"],
                        "ACMEDNS_SUBDOMAIN": "centro-999001", "ACMEDNS_SERVER_URL": "https://nombres.example"}})

    def test_a_name_another_installation_holds_says_aps_conecta_can_release_it(self):
        self.suite.held.add("999001")
        browser = self.operator()
        status, body = self.claim(browser)
        self.assertEqual(status, 409, body)
        self.assertIn("APS Conecta puede liberarlo", body["error"])
        self.assertIn("«Reintentar»", body["error"])
        self.assertEqual(self.suite.aio, {}, "AIO is not set up for a name the server does not hold")
        self.suite.held.clear()  # APS Conecta released it
        status, body = browser.request("POST", "/api/address", {})
        self.assertEqual((status, body["address"]["name"]), (200, NAME))

    def test_a_name_service_or_internet_outage_comes_with_reintentar(self):
        self.suite.outage = True
        browser = self.operator()
        status, body = self.claim(browser)
        self.assertEqual(status, 503, body)
        self.assertIn("servicio de nombres de APS Conecta", body["error"])
        self.assertIn("conexión a internet", body["error"])
        self.assertIn("«Reintentar»", body["error"])
        self.assertIsNone(browser.get("/api/state")[1]["address"])
        self.suite.outage = False
        status, body = browser.request("POST", "/api/address", {})
        self.assertEqual((status, body["address"]["name"]), (200, NAME))

    def test_an_outage_after_the_claim_keeps_the_credential_for_reintentar(self):
        browser = self.operator()
        self.assertEqual(browser.request("POST", "/api/centre", {"code": "999001"})[0], 200)
        with mock.patch.object(self.suite, "publish", side_effect=provisionador.Unreachable("sin respuesta")):
            self.assertEqual(browser.request("POST", "/api/address", {})[0], 503)
        status, body = browser.request("POST", "/api/address", {})
        self.assertEqual((status, body["address"]["name"]), (200, NAME))
        self.assertEqual(self.suite.claims, ["999001"])

    def test_a_resolver_that_drops_the_private_answer_is_detected_from_the_browser(self):
        browser = self.operator()
        self.assertEqual(self.claim(browser)[0], 200)
        # The page asks for AIO's interface at the name. This network's resolver drops the answer, which points to
        # the server's private address, so the request never reaches the server.
        self.assertEqual(browser.get("/api/state")[1]["address"], {"name": NAME, "opened": False})

    def test_a_browser_whose_resolver_answers_the_server_opens_the_name(self):
        browser = self.operator()
        self.assertEqual(self.claim(browser)[0], 200)
        self.suite.hello(NAME)  # the page's request reaches AIO's interface at the name
        self.assertEqual(browser.get("/api/state")[1]["address"], {"name": NAME, "opened": True})

    def test_the_address_updater_points_the_name_at_the_servers_new_address(self):
        self.assertEqual(self.claim(self.operator())[0], 200)
        self.suite.server = "192.168.1.23"  # DHCP gave the server another address
        provisionador.update_address(self.state, self.suite)
        self.assertEqual(self.suite.addresses, {NAME: "192.168.1.23"})

    def test_an_update_during_an_outage_waits_for_the_next_one(self):
        self.assertEqual(self.claim(self.operator())[0], 200)
        self.suite.server, self.suite.outage = "192.168.1.23", True
        with contextlib.redirect_stderr(io.StringIO()) as log:
            provisionador.update_address(self.state, self.suite)
        self.assertIn("servicio de nombres", log.getvalue())
        self.suite.outage = False
        provisionador.update_address(self.state, self.suite)
        self.assertEqual(self.suite.addresses, {NAME: "192.168.1.23"})

    def test_before_the_claim_the_address_updater_publishes_nothing(self):
        provisionador.update_address(self.state, self.suite)
        self.assertEqual(self.suite.addresses, {})

    def test_the_claimed_name_keeps_its_centre_though_the_point_still_moves(self):
        browser = self.operator()
        self.assertEqual(self.claim(browser)[0], 200)
        status, body = browser.request("POST", "/api/centre", {"code": "999002"})
        self.assertEqual(status, 409, body)
        self.assertIn(NAME, body["error"])
        self.assertEqual(browser.get("/api/state")[1]["centre"]["code"], "999001")
        moved = {"latitude": -33.4512, "longitude": -70.6634}
        status, body = browser.request("POST", "/api/centre", {"code": "999001", "point": moved})
        self.assertEqual((status, body["centre"]["point"]), (200, moved))

    def test_direccion_needs_the_centre_first(self):
        status, body = self.operator().request("POST", "/api/address", {})
        self.assertEqual(status, 409, body)
        self.assertIn("«Centro»", body["error"])
        self.assertEqual(self.suite.claims, [])


def claimed(browser, code="999001"):
    """«Centro» confirmed and «Dirección» claimed its APS name, as the page goes from one to the other."""
    for path, body in (("/api/centre", {"code": code}), ("/api/address", {})):
        status, answer = browser.request("POST", path, body)
        assert status == 200, answer
    return answer["address"]["name"]


class Revisar(ProvisionadorTest):
    def test_revisar_summarises_the_centre_the_name_the_timezone_the_components_and_the_backup(self):
        browser = self.operator()
        self.assertIsNone(browser.get("/api/state")[1]["review"], "nothing to review before «Dirección»")
        claimed(browser, "999002")
        state = browser.get("/api/state")[1]
        self.assertEqual((state["centre"]["name"], state["centre"]["timezone"], state["address"]["name"]),
                         ("CECOSF Estrecho", "America/Punta_Arenas", "centro-999002.gestion.apsconecta.cl"))
        self.assertEqual(state["review"], {
            "components": ["Talk", "Euro-Office", "ClamAV (antivirus)", "Imaginary (vistas previas de imágenes)",
                           "Búsqueda de texto completo", "HaRP (aplicaciones externas)"],
            "backup": {"folder": "/var/backups/apsconecta-gestion", "time": "06:00"}})


class Instalar(ProvisionadorTest):
    """«Instalar» runs in the background, as against the real suite; each test waits for what the operator would see."""

    def setUp(self):
        super().setUp()
        self.enterContext(mock.patch.object(steps, "POLL", 0.01))
        self.log = self.enterContext(contextlib.redirect_stdout(io.StringIO()))
        self.addCleanup(self.finish)
        self.browser = self.operator()

    def finish(self):
        """The suite comes up, so the install a test left running ends before its state goes."""
        self.suite.up()
        if self.app.worker:
            self.app.worker.join()

    def install(self):
        return self.browser.request("POST", "/api/install", {})

    def status(self):
        return self.browser.get("/api/state")[1]["install"]["status"]

    def eventually(self, condition, what, timeout=10):
        deadline = time.monotonic() + timeout
        while not condition():
            if time.monotonic() > deadline:
                self.fail(f"no {what} within {timeout} s")
            time.sleep(0.01)

    def test_instalar_needs_the_aps_name_first(self):
        self.assertEqual(self.browser.request("POST", "/api/centre", {"code": "999001"})[0], 200)
        status, body = self.install()
        self.assertEqual(status, 409, body)
        self.assertIn("«Dirección»", body["error"])
        self.assertEqual((self.suite.aio, self.suite.starts), ({}, 0))

    def test_instalar_writes_aios_settings_for_each_choice_then_starts_the_suite_with_aios_own_start(self):
        claimed(self.browser, "999002")
        self.assertEqual(self.install()[0], 202)
        self.eventually(lambda: self.suite.starts, "AIO's start")
        written = {"officeSuite": "eurooffice", "isTalkEnabled": True, "isClamavEnabled": True,
                   "isImaginaryEnabled": True, "isFulltextsearchEnabled": True, "isHarpEnabled": True,
                   "isTalkRecordingEnabled": False, "isDockerSocketProxyEnabled": False, "isWhiteboardEnabled": False,
                   "timezone": "America/Punta_Arenas", "borg_backup_host_location": "/var/backups/apsconecta-gestion",
                   "borg_remote_repo": "", "wasStartButtonClicked": True, "AIO_URL": "192.168.1.10:8080"}
        self.assertEqual({key: self.suite.aio.get(key) for key in written}, written)
        self.assertEqual(self.suite.daily_backup_time, "06:00\nautomaticUpdatesAreNotEnabled\n",
                         "nightly at 06:00 UTC, with success notifications and without automatic updates")
        self.assertEqual(self.suite.starts, 1)

    def test_the_progress_shows_each_container_as_aio_reads_it_and_listo_waits_for_every_one(self):
        claimed(self.browser)
        self.install()
        self.eventually(lambda: self.suite.starts, "AIO's start")
        self.suite.up("nextcloud-aio-nextcloud")
        self.assertEqual(self.browser.get("/api/state")[1]["install"], {"status": "installing", "containers": [
            {"name": "Apache & Caddy", "state": "starting"}, {"name": "Servidor de aplicaciones", "state": "running"},
            {"name": "Talk", "state": "starting"}, {"name": "EuroOffice", "state": "starting"}]})
        self.suite.up("nextcloud-aio-talk", "nextcloud-aio-eurooffice")
        time.sleep(0.3)  # many readings of the containers
        self.assertFalse((self.state / provisionador.LISTO).exists(), "Apache still starts")
        self.suite.up("nextcloud-aio-apache")
        self.eventually(lambda: (self.state / provisionador.LISTO).exists(), "«Listo»")
        self.assertEqual(self.browser.get("/api/state")[0], 410, "«Listo» ends the session; AIO's page takes 8080")
        self.assertIn("«Listo»: el personal abre APS Conecta Gestión en https://centro-999001.gestion.apsconecta.cl",
                      self.log.getvalue())

    def test_a_container_that_never_runs_fails_the_install_with_its_name_until_reintentar_finds_it_running(self):
        self.enterContext(mock.patch.object(steps.start, "WAIT", 0.3))
        claimed(self.browser)
        self.install()
        self.eventually(lambda: self.suite.starts, "AIO's start")
        self.suite.up("nextcloud-aio-apache", "nextcloud-aio-nextcloud", "nextcloud-aio-eurooffice")
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.assertEqual(self.browser.get("/api/state")[1]["install"]["reasons"], [
            "Estos contenedores de la suite no quedaron en ejecución: Talk. Presione «Reintentar»; si vuelve a ocurrir, "
            "contacte a APS Conecta."])
        self.assertFalse((self.state / provisionador.LISTO).exists())
        self.suite.up("nextcloud-aio-talk")
        self.assertEqual(self.install()[0], 202)  # «Reintentar»
        self.eventually(lambda: (self.state / provisionador.LISTO).exists(), "«Listo»")
        self.assertEqual(self.suite.starts, 1, "AIO's start is not sent again while no container is stopped")

    def test_reintentar_sends_aios_start_again_for_a_container_that_stopped(self):
        self.enterContext(mock.patch.object(steps.start, "WAIT", 0.3))
        claimed(self.browser)
        self.install()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.suite.states["nextcloud-aio-talk"] = "stopped"  # Talk exited
        self.install()
        self.eventually(lambda: self.suite.starts == 2, "AIO's start again")
        self.suite.up()
        self.eventually(lambda: (self.state / provisionador.LISTO).exists(), "«Listo»")

    def test_instalar_pressed_again_while_the_install_runs_starts_nothing_more(self):
        claimed(self.browser)
        self.assertEqual(self.install()[0], 202)
        self.eventually(lambda: self.suite.starts, "AIO's start")
        status, body = self.install()
        self.assertEqual((status, body["install"]["status"]), (202, "installing"))
        self.suite.up()
        self.eventually(lambda: (self.state / provisionador.LISTO).exists(), "«Listo»")
        self.assertEqual(self.suite.starts, 1)

    def test_an_install_a_restart_cut_short_goes_on_by_itself(self):
        claimed(self.browser)
        cut_short = threading.Event()  # never set: the Provisionador that sent AIO's start is gone
        with mock.patch.object(self.suite, "start", side_effect=lambda url: cut_short.wait()) as first:
            self.install()
            self.eventually(lambda: first.called, "AIO's start")
        self.restart()  # the mastercontainer restarted while AIO started the suite
        self.eventually(lambda: self.suite.starts, "AIO's start, from the Provisionador that started again")
        self.assertEqual(self.status(), "installing")
        self.suite.up()
        self.eventually(lambda: (self.state / provisionador.LISTO).exists(), "«Listo»")

    def test_a_suite_that_does_not_start_fails_the_install_with_aios_reason(self):
        claimed(self.browser)
        with mock.patch.object(self.suite, "start", side_effect=provisionador.Unreachable("El contenedor maestro no "
                                                                                         "logró iniciar la suite.")):
            self.install()
            self.eventually(lambda: self.status() == "failed", "a failed install")
        self.assertEqual(self.browser.get("/api/state")[1]["install"]["reasons"],
                         ["El contenedor maestro no logró iniciar la suite."])


class ImagePulls(ProvisionadorTest):
    def test_at_its_start_the_provisionador_pulls_the_images_of_the_suite_instalar_starts_writing_no_setting(self):
        log = printed(self.app.pull_images)  # what the mastercontainer's start runs beside the link, in the background
        self.assertEqual(self.suite.pulled, [{
            "officeSuite": "eurooffice", "isTalkEnabled": True, "isClamavEnabled": True, "isImaginaryEnabled": True,
            "isFulltextsearchEnabled": True, "isHarpEnabled": True, "isTalkRecordingEnabled": False,
            "isDockerSocketProxyEnabled": False, "isWhiteboardEnabled": False}])
        self.assertEqual(self.suite.aio, {}, "AIO's settings wait for «Instalar»")
        self.assertIn("Las imágenes de la suite están descargadas.", log)

    def test_a_pull_that_fails_is_logged_and_instalar_pulls_again(self):
        with mock.patch.object(self.suite, "pull", side_effect=provisionador.Unreachable("Sin conexión.")), \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertNotIn("descargadas", printed(self.app.pull_images))
        self.assertIn("Sin conexión.", errors.getvalue())


class ReleaseName(ProvisionadorTest):
    """provisionador.py release-name, which the Bootstrap's reset runs and the acceptance harness for each CI name it
    claimed: the name is freed with its own credential, given on stdin."""

    def release(self, credential):
        with mock.patch.object(sys, "stdin", io.StringIO(credential)):
            return printed(lambda: self.assertEqual(provisionador.main(["release-name"], self.suite), 0))

    def test_the_name_whose_credential_arrives_on_stdin_is_freed_so_that_its_centre_claims_it_again(self):
        claimed(self.operator())
        credential = (self.state / provisionador.NAME_CREDENTIAL).read_text(encoding="utf-8")
        self.assertIn(NAME, self.release(credential))
        self.assertEqual(self.suite.claim("999001")["name"], NAME, "a reinstall claims the name again")

    def test_a_name_freed_already_stays_free(self):
        claimed(self.operator())
        credential = (self.state / provisionador.NAME_CREDENTIAL).read_text(encoding="utf-8")
        self.release(credential)
        self.assertIn("ya estaba libre", self.release(credential))


class ShippedRegister(ProvisionadorTest):
    """The register the image ships: aps/deis's newest, #250's verified snapshot."""

    def register_file(self, folder):
        return provisionador.deis.newest(provisionador.REGISTER)

    def test_the_shipped_register_offers_every_region_north_to_south_and_every_type(self):
        status, register = self.operator().get("/api/register")
        self.assertEqual(status, 200)
        self.assertEqual(register["date"], "2026-07-23")
        self.assertEqual([r["code"] for r in register["regions"]],
                         ["15", "01", "02", "03", "04", "05", "13", "06", "07", "16", "08", "09", "14", "10", "11",
                          "12"])
        self.assertEqual([t["code"] for t in register["types"]],
                         ["CESFAM", "CECOSF", "PSR", "SAPU", "SUR", "SAR", "COSAM", "CGU", "CGR"])

    def test_a_search_answers_at_most_fifty_rows_and_how_many_match(self):
        status, body = self.operator().get("/api/establishments")
        self.assertEqual(status, 200)
        self.assertEqual(len(body["rows"]), 50)
        self.assertGreater(body["total"], 50)

    def test_a_shipped_establishment_comes_with_its_official_point_and_its_timezone(self):
        browser = self.operator()
        status, body = browser.get("/api/establishments?" + urlencode({"name": "posta cameron"}))
        self.assertEqual(body["rows"][0]["point"], {"latitude": -53.64055, "longitude": -69.64585})
        status, body = browser.request("POST", "/api/centre", {"code": body["rows"][0]["code"]})
        self.assertEqual((status, body["centre"]["comuna"], body["centre"]["timezone"]),
                         (200, "Timaukel", "America/Punta_Arenas"))


if __name__ == "__main__":
    unittest.main()
