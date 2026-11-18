#!/bin/sh
# Every driver's real latest release, installed by its own script exactly as the one-liner runs it
# (piped into sh), then loaded by name through the ADBC driver manager (check_driver_by_name.py),
# then uninstalled. On one driver also: a pinned version, another driver's manifest backed up,
# replaced and restored, and --name side by side.
#
#   PYTHON=<python with adbc-driver-manager> .github/scripts/real-release.sh [<site dir or URL>]
#
# The scripts come from <site dir> (default: built from this checkout) or a URL such as
# https://install.adbc.gizmodata.com (to check the live site). Runs in a throwaway HOME.
#
# What each driver must do is decided from its latest release (read anonymously from github.com,
# without the installer), checked against what its releases had when this was written:
#   - no archive for this platform: the installer must say "has no build for <platform>"; but a
#     platform listed in builds_of() below must have one (its loss is a failure);
#   - no SHA256SUMS and no <archive>.sha256: the installer must refuse ("publishes no checksums").
#     gizmosql, chargewire and hardcharger's releases up to gizmosql 2.0.18, chargewire 2.4.0 and
#     hardcharger 2.6.0 have no checksums, so for them this check expects the refusal until their
#     first release with SHA256SUMS, and from then on expects (and checks) a real install. Their
#     releases adding SHA256SUMS are being shipped on 2026-11-18, which flips this automatically.
#     oracle, db2 and quack already publish checksums: a release of theirs without them fails.
#   - otherwise: install, load by name, uninstall.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE="${1:-}"
PY="${PYTHON:-python3}"
"$PY" -c 'import adbc_driver_manager' || { echo "::error::$PY has no adbc_driver_manager"; exit 1; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
if [ -z "$SOURCE" ]; then
  "$HERE/build-site.sh" "$ROOT/site" >/dev/null
  SOURCE="$ROOT/site"
fi
export HOME="$ROOT/home"
mkdir -p "$HOME"
unset ADBC_DRIVER ADBC_VERSION ADBC_DIR ADBC_SYSTEM ADBC_NAME ADBC_ARCHIVE ADBC_BASE_URL ADBC_UNINSTALL XDG_CONFIG_HOME ADBC_INSTALL_GITHUB ADBC_DRIVER_PATH 2>/dev/null || true
OUT="$ROOT/out"
failures=0

case "$(uname -s)" in Darwin) OS=macos; OSNAME=darwin ;; *) OS=linux; OSNAME=linux ;; esac
case "$(uname -m)" in x86_64|amd64) ARCH=amd64 ;; *) ARCH=arm64 ;; esac
PLATFORM="${OS}_$ARCH"
if [ "$OS" = macos ]; then D="$HOME/Library/Application Support/ADBC/Drivers"; else D="$HOME/.config/adbc/drivers"; fi
echo "platform: $PLATFORM; scripts from: $SOURCE; python: $("$PY" -c 'import adbc_driver_manager, sys; print(sys.version.split()[0], "adbc_driver_manager", adbc_driver_manager.__version__)')"

# The platforms each driver's releases have builds for (as of their latest releases, 2026-11-18).
builds_of() {
  case "$1" in
    oracle|quack) echo "linux_amd64 linux_arm64 macos_arm64 windows_amd64 windows_arm64" ;;
    db2) echo "linux_amd64 linux_arm64 macos_arm64 windows_amd64" ;;
    *) echo "linux_amd64 linux_arm64 macos_amd64 macos_arm64 windows_amd64 windows_arm64" ;;
  esac
}

repo_of() {
  case "$1" in
    oracle) echo adbc-driver-oracle ;; db2) echo adbc-driver-db2 ;; quack) echo adbc-driver-quack ;;
    gizmosql) echo gizmosql-adbc ;; chargewire) echo chargewire-adbc ;; hardcharger) echo hardcharger-adbc ;;
  esac
}
# github.com answers a release file that exists with a redirect to its storage, one that doesn't with 404.
exists() {
  code="$(curl -sS --retry 4 --retry-delay 3 -o /dev/null -w '%{http_code}' -I "$1" || true)"
  case "$code" in 302) return 0 ;; 404) return 1 ;; esac
  echo "::error::couldn't tell whether $1 exists (HTTP $code)"; exit 1
}
installer() {  # installer [NAME=value ...] -- [args...]: the driver's script, piped into sh
  envs=""
  while [ "$1" != "--" ]; do envs="$envs $1"; shift; done
  shift
  case "$SOURCE" in
    http://*|https://*) curl -sS --retry 3 "$SOURCE/$d" > "$ROOT/script" ;;
    *) cp "$SOURCE/$d" "$ROOT/script" ;;
  esac
  set +e
  # shellcheck disable=SC2086 # the NAME=value list is split on purpose
  env $envs sh -s -- "$@" < "$ROOT/script" > "$OUT" 2>&1
  code=$?
  set -e
  sed 's/^/  | /' "$OUT"
  return "$code"
}
bad() { echo "::error::$d: $*"; failures=$((failures + 1)); }
has() { grep -F -- "$1" "$OUT" >/dev/null; }
by_name() { "$PY" -I "$HERE/check_driver_by_name.py" --driver "$d" "$@"; }

