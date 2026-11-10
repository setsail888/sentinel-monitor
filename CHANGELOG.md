# CHANGELOG

## 0.1.0

稳定化修复版。保留 0.0.1-beta 的架构与上报协议，只做可靠性与安全加固。

### 修复

- **TCP 注入（高危）**：TCP 检测不再把目标拼进 `bash -c` 字符串，改用位置参数的安全写法，并先做白名单校验。
- **任务参数无校验（高危）**：集中校验下发的检测任务——`serviceId` 必须为纯数字，`type` 白名单 `http|tcp|ping`，`target` 按类型校验，`interval` 必须为 10–86400 的整数，`last_run` 非数字按 0 处理；任一字段非法则整行跳过并计数记日志。
- **权限隔离（高）**：安装时创建专用系统用户 `sentinel`（`--system --no-create-home --shell /usr/sbin/nologin`），systemd 服务以该用户运行，并加 `NoNewPrivileges=true`、`ProtectSystem=strict`、`ProtectHome=true`、`PrivateTmp=true`、`ReadWritePaths=/var/lib/sentinel-probe`、`CapabilityBoundingSet=CAP_NET_RAW`、`AmbientCapabilities=CAP_NET_RAW`（Ping 所需）、`ProtectKernelTunables=true`、`ProtectControlGroups=true`、`LockPersonality=true`、`StateDirectory=sentinel-probe`；`probe.env` 为 `root:sentinel 640` 且以 `umask 077` 创建；取消 `/tmp` 回退（状态目录建不出来就报错退出）；临时文件改用 `mktemp`；`/etc/os-release` 改用 `grep` 解析，不再 `source`；不再用 `set --` 覆盖位置参数。
- **JSON 转义（中）**：重写为完备的纯 Bash `json_escape`，处理反斜杠、双引号、`\n`、`\r`、`\t`、`\b`、`\f` 及其他 `<0x20` 控制字符（转 `\u00XX`）；令牌同样经过转义；所有数值拼 payload 前校验为数字，不合规填 `null` 并记日志。
- **流量重复计量（中）**：`netRxBytes` / `netTxBytes` 改为只统计默认路由出口接口（从 `/proc/net/route` 取默认出口，不依赖 `ip` 命令），不再把除 `lo` 外全部网卡求和。
- **延迟精度（中）**：改用 `date +%s%3N` 毫秒时钟；HTTP 改用 `curl -w '%{time_total}'`；Ping 保留小数。`latencyMs` 改为带 1 位小数的浮点毫秒（见兼容性变化）。
- **SSL 非标准端口（中）**：解析 URL 分离 host 与 port（默认 443），`openssl s_client -servername <去括号主机名> -connect <host:port>`（IPv6 连接用方括号、SNI 去括号）；`certDaysLeft` 保持向下取整的现有含义不变。
- **重试 / 超时 / 日志（中）**：上报失败有限重试 3 次（退避 2s / 5s）、每次超时 15s；失败记日志（时间戳 + 原因，绝不记令牌）；日志写 `$STATE_DIR/probe.log`（轮转，约 200KB 保留 1 个备份），有 `logger` 时同时写 syslog；任务拉取失败与上报失败分开记日志；`.last` 改为检测成功后写（失败用较短重试间隔）；入口加 `flock` 防重叠运行；失败的上报 payload 存入 spool 文件备查（上限 1MB 轮转），不自动补发旧指标（避免面板按差值累计时算出负增量）。
- **安装脚本加固（中）**：令牌白名单 `^[A-Za-z0-9_-]{16,128}$`、上报地址必须 `^https://` 且拒绝占位符；开头检查依赖（`curl` 必需；`systemctl` 或 `crontab` 必需其一；`openssl` / `ping` 可选缺失时告警）；下载后 SHA256 校验再原子替换并保留一次 `.bak` 备份；`probe.env` 用 `umask 077` + 单引号安全写法创建；首次上报失败明确报错并退出非零；增加 `--update`、`--uninstall`、`--version`、`--help`。
- **固定版本（高）**：不再拉 `main` 分支可变脚本。`install.sh` 内 `DEFAULT_VERSION="0.1.0"`，探针地址用 tag 地址 `https://raw.githubusercontent.com/setsail888/sentinel-monitor/v0.1.0/sentinel-probe.sh`，同时下载同 tag 的 `sentinel-probe.sh.sha256` 校验（校验文件缺失时告警继续、校验不匹配时中止）；`--update [版本]` 支持指定版本升级（版本号格式校验）；README 的一键安装命令改用 `v0.1.0` tag 地址；`agentVersion` 升为 `"0.1.0"`。

### 新增字段（均为可选附加字段）

- `bootId`（顶层）：`/proc/sys/kernel/random/boot_id`，用于识别服务器重启。
- `countersReset`（顶层，布尔）：本次流量计数器小于上次采样（或启动标识变化）即为 `true`；探针只存一份最小的上次计数器用于该判断，不做速率计算、不做月度状态，月度累计仍由面板按计数器差值算。
- `certExpiresAt`（`checks[]` 每项）：HTTPS 证书过期时间戳（epoch 秒），非 HTTPS 或读不到时为 `null`。

### 兼容性变化

1. **`netRxBytes` / `netTxBytes` 口径改为默认路由接口**：旧版对除 `lo` 外全部网卡求和，会重复计量容器/虚拟网卡/隧道接口；0.1.0 起只统计默认路由出口接口，数值会比旧版小。面板展示时建议标注口径。
2. **`latencyMs` 整数 → 1 位小数浮点数**：单位仍是毫秒，数值含义不变；面板解析时需能接受浮点数。
3. **`certDaysLeft` 含义不变**（向下取整的剩余天数，过期为负数）；新增可选字段 `certExpiresAt`，面板可按需使用。

## 0.0.1-beta

测试版，探针首次发布。
