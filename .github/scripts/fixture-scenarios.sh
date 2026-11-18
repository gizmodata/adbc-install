#!/bin/sh
# install.sh, and the per-driver scripts the deploy builds from it, end to end against fixture
# releases served by a local stand-in for github.com (fake_github.py). No credentials and no real
# release are needed; nothing here may reach github.com (a step that names no fake server gets a
# dead one). The stand-in libraries are a few bytes with a real ELF or Mach-O header, so the
# installer's architecture check sees a real machine type.
#
# Covered: the generic script (no driver: the list and exit 1; a driver by argument or
# ADBC_DRIVER; an unknown one), every driver's per-driver script (latest), pinned versions by
# ADBC_VERSION and --version, SHA256SUMS (good, mismatch, no line for the archive, "./" names),
# <archive>.sha256, a release with no checksums at all, an archive for another machine, a release
# with no build for this platform, a version never released, another driver's manifest backed up
# and replaced (and the printed restore command run), --name side by side, uninstall (ours, and
# with another driver's manifest left alone), paths with spaces and quotes, --archive, --base-url,
# --system without root, XDG_CONFIG_HOME, wget without curl, and a dead github.com.
#
#   .github/scripts/fixture-scenarios.sh            (SH picks the shell the installer runs under)
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SH="${SH:-sh}"
PY="$(command -v python3 || command -v python)"

ROOT="$(mktemp -d)"
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done; rm -rf "$ROOT"; }
trap cleanup EXIT
SITE="$ROOT/site"
"$HERE/build-site.sh" "$SITE" >/dev/null
export HOME="$ROOT/home dir"
mkdir -p "$HOME"
OUT="$ROOT/out"
unset ADBC_DRIVER ADBC_VERSION ADBC_DIR ADBC_SYSTEM ADBC_NAME ADBC_ARCHIVE ADBC_BASE_URL ADBC_UNINSTALL XDG_CONFIG_HOME 2>/dev/null || true
DEAD=http://127.0.0.1:9
export ADBC_INSTALL_GITHUB="$DEAD"

step() { printf '\n### %s\n' "$*"; }
fail() { echo "::error::$*"; [ -f "$OUT" ] && sed 's/^/  | /' "$OUT"; exit 1; }
# run <0|nonzero> [NAME=value ...] -- <script> [args...]: pipes the script into $SH as curl | sh does.
# The NAME=value list is split on spaces: a value with spaces is passed by calling env directly.
run() {
  want="$1"; shift
  envs=""
  while [ "$1" != "--" ]; do envs="$envs $1"; shift; done
  shift
  script="$1"; shift
  set +e
  # shellcheck disable=SC2086 # word splitting of the NAME=value list is intended
  env $envs "$SH" -s -- "$@" < "$script" > "$OUT" 2>&1
  code=$?
  set -e
  sed 's/^/  | /' "$OUT"
  if [ "$want" = 0 ] && [ "$code" != 0 ]; then fail "installer exited $code, expected success"; fi
  if [ "$want" = nonzero ] && [ "$code" = 0 ]; then fail "installer succeeded, expected a failure"; fi
}
expect()     { grep -F -- "$1" "$OUT" >/dev/null || fail "expected output to contain: $1"; }
expect_not() { if grep -F -- "$1" "$OUT" >/dev/null; then fail "expected output NOT to contain: $1"; fi; }
sum() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
same() { cmp -s "$1" "$2" || fail "$1 changed"; }

