param([Parameter(Mandatory = $true)][string]$Repo)

# 효과 상수 검색대(tools/opcg_find_op.py) 라벨 커버리지 감시:
# 계약 허용목록의 모든 action/cost/condition op에 손라벨이 달려 있어야 한다.
# 신규 op를 추가하고 라벨을 안 달면 여기서 FAIL — 검색대 부패 방지.
$env:PYTHONIOENCODING = "utf-8"
python "$Repo\tools\opcg_find_op.py" --audit
if ($LASTEXITCODE -eq 0) {
    Write-Output "OP_CATALOG PASS"
    exit 0
} else {
    Write-Output "OP_CATALOG FAIL"
    exit 1
}
