#!/usr/bin/env bash
# =============================================================================
# 临时应急修复：为 BakaSU 补回 SELinux hide 所需的 fake_state
#
# 现象（第一次修复后）：
#   内核能编译、能刷入，但 SELinux hide 功能完全失效。
#
# 原因：
#   susfs4oki 的 6.1 补丁（50_add_susfs_in_gki-android14-6.1.patch）在
#   security/selinux/hooks.c、selinuxfs.c 里使用
#       extern struct selinux_state fake_state;
#   来做 app（uid>=10000）的上下文校验/伪装。
#   BakaSU 在 fa12ffde（v4.2.0-rc3）重构 selinux_hide 时删除了 fake_state；
#   而在 susfs 模式下（KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE）BakaSU 会
#   跳过自己的 selinuxfs 钩子，把 SELinux hide 完全交给 susfs 内核补丁。
#   于是补丁成为唯一实现，fake_state 缺失 = SELinux hide 整体失效。
#
#   之前的应急方案把 &fake_state 换成真实 state，虽然能链接，但等于把
#   SUSFS 的隐藏路径改回“真实策略校验”，所以功能失效。本脚本废弃该方案。
#
# 正确做法（与 WildKernels / cctv18 10_enable 的设计一致）：
#   1. 在 BakaSU 的 kernel/feature/selinux_hide.c 中补一个全局
#        struct selinux_state fake_state;
#   2. 在 ksu_selinux_hide_enable() 里、备份策略检查通过后，用
#        fake_state.initialized = true;
#        fake_state.policy = backup_sepolicy;
#      初始化它（6.1 属于 5.10+ / <6.6 分支）。
#   3. 内核里的 &fake_state 引用保持原样，由 BakaSU 提供真实符号。
#
#   这样 susfs 内核补丁的 sel_write_context / sel_write_access /
#   selinux_setprocattr 重新走“备份策略”校验，SELinux hide 恢复。
#
# 本脚本只修改 runner 里的 BakaSU 克隆，不修改：
#   - 仓库里的原始工作流 / 原始构建脚本 / 补丁
#   - 内核源码里的 &fake_state 引用
#
# 用法：
#   bash .github/scripts/hotfix_bakasu_fake_state.sh [kernel_workspace 或 common 目录]
#   HOTFIX_DRY_RUN=1 bash ...   # 只检查，不修改
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="${1:-}"
if [[ -n "$TARGET" ]]; then
  KERNEL_ROOT="$TARGET"
else
  KERNEL_ROOT="$REPO_ROOT/kernel_workspace"
fi

log() { printf '[fake_state-hotfix] %s\n' "$*"; }

if [[ -d "$KERNEL_ROOT/security/selinux" ]]; then
  COMMON="$KERNEL_ROOT"
elif [[ -d "$KERNEL_ROOT/common/security/selinux" ]]; then
  COMMON="$KERNEL_ROOT/common"
else
  log "未找到内核源码（$KERNEL_ROOT[/common]/security/selinux），跳过。"
  exit 0
fi
KERNEL_ROOT="$(cd "$COMMON/.." && pwd)"

HOOKS="$COMMON/security/selinux/hooks.c"
SELINUXFS="$COMMON/security/selinux/selinuxfs.c"

for f in "$HOOKS" "$SELINUXFS"; do
  if [[ ! -f "$f" ]]; then
    log "缺少文件：$f，跳过。"
    exit 0
  fi
done

HOOKS_N="$(grep -c '&fake_state' "$HOOKS" || true)"
FS_N="$(grep -c '&fake_state' "$SELINUXFS" || true)"
TOTAL=$((HOOKS_N + FS_N))

if [[ "$TOTAL" -eq 0 ]]; then
  log "未发现 &fake_state 引用（可能未开启 susfs，或补丁已更新），无需处理。"
  exit 0
fi

log "内核源码：$COMMON"
log "susfs 补丁引用 fake_state：hooks.c=$HOOKS_N 处，selinuxfs.c=$FS_N 处。"
log "开始为 KernelSU/BakaSU 补回全局 fake_state 并从 backup_sepolicy 初始化 ..."

if [[ "${HOTFIX_DRY_RUN:-0}" == "1" ]]; then
  log "dry-run：只检查，不修改。"
  exit 0
fi

PYTHON_BIN=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys' >/dev/null 2>&1; then
    PYTHON_BIN="$c"
    break
  fi
