# 哨兵监控 Sentinel Monitor

> 轻量级服务器监控探针：一个 Bash 脚本，像哨兵一样盯着你的服务器，有情况就报。

**版本：0.1.0**

哨兵监控（Sentinel Monitor）是 VPS Manager Pro 的开源探针。它跑在你的服务器上，每 60 秒采集一次真实数据并推送到面板：CPU、内存、硬盘、流量用掉多少、服务器在不在线，一目了然。只有一个 Bash 脚本，探针以专用低权限用户运行，不装重依赖，不占资源。

## 功能

- **实时指标**：CPU 使用率与核数、内存（总量 / 已用）、硬盘（根分区总量 / 已用）、上下行流量计数、负载（1 / 5 / 15 分钟）、进程数、TCP / UDP 连接数、Swap、运行时间
- **服务监测**：HTTP（状态码 + 延迟）、TCP 端口、Ping，全部由服务器本机执行；HTTPS 自动读取 SSL 证书剩余天数与过期时间
- **流量口径准确**：只统计默认路由出口接口的流量，不重复计量虚拟网卡与隧道接口；上报重启标识与计数器清零标志，面板按计数器差值累计月度用量不算错
- **推送式上报**：只往外推数据，不开端口，不存密码；令牌只放在请求体文件里，不出现在进程参数与日志里
- **可靠上报**：失败自动重试 3 次（退避 2 秒 / 5 秒），失败记本地日志，失败的上报存入 spool 备查（不自动补发旧指标）
- **轻量安全**：纯 Bash + 系统自带工具（`curl`、`openssl`、`ping`），探针以专用系统用户 `sentinel` 运行，systemd 服务带多项加固；防重叠运行（flock）
- **一键安装**：systemd timer 每 60 秒上报，无 systemd 时自动用 cron 备选；带更新与卸载命令

面板侧的到期提醒、费用统计、离线与阈值告警、证书临期提醒，由 VPS Manager Pro 提供。

## 快速安装

在服务器上以 root 执行一行命令（令牌和上报地址从 VPS Manager Pro 的探针安装命令里拿；安装命令不带 `sudo`）：

```bash
curl -sSL https://raw.githubusercontent.com/setsail888/sentinel-monitor/v0.1.0/install.sh | bash -s -- <TOKEN> <REPORT_URL>
```

安装器会校验令牌格式（16–128 位字母、数字、下划线或连字符）与上报地址（须为 `https://` 开头的真实地址），检查依赖（`curl` 必需；`systemctl` 或 `crontab` 必需其一；`openssl` / `ping` 缺失时告警），下载固定版本 `v0.1.0` 的探针并做 SHA256 校验，创建专用用户 `sentinel`，写入权限为 `640`（`root:sentinel`）的配置，设置好定时任务后做一次首次上报验证——首次上报失败会明确报错并以非零退出码退出。

装好后探针每 60 秒上报一次，面板里就能看到这台服务器的实时数据。

## 手动安装

```bash
# 1. 下载探针（固定版本 v0.1.0）与校验文件
curl -fsSL https://raw.githubusercontent.com/setsail888/sentinel-monitor/v0.1.0/sentinel-probe.sh -o /usr/local/bin/sentinel-probe.sh
curl -fsSL https://raw.githubusercontent.com/setsail888/sentinel-monitor/v0.1.0/sentinel-probe.sh.sha256 -o /tmp/sentinel-probe.sh.sha256
cd /usr/local/bin && sha256sum -c /tmp/sentinel-probe.sh.sha256
chmod +x /usr/local/bin/sentinel-probe.sh

# 2. 建专用用户并写配置（令牌和上报地址从 VPS Manager Pro 里拿）
useradd --system --no-create-home --shell /usr/sbin/nologin sentinel
mkdir -p /etc/sentinel
printf "SENTINEL_TOKEN='<TOKEN>'\nSENTINEL_REPORT_URL='<REPORT_URL>'\n" > /etc/sentinel/probe.env
chown root:sentinel /etc/sentinel/probe.env
chmod 640 /etc/sentinel/probe.env
mkdir -p /var/lib/sentinel-probe
chown sentinel:sentinel /var/lib/sentinel-probe

# 3. 定时运行（二选一）
# systemd（service 文件见 install.sh 内置的加固配置）：
# systemctl enable --now sentinel-probe.timer
# 或 cron（每分钟，以 sentinel 用户运行）：
# * * * * * /usr/local/bin/sentinel-probe.sh

# 4. 立即上报一次验证（以 sentinel 用户运行）
runuser -u sentinel -- /usr/local/bin/sentinel-probe.sh && echo "首次上报已发送"
```

`install.sh` 做的就是上面这几步，外加下载校验与首次上报失败报错。

## 更新

```bash
# 升级到默认版本（0.1.0）
curl -sSL https://raw.githubusercontent.com/setsail888/sentinel-monitor/v0.1.0/install.sh | bash -s -- --update

# 升级到指定版本
curl -sSL https://raw.githubusercontent.com/setsail888/sentinel-monitor/v0.1.0/install.sh | bash -s -- --update 0.1.0
```

更新时同样下载固定版本并做 SHA256 校验，旧探针文件保留一次 `.bak` 备份，升级后做一次验证上报。

## 卸载

```bash
curl -sSL https://raw.githubusercontent.com/setsail888/sentinel-monitor/v0.1.0/install.sh | bash -s -- --uninstall
```

卸载会停掉并删除 systemd timer / service（或清理 cron 条目），删除探针、配置 `/etc/sentinel`、状态数据 `/var/lib/sentinel-probe` 与专用用户 `sentinel`。面板里删掉这台服务器的记录即可。

其他命令：`install.sh --version` 显示版本，`install.sh --help` 显示帮助。

