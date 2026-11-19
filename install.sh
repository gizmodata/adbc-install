#!/bin/sh
# GizmoData ADBC driver installer for macOS and Linux.
#
#   curl https://install.adbc.gizmodata.com/oracle | sh                     # the latest Oracle driver
#   curl https://install.adbc.gizmodata.com/oracle | ADBC_VERSION=1.0.6 sh  # a given version
#   curl https://install.adbc.gizmodata.com | sh -s -- oracle               # the same, by name
#
# Installs one of GizmoData's ADBC drivers (hardcharger, chargewire, gizmosql, oracle, db2, quack)
# from its GitHub release for every ADBC driver manager on this machine (C/C++, Go, Python, R,
# Rust, ...), so that `driver = "<name>"` loads it:
#
#   <drivers dir>/<name>/<version>/   the release's library (and its LICENSE/NOTICE files)
#   <drivers dir>/<name>.toml         the driver manifest: the library's absolute path and entrypoint
#
# <drivers dir> is the per-user directory the ADBC driver manager searches:
#   Linux: $XDG_CONFIG_HOME/adbc/drivers (default ~/.config/adbc/drivers)
#   macOS: ~/Library/Application Support/ADBC/Drivers
#
# The archive is checked against the release's SHA256SUMS (or <archive>.sha256) before anything
# is installed; a release with neither, or a mismatch, is refused. Another driver's <name>.toml
# (one whose url is not ours) is moved aside to <name>.toml.replaced-<UTC time> first, and the
# installer prints the command that puts it back; --name installs side by side instead.
#
# Options (environment variable, or `sh -s -- <options>` when piping):
#   --version <v>     ADBC_VERSION    a release, X.Y.Z or vX.Y.Z (default: the latest)
#   --dir <dir>       ADBC_DIR        drivers directory (default: the per-user one above)
#   --system          ADBC_SYSTEM=1   the system-wide one: /etc/adbc/drivers,
#                                     /Library/Application Support/ADBC/Drivers (needs sudo)
#   --name <name>     ADBC_NAME       install under another manifest name (side by side)
#   --archive <file>  ADBC_ARCHIVE    install this local release archive; nothing is downloaded
#   --base-url <url>  ADBC_BASE_URL   where the release files are (a mirror of
#                                     https://github.com/<repo>/releases/download/<tag>)
#   --uninstall       ADBC_UNINSTALL=1  remove the manifest and <drivers dir>/<name>/
#   <driver>          ADBC_DRIVER     which driver (only in the generic script, served at /)
#   --help
#
# Source: https://github.com/gizmodata/adbc-install

set -eu

# The deploy sets this to one driver for https://install.adbc.gizmodata.com/<driver>; empty here.
ADBC_INSTALL_PRESET=""

INSTALL_URL="https://install.adbc.gizmodata.com"
DRIVERS="hardcharger chargewire gizmosql oracle db2 quack"
# For tests only: another github.com (fake_github.py). Plain http is allowed only then.
GH="${ADBC_INSTALL_GITHUB:-https://github.com}"
GH="${GH%/}"

# ---- output -------------------------------------------------------------------------------------
if [ -t 2 ]; then
  B="$(printf '\033[1m')"; G="$(printf '\033[32m')"; R="$(printf '\033[31m')"
  Y="$(printf '\033[33m')"; N="$(printf '\033[0m')"
else
  B=""; G=""; R=""; Y=""; N=""
fi
info()  { printf '%s==>%s %s\n' "${G}${B}" "$N" "$*"; }
note()  { printf '%snote:%s %s\n' "${Y}${B}" "$N" "$*" >&2; }
fatal() { printf '%serror:%s %s\n' "${R}${B}" "$N" "$*" >&2; exit 1; }

