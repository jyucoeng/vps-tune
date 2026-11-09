# vps-tune

VPS 一键调优。脚本自己认系统，然后调对应的后端：

- **Alpine**（含 OpenVZ / LXC）→ `tune-alpine.sh`：apk 源锁分支、常用工具、时区、内核参数 + BBR
- **Debian / Ubuntu**（含 KVM / LXC / Incus / OpenVZ）→ `tune-debian.sh`：sysctl、BBR+fq、journald 限额、nofile、SSH 保活、MTU、可选 swap

源自 [alpine-onekey](https://github.com/jyucoeng/alpine-onekey) 和 [ovz-tune](https://github.com/jyucoeng/ovz-tune)，合并成一个入口。

## 用起来

```sh
# 1) 先演练：只打印要改什么，不动系统（默认就是演练）
curl -Ls https://raw.githubusercontent.com/jyucoeng/vps-tune/main/vps-tune.sh | sh

# 2) 看着没问题再执行
curl -Ls https://raw.githubusercontent.com/jyucoeng/vps-tune/main/vps-tune.sh | sh -s -- --apply

# 3) 或者装成本地命令，以后直接敲（推荐）
curl -Ls https://raw.githubusercontent.com/jyucoeng/vps-tune/main/install.sh | sh
vps-tune            # 演练
vps-tune --apply    # 执行
```

## 常用参数

| 参数 | 作用 |
|---|---|
| `--apply` | 真执行。不加就只演练 |
| `--rollback` | 撤销（仅 Debian / Ubuntu） |
| `--ssh` | 允许改 sshd 登录策略（**默认不改**） |
| `--upgrade` | 顺带做包升级，慢 |
| `--sysctl-only` | 只调内核参数（仅 Alpine，最保守） |
| `--mtu auto` | 实测路径 MTU 再决定（仅 Debian / Ubuntu） |
| `--offline` | 只用本地缓存，不联网 |
| `--os alpine\|debian` | 强制指定后端（调试用） |

其余参数（`--tz`、`--hostname`、`--swap`、`--journald-max`、`--no-tools`、`--no-journald`、`--no-clean`…）用 `vps-tune -h` 看，后端不支持的会自动忽略并提示。

## 默认不改 SSH

两个后端原本都会写 `PermitRootLogin yes` / `PasswordAuthentication yes`，在公网机器上等于安全降级。所以这里**默认一律跳过 SSH 段**，确实要放开密码登录才加 `--ssh`。

## 回滚

```sh
vps-tune --rollback     # 仅 Debian / Ubuntu
```

删掉写过的配置文件、清 `limits.conf` 里的段、qdisc 恢复 `fq_codel`、移除 MTU unit、解除 `systemd-hostnamed` 的 mask，也能清老版 ovz-tune 留下的东西。

不自动还原：主机名、时区、swap、已经进内核的参数（要重启才回默认）、当前 MTU。备份在 `/var/backups/vps-tune/`。

Alpine 侧没有回滚命令，但每步改前都留 `.bak.<时间戳>`，改动也都落在 `/etc/local.d/`、`/etc/sysctl.d/` 这种明面上。

## 被 sb.sh 调用

`singbox-tools` 的 `sb.sh` 装完会自动跑一次（`sb opt`），等价于 `vps-tune --apply --no-ssh`。失败只告警，不阻断安装。

## 更新记录

| 版本 | 变更 |
|---|---|
| 1.0.3 | 修下载进度污染 stdout（导致 `exec "bash 下载 tune-debian.sh…"`） |
| 1.0.2 | 后端下载改 GitHub API 优先，`raw.githubusercontent` 的 CDN 会长期留旧副本 |
| 1.0.1 | 入口改纯 POSIX sh，`curl … \| sh`、dash、busybox 都能跑 |
| 1.0.0 | 首版：合并 alpine-onekey + ovz-tune |

## 免责

按「现状」提供，无担保。会改 sysctl / sshd / journald / limits.conf / 包管理器源，先跑演练自己备份。License: MIT
