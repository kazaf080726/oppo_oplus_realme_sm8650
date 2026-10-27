#!/usr/bin/env bash
# NoMount latest-release built-in integration.
# - resolves the latest NoMount release every run
# - clones that tag fresh
# - installs kernel/src into <kernel>/fs/nomount
# - enables CONFIG_NOMOUNT=y
# - downloads the matching metamodule ZIP for embedding
# - verifies source / Kconfig / Makefile / defconfig / module
set -euo pipefail

KERNEL_ROOT="${1:-$PWD/kernel_workspace}"
log() { printf '[nomount] %s\n' "$*"; }

if [[ -d "$KERNEL_ROOT/fs" ]]; then
  COMMON="$KERNEL_ROOT"
elif [[ -d "$KERNEL_ROOT/common/fs" ]]; then
  COMMON="$KERNEL_ROOT/common"
else
  log "ERROR: kernel tree not found under $KERNEL_ROOT"
  exit 1
fi
COMMON="$(cd "$COMMON" && pwd)"
FS="$COMMON/fs"
DEFCONFIG="$COMMON/arch/arm64/configs/gki_defconfig"
for f in "$FS/Makefile" "$FS/Kconfig" "$DEFCONFIG"; do
  [[ -f "$f" ]] || { log "ERROR: missing $f"; exit 1; }
done

# Resolve latest release tag from the live repository every run.
TAG="$(gh api repos/maxsteeel/nomount/releases/latest --jq '.tag_name' 2>/dev/null || true)"
if [[ -z "$TAG" || "$TAG" == "null" ]]; then
  TAG="$(git ls-remote --tags --refs https://github.com/maxsteeel/nomount.git \
    | awk -F/ '{print $NF}' | grep -E '^v?[0-9]' | sort -V | tail -n1)"
fi
[[ -n "$TAG" ]] || { log "ERROR: cannot resolve latest NoMount release"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
log "cloning maxsteeel/nomount @ latest release $TAG"
git clone --depth=1 --branch "$TAG" https://github.com/maxsteeel/nomount.git "$TMP/nomount" >/dev/null
SRC="$TMP/nomount/kernel/src"
[[ -f "$SRC/nomount.c" && -f "$SRC/nomount.h" ]] || { log "ERROR: source layout changed"; exit 1; }
COMMIT="$(git -C "$TMP/nomount" rev-parse --short HEAD)"
PROTO="$(sed -n 's/.*NOMOUNT_BASE_VERSION "\([0-9]*\)".*/\1/p' "$SRC/nomount.h" | head -n1)"
[[ -n "$PROTO" ]] || { log "ERROR: cannot read NoMount protocol"; exit 1; }

# Backups once, never overwrite the first backup.
for f in "$FS/Makefile" "$FS/Kconfig" "$DEFCONFIG"; do
  [[ -f "$f.nomount-bak" ]] || cp -p "$f" "$f.nomount-bak"
done

rm -rf "$FS/nomount"
mkdir -p "$FS/nomount"
cp -a "$SRC/." "$FS/nomount/"

if ! grep -q 'CONFIG_NOMOUNT' "$FS/Makefile"; then
  printf '\nobj-$(CONFIG_NOMOUNT) += nomount/\n' >> "$FS/Makefile"
fi
if ! grep -q 'fs/nomount/Kconfig' "$FS/Kconfig"; then
  if grep -q '^endmenu' "$FS/Kconfig"; then
    awk '
      /^endmenu/ { last = NR }
      { lines[NR] = $0 }
      END {
        for (i = 1; i <= NR; i++) {
          if (i == last) print "source \"fs/nomount/Kconfig\""
          print lines[i]
        }
      }
    ' "$FS/Kconfig" > "$FS/Kconfig.nomount.tmp"
    mv "$FS/Kconfig.nomount.tmp" "$FS/Kconfig"
  else
    printf '\nsource "fs/nomount/Kconfig"\n' >> "$FS/Kconfig"
  fi
fi
sed -i '/^CONFIG_NOMOUNT=/d; /^# CONFIG_NOMOUNT is not set/d' "$DEFCONFIG"
printf 'CONFIG_NOMOUNT=y\n' >> "$DEFCONFIG"

# Matching metamodule (userspace nm / WebUI / boot scripts) from the same release.
MODULE_DIR="$(mktemp -d)"
ASSET="$(gh release view "$TAG" -R maxsteeel/nomount --json assets \
  --jq '.assets[] | select(.name | test("^NoMount-.*\\.zip$")) | .name' | head -n1)"
if [[ -n "$ASSET" && "$ASSET" != "null" ]]; then
  gh release download "$TAG" -R maxsteeel/nomount -p "$ASSET" -D "$MODULE_DIR" >/dev/null
  WORKSPACE="${GITHUB_WORKSPACE:-$(dirname "$KERNEL_ROOT")}"
  MODULE_PATH="$WORKSPACE/nomount-module.zip"
  mv "$MODULE_DIR/$ASSET" "$MODULE_PATH"
  unzip -l "$MODULE_PATH" | grep -q 'module.prop' || { log "ERROR: bad metamodule zip"; exit 1; }
  log "metamodule saved: $MODULE_PATH ($ASSET)"
else
  log "ERROR: latest release has no NoMount-*.zip asset"
  exit 1
fi
rm -rf "$MODULE_DIR"

# Hard verification before the kernel build.
grep -q 'obj-$(CONFIG_NOMOUNT) += nomount/' "$FS/Makefile"
grep -q 'fs/nomount/Kconfig' "$FS/Kconfig"
grep -q '^CONFIG_NOMOUNT=y$' "$DEFCONFIG"
[[ -f "$FS/nomount/nomount.c" && -f "$FS/nomount/nomount.h" ]]
grep -q 'NOMOUNT_BASE_VERSION' "$FS/nomount/nomount.h"
[[ -f "${GITHUB_WORKSPACE:-$(dirname "$KERNEL_ROOT")}/nomount-module.zip" ]]

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "NOMOUNT_TAG=$TAG"
    echo "NOMOUNT_COMMIT=$COMMIT"
    echo "NOMOUNT_PROTO=$PROTO"
    echo "NOMOUNT_MODULE_PATH=${GITHUB_WORKSPACE:-$(dirname "$KERNEL_ROOT")}/nomount-module.zip"
  } >> "$GITHUB_ENV"
fi
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### NoMount built-in"
    echo ""
    echo "- latest release: \`$TAG\` @ \`$COMMIT\`"
    echo "- driver protocol: v$PROTO"
    echo "- source: \`fs/nomount/\`"
    echo "- defconfig: \`CONFIG_NOMOUNT=y\`"
    echo "- metamodule: \`${GITHUB_WORKSPACE:-$(dirname "$KERNEL_ROOT")}/nomount-module.zip\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi
log "OK: NoMount $TAG @ $COMMIT protocol=v$PROTO"
