#!/usr/bin/env bash
# 权限隔离实测：install.sh 生成的 systemd 单元含全部加固项；
# 建 sentinel 用户并以该用户身份跑一次真实探针，验证能采集能上送；
# ps 输出与日志里无令牌。退出时清理全部临时安装痕迹。
set -u
TEST_NAME="test_permissions"
. "$(dirname "$0")/lib/common.sh"

cleanup_perm() {
  cleanup_all
  rm -f /usr/local/bin/sentinel-probe.sh /usr/local/bin/sentinel-probe.sh.bak /usr/local/bin/sentinel-probe.sh.tmp
  rm -rf /etc/sentinel /var/lib/sentinel-probe
  if id sentinel >/dev/null 2>&1; then userdel sentinel 2>/dev/null || true; fi
}
trap cleanup_perm EXIT

# 1) 静态：systemd 单元加固项齐全（install.sh 内置的 service 段）。
for d in "User=sentinel" "NoNewPrivileges=true" "ProtectSystem=strict" "ProtectHome=true" \
         "PrivateTmp=true" "ReadWritePaths=/var/lib/sentinel-probe" \
         "CapabilityBoundingSet=CAP_NET_RAW" "AmbientCapabilities=CAP_NET_RAW" \
         "ProtectKernelTunables=true" "ProtectControlGroups=true" "LockPersonality=true" \
         "StateDirectory=sentinel-probe" "EnvironmentFile=/etc/sentinel/probe.env" \
         "ExecStart=/usr/local/bin/sentinel-probe.sh" "Type=oneshot" \
         "OnUnitActiveSec=60s" "OnBootSec=20s"; do
  assert_contains "systemd 单元含 $d" "$INSTALL" "$d"
done

# 2) 实测：按 install.sh 的方式布好用户、配置与状态目录，以 sentinel 身份跑探针。
TDIR=$(mk_tmp_dir)
RECORD="$TDIR/panel.jsonl"
TASKS="$TDIR/tasks.txt"
URL="http://127.0.0.1:18161/"
printf '%s\n' "1|http|http://127.0.0.1:18162/ok|10" "2|tcp|127.0.0.1:18163|10" > "$TASKS"
printf '%s' "$TEST_TOKEN" > "$TDIR/token.txt"

if ! command -v runuser >/dev/null 2>&1; then
  skip "无 runuser，以 sentinel 身份运行未测"
  finish
fi
cp "$PROBE" /usr/local/bin/sentinel-probe.sh && chmod 755 /usr/local/bin/sentinel-probe.sh
if ! id sentinel >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin sentinel \
    || { bad "创建 sentinel 用户失败"; finish; }
fi
mkdir -p /etc/sentinel /var/lib/sentinel-probe
# 目录本身也要显式设权限（见下方对 install.sh 的检查：安装器未对此负责）。
chown root:sentinel /etc/sentinel
chmod 750 /etc/sentinel
( umask 077
  printf "SENTINEL_TOKEN='%s'\nSENTINEL_REPORT_URL='%s'\n" "$TEST_TOKEN" "$URL" > /etc/sentinel/probe.env
)
chown root:sentinel /etc/sentinel/probe.env
chmod 640 /etc/sentinel/probe.env
chown sentinel:sentinel /var/lib/sentinel-probe
chmod 750 /var/lib/sentinel-probe

start_static 18162 || finish
start_tcp_listener 18163 || finish
start_panel 18161 ok "$TASKS" "$RECORD" 2 || finish

runuser -u sentinel -- /usr/local/bin/sentinel-probe.sh >/dev/null 2>&1 &
PROBE_PID=$!
if scan_ps_for_token "$TDIR/token.txt" 6; then bad "sentinel 运行期间 ps 输出中出现令牌"; else ok "sentinel 运行期间 ps 输出中无令牌"; fi
wait "$PROBE_PID"; rc=$?
assert_eq "sentinel 用户跑探针退出码为 0" "0" "$rc"

# 权限保持：配置 640 root:sentinel，配置目录 750 root:sentinel，状态目录 750 sentinel:sentinel。
ENV_PERM=$(stat -c '%a %U:%G' /etc/sentinel/probe.env)
assert_eq "probe.env 权限为 640 root:sentinel" "640 root:sentinel" "$ENV_PERM"
ENVDIR_PERM=$(stat -c '%a %U:%G' /etc/sentinel)
assert_eq "配置目录权限为 750 root:sentinel" "750 root:sentinel" "$ENVDIR_PERM"
STATE_PERM=$(stat -c '%a %U:%G' /var/lib/sentinel-probe)
assert_eq "状态目录权限为 750 sentinel:sentinel" "750 sentinel:sentinel" "$STATE_PERM"
# sentinel 用户不可读 probe.env 之外的 root 文件：以 sentinel 身份读配置应成功，读 shadow 应失败。
check "sentinel 能读自己的 probe.env" runuser -u sentinel -- cat /etc/sentinel/probe.env
if runuser -u sentinel -- cat /etc/shadow >/dev/null 2>&1; then bad "sentinel 不应能读 /etc/shadow"; else ok "sentinel 不能读 /etc/shadow"; fi

# 上报内容与日志。
RECORD="$RECORD" python3 - <<'PYEOF'
import json, os
recs = [json.loads(l) for l in open(os.environ['RECORD']) if l.strip()]
reps = [r for r in recs if r.get('action') == 'reportProbe']
assert reps, "未收到 reportProbe"
args = reps[-1]['args']
assert args['agentVersion'] == '0.1.0'
assert isinstance(args['cpuPct'], float) and isinstance(args['netRxBytes'], int)
checks = {c['serviceId']: c for c in args['checks']}
assert set(checks) == {1, 2}, "应执行任务 1/2：%s" % sorted(checks)
print("sentinel 身份上报成功：指标与检测结果齐全")
PYEOF
[ $? -eq 0 ] && ok "sentinel 身份采集并上报成功" || bad "sentinel 身份上报断言失败"
if [ -f /var/lib/sentinel-probe/probe.log ]; then
  assert_not_contains "探针日志里无令牌" /var/lib/sentinel-probe/probe.log "$TEST_TOKEN"
else
  ok "探针日志里无令牌（本次成功运行未产生日志，probe.log 不存在）"
fi

# install.sh 是否显式设置 /etc/sentinel 目录本身的权限/归属：
# write_env 只对 probe.env 文件做 chown root:sentinel + chmod 640，
# 对 ENV_DIR 目录本身没有任何 chmod/chown；若安装时 umask 较严
# （如 027/077），mkdir -p 造出的目录为 750/700 root:root，sentinel
# 无法进入目录读配置，探针以 exit 2 退出（本沙盒 umask 0007 下复现过）。
if grep -Eq 'chmod[^#]*\$ENV_DIR|chown[^#]*\$ENV_DIR' "$INSTALL"; then
  ok "install.sh 显式设置 /etc/sentinel 目录权限"
else
  bad "install.sh 未显式设置 /etc/sentinel 目录权限（依赖 ambient umask；umask 027/077 时 sentinel 读不到配置，探针 exit 2）"
fi
finish