case "$(uname -s)" in Darwin) OS=macos; OSNAME=darwin; EXT=dylib ;; *) OS=linux; OSNAME=linux; EXT=so ;; esac
case "$(uname -m)" in x86_64|amd64) ARCH=amd64; OTHER=arm64 ;; *) ARCH=arm64; OTHER=amd64 ;; esac
if [ "$OS" = macos ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" = 1 ]; then ARCH=arm64; OTHER=amd64; fi
PLATFORM="${OS}_$ARCH"
if [ "$OS" = macos ]; then D="$HOME/Library/Application Support/ADBC/Drivers"; else D="$HOME/.config/adbc/drivers"; fi
echo "platform: $PLATFORM; shell: $SH; drivers dir: $D"
manifest_ok() {  # manifest_ok <manifest> <driver> <version> [lib dir]
  "$PY" "$HERE/check_manifest.py" --manifest "$1" --driver "$2" --version "$3" --platform "$PLATFORM" ${4:+--lib-dir "$4"} \
    || fail "the manifest $1 is not right"
}

# ---- fixtures -----------------------------------------------------------------------------------
F="$ROOT/fixtures/gizmodata"
repo_of() {
  case "$1" in
    oracle) echo adbc-driver-oracle ;; db2) echo adbc-driver-db2 ;; quack) echo adbc-driver-quack ;;
    gizmosql) echo gizmosql-adbc ;; chargewire) echo chargewire-adbc ;; hardcharger) echo hardcharger-adbc ;;
  esac
}
by_os() { case "$1" in oracle|db2|quack) return 0 ;; *) return 1 ;; esac; }
asset_of() {  # asset_of <driver> <version>
  if by_os "$1"; then echo "libadbc_driver_$1-$OSNAME-$ARCH.tar.gz"; else echo "libadbc_driver_$1-v$2-$PLATFORM.tar.gz"; fi
}
fake_lib() {  # fake_lib <arch> <file>: a few bytes with this OS's library header for <arch>
  if [ "$OS" = linux ]; then
    if [ "$1" = amd64 ]; then m='\076\000'; else m='\267\000'; fi
    # shellcheck disable=SC2059 # the octal escapes are the format
    printf "\\177ELF\\002\\001\\001\\000\\000\\000\\000\\000\\000\\000\\000\\000\\003\\000$m\\001\\000\\000\\000" > "$2"
  else
    if [ "$1" = amd64 ]; then m='\007'; else m='\014'; fi
    # shellcheck disable=SC2059
    printf "\\317\\372\\355\\376$m\\000\\000\\001\\000\\000\\000\\000\\006\\000\\000\\000" > "$2"
  fi
  printf 'fixture library\n' >> "$2"
}
# release <driver> <version> [sums: both|sums|sha256|none|noline|mismatch] [arch of the library]
release() {
  d="$1"; v="$2"; sums="${3:-both}"; libarch="${4:-$ARCH}"
  dir="$F/$(repo_of "$d")/v$v"
  asset="$(asset_of "$d" "$v")"
  b="$ROOT/build/$d-$v"
  rm -rf "$b"; mkdir -p "$b"
  # Layouts as the real releases have them: oracle and db2 flat, the others in a folder.
  case "$d" in oracle|db2) pkg="$b" ;; *) pkg="$b/${asset%.tar.gz}"; mkdir -p "$pkg" ;; esac
  fake_lib "$libarch" "$pkg/libadbc_driver_$d.$EXT"
  echo "license of $d $v" > "$pkg/LICENSE"
  mkdir -p "$dir"
  (cd "$b" && tar -czf "$dir/$asset" -- *)
  # Another platform's asset sits next to it, as in a real release.
  if by_os "$d"; then o="libadbc_driver_$d-windows-amd64.tar.gz"; else o="libadbc_driver_$d-v$v-windows_amd64.tar.gz"; fi
  echo "not this platform" > "$dir/$o"
  h="$(sum "$dir/$asset")"
  # quack's real SHA256SUMS names files "./<name>".
  if [ "$d" = quack ]; then n="./$asset"; else n="$asset"; fi
  case "$sums" in
    both)     printf '%s  %s\n%s  %s\n' "$(sum "$dir/$o")" "$o" "$h" "$n" > "$dir/SHA256SUMS"
              if by_os "$d"; then printf '%s  %s\n' "$h" "$asset" > "$dir/$asset.sha256"; fi ;;
    sums)     printf '%s  %s\n' "$h" "$n" > "$dir/SHA256SUMS" ;;
    sha256)   printf '%s  %s\n' "$h" "$asset" > "$dir/$asset.sha256" ;;
    none)     ;;
    noline)   printf '%s  %s\n' "$(sum "$dir/$o")" "$o" > "$dir/SHA256SUMS" ;;
    mismatch) printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "$n" > "$dir/SHA256SUMS" ;;
  esac
}
for d in oracle db2 quack gizmosql chargewire hardcharger; do
  release "$d" 9.9.8
  release "$d" 9.9.9
done
release oracle 9.9.7 mismatch
release oracle 9.9.6 sha256
release oracle 9.9.5 none
release oracle 9.9.4 noline
release oracle 9.9.3 both "$OTHER"
mkdir -p "$F/adbc-driver-oracle/v9.9.2" && echo other > "$F/adbc-driver-oracle/v9.9.2/libadbc_driver_oracle-windows-amd64.tar.gz"
release chargewire 9.9.5 none
release chargewire 9.9.7 mismatch
release gizmosql 9.9.6 sums

