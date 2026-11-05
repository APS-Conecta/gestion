// SPDX-FileCopyrightText: 2026 APS Conecta
// SPDX-License-Identifier: AGPL-3.0-or-later
// The Provisionador's page: it exchanges the link's secret (the URL fragment, never sent in a request line) for a
// session, then drives «Centro», «Dirección», «Revisar» and «Instalar» through the HTTP API, until «Listo».
"use strict";

// AIO's interface enforces Trusted Types; on the Provisionador's routes it also allows a default policy
// (provisionador.Caddyfile). The policy lets through only the HTML Leaflet writes for this page's map: its inline-SVG
// probe when it loads and the zoom buttons' labels. So this script runs before leaflet.js.
const ZOOM_IN = "+";
const ZOOM_OUT = "−";
if (window.trustedTypes) {
  const leaflet = new Set(["<svg/>", ZOOM_IN, ZOOM_OUT]);
  window.trustedTypes.createPolicy("default", {createHTML: (html) => (leaflet.has(html) ? html : null)});
}

const $ = (id) => document.getElementById(id);
const CHILE = [-35.7, -71.5];
const PUBLISHING = 5000; // between two readings of whether the name's nameservers publish the server's address
const NEXT_LOOK = 15000;
const PROGRESS = 3000; // between two readings of the install's progress
const STATES = {stopped: "Detenido", starting: "Iniciando", running: "En ejecución"}; // as AIO's page names them
const STEP_STATES = {pending: "Pendiente", running: "En curso", green: "Completado", failed: "No se completó",
  waiting: "En espera"};
let register = null;
let selected = null;
let map = null;
let marker = null;
let searching = null;
let looking = null;
let polling = null;

async function api(method, path, body) {
  let response;
  let answer;
  try {
    response = await fetch(path, {
      method,
      headers: body ? {"Content-Type": "application/json"} : {},
      body: body ? JSON.stringify(body) : undefined,
    });
    answer = await response.json();
  } catch {
    throw new Error("No se pudo comunicar con el Provisionador. Revise la conexión e intente nuevamente.");
  }
  if (!response.ok) throw new Error(answer.error || "Ocurrió un error inesperado. Intente nuevamente.");
  return answer;
}

function element(tag, text) {
  const node = document.createElement(tag);
  node.textContent = text;
  return node;
}

function say(text, isError = false, id = "message") {
  $(id).textContent = text;
  $(id).classList.toggle("error", isError);
}

function locked(message) {
  $("locked-message").textContent = message;
  $("locked").hidden = false;
}

function show(screen) {
  for (const id of ["centro", "direccion", "revisar", "listo"]) $(id).hidden = id !== screen;
}

function fillFilters() {
  const form = $("search");
  for (const r of register.regions) form.region.append(Object.assign(element("option", r.name), {value: r.code}));
  for (const t of register.types) form.type.append(Object.assign(element("option", t.name), {value: t.code}));
  fillComunas();
}

function fillComunas() {
  const form = $("search");
  form.comuna.length = 1;
  for (const c of register.comunas) {
    if (!form.region.value || c.region === form.region.value) {
      form.comuna.append(Object.assign(element("option", c.name), {value: c.code}));
    }
  }
}

function search() {
  clearTimeout(searching);
  searching = setTimeout(async () => {
    try {
      showResults(await api("GET", "/api/establishments?" + new URLSearchParams(new FormData($("search")))));
    } catch (e) {
      say(e.message, true);
    }
  }, 200);
}

function typeName(code) {
  return (register.types.find((t) => t.code === code) || {name: code}).name;
}

function showResults(found) {
  $("total").textContent = found.total === 0 ? "Ningún establecimiento coincide con la búsqueda."
    : found.total > found.rows.length
      ? `Se muestran ${found.rows.length} de ${found.total} establecimientos. Precise la búsqueda para encontrar el suyo.`
      : `${found.total} ${found.total === 1 ? "establecimiento" : "establecimientos"}.`;
  $("results").replaceChildren(...found.rows.map((row) => {
    const button = document.createElement("button");
    button.type = "button";
    button.dataset.code = row.code;
    button.setAttribute("aria-pressed", String(selected?.code === row.code));
    button.append(element("strong", row.name),
      element("span", `${typeName(row.type)} · ${row.comuna} · ${row.address}`));
    button.addEventListener("click", () => select(row, row.point));
    const item = document.createElement("li");
    item.append(button);
    return item;
  }));
}

// `establishment.point` is the register's official point; `point` is where the marker goes.
function select(establishment, point) {
  selected = establishment;
  place(point);
  map.setView([point.latitude, point.longitude], 16);
  for (const b of $("results").querySelectorAll("button")) {
    b.setAttribute("aria-pressed", String(b.dataset.code === establishment.code));
  }
  $("map-note").textContent = `${establishment.name}. Si el marcador no está sobre el establecimiento, `
    + "haga clic en el lugar correcto o arrástrelo.";
  $("confirm").disabled = false;
  $("reset").disabled = false;
  say("");
}

