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

# 배포처: tools/deploy_all.ps1의 타깃 그대로 + 캐논(F: CODEX)
$Targets = @(
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
    Fail ("배포된 곳이 한 군데도 없습니다. 배포처 드라이브(E:, F:)가 연결돼 있는지 확인하세요.`n" +
          "배포처 경로가 바뀌었다면 이 창 내용을 Claude에게 알려주세요.")
}
Write-Host ("=== 배포 완료: {0}곳 반영 ===" -f $done) -ForegroundColor Green
Write-Host ""
Write-Host "남은 수동 단계 (기존 방식 그대로):"
Write-Host "  1) E:\github\OPTCG 커밋 & push (클라 자동업데이트 배포용)"
Write-Host "  2) E:\Multiroptcg-data\적용하기.bat 실행 또는 서버 재시작"
