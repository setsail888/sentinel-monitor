# 哨兵监控 Sentinel Monitor

> 轻量级服务器监控探针：一个 Bash 脚本，像哨兵一样盯着你的服务器，有情况就报。

**版本：0.0.1-beta（测试版）**

哨兵监控（Sentinel Monitor）是 VPS Manager Pro 的开源探针。它跑在你的服务器上，每 60 秒采集一次真实数据并推送到面板：CPU、内存、硬盘、流量用掉多少、服务器在不在线，一目了然。只有一个 Bash 脚本，不装依赖，不占资源。

## 功能

- **实时指标**：CPU 使用率与核数、内存（总量 / 已用 / 剩余）、硬盘（总量 / 已用 / 剩余）、上下行流量与本月累计、负载（1 / 5 / 15 分钟）、进程数、TCP / UDP 连接数、Swap、运行时间
- **服务监测**：HTTP（状态码 + 延迟）、TCP 端口、Ping，全部由服务器本机执行；HTTPS 自动读取 SSL 证书剩余天数
- **推送式上报**：只往外推数据，不开端口，不存密码
- **轻量**：纯 Bash + 系统自带工具（`curl`、`openssl`、`ping`），无额外依赖
- **一键安装**：systemd timer 每 60 秒上报，无 systemd 时自动用 cron 备选；带卸载命令

面板侧的到期提醒、费用统计、离线与阈值告警、证书临期提醒，由 VPS Manager Pro 提供。

## 快速安装

在服务器上以 root 执行一行命令（令牌和上报地址从 VPS Manager Pro 的探针安装命令里拿）：

```bash
curl -sSL https://raw.githubusercontent.com/setsail888/sentinel-monitor/main/install.sh | bash -s -- <TOKEN> <REPORT_URL>
```

装好后探针每 60 秒上报一次，面板里就能看到这台服务器的实时数据。

## 手动安装

```bash
# 1. 下载探针
curl -fsSL https://raw.githubusercontent.com/setsail888/sentinel-monitor/main/sentinel-probe.sh -o /usr/local/bin/sentinel-probe.sh
chmod +x /usr/local/bin/sentinel-probe.sh

# 2. 写配置（令牌和上报地址从 VPS Manager Pro 里拿）
mkdir -p /etc/sentinel
printf 'SENTINEL_TOKEN="<TOKEN>"\nSENTINEL_REPORT_URL="<REPORT_URL>"\n' > /etc/sentinel/probe.env
chmod 600 /etc/sentinel/probe.env

# 3. 定时运行（二选一）
# systemd：
systemctl enable --now sentinel-probe.timer
# 或 cron（每分钟）：
# * * * * * bash -c 'set -a; . /etc/sentinel/probe.env; exec /usr/local/bin/sentinel-probe.sh'

# 4. 立即上报一次验证
bash -c 'set -a; . /etc/sentinel/probe.env; exec /usr/local/bin/sentinel-probe.sh' && echo "首次上报已发送"
```

`install.sh` 做的就是上面这几步。

## 卸载

```bash
systemctl disable --now sentinel-probe.timer 2>/dev/null
rm -f /etc/systemd/system/sentinel-probe.{service,timer} /usr/local/bin/sentinel-probe.sh
rm -rf /etc/sentinel /var/lib/sentinel-probe
systemctl daemon-reload 2>/dev/null
crontab -l 2>/dev/null | grep -v sentinel-probe | crontab -
```

面板里删掉这台服务器的记录即可。

## 上报协议

探针每 60 秒向面板 POST 一次 JSON：本机指标（CPU、内存、硬盘、流量计数、负载、进程数、连接数、Swap、运行时间、系统、主机名）与本次执行的服务检测结果（HTTP / TCP / Ping、证书剩余天数）。面板用流量计数差值累计本月用量，用最近上报时间判定在线 / 延迟 / 离线。

## 版本

- **0.0.1-beta**：测试版，探针首次发布。

## 开源协议

MIT License，见 [LICENSE](LICENSE)。
