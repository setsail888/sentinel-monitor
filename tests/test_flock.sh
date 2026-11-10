#!/usr/bin/env bash
# flock 防重叠：占住锁时第二实例跳过并退出 0。
set -u
TEST_NAME="test_flock"
. "$(dirname "$0")/lib/common.sh"
trap cleanup_all EXIT

STATE=$(mk_state_dir)
mkdir -p "$STATE"
touch "$STATE/probe.lock"

# 占住锁 3 秒，期间跑探针；等持锁进程自然结束，不留孤儿进程。
flock "$STATE/probe.lock" -c 'sleep 3' &
HOLDER=$!
register_pid "$HOLDER"
sleep 0.5
OUT=$(SENTINEL_STATE_DIR="$STATE" SENTINEL_TOKEN="$TEST_TOKEN" \
  SENTINEL_REPORT_URL="http://127.0.0.1:9/" "$PROBE" 2>&1)
rc=$?
wait "$HOLDER" 2>/dev/null || true
assert_eq "占锁时第二实例退出 0" "0" "$rc"
assert_match "占锁时第二实例输出跳过提示" "$OUT" "仍在运行，本次跳过"
finish
