# opencode-egress panel. One window: tunnels, exit, modelgate, settings.
# Reads the router's loopback control port. Nothing starts without a confirmation.
$ErrorActionPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$Root = Split-Path -Parent $PSScriptRoot
$RouterJs = Join-Path $PSScriptRoot 'egress-router.mjs'
$ConfigDir = Join-Path $env:USERPROFILE '.config\opencode-egress'
$StateFile = Join-Path $ConfigDir 'router-state.json'
$HostsFile = Join-Path $ConfigDir 'hosts'
$ConfigFile = Join-Path $ConfigDir 'config.json'
$RouterPort = 8888        # opencode service.json bu porta sabit; değiştirilemez
$ControlPort = 8899
$BasePort = 8891
$Control = "http://127.0.0.1:$ControlPort"
$GateJs = Join-Path $Root 'vendor\modelgate\zen-proxy.mjs'

# 8787 kullanicinin web/server.js'inde; varsayilan 8790 (ayarlardan degistirilebilir).
$Config = @{ gatePort = 8790; gateAuto = $true; refreshSec = 2 }
try { $Host.UI.RawUI.WindowTitle = 'opencode-egress' } catch {}
function Load-Config {
    if (-not (Test-Path $ConfigFile)) { return }
    try {
        $c = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($c.gatePort) { $Config.gatePort = [int]$c.gatePort }
        elseif ($c.zenPort) { $Config.gatePort = [int]$c.zenPort }  # eski anahtar
        if ($null -ne $c.gateAuto) { $Config.gateAuto = [bool]$c.gateAuto }
        if ($c.refreshSec) { $Config.refreshSec = [Math]::Max(1, [int]$c.refreshSec) }
    } catch { Say 'config.json okunamadi, varsayilanlar kullaniliyor' Red }
}
function Save-Config {
    if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
    @{ gatePort = $Config.gatePort; gateAuto = [bool]$Config.gateAuto; refreshSec = $Config.refreshSec } |
        ConvertTo-Json | Set-Content $ConfigFile
}

# Kare ekranı silmeden yerinde çizilir: Clear-Host her yenilemede titretiyordu.
# Say satırı pencere genişliğine doldurur, böylece eski satır kuyruğu kalmasın.
$script:frameCount = 0
$script:prevCount = 0
$script:inFrame = $false
$script:drawn = $false
$script:forceClear = $false

function Say($text, $color) {
    $w = 0
    try { $w = [Console]::WindowWidth - 1 } catch {}
    if ($w -gt 0 -and $text.Length -lt $w) { $text = $text.PadRight($w) }
    Write-Host $text -ForegroundColor $color
    if ($script:inFrame) { $script:frameCount++ }
}

function Begin-Frame {
    try {
        if (-not $script:drawn -or $script:forceClear) { Clear-Host; $script:drawn = $true; $script:forceClear = $false }
        else { [Console]::SetCursorPosition(0, 0) }
    } catch { Clear-Host }
    $script:inFrame = $true
    $script:frameCount = 0
}

function End-Frame {
    $w = 0
    try { $w = [Console]::WindowWidth - 1 } catch {}
    if ($w -gt 0 -and $script:frameCount -lt $script:prevCount) {
        for ($i = $script:frameCount; $i -lt $script:prevCount; $i++) { Write-Host (' ' * $w) }
    }
    $script:prevCount = $script:frameCount
    $script:inFrame = $false
}

function Listening($port) {
    $c = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($c) { return [int]$c.OwningProcess }
    return $null
}

