# vps-tune

VPS 一键调优统一入口。自动识别系统，调用对应后端：

| 系统 | 后端 | 做什么 |
|---|---|---|
| Alpine（含 OpenVZ / LXC 小鸡） | `tune-alpine.sh` | apk 源锁版本分支、常用工具、时区、sshd 自检回滚、内核参数 + `/etc/local.d` 开机重放 |
| Debian / Ubuntu（含 OpenVZ / LXC / Incus NAT） | `tune-debian.sh` | 按内核能力自适应的 sysctl、bbr+fq、journald 限额、nofile、SSH 保活、失败单元清理、路径 MTU、可选 swap/时区/主机名/apt 升级 |

两个后端都源自实际踩坑：

- Alpine 侧来自 [alpine-onekey](https://github.com/jyucoeng/alpine-onekey) 的 `alpine-optimize-safe.sh` v2.1
- Debian/Ubuntu 侧来自 [ovz-tune](https://github.com/jyucoeng/ovz-tune) v1.1.0

合并后统一了入口、参数语义、默认安全策略和缓存/回落逻辑，行为上向下兼容原来的两个脚本。

## 快速开始

```sh
# 演练：只打印计划，不改系统（默认行为）
curl -Ls https://raw.githubusercontent.com/jyucoeng/vps-tune/main/vps-tune.sh | sh

# 执行
curl -Ls https://raw.githubusercontent.com/jyucoeng/vps-tune/main/vps-tune.sh | sh -s -- --apply

# 装成本地命令（推荐，之后可反复用、可离线）
curl -Ls https://raw.githubusercontent.com/jyucoeng/vps-tune/main/install.sh | sh
vps-tune --dry-run
vps-tune --apply
```

> 直接 `| sh` 时，`sh` 是 dash/busybox，所以入口脚本本身用 `#!/usr/bin/env bash` 也要写成 `sh -s -- <参数>` 才能传参。

## 参数

入口把两个后端的参数收敛成一套，后端不支持的会自动忽略并提示。

| 参数 | Alpine | Debian/Ubuntu | 说明 |
|---|:--:|:--:|---|
| （无） | ✅ | ✅ | 演练，只打印计划 |
| `--apply` | ✅ | ✅ | 真正执行 |
| `--dry-run` | ✅ | ✅ | 显式演练 |
| `--rollback` | — | ✅ | 删除写过的配置文件、清 `limits.conf` 段、恢复 qdisc、移除 MTU unit |
| `--upgrade` | ✅ | ✅ | 包升级（apk / apt），耗时 |
| `--no-ssh` | ✅ | ✅ | 不改 sshd、不重启 sshd（**默认就是跳过**） |
| `--ssh` | ✅ | ✅ | 允许写 sshd 登录策略（会放开密码登录，慎用） |
| `--no-tools` | ✅ | — | 不装常用工具 |
| `--no-tz` | ✅ | — | 不改时区 |
| `--sysctl-only` | ✅ | — | 只调内核参数（最保守） |
| `--no-journald` | — | ✅ | 不改 journald 限额 |
| `--no-clean` | — | ✅ | 不清理失败单元 / 不 mask `systemd-hostnamed` |
| `--tz ZONE` | — | ✅ | 时区 |
| `--hostname NAME` | — | ✅ | 主机名 |
| `--journald-max 200M` | — | ✅ | journald 上限 |
| `--swap 1024` | — | ✅ | 尝试加 1G swap |
| `--mtu auto\|1400` | — | ✅ | MTU；`auto` 实测路径 MTU 后取最优值 |
| `--offline` | ✅ | ✅ | 只用本地缓存的后端，不联网 |
| `--os alpine\|debian` | ✅ | ✅ | 强制指定后端（调试用） |

### 默认安全策略：不碰 SSH 登录

两个后端的 SSH 段都会写 `PermitRootLogin yes` / `PasswordAuthentication yes`，这在公网机器上是**安全降级**。所以 `vps-tune` 默认一律传 `--no-ssh`，只有显式 `--ssh` 才允许写。

```sh
vps-tune --apply            # 不动 sshd
vps-tune --apply --ssh      # 明确要放开密码登录时才用
```

## Alpine 侧细节

7 段，逐段可裁剪：

1. **apk 源**：只锁当前版本分支（`v3.22`），不追 `latest-stable`，避免跨大版本漂移
2. **磁盘余量**：< 200MB 时跳过安装类操作
3. **apk upgrade**：只有 `--upgrade` 才做
4. **常用工具**：`bash curl wget vim htop nano tzdata openssh sudo ca-certificates iproute2`
5. **时区**：`Asia/Shanghai`
6. **SSH**：只探测真实监听端口、不猜；改前备份 + `sshd -t` + 重启后回连自检 + 失败自动回滚
7. **内核参数**：只写内核真正允许写的键，落 `/etc/local.d/99-alpine-optimize.start` 开机重放

内核参数清单（10 项）：

```
net.ipv4.tcp_fastopen = 3            net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1         net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1            net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_max_syn_backlog = 4096  net.core.somaxconn = 4096
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_congestion_control = bbr
```

## Debian / Ubuntu 侧细节

段落顺序：环境探测 → sysctl → 拥塞控制与队列 → 路径 MTU → 持久化 → journald → 文件句柄 → SSH 保活 → 失败单元 → 时区 → 主机名 → swap → 升级 → 汇总。

- **sysctl 按能力自适应**：`try_kv` 先读再试写，内核不认的键直接记入「跳过」而不是报错——所以同一份脚本在 KVM、LXC、OpenVZ 上都能跑，只是生效项数不同
- **拥塞控制**：`bbr` + `fq`，队列只在当前不是 `fq` 时替换
- **路径 MTU**：`--mtu auto` 会实测 TLS 握手基线，只有「基线 > 0.5s 且最优 < 0.15s」才动手，并写 `vps-tune-mtu.service` 持久化
- **journald**：< 1G → 64M，< 2G → 100M，否则 200M
- **文件句柄**：`/etc/security/limits.conf` 追加 `nofile 65535`
- **SSH 保活**：`ClientAliveInterval 60` / `ClientAliveCountMax 3` / `MaxAuthTries 6` / `LoginGraceTime 40`，`sshd -t` 通过才 reload
- **失败单元**：容器里 mask 永远起不来的 `systemd-hostnamed`，`reset-failed 'ssh@*' 'session-*'`
- **apt 升级**：`systemd-run --unit=vps-tune-upgrade --collect` 跑在独立 unit，断线不会打断 dpkg

参考实测（原作者 README，脚本逻辑未变）：

| 环境 | 生效 | 跳过 |
|---|---|---|
| KVM / Debian 11 / 461MB | 24 | 0 |
| LXC | 18 | 5 |
| Incus NAT | 12 | 10 |
| OpenVZ / Debian 12 / 1.5GB | 3 | 4 |

## 回滚

```sh
vps-tune --rollback
```

- 删除 `99-vps-tuning.conf` / `99-vps-limit.conf` / `99-vps-keepalive.conf`
- 清掉 `limits.conf` 里的 `# BEGIN vps-tune` 段
- qdisc 恢复 `fq_codel`、移除 MTU unit、解除 `systemd-hostnamed` 的 mask
- 兼容老版本：`ovz-tune 1.x` 写的文件、标记、unit 也一并清理

不自动还原：主机名、时区、swap、已生效的内核参数（要重启才回默认）、MTU 当前值。备份在 `/var/backups/vps-tune/`。

Alpine 侧没有回滚，改动都在 `/etc/local.d/`、`/etc/sysctl.d/` 之类明面上，改前脚本自己留 `.bak.<时间戳>`。

## 后端脚本的查找顺序

`vps-tune` 不会每次都重新下载，顺序是：

1. 脚本同目录的 `tune-<os>.sh`
2. `/usr/local/share/vps-tune/tune-<os>.sh`（`install.sh` 装的位置）
3. 缓存 `/var/cache/vps-tune/`（不可写时退到 `/tmp/vps-tune-cache/`）
4. 联网：`raw.githubusercontent.com` → 失败换 `api.github.com/.../contents`（raw 的 CDN 偶发 504 时这条路通常还通）

`--offline` 只用 1/2/3，适合内网或 GitHub 抽风时。下载后都会 `sh -n` / `bash -n` 校验，HTML 错误页会被拒。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `VPS_TUNE_REPO` | `jyucoeng/vps-tune` | 换成自己的 fork |
| `VPS_TUNE_BRANCH` | `main` | 分支 |
| `VPS_TUNE_CACHE_DIR` | `/var/cache/vps-tune` | 后端缓存目录 |
| `VPS_TUNE_OS` | 自动 | 等价 `--os` |
| `PORT` | 自动探测 | **仅 Alpine**：显式指定 sshd 端口，必须等于当前监听端口 |

## 被 sb.sh 调用

`singbox-tools` 的 `sb.sh` 在安装完成后会自动跑一次（`sb opt`），内部就是：

```sh
sh /root/doraemon/vps-tune.sh --apply --no-ssh        # Alpine 会自动补 --dry-run/不加 --apply
```

各系统的后端由 `vps-tune.sh` 自己识别，`sb.sh` 不再分叉。失败不阻断安装（`|| warn`）。

## 更新记录

| 版本 | 变更 |
|---|---|
| 1.0.3 | 修 `resolve_backend` 的 stdout 被下载进度污染（`exec "bash 下载 tune-debian.sh …"` 报 No such file）；`warn` 统一走 stderr |
| 1.0.2 | 后端下载改成 **GitHub API 优先**：`raw.githubusercontent` 的 CDN 会长期留旧副本，`?ts=` 也压不住，旧文件语法合法会被误判成下载成功；API 限流时才回落 raw |
| 1.0.1 | `vps-tune.sh` 改**纯 POSIX sh**（去掉 bash 数组，用 `set --` 重排参数），`curl … \| sh`、dash、busybox ash 都能跑；修 Debian 12 上 `Syntax error: "(" unexpected` |
| 1.0.0 | 首版：合并 [alpine-onekey](https://github.com/jyucoeng/alpine-onekey)（`tune-alpine.sh`）与 [ovz-tune](https://github.com/jyucoeng/ovz-tune)（`tune-debian.sh`），加统一入口与 `install.sh` |

## 免责

按「现状」提供，无任何担保。会改 `sysctl` / `sshd_config` / `journald.conf` / `limits.conf` / apk 或 apt 源。跑之前先 `--dry-run`，自己备份，失联或数据丢失自负。License: MIT
