#!/usr/bin/env python3
"""Find an establishment in the DEIS register and write its site file (sites/<slug>/site.sh).

  scripts/deis.py                     interactive: search, then pick a number from the list
  scripts/deis.py cesfam florida      filter: every term must appear in the row (accent-blind)
  scripts/deis.py <codigo>            exact code: print that establishment's identity block
  scripts/deis.py <codigo> --new <slug>  write sites/<slug>/site.sh, asking what the register cannot
                                      know: which sectors and programs it has
  scripts/deis.py --snapshot <dir>    regenerate the register from a clone of the DEIS pipeline

No establishment ships with this repository; running this is how an install gets one, and the file it
writes is gitignored because its content depends on which establishment you chose.

The register is the newest sites/establecimientos-deis-*.csv: public primary-care establishments in
operation, trimmed to the ten columns an install needs. It carries the whole APS network — CESFAM,
PSR, CECOSF, CGR, CGU, COSAM, SAPU, SAR, SUR — and the filter is a plain term match, so `cesfam`
above is a search word and not a required type: `deis.py sapu florida` works the same way. The date
in the filename IS the provenance — never edit the file by hand, regenerate it with --snapshot.

Python, not bash: the CSV quotes fields that contain commas ("Sargento Aldea, Florida Alto"), and
awk -F, gets those wrong. python3 is already assumed by provisioning/lib.sh; jq is not.
"""
import csv
import glob
import os
import shlex
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
# The type sigla plus the long DEIS phrase it stands for — used to suggest a short display name.
SIGLA = {
    "CESFAM": "Centro de Salud Familiar",
    "CECOSF": "Centro Comunitario de Salud Familiar",
    "PSR": "Posta de Salud Rural",
    "CGR": "Consultorio General Rural",
    "CGU": "Consultorio General Urbano",
}


def fold(s):  # accent- and case-blind, so "julio cesar" finds "Julio César"
    return "".join(c for c in unicodedata.normalize("NFD", s.lower()) if not unicodedata.combining(c))


def load():
    files = sorted(glob.glob(os.path.join(HERE, "..", "sites", "establecimientos-deis-*.csv")))
    if not files:
        sys.exit("FATAL: no sites/establecimientos-deis-*.csv found")
    snapshot = os.path.basename(files[-1])[len("establecimientos-deis-"):-len(".csv")]
    with open(files[-1], encoding="utf-8") as fh:
        return snapshot, list(csv.DictReader(fh))


def snapshot_from(root):
    """Trim the DEIS pipeline's export down to the register this repo ships.

    KEPT: establishments in operation whose type comes from the primary-care codebook (CESFAM, PSR,
    CECOSF, CGR, CGU), plus COSAM, plus the primary-care urgency network (SAPU, SAR, SUR) — those
    are APS devices, usually dependent on a CESFAM. Dropped: the private sector, and hospitals with
    them, so hospital urgency (UEH) never appears — it is an attribute of the hospital, not a row of
    its own. Also dropped: the single SAMU row, a regional dispatch centre, not an establishment.

    The date comes from the pipeline's own data/raw/<date>/ capture, not from today's clock: the
    filename must name when MINSAL published, not when we happened to run this."""
    src = os.path.join(root, "exports", "salud_establecimiento.csv")
    if not os.path.isfile(src):
        sys.exit(f"FATAL: {src} not found — pass the root of an establecimientos-salud clone")
    captures = sorted(glob.glob(os.path.join(root, "data", "raw", "20*")))
    if not captures:
        sys.exit(f"FATAL: no data/raw/<date>/ under {root} — run `make fetch` there first")
    date = os.path.basename(captures[-1])

    out = os.path.join(HERE, "..", "sites", f"establecimientos-deis-{date}.csv")
    n = 0
    with open(src, encoding="utf-8") as fh, open(out, "w", newline="", encoding="utf-8") as dst:
        w = csv.writer(dst)
        w.writerow(["codigo", "tipo", "nombre", "direccion", "comuna_codigo", "comuna",
                    "region_codigo", "region", "servicio_salud", "dependencia"])
        for r in csv.DictReader(fh):
            tipo = r["tipo_estab_norma_codigo"] or r["tipo_estab_inferido_codigo"]
            glosa = r["tipo_estab_norma_glosa"] or r["tipo_estab_inferido_glosa"]
            origen = r["tipo_establecimiento_glosa_origen"]
            if r["esta_vigente"] != "true":
                continue
            urgencia = glosa == "Establecimientos Públicos de la Red de Urgencia"
            if r["tipo_estab_norma_campo"] != "TipoEstabPubAtenPrimCodigo" \
                    and "COSAM" not in glosa and not urgencia:
                continue
            if urgencia:
                # The norm gives the whole urgency network one code, and that code (3) collides with
                # "Centros de Salud Privados" in the private codebook. The sigla the DEIS writes in
                # its own glosa — "… de Urgencia (SAPU)" — is the only thing that tells them apart.
                sigla = origen[origen.rfind("(") + 1:origen.rfind(")")] if "(" in origen else ""
                if sigla == "SAMU":
                    continue
                tipo = sigla
            calle = " ".join(x for x in (r["tipo_via_glosa"], r["nombre_via"], r["numero"]) if x)
            w.writerow([r["establecimiento_codigo"], tipo, r["establecimiento_glosa"], calle.strip(),
                        r["comuna_codigo"], r["comuna_glosa_origen"], r["region_codigo"],
                        r["region_glosa_origen"], r["entidad_admin_glosa_origen"],
                        r["dependencia_administrativa"]])
            n += 1
    print(f"wrote {os.path.relpath(out, os.path.join(HERE, '..'))} — {n} establishments")
    print("delete the older establecimientos-deis-*.csv once the new one is verified")


