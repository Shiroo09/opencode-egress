#!/usr/bin/env bash
# Point OpenCode's model traffic at a tinyproxy running on a VPS you own.
# Works on Windows (Git Bash or MSYS2), Linux, and macOS. Requires bash,
# openssh, and curl. The proxy listens on loopback at both ends. The SSH
# tunnel is the only path between them.
set -euo pipefail

PORT="${PORT:-8888}"
REMOTE_PORT="${REMOTE_PORT:-$PORT}"
SSH_HOST="${SSH_HOST:-}"
NO_PROXY_EXTRA="${NO_PROXY_EXTRA:-}"

# Router + pool settings. OpenCode always points at ROUTER_PORT; each VPS
# tunnel listens on BASE_PORT+i. CONTROL_PORT serves the router's loopback
# API (status, next, exhausted) used by `next`/`use` and the OpenCode plugin.
ROUTER_PORT="${ROUTER_PORT:-8888}"
CONTROL_PORT="${CONTROL_PORT:-8899}"
BASE_PORT="${BASE_PORT:-8891}"
EGRESS_HOSTS="${EGRESS_HOSTS:-}"
EGRESS_INCLUDE_DIRECT="${EGRESS_INCLUDE_DIRECT:-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_JS="${ROUTER_JS:-$SCRIPT_DIR/egress-router.mjs}"
CONFIG_DIR="${EGRESS_CONFIG_DIR:-$HOME/.config/opencode-egress}"
HOSTS_FILE="${EGRESS_HOSTS_FILE:-$CONFIG_DIR/hosts}"
STATE_FILE="${EGRESS_STATE_FILE:-$CONFIG_DIR/router-state.json}"
ROUTER_PID_FILE="${EGRESS_ROUTER_PID:-$CONFIG_DIR/router.pid}"
ROUTER_LOG="${EGRESS_ROUTER_LOG:-$CONFIG_DIR/router.log}"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

usage() {
  cat <<EOF
Point OpenCode's model traffic at a tinyproxy on a VPS you own.
Runs on Windows (Git Bash or MSYS2), Linux, and macOS.
EOF
  cat <<EOF

usage: $(basename "$0") <command> [ssh-host]

commands:
  tunnel-up     open the local tunnel to the VPS proxy (legacy single mode)
  tunnel-down   close it
  tunnel-up-all open one tunnel per configured VPS (pool mode)
  tunnel-down-all close all pool tunnels
  router-up     start the local rotating router on 127.0.0.1:ROUTER_PORT
  router-down   stop it
  on            send OpenCode model traffic through the router
  off           remove that setting
  next          rotate to the next usable egress now
  use           pin one egress: use <name> (name, or "direct")
  status        show the tunnel, both egress IPs, and the VPS log
  status-all    show router, every pool egress, and health
  setup-hint    print the command that installs tinyproxy on the VPS

ssh-host is a Host alias from your SSH config that logs in with a key.
Set SSH_HOST instead of passing it. PORT and NO_PROXY_EXTRA override defaults.

examples:
  $(basename "$0") tunnel-up my-vps
  NO_PROXY_EXTRA=192.0.2.10 $(basename "$0") on my-vps
  $(basename "$0") status my-vps
  $(basename "$0") off
EOF
}

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed"; }

host_arg() {
  if [[ -n "${1:-}" ]]; then
    SSH_HOST="$1"
  fi
  [[ -n "$SSH_HOST" ]] || die "pass the SSH config alias, or set SSH_HOST"
}

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
  Darwin) PLATFORM="mac" ;;
  Linux) PLATFORM="linux" ;;
  *) die "unsupported system: $(uname -s)" ;;
esac

# OpenSSH on Windows prints a different process title than the PID file can
# match, so listeners are tracked by the local port they bind.
listeners() {
  local port="${1:-$PORT}"
  if [[ "$PLATFORM" == "windows" ]]; then
    powershell.exe -NoProfile -Command \
      "Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess" \
      | tr -d '\r'
  else
    if command -v lsof >/dev/null 2>&1; then
      lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true
    elif command -v ss >/dev/null 2>&1; then
      ss -ltnp "sport = :$port" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p'
    else
      die "need lsof or ss to see what is listening"
    fi
  fi
}

