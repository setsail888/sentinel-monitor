#!/usr/bin/env bash
# 哨兵监控 Sentinel Monitor — probe agent 0.1.0
# 轻量服务器监控探针：采集本机真实指标，执行分配的服务检测，
# 推送到监控面板。只出站，不开端口，不存密码。
# 用法：SENTINEL_TOKEN=<令牌> SENTINEL_REPORT_URL=<地址> ./sentinel-probe.sh
#   或：./sentinel-probe.sh <令牌> <上报地址>
#   或：由安装器写入 /etc/sentinel/probe.env 后直接运行（无参数时自动读取）。
set -u

AGENT_VERSION="0.1.0"
STATE_DIR="${SENTINEL_STATE_DIR:-/var/lib/sentinel-probe}"
LOG_FILE="$STATE_DIR/probe.log"
SPOOL_FILE="$STATE_DIR/failed-spool.jsonl"
COUNTERS_FILE="$STATE_DIR/counters.prev"

# ---------- 配置：参数 > 环境变量 > /etc/sentinel/probe.env ----------
TOKEN="${1:-${SENTINEL_TOKEN:-}}"
REPORT_URL="${2:-${SENTINEL_REPORT_URL:-}}"
if [ -z "$TOKEN" ] || [ -z "$REPORT_URL" ]; then
  if [ -r /etc/sentinel/probe.env ]; then
    set -a
    # shellcheck source=/dev/null
    . /etc/sentinel/probe.env
    set +a
    TOKEN="${TOKEN:-${SENTINEL_TOKEN:-}}"
    REPORT_URL="${REPORT_URL:-${SENTINEL_REPORT_URL:-}}"
  fi
fi
if [ -z "$TOKEN" ] || [ -z "$REPORT_URL" ] \
    || [ "$TOKEN" = "__TOKEN__" ] || [ "$REPORT_URL" = "__REPORT_URL__" ]; then
  echo "用法: sentinel-probe.sh <TOKEN> <REPORT_URL>" >&2
  echo "或先由安装器写入 /etc/sentinel/probe.env 再直接运行。" >&2
  exit 2
fi

# ---------- 状态目录：建不出来就报错退出，不回退到 /tmp ----------
if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
  echo "错误：无法创建状态目录 $STATE_DIR" >&2
  exit 1
fi
if [ "$(id -u)" -eq 0 ] && id sentinel >/dev/null 2>&1; then
  chown sentinel:sentinel "$STATE_DIR" 2>/dev/null || true
fi

# ---------- 日志：轮转约 200KB 保留 1 个备份；有 logger 时同时写 syslog ----------
# 日志里绝不出现令牌或上报体。
log() {
  local msg="$1" size
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S %Z')
  if [ -f "$LOG_FILE" ]; then
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$size" -gt 204800 ]; then
      mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
    fi
  fi
  printf '%s %s\n' "$ts" "$msg" >> "$LOG_FILE" 2>/dev/null || true
  if command -v logger >/dev/null 2>&1; then
    logger -t sentinel-probe -- "$msg" 2>/dev/null || true
  fi
}

# ---------- 防重叠运行 ----------
# 先验证锁文件可写，再开 fd（exec 的重定向会永久生效，不能带 2>/dev/null）。
if ! : > "$STATE_DIR/probe.lock" 2>/dev/null; then
  echo "错误：无法创建锁文件 $STATE_DIR/probe.lock" >&2
  exit 1
fi
exec 9>"$STATE_DIR/probe.lock"
if [ "$(id -u)" -eq 0 ] && id sentinel >/dev/null 2>&1; then
  chown sentinel:sentinel "$STATE_DIR/probe.lock" 2>/dev/null || true
fi
if ! flock -n 9 2>/dev/null; then
  echo "上一次探针仍在运行，本次跳过。" >&2
  exit 0
fi

# ---------- JSON 转义：纯 bash，处理全部控制字符 ----------
json_escape() {
  local s="$1" out="" c hex code i len
  len=${#s}
  for ((i = 0; i < len; i++)); do
    c="${s:i:1}"
    case "$c" in
      '\') out+='\\' ;;
      '"') out+='\"' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      $'\b') out+='\b' ;;
      $'\f') out+='\f' ;;
      [$'\x01'-$'\x1f'])
        printf -v code '%d' "'$c"
        printf -v hex '\\u%04x' "$code"
        out+="$hex" ;;
      *) out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# ---------- 数值校验：不合规填 null 并记日志（只记字段名，不记值） ----------
