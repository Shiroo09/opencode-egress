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

if (Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $RouterPort -State Listen -ErrorAction SilentlyContinue) { exit 0 }

$up = @()
$i = 0
if (Test-Path $HostsFile) {
    Get-Content $HostsFile | ForEach-Object { ($_ -replace '#.*', '').Trim() } | Where-Object { $_ } | ForEach-Object {
        $up += '--upstream'; $up += "$_=127.0.0.1:$($BasePort + $i)"; $i++
    }
}
$up += '--upstream', 'direct=direct'

$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { exit 1 }
Start-Process $node -WindowStyle Hidden -ArgumentList (@(
        $RouterJs, '--port', $RouterPort, '--control', $ControlPort, '--state', $StateFile) + $up)
