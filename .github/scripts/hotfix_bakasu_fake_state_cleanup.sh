#!/usr/bin/env bash
# =============================================================================
# 清理脚本：撤销 hotfix_bakasu_fake_state.sh 对内核源码的临时修改
#
# 只做两件事：
#   1. 用 *.hotfix-bak 备份恢复 security/selinux/hooks.c 与 selinuxfs.c
#   2. 删除对应的 *.hotfix-bak 备份文件
#
# 明确不会：
#   - 删除或修改仓库里的任何原始脚本（local/*.sh、.github/scripts/*.sh 等）
#   - 删除或修改工作流文件
#   - 删除或修改任何补丁
#   - 删除内核源码目录（kernel_workspace）本身
#
# 用法：
#   bash .github/scripts/hotfix_bakasu_fake_state_cleanup.sh [kernel_workspace 或 common 目录]
#   HOTFIX_DRY_RUN=1 bash ...   # 只打印将要恢复的文件
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="${1:-}"
if [[ -n "$TARGET" ]]; then
  KERNEL_ROOT="$TARGET"
else
  KERNEL_ROOT="$REPO_ROOT/kernel_workspace"
fi

log() { printf '[fake_state-cleanup] %s\n' "$*"; }

if [[ -d "$KERNEL_ROOT/security/selinux" ]]; then
  COMMON="$KERNEL_ROOT"
elif [[ -d "$KERNEL_ROOT/common/security/selinux" ]]; then
  COMMON="$KERNEL_ROOT/common"
else
  log "未找到内核源码（$KERNEL_ROOT[/common]/security/selinux），跳过。"
  exit 0
fi

HOOKS="$COMMON/security/selinux/hooks.c"
SELINUXFS="$COMMON/security/selinux/selinuxfs.c"
RESTORED=0

for f in "$HOOKS" "$SELINUXFS"; do
  if [[ -f "$f.hotfix-bak" ]]; then
    if [[ "${HOTFIX_DRY_RUN:-0}" == "1" ]]; then
      log "dry-run：将恢复 $f（来自 $f.hotfix-bak）"
    else
      cp -p "$f.hotfix-bak" "$f"
      rm -f "$f.hotfix-bak"
      log "已恢复 $f"
    fi
    RESTORED=$((RESTORED + 1))
  else
    log "没有备份，保持原样：$f"
  fi
done

if [[ "$RESTORED" -eq 0 ]]; then
  log "没有需要清理的临时修改。"
else
  log "清理完成，共恢复 $RESTORED 个文件。仓库原始脚本、补丁、工作流均未改动。"
fi
