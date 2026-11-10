#!/usr/bin/env bash
# 哨兵监控 Sentinel Monitor — 一键安装脚本 0.1.0
# 用法（以 root 执行，命令里不带 sudo）：
#   curl -sSL https://raw.githubusercontent.com/setsail888/sentinel-monitor/v0.1.0/install.sh | bash -s -- <TOKEN> <REPORT_URL>
#   install.sh --update [版本]   # 升级探针，不指定版本时升到 0.1.0
#   install.sh --uninstall       # 卸载
#   install.sh --version         # 显示版本
#   install.sh --help            # 显示帮助
# 令牌和上报地址从 VPS Manager Pro 的探针安装命令里拿。
set -u

DEFAULT_VERSION="0.1.0"
REPO="setsail888/sentinel-monitor"
PROBE_NAME="sentinel-probe.sh"
PROBE_PATH="/usr/local/bin/sentinel-probe.sh"
ENV_DIR="/etc/sentinel"
ENV_FILE="/etc/sentinel/probe.env"
STATE_DIR="/var/lib/sentinel-probe"
SERVICE_FILE="/etc/systemd/system/sentinel-probe.service"
TIMER_FILE="/etc/systemd/system/sentinel-probe.timer"

if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; else SUDO=""; fi

die() { echo "错误：$*" >&2; exit 1; }
info() { echo "$*"; }

usage() {
  cat <<EOF
用法：
  install.sh <TOKEN> <REPORT_URL>   安装哨兵监控探针（首次上报失败会报错退出）
  install.sh --update [版本]        升级探针；不指定版本时升到 $DEFAULT_VERSION
  install.sh --uninstall            卸载探针（含定时任务、配置与状态数据）
  install.sh --version              显示版本
  install.sh --help                 显示本帮助

令牌和上报地址从 VPS Manager Pro 的探针安装命令里拿。
安装后探针每 60 秒上报一次（systemd timer；无 systemd 时用 cron）。
EOF
}

# ---------- 校验 ----------
valid_token() { [[ "$1" =~ ^[A-Za-z0-9_-]{16,128}$ ]]; }

