# ============================================================
#  OPCG 동기화 + 게임 폴더 직결 배포
#
#  1) sync-opcg.ps1 실행 (GitHub 최신 받기)
#  2) 동기화된 expansions(스크립트/카드DB)를 기존 deploy_all.ps1과
#     같은 방식(전체 미러 + 유령 파일 정리)으로 배포처에 꽂는다
#  3) 새 카드 이미지(pics)를 이미지 폴더가 있는 배포처에 추가한다
#
#  배포처는 tools/deploy_all.ps1의 타깃 + 캐논(F: CODEX)을 그대로 따름.
#  없는 폴더는 건너뛴다. ocgcore.dll은 건드리지 않는다(카드 데이터만).
#  서버 반영(E:\Multiroptcg-data\적용하기.bat)과 OPTCG repo push는
#  기존대로 수동 - 마지막에 안내를 출력한다.
#
#  사용법: 리포 루트의 sync-and-deploy.bat 더블클릭
#          (동기화 없이 배포만: scripts\deploy-opcg.ps1 -SkipSync)
# ============================================================

param(
    [switch]$SkipSync
)

$RepoDir = Split-Path -Parent $PSScriptRoot
$SrcExp  = Join-Path $RepoDir "OPCG\rev28_work\windows_source\bin\release\expansions"
$SrcPics = Join-Path $RepoDir "OPCG\rev28_work\windows_source\bin\release\pics"

# 이 컴퓨터의 작업 폴더 (동기화 스크립트와 같은 규칙으로 찾음)
$WorkDir = "C:\Users\정민혁\Documents\OPCG"
if (-not (Test-Path $WorkDir)) {
    $docsOpcg = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "OPCG"
    if (Test-Path $docsOpcg) { $WorkDir = $docsOpcg }
}
# 이 컴퓨터에 있는 게임 클라이언트 (작업 폴더 안 CODEX 통합본)
$CodexRelease = Join-Path $WorkDir "edopcg_CODEX_INTEGRATED_20260701_FINAL_EDIT_BY_CLAUDE_FABLE\bin\release"

function Fail([string]$Msg) {
    Write-Host ""
    Write-Host "=======================================" -ForegroundColor Red
    Write-Host "  배포 실패" -ForegroundColor Red
    Write-Host "=======================================" -ForegroundColor Red
    Write-Host $Msg -ForegroundColor Red
    Write-Host ""
    Write-Host "이 창의 내용을 복사해서 Claude에게 붙여넣으면 해결 방법을 알려줍니다."
    exit 1
}

# 1) 동기화 먼저
if (-not $SkipSync) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "sync-opcg.ps1")
    if ($LASTEXITCODE -ne 0) {
        Fail "동기화가 실패해서 배포를 중단했습니다. 위쪽 동기화 오류를 먼저 해결하세요."
    }
}

if (-not (Test-Path (Join-Path $SrcExp "cards-opcg.cdb"))) {
    Fail "동기화된 카드DB를 찾을 수 없습니다: $SrcExp`n동기화가 정상적으로 끝났는지 확인하세요."
}

Write-Host ""
Write-Host "=== 게임 폴더 직결 배포 시작 ==="
Write-Host "소스: $SrcExp"

# 배포처: 이 컴퓨터의 게임 클라이언트 + tools/deploy_all.ps1의 타깃(다른 컴퓨터, 없으면 건너뜀)
$Targets = @(
    @{ name = "이 컴퓨터 CODEX 클라이언트";     script = (Join-Path $CodexRelease "expansions\script"); cdb = (Join-Path $CodexRelease "expansions\cards-opcg.cdb") },
    @{ name = "캐논 (F: CODEX)";               script = "F:\edopcg_CODEX_INTEGRATED_20260701_FINAL_EDIT_BY_CLAUDE_FABLE\bin\release\expansions\script"; cdb = "F:\edopcg_CODEX_INTEGRATED_20260701_FINAL_EDIT_BY_CLAUDE_FABLE\bin\release\expansions\cards-opcg.cdb" },
    @{ name = "OPTCG repo (클라 자동업데이트)"; script = "E:\github\OPTCG\script";                     cdb = "E:\github\OPTCG\cards-opcg.cdb" },
    @{ name = "서버 드롭 폴더";                 script = "E:\Multiroptcg-data\script";                 cdb = "E:\Multiroptcg-data\cards-opcg.cdb" },
    @{ name = "로컬 빌드 클라이언트";           script = "F:\edopro\bin\release\expansions\script";    cdb = "F:\edopro\bin\release\expansions\cards-opcg.cdb" },
    @{ name = "optcg-script repo";              script = "E:\github\optcg-script\expansions\script";   cdb = "E:\github\optcg-script\expansions\cards-opcg.cdb" },
    @{ name = "실배포 클라이언트";              script = "E:\dfdffsdfe\원배포\expansions\script";      cdb = "E:\dfdffsdfe\원배포\expansions\cards-opcg.cdb" }
)

# 캐논 파일명 집합 (전체 미러 + 유령 파일 정리용 - deploy_all.ps1과 동일 방식)
$canonNames = @{}
Get-ChildItem (Join-Path $SrcExp "script") -Filter *.lua | Where-Object {
    $_.Name -like "opcg_*.lua" -or $_.Name -like "c8*.lua"
} | ForEach-Object { $canonNames[$_.Name] = $true }
Write-Host ("배포할 카드 스크립트: {0}개 + cards-opcg.cdb" -f $canonNames.Count)

