#!/usr/bin/env bash
# HTTP/TCP/Ping 延迟：验证 latencyMs 为 1 位小数浮点毫秒。
# Ping 在本沙盒禁原始套接字时记为未测，不伪造通过。
set -u
TEST_NAME="test_latency"
. "$(dirname "$0")/lib/common.sh"
trap cleanup_all EXIT

TDIR=$(mk_tmp_dir)
STATE=$(mk_state_dir)
RECORD="$TDIR/panel.jsonl"
TASKS="$TDIR/tasks.txt"
URL="http://127.0.0.1:18111/"
printf '%s\n' "1|http|http://127.0.0.1:18112/ok|10" "2|tcp|127.0.0.1:18113|10" "3|ping|127.0.0.1|10" > "$TASKS"

if ping -c 1 -W 2 127.0.0.1 >/dev/null 2>&1; then
  PING_WORKS=1; info "直连 Ping 可用"
else
  PING_WORKS=0; skip "直连 Ping 失败（沙盒禁原始套接字），探针 Ping 成功路径未测"
fi

start_static 18112 || finish
start_tcp_listener 18113 || finish
start_panel 18111 ok "$TASKS" "$RECORD" || finish

run_probe "$STATE" "$URL" >/dev/null 2>&1
assert_eq "探针退出码为 0" "0" "$?"

RECORD="$RECORD" PING_WORKS="$PING_WORKS" python3 - <<'PYEOF'
import json, os, re, sys
recs = [json.loads(l) for l in open(os.environ['RECORD']) if l.strip()]
reps = [r for r in recs if r.get('action') == 'reportProbe']
assert reps, "未收到 reportProbe"
raw = reps[-1]['raw']
checks = {c['serviceId']: c for c in reps[-1]['args']['checks']}
ok = True
for sid in (1, 2):
    c = checks.get(sid)
    assert c is not None, "缺少 serviceId %s" % sid
    lat = c['latencyMs']
    assert isinstance(lat, float), "serviceId %s latencyMs 不是浮点：%r" % (sid, lat)
    assert re.search(r'"latencyMs":%s' % re.escape(('%.1f' % lat)), raw), \
        "serviceId %s 原始 JSON 不是 1 位小数：%s" % (sid, raw)
    print("serviceId %s latencyMs=%.1f（浮点，1 位小数）" % (sid, lat))
ping = checks.get(3)
assert ping is not None, "缺少 ping 任务结果"
if os.environ['PING_WORKS'] == '1':
    assert isinstance(ping['latencyMs'], float), "ping latencyMs 不是浮点：%r" % ping['latencyMs']
    print("ping latencyMs=%.1f" % ping['latencyMs'])
else:
    assert ping['latencyMs'] is None, "沙盒禁 ping 时 latencyMs 应为 null：%r" % ping['latencyMs']
    assert ping['ok'] is False, "沙盒禁 ping 时 ok 应为 false"
    print("ping：沙盒禁原始套接字，探针如实返回 ok=false、latencyMs=null（未测成功路径）")
PYEOF
[ $? -eq 0 ] && ok "延迟均为 1 位小数浮点毫秒（Ping 按沙盒能力处理）" || bad "延迟断言失败，见上文"
finish
