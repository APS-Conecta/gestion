# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Full-text search, vanilla's: AIO's switch (the components step) starts its Elasticsearch, and AIO's Nextcloud
container sets up fulltextsearch, its Elasticsearch connector and the files provider at its start and indexes the
files, and vanilla's index job, which AIO's cron runs, indexes each new one; when Elasticsearch does not answer that
start in time, it leaves the three apps off instead, and the step fails. The files provider is our fork, which finds a
document for a user ID with a dot, as staff's are (ADR 0023): the step comes after the apps step, which installs it in
place of the store's. Its part of the end-of-install check: the three apps still on."""

from steps import differences

NAME = "Búsqueda de texto completo"
NEEDS = ("apps",)
ON = {"apps": dict.fromkeys(("fulltextsearch", "fulltextsearch_elasticsearch", "files_fulltextsearch"),
                            {"enabled": "yes"})}
OFF = ("La búsqueda de texto completo no quedó activa en Nextcloud: AIO la desactiva cuando su contenedor no responde "
       "a tiempo al iniciarse Nextcloud. Contacte a APS Conecta.")


def run(context):
    return [OFF] if differences(context.suite.nextcloud, ON) else []


check = run
