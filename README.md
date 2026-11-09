# vps-tune

给 VPS 做一次系统调优：内核参数、BBR、文件句柄、journald 限额等。
自动识别系统，选对应后端执行：

| 系统 | 后端 |
|---|---|
| Alpine | `tune-alpine.sh` |
| Debian / Ubuntu | `tune-debian.sh` |

两个后端来自 [alpine-onekey](https://github.com/jyucoeng/alpine-onekey) 和 [ovz-tune](https://github.com/jyucoeng/ovz-tune)，这里合并成一个入口。

## 安装

```sh
# 装成本地命令（推荐，之后可反复用、可离线）
curl -Ls https://raw.githubusercontent.com/jyucoeng/vps-tune/main/install.sh | sh
```

装到 `/usr/local/bin/vps-tune` + `/usr/local/share/vps-tune/tune-*.sh`。
不想装也行，每次直接跑：

```sh
curl -Ls https://raw.githubusercontent.com/jyucoeng/vps-tune/main/vps-tune.sh | sh -s -- --apply
```

## 用法

都要 root 执行：

```sh
vps-tune                 # 演练：只打印要改什么，不动系统
vps-tune --apply         # 执行
vps-tune --apply --upgrade   # 执行，顺带做包升级（慢）
vps-tune -h              # 全部参数
```

不装的时候把 `vps-tune` 换成 `sh vps-tune.sh`，参数照写。

常用参数：

| 参数 | 作用 |
|---|---|
| `--apply` | 真执行。不加就只演练 |
| `--rollback` | 撤销改动（仅 Debian / Ubuntu） |
| `--ssh` | 允许改 sshd 登录策略（**默认不改**） |
| `--upgrade` | 顺带做包升级 |
| `--sysctl-only` | 只调内核参数（仅 Alpine） |
| `--offline` | 只用本地缓存，不联网 |
| `--os alpine\|debian` | 强制指定后端（调试用） |

其余（`--tz`、`--hostname`、`--swap`、`--mtu`、`--journald-max`、`--no-tools`、`--no-journald`、`--no-clean`、`--no-tz`）见 `-h`；当前系统不支持的那个会被忽略并提示。

**默认不改 SSH。** 两个后端原本都会写 `PermitRootLogin yes` / `PasswordAuthentication yes`，在公网机器上等于安全降级，所以这里一律跳过；确实要放开登录才加 `--ssh`。

## 回滚

```sh
vps-tune --rollback        # 仅 Debian / Ubuntu
```

删掉写过的配置文件、清 `limits.conf` 里的段、qdisc 回 `fq_codel`、移除 MTU unit，也能清掉老版 ovz-tune 留下的东西。备份在 `/var/backups/vps-tune/`。

不自动还原：主机名、时区、swap、已经进内核的参数（重启才回默认）、当前 MTU。

**Alpine 没有自动回滚**，`--rollback` 会直接报错并给出手动命令，不会误跑一遍优化；改动都落在明面上，删两个文件即可：

```sh
rm -f /etc/sysctl.d/99-alpine-optimize.conf /etc/local.d/99-alpine-optimize.start
```

## 卸载

```sh
curl -Ls https://raw.githubusercontent.com/jyucoeng/vps-tune/main/install.sh | sh -s -- --uninstall
```

只删 `vps-tune` 命令和 `/usr/local/share/vps-tune/`，**不还原系统改动**。要撤调优：Debian/Ubuntu 先 `vps-tune --rollback` 再卸载；Alpine 用上面的手动删除命令。

## 被外部调用

[singbox-tools](https://github.com/jyucoeng/singbox-tools) 的 `sb.sh` 装完后自动跑一次，等价于：

```sh
vps-tune --apply --no-ssh
```

关掉它：装的时候带 `OS_TUNE_ON_INSTALL=0`。手动随时可跑：`sb opt`。

退出码：`0` 成功 · `2` 参数或系统不支持 · `3` 认不出系统 · `4` 后端下载失败 · `5` 安装失败。

## 免责

按「现状」提供，无担保。会改 sysctl / journald / limits.conf / sshd / 包管理器源，先跑演练自己备份。License: MIT
