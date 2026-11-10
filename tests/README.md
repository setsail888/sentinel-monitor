# 哨兵监控 Sentinel Monitor 0.1.0 测试

测试员视角的测试套件：只验证 `sentinel-probe.sh` 与 `install.sh` 的行为，
不修改任何被测文件，不碰 VPS Manager Pro，不连外网，不向 GitHub 推送。

## 怎么跑

```bash
bash tests/run_tests.sh            # 一键跑全部，汇总通过/失败数
bash tests/test_ssl.sh             # 只跑某一项
```

要求：以 root 运行（权限隔离实测需要建 `sentinel` 用户并以该用户运行探针；
流量夹具挂载需要 `unshare -m`）。前置：`shellcheck`、`python3`、`openssl`、
`curl`、`ping`、`flock`、`unshare`。

## 原则

- 全部网络流量只走回环地址（`127.0.0.1`），假面板 / HTTP / TCP / HTTPS 服务
  都是本地 Python 进程；令牌与地址只用明显假的值（测试令牌为
  `0123456789abcdef0123456789abcdef01234567`）。
- 探针本身不强制 https（只校验令牌与地址非空、非占位符），所以回环假面板
  用 `http://127.0.0.1:端口`；`install.sh` 的地址校验要求 `https://`，
  因此安装测试只测拒绝路径，不做真实安装（真实安装还要从 GitHub 下载，
  属于外网行为，本套件不做）。
- 每个分项脚本独立：自建临时状态目录与临时端口，退出时杀掉自己拉起的
  服务进程并清理临时目录。

## 文件

| 文件 | 说明 |
| --- | --- |
| `run_tests.sh` | 总入口，按顺序跑全部 12 个分项，汇总后失败时非零退出 |
| `lib/common.sh` | 共享断言 / 启停服务 / ps 令牌扫描等辅助函数 |
| `lib/fake_panel.py` | 假面板：实现 `getProbeTasks` + `reportProbe`，可配失败模式（`ok` / `flaky2` / `alwaysfail`），记录每次请求 |
| `lib/static_server.py` | 回环 HTTP(S) 静态服务器，任何路径都返回 200，可配证书 |
| `lib/tcp_listener.py` | 回环 TCP 监听，接受连接后关闭 |
| `fixtures/proc-net-dev.txt` | 流量夹具：默认出口 `eth0` + docker/veth/tun/lo 等干扰接口 |
| `fixtures/proc-net-route.txt` | 路由夹具：默认路由走 `eth0` |
| `test_shellcheck.sh` | 两脚本 ShellCheck 零告警 |
| `test_static.sh` | 禁用词 0 处、推迟字段 0 处、三处版本号一致、SHA256 一致、无 main 分支引用 |
| `test_traffic.sh` | 默认路由口径、虚拟网卡排除、计数器清零（`countersReset`） |
| `test_task_validation.sh` | 任务校验：非法行跳过、注入目标无副作用 |
| `test_latency.sh` | HTTP/TCP/Ping 延迟为 1 位小数浮点毫秒 |
| `test_ssl.sh` | 自签名 HTTPS：`certDaysLeft` / `certExpiresAt`，非标准端口不错取 443 证书 |
| `test_json_escape.sh` | JSON 转义：控制字符 / 引号 / 反斜杠，`json.tool` 可解析 |
| `test_retry.sh` | 重试成功不留 spool；一直失败 3 次后退出 1、spool 合法、日志无令牌 |
| `test_flock.sh` | 占住锁时第二实例跳过并退出 0 |
| `test_e2e.sh` | 假面板全流程：字段清单 23 旧 + 3 新、类型与单位、`latencyMs` 浮点、ps 无令牌 |
| `test_install.sh` | `--help` / `--version`、各类非法输入被拒、卸载删干净 |
| `test_permissions.sh` | systemd 单元加固项齐全；`sentinel` 用户实测能上送；ps 与日志无令牌 |

## 沙盒限制（已知的“未测”，不是通过）

- **Ping**：本沙盒禁原始套接字（`ping 127.0.0.1` 报 `Operation not permitted`），
  探针的 Ping 检测只能走到“无响应”分支；延迟精度与成功路径未测。
- **crontab**：本机无 `crontab` 命令，`install.sh` 的 cron 备选路径未测
  （本机有 systemd，`has_systemd` 为真，走 systemd 分支）。
- **真实 tag 下载**：不连外网，`install.sh` 从 GitHub 拉固定版本 + SHA256 校验
  的真实下载路径未测；只测了版本号格式校验与“未安装探针时拒绝升级”。
- **流量夹具挂载**：本沙盒静默忽略对 `/proc` 下路径的 bind 挂载（`mount` 返回 0
  但内容不变、`/proc/mounts` 无记录；`/tmp` 文件的 bind 正常生效），所以无法把
  夹具挂到 `/proc/net/dev` 与 `/proc/net/route` 上跑真实探针，对应子项记 SKIP；
  `test_traffic.sh` 改为用探针取数逻辑的 awk 模拟 + 真实计数器三态验证
  （`countersReset` 回落/正常/仅 bootId 变化）作为证据。

## 清理

- `test_permissions.sh` 会临时把探针装到 `/usr/local/bin/sentinel-probe.sh`、
  建 `sentinel` 用户与 `/etc/sentinel/probe.env`，退出时全部删掉。
- `test_install.sh` 的卸载子项会在 `/usr/local/bin`、`/etc/sentinel`、
  `/var/lib/sentinel-probe`、`/etc/systemd/system` 下造假文件再删掉，
  退出时不留痕迹。
- 其余测试只用 `/tmp/sentinel-test*` 临时目录，退出即删。