# Pool hosts, one SSH alias per line. Precedence: CLI args, EGRESS_HOSTS
# (comma or space separated), hosts file, single SSH_HOST fallback.
hosts_list() {
  local given=()
  local a
  for a in "$@"; do
    [[ -n "$a" ]] && given+=("$a")
  done
  if [[ ${#given[@]} -gt 0 ]]; then
    printf '%s\n' "${given[@]}"
    return 0
  fi
  if [[ -n "$EGRESS_HOSTS" ]]; then
    printf '%s\n' "$EGRESS_HOSTS" | tr ', ' '\n\n' | sed '/^[[:space:]]*$/d'
    return 0
  fi
  if [[ -f "$HOSTS_FILE" ]]; then
    sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//;s/[[:space:]]*$//' "$HOSTS_FILE"
    return 0
  fi
  if [[ -n "$SSH_HOST" ]]; then
    printf '%s\n' "$SSH_HOST"
    return 0
  fi
  die "no VPS configured: pass alias(es), set EGRESS_HOSTS, or create $HOSTS_FILE"
}

port_for_index() {
  printf '%s' "$((BASE_PORT + $1))"
}

upstream_args() {
  local i=0 host port
  while IFS= read -r host; do
    [[ -z "$host" ]] && continue
    port=$(port_for_index "$i")
    printf ' --upstream %s=127.0.0.1:%s' "$host" "$port"
    i=$((i + 1))
  done < <(hosts_list "$@")
  if [[ "$EGRESS_INCLUDE_DIRECT" == "1" ]]; then
    printf ' --upstream direct=direct'
  fi
}

open_tunnel() {
  local host="$1" local_port="$2"
  need ssh
  local owner
  owner=$(listeners "$local_port" | head -n 1 || true)
  if [[ -n "$owner" ]]; then
    printf 'tunnel already listening on 127.0.0.1:%s (pid %s)\n' "$local_port" "$owner"
    return 0
  fi
  # shellcheck disable=SC2029
  ssh -f -N \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -L "127.0.0.1:${local_port}:127.0.0.1:${REMOTE_PORT}" \
    "$host"
  local tries=0
  owner=""
  while [[ $tries -lt 20 ]]; do
    owner=$(listeners "$local_port" | head -n 1 || true)
    [[ -n "$owner" ]] && break
    sleep 0.25
    tries=$((tries + 1))
  done
  [[ -n "$owner" ]] || die "tunnel did not open for $host. try: ssh -o BatchMode=yes $host echo ok"
  printf 'tunnel up: 127.0.0.1:%s -> %s:%s (pid %s)\n' "$local_port" "$host" "$REMOTE_PORT" "$owner"
}

tunnel_up() {
  host_arg "${1:-}"
  open_tunnel "$SSH_HOST" "$PORT"
}

tunnel_up_all() {
  local i=0 host
  while IFS= read -r host; do
    [[ -z "$host" ]] && continue
    open_tunnel "$host" "$(port_for_index "$i")"
    i=$((i + 1))
  done < <(hosts_list "$@")
  [[ "$i" -gt 0 ]] || die "host list is empty"
}

tunnel_down_all() {
  local i=0 host
  while IFS= read -r host; do
    [[ -z "$host" ]] && continue
    local port
    port=$(port_for_index "$i")
    local owner
    owner=$(listeners "$port" | head -n 1 || true)
    if [[ -z "$owner" ]]; then
      printf 'no tunnel on 127.0.0.1:%s (%s)\n' "$port" "$host"
    else
      if [[ "$PLATFORM" == "windows" ]]; then
        powershell.exe -NoProfile -Command "Stop-Process -Id $owner -Force"
      else
        kill "$owner"
      fi
      printf 'stopped pid %s (%s)\n' "$owner" "$host"
    fi
    i=$((i + 1))
  done < <(hosts_list "$@")
}

tunnel_down() {
  local owner
  owner=$(listeners | head -n 1 || true)
  if [[ -z "$owner" ]]; then
    printf 'no tunnel on 127.0.0.1:%s\n' "$PORT"
    return 0
  fi
  if [[ "$PLATFORM" == "windows" ]]; then
    powershell.exe -NoProfile -Command "Stop-Process -Id $owner -Force"
  else
    kill "$owner"
  fi
  printf 'stopped pid %s\n' "$owner"
}

no_proxy_list() {
  local list="localhost,127.0.0.1,::1"
  if [[ -n "$NO_PROXY_EXTRA" ]]; then
    list="${list},${NO_PROXY_EXTRA}"
  fi
  printf '%s\n' "$list"
}

router_up() {
  need node
  [[ -f "$ROUTER_JS" ]] || die "router not found: $ROUTER_JS"
  local owner
  # shellcheck disable=SC2046
  owner=$(listeners "$ROUTER_PORT" | head -n 1 || true)
  if [[ -n "$owner" ]]; then
    if router_api GET "/health" >/dev/null 2>&1; then
      printf 'router already on 127.0.0.1:%s (pid %s)\n' "$ROUTER_PORT" "$owner"
      return 0
    fi
    die "port $ROUTER_PORT is owned by pid $owner, not the router. Stop it or set ROUTER_PORT."
  fi
  mkdir -p "$CONFIG_DIR"
  # shellcheck disable=SC2046
  nohup node "$ROUTER_JS" --port "$ROUTER_PORT" --control "$CONTROL_PORT" \
    --state "$STATE_FILE" $(upstream_args "$@") \
    >>"$ROUTER_LOG" 2>&1 &
  echo $! >"$ROUTER_PID_FILE"
  local tries=0
  while [[ $tries -lt 20 ]]; do
    router_api GET "/health" >/dev/null 2>&1 && break
    sleep 0.25
    tries=$((tries + 1))
  done
  router_api GET "/health" >/dev/null 2>&1 || die "router did not start, see $ROUTER_LOG"
  printf 'router up: 127.0.0.1:%s control 127.0.0.1:%s\n' "$ROUTER_PORT" "$CONTROL_PORT"
  router_api GET "/status"
}

router_down() {
  if [[ -f "$ROUTER_PID_FILE" ]]; then
    local pid
    pid=$(cat "$ROUTER_PID_FILE")
    if [[ "$PLATFORM" == "windows" ]]; then
      powershell.exe -NoProfile -Command "Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue"
    else
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$ROUTER_PID_FILE"
    printf 'router pid %s stopped\n' "$pid"
    return 0
  fi
  local owner
  owner=$(listeners "$ROUTER_PORT" | head -n 1 || true)
  if [[ -z "$owner" ]]; then
    printf 'no router on 127.0.0.1:%s\n' "$ROUTER_PORT"
    return 0
  fi
  die "router pid file missing but port $ROUTER_PORT is owned by pid $owner; stop it by hand"
}

router_api() {
  local method="$1" path="$2" data="${3:-}"
  need curl
  if [[ -n "$data" ]]; then
    curl -s --max-time 10 -X "$method" "http://127.0.0.1:${CONTROL_PORT}${path}" \
      -H 'Content-Type: application/json' -d "$data"
  else
    curl -s --max-time 10 -X "$method" "http://127.0.0.1:${CONTROL_PORT}${path}"
  fi
}

router_next() {
  router_api POST "/next" "{}"
  printf '\n'
}

router_use() {
  [[ -n "${1:-}" ]] || die "usage: $(basename "$0") use <name>  (name, or \"direct\")"
  router_api POST "/use" "{\"name\":\"$1\"}"
  printf '\n'
}

proxy_on() {
  need opencode
  local bypass
  bypass=$(no_proxy_list)
  opencode service set env HTTPS_PROXY "http://127.0.0.1:${ROUTER_PORT}"
  opencode service set env HTTP_PROXY "http://127.0.0.1:${ROUTER_PORT}"
  opencode service set env NO_PROXY "$bypass"
  opencode service start >/dev/null 2>&1 || true
  printf 'proxy set to http://127.0.0.1:%s (router)\n' "$ROUTER_PORT"
  printf 'bypass: %s\n' "$bypass"
  printf 'run tunnel-up-all + router-up first, then restart OpenCode.\n'
}

proxy_off() {
  need opencode
  local name
  for name in HTTPS_PROXY HTTP_PROXY NO_PROXY; do
    opencode service unset env "$name" || true
  done
  printf 'proxy removed. restart OpenCode to leave from this machine again.\n'
}

status() {
  host_arg "${1:-}"
  need curl
  printf '%s\n' '--- tunnel ---'
  local owner
  owner=$(listeners | head -n 1 || true)
  if [[ -n "$owner" ]]; then
    printf 'listening on 127.0.0.1:%s (pid %s)\n' "$PORT" "$owner"
  else
    printf 'NOT listening on 127.0.0.1:%s\n' "$PORT"
  fi

  printf '%s\n' '' '--- egress ---'
  local direct via
  # Drop inherited proxy variables for the measurement only. Otherwise a shell
  # that already points at the tunnel reports the same address twice.
  direct=$(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
    curl -s --max-time 20 https://ifconfig.me || true)
  via=$(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
    curl -s --max-time 20 -x "http://127.0.0.1:${PORT}" https://ifconfig.me || true)
  printf 'direct:     %s\n' "${direct:-unreachable}"
  printf 'via tunnel: %s\n' "${via:-unreachable}"
  if [[ -n "$via" && -n "$direct" && "$via" != "$direct" ]]; then
    printf 'tunnel changes the egress address\n'
  else
    printf 'tunnel is NOT changing the egress address\n'
  fi

  printf '%s\n' '' '--- opencode ---'
  if command -v opencode >/dev/null 2>&1; then
    opencode service status || true
    opencode service get env || true
  else
    printf 'opencode is not on PATH\n'
  fi

  printf '%s\n' '' '--- vps log ---'
  ssh -o BatchMode=yes -o ConnectTimeout=12 "$SSH_HOST" \
    "grep -c opencode.ai /var/log/tinyproxy/tinyproxy.log 2>/dev/null || echo 0; echo '--- last ---'; grep opencode.ai /var/log/tinyproxy/tinyproxy.log 2>/dev/null | tail -n 5" \
    || printf 'could not read the VPS log\n'
}

status_all() {
  need curl
  printf '%s\n' '--- router ---'
  local owner
  owner=$(listeners "$ROUTER_PORT" | head -n 1 || true)
  if [[ -n "$owner" ]]; then
    printf 'listening on 127.0.0.1:%s (pid %s)\n' "$ROUTER_PORT" "$owner"
  else
    printf 'NOT listening on 127.0.0.1:%s\n' "$ROUTER_PORT"
  fi
  if router_api GET "/health" >/dev/null 2>&1; then
    router_api GET "/status"
    printf '\n'
  else
    printf 'control 127.0.0.1:%s unreachable (router down?)\n' "$CONTROL_PORT"
  fi

  printf '%s\n' '' '--- pool egress ---'
  local i=0 host
  while IFS= read -r host; do
    [[ -z "$host" ]] && continue
    local port ip
    port=$(port_for_index "$i")
    ip=$(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
      curl -s --max-time 15 -x "http://127.0.0.1:${port}" https://ifconfig.me || true)
    printf '%s: local 127.0.0.1:%s egress %s\n' "$host" "$port" "${ip:-unreachable}"
    i=$((i + 1))
  done < <(hosts_list "$@")
  if [[ "$EGRESS_INCLUDE_DIRECT" == "1" ]]; then
    local direct
    direct=$(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
      curl -s --max-time 15 https://ifconfig.me || true)
    printf 'direct: %s\n' "${direct:-unreachable}"
  fi

  printf '%s\n' '' '--- opencode ---'
  if command -v opencode >/dev/null 2>&1; then
    opencode service status || true
    opencode service get env || true
  else
    printf 'opencode is not on PATH\n'
  fi
}

setup_hint() {
  host_arg "${1:-}"
  cat <<EOF
Run this from the repo root. It installs tinyproxy on ${SSH_HOST}, bound to
127.0.0.1 only, and does not open a firewall port.

  cat scripts/setup-vps.sh | ssh ${SSH_HOST} "bash -s"
EOF
}

cmd="${1:-}"
shift || true

case "$cmd" in
  tunnel-up) tunnel_up "${1:-}" ;;
  tunnel-down) tunnel_down ;;
  tunnel-up-all) tunnel_up_all "${1:-}" ;;
  tunnel-down-all) tunnel_down_all "${1:-}" ;;
  router-up) router_up "${1:-}" ;;
  router-down) router_down ;;
  next) router_next ;;
  use) router_use "${1:-}" ;;
  on) proxy_on ;;
  off) proxy_off ;;
  status) status "${1:-}" ;;
  status-all) status_all "${1:-}" ;;
  setup-hint) setup_hint "${1:-}" ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown command: $cmd" ;;
esac
