#!/usr/bin/env bash
# 哨兵监控 Sentinel Monitor — probe agent 0.0.1-beta
# 轻量服务器监控探针：采集本机真实指标，执行分配的服务检测，
# 推送到监控面板。只出站，不开端口，不存密码。
# 用法：SENTINEL_TOKEN=<令牌> SENTINEL_REPORT_URL=<地址> ./sentinel-probe.sh
#   或：./sentinel-probe.sh <令牌> <上报地址>
set -u
TOKEN="${1:-${SENTINEL_TOKEN:-}}"
REPORT_URL="${2:-${SENTINEL_REPORT_URL:-}}"
if [ -z "$TOKEN" ] || [ -z "$REPORT_URL" ] || [ "$TOKEN" = "__TOKEN__" ] || [ "$REPORT_URL" = "__REPORT_URL__" ]; then
  echo "用法: sentinel-probe.sh <TOKEN> <REPORT_URL>" >&2
  exit 2
fi
AGENT_VERSION="0.0.1-beta"
STATE_DIR=/var/lib/sentinel-probe

esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# CPU: two /proc/stat samples 1s apart (idle = idle + iowait)
read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
sleep 1
read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat
t1=$((u1+n1+s1+i1+w1+q1+sq1+st1)); d1=$((i1+w1))
t2=$((u2+n2+s2+i2+w2+q2+sq2+st2)); d2=$((i2+w2))
cpu_pct=$(awk -v a="$t1" -v b="$t2" -v c="$d1" -v d="$d2" 'BEGIN{dt=b-a; di=d-c; if (dt<=0) print 0; else printf "%.1f", (dt-di)*100/dt}')
cpu_cores=$(nproc 2>/dev/null || echo 1)

mem_total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
mem_avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
mem_total_mb=$(awk -v k="$mem_total_kb" 'BEGIN{printf "%.0f", k/1024}')
mem_used_mb=$(awk -v t="$mem_total_kb" -v a="$mem_avail_kb" 'BEGIN{printf "%.0f", (t-a)/1024}')
swap_total_kb=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
swap_free_kb=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
swap_total_mb=$(awk -v k="${swap_total_kb:-0}" 'BEGIN{printf "%.0f", k/1024}')
swap_used_mb=$(awk -v t="${swap_total_kb:-0}" -v f="${swap_free_kb:-0}" 'BEGIN{printf "%.0f", (t-f)/1024}')

set -- $(df -B1 / | awk 'NR==2{print $2, $3}')
disk_total_gb=$(awk -v b="$1" 'BEGIN{printf "%.2f", b/1073741824}')
disk_used_gb=$(awk -v b="$2" 'BEGIN{printf "%.2f", b/1073741824}')

read -r net_rx net_tx <<< "$(awk '$1!="lo:"{rx+=$2; tx+=$10} END{printf "%.0f %.0f", rx, tx}' /proc/net/dev)"
uptime_sec=$(awk '{printf "%.0f", $1}' /proc/uptime)
read -r load1 load5 load15 _ < /proc/loadavg
processes=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l | tr -d ' ')
tcp_conns=0; udp_conns=0
for f in /proc/net/tcp /proc/net/tcp6; do [ -f "$f" ] && tcp_conns=$((tcp_conns + $(awk 'NR>1{c++} END{print c+0}' "$f"))); done
for f in /proc/net/udp /proc/net/udp6; do [ -f "$f" ] && udp_conns=$((udp_conns + $(awk 'NR>1{c++} END{print c+0}' "$f"))); done
os_name=""
if [ -r /etc/os-release ]; then . /etc/os-release; os_name="$PRETTY_NAME"; fi
host_name=$(hostname 2>/dev/null || echo "")

