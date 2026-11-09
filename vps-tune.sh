#!/bin/sh
# =========================================================
# vps-tune.sh  v1.0.1 (2026-11-09)
# VPS 一键调优统一入口：自动识别 Alpine / Debian / Ubuntu 并调用对应后端
#
# 后端:
#   tune-alpine.sh   Alpine / OpenVZ / LXC（apk 源、时区、sshd、内核参数）
#   tune-debian.sh   Debian / Ubuntu（sysctl、bbr+fq、journald、limits、sshd、MTU）
#
# 设计约定:
#   * 纯 POSIX sh，没有 bash 也能跑（`curl … | sh` 可用）
#   * 默认演练（--dry-run），加 --apply 才真实改动
#   * 默认不改 SSH 登录策略；要放开密码登录必须显式 --ssh
#   * 后端脚本查找顺序：同目录 → /usr/local/share/vps-tune → 缓存 → 联网，
#     联网失败自动用缓存，适合被上层脚本（如 singbox-tools 的 sb.sh）调用
#
# 免责：按"现状"提供，无任何担保。会改 sysctl / sshd / journald 等系统配置，
#       跑之前先演练、自己备份，失联或数据丢失自负。License: MIT
# =========================================================
set -u

VERSION="1.0.2"
REPO="${VPS_TUNE_REPO:-jyucoeng/vps-tune}"
BRANCH="${VPS_TUNE_BRANCH:-main}"
CACHE_DIR="${VPS_TUNE_CACHE_DIR:-/var/cache/vps-tune}"
FALLBACK_CACHE="/tmp/vps-tune-cache"
SHARE_DIR="/usr/local/share/vps-tune"
SELF_DIR=$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd -P || echo .)

if [ -t 1 ]; then
  C_G=$(printf '\033[1;32m'); C_Y=$(printf '\033[1;33m'); C_R=$(printf '\033[1;31m'); C_N=$(printf '\033[0m')
else
  C_G=""; C_Y=""; C_R=""; C_N=""
fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '   %s✓%s %s\n' "$C_G" "$C_N" "$*"; }
warn() { printf '   %s!%s %s\n' "$C_Y" "$C_N" "$*"; }
bad()  { printf '   %s✗%s %s\n' "$C_R" "$C_N" "$*" >&2; }

usage() {
  cat <<'EOF'
vps-tune — VPS 一键调优统一入口（Alpine / Debian / Ubuntu）

用法:
  vps-tune                         演练：只打印计划（默认）
  vps-tune --apply                 按系统自动选后端并执行
  vps-tune --apply --upgrade       顺带做包升级（apk/apt，耗时长）
  vps-tune --rollback              撤销本工具的所有改动（仅 Debian/Ubuntu）
  vps-tune --offline               只用本地缓存的后端脚本，不联网
  vps-tune --os alpine|debian      强制指定后端（调试用）

统一参数（后端不支持的会自动忽略并提示）:
  --no-ssh        不改 sshd 登录策略（默认行为）
  --ssh           允许写 sshd 登录策略（会放开密码登录，慎用）
  --no-tools      不安装常用工具包（仅 Alpine）
  --no-tz         不改时区（仅 Alpine；Debian 侧用 --no-tz 无意义）
  --sysctl-only   只调内核参数（仅 Alpine）
  --no-journald   不改 journald 限额（仅 Debian/Ubuntu）
  --no-clean      不清理失败单元 / 不 mask systemd-hostnamed（仅 Debian/Ubuntu）
  --tz ZONE       设置时区，如 Asia/Shanghai（仅 Debian/Ubuntu）
  --hostname NAME 设置主机名（仅 Debian/Ubuntu）
  --journald-max  指定 journald 上限，如 200M（仅 Debian/Ubuntu）
  --swap MB       尝试加 swap（仅 Debian/Ubuntu）
  --mtu auto|1400 调 MTU（仅 Debian/Ubuntu，auto 会实测路径 MTU）

环境变量:
  VPS_TUNE_REPO      默认 jyucoeng/vps-tune
  VPS_TUNE_BRANCH    默认 main
  VPS_TUNE_CACHE_DIR 后端脚本缓存目录，默认 /var/cache/vps-tune
  VPS_TUNE_OS        等价于 --os

注意: 参数按空格切分，取值里不要带空格（时区、主机名、容量都没有空格）。
EOF
}

