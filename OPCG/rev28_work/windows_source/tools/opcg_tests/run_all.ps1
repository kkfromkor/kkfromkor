param([string]$Repo = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..").Path)

# OPCG 하네스 일괄 러너 — 32비트 PS로 각 하네스를 돌리고 PASS/FAIL 표를 낸다.
# 사용: powershell -File tools\opcg_tests\run_all.ps1
# (개별 하네스가 32비트 전용이므로 이 러너가 SysWOW64 PS를 대신 호출한다)

$ps32 = "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
$harnesses = Get-ChildItem -LiteralPath $PSScriptRoot -Filter "opcg_*_x86.ps1" |
    Where-Object { $_.Name -notmatch "forge" } |  # 리플레이 합성기는 검증용이 아님
    Sort-Object Name

$results = @()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($h in $harnesses) {
    $t0 = $sw.Elapsed
    $out2 = & $ps32 -NoProfile -ExecutionPolicy Bypass -File $h.FullName -Repo $Repo 2>&1
    $out = $out2 -join "`n"
    # 결정적 판정: 하네스의 최종 센티넬 = "<NAME> PASS" / "<NAME> FAIL" 형태의
    # 줄. 그 패턴에 맞는 '마지막' 줄만 신뢰한다(윈도우 join의 스트레이 매칭 배제).
    $sentinel = $out2 | Where-Object { $_ -match '\b(PASS|FAIL)\s*$' } | Select-Object -Last 1
    $verdict =
        if ($sentinel -match '\bPASS\s*$') { "PASS" }
        elseif ($sentinel -match '\bFAIL\s*$') { "FAIL" }
        elseif ($out -match "errors=0" -and $out -notmatch "FAIL") { "OK" }  # 무센티넬 로드-스모크류
        else { "?" }
    $secs = [int]($sw.Elapsed - $t0).TotalSeconds
    $results += [PSCustomObject]@{ Harness = $h.BaseName; Verdict = $verdict; Sec = $secs }
    Write-Host ("{0,-34} {1,-5} {2,3}s" -f $h.BaseName, $verdict, $secs)
}
# 실제 회귀 = FAIL 만. PASS/OK 는 그린, ? 는 사람이 봐야 함.
$fails = @($results | Where-Object { $_.Verdict -eq "FAIL" })
$green = @($results | Where-Object { $_.Verdict -eq "PASS" -or $_.Verdict -eq "OK" })
Write-Host ("-" * 46)
Write-Host ("total {0}  green {1}  FAIL {2}  ? {3}  ({4}s)" -f $results.Count, $green.Count, $fails.Count, (@($results | Where-Object Verdict -eq "?").Count), [int]$sw.Elapsed.TotalSeconds)
if ($fails.Count -gt 0) { Write-Host ("FAIL: " + (($fails | ForEach-Object Harness) -join ", ")) }
if ($fails.Count -gt 0) { exit 1 } else { exit 0 }