// The marker's icon is an element, never HTML text, so Leaflet appends it instead of writing innerHTML.
function place(point) {
  const at = [point.latitude, point.longitude];
  if (marker) {
    marker.setLatLng(at);
    return;
  }
  const pin = document.createElement("span");
  pin.className = "pin";
  const icon = L.divIcon({className: "pin-icon", html: pin, iconSize: [22, 22]});
  marker = L.marker(at, {draggable: true, icon, title: "Ubicación del establecimiento"}).addTo(map);
}

function confirmed(centre) {
  say(`Centro confirmado: ${centre.name}, ${centre.comuna}. Zona horaria: ${centre.timezone}.`);
}

async function confirm() {
  const at = marker.getLatLng().wrap();
  const round = (degrees) => Math.round(degrees * 1e6) / 1e6;
  try {
    await api("POST", "/api/centre", {code: selected.code, point: {latitude: round(at.lat), longitude: round(at.lng)}});
  } catch (e) {
    return say(e.message, true);
  }
  direccion();
}

// «Dirección»: the Provisionador claims the centre's APS name, sets the suite up to serve it and points it at the
// server's address. A name already held or an outage comes with «Reintentar».
async function direccion() {
  show("direccion");
  $("retry").hidden = true;
  say("Obteniendo la dirección del establecimiento…", false, "address-status");
  let address;
  try {
    ({address} = await api("POST", "/api/address", {}));
  } catch (e) {
    say(e.message, true, "address-status");
    $("retry").hidden = false;
    return;
  }
  addressed(address);
}

function addressed(address) {
  $("address-name").textContent = `https://${address.name}`;
  say("Dirección asignada. Apunta a este servidor en la red del establecimiento.", false, "address-status");
  $("direccion-next").hidden = false;
  reach(address);
}

// The browser asks its resolver for the name only once every nameserver of the name's zone publishes the server's
// address, as the Provisionador reads them: a resolver asked before keeps finding nothing for the zone's SOA minimum,
// 30 minutes.
function reach(address) {
  clearTimeout(looking);
  if (address.published) {
    say(`Comprobando que este equipo encuentra el servidor en ${address.name}…`, false, "reach");
    look(address.name);
    return;
  }
  say("La dirección se está publicando en internet. Cuando esté publicada, esta página comprobará por sí sola que "
    + "este equipo encuentra el servidor en ella.", false, "reach");
  looking = setTimeout(async () => {
    try {
      reach((await api("GET", "/api/state")).address);
    } catch (e) {
      say(e.message, true, "reach");
    }
  }, PUBLISHING);
}

// The browser asks for this interface at the name. When this network's resolver answers the server's address, the
// request reaches the server, which tells; a resolver that drops answers pointing to private addresses keeps it away.
// The request itself fails: the interface's certificate is AIO's own, which this browser accepted for the link only.
async function look(name) {
  await fetch(`https://${name}:${location.port || 443}/`, {
    mode: "no-cors", cache: "no-store", signal: AbortSignal.timeout(8000),
  }).catch(() => {});
  let address;
  try {
    ({address} = await api("GET", "/api/state"));
  } catch (e) {
    return say(e.message, true, "reach");
  }
  if (address.opened) {
    return say(`Este equipo encuentra el servidor en ${name}.`, false, "reach");
  }
  say(`Este equipo no encuentra el servidor en ${name}: el DNS de esta red descarta las respuestas que apuntan a `
    + `direcciones internas. En el router, permita esas respuestas para ${name.split(".").slice(1).join(".")} (una `
    + "excepción a la protección contra «DNS rebinding») y vuelva a conectar este equipo a la red. Esta página lo "
    + "comprobará de nuevo por sí sola.", true, "reach");
  looking = setTimeout(() => look(name), NEXT_LOOK);
}

// «Revisar»: the centre, its name and timezone, what «Instalar» sets up beside them, and the optional apps, off by
// default.
async function revisar() {
  try {
    review(await api("GET", "/api/state"));
  } catch (e) {
    say(e.message, true, "reach");
  }
}

function review(state) {
  const {centre, address, review: chosen} = state;
  const suite = `https://${address.name}`;
  clearTimeout(looking);
  $("summary-centre").textContent = `${centre.name}, ${centre.comuna}, región ${centre.region} (código DEIS `
    + `${centre.code})`;
  $("summary-address").textContent = suite;
  $("summary-timezone").textContent = centre.timezone;
  $("summary-components").replaceChildren(...chosen.components.map((name) => element("li", name)));
  $("summary-backup").textContent = `Cada noche, a las ${chosen.backup.time} UTC, en la carpeta `
    + `${chosen.backup.folder} del servidor.`;
  $("optional-apps").replaceChildren(...chosen.optional_apps.map(choice));
  Object.assign($("suite-address"), {textContent: suite, href: suite});
  show("revisar");
  if (state.install) progress(state.install);
}

