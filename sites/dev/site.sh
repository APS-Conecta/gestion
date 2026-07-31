# SYNTHETIC dev site — not a real CESFAM, and no real CESFAM is committed here.
# Its job is to give `make seed`, the idempotency gate and the clean-boot job a site to run against
# on a fresh clone, exercising every shape a real one has (NFR-2: synthetic fixtures only).
#
# For a real clinic, write your own and point SITE at it — the register is already in the repo:
#   scripts/deis.py cesfam <comuna>          # find the DEIS code
#   scripts/deis.py <codigo> --new <slug>    # writes sites/<slug>/site.sh
#
# Sourced once by seed.sh, before the phase loop; every phase sees it, none can write back.

# --- Identity. No DEIS code: this establishment does not exist. ---
SITE_DEIS=
SITE_TIPO=CESFAM
SITE_NOMBRE="Centro de Salud Familiar de Prueba"
SITE_NOMBRE_CORTO="CESFAM de Prueba"
SITE_DIRECCION="Calle Falsa 123"
SITE_COMUNA="Comuna de Prueba"
SITE_SERVICIO_SALUD="Servicio de Salud de Prueba"

# Forward hook for the production posture (#75). Empty = local dev, reached over the host port.
SITE_DOMINIO=""

# Staff roster, kept OUTSIDE the repo. Path on the install host; empty = no staff phase.
SITE_ROSTER=""

# --- Teams: programs and territorial sectors (id|display) ---
SITE_TEAMS=(
  "prog-salud-mental|Programa Salud Mental"
  "prog-infantil|Programa Infantil"
  "prog-cardiovascular|Programa Cardiovascular"
  "sector-1|Sector 1"
  "sector-2|Sector 2"
)

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
  "Sectores/Sector 1"
  "Sectores/Sector 2"
)

SITE_SUBFOLDERS=( "Protocolos" "Flujogramas" "Documentación" "Registro de redes" "Actas de reuniones" )

# --- Access matrix: mount|group|perms. Three fields ALWAYS; an empty third = read-only. ---
# TEMPORARY: every row is "read write delete" while the tree is reorganised, including the ones
# meant to be read-only (all-staff on Transversal, cat-jefaturas on the Unidades).
# Anything granted on these folders and not listed here is revoked (gf_prune).
SITE_ACL=(
  "Transversal|all-staff|read write delete"
  "Transversal|cat-jefaturas|read write delete"
  "Programas/Salud Mental|prog-salud-mental|read write delete"
  "Programas/Salud Mental|cat-jefaturas|read write delete"
  "Programas/Infantil|prog-infantil|read write delete"
  "Programas/Infantil|cat-jefaturas|read write delete"
  "Programas/Cardiovascular|prog-cardiovascular|read write delete"
  "Programas/Cardiovascular|cat-jefaturas|read write delete"
  "Unidades/SOME|role-administrativo-some|read write delete"
  "Unidades/SOME|cat-jefaturas|read write delete"
  "Unidades/Farmacia|role-quimico-farmaceutico|read write delete"
  "Unidades/Farmacia|role-tens-farmacia|read write delete"
  "Unidades/Farmacia|cat-jefaturas|read write delete"
  "Unidades/Dental|role-dentista|read write delete"
  "Unidades/Dental|role-tons|read write delete"
  "Unidades/Dental|cat-jefaturas|read write delete"
  "Unidades/OIRS|role-oirs|read write delete"
  "Unidades/OIRS|cat-jefaturas|read write delete"
  "Unidades/Estadística-REM|role-estadistica-rem|read write delete"
  "Unidades/Estadística-REM|cat-jefaturas|read write delete"
  "Unidades/Dirección|cat-jefaturas|read write delete"
  "Sectores/Sector 1|sector-1|read write delete"
  "Sectores/Sector 1|cat-jefaturas|read write delete"
  "Sectores/Sector 2|sector-2|read write delete"
  "Sectores/Sector 2|cat-jefaturas|read write delete"
)
