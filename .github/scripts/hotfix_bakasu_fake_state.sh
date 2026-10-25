#!/usr/bin/env bash
# =============================================================================
# 临时应急修复：兼容新版 BakaSU 的 selinux fake_state
#
# 现象：
#   vmlinux 链接阶段报
#       ld.lld: error: undefined symbol: fake_state
#       >>> referenced by selinuxfs.c:726 (../security/selinux/selinuxfs.c:726)
#       >>>               security/selinux/selinuxfs.o:(sel_write_context)
#   随后 pahole / .btf.vmlinux.bin.o 连锁报错（“Invalid argument”“unknown file type”）。
#
# 原因：
#   susfs4oki 的 6.1 内核补丁 50_add_susfs_in_gki-android14-6.1.patch 在
#   security/selinux/hooks.c、security/selinux/selinuxfs.c 中加入
#       extern struct selinux_state fake_state;
#   并把 app(uid >= 10000) 写 selinux 上下文时的校验切到 &fake_state。
#   该符号原本由 BakaSU 的 kernel/feature/selinux_hide.c 提供。
#   BakaSU 提交 fa12ffde（v4.2.0-rc3，2026-10-11，cherry-pick tiann/KernelSU #3877）
#   重构 selinux_hide 后删除了 fake_state（fake_status 等仍然保留），
#   而 50 号补丁没有同步更新，于是链接时找不到符号。
#
#   工作流只在 ksu_type == ksu（原版 KernelSU）时才应用
#   kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch；
#   bakasu / sukisu（都指向 BakaSU）不会应用，因此缺少 fake_state 的定义。
#
# 本脚本做什么：
#   只在内核源码【打完 50 号补丁之后】做幂等的兼容处理，且只在
#   BakaSU 确实没有定义 fake_state 时才动手：
#     hooks.c      &fake_state  ->  &selinux_state   （上游原本就是 &selinux_state）
#     selinuxfs.c  &fake_state  ->  state            （函数内 struct selinux_state *state = fsi->state）
#   并删除已经无用的 extern 声明。
#
#   新版 BakaSU 的 selinux_hide 已经用 backup_policydb/backup_sidtab + fops 包装
#   自行接管 app 的上下文写入（my_write_context），补丁里这条 fake_state 分支
#   在 uid>=10000 时不会真正被走到；退回到真实 selinux_state 与上游行为一致，
#   不影响 SUSFS 的其余功能（sus_path / sus_mount / open_redirect / status 等）。
#
# 本脚本不修改：
#   - 原始工作流（只由工作流新增的一步调用本脚本）
#   - local/ 下的原始构建脚本
#   - susfs4oki / BakaSU / 任何补丁文件
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

# 若 KernelSU 侧仍然定义 fake_state（旧版 BakaSU，或已应用 10_enable_susfs_for_ksu.patch），
# 保持补丁原始逻辑，不做任何修改。
KSU_DEF=""
for d in "$KERNEL_ROOT/KernelSU" "$KERNEL_ROOT/KernelSU-Next"; do
  [[ -d "$d" ]] || continue
  if grep -rqsE --include='*.c' --include='*.h' \
      '^[[:space:]]*(__maybe_static[[:space:]]+)?struct[[:space:]]+selinux_state[[:space:]]+fake_state[[:space:]]*;' \
      "$d"; then
    KSU_DEF="$d"
    break
  fi
done

if [[ -n "$KSU_DEF" ]]; then
  log "KernelSU 目录仍定义 fake_state（$KSU_DEF），保留补丁原始逻辑，跳过。"
  exit 0
fi

log "内核源码：$COMMON"
log "检测到补丁引用 fake_state（hooks.c=$HOOKS_N 处，selinuxfs.c=$FS_N 处），但 KernelSU 未定义该符号。"
log "新版 BakaSU 已删除 fake_state，开始还原为真实 selinux_state ..."

if [[ "${HOTFIX_DRY_RUN:-0}" == "1" ]]; then
  log "dry-run：将修改 hooks.c 的 $HOOKS_N 处、selinuxfs.c 的 $FS_N 处，并删除 extern 声明。"
  exit 0
fi

for f in "$HOOKS" "$SELINUXFS"; do
  if [[ ! -f "$f.hotfix-bak" ]]; then
    cp -p "$f" "$f.hotfix-bak"
    log "已备份：$f.hotfix-bak"
  else
    log "备份已存在，保留首次备份：$f.hotfix-bak"
  fi
done

# hooks.c 里没有局部 state 变量，使用全局 selinux_state（上游同样调用）
sed -i 's/&fake_state/\&selinux_state/g' "$HOOKS"
# selinuxfs.c 的 sel_write_context / sel_write_access 内都有 struct selinux_state *state = fsi->state;
sed -i 's/&fake_state/state/g' "$SELINUXFS"
# 删除已无用的 extern 声明
sed -i '/^[[:space:]]*extern struct selinux_state fake_state;[[:space:]]*$/d' "$HOOKS" "$SELINUXFS"

if grep -q 'fake_state' "$HOOKS" "$SELINUXFS"; then
  log "错误：仍残留 fake_state 引用，修复未完成。"
  grep -n 'fake_state' "$HOOKS" "$SELINUXFS" || true
  exit 1
fi

if ! grep -qE '^[[:space:]]*struct[[:space:]]+selinux_state[[:space:]]+\*state[[:space:]]*=[[:space:]]*fsi->state;' "$SELINUXFS"; then
  log "错误：selinuxfs.c 中未找到局部 state 变量，替换结果可能不正确。"
  exit 1
fi

log "修复完成：hooks.c $HOOKS_N 处 -> &selinux_state，selinuxfs.c $FS_N 处 -> state。"
log "原始脚本、原始补丁均未修改。"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### 临时应急修复：BakaSU fake_state 兼容"
    echo ""
    echo "- 内核源码：\`$COMMON\`"
    echo "- 修复前 \`&fake_state\` 引用：hooks.c = $HOOKS_N，selinuxfs.c = $FS_N"
    echo "- 原因：BakaSU fa12ffde（v4.2.0-rc3）重构后删除了 \`fake_state\`，susfs4oki 的 6.1 补丁仍按旧版引用"
    echo "- 处理：仅在 BakaSU 未定义该符号时，把旧调用点还原为真实的 selinux state"
    echo "- 未修改：原始工作流步骤、local/ 构建脚本、susfs4oki / BakaSU 补丁"
  } >> "$GITHUB_STEP_SUMMARY"
fi
