#!/usr/bin/env bash
# install.sh：--help/--version 正常；坏令牌、http 地址、占位符地址、
# 坏版本号的 --update 均被拒且非零退出；卸载删干净（无 systemd 时不得硬失败）。
# 注意：本套件不连外网，不跑任何会触发真实下载的合法安装/升级路径。
set -u
TEST_NAME="test_install"
. "$(dirname "$0")/lib/common.sh"
trap cleanup_all EXIT

TDIR=$(mk_tmp_dir)
GOOD_TOKEN="$TEST_TOKEN"
LONG_TOKEN=$(python3 -c "print('a'*129)")

expect_reject() { # expect_reject <描述> <期望的 stderr 关键字> <install.sh 参数...>
  local desc="$1" want="$2"; shift 2
  local out rc
  out=$(bash "$INSTALL" "$@" 2>&1) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -Fq -- "$want"; then
    ok "$desc"
  else
    bad "$desc（退出码 $rc，输出：$out）"
  fi
}

# --help / --version。
if bash "$INSTALL" --help 2>&1 | grep -Fq "用法"; then ok "--help 正常，退出 0"; else bad "--help 异常"; fi
bash "$INSTALL" --help >/dev/null 2>&1; assert_eq "--help 退出码为 0" "0" "$?"
VER_OUT=$(bash "$INSTALL" --version 2>&1); assert_eq "--version 输出含 0.1.0" "sentinel-monitor install.sh 0.1.0" "$VER_OUT"
bash "$INSTALL" --version >/dev/null 2>&1; assert_eq "--version 退出码为 0" "0" "$?"
bash "$INSTALL" >/dev/null 2>&1; assert_eq "无参数退出码为 2" "2" "$?"

# 坏令牌。
expect_reject "令牌过短（5 位）被拒" "令牌格式无效" "short" "https://127.0.0.1:1/x"
expect_reject "令牌含非法字符 ! 被拒" "令牌格式无效" "0123456789abcdef!" "https://127.0.0.1:1/x"
expect_reject "令牌 15 位被拒" "令牌格式无效" "0123456789abcde" "https://127.0.0.1:1/x"
expect_reject "令牌 129 位被拒" "令牌格式无效" "$LONG_TOKEN" "https://127.0.0.1:1/x"

# 坏地址。
expect_reject "http:// 地址被拒" "上报地址无效" "$GOOD_TOKEN" "http://127.0.0.1:1/x"
expect_reject "占位符 __REPORT_URL__ 被拒" "上报地址无效" "$GOOD_TOKEN" "https://__REPORT_URL__"
expect_reject "地址含 __TOKEN__ 被拒" "上报地址无效" "$GOOD_TOKEN" "https://127.0.0.1/__TOKEN__/x"
expect_reject "地址含空格被拒" "上报地址无效" "$GOOD_TOKEN" "https://127.0.0.1/a b"

# 坏版本号的 --update。
expect_reject "--update abc 被拒" "版本号格式无效" --update abc
expect_reject "--update 999999 被拒" "版本号格式无效" --update 999999
expect_reject "--update 1.2.3.4 被拒" "版本号格式无效" --update 1.2.3.4
expect_reject "--update v1.2 被拒" "版本号格式无效" --update v1.2
expect_reject "--update 后跟选项被拒" "--update 后请跟版本号" --update -x

# 合法格式版本但未安装探针：应在下载前拒绝（不连外网）。
if [ -e /usr/local/bin/sentinel-probe.sh ]; then
  skip "--update 0.1.0 未安装拒绝：/usr/local/bin/sentinel-probe.sh 已存在，跳过以免触发下载"
else
  expect_reject "--update 0.1.0 未安装时被拒（下载前）" "未找到已安装的探针" --update 0.1.0
  expect_reject "--update（无版本）未安装时被拒" "未找到已安装的探针" --update
fi

# 卸载：手工造出安装会产生的文件，跑 --uninstall 验证删干净。
mkdir -p /etc/sentinel /var/lib/sentinel-probe /etc/systemd/system
printf 'sentinel-probe-test-content\n' > /usr/local/bin/sentinel-probe.sh
printf 'old\n' > /usr/local/bin/sentinel-probe.sh.bak
printf "SENTINEL_TOKEN='%s'\nSENTINEL_REPORT_URL='https://127.0.0.1/x'\n" "$GOOD_TOKEN" > /etc/sentinel/probe.env
printf 'log\n' > /var/lib/sentinel-probe/probe.log
printf 'x\n' > /var/lib/sentinel-probe/counters.prev
printf '[Unit]\n' > /etc/systemd/system/sentinel-probe.service
printf '[Unit]\n' > /etc/systemd/system/sentinel-probe.timer
if ! id sentinel >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin sentinel 2>/dev/null || true
fi
if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ] && [ -d /run/systemd/system ]; then
  info "has_systemd=true（本机走 systemd 分支）"
else
  info "has_systemd=false（本机走 cron 分支）"
fi
bash "$INSTALL" --uninstall >/dev/null 2>&1
assert_eq "--uninstall 退出码为 0" "0" "$?"
check "卸载删探针文件" test ! -e /usr/local/bin/sentinel-probe.sh
check "卸载删 .bak 备份" test ! -e /usr/local/bin/sentinel-probe.sh.bak
check "卸载删 /etc/sentinel" test ! -e /etc/sentinel
check "卸载删 /var/lib/sentinel-probe" test ! -e /var/lib/sentinel-probe
check "卸载删 service 文件" test ! -e /etc/systemd/system/sentinel-probe.service
check "卸载删 timer 文件" test ! -e /etc/systemd/system/sentinel-probe.timer
check "卸载删 sentinel 用户" bash -c '! id sentinel >/dev/null 2>&1'
bash "$INSTALL" --uninstall >/dev/null 2>&1
assert_eq "再次 --uninstall 仍退出 0（幂等）" "0" "$?"
finish