# Port dinliyor olabilir ama bizim ssh tünelimiz olmayabilir (baska surec).
function Is-Tunnel($port) {
    $pid_ = Listening $port
    if (-not $pid_) { return $false }
    $p = Get-Process -Id $pid_ -ErrorAction SilentlyContinue
    return ($p -and $p.ProcessName -like 'ssh*')
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

function Set-Hosts($list) {
    if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
    if (@($list).Count) { @($list) | Set-Content $HostsFile }
    else { Set-Content -Path $HostsFile -Value '' }  # son host silinince dosya bos kalsin
}

# --- Onay ve bekleme -------------------------------------------------------
function Ask($prompt) {
    $script:forceClear = $true
    Write-Host ''
    return ((Read-Host $prompt) -match '^(e|evet|y|yes)$')
}
function Pause($msg) { $script:forceClear = $true; Write-Host ''; Read-Host $msg | Out-Null }

# --- Router ---------------------------------------------------------------
function Start-Router {
    if (Listening $RouterPort) { return $true }
    $list = @(Hosts)
    $up = @()
    $i = 0
    foreach ($h in $list) { $up += '--upstream'; $up += "$h=127.0.0.1:$($BasePort + $i)"; $i++ }
    $up += '--upstream', 'direct=direct'
    $node = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $node) { Write-Host 'node bulunamadi' -ForegroundColor Red; return $false }
    Start-Process $node -WindowStyle Hidden -ArgumentList (@(
            $RouterJs, '--port', $RouterPort, '--control', $ControlPort, '--state', $StateFile) + $up)
    for ($k = 0; $k -lt 30; $k++) { Start-Sleep -Milliseconds 100; if (Listening $RouterPort) { return $true } }
    return $false
}