"$PY" "$HERE/fake_github.py" --root "$ROOT/fixtures" --port-file "$ROOT/port" --log "$ROOT/requests.log" 2>"$ROOT/server.err" &
PIDS="$PIDS $!"
i=0
until [ -s "$ROOT/port" ]; do
  i=$((i + 1))
  if [ "$i" -ge 300 ]; then cat "$ROOT/server.err" >&2; fail "fake github.com didn't start ($PY)"; fi
  sleep 0.1
done
URL="http://127.0.0.1:$(cat "$ROOT/port")"
GH="ADBC_INSTALL_GITHUB=$URL"

# ---- the generic script ---------------------------------------------------------------------------
step "1. The generic script with no driver: the list and usage, exit 1"
run nonzero -- "$SITE/install.sh"
expect "no driver chosen: pick one of: oracle db2 quack gizmosql chargewire hardcharger"
for d in oracle db2 quack gizmosql chargewire hardcharger; do expect "https://github.com/gizmodata/$(repo_of "$d")"; done
expect "curl https://install.adbc.gizmodata.com/<driver> | sh"

step "1a. --help exits 0; an unknown driver and an unknown option are refused"
run 0 -- "$SITE/install.sh" --help
expect "ADBC_VERSION"
run nonzero -- "$SITE/install.sh" mysql
expect "unknown driver 'mysql': pick one of: oracle db2 quack gizmosql chargewire hardcharger"
run nonzero -- "$SITE/oracle" --frobnicate
expect "unknown option: --frobnicate"
run nonzero -- "$SITE/oracle" db2
expect "unexpected argument: db2 (this is the oracle installer"

step "1b. The generic script takes the driver as an argument or ADBC_DRIVER"
# shellcheck disable=SC2086
run 0 $GH -- "$SITE/install.sh" db2
expect "Installed the Db2 ADBC driver 9.9.9"
manifest_ok "$D/db2.toml" db2 9.9.9
# shellcheck disable=SC2086
run 0 $GH ADBC_DRIVER=quack -- "$SITE/install.sh"
expect "Installed the Quack ADBC driver 9.9.9"
manifest_ok "$D/quack.toml" quack 9.9.9

# ---- every driver's own script ------------------------------------------------------------------
step "2. Every driver's script installs its latest release"
for d in oracle db2 quack gizmosql chargewire hardcharger; do
  # shellcheck disable=SC2086
  run 0 $GH -- "$SITE/$d"
  expect "Checksum OK (SHA256SUMS)"
  expect "  library:  $D/$d/9.9.9/libadbc_driver_$d.$EXT"
  expect "  manifest: $D/$d.toml"
  expect "  driver = \"$d\""
  manifest_ok "$D/$d.toml" "$d" 9.9.9
  [ -f "$D/$d/9.9.9/LICENSE" ] || fail "the release's LICENSE wasn't installed next to the library"
done
grep -q "^GET /gizmodata/adbc-driver-oracle/releases/latest$" "$ROOT/requests.log" || fail "latest wasn't looked up by the releases/latest redirect"

step "2a. The same version again replaces it cleanly"
# shellcheck disable=SC2086
run 0 $GH -- "$SITE/oracle"
manifest_ok "$D/oracle.toml" oracle 9.9.9
[ "$(ls "$D/oracle")" = 9.9.9 ] || fail "oracle/ holds more than 9.9.9: $(ls "$D/oracle")"

step "3. A pinned version: ADBC_VERSION=9.9.8, then --version v9.9.9; the old one is removed"
# shellcheck disable=SC2086
run 0 $GH ADBC_VERSION=9.9.8 -- "$SITE/oracle"
expect "Downloading the Oracle ADBC driver 9.9.8 for $PLATFORM"
manifest_ok "$D/oracle.toml" oracle 9.9.8
[ ! -e "$D/oracle/9.9.9" ] || fail "9.9.9 was left behind"
# shellcheck disable=SC2086
run 0 $GH -- "$SITE/oracle" --version v9.9.9
manifest_ok "$D/oracle.toml" oracle 9.9.9
# shellcheck disable=SC2086
run nonzero $GH ADBC_VERSION=1.2 -- "$SITE/oracle"
expect "ADBC_VERSION/--version must be X.Y.Z or vX.Y.Z (got '1.2')"

