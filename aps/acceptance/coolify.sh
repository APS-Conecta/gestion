#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# The acceptance harness's Coolify way in (Seam 1, ADR 0029), on the machine as root, where run.sh puts it as
# aps-coolify. It sets Coolify up as its admin does and adds the suite as a resource of it: Coolify's own install
# script, then its API, with a token of its root user that stays in /root/.aps-coolify, never on a command line or in
# a log.
#   aps-coolify setup <repository> <commit> <address> <files> <mastercontainer>
#       Coolify 4.6.0; its proxy configuration with AIO's Traefik settings pasted, as the Provisionador shows them (the
#       file <files>/settings, one per line), and the proxy restarted; the resource's source: the candidate's commit of
#       <repository> on GitHub, and its one variable: <address>, the machine's address, as its public one. On a test
#       build, whose mastercontainer's services.json names the name service of <files>/test-build.json (as run.sh tells
#       a test build, from aps/acceptance/test-build.json): Traefik gets the CI name's certificate from
#       Let's Encrypt's staging service by the DNS challenge through the name service, as our Caddy does, since the
#       runner takes no inbound connection: Coolify's resolver takes the staging directory and acme-dns, whose account
#       lego reads from a storage on the machine (<files>/acme-dns-storage.py); and the suite trusts the staging roots
#       (<files>/ca.crt) through AIO's NEXTCLOUD_TRUSTED_CACERTS_DIR, as a test build's Bootstrap gives them.
#   aps-coolify deploy <mastercontainer>
#       The way in: the candidate's mastercontainer, by digest, as the channel tag, which a release would give it on the
#       registry, as the Bootstrap loads it; the resource, created first when Coolify has none, as the admin adds it;
#       its deploy, through the API; then the resource's logs, through the API, once they show the Provisionador's link
#       or the end of the install. A candidate is never on the channel tag, so the resource's custom build command, the
#       one setting the admin does not make, skips Coolify's pull of it.
#   aps-coolify delete
#       The resource deleted in Coolify, the end of the manual's removal.
set -euo pipefail
STATE=/root/.aps-coolify
CHANNEL=ghcr.io/aps-conecta/all-in-one:latest
CACERTS=/etc/ssl/apsconecta-gestion  # where a test build's Bootstrap writes the CAs its suite trusts
STORAGE_PORT=8099
# The last line of the Provisionador's link block (LINK_LOG) and the start of what it prints after «Listo» (CLOSED), in
# aps/provisionador/provisionador.py.
LINK_LAST="El enlace sirve hasta «Listo»."
CLOSED="La instalación terminó en «Listo»"

api() { # <method> <path> [<JSON body>]: Coolify's API answer
  curl -fsS --retry 3 -X "$1" -H @"$STATE/header" -H 'Content-Type: application/json' \
    "http://localhost:8000/api/v1$2" ${3:+--data "$3"}
}

tinker() { # <PHP>: run in Coolify's own application, as its artisan tinker does; APS_* variables pass through
  docker exec --env APS_PROXY="${APS_PROXY:-}" coolify php artisan tinker --execute "$1"
}

