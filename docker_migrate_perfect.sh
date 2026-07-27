#!/usr/bin/env bash
# docker_migrate_perfect.sh — Docker 容器一键迁移（源服务器使用）
#
# 依赖：bash >= 4.0（需要关联数组 declare -A 和 mapfile）
# macOS 用户请用 Homebrew bash: brew install bash && /usr/local/bin/bash docker_migrate_perfect.sh
#
# 功能概要：
# 1. 自动检测并安装依赖（docker / jq / python3 / tar / gzip / curl）
# 2. 按“独立容器 / docker compose 容器组”展示并选择要迁移的容器
# 3. 打包：镜像、命名卷、绑定目录、（可用的）Compose 配置
# 4. 生成 manifest.json 和 restore.sh
# 5. 启动带安全随机路径的 HTTP 服务，输出下载链接；退出时关闭 HTTP、重启停机容器、清理临时文件
#
# 本版修复：
# - 恢复时同名容器已存在但端口绑定不同，会删除并重建容器，避免“恢复成功但端口丢失”。
# - 单容器 docker compose 项目按独立容器恢复，确保可以从 inspect 还原 -p 端口参数。
# - 端口绑定还原支持空 HostPort 跳过、IPv6 HostIp 加方括号。
# - 恢复已暂停容器时会先 unpause，再 start / remove。
#
# 环境变量：
# PORT=8080             默认 HTTP 端口（会询问你要不要改；被占用则向后尝试）
# ADVERTISE_HOST=IP     下载链接里使用的域名/IP（默认自动探测）
# RESTORE_KEEP=1        恢复后保留下载包与解压目录
# RESTORE_CLEAN_ALL=1   恢复失败也强制清理文件
# RESTORE_BASE=/path    新服务器恢复目录
#
# 参数：
# --no-stop             不停机备份（可能不一致，数据库慎用）
# --include=name1,name2 按容器名称精确匹配，只迁移指定容器（不使用分组菜单）

# bash 版本检测：需要 4.0+（关联数组 / mapfile）
if [[ -z "${BASH_VERSINFO[0]:-}" ]] || ((BASH_VERSINFO[0] < 4)); then
  echo "[ERR] 本脚本需要 bash >= 4.0，当前版本：${BASH_VERSION:-unknown}" >&2
  echo "[ERR] macOS 用户请用 Homebrew bash: brew install bash && /usr/local/bin/bash docker_migrate_perfect.sh" >&2
  exit 1
fi

set -euo pipefail
umask 077

SCRIPT_VERSION="2.0.0"
declare -a IDS=()
declare -a RUNS=()
declare -a STOPPED_ON_BACKUP=()
declare -a BACKUP_FAILURES=()

#####################################
# 基础函数 & 依赖管理
#####################################
BLUE() { echo -e "\033[1;34m$*\033[0m"; }
YEL() { echo -e "\033[1;33m$*\033[0m"; }
RED() { echo -e "\033[1;31m$*\033[0m"; }
OK() { echo -e "\033[1;32m$*\033[0m"; }
CYA() { echo -e "\033[1;36m$*\033[0m"; }

