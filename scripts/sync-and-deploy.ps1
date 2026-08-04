# ============================================================
#  동기화 + 배포 오케스트레이터
#  1) sync-opcg.ps1 실행 (GitHub 최신 받기 - 배포 스크립트 자신도 갱신됨)
#  2) 갱신된 deploy-opcg.ps1을 새로 읽어 배포 실행
#  이 구조라서 스크립트 수정이 항상 "이번 실행"에 바로 반영된다.
# ============================================================

& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "sync-opcg.ps1")
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "동기화가 실패해서 배포를 진행하지 않습니다. 위 오류를 확인하세요." -ForegroundColor Red
    exit 1
}

& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "deploy-opcg.ps1") -SkipSync
exit $LASTEXITCODE
