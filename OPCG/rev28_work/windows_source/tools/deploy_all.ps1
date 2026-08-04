# deploy_all.ps1 - canon -> every distribution copy, FULL mirror of script/*.lua + cdb.
#
# Partial per-file deploys mixed engine generations across copies (2026-07-16:
# the stale-queue client + the initial-drop fossil card made "fixed" effects
# behave like their old selves at the table). Always ship the whole set.
#
# Run:  powershell -NoProfile -File tools\deploy_all.ps1
# After deploying, push E:\github\OPTCG yourself, and run E:\Multiroptcg-data\적용하기.bat
# (or just restart the server) to make the drop folder live.

$ErrorActionPreference = "Stop"
$src = "F:\edopcg_CODEX_INTEGRATED_20260701_FINAL_EDIT_BY_CLAUDE_FABLE\bin\release\expansions"

# target script dir, target cdb path (empty = skip cdb)
$targets = @(
    @{ name = "OPTCG repo (client auto-update)"; script = "E:\github\OPTCG\script";                       cdb = "E:\github\OPTCG\cards-opcg.cdb" },
    @{ name = "server drop folder";              script = "E:\Multiroptcg-data\script";                   cdb = "E:\Multiroptcg-data\cards-opcg.cdb" },
    @{ name = "local built client";              script = "F:\edopro\bin\release\expansions\script";      cdb = "F:\edopro\bin\release\expansions\cards-opcg.cdb" },
    @{ name = "optcg-script repo";               script = "E:\github\optcg-script\expansions\script";     cdb = "E:\github\optcg-script\expansions\cards-opcg.cdb" },
    @{ name = "real client (fossil incident 2026-08-03)"; script = "E:\dfdffsdfe\원배포\expansions\script"; cdb = "E:\dfdffsdfe\원배포\expansions\cards-opcg.cdb" }
)

function Get-LuaFingerprint([string]$dir) {
    $hashes = Get-ChildItem (Join-Path $dir "*.lua") | Sort-Object Name |
        Get-FileHash -Algorithm MD5 | ForEach-Object { $_.Hash }
    $joined = [Text.Encoding]::UTF8.GetBytes(($hashes -join "`n"))
    $md5 = [Security.Cryptography.MD5]::Create()
    ([BitConverter]::ToString($md5.ComputeHash($joined)) -replace "-", "").ToLower()
}

# canon fingerprint counts ONLY the opcg_/c* card+runtime set so the standard
# EDOPro scripts living next to them in the targets don't skew the comparison
function Get-OpcgFingerprint([string]$dir) {
    $files = Get-ChildItem (Join-Path $dir "*.lua") | Where-Object {
        $_.Name -like "opcg_*.lua" -or $_.Name -like "c8*.lua"
    } | Sort-Object Name
    $hashes = $files | Get-FileHash -Algorithm MD5 | ForEach-Object { $_.Hash }
    $joined = [Text.Encoding]::UTF8.GetBytes(($hashes -join "`n"))
    $md5 = [Security.Cryptography.MD5]::Create()
    "{0} ({1} files)" -f ([BitConverter]::ToString($md5.ComputeHash($joined)) -replace "-", "").ToLower(), $files.Count
}

$canonFp = Get-OpcgFingerprint (Join-Path $src "script")
Write-Host ("canon  | {0}" -f $canonFp)

foreach ($t in $targets) {
    if (-not (Test-Path $t.script)) { Write-Host ("SKIP (missing): {0}" -f $t.name); continue }
    Copy-Item (Join-Path $src "script\opcg_*.lua") $t.script -Force
    Copy-Item (Join-Path $src "script\c8*.lua") $t.script -Force
    # 삭제 전파: 캐논에서 사라진 opcg_/c8* 파일은 타깃에서도 걷는다
    # (2026-08-03 동일 일러 별쇄 숙청 때 미러들에 유령 파일이 남던 결함)
    $canonNames = @{}
    Get-ChildItem (Join-Path $src "script") -Filter *.lua | Where-Object {
        $_.Name -like "opcg_*.lua" -or $_.Name -like "c8*.lua"
    } | ForEach-Object { $canonNames[$_.Name] = $true }
    Get-ChildItem $t.script -Filter *.lua | Where-Object {
        ($_.Name -like "opcg_*.lua" -or $_.Name -like "c8*.lua") -and (-not $canonNames.ContainsKey($_.Name))
    } | Remove-Item -Force
    if ($t.cdb) { Copy-Item (Join-Path $src "cards-opcg.cdb") $t.cdb -Force }
    $fp = Get-OpcgFingerprint $t.script
    $ok = if ($fp -eq $canonFp) { "OK" } else { "MISMATCH!" }
    Write-Host ("{0,-9}| {1} <- {2}" -f $ok, $fp, $t.name)
}

# core dll: the OPTCG repo serves has_core clients whose configs disagree on
# core_path ("" vs "bin") - keep the CURRENT dll at BOTH paths, always.
$coreSrc = Join-Path (Split-Path $src -Parent) "ocgcore.dll"
if (Test-Path $coreSrc) {
    $coreMd5 = (Get-FileHash $coreSrc -Algorithm MD5).Hash.ToLower()
    foreach ($dst in @("E:\github\OPTCG\ocgcore.dll", "E:\github\OPTCG\bin\ocgcore.dll")) {
        $dir = Split-Path $dst -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        Copy-Item $coreSrc $dst -Force
    }
    Write-Host ("core     | {0} -> OPTCG repo root + bin (has_core dual path)" -f $coreMd5)
}

Write-Host ""
Write-Host "next: push E:\github\OPTCG (commit first), then E:\Multiroptcg-data\적용하기.bat or server restart."