def block(row, snapshot):
    short = row["nombre"]
    long_form = SIGLA.get(row["tipo"])
    if long_form and fold(short).startswith(fold(long_form)):
        short = f'{row["tipo"]} {short[len(long_form):].strip()}'
    # Quoted because seed.sh SOURCES this: a `"` or a backtick in a register value is
    # shell syntax, not data. Six values in the register are: DEIS 113314's backtick is a
    # syntax error, DEIS 201079's quotes parse clean and leave SITE_NOMBRE EMPTY.
    # Not codigo/tipo — digits and a nine-word enum, so quoting them is a zero-delta edit.
    q = shlex.quote
    return f"""# --- Identity — DEIS {row['codigo']}, snapshot {snapshot} (scripts/deis.py {row['codigo']}) ---
SITE_DEIS={row['codigo']}
SITE_TIPO={row['tipo']}
SITE_NOMBRE={q(row['nombre'])}
SITE_NOMBRE_CORTO={q(short)}
SITE_DIRECCION={q(row['direccion'])}
SITE_COMUNA={q(row['comuna'])}
SITE_SERVICIO_SALUD={q(row['servicio_salud'])}
"""


def matches(rows, terms):
    return [r for r in rows if all(t in fold(",".join(r.values())) for t in terms)]


def ask(question, word, gid_prefix):
    """What neither the register nor the type can tell us: how many sectors and programs there are
    and what they are called. Sectors are numbered here, coloured there, named after a neighbourhood
    somewhere else — so ask. Returns (gid, display, bare) per line, empty line to finish.

    "Estrella", "Sector Estrella" and "SECTOR estrella" all land on the same three strings, so it
    does not matter whether the operator repeats the word."""
    print(f"\n{question} (one per line, blank line to finish)")
    out = []
    while True:
        try:
            name = input(f"  {len(out) + 1}: ").strip()
        except EOFError:  # answers piped in and exhausted — a traceback would bury the real cause
            sys.exit(f"\nFATAL: input ended while asking: {question}")
        if not name:
            return out
        bare = name[len(word):].strip() if fold(name).startswith(word) else name
        out.append((gid_prefix + "-".join(fold(bare).split()), f"{word.capitalize()} {bare}", bare))