# ---- checksums and refusals: nothing may change --------------------------------------------------
cp "$D/oracle.toml" "$ROOT/oracle.toml.before"
unchanged() { same "$D/oracle.toml" "$ROOT/oracle.toml.before"; [ "$(ls "$D/oracle")" = 9.9.9 ] || fail "oracle/ changed: $(ls "$D/oracle")"; }

step "4. A checksum mismatch is refused"
# shellcheck disable=SC2086
run nonzero $GH ADBC_VERSION=9.9.7 -- "$SITE/oracle"
expect "checksum mismatch for $(asset_of oracle 9.9.7): SHA256SUMS says 0000000000000000000000000000000000000000000000000000000000000000"
unchanged
# shellcheck disable=SC2086
run nonzero $GH ADBC_VERSION=9.9.7 -- "$SITE/chargewire"
expect "checksum mismatch for $(asset_of chargewire 9.9.7)"
manifest_ok "$D/chargewire.toml" chargewire 9.9.9

step "5. No SHA256SUMS: <archive>.sha256 is used"
# shellcheck disable=SC2086
run 0 $GH ADBC_VERSION=9.9.6 -- "$SITE/oracle"
expect "Checksum OK ($(asset_of oracle 9.9.6).sha256)"
manifest_ok "$D/oracle.toml" oracle 9.9.6
# shellcheck disable=SC2086
run 0 $GH ADBC_VERSION=9.9.9 -- "$SITE/oracle"

step "6. A release with no checksums at all is refused (oracle by OS name, chargewire by tag)"
# shellcheck disable=SC2086
run nonzero $GH ADBC_VERSION=9.9.5 -- "$SITE/oracle"
expect "Oracle 9.9.5 publishes no checksums (neither SHA256SUMS nor $(asset_of oracle 9.9.5).sha256 is in the release), and this installer never installs files it cannot verify."
unchanged
# shellcheck disable=SC2086
run nonzero $GH ADBC_VERSION=9.9.5 -- "$SITE/chargewire"
expect "Chargewire 9.9.5 publishes no checksums"
manifest_ok "$D/chargewire.toml" chargewire 9.9.9

step "7. SHA256SUMS without a line for the archive is refused"
# shellcheck disable=SC2086
run nonzero $GH ADBC_VERSION=9.9.4 -- "$SITE/oracle"
expect "the release's SHA256SUMS has no line for $(asset_of oracle 9.9.4); not installing it"
unchanged

step "8. An archive whose library is for another machine is refused"
# shellcheck disable=SC2086
run nonzero $GH ADBC_VERSION=9.9.3 -- "$SITE/oracle"
expect "holds a ${OS}_$OTHER library, and this machine is $PLATFORM"
unchanged

step "9. A release with no build for this platform, and a version never released"
# shellcheck disable=SC2086
run nonzero $GH ADBC_VERSION=9.9.2 -- "$SITE/oracle"
expect "Oracle 9.9.2 has no build for $PLATFORM ($(asset_of oracle 9.9.2) is not in $URL/gizmodata/adbc-driver-oracle/releases/tag/v9.9.2)"
# shellcheck disable=SC2086
run nonzero $GH ADBC_VERSION=1.2.3 -- "$SITE/oracle"
expect "gizmodata/adbc-driver-oracle has no release v1.2.3 (releases: $URL/gizmodata/adbc-driver-oracle/releases)"
unchanged

step "9a. github.com not answering"
run nonzero -- "$SITE/oracle"
expect "could not find the latest Oracle release at $DEAD/gizmodata/adbc-driver-oracle/releases/latest"
unchanged

# ---- another driver's manifest, --name, uninstall ------------------------------------------------
FOREIGN="$ROOT/foreign.toml"
cat > "$FOREIGN" <<'EOF'
manifest_version = 1
name = 'Someone else'
url = 'https://example.com/another-oracle-driver'
[Driver.shared]
linux_amd64 = '/nonexistent/libadbc_driver_oracle.so'
EOF

