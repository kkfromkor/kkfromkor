# ============================================================
#  OPCG 작업 폴더 동기화 (v2)
#
#  PC 작업 폴더  : C:\Users\정민혁\Documents\OPCG
#  리포지토리 쪽 : <리포 루트>\OPCG
#
#  사용법 (보통은 리포 루트의 sync-opcg.bat 더블클릭으로 실행)
#    scripts\sync-opcg.ps1              양방향 동기화 + commit/push (기본)
#    scripts\sync-opcg.ps1 -Mode pull   받기만 (리포 -> 작업 폴더)
#    scripts\sync-opcg.ps1 -Mode push   보내기만 (작업 폴더 -> 리포)
#    scripts\sync-opcg.ps1 -NoGit       git pull/push 없이 파일 복사만
#
#  마지막 줄이 초록색 "동기화 성공"이면 GitHub까지 올라간 것이고,
#  빨간색 "동기화 실패"면 올라가지 않은 것입니다.
# ============================================================

param(
    [ValidateSet("sync", "pull", "push")]
    [string]$Mode = "sync",

    [switch]$NoGit
)

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

function Fail([string]$Msg) {
    Write-Host ""
    Write-Host "=======================================" -ForegroundColor Red
    Write-Host "  동기화 실패 - GitHub에 반영되지 않음" -ForegroundColor Red
    Write-Host "=======================================" -ForegroundColor Red
    Write-Host $Msg -ForegroundColor Red
    Write-Host ""
    Write-Host "이 창의 내용을 복사해서 Claude에게 붙여넣으면 해결 방법을 알려줍니다."
    exit 1
}

$useGit = -not $NoGit

if ($useGit) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Fail "git이 설치되어 있지 않습니다. https://git-scm.com/download/win 에서 설치한 뒤 다시 실행해주세요."
    }
    git -C $RepoDir rev-parse --is-inside-work-tree | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Fail ("이 폴더는 git 저장소가 아닙니다: $RepoDir`n" +
              "GitHub에서 ZIP으로 내려받은 폴더에서는 업로드가 되지 않습니다.`n" +
              "PowerShell에서 아래 두 줄을 실행해 git clone으로 다시 받아주세요:`n" +
              '  cd $env:USERPROFILE\Documents' + "`n" +
              "  git clone https://github.com/kkfromkor/kkfromkor.git")
    }
    # 긴 경로(Windows 260자 제한)와 한글 파일명 대응
    git -C $RepoDir config core.longpaths true
    git -C $RepoDir config core.quotepath false
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
    New-Item -ItemType Directory -Force -Path $To -ErrorAction Stop | Out-Null
    & robocopy $From $To @RoboOpts
    if ($LASTEXITCODE -ge 8) {
        Fail "$Label 복사 중 오류가 났습니다 (robocopy 종료 코드 $LASTEXITCODE)"
    }
}

Write-Host ""
Write-Host "=== OPCG 동기화 시작 (모드: $Mode) ==="
Write-Host "작업 폴더 : $WorkDir"
Write-Host "리포 폴더 : $RepoSyncDir"

if (-not (Test-Path $WorkDir)) {
    New-Item -ItemType Directory -Force -Path $WorkDir -ErrorAction Stop | Out-Null
    Write-Host "* 작업 폴더가 없어서 새로 만들었습니다: $WorkDir" -ForegroundColor Yellow
}