def write_site(row, snapshot, name, sectors, programs):
    """Write a COMPLETE, standalone site file. Nothing is inherited at seed time: after this, the
    file is the whole truth for that clinic and is edited by hand — adding a Unidad or a grant is
    adding a line. Adding a folder later also means adding its ACL rows; nothing generates them."""
    path = os.path.join(HERE, "..", "sites", name, "site.sh")
    if os.path.exists(path):
        sys.exit(f"FATAL: {os.path.relpath(path)} already exists — edit it, or remove the directory")
    os.makedirs(os.path.dirname(path), exist_ok=True)

    # The units are the one part taken on faith: most primary-care establishments have these, so
    # they are not worth a prompt. Which ones the tree really carries, and which role manages each,
    # is settled with the clinic — by editing the file this writes.
    q = shlex.quote
    units = [("SOME", "role-administrativo-some"), ("Farmacia", "role-quimico-farmaceutico role-tens-farmacia"),
                ("Dental", "role-dentista role-tons"), ("OIRS", "role-oirs"),
                ("Estadística-REM", "role-estadistica-rem"), ("Dirección", "")]
    teams = [q(f"{gid}|{display}") for gid, display, _ in programs + sectors]
    folders = ["Transversal"] + [f"Programas/{bare}" for _, _, bare in programs]
    folders += [f"Unidades/{u}" for u, _ in units] + [f"Sectores/{d}" for _, d, _ in sectors]

    # Two levels, and the empty string is the point: phase 40 passes the third field UNQUOTED to
    # gf_grant, so "" reaches it as no permission words at all — a bare grant, which is READ (#116).
    # Every clinic written before 2026-08-01 got P on every row; that was the temporary widening for
    # the tree reorganisation and it is over.
    P, R = "read write delete", ""
    acl = [f"Transversal|all-staff|{R}",          # staff read the shared area...
           f"Transversal|cat-jefaturas|{P}"]      # ...Jefaturas curate it
    for gid, _, bare in programs:
        acl += [f"Programas/{bare}|{gid}|{P}", f"Programas/{bare}|cat-jefaturas|{P}"]
    for unit, roles in units:
        # A Jefatura READS a unit that has an owning role and MANAGES one that does not. Keyed on
        # `roles` rather than on the name "Dirección", so a clinic that adds an unowned unit gets the
        # right answer without editing this, and one that gives Dirección an owner does too.
        acl += [f"Unidades/{unit}|{r}|{P}" for r in roles.split()]
        acl += [f"Unidades/{unit}|cat-jefaturas|{R if roles.split() else P}"]
    for gid, display, _ in sectors:
        acl += [f"Sectores/{display}|{gid}|{P}", f"Sectores/{display}|cat-jefaturas|{P}"]

    nl = "\n  "
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(f"""# {row['nombre']} — everything about this establishment that the provisioning phases read.
# Written by scripts/deis.py; edited by hand from here on. Sourced once by seed.sh, before the
# phase loop, so every phase sees it and none of it can leak back out.
# NOT TRACKED: this file is yours, gitignored like .env, and survives a git pull untouched.

{block(row, snapshot)}
# Forward hook for the production posture (#75). Empty = local dev, reached over the host port.
SITE_DOMINIO=""

# Staff roster, kept OUTSIDE the repo. Path on the install host. Nothing reads it yet — the reader
# waits on password delivery (#106).
SITE_ROSTER=""

# --- Teams: programs and territorial sectors (id|display) ---
SITE_TEAMS=(
  {nl.join(teams)}
)

# --- Roles this establishment adds beyond the 22 in the shared registry (id|display|category) (#103) ---
# Empty is the right default: those 22 are a CESFAM's standard positions and cover an establishment
# with no local unit of its own. Add one here if this one runs a SAR, SAPU or SUR, e.g.
#   "role-jefe-sar|Jefe/a de SAR|cat-jefaturas"    <- gets a standing account, like the other jefaturas
#   "role-tens-sar|TENS – SAR|cat-tecnicos"        <- a job title; the people arrive with the roster
# The category is which cat-* an account holding the role must also join, and it is what carries the
# access. Only the four shared categories are accepted; phase 20 fails loudly on anything else.
SITE_ROLES=()

# --- Group folders. They cannot nest; the slashes only give the tree look. ---
SITE_FOLDERS=(
  {nl.join(q(f) for f in folders)}
)

SITE_SUBFOLDERS=( "Protocolos" "Flujogramas" "Documentación" "Registro de redes" "Actas de reuniones" )

# --- Access matrix: mount|group|perms. Three fields ALWAYS; an empty third = read-only. ---
# Staff READ Transversal and the Jefaturas curate it; a Jefatura READS a Unidad that has an owning
# role and manages one that does not. Anything granted on these folders and not listed here is
# revoked (gf_prune).
SITE_ACL=(
  {nl.join(q(a) for a in acl)}
)
""")
    print(f"wrote {os.path.relpath(path, os.path.join(HERE, '..'))} — "
          f"{len(folders)} folders, {len(teams)} teams, {len(acl)} grants")


def main(argv):
    if argv and argv[0] == "--snapshot":
        if len(argv) != 2:
            sys.exit(__doc__)
        return snapshot_from(argv[1])

    snapshot, rows = load()

    if argv and argv[0].isdigit():
        hit = [r for r in rows if r["codigo"] == argv[0]]
        if not hit:
            sys.exit(f"FATAL: no establishment with DEIS code {argv[0]} in the {snapshot} snapshot")
        if len(argv) == 3 and argv[1] == "--new":
            write_site(hit[0], snapshot, argv[2],
                       ask("Territorial sectors?", "sector", "sector-"),
                       ask("Programs?", "programa", "prog-"))
        elif len(argv) == 1:
            print(block(hit[0], snapshot))
        else:
            sys.exit(__doc__)
        return

    terms = [fold(t) for t in argv]
    if not terms:
        terms = [fold(t) for t in input("Search (type, comuna, name — space separated): ").split()]
    found = matches(rows, terms)
    if not found:
        sys.exit("No matches. Try fewer terms.")
    for i, r in enumerate(found[:40], 1):
        print(f'{i:3}. {r["codigo"]}  {r["tipo"]:<7} {r["nombre"][:48]:<48} {r["comuna"]}, {r["region"]}')
    if len(found) > 40:
        print(f"... and {len(found) - 40} more — narrow the search.")
        return
    if argv:  # non-interactive: the list is the answer
        return
    pick = input("\nNumber (Enter to quit): ").strip()
    if pick.isdigit() and 1 <= int(pick) <= len(found):
        print()
        print(block(found[int(pick) - 1], snapshot))


if __name__ == "__main__":
    main(sys.argv[1:])
