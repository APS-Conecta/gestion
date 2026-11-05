# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Datos comunales de Territorio», an optional step: Territorio holds the centre's comuna, its unidades
vecinales and its health establishments, cut from the national masters the suite pins."""

import hashlib
from unittest import mock

import steps
from test_provisionador import AREAS, EAST, HOLE, OUTER, SQUARE, WEST, WEST_HOLE, Installing, shapefile

TERRITORIO = "Datos comunales de Territorio"
UNIDADES_VECINALES_MASTER, DEIS_MASTER = "unidades-vecinales-2024", "minsal-deis-establecimientos"

UNIDADES_VECINALES = {"label": "Unidades Vecinales", "records": {
    "131011": {"name": "SANTA LUCÍA", "category": "division_territorial", "subcategory": "unidad_vecinal",
               "geometry": {"type": "Polygon", "coordinates": [SQUARE]}},
    "131012": {"name": "2", "category": "division_territorial", "subcategory": "unidad_vecinal",
               "geometry": {"type": "Polygon", "coordinates": [OUTER, HOLE]}},
    "131013": {"name": "PARQUE O'HIGGINS", "category": "division_territorial", "subcategory": "unidad_vecinal",
               "geometry": {"type": "MultiPolygon", "coordinates": [[WEST, WEST_HOLE], [EAST]]}}}}
ESTABLISHMENTS = {"label": "Establecimientos de salud", "records": {
    "deis:999001": {"name": "Centro de Salud Familiar Los Castaños", "category": "salud", "subcategory": "cesfam",
                    "address": "Calle Uno 100", "geometry": {"type": "Point", "coordinates": [-70.66, -33.45]}},
    "deis:999004": {"name": "SAPU Doctor Juan Pérez", "category": "salud", "subcategory": "sapu",
                    "address": "Avenida Cuatro 400", "geometry": {"type": "Point", "coordinates": [-70.64, -33.47]}},
    "deis:999006": {"name": "Hospital Doctor Seis", "category": "salud", "subcategory": "establecimiento",
                    "address": "Calle Seis", "geometry": {"type": "Point", "coordinates": [-70.65, -33.46]}}}}


class TerritorioData(Installing):
    def test_after_listo_territorio_holds_the_centres_comuna_its_unidades_vecinales_and_health_establishments(self):
        self.install_the_suite()  # «Centro» confirms the CESFAM Los Castaños, in Santiago
        self.eventually(self.listo, "«Listo»")
        territorio = self.suite.nextcloud.apps["territorio"]
        self.assertEqual((territorio.get("comuna_cut"), territorio.get("comuna_name")), ("13101", "Santiago"))
        self.assertEqual(self.suite.nextcloud.territorio, {"unidades-vecinales": UNIDADES_VECINALES,
                                                           "deis-establecimientos": ESTABLISHMENTS})

    def master(self, master, data):
        """The master's origin serves `data`, whose checksum the suite pins."""
        pin = steps.territorio.MASTERS[master]
        self.suite.masters[pin["origin"]] = data
        self.enterContext(mock.patch.dict(pin, sha256=hashlib.sha256(data).hexdigest()))

    def test_a_territorio_that_does_not_install_makes_the_step_wait_and_brings_nothing_until_it_does(self):
        territorio = next(app for app in steps.apps.MANIFEST if app["id"] == "territorio")
        release = self.suite.releases.pop((territorio["repo"], territorio["pin"], "territorio.tar.gz"))  # GitHub fails
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.assertEqual(self.steps()[TERRITORIO], ("waiting", "Espera a que se complete «Aplicaciones»."))
        self.assertEqual(self.suite.nextcloud.territorio, {})
        self.suite.releases[territorio["repo"], territorio["pin"], "territorio.tar.gz"] = release
        self.assertEqual(self.install()[0], 202)  # «Reintentar»
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(self.suite.nextcloud.territorio, {"unidades-vecinales": UNIDADES_VECINALES,
                                                           "deis-establecimientos": ESTABLISHMENTS})

    def test_a_master_that_cannot_be_downloaded_fails_the_step_alone_and_reintentar_imports_it(self):
        origin = steps.territorio.MASTERS[UNIDADES_VECINALES_MASTER]["origin"]
        cadastre = self.suite.masters.pop(origin)  # the ministry's server does not answer
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        progress = self.steps()
        self.assertEqual(progress.pop(TERRITORIO), (
            "failed", "«Unidades Vecinales»: No se pudo descargar su fuente nacional desde "
                      "bid-ckan-dataset.ministeriodesarrollosocial.gob.cl. Revise la conexión a internet del servidor "
                      "y presione «Reintentar»."))
        self.assertEqual(set(progress.values()), {("green", None)}, "no step needs the comuna data")
        self.assertEqual(self.suite.nextcloud.territorio, {"deis-establecimientos": ESTABLISHMENTS})
        self.assertFalse(self.listo())
        self.suite.masters[origin] = cadastre
        self.assertEqual(self.install()[0], 202)  # «Reintentar»
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(self.suite.nextcloud.territorio, {"unidades-vecinales": UNIDADES_VECINALES,
                                                           "deis-establecimientos": ESTABLISHMENTS})

    def test_a_master_whose_checksum_is_not_the_pinned_one_is_refused_and_nothing_of_it_is_imported(self):
        origin = steps.territorio.MASTERS[DEIS_MASTER]["origin"]
        self.suite.masters[origin] += "999007;Clínica Nueva;Clínica;13101;Calle;Siete;7;-33.43;-70.61\n".encode()
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.assertEqual(self.steps()[TERRITORIO], (
            "failed", "«Establecimientos de salud»: La descarga de su fuente nacional no coincide con la suma de "
                      "verificación que fija la suite, así que no se importó. Presione «Reintentar»; si vuelve a "
                      "ocurrir, contacte a APS Conecta."))
        self.assertEqual(self.suite.nextcloud.territorio, {"unidades-vecinales": UNIDADES_VECINALES})

    def test_a_master_with_no_record_of_the_comuna_fails_the_step_with_its_reason(self):
        self.master(UNIDADES_VECINALES_MASTER, shapefile([area for area in AREAS if area[0].strip() != "13101"]))
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.assertEqual(self.steps()[TERRITORIO], (
            "failed", "«Unidades Vecinales»: Su fuente nacional no tiene ningún registro de la comuna Santiago "
                      "(13101), así que no se importó. Contacte a APS Conecta."))
        self.assertEqual(self.suite.nextcloud.territorio, {"deis-establecimientos": ESTABLISHMENTS})

    def test_a_cadastre_whose_cpg_file_names_utf_8_keeps_its_names(self):
        self.master(UNIDADES_VECINALES_MASTER, shapefile(AREAS, encoding="utf-8"))
        self.install_the_suite()
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(self.suite.nextcloud.territorio["unidades-vecinales"], UNIDADES_VECINALES)

    def test_the_end_of_install_check_turns_the_step_red_again_when_territorios_comuna_changed(self):
        del self.suite.nextcloud.apps["admin_audit"]  # the security step fails, so the end-of-install check waits
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.suite.nextcloud.apps["territorio"]["comuna_cut"] = "13110"  # meanwhile, Territorio is given another comuna
        self.suite.nextcloud.apps["admin_audit"] = {"enabled": "no"}
        self.assertEqual(self.install()[0], 202)  # «Reintentar»
        self.eventually(lambda: self.status() == "failed", "a failed end-of-install check")
        self.assertEqual(self.steps()[TERRITORIO], (
            "failed", "Nextcloud no conserva estos ajustes: territorio.comuna_cut. Presione «Reintentar»; si vuelve a "
                      "ocurrir, contacte a APS Conecta."))
        self.assertEqual(self.install()[0], 202)  # «Reintentar»
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(self.suite.nextcloud.apps["territorio"]["comuna_cut"], "13101")
