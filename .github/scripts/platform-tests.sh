#!/bin/sh
# Unit tests of install.sh's platform checks, with fake uname/ldd/sysctl first on PATH. Nothing is
# downloaded: each case is refused before any fetch, or gets past the checks and then fails to
# download from a dead stand-in for github.com, after saying which platform it chose.
#
#   .github/scripts/platform-tests.sh [<shell>]
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$(cd "$HERE/../.." && pwd)/install.sh"
SH="${1:-sh}"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
FAKE="$ROOT/fakebin"
mkdir -p "$FAKE" "$ROOT/home"
failures=0

cat > "$FAKE/uname" <<'EOF'
#!/bin/sh
case "$1" in -s) echo "$FAKE_S" ;; -m) echo "$FAKE_M" ;; *) echo "$FAKE_S" ;; esac
EOF
cat > "$FAKE/ldd" <<'EOF'
#!/bin/sh
if [ -n "${FAKE_MUSL:-}" ]; then echo "musl libc (x86_64)" >&2; exit 1; fi
echo "ldd (GNU libc) 2.36"
EOF
cat > "$FAKE/sysctl" <<'EOF'
#!/bin/sh
echo "${FAKE_TRANSLATED:-0}"
EOF
chmod +x "$FAKE"/*

# check <name> <message> <env...>: the installer must fail and print <message>.
check() {
  name="$1"; msg="$2"; shift 2
  set +e
  out="$(env PATH="$FAKE:$PATH" HOME="$ROOT/home" ADBC_INSTALL_GITHUB=http://127.0.0.1:9 ADBC_DRIVER=oracle \
    "$@" "$SH" -s < "$INSTALLER" 2>&1)"
  code=$?
  set -e
  if [ "$code" != 0 ] && printf '%s\n' "$out" | grep -F -- "$msg" >/dev/null; then
    echo "ok   $name"
  else
    echo "FAIL $name (exit $code; wanted '$msg')"; printf '%s\n' "$out" | sed 's/^/     | /'
    failures=$((failures + 1))
  fi
}

V=ADBC_VERSION=1.0.0
check "Linux x86_64 (glibc)"           "Downloading the Oracle ADBC driver 1.0.0 for linux_amd64"  FAKE_S=Linux FAKE_M=x86_64 $V
check "Linux aarch64 (glibc)"          "Downloading the Oracle ADBC driver 1.0.0 for linux_arm64"  FAKE_S=Linux FAKE_M=aarch64 $V
check "Apple silicon"                  "Downloading the Oracle ADBC driver 1.0.0 for macos_arm64"  FAKE_S=Darwin FAKE_M=arm64 $V
check "Rosetta shell on Apple silicon" "Downloading the Oracle ADBC driver 1.0.0 for macos_arm64"  FAKE_S=Darwin FAKE_M=x86_64 FAKE_TRANSLATED=1 $V
check "Intel Mac"                      "Downloading the Oracle ADBC driver 1.0.0 for macos_amd64"  FAKE_S=Darwin FAKE_M=x86_64 FAKE_TRANSLATED=0 $V
check "Alpine (musl)"                  "this system uses musl libc (Alpine Linux or similar); GizmoData's ADBC drivers for Linux need glibc" FAKE_S=Linux FAKE_M=x86_64 FAKE_MUSL=1 $V
check "Git Bash on Windows"            "on Windows run in PowerShell: irm https://install.adbc.gizmodata.com/oracle.ps1 | iex" FAKE_S=MINGW64_NT-10.0 FAKE_M=x86_64 $V
check "FreeBSD"                        "built for Linux, macOS and Windows, not FreeBSD"          FAKE_S=FreeBSD FAKE_M=amd64 $V
check "32-bit Raspberry Pi OS"         "built for x86-64 and arm64, not armv7l"                   FAKE_S=Linux FAKE_M=armv7l $V
check "i686"                           "built for x86-64 and arm64, not i686"                     FAKE_S=Linux FAKE_M=i686 $V
check "riscv64"                        "built for x86-64 and arm64, not riscv64"                  FAKE_S=Linux FAKE_M=riscv64 $V

if [ "$failures" != 0 ]; then echo "$failures platform test(s) failed"; exit 1; fi
echo "all platform tests passed ($SH)"