## 配置说明

| 项目 | 说明 |
| --- | --- |
| 探针 | `/usr/local/bin/sentinel-probe.sh` |
| 配置 | `/etc/sentinel/probe.env`，内容为 `SENTINEL_TOKEN` 与 `SENTINEL_REPORT_URL`，权限 `640`（`root:sentinel`），安装时以单引号安全写法写入 |
| 状态数据 | `/var/lib/sentinel-probe/`：检测节流记录（`check-<id>.last`）、日志（`probe.log`，约 200KB 轮转保留 1 个备份）、失败上报 spool（`failed-spool.jsonl`，上限 1MB 轮转）、上次流量计数器（`counters.prev`，仅用于清零检测）、锁文件（`probe.lock`） |
| 运行用户 | 专用系统用户 `sentinel`（`--system --no-create-home --shell /usr/sbin/nologin`）；systemd 服务另有 `NoNewPrivileges`、`ProtectSystem=strict`、`ProtectHome`、`PrivateTmp` 等加固，仅放行 Ping 所需的 `CAP_NET_RAW` |
| 定时 | systemd timer 每 60 秒；无 systemd 时 cron 每分钟 |
| 日志 | `/var/lib/sentinel-probe/probe.log`，同时写 syslog（有 `logger` 时）；日志里绝不出现令牌 |

探针也可以直接传参运行（调试用）：`./sentinel-probe.sh <TOKEN> <REPORT_URL>`；无参数时自动读取 `/etc/sentinel/probe.env`。

## 上报协议与字段

探针每 60 秒向面板 POST 一次 JSON，外层为 `{"action":"reportProbe","args":<payload>}`；任务拉取为 `{"action":"getProbeTasks","args":{"token":...}}`，返回的 `tasksText` 每行格式为 `serviceId|type|target|intervalSeconds`。

### 指标字段（`args` 顶层）

| 字段 | 说明 |
| --- | --- |
| `token` | 探针令牌（面板按服务器分配） |
| `cpuPct` | CPU 使用率（%），两次 `/proc/stat` 采样算出 |
| `cpuCores` | CPU 核数 |
| `memTotalMb` / `memUsedMb` | 内存总量 / 已用（MB） |
| `diskTotalGb` / `diskUsedGb` | 根分区总量 / 已用（GB） |
| `netRxBytes` / `netTxBytes` | 默认路由出口接口的累计收 / 发字节数（见流量口径说明） |
| `uptimeSec` | 运行时间（秒） |
| `load1` / `load5` / `load15` | 负载（1 / 5 / 15 分钟） |
| `processes` | 进程数 |
| `tcpConns` / `udpConns` | TCP / UDP 连接数 |
| `swapTotalMb` / `swapUsedMb` | Swap 总量 / 已用（MB） |
| `agentVersion` | 探针版本，如 `"0.1.0"` |
| `os` | 系统名称（如 `Ubuntu 24.04.5 LTS`） |
| `hostname` | 主机名 |
| `localDate` | 服务器本地日期（`YYYY-MM-DD`） |
| `bootId` | 本次启动标识（`/proc/sys/kernel/random/boot_id`），用于识别重启 |
| `countersReset` | 布尔值：本次流量计数器小于上次采样（或启动标识变化）即为 `true`，表示计数器已清零或服务器已重启 |
| `checks` | 本次执行的服务检测结果数组（见下） |

### 服务检测结果（`checks[]` 每项）

| 字段 | 说明 |
| --- | --- |
| `serviceId` | 检测任务 ID（数字） |
| `ok` | 是否通过（布尔值） |
| `latencyMs` | 延迟（毫秒，1 位小数浮点数；无法测到时为 `null`） |
| `detail` | 说明，如 `HTTP 200`、`端口可连接`、`Ping 成功` |
| `certDaysLeft` | HTTPS 证书剩余天数（向下取整；非 HTTPS 或读不到时为 `null`；过期为负数） |
| `certExpiresAt` | HTTPS 证书过期时间戳（epoch 秒；非 HTTPS 或读不到时为 `null`） |

检测任务由面板下发，探针按 `intervalSeconds`（10–86400 秒）节流执行；检测失败（`ok=false`）时不写节流记录，下次运行即重试。非法任务行（ID、类型、目标、间隔任一不合规）整行跳过并记入本地日志。

## 流量口径说明

- **0.1.0 起，`netRxBytes` / `netTxBytes` 只统计默认路由出口接口**（从 `/proc/net/route` 取默认出口，不依赖 `ip` 命令）。旧版把除 `lo` 外全部网卡求和，容器/虚拟网卡/隧道接口会被重复计量，数字偏大；升级后口径变小是预期变化，不是流量丢失。
- 探针只上报累计计数器，不做月度统计；月度累计由面板按计数器差值算。服务器重启或计数器清零时，`bootId` 会变化且 `countersReset` 为 `true`，面板据此不把回落算成负增量。
- 面板侧的实时速率同样按两次上报的计数器差值算，探针不另做速率采样。

## 版本说明

- **0.1.0**：稳定化修复版。见 [CHANGELOG.md](CHANGELOG.md)。
- **0.0.1-beta**：测试版，探针首次发布。

### 0.1.0 兼容性变化（面板侧需注意）

1. `netRxBytes` / `netTxBytes` 口径改为默认路由接口（见上），数值会比旧版小；面板展示时建议标注口径。
2. `latencyMs` 由整数改为 1 位小数浮点数（单位仍是毫秒），面板解析时需能接受浮点数。
3. `certDaysLeft` 含义不变（向下取整的剩余天数）；新增可选字段 `certExpiresAt`（证书过期时间戳）。

## 开源协议

MIT License，见 [LICENSE](LICENSE)。
