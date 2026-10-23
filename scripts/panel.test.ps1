# panel.ps1 onay mantigini dogrular; ekran cizmez (self-test guard).
# Calistir: powershell -NoProfile -File scripts/panel.test.ps1
$env:OPENCODE_EGRESS_SELFTEST = '1'
. "$PSScriptRoot/panel.ps1"

function Read-Host { param($Prompt) $script:answer }

function Check($answer, $expected) {
    $script:answer = $answer
    $got = Ask 'test'
    if ($got -ne $expected) { throw "Ask('$answer') beklenen $expected, gelen $got" }
}

Check 'e' $true
Check 'evet' $true
Check 'Y' $true
Check 'h' $false
Check '' $false
Check 'hayir' $false

'panel: onay mantigi OK'
