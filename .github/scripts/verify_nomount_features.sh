#!/usr/bin/env bash
# Verify NoMount and feature switches against the built kernel .config.
set -euo pipefail

KERNEL_ROOT="${1:-$PWD/kernel_workspace}"
ENABLED="${2:-true}"
REPORT="${3:-$PWD/verification.txt}"

if [[ -d "$KERNEL_ROOT/fs" ]]; then
  COMMON="$KERNEL_ROOT"
elif [[ -d "$KERNEL_ROOT/common/fs" ]]; then
  COMMON="$KERNEL_ROOT/common"
else
  echo "ERROR: kernel tree not found" | tee "$REPORT"
  exit 1
fi
COMMON="$(cd "$COMMON" && pwd)"
CONFIG="$COMMON/out/.config"
SYSMAP="$COMMON/out/System.map"
MODULE="${GITHUB_WORKSPACE:-$PWD}/nomount-module.zip"

FAIL=()
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; FAIL+=("$*"); }
check_key() {
  local key="$1" expected="$2" label="$3"
  if grep -q "^${key}=${expected}$" "$CONFIG"; then ok "$label ($key=$expected)"; else bad "$label ($key=$expected missing)"; fi
}
check_any() {
  local label="$1"; shift
  local k
  for k in "$@"; do
    if grep -q "^${k}=y$" "$CONFIG"; then ok "$label ($k=y)"; return 0; fi
  done
  bad "$label (none of: $*)"
}

{
  echo "# Verification report"
  echo "- time: $(date -u +%FT%TZ)"
  echo "- kernel root: $COMMON"
  echo "- NoMount enabled input: $ENABLED"
  echo "- NoMount tag: ${NOMOUNT_TAG:-unknown}"
  echo "- NoMount commit: ${NOMOUNT_COMMIT:-unknown}"
  echo "- NoMount protocol: ${NOMOUNT_PROTO:-unknown}"
  echo "- module zip: $MODULE"
  echo ""

  if [[ ! -f "$CONFIG" ]]; then
    bad "out/.config missing"
  else
    if [[ "$ENABLED" == "true" ]]; then
      echo "## NoMount"
      check_key CONFIG_NOMOUNT y "NoMount built-in config"
      if [[ -f "$COMMON/out/fs/nomount/nomount.o" ]]; then
        ok "NoMount object built (out/fs/nomount/nomount.o)"
      else
        bad "NoMount object missing"
      fi
      if [[ -f "$SYSMAP" ]] && grep -qE ' (nm_init|nm_exit|nomount_init|nomount_exit)$' "$SYSMAP"; then
        ok "NoMount symbols in System.map"
      else
        bad "NoMount symbols missing from System.map"
      fi
      if [[ -f "$MODULE" ]] && unzip -l "$MODULE" | grep -q 'module.prop'; then
        ok "latest metamodule zip embedded"
      else
        bad "metamodule zip missing/invalid"
      fi
    else
      echo "## NoMount disabled"
      if grep -q '^CONFIG_NOMOUNT=y$' "$CONFIG"; then bad "CONFIG_NOMOUNT=y while disabled"; else ok "CONFIG_NOMOUNT is not enabled"; fi
      if [[ -f "$MODULE" ]]; then bad "metamodule zip exists while disabled"; else ok "no metamodule zip while disabled"; fi
    fi

    echo ""
    echo "## Feature switches"
    if [[ "${KSU_TYPE:-none}" != "none" && "${SUSFS_ENABLE:-false}" == "true" ]]; then
      check_key CONFIG_KSU_SUSFS y "SUSFS"
    fi
    if [[ "${LZ4_ENABLE:-false}" == "true" ]]; then
      check_any "LZ4" CONFIG_CRYPTO_LZ4HC CONFIG_CRYPTO_LZ4
    fi
    if [[ "${BBR_ENABLE:-false}" == "true" ]]; then
      check_key CONFIG_TCP_CONG_BBR y "BBR"
    fi
    if [[ "${DROIDSPACES_ENABLE:-false}" != "false" ]]; then
      check_key CONFIG_NTSYNC y "Droidspaces NTSYNC"
      check_key CONFIG_NAMESPACES y "Droidspaces namespaces"
    fi
    if [[ "${SSG_ENABLE:-false}" == "true" ]]; then
      check_key CONFIG_MQ_IOSCHED_SSG y "SSG"
    fi
    if [[ "${ADIOS_ENABLE:-false}" == "true" ]]; then
      check_key CONFIG_MQ_IOSCHED_ADIOS y "ADIOS"
    fi
    if [[ "${REKERNEL_ENABLE:-false}" == "true" ]]; then
      check_key CONFIG_REKERNEL y "Re-Kernel"
    fi
    if [[ "${BASEBAND_GUARD:-false}" == "true" ]]; then
      check_key CONFIG_BBG y "Baseband guard"
    fi
    if [[ "${LZ4KD_ENABLE:-false}" == "true" ]]; then
      check_key CONFIG_CRYPTO_LZ4KD y "LZ4KD"
    fi
    echo "KPM: ${KPM_ENABLE:-false} (KPM is applied by patch; see build step status)"

    echo ""
    echo "## Raw config evidence"
    grep -E '^(CONFIG_NOMOUNT|CONFIG_KSU|CONFIG_KSU_SUSFS|CONFIG_KPM|CONFIG_CRYPTO_LZ4|CONFIG_ZRAM_BACKEND_LZ4|CONFIG_TCP_CONG_BBR|CONFIG_MQ_IOSCHED_(SSG|ADIOS)|CONFIG_NTSYNC|CONFIG_NAMESPACES|CONFIG_REKERNEL|CONFIG_BBG)=' "$CONFIG" || true
  fi

  echo ""
  if (( ${#FAIL[@]} )); then
    echo "RESULT: FAIL (${#FAIL[@]})"
    printf ' - %s\n' "${FAIL[@]}"
    exit 1
  fi
  echo "RESULT: PASS"
} 2>&1 | tee "$REPORT"