function choice(app) {
  const box = Object.assign(document.createElement("input"), {type: "checkbox", id: `optional-${app.id}`,
    value: app.id});
  const label = document.createElement("label");
  label.className = "choice";
  label.append(box, element("strong", app.name), element("span", app.summary));
  return label;
}

function ticked() {
  return [...$("optional-apps").querySelectorAll("input:checked")].map((box) => box.value);
}

// «Instalar», and «Reintentar» after a failure: the Provisionador sets AIO up and starts the suite, with the optional
// apps ticked at the first «Instalar».
async function install() {
  $("install").disabled = true;
  say("Iniciando la instalación…", false, "install-status");
  try {
    progress((await api("POST", "/api/install", {optional: ticked()})).install);
  } catch (e) {
    $("install").disabled = false;
    say(e.message, true, "install-status");
  }
}

function item(name, state, label, reason) {
  const node = document.createElement("li");
  node.dataset.state = state;
  node.append(element("strong", name), element("span", label));
  if (reason) node.append(element("p", reason));
  return node;
}

// Each step as the Provisionador declares it, a failed or waiting one in red with its reason, and each container of
// the suite as AIO reads it, until «Listo» or a failure; «Reintentar» runs the failed and waiting steps again.
function progress(install) {
  for (const box of $("optional-apps").querySelectorAll("input")) {
    Object.assign(box, {checked: install.optional.includes(box.value), disabled: true});
  }
  $("steps").replaceChildren(...install.steps.map(
    (step) => item(step.name, step.status, STEP_STATES[step.status], step.reason)));
  $("progress").replaceChildren(...install.containers.map((c) => item(c.name, c.state, STATES[c.state])));
  const failed = install.status === "failed";
  $("install").disabled = !failed;
  $("install").textContent = failed ? "Reintentar" : "Instalar";
  if (failed) {
    return say("Algunos pasos no se completaron; su motivo aparece en rojo. Presione «Reintentar».", true,
      "install-status");
  }
  say(install.error || "Instalando la suite: cada paso sigue por sí solo. «Listo» aparece cuando todos estén completos.",
    false, "install-status");
  clearTimeout(polling);
  polling = setTimeout(poll, PROGRESS);
}

async function poll() {
  let state;
  try {
    state = await api("GET", "/api/state");
  } catch (e) {
    if (await closed()) return show("listo");
    say(e.message, true, "install-status");
    polling = setTimeout(poll, PROGRESS);
    return;
  }
  progress(state.install);
}

// «Listo» hands this address to AIO's page, which answers its root with a redirect, where the Provisionador served
// this page.
async function closed() {
  const answer = await fetch("/", {redirect: "manual", cache: "no-store"}).catch(() => null);
  return answer?.type === "opaqueredirect";
}

// Leaflet's own attribution control writes HTML, so the page shows OpenStreetMap's under the map.
function startMap() {
  map = L.map("map", {attributionControl: false, zoomControl: false}).setView(CHILE, 4);
  L.control.zoom({zoomInText: ZOOM_IN, zoomOutText: ZOOM_OUT, zoomInTitle: "Acercar", zoomOutTitle: "Alejar"})
    .addTo(map);
  // crossOrigin: AIO's interface requires CORS or CORP of what it embeds (COEP), and the tiles answer CORS.
  // referrerPolicy: OpenStreetMap's tile policy requires a Referer, which AIO's no-referrer policy drops; the tiles
  // get the page's origin only.
  const tiles = L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png",
    {maxZoom: 19, crossOrigin: true, referrerPolicy: "strict-origin"});
  tiles.once("tileerror", () => {
    $("map-error").hidden = false;
  });
  tiles.addTo(map);
  map.on("click", (e) => selected && place({latitude: e.latlng.lat, longitude: e.latlng.lng}));
}

async function start() {
  const code = location.hash.slice(1);
  if (code) {
    history.replaceState(null, "", location.pathname);
    try {
      await api("POST", "/api/session", {link: code});
    } catch (e) {
      return locked(e.message);
    }
  }
  $("retry-button").addEventListener("click", direccion);
  $("to-revisar").addEventListener("click", revisar);
  $("install").addEventListener("click", install);
  let state;
  try {
    state = await api("GET", "/api/state");
    if (state.install) return review(state);
    if (state.address) {
      show("direccion");
      return addressed(state.address);
    }
    register = await api("GET", "/api/register");
  } catch (e) {
    return locked(e.message);
  }
  $("register-date").textContent = ` del ${register.date.split("-").reverse().join("-")}`;
  fillFilters();
  show("centro");
  startMap();
  if (state.centre) {
    select({...state.centre, point: state.centre.official_point}, state.centre.point);
    confirmed(state.centre);
  }
  const form = $("search");
  form.addEventListener("submit", (e) => e.preventDefault());
  form.region.addEventListener("change", fillComunas);
  form.addEventListener("input", search);
  form.addEventListener("change", search);
  $("confirm").addEventListener("click", confirm);
  $("reset").addEventListener("click", () => place(selected.point));
  search();
}

document.addEventListener("DOMContentLoaded", start);
