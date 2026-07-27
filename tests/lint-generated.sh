#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DOCKER_MIGRATE_LIB_ONLY=1
# shellcheck source=../docker_migrate_perfect.sh
source "${ROOT_DIR}/docker_migrate_perfect.sh"

command -v shellcheck >/dev/null 2>&1 || {
  echo "shellcheck is required" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "${tmp}/bundle/runs" "${tmp}/bundle/meta"
write_run_script lint_target "${tmp}/bundle/runs/lint_target.sh"
write_bundle_restore_script "${tmp}/bundle/restore.sh"

bash -n "${tmp}/bundle/runs/lint_target.sh"
bash -n "${tmp}/bundle/restore.sh"
shellcheck -S warning "${tmp}/bundle/runs/lint_target.sh"
shellcheck -S warning "${tmp}/bundle/restore.sh"
