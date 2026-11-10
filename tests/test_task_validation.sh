#!/usr/bin/env bash
# 任务校验：合法行正常执行；非法行全部跳过并记日志；注入目标不得产生副作用。
set -u
TEST_NAME="test_task_validation"
. "$(dirname "$0")/lib/common.sh"
trap cleanup_all EXIT

TDIR=$(mk_tmp_dir)
STATE=$(mk_state_dir)
RECORD="$TDIR/panel.jsonl"
HTTPLOG="$TDIR/http.log"
MARKDIR="$TDIR/markers"; mkdir -p "$MARKDIR"
TASKS="$TDIR/tasks.txt"
URL="http://127.0.0.1:18101/"

# 任务文件用 python 写，避免 shell 对 $()、反引号、;、&& 的转义干扰。
TASKS="$TASKS" MARKDIR="$MARKDIR" python3 - <<'PYEOF'
import os
m = os.environ['MARKDIR']
lines = [
    "1|http|http://127.0.0.1:18102/ok|10",
    "2|tcp|127.0.0.1:18103|10",
    "abc|http|http://127.0.0.1:18102/ok|10",
    "10|http|http://127.0.0.1:18102/ok|5",
    "11|http|http://127.0.0.1:18102/ok|0",
    "12|http|http://127.0.0.1:18102/ok|-1",
    "13|http|http://127.0.0.1:18102/ok|abc",
    "14|http|http://127.0.0.1:18102/ok|999999",
    "15|tcp|127.0.0.1|10",
    "16|tcp|127.0.0.1:0|10",
    "17|tcp|127.0.0.1:99999|10",
    "18|tcp|127.0.0.1:80;touch %s/pwned18|10" % m,
    "19|tcp|127.0.0.1:$(touch %s/pwned19)|10" % m,
    "20|tcp|$(touch %s/pwned20):18103|10" % m,
    "21|tcp|127.0.0.1:80 && touch %s/pwned21|10" % m,
    "22|http|ftp://127.0.0.1:18102/ok|10",
    "23|http|127.0.0.1:18102/ok|10",
    "24|ping|-127.0.0.1|10",
    "25|ping|--help|10",
    "26|http|http://127.0.0.1:18102/$(touch${IFS}%s/pwned26)|10" % m,
    "28|ping|127.0.0.1;touch %s/pwned28|10" % m,
    "29|http|http://127.0.0.1:18102/`touch${IFS}%s/pwned29`|10" % m,
    "30|bogus|127.0.0.1|10",
    "31|http|http://127.0.0.1:18102/ok|10|extra",
    "|http|http://127.0.0.1:18102/ok|10",
]
open(os.environ['TASKS'], 'w').write("\n".join(lines) + "\n")
print("任务行数：%d" % len(lines))
PYEOF

start_static 18102 "" "" "$HTTPLOG" || finish
start_tcp_listener 18103 || finish
start_panel 18101 ok "$TASKS" "$RECORD" || finish

run_probe "$STATE" "$URL" >/dev/null 2>&1
rc=$?
assert_eq "探针退出码为 0" "0" "$rc"

# 分析上报的 checks。
IDSFILE="$TDIR/ids.txt" RECORD="$RECORD" python3 - <<'PYEOF'
import json, os, sys
recs = [json.loads(l) for l in open(os.environ['RECORD']) if l.strip()]
reps = [r['args'] for r in recs if r.get('action') == 'reportProbe']
assert reps, "未收到 reportProbe"
checks = reps[-1].get('checks', [])
ids = sorted(c['serviceId'] for c in checks)
print("实际执行的 checks serviceId：%s" % ids)
open(os.environ['IDSFILE'], 'w').write(' '.join(map(str, ids)))
PYEOF
IDS=$(cat "$TDIR/ids.txt" 2>/dev/null || echo "")

# 合法行执行。
check "合法 HTTP 任务（id 1）已执行" bash -c "echo ' $IDS ' | grep -q ' 1 '"
check "合法 TCP 任务（id 2）已执行" bash -c "echo ' $IDS ' | grep -q ' 2 '"
# HTTP 注入路径行：按实现是被接受后经 curl 安全请求的（参数加引号），只断言无副作用。
check "HTTP \$() 路径行（id 26）已执行（经 curl 安全请求）" bash -c "echo ' $IDS ' | grep -q ' 26 '"
check "HTTP 反引号路径行（id 29）已执行（经 curl 安全请求）" bash -c "echo ' $IDS ' | grep -q ' 29 '"
assert_contains "HTTP 服务器确实收到了 \$(touch …) 路径请求" "$HTTPLOG" '$(touch'
assert_contains "HTTP 服务器确实收到了反引号路径请求" "$HTTPLOG" '`touch'

# 非法行必须不在 checks 里（id 10–23、28、30、31 与空 id、abc）。
for bad_id in 10 11 12 13 14 15 16 17 18 19 20 21 22 23 28 30 31; do
  check "非法行 id $bad_id 已跳过" bash -c "echo ' $IDS ' | grep -vq ' $bad_id '"
done
check "非法行 abc（非数字 id）已跳过" bash -c "echo ' $IDS ' | grep -vq ' abc '"

# 注入标记文件一个都不能出现（任何注入都不应执行）。
if [ -z "$(ls -A "$MARKDIR" 2>/dev/null)" ]; then ok "注入无副作用：markers 目录为空"; else bad "注入产生了副作用：$(ls "$MARKDIR")"; fi

# 规格要求：带前导 - 的 Ping 目标应被跳过（共 21 行非法行）。
# 实际：探针的 Ping 正则把 - 含在允许字符集里，24/25 被执行而非跳过。
skip_n=$(grep -o '跳过非法任务行 [0-9]* 行' "$STATE/probe.log" 2>/dev/null | grep -o '[0-9]*' || echo 0)
assert_eq "日志跳过数为 21 行（含 2 行前导 - Ping）" "21" "$skip_n"
check "前导 - Ping 任务（id 24）应被跳过" bash -c "echo ' $IDS ' | grep -vq ' 24 '"
check "前导 - Ping 任务（id 25）应被跳过" bash -c "echo ' $IDS ' | grep -vq ' 25 '"
info "实际跳过数：$skip_n 行；实际 checks：$IDS"
finish
