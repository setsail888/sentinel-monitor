#!/usr/bin/env bash
# JSON 转义：含控制字符、引号、反斜杠的主机名/系统名/详情，
# 验证上报 JSON 能被 python3 -m json.tool 解析。
# 单元部分直接抽取探针的 json_escape 函数验证；实测部分用含引号与反斜杠的令牌跑一次真实探针。
set -u
TEST_NAME="test_json_escape"
. "$(dirname "$0")/lib/common.sh"
trap cleanup_all EXIT

TDIR=$(mk_tmp_dir)
STATE=$(mk_state_dir)
RECORD="$TDIR/panel.jsonl"
URL="http://127.0.0.1:18131/"

# 1) 单元：从探针抽取 json_escape（不改探针），逐个用例 round-trip。
awk '/^json_escape\(\) \{/,/^}/' "$PROBE" > "$TDIR/json_escape_fn.sh"
# shellcheck disable=SC1090
. "$TDIR/json_escape_fn.sh"
check_case() { # check_case <描述> <原串>
  local desc="$1" orig="$2" esc
  esc=$(json_escape "$orig")
  if ORIG="$orig" ESC="$esc" python3 -c "
import json, os, sys
obj = json.loads('{\"k\":\"' + os.environ['ESC'] + '\"}')
assert obj['k'] == os.environ['ORIG'], (repr(obj['k']), repr(os.environ['ORIG']))
"; then ok "$desc"; else bad "$desc（转义后无法 round-trip）"; fi
}
check_case "纯文本" "plain-host"
check_case "制表符" "$(printf 'a\tb')"
check_case "换行" "$(printf 'a\nb')"
check_case "回车" "$(printf 'a\rb')"
check_case "控制字符 0x01/0x02/0x1f" "$(printf 'a\x01\x02\x1f')"
check_case "双引号" 'a"b"c'
check_case "反斜杠" 'a\b\c'
check_case "混合控制字符+引号+反斜杠" "$(printf 'mix\t\n\r\x01\x07\x08\x0c\x1f"\\end')"
check_case "退格与换页" "$(printf 'a\x08\x0cb')"

# 2) 实测：含引号与反斜杠的令牌跑一次真实探针，上报 JSON 须合法且令牌原样回传。
WEIRD_TOKEN='T"OK\EN0123456789abcdef0123456789abcdef'
start_panel 18131 ok "" "$RECORD" || finish
run_probe_token "$STATE" "$URL" "$WEIRD_TOKEN" >/dev/null 2>&1
assert_eq "探针退出码为 0" "0" "$?"
RECORD="$RECORD" WEIRD_TOKEN="$WEIRD_TOKEN" python3 - <<'PYEOF'
import json, os
recs = [json.loads(l) for l in open(os.environ['RECORD']) if l.strip()]
assert recs, "假面板未收到任何请求"
for r in recs:
    json.loads(r['raw'])  # 每条原始请求体都须是合法 JSON
reps = [r for r in recs if r.get('action') == 'reportProbe']
assert reps, "未收到 reportProbe"
assert reps[-1]['args']['token'] == os.environ['WEIRD_TOKEN'], "令牌未原样回传"
tasks = [r for r in recs if r.get('action') == 'getProbeTasks']
assert tasks and tasks[0]['args']['token'] == os.environ['WEIRD_TOKEN'], "任务拉取令牌未原样回传"
print("含引号与反斜杠的令牌：上报与任务拉取 JSON 均合法，令牌原样回传")
PYEOF
[ $? -eq 0 ] && ok "实测：特殊字符令牌上报 JSON 合法且原样回传" || bad "实测：特殊字符令牌上报断言失败"
finish
