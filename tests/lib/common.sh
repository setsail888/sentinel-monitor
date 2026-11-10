#!/usr/bin/env bash
# tests/lib/common.sh — 共享辅助函数（由各分项测试脚本 source）。
# 只做测试脚手架，不修改被测脚本。
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTS_DIR="$REPO_DIR/tests"
PROBE="$REPO_DIR/sentinel-probe.sh"
INSTALL="$REPO_DIR/install.sh"
TEST_TOKEN="0123456789abcdef0123456789abcdef01234567"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
declare -a BG_PIDS=()
declare -a TMP_DIRS=()

ok()   { PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $*"; }
bad()  { FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $*"; }
skip() { SKIP_COUNT=$((SKIP_COUNT+1)); echo "SKIP: $*"; }
info() { echo "INFO: $*"; }

# check <描述> <命令...>: 命令成功记 PASS，否则 FAIL（输出丢弃）。
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

assert_eq() { # assert_eq <描述> <期望> <实际>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$2]，实际 [$3]）"; fi
}
assert_contains() { # assert_contains <描述> <文件> <子串>
  if grep -Fq -- "$3" "$2"; then ok "$1"; else bad "$1（在 $2 中未找到 [$3]）"; fi
}
assert_not_contains() { # assert_not_contains <描述> <文件> <子串>
  if grep -Fq -- "$3" "$2"; then bad "$1（在 $2 中不应出现 [$3]）"; else ok "$1"; fi
}
assert_match() { # assert_match <描述> <字符串> <扩展正则>
  if printf '%s' "$2" | grep -Eq -- "$3"; then ok "$1"; else bad "$1（[$2] 不匹配 [$3]）"; fi
}

mk_state_dir() { local d; d="$(mktemp -d /tmp/sentinel-test-state.XXXXXX)"; TMP_DIRS+=("$d"); printf '%s' "$d"; }
mk_tmp_dir() { local d; d="$(mktemp -d /tmp/sentinel-test.XXXXXX)"; TMP_DIRS+=("$d"); printf '%s' "$d"; }

register_pid() { BG_PIDS+=("$1"); }

wait_port() { # wait_port <端口> [超时秒]
  local port="$1" timeout_s="${2:-10}" i
  for ((i=0; i<timeout_s*10; i++)); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  return 1
}

start_panel() { # start_panel <端口> <模式 ok|flaky2|alwaysfail> <任务文件|空> <记录文件> [延迟秒]
  local port="$1" mode="$2" tasks="$3" record="$4" delay="${5:-0}"
  python3 "$TESTS_DIR/lib/fake_panel.py" --port "$port" --mode "$mode" \
    --tasks-file "$tasks" --record "$record" --delay "$delay" \
    >>"$record.stdout" 2>>"$record.stderr" &
  local pid=$!
  register_pid "$pid"
  if wait_port "$port" 10; then return 0; else bad "假面板未在 10 秒内监听端口 $port"; return 1; fi
}

start_static() { # start_static <端口> [证书] [私钥] [请求日志]
  local port="$1" cert="${2:-}" key="${3:-}" rlog="${4:-}"
  python3 "$TESTS_DIR/lib/static_server.py" --port "$port" --cert "$cert" --key "$key" --log "$rlog" >/dev/null 2>&1 &
  local pid=$!
  register_pid "$pid"
  if wait_port "$port" 10; then return 0; else bad "静态服务器未在 10 秒内监听端口 $port"; return 1; fi
}

start_tcp_listener() { # start_tcp_listener <端口>
  python3 "$TESTS_DIR/lib/tcp_listener.py" --port "$1" >/dev/null 2>&1 &
  local pid=$!
  register_pid "$pid"
  if wait_port "$1" 10; then return 0; else bad "TCP 监听未在 10 秒内监听端口 $1"; return 1; fi
}

# run_probe <状态目录> <上报地址> [额外环境 VAR=VAL ...]
run_probe() {
  local state="$1" url="$2"; shift 2
  env SENTINEL_STATE_DIR="$state" SENTINEL_TOKEN="$TEST_TOKEN" \
      SENTINEL_REPORT_URL="$url" "$@" "$PROBE"
}

# run_probe_token <状态目录> <上报地址> <令牌>
run_probe_token() {
  local state="$1" url="$2" token="$3"
  env SENTINEL_STATE_DIR="$state" SENTINEL_TOKEN="$token" \
      SENTINEL_REPORT_URL="$url" "$PROBE"
}

# scan_ps_for_token <令牌文件> <时长秒>：轮询 ps，若在任何进程命令行里
# 发现令牌返回 0（命中），否则返回 1。令牌经文件传给 grep，不出现在 grep 自身参数里。
scan_ps_for_token() {
  local tokenfile="$1" dur="$2"
  local end=$((SECONDS+dur))
  while [ "$SECONDS" -lt "$end" ]; do
    if ps -eo args= | grep -F -f "$tokenfile" >/dev/null 2>&1; then return 0; fi
    sleep 0.2
  done
  return 1
}

cleanup_all() {
  local p d
  for p in "${BG_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  sleep 0.2
  for p in "${BG_PIDS[@]}"; do kill -9 "$p" 2>/dev/null || true; done
  for d in "${TMP_DIRS[@]}"; do rm -rf "$d" 2>/dev/null || true; done
}

finish() {
  echo "---- ${TEST_NAME:-$(basename "$0")}: 通过 $PASS_COUNT，失败 $FAIL_COUNT，跳过 $SKIP_COUNT ----"
  if [ "$FAIL_COUNT" -gt 0 ]; then exit 1; else exit 0; fi
}
