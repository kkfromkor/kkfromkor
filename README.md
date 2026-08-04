# kkfromkor 작업 리포지토리

`OPCG/` 폴더는 내 컴퓨터의 `C:\Users\정민혁\Documents\OPCG` 작업 폴더와 동기화되는 사본입니다.
작업을 시작할 때 동기화 스크립트를 한 번 실행하면 작업 폴더 ↔ GitHub 양쪽이 최신 상태로 맞춰집니다.

## 처음 한 번만 (내 컴퓨터에 설치)

1. [Git 설치](https://git-scm.com/download/win) — 이미 있으면 생략
2. 원하는 위치에 리포지토리 받기 (예: 문서 폴더 아래)

   ```
   cd %USERPROFILE%\Documents
   git clone https://github.com/kkfromkor/kkfromkor.git
   ```

3. 받은 `kkfromkor` 폴더 안의 `sync-opcg.bat` 더블클릭 → 첫 동기화 완료

## 평소 사용법

- **작업 시작할 때** `sync-opcg.bat` 더블클릭 → 다른 곳(Claude 세션 등)에서 바뀐 파일을 작업 폴더로 받아옴
- **작업 끝났을 때** 한 번 더 더블클릭 → 오늘 작업한 파일을 GitHub에 올림
- **카드 데이터를 게임에 반영할 때** `sync-and-deploy.bat` 더블클릭 → 동기화 후 게임·서버 폴더까지 한 번에 배포 (서버 적용하기.bat과 OPTCG repo push는 안내에 따라 수동)

시작/끝 구분 없이 생각날 때마다 실행해도 됩니다. 실행할 때마다 양방향으로 맞춰줍니다.

### 로그인할 때 자동 실행 (선택)

1. `Win + R` → `shell:startup` 입력 → 엔터
2. 열린 폴더에 `sync-opcg.bat`의 **바로가기**를 넣어두면 로그인할 때마다 자동 동기화

## 동작 방식

- 작업 폴더 전체(약 10GB)는 GitHub에 올릴 수 없어서, **`scripts/sync-include.txt`에 적힌 하위 폴더만** 양방향 동기화합니다.
- 대신 실행할 때마다 **전체 파일 목록**이 `OPCG/_inventory.txt`로 올라가고, Claude가 그 목록을 보고 작업에 필요한 폴더를 `sync-include.txt`에 채웁니다.
- 실행 순서: GitHub에서 받기(`git pull`) → 대상 폴더를 서로 더 최신 파일로 맞춤 → 전체 목록 생성 → 변경분 commit & push
- **더 최신 파일이 이깁니다.** 같은 파일을 양쪽에서 동시에 고쳤다면 수정 시각이 늦은 쪽이 남습니다.
- **삭제는 전파되지 않습니다.** 한쪽에서 지운 파일이 다른 쪽에서 자동으로 지워지지는 않습니다 (안전을 위해).
- GitHub 파일 크기 제한(100MB) 때문에 95MB가 넘는 파일은 동기화에서 제외되고, 동기화 대상 합계가 1.5GB를 넘으면 실행이 중단됩니다.

## 문제가 생기면

- 창에 빨간 오류가 보이면 리포 폴더에서 `git status`를 확인하거나, 오류 내용을 Claude에게 붙여넣고 물어보세요.
- 작업 폴더 위치가 바뀌면 `scripts/sync-opcg.ps1` 상단의 `$WorkDir` 한 줄만 고치면 됩니다.
