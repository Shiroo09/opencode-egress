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
- `scripts/egress-watch.mjs`: rotates the egress when OpenCode's free bucket
  runs out. OpenCode 2 dropped the V1 plugin hook, so rotation now watches the
  shared server's event stream (`~/.local/state/opencode/service.json`), marks
  the active egress spent, rotates the router and re-sends the last user
  message. Works for every client of that server (TUI, OpenChamber); started at
  logon by `router-boot.ps1` and shown in the panel.
- `scripts/egress-watch.test.mjs`: hermetic rotation test (stubbed service and
  router, strict on the `GET /status` verb the real router requires).
- `scripts/ccgate.mjs`: local model-name gateway for Claude Code. Compaction
  resolves the session model against Claude Code's own catalog, so a gateway
  model (`deepseek-v4.1-flash`) made every compaction fail with
  "Prompt is too long · automatic compaction failed: Not logged in". ccgate
  accepts catalog names, rewrites `model` in the body to the gateway model
  (including `[1m]` suffixes and family aliases), collapses the doubled `/v1`
  path and answers `/models`. Config: `~/.claude/ccgate.json`.
- `scripts/ccgate.test.mjs`: name mapping, body rewrite and path normalisation.
- Panel `[O]` also repairs a broken CLI after an npm update: `@opencode/cli`
  2.1.4 shipped without its `postinstall`, which made every `opencode` command
  fail with "postinstall script was not run". Detected by probing
  `opencode --version` and re-running `postinstall.mjs`.
- Panel shows the OpenCode service (`opencode`) and its pid, and `[O]` restarts
  it via `opencode service restart`. Closing the TUI leaves that background
  service running, which is why a "closed" OpenCode still retried on the spent
  IP.
- Panel settings screen `[Y]`: add/remove VPS hosts, test SSH, modelgate port,
  auto-start toggle and refresh interval, saved to
  `~/.config/opencode-egress/config.json`. Every start/stop now asks first;
  `[A]` offers all hosts or one and reports per-tunnel success, `[V]` picks the
  exit from the live upstream list.
- `scripts/panel.test.ps1`: asserts the yes/no parser behind the confirmations.
- `scripts/router-boot.ps1`: starts the router at logon (HKCU `Run` entry) so
  opencode's fixed `127.0.0.1:8888` proxy never goes missing; with tunnels down
  the first connection falls back to `direct`. Panel `[K]` now stops tunnels and
  the gateway only, `[X]` stops the router too.

### Fixed

- `plugins/egress-rotate` never loaded on OpenCode 2.x ("configured plugin path
  must be a directory", then "Plugin must export a default definition"): the
  config now points at the plugin directory and `index.ts` exports
  `{ id, setup, server }`. The rate-limit matcher also normalises punctuation,
  so "Free usage limit reached." matches, and a structured `action.reason`
  (`provider.quota`) rotates even when the text is generic.
- modelgate's port came from `zen-proxy.json`, not `PORT`, so the panel's `[P]`
  changed nothing. The panel now writes the chosen port into that file.
- `scripts/smoke-zen.mjs` picked a fixed port and the shipped config overrode
  it; a half-finished run then made the next one hit a stale gateway. It now
  uses a free port and its own temporary config copy.

### Changed

- modelgate now defaults to port **8790** (8787 is `web/server.js`); the panel
  reports a busy port instead of silently reusing it.
- Vendored gateway renamed **modelgate**: `vendor/zen-proxy/` → `vendor/modelgate/`.
  Panel functions `Start-Zen`/`Stop-Zen` → `Start-Gate`/`Stop-Gate`, `[Z]` label
  and config key `zenPort` → `gatePort` (old key still read).
- Dashboard logo replaced with an AI-generated sunburst
  (`gpt-image-2.5-sunburst`), palette acid/coral/ink on ivory, served as
  `assets/logo.svg` (favicon + header/auth images pick it up).

### Fixed

- Panel no longer clears the screen on every refresh; the frame is redrawn in
  place (cursor home + padded lines), so the menu stops flickering while
  requests keep updating automatically. The "refreshes every 2 s" caption is gone.
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
