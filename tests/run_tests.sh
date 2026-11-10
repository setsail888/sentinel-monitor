#!/usr/bin/env bash
# 一键跑全部哨兵监控 0.1.0 测试。
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SUITES=(test_shellcheck test_static test_traffic test_task_validation test_latency test_ssl test_json_escape test_retry test_flock test_e2e test_install test_permissions)
echo "哨兵监控 0.1.0 测试套件"
echo "仓库：$(dirname "$TESTS_DIR")"
echo "时间：$(date '+%F %T %Z')"
echo "身份：$(id -un)（uid=$(id -u)）"
echo "shellcheck：$(shellcheck --version 2>/dev/null | awk '/^version:/{print $2}' || echo 未安装)"
echo "python3：$(python3 --version 2>&1)"
echo "说明：全部测试只用回环地址，不连外网；令牌与地址均为假值。"
echo
passed=0; failed=0
declare -a failed_suites=()
for s in "${SUITES[@]}"; do
  echo "===== $s ====="
  if bash "$TESTS_DIR/$s.sh"; then
    passed=$((passed+1)); echo "----- $s: 通过 -----"
  else
    failed=$((failed+1)); failed_suites+=("$s"); echo "----- $s: 失败 -----"
  fi
  echo
done
echo "汇总：套件通过 $passed，失败 $failed（共 ${#SUITES[@]} 个）"
if [ "$failed" -gt 0 ]; then echo "失败套件：${failed_suites[*]}"; exit 1; fi
exit 0