# ---- service checks assigned to this server (HTTP / TCP / Ping) ----
checks_json=""
tasks_resp=$(curl -fsS -m 10 -X POST "$REPORT_URL" -H 'Content-Type: application/json' -d "{\"action\":\"getProbeTasks\",\"args\":{\"token\":\"$TOKEN\"}}" 2>/dev/null | tr -d '\r')
tasks_text=$(printf '%s' "$tasks_resp" | sed -n 's/.*"tasksText":"\([^"]*\)".*/\1/p' | head -n 1)
if [ -n "$tasks_text" ]; then
  mkdir -p "$STATE_DIR" 2>/dev/null || STATE_DIR=/tmp/sentinel-probe
  mkdir -p "$STATE_DIR" 2>/dev/null
  res_file="$STATE_DIR/results.$$"
  printf '%s' "$tasks_text" | sed 's/\\n/\n/g' | while IFS='|' read -r svc_id svc_type svc_target svc_interval || [ -n "$svc_id" ]; do
    [ -n "$svc_id" ] || continue
    last_file="$STATE_DIR/check-$svc_id.last"
    last_run=0
    [ -f "$last_file" ] && last_run=$(cat "$last_file" 2>/dev/null || echo 0)
    now_s=$(date +%s)
    [ $((now_s - last_run)) -lt "$svc_interval" ] && continue
    echo "$now_s" > "$last_file" 2>/dev/null
    ok=0; latency="null"; detail=""; cert="null"
    start_ms=$(( $(date +%s) * 1000 ))
    case "$svc_type" in
      http)
        code=$(curl -o /dev/null -s -m 10 -w '%{http_code}' "$svc_target" 2>/dev/null)
        [ -n "$code" ] || code=000
        latency=$(( $(date +%s) * 1000 - start_ms ))
        detail="HTTP $code"
        case "$code" in 2*|3*) ok=1 ;; *) ok=0 ;; esac
        case "$svc_target" in
          https://*)
            if command -v openssl >/dev/null 2>&1; then
              thost=$(printf '%s' "$svc_target" | sed -e 's|^https://||' -e 's|[:/].*$||')
              enddate=$(echo | timeout 8 openssl s_client -servername "$thost" -connect "$thost:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
              if [ -n "$enddate" ]; then
                exp_s=$(date -d "$enddate" +%s 2>/dev/null || echo "")
                [ -n "$exp_s" ] && cert=$(( (exp_s - now_s) / 86400 ))
              fi
            fi
            ;;
        esac
        ;;
      tcp)
        thost=${svc_target%:*}; tport=${svc_target##*:}
        if timeout 5 bash -c "exec 3<>/dev/tcp/$thost/$tport" 2>/dev/null; then ok=1; detail="端口可连接"; else ok=0; detail="端口连接失败"; fi
        latency=$(( $(date +%s) * 1000 - start_ms ))
        ;;
      ping)
        if command -v ping >/dev/null 2>&1; then
          pout=$(ping -c 1 -W 3 "$svc_target" 2>/dev/null)
          if [ $? -eq 0 ]; then
            ok=1; detail="Ping 成功"
            ms=$(printf '%s' "$pout" | awk -F'time[=<]' 'NF>1 {split($2,a," "); print a[1]}')
            [ -n "$ms" ] && latency=$(printf '%.0f' "$ms")
          else
            ok=0; detail="Ping 无响应"
          fi
        else
          ok=0; detail="服务器未安装 ping 命令"
        fi
        ;;
      *) continue ;;
    esac
    ok_json=false; [ "$ok" = "1" ] && ok_json=true
    printf '{"serviceId":%s,"ok":%s,"latencyMs":%s,"detail":"%s","certDaysLeft":%s}\n' "$svc_id" "$ok_json" "$latency" "$(esc "$detail")" "$cert" >> "$res_file"
  done
  if [ -f "$res_file" ]; then
    checks_json=$(paste -sd, "$res_file")
    rm -f "$res_file"
  fi
fi

payload=$(printf '{"token":"%s","cpuPct":%s,"cpuCores":%s,"memTotalMb":%s,"memUsedMb":%s,"diskTotalGb":%s,"diskUsedGb":%s,"netRxBytes":%s,"netTxBytes":%s,"uptimeSec":%s,"load1":%s,"load5":%s,"load15":%s,"processes":%s,"tcpConns":%s,"udpConns":%s,"swapTotalMb":%s,"swapUsedMb":%s,"agentVersion":"%s","os":"%s","hostname":"%s","localDate":"%s","checks":[%s]}' \
  "$TOKEN" "$cpu_pct" "$cpu_cores" "$mem_total_mb" "$mem_used_mb" "$disk_total_gb" "$disk_used_gb" "$net_rx" "$net_tx" "$uptime_sec" "$load1" "$load5" "$load15" "$processes" "$tcp_conns" "$udp_conns" "$swap_total_mb" "$swap_used_mb" "$AGENT_VERSION" "$(esc "$os_name")" "$(esc "$host_name")" "$(date +%F)" "$checks_json")
curl -fsS -m 15 -X POST "$REPORT_URL" -H 'Content-Type: application/json' \
  -d "{\"action\":\"reportProbe\",\"args\":$payload}" >/dev/null