num_or_null() {
  local field="$1" v="$2"
  if [ "$v" = "null" ]; then
    printf 'null'
  elif [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    printf '%s' "$v"
  else
    log "WARN: 字段 $field 不是合法数字，已填 null"
    printf 'null'
  fi
}

is_int() { [[ "$1" =~ ^-?[0-9]+$ ]]; }

# ---------- CPU：两次 /proc/stat 采样，间隔 1 秒 ----------
read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
sleep 1
read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat
t1=$((u1 + n1 + s1 + i1 + w1 + q1 + sq1 + st1)); d1=$((i1 + w1))
t2=$((u2 + n2 + s2 + i2 + w2 + q2 + sq2 + st2)); d2=$((i2 + w2))
cpu_pct=$(awk -v a="$t1" -v b="$t2" -v c="$d1" -v d="$d2" 'BEGIN{dt=b-a; di=d-c; if (dt<=0) print 0; else printf "%.1f", (dt-di)*100/dt}')
cpu_cores=$(nproc 2>/dev/null || echo 1)

# ---------- 内存 / Swap ----------
mem_total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
mem_avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
mem_total_mb=$(awk -v k="$mem_total_kb" 'BEGIN{printf "%.0f", k/1024}')
mem_used_mb=$(awk -v t="$mem_total_kb" -v a="$mem_avail_kb" 'BEGIN{printf "%.0f", (t-a)/1024}')
swap_total_kb=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
swap_free_kb=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
swap_total_mb=$(awk -v k="${swap_total_kb:-0}" 'BEGIN{printf "%.0f", k/1024}')
swap_used_mb=$(awk -v t="${swap_total_kb:-0}" -v f="${swap_free_kb:-0}" 'BEGIN{printf "%.0f", (t-f)/1024}')

# ---------- 磁盘：根分区（口径不变） ----------
disk_total_b=0; disk_used_b=0
read -r _ disk_total_b disk_used_b _ < <(df -B1 / 2>/dev/null | awk 'NR==2{print $1, $2, $3, $4}')
disk_total_gb=$(awk -v b="$disk_total_b" 'BEGIN{printf "%.2f", b/1073741824}')
disk_used_gb=$(awk -v b="$disk_used_b" 'BEGIN{printf "%.2f", b/1073741824}')

# ---------- 流量：只统计默认路由出口接口（0.1.0 起口径变更） ----------
# 从 /proc/net/route 取默认出口，不依赖 ip 命令；容器/虚拟网卡/隧道接口不再重复计量。
net_rx=0; net_tx=0
default_iface=$(awk '$2=="00000000" {print $1; exit}' /proc/net/route 2>/dev/null)
if [ -n "$default_iface" ]; then
  read -r net_rx net_tx <<< "$(awk -v iface="$default_iface" '$1==iface":" {print $2, $10}' /proc/net/dev 2>/dev/null)"
  is_int "$net_rx" || net_rx=0
  is_int "$net_tx" || net_tx=0
else
  log "WARN: 未找到默认路由接口，流量计数记为 0"
fi

# ---------- 计数器清零检测：本次计数器小于上次采样即为 true ----------
# 只存一份最小的上次采样（收/发计数器 + bootId），不做速率计算，不做月度状态。
boot_id=$(tr -d ' \t\r\n' < /proc/sys/kernel/random/boot_id 2>/dev/null || echo "")
counters_reset=false
if [ -f "$COUNTERS_FILE" ]; then
  read -r prev_rx prev_tx prev_boot < "$COUNTERS_FILE" 2>/dev/null || true
  if is_int "${prev_rx:-x}" && is_int "${prev_tx:-x}"; then
    if [ "$net_rx" -lt "$prev_rx" ] || [ "$net_tx" -lt "$prev_tx" ] \
        || { [ -n "$boot_id" ] && [ -n "${prev_boot:-}" ] && [ "$boot_id" != "$prev_boot" ]; }; then
      counters_reset=true
      log "INFO: 检测到计数器清零或重启（bootId 变化或计数器回落）"
    fi
  fi
fi
printf '%s %s %s\n' "$net_rx" "$net_tx" "$boot_id" > "$COUNTERS_FILE" 2>/dev/null || true

uptime_sec=$(awk '{printf "%.0f", $1}' /proc/uptime)
read -r load1 load5 load15 _ < /proc/loadavg
processes=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l | tr -d ' ')
tcp_conns=0; udp_conns=0
for f in /proc/net/tcp /proc/net/tcp6; do
  [ -f "$f" ] && tcp_conns=$((tcp_conns + $(awk 'NR>1{c++} END{print c+0}' "$f")))
