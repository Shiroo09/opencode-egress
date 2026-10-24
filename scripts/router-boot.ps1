# opencode 127.0.0.1:8888 proxy'sini kullanır; router yoksa hiçbir istek çıkmaz.
# Bu yüzden router oturum açılışında kendi başına ayağa kalkar.
# Tüneller kapalıyken ilk bağlantı anında ECONNREFUSED alıp `direct`e düşer.
# Zaten dinliyorsa hiçbir şey yapmaz (panel [A] ile çakışmaz).
# shortcut: hosts dosyası değişirse router eski listeyle kalır, yeniden başlat.
$ErrorActionPreference = 'SilentlyContinue'
$Root = Split-Path -Parent $PSScriptRoot
$ConfigDir = Join-Path $env:USERPROFILE '.config\opencode-egress'
$RouterJs = Join-Path $PSScriptRoot 'egress-router.mjs'
$StateFile = Join-Path $ConfigDir 'router-state.json'
$HostsFile = Join-Path $ConfigDir 'hosts'
$RouterPort = 8888
$ControlPort = 8899
$BasePort = 8891

$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { exit 1 }

# OpenCode 2 dropped the plugin hook, so rotation lives in this watcher; it
# survives panel restarts and serves every client of the shared server.
function Watch-Running {
    $p = Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
        Where-Object { $_.CommandLine -match 'egress-watch\.mjs' } | Select-Object -First 1
    return [bool]$p
}
if (-not (Watch-Running)) {
    Start-Process $node -WindowStyle Hidden -ArgumentList (Join-Path $PSScriptRoot 'egress-watch.mjs')
}

# Claude Code'un compaction yolu modeli kendi katalogunda arar; ccgate ada
# çevirir. Kimlik ~/.claude/ccgate.json'dan okunur; yoksa başlatılmaz.
function Ccgate-Running {
    $p = Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
        Where-Object { $_.CommandLine -match 'ccgate\.mjs' } | Select-Object -First 1
    return [bool]$p
}
if (-not (Ccgate-Running) -and (Test-Path (Join-Path $env:USERPROFILE '.claude\ccgate.json'))) {
    Start-Process $node -WindowStyle Hidden -ArgumentList (Join-Path $PSScriptRoot 'ccgate.mjs')
}

if (Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $RouterPort -State Listen -ErrorAction SilentlyContinue) { exit 0 }

$up = @()
$i = 0
if (Test-Path $HostsFile) {
    Get-Content $HostsFile | ForEach-Object { ($_ -replace '#.*', '').Trim() } | Where-Object { $_ } | ForEach-Object {
        $up += '--upstream'; $up += "$_=127.0.0.1:$($BasePort + $i)"; $i++
    }
}
$up += '--upstream', 'direct=direct'

Start-Process $node -WindowStyle Hidden -ArgumentList (@(
        $RouterJs, '--port', $RouterPort, '--control', $ControlPort, '--state', $StateFile) + $up)
