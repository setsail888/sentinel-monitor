#!/usr/bin/env bash
# ShellCheck：两个脚本都过，要求零 warning。
set -u
TEST_NAME="test_shellcheck"
. "$(dirname "$0")/lib/common.sh"
trap cleanup_all EXIT

if ! command -v shellcheck >/dev/null 2>&1; then
  skip "shellcheck 未安装，无法检查"
  finish
fi
info "shellcheck 版本：$(shellcheck --version | awk '/^version:/{print $2}')"
out=$(shellcheck -S warning "$PROBE" "$INSTALL" 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "shellcheck -S warning 通过，零告警：sentinel-probe.sh + install.sh"
else
  bad "shellcheck 有输出（rc=$rc）：$out"
fi
finish
