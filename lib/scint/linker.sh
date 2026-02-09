#!/bin/bash
# scint-linker — bulk-copy cached gems into a bundle using the fastest
# available filesystem primitive.
#
# Protocol (stdin):
#   Line 1: source parent dir  (e.g. ~/.cache/scint/cached/ruby-3.4.7-x86_64-linux)
#   Line 2: dest parent dir    (e.g. .bundle/ruby/3.4.0/gems)
#   Remaining lines: gem directory basenames (e.g. "rack-3.2.4")

set -euo pipefail

read -r SRC
read -r DST
mkdir -p "$DST"

# Collect all source dirs, skipping gems that already exist in DST
SOURCES=()
while IFS= read -r gem; do
  [ -z "$gem" ] && continue
  [ -d "$SRC/$gem" ] || continue
  [ -d "$DST/$gem" ] && continue
  SOURCES+=("$SRC/$gem")
done

[ ${#SOURCES[@]} -eq 0 ] && exit 0

# Single batch copy — let the OS handle the rest.
# On macOS/APFS, cp -cR uses clonefile (CoW, near-instant for metadata).
# On Linux, cp --reflink=auto -R tries reflink, falls back to copy.
if [ "$(uname)" = "Darwin" ]; then
  cp -cR "${SOURCES[@]}" "$DST/" 2>/dev/null || cp -R "${SOURCES[@]}" "$DST/"
else
  cp --reflink=auto -R "${SOURCES[@]}" "$DST/" 2>/dev/null || cp -R "${SOURCES[@]}" "$DST/"
fi
