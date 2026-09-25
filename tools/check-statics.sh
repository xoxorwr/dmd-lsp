#!/bin/sh
# Every mutable function-local static of the vendored dmd must be snapshotted
# by a memory level (src/dmdglobals.d `locals`), since reflection cannot see
# them. Lists the binary's dmd function-local data symbols and fails on any
# that is neither listed nor explicitly exempt. Linux (readelf) only.
set -e
command -v ddemangle >/dev/null || { echo "check-statics: needs ddemangle (D tools)" >&2; exit 2; }
BIN=${1:-./dmd-lsp}
LIST=${LIST:-src/dmdglobals.d}
EXEMPT='printDiagnostic.*old_loc'
missing=0
for sym in $(readelf -sW "$BIN" | awk '($4=="OBJECT"||$4=="TLS") && $8 ~ /^_D3dmd/ {print $8}' | sort -u); do
  d=$(echo "$sym" | ddemangle 2>/dev/null || echo "$sym")
  case "$d" in immutable*|const*|*__init*|*__vtbl*|*__Class*|*__ModuleInfo*|*TypeInfo*) continue;; esac
  # function-local: the owning scope ends in a parameter list
  echo "$d" | grep -q ')\.[A-Za-z_0-9]*$' || continue
  echo "$d" | grep -Eq "$EXEMPT" && continue
  if ! grep -q "\"$sym\"" "$LIST"; then
    echo "not snapshotted: $d"
    echo "  add [\"$sym\", \"<size>\"] to src/dmdglobals.d"
    missing=1
  fi
done
[ $missing -eq 0 ] && echo "function-local statics: all snapshotted"
exit $missing
