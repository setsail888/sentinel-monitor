#!/usr/bin/env bash
# 端到端：假面板全流程。验证任务拉取成功、检测执行、上报 JSON 合法、
# 23 个旧字段齐全且类型/单位不变、新增字段只有 bootId/countersReset/certExpiresAt、
# latencyMs 为浮点；运行期间 ps 输出里无令牌。
set -u
TEST_NAME="test_e2e"
. "$(dirname "$0")/lib/common.sh"
trap cleanup_all EXIT

TDIR=$(mk_tmp_dir)
STATE=$(mk_state_dir)
RECORD="$TDIR/panel.jsonl"
TASKS="$TDIR/tasks.txt"
URL="http://127.0.0.1:18151/"
printf '%s\n' "1|http|http://127.0.0.1:18152/ok|10" "2|tcp|127.0.0.1:18153|10" "3|ping|127.0.0.1|10" > "$TASKS"
printf '%s' "$TEST_TOKEN" > "$TDIR/token.txt"

if ping -c 1 -W 2 127.0.0.1 >/dev/null 2>&1; then PING_WORKS=1; else PING_WORKS=0; info "直连 Ping 失败（沙盒禁原始套接字），Ping 成功路径未测"; fi

start_static 18152 || finish
start_tcp_listener 18153 || finish
# reportProbe 延迟 2 秒，让探针在运行期间可被 ps 扫到。
start_panel 18151 ok "$TASKS" "$RECORD" 2 || finish

iface=$(awk '$2=="00000000" {print $1; exit}' /proc/net/route)
read -r before_rx _ <<< "$(awk -v i="$iface" '$1==i":" {print $2, $10}' /proc/net/dev)"

SENTINEL_STATE_DIR="$STATE" SENTINEL_TOKEN="$TEST_TOKEN" SENTINEL_REPORT_URL="$URL" "$PROBE" >/dev/null 2>&1 &
PROBE_PID=$!
# 探针运行期间轮询 ps，令牌不得出现在任何进程命令行里。
if scan_ps_for_token "$TDIR/token.txt" 6; then bad "ps 输出中出现令牌"; else ok "探针运行期间 ps 输出中无令牌"; fi
wait "$PROBE_PID"; rc=$?
assert_eq "探针退出码为 0" "0" "$rc"

read -r after_rx _ <<< "$(awk -v i="$iface" '$1==i":" {print $2, $10}' /proc/net/dev)"

RECORD="$RECORD" BEFORE_RX="$before_rx" AFTER_RX="$after_rx" PING_WORKS="$PING_WORKS" python3 - <<'PYEOF'
import json, os, sys

OLD_TOP = {
    'token', 'cpuPct', 'cpuCores', 'memTotalMb', 'memUsedMb',
    'diskTotalGb', 'diskUsedGb', 'netRxBytes', 'netTxBytes', 'uptimeSec',
    'load1', 'load5', 'load15', 'processes', 'tcpConns', 'udpConns',
    'swapTotalMb', 'swapUsedMb', 'agentVersion', 'os', 'hostname',
    'localDate', 'checks',
}
NEW_TOP = {'bootId', 'countersReset'}
OLD_CHECK = {'serviceId', 'ok', 'latencyMs', 'detail', 'certDaysLeft'}
NEW_CHECK = {'certExpiresAt'}

recs = [json.loads(l) for l in open(os.environ['RECORD']) if l.strip()]
for r in recs:
    json.loads(r['raw'])  # 每条原始请求体都须合法
tasks = [r for r in recs if r.get('action') == 'getProbeTasks']
reps = [r for r in recs if r.get('action') == 'reportProbe']
assert tasks, "未收到 getProbeTasks"
assert reps, "未收到 reportProbe"
args = reps[-1]['args']
keys = set(args)
assert len(OLD_TOP) == 23, len(OLD_TOP)
missing = OLD_TOP - keys
extra = keys - OLD_TOP - NEW_TOP
assert not missing, "缺失旧字段：%s" % sorted(missing)
assert not extra, "多出未知顶层字段：%s" % sorted(extra)
assert NEW_TOP <= keys, "缺失新增顶层字段：%s" % sorted(NEW_TOP - keys)
print("顶层字段：23 旧字段齐全，新增只有 bootId、countersReset")

def is_num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)

assert isinstance(args['token'], str) and args['token']
assert isinstance(args['cpuPct'], float), "cpuPct 应为浮点：%r" % args['cpuPct']
assert isinstance(args['cpuCores'], int), args['cpuCores']
assert isinstance(args['memTotalMb'], int) and isinstance(args['memUsedMb'], int)
assert isinstance(args['diskTotalGb'], float) and isinstance(args['diskUsedGb'], float)
assert isinstance(args['netRxBytes'], int) and isinstance(args['netTxBytes'], int)
assert isinstance(args['uptimeSec'], int)
for k in ('load1', 'load5', 'load15'):
    assert isinstance(args[k], float), "%s 应为浮点：%r" % (k, args[k])
assert isinstance(args['processes'], int)
assert isinstance(args['tcpConns'], int) and isinstance(args['udpConns'], int)
assert isinstance(args['swapTotalMb'], int) and isinstance(args['swapUsedMb'], int)
assert args['agentVersion'] == '0.1.0', args['agentVersion']
assert isinstance(args['os'], str) and isinstance(args['hostname'], str)
assert isinstance(args['localDate'], str) and len(args['localDate']) == 10
assert isinstance(args['bootId'], str) and args['bootId'], "bootId 应为非空字符串"
assert isinstance(args['countersReset'], bool), args['countersReset']
print("顶层字段类型与单位均与 0.0.1-beta 一致")

b, a = int(os.environ['BEFORE_RX']), int(os.environ['AFTER_RX'])
assert b <= args['netRxBytes'] <= a, (b, args['netRxBytes'], a)
print("netRxBytes=%s 落在实测区间 [%s, %s]" % (args['netRxBytes'], b, a))

checks = {c['serviceId']: c for c in args['checks']}
assert set(checks) == {1, 2, 3}, "checks 应含任务 1/2/3：%s" % sorted(checks)
for sid, c in checks.items():
    ck = set(c)
    assert ck == OLD_CHECK | NEW_CHECK, "serviceId %s 字段异常：%s" % (sid, sorted(ck))
    assert isinstance(c['ok'], bool)
    assert c['latencyMs'] is None or isinstance(c['latencyMs'], float), \
        "serviceId %s latencyMs 应为浮点或 null：%r" % (sid, c['latencyMs'])
    assert isinstance(c['detail'], str)
    assert c['certDaysLeft'] is None or isinstance(c['certDaysLeft'], int)
    assert c['certExpiresAt'] is None or isinstance(c['certExpiresAt'], int)
for sid in (1, 2):
    assert isinstance(checks[sid]['latencyMs'], float), \
        "serviceId %s latencyMs 应为浮点：%r" % (sid, checks[sid]['latencyMs'])
ping = checks[3]
if os.environ['PING_WORKS'] == '1':
    assert isinstance(ping['latencyMs'], float)
else:
    assert ping['latencyMs'] is None and ping['ok'] is False
    print("ping：沙盒禁原始套接字，ok=false、latencyMs=null（未测成功路径）")
print("checks：3 项齐全，字段=5 旧+certExpiresAt，latencyMs 为浮点")
PYEOF
[ $? -eq 0 ] && ok "端到端：字段清单、类型、单位、latencyMs 浮点均符合" || bad "端到端断言失败，见上文"
finish
