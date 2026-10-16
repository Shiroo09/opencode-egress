# opencode-egress

Send OpenCode's free-model traffic out through public IPs you already own,
with automatic failover across all of them.

OpenCode's free tier counts requests against the client IP, not the account.
Each address you own (your machine, each VPS) has its own daily bucket. This
project pools them: OpenCode always talks to a router on `127.0.0.1:8888`,
and the router leaves from whichever pool member is currently active. When the
active bucket runs out, the OpenCode plugin detects the limit message, marks
that egress spent, rotates to the next one, and re-sends your last message
with the same model — the open chat continues where it stopped. Only model
traffic moves. Everything else on the machine stays on its normal route.

```
OpenCode
  |  HTTPS_PROXY=http://127.0.0.1:8888 (router, fixed)
  v
127.0.0.1:8888  egress-router.mjs, bound to loopback
  |-> 127.0.0.1:8891 -> SSH tunnel -> VPS-1 tinyproxy -> opencode.ai:443
  |-> 127.0.0.1:8892 -> SSH tunnel -> VPS-2 tinyproxy -> opencode.ai:443
  |-> direct (your own address, optional, last in rotation)
```

The proxy never listens on a public interface. SSH is the only port the VPS needs
open, and you already have that.

The client script runs on Windows, Linux, and macOS. The server script runs on
Debian, Ubuntu, Fedora, RHEL, and Arch.

## What this is not

- It does not raise a limit. It pools the separate daily buckets of your
  machine and your VPSes. They do not add together; the router uses one at a
  time and moves on when it is spent.
- It does nothing for OpenCode Go or a paid Console balance. Those follow the
  account, so a different IP changes nothing.
- It is not an open proxy. tinyproxy accepts `127.0.0.1` only, the router and
  its control API bind loopback only, and the tunnel is the only way to reach
  the VPS side.
- Seamless means a fresh attempt, not a rescued stream. The failed step can
  not be resumed mid-token (its error arrived inside TLS), so the plugin
  re-sends your last message as a new attempt in the same chat, on the new
  IP. If even that is impossible (every bucket spent), it does nothing and
  OpenCode retries normally.

## How the limit behaves