show_banner() {
  echo -e "\033[1;36m"
  cat <<'BANNER'
  ____             _               __  __ _                 _
 |  _ \  ___   ___| | _____ _ __  |  \/  (_) __ _ _ __ __ _| |_ ___
 | | | |/ _ \ / __| |/ / _ \ '__| | |\/| | |/ _` | '__/ _` | __/ _ \
 | |_| | (_) | (__|   <  __/ |    | |  | | | (_| | | | (_| | ||  __/
 |____/ \___/ \___|_|\_\___|_|    |_|  |_|_|\__, |_|  \__,_|\__\___|
                                            |___/
 ---------------------------------------------------------------
      🐳 一键备份 · 安全传输 · 完整恢复 | Docker 容器迁移工具
 ---------------------------------------------------------------
BANNER
  echo -e "\033[0m"
}

show_help() {
  cat <<'HLP'
用法:
  bash docker_migrate_perfect.sh [--backup] [--no-stop] [--include=name1,name2]
  bash docker_migrate_perfect.sh --restore[=URL]

环境变量:
  PORT=8080                 HTTP 端口（被占用会自动递增）
  ADVERTISE_HOST=IP         下载链接中使用的主机名/IP
  RESTORE_EXISTING=replace  同名容器策略：replace、skip 或 fail
  RESTORE_KEEP=1            恢复后保留文件
  RESTORE_CLEAN_ALL=1       恢复失败也强制删除文件
  RESTORE_BASE=/path        自定义恢复目录

不带参数运行时仍使用原有交互菜单。
HLP
}

asudo() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

run_with_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  else
    "$@"
  fi
}

pm_detect() {
  if command -v apt-get >/dev/null 2>&1; then
    echo apt
    return
  fi
  if command -v dnf >/dev/null 2>&1; then
    echo dnf
    return
  fi
  if command -v yum >/dev/null 2>&1; then
    echo yum
    return
  fi
  if command -v zypper >/dev/null 2>&1; then
    echo zypper
    return
  fi
  if command -v apk >/dev/null 2>&1; then
    echo apk
    return
  fi
  echo none
}

pm_install() {
  local pm="$1"
  shift
  case "$pm" in
    apt)
      asudo apt-get update -y
      asudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    dnf) asudo dnf install -y "$@" ;;
    yum) asudo yum install -y "$@" ;;
    zypper) asudo zypper --non-interactive install -y "$@" ;;
    apk) asudo apk add --no-cache "$@" ;;
    *)
      RED "[ERR] 不支持的包管理器：$pm，请手动安装：$*"
      exit 1
      ;;
  esac
}

need_bin() {
  local bin="$1" pkg="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[INFO] 安装依赖：$bin"
    pm_install "$PKGMGR" "$pkg"
  fi
}

try_optional_bin() {
  local bin="$1" pkg="$2"
  command -v "$bin" >/dev/null 2>&1 && return 0
  [[ "${PKGMGR:-none}" != "none" ]] || return 0
  (pm_install "$PKGMGR" "$pkg") >/dev/null 2>&1 || true
}

ensure_docker_running() {
  if ! command -v docker >/dev/null 2>&1; then
    RED "[ERR] 未检测到 docker，请先安装 Docker 再运行本脚本。"
    exit 1
  fi

  if docker info >/dev/null 2>&1; then
    return 0
  fi

  YEL "[INFO] 尝试启动 Docker 服务..."
  if command -v systemctl >/dev/null 2>&1; then
    asudo systemctl enable --now docker || true
  fi
  if ! docker info >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
    asudo service docker start || true
  fi
  if ! docker info >/dev/null 2>&1; then
    YEL "[WARN] 尝试后台直接启动 dockerd ..."
    if command -v dockerd >/dev/null 2>&1; then
      asudo nohup dockerd >/var/log/dockerd.migrate.log 2>&1 &
      sleep 3
    fi
  fi
  if ! docker info >/dev/null 2>&1; then
    RED "[ERR] Docker 仍未正常启动，请手动检查后重试。"
    exit 1
  fi
}

human() {
  local b="${1:-0}"
  local -a units=(B KB MB GB TB PB)
  local i=0
  while ((b >= 1024 && i < ${#units[@]} - 1)); do
    b=$((b / 1024))
    i=$((i + 1))
  done
  echo "${b}${units[$i]}"
}

progress_docker_save() {
  local outfile="$1"
  shift
  local rc=0
  if command -v pv >/dev/null 2>&1; then
    BLUE "[INFO] 保存镜像 images.tar（使用 pv 显示进度）..."
    if "$@" | pv -b >"$outfile"; then
      rc=0
    else
      rc=$?
    fi
    local cur
    cur=$(stat -c %s "$outfile" 2>/dev/null || stat -f%z "$outfile" 2>/dev/null || echo 0)
    echo "[进度] images.tar 完成：$(human "$cur")"
  else
    BLUE "[INFO] 保存镜像 images.tar（此步骤可能较久，请耐心等待）..."
    "$@" >"$outfile" &
    local pid=$!
    printf "[进度] images.tar "
    # 把进度显示放到后台子 shell，避免 PID 竞态导致死循环。
    # wait 直接等待子进程，不受 OS 回收 PID 影响。
    (
      local last=0 cur=0
      local spin='-/|\' i=0
      while kill -0 "$pid" 2>/dev/null; do
        if [[ -f "$outfile" ]]; then
          cur=$(stat -c %s "$outfile" 2>/dev/null || stat -f%z "$outfile" 2>/dev/null || echo 0)
          if ((cur != last)); then
            printf "\r[进度] images.tar %c 已写入：%s" "${spin:$i:1}" "$(human "$cur")"
            last=$cur
          else
            printf "\r[进度] images.tar %c 写入中 ..." "${spin:$i:1}"
          fi
        else
          printf "\r[进度] images.tar %c 准备中 ..." "${spin:$i:1}"
        fi
        i=$(((i + 1) % 4))
        sleep 1
      done
    ) &
    local spinner_pid=$!
    if wait "$pid"; then
      rc=0
    else
      rc=$?
    fi
    kill "$spinner_pid" 2>/dev/null || true
    wait "$spinner_pid" 2>/dev/null || true
    cur=$(stat -c %s "$outfile" 2>/dev/null || stat -f%z "$outfile" 2>/dev/null || echo 0)
    printf "\r%-80s\r" ""
    echo "[进度] images.tar 完成：$(human "$cur")"
  fi
  return "$rc"
}

is_private_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^10\. ]] && return 0
  [[ "$ip" =~ ^192\.168\. ]] && return 0
  [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] && return 0
  [[ "$ip" =~ ^127\. ]] && return 0
  [[ "$ip" =~ ^169\.254\. ]] && return 0
  return 1
}

get_public_ip_external() {
  local ip
  for svc in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me; do
    ip="$(curl -fsS --max-time 2 "$svc" 2>/dev/null | tr -d '\r\n' || true)"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

pick_advertise_url() {
  local port="$1"
  local host=""
  if [[ -n "${ADVERTISE_HOST:-}" ]]; then
    host="$ADVERTISE_HOST"
  else
    local via_route=""
    via_route="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    if [[ -n "$via_route" ]] && ! is_private_ipv4 "$via_route"; then
      host="$via_route"
    fi
    [[ -z "$host" ]] && host="$(get_public_ip_external || true)"
    [[ -z "$host" ]] && host="$(ip -4 -o addr show 2>/dev/null | awk '!/ lo| docker| veth| br-| kube/ {print $4}' | cut -d/ -f1 | head -n1 || true)"
    : "${host:=127.0.0.1}"
  fi
  echo "http://${host}:${port}"
}

pick_free_port() {
  local p="${1:-8080}"
  local i
  for i in $(seq 0 50); do
    if command -v ss >/dev/null 2>&1; then
      if ! ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$p$"; then
        echo "$p"
        return 0
      fi
    elif command -v netstat >/dev/null 2>&1; then
      if ! netstat -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$p$"; then
        echo "$p"
        return 0
      fi
    else
      echo "$p"
      return 0
    fi
    p=$((p + 1))
  done
  echo "${1:-8080}"
}

json_array_from_lines() {
  if [[ $# -eq 0 ]]; then
    echo '[]'
    return 0
  fi
  # 过滤空行，避免空数组被序列化成 [""]。
  printf '%s\n' "$@" | awk 'NF' | jq -R . | jq -cs .
}

compose_env_file_refs() {
  # Best-effort fallback parser for common Compose env_file scalar/list/long syntax.
  # 正常情况下恢复使用 `docker compose config` 生成的已解析配置。
  awk '
    function trim(v) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^["'"'"']|["'"'"']$/, "", v)
      return v
    }
    /^[[:space:]]*env_file[[:space:]]*:/ {
      in_env = 1
      value = $0
      sub(/^[^:]*:[[:space:]]*/, "", value)
      value = trim(value)
      if (value != "") {
        print value
        in_env = 0
      }
      next
    }
    in_env && /^[[:space:]]*-[[:space:]]*/ {
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      if (value ~ /^path[[:space:]]*:/) {
        sub(/^path[[:space:]]*:[[:space:]]*/, "", value)
      }
      value = trim(value)
      if (value != "" && value !~ /^(required|format)[[:space:]]*:/) print value
      next
    }
    in_env && /^[[:space:]]*path[[:space:]]*:/ {
      value = $0
      sub(/^[[:space:]]*path[[:space:]]*:[[:space:]]*/, "", value)
      value = trim(value)
      if (value != "") print value
      next
    }
    in_env && /^[^[:space:]#]/ { in_env = 0 }
  ' "$1"
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  else
    return 127
  fi
}

generate_bundle_checksums() {
  local bundle_dir="$1"
  local manifest="${bundle_dir}/checksums.sha256"
  local file rel digest
  : >"$manifest"
  while IFS= read -r -d '' file; do
    rel="${file#"${bundle_dir}/"}"
    case "$rel" in checksums.sha256 | restore.sh) continue ;; esac
    digest="$(sha256_file "$file")" || {
      RED "[ERR] 系统缺少 SHA-256 工具（sha256sum/shasum/openssl）。"
      return 1
    }
    printf '%s\t%s\n' "$digest" "$rel" >>"$manifest"
  done < <(find "$bundle_dir" -type f -print0)
}

verify_bundle_checksums() {
  local bundle_dir="$1"
  local manifest="${bundle_dir}/checksums.sha256"
  local expected rel file actual count=0
  [[ -f "$manifest" ]] || {
    RED "[ERR] 迁移包缺少 checksums.sha256。"
    return 1
  }
  while IFS=$'\t' read -r expected rel; do
    [[ -n "$expected" && -n "$rel" ]] || continue
    case "$rel" in
      /* | .. | ../* | */../* | */..)
        RED "[ERR] 校验清单含危险路径：$rel"
        return 1
        ;;
    esac
    file="${bundle_dir}/${rel}"
    [[ -f "$file" ]] || {
      RED "[ERR] 迁移包缺少文件：$rel"
      return 1
    }
    actual="$(sha256_file "$file")" || return 1
    [[ "$actual" == "$expected" ]] || {
      RED "[ERR] 文件完整性校验失败：$rel"
      return 1
    }
    count=$((count + 1))
  done <"$manifest"
  ((count > 0)) || {
    RED "[ERR] 校验清单为空。"
    return 1
  }
}

archive_layout_is_safe() {
  local archive="$1"
  local entry
  tar -tzf "$archive" >/dev/null 2>&1 || return 1
  while IFS= read -r entry; do
    case "$entry" in
      /* | .. | ../* | */../* | */..) return 1 ;;
    esac
  done < <(tar -tzf "$archive")
  # 顶层迁移包不需要符号链接或硬链接；拒绝它们可避免解压路径绕过。
  ! tar -tvzf "$archive" | awk 'substr($1,1,1) ~ /^[lh]$/ { bad=1 } END { exit bad ? 0 : 1 }'
}

#####################################
# 生成单容器恢复脚本
#####################################
write_run_script() {
  local name="$1"
  local out="$2"
  cat >"$out" <<'RUN_SH'
#!/usr/bin/env bash
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
META="${BUNDLE_DIR}/meta/__NAME__.inspect.json"

if [[ ! -f "$META" ]]; then
  echo "[WARN] missing metadata: $META" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "[WARN] jq is required to restore container: __NAME__" >&2
  exit 1
fi

resolve_container_mode() {
  local mode="$1"
  local ref f cid2 cname
  [[ "$mode" == container:* ]] || {
    printf '%s\n' "$mode"
    return 0
  }
  ref="${mode#container:}"
  [[ "$ref" =~ ^[0-9a-f]{12,}$ ]] || {
    printf '%s\n' "$mode"
    return 0
  }
  for f in "${BUNDLE_DIR}"/meta/*.inspect.json; do
    [[ -f "$f" ]] || continue
    cid2="$(jq -r '.[0].Id' "$f")"
    if [[ "$cid2" == "$ref" || "${cid2:0:12}" == "$ref" ]]; then
      cname="$(jq -r '.[0].Name | ltrimstr("/")' "$f")"
      printf 'container:%s\n' "$cname"
      return 0
    fi
  done
  printf '%s\n' "$mode"
}

decode_base64() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    base64 -D
  else
    base64 -d
  fi
}

name="$(jq -r '.[0].Name | ltrimstr("/")' "$META")"
image="$(jq -r '.[0].Config.Image' "$META")"
if [[ -z "$name" || -z "$image" || "$image" == "null" ]]; then
  echo "[WARN] invalid container metadata for __NAME__" >&2
  exit 1
fi

if ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "[INFO] image is not loaded; pull before changing any existing container: $image"
  docker pull "$image" >/dev/null || {
    echo "[WARN] image is unavailable; existing container was left unchanged: $image" >&2
    exit 1
  }
fi

if docker ps -a --format '{{.Names}}' | grep -Fxq "$name"; then
  existing_state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
  case "${RESTORE_EXISTING:-replace}" in
    replace)
      echo "[WARN] container exists; replace it to restore the complete configuration: $name"
      [[ "$existing_state" == "paused" ]] && docker unpause "$name" >/dev/null 2>&1 || true
      docker rm -f "$name" >/dev/null 2>&1 || {
        echo "[WARN] failed to remove existing container: $name" >&2
        exit 1
      }
      ;;
    skip)
      echo "[WARN] container exists; skipped by RESTORE_EXISTING=skip: $name"
      exit 0
      ;;
    fail)
      echo "[WARN] container exists; refusing to replace it (RESTORE_EXISTING=fail): $name" >&2
      exit 1
      ;;
    *)
      echo "[WARN] invalid RESTORE_EXISTING value: ${RESTORE_EXISTING}; use replace, skip, or fail" >&2
      exit 1
      ;;
  esac
fi

args=(docker run -d --name "$name")
cmd_args=()

mapfile -t entrypoint < <(jq -r '.[0].Config.Entrypoint[]?' "$META")
mapfile -t cmd < <(jq -r '.[0].Config.Cmd[]?' "$META")
if ((${#entrypoint[@]})); then
  args+=(--entrypoint "${entrypoint[0]}")
  if ((${#entrypoint[@]} > 1)); then
    cmd_args+=("${entrypoint[@]:1}")
  fi
fi
if ((${#cmd[@]})); then
  cmd_args+=("${cmd[@]}")
fi

user="$(jq -r '.[0].Config.User // empty' "$META")"
[[ -n "$user" ]] && args+=(-u "$user")

workdir="$(jq -r '.[0].Config.WorkingDir // empty' "$META")"
[[ -n "$workdir" ]] && args+=(-w "$workdir")

cid="$(jq -r '.[0].Id' "$META")"
default_host="${cid:0:12}"
hostname="$(jq -r '.[0].Config.Hostname // empty' "$META")"
if [[ -n "$hostname" && "$hostname" != "$default_host" ]]; then
  args+=(--hostname "$hostname")
fi

domainname="$(jq -r '.[0].Config.Domainname // empty' "$META")"
[[ -n "$domainname" ]] && args+=(--domainname "$domainname")

mapfile -t envs < <(jq -r '.[0].Config.Env[]?' "$META")
for e in "${envs[@]}"; do args+=(-e "$e"); done

mapfile -t labels < <(jq -r '.[0].Config.Labels // {} | to_entries[]? | "\(.key)=\(.value)"' "$META")
for l in "${labels[@]}"; do args+=(--label "$l"); done

restart_name="$(jq -r '.[0].HostConfig.RestartPolicy.Name // empty' "$META")"
restart_max="$(jq -r '.[0].HostConfig.RestartPolicy.MaximumRetryCount // 0' "$META")"
if [[ -n "$restart_name" && "$restart_name" != "no" ]]; then
  if [[ "$restart_name" == "on-failure" && "$restart_max" -gt 0 ]]; then
    args+=(--restart "${restart_name}:${restart_max}")
  else
    args+=(--restart "$restart_name")
  fi
fi

jq -e '.[0].HostConfig.Privileged == true' "$META" >/dev/null 2>&1 && args+=(--privileged)
jq -e '.[0].HostConfig.ReadonlyRootfs == true' "$META" >/dev/null 2>&1 && args+=(--read-only)
jq -e '.[0].HostConfig.Init == true' "$META" >/dev/null 2>&1 && args+=(--init)

# --- 设备映射: --device ---
mapfile -t devices < <(jq -r '.[0].HostConfig.Devices[]? | "\(.PathOnHost):\(.PathInContainer)\(if .CgroupPermissions then ":\(.CgroupPermissions)" else "" end)"' "$META")
for d in "${devices[@]}"; do args+=(--device "$d"); done

# --- 资源限制: --memory, --cpus, --shm-size ---
shm_size="$(jq -r '.[0].HostConfig.ShmSize // 0' "$META")"
if [[ "$shm_size" != "0" && "$shm_size" != "null" ]]; then args+=(--shm-size "${shm_size}b"); fi

mem="$(jq -r '.[0].HostConfig.Memory // 0' "$META")"
if [[ "$mem" != "0" && "$mem" != "null" ]]; then args+=(--memory "$mem"); fi

mem_swap="$(jq -r '.[0].HostConfig.MemorySwap // 0' "$META")"
if [[ "$mem_swap" != "0" && "$mem_swap" != "null" ]]; then args+=(--memory-swap "$mem_swap"); fi

mem_res="$(jq -r '.[0].HostConfig.MemoryReservation // 0' "$META")"
if [[ "$mem_res" != "0" && "$mem_res" != "null" ]]; then args+=(--memory-reservation "$mem_res"); fi

nano_cpus="$(jq -r '.[0].HostConfig.NanoCpus // 0' "$META")"
if [[ "$nano_cpus" != "0" && "$nano_cpus" != "null" ]]; then
  cpus="$(awk -v n="$nano_cpus" 'BEGIN { printf "%.9g", n / 1000000000 }')"
  args+=(--cpus "$cpus")
fi

cpu_shares="$(jq -r '.[0].HostConfig.CpuShares // 0' "$META")"
if [[ "$cpu_shares" != "0" && "$cpu_shares" != "null" ]]; then args+=(--cpu-shares "$cpu_shares"); fi

cpu_period="$(jq -r '.[0].HostConfig.CpuPeriod // 0' "$META")"
if [[ "$cpu_period" != "0" && "$cpu_period" != "null" ]]; then args+=(--cpu-period "$cpu_period"); fi

cpu_quota="$(jq -r '.[0].HostConfig.CpuQuota // 0' "$META")"
if [[ "$cpu_quota" != "0" && "$cpu_quota" != "null" ]]; then args+=(--cpu-quota "$cpu_quota"); fi

cpuset_cpus="$(jq -r '.[0].HostConfig.CpusetCpus // empty' "$META")"
[[ -n "$cpuset_cpus" ]] && args+=(--cpuset-cpus "$cpuset_cpus")

cpuset_mems="$(jq -r '.[0].HostConfig.CpusetMems // empty' "$META")"
[[ -n "$cpuset_mems" ]] && args+=(--cpuset-mems "$cpuset_mems")

oom_kill_disable="$(jq -r '.[0].HostConfig.OomKillDisable // false' "$META")"
[[ "$oom_kill_disable" == "true" ]] && args+=(--oom-kill-disable)

# --- 命名空间模式: --pid, --ipc, --uts ---
pid_mode="$(jq -r '.[0].HostConfig.PidMode // empty' "$META")"
if [[ -n "$pid_mode" && "$pid_mode" != "null" ]]; then
  pid_mode="$(resolve_container_mode "$pid_mode")"
  args+=(--pid "$pid_mode")
fi

ipc_mode="$(jq -r '.[0].HostConfig.IpcMode // empty' "$META")"
if [[ -n "$ipc_mode" && "$ipc_mode" != "null" ]]; then
  ipc_mode="$(resolve_container_mode "$ipc_mode")"
  args+=(--ipc "$ipc_mode")
fi

uts_mode="$(jq -r '.[0].HostConfig.UTSMode // empty' "$META")"
if [[ -n "$uts_mode" && "$uts_mode" != "null" && "$uts_mode" != "default" ]]; then
  args+=(--uts "$uts_mode")
fi

# --- 健康检查: 正确区分 NONE / CMD / CMD-SHELL ---
hc_kind="$(jq -r '.[0].Config.Healthcheck.Test[0] // empty' "$META" 2>/dev/null || true)"
if [[ "$hc_kind" == "NONE" ]]; then
  args+=(--no-healthcheck)
elif [[ "$hc_kind" == "CMD" || "$hc_kind" == "CMD-SHELL" ]]; then
  if [[ "$hc_kind" == "CMD-SHELL" ]]; then
    hc_test="$(jq -r '.[0].Config.Healthcheck.Test[1] // empty' "$META")"
  else
    hc_test="$(jq -r '.[0].Config.Healthcheck.Test[1:] | map(@sh) | join(" ")' "$META")"
  fi
  hc_interval="$(jq -r '.[0].Config.Healthcheck.Interval // 30000000000' "$META")"
  hc_timeout="$(jq -r '.[0].Config.Healthcheck.Timeout // 30000000000' "$META")"
  hc_retries="$(jq -r '.[0].Config.Healthcheck.Retries // 3' "$META")"
  hc_start_period="$(jq -r '.[0].Config.Healthcheck.StartPeriod // 0' "$META")"
  hc_start_interval="$(jq -r '.[0].Config.Healthcheck.StartInterval // 5000000000' "$META")"
  args+=(--health-cmd "$hc_test")
  args+=(--health-interval "${hc_interval}ns")
  args+=(--health-timeout "${hc_timeout}ns")
  args+=(--health-retries "$hc_retries")
  [[ "$hc_start_period" != "0" ]] && args+=(--health-start-period "${hc_start_period}ns")
  if [[ "$hc_start_interval" != "0" ]] && docker run --help 2>/dev/null | grep -q -- '--health-start-interval'; then
    args+=(--health-start-interval "${hc_start_interval}ns")
  fi
fi

# --- runtime: --runtime (例如 nvidia) ---
runtime="$(jq -r '.[0].HostConfig.Runtime // empty' "$META")"
if [[ -n "$runtime" && "$runtime" != "null" && "$runtime" != "runc" ]]; then
  args+=(--runtime "$runtime")
fi

# --- --group-add ---
mapfile -t group_add < <(jq -r '.[0].HostConfig.GroupAdd[]?' "$META")
for g in "${group_add[@]}"; do args+=(--group-add "$g"); done

# --- storage opt: --storage-opt ---
mapfile -t storage_opts < <(jq -r '.[0].HostConfig.StorageOpt // {} | to_entries[]? | "\(.key)=\(.value)"' "$META")
for s in "${storage_opts[@]}"; do args+=(--storage-opt "$s"); done

mapfile -t extra_hosts < <(jq -r '.[0].HostConfig.ExtraHosts[]?' "$META")
for h in "${extra_hosts[@]}"; do args+=(--add-host "$h"); done

mapfile -t dns_list < <(jq -r '.[0].HostConfig.Dns[]?' "$META")
for d in "${dns_list[@]}"; do args+=(--dns "$d"); done
mapfile -t dns_search < <(jq -r '.[0].HostConfig.DnsSearch[]?' "$META")
for d in "${dns_search[@]}"; do args+=(--dns-search "$d"); done
mapfile -t dns_opts < <(jq -r '.[0].HostConfig.DnsOptions[]?' "$META")
for d in "${dns_opts[@]}"; do args+=(--dns-option "$d"); done

mapfile -t cap_add < <(jq -r '.[0].HostConfig.CapAdd[]?' "$META")
for c in "${cap_add[@]}"; do args+=(--cap-add "$c"); done
mapfile -t cap_drop < <(jq -r '.[0].HostConfig.CapDrop[]?' "$META")
for c in "${cap_drop[@]}"; do args+=(--cap-drop "$c"); done
mapfile -t sec_opts < <(jq -r '.[0].HostConfig.SecurityOpt[]?' "$META")
for s in "${sec_opts[@]}"; do args+=(--security-opt "$s"); done
mapfile -t sysctls < <(jq -r '.[0].HostConfig.Sysctls // {} | to_entries[]? | "\(.key)=\(.value)"' "$META")
for s in "${sysctls[@]}"; do args+=(--sysctl "$s"); done
mapfile -t ulimits < <(jq -r '.[0].HostConfig.Ulimits[]? | "\(.Name)=\(.Soft):\(.Hard)"' "$META")
for u in "${ulimits[@]}"; do args+=(--ulimit "$u"); done
mapfile -t tmpfs < <(jq -r '.[0].HostConfig.Tmpfs // {} | to_entries[]? | "\(.key):\(.value)"' "$META")
for t in "${tmpfs[@]}"; do args+=(--tmpfs "$t"); done

log_driver="$(jq -r '.[0].HostConfig.LogConfig.Type // empty' "$META")"
if [[ -n "$log_driver" && "$log_driver" != "json-file" ]]; then
  args+=(--log-driver "$log_driver")
fi
mapfile -t log_opts < <(jq -r '.[0].HostConfig.LogConfig.Config // {} | to_entries[]? | "\(.key)=\(.value)"' "$META")
for o in "${log_opts[@]}"; do args+=(--log-opt "$o"); done

publish_all="$(jq -r '.[0].HostConfig.PublishAllPorts // false' "$META")"
if [[ "$publish_all" == "true" ]]; then
  args+=(-P)
fi

# 关键修复：稳健还原 PortBindings。
# 旧脚本在 HostPort 为空或 IPv6 HostIp 场景下容易生成无效 -p；这里跳过空 HostPort，并给 IPv6 加 []。
mapfile -t port_bindings < <(jq -r '.[0].HostConfig.PortBindings // {} | to_entries[]? | .key as $c | .value[]? | "\(.HostIp // "")|\(.HostPort // "")|\($c)"' "$META")
for p in "${port_bindings[@]}"; do
  host_ip="${p%%|*}"
  rest="${p#*|}"
  host_port="${rest%%|*}"
  cont_port="${rest#*|}"

  # 空 HostPort 是 Docker 随机端口分配（如 -p 80 或 -p 0.0.0.0::80），保留空 HostPort 让 Docker 重新随机分配
  [[ -z "$cont_port" ]] && continue

  if [[ -z "$host_port" || "$host_port" == "null" ]]; then
    # 随机端口：格式为 -p [ip::]containerPort[/proto]
    host_port=""
  fi

  if [[ -n "$host_ip" && "$host_ip" != "0.0.0.0" && "$host_ip" != "::" ]]; then
    if [[ "$host_ip" == *:* ]]; then
      args+=(-p "[${host_ip}]:${host_port}:${cont_port}")
    else
      args+=(-p "${host_ip}:${host_port}:${cont_port}")
    fi
  else
    args+=(-p "${host_port}:${cont_port}")
  fi
  echo "[INFO] restore port: ${host_ip:-0.0.0.0}:${host_port}->${cont_port}"
done

mapfile -t mounts < <(jq -r '.[0].Mounts[]? | @base64' "$META")
for m in "${mounts[@]}"; do
  _jq(){ echo "$m" | decode_base64 | jq -r "$1"; }
  m_type="$(_jq '.Type')"
  dest="$(_jq '.Destination')"
  rw="$(_jq '.RW')"
  mode="$(_jq '.Mode // empty')"
  src=""
  case "$m_type" in
    volume) src="$(_jq '.Name')" ;;
    bind) src="$(_jq '.Source')" ;;
    tmpfs) continue ;;
    *) continue ;;
  esac
  [[ -z "$src" || -z "$dest" || "$src" == "null" || "$dest" == "null" ]] && continue

  opts=()
  if [[ -n "$mode" && "$mode" != "null" ]]; then
    IFS=',' read -r -a mode_parts <<<"$mode"
    for part in "${mode_parts[@]}"; do [[ -n "$part" ]] && opts+=("$part"); done
  fi
  [[ "$rw" != "true" ]] && opts+=(ro)
  if ((${#opts[@]})); then
    optstr="$(IFS=,; echo "${opts[*]}")"
    args+=(-v "${src}:${dest}:${optstr}")
  else
    args+=(-v "${src}:${dest}")
  fi
done

network_mode="$(jq -r '.[0].HostConfig.NetworkMode // empty' "$META")"
network_mode="$(resolve_container_mode "$network_mode")"

primary_net=""
if [[ -n "$network_mode" && "$network_mode" != "default" && "$network_mode" != "bridge" ]]; then
  args+=(--network "$network_mode")
  primary_net="$network_mode"
else
  primary_net="bridge"
fi

if [[ "$primary_net" != "bridge" && "$primary_net" != "host" &&
      "$primary_net" != "none" && "$primary_net" != container:* ]]; then
  primary_ip="$(jq -r --arg n "$primary_net" '.[0].NetworkSettings.Networks[$n].IPAMConfig.IPv4Address // .[0].NetworkSettings.Networks[$n].IPAddress // empty' "$META")"
  primary_ip6="$(jq -r --arg n "$primary_net" '.[0].NetworkSettings.Networks[$n].IPAMConfig.IPv6Address // .[0].NetworkSettings.Networks[$n].GlobalIPv6Address // .[0].NetworkSettings.Networks[$n].IPv6Address // empty' "$META")"
  [[ -z "$primary_ip" ]] || args+=(--ip "$primary_ip")
  [[ -z "$primary_ip6" ]] || args+=(--ip6 "$primary_ip6")
  mapfile -t primary_aliases < <(jq -r --arg n "$primary_net" '.[0].NetworkSettings.Networks[$n].Aliases[]? // empty' "$META")
  for primary_alias in "${primary_aliases[@]}"; do
    [[ -z "$primary_alias" || "$primary_alias" == "$name" ]] || args+=(--network-alias "$primary_alias")
  done
fi

args+=("$image")
if ((${#cmd_args[@]})); then
  args+=("${cmd_args[@]}")
fi

set +e
"${args[@]}"
run_rc=$?
set -e

# 端口冲突检测：宿主机端口已被占用时给出明确提示
if [[ $run_rc -ne 0 ]]; then
  # 回显 docker run 的所有 -p 参数便于排查
  failed_ports=()
  for a in "${args[@]}"; do
    [[ "$a" == -p ]] && continue
    [[ "$a" == -* ]] && { last_opt="$a"; continue; }
    if [[ -n "${last_opt:-}" ]]; then last_opt=""; fi
    if [[ "$a" == *:* ]]; then
      failed_ports+=("$a")
    fi
  done
  if ((${#failed_ports[@]})); then
    echo "[WARN] 容器启动失败，可能是端口冲突。" >&2
    echo "[WARN] 尝试绑定的端口：" >&2
    for p in "${failed_ports[@]}"; do
      echo "[WARN]   - $p" >&2
    done
    echo "[WARN] 请检查占用端口的进程并释放：sudo ss -lntp | grep <PORT>" >&2
  fi
  exit $run_rc
fi

# 连接额外网络。
if [[ "$network_mode" != "host" && "$network_mode" != "none" && "$network_mode" != container:* ]]; then
  mapfile -t net_entries < <(jq -r '.[0].NetworkSettings.Networks | to_entries[]? | @base64' "$META")
  for entry in "${net_entries[@]}"; do
    _net(){ echo "$entry" | decode_base64 | jq -r "$1"; }
    net_name="$(_net '.key')"
    [[ -z "$net_name" || "$net_name" == "$primary_net" || "$net_name" == "bridge" ]] && continue
    ip="$(_net '.value.IPAMConfig.IPv4Address // .value.IPAddress // empty')"
    ip6="$(_net '.value.IPAMConfig.IPv6Address // .value.GlobalIPv6Address // .value.IPv6Address // empty')"
    aliases_raw="$(_net '.value.Aliases // empty | join(" ")')"
    conn_args=()
    [[ -n "$ip" && "$ip" != "null" ]] && conn_args+=(--ip "$ip")
    [[ -n "$ip6" && "$ip6" != "null" ]] && conn_args+=(--ip6 "$ip6")
    if [[ -n "$aliases_raw" && "$aliases_raw" != "null" ]]; then
      for a in $aliases_raw; do conn_args+=(--alias "$a"); done
    fi
    docker network connect "${conn_args[@]}" "$net_name" "$name" >/dev/null 2>&1 || {
      echo "[WARN] 连接额外网络失败：$net_name，容器可能缺少网络" >&2
      case "$net_name" in
        macvlan*|ipvlan*|overlay*)
          echo "[WARN] → 网络 $net_name 需管理员在目标服务器预创建（macvlan/ipvlan/overlay 不自动创建）" >&2
          ;;
      esac
    }
  done
fi
RUN_SH
  # 安全转义容器名中的 \ / &，防止 sed 替换出错
  local escaped_name="$name"
  escaped_name="${escaped_name//\\/\\\\}" # \ → \\
  escaped_name="${escaped_name//\//\\/}"  # / → \/
  escaped_name="${escaped_name//&/\\&}"   # & → \&
  local rendered="${out}.rendered"
  sed "s/__NAME__/${escaped_name}/g" "$out" >"$rendered"
  mv "$rendered" "$out"
  chmod +x "$out"
}

#####################################
# 生成恢复主脚本
#####################################
write_bundle_restore_script() {
  local out="$1"
  cat >"$out" <<'REST_SH'
#!/usr/bin/env bash
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$BUNDLE_DIR"

say(){ echo -e "\033[1;34m$*\033[0m"; }
warn(){ echo -e "\033[1;33m$*\033[0m"; }

# Failure tracking
FAILED_VOLUMES=()
FAILED_BINDS=()
FAILED_NETWORKS=()
FAILED_PROJECTS=()
FAILED_CONTAINERS=()

restore_has_failures() {
  (( ${#FAILED_VOLUMES[@]} > 0 ||
     ${#FAILED_BINDS[@]} > 0 ||
     ${#FAILED_NETWORKS[@]} > 0 ||
     ${#FAILED_PROJECTS[@]} > 0 ||
     ${#FAILED_CONTAINERS[@]} > 0 ))
}

print_failure_summary() {
  restore_has_failures || return 0
  warn "============================================"
  warn "  部分内容恢复失败，请检查以下项目："
  ((${#FAILED_VOLUMES[@]} == 0)) || warn "  · 命名卷失败: ${FAILED_VOLUMES[*]}"
  ((${#FAILED_BINDS[@]} == 0)) || warn "  · 绑定目录失败: ${FAILED_BINDS[*]}"
  ((${#FAILED_NETWORKS[@]} == 0)) || warn "  · 自定义网络失败: ${FAILED_NETWORKS[*]}"
  ((${#FAILED_PROJECTS[@]} == 0)) || warn "  · Compose 项目失败: ${FAILED_PROJECTS[*]}"
  if ((${#FAILED_CONTAINERS[@]} > 0)); then
    warn "  · 独立容器失败: ${FAILED_CONTAINERS[*]}"
    warn "  常见原因：端口冲突、镜像缺失、网络配置不兼容。"
    warn "  可用命令排查端口：sudo ss -lntp"
  fi
  warn "============================================"
}

compose_run() {
  if [[ "${COMPOSE_IMPL:-}" == "plugin" ]]; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

run_with_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  else
    "$@"
  fi
}

restore_sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  else
    return 127
  fi
}

restore_verify_checksums() {
  local expected rel file actual count=0
  [[ -f checksums.sha256 ]] || return 2
  while IFS=$'\t' read -r expected rel; do
    [[ -n "$expected" && -n "$rel" ]] || continue
    case "$rel" in /*|..|../*|*/../*|*/..) return 1 ;; esac
    file="${BUNDLE_DIR}/${rel}"
    [[ -f "$file" ]] || return 1
    actual="$(restore_sha256_file "$file")" || return 1
    [[ "$actual" == "$expected" ]] || return 1
    count=$((count + 1))
  done <checksums.sha256
  (( count > 0 ))
}

archive_members_safe() {
  local archive="$1"
  local allowed_prefix="${2:-}"
  local entry
  tar -tzf "$archive" >/dev/null 2>&1 || return 1
  while IFS= read -r entry; do
    entry="${entry#./}"
    case "$entry" in /*|..|../*|*/../*|*/..) return 1 ;; esac
    if [[ -n "$allowed_prefix" &&
          "$entry" != "$allowed_prefix" &&
          "$entry" != "${allowed_prefix}/"* ]]; then
      return 1
    fi
  done < <(tar -tzf "$archive")
}

compose_networks_from_meta_all() {
  [[ -d meta ]] || return 0
  local f proj
  for f in meta/*.inspect.json; do
    [[ -f "$f" ]] || continue
    proj="$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' "$f" 2>/dev/null || true)"
    [[ -n "$proj" ]] || continue
    jq -r '.[0].NetworkSettings.Networks | keys[]?' "$f" 2>/dev/null || true
  done | awk '!/^(bridge|host|none)$/' | sort -u
}

compose_networks_from_meta_for_project() {
  local project="$1"
  [[ -d meta ]] || return 0
  local f proj
  for f in meta/*.inspect.json; do
    [[ -f "$f" ]] || continue
    proj="$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' "$f" 2>/dev/null || true)"
    [[ "$proj" == "$project" ]] || continue
    jq -r '.[0].NetworkSettings.Networks | keys[]?' "$f" 2>/dev/null || true
  done | awk '!/^(bridge|host|none)$/' | sort -u
}

compose_cleanup_conflicting_network() {
  local project="$1" network_name="$2"
  [[ -n "$network_name" ]] || return 0
  if ! docker network inspect "$network_name" >/dev/null 2>&1; then
    return 0
  fi
  local proj_label net_label
  proj_label="$(docker network inspect -f '{{ index .Labels "com.docker.compose.project" }}' "$network_name" 2>/dev/null || true)"
  net_label="$(docker network inspect -f '{{ index .Labels "com.docker.compose.network" }}' "$network_name" 2>/dev/null || true)"
  # 仅当网络属于当前项目（有 project label 且匹配）时才允许删除
  # 空 proj_label 表示非 compose 网络（手动创建或外部共享），跳过删除
  if [[ -n "$proj_label" && -n "$net_label" && "$proj_label" == "$project" ]]; then
    if docker network rm "$network_name" >/dev/null 2>&1; then
      echo " · 已清理旧网络：$network_name"
    else
      warn " · 无法清理网络：$network_name（可能仍被占用）"
    fi
  fi
}

compose_network_records() {
  local project="$1"
  shift
  local tmp_cfg=""
  if command -v mktemp >/dev/null 2>&1; then
    tmp_cfg="$(mktemp)"
  else
    tmp_cfg="/tmp/docker_migrate_compose_config_$$.json"
    : > "$tmp_cfg"
  fi

  if compose_run "$@" config --format json >"$tmp_cfg" 2>/dev/null; then
    jq -r '
      .name as $project |
      ((.networks // {"default": {}}) | to_entries[]) |
      [(.value.name // "\($project)_\(.key)"), ((.value.external // false) | tostring)] | @tsv
    ' "$tmp_cfg"
    rm -f "$tmp_cfg" 2>/dev/null || true
    return 0
  fi
  rm -f "$tmp_cfg" 2>/dev/null || true

  while IFS= read -r net; do
    [[ -n "$net" ]] || continue
    if [[ "$net" == "${project}_"* ]]; then
      printf '%s\tfalse\n' "$net"
    else
      printf '%s\tunknown\n' "$net"
    fi
  done < <(compose_networks_from_meta_for_project "$project")
}

compose_prepare_networks() {
  local project="$1"
  shift
  local seen=0 net external
  while IFS=$'\t' read -r net external; do
    [[ -n "$net" ]] || continue
    seen=1
    case "$external" in
      true)
        if ! docker network inspect "$net" >/dev/null 2>&1; then
          warn " · 检测到外部网络缺失，尝试创建：$net"
          docker network create "$net" >/dev/null 2>&1 || warn " · 创建外部网络失败：$net"
        fi
        ;;
      false)
        compose_cleanup_conflicting_network "$project" "$net"
        ;;
      *)
        if [[ "$net" == "${project}_"* ]]; then
          compose_cleanup_conflicting_network "$project" "$net"
        fi
        ;;
    esac
  done < <(compose_network_records "$project" "$@")

  if (( seen == 0 )); then
    while IFS= read -r net; do
      [[ -n "$net" ]] || continue
      if [[ "$net" == "${project}_"* ]]; then
        compose_cleanup_conflicting_network "$project" "$net"
      fi
    done < <(compose_networks_from_meta_for_project "$project")
  fi
}

create_network_from_record() {
  local row="$1"
  local name driver desired_core actual_core cfg subnet ip_range gateway
  local ipam_driver pair
  local -a create_args option_pairs label_pairs ipam_option_pairs aux_pairs
  name="$(jq -r '.name' <<<"$row")"
  driver="$(jq -r '.driver // "bridge"' <<<"$row")"
  [[ -n "$name" && "$name" != "null" ]] || return 1

  desired_core="$(jq -cS '{
    driver: (.driver // "bridge"),
    internal: (.internal // false),
    attachable: (.attachable // false),
    enable_ipv6: (.enable_ipv6 // false),
    options: (.options // {}),
    ipam: {
      driver: (.ipam.driver // "default"),
      options: (.ipam.options // {}),
      config: (.ipam.config // [])
    }
  }' <<<"$row")"

  if docker network inspect "$name" >/dev/null 2>&1; then
    if [[ "$(jq -r '.legacy // false' <<<"$row")" == "true" ]]; then
      return 0
    fi
    actual_core="$(docker network inspect "$name" | jq -cS '.[0] | {
      driver: (.Driver // "bridge"),
      internal: (.Internal // false),
      attachable: (.Attachable // false),
      enable_ipv6: (.EnableIPv6 // false),
      options: (.Options // {}),
      ipam: {
        driver: (.IPAM.Driver // "default"),
        options: (.IPAM.Options // {}),
        config: (.IPAM.Config // [])
      }
    }')"
    if [[ "$actual_core" != "$desired_core" ]]; then
      warn " 已存在同名但配置不同的网络：$name；为避免断开其他容器，不自动删除。"
      return 1
    fi
    return 0
  fi

  create_args=(docker network create --driver "$driver")
  [[ "$(jq -r '.internal // false' <<<"$row")" != "true" ]] || create_args+=(--internal)
  [[ "$(jq -r '.attachable // false' <<<"$row")" != "true" ]] || create_args+=(--attachable)
  [[ "$(jq -r '.enable_ipv6 // false' <<<"$row")" != "true" ]] || create_args+=(--ipv6)
  ipam_driver="$(jq -r '.ipam.driver // "default"' <<<"$row")"
  [[ "$ipam_driver" == "default" ]] || create_args+=(--ipam-driver "$ipam_driver")

  mapfile -t option_pairs < <(jq -r '.options // {} | to_entries[]? | "\(.key)=\(.value)"' <<<"$row")
  for pair in "${option_pairs[@]}"; do create_args+=(--opt "$pair"); done
  mapfile -t label_pairs < <(jq -r '.labels // {} | to_entries[]? | "\(.key)=\(.value)"' <<<"$row")
  for pair in "${label_pairs[@]}"; do create_args+=(--label "$pair"); done
  mapfile -t ipam_option_pairs < <(jq -r '.ipam.options // {} | to_entries[]? | "\(.key)=\(.value)"' <<<"$row")
  for pair in "${ipam_option_pairs[@]}"; do create_args+=(--ipam-opt "$pair"); done

  while IFS= read -r cfg; do
    [[ -n "$cfg" ]] || continue
    subnet="$(jq -r '.Subnet // empty' <<<"$cfg")"
    ip_range="$(jq -r '.IPRange // empty' <<<"$cfg")"
    gateway="$(jq -r '.Gateway // empty' <<<"$cfg")"
    [[ -z "$subnet" ]] || create_args+=(--subnet "$subnet")
    [[ -z "$ip_range" ]] || create_args+=(--ip-range "$ip_range")
    [[ -z "$gateway" ]] || create_args+=(--gateway "$gateway")
    mapfile -t aux_pairs < <(jq -r '.AuxiliaryAddresses // {} | to_entries[]? | "\(.key)=\(.value)"' <<<"$cfg")
    for pair in "${aux_pairs[@]}"; do create_args+=(--aux-address "$pair"); done
  done < <(jq -c '.ipam.config[]?' <<<"$row")
  create_args+=("$name")

  "${create_args[@]}" >/dev/null
}

if [[ "${RESTORE_CHECKSUM_VERIFIED:-0}" == "1" ]]; then
  :
elif [[ -f checksums.sha256 ]]; then
  say "[0] 验证迁移包完整性"
  if ! restore_verify_checksums; then
    warn "迁移包完整性校验失败，拒绝恢复。"
    exit 1
  fi
else
  warn "旧版迁移包未包含校验清单，按兼容模式继续。"
fi

say "[A] 加载镜像（如 images.tar 存在）"
if [[ -f images.tar ]]; then
  docker load -i images.tar || warn "部分镜像加载失败，将尝试在线拉取"
else
  warn "images.tar 不存在，将按需在线拉取镜像。"
fi

say "[B] 回灌命名卷"
docker pull alpine:3.20 >/dev/null 2>&1 || warn "无法拉取 alpine:3.20，卷恢复可能失败"
if jq -e '.volumes|length>0' manifest.json >/dev/null 2>&1; then
  mkdir -p volumes
  while IFS= read -r row; do
    vname=$(jq -r '.name' <<<"$row")
    file="vol_${vname}.tgz"
    if [[ ! -f "volumes/$file" ]]; then
      warn " 命名卷缺少备份文件：$vname（volumes/$file）"
      FAILED_VOLUMES+=("$vname")
      continue
    fi
    if ! archive_members_safe "volumes/$file"; then
      warn " 命名卷归档结构异常：$vname"
      FAILED_VOLUMES+=("$vname")
      continue
    fi
    echo " - ${vname}"
    # 使用备份时记录的 driver 和 options 创建卷
    v_driver=$(jq -r '.driver // "local"' <<<"$row")
    volume_create_args=(docker volume create --driver "$v_driver")
    mapfile -t volume_opts < <(jq -r '.opts // {} | to_entries[]? | "\(.key)=\(.value)"' <<<"$row" 2>/dev/null || true)
    for volume_opt in "${volume_opts[@]}"; do
      volume_create_args+=(--opt "$volume_opt")
    done
    volume_create_args+=("$vname")
    if ! "${volume_create_args[@]}" >/dev/null 2>&1; then
      warn " 卷创建失败（driver=$v_driver）：$vname"
      FAILED_VOLUMES+=("$vname")
      continue
    fi
    if ! docker run --rm \
      -v "${vname}:/to" \
      -v "$PWD/volumes:/from" \
      alpine:3.20 sh -c "cd /to && tar -xzf /from/${file}"; then
      warn " 恢复卷 ${vname} 失败，跳过"
      FAILED_VOLUMES+=("$vname")
    fi
  done < <(jq -c '.volumes[]' manifest.json)
fi

say "[C] 回灌绑定目录"
if jq -e '.binds|length>0' manifest.json >/dev/null 2>&1; then
  mkdir -p binds
  while IFS= read -r row; do
    host=$(jq -r '.host' <<<"$row")
    file=$(jq -r '.file' <<<"$row")
    if [[ ! -f "binds/$file" ]]; then
      warn " 绑定目录缺少备份文件：$host（binds/$file）"
      FAILED_BINDS+=("$host")
      continue
    fi
    bind_prefix="${host#/}"
    if ! archive_members_safe "binds/$file" "$bind_prefix"; then
      warn " 绑定目录归档结构异常：$host"
      FAILED_BINDS+=("$host")
      continue
    fi
    echo " - ${host}"
    parent="$(dirname "$host")"
    if ! run_with_timeout 10 sudo -n mkdir -p "$parent" 2>/dev/null &&
       ! mkdir -p "$parent" 2>/dev/null; then
      warn " 无法创建绑定目录的父目录：$parent"
      FAILED_BINDS+=("$host")
      continue
    fi
    if ! run_with_timeout 30 sudo -n tar -C / -xzf "binds/${file}" 2>/dev/null &&
       ! tar -C / -xzf "binds/${file}" 2>/dev/null; then
      warn " 无法恢复绑定目录：$host（可能需要 root 权限）"
      FAILED_BINDS+=("$host")
    fi
  done < <(jq -c '.binds[]' manifest.json)
fi

# 数据恢复失败时禁止继续启动容器，避免 Docker 自动创建空卷/空目录。
if ((${#FAILED_VOLUMES[@]} > 0 || ${#FAILED_BINDS[@]} > 0)); then
  print_failure_summary
  exit 1
fi

say "[D] 恢复 Compose 项目"
if jq -e '.projects|length>0' manifest.json >/dev/null 2>&1; then
  mkdir -p compose_restore
  while IFS= read -r row; do
    USE_WDIR=0
    name=$(jq -r '.name' <<<"$row")
    wdir=$(jq -r '.working_dir // ""' <<<"$row")
    echo " - project: $name"
    mkdir -p "compose_restore/${name}"

    if [[ -d "compose/${name}" ]]; then
      cp -a "compose/${name}/." "compose_restore/${name}/"
    fi

    if [[ -n "$wdir" ]]; then
      echo " · 还原 compose 配置到原路径：$wdir"
      mkdir -p "$wdir"
      cp -a "compose/${name}/." "$wdir/"
      # 如果 wdir 存在且 compose 文件已还原到 wdir，则从 wdir 执行 compose up
      # 这确保 1Panel / 宝塔等使用相对路径 bind mount 的 compose 项目能正确解析路径
      USE_WDIR=1
    fi

    # 恢复原本使用绝对路径的 env_file（普通相对路径已由递归复制保留）。
    if [[ -f "compose/${name}/.env_file_map.jsonl" ]]; then
      while IFS= read -r env_map; do
        env_source="$(jq -r '.source' <<<"$env_map")"
        env_stored="$(jq -r '.stored' <<<"$env_map")"
        [[ -n "$env_source" && -f "compose/${name}/${env_stored}" ]] || continue
        mkdir -p "$(dirname "$env_source")"
        cp -a "compose/${name}/${env_stored}" "$env_source"
      done < "compose/${name}/.env_file_map.jsonl"
    fi

    # 构建多文件 -f 参数：从 manifest 的 config_files 提取 basename
    # 如果没有 config_files，compose 会按默认文件名自动扫描
    declare -a COMPOSE_FILE_ARGS=()
    if jq -e '.config_files|length>0' <<<"$row" >/dev/null 2>&1; then
      while IFS= read -r cf; do
        [[ -n "$cf" ]] || continue
        local_fn="compose_restore/${name}/$(basename "$cf")"
        if [[ -f "$local_fn" ]]; then
          COMPOSE_FILE_ARGS+=(-f "$(basename "$cf")")
        fi
      done < <(jq -r '.config_files[]?' <<<"$row")
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      compose_impl="plugin"
    elif command -v docker-compose >/dev/null 2>&1; then
      compose_impl="legacy"
    else
      warn " 新机未安装 docker compose/docker-compose，跳过该项目。"
      FAILED_PROJECTS+=("$name")
      continue
    fi

    if [[ "$USE_WDIR" == "1" ]]; then
      compose_dir="$wdir"
    else
      compose_dir="compose_restore/${name}"
    fi
    (
      cd "$compose_dir"
      COMPOSE_IMPL="$compose_impl"
      # down 与 up 使用完全相同的多文件参数，避免操作到错误的 Compose 项目。
      compose_run "${COMPOSE_FILE_ARGS[@]}" down || true
      compose_prepare_networks "$name" "${COMPOSE_FILE_ARGS[@]}"
      compose_run "${COMPOSE_FILE_ARGS[@]}" up -d 2>&1
    ) || FAILED_PROJECTS+=("$name")
  done < <(jq -c '.projects[]' manifest.json)
fi

say "[E] 创建独立容器自定义网络（非 Compose）"
declare -A COMPOSE_NETS=()
while IFS= read -r n; do
  [[ -n "$n" ]] || continue
  COMPOSE_NETS["$n"]=1
done < <(compose_networks_from_meta_all)

if jq -e '.networks|length>0' manifest.json >/dev/null 2>&1; then
  while IFS= read -r network_row; do
    n="$(jq -r '.name // empty' <<<"$network_row")"
    case "$n" in bridge|host|none|"") continue ;; esac
    if [[ -n "${COMPOSE_NETS[$n]:-}" ]]; then
      continue
    fi
    if ! create_network_from_record "$network_row"; then
      FAILED_NETWORKS+=("$n")
    fi
  done < <(jq -c '.networks[] | if type == "string" then
    {name: ., legacy: true, driver: "bridge", internal: false, attachable: false,
     enable_ipv6: false, options: {}, labels: {},
     ipam: {driver: "default", options: {}, config: []}}
    else . end' manifest.json)
fi

if ((${#FAILED_NETWORKS[@]} > 0)); then
  print_failure_summary
  exit 1
fi

say "[F] 恢复单容器（非 Compose）"
if jq -e '.runs|length>0' manifest.json >/dev/null 2>&1; then
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    echo " - $r"
    if ! bash "$r" 2>&1; then
      warn " 容器恢复脚本失败：$r"
      # 从 run 脚本中提取容器名以便诊断
      cname_from_script="${r#runs/}"
      cname_from_script="${cname_from_script%.sh}"
      FAILED_CONTAINERS+=("$cname_from_script")
    fi
  done < <(jq -r '.runs[]' manifest.json)
fi

say "[G] 完成，当前容器："
docker ps --format ' {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo "提示：若端口被占用，请释放端口后重新执行 restore.sh；本版会在端口绑定不一致时重建同名容器。"

if restore_has_failures; then
  print_failure_summary
  exit 1
fi
REST_SH
  chmod +x "$out"
}

#####################################
# 恢复模式
#####################################
restore_prompt_url() {
  local restore_url="${1:-}"
  if [[ -z "$restore_url" ]]; then
    read -rp "请输入旧服务器的一键包下载链接（以 .tar.gz 结尾）： " restore_url
  fi
  if ! [[ "$restore_url" =~ \.tar\.gz($|\?) ]]; then
    RED "[ERR] 链接必须以 .tar.gz 结尾。"
    exit 1
  fi
  echo "$restore_url"
}

restore_find_bundle_dir() {
  local outdir="$1" rid="$2"
  if [[ -d "${outdir}/${rid}" && -f "${outdir}/${rid}/restore.sh" ]]; then
    echo "${outdir}/${rid}"
    return 0
  fi
  local first
  first="$(find "$outdir" -maxdepth 2 -type f -name restore.sh -print | head -n1 || true)"
  [[ -n "$first" ]] && dirname "$first"
}

restore_ensure_deps() {
  local pm
  pm="$(pm_detect)"
  local pair bin pkg
  for pair in "curl curl" "tar tar" "jq jq" "docker docker"; do
    bin="${pair%% *}"
    pkg="${pair##* }"
    if ! command -v "$bin" >/dev/null 2>&1; then
      if [[ "$pm" == "none" ]]; then
        RED "[ERR] 缺少命令：$bin，请在新服务器安装该命令后重试。"
        exit 1
      fi
      if [[ "$bin" == "docker" ]]; then
        YEL "[INFO] 安装依赖：$bin（以及 docker compose）"
        case "$pm" in
          apt) pm_install "$pm" docker.io ;;
          dnf | yum | zypper | apk) pm_install "$pm" docker ;;
          *) pm_install "$pm" docker || true ;;
        esac
        if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
          case "$pm" in
            apt) pm_install "$pm" docker-compose-plugin || pm_install "$pm" docker-compose || true ;;
            dnf | yum | zypper | apk) pm_install "$pm" docker-compose || true ;;
            *) pm_install "$pm" docker-compose || true ;;
          esac
        fi
      else
        YEL "[INFO] 安装依赖：$bin"
        pm_install "$pm" "$pkg"
      fi
    fi
  done
  ensure_docker_running
}

restore_main() {
  restore_ensure_deps
  local URL
  URL="$(restore_prompt_url "${1:-}")"
  local BASE="${RESTORE_BASE:-$HOME/docker_migrate_restore}"
  mkdir -p "$BASE"
  local RID
  RID="$(basename "$URL" | sed 's/\.tar\.gz.*$//' | tr -dc 'A-Za-z0-9_-')"
  [[ -n "$RID" ]] || RID="$(date +%s)"
  local TGZ="${BASE}/bundle.tar.gz"
  local OUTDIR="${BASE}/${RID}"

  BLUE "[INFO] 下载：$URL"
  if ! curl -fL --progress-bar --retry 5 --retry-delay 10 --retry-max-time 300 --connect-timeout 30 "$URL" -o "$TGZ"; then
    RED "[ERR] 下载失败：$URL"
    exit 1
  fi
  OK "[OK] 保存路径：$TGZ"
  BLUE "[INFO] 文件大小：$(du -h "$TGZ" | awk '{print $1}')"
  if ! archive_layout_is_safe "$TGZ"; then
    RED "[ERR] 迁移包结构不安全或已损坏，拒绝解压。"
    exit 1
  fi
  BLUE "[INFO] 解压到：$OUTDIR"
  mkdir -p "$OUTDIR"
  BLUE "[INFO] 正在解压压缩包（根据文件大小可能需要一段时间，请不要中断）..."
  if ! tar -xzf "$TGZ" -C "$OUTDIR"; then
    RED "[ERR] 解压失败，请检查磁盘空间或确认文件是否完整。"
    exit 1
  fi

  local BUNDLE_DIR
  BUNDLE_DIR="$(restore_find_bundle_dir "$OUTDIR" "$RID" || true)"
  if [[ -z "$BUNDLE_DIR" || ! -f "${BUNDLE_DIR}/restore.sh" ]]; then
    RED "[ERR] 未找到 restore.sh，解压内容异常：$OUTDIR"
    exit 1
  fi
  if [[ -f "${BUNDLE_DIR}/checksums.sha256" ]]; then
    BLUE "[INFO] 验证迁移包完整性 ..."
    if ! verify_bundle_checksums "$BUNDLE_DIR"; then
      RED "[ERR] 完整性校验未通过，拒绝恢复。"
      exit 1
    fi
    OK "[OK] 迁移包完整性校验通过"
  else
    YEL "[WARN] 这是未带校验清单的旧版迁移包，将按兼容模式继续。"
  fi

  # 使用当前脚本内置的修复版 restore.sh 覆盖包内旧 restore.sh。
  write_bundle_restore_script "${BUNDLE_DIR}/restore.sh"

  BLUE "[INFO] 执行恢复脚本：${BUNDLE_DIR}/restore.sh"
  BLUE "[INFO] 该步骤会加载镜像、回灌卷和绑定目录，并启动容器，可能需要数分钟，请耐心等待..."
  local rc
  set +e
  RESTORE_CHECKSUM_VERIFIED=1 bash "${BUNDLE_DIR}/restore.sh"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    OK "[OK] 恢复完成！当前容器："
    docker ps --format ' {{.Names}}\t{{.Status}}\t{{.Ports}}'
    if [[ "${RESTORE_KEEP:-0}" == "1" ]]; then
      YEL "[INFO] 已按 RESTORE_KEEP=1 保留文件：$TGZ 与 $OUTDIR"
    else
      rm -rf "$TGZ" "$OUTDIR" 2>/dev/null || true
      OK "[OK] 已清理下载文件与临时目录"
    fi
    exit 0
  else
    RED "[ERR] 恢复脚本返回非零：$rc"
    YEL "[INFO] 为便于排查，默认保留文件：$TGZ 与 $OUTDIR"
    if [[ "${RESTORE_CLEAN_ALL:-0}" == "1" ]]; then
      YEL "[WARN] RESTORE_CLEAN_ALL=1：仍将强制删除文件"
      rm -rf "$TGZ" "$OUTDIR" 2>/dev/null || true
      OK "[OK] 已清理下载文件与临时目录"
    fi
    exit "$rc"
  fi
}

if [[ "${DOCKER_MIGRATE_LIB_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

#####################################
# 模式选择：1) 备份并传输 2) 下载并恢复
#####################################
REQUESTED_MODE=""
RESTORE_URL=""
declare -a ORIGINAL_ARGS=("$@")
for ((arg_i = 0; arg_i < ${#ORIGINAL_ARGS[@]}; arg_i++)); do
  case "${ORIGINAL_ARGS[$arg_i]}" in
    -h | --help)
      show_help
      exit 0
      ;;
    --backup) REQUESTED_MODE=1 ;;
    --restore=*)
      REQUESTED_MODE=2
      RESTORE_URL="${ORIGINAL_ARGS[$arg_i]#*=}"
      ;;
    --restore)
      REQUESTED_MODE=2
      if ((arg_i + 1 < ${#ORIGINAL_ARGS[@]})) &&
        [[ "${ORIGINAL_ARGS[$((arg_i + 1))]}" != --* ]]; then
        RESTORE_URL="${ORIGINAL_ARGS[$((arg_i + 1))]}"
      fi
      ;;
  esac
done

if [[ -n "$REQUESTED_MODE" ]]; then
  MODE_PICK="$REQUESTED_MODE"
elif [[ -t 0 ]]; then
  show_banner
  echo "请选择功能："
  echo " 1) 备份容器并传输"
  echo " 2) 下载备份并恢复"
  read -rp "请输入序号 [回车=1]：" MODE_PICK || true
  MODE_PICK="${MODE_PICK:-1}"
else
  MODE_PICK=1
fi

case "$MODE_PICK" in
  1) : ;;
  2)
    restore_main "$RESTORE_URL"
    exit 0
    ;;
  *)
    RED "[ERR] 无效选择：${MODE_PICK}"
    exit 1
    ;;
esac

#####################################
# 依赖检测 / 安装
#####################################
PKGMGR="$(pm_detect)"

case "$PKGMGR" in
  apt)
    need_bin curl curl
    need_bin jq jq
    try_optional_bin python3 python3
    need_bin tar tar
    need_bin gzip gzip
    need_bin docker docker.io
    ;;
  yum | dnf)
    need_bin curl curl
    need_bin jq jq
    try_optional_bin python3 python3
    need_bin tar tar
    need_bin gzip gzip
    if ! command -v docker >/dev/null 2>&1; then
      pm_install "$PKGMGR" docker || pm_install "$PKGMGR" docker-ce || true
    fi
    ;;
  zypper)
    need_bin curl curl
    need_bin jq jq
    try_optional_bin python3 python3
    need_bin tar tar
    need_bin gzip gzip
    need_bin docker docker
    ;;
  apk)
    need_bin curl curl
    need_bin jq jq
    try_optional_bin python3 python3
    need_bin tar tar
    need_bin gzip gzip
    need_bin docker docker
    ;;
  none)
    for required_bin in curl jq tar gzip docker; do
      if ! command -v "$required_bin" >/dev/null 2>&1; then
        RED "[ERR] 缺少命令：$required_bin，且未检测到受支持的包管理器，请手动安装。"
        exit 1
      fi
    done
    ;;
esac
ensure_docker_running

#####################################
# 参数解析
#####################################
NO_STOP=0
INCLUDE_LIST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup) shift ;;
    --no-stop)
      NO_STOP=1
      shift
      ;;
    --include=*)
      INCLUDE_LIST="${1#*=}"
      shift
      ;;
    --include)
      shift
      INCLUDE_LIST="${1:-}"
      [[ $# -gt 0 ]] && shift || true
      ;;
    -h | --help)
      show_help
      exit 0
      ;;
    *)
      RED "[ERR] 未知参数：$1"
      exit 1
      ;;
  esac
done

#####################################
# Bundle 路径与 ID
#####################################
DEFAULT_PORT="${PORT:-8080}"
PORT="$(pick_free_port "$DEFAULT_PORT")"
WORKDIR="$(pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
RID="$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 10)"
BUNDLE_ROOT="${WORKDIR}/bundle"
BUNDLE="${BUNDLE_ROOT}/${RID}"
mkdir -p "${BUNDLE}"/{runs,volumes,binds,compose,meta,networks}
BLUE "[INFO] Bundle 目录：${BUNDLE}"

#####################################
# 并发锁：防止同机同时运行两个实例互相干扰
#####################################
LOCKFILE="${WORKDIR}/.docker_migrate.lock"
LOCK_METHOD="mkdir"
LOCKDIR="${LOCKFILE}.d"
if command -v flock >/dev/null 2>&1; then
  LOCK_METHOD="flock"
  exec 200>"$LOCKFILE"
  if ! flock -n 200 2>/dev/null; then
    RED "[ERR] 检测到另一个 docker_migrate 实例正在运行。"
    exit 1
  fi
elif ! mkdir "$LOCKDIR" 2>/dev/null; then
  RED "[ERR] 检测到另一个 docker_migrate 实例正在运行。"
  RED "[ERR] 若确认没有实例运行，可删除：$LOCKDIR"
  exit 1
fi

SHPID=""
CLEANUP_DONE=0

cleanup_http() {
  if [[ -n "${SHPID:-}" ]]; then
    kill "${SHPID}" 2>/dev/null || true
    wait "${SHPID}" 2>/dev/null || true
  fi
}

hard_clean() {
  [[ -z "${BUNDLE:-}" ]] || rm -rf "${BUNDLE}" 2>/dev/null || true
  [[ -z "${SINGLE_TAR_PATH:-}" ]] || rm -f "${SINGLE_TAR_PATH}" 2>/dev/null || true
  [[ -z "${BUNDLE_ROOT:-}" ]] || rm -rf "${BUNDLE_ROOT}/_bb_http_serve" 2>/dev/null || true
  [[ -z "${BUNDLE_ROOT:-}" ]] || rm -f "${BUNDLE_ROOT}/nc_http_response.http" 2>/dev/null || true
}

restart_source_containers() {
  if ((${#STOPPED_ON_BACKUP[@]} == 0)); then
    return 0
  fi
  BLUE "[INFO] 恢复源服务器容器原始运行状态（共 ${#STOPPED_ON_BACKUP[@]} 个）..."
  local ok=0 fail=0 n
  for n in "${STOPPED_ON_BACKUP[@]}"; do
    printf " - starting: %s ... " "$n"
    if run_with_timeout 60 docker start "$n" >/dev/null 2>&1; then
      printf "ok\n"
      ok=$((ok + 1))
    else
      printf "fail\n"
      fail=$((fail + 1))
    fi
  done
  if ((fail > 0)); then
    RED "[ERR] 有 ${fail} 个源容器未能重启，请立即人工检查。"
    return 1
  fi
  OK "[OK] 源容器已恢复：${ok}/${#STOPPED_ON_BACKUP[@]}"
}

graceful_exit() {
  local rc="${1:-0}"
  ((CLEANUP_DONE == 0)) || return "$rc"
  CLEANUP_DONE=1
  trap - EXIT INT TERM HUP
  cleanup_http
  if ! restart_source_containers; then
    ((rc != 0)) || rc=1
  fi
  hard_clean
  if [[ "$LOCK_METHOD" == "flock" ]]; then
    flock -u 200 2>/dev/null || true
  else
    rmdir "$LOCKDIR" 2>/dev/null || true
  fi
  rm -f "${LOCKFILE}" 2>/dev/null || true
  exit "$rc"
}

# 从获得锁开始，任何正常退出、错误或信号都会恢复源容器并清理临时包。
trap 'graceful_exit $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

#####################################
# 容器选择（支持 compose 分组）
#####################################
if [[ -n "$INCLUDE_LIST" ]]; then
  mapfile -t ALL_IDS < <(docker ps -a --format '{{.ID}}')
  ((${#ALL_IDS[@]})) || {
    RED "[ERR] 没有任何容器（运行中或已停止）"
    exit 1
  }
  IFS=',' read -r -a NAMES <<<"$INCLUDE_LIST"
  for n in "${NAMES[@]}"; do
    n="$(echo "$n" | xargs)"
    [[ -z "$n" ]] && continue
    # 精确匹配容器名：Docker --filter name= 是子字符串匹配，即使带 ^$ 也不做正则锚定。
    # 改用先列出所有容器名，再 grep 做精确字符串匹配，避免误匹配到包含元字符的容器名。
    id=""
    while IFS= read -r cid; do
      id="$cid"
      break
    done < <(docker ps -a --format '{{.ID}}\t{{.Names}}' | awk -F'\t' -v name="$n" '$2 == name {print $1}')
    if [[ -n "$id" ]]; then
      IDS+=("$id")
    else
      YEL "[WARN] 未找到容器：$n"
    fi
  done
  ((${#IDS[@]})) || {
    RED "[ERR] --include 未匹配到任何容器"
    exit 1
  }
else
  mapfile -t PS_LINES < <(docker ps -a --format '{{.ID}} {{.Names}}')
  ((${#PS_LINES[@]})) || {
    RED "[ERR] 没有任何容器（运行中或已停止）"
    exit 1
  }

  declare -a STANDALONE_IDS=()
  declare -a STANDALONE_NAMES=()
  declare -A NAME_OF_ID=()
  declare -A GROUP_IDS=()
  declare -A GROUP_LABELS=()
  declare -A GROUP_SEEN=()
  declare -a GROUP_KEYS=()
  declare -a PANEL_CONTAINERS=()
  declare -A PANEL_WARN_OF=()

  for line in "${PS_LINES[@]}"; do
    id="${line%% *}"
    cname="${line#* }"
    [[ -z "$cname" || "$cname" == "$id" ]] && cname="$id"
    NAME_OF_ID["$id"]="$cname"

    j="$(docker inspect "$id")"
    proj=$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' <<<"$j")
    wdir=$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // empty' <<<"$j")

    # 面板管理容器检测：btpanel/baota/1Panel 自身 — 标记警告
    panel_warn=""
    img_name="$(jq -r '.[0].Config.Image // ""' <<<"$j")"
    case "$img_name" in
      *btpanel* | *baota* | *1panel* | *1Panel*)
        PANEL_CONTAINERS+=("$id")
        panel_warn=" [⚡ 面板管理容器，迁移可能导致管理界面异常]"
        ;;
    esac
    # 检测挂载了面板关键路径的容器
    mounts_json="$(jq -r '.[0].Mounts[]?.Source // empty' <<<"$j" 2>/dev/null || true)"
    case "$mounts_json" in
      *"/www/server/panel/"* | *"/opt/1panel/"*)
        if [[ -z "$panel_warn" ]]; then
          PANEL_CONTAINERS+=("$id")
          panel_warn=" [⚡ 挂载了面板关键路径，请确认是否为管理容器]"
        fi
        ;;
    esac
    PANEL_WARN_OF["$id"]="$panel_warn"
    # 兼容 docker-compose v1（无 working_dir label）：将 v1 的 project 容器也归入 compose 组。
    # v1 缺少 working_dir 时，使用 compose config_files 中第一个文件的父目录作为 wdir。
    if [[ -z "$wdir" && -n "$proj" ]]; then
      cfgs_raw=$(jq -r '.[0].Config.Labels["com.docker.compose.project.config_files"] // empty' <<<"$j")
      if [[ -n "$cfgs_raw" ]]; then
        IFS=':' read -r -a cfgs_arr <<<"$cfgs_raw"
        for cfg in "${cfgs_arr[@]}"; do
          cfg="${cfg#./}"
          if [[ -n "$cfg" ]]; then
            d="$(dirname "$cfg")"
            if [[ "$cfg" == /* ]]; then wdir="$d"; else wdir="${PWD}/${d}"; fi
            break
          fi
        done
      fi
    fi
    if [[ -n "$proj" && -n "$wdir" ]]; then
      key="${proj}|${wdir}"
      if [[ -z "${GROUP_SEEN[$key]:-}" ]]; then
        GROUP_SEEN["$key"]=1
        GROUP_IDS["$key"]="$id"
        GROUP_LABELS["$key"]="$cname"
        GROUP_KEYS+=("$key")
      else
        GROUP_IDS["$key"]="${GROUP_IDS[$key]} $id"
        GROUP_LABELS["$key"]="${GROUP_LABELS[$key]} $cname"
      fi
    else
      STANDALONE_IDS+=("$id")
      STANDALONE_NAMES+=("$cname")
    fi
  done

  # 关键修复：只有一个容器的 compose 项目归类为“独立容器”。
  # 这样 danmu_api 这类单容器项目会走 docker run 恢复路径，从 inspect 还原 -p 端口。
  if ((${#GROUP_KEYS[@]})); then
    declare -a TRUE_GROUP_KEYS=()
    for key in "${GROUP_KEYS[@]}"; do
      cnt=0
      for cid in ${GROUP_IDS[$key]}; do cnt=$((cnt + 1)); done
      if ((cnt > 1)); then
        TRUE_GROUP_KEYS+=("$key")
      else
        for cid in ${GROUP_IDS[$key]}; do
          STANDALONE_IDS+=("$cid")
          STANDALONE_NAMES+=("${NAME_OF_ID[$cid]}")
        done
      fi
    done
    GROUP_KEYS=("${TRUE_GROUP_KEYS[@]}")
  fi

  declare -a MENU_KIND=()
  declare -a MENU_VAL=()
  idx=0
  if ((${#STANDALONE_IDS[@]})); then
    BLUE "独立 docker 容器："
    for i in "${!STANDALONE_IDS[@]}"; do
      idx=$((idx + 1))
      id="${STANDALONE_IDS[$i]}"
      name="${STANDALONE_NAMES[$i]}"
      pw="${PANEL_WARN_OF[$id]:-}"
      printf " %2d) %s%s\n" "$idx" "$name" "$pw"
      MENU_KIND[$idx]="single"
      MENU_VAL[$idx]="$id"
    done
    echo ""
  fi

  if ((${#PANEL_CONTAINERS[@]})); then
    YEL " ⚡ 提示：检测到面板管理容器（btpanel/1Panel/baota），迁移可能导致面板界面异常。"
    YEL "    建议仅迁移业务容器，排除面板管理容器。"
    echo ""
  fi

  if ((${#GROUP_KEYS[@]})); then
    BLUE "docker compose 容器组："
    for key in "${GROUP_KEYS[@]}"; do
      idx=$((idx + 1))
      label_display=""
      for cname in ${GROUP_LABELS[$key]}; do label_display+="〖${cname}〗"; done
      printf " %2d) %s\n" "$idx" "$label_display"
      MENU_KIND[$idx]="compose"
      MENU_VAL[$idx]="$key"
    done
    echo ""
  fi

  if ((idx == 0)); then
    RED "[ERR] 没有运行中的容器"
    exit 1
  fi

  read -rp "请输入要迁移的序号 [回车=全部 / 逗号分隔，如 1,3]： " PICK
  if [[ -z "$PICK" ]]; then
    IDS=("${STANDALONE_IDS[@]}")
    for key in "${GROUP_KEYS[@]}"; do
      for cid in ${GROUP_IDS[$key]}; do IDS+=("$cid"); done
    done
  else
    IFS=',' read -r -a INDEX_LIST <<<"$PICK"
    declare -A SEEN_ID=()
    for t in "${INDEX_LIST[@]}"; do
      t="$(echo "$t" | xargs)"
      [[ -z "$t" ]] && continue
      if ! [[ "$t" =~ ^[0-9]+$ ]]; then
        YEL "[WARN] 非法序号：$t"
        continue
      fi
      num="$t"
      if ((num < 1 || num > idx)); then
        YEL "[WARN] 序号越界：$t"
        continue
      fi
      kind="${MENU_KIND[$num]}"
      val="${MENU_VAL[$num]}"
      if [[ "$kind" == "single" ]]; then
        cid="$val"
        if [[ -z "${SEEN_ID[$cid]:-}" ]]; then
          SEEN_ID["$cid"]=1
          IDS+=("$cid")
        fi
      elif [[ "$kind" == "compose" ]]; then
        for cid in ${GROUP_IDS[$val]}; do
          if [[ -z "${SEEN_ID[$cid]:-}" ]]; then
            SEEN_ID["$cid"]=1
            IDS+=("$cid")
          fi
        done
      fi
    done
    ((${#IDS[@]})) || {
      RED "[ERR] 未选择任何容器"
      exit 1
    }
  fi
fi

#####################################
# 元数据采集
#####################################
BLUE "[INFO] 采集容器元数据 ..."
declare -A IMGSET=()
declare -A NETWORKS=()
declare -A CONTAINER_NAME=()
declare -A CONTAINER_IS_COMPOSE=()
declare -A COMPOSE_GROUP=()
declare -A COMPOSE_CFGS=()
declare -A SELECTED_COMPOSE_COUNT=()

# 关键修复：重新按最终选择的容器统计 compose 分组数量，避免菜单阶段归类为单容器，元数据阶段又被重新归为 compose。
for id in "${IDS[@]}"; do
  jtmp="$(docker inspect "$id")"
  projtmp=$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' <<<"$jtmp")
  wdirtmp=$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // empty' <<<"$jtmp")
  # 兼容 v1：缺少 working_dir 时从 config_files 推断
  if [[ -z "$wdirtmp" && -n "$projtmp" ]]; then
    cfgstmp=$(jq -r '.[0].Config.Labels["com.docker.compose.project.config_files"] // empty' <<<"$jtmp")
    if [[ -n "$cfgstmp" ]]; then
      IFS=':' read -r -a cfgs_tmp <<<"$cfgstmp"
      for ct in "${cfgs_tmp[@]}"; do
        ct="${ct#./}"
        if [[ -n "$ct" ]]; then
          if [[ "$ct" == /* ]]; then wdirtmp="$(dirname "$ct")"; else wdirtmp="${PWD}/$(dirname "$ct")"; fi
          break
        fi
      done
    fi
  fi
  if [[ -n "$projtmp" && -n "$wdirtmp" ]]; then
    keytmp="${projtmp}|${wdirtmp}"
    SELECTED_COMPOSE_COUNT["$keytmp"]=$((${SELECTED_COMPOSE_COUNT["$keytmp"]:-0} + 1))
  fi
done

for id in "${IDS[@]}"; do
  j="$(docker inspect "$id")"
  name=$(jq -r '.[0].Name | ltrimstr("/")' <<<"$j")
  img=$(jq -r '.[0].Config.Image' <<<"$j")
  CONTAINER_NAME["$id"]="$name"
  IMGSET["$img"]=1

  proj=$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' <<<"$j")
  wdir=$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // empty' <<<"$j")
  cfgs=$(jq -r '.[0].Config.Labels["com.docker.compose.project.config_files"] // empty' <<<"$j")
  # 兼容 v1：缺少 working_dir 时从 config_files 推断
  if [[ -z "$wdir" && -n "$proj" ]]; then
    if [[ -n "$cfgs" ]]; then
      IFS=':' read -r -a cfgs_arr <<<"$cfgs"
      for cg in "${cfgs_arr[@]}"; do
        cg="${cg#./}"
        if [[ -n "$cg" ]]; then
          if [[ "$cg" == /* ]]; then wdir="$(dirname "$cg")"; else wdir="${PWD}/$(dirname "$cg")"; fi
          break
        fi
      done
    fi
  fi
  key=""
  if [[ -n "$proj" && -n "$wdir" ]]; then
    key="${proj}|${wdir}"
  fi

  if [[ -n "$key" && "${SELECTED_COMPOSE_COUNT[$key]:-0}" -gt 1 ]]; then
    COMPOSE_GROUP["$key"]=1
    [[ -n "$cfgs" ]] && COMPOSE_CFGS["$key"]="$cfgs"
    CONTAINER_IS_COMPOSE["$id"]=1
  else
    CONTAINER_IS_COMPOSE["$id"]=0
    mapfile -t nets < <(jq -r '.[0].NetworkSettings.Networks | keys[]?' <<<"$j" || true)
    for n in "${nets[@]}"; do
      case "$n" in bridge | host | none) : ;; *) NETWORKS["$n"]=1 ;; esac
    done
  fi

  echo "$j" >"${BUNDLE}/meta/${name}.inspect.json"
done

# 保存独立容器使用的自定义网络定义，而不只保存网络名称。
for network_name in "${!NETWORKS[@]}"; do
  network_id="$(printf '%s' "$network_name" | cksum | awk '{print $1}')"
  if ! docker network inspect "$network_name" | jq '.[0] | {
      name: .Name,
      driver: (.Driver // "bridge"),
      internal: (.Internal // false),
      attachable: (.Attachable // false),
      enable_ipv6: (.EnableIPv6 // false),
      options: (.Options // {}),
      labels: (.Labels // {}),
      ipam: {
        driver: (.IPAM.Driver // "default"),
        options: (.IPAM.Options // {}),
        config: (.IPAM.Config // [])
      }
    }' >"${BUNDLE}/networks/${network_id}.json"; then
    BACKUP_FAILURES+=("网络元数据采集失败：$network_name")
  fi
done

#####################################
# 打包 Compose 配置（绝对/相对路径）
#####################################
if ((${#COMPOSE_GROUP[@]})); then
  BLUE "[INFO] 打包 docker compose 项目配置 ..."
  for key in "${!COMPOSE_GROUP[@]}"; do
    proj="${key%%|*}"
    wdir="${key#*|}"
    dest="${BUNDLE}/compose/${proj}"
    mkdir -p "$dest"
    cfgs="${COMPOSE_CFGS[$key]:-}"
    declare -a CFG_SOURCE_ARGS=()

    if [[ -n "$cfgs" ]]; then
      IFS=':' read -r -a CFG_ARR <<<"$cfgs"
      for cfg in "${CFG_ARR[@]}"; do
        cfg="${cfg#./}"
        [[ -z "$cfg" ]] && continue
        src=""
        if [[ "$cfg" == /* ]]; then
          src="$cfg"
        elif [[ -n "$wdir" ]]; then
          src="${wdir}/${cfg}"
        else
          src="$cfg"
        fi
        if [[ -f "$src" ]]; then
          cp -a "$src" "$dest/"
          CFG_SOURCE_ARGS+=(-f "$src")
        else
          BACKUP_FAILURES+=("Compose 配置文件缺失：$src")
        fi
      done
    fi

    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml .env docker-compose.override.yml compose.override.yaml; do
      if [[ -n "$wdir" && -f "${wdir}/${f}" ]]; then
        cp -a "${wdir}/${f}" "$dest/" 2>/dev/null || true
      fi
    done

    # 使用全部 -f 文件生成规范配置，合并覆盖文件并解析 env_file。
    if ((${#CFG_SOURCE_ARGS[@]} > 0)); then
      resolved_tmp="${dest}/.resolved_config.yml.tmp"
      if docker compose version >/dev/null 2>&1 &&
        { docker compose --project-directory "$wdir" "${CFG_SOURCE_ARGS[@]}" config --no-path-resolution >"$resolved_tmp" 2>/dev/null ||
          docker compose --project-directory "$wdir" "${CFG_SOURCE_ARGS[@]}" config >"$resolved_tmp" 2>/dev/null; }; then
        mv "$resolved_tmp" "${dest}/_resolved_config.yml"
      elif command -v docker-compose >/dev/null 2>&1 &&
        (cd "$wdir" && docker-compose "${CFG_SOURCE_ARGS[@]}" config) >"$resolved_tmp" 2>/dev/null; then
        mv "$resolved_tmp" "${dest}/_resolved_config.yml"
      else
        rm -f "$resolved_tmp"
        YEL "[WARN] 无法生成解析后的 Compose 配置，将使用原始配置文件。"
      fi
    fi

    # 原始配置回退：收集常见 env_file 语法并保留相对目录结构。
    for cfg in "$dest"/*.yml "$dest"/*.yaml; do
      [[ -f "$cfg" ]] || continue
      while IFS= read -r ef; do
        ef="${ef#./}"
        [[ -z "$ef" ]] && continue
        if [[ "$ef" == /* ]]; then
          if [[ -f "$ef" ]]; then
            env_id="$(printf '%s' "$ef" | cksum | awk '{print $1}')"
            stored="_env_files/${env_id}_$(basename "$ef")"
            mkdir -p "${dest}/$(dirname "$stored")"
            cp -a "$ef" "${dest}/${stored}"
            jq -cn --arg source "$ef" --arg stored "$stored" \
              '{source:$source,stored:$stored}' >>"${dest}/.env_file_map.jsonl"
          fi
        elif [[ -n "$wdir" && -f "${wdir}/${ef}" ]]; then
          mkdir -p "${dest}/$(dirname "$ef")"
          cp -a "${wdir}/${ef}" "${dest}/${ef}"
        fi
      done < <(compose_env_file_refs "$cfg" || true)
    done
  done
fi

#####################################
# 停机窗口（可选）
#####################################
if ((NO_STOP == 1)); then
  YEL "[WARN] 使用 --no-stop：不停机备份，数据可能不一致（尤其数据库类容器）。"
else
  read -rp "是否现在停机以确保一致性备份？[Y/n] " STOPNOW
  STOPNOW=${STOPNOW:-Y}
  if [[ "$STOPNOW" =~ ^[Yy]$ ]]; then
    total_count=${#IDS[@]}
    idx=0
    for id in "${IDS[@]}"; do
      idx=$((idx + 1))
      n="${CONTAINER_NAME[$id]}"
      was_running="$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null || echo false)"
      if [[ "$was_running" != "true" ]]; then
        printf "[停机] (%d/%d) %s ... already stopped\n" "$idx" "$total_count" "$n"
        continue
      fi
      printf "[停机] (%d/%d) %s ..." "$idx" "$total_count" "$n"
      if docker stop "$n" >/dev/null 2>&1; then
        STOPPED_ON_BACKUP+=("$n")
        printf " ok\n"
      else
        printf " fail\n"
        BACKUP_FAILURES+=("无法停止正在运行的容器：$n")
      fi
    done
    if ((${#BACKUP_FAILURES[@]} > 0)); then
      RED "[ERR] 停机阶段失败，已取消备份以避免不一致数据。"
      exit 1
    fi
  else
    YEL "[WARN] 你选择了不停机备份。"
  fi
fi

#####################################
# 备份卷与绑定目录
#####################################
BLUE "[INFO] 备份卷与绑定目录 ..."
BLUE "[INFO] 预拉取 alpine:3.20 镜像（用于卷操作）..."
docker pull alpine:3.20 >/dev/null 2>&1 || YEL "[WARN] 无法拉取 alpine:3.20，卷操作可能失败"
declare -a MAN_VOL=()
declare -a MAN_BIND=()
declare -A BACKED_VOLUMES=()
declare -A BACKED_BINDS=()
vol_count=0
bind_count=0
for id in "${IDS[@]}"; do
  n="${CONTAINER_NAME[$id]}"
  j="$(cat "${BUNDLE}/meta/${n}.inspect.json")"
  vc=$(jq -r '.[0].Mounts[]? | select(.Type=="volume") | 1' <<<"$j" | wc -l || echo 0)
  bc=$(jq -r '.[0].Mounts[]? | select(.Type=="bind") | 1' <<<"$j" | wc -l || echo 0)
  vol_count=$((vol_count + vc))
  bind_count=$((bind_count + bc))
done

v_idx=0
b_idx=0
for id in "${IDS[@]}"; do
  n="${CONTAINER_NAME[$id]}"
  j="$(cat "${BUNDLE}/meta/${n}.inspect.json")"
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    t=$(jq -r '.Type' <<<"$m")
    dest=$(jq -r '.Destination' <<<"$m")
    case "$t" in
      volume)
        v_idx=$((v_idx + 1))
        vname=$(jq -r '.Name' <<<"$m")
        [[ -z "${BACKED_VOLUMES[$vname]:-}" ]] || continue
        BACKED_VOLUMES["$vname"]=1
        # 捕获卷的 driver 和 options，用于恢复时精确还原
        v_driver="$(docker volume inspect "$vname" -f '{{.Driver}}' 2>/dev/null || echo local)"
        v_opts_json="$(docker volume inspect "$vname" -f '{{json .Options}}' 2>/dev/null || echo '{}')"
        printf " [VOL] (%d/%d) %s :: %s -> %s\n" "$v_idx" "$vol_count" "$n" "$vname" "$dest"
        mkdir -p "${BUNDLE}/volumes"
        out="${BUNDLE}/volumes/vol_${vname}.tgz"
        docker run --rm \
          -v "${vname}:/from:ro" \
          -v "${BUNDLE}/volumes:/to" \
          alpine:3.20 sh -c "cd /from && tar -czf /to/$(basename "$out") ." || {
          YEL " [WARN] 打包卷失败：$vname"
          BACKUP_FAILURES+=("命名卷备份失败：$vname")
          continue
        }
        MAN_VOL+=("$(jq -cn --arg name "$vname" --arg dest "$dest" --arg driver "$v_driver" --argjson opts "$v_opts_json" '{name:$name,dest:$dest,driver:$driver,opts:$opts}')")
        ;;
      bind)
        src=$(jq -r '.Source' <<<"$m")
        # 过滤 Docker socket 等 Unix socket 文件，防止恢复时覆盖目标服务器 daemon
        case "$src" in
          */docker.sock | */podman.sock | */containerd.sock)
            YEL " [SKIP] 跳过 Docker socket bind mount：$src"
            continue
            ;;
        esac
        b_idx=$((b_idx + 1))
        [[ -z "${BACKED_BINDS[$src]:-}" ]] || continue
        BACKED_BINDS["$src"]=1
        esc="$(basename "$src" | tr -c 'A-Za-z0-9_.-' '_')"
        src_id="$(printf '%s' "$src" | cksum | awk '{print $1}')"
        out="${BUNDLE}/binds/bind_${esc}_${src_id}.tgz"
        printf " [BIND] (%d/%d) %s :: %s -> %s\n" "$b_idx" "$bind_count" "$n" "$src" "$dest"
        mkdir -p "${BUNDLE}/binds"
        if ! tar -C / -czf "$out" "${src#/}" 2>/dev/null; then
          YEL " [WARN] 跳过不可读路径：$src"
          BACKUP_FAILURES+=("绑定目录备份失败：$src")
          continue
        fi
        MAN_BIND+=("$(jq -cn --arg host "$src" --arg dest "$dest" --arg file "$(basename "$out")" '{host:$host,dest:$dest,file:$file}')")
        ;;
      *)
        YEL " [SKIP] 未处理的 mount 类型：$t (dest=$dest)"
        ;;
    esac
  done < <(jq -c '.[0].Mounts[]?' <<<"$j")
done

if ((${#BACKUP_FAILURES[@]} > 0)); then
  RED "[ERR] 数据备份不完整，已取消生成迁移包："
  for failure in "${BACKUP_FAILURES[@]}"; do
    RED " - $failure"
  done
  exit 1
fi

#####################################
# 生成独立容器 run 脚本
#####################################
if ((${#IDS[@]})); then
  BLUE "[INFO] 生成独立容器 run 脚本 ..."
  for id in "${IDS[@]}"; do
    if [[ "${CONTAINER_IS_COMPOSE[$id]}" == "1" ]]; then
      continue
    fi
    n="${CONTAINER_NAME[$id]}"
    run_file="${BUNDLE}/runs/${n}.sh"
    write_run_script "$n" "$run_file"
    RUNS+=("runs/$(basename "$run_file")")
  done
fi

#####################################
# 保存镜像 images.tar
#####################################
mapfile -t IMAGES < <(printf "%s\n" "${!IMGSET[@]}" | awk 'NF' | sort -u)
if ((${#IMAGES[@]})); then
  OUT_IMG="${BUNDLE}/images.tar"
  if progress_docker_save "${OUT_IMG}" docker image save "${IMAGES[@]}"; then
    OK "[OK] images.tar 已生成，大小：$(du -h "${OUT_IMG}" | awk '{print $1}')"
  else
    RED "[ERR] docker image save 失败，请检查磁盘空间或 Docker 状态。"
    rm -f "${OUT_IMG}" 2>/dev/null || true
    BACKUP_FAILURES+=("镜像归档失败")
  fi
else
  YEL "[WARN] 未收集到镜像名（可能是只用了本地 none 镜像）。"
fi

if ((${#BACKUP_FAILURES[@]} > 0)); then
  RED "[ERR] 备份未完成，不会生成可误用的迁移包。"
  exit 1
fi

#####################################
# 生成 manifest.json 与 restore.sh
#####################################
generate_manifest_and_restore() {
  declare -a MAN_PROJECTS=()
  local key
  for key in "${!COMPOSE_GROUP[@]}"; do
    local proj="${key%%|*}"
    local wdir="${key#*|}"
    local files_json="[]"
    local cfgs_json="[]"
    if [[ -d "${BUNDLE}/compose/${proj}" ]]; then
      mapfile -t FLS < <(find "${BUNDLE}/compose/${proj}" -maxdepth 1 -type f -exec basename {} \; 2>/dev/null | sort || true)
      if ((${#FLS[@]})); then
        files_json="$(json_array_from_lines "${FLS[@]}")"
      fi
    fi
    # 解析后的单文件配置优先；否则保持原始 config_files 顺序。
    local cfs="${COMPOSE_CFGS[$key]:-}"
    if [[ -f "${BUNDLE}/compose/${proj}/_resolved_config.yml" ]]; then
      cfgs_json='["_resolved_config.yml"]'
    elif [[ -n "$cfs" ]]; then
      IFS=':' read -r -a CFS_ARR <<<"$cfs"
      declare -a cfgs_abs
      cfgs_abs=()
      for c in "${CFS_ARR[@]}"; do
        c="${c#./}"
        [[ -z "$c" ]] && continue
        if [[ "$c" == /* ]]; then cfgs_abs+=("$c"); elif [[ -n "$wdir" ]]; then cfgs_abs+=("${wdir}/${c}"); else cfgs_abs+=("$c"); fi
      done
      if ((${#cfgs_abs[@]})); then
        cfgs_json="$(json_array_from_lines "${cfgs_abs[@]}")"
      fi
    fi
    MAN_PROJECTS+=("$(jq -cn --arg name "$proj" --arg working_dir "$wdir" --argjson files "$files_json" --argjson config_files "$cfgs_json" '{name:$name,working_dir:$working_dir,files:$files,config_files:$config_files}')")
  done

  local images_json nets_json projects_json vols_json binds_json runs_json
  # 使用正确的 bash 数组展开语法，避免空数组产生空字符串参数
  images_json="$(json_array_from_lines ${IMAGES[@]+"${IMAGES[@]}"})"
  runs_json="$(json_array_from_lines ${RUNS[@]+"${RUNS[@]}"})"
  mapfile -t NETWORK_FILES < <(find "${BUNDLE}/networks" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | sort || true)
  if ((${#NETWORK_FILES[@]})); then
    nets_json="$(jq -s . "${NETWORK_FILES[@]}")"
  else
    nets_json='[]'
  fi

  if ((${#MAN_PROJECTS[@]})); then
    projects_json="$(printf '%s\n' "${MAN_PROJECTS[@]}" | jq -cs .)"
  else
    projects_json='[]'
  fi
  if ((${#MAN_VOL[@]})); then
    vols_json="$(printf '%s\n' "${MAN_VOL[@]}" | jq -cs .)"
  else
    vols_json='[]'
  fi
  if ((${#MAN_BIND[@]})); then
    binds_json="$(printf '%s\n' "${MAN_BIND[@]}" | jq -cs .)"
  else
    binds_json='[]'
  fi

  jq -n \
    --arg created_at "$STAMP" \
    --arg script_version "$SCRIPT_VERSION" \
    --argjson images "$images_json" \
    --argjson networks "$nets_json" \
    --argjson projects "$projects_json" \
    --argjson volumes "$vols_json" \
    --argjson binds "$binds_json" \
    --argjson runs "$runs_json" \
    '{created_at:$created_at,script_version:$script_version,images:$images,networks:$networks,projects:$projects,volumes:$volumes,binds:$binds,runs:$runs}' \
    >"${BUNDLE}/manifest.json"

  write_bundle_restore_script "${BUNDLE}/restore.sh"

  cat >"${BUNDLE}/README.txt" <<README
Docker 迁移包
生成时间：${STAMP}

恢复方法：
1. 新服务器运行同一份 docker_migrate_perfect.sh，选择 2，然后粘贴下载链接；或
2. 手动解压本包后，在包目录执行：bash restore.sh

本版修复端口丢失问题：
- 单容器 compose 项目会以独立容器方式迁移。
- 已存在同名容器但端口绑定不一致时，恢复脚本会删除并重建容器。
README
}

generate_manifest_and_restore
BLUE "[INFO] 生成迁移包完整性校验 ..."
generate_bundle_checksums "$BUNDLE"

#####################################
# 打包成单文件 tar.gz
#####################################
BUNDLE_BASENAME="docker_migrate_${STAMP}_${RID}"
SINGLE_TAR_PATH="${BUNDLE_ROOT}/${BUNDLE_BASENAME}.tar.gz"
BLUE "[INFO] 打包一键迁移包：${SINGLE_TAR_PATH}"
(
  cd "$BUNDLE_ROOT"
  tar -czf "${BUNDLE_BASENAME}.tar.gz" "$RID"
)
OK "[OK] 一键迁移包已生成，大小：$(du -h "$SINGLE_TAR_PATH" | awk '{print $1}')"

#####################################
# HTTP 下载服务
#####################################
if [[ -t 0 ]]; then
  echo ""
  read -rp "HTTP 下载端口 [回车=${PORT}]： " IN_PORT || true
  if [[ -n "${IN_PORT:-}" ]]; then
    if [[ "$IN_PORT" =~ ^[0-9]+$ ]] && ((IN_PORT >= 1 && IN_PORT <= 65535)); then
      NEW_PORT="$(pick_free_port "$IN_PORT")"
      if [[ "$NEW_PORT" != "$IN_PORT" ]]; then
        YEL "[WARN] 端口 ${IN_PORT} 已占用，改用临近可用端口：${NEW_PORT}"
      fi
      PORT="$NEW_PORT"
    else
      YEL "[WARN] 输入端口无效，继续使用默认端口：${PORT}"
    fi
  fi
fi

SECRET_TOKEN="$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
BASE_URL="$(pick_advertise_url "$PORT")"
FINAL_URL="" # will be set below by the chosen HTTP server

BLUE "[INFO] 启动 HTTP 服务（端口 ${PORT}，仅允许路径 /${SECRET_TOKEN}/${BUNDLE_BASENAME}.tar.gz）"
SHPID=""

HTTP_LOG="${BUNDLE_ROOT}/http_server_${RID}.log"
cd "${BUNDLE_ROOT}" || exit 1

# start_http_server: multi-fallback — python3 > busybox httpd > netcat
TGZ_NAME="${BUNDLE_BASENAME}.tar.gz"
TGZ_PATH="${BUNDLE_ROOT}/${TGZ_NAME}"
TGZ_SIZE="$(stat -c%s "$TGZ_PATH" 2>/dev/null || stat -f%z "$TGZ_PATH" 2>/dev/null || echo 0)"

if command -v python3 >/dev/null 2>&1; then
  # --- Fallback 1: Python3 HTTP server (best — supports secret token + proper headers) ---
  YEL "[INFO] 使用 Python3 HTTP 服务 ..."
  python3 - "$PORT" "$SECRET_TOKEN" "$BUNDLE_BASENAME" >"${HTTP_LOG}" 2>&1 <<'PY' &
import http.server
import os
from socketserver import ThreadingTCPServer
import sys

port = int(sys.argv[1])
secret = sys.argv[2]
bundle_basename = sys.argv[3]
fname = bundle_basename + ".tar.gz"
allowed_path = "/" + secret + "/" + fname
root = os.getcwd()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0].split("#", 1)[0]
        if path != allowed_path:
            self.send_response(404)
            self.end_headers()
            return
        fpath = os.path.join(root, fname)
        try:
            st = os.stat(fpath)
        except FileNotFoundError:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Length", str(st.st_size))
        self.send_header("Content-Disposition", 'attachment; filename="' + fname + '"')
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        with open(fpath, "rb") as f:
            while True:
                chunk = f.read(64 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)

    def log_message(self, format, *args):
        return

from socketserver import ThreadingTCPServer

with ThreadingTCPServer(("", port), Handler) as httpd:
    httpd.serve_forever()
PY
  SHPID=$!
  FINAL_URL="${BASE_URL}/${SECRET_TOKEN}/${BUNDLE_BASENAME}.tar.gz"

elif command -v busybox >/dev/null 2>&1; then
  # --- Fallback 2: Busybox httpd (widespread on minimal/embedded systems) ---
  # 通过子目录隔离：创建一个符号链接，只暴露 tar.gz 文件而不暴露整个 bundle_root
  YEL "[INFO] 使用 Busybox HTTP 服务 ..."
  BUSYBOX_WEB="${BUNDLE_ROOT}/_bb_http_serve"
  mkdir -p "$BUSYBOX_WEB/$SECRET_TOKEN"
  printf 'Not found\n' >"$BUSYBOX_WEB/index.html"
  ln -sf "$TGZ_PATH" "$BUSYBOX_WEB/$SECRET_TOKEN/$TGZ_NAME"
  busybox httpd -f -p "$PORT" -h "$BUSYBOX_WEB" >"${HTTP_LOG}" 2>&1 &
  SHPID=$!
  FINAL_URL="${BASE_URL}/${SECRET_TOKEN}/${TGZ_NAME}"

elif command -v nc >/dev/null 2>&1; then
  # --- Fallback 3: Netcat one-shot HTTP (virtually universal) ---
  YEL "[INFO] 使用 Netcat HTTP 服务 ..."
  # Build a raw HTTP response; serve the same file for any path
  cat >"${BUNDLE_ROOT}/nc_http_response.http" <<NCEOF
HTTP/1.1 200 OK
Content-Type: application/gzip
Content-Length: ${TGZ_SIZE}
Content-Disposition: attachment; filename="${TGZ_NAME}"
Cache-Control: no-store
X-Content-Type-Options: nosniff
Connection: close

NCEOF
  (
    while true; do
      # Ncat (modern nmap) uses --send-only; traditional nc uses -N or relies on client closing
      (
        cat "${BUNDLE_ROOT}/nc_http_response.http"
        cat "$TGZ_PATH"
      ) | nc -l -p "$PORT" -q 0 2>/dev/null ||
        (
          cat "${BUNDLE_ROOT}/nc_http_response.http"
          cat "$TGZ_PATH"
        ) | nc -l -p "$PORT" 2>/dev/null || true
    done
  ) >"${HTTP_LOG}" 2>&1 &
  SHPID=$!
  # nc fallback: no secret token — URL is just http://host:port/<file>
  FINAL_URL="${BASE_URL}/${TGZ_NAME}"

else
  RED "[ERR] 未找到可用的 HTTP 服务方式（python3 / busybox httpd / nc），请手动安装其一后重试。"
  exit 1
fi

cd "$WORKDIR"
sleep 1

if ! kill -0 "$SHPID" 2>/dev/null; then
  RED "[ERR] HTTP 服务启动失败，请检查端口 ${PORT}、防火墙或运行日志：${HTTP_LOG}"
  if [[ -f "${HTTP_LOG}" ]]; then tail -n 20 "${HTTP_LOG}" || true; fi
  graceful_exit 1
fi

OK "[OK] 一键迁移包下载链接：${FINAL_URL}"
YEL "[WARN] HTTP 为明文传输，请仅在可信网络使用。"
YEL "[INFO] HTTP 服务日志：${HTTP_LOG}"

if [[ -t 0 ]]; then
  read -rp $' 按回车键停止 HTTP 并退出（将自动重启停机容器并清理产物）...' _
  graceful_exit 0
else
  YEL "[INFO] 当前为非交互模式，HTTP 服务将保持运行；请在下载完成后手动结束本脚本。"
  wait "$SHPID" || true
  graceful_exit 0
fi
