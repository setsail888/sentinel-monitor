#!/usr/bin/env bash
# SSL 检测：本地自签名 HTTPS，验证 certDaysLeft 与 certExpiresAt；
# 443 与 8443 用不同过期时间的证书，验证非标准端口不错取 443 的证书。
set -u
TEST_NAME="test_ssl"
. "$(dirname "$0")/lib/common.sh"
trap cleanup_all EXIT

TDIR=$(mk_tmp_dir)
STATE=$(mk_state_dir)
RECORD="$TDIR/panel.jsonl"
TASKS="$TDIR/tasks.txt"
URL="http://127.0.0.1:18121/"
printf '%s\n' "1|http|https://127.0.0.1:8443/x|10" "2|http|https://127.0.0.1:443/x|10" > "$TASKS"

openssl req -x509 -newkey rsa:2048 -keyout "$TDIR/k443.pem" -out "$TDIR/c443.pem" \
  -days 30 -nodes -subj "/CN=127.0.0.1" 2>/dev/null || { bad "生成 443 证书失败"; finish; }
openssl req -x509 -newkey rsa:2048 -keyout "$TDIR/k8443.pem" -out "$TDIR/c8443.pem" \
  -days 365 -nodes -subj "/CN=127.0.0.1" 2>/dev/null || { bad "生成 8443 证书失败"; finish; }
EXP443=$(date -d "$(openssl x509 -in "$TDIR/c443.pem" -noout -enddate | cut -d= -f2)" +%s)
EXP8443=$(date -d "$(openssl x509 -in "$TDIR/c8443.pem" -noout -enddate | cut -d= -f2)" +%s)
NOW=$(date +%s)
DAYS443=$(( (EXP443 - NOW) / 86400 ))
DAYS8443=$(( (EXP8443 - NOW) / 86400 ))
info "443 证书：过期 $EXP443（约 $DAYS443 天）；8443 证书：过期 $EXP8443（约 $DAYS8443 天）"

start_static 443 "$TDIR/c443.pem" "$TDIR/k443.pem" || finish
start_static 8443 "$TDIR/c8443.pem" "$TDIR/k8443.pem" || finish
start_panel 18121 ok "$TASKS" "$RECORD" || finish

run_probe "$STATE" "$URL" >/dev/null 2>&1
assert_eq "探针退出码为 0" "0" "$?"

RECORD="$RECORD" EXP443="$EXP443" EXP8443="$EXP8443" DAYS443="$DAYS443" DAYS8443="$DAYS8443" python3 - <<'PYEOF'
import json, os, sys
recs = [json.loads(l) for l in open(os.environ['RECORD']) if l.strip()]
reps = [r for r in recs if r.get('action') == 'reportProbe']
assert reps, "未收到 reportProbe"
checks = {c['serviceId']: c for c in reps[-1]['args']['checks']}
c1, c2 = checks.get(1), checks.get(2)
assert c1 and c2, "缺少 HTTPS 检测结果：%s" % sorted(checks)
# 自签名证书：curl 不带 -k 应拒绝，ok=false，但证书字段仍应读出。
assert c1['ok'] is False and c2['ok'] is False, "自签名应使 ok=false：%r %r" % (c1, c2)
print("自签名证书：curl 拒绝，ok=false（符合预期，未用 -k）")
for c, exp, days, port in ((c1, int(os.environ['EXP8443']), int(os.environ['DAYS8443']), 8443),
                           (c2, int(os.environ['EXP443']), int(os.environ['DAYS443']), 443)):
    assert abs(c['certExpiresAt'] - exp) <= 2, \
        "端口 %s certExpiresAt 错误：%r，期望 %s" % (port, c['certExpiresAt'], exp)
    assert abs(c['certDaysLeft'] - days) <= 1, \
        "端口 %s certDaysLeft 错误：%r，期望约 %s" % (port, c['certDaysLeft'], days)
    print("端口 %s：certDaysLeft=%s，certExpiresAt=%s（与该端口证书一致）"
          % (port, c['certDaysLeft'], c['certExpiresAt']))
assert c1['certDaysLeft'] != c2['certDaysLeft'], "8443 与 443 的剩余天数不应相同"
assert c1['certExpiresAt'] != c2['certExpiresAt'], "8443 与 443 的过期时间戳不应相同"
print("8443 未错取 443 的证书")
PYEOF
[ $? -eq 0 ] && ok "SSL：两端口证书天数与过期时间戳均正确，互不串用" || bad "SSL 断言失败，见上文"
finish
