# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""«Datos comunales de Territorio», an optional step: Territorio's comuna data, cut at install from the national masters
the suite pins (aps/comunas/packages.json). Territorio's comuna is the centre's, by its CUT code, named as the DEIS
comuna reference beside the pins names it; setting it first arms Territorio's refusal of a file cut for another comuna.
Then each master comes from its origin, only when the download's SHA-256 checksum is the pinned one, and the comuna's
records are cut out of it: the unidades vecinales of the cadastre, a zipped shapefile read as GDAL reads one, and the
establishments of the DEIS master that have a point. Each cut goes into its Territorio dataset through Territorio's own
import (occ territorio:import), which updates in place the records a re-import brings again. A master that does not
download, does not match or holds no record of the comuna fails with its reason, and nothing of it is imported, while
the other master still is. It needs Territorio, which the apps step installs, and no step needs it. Its part of the
end-of-install check: Territorio's comuna."""

import csv
import hashlib
import io
import itertools
import json
import struct
import zipfile
from pathlib import Path

from steps import configure, differences
from suite import Unreachable

NAME = "Datos comunales de Territorio"
NEEDS = ("apps",)
OPTIONAL = True
COMUNAS = Path(__file__).resolve().parents[2] / "comunas"  # aps/comunas
MASTERS = {master["id"]: master
           for master in json.loads((COMUNAS / "packages.json").read_text(encoding="utf-8"))["masters"]}
with open(COMUNAS / "comunas-deis.csv", encoding="utf-8", newline="") as reference:
    COMUNA_NAMES = {row["cut"]: " ".join(row["glosa"].split()) for row in csv.DictReader(reference)}
FAILED = "«{}»: {}"  # a dataset's label and why it is not imported
ALTERED = ("La descarga de su fuente nacional no coincide con la suma de verificación que fija la suite, así que no se "
           "importó. Presione «Reintentar»; si vuelve a ocurrir, contacte a APS Conecta.")
EMPTY = ("Su fuente nacional no tiene ningún registro de la comuna {} ({}), así que no se importó. Contacte a APS "
         "Conecta.")


class Refused(Exception):
    """A master that is not the one packages.json pins, or that holds nothing of the comuna; the message says why."""


def comuna(context):
    cut = context.centre["comuna_code"]
    return cut, COMUNA_NAMES[cut]


def settings(context):
    cut, name = comuna(context)
    return {"apps": {"territorio": {"comuna_cut": cut, "comuna_name": name}}}


def master(suite, pin):
    """The master's bytes from its origin, once their checksum is the pinned one."""
    data = suite.master(pin["origin"])
    if hashlib.sha256(data).hexdigest() != pin["sha256"]:
        raise Refused(ALTERED)
    return data


def clockwise(ring):
    return sum(x0 * y1 - x1 * y0 for (x0, y0), (x1, y1) in zip(ring, ring[1:])) < 0


def inside(point, ring):
    """Whether the point lies inside the ring, by the crossings of a ray from it."""
    x, y = point
    crossings = [x < x0 + (y - y0) * (x1 - x0) / (y1 - y0)
                 for (x0, y0), (x1, y1) in zip(ring, ring[1:]) if (y0 > y) != (y1 > y)]
    return sum(crossings) % 2 == 1


def geometry(record):
    """A shapefile record's shape as GeoJSON, None for a null or empty shape. As GDAL reads a polygon: its clockwise
    rings are outer, each other ring is a hole of the first outer ring around it, and one outer ring makes a Polygon,
    several a MultiPolygon; a polygon without a clockwise ring has only outer rings."""
    if struct.unpack_from("<i", record)[0] == 0 or not (parts := struct.unpack_from("<i", record, 36)[0]):
        return None
    count = struct.unpack_from("<i", record, 40)[0]
    starts = struct.unpack_from(f"<{parts}i", record, 44)
    xy = struct.unpack_from(f"<{2 * count}d", record, 44 + 4 * parts)
    points = [[xy[i], xy[i + 1]] for i in range(0, 2 * count, 2)]
    rings = [points[start:end] for start, end in zip(starts, starts[1:] + (count,))]
    outer = [clockwise(ring) for ring in rings]
    outer = outer if any(outer) else [True] * len(rings)
    polygons = [[ring] for ring, kind in zip(rings, outer) if kind]
    for hole in (ring for ring, kind in zip(rings, outer) if not kind):
        around = next((polygon for polygon in polygons if inside(hole[0], polygon[0])), None)
        polygons.append([hole]) if around is None else around.append(hole)
    return {"type": "Polygon", "coordinates": polygons[0]} if len(polygons) == 1 else {
        "type": "MultiPolygon", "coordinates": polygons}


