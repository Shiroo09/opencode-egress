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

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

usage() {
  cat <<EOF
Point OpenCode's model traffic at a tinyproxy on a VPS you own.
Runs on Windows (Git Bash or MSYS2), Linux, and macOS.
EOF
  cat <<EOF

usage: $(basename "$0") <command> [ssh-host]

commands:
  tunnel-up     open the local tunnel to the VPS proxy
  tunnel-down   close it
  on            send OpenCode model traffic through the tunnel
  off           remove that setting
  status        show the tunnel, both egress IPs, and the VPS log
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
# match, so the tunnel is tracked by the local port it binds.
listeners() {
  if [[ "$PLATFORM" == "windows" ]]; then
    powershell.exe -NoProfile -Command \
      "Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $PORT -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess" \
      | tr -d '\r'
  else
    if command -v lsof >/dev/null 2>&1; then
      lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true
    elif command -v ss >/dev/null 2>&1; then
      ss -ltnp "sport = :$PORT" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p'
    else
      die "need lsof or ss to see what is listening"
    fi
  fi
}

tunnel_up() {
  host_arg "${1:-}"
  need ssh
  local owner
  owner=$(listeners | head -n 1 || true)
  if [[ -n "$owner" ]]; then
    printf 'tunnel already listening on 127.0.0.1:%s (pid %s)\n' "$PORT" "$owner"
    return 0
  fi

  # shellcheck disable=SC2029
  ssh -f -N \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -L "127.0.0.1:${PORT}:127.0.0.1:${REMOTE_PORT}" \
    "$SSH_HOST"

  local tries=0
  owner=""
  while [[ $tries -lt 20 ]]; do
    owner=$(listeners | head -n 1 || true)
    [[ -n "$owner" ]] && break
    sleep 0.25
    tries=$((tries + 1))
  done
  [[ -n "$owner" ]] || die "tunnel did not open. try: ssh -o BatchMode=yes $SSH_HOST echo ok"
  printf 'tunnel up: 127.0.0.1:%s -> %s:%s (pid %s)\n' "$PORT" "$SSH_HOST" "$REMOTE_PORT" "$owner"
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

proxy_on() {
  need opencode
  local bypass
  bypass=$(no_proxy_list)
  opencode service set env HTTPS_PROXY "http://127.0.0.1:${PORT}"
  opencode service set env HTTP_PROXY "http://127.0.0.1:${PORT}"
  opencode service set env NO_PROXY "$bypass"
  opencode service start >/dev/null 2>&1 || true
  printf 'proxy set to http://127.0.0.1:%s\n' "$PORT"
  printf 'bypass: %s\n' "$bypass"
  printf 'restart OpenCode so the running process picks this up.\n'
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
  on) proxy_on ;;
  off) proxy_off ;;
  status) status "${1:-}" ;;
  setup-hint) setup_hint "${1:-}" ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown command: $cmd" ;;
esac
