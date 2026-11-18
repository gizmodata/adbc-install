"""Check a driver manifest the installer wrote, by parsing it as TOML (Python 3.11+, no packages).

    python check_manifest.py --manifest <file> --driver oracle --version 1.0.6 --platform linux_amd64

The expected repository and entrypoint are listed here a second time, independently of the
installers' own tables, so a wrong entry in either shows up.
"""

from __future__ import annotations

import argparse
import os
import sys
import tomllib

EXPECTED = {
    "oracle": ("https://github.com/gizmodata/adbc-driver-oracle", "AdbcDriverOracleInit", "libadbc_driver_oracle"),
    "db2": ("https://github.com/gizmodata/adbc-driver-db2", "AdbcDriverDb2Init", "libadbc_driver_db2"),
    "quack": ("https://github.com/gizmodata/adbc-driver-quack", "AdbcDriverQuackInit", "libadbc_driver_quack"),
    "gizmosql": ("https://github.com/gizmodata/gizmosql-adbc", "AdbcDriverInit", "libadbc_driver_gizmosql"),
    "chargewire": ("https://github.com/gizmodata/chargewire-adbc", "AdbcDriverChargewireInit", "libadbc_driver_chargewire"),
    "hardcharger": ("https://github.com/gizmodata/hardcharger-adbc", "AdbcDriverHardchargerInit", "libadbc_driver_hardcharger"),
}
EXT = {"linux": ".so", "macos": ".dylib", "windows": ".dll"}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--driver", required=True, choices=sorted(EXPECTED))
    parser.add_argument("--version", required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--lib-dir", help="the directory the library must be in (default: <manifest dir>/<name>/<version>)")
    args = parser.parse_args()

    with open(args.manifest, "rb") as f:
        raw = f.read()
    problems = []
    if raw.startswith(b"\xef\xbb\xbf"):
        problems.append("starts with a UTF-8 byte order mark")
    if b"\r" in raw:
        problems.append("has CR line endings")
    doc = tomllib.loads(raw.decode("utf-8"))
    url, entrypoint, lib = EXPECTED[args.driver]
    name = os.path.basename(args.manifest)[: -len(".toml")]
    lib_dir = args.lib_dir or os.path.join(os.path.dirname(os.path.abspath(args.manifest)), name, args.version)
    want_path = os.path.join(lib_dir, lib + EXT[args.platform.split("_")[0]])

    checks = {
        "manifest_version": (doc.get("manifest_version"), 1),
        "url": (doc.get("url"), url),
        "version": (doc.get("version"), args.version),
        "publisher": (doc.get("publisher"), "GizmoData"),
        "ADBC.version": (doc.get("ADBC", {}).get("version"), "1.1.0"),
        "Driver.entrypoint": (doc.get("Driver", {}).get("entrypoint"), entrypoint),
        "Driver.shared": (doc.get("Driver", {}).get("shared"), {args.platform: want_path}),
    }
    for key, (got, want) in checks.items():
        if got != want:
            problems.append(f"{key} is {got!r}, expected {want!r}")
    if not os.path.isfile(want_path):
        problems.append(f"the library {want_path!r} does not exist")
    if problems:
        print(f"{args.manifest}:", *problems, sep="\n  ", file=sys.stderr)
        return 1
    print(f"manifest OK: {args.driver} {args.version} {args.platform} -> {want_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
