#!/bin/sh
# =========================================================
# install.sh — 把 vps-tune 装成本地命令（Alpine / Debian / Ubuntu）
#   /usr/local/bin/vps-tune              统一入口
#   /usr/local/share/vps-tune/tune-*.sh  对应系统的后端
#
# 用法:
#   sh install.sh                  装当前系统对应的后端
#   sh install.sh --all            两个后端都装上
#   sh install.sh --dry-run        只打印会做什么
# =========================================================
set -u

VERSION="1.0.0"
REPO="${VPS_TUNE_REPO:-jyucoeng/vps-tune}"
BRANCH="${VPS_TUNE_BRANCH:-main}"
BIN_DIR="${PREFIX:-/usr/local}/bin"
SHARE_DIR="${PREFIX:-/usr/local}/share/vps-tune"

DRY=0; ALL=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --all) ALL=1 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -V|--version) echo "vps-tune install.sh $VERSION"; exit 0 ;;
    *) echo "未知参数: ${a}（--help 看用法）"; exit 1 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
ok()   { printf '   ✓ %s\n' "$*"; }
warn() { printf '   ! %s\n' "$*"; }
bad()  { printf '   ✗ %s\n' "$*" >&2; }

detect_os() {
  [ -f /etc/alpine-release ] && { echo alpine; return; }
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    (. /etc/os-release 2>/dev/null
     case " ${ID:-} ${ID_LIKE:-} " in
       *" alpine "*) echo alpine ;;
       *" debian "*|*" ubuntu "*) echo debian ;;
       *) echo unsupported ;;
     esac)
    return
  fi
  echo unsupported
}

dl() { # <url> <out> [header]
  if command -v curl >/dev/null 2>&1; then
    if [ -n "${3:-}" ]; then
      curl -fsSL --connect-timeout 8 --max-time 120 --retry 2 --retry-all-errors -H "$3" -o "$2" "$1"
    else
      curl -fsSL --connect-timeout 8 --max-time 120 --retry 2 --retry-all-errors -o "$2" "$1"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if [ -n "${3:-}" ]; then wget -q -T 30 --header="$3" -O "$2" "$1"
    else wget -q -T 30 -O "$2" "$1"; fi
  else
    return 1
  fi
}

fetch() { # <相对文件名> <目标路径> <sh>
  local f="$1" dest="$2" sh="${3:-sh}" tmp="${2}.part.$$"
  say "   拉取 $f"
  if dl "https://raw.githubusercontent.com/$REPO/$BRANCH/$f?ts=$(date +%s)" "$tmp" \
     && [ -s "$tmp" ] && "$sh" -n "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$dest"; ok "$dest"
    return 0
  fi
  rm -f "$tmp"
  warn "直链失败，改用 GitHub API"
  if dl "https://api.github.com/repos/$REPO/contents/$f?ref=$BRANCH" "$tmp" \
        "Accept: application/vnd.github.raw" \
     && [ -s "$tmp" ] && "$sh" -n "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$dest"; ok "$dest"
    return 0
  fi
  rm -f "$tmp"; bad "拉取失败：$f"; return 1
}

OS=$(detect_os)
TARGETS=""
if [ "$ALL" = 1 ]; then TARGETS="alpine debian"
elif [ "$OS" = alpine ] || [ "$OS" = debian ]; then TARGETS="$OS"
else bad "无法识别的系统（${OS}）；可用 --all 直接装两个后端"; exit 3; fi

say "vps-tune 安装器 $VERSION"
say "   系统: $OS   目标后端: $TARGETS"
say "   安装到: $BIN_DIR/vps-tune  +  $SHARE_DIR/"
[ "$DRY" = 1 ] && say "   （演练模式，不做任何改动）"
say ""

if [ "$DRY" = 1 ]; then
  say "将创建 ${BIN_DIR}、$SHARE_DIR 并写入 vps-tune.sh + tune-*.sh"
  exit 0
fi

mkdir -p "$BIN_DIR" "$SHARE_DIR" || { bad "建目录失败（需要 root？）"; exit 4; }

fetch "vps-tune.sh" "$BIN_DIR/vps-tune" bash || exit 5
chmod 755 "$BIN_DIR/vps-tune"

for os in $TARGETS; do
  sh_bin=sh; [ "$os" = debian ] && sh_bin=bash
  fetch "tune-$os.sh" "$SHARE_DIR/tune-$os.sh" "$sh_bin" || exit 5
  chmod 755 "$SHARE_DIR/tune-$os.sh"
done

say ""
ok "安装完成"
say "   试跑（不改系统）: vps-tune --os ${TARGETS%% *} --dry-run"
say "   正式执行:        vps-tune --apply"
say "   撤销改动:        vps-tune --rollback   （Alpine 侧无回滚，需自行备份）"
