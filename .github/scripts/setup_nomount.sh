#!/usr/bin/env bash
# =============================================================================
# NoMount 内核集成脚本（可复用 / 幂等 / 支持版本更新）
#
# 作用：
#   把 maxsteeel/nomount 的内核部分以 built-in 方式集成进 GKI 内核源码：
#     - 复制 kernel/src -> <kernel>/fs/nomount/
#     - fs/Makefile 追加 obj-$(CONFIG_NOMOUNT) += nomount/
#     - fs/Kconfig 追加 source "fs/nomount/Kconfig"
#     - arch/arm64/configs/gki_defconfig 追加 CONFIG_NOMOUNT=y
#
# 备份（三处，全部保留）：
#   fs/Makefile.nomount-bak
#   fs/Kconfig.nomount-bak
#   arch/arm64/configs/gki_defconfig.nomount-bak
#   仅在首次运行时创建；后续更新不会覆盖第一次的原始备份。
#
# 兼容性：
#   - 不依赖内核小版本；6.1 / 6.6 / 未来版本通用（NoMount 自己按
#     LINUX_VERSION_CODE 适配）
#   - 重复运行会替换 fs/nomount 源码（便于更新 NoMount），但不会重复写
#     Makefile/Kconfig/defconfig
#   - 通过第 2 个参数或 NOMOUNT_REF 指定 tag/branch/commit，默认 v2.2.0
#
# 用法：
#   bash setup_nomount.sh <kernel_workspace 或 common 目录> [NoMount ref]
#   NOMOUNT_REF=v2.2.0 bash setup_nomount.sh /path/to/common
# =============================================================================
set -euo pipefail

KERNEL_ROOT="${1:-$PWD/kernel_workspace}"
NOMOUNT_REF="${2:-${NOMOUNT_REF:-v2.2.0}}"

log() { printf '[nomount] %s\n' "$*"; }

if [[ -d "$KERNEL_ROOT/fs" ]]; then
  COMMON="$KERNEL_ROOT"
elif [[ -d "$KERNEL_ROOT/common/fs" ]]; then
  COMMON="$KERNEL_ROOT/common"
else
  log "错误：找不到内核源码（$KERNEL_ROOT[/common]/fs）。"
  exit 1
fi
COMMON="$(cd "$COMMON" && pwd)"

FS="$COMMON/fs"
DEFCONFIG="$COMMON/arch/arm64/configs/gki_defconfig"

for f in "$FS/Makefile" "$FS/Kconfig" "$DEFCONFIG"; do
  if [[ ! -f "$f" ]]; then
    log "错误：缺少 $f"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# 1) 先备份（首次运行创建，绝不覆盖已有备份）
# ---------------------------------------------------------------------------
for f in "$FS/Makefile" "$FS/Kconfig" "$DEFCONFIG"; do
  if [[ ! -f "$f.nomount-bak" ]]; then
    cp -p "$f" "$f.nomount-bak"
    log "已备份：$f -> $f.nomount-bak"
  else
    log "备份已存在，保留首次备份：$f.nomount-bak"
  fi
done

# ---------------------------------------------------------------------------
# 2) 拉取 NoMount 源码（浅克隆，支持 tag / branch / commit）
# ---------------------------------------------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if ! git clone --depth=1 --branch "$NOMOUNT_REF" \
      https://github.com/maxsteeel/nomount.git "$TMP_DIR/nomount" >/dev/null 2>&1; then
  log "按 tag/branch 克隆失败，改用 commit 方式：$NOMOUNT_REF"
  git clone --depth=1 https://github.com/maxsteeel/nomount.git "$TMP_DIR/nomount" >/dev/null
  git -C "$TMP_DIR/nomount" fetch --depth=1 origin "$NOMOUNT_REF"
  git -C "$TMP_DIR/nomount" checkout --detach FETCH_HEAD >/dev/null
fi

SRC="$TMP_DIR/nomount/kernel/src"
if [[ ! -f "$SRC/nomount.c" ]]; then
  log "错误：NoMount 源码结构异常，缺少 $SRC/nomount.c"
  exit 1
fi
NM_COMMIT="$(git -C "$TMP_DIR/nomount" rev-parse --short HEAD)"

