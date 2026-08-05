# Centro de Salud Familiar Los Castaños — this clinic's record, and the structure the provisioning
# phases build from it. The identity block below is a RECORD: `scripts/deis.py` writes all seven
# fields from the official DEIS register, and provisioning reads two of them (SITE_NOMBRE and
# SITE_NOMBRE_CORTO). The other five are kept on purpose — they are how an operator standing up a
# second clinic confirms they edited the right file — and are not a promise that code consumes them.
# Written by scripts/deis.py; edited by hand from here on. Sourced once by seed.sh, before the
# phase loop, so every phase sees it and none of it can leak back out.

# --- Identity — DEIS 114302, snapshot 2026-07-23 (scripts/deis.py 114302) ---
SITE_DEIS=114302
SITE_TIPO=CESFAM
SITE_NOMBRE="Centro de Salud Familiar Los Castaños"
SITE_NOMBRE_CORTO="CESFAM Los Castaños"
SITE_DIRECCION="Calle Diagonal Los Castaños 5820"
SITE_COMUNA="La Florida"
SITE_SERVICIO_SALUD="Servicio de Salud Metropolitano Sur Oriente"

# Forward hook for the production posture (#75). Empty = local dev, reached over the host port.
SITE_DOMINIO=""

# Staff roster, kept OUTSIDE the repo. Path on the install host. Nothing reads it yet — the reader
# waits on password delivery (#106).
SITE_ROSTER=""

# --- Teams: programs and territorial sectors (id|display) ---
SITE_TEAMS=(
  "prog-salud-mental|Programa Salud Mental"
  "prog-infantil|Programa Infantil"
  "prog-cardiovascular|Programa Cardiovascular"
  "sector-estrella|Sector Estrella"
  "sector-lucero|Sector Lucero"
  "sector-sol|Sector Sol"
  "sector-luna|Sector Luna"
)

# --- Roles this clinic adds beyond the 22 every CESFAM has (id|display|category) (#103) ---
# Empty because Los Castaños has no SAR, SAPU or SUR — every position it carries is already in the
# shared registry. A clinic that runs one declares its people here, e.g.
#   "role-jefe-sar|Jefe/a de SAR|cat-jefaturas"    <- gets a standing account, like the other jefaturas
#   "role-tens-sar|TENS – SAR|cat-tecnicos"        <- a job title; the people arrive with the roster
# The category is which cat-* an account holding the role must also join. It is what carries the
# access: grants target cat-* wherever possible, so a new lead inherits them without an ACL edit.
# Only the four shared categories are accepted; phase 20 fails loudly on anything else.
SITE_ROLES=()

# --- Group folders. They cannot nest; the slashes only give the tree look. ---
SITE_FOLDERS=(
  "Transversal"
  "Programas/Salud Mental"
  "Programas/Infantil"
  "Programas/Cardiovascular"
  "Unidades/SOME"
  "Unidades/Farmacia"
  "Unidades/Dental"
  "Unidades/OIRS"
  "Unidades/Estadística-REM"
  "Unidades/Dirección"
  "Sectores/Sector Estrella"
  "Sectores/Sector Lucero"
  "Sectores/Sector Sol"
  "Sectores/Sector Luna"
)

SITE_SUBFOLDERS=( "Protocolos" "Flujogramas" "Documentación" "Registro de redes" "Actas de reuniones" )

# --- Access matrix: mount|group|perms. Three fields ALWAYS; an empty third = read-only. ---
# Six rows are read-only (#116): staff READ Transversal and the Jefaturas manage it; a Jefatura reads
# a Unidad it does not own while the owning role manages it. Model: provisioning/phases/40-acl.sh.
# Unidades/Dirección keeps cat-jefaturas at manage on purpose: it is the Jefaturas' own folder.
# Anything granted on these folders and not listed here is revoked (gf_prune).
SITE_ACL=(
  "Transversal|all-staff|"
  "Transversal|cat-jefaturas|read write delete"
  "Programas/Salud Mental|prog-salud-mental|read write delete"
  "Programas/Salud Mental|cat-jefaturas|read write delete"
  "Programas/Infantil|prog-infantil|read write delete"
  "Programas/Infantil|cat-jefaturas|read write delete"
  "Programas/Cardiovascular|prog-cardiovascular|read write delete"
  "Programas/Cardiovascular|cat-jefaturas|read write delete"
  "Unidades/SOME|role-administrativo-some|read write delete"
  "Unidades/SOME|cat-jefaturas|"
  "Unidades/Farmacia|role-quimico-farmaceutico|read write delete"
  "Unidades/Farmacia|role-tens-farmacia|read write delete"
  "Unidades/Farmacia|cat-jefaturas|"
  "Unidades/Dental|role-dentista|read write delete"
  "Unidades/Dental|role-tons|read write delete"
  "Unidades/Dental|cat-jefaturas|"
  "Unidades/OIRS|role-oirs|read write delete"
  "Unidades/OIRS|cat-jefaturas|"
  "Unidades/Estadística-REM|role-estadistica-rem|read write delete"
  "Unidades/Estadística-REM|cat-jefaturas|"
  "Unidades/Dirección|cat-jefaturas|read write delete"
  "Sectores/Sector Estrella|sector-estrella|read write delete"
  "Sectores/Sector Estrella|cat-jefaturas|read write delete"
  "Sectores/Sector Lucero|sector-lucero|read write delete"
  "Sectores/Sector Lucero|cat-jefaturas|read write delete"
  "Sectores/Sector Sol|sector-sol|read write delete"
  "Sectores/Sector Sol|cat-jefaturas|read write delete"
  "Sectores/Sector Luna|sector-luna|read write delete"
  "Sectores/Sector Luna|cat-jefaturas|read write delete"
)