detect_os() {
  if [ -n "${FORCE_OS:-}" ]; then echo "$FORCE_OS"; return 0; fi
  if [ -f /etc/alpine-release ]; then echo alpine; return 0; fi
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    (. /etc/os-release 2>/dev/null
     case " ${ID:-} ${ID_LIKE:-} " in
       *" alpine "*) echo alpine ;;
       *" debian "*|*" ubuntu "*) echo debian ;;
       *) case "${ID:-}" in
            debian|ubuntu|linuxmint|pop|kali|raspbian|devuan) echo debian ;;
            *) echo unsupported ;;
          esac ;;
     esac)
    return 0
  fi
  echo unsupported
}

backend_name() { echo "tune-$1.sh"; }
shell_for()    { if [ "$1" = alpine ]; then echo sh; else echo bash; fi; }

valid_backend() { # <file> <sh>
  [ -s "$1" ] || return 1
  head -c 200 "$1" 2>/dev/null | grep -qi '<!doctype\|<html' && return 1
  "$2" -n "$1" >/dev/null 2>&1
}

dl() { # <url> <out> [header]
  _d_url="$1"; _d_out="$2"; _d_hdr="${3:-}"
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$_d_hdr" ]; then
      curl -fsSL --connect-timeout 8 --max-time 120 --retry 2 --retry-delay 2 \
           --retry-all-errors -H "$_d_hdr" -o "$_d_out" "$_d_url" >/dev/null 2>&1
    else
      curl -fsSL --connect-timeout 8 --max-time 120 --retry 2 --retry-delay 2 \
           --retry-all-errors -o "$_d_out" "$_d_url" >/dev/null 2>&1
    fi
  elif command -v wget >/dev/null 2>&1; then
    if [ -n "$_d_hdr" ]; then
      wget -q -T 30 --header="$_d_hdr" -O "$_d_out" "$_d_url" >/dev/null 2>&1
    else
      wget -q -T 30 -O "$_d_out" "$_d_url" >/dev/null 2>&1
    fi
  else
    return 1
  fi
}

download_backend() { # <os> <dest>
  _os="$1"; _dest="$2"
  _f=$(backend_name "$_os"); _sh=$(shell_for "$_os")
  _tmp="${_dest}.part.$$"
  _url="https://raw.githubusercontent.com/$REPO/$BRANCH/$_f?ts=$(date +%s)"
  _api="https://api.github.com/repos/$REPO/contents/$_f?ref=$BRANCH"

  say "   下载 $_f ..."
  rm -f "$_tmp" 2>/dev/null
  # 先走 GitHub API：raw.githubusercontent 的 CDN 会长期留着旧副本（带 ?ts= 也压不住），
  # 旧副本语法合法但内容过期，很容易被误当成「下载成功」。API 的 contents 接口不吃这层缓存。
  if dl "$_api" "$_tmp" "Accept: application/vnd.github.raw" && valid_backend "$_tmp" "$_sh"; then
    mv -f "$_tmp" "$_dest"; return 0
  fi
  rm -f "$_tmp" 2>/dev/null
  warn "GitHub API 不可用（可能是限流），改用 raw 直链（可能是旧版本）"
  if dl "$_url" "$_tmp" && valid_backend "$_tmp" "$_sh"; then
    mv -f "$_tmp" "$_dest"; return 0
  fi
  rm -f "$_tmp" 2>/dev/null
  return 1
}

writable_dir() { mkdir -p "$1" 2>/dev/null && [ -w "$1" ] && echo "$1"; }

resolve_backend() { # <os> -> 打印后端路径
  _os="$1"
  _f=$(backend_name "$_os"); _sh=$(shell_for "$_os")

  for _c in "$SELF_DIR/$_f" "$SHARE_DIR/$_f"; do
    if [ -f "$_c" ] && valid_backend "$_c" "$_sh"; then echo "$_c"; return 0; fi
  done

  _dir=$(writable_dir "$CACHE_DIR" || writable_dir "$FALLBACK_CACHE" || true)
  if [ -n "${_dir:-}" ] && [ -f "$_dir/$_f" ] && valid_backend "$_dir/$_f" "$_sh"; then
    if [ "${OFFLINE:-0}" = 1 ]; then echo "$_dir/$_f"; return 0; fi
    if download_backend "$_os" "$_dir/$_f" >/dev/null 2>&1; then echo "$_dir/$_f"; return 0; fi
    warn "联网刷新失败，改用本地缓存 $_dir/$_f" >&2
    echo "$_dir/$_f"; return 0
  fi

  if [ "${OFFLINE:-0}" = 1 ]; then
    bad "--offline 但没有可用的本地后端（${_f}）"; return 1
  fi
  [ -n "${_dir:-}" ] || { bad "没有可写的缓存目录（$CACHE_DIR / ${FALLBACK_CACHE}）"; return 1; }
  download_backend "$_os" "$_dir/$_f" || { bad "下载后端失败：$_f"; return 1; }
  valid_backend "$_dir/$_f" "$_sh" || { bad "后端校验失败：$_dir/$_f"; return 1; }
  echo "$_dir/$_f"
}

