#!/bin/bash
# scint-linker — bulk-hardlink cached gems into a bundle.
#
# Protocol (stdin):
#   Line 1: source parent dir  (e.g. ~/.cache/scint/cached/ruby-3.4.7-x86_64-linux)
#   Line 2: dest parent dir    (e.g. .bundle/ruby/3.4.0/gems)
#   Remaining lines: gem directory basenames (e.g. "rack-3.2.4")
#
# The script probes the best copy strategy once (cpio, hardlink, reflink,
# copy) and uses it for every gem. When cpio is available it reads
# .scint-files from each cached gem so only listed files are materialized.
# Otherwise falls back to cp -al / cp --reflink / cp -R.

set -euo pipefail

read -r SRC
read -r DST
mkdir -p "$DST"

# ── detect strategy ──────────────────────────────────────────────
STRATEGY=""

# Probe needs a real file to test against. Find one quickly.
probe_src=""
for candidate in "$SRC"/*/.scint-files; do
  [ -f "$candidate" ] && probe_src="$candidate" && break
done

if [ -z "$probe_src" ]; then
  # No .scint-files at all — fall back to cp -al or cp -R
  if cp -al --version >/dev/null 2>&1; then
    STRATEGY="cp-al"
  else
    STRATEGY="cp"
  fi
else
  probe_dst="$DST/.scint-probe-$$"

  # 1. cpio -pld (file-list driven hardlinks — ideal)
  if command -v cpio >/dev/null 2>&1; then
    if echo "$probe_src" | cpio -pld "$DST" >/dev/null 2>&1; then
      rm -f "$probe_dst" 2>/dev/null
      STRATEGY="cpio"
    fi
  fi

  # 2. hardlink via ln
  if [ -z "$STRATEGY" ]; then
    if ln "$probe_src" "$probe_dst" 2>/dev/null; then
      rm -f "$probe_dst"
      STRATEGY="cp-al"
    fi
  fi

  # 3. reflink (btrfs/xfs/APFS)
  if [ -z "$STRATEGY" ]; then
    if [ "$(uname)" = "Darwin" ]; then
      if cp -c "$probe_src" "$probe_dst" 2>/dev/null; then
        rm -f "$probe_dst"
        STRATEGY="reflink"
      fi
    else
      if cp --reflink=always "$probe_src" "$probe_dst" 2>/dev/null; then
        rm -f "$probe_dst"
        STRATEGY="reflink"
      fi
    fi
  fi

  rm -f "$probe_dst" 2>/dev/null
  [ -z "$STRATEGY" ] && STRATEGY="cp"
fi

# ── link gems ────────────────────────────────────────────────────

link_cpio() {
  # Read .scint-files, prefix each line with gem name, pipe to cpio -pld.
  # One cpio call per gem (cpio needs a single source root).
  local gem="$1"
  local dotfiles="$SRC/$gem/.scint-files"
  if [ -f "$dotfiles" ]; then
    (cd "$SRC/$gem" && cpio -pld "$DST/$gem" < "$dotfiles" 2>/dev/null)
  else
    cp -al "$SRC/$gem" "$DST/$gem"
  fi
}

# For cp-al: batch all gems into one call
BATCH=()

flush_batch() {
  [ ${#BATCH[@]} -eq 0 ] && return
  case "$STRATEGY" in
    cp-al)
      cp -al "${BATCH[@]}" "$DST/" 2>/dev/null || {
        # Individual fallback on batch failure
        for s in "${BATCH[@]}"; do
          cp -al "$s" "$DST/" 2>/dev/null || cp -R "$s" "$DST/"
        done
      }
      ;;
    reflink)
      if [ "$(uname)" = "Darwin" ]; then
        cp -cR "${BATCH[@]}" "$DST/" 2>/dev/null || {
          for s in "${BATCH[@]}"; do cp -R "$s" "$DST/"; done
        }
      else
        cp --reflink=always -R "${BATCH[@]}" "$DST/" 2>/dev/null || {
          for s in "${BATCH[@]}"; do cp -R "$s" "$DST/"; done
        }
      fi
      ;;
    cp)
      cp -R "${BATCH[@]}" "$DST/"
      ;;
  esac
  BATCH=()
}

while IFS= read -r gem; do
  [ -z "$gem" ] && continue
  [ -d "$SRC/$gem" ] || continue
  [ -d "$DST/$gem" ] && continue

  case "$STRATEGY" in
    cpio)
      link_cpio "$gem"
      ;;
    *)
      BATCH+=("$SRC/$gem")
      # Flush in chunks to stay under ARG_MAX
      [ ${#BATCH[@]} -ge 200 ] && flush_batch
      ;;
  esac
done

flush_batch