- The counter is keyed on the client IP. An OpenCode maintainer described the
  free-tier limiter as IP based in
  [opencode#10420](https://github.com/anomalyco/opencode/issues/10420).
- IPv6 is folded to a `/64`. Every address inside that prefix shares one bucket.
- The unit is requests, not tokens. One chat message can cost several requests,
  because the agent calls the model once per step.
- The window is roughly 24 hours. Past the limit, the client reports
  `Free usage exceeded` and a `retrying in Xh` delay.
- The size of the bucket is not published and is not fixed. A maintainer said in
  [opencode#28055](https://github.com/anomalyco/opencode/issues/28055) that it
  moves with capacity and demand. A number you read elsewhere is probably stale.

## Requirements

- A Linux VPS with a public IPv4 address, `systemd`, and one of `apt-get`, `dnf`,
  or `pacman`. Root SSH login with a key.
- On your machine: `bash`, `ssh`, and `curl`. OpenCode itself, so `opencode` is on
  `PATH`.
- Windows needs Git Bash or MSYS2. The built-in PowerShell is not a bash. Git for
  Windows ships all three tools, and `ssh` there is the system OpenSSH client.

## Install

### 1. Name the VPS in your SSH config

Add a `Host` alias that authenticates with a key and never asks for a password.
Keep this file out of the repo.

```
Host my-vps
    HostName 203.0.113.10
    User root
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

The path is `~/.ssh/config` on Linux and macOS, and `%USERPROFILE%\.ssh\config`
on Windows. Check it before continuing. `BatchMode` makes a missing key fail fast
instead of hanging on a prompt:

```sh
ssh -o BatchMode=yes my-vps "uname -a"
```

### 2. Install the proxy on the VPS

From the repo root:

```sh
cat scripts/setup-vps.sh | ssh my-vps "bash -s"
```

This installs tinyproxy, binds it to `127.0.0.1:8888`, allows loopback only, and
enables the service. It does not touch the firewall. On the VPS, confirm it:

```sh
systemctl is-active tinyproxy
ss -ltn | grep 8888          # 127.0.0.1:8888, never 0.0.0.0:8888
curl -s -x http://127.0.0.1:8888 https://ifconfig.me
```

The last line prints the VPS address. That is the address OpenCode will wear.

`setup-vps.sh` edits the packaged config instead of replacing it. tinyproxy 1.11
on Ubuntu rejects a rewritten file: a quoted path in `DefaultErrorFile` comes back
as `Syntax error on line N` and nothing else. If you edit the file by hand later,
keep the quoting style the package shipped.

### 3. Open the tunnels and point OpenCode at the router

List every VPS once, one SSH alias per line, in rotation order:

```
# ~/.config/opencode-egress/hosts  (keep this file out of the repo)
my-vps-1
my-vps-2
```

Then, from the repo root:

```sh
scripts/egress.sh tunnel-up-all
scripts/egress.sh router-up
scripts/egress.sh on
```

`router-up` starts `scripts/egress-router.mjs` on `127.0.0.1:8888` (Node
standard library only, no dependencies) and remembers the active egress in
`~/.config/opencode-egress/router-state.json`, so an OpenCode restart
continues from the next proxy instead of the spent one. `on` stores
`HTTPS_PROXY`, `HTTP_PROXY`, and `NO_PROXY` in the OpenCode service
environment, and nowhere else. Do not export those variables from your shell
profile. A shell that inherits them sends every program on the machine through
the router, and `status-all` then reports the same address twice. A process that is
already running keeps the environment it was born with, so quit OpenCode, or
OpenChamber, and start it again.

`EGRESS_HOSTS="my-vps-1,my-vps-2"` works instead of the hosts file, and a
bare `SSH_HOST=my-vps-1` keeps the single-VPS case working. Set
`EGRESS_INCLUDE_DIRECT=0` to take your own address out of the rotation.

Anything on your LAN that OpenCode talks to directly has to bypass the proxy.
Loopback is excluded automatically. Add the rest with `NO_PROXY_EXTRA`:

```sh
NO_PROXY_EXTRA=192.0.2.10,192.0.2.11 scripts/egress.sh on
```

Without that, those connections pile up inside tinyproxy until it starts refusing
new ones.

### 4. Install the rotation plugin (automatic failover)

Without this, the router stays on one egress until you move it by hand.
With it, a spent bucket rotates by itself:

```jsonc
// ~/.config/opencode/opencode.jsonc
{
  "plugin": ["file:///C:/Users/Samet/Documents/Projeler/opencode-egress/plugins/egress-rotate/index.ts"]
}
```

Use your own checkout path. Then restart OpenCode. Optional config,
`~/.config/opencode/egress-rotate.json`:

```json
{
  "routerUrl": "http://127.0.0.1:8899",
  "cooldownMs": 86400000,
  "logging": true
}
```

`cooldownMs` is how long a spent egress is skipped (default 24h, the bucket
window). Logs go to `~/.local/share/opencode/logs/egress-rotate.log` when
`logging` is true.

### 5. Check

```sh
scripts/egress.sh status-all
```

One line per pool member should show a different egress address, and the
router status should name the active one. Send a message, then confirm on
the active VPS:

```sh
ssh my-vps-1 "grep opencode.ai /var/log/tinyproxy/tinyproxy.log | tail -n 5"
```

The log line is the one that counts. A correct `ifconfig.me` result only proves
the tunnel works. The log proves OpenCode is using it.

Manual rotation any time, no restart:

```sh
scripts/egress.sh next          # next usable egress
scripts/egress.sh use direct    # pin one: a host alias, or "direct"
```

## Commands

```sh
scripts/egress.sh tunnel-up-all            # one tunnel per configured VPS
scripts/egress.sh tunnel-down-all          # close all pool tunnels
scripts/egress.sh router-up                # start the rotating router
scripts/egress.sh router-down              # stop it
scripts/egress.sh on                       # route OpenCode through the router
scripts/egress.sh off                      # route OpenCode direct again
scripts/egress.sh next                     # rotate now, no restart
scripts/egress.sh use direct               # pin one egress (alias or "direct")
scripts/egress.sh status-all               # router, every egress IP, health
scripts/egress.sh tunnel-up   my-vps       # legacy single-tunnel mode
scripts/egress.sh status      my-vps       # legacy single-tunnel check
scripts/egress.sh setup-hint  my-vps       # print the server install command
```

`EGRESS_HOSTS="my-vps-1,my-vps-2"` replaces the hosts file, `SSH_HOST`
replaces the argument for the legacy commands, and `ROUTER_PORT`,
`CONTROL_PORT`, `BASE_PORT` override `8888`/`8899`/`8891`.

## After a reboot

| Piece | Comes back on its own? |
| --- | --- |
| tinyproxy on the VPS | Yes. The service is enabled. |
| OpenCode proxy setting | Yes. It is stored in the service environment. |
| Active egress choice | Yes. It is stored in `router-state.json`. |
| SSH tunnels | No. They die with the session that opened them. |
| Router | No. Start it after the tunnels. |

Start the pool before OpenCode. With the proxy setting on and the router or
its tunnels down, model requests fail instead of leaking out direct.

```sh
scripts/egress.sh tunnel-up-all
scripts/egress.sh router-up
```

To run that at login, call it from whatever your system already uses. A systemd
user service on Linux, a LaunchAgent on macOS, or a shortcut in the Windows
Startup folder:

```
powershell.exe -WindowStyle Hidden -Command "bash -lc 'scripts/egress.sh tunnel-up-all && scripts/egress.sh router-up'"
```

Run it by hand once first, so you see the error if the key is wrong.

## Going back

```sh
scripts/egress.sh off
scripts/egress.sh router-down
scripts/egress.sh tunnel-down-all
```

Restart OpenCode. Traffic leaves from your own address again, and that bucket
continues from where it stopped.

## Troubleshooting

**`status-all` shows the same address for every member.**
A tunnel is down (its line says `unreachable`), or another program already
owns the router port. The router fails a dead member over on the next
connection, but a member that was never up has no bucket to offer. Fix the
tunnel, or take the member out of the hosts file.

**OpenCode errors while the proxy setting is on.**
The router or its tunnels are down. `router-up` refuses to start when port
8888 belongs to something else — usually a leftover legacy `tunnel-up` on the
same port. Run `tunnel-down`, then `tunnel-up-all` + `router-up`, and retry.
Nothing falls back to direct on its own; that is what keeps the buckets
separate.

**Limit hit on every egress, plugin does nothing.**
All buckets are spent. `status-all` (control section) shows each member with
an exhaustion timestamp. Wait for the oldest window to roll, or add another
VPS to the pool. The plugin stands down in this state by design.

**Plugin rotates but the chat does not continue.**
Check `~/.local/share/opencode/logs/egress-rotate.log` (needs
`"logging": true`). The rotation already happened, so one manual retry or
re-send goes out the fresh IP. If the log shows router connection errors,
the control port is wrong or the router is down.

**The VPS log fills with connections to your LAN, then refuses new ones.**
Those hosts are missing from `NO_PROXY_EXTRA`. Add them, run `on` again, and
restart OpenCode. The log line is `Maximum number of connections reached`.
`setup-vps.sh` sets `MaxClients 200`. Raising it hides the problem. Fixing
`NO_PROXY` removes it.

**tinyproxy will not start after a hand edit.**
Restore the backup the script left next to the config, named
`tinyproxy.conf.bak.<timestamp>`, and re-run `setup-vps.sh`.

**`ssh` asks for a password.**
`BatchMode=yes` forbids interactive input, so the tunnel exits. Use a key with no
passphrase, or load it into `ssh-agent` first.

## Layout

```
scripts/setup-vps.sh          run once per VPS, as root
scripts/egress.sh             tunnels, router, proxy setting, status
scripts/egress-router.mjs     loopback router + control API (Node stdlib only)
scripts/egress-router.test.mjs  hermetic router test: node scripts/egress-router.test.mjs
scripts/release.sh            semver bump + changelog + tag + GitHub Release
VERSION / CHANGELOG.md        version source of truth + release notes
plugins/egress-rotate/        OpenCode plugin: rotate + re-send on limit
plugins/egress-rotate/test.mjs  plugin simulation: node plugins/egress-rotate/test.mjs
contrib/opencode-egress.service   optional systemd user unit for one tunnel
```

## Releases

Versions follow [Semantic Versioning](https://semver.org/): `MAJOR.MINOR.PATCH`
in `VERSION`, notes in `CHANGELOG.md`, one annotated tag `vX.Y.Z` and one
GitHub Release per version. The release notes are the source of truth for
what changed, what was fixed, and how to upgrade.

To ship a new version, write the entry under `[Unreleased]` and run:

```sh
scripts/release.sh minor   # 0.2.0 -> 0.3.0 (new feature)
scripts/release.sh patch   # 0.2.0 -> 0.2.1 (fix)
scripts/release.sh major   # 0.2.0 -> 1.0.0 (breaking change)
```

It bumps `VERSION`, moves the notes to the new version, commits, tags,
pushes, and creates the GitHub Release (needs `gh` authenticated). The same
script works in your other projects: copy `scripts/release.sh` next to a
`VERSION` file and a Keep-a-Changelog `CHANGELOG.md`.

## License

MIT. See [LICENSE](LICENSE).
