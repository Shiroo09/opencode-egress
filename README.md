# opencode-egress

Send OpenCode's free-model traffic out through a second public IP, using a Linux
VPS you already own.

OpenCode's free tier counts requests against the client IP, not the account. When
the address you are on runs out, this points the client at a VPS address that has
its own daily bucket. Only model traffic moves. Everything else on the machine
stays on its normal route.

```
OpenCode
  |  HTTPS_PROXY=http://127.0.0.1:8888
  |  NO_PROXY=localhost,127.0.0.1,::1,...
  v
127.0.0.1:8888            SSH tunnel, bound to loopback
  v
VPS 127.0.0.1:8888        tinyproxy, bound to loopback
  v
opencode.ai:443           leaves from the VPS address
```

The proxy never listens on a public interface. SSH is the only port the VPS needs
open, and you already have that.

The client script runs on Windows, Linux, and macOS. The server script runs on
Debian, Ubuntu, Fedora, RHEL, and Arch.

## What this is not

- It does not raise a limit. It gives you a second, separate daily bucket. The two
  do not add together, and nothing here switches between them automatically.
- It does nothing for OpenCode Go or a paid Console balance. Those follow the
  account, so a different IP changes nothing.
- It is not an open proxy. tinyproxy accepts `127.0.0.1` only, and the tunnel is
  the only way to reach it.

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

### 3. Open the tunnel and point OpenCode at it

```sh
scripts/egress.sh tunnel-up my-vps
scripts/egress.sh on
```

`on` stores `HTTPS_PROXY`, `HTTP_PROXY`, and `NO_PROXY` in the OpenCode service
environment, and nowhere else. Do not export those variables from your shell
profile. A shell that inherits them sends every program on the machine through
the VPS, and `status` then reports the same address twice. A process that is
already running keeps the environment it was born with, so quit OpenCode, or
OpenChamber, and start it again.

Anything on your LAN that OpenCode talks to directly has to bypass the proxy.
Loopback is excluded automatically. Add the rest with `NO_PROXY_EXTRA`:

```sh
NO_PROXY_EXTRA=192.0.2.10,192.0.2.11 scripts/egress.sh on
```

Without that, those connections pile up inside tinyproxy until it starts refusing
new ones.

### 4. Check

```sh
scripts/egress.sh status my-vps
```

Three things should be true:

- something is listening on `127.0.0.1:8888`
- `via tunnel` prints the VPS address, and `direct` prints your own
- the VPS log shows `CONNECT opencode.ai:443` after you send a message

The log line is the one that counts. A correct `ifconfig.me` result only proves
the tunnel works. The log proves OpenCode is using it.

## Commands

```sh
scripts/egress.sh tunnel-up   my-vps     # open the tunnel
scripts/egress.sh tunnel-down            # close it
scripts/egress.sh on                     # route OpenCode through it
scripts/egress.sh off                    # route OpenCode direct again
scripts/egress.sh status      my-vps     # tunnel, both IPs, VPS log
scripts/egress.sh setup-hint  my-vps     # print the server install command
```

`SSH_HOST` can replace the argument, and `PORT` overrides `8888` at both ends.

```sh
SSH_HOST=my-vps PORT=8888 scripts/egress.sh status
```

## After a reboot

| Piece | Comes back on its own? |
| --- | --- |
| tinyproxy on the VPS | Yes. The service is enabled. |
| OpenCode proxy setting | Yes. It is stored in the service environment. |
| SSH tunnel | No. It dies with the session that opened it. |

Start the tunnel before OpenCode. With the proxy setting on and the tunnel down,
model requests fail. They do not fall back to your own address.

```sh
scripts/egress.sh tunnel-up my-vps
```

To run that at login, call it from whatever your system already uses. A systemd
user service on Linux, a LaunchAgent on macOS, or a shortcut in the Windows
Startup folder:

```
powershell.exe -WindowStyle Hidden -Command "bash -lc 'scripts/egress.sh tunnel-up my-vps'"
```

Run it by hand once first, so you see the error if the key is wrong.

## Going back

```sh
scripts/egress.sh off
scripts/egress.sh tunnel-down
```

Restart OpenCode. Traffic leaves from your own address again, and that bucket
continues from where it stopped.

## Troubleshooting

**`status` shows the same address for `direct` and `via tunnel`.**
The tunnel is not up, or another program already owns local port 8888. Stop that
program or set `PORT` to a free one and re-run both `tunnel-up` and `on`.

**OpenCode errors while the proxy setting is on.**
The tunnel is down. Start it and retry. There is no fallback path.

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
scripts/setup-vps.sh     run once, on the VPS, as root
scripts/egress.sh        tunnel, proxy setting, and status, on your machine
contrib/opencode-egress.service   optional systemd user unit for the tunnel
```

## License

MIT. See [LICENSE](LICENSE).
