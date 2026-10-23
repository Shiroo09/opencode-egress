# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions follow
[Semantic Versioning](https://semver.org/). Each version also ships as a
GitHub Release on the tag `vX.Y.Z` with the same notes.

## [Unreleased]

### Added

- `scripts/release.sh --auto-notes`: build empty release notes from commits
  since the previous tag (conventional subjects grouped), plus
  `--print-notes` preview, a dirty-tree guard, and a key-material scan.
- `scripts/release.sh` syncs a top-level `package.json` version in step.

### Changed

- Vendored gateway renamed **modelgate**: `vendor/zen-proxy/` → `vendor/modelgate/`.
  Panel functions `Start-Zen`/`Stop-Zen` → `Start-Gate`/`Stop-Gate`, `[Z]` label
  and config key `zenPort` → `gatePort` (old key still read).
- Dashboard logo replaced with an AI-generated sunburst
  (`gpt-image-2.5-sunburst`), palette acid/coral/ink on ivory, served as
  `assets/logo.svg` (favicon + header/auth images pick it up).

### Fixed

- `scripts/release.sh`: GitHub slug regex used a non-greedy `+?`, invalid
  in POSIX ERE, so the compare link was skipped on some systems. Now matches
  both HTTPS and SSH remotes.

## [0.2.0] - 2026-10-16

### Added

- Pool of VPSes behind a loopback router, with automatic failover. One bucket
  at a time is used; when it runs out the pool moves on by itself.
- `scripts/egress-router.mjs`: fixed `127.0.0.1:8888` endpoint for OpenCode.
  Forwards each connection to the active pool member (per-VPS SSH tunnels on
  `8891+i`, plus optional `direct`). TCP failures fail over transparently on
  the same connection. Exhaustion is tracked per egress with cooldowns, and
  the choice persists in `router-state.json` so restarts continue from the
  next egress. Loopback only, Node standard library, no dependencies.
- `plugins/egress-rotate`: OpenCode plugin. On a free-tier limit retry it
  marks the spent egress exhausted, rotates to the next one, and re-sends
  the last user message with the same model in the same chat. Stands down
  when every bucket is spent.
- Pool commands in `scripts/egress.sh`: `tunnel-up-all`, `tunnel-down-all`,
  `router-up`, `router-down`, `next`, `use <name>`, `status-all`.
- Pool config: `~/.config/opencode-egress/hosts` file or `EGRESS_HOSTS`, with
  `EGRESS_INCLUDE_DIRECT=0` to take your own address out of the rotation.
- Hermetic tests, Node stdlib only: `scripts/egress-router.test.mjs`
  (rotation, failover, exhaustion skip, persistence) and
  `plugins/egress-rotate/test.mjs` (rotate + re-send simulation).
- `scripts/release.sh`: semver bump, changelog, tag, push, GitHub Release
  in one command. Copy it into your other projects as is.

### Changed

- OpenCode now always points at the router (`127.0.0.1:8888`); per-VPS
  tunnels moved to `127.0.0.1:8891+i`. The router control API listens on
  `127.0.0.1:8899`.
- `on` targets the router; legacy single-tunnel `tunnel-up`/`status` still
  work but share port 8888 with the router, so use one mode or the other.
- README documents the pool setup, the plugin, reboot behavior, and the new
  troubleshooting cases.

### Upgrade notes

- Write your VPS aliases into `~/.config/opencode-egress/hosts` (one per
  line), then `tunnel-up-all`, `router-up`, `on`, and restart OpenCode.
- To enable automatic rotation, add the plugin to `opencode.jsonc` and
  restart OpenCode. Without it, `next` rotates by hand.
- With the proxy setting on and the router or its tunnels down, model
  requests fail instead of leaking out direct. That is intentional.

## [0.1.0] - 2026-10-16

First release: route OpenCode's free-model traffic through one VPS you own.

### Added

- `scripts/setup-vps.sh`: installs tinyproxy bound to `127.0.0.1:8888`,
  loopback only, on Debian/Ubuntu/Fedora/RHEL/Arch. No firewall changes.
- `scripts/egress.sh`: SSH tunnel management, OpenCode service proxy
  setting (`tunnel-up`, `tunnel-down`, `on`, `off`, `status`, `setup-hint`).
- `contrib/opencode-egress.service`: optional systemd user unit for one
  tunnel.
- README with the IP-bucket model, install steps, reboot table, and
  troubleshooting.
