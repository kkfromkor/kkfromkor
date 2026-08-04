# OPCGPro exe release helper.
# 1) zips bin\release\ygopro.exe + ocgcore.dll into release_out\OPCGPro-update.zip
# 2) writes E:\github\OPTCG\update.json (manifest the client polls at boot)
# 3) prints the remaining manual steps (Releases upload + push = user's call)
#
# Per release: bump OPCG_UPDATE_REVISION in gframe\config.h, rebuild, run this.
param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$ManifestRepo = 'E:\github\OPTCG',
    [string]$AssetName = 'OPCGPro-update.zip'
)
$ErrorActionPreference = 'Stop'

$bin = Join-Path $RepoRoot 'bin\release'
$exe = Join-Path $bin 'ygopro.exe'
$core = Join-Path $bin 'ocgcore.dll'
if (-not (Test-Path $exe)) { throw "missing $exe" }
if (-not (Test-Path $core)) { throw "missing $core" }

$rev = $null
$configLine = Select-String -Path (Join-Path $RepoRoot 'gframe\config.h') -Pattern 'OPCG_UPDATE_REVISION\s+(\d+)'
if ($configLine) { $rev = [int]$configLine.Matches[0].Groups[1].Value }
if ($null -eq $rev) { throw 'OPCG_UPDATE_REVISION not found in gframe\config.h' }

$manifestPath = Join-Path $ManifestRepo 'update.json'
if (Test-Path $manifestPath) {
    $old = (Get-Content $manifestPath -Raw | ConvertFrom-Json)
    $oldRev = ($old | ForEach-Object { $_.rev } | Measure-Object -Maximum).Maximum
    if ($oldRev -eq $rev) {
        Write-Warning "update.json rev already $rev - new exe release needs a bumped OPCG_UPDATE_REVISION (config.h) + rebuild."
    }
}

$outDir = Join-Path $RepoRoot 'release_out'
New-Item -ItemType Directory -Force $outDir | Out-Null
$zip = Join-Path $outDir $AssetName
if (Test-Path $zip) { Remove-Item $zip -Force }

# 스테이징 폴더에 구조를 잡고 통째로 압축한다. exe/dll은 루트, 커스텀 자산
# (반다이 공홈에 없는 우리 그림 - DON!! 카드 등)은 pics\ 하위로 넣어야
# UnzipArchive가 ./pics 로 풀어준다.
$stage = Join-Path $outDir 'stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item $exe $stage
Copy-Item $core $stage
$stagePics = Join-Path $stage 'pics'
New-Item -ItemType Directory -Force $stagePics | Out-Null
# 공홈이 커버 못 하는 커스텀 그림 목록(코드). DON!! 카드가 핵심.
$customArt = @(879999997, 879999998, 879999999)
$bundled = 0
foreach ($c in $customArt) {
    foreach ($ext in @('.jpg', '.png')) {
        $src = Join-Path $bin "pics\$c$ext"
        if (Test-Path $src) { Copy-Item $src $stagePics; $bundled++ }
    }
}
# Bundle config\strings.conf so runtime label edits (e.g. the deck-editor
# "Leader:" label) reach clients with the exe - the updater unzips paths as-is,
# so this lands at .\config\strings.conf. It differs from a client's copy only
# by our own OPCG label lines.
$stageConfig = Join-Path $stage 'config'
New-Item -ItemType Directory -Force $stageConfig | Out-Null
$stringsSrc = Join-Path $bin 'config\strings.conf'
if (Test-Path $stringsSrc) { Copy-Item $stringsSrc $stageConfig; Write-Output "bundled config: strings.conf" }
else { Write-Warning "missing $stringsSrc - strings.conf not bundled" }

Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Remove-Item $stage -Recurse -Force
Write-Output "bundled custom art: $bundled file(s)"

$md5 = (Get-FileHash $zip -Algorithm MD5).Hash.ToLower()

# Ship the zip THROUGH the data repo (raw URL), not GitHub Releases: the
# release-asset upload needs a browser file dialog (automation-hostile), while
# committing to the repo pushes with one GitHub Desktop Ctrl+P. Clients
# download from raw.githubusercontent the same way they fetch update.json.
# The filename carries the rev (…-r18.zip): a brand-new raw path can never be
# served stale from the CDN cache, so manifest/zip can't disagree (no
# "unlucky boot needs a second try"). Old rev zips are pruned from the
# worktree to keep checkouts lean (history keeps them anyway).
$repoRelease = Join-Path $ManifestRepo 'release'
New-Item -ItemType Directory -Force $repoRelease | Out-Null
$revName = "OPCGPro-update-r$rev.zip"
Get-ChildItem $repoRelease -Filter 'OPCGPro-update*.zip' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne $revName } | Remove-Item -Force
Copy-Item $zip (Join-Path $repoRelease $revName) -Force
$manifest = @(
    [ordered]@{
        name = $revName
        url  = "https://raw.githubusercontent.com/ClaudeFable5/OPTCG/main/release/$revName"
        md5  = $md5
        rev  = $rev
    }
)

# NOTE: never add card-art assets here. Shipping Bandai card images from our
# GitHub is copyright redistribution (user ruling 2026-07-20, parallels asset
# pulled from v-rev13). Only our own art may ride along ($customArt above).
# CDB-vs-official art mismatches: tools\bundled_pics.txt is the inventory;
# fix = number remap table (text data), not image bundling.
$json = ConvertTo-Json $manifest -Depth 4
# client expects a top-level array; ConvertTo-Json unwraps single-element arrays
if (-not $json.TrimStart().StartsWith('[')) { $json = "[`n$json`n]" }
[IO.File]::WriteAllText($manifestPath, $json)

Write-Output "zip     : $zip"
Write-Output "md5     : $md5"
Write-Output "rev     : $rev"
Write-Output "manifest: $manifestPath"
Write-Output ""
Write-Output "manual steps left:"
Write-Output " 1) cd $ManifestRepo; git add -A update.json release; git commit"
Write-Output " 2) push via GitHub Desktop (Ctrl+P) - no GitHub Releases page needed"
Write-Output "    (clients built with a lower rev will see the update button on next boot)"
exit 0
