# opencode-egress panel. One window: open, close, pick the exit, watch requests.
# Reads only the router's loopback control port. Starts nothing until you press a key.
$ErrorActionPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$Root = Split-Path -Parent $PSScriptRoot
$RouterJs = Join-Path $PSScriptRoot 'egress-router.mjs'
$ConfigDir = Join-Path $env:USERPROFILE '.config\opencode-egress'
$StateFile = Join-Path $ConfigDir 'router-state.json'
$HostsFile = Join-Path $ConfigDir 'hosts'
$RouterPort = 8888
$ControlPort = 8899
$BasePort = 8891
$Control = "http://127.0.0.1:$ControlPort"
$ZenJs = Join-Path $Root 'vendor\zen-proxy\zen-proxy.mjs'
$ZenPort = 8787

function Say($text, $color) { Write-Host $text -ForegroundColor $color }

function Listening($port) {
    $c = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($c) { return [int]$c.OwningProcess }
    return $null
}

function Get-Json($url) {
    try { return Invoke-RestMethod -Uri $url -TimeoutSec 3 } catch { return $null }
}

function Post-Json($path, $body) {
    try {
        return Invoke-RestMethod -Uri "$Control$path" -Method Post -ContentType 'application/json' `
            -Body $body -TimeoutSec 5
    } catch { return $null }
}

function Hosts {
    if (-not (Test-Path $HostsFile)) { return @() }
    Get-Content $HostsFile | ForEach-Object { ($_ -replace '#.*', '').Trim() } | Where-Object { $_ }
}

function Start-Pool {
    $list = @(Hosts)
    if (-not $list) { Say 'host listesi bos: ~/.config/opencode-egress/hosts' Red; return }
    $i = 0
    foreach ($h in $list) {
        $port = $BasePort + $i
        if (-not (Listening $port)) {
            Start-Process ssh -WindowStyle Hidden -ArgumentList @(
                '-N', '-o', 'BatchMode=yes', '-o', 'ExitOnForwardFailure=yes',
                '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3',
                '-L', "127.0.0.1:${port}:127.0.0.1:8888", $h)
            Say "tunel aciliyor: $h -> 127.0.0.1:$port" DarkGray
        }
        $i++
    }
    if (-not (Listening $RouterPort)) {
        $up = @()
        $i = 0
        foreach ($h in $list) { $up += '--upstream'; $up += "$h=127.0.0.1:$($BasePort + $i)"; $i++ }
        $up += '--upstream', 'direct=direct'
        $node = (Get-Command node -ErrorAction SilentlyContinue).Source
        if (-not $node) { Say 'node yok' Red; return }
        Start-Process $node -WindowStyle Hidden -ArgumentList (@(
                $RouterJs, '--port', $RouterPort, '--control', $ControlPort,
                '--state', $StateFile) + $up)
        Say 'router aciliyor: 127.0.0.1:8888' DarkGray
    }
}

function Stop-Pool {
    foreach ($port in @($RouterPort, $ControlPort)) {
        $pid_ = Listening $port
        if ($pid_) { Stop-Process -Id $pid_ -Force -ErrorAction SilentlyContinue }
    }
    $list = @(Hosts)
    for ($i = 0; $i -lt $list.Count; $i++) {
        $pid_ = Listening ($BasePort + $i)
        if ($pid_) { Stop-Process -Id $pid_ -Force -ErrorAction SilentlyContinue }
    }
    Stop-Zen
}

function Start-Zen {
    if (Listening $ZenPort) {
        $h = Get-Json "http://127.0.0.1:$ZenPort/health"
        if ($h -and $h.upstream) { return }
        Say "port $ZenPort baska bir surecde dolu (zen-proxy degil)" Red
        return
    }
    if (-not (Test-Path $ZenJs)) { Say 'vendor/zen-proxy yok' Red; return }
    if (-not (Listening $RouterPort)) { Say 'zen-proxy icin router acik olmali (A)' Red; return }
    $node = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $node) { Say 'node yok' Red; return }
    $env:NODE_USE_ENV_PROXY = '1'
    $env:HTTPS_PROXY = "http://127.0.0.1:$RouterPort"
    $env:NO_PROXY = 'localhost,127.0.0.1'
    Start-Process $node -WindowStyle Hidden -ArgumentList $ZenJs
    Say "zen-proxy aciliyor: 127.0.0.1:$ZenPort" DarkGray
}

function Stop-Zen {
    $pid_ = Listening $ZenPort
    if ($pid_) { Stop-Process -Id $pid_ -Force -ErrorAction SilentlyContinue }
}

$status = $null
$seen = @{}
$since = (Get-Date).ToUniversalTime().ToString('o')

while ($true) {
    Clear-Host
    $routerPid = Listening $RouterPort
    $status = if ($routerPid) { Get-Json "$Control/status" } else { $null }
    $recent = if ($routerPid) { Get-Json "$Control/recent?n=200" } else { $null }

    Say 'opencode-egress' Cyan
    if (-not $routerPid) {
        Say 'KAPALI  router 127.0.0.1:8888 dinlemiyor' Red
    } else {
        $active = if ($status) { $status.active } else { '?' }
        Say "ACIK    cikis: $active    router pid $routerPid" Green
    }

    $i = 0
    foreach ($h in @(Hosts)) {
        $port = $BasePort + $i
        $pid_ = Listening $port
        $mark = if ($pid_) { "tunel acik  pid $pid_" } else { 'tunel kapali' }
        $color = if ($pid_) { 'Green' } else { 'DarkGray' }
        Say ("  {0,-22} 127.0.0.1:{1}  {2}" -f $h, $port, $mark) $color
        $i++
    }
    $zenPid = Listening $ZenPort
    $zenUp = if ($zenPid) { Get-Json "http://127.0.0.1:$ZenPort/health" } else { $null }
    if ($zenPid -and $zenUp -and $zenUp.upstream) {
        Say ("  {0,-22} acik  pid {1}  http://127.0.0.1:{2}" -f 'zen-proxy', $zenPid, $ZenPort) Green
    } elseif ($zenPid) {
        Say ("  {0,-22} port {1} dolu (zen-proxy degil)" -f 'zen-proxy', $ZenPort) Red
    } else {
        Say ("  {0,-22} kapali" -f 'zen-proxy') DarkGray
    }
    if ($status) {
        foreach ($u in $status.upstreams) {
            $flags = @()
            if ($u.exhaustedUntil) { $flags += 'limit dolu' }
            if ($u.downUntil) { $flags += 'erisilemiyor' }
            $tag = if ($u.name -eq $status.active) { '*' } else { ' ' }
            $extra = if ($flags) { '  [' + ($flags -join ', ') + ']' } else { '' }
            Say ("  {0} {1,-22} {2}{3}" -f $tag, $u.name, $u.via, $extra) Gray
        }
    }

    Say '' White
    Say 'istekler  (son gelen ustte, yalniz bu oturum)' Cyan
    $rows = @()
    if ($recent -and $recent.rows) { $rows = @($recent.rows) }
    $fresh = @($rows | Where-Object { $_.t -gt $since } | Sort-Object t -Descending)
    if (-not $fresh) {
        Say '  henuz istek yok' DarkGray
    } else {
        $n = 0
        foreach ($r in $fresh) {
            if ($n -ge 18) { break }
            $clock = ([DateTime]$r.t).ToLocalTime().ToString('HH:mm:ss')
            $where = if ($r.via) { $r.via } else { '-' }
            $color = if ($r.result -eq 'ok') { 'Gray' } else { 'Red' }
            Say ("  {0}  {1,-6} {2}:{3,-5}  {4,-18} {5}" -f $clock, $r.method, $r.host, $r.port, $where, $r.result) $color
            $n++
        }
        $ok = @($fresh | Where-Object result -eq 'ok').Count
        $bad = $fresh.Count - $ok
        Say ("  toplam {0}   ok {1}   hata {2}" -f $fresh.Count, $ok, $bad) DarkGray
    }

    Say '' White
    Say '[A] ac   [Z] zen-proxy   [K] kapat   [D] direct   [V] VPS   [S] sonraki   [Q] cik' Yellow
    Say 'tus bekleniyor, istekler 2 sn de bir yenilenir' DarkGray

    $deadline = (Get-Date).AddSeconds(2)
    $key = $null
    while ((Get-Date) -lt $deadline) {
        if ([Console]::KeyAvailable) { $key = [Console]::ReadKey($true); break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $key) { continue }

    switch ($key.Key) {
        'A' { Start-Pool; Start-Sleep -Seconds 2; Start-Zen }
        'K' { Stop-Pool }
        'Z' { if (Listening $ZenPort) { Stop-Zen } else { Start-Zen; Start-Sleep -Seconds 2 } }
        'D' { Post-Json '/use' '{"name":"direct"}' | Out-Null }
        'V' {
            $first = @(Hosts) | Select-Object -First 1
            if ($first) { Post-Json '/use' ('{"name":"' + $first + '"}') | Out-Null }
        }
        'S' { Post-Json '/next' '{}' | Out-Null }
        'Q' { return }
    }
}
