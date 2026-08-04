# OPTCG 전체 배포 지시서 (ClaudeFable5/OPTCG 세션용)

이 문서는 **`ClaudeFable5/OPTCG` 리포로 열린 Claude 세션**이 카드 데이터를
전체 유저에게 배포할 때 따르는 절차다. OPTCG 리포는 모든 유저 클라이언트가
부팅 시 자동 업데이트를 받아가는 배포 채널이다.

## 절대 규칙 (코어 채널 - 건드리면 안 됨)

- `update.json`, `release/` 폴더, `*.zip`, `*.exe`, `*.dll` — **절대 수정·삭제 금지.**
  이건 exe/코어 업데이트 채널이고 사용자 사전 승인 없이는 손대지 않는다.
- 이 지시서로 바꾸는 것은 **카드 데이터만**: `script/`의 카드 스크립트, 루트의
  `cards-opcg.cdb`, (있다면) `pics/`.

## 절차

1. **페이로드 받기** — 최신 카드 데이터는 공개 리포 `kkfromkor/kkfromkor`에 있다:
   ```
   git clone --depth 1 https://github.com/kkfromkor/kkfromkor /tmp/payload
   ```
   페이로드 위치: `/tmp/payload/OPCG/rev28_work/windows_source/bin/release/`
   - 스크립트: `expansions/script/` 안의 `opcg_*.lua` + `c8*.lua` (이 두 패턴 전부가 정본 전체 세트)
   - 카드DB: `expansions/cards-opcg.cdb`
   - 카드 이미지: `pics/*.jpg`

2. **사전 확인** — OPTCG 리포 루트에 `cards-opcg.cdb`와 `script/` 폴더가 있는지
   확인한다. 없으면 구조가 예상과 다른 것이니 **중단하고 사용자에게 보고**한다.

3. **카드 스크립트 전체 미러** (부분 배포 금지 - 세대 섞임 사고 방지):
   - 페이로드의 `opcg_*.lua`, `c8*.lua` 전부를 OPTCG `script/`에 복사(덮어쓰기).
   - OPTCG `script/`에 있는 `opcg_*.lua`/`c8*.lua` 중 페이로드에 **없는** 파일은
     삭제한다 (유령 스크립트 정리). 그 외 파일(공식 EDOPro 스크립트 등)은 건드리지 않는다.

4. **카드DB 교체** — 페이로드의 `cards-opcg.cdb`로 루트 `cards-opcg.cdb`를 덮어쓴다.

5. **카드 이미지** — OPTCG 리포에 `pics/` 폴더가 **이미 있을 때만** 페이로드의
   `pics/*.jpg`를 복사(추가/덮어쓰기, 삭제 없음). 폴더가 없으면 만들지 말고 건너뛴다.

6. **검증** — 페이로드와 OPTCG `script/`의 `opcg_*`+`c8*` 파일 수가 일치하는지,
   cdb 파일 크기가 페이로드와 같은지 확인한다.

7. **커밋 & push** — 기본 브랜치(main)에:
   ```
   카드 데이터 업데이트 (kkfromkor 동기화 리포 기준 YYYY-MM-DD)
   ```
   형식으로 커밋하고 push한다. push까지 성공해야 배포 완료다.

8. **보고** — 반영된 파일 수(스크립트/이미지), cdb 크기, 커밋 해시를 요약 보고하고,
   "서버 반영은 서버 컴퓨터에서 적용하기.bat 실행 또는 재시작 필요"를 덧붙인다.

## 재실행

이 절차는 몇 번을 다시 돌려도 안전하다(전체 미러 방식). 사용자가 "배포해줘",
"ㄱㄱ" 등으로 재요청하면 1번부터 다시 (fresh clone으로 최신 페이로드를 받아) 수행한다.