# The driver table. Read from each driver's releases and manifest code (python/*/_manifest.py,
# packaging/*.toml.in): repository, entrypoint, the manifest's name and license, and how the
# release names its archives:
#   by_os:   libadbc_driver_<d>-<darwin|linux|windows>-<amd64|arm64>.tar.gz   (+ <archive>.sha256)
#   by_tag:  libadbc_driver_<d>-v<version>-<macos|linux|windows>_<amd64|arm64>.tar.gz
driver_info() {
  case "$1" in
    hardcharger) REPO=gizmodata/hardcharger-adbc;   ENTRY=AdbcDriverHardchargerInit; TITLE="Hardcharger"; MNAME="Hardcharger";             LICENSE=Apache-2.0; NAMING=by_tag; ABOUT="Hardcharger" ;;
    chargewire)  REPO=gizmodata/chargewire-adbc;    ENTRY=AdbcDriverChargewireInit;  TITLE="Chargewire";  MNAME="Chargewire";              LICENSE=Apache-2.0; NAMING=by_tag; ABOUT="any Chargewire server" ;;
    gizmosql)    REPO=gizmodata/gizmosql-adbc;      ENTRY=AdbcDriverInit;            TITLE="GizmoSQL";    MNAME="GizmoSQL";                LICENSE=Apache-2.0; NAMING=by_tag; ABOUT="GizmoSQL (Arrow Flight SQL)" ;;
    oracle)      REPO=gizmodata/adbc-driver-oracle; ENTRY=AdbcDriverOracleInit;      TITLE="Oracle";      MNAME="ADBC Oracle Driver - Go"; LICENSE=MIT;        NAMING=by_os;  ABOUT="Oracle Database, pure Go (no Oracle Client libraries)" ;;
    db2)         REPO=gizmodata/adbc-driver-db2;    ENTRY=AdbcDriverDb2Init;         TITLE="Db2";         MNAME="ADBC Db2 Driver - Go";    LICENSE=MIT;        NAMING=by_os;  ABOUT="IBM Db2, pure Go (no IBM CLI libraries)" ;;
    quack)       REPO=gizmodata/adbc-driver-quack;  ENTRY=AdbcDriverQuackInit;       TITLE="Quack";       MNAME="ADBC Quack Driver - Go";  LICENSE=MIT;        NAMING=by_os;  ABOUT="DuckDB's Quack remote protocol" ;;
    *) return 1 ;;
  esac
  LIB="libadbc_driver_$1"
}

