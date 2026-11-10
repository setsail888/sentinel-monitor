#!/usr/bin/env bash
# 流量统计：只统计默认路由出口、排除虚拟网卡；计数器清零检测。
set -u
TEST_NAME="test_traffic"
. "$(dirname "$0")/lib/common.sh"
trap cleanup_all EXIT

FIX_DEV="$TESTS_DIR/fixtures/proc-net-dev.txt"
FIX_ROUTE="$TESTS_DIR/fixtures/proc-net-route.txt"
TDIR=$(mk_tmp_dir)
STATE=$(mk_state_dir)
RECORD="$TDIR/panel.jsonl"
URL="http://127.0.0.1:18171/"
BOOT_ID=$(tr -d ' \t\r\n' < /proc/sys/kernel/random/boot_id 2>/dev/null || echo "")
OTHER_BOOT="00000000-0000-0000-0000-000000000000"

# 1) awk 口径模拟（与探针完全相同的取数逻辑，对夹具跑一遍）。
sim_iface=$(awk '$2=="00000000" {print $1; exit}' "$FIX_ROUTE")
assert_eq "夹具默认路由接口为 eth0" "eth0" "$sim_iface"
read -r sim_rx sim_tx <<< "$(awk -v iface="$sim_iface" '$1==iface":" {print $2, $10}' "$FIX_DEV")"
assert_eq "夹具 eth0 收字节为 111111（docker/veth/tun 未计入）" "111111" "$sim_rx"
assert_eq "夹具 eth0 发字节为 222222（docker/veth/tun 未计入）" "222222" "$sim_tx"

# 2) 夹具挂载跑真实探针：本沙盒静默忽略对 /proc 下路径的 bind 挂载
#    （mount 返回 0 但无效果、/proc/mounts 无记录；/tmp 文件的 bind 正常生效）。
#    先实测一次挂载是否生效，不生效则该子项记 SKIP，不伪造通过。
FIX_DEV="$FIX_DEV" FIX_ROUTE="$FIX_ROUTE" unshare -rm bash -c '
  mount --bind "$FIX_DEV" /proc/net/dev 2>/dev/null
  mount --bind "$FIX_ROUTE" /proc/net/route 2>/dev/null
  grep -q " 111111 " /proc/net/dev && grep -q "^eth0" /proc/net/route
' 2>/dev/null
if [ $? -ne 0 ]; then
  skip "夹具挂载跑真实探针未测：沙盒对 /proc 的 bind 挂载静默无效果（mount 返回 0，内容不变）"
else
  info "夹具挂载生效（本环境支持），但当前脚本改用真实计数器验证 countersReset，见下"
fi

# 3) 真实探针 + 真实计数器：验证 countersReset 三态与流量取数。
start_panel 18171 ok "" "$RECORD" || finish

iface=$(awk '$2=="00000000" {print $1; exit}' /proc/net/route)
info "真实默认路由接口：$iface"

last_payload() {
  RECORD="$RECORD" python3 -c "
import json, os
recs = [json.loads(l) for l in open(os.environ['RECORD']) if l.strip()]
reps = [r['args'] for r in recs if r.get('action') == 'reportProbe']
print(json.dumps(reps[-1]) if reps else '{}')
"
}

# 3a) 计数器回落：旧采样比真实值大 + 不同 bootId → countersReset=true。
read -r cur_rx cur_tx <<< "$(awk -v i="$iface" '$1==i":" {print $2, $10}' /proc/net/dev)"
printf '%s %s %s\n' "$((cur_rx + 1000000))" "$((cur_tx + 1000000))" "$OTHER_BOOT" > "$STATE/counters.prev"
read -r before_rx _ <<< "$(awk -v i="$iface" '$1==i":" {print $2, $10}' /proc/net/dev)"
run_probe "$STATE" "$URL" >/dev/null 2>&1
read -r after_rx _ <<< "$(awk -v i="$iface" '$1==i":" {print $2, $10}' /proc/net/dev)"
p=$(last_payload)
B="$before_rx" A="$after_rx" python3 -c "
import json, os, sys
d = json.load(sys.stdin)
b, a = int(os.environ['B']), int(os.environ['A'])
assert d['countersReset'] is True, d
assert b <= d['netRxBytes'] <= a, (b, d['netRxBytes'], a)
print('countersReset=true，netRxBytes 在实测区间内')
" <<< "$p" && ok "计数器回落 + bootId 变化 → countersReset=true，流量取默认出口实测值" || bad "计数器回落用例：$p（区间 $before_rx-$after_rx）"

# 3b) 正常：旧采样更小 + 相同 bootId → countersReset=false。
printf '%s %s %s\n' "100" "200" "$BOOT_ID" > "$STATE/counters.prev"
run_probe "$STATE" "$URL" >/dev/null 2>&1
p=$(last_payload)
echo "$p" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['countersReset'] is False, d
print('countersReset=false')
" && ok "计数器正常递增 + bootId 相同 → countersReset=false" || bad "正常递增用例：$p"

# 3c) 仅 bootId 变化（计数器更小）→ countersReset=true。
printf '%s %s %s\n' "100" "200" "$OTHER_BOOT" > "$STATE/counters.prev"
run_probe "$STATE" "$URL" >/dev/null 2>&1
p=$(last_payload)
echo "$p" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['countersReset'] is True, d
print('countersReset=true (仅 bootId 变化)')
" && ok "仅 bootId 变化 → countersReset=true" || bad "仅 bootId 变化用例：$p"
finish
