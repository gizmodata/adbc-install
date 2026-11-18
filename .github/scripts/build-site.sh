#!/bin/sh
# Builds the files served at https://install.adbc.gizmodata.com into <out dir>:
#
#   install.sh, install.ps1     the generic scripts (install.sh is the default root object, /)
#   <driver>, <driver>.ps1      the same scripts with the driver preset, one pair per driver
#
# The per-driver files differ from the generic ones in one line each (ADBC_INSTALL_PRESET="" and
# $AdbcInstallPreset = ''), so install.sh and install.ps1 stay the one source of truth. The driver
# list is install.sh's DRIVERS line, and install.ps1's must match it.
#
#   .github/scripts/build-site.sh site
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?usage: build-site.sh <out dir>}"
mkdir -p "$OUT"

drivers="$(sed -n 's/^DRIVERS="\(.*\)"$/\1/p' "$ROOT/install.sh")"
[ -n "$drivers" ] || { echo "build-site: no DRIVERS line in install.sh" >&2; exit 1; }
ps_drivers="$(sed -n "s/^\$Drivers = @(\(.*\))\$/\1/p" "$ROOT/install.ps1" | tr -d "' " | tr ',' ' ')"
if [ "$ps_drivers" != "$drivers" ]; then
  echo "build-site: install.ps1's drivers ($ps_drivers) differ from install.sh's ($drivers)" >&2
  exit 1
fi
for f in install.sh install.ps1; do
  # shellcheck disable=SC2016 # a literal $AdbcInstallPreset
  n="$(grep -c -e '^ADBC_INSTALL_PRESET=""$' -e '^\$AdbcInstallPreset = '"''"'$' "$ROOT/$f" || true)"
  [ "$n" = 1 ] || { echo "build-site: $f must have exactly one preset line (found $n)" >&2; exit 1; }
done

cp "$ROOT/install.sh" "$OUT/install.sh"
cp "$ROOT/install.ps1" "$OUT/install.ps1"
for d in $drivers; do
  sed "s/^ADBC_INSTALL_PRESET=\"\"\$/ADBC_INSTALL_PRESET=\"$d\"/" "$ROOT/install.sh" > "$OUT/$d"
  sed "s/^\$AdbcInstallPreset = ''\$/\$AdbcInstallPreset = '$d'/" "$ROOT/install.ps1" > "$OUT/$d.ps1"
  # Exactly one line may differ, and it must be the preset.
  for pair in "install.sh:$d" "install.ps1:$d.ps1"; do
    src="${pair%%:*}"; dst="${pair#*:}"
    changed="$(diff "$ROOT/$src" "$OUT/$dst" | grep -c '^>' || true)"
    [ "$changed" = 1 ] || { echo "build-site: $dst differs from $src in $changed lines, not 1" >&2; exit 1; }
    grep -q -e "^ADBC_INSTALL_PRESET=\"$d\"\$" -e "^\$AdbcInstallPreset = '$d'\$" "$OUT/$dst" \
      || { echo "build-site: $dst has no preset for $d" >&2; exit 1; }
  done
done
echo "built $(echo "$drivers" | wc -w | tr -d ' ') drivers into $OUT: install.sh install.ps1 $(for d in $drivers; do printf '%s %s.ps1 ' "$d" "$d"; done)"