usage() {
  if [ -n "$ADBC_INSTALL_PRESET" ]; then
    u="$INSTALL_URL/$ADBC_INSTALL_PRESET"
    cat <<EOF
GizmoData ADBC driver installer: $ADBC_INSTALL_PRESET (macOS and Linux)

  curl $u | sh                         # the latest release
  curl $u | ADBC_VERSION=X.Y.Z sh      # a given release
  curl $u | sh -s -- --uninstall       # remove it

EOF
  else
    cat <<EOF
GizmoData ADBC driver installer (macOS and Linux)

  curl $INSTALL_URL/<driver> | sh                      # the latest release of <driver>
  curl $INSTALL_URL/<driver> | ADBC_VERSION=X.Y.Z sh   # a given release
  curl $INSTALL_URL | sh -s -- <driver> [options]

Drivers:
EOF
    for d in $DRIVERS; do
      driver_info "$d"
      printf '  %-12s %s (https://github.com/%s)\n' "$d" "$ABOUT" "$REPO"
    done
    echo
  fi
  cat <<EOF
Options (environment variable, or \`sh -s -- <options>\` when piping):
  --version <v>     ADBC_VERSION      X.Y.Z or vX.Y.Z (default: the latest release)
  --dir <dir>       ADBC_DIR          drivers directory (default: the per-user one the
                                      ADBC driver manager searches)
  --system          ADBC_SYSTEM=1     the system-wide drivers directory (run with sudo)
  --name <name>     ADBC_NAME         install under another name, side by side with a
                                      driver that already has this one
  --archive <file>  ADBC_ARCHIVE      install a local release archive, download nothing
  --base-url <url>  ADBC_BASE_URL     a mirror of the release's files
  --uninstall       ADBC_UNINSTALL=1  remove the driver's manifest and libraries
  --help

Windows (PowerShell): irm $INSTALL_URL/${ADBC_INSTALL_PRESET:-<driver>}.ps1 | iex
Source: https://github.com/gizmodata/adbc-install
EOF
}

# ---- arguments ----------------------------------------------------------------------------------
DRIVER="$ADBC_INSTALL_PRESET"
[ -n "$DRIVER" ] || DRIVER="${ADBC_DRIVER:-}"
VERSION="${ADBC_VERSION:-}"
DIR="${ADBC_DIR:-}"
SYSTEM="${ADBC_SYSTEM:-}"
NAME="${ADBC_NAME:-}"
ARCHIVE="${ADBC_ARCHIVE:-}"
BASE_URL="${ADBC_BASE_URL:-}"
UNINSTALL="${ADBC_UNINSTALL:-}"

need_value() { [ "$2" -ge 2 ] || fatal "$1 needs a value (see --help)"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --version)    need_value "$1" $#; VERSION="$2"; shift 2 ;;
    --version=*)  VERSION="${1#*=}"; shift ;;
    --dir)        need_value "$1" $#; DIR="$2"; shift 2 ;;
    --dir=*)      DIR="${1#*=}"; shift ;;
    --system)     SYSTEM=1; shift ;;
    --name)       need_value "$1" $#; NAME="$2"; shift 2 ;;
    --name=*)     NAME="${1#*=}"; shift ;;
    --archive)    need_value "$1" $#; ARCHIVE="$2"; shift 2 ;;
    --archive=*)  ARCHIVE="${1#*=}"; shift ;;
    --base-url)   need_value "$1" $#; BASE_URL="$2"; shift 2 ;;
    --base-url=*) BASE_URL="${1#*=}"; shift ;;
    --uninstall)  UNINSTALL=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    -*)           fatal "unknown option: $1 (see --help)" ;;
    *)
      if [ -n "$ADBC_INSTALL_PRESET" ]; then
        fatal "unexpected argument: $1 (this is the $ADBC_INSTALL_PRESET installer; see --help)"
      fi
      DRIVER="$1"; shift ;;
  esac
done

if [ -z "$DRIVER" ]; then
  usage >&2
  echo >&2
  fatal "no driver chosen: pick one of: $DRIVERS"
fi
driver_info "$DRIVER" || fatal "unknown driver '$DRIVER': pick one of: $DRIVERS"
case "$SYSTEM" in 1|true|yes) SYSTEM=1 ;; ""|0|false|no) SYSTEM="" ;; *) fatal "ADBC_SYSTEM must be 1 or 0 (got '$SYSTEM')" ;; esac
case "$UNINSTALL" in 1|true|yes) UNINSTALL=1 ;; ""|0|false|no) UNINSTALL="" ;; *) fatal "ADBC_UNINSTALL must be 1 or 0 (got '$UNINSTALL')" ;; esac

# The manifest name: the driver's own, or --name. Driver managers look up "<name>.toml".
[ -n "$NAME" ] || NAME="$DRIVER"
case "$NAME" in
  .*|*[!A-Za-z0-9_.-]*) fatal "--name must be letters, digits, '_', '-' or '.', not starting with '.' (got '$NAME')" ;;
esac

# ---- the platform ------------------------------------------------------------------------------
os="$(uname -s)"
case "$os" in
  Linux)  OS=linux ;;
  Darwin) OS=macos ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    fatal "this is the macOS and Linux installer; on Windows run in PowerShell: irm $INSTALL_URL/$DRIVER.ps1 | iex" ;;
  *) fatal "GizmoData's ADBC drivers are built for Linux, macOS and Windows, not $os" ;;
esac
machine="$(uname -m)"
case "$machine" in
  x86_64|amd64)  ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) fatal "GizmoData's ADBC drivers are built for x86-64 and arm64, not $machine" ;;
esac
# A shell under Rosetta reports x86_64 on Apple silicon; native programs need the arm64 library.
if [ "$OS" = macos ] && [ "$ARCH" = amd64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" = 1 ]; then
  ARCH=arm64
fi
PLATFORM="${OS}_$ARCH"
if [ "$OS" = linux ]; then
  if ls /lib/ld-musl-* >/dev/null 2>&1 || ldd --version 2>&1 | grep -qi musl; then
    fatal "this system uses musl libc (Alpine Linux or similar); GizmoData's ADBC drivers for Linux need glibc"
  fi
  EXT=so
else
  EXT=dylib
fi

# ---- the drivers directory, as the ADBC driver manager computes it ------------------------------
if [ -z "$DIR" ]; then
  if [ -n "$SYSTEM" ]; then
    if [ "$OS" = macos ]; then DIR="/Library/Application Support/ADBC/Drivers"; else DIR=/etc/adbc/drivers; fi
  elif [ "$OS" = macos ]; then
    [ -n "${HOME:-}" ] || fatal "HOME is not set; pass --dir"
    DIR="$HOME/Library/Application Support/ADBC/Drivers"
  elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
    DIR="$XDG_CONFIG_HOME/adbc/drivers"
  else
    [ -n "${HOME:-}" ] || fatal "HOME is not set; pass --dir"
    DIR="$HOME/.config/adbc/drivers"
  fi
  CUSTOM_DIR=""
else
  CUSTOM_DIR=1
fi
case "$DIR" in /*) ;; *) DIR="$(pwd)/$DIR" ;; esac
while [ "$DIR" != / ] && [ "${DIR%/}" != "$DIR" ]; do DIR="${DIR%/}"; done
NL='
'
case "$DIR" in *"$NL"*) fatal "the drivers directory's path contains a line break" ;; esac
MANIFEST="$DIR/$NAME.toml"
LIBROOT="$DIR/$NAME"
MARKER="$LIBROOT/.adbc-install"
OUR_URL="https://github.com/$REPO"

# A path quoted for a POSIX shell, for the commands this script prints.
shquote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Ours: the manifest's url is our repository's (this script, the driver's own Python package, or a
# person following the driver's template wrote it).
OUR_URL_RE="$(printf '%s' "$OUR_URL" | sed 's/[.]/[.]/g')"
is_ours() { grep -Eq "^[[:space:]]*url[[:space:]]*=[[:space:]]*['\"]$OUR_URL_RE/?['\"]" "$1"; }

# ---- uninstall ----------------------------------------------------------------------------------
if [ -n "$UNINSTALL" ]; then
  removed=""
  if [ -f "$MANIFEST" ]; then
    if is_ours "$MANIFEST"; then
      rm -f "$MANIFEST" || fatal "cannot remove $MANIFEST (no write access? --system needs sudo)"
      removed=1; info "Removed $MANIFEST"
    else
      note "$MANIFEST belongs to another driver (its url is not $OUR_URL); left as it is"
    fi
  fi
  if [ -f "$MARKER" ]; then
    rm -rf "$LIBROOT" || fatal "cannot remove $LIBROOT"
    removed=1; info "Removed $LIBROOT"
  elif [ -d "$LIBROOT" ]; then
    note "$LIBROOT was not made by this installer; left as it is"
  fi
  [ -n "$removed" ] || info "Nothing to remove: no $TITLE driver named '$NAME' in $DIR"
  for b in "$MANIFEST".replaced-*; do
    [ -f "$b" ] || continue
    note "the manifest this installer replaced is kept as $b; to restore it: mv $(shquote "$b") $(shquote "$MANIFEST")"
  done
  exit 0
fi

# ---- tools --------------------------------------------------------------------------------------
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t adbc-install)"
STAGE=""
cleanup() { rm -rf "$TMP"; if [ -n "$STAGE" ]; then rm -rf "$STAGE"; fi; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if command -v curl >/dev/null 2>&1; then DL=curl
elif command -v wget >/dev/null 2>&1; then DL=wget
elif [ -z "$ARCHIVE" ]; then fatal "curl or wget is needed to download the driver"
fi
PROTO="=https"
if [ -n "${ADBC_INSTALL_GITHUB:-}" ] || [ -n "$BASE_URL" ]; then PROTO="=http,https"; fi

# fetch URL FILE: prints the final HTTP status (000 when there was no answer).
fetch() {
  if [ "$DL" = curl ]; then
    curl -sSL --retry 3 --connect-timeout 20 --proto "$PROTO" --proto-redir "$PROTO" \
      -o "$2" -w '%{http_code}' "$1" 2>"$TMP/fetch.err" || true
  else
    wget -q -S -t 3 -T 30 -O "$2" "$1" 2>"$TMP/fetch.err" || true
    awk '/^  HTTP\//{c=$2} END{printf "%03d", c+0}' "$TMP/fetch.err"
  fi
}
# curl's own message for the last failed fetch ("curl: (6) Could not resolve host: ..."), if any.
fetch_err() { if [ "$DL" = curl ] && [ -s "$TMP/fetch.err" ]; then printf '(%s) ' "$(head -n 1 "$TMP/fetch.err")"; fi; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  else fatal "sha256sum, shasum or openssl is needed to check the download"
  fi
}

# The library's machine, from its header: linux_amd64, linux_arm64, macos_amd64, macos_arm64,
# macos_universal, or "unknown".
lib_platform() {
  h="$(od -An -tx1 -N20 "$1" | tr -s ' \n' '  ')"
  # shellcheck disable=SC2086 # split into one byte per parameter, on purpose
  set -- $h
  if [ "${1:-}${2:-}${3:-}${4:-}" = 7f454c46 ]; then
    case "${19:-}${20:-}" in 3e00) echo linux_amd64 ;; b700) echo linux_arm64 ;; *) echo "unknown" ;; esac
  elif [ "${1:-}${2:-}${3:-}${4:-}" = cffaedfe ]; then
    case "${5:-}${6:-}${7:-}${8:-}" in 07000001) echo macos_amd64 ;; 0c000001) echo macos_arm64 ;; *) echo "unknown" ;; esac
  elif [ "${1:-}${2:-}${3:-}${4:-}" = cafebabe ]; then
    echo macos_universal
  else
    echo unknown
  fi
}

# The checksum for $ASSET in a sha256sum-style file ("<sha256>  [*][./]<name>"; with "one", a
# bare "<sha256>" line counts too, as in <asset>.sha256).
sums_entry() {
  awk -v f="$ASSET" -v one="${2:-}" '{ n = $2; sub(/^\*/, "", n); sub(/^.*\//, "", n) }
    $1 ~ /^[0-9A-Fa-f]+$/ && length($1) == 64 && (n == f || (one != "" && NF == 1)) { print $1; exit }' "$1"
}

normalize_version() {
  v="${1#v}"
  printf '%s\n' "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' || return 1
  printf '%s\n' "$v"
}

asset_name() {  # asset_name VERSION [PLATFORM]
  p="${2:-$PLATFORM}"
  if [ "$NAMING" = by_os ]; then
    o="${p%%_*}"; [ "$o" = macos ] && o=darwin
    echo "$LIB-$o-${p#*_}.tar.gz"
  else
    echo "$LIB-v$1-$p.tar.gz"
  fi
}

# Whether a release file exists (HTTP 200 at the end of its redirects), without downloading it.
exists() {
  if [ "$DL" = curl ]; then
    c="$(curl -sSIL --retry 2 --connect-timeout 20 --proto "$PROTO" --proto-redir "$PROTO" -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true)"
    [ "$c" = 200 ]
  else
    wget -q --spider -t 2 -T 30 "$1" 2>/dev/null
  fi
}

# ---- the archive: downloaded and checked, or given -------------------------------------------
if [ -n "$VERSION" ]; then
  VERSION="$(normalize_version "$VERSION")" || fatal "ADBC_VERSION/--version must be X.Y.Z or vX.Y.Z (got '${ADBC_VERSION:-$VERSION}')"
fi

if [ -z "$ARCHIVE" ]; then
  if [ -z "$VERSION" ]; then
    # /releases/latest redirects to /releases/tag/<tag>: no GitHub API call, so no rate limit.
    if [ "$DL" = curl ]; then
      latest="$(curl -sSL --retry 3 --connect-timeout 20 --proto "$PROTO" --proto-redir "$PROTO" \
        -o /dev/null -w '%{url_effective}' "$GH/$REPO/releases/latest" 2>"$TMP/fetch.err" || true)"
    else
      latest="$(wget -q -S -t 3 -T 30 -O /dev/null "$GH/$REPO/releases/latest" 2>&1 | awk '/^  Location: /{l=$2} END{print l}' | tr -d '\r')"
    fi
    case "$latest" in
      */releases/tag/*) VERSION="$(normalize_version "${latest##*/}")" \
        || fatal "the latest $TITLE release is tagged '${latest##*/}', which is not a version this installer knows; pass ADBC_VERSION" ;;
      *) fatal "could not find the latest $TITLE release at $GH/$REPO/releases/latest $(fetch_err)(try again, or pass ADBC_VERSION=X.Y.Z)" ;;
    esac
  fi
  TAG="v$VERSION"
  ASSET="$(asset_name "$VERSION")"
  if [ -z "$BASE_URL" ]; then BASE="$GH/$REPO/releases/download/$TAG"; else BASE="${BASE_URL%/}"; fi

  info "Downloading the $TITLE ADBC driver $VERSION for $PLATFORM"
  code="$(fetch "$BASE/$ASSET" "$TMP/$ASSET")"
  if [ "$code" != 200 ]; then
    if [ "$code" = 404 ] && [ -z "$BASE_URL" ]; then
      rel="$(fetch "$GH/$REPO/releases/tag/$TAG" "$TMP/release.html")"
      if [ "$rel" = 404 ]; then
        fatal "$REPO has no release $TAG (releases: $GH/$REPO/releases)"
      fi
      builds=""
      for p in linux_amd64 linux_arm64 macos_amd64 macos_arm64 windows_amd64 windows_arm64; do
        if exists "$BASE/$(asset_name "$VERSION" "$p")"; then builds="$builds $p"; fi
      done
      fatal "$TITLE $VERSION has no build for $PLATFORM; its builds are for:${builds:- (none found)} ($GH/$REPO/releases/tag/$TAG)"
    fi
    fatal "could not download $BASE/$ASSET (HTTP $code) $(fetch_err)"
  fi

  # The checksum: the release's SHA256SUMS, else <asset>.sha256. Never install unverified bytes.
  code="$(fetch "$BASE/SHA256SUMS" "$TMP/SHA256SUMS")"
  if [ "$code" = 200 ]; then
    want="$(sums_entry "$TMP/SHA256SUMS")"
    [ -n "$want" ] || fatal "the release's SHA256SUMS has no line for $ASSET; not installing it"
    from=SHA256SUMS
  elif [ "$code" = 404 ]; then
    code="$(fetch "$BASE/$ASSET.sha256" "$TMP/asset.sha256")"
    if [ "$code" = 200 ]; then
      want="$(sums_entry "$TMP/asset.sha256" one)"
      [ -n "$want" ] || fatal "$ASSET.sha256 is not a checksum of $ASSET; not installing it"
      from="$ASSET.sha256"
    elif [ "$code" = 404 ]; then
      fatal "$TITLE $VERSION publishes no checksums (neither SHA256SUMS nor $ASSET.sha256 is in the release), and this installer never installs files it cannot verify. Install a release that has them, or check $ASSET yourself and pass ADBC_ARCHIVE=<file>."
    else
      fatal "could not download $BASE/$ASSET.sha256 (HTTP $code) $(fetch_err)"
    fi
  else
    fatal "could not download $BASE/SHA256SUMS (HTTP $code) $(fetch_err)"
  fi
  want="$(printf '%s' "$want" | tr 'A-F' 'a-f')"
  got="$(sha256 "$TMP/$ASSET")"
  if [ "$got" != "$want" ]; then
    fatal "checksum mismatch for $ASSET: $from says $want, the download is $got; not installing it"
  fi
  info "Checksum OK ($from)"
  ARCHIVE="$TMP/$ASSET"
else
  [ -f "$ARCHIVE" ] || fatal "no such archive: $ARCHIVE"
  if [ -z "$VERSION" ]; then
    # Archives named by tag carry the version: libadbc_driver_<d>-v1.2.3-<platform>.tar.gz
    v="$(basename "$ARCHIVE" | sed -n "s/^$LIB-v\{0,1\}\([0-9][0-9.]*[0-9]\(-[0-9A-Za-z.-]*\)\{0,1\}\)-[a-z]*_[a-z0-9]*\.tar\.gz\$/\1/p")"
    VERSION="$(normalize_version "$v" 2>/dev/null)" \
      || fatal "can't tell the version of $(basename "$ARCHIVE") from its name; pass ADBC_VERSION=X.Y.Z with ADBC_ARCHIVE"
  fi
  info "Installing the $TITLE ADBC driver $VERSION for $PLATFORM from $ARCHIVE"
fi

# ---- unpack and check the library ---------------------------------------------------------------
mkdir "$TMP/x"
tar -xzf "$ARCHIVE" -C "$TMP/x" 2>"$TMP/tar.err" || fatal "could not unpack $(basename "$ARCHIVE"): $(head -n 1 "$TMP/tar.err")"
# The library is at the archive's root (oracle, db2) or in its one top folder (the others).
found=""
for f in "$TMP/x/$LIB.$EXT" "$TMP/x"/*/"$LIB.$EXT"; do
  [ -f "$f" ] || continue
  [ -z "$found" ] || fatal "$(basename "$ARCHIVE") holds more than one $LIB.$EXT"
  found="$f"
done
[ -n "$found" ] || fatal "$(basename "$ARCHIVE") holds no $LIB.$EXT at its root or one folder down: is it the $TITLE archive for $PLATFORM?"
built="$(lib_platform "$found")"
case "$built" in
  "$PLATFORM"|macos_universal) ;;
  *) fatal "$(basename "$ARCHIVE") holds a $built library, and this machine is $PLATFORM: is it the right archive?" ;;
esac
srcdir="$(dirname "$found")"

# ---- install the library ------------------------------------------------------------------------
mkdir -p "$DIR" 2>/dev/null || fatal "cannot create $DIR (no write access?$( [ -n "$SYSTEM" ] && echo ' run it with sudo:' "curl $INSTALL_URL/$DRIVER | sudo sh -s -- --system"))"
[ -w "$DIR" ] || fatal "no write access to $DIR$( [ -n "$SYSTEM" ] && echo '; run it with sudo:' "curl $INSTALL_URL/$DRIVER | sudo sh -s -- --system")"
if [ -d "$LIBROOT" ] && [ ! -f "$MARKER" ] && [ -n "$(ls -A "$LIBROOT" 2>/dev/null)" ]; then
  fatal "$LIBROOT exists and was not made by this installer; move it away, or pass --name <other name>"
fi
mkdir -p "$LIBROOT"
printf '%s\n' "Made by $INSTALL_URL for $OUR_URL; removed by --uninstall." > "$MARKER"
DEST="$LIBROOT/$VERSION"
STAGE="$LIBROOT/.staging.$$"
rm -rf "$STAGE"
mkdir "$STAGE"
cp "$srcdir"/* "$STAGE"/
rm -rf "$DEST"
mv "$STAGE" "$DEST"
STAGE=""
LIBPATH="$DEST/$LIB.$EXT"

# ---- the manifest -------------------------------------------------------------------------------
# A TOML basic string: backslashes and double quotes escaped.
escaped="$(printf '%s' "$LIBPATH" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
staged="$DIR/.$NAME.toml.tmp.$$"
cat > "$staged" <<EOF
# Written by $INSTALL_URL (https://github.com/gizmodata/adbc-install).
# Load it by name: driver = "$NAME" in any ADBC driver manager.
manifest_version = 1

name = '$MNAME'
version = '$VERSION'
publisher = 'GizmoData'
license = '$LICENSE'
url = '$OUR_URL'

[ADBC]
version = '1.1.0'

[Driver]
entrypoint = '$ENTRY'

[Driver.shared]
$PLATFORM = "$escaped"
EOF
replaced=""
if [ -f "$MANIFEST" ] && ! is_ours "$MANIFEST"; then
  replaced="$MANIFEST.replaced-$(date -u +%Y%m%dT%H%M%SZ)"
  n=1
  while [ -e "$replaced" ]; do n=$((n + 1)); replaced="${replaced%-[0-9]}-$n"; done
  theirs="$(sed -n "s/^[[:space:]]*url[[:space:]]*=[[:space:]]*['\"]\(.*\)['\"].*/\1/p" "$MANIFEST" | head -n 1)"
  mv "$MANIFEST" "$replaced" || { rm -f "$staged"; fatal "cannot move $MANIFEST aside"; }
fi
# Into place in one step, so a driver manager never reads half a manifest.
mv -f "$staged" "$MANIFEST"

# Earlier versions this installer put here are no longer in use.
for old in "$LIBROOT"/*; do
  [ -d "$old" ] && [ "$old" != "$DEST" ] && rm -rf "$old"
done

info "Installed the $TITLE ADBC driver $VERSION"
echo "  library:  $LIBPATH"
echo "  manifest: $MANIFEST"
echo "  driver = \"$NAME\""
if [ -n "$replaced" ]; then
  note "$MANIFEST belonged to another driver (url ${theirs:-unknown}); it is kept as $replaced"
  note "to go back to it: mv $(shquote "$replaced") $(shquote "$MANIFEST")"
fi
if [ -n "$CUSTOM_DIR" ]; then
  echo "  (driver managers search $DIR only when it is on ADBC_DRIVER_PATH)"
fi
echo "Python: adbc_driver_manager.dbapi.connect(driver=\"$NAME\", uri=\"...\")"