# ---------------- 参数解析 ----------------
APPLY=0; OFFLINE=0; WANT_SSH=0; FORCE_OS="${VPS_TUNE_OS:-}"
NL='
'
RAW=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -V|--version) echo "vps-tune $VERSION"; exit 0 ;;
    --apply)      APPLY=1 ;;
    --offline)    OFFLINE=1 ;;
    --ssh)        WANT_SSH=1 ;;
    --os)         if [ $# -lt 2 ]; then bad "--os 缺少取值（alpine|debian）"; exit 2; fi
                  FORCE_OS="$2"; shift ;;
    --os=*)       FORCE_OS="${1#--os=}" ;;
    *)            RAW="$RAW$NL$1" ;;
  esac
  shift
done

OS=$(detect_os)
case "$OS" in
  alpine|debian) ;;
  *) bad "无法识别的系统，只支持 Alpine / Debian / Ubuntu"
     say "   确定要跑某个后端，用 --os alpine|debian 强制指定"; exit 3 ;;
esac

# ---------------- 参数透传与默认值 ----------------
# 带值的标志，丢的时候要连值一起丢
VALUE_FLAGS=" --tz --hostname --journald-max --swap --mtu "
DROP_ALPINE=" --rollback --no-journald --no-clean --tz --hostname --journald-max --swap --mtu "
DROP_DEBIAN=" --no-tools --no-tz --sysctl-only "

if [ "$OS" = alpine ]; then DROP="$DROP_ALPINE"; else DROP="$DROP_DEBIAN"; fi

set -f
set -- $RAW
set +f
FINAL=""
while [ $# -gt 0 ]; do
  t="$1"
  case "$DROP" in
    *" $t "*)
      case "$VALUE_FLAGS" in
        *" $t "*) if [ $# -ge 2 ]; then warn "本后端不支持 ${t}（连其取值），已忽略"; shift 2
                  else warn "本后端不支持 ${t}，已忽略"; shift; fi
                  continue ;;
        *)        warn "本后端不支持 ${t}，已忽略"; shift; continue ;;
      esac ;;
  esac
  FINAL="$FINAL$NL$t"; shift
done

if [ "$OS" = alpine ]; then
  # tune-alpine.sh 默认就执行，演练要显式 --dry-run
  [ "$APPLY" = 1 ] || FINAL="${NL}--dry-run$FINAL"
else
  # tune-debian.sh 默认演练，执行要显式 --apply
  [ "$APPLY" = 1 ] && FINAL="${NL}--apply$FINAL"
fi
[ "$WANT_SSH" = 1 ] || FINAL="$FINAL${NL}--no-ssh"

# 去重 + 解决 --apply / --dry-run 冲突（--apply 优先）
set -f
set -- $FINAL
set +f
HAVE_APPLY=0
for a in "$@"; do [ "$a" = "--apply" ] && HAVE_APPLY=1; done
SEEN="|"
DEDUP=""
for a in "$@"; do
  [ -z "$a" ] && continue
  if [ "$a" = "--dry-run" ] && [ "$HAVE_APPLY" = 1 ]; then continue; fi
  case "$SEEN" in *"|$a|"*) continue ;; esac
  SEEN="$SEEN$a|"
  DEDUP="$DEDUP$NL$a"
done

BACKEND=$(resolve_backend "$OS") || exit 4
SH=$(shell_for "$OS")

set -f
set -- $DEDUP
set +f
say "${C_G}vps-tune${C_N} $VERSION  后端 $(basename "$BACKEND")（${OS}）"
if [ -n "$DEDUP" ]; then
  say "   参数: $*"
else
  say "   参数: （无）"
fi
say ""
exec "$SH" "$BACKEND" "$@"
