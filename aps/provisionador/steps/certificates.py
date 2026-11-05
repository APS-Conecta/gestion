# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The CAs that Nextcloud's own requests trust beside the ones it ships. Those of AIO's own folder of trusted CAs,
which AIO gives the Nextcloud and Talk containers but which Nextcloud's HTTP client does not read: a test build's Let's
Encrypt staging roots, so that Nextcloud's calls to the suite's own name verify its certificate as a release's verify
Let's Encrypt's; a release has none. And the CA that issued the certificate of the ISP's www.ispch.gob.cl, whose feeds
carry the national sanitary alerts: the site serves only its leaf, which browsers complete and Nextcloud's requests
cannot. That part only warns, so that the ISP's site being down never stops an install."""

from steps import Notice
from suite import Unreachable

NAME = "Certificados de confianza"
NEEDS = ("start",)
ISP = "www.ispch.gob.cl"
ISP_UNTRUSTED = ("No se pudo obtener ni verificar el certificado intermedio de {}, así que Nextcloud no podrá descargar "
                 "las alertas sanitarias del ISP. La instalación continúa sin él; contacte a APS Conecta.")


def run(context):
    context.suite.nextcloud.trust_cacerts()
    try:
        context.suite.nextcloud.trust_issuer(ISP)
    except Unreachable:
        return [Notice(ISP_UNTRUSTED.format(ISP))]
