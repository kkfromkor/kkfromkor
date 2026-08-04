# ============================================================
#  OPCG 작업 폴더 동기화 (v5 - 선택 동기화)
#
#  PC 작업 폴더  : C:\Users\정민혁\Documents\OPCG  (전체 약 10GB)
#  리포지토리 쪽 : <리포 루트>\OPCG
#
#  작업 폴더 전체는 GitHub에 올릴 수 없는 크기라서,
#  scripts\sync-include.txt 에 적힌 하위 폴더만 양방향 동기화합니다.
#  대신 매번 전체 파일 목록을 OPCG\_inventory.txt 로 만들어 올리고,
#  Claude가 그 목록을 보고 필요한 폴더를 sync-include.txt에 채웁니다.
#
#  사용법 (보통은 리포 루트의 sync-opcg.bat 더블클릭으로 실행)
#    scripts\sync-opcg.ps1              동기화 + commit/push (기본)
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
$IncludeFile = Join-Path $PSScriptRoot "sync-include.txt"

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

# robocopy 공통 옵션
#   /XO  대상 파일이 더 최신이면 덮어쓰지 않음   /FFT 시간 오차 2초 허용
#   /MAX GitHub 제한(100MB)에 걸릴 큰 파일 제외
$RoboCommon = @(
    "/XO", "/FFT", "/MAX:95000000",
    "/R:2", "/W:2", "/NJH", "/NJS", "/NDL", "/NP",
    "/XD", ".git",
    "/XF", "Thumbs.db", "desktop.ini", "~$*", "*.tmp"
)

function Invoke-Robocopy {
    param(
        [string]$From,
        [string]$To,
        [string]$Label,
        [switch]$Deep,
        [string[]]$ExtraOpts = @()
    )
    if (-not (Test-Path $From)) { return }
    New-Item -ItemType Directory -Force -Path $To -ErrorAction Stop | Out-Null
    $opts = @($RoboCommon) + $ExtraOpts
    if ($Deep) { $opts += "/E" }
    & robocopy $From $To @opts
    if ($LASTEXITCODE -ge 8) {
        Fail "$Label 복사 중 오류가 났습니다 (robocopy 종료 코드 $LASTEXITCODE)"
    }
}