done
if [[ -z "$PYTHON_BIN" ]]; then
  log "错误：找不到 python3/python，无法安全地打补丁。"
  exit 1
fi

PATCHED_FILE=""
for KSU_DIR in "$KERNEL_ROOT/KernelSU" "$KERNEL_ROOT/KernelSU-Next"; do
  HIDE="$KSU_DIR/kernel/feature/selinux_hide.c"
  [[ -f "$HIDE" ]] || continue

  if grep -q 'struct selinux_state fake_state;' "$HIDE"; then
    log "已存在 fake_state 定义：$HIDE"
    PATCHED_FILE="$HIDE"
    break
  fi

  if ! grep -q 'static DEFINE_MUTEX(selinux_hide_mutex);' "$HIDE" || \
     ! grep -q 'no backup sidtab available' "$HIDE"; then
    log "跳过（锚点不匹配）：$HIDE"
    continue
  fi

  log "正在补 fake_state：$HIDE"
  if [[ ! -f "$HIDE.hotfix-bak" ]]; then
    cp -p "$HIDE" "$HIDE.hotfix-bak"
    log "已备份：$HIDE.hotfix-bak"
  fi
  "$PYTHON_BIN" - "$HIDE" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding='utf-8') as fh:
    src = fh.read()

if 'struct selinux_state fake_state;' in src:
    print('already-patched')
    sys.exit(0)

anchor1 = 'static DEFINE_MUTEX(selinux_hide_mutex);\n'
if src.count(anchor1) != 1:
    print('anchor1-not-unique', file=sys.stderr)
    sys.exit(2)
src = src.replace(anchor1, anchor1 + 'struct selinux_state fake_state;\n', 1)

tail = '''    if (!backup_sidtab) {
        pr_err("no backup sidtab available, please save feature and reboot to retry!\\n");
        return -EAGAIN;
    }
#endif
'''
if src.count(tail) != 1:
    print('anchor2-not-unique', file=sys.stderr)
    sys.exit(3)

prime = tail + '''
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0) || defined(KSU_COMPAT_HAS_SELINUX_POLICY_STRUCT)
    fake_state.initialized = true;
    fake_state.policy = backup_sepolicy;
    pr_info("selinux_hide: fake_state primed from backup_sepolicy\\n");
#endif
'''
src = src.replace(tail, prime, 1)

with open(path, 'w', encoding='utf-8', newline='') as fh:
    fh.write(src)
print('patched')
PY

  if grep -q 'struct selinux_state fake_state;' "$HIDE" && \
     grep -q 'fake_state.policy = backup_sepolicy;' "$HIDE"; then
    log "fake_state 已补齐并初始化：$HIDE"
    PATCHED_FILE="$HIDE"
    break
  fi
done

if [[ -z "$PATCHED_FILE" ]]; then
  log "错误：未能为当前 KernelSU 补上 fake_state（找不到 selinux_hide.c 或锚点不匹配）。"
  log "为避免生成 SELinux hide 失效的内核，本次构建终止。"
  exit 1
fi

# 关键：内核里的 &fake_state 引用必须保持原样，由 BakaSU 提供符号
if ! grep -q '&fake_state' "$HOOKS" || ! grep -q '&fake_state' "$SELINUXFS"; then
  log "错误：内核 &fake_state 引用被意外修改，修复不完整。"
  exit 1
fi

log "完成：内核保持 &fake_state 引用，$PATCHED_FILE 提供并初始化 fake_state。"
log "SELinux hide 的 susfs 路径已恢复（未改动原始脚本/补丁）。"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### 临时应急修复：恢复 BakaSU fake_state（SELinux hide）"
    echo ""
    echo "- 内核源码：\`$COMMON\`"
    echo "- susfs 补丁引用：hooks.c = $HOOKS_N，selinuxfs.c = $FS_N"
    echo "- 处理：在 \`KernelSU/kernel/feature/selinux_hide.c\` 补全局 \`fake_state\`，"
    echo "  并在 \`ksu_selinux_hide_enable()\` 中用 \`backup_sepolicy\` 初始化"
    echo "- 内核中的 \`&fake_state\` 引用保持不变，SELinux hide 恢复走备份策略"
    echo "- 未修改：原始工作流、local/ 脚本、susfs4oki / BakaSU 补丁"
  } >> "$GITHUB_STEP_SUMMARY"
fi
