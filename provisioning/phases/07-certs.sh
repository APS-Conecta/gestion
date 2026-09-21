# Phase 07 — TLS intermediates the hosts we read refuse to serve.  OWNER: #28.
# Before 12-apps, because epidemiologia is installed there and loses the ISP's alert feeds without this.
phase_begin "07-certs" "intermediate CAs for hosts that serve only their leaf"

# The host below serves ONLY its leaf certificate. A browser hides that by chasing the leaf's
# authorityInfoAccess pointer; a server-side client does not, so Nextcloud's IClientService fails
# verification and the fetch returns nothing at all. Measured inside this container 2026-08-02:
# ssl_verify_result=20 before, 0 after.
#
#   www.ispch.gob.cl   the ISP's 24 ANAMED alert feeds — sanitary alerts, drug and device recalls.
#                      National: every install reads the same host, so the list is product code.
#
# Regional hosts are deliberately absent. Which regional sources an establishment reads is
# instance configuration (ADR-0013), and no suite app consumes one today; when one grows a
# regional consumer, its hostname arrives through that app's own config seam — this list stays
# national-only in every commit.
#
# The fix belongs in provisioning, not in an app: `occ security:certificates:import` APPENDS to the
# bundle Nextcloud ships (CertificateManager::createCertificateBundle) and IClientService picks it
# up through getAbsoluteBundlePath(), so one import serves News and every custom app at once. No
# Dockerfile, no update-ca-certificates, no rebuild.
#
# The bundle lands in the data volume (data/files_external/rootcerts.crt): it survives a restart
# but NOT a volume wipe, which is exactly why this is a phase and not a one-off command.
#
# NEVER disable verification instead. A CA that cannot be verified is a CA that cannot be trusted,
# and `verify=False` would apply to every host, not just to this one.
for host in www.ispch.gob.cl; do
  ensure_aia_intermediate "$host"
done

phase_end