function Restart-Router {
    foreach ($port in @($RouterPort, $ControlPort)) {
        $pid_ = Listening $port
        if ($pid_) { Stop-Process -Id $pid_ -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 400
    Start-Router | Out-Null
}

# --- Tunnels --------------------------------------------------------------
function Start-Tunnel($hostName, $port) {
    if (Is-Tunnel $port) { return $true }
    if (Listening $port) { Say "port $port baska bir surecde dolu" Red; return $false }
    $ssh = (Get-Command ssh -ErrorAction SilentlyContinue).Source
    if (-not $ssh) { Say 'ssh bulunamadi' Red; return $false }
    $log = Join-Path $env:TEMP "egress-ssh-$port.log"
    Start-Process $ssh -WindowStyle Hidden -RedirectStandardError $log -ArgumentList @(
        '-N', '-o', 'BatchMode=yes', '-o', 'ExitOnForwardFailure=yes', '-o', 'ConnectTimeout=6',
        '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3',
        '-L', "127.0.0.1:${port}:127.0.0.1:8888", $hostName)
    for ($k = 0; $k -lt 50; $k++) { Start-Sleep -Milliseconds 100; if (Is-Tunnel $port) { return $true } }
    # Basarisizligin sebebi ssh ciktisinda: son satiri goster.
    $why = (Get-Content $log -Tail 1 -ErrorAction SilentlyContinue)
    if ($why) { Say "  ssh: $why" Red }
    return $false
}

function Start-Pool {
    $list = @(Hosts)
    if (-not $list) { Say 'host listesi bos - [Y] ayarlar' Red; Pause 'devam icin Enter'; return }

    # Kullanıcıya ne açılacağını sor: tümü, tek host ya da iptal.
    $script:forceClear = $true
    Write-Host ''
    Write-Host 'Acilacak tuneller:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $list.Count; $i++) { Write-Host ("  [{0}] {1,-22} 127.0.0.1:{2}" -f ($i + 1), $list[$i], ($BasePort + $i)) }
    $gate = $Config.gateAuto -and (Test-Path $GateJs)
    if ($gate) { Write-Host ("  [+] modelgate (port {0})" -f $Config.gatePort) }
    Write-Host ''
    $a = Read-Host 'Tumu icin [e], tek host icin numara, iptal icin bos birakip Enter'
    if (-not $a) { return }
    $pick = @()
    if ($a -match '^(e|evet|y|yes)$') { $pick = $list }
    elseif ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $list.Count) { $pick = @($list[[int]$a - 1]) }
    else { Write-Host 'gecersiz secim' -ForegroundColor Red; Start-Sleep -Seconds 1; return }

    foreach ($h in $pick) {
        $port = $BasePort + [array]::IndexOf($list, $h)
        $ok = Start-Tunnel $h $port
        if ($ok) { Say "tunel acildi: $h -> 127.0.0.1:$port" Green }
        else { Say "tunel ACILAMADI: $h (ssh anahtari/ag?)" Red }
    }
    if (-not (Start-Router)) { Say 'router acilamadi (8888)' Red; Start-Sleep -Seconds 2; return }
    Say "router hazir: 127.0.0.1:$RouterPort" DarkGray
    if ($gate) { Start-Gate }
    Start-Sleep -Seconds 1
}

# Yalnizca kendi surecimizi oldur: portta baska bir uygulama olabilir.
function Is-Our-Process($port, $pattern) {
    $pid_ = Listening $port
    if (-not $pid_) { return $false }
    $c = Get-CimInstance Win32_Process -Filter "ProcessId=$pid_" -ErrorAction SilentlyContinue
    return ($c -and $c.CommandLine -match $pattern)
}

function Stop-Tunnels {
    $list = @(Hosts)
    for ($i = 0; $i -lt $list.Count; $i++) {
        $port = $BasePort + $i
        $pid_ = Listening $port
        if ($pid_ -and (Is-Tunnel $port)) { Stop-Process -Id $pid_ -Force -ErrorAction SilentlyContinue }
    }
}

function Stop-Pool {
    if (-not (Ask 'Tuneller ve modelgate kapatilsin mi? Router acik kalir (opencode icin).')) { return }
    Stop-Tunnels
    Stop-Gate
}

function Stop-All {
    if (-not (Ask 'HER SEY kapatilsin mi? (opencode baglantisi da kesilir)')) { return }
    Stop-Tunnels
    Stop-Gate
    foreach ($port in @($RouterPort, $ControlPort)) {
        if (Is-Our-Process $port 'egress-router') {
            Stop-Process -Id (Listening $port) -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Modelgate ------------------------------------------------------------
function Start-Gate {
    if (Listening $Config.gatePort) {
        $h = Get-Json "http://127.0.0.1:$($Config.gatePort)/health"
        if ($h -and $h.upstream) { return }
        Say "port $($Config.gatePort) baska bir surecde dolu (modelgate degil)" Red
        return
    }
    if (-not (Test-Path $GateJs)) { Say 'vendor/modelgate yok' Red; return }
    if (-not (Listening $RouterPort)) { Say 'modelgate icin router acik olmali (A)' Red; return }
    $node = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $node) { Say 'node yok' Red; return }
    $env:NODE_USE_ENV_PROXY = '1'
    $env:HTTPS_PROXY = "http://127.0.0.1:$RouterPort"
    $env:NO_PROXY = 'localhost,127.0.0.1'
    $env:PORT = "$($Config.gatePort)"
    Start-Process $node -WindowStyle Hidden -ArgumentList $GateJs
    Say "modelgate aciliyor: 127.0.0.1:$($Config.gatePort)" DarkGray
}

function Stop-Gate {
    if (Is-Our-Process $Config.gatePort 'zen-proxy') {
        Stop-Process -Id (Listening $Config.gatePort) -Force -ErrorAction SilentlyContinue
    }
}

# --- Ayarlar --------------------------------------------------------------
function Test-Host($h) {
    Write-Host "  $h test ediliyor..." -ForegroundColor DarkGray
    $p = Start-Process ssh -WindowStyle Hidden -PassThru -ArgumentList @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=6', $h, 'true')
    if ($p.WaitForExit(8000) -and $p.ExitCode -eq 0) { Write-Host '  ssh OK' -ForegroundColor Green; return }
    Write-Host '  ssh BASARISIZ (anahtar, host adi ya da ag)' -ForegroundColor Red
}

function Show-Settings {
    while ($true) {
        Clear-Host
        $list = @(Hosts)
        Write-Host 'opencode-egress / ayarlar' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  1) VPS listesi' -ForegroundColor Yellow
        if ($list) { for ($i = 0; $i -lt $list.Count; $i++) { Write-Host ("       [{0}] {1}" -f ($i + 1), $list[$i]) } }
        else { Write-Host '       (bos)' -ForegroundColor DarkGray }
        Write-Host ("  2) modelgate portu   : {0}" -f $Config.gatePort) -ForegroundColor Yellow
        Write-Host ("  3) A ile modelgate   : {0}" -f $(if ($Config.gateAuto) { 'acilsin' } else { 'acilmasin' })) -ForegroundColor Yellow
        Write-Host ("  4) yenileme          : {0} sn" -f $Config.refreshSec) -ForegroundColor Yellow
        Write-Host ("  5) router portu      : {0}  (opencode service.json'a sabit)" -f $RouterPort) -ForegroundColor DarkGray
        Write-Host ("  dosyalar             : {0}" -f $ConfigDir) -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  [B] geri' -ForegroundColor Cyan
        Write-Host ''
        $k = Read-Host 'secim'
        switch -Regex ($k) {
            '^1$' {
                Write-Host ''
                $n = Read-Host '  [+] host ekle, [c] cikar, [t] test, bos = geri'
                if ($n -match '^\+' -or $n -match '^ekle') {
                    $h = Read-Host '  host adi (ssh config alias ya da user@host)'
                    if ($h -and $h -notmatch '^[\w.@\-]+$') { Write-Host '  gecersiz host adi' -ForegroundColor Red; Read-Host '  Enter' | Out-Null }
                    elseif ($h -and ($list -contains $h)) { Write-Host '  bu host zaten listede' -ForegroundColor Yellow; Read-Host '  Enter' | Out-Null }
                    elseif ($h) {
                        Stop-Tunnels  # eski port eslemesi gecersiz kalmasin
                        $list += $h; Set-Hosts $list
                        Restart-Router | Out-Null
                        Write-Host '  eklendi; router yeni listeyle yeniden baslatildi' -ForegroundColor Green
                        Test-Host $h
                    }
                    Read-Host '  Enter' | Out-Null
                } elseif ($n -match '^(c|-)' -or $n -match '^cikar') {
                    $i = Read-Host '  cikarilacak numara'
                    if ($i -match '^\d+$' -and [int]$i -ge 1 -and [int]$i -le $list.Count) {
                        $drop = $list[([int]$i - 1)]
                        Stop-Tunnels  # eski port eslemesi gecersiz kalmasin
                        $list = @($list | Where-Object { $_ -ne $drop })
                        Set-Hosts $list
                        Restart-Router | Out-Null
                        Write-Host '  cikarildi; router yeniden baslatildi' -ForegroundColor Green
                    } else { Write-Host '  gecersiz numara' -ForegroundColor Red }
                    Read-Host '  Enter' | Out-Null
                } elseif ($n -match '^(t|test)') {
                    foreach ($h in $list) { Test-Host $h }
                    Read-Host '  Enter' | Out-Null
                }
            }
            '^2$' {
                $p = Read-Host ("  yeni modelgate portu (simdi {0})" -f $Config.gatePort)
                if ($p -match '^\d+$' -and [int]$p -ge 1024 -and [int]$p -le 65535) {
                    if (Listening ([int]$p)) { Write-Host '  port dolu' -ForegroundColor Red }
                    else {
                        Stop-Gate           # eski porttaki modelgate kalmasin
                        $Config.gatePort = [int]$p; Save-Config
                        Write-Host '  kaydedildi ([Z] ile yeni portta ac)' -ForegroundColor Green
                    }
                } elseif ($p) { Write-Host '  gecersiz port' -ForegroundColor Red }
                Read-Host '  Enter' | Out-Null
            }
            '^3$' { $Config.gateAuto = -not $Config.gateAuto; Save-Config }
            '^4$' {
                $r = Read-Host ("  yenileme saniyesi (simdi {0})" -f $Config.refreshSec)
                if ($r -match '^\d+$' -and [int]$r -ge 1 -and [int]$r -le 60) { $Config.refreshSec = [int]$r; Save-Config }
                else { Write-Host '  1-60 arasi olmali' -ForegroundColor Red; Read-Host '  Enter' | Out-Null }
            }
            '^(b|B|q|Q)$' { $script:forceClear = $true; return }
        }
    }
}

# --- Ana dongu ------------------------------------------------------------
# Test icin: fonksiyonlari yukle, ekrani cizme (scripts/panel.test.ps1).
if ($env:OPENCODE_EGRESS_SELFTEST -eq '1') { return }
Load-Config
while ($true) {
    Begin-Frame
    $routerPid = Listening $RouterPort
    $status = if ($routerPid) { Get-Json "$Control/status" } else { $null }
    $recent = if ($routerPid) { Get-Json "$Control/recent?n=200" } else { $null }

    Say 'opencode-egress' Cyan
    if (-not $routerPid) {
        Say 'KAPALI  router 127.0.0.1:8888 dinlemiyor  ([A] ile baslat)' Red
    } else {
        $active = if ($status) { $status.active } else { '?' }
        Say "ACIK    cikis: $active    router pid $routerPid" Green
    }

    $i = 0
    foreach ($h in @(Hosts)) {
        $port = $BasePort + $i
        $pid_ = Listening $port
        if ($pid_ -and (Is-Tunnel $port)) {
            Say ("  {0,-22} 127.0.0.1:{1}  tunel acik  pid {2}" -f $h, $port, $pid_) Green
        } elseif ($pid_) {
            Say ("  {0,-22} 127.0.0.1:{1}  port dolu (baska surec)" -f $h, $port) Red
        } else {
            Say ("  {0,-22} 127.0.0.1:{1}  tunel kapali" -f $h, $port) DarkGray
        }
        $i++
    }
    $gatePid = Listening $Config.gatePort
    $gateUp = if ($gatePid) { Get-Json "http://127.0.0.1:$($Config.gatePort)/health" } else { $null }
    if ($gatePid -and $gateUp -and $gateUp.upstream) {
        Say ("  {0,-22} acik  pid {1}  http://127.0.0.1:{2}" -f 'modelgate', $gatePid, $Config.gatePort) Green
    } elseif ($gatePid) {
        Say ("  {0,-22} port {1} dolu (modelgate degil)" -f 'modelgate', $Config.gatePort) Red
    } else {
        Say ("  {0,-22} kapali" -f 'modelgate') DarkGray
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
    Say 'istekler  (son gelen ustte, router gunlugu)' Cyan
    if ($routerPid -and -not $recent) {
        Say '  router eski surum - [X] sonra [A] ile yeniden baslatin' Yellow
    }
    $rows = @()
    if ($recent -and $recent.rows) { $rows = @($recent.rows) }
    $fresh = @($rows | Sort-Object t -Descending)
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
    Say '[A] ac   [K] tunelleri kapat   [X] her sey   [Z] modelgate' Yellow
    Say '[V] cikis sec   [D] direct   [N] sonraki   [Y] ayarlar   [Q] cik' Yellow
    End-Frame

    $deadline = (Get-Date).AddSeconds($Config.refreshSec)
    $key = $null
    while ((Get-Date) -lt $deadline) {
        if ([Console]::KeyAvailable) { $key = [Console]::ReadKey($true); break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $key) { continue }

    switch ($key.Key) {
        'A' { Start-Pool }
        'K' { Stop-Pool }
        'X' { Stop-All }
        'Z' { if (Listening $Config.gatePort) { Stop-Gate } else { Start-Gate; Start-Sleep -Seconds 2 } }
        'D' {
            if (-not (Listening $RouterPort)) { Say 'router kapali' Red; Start-Sleep -Seconds 1 }
            else { Post-Json '/use' '{"name":"direct"}' | Out-Null }
        }
        'V' {
            $names = @()
            if ($status -and $status.upstreams) { $names = @($status.upstreams | ForEach-Object { $_.name }) }
            if (-not $names) { Say 'router kapali' Red; Start-Sleep -Seconds 1 }
            else {
                $script:forceClear = $true
                Write-Host ''
                for ($j = 0; $j -lt $names.Count; $j++) { Write-Host ("  [{0}] {1}" -f ($j + 1), $names[$j]) -ForegroundColor Gray }
                $pick = Read-Host 'cikis numarasi'
                if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $names.Count) {
                    Post-Json '/use' ('{"name":"' + $names[([int]$pick - 1)] + '"}') | Out-Null
                }
            }
        }
        'N' { if (Listening $RouterPort) { Post-Json '/next' '{}' | Out-Null } else { Say 'router kapali' Red; Start-Sleep -Seconds 1 } }
        'Y' { Show-Settings }
        'Q' { return }
    }
}
