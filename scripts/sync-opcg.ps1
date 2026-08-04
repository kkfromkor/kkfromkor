# ============================================================
#  OPCG 작업 폴더 동기화
#
#  PC 작업 폴더  : C:\Users\정민혁\Documents\OPCG
#  리포지토리 쪽 : <리포 루트>\OPCG
#
#  사용법 (보통은 리포 루트의 sync-opcg.bat 더블클릭으로 실행)
#    scripts\sync-opcg.ps1              양방향 동기화 + commit/push (기본)
#    scripts\sync-opcg.ps1 -Mode pull   받기만 (리포 -> 작업 폴더)
#    scripts\sync-opcg.ps1 -Mode push   보내기만 (작업 폴더 -> 리포)
#    scripts\sync-opcg.ps1 -NoGit       git pull/push 없이 파일 복사만
# ============================================================

param(
    [ValidateSet("sync", "pull", "push")]
    [string]$Mode = "sync",

    [switch]$NoGit
)

$ErrorActionPreference = "Stop"

# ---- 설정: 작업 폴더 위치가 바뀌면 이 줄만 고치면 됩니다 ----
$WorkDir = "C:\Users\정민혁\Documents\OPCG"
# ------------------------------------------------------------

$RepoDir     = Split-Path -Parent $PSScriptRoot
$RepoSyncDir = Join-Path $RepoDir "OPCG"

# 문서 폴더가 OneDrive 등으로 옮겨져 있으면 그쪽의 OPCG 폴더를 대신 사용
if (-not (Test-Path $WorkDir)) {
    $docsOpcg = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "OPCG"
    if (Test-Path $docsOpcg) { $WorkDir = $docsOpcg }
}

$useGit = -not $NoGit
if ($useGit -and -not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Warning "git을 찾을 수 없어 파일 복사만 진행합니다. (설치: https://git-scm.com/download/win)"
    $useGit = $false
}

# robocopy 옵션
#   /E   하위 폴더 포함(빈 폴더 포함)   /XO  대상 파일이 더 최신이면 덮어쓰지 않음
#   /FFT 시간 오차 2초 허용             /MAX GitHub 제한(100MB)에 걸릴 큰 파일 제외
$RoboOpts = @(
    "/E", "/XO", "/FFT", "/MAX:95000000",
    "/R:2", "/W:2", "/NJH", "/NJS", "/NDL", "/NP",
    "/XD", ".git",
    "/XF", "Thumbs.db", "desktop.ini", "~$*", "*.tmp"
)

function Invoke-Robocopy([string]$From, [string]$To, [string]$Label) {
    if (-not (Test-Path $From)) { return }
    New-Item -ItemType Directory -Force -Path $To | Out-Null
    & robocopy $From $To @RoboOpts
    if ($LASTEXITCODE -ge 8) {
        throw "$Label 복사 중 오류가 났습니다 (robocopy 종료 코드 $LASTEXITCODE)"
    }
}

Write-Host ""
Write-Host "=== OPCG 동기화 시작 (모드: $Mode) ==="
Write-Host "작업 폴더 : $WorkDir"
Write-Host "리포 폴더 : $RepoSyncDir"
Write-Host ""

if (-not (Test-Path $WorkDir)) {
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    Write-Host "* 작업 폴더가 없어서 새로 만들었습니다: $WorkDir"
}

# 1) GitHub에서 최신 내용 받기
if ($useGit) {
    Write-Host "[1/4] GitHub에서 받는 중 (git pull)..."
    git -C $RepoDir -c pull.rebase=false pull --no-edit
    if ($LASTEXITCODE -ne 0) {
        if (git -C $RepoDir ls-files -u) {
            git -C $RepoDir merge --abort
            Write-Warning "GitHub 쪽 변경과 충돌이 나서 병합을 취소했습니다. 이번 실행에서는 GitHub 변경을 받지 못합니다."
        } else {
            Write-Warning "git pull 실패 - 인터넷 연결을 확인하세요. 파일 복사는 계속합니다."
        }
    }
    if (git -C $RepoDir ls-files -u) {
        throw "리포지토리에 해결되지 않은 충돌이 있습니다. 리포 폴더에서 'git status'를 확인하거나 Claude에게 물어보세요."
    }
} else {
    Write-Host "[1/4] git pull 건너뜀"
}

# 2) 리포 -> 작업 폴더 (다른 곳에서 바뀐 파일 받기)
if ($Mode -ne "push") {
    Write-Host "[2/4] 리포 -> 작업 폴더 복사..."
    Invoke-Robocopy $RepoSyncDir $WorkDir "리포 -> 작업 폴더"
} else {
    Write-Host "[2/4] 건너뜀 (push 모드)"
}

# 3) 작업 폴더 -> 리포 (이 컴퓨터에서 작업한 파일 보내기)
if ($Mode -ne "pull") {
    Write-Host "[3/4] 작업 폴더 -> 리포 복사..."
    Invoke-Robocopy $WorkDir $RepoSyncDir "작업 폴더 -> 리포"
} else {
    Write-Host "[3/4] 건너뜀 (pull 모드)"
}

# 4) 변경분 commit & push
if ($useGit -and $Mode -ne "pull") {
    Write-Host "[4/4] GitHub로 올리는 중 (commit & push)..."
    git -C $RepoDir add -A -- OPCG
    git -C $RepoDir diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        if (-not (git -C $RepoDir config user.email)) {
            git -C $RepoDir config user.name  "kkfromkor"
            git -C $RepoDir config user.email "kkfromkor@users.noreply.github.com"
        }
        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm"
        git -C $RepoDir commit -m "sync: OPCG 작업 폴더 ($stamp)"

        $pushed = $false
        foreach ($delay in 0, 2, 4, 8, 16) {
            if ($delay -gt 0) {
                Write-Warning "push 실패 - ${delay}초 후 다시 시도합니다..."
                Start-Sleep -Seconds $delay
            }
            git -C $RepoDir push
            if ($LASTEXITCODE -eq 0) { $pushed = $true; break }
        }
        if (-not $pushed) {
            Write-Warning "push에 계속 실패했습니다. commit은 저장돼 있으니 다음 동기화 때 다시 올라갑니다."
        }
    } else {
        Write-Host "  올릴 변경 사항이 없습니다."
    }
} elseif ($Mode -eq "pull") {
    Write-Host "[4/4] 건너뜀 (pull 모드)"
} else {
    Write-Host "[4/4] git push 건너뜀"
}

Write-Host ""
Write-Host "=== 동기화 완료 ==="
