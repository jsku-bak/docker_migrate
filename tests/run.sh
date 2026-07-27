#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DOCKER_MIGRATE_LIB_ONLY=1
# shellcheck source=../docker_migrate_perfect.sh
source "${ROOT_DIR}/docker_migrate_perfect.sh"

PASS_COUNT=0
FAIL_COUNT=0

run_test() {
  local name="$1"
  shift
  if ("$@"); then
    printf 'ok - %s\n' "$name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf 'not ok - %s\n' "$name" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

test_progress_propagates_failure() {
  local tmp rc
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  set +e
  progress_docker_save "${tmp}/images.tar" bash -c 'printf partial; exit 7' >/dev/null 2>&1
  rc=$?
  set -e
  [[ "$rc" -eq 7 ]]
}

test_generated_scripts_are_valid_bash() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "${tmp}/bundle/runs" "${tmp}/bundle/meta"
  write_run_script demo "${tmp}/bundle/runs/demo.sh"
  write_bundle_restore_script "${tmp}/bundle/restore.sh"
  bash -n "${tmp}/bundle/runs/demo.sh"
  bash -n "${tmp}/bundle/restore.sh"
}

test_checksums_detect_tampering() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "${tmp}/bundle/meta"
  printf 'manifest\n' >"${tmp}/bundle/manifest.json"
  printf 'metadata\n' >"${tmp}/bundle/meta/demo.json"
  generate_bundle_checksums "${tmp}/bundle"
  verify_bundle_checksums "${tmp}/bundle" >/dev/null
  printf 'tampered\n' >>"${tmp}/bundle/meta/demo.json"
  ! verify_bundle_checksums "${tmp}/bundle" >/dev/null 2>&1
}

test_archive_layout_rejects_symlinks() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "${tmp}/safe/root" "${tmp}/unsafe/root"
  printf 'ok\n' >"${tmp}/safe/root/file"
  tar -czf "${tmp}/safe.tar.gz" -C "${tmp}/safe" root
  archive_layout_is_safe "${tmp}/safe.tar.gz"
  ln -s /etc/passwd "${tmp}/unsafe/root/link"
  tar -czf "${tmp}/unsafe.tar.gz" -C "${tmp}/unsafe" root
  ! archive_layout_is_safe "${tmp}/unsafe.tar.gz"
}

test_compose_env_file_parser() {
  local tmp
  local -a actual expected
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  cat >"${tmp}/compose.yml" <<'YAML'
services:
  scalar:
    env_file: .env.scalar
  list:
    env_file:
      - .env.first
      - path: config/.env.second
        required: false
YAML
  mapfile -t actual < <(compose_env_file_refs "${tmp}/compose.yml")
  expected=(.env.scalar .env.first config/.env.second)
  [[ "${actual[*]}" == "${expected[*]}" ]]
}

run_test "docker image save failure status is preserved" test_progress_propagates_failure
run_test "generated restore scripts parse as Bash" test_generated_scripts_are_valid_bash
run_test "bundle checksum detects tampering" test_checksums_detect_tampering
run_test "top-level archive rejects symlinks" test_archive_layout_rejects_symlinks
run_test "Compose env_file parser handles scalar/list/long syntax" test_compose_env_file_parser

printf '\nTests: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
((FAIL_COUNT == 0))