$workFiles = (Get-ChildItem -Path $WorkDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
Write-Host "작업 폴더 파일 수: $workFiles"
Write-Host ""
if ($workFiles -eq 0) {
    Write-Host "* 작업 폴더가 비어 있습니다! OPCG 작업 파일들이 위 경로에 있는 게 맞는지 확인하세요." -ForegroundColor Yellow
    Write-Host "  (실제 작업 폴더가 다른 곳이면 scripts\sync-opcg.ps1 상단의 `$WorkDir 경로를 고쳐주세요)" -ForegroundColor Yellow
}

# 1) GitHub에서 최신 내용 받기
if ($useGit) {
    Write-Host "[1/4] GitHub에서 받는 중 (git pull)..."
    git -C $RepoDir -c pull.rebase=false pull --no-edit
    if ($LASTEXITCODE -ne 0) {
        if (git -C $RepoDir ls-files -u) {
            git -C $RepoDir merge --abort
            Write-Host "* GitHub 쪽 변경과 충돌이 나서 병합을 취소했습니다. 이번에는 GitHub 변경을 받지 않고 진행합니다." -ForegroundColor Yellow
        } else {
            Write-Host "* git pull 실패 - 인터넷 연결 문제일 수 있습니다. 계속 진행합니다." -ForegroundColor Yellow
        }
    }
    if (git -C $RepoDir ls-files -u) {
        Fail "리포지토리에 해결되지 않은 충돌이 있습니다. 리포 폴더에서 'git status' 결과를 Claude에게 보여주세요."
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
$pushedOk   = $false
$hadChanges = $false
$ahead      = 0

if ($useGit -and $Mode -ne "pull") {
    Write-Host "[4/4] GitHub로 올리는 중 (commit & push)..."
    git -C $RepoDir add -A -- OPCG
    if ($LASTEXITCODE -ne 0) {
        Fail ("파일을 git에 추가(add)하지 못했습니다. 위쪽의 영어 오류 문구를 확인하세요.`n" +
              "- 'Filename too long'이 보이면: 경로가 긴 파일 때문인데, 방금 설정을 자동으로 켰으니 이 스크립트를 한 번만 더 실행해보세요.`n" +
              "- 'Permission denied'가 보이면: 그 파일을 열어둔 프로그램을 닫고 다시 실행하세요.`n" +
              "- 그 외에는 이 창 내용을 Claude에게 붙여넣어 주세요.")
    }

    $changed = git -C $RepoDir status --porcelain -uall -- OPCG
    git -C $RepoDir diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        $hadChanges = $true
        if (-not (git -C $RepoDir config user.email)) {
            git -C $RepoDir config user.name  "kkfromkor"
            git -C $RepoDir config user.email "kkfromkor@users.noreply.github.com"
        }
        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm"
        git -C $RepoDir commit -m "sync: OPCG 작업 폴더 ($stamp)"
        if ($LASTEXITCODE -ne 0) {
            Fail "commit에 실패했습니다. 위쪽의 오류 내용을 Claude에게 보여주세요."
        }
        $fileCount = ($changed | Measure-Object).Count
        Write-Host "  변경 파일 $fileCount개 commit 완료"
    } elseif ($changed) {
        Fail ("올릴 파일이 분명히 있는데 git add가 아무것도 추가하지 못했습니다.`n" +
              "위쪽에 'Filename too long' 오류가 있으면 이 스크립트를 한 번만 더 실행해보고,`n" +
              "그래도 안 되면 이 창 내용을 Claude에게 붙여넣어 주세요.")
    } else {
        Write-Host "  새로 commit할 변경 파일은 없습니다."
    }

    # 이전 실행에서 push가 실패해 밀려 있는 commit이 있는지 확인
    $aheadRaw = git -C $RepoDir rev-list --count "@{u}..HEAD" 2>$null
    if ($LASTEXITCODE -eq 0 -and $aheadRaw) { $ahead = [int]$aheadRaw }
    if ($ahead -gt 0) { Write-Host "  GitHub로 올릴 commit: $ahead개" }

    foreach ($delay in 0, 2, 4, 8, 16) {
        if ($delay -gt 0) {
            Write-Host "* push 실패 - ${delay}초 후 다시 시도합니다..." -ForegroundColor Yellow
            Start-Sleep -Seconds $delay
        }
        git -C $RepoDir push
        if ($LASTEXITCODE -eq 0) { $pushedOk = $true; break }
    }
} elseif ($Mode -eq "pull") {
    Write-Host "[4/4] 건너뜀 (pull 모드)"
} else {
    Write-Host "[4/4] git push 건너뜀 (-NoGit)"
}

# ---- 최종 결과 ----
Write-Host ""
if ($Mode -eq "pull") {
    Write-Host "=== 동기화 완료 (GitHub에서 받기만 실행) ===" -ForegroundColor Green
} elseif (-not $useGit) {
    Write-Host "=== 파일 복사만 완료 (-NoGit: GitHub에는 올라가지 않음) ===" -ForegroundColor Yellow
} elseif ($pushedOk) {
    if ($hadChanges -or $ahead -gt 0) {
        Write-Host "=== 동기화 성공: GitHub 업로드까지 완료 ===" -ForegroundColor Green
    } else {
        Write-Host "=== 동기화 성공: GitHub와 이미 같은 상태 (새 변경 없음) ===" -ForegroundColor Green
        if ($workFiles -eq 0) {
            Write-Host "단, 작업 폴더가 비어 있어서 올라간 파일도 없습니다. 경로를 확인하세요: $WorkDir" -ForegroundColor Yellow
        }
    }
} else {
    Fail ("GitHub 업로드(push)에 실패했습니다. 파일 복사와 commit은 됐지만 GitHub에는 안 올라갔습니다.`n" +
          "- 실행 중 브라우저로 GitHub 로그인 창이 떴다면: 로그인을 마친 뒤 이 스크립트를 다시 실행하세요.`n" +
          "- 위쪽의 push 오류 메시지(영어 문구)를 Claude에게 붙여넣어 주세요.")
}