def areas(archive, keep):
    """Each area of a zipped shapefile, the first one in the archive, whose attributes `keep` accepts: its attributes as
    text, by field name, and its shape. Its attributes are in the encoding its .cpg file names when that is UTF-8, else
    in Latin-1, GDAL's default; a deleted row is skipped."""
    with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
        shp = next(name for name in zipped.namelist() if name.lower().endswith(".shp"))
        beside = {name[len(shp) - 4:].lower(): name for name in zipped.namelist() if name[:len(shp) - 4] == shp[:-4]}
        cpg = zipped.read(beside[".cpg"]).strip().upper().replace(b"-", b"") if ".cpg" in beside else b""
        encoding = "utf-8" if cpg == b"UTF8" else "latin-1"
        with zipped.open(shp) as shapes, zipped.open(beside[".dbf"]) as table:
            shapes.read(100)
            rows, header, size = struct.unpack("<4xI2H20x", table.read(32))
            descriptors = table.read(header - 32)  # 32 bytes a field, up to the byte that ends them
            fields = [(field[:11].split(b"\0")[0].decode("latin-1"), field[11:12], field[16])
                      for field in itertools.takewhile(lambda field: field[:1] != b"\r", (
                          descriptors[i:i + 32] for i in range(0, len(descriptors), 32)))]
            for _ in range(rows):
                _, length = struct.unpack(">2i", shapes.read(8))
                record, row = shapes.read(2 * length), table.read(size)
                values, offset = {}, 1
                for name, kind, width in fields:
                    text = row[offset:offset + width].decode(encoding)
                    values[name], offset = text.rstrip() if kind == b"C" else text.strip(), offset + width
                if row[:1] != b"*" and keep(values):
                    yield values, geometry(record)


def unidades_vecinales(archive, cut):
    """The comuna's unidades vecinales: uid, name and the cadastre's taxonomy pair, with no other attribute of the
    cadastre, which Territorio would not map."""
    return [{"type": "Feature", "geometry": shape,
             "properties": {"uid": values["t_id_uv_ca"], "name": values.get("t_uv_nom", ""),
                            "category": "division_territorial", "subcategory": "unidad_vecinal"}}
            for values, shape in areas(archive, lambda values: values.get("t_com", "").strip().zfill(5) == cut)]


def kind(glosa):
    """The subcategory of an establishment by its type: the DEIS master writes the type in full, so it goes by the
    acronym within it."""
    glosa = glosa.upper()
    return "cesfam" if "CESFAM" in glosa else "sapu" if "SAPU" in glosa else "establecimiento"


def establishments(master, cut):
    """The comuna's establishments that have a point, from the DEIS master, semicolon-separated."""
    rows = csv.DictReader(io.StringIO(master.decode("utf-8-sig"), newline=""), delimiter=";")
    return [{"type": "Feature", "geometry": {"type": "Point", "coordinates": [float(lon), float(lat)]},
             "properties": {"uid": f"deis:{row['EstablecimientoCodigo']}", "name": row["EstablecimientoGlosa"],
                            "category": "salud", "subcategory": kind(row.get("TipoEstablecimientoGlosa") or ""),
                            "address": " ".join(part.strip() for part in (row.get(key) or "" for key in (
                                "TipoViaGlosa", "NombreVia", "Numero")) if part.strip())}}
            for row in rows if (row.get("ComunaCodigo") or "").strip().zfill(5) == cut
            and (lat := (row.get("Latitud") or "").strip()) and (lon := (row.get("Longitud") or "").strip())]


# Each Territorio dataset: its slug and label, the master it is cut from and how.
DATASETS = (("unidades-vecinales", "Unidades Vecinales", "unidades-vecinales-2024", unidades_vecinales),
            ("deis-establecimientos", "Establecimientos de salud", "minsal-deis-establecimientos", establishments))


def run(context):
    nextcloud = context.suite.nextcloud
    if wrong := configure(nextcloud, settings(context)):
        return wrong
    cut, name = comuna(context)
    reasons = []
    for dataset, label, source, cutter in DATASETS:
        try:
            if not (features := cutter(master(context.suite, MASTERS[source]), cut)):
                raise Refused(EMPTY.format(name, cut))
            nextcloud.occ("territorio:import", "/dev/stdin", f"--dataset={dataset}", f"--label={label}",
                          "--actor=Provisionador",
                          stdin=json.dumps({"type": "FeatureCollection", "comuna": cut, "features": features}))
        except (Refused, Unreachable) as failure:
            reasons.append(FAILED.format(label, failure))
    return reasons


def check(context):
    return differences(context.suite.nextcloud, settings(context))
