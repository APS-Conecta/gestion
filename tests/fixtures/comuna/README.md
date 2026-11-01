# Datos de prueba comunales

Clean boot utiliza estos subconjuntos para comprobar la descarga, el recorte y la importación. La captura corresponde al 2026-11-01.

| Archivo | Contenido | Fuente |
|---|---|---|
| `unidades-vecinales-v1.zip` | 345 áreas; se elige la de menor perímetro por comuna normalizada y se conserva su geometría | [MIDESOF, republicado por Esri Chile](https://services.arcgis.com/r7t1P5pnkoOLRdhr/ArcGIS/rest/services/Unidades_Vecinales___2024/FeatureServer/0) |
| `establecimientos-deis-v1.csv` | 344 establecimientos; un registro con coordenadas por comuna, con sus campos originales | [Ministerio de Salud](https://datos.gob.cl/dataset/establecimientos-de-salud-vigentes/resource/2c44d782-3365-44e3-aefb-2c8b8363a1bc) |
| `archive-uv-v1.geojson` | Un área del mismo subconjunto, convertida con GDAL para la comprobación local del comando | Mismo servicio de MIDESOF y Esri Chile |
| `expected-v1.json` | Nombres, identificadores, límites y coordenadas de los registros seleccionados, tomados de las fuentes para verificar la importación | Mismas fuentes de MIDESOF y DEIS |

La consulta de límites solicita EPSG:4326. GDAL convierte el subconjunto a Shapefile; los nombres, identificadores, códigos comunales y coordenadas se verifican contra la consulta.

Los límites de MIDESOF se distribuyen bajo [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/deed.es). APS Conecta selecciona registros y convierte el formato. El catálogo del Ministerio de Salud declara CCZero para los establecimientos.