for d in oracle db2 quack gizmosql chargewire hardcharger; do
  printf '\n### %s\n' "$d"
  repo="gizmodata/$(repo_of "$d")"
  latest="$(curl -sSIL --retry 4 --retry-delay 3 -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest")"
  case "$latest" in */releases/tag/v*) tag="${latest##*/}" ;; *) bad "no latest release ($latest)"; continue ;; esac
  ver="${tag#v}"
  case "$d" in oracle|db2|quack) asset="libadbc_driver_$d-$OSNAME-$ARCH.tar.gz" ;; *) asset="libadbc_driver_$d-$tag-$PLATFORM.tar.gz" ;; esac
  base="https://github.com/$repo/releases/download/$tag"
  case " $(builds_of "$d") " in *" $PLATFORM "*) listed=1 ;; *) listed="" ;; esac

  if ! exists "$base/$asset"; then
    [ -z "$listed" ] || { bad "$tag has no $asset, and $d has had $PLATFORM builds"; continue; }
    echo "$d $tag has no $PLATFORM build: the installer must say so"
    if installer -- ; then bad "the installer succeeded without a $PLATFORM build"; continue; fi
    has "$ver has no build for $PLATFORM" || bad "refused, but not with 'has no build for $PLATFORM'"
    continue
  fi
  [ -n "$listed" ] || echo "note: $d $tag now has a $PLATFORM build; add it to builds_of()"

  if ! exists "$base/SHA256SUMS" && ! exists "$base/$asset.sha256"; then
    case "$d" in
      gizmosql|chargewire|hardcharger) ;;
      *) bad "$tag publishes no checksums; $d's releases have had them"; continue ;;
    esac
    # Expected until the driver's first release with SHA256SUMS (see the comment at the top).
    echo "$d $tag has no checksums yet: the installer must refuse it"
    if installer -- ; then bad "the installer installed $tag without checksums"; continue; fi
    has "publishes no checksums (neither SHA256SUMS nor $asset.sha256 is in the release), and this installer never installs files it cannot verify" \
      || bad "refused, but not for the missing checksums"
    [ ! -e "$D/$d.toml" ] || bad "a manifest was written anyway"
    by_name --absent || bad "'$d' loads although nothing was installed"
    continue
  fi

  echo "$d $tag: install, load by name, uninstall"
  by_name --absent || bad "'$d' was found before installing"
  if ! installer -- ; then bad "the installer failed"; continue; fi
  has "Checksum OK (" || bad "no checksum line"
  has "  library:  $D/$d/$ver/libadbc_driver_$d." || bad "no library line"
  has "  manifest: $D/$d.toml" || bad "no manifest line"
  has "  driver = \"$d\"" || bad "no driver line"
  "$PY" -I "$HERE/check_manifest.py" --manifest "$D/$d.toml" --driver "$d" --version "$ver" --platform "$PLATFORM" || bad "manifest"
  by_name || bad "'$d' does not load by name"

  if [ "$d" = oracle ]; then
    echo "-- oracle: pinned ADBC_VERSION=$ver"
    installer ADBC_VERSION="$ver" -- || bad "pinned install failed"
    by_name || bad "'$d' does not load after the pinned install"

    echo "-- oracle: another driver's oracle.toml is backed up, replaced, and restored"
    printf "manifest_version = 1\nname = 'Another Oracle driver'\nurl = 'https://example.com/another-oracle-driver'\n[Driver]\nshared = '/nonexistent/libanother.so'\n" > "$ROOT/foreign.toml"
    cp "$ROOT/foreign.toml" "$D/oracle.toml"
    installer -- || bad "install over another driver's manifest failed"
    by_name || bad "'oracle' does not load after replacing another driver's manifest"
    restore="$(sed -n 's/.*note: to go back to it: //p' "$OUT")"
    [ -n "$restore" ] || bad "no restore command printed"
    if ! sh -c "$restore" || ! cmp -s "$D/oracle.toml" "$ROOT/foreign.toml"; then bad "the restore command didn't restore the other manifest"; fi

    echo "-- oracle: --name oracle-gizmodata side by side with it"
    installer -- --name oracle-gizmodata || bad "--name install failed"
    cmp -s "$D/oracle.toml" "$ROOT/foreign.toml" || bad "--name touched the other driver's manifest"
    by_name --name oracle-gizmodata || bad "'oracle-gizmodata' does not load the Oracle driver"
    installer ADBC_NAME=oracle-gizmodata -- --uninstall || bad "--name uninstall failed"
    by_name --name oracle-gizmodata --absent || bad "'oracle-gizmodata' still loads after uninstall"
    rm -f "$D/oracle.toml"
    installer -- || bad "reinstall failed"
  fi

  installer -- --uninstall || bad "uninstall failed"
  by_name --absent || bad "'$d' still loads after uninstall"
  [ ! -e "$D/$d" ] || bad "$D/$d is still there"
done

echo
if [ "$failures" != 0 ]; then echo "$failures real-release check(s) failed"; exit 1; fi
echo "all real-release checks passed ($PLATFORM)"