valid_url() {
  local u="$1"
  case "$u" in
    https://*) ;;
    *) return 1 ;;
  esac
  # 主机部分不能为空，且不能以 / 或 : 开头（拒绝裸 https:// 这类无效地址）
  rest="${u#https://}"
  case "$rest" in ""|/*|:*) return 1 ;; esac
  case "$u" in
    *[[:space:]]*|*\"*|*"'"*|*"<"*|*">"*|*__TOKEN__*|*__REPORT_URL__*) return 1 ;;
  esac
  return 0
}

valid_version() { [[ "$1" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; }

# 以 sentinel 用户运行一次探针（首次上报 / 升级验证用）。
run_probe_as_sentinel() {
  if command -v runuser >/dev/null 2>&1; then
    runuser -u sentinel -- "$PROBE_PATH"
  elif command -v su >/dev/null 2>&1; then
    su -s /bin/bash sentinel -c "$PROBE_PATH"
  elif [ -n "$SUDO" ]; then
    $SUDO -u sentinel "$PROBE_PATH"
  else
    "$PROBE_PATH"
  fi
}

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ] && [ -d /run/systemd/system ]
}

# ---------- 依赖检查 ----------
check_deps() {
  command -v curl >/dev/null 2>&1 || die "缺少必需依赖 curl，请先安装（apt install curl）"
  command -v sha256sum >/dev/null 2>&1 || info "警告：缺少 sha256sum，无法校验探针文件完整性"
  if ! has_systemd && ! command -v crontab >/dev/null 2>&1; then
    die "缺少 systemctl 与 crontab，无法设置定时上报"
  fi
  command -v openssl >/dev/null 2>&1 || info "警告：缺少 openssl，HTTPS 证书剩余天数将无法检测"
  command -v ping >/dev/null 2>&1 || info "警告：缺少 ping 命令，Ping 检测将无法执行"
}

# ---------- 下载并校验探针（版本固定，不走 main 分支） ----------
# 用法：download_probe <版本>；成功后下载文件路径写入 $TMP_PROBE。
TMP_PROBE=""
TMP_SUM=""
download_probe() {
  local ver="$1" tag="v$1"
  local base="https://raw.githubusercontent.com/$REPO/$tag"
  TMP_PROBE=$(mktemp /tmp/sentinel-probe.XXXXXX)
  TMP_SUM=$(mktemp /tmp/sentinel-probe-sha256.XXXXXX)
  info "正在下载探针 $tag ..."
  curl -fsSL "$base/$PROBE_NAME" -o "$TMP_PROBE" \
    || { rm -f "$TMP_PROBE" "$TMP_SUM"; die "下载探针失败：$base/$PROBE_NAME"; }
  if curl -fsSL "$base/$PROBE_NAME.sha256" -o "$TMP_SUM" 2>/dev/null; then
    if command -v sha256sum >/dev/null 2>&1; then
      local expect actual
      expect=$(awk '{print $1}' "$TMP_SUM")
      actual=$(sha256sum "$TMP_PROBE" | awk '{print $1}')
      if [ -n "$expect" ] && [ "$expect" = "$actual" ]; then
        info "SHA256 校验通过"
      else
        rm -f "$TMP_PROBE" "$TMP_SUM"
        die "SHA256 校验不匹配，已中止（文件可能被篡改）"
      fi
    else
      info "警告：缺少 sha256sum，跳过校验"
    fi
  else
    info "警告：未下载到校验文件，跳过 SHA256 校验"
  fi
}

# ---------- 原子替换探针文件，保留一次 .bak 备份 ----------
install_probe_file() {
  $SUDO mkdir -p /usr/local/bin
  if [ -f "$PROBE_PATH" ]; then
    $SUDO cp -f "$PROBE_PATH" "$PROBE_PATH.bak" 2>/dev/null || true
  fi
  $SUDO cp -f "$TMP_PROBE" "$PROBE_PATH.tmp"
  $SUDO chmod 755 "$PROBE_PATH.tmp"
  $SUDO mv -f "$PROBE_PATH.tmp" "$PROBE_PATH"
}

ensure_sentinel_user() {
  if ! id sentinel >/dev/null 2>&1; then
    $SUDO useradd --system --no-create-home --shell /usr/sbin/nologin sentinel \
      || die "创建专用用户 sentinel 失败"
  fi
}

# ---------- 写配置：umask 077 + 单引号安全写法，root:sentinel 640 ----------
write_env() {
  local token="$1" url="$2"
  case "$token$url" in
    *"'"*) die "配置值含非法字符" ;;
  esac
  $SUDO mkdir -p "$ENV_DIR" "$STATE_DIR"
  ( umask 077
    printf "SENTINEL_TOKEN='%s'\nSENTINEL_REPORT_URL='%s'\n" "$token" "$url" | $SUDO tee "$ENV_FILE" >/dev/null
  )
  $SUDO chown root:sentinel "$ENV_FILE"
  $SUDO chmod 640 "$ENV_FILE"
  # 配置目录本身也要显式定权限，不依赖安装时的 umask（否则 umask 007 下 sentinel 读不到配置）
  $SUDO chown root:sentinel "$ENV_DIR"
  $SUDO chmod 750 "$ENV_DIR"
  $SUDO chown sentinel:sentinel "$STATE_DIR"
  $SUDO chmod 750 "$STATE_DIR"
}

# ---------- 定时任务：systemd timer 为主，cron 兼容 ----------
setup_schedule() {
  if has_systemd; then
    $SUDO tee "$SERVICE_FILE" >/dev/null <<'EOF'
[Unit]
Description=哨兵监控探针
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=sentinel
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/sentinel-probe
CapabilityBoundingSet=CAP_NET_RAW
AmbientCapabilities=CAP_NET_RAW
ProtectKernelTunables=true
ProtectControlGroups=true
LockPersonality=true
StateDirectory=sentinel-probe
EnvironmentFile=/etc/sentinel/probe.env
ExecStart=/usr/local/bin/sentinel-probe.sh
EOF
    $SUDO tee "$TIMER_FILE" >/dev/null <<'EOF'
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
    info "哨兵监控已安装：systemd timer 每 60 秒上报"
  else
    local new_cron
    new_cron=$( { $SUDO crontab -u sentinel -l 2>/dev/null | grep -v sentinel-probe; echo "* * * * * /usr/local/bin/sentinel-probe.sh"; } )
    if printf '%s\n' "$new_cron" | $SUDO crontab -u sentinel - 2>/dev/null; then
      info "哨兵监控已安装：cron 每分钟上报"
    elif command -v runuser >/dev/null 2>&1; then
      ( crontab -l 2>/dev/null | grep -v sentinel-probe; echo "* * * * * runuser -u sentinel -- /usr/local/bin/sentinel-probe.sh" ) | crontab -
      info "哨兵监控已安装：cron 每分钟上报"
    else
      ( crontab -l 2>/dev/null | grep -v sentinel-probe; echo "* * * * * su -s /bin/bash sentinel -c /usr/local/bin/sentinel-probe.sh" ) | crontab -
      info "哨兵监控已安装：cron 每分钟上报"
    fi
  fi
}

do_install() {
  local token="$1" url="$2"
  valid_token "$token" || die "令牌格式无效：须为 16–128 位字母、数字、下划线或连字符"
  valid_url "$url" || die "上报地址无效：须为 https:// 开头的真实地址（不要用占位符）"
  check_deps
  download_probe "$DEFAULT_VERSION"
  install_probe_file
  ensure_sentinel_user
  write_env "$token" "$url"
  setup_schedule
  rm -f "$TMP_PROBE" "$TMP_SUM"
  info "正在做首次上报验证 ..."
  if run_probe_as_sentinel; then
    info "首次上报已发送，安装完成"
  else
    die "首次上报失败：请检查上报地址与网络，探针已安装但未成功上报（详见 /var/lib/sentinel-probe/probe.log）"
  fi
}

do_update() {
  local ver="${1:-$DEFAULT_VERSION}"
  valid_version "$ver" || die "版本号格式无效：如 0.1.0 或 v0.1.0"
  ver="${ver#v}"
  [ -f "$PROBE_PATH" ] || die "未找到已安装的探针，请先用 install.sh <TOKEN> <REPORT_URL> 安装"
  check_deps
  download_probe "$ver"
  install_probe_file
  rm -f "$TMP_PROBE" "$TMP_SUM"
  if has_systemd; then
    $SUDO systemctl daemon-reload
    $SUDO systemctl restart sentinel-probe.timer 2>/dev/null || true
  fi
  info "探针已升级到 $ver，正在验证上报 ..."
  if run_probe_as_sentinel; then
    info "升级完成，验证上报已发送"
  else
    die "升级后验证上报失败（探针文件已替换），请检查上报地址与网络"
  fi
}

do_uninstall() {
  if has_systemd; then
    $SUDO systemctl disable --now sentinel-probe.timer 2>/dev/null || true
    $SUDO systemctl stop sentinel-probe.service 2>/dev/null || true
  fi
  $SUDO rm -f "$SERVICE_FILE" "$TIMER_FILE" "$PROBE_PATH" "$PROBE_PATH.bak" "$PROBE_PATH.tmp"
  $SUDO rm -rf "$ENV_DIR" "$STATE_DIR"
  if has_systemd; then
    $SUDO systemctl daemon-reload 2>/dev/null || true
  fi
  $SUDO crontab -u sentinel -l 2>/dev/null | grep -v sentinel-probe | $SUDO crontab -u sentinel - 2>/dev/null || true
  crontab -l 2>/dev/null | grep -v sentinel-probe | crontab - 2>/dev/null || true
  if id sentinel >/dev/null 2>&1; then
    $SUDO userdel sentinel 2>/dev/null || true
  fi
  info "哨兵监控已卸载。面板里删掉这台服务器的记录即可。"
}

# ---------- 入口 ----------
case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  --version)
    echo "sentinel-monitor install.sh $DEFAULT_VERSION"
    exit 0
    ;;
  --uninstall)
    do_uninstall
    exit 0
    ;;
  --update)
    shift
    if [ -n "${1:-}" ]; then
      case "$1" in
        -*) die "--update 后请跟版本号，如 --update 0.1.0" ;;
        *) do_update "$1" ;;
      esac
    else
      do_update
    fi
    exit 0
    ;;
  ""| -*)
    usage >&2
    exit 2
    ;;
  *)
    if [ -z "${2:-}" ]; then
      usage >&2
      exit 2
    fi
    do_install "$1" "$2"
    exit 0
    ;;
esac