step "10. Another driver's oracle.toml is backed up and replaced, and the printed command restores it"
# shellcheck disable=SC2086
run 0 $GH -- "$SITE/oracle" --uninstall
cp "$FOREIGN" "$D/oracle.toml"
# shellcheck disable=SC2086
run 0 $GH -- "$SITE/oracle"
expect "belonged to another driver (url https://example.com/another-oracle-driver); it is kept as $D/oracle.toml.replaced-"
manifest_ok "$D/oracle.toml" oracle 9.9.9
set -- "$D"/oracle.toml.replaced-*
[ $# = 1 ] && [ -f "$1" ] || fail "expected one backup, found: $*"
same "$1" "$FOREIGN"
restore="$(sed -n 's/.*note: to go back to it: //p' "$OUT")"
[ -n "$restore" ] || fail "no restore command printed"
echo "  restore: $restore"
sh -c "$restore"
same "$D/oracle.toml" "$FOREIGN"

step "10a. Replaced twice in the same second: both backups are kept"
# shellcheck disable=SC2086
run 0 $GH -- "$SITE/oracle"
cp "$FOREIGN" "$D/oracle.toml"
# shellcheck disable=SC2086
run 0 $GH -- "$SITE/oracle"
[ "$(find "$D" -name 'oracle.toml.replaced-*' | wc -l | tr -d ' ')" -ge 2 ] || fail "a backup was overwritten"
rm -f "$D"/oracle.toml.replaced-*

step "11. --name installs side by side and leaves the other driver's manifest alone"
cp "$FOREIGN" "$D/oracle.toml"
# shellcheck disable=SC2086
run 0 $GH -- "$SITE/oracle" --name oracle-gizmodata
expect "  driver = \"oracle-gizmodata\""
expect_not "belonged to another driver"
same "$D/oracle.toml" "$FOREIGN"
manifest_ok "$D/oracle-gizmodata.toml" oracle 9.9.9
# shellcheck disable=SC2086
run 0 $GH ADBC_NAME=oracle-gizmodata ADBC_UNINSTALL=1 -- "$SITE/oracle"
[ ! -e "$D/oracle-gizmodata.toml" ] && [ ! -e "$D/oracle-gizmodata" ] || fail "--name uninstall left files"
same "$D/oracle.toml" "$FOREIGN"
run nonzero -- "$SITE/oracle" --name ../x
expect "--name must be letters, digits"

step "12. Uninstall leaves another driver's manifest alone"
# shellcheck disable=SC2086
run 0 -- "$SITE/oracle" --uninstall
expect "belongs to another driver (its url is not https://github.com/gizmodata/adbc-driver-oracle); left as it is"
same "$D/oracle.toml" "$FOREIGN"
rm "$D/oracle.toml"

step "13. Uninstall removes our manifest and libraries, then has nothing to do"
run 0 -- "$SITE/db2" --uninstall
expect "Removed $D/db2.toml"
expect "Removed $D/db2"
[ ! -e "$D/db2.toml" ] && [ ! -e "$D/db2" ] || fail "db2 is still there"
run 0 -- "$SITE/db2" --uninstall
expect "Nothing to remove: no Db2 driver named 'db2'"
for d in quack gizmosql chargewire hardcharger; do run 0 -- "$SITE/$d" --uninstall; done
[ -z "$(ls -A "$D")" ] || fail "the drivers directory isn't empty after every uninstall: $(ls -A "$D")"

# ---- paths, local archives, mirrors, system, XDG, wget -------------------------------------------
step "14. A drivers directory with spaces and both quote characters"
Q="$ROOT/we'ird \"dir\" with spaces"
# By ADBC_DIR (run() splits its NAME=value list on spaces, so this one is called directly).
env "ADBC_DIR=$Q" "$GH" "$SH" -s < "$SITE/oracle" > "$OUT" 2>&1 || fail "ADBC_DIR with quotes and spaces failed"
sed 's/^/  | /' "$OUT"
manifest_ok "$Q/oracle.toml" oracle 9.9.9
expect "only when it is on ADBC_DRIVER_PATH"
cp "$FOREIGN" "$Q/oracle.toml"
# shellcheck disable=SC2086
run 0 $GH -- "$SITE/oracle" --dir "$Q"
restore="$(sed -n 's/.*note: to go back to it: //p' "$OUT")"
sh -c "$restore"
same "$Q/oracle.toml" "$FOREIGN"
run 0 -- "$SITE/oracle" --dir "$Q" --uninstall
[ ! -e "$Q/oracle" ] || fail "uninstall in a quoted directory left the libraries"

step "15. --archive installs a local file and fetches nothing"
A="$ROOT/archives dir"
mkdir -p "$A"
cp "$F/chargewire-adbc/v9.9.8/$(asset_of chargewire 9.9.8)" "$A/"
cp "$F/adbc-driver-oracle/v9.9.8/$(asset_of oracle 9.9.8)" "$A/"
before="$(wc -l < "$ROOT/requests.log")"
run 0 -- "$SITE/chargewire" --archive "$A/$(asset_of chargewire 9.9.8)"
expect "Installing the Chargewire ADBC driver 9.9.8 for $PLATFORM from $A/"
manifest_ok "$D/chargewire.toml" chargewire 9.9.8
run nonzero -- "$SITE/oracle" --archive "$A/$(asset_of oracle 9.9.8)"
expect "can't tell the version of $(asset_of oracle 9.9.8) from its name; pass ADBC_VERSION=X.Y.Z with ADBC_ARCHIVE"
env ADBC_VERSION=9.9.8 "ADBC_ARCHIVE=$A/$(asset_of oracle 9.9.8)" "$SH" -s < "$SITE/oracle" > "$OUT" 2>&1 || fail "ADBC_ARCHIVE failed"
sed 's/^/  | /' "$OUT"
manifest_ok "$D/oracle.toml" oracle 9.9.8
[ "$(wc -l < "$ROOT/requests.log")" = "$before" ] || fail "--archive made requests"
run nonzero -- "$SITE/oracle" --archive "$A/nothing.tar.gz"
expect "no such archive: $A/nothing.tar.gz"

step "16. --base-url: a mirror of the release files"
# shellcheck disable=SC2086
run 0 ADBC_VERSION=9.9.8 -- "$SITE/gizmosql" --base-url "$URL/storage/gizmodata/gizmosql-adbc/v9.9.8/"
expect "Checksum OK (SHA256SUMS)"
manifest_ok "$D/gizmosql.toml" gizmosql 9.9.8
run nonzero ADBC_VERSION=9.9.8 -- "$SITE/gizmosql" --base-url "$URL/storage/gizmodata/gizmosql-adbc/v9.9.1"
expect "could not download $URL/storage/gizmodata/gizmosql-adbc/v9.9.1/$(asset_of gizmosql 9.9.8) (HTTP 404)"

step "17. --system without root says to use sudo"
if [ "$(id -u)" = 0 ]; then
  echo "  (running as root: skipped)"
elif [ -w /etc ] || [ -w "/Library/Application Support" ]; then
  echo "  (the system directory is writable here: skipped)"
else
  # shellcheck disable=SC2086
  run nonzero $GH -- "$SITE/oracle" --system
  expect "sudo sh -s -- --system"
fi
run nonzero ADBC_SYSTEM=maybe -- "$SITE/oracle"
expect "ADBC_SYSTEM must be 1 or 0 (got 'maybe')"

if [ "$OS" = linux ]; then
  step "18. Linux: XDG_CONFIG_HOME decides the drivers directory"
  # shellcheck disable=SC2086
  run 0 $GH XDG_CONFIG_HOME="$ROOT/xdg" -- "$SITE/hardcharger"
  manifest_ok "$ROOT/xdg/adbc/drivers/hardcharger.toml" hardcharger 9.9.9

  if command -v wget >/dev/null 2>&1; then
    step "19. wget when there is no curl"
    NOCURL="$ROOT/nocurl"
    mkdir -p "$NOCURL"
    for dir in /usr/local/bin /usr/bin /bin; do
      for f in "$dir"/*; do
        b="$(basename "$f")"
        [ "$b" = curl ] || [ -e "$NOCURL/$b" ] || ln -s "$f" "$NOCURL/$b"
      done
    done
    # shellcheck disable=SC2086
    run 0 PATH="$NOCURL" $GH -- "$SITE/quack"
    expect "Checksum OK (SHA256SUMS)"
    manifest_ok "$D/quack.toml" quack 9.9.9
    # shellcheck disable=SC2086
    run nonzero PATH="$NOCURL" $GH ADBC_VERSION=9.9.5 -- "$SITE/oracle"
    expect "Oracle 9.9.5 publishes no checksums"
    # shellcheck disable=SC2086
    run nonzero PATH="$NOCURL" $GH ADBC_VERSION=1.2.3 -- "$SITE/oracle"
    expect "has no release v1.2.3"
  else
    echo "  (no wget here: the wget path is tested on the Linux runners)"
  fi
fi

echo
echo "all fixture scenarios passed ($SH, $PLATFORM)"