# 동기화할 하위 폴더 목록 읽기
$Includes = @()
if (Test-Path $IncludeFile) {
    $Includes = @(Get-Content -Path $IncludeFile -Encoding UTF8 |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") })
}

Write-Host ""
Write-Host "=== OPCG 동기화 시작 (모드: $Mode) ==="
Write-Host "작업 폴더 : $WorkDir"
Write-Host "리포 폴더 : $RepoSyncDir"
if ($Includes.Count -gt 0) {
    Write-Host "동기화 대상 하위 폴더: $($Includes -join ', ')"
} else {
    Write-Host "동기화 대상 하위 폴더: (아직 없음 - 전체 목록과 루트 낱개 파일만 동기화)"
}

if (-not (Test-Path $WorkDir)) {
    New-Item -ItemType Directory -Force -Path $WorkDir -ErrorAction Stop | Out-Null
    Write-Host "* 작업 폴더가 없어서 새로 만들었습니다: $WorkDir" -ForegroundColor Yellow
}

Write-Host "작업 폴더 전체 파일 목록을 읽는 중... (파일이 많으면 시간이 걸립니다)"
$allFiles  = @(Get-ChildItem -Path $WorkDir -Recurse -File -ErrorAction SilentlyContinue)
$workFiles = $allFiles.Count
$totalMB   = 0
if ($workFiles -gt 0) {
    $totalMB = [math]::Round(($allFiles | Measure-Object -Property Length -Sum).Sum / 1MB)
}
Write-Host "작업 폴더: 파일 ${workFiles}개, 약 ${totalMB}MB"
Write-Host ""
if ($workFiles -eq 0) {
    Write-Host "* 작업 폴더가 비어 있습니다! OPCG 작업 파일들이 위 경로에 있는 게 맞는지 확인하세요." -ForegroundColor Yellow
    Write-Host "  (실제 작업 폴더가 다른 곳이면 scripts\sync-opcg.ps1 상단의 `$WorkDir 경로를 고쳐주세요)" -ForegroundColor Yellow
}

# 1) GitHub에서 최신 내용 받기
if ($useGit) {
    # 이전 전체 동기화 시도가 리포 폴더에 남긴 대용량 사본/commit 정리
    # (작업 폴더 원본은 건드리지 않음 - 리포 쪽 OPCG는 어차피 복사본)
    $repoOpcgSum = (Get-ChildItem -Path $RepoSyncDir -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum
    if ($repoOpcgSum -and ([math]::Round($repoOpcgSum / 1MB) -gt 1500)) {
        Write-Host "* 이전 시도가 리포 폴더에 남긴 대용량 사본을 정리합니다. 몇 분 걸릴 수 있습니다..." -ForegroundColor Yellow
        git -C $RepoDir reset --hard "@{u}"
        git -C $RepoDir clean -fd -- OPCG
        git -C $RepoDir reflog expire --expire=now --all
        git -C $RepoDir gc --prune=now
        Write-Host "* 정리 완료. 계속 진행합니다." -ForegroundColor Yellow
    }
    Write-Host "[1/5] GitHub에서 받는 중 (git pull)..."
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
    # pull로 sync-include.txt가 갱신됐을 수 있으니 다시 읽기
    if (Test-Path $IncludeFile) {
        $Includes = @(Get-Content -Path $IncludeFile -Encoding UTF8 |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith("#") })
    }
} else {
    Write-Host "[1/5] git pull 건너뜀"
}

# 2) 리포 -> 작업 폴더 (다른 곳에서 바뀐 파일 받기)
if ($Mode -ne "push") {
    Write-Host "[2/5] 리포 -> 작업 폴더 복사..."
    Invoke-Robocopy $RepoSyncDir $WorkDir "리포 -> 작업 폴더(루트)" -ExtraOpts @("/XF", "_inventory.txt", ".gitkeep")
    foreach ($inc in $Includes) {
        Invoke-Robocopy (Join-Path $RepoSyncDir $inc) (Join-Path $WorkDir $inc) "리포 -> 작업 폴더($inc)" -Deep
    }
} else {
    Write-Host "[2/5] 건너뜀 (push 모드)"
}

# 3) 작업 폴더 -> 리포 (이 컴퓨터에서 작업한 파일 보내기)
if ($Mode -ne "pull") {
    Write-Host "[3/5] 작업 폴더 -> 리포 복사..."
    Invoke-Robocopy $WorkDir $RepoSyncDir "작업 폴더 -> 리포(루트)"
    foreach ($inc in $Includes) {
        Invoke-Robocopy (Join-Path $WorkDir $inc) (Join-Path $RepoSyncDir $inc) "작업 폴더 -> 리포($inc)" -Deep
    }
} else {
    Write-Host "[3/5] 건너뜀 (pull 모드)"
}

# 4) 전체 파일 목록 만들기 (Claude가 보고 동기화 폴더를 고르는 용도)
if ($Mode -ne "pull") {
    Write-Host "[4/5] 전체 파일 목록(OPCG\_inventory.txt) 만드는 중..."
    New-Item -ItemType Directory -Force -Path $RepoSyncDir -ErrorAction Stop | Out-Null
    $invPath  = Join-Path $RepoSyncDir "_inventory.txt"
    $stampNow = Get-Date -Format "yyyy-MM-dd HH:mm"
    $header = @(
        "# OPCG 작업 폴더 전체 파일 목록 (자동 생성: $stampNow)",
        "# 작업 폴더: $WorkDir",
        "# 파일 ${workFiles}개, 총 약 ${totalMB}MB",
        "# 형식: 상대경로<TAB>크기(byte)"
    )
    $body = $allFiles | ForEach-Object {
        "{0}`t{1}" -f $_.FullName.Substring($WorkDir.Length + 1), $_.Length
    }
    Set-Content -Path $invPath -Value ($header + $body) -Encoding UTF8
} else {
    Write-Host "[4/5] 건너뜀 (pull 모드)"
}

# 동기화 폴더 크기 확인 (GitHub 한계 예방)
$syncMB = 0
$syncSum = (Get-ChildItem -Path $RepoSyncDir -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
if ($syncSum) { $syncMB = [math]::Round($syncSum / 1MB) }
Write-Host "리포에 올라갈 동기화 폴더 크기: 약 ${syncMB}MB"
if ($syncMB -gt 1500) {
    Fail ("동기화 대상이 너무 큽니다 (약 ${syncMB}MB). GitHub에 한 번에 올릴 수 있는 크기를 넘습니다.`n" +
          "scripts\sync-include.txt의 폴더 목록을 줄여야 합니다. 이 내용을 Claude에게 알려주세요.")
}

# 5) 변경분 commit & push
$pushedOk   = $false
$hadChanges = $false
$ahead      = 0
$pushOut    = ""

if ($useGit -and $Mode -ne "pull") {
    Write-Host "[5/5] GitHub로 올리는 중 (commit & push)..."
    git -C $RepoDir add -A -- OPCG
    if ($LASTEXITCODE -ne 0) {
        Fail ("파일을 git에 추가(add)하지 못했습니다. 위쪽의 영어 오류 문구를 확인하세요.`n" +
              "- 'Filename too long'이 보이면: 경로가 긴 파일 때문인데, 설정을 자동으로 켰으니 이 스크립트를 한 번만 더 실행해보세요.`n" +
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
        Write-Host "  변경 파일 ${fileCount}개 commit 완료"
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
    if ($ahead -gt 0) { Write-Host "  GitHub로 올릴 commit: ${ahead}개" }

    foreach ($delay in 0, 2, 4, 8, 16) {
        if ($delay -gt 0) {
            Write-Host "* push 실패 - ${delay}초 후 다시 시도합니다..." -ForegroundColor Yellow
            Start-Sleep -Seconds $delay
        }
        $pushOut = git -C $RepoDir push 2>&1 | Out-String
        if ($pushOut) { Write-Host $pushOut.Trim() }
        if ($LASTEXITCODE -eq 0) { $pushedOk = $true; break }
    }
} elseif ($Mode -eq "pull") {
    Write-Host "[5/5] 건너뜀 (pull 모드)"
} else {
    Write-Host "[5/5] git push 건너뜀 (-NoGit)"
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
    $why = "- 위쪽의 push 오류 메시지(영어 문구)와 이 창 내용을 Claude에게 붙여넣어 주세요."
    if ($pushOut -match "Authentication failed|could not read Username|Permission to .+ denied|returned error: 403|Logon failed") {
        $why = ("- 원인: GitHub 로그인/권한 문제입니다.`n" +
                "  브라우저로 GitHub 로그인 창이 뜨면 kkfromkor 계정으로 로그인한 뒤 이 스크립트를 다시 실행하세요.`n" +
                "  로그인 창이 아예 안 뜨면 이 창 내용을 Claude에게 보여주세요.")
    } elseif ($pushOut -match "pack exceeds maximum|RPC failed|HTTP 408|HTTP 400|curl 55|curl 52|remote end hung up") {
        $why = ("- 원인: 한 번에 올리기엔 용량이 큰 것 같습니다 (올릴 크기 약 ${syncMB}MB).`n" +
                "  Claude에게 '용량 때문에 push 실패, 약 ${syncMB}MB'라고 알려주세요.")
    } elseif ($pushOut -match "non-fast-forward|fetch first|\[rejected\]") {
        $why = "- 원인: GitHub 쪽에 새 변경이 있어서입니다. 이 스크립트를 한 번 더 실행하면 받아서 합친 뒤 올라갑니다."
    }
    Fail ("GitHub 업로드(push)에 실패했습니다. 파일 복사와 commit은 됐지만 GitHub에는 안 올라갔습니다.`n" + $why)
}
