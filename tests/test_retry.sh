#!/usr/bin/env bash
# 重试/超时：回环假面板先失败 2 次再成功，验证重试后成功且不留 spool；
# 一直失败的端点，验证 3 次重试后退出码 1、spool 合法 JSON、日志含失败记录、日志无令牌。
set -u
TEST_NAME="test_retry"
. "$(dirname "$0")/lib/common.sh"
trap cleanup_all EXIT

TDIR=$(mk_tmp_dir)
STATE1=$(mk_state_dir)
STATE2=$(mk_state_dir)
REC1="$TDIR/panel-flaky.jsonl"
REC2="$TDIR/panel-fail.jsonl"

count_reports() { # count_reports <记录文件>
  python3 -c "
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(sum(1 for r in recs if r.get('action') == 'reportProbe'))
" "$1"
}

# 1) 先失败 2 次再成功。
start_panel 18141 flaky2 "" "$REC1" || finish
run_probe "$STATE1" "http://127.0.0.1:18141/" >/dev/null 2>&1
assert_eq "flaky 面板：探针最终退出码为 0" "0" "$?"
assert_eq "flaky 面板：reportProbe 共尝试 3 次" "3" "$(count_reports "$REC1")"
check "flaky 面板：重试成功后不留 spool" test ! -e "$STATE1/failed-spool.jsonl"
assert_contains "flaky 面板：日志记第 1 次失败" "$STATE1/probe.log" "上报失败（第 1 次"
assert_contains "flaky 面板：日志记第 2 次失败" "$STATE1/probe.log" "上报失败（第 2 次"

# 2) 一直失败。
start_panel 18142 alwaysfail "" "$REC2" || finish
run_probe "$STATE2" "http://127.0.0.1:18142/" >/dev/null 2>&1
assert_eq "一直失败：探针退出码为 1" "1" "$?"
assert_eq "一直失败：reportProbe 共尝试 3 次" "3" "$(count_reports "$REC2")"
check "一直失败：spool 文件已写入" test -s "$STATE2/failed-spool.jsonl"
if [ -s "$STATE2/failed-spool.jsonl" ]; then
  if python3 -m json.tool "$STATE2/failed-spool.jsonl" >/dev/null 2>&1; then
    ok "一直失败：spool 内容为合法 JSON"
  else
    bad "一直失败：spool 内容不是合法 JSON"
  fi
fi
assert_contains "一直失败：日志含已重试 3 次" "$STATE2/probe.log" "已重试 3 次"
assert_contains "一直失败：日志含第 3 次失败" "$STATE2/probe.log" "上报失败（第 3 次"
assert_not_contains "一直失败：日志里无令牌" "$STATE2/probe.log" "$TEST_TOKEN"
assert_not_contains "flaky 面板日志里无令牌" "$STATE1/probe.log" "$TEST_TOKEN"
finish