done
for f in /proc/net/udp /proc/net/udp6; do
  [ -f "$f" ] && udp_conns=$((udp_conns + $(awk 'NR>1{c++} END{print c+0}' "$f")))
done
# /etc/os-release 用 grep 解析，不 source（避免执行其中内容）。
os_name=""
if [ -r /etc/os-release ]; then
  os_name=$(grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//')
fi
host_name=$(hostname 2>/dev/null || echo "")

# ---------- 服务检测：先拉取面板下发的任务 ----------
checks_json=""
invalid_skipped=0
tasks_file=$(mktemp "$STATE_DIR/tasks.XXXXXX")
req_file=$(mktemp "$STATE_DIR/req.XXXXXX")
trap 'rm -f "$tasks_file" "$req_file"' EXIT
printf '{"action":"getProbeTasks","args":{"token":"%s"}}' "$(json_escape "$TOKEN")" > "$req_file"
tasks_fetch_ok=0
if curl -fsS -m 10 -X POST "$REPORT_URL" -H 'Content-Type: application/json' \
    --data-binary @"$req_file" -o "$tasks_file" 2>/dev/null; then
  tasks_fetch_ok=1
else
  log "WARN: 任务拉取失败，本次不做服务检测"
fi

if [ "$tasks_fetch_ok" -eq 1 ]; then
  tasks_resp=$(tr -d '\r' < "$tasks_file")
  tasks_text=$(printf '%s' "$tasks_resp" | sed -n 's/.*"tasksText"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  if [ -n "$tasks_text" ]; then
    res_file=$(mktemp "$STATE_DIR/results.XXXXXX")
    printf '%s' "$tasks_text" | sed 's/\\n/\n/g' | while IFS='|' read -r svc_id svc_type svc_target svc_interval || [ -n "$svc_id" ]; do
      # ---- 集中校验：任一字段非法则整行跳过并计数 ----
      valid=1
      [[ "$svc_id" =~ ^[0-9]+$ ]] || valid=0
      case "$svc_type" in http|tcp|ping) ;; *) valid=0 ;; esac
      if ! [[ "$svc_interval" =~ ^[0-9]+$ ]] || [ "$svc_interval" -lt 10 ] || [ "$svc_interval" -gt 86400 ]; then
        valid=0
      fi
      # 目标不得以 - 开头（防选项注入，如 ping -127.0.0.1 / ping --help）
      case "$svc_target" in -*) valid=0 ;; esac
      case "$svc_type" in
        http)
          [[ "$svc_target" =~ ^https?://[A-Za-z0-9._~%\-]+(:[0-9]{1,5})?([/?#][^[:space:]\"\\]*)?$ ]] || valid=0
          ;;
        tcp)
          t_host="${svc_target%:*}"; t_port="${svc_target##*:}"
          if ! [[ "$t_port" =~ ^[0-9]+$ ]] || [ "$t_port" -lt 1 ] || [ "$t_port" -gt 65535 ]; then
            valid=0
          elif [[ "$t_host" =~ ^\[[0-9A-Fa-f:]+\]$ ]] || [[ "$t_host" =~ ^[A-Za-z0-9._-]+$ ]]; then
            :
          else
            valid=0
          fi
          ;;
        ping)
          [[ "$svc_target" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "$svc_target" =~ ^[0-9A-Fa-f:]+$ ]] || valid=0
          ;;
      esac
      if [ "$valid" -eq 0 ]; then
        echo "skip" >> "$STATE_DIR/.invalid_marker"
        continue
      fi
      # ---- 节流：上次成功检测未满间隔则跳过 ----
      last_file="$STATE_DIR/check-$svc_id.last"
      last_run=0
      if [ -f "$last_file" ]; then
        last_run=$(cat "$last_file" 2>/dev/null || echo 0)
        is_int "$last_run" || last_run=0
      fi
      now_s=$(date +%s)
      if [ $((now_s - last_run)) -lt "$svc_interval" ]; then
        continue
      fi
      ok=0; latency="null"; detail=""; cert="null"; cert_exp="null"
      case "$svc_type" in
        http)
          start_ms=$(date +%s%3N)
          http_out=$(curl -o /dev/null -s -m 10 -w '%{http_code} %{time_total}' "$svc_target" 2>/dev/null || echo "000 0")
          code="${http_out%% *}"; secs="${http_out##* }"
          # curl 失败（000）表示未测出延迟，与 Ping 失败口径一致记 null，不记 0.0
          if [ "$code" = "000" ]; then latency="null"; else latency=$(awk -v s="$secs" 'BEGIN{printf "%.1f", s*1000}'); fi
          detail="HTTP $code"
          case "$code" in 2*|3*) ok=1 ;; *) ok=0 ;; esac
          case "$svc_target" in
            https://*)
              if command -v openssl >/dev/null 2>&1; then
                # 分离 host 与 port（默认 443）；IPv6 连接用方括号，SNI 去括号。
                rest="${svc_target#https://}"
                authority="${rest%%/*}"
                if [[ "$authority" =~ ^\[([0-9A-Fa-f:]+)\](:([0-9]+))?$ ]]; then
                  sni_host="${BASH_REMATCH[1]}"
                  cert_port="${BASH_REMATCH[3]:-443}"
                  connect_host="[$sni_host]:$cert_port"
                else
                  sni_host="${authority%%:*}"
                  cert_port="${authority##*:}"
                  [[ "$cert_port" =~ ^[0-9]+$ ]] || cert_port=443
                  [ "$cert_port" = "$authority" ] && cert_port=443
                  connect_host="$sni_host:$cert_port"
                fi
                enddate=$(echo | timeout 8 openssl s_client -servername "$sni_host" -connect "$connect_host" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
                if [ -n "$enddate" ]; then
                  exp_s=$(date -d "$enddate" +%s 2>/dev/null || echo "")
                  if [ -n "$exp_s" ] && is_int "$exp_s"; then
                    cert=$(( (exp_s - now_s) / 86400 ))
                    cert_exp="$exp_s"
                  fi
                fi
              fi
              ;;
          esac
          ;;
        tcp)
          t_host="${svc_target%:*}"; t_port="${svc_target##*:}"
          start_ms=$(date +%s%3N)
          # 位置参数写法：目标不拼进 bash -c 字符串，防注入。
          if timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$t_host" "$t_port" 2>/dev/null; then
            ok=1; detail="端口可连接"
          else
            ok=0; detail="端口连接失败"
          fi
          end_ms=$(date +%s%3N)
          latency=$(awk -v a="$start_ms" -v b="$end_ms" 'BEGIN{printf "%.1f", b-a}')
          ;;
        ping)
          if command -v ping >/dev/null 2>&1; then
            pout=$(ping -c 1 -W 3 "$svc_target" 2>/dev/null)
            if [ $? -eq 0 ]; then
              ok=1; detail="Ping 成功"
              ms=$(printf '%s' "$pout" | awk -F'time[=<]' 'NF>1 {split($2,a," "); print a[1]}')
              if [ -n "$ms" ] && [[ "$ms" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                latency=$(awk -v m="$ms" 'BEGIN{printf "%.1f", m}')
              fi
            else
              ok=0; detail="Ping 无响应"
            fi
          else
            ok=0; detail="服务器未安装 ping 命令"
          fi
          ;;
      esac
      # 检测成功（ok=1）后才写 .last；失败用较短重试间隔（下次运行即重试）。
      if [ "$ok" -eq 1 ]; then
        echo "$now_s" > "$last_file" 2>/dev/null || true
      fi
      ok_json=false; [ "$ok" = "1" ] && ok_json=true
      latency_json=$(num_or_null "latencyMs" "$latency")
      cert_json=$(num_or_null "certDaysLeft" "$cert")
      cert_exp_json=$(num_or_null "certExpiresAt" "$cert_exp")
      printf '{"serviceId":%s,"ok":%s,"latencyMs":%s,"detail":"%s","certDaysLeft":%s,"certExpiresAt":%s}\n' \
        "$svc_id" "$ok_json" "$latency_json" "$(json_escape "$detail")" "$cert_json" "$cert_exp_json" >> "$res_file"
    done
    if [ -f "$STATE_DIR/.invalid_marker" ]; then
      invalid_skipped=$(wc -l < "$STATE_DIR/.invalid_marker" | tr -d ' ')
      rm -f "$STATE_DIR/.invalid_marker"
    fi
    if [ -f "$res_file" ]; then
      checks_json=$(paste -sd, "$res_file")
      rm -f "$res_file"
    fi
  fi
fi
if [ "$invalid_skipped" -gt 0 ]; then
  log "WARN: 本次跳过非法任务行 $invalid_skipped 行"
fi

# ---------- 组装上报体：令牌同样转义；数值先校验 ----------
payload_file=$(mktemp "$STATE_DIR/payload.XXXXXX")
trap 'rm -f "$tasks_file" "$req_file" "$payload_file"' EXIT
{
  printf '{"token":"%s"' "$(json_escape "$TOKEN")"
  printf ',"cpuPct":%s' "$(num_or_null "cpuPct" "$cpu_pct")"
  printf ',"cpuCores":%s' "$(num_or_null "cpuCores" "$cpu_cores")"
  printf ',"memTotalMb":%s' "$(num_or_null "memTotalMb" "$mem_total_mb")"
  printf ',"memUsedMb":%s' "$(num_or_null "memUsedMb" "$mem_used_mb")"
  printf ',"diskTotalGb":%s' "$(num_or_null "diskTotalGb" "$disk_total_gb")"
  printf ',"diskUsedGb":%s' "$(num_or_null "diskUsedGb" "$disk_used_gb")"
  printf ',"netRxBytes":%s' "$(num_or_null "netRxBytes" "$net_rx")"
  printf ',"netTxBytes":%s' "$(num_or_null "netTxBytes" "$net_tx")"
  printf ',"uptimeSec":%s' "$(num_or_null "uptimeSec" "$uptime_sec")"
  printf ',"load1":%s' "$(num_or_null "load1" "$load1")"
  printf ',"load5":%s' "$(num_or_null "load5" "$load5")"
  printf ',"load15":%s' "$(num_or_null "load15" "$load15")"
  printf ',"processes":%s' "$(num_or_null "processes" "$processes")"
  printf ',"tcpConns":%s' "$(num_or_null "tcpConns" "$tcp_conns")"
  printf ',"udpConns":%s' "$(num_or_null "udpConns" "$udp_conns")"
  printf ',"swapTotalMb":%s' "$(num_or_null "swapTotalMb" "$swap_total_mb")"
  printf ',"swapUsedMb":%s' "$(num_or_null "swapUsedMb" "$swap_used_mb")"
  printf ',"agentVersion":"%s"' "$AGENT_VERSION"
  printf ',"os":"%s"' "$(json_escape "$os_name")"
  printf ',"hostname":"%s"' "$(json_escape "$host_name")"
  printf ',"localDate":"%s"' "$(date +%F)"
  printf ',"bootId":"%s"' "$(json_escape "$boot_id")"
  printf ',"countersReset":%s' "$counters_reset"
  printf ',"checks":[%s]}' "$checks_json"
} > "$payload_file"

# 请求体用 --data-binary @文件发送，令牌不出现在进程参数里。
report_req=$(mktemp "$STATE_DIR/reportreq.XXXXXX")
trap 'rm -f "$tasks_file" "$req_file" "$payload_file" "$report_req"' EXIT
{
  printf '{"action":"reportProbe","args":'
  cat "$payload_file"
  printf '}'
} > "$report_req"

# ---------- 上报：失败有限重试 3 次（退避 2s/5s），每次超时 15s ----------
report_ok=0
attempt=1
while [ "$attempt" -le 3 ]; do
  http_code=$(curl -fsS -m 15 -o /dev/null -w '%{http_code}' -X POST "$REPORT_URL" \
    -H 'Content-Type: application/json' --data-binary @"$report_req" 2>/dev/null)
  [ -n "$http_code" ] || http_code="000"
  case "$http_code" in
    2*) report_ok=1; break ;;
    *) log "WARN: 上报失败（第 $attempt 次，HTTP $http_code）" ;;
  esac
  if [ "$attempt" -eq 1 ]; then sleep 2; elif [ "$attempt" -eq 2 ]; then sleep 5; fi
  attempt=$((attempt + 1))
done

if [ "$report_ok" -eq 1 ]; then
  exit 0
fi
# 失败的上报 payload 存入 spool 备查（上限 1MB 轮转），不自动补发旧指标
# （面板按计数器差值累计，补发旧值可能算出负增量）。
log "ERROR: 上报失败（已重试 3 次），payload 已存入 spool 备查，不自动补发"
if [ -f "$SPOOL_FILE" ]; then
  spool_size=$(stat -c%s "$SPOOL_FILE" 2>/dev/null || echo 0)
  if [ "$spool_size" -gt 1048576 ]; then
    mv -f "$SPOOL_FILE" "$SPOOL_FILE.1" 2>/dev/null || true
  fi
fi
cat "$payload_file" >> "$SPOOL_FILE" 2>/dev/null || true
printf '\n' >> "$SPOOL_FILE" 2>/dev/null || true
exit 1
