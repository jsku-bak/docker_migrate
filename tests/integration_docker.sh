#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DOCKER_MIGRATE_LIB_ONLY=1
# shellcheck source=../docker_migrate_perfect.sh
source "${ROOT_DIR}/docker_migrate_perfect.sh"

for bin in docker jq; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "skip: $bin is unavailable"
    exit 0
  }
done
docker info >/dev/null 2>&1 || {
  echo "skip: Docker daemon is unavailable"
  exit 0
}

suffix="dmtest_${$}"
container_name="${suffix}_container"
network_name="${suffix}_network"
third_octet=$((($$ % 180) + 20))
subnet="172.30.${third_octet}.0/24"
container_ip="172.30.${third_octet}.10"
tmp="$(mktemp -d)"
compose_project="${suffix}_compose"
compose_work="${tmp}/compose-work"

cleanup() {
  if [[ -f "${compose_work}/_resolved_config.yml" ]] &&
    docker compose version >/dev/null 2>&1; then
    docker compose -f "${compose_work}/_resolved_config.yml" down -v >/dev/null 2>&1 || true
  fi
  docker rm -f "$container_name" >/dev/null 2>&1 || true
  docker network rm "$network_name" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

docker pull alpine:3.20 >/dev/null
docker network create --driver bridge --subnet "$subnet" "$network_name" >/dev/null
docker create \
  --name "$container_name" \
  --cpus 0.5 \
  --network "$network_name" \
  --ip "$container_ip" \
  --health-cmd 'test -f /etc/alpine-release' \
  --health-interval 5s \
  alpine:3.20 sleep 300 >/dev/null

bundle="${tmp}/bundle"
mkdir -p "${bundle}/runs" "${bundle}/meta" "${bundle}/volumes" \
  "${bundle}/binds" "${bundle}/compose"
docker inspect "$container_name" >"${bundle}/meta/${container_name}.inspect.json"
write_run_script "$container_name" "${bundle}/runs/${container_name}.sh"

network_json="$(docker network inspect "$network_name" | jq '.[0] | {
  name: .Name,
  driver: .Driver,
  internal: .Internal,
  attachable: .Attachable,
  enable_ipv6: .EnableIPv6,
  options: (.Options // {}),
  labels: (.Labels // {}),
  ipam: {
    driver: (.IPAM.Driver // "default"),
    options: (.IPAM.Options // {}),
    config: (.IPAM.Config // [])
  }
}')"
jq -n \
  --arg run "runs/${container_name}.sh" \
  --argjson network "$network_json" \
  '{images:[],networks:[$network],projects:[],volumes:[],binds:[],runs:[$run]}' \
  >"${bundle}/manifest.json"
write_bundle_restore_script "${bundle}/restore.sh"
generate_bundle_checksums "$bundle"

docker rm -f "$container_name" >/dev/null
docker network rm "$network_name" >/dev/null

(cd "$bundle" && bash restore.sh >/dev/null)

[[ "$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$container_name")" == "500000000" ]]
[[ "$(docker inspect -f "{{with index .NetworkSettings.Networks \"${network_name}\"}}{{.IPAddress}}{{end}}" "$container_name")" == "$container_ip" ]]
docker inspect "$container_name" | jq -e '.[0].Config.Healthcheck.Test[0] == "CMD-SHELL"' >/dev/null

first_id="$(docker inspect -f '{{.Id}}' "$container_name")"
RESTORE_EXISTING=skip bash "${bundle}/runs/${container_name}.sh" >/dev/null
[[ "$(docker inspect -f '{{.Id}}' "$container_name")" == "$first_id" ]]

if RESTORE_EXISTING=fail bash "${bundle}/runs/${container_name}.sh" >/dev/null 2>&1; then
  echo "RESTORE_EXISTING=fail unexpectedly succeeded" >&2
  exit 1
fi

RESTORE_EXISTING=replace bash "${bundle}/runs/${container_name}.sh" >/dev/null
[[ "$(docker inspect -f '{{.Id}}' "$container_name")" != "$first_id" ]]

if docker compose version >/dev/null 2>&1; then
  compose_bundle="${tmp}/compose-bundle"
  mkdir -p "${compose_bundle}/compose/${compose_project}" "${compose_bundle}/meta" \
    "${compose_bundle}/volumes" "${compose_bundle}/binds"
  cat >"${compose_bundle}/compose/${compose_project}/_resolved_config.yml" <<YAML
name: ${compose_project}
services:
  first:
    image: alpine:3.20
    command: ["sleep", "300"]
    environment:
      MIGRATION_TEST: merged-config
  second:
    image: alpine:3.20
    command: ["sleep", "300"]
YAML
  jq -n \
    --arg name "$compose_project" \
    --arg working_dir "$compose_work" \
    '{
      images:[], networks:[], volumes:[], binds:[], runs:[],
      projects:[{
        name:$name,
        working_dir:$working_dir,
        files:["_resolved_config.yml"],
        config_files:["_resolved_config.yml"]
      }]
    }' >"${compose_bundle}/manifest.json"
  write_bundle_restore_script "${compose_bundle}/restore.sh"
  generate_bundle_checksums "$compose_bundle"
  (cd "$compose_bundle" && bash restore.sh >/dev/null)
  docker inspect "${compose_project}-first-1" |
    jq -e '.[0].Config.Env | index("MIGRATION_TEST=merged-config") != null' >/dev/null
else
  echo "skip: Docker Compose integration subtest is unavailable"
fi

echo "Docker integration test passed"