$done = 0
foreach ($t in $Targets) {
    if (-not (Test-Path $t.script)) {
        Write-Host ("  건너뜀 (폴더 없음): {0}" -f $t.name) -ForegroundColor Yellow
        continue
    }
    Copy-Item (Join-Path $SrcExp "script\opcg_*.lua") $t.script -Force
    Copy-Item (Join-Path $SrcExp "script\c8*.lua") $t.script -Force
    Get-ChildItem $t.script -Filter *.lua | Where-Object {
        ($_.Name -like "opcg_*.lua" -or $_.Name -like "c8*.lua") -and (-not $canonNames.ContainsKey($_.Name))
    } | Remove-Item -Force
    if ($t.cdb) { Copy-Item (Join-Path $SrcExp "cards-opcg.cdb") $t.cdb -Force }
    $n = (Get-ChildItem $t.script -Filter "c8*.lua").Count + (Get-ChildItem $t.script -Filter "opcg_*.lua").Count
    if ($n -eq $canonNames.Count) {
        Write-Host ("  OK: {0} ({1}개 일치)" -f $t.name, $n) -ForegroundColor Green
        $done++
    } else {
        Write-Host ("  경고: {0} - 파일 수 불일치 (캐논 {1} vs 타깃 {2})" -f $t.name, $canonNames.Count, $n) -ForegroundColor Yellow
    }
}

# 새 카드 이미지 배포 (pics 폴더가 있는 곳에만, 추가/갱신만 - 삭제 없음)
$PicsTargets = @(
    (Join-Path $CodexRelease "pics"),
    "F:\edopcg_CODEX_INTEGRATED_20260701_FINAL_EDIT_BY_CLAUDE_FABLE\bin\release\pics",
    "F:\edopro\bin\release\pics",
    "E:\dfdffsdfe\원배포\pics",
    "E:\github\OPTCG\pics"
)
$picsFiles = @(Get-ChildItem -Path $SrcPics -Filter *.jpg -ErrorAction SilentlyContinue)
if ($picsFiles.Count -gt 0) {
    Write-Host ("새 카드 이미지 {0}장 배포:" -f $picsFiles.Count)
    foreach ($p in $PicsTargets) {
        if (-not (Test-Path $p)) {
            Write-Host ("  건너뜀 (폴더 없음): {0}" -f $p) -ForegroundColor Yellow
            continue
        }
        Copy-Item (Join-Path $SrcPics "*.jpg") $p -Force
        Write-Host ("  OK: {0}" -f $p) -ForegroundColor Green
    }
}

Write-Host ""
if ($done -eq 0) {
    Fail ("배포된 곳이 한 군데도 없습니다.`n" +
          "- 이 컴퓨터의 게임 폴더를 못 찾았습니다: $CodexRelease`n" +
          "- 게임을 실행하는 실제 폴더 경로(게임 바로가기 우클릭 > 파일 위치)를 Claude에게 알려주세요.")
}
Write-Host ("=== 배포 완료: {0}곳 반영 ===" -f $done) -ForegroundColor Green
Write-Host "참고: rev28_work\windows_source 클라이언트는 동기화 단계에서 이미 갱신됩니다."

# OPTCG repo 자동 커밋/push - 카드 데이터 경로만 (코어 dll/exe/update.json 제외)
# (사용자 승인 2026-08-04: 코어 외에는 확인 없이 리포 반영·배포)
$optcg = "E:\github\OPTCG"
if ((Test-Path (Join-Path $optcg ".git")) -and (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "OPTCG repo 커밋/push 중..."
    git -C $optcg add -- script cards-opcg.cdb 2>$null
    if (Test-Path (Join-Path $optcg "pics")) { git -C $optcg add -- pics 2>$null }
    git -C $optcg diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm"
        git -C $optcg commit -m "카드 데이터 업데이트 (sync-and-deploy $stamp)"
        git -C $optcg push
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  OK: OPTCG repo push 완료 (클라 자동업데이트 배포됨)" -ForegroundColor Green
        } else {
            Write-Host "  경고: OPTCG repo push 실패 - commit은 저장됨. 수동으로 push하거나 Claude에게 알려주세요." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  OPTCG repo: 새 변경 없음"
    }
} else {
    Write-Host "  건너뜀: OPTCG repo 없음 또는 git 미설치" -ForegroundColor Yellow
}

# 서버 적용하기.bat 자동 실행 (별도 창으로 띄움 - 내부에 pause가 있어도 안 막히게)
$apply = "E:\Multiroptcg-data\적용하기.bat"
if (Test-Path $apply) {
    Write-Host "서버 적용하기.bat 창을 띄웁니다..."
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$apply`"" -WorkingDirectory (Split-Path $apply)
    Write-Host "  새로 뜬 창에서 완료를 확인하세요." -ForegroundColor Green
} else {
    Write-Host "  건너뜀: 적용하기.bat 없음 - 서버 반영은 서버 재시작으로 하세요." -ForegroundColor Yellow
}