# ---------------------------------------------------------------------------
# 3) 安装/更新源码（整目录替换，便于以后更新 NoMount）
# ---------------------------------------------------------------------------
rm -rf "$FS/nomount"
mkdir -p "$FS/nomount"
cp -a "$SRC/." "$FS/nomount/"
log "已安装源码：$FS/nomount（NoMount $NOMOUNT_REF @ $NM_COMMIT）"

# ---------------------------------------------------------------------------
# 4) fs/Makefile
# ---------------------------------------------------------------------------
if grep -q 'CONFIG_NOMOUNT' "$FS/Makefile"; then
  log "fs/Makefile 已包含 CONFIG_NOMOUNT，跳过"
else
  printf '\nobj-$(CONFIG_NOMOUNT) += nomount/\n' >> "$FS/Makefile"
  log "已修改 fs/Makefile"
fi

# ---------------------------------------------------------------------------
# 5) fs/Kconfig（插到最后一个 endmenu 前；没有 endmenu 就追加）
# ---------------------------------------------------------------------------
if grep -q 'fs/nomount/Kconfig' "$FS/Kconfig"; then
  log "fs/Kconfig 已包含 fs/nomount/Kconfig，跳过"
else
  if grep -q '^endmenu' "$FS/Kconfig"; then
    awk '
      /^endmenu/ { last_match = NR }
      { lines[NR] = $0 }
      END {
        for (i = 1; i <= NR; i++) {
          if (i == last_match) print "source \"fs/nomount/Kconfig\""
          print lines[i]
        }
      }
    ' "$FS/Kconfig" > "$FS/Kconfig.nomount.tmp"
    mv "$FS/Kconfig.nomount.tmp" "$FS/Kconfig"
  else
    printf '\nsource "fs/nomount/Kconfig"\n' >> "$FS/Kconfig"
  fi
  log "已修改 fs/Kconfig"
fi

# ---------------------------------------------------------------------------
# 6) defconfig（先删旧项，保证只有一行 =y）
# ---------------------------------------------------------------------------
sed -i '/^CONFIG_NOMOUNT=/d; /^# CONFIG_NOMOUNT is not set/d' "$DEFCONFIG"
printf 'CONFIG_NOMOUNT=y\n' >> "$DEFCONFIG"
log "已在 $(basename "$DEFCONFIG") 启用 CONFIG_NOMOUNT=y"

# ---------------------------------------------------------------------------
# 7) 校验
# ---------------------------------------------------------------------------
fail() { log "错误：$*"; exit 1; }

grep -q 'obj-$(CONFIG_NOMOUNT) += nomount/' "$FS/Makefile" || fail "fs/Makefile 未写入 nomount"
grep -q 'fs/nomount/Kconfig' "$FS/Kconfig" || fail "fs/Kconfig 未写入 source"
grep -q '^CONFIG_NOMOUNT=y$' "$DEFCONFIG" || fail "defconfig 未启用 CONFIG_NOMOUNT"
[[ -f "$FS/nomount/nomount.c" ]] || fail "缺少 fs/nomount/nomount.c"
[[ -f "$FS/nomount/nomount.h" ]] || fail "缺少 fs/nomount/nomount.h"
grep -q 'NOMOUNT_BASE_VERSION' "$FS/nomount/nomount.h" || fail "NoMount 头文件异常"

NM_PROTO="$(grep -m1 'NOMOUNT_BASE_VERSION' "$FS/nomount/nomount.h" | sed 's/.*"\(.*\)".*/\1/')"
log "NoMount 集成完成：ref=$NOMOUNT_REF commit=$NM_COMMIT 协议=v$NM_PROTO"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### NoMount 内核集成"
    echo ""
    echo "- 内核源码：\`$COMMON\`"
    echo "- NoMount：\`$NOMOUNT_REF\` @ \`$NM_COMMIT\`，驱动协议 v$NM_PROTO"
    echo "- 源码：\`fs/nomount/\`"
    echo "- 备份：\`fs/Makefile.nomount-bak\`、\`fs/Kconfig.nomount-bak\`、\`gki_defconfig.nomount-bak\`"
    echo "- 配置文件：\`CONFIG_NOMOUNT=y\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi
