#!/usr/bin/env bash
# 静态检查：禁用词 0 处、推迟字段 0 处、三处版本号一致、
# SHA256 与当前探针一致、安装地址无 main/master 分支引用。
set -u
TEST_NAME="test_static"
. "$(dirname "$0")/lib/common.sh"
trap cleanup_all EXIT

# 禁用词：用八进制转义拼出，不在任何文件里写出原文，避免自检误报。
BAD_WORD=$(printf '\345\223\252\345\220\222\346\216\242\351\222\210')
hits=$(grep -r -F -- "$BAD_WORD" "$REPO_DIR" --exclude-dir=.git 2>/dev/null | wc -l | tr -d ' ')
assert_eq "禁用词 0 处" "0" "$hits"

# 已推迟、不应出现在 0.1.0 里的字段名。
for f in interfaces disks netRxRateBps netTxRateBps diagnostics SENTINEL_RUN_MODE; do
  n=$(grep -r -F -- "$f" "$PROBE" "$INSTALL" "$REPO_DIR/README.md" "$REPO_DIR/CHANGELOG.md" 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "推迟字段 $f 出现 0 次" "0" "$n"
done
# IPv4/IPv6 区分字段也不应出现。说明：探针注释与 CHANGELOG 里各有 1 处提到
# “IPv6 连接用方括号”——那是 SSL 检测解析 URL 主机名时的括号处理说明，
# 不是 IPv4/IPv6 区分字段，故排除含“方括号”的说明行后再计数。
n=$(grep -r -i -E 'ipv4|ipv6' "$PROBE" "$INSTALL" "$REPO_DIR/README.md" "$REPO_DIR/CHANGELOG.md" 2>/dev/null | grep -v '方括号' | wc -l | tr -d ' ')
assert_eq "IPv4/IPv6 区分字段出现 0 次" "0" "$n"
info "另有 2 处“IPv6 …方括号”说明行（SSL 主机名解析注释/文档），非区分字段"

# 三处版本号一致：探针、安装器、README 均为 0.1.0。
pv=$(grep -m1 '^AGENT_VERSION=' "$PROBE" | cut -d'"' -f2)
iv=$(grep -m1 '^DEFAULT_VERSION=' "$INSTALL" | cut -d'"' -f2)
rv=$(grep -m1 '^\*\*版本：' "$REPO_DIR/README.md" | sed 's/[^0-9.]//g')
assert_eq "探针 AGENT_VERSION 为 0.1.0" "0.1.0" "$pv"
assert_eq "安装器 DEFAULT_VERSION 为 0.1.0" "0.1.0" "$iv"
assert_eq "README 版本为 0.1.0" "0.1.0" "$rv"

# SHA256 与当前探针一致。
check "sentinel-probe.sh.sha256 与当前探针一致" bash -c "cd '$REPO_DIR' && sha256sum -c sentinel-probe.sh.sha256"

# 安装地址无 main/master 分支引用；所有写死的 raw.githubusercontent 地址都走固定 tag。
# install.sh 里另有一处变量拼装形式（$REPO/$tag），tag 由 "v$1" 生成，单独断言。
n=$(grep -r -E 'raw\.githubusercontent\.com/[^ ]*/(main|master)(/|$)' "$PROBE" "$INSTALL" "$REPO_DIR/README.md" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "main/master 分支引用 0 处" "0" "$n"
bad_urls=$(grep -rho -E 'https://raw\.githubusercontent\.com/[^ )`]*' "$INSTALL" "$REPO_DIR/README.md" 2>/dev/null | grep -v '\$' | grep -v '/v0\.1\.0/' || true)
if [ -z "$bad_urls" ]; then ok "全部写死的 raw.githubusercontent 地址均走 v0.1.0 tag"; else bad "存在非 v0.1.0 的 raw 地址：$bad_urls"; fi
assert_contains "install.sh 用变量拼装下载地址（\$REPO/\$tag）" "$INSTALL" 'local base="https://raw.githubusercontent.com/$REPO/$tag"'
assert_contains "install.sh 的 tag 由 v + 版本生成" "$INSTALL" 'tag="v$1"'
finish
