#!/usr/bin/env bash
# 哨兵监控一键安装脚本
# 用法：curl -sSL https://raw.githubusercontent.com/setsail888/sentinel-monitor/main/install.sh | bash -s -- <TOKEN> <REPORT_URL>
# 令牌和上报地址从 VPS Manager Pro 的探针安装命令里拿。
set -e
TOKEN="${1:-}"
REPORT_URL="${2:-}"
if [ -z "$TOKEN" ] || [ -z "$REPORT_URL" ]; then
  echo "用法: install.sh <TOKEN> <REPORT_URL>" >&2
  exit 2
fi
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; else SUDO=""; fi
PROBE_URL="https://raw.githubusercontent.com/setsail888/sentinel-monitor/main/sentinel-probe.sh"

$SUDO mkdir -p /usr/local/bin
$SUDO curl -fsSL "$PROBE_URL" -o /usr/local/bin/sentinel-probe.sh
$SUDO chmod +x /usr/local/bin/sentinel-probe.sh
$SUDO mkdir -p /etc/sentinel
printf 'SENTINEL_TOKEN="%s"\nSENTINEL_REPORT_URL="%s"\n' "$TOKEN" "$REPORT_URL" | $SUDO tee /etc/sentinel/probe.env >/dev/null
$SUDO chmod 600 /etc/sentinel/probe.env

if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
  $SUDO tee /etc/systemd/system/sentinel-probe.service >/dev/null <<'EOF'
[Unit]
Description=哨兵监控探针
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/sentinel/probe.env
ExecStart=/usr/local/bin/sentinel-probe.sh
EOF
  $SUDO tee /etc/systemd/system/sentinel-probe.timer >/dev/null <<'EOF'
[Unit]
Description=每 60 秒运行哨兵监控探针

[Timer]
OnBootSec=20s
OnUnitActiveSec=60s
AccuracySec=5s
Unit=sentinel-probe.service

[Install]
WantedBy=timers.target
EOF
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now sentinel-probe.timer
  echo "哨兵监控已安装：systemd timer 每 60 秒上报"
else
  (crontab -l 2>/dev/null | grep -v sentinel-probe; echo "* * * * * bash -c 'set -a; . /etc/sentinel/probe.env; exec /usr/local/bin/sentinel-probe.sh'") | crontab -
  echo "哨兵监控已安装：cron 每分钟上报"
fi

$SUDO bash -c 'set -a; . /etc/sentinel/probe.env; exec /usr/local/bin/sentinel-probe.sh' && echo "首次上报已发送"
