#!/usr/bin/env bash
# Install tinyproxy bound to loopback, so an SSH tunnel is the only way in.
# Supports apt (Debian, Ubuntu), dnf (Fedora, RHEL), and pacman (Arch).
# Does not open a firewall port. Run as root.
set -euo pipefail

PORT="${PORT:-8888}"
MAX_CLIENTS="${MAX_CLIENTS:-200}"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

install_pkg() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq tinyproxy
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y tinyproxy
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm tinyproxy
  else
    echo "no supported package manager (apt-get, dnf, pacman)" >&2
    exit 1
  fi
}

install_pkg

CONF=""
for candidate in /etc/tinyproxy/tinyproxy.conf /etc/tinyproxy.conf; do
  if [[ -f "$candidate" ]]; then
    CONF="$candidate"
    break
  fi
done
if [[ -z "$CONF" ]]; then
  echo "tinyproxy installed but its config was not found" >&2
  exit 1
fi

# Edit the packaged file in place. Rewriting it breaks tinyproxy 1.11 on
# Ubuntu: quoted paths in DefaultErrorFile are reported as a syntax error,
# and the message only names the line.
cp -a "$CONF" "${CONF}.bak.$(date +%Y%m%d%H%M%S)"

set_kv() {
  local key="$1" value="$2"
  if grep -qE "^${key}[[:space:]]" "$CONF"; then
    sed -i "s|^${key}[[:space:]].*|${key} ${value}|" "$CONF"
  elif grep -qE "^#[[:space:]]*${key}[[:space:]]" "$CONF"; then
    sed -i "0,/^#[[:space:]]*${key}[[:space:]]/{s|^#[[:space:]]*${key}[[:space:]].*|${key} ${value}|}" "$CONF"
  else
    printf '\n%s %s\n' "$key" "$value" >> "$CONF"
  fi
}

set_kv Listen 127.0.0.1
set_kv Port "$PORT"
set_kv MaxClients "$MAX_CLIENTS"
grep -qE "^Allow[[:space:]]+127\.0\.0\.1([[:space:]]|$)" "$CONF" || echo "Allow 127.0.0.1" >> "$CONF"

if command -v systemctl >/dev/null 2>&1; then
  systemctl enable tinyproxy >/dev/null 2>&1 || true
  systemctl restart tinyproxy
  sleep 1
  if ! systemctl is-active --quiet tinyproxy; then
    echo "tinyproxy failed to start:" >&2
    journalctl -u tinyproxy -n 20 --no-pager >&2 || true
    exit 1
  fi
else
  service tinyproxy restart
  sleep 1
fi

listening=$(ss -ltn 2>/dev/null | grep -E ":${PORT}([^0-9]|$)" || true)
if [[ -z "$listening" ]]; then
  echo "nothing is listening on port ${PORT}" >&2
  exit 1
fi
echo "$listening"

if echo "$listening" | grep -qE "(0\.0\.0\.0|\*|\[::\]):${PORT}"; then
  echo "refusing to leave tinyproxy reachable beyond loopback" >&2
  systemctl stop tinyproxy 2>/dev/null || service tinyproxy stop
  exit 1
fi

echo "egress through the proxy:"
curl -s --max-time 20 -x "http://127.0.0.1:${PORT}" https://ifconfig.me || true
echo