setup() {
  local repository="$1" commit="$2" address="$3" files="$4" password server proxy services waited=0 test_build=false
  install -d -m 700 "$STATE"
  curl -fsSL --retry 5 -o "$STATE/install.sh" \
    https://raw.githubusercontent.com/coollabsio/coolify/v4.6.0/scripts/install.sh
  echo "c221f81e0bc9b47541f47bf671da76c79cfb61ce4741c3cb0800d7a18b99f137  $STATE/install.sh" | sha256sum --check --quiet
  password="$(openssl rand -hex 16)Aa1!"
  ROOT_USERNAME=acceptance ROOT_USER_EMAIL=acceptance@example.org ROOT_USER_PASSWORD="$password" AUTOUPDATE=false \
    bash "$STATE/install.sh" 4.6.0 > "$STATE/install.log" 2>&1 \
    || { tail -n 40 "$STATE/install.log" >&2; exit 1; }
  until curl -fsS http://localhost:8000/api/health > /dev/null 2>&1; do
    ((++waited < 60)) || { echo "Coolify does not answer on port 8000" >&2; exit 1; }
    sleep 5
  done
  tinker 'App\Models\InstanceSettings::get()->update(["is_api_enabled" => true]);
    echo "APS-TOKEN ".App\Models\User::find(0)->createToken("acceptance", ["root"], null, 0)->plainTextToken.PHP_EOL;' \
    | sed -n 's/^APS-TOKEN /Authorization: Bearer /p' > "$STATE/header"
  [ -s "$STATE/header" ] || { echo "Coolify gave no API token" >&2; exit 1; }
  for _ in $(seq 60); do
    server="$(api GET /servers | jq -r '.[] | select(.name == "localhost" and .is_reachable and .is_usable) | .uuid')"
    [ -z "$server" ] || break
    sleep 5
  done
  [ -n "$server" ] || { echo "Coolify's own server never became usable" >&2; exit 1; }
  # The proxy configuration, as the admin edits it: AIO's settings added to the command of Coolify's Traefik; and on a
  # test build, its resolver on the staging service by the DNS challenge through acme-dns, in place of the HTTP one.
  proxy="$(jq -R . "$files/settings" | jq -s '{add: ., remove: [], environment: {}}')"
  docker pull --quiet "$5" > /dev/null
  services="$(docker run --rm --entrypoint cat "$5" /var/www/docker-aio/aps/provisionador/services.json)"
  [ "$(jq -r .name_service <<< "$services")" != "$(jq -r .name_service "$files/test-build.json")" ] || test_build=true
  if [ "$test_build" = true ]; then
    install -d -m 755 "$CACERTS"
    install -m 644 "$files/ca.crt" "$CACERTS/ca.crt"
    install -m 700 "$files/acme-dns-storage.py" "$STATE/acme-dns-storage.py"
    systemd-run --unit aps-acme-dns-storage --property Restart=always python3 -I "$STATE/acme-dns-storage.py" \
      "$STORAGE_PORT" > /dev/null
    proxy="$(jq --slurpfile build "$files/test-build.json" --arg storage "http://host.docker.internal:$STORAGE_PORT/" '
      .add += ["--certificatesresolvers.letsencrypt.acme.caserver=\($build[0].acme_ca)",
               "--certificatesresolvers.letsencrypt.acme.dnschallenge=true",
               "--certificatesresolvers.letsencrypt.acme.dnschallenge.provider=acme-dns"]
      | .remove += ["--certificatesresolvers.letsencrypt.acme.httpchallenge=true",
                    "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=http"]
      | .environment += {ACME_DNS_API_BASE: $build[0].name_service, ACME_DNS_STORAGE_BASE_URL: $storage}' <<< "$proxy")"
  fi
  APS_PROXY="$proxy" tinker '$server = App\Models\Server::findOrFail(0);
    $proxy = json_decode(getenv("APS_PROXY"), true);
    $config = Symfony\Component\Yaml\Yaml::parse(App\Actions\Proxy\GetProxyConfiguration::run($server));
    $traefik = $config["services"]["traefik"];
    $traefik["command"] = array_values(array_merge(array_diff($traefik["command"], $proxy["remove"]), $proxy["add"]));
    $traefik["environment"] = array_merge($traefik["environment"] ?? [], $proxy["environment"]);
    $config["services"]["traefik"] = $traefik;
    App\Actions\Proxy\SaveProxyConfiguration::run($server, Symfony\Component\Yaml\Yaml::dump($config, 12, 2));
    App\Actions\Proxy\StartProxy::run($server, false, true);' > /dev/null
  waited=0
  until docker inspect --format '{{json .Config.Cmd}}' coolify-proxy 2> /dev/null | jq -e --slurpfile want \
      <(jq -R . "$files/settings") '. as $running | $want | all(. as $setting | $running | index($setting))' \
      > /dev/null; do
    ((++waited < 60)) || { echo "Coolify's proxy does not run with AIO's settings" >&2; exit 1; }
    sleep 5
  done
  printf '%s\n' "$server" > "$STATE/server"
  api POST /projects '{"name": "APS Conecta Gestión"}' | jq -er .uuid > "$STATE/project"
  jq -n --arg repository "$repository" --arg commit "$commit" --arg address "$address" \
    --arg cacerts "$([ "$test_build" != true ] || echo "$CACERTS")" \
    '{repository: $repository, commit: $commit, address: $address, cacerts: $cacerts}' > "$STATE/resource.json"
  echo "Coolify 4.6.0 runs, and its proxy with AIO's Traefik settings"
}

