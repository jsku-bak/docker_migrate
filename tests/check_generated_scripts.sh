#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
export DOCKER_MIGRATE_LIB_ONLY=1
# shellcheck source=../docker_migrate_perfect.sh
source "${ROOT}/../docker_migrate_perfect.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

write_run_script "test-container" "${tmp}/runs/test-container.sh"
bash -n "${tmp}/runs/test-container.sh" && echo "RUN_SH syntax OK"

write_bundle_restore_script "${tmp}/restore.sh"
bash -n "${tmp}/restore.sh" && echo "REST_SH syntax OK"

# 验证关键逻辑已在生成脚本中
grep -q 'DockerMigrate.original_image' "${tmp}/runs/test-container.sh" && echo "RUN_SH uses original_image"
grep -q 'NetworkSettings.Ports' "${tmp}/runs/test-container.sh" && echo "RUN_SH uses runtime ports"
grep -q 'docker tag' "${tmp}/runs/test-container.sh" && echo "RUN_SH retags snapshot"
grep -q 'Created // empty' "${tmp}/restore.sh" && echo "REST_SH sorts runs by creation time"
grep -q 'DM_ORIG_IMAGE_USES' "${tmp}/restore.sh" && echo "REST_SH restores original image names"
echo "ALL CHECKS DONE"