create() { # the resource, as the admin adds it: this repository's compose file for Coolify, in Raw mode
  local app
  app="$(api POST /applications/public "$(jq --arg project "$(cat "$STATE/project")" \
    --arg server "$(cat "$STATE/server")" '{
      project_uuid: $project, server_uuid: $server, environment_name: "production", name: "aps-conecta-gestion",
      git_repository: "https://github.com/\(.repository)", git_branch: "main", git_commit_sha: .commit,
      build_pack: "dockercompose", docker_compose_location: "/aps/coolify.yaml",
      is_raw_compose_deployment_enabled: true,
      docker_compose_custom_build_command: "docker compose build", instant_deploy: false}' "$STATE/resource.json")" \
    | jq -er .uuid)"
  variable "$app" APS_PUBLIC_ADDRESS "$(jq -r .address "$STATE/resource.json")"
  [ -z "$(jq -r .cacerts "$STATE/resource.json")" ] \
    || variable "$app" NEXTCLOUD_TRUSTED_CACERTS_DIR "$(jq -r .cacerts "$STATE/resource.json")"
  printf '%s\n' "$app" > "$STATE/app"
}

variable() { # <resource> <name> <value>
  api POST "/applications/$1/envs" "$(jq -n --arg key "$2" --arg value "$3" \
    '{key: $key, value: $value, is_runtime: true, is_buildtime: true}')" > /dev/null
}

deploy() {
  local app deployment status logs
  docker pull --quiet "$1" > /dev/null
  docker tag "$1" "$CHANNEL"
  [ -s "$STATE/app" ] || create
  app="$(cat "$STATE/app")"
  deployment="$(api POST "/deploy?uuid=$app" | jq -er '.deployments[0].deployment_uuid')"
  for _ in $(seq 240); do
    status="$(api GET "/deployments/$deployment" | jq -r .status)"
    [[ "$status" = queued || "$status" = in_progress ]] || break
    sleep 5
  done
  if [ "$status" != finished ]; then
    echo "Coolify's deploy $deployment ended $status:" >&2
    api GET "/deployments/$deployment" | jq -r '.logs // "[]" | fromjson | .[] | select(.hidden | not) | .output' \
      | tail -n 40 >&2
    exit 1
  fi
  for _ in $(seq 120); do
    logs="$(api GET "/applications/$app/logs?lines=2000" | jq -r '.logs // ""')"
    if grep -qF -e "$LINK_LAST" -e "$CLOSED" <<< "$logs"; then
      printf '%s\n' "$logs"
      return 0
    fi
    sleep 5
  done
  echo "the resource's logs showed neither the Provisionador's link nor the end of the install" >&2
  exit 1
}

delete() { # Coolify deletes in the background: the reinstall waits for it, and no Docker cleanup races its pull
  local app waited=0
  app="$(cat "$STATE/app")"
  api DELETE "/applications/$app?delete_volumes=false&docker_cleanup=false" > /dev/null
  while api GET "/applications/$app" > /dev/null 2>&1; do
    ((++waited < 60)) || { echo "Coolify did not delete the resource" >&2; exit 1; }
    sleep 5
  done
  rm -f "$STATE/app"
}

case "${1:-}" in
  setup) shift; setup "$@" ;;
  deploy) shift; deploy "$@" ;;
  delete) delete ;;
  *) echo "usage: aps-coolify setup <repository> <commit> <address> <files> <mastercontainer>" \
       "| deploy <mastercontainer> | delete" >&2
     exit 2 ;;
esac
