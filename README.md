<p align="center">
  <a href="https://github.com/gizmodata/adbc-install/actions/workflows/deploy.yml"><img src="https://github.com/gizmodata/adbc-install/actions/workflows/deploy.yml/badge.svg" alt="Deploy"></a>
  <a href="https://github.com/gizmodata/adbc-install/actions/workflows/test-install.yml"><img src="https://github.com/gizmodata/adbc-install/actions/workflows/test-install.yml/badge.svg" alt="Test installers"></a>
  <a href="https://arrow.apache.org/adbc/"><img src="https://img.shields.io/badge/installs-ADBC%20drivers-f15a24.svg" alt="ADBC drivers"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-brightgreen.svg" alt="Apache 2.0 license"></a>
  <a href="https://gizmodata.com"><img src="https://img.shields.io/badge/by-GizmoData%E2%84%A2-31a8db.svg" alt="GizmoData™"></a>
</p>

# 🔌 adbc-install

The one-line installer for GizmoData's [ADBC](https://arrow.apache.org/adbc/) drivers, served at
<https://install.adbc.gizmodata.com>. It installs a driver for every ADBC driver manager on the
machine (C/C++, Go, Python, R, Rust, ...), so that `driver = "hardcharger"` (or `"chargewire"`, `"oracle"`, ...)
loads it by name, with no path to give and no Python package to install.

## ⚡ Install

**macOS and Linux**

```bash
curl https://install.adbc.gizmodata.com/hardcharger | sh                  # the latest Hardcharger driver
curl https://install.adbc.gizmodata.com/hardcharger | ADBC_VERSION=2.6.1 sh
curl https://install.adbc.gizmodata.com | sh                              # no driver: the list and usage
```

No `-fsSL` is needed: every URL answers with the script itself, as `text/plain`, with no redirect.
Use `https://`: plain `http://` (and a URL typed without a scheme, which curl takes as http) never
serves the script, only a one-line stub that prints the https URL and exits non-zero, because
anyone on the network path could swap a script sent over http.

**Windows (Windows PowerShell 5.1 or PowerShell 7)**

```powershell
irm https://install.adbc.gizmodata.com/hardcharger.ps1 | iex
$env:ADBC_VERSION = '2.6.1'; irm https://install.adbc.gizmodata.com/hardcharger.ps1 | iex
& ([scriptblock]::Create((irm https://install.adbc.gizmodata.com/hardcharger.ps1))) -Uninstall
```

Then, from any ADBC driver manager, for example Python's (`pip install adbc-driver-manager pyarrow`),
here against a local Hardcharger server (`HARDCHARGER_ADMIN_PASSWORD=change-me hardcharger-server`,
which listens on port 31337 without TLS):

```python
import adbc_driver_manager.dbapi

with adbc_driver_manager.dbapi.connect(
    driver="hardcharger",
    uri="hardcharger://localhost?tls=false",
    db_kwargs={"username": "hardcharger", "password": "change-me"},
) as conn:
    with conn.cursor() as cur:
        cur.execute("SELECT 42 AS answer")
        print(cur.fetchone())
```

## 🗃️ Drivers

| Driver | Path | For | Builds |
|---|---|---|---|
| [`hardcharger`](https://github.com/gizmodata/hardcharger-adbc) | `/hardcharger`, `/hardcharger.ps1` | Hardcharger | Linux x86-64/arm64, macOS x86-64/arm64, Windows x64/ARM64 |
| [`chargewire`](https://github.com/gizmodata/chargewire-adbc) | `/chargewire`, `/chargewire.ps1` | any Chargewire server | Linux x86-64/arm64, macOS x86-64/arm64, Windows x64/ARM64 |
| [`gizmosql`](https://github.com/gizmodata/gizmosql-adbc) | `/gizmosql`, `/gizmosql.ps1` | GizmoSQL (Arrow Flight SQL) | Linux x86-64/arm64, macOS x86-64/arm64, Windows x64/ARM64 |
| [`oracle`](https://github.com/gizmodata/adbc-driver-oracle) | `/oracle`, `/oracle.ps1` | Oracle Database, pure Go (no Oracle Client libraries) | Linux x86-64/arm64, macOS arm64, Windows x64/ARM64 |
| [`db2`](https://github.com/gizmodata/adbc-driver-db2) | `/db2`, `/db2.ps1` | IBM Db2, pure Go (no IBM CLI libraries) | Linux x86-64/arm64, macOS arm64, Windows x64 |
| [`quack`](https://github.com/gizmodata/adbc-driver-quack) | `/quack`, `/quack.ps1` | DuckDB's Quack remote protocol | Linux x86-64/arm64, macOS arm64, Windows x64/ARM64 |

Each driver's README describes its URI and options. The installer verifies every download
against the release's checksums, so it installs only releases that publish them: every driver's
latest release does (`gizmosql` from 2.0.19, `chargewire` from 2.4.1 and `hardcharger` from 2.6.1
on). Asking for an older release of those three that has none (`ADBC_VERSION=2.0.18` for
`gizmosql`, for example) is refused with a message that says so.

The Linux builds need glibc, not musl (so not Alpine); the tests run them on Oracle Linux 8 (glibc 2.28) and newer.

## 🔧 Options

Set an environment variable for the `sh` (or `iex`) that runs the script, or pass a flag with
`sh -s -- <flags>` (PowerShell: a parameter, with the `[scriptblock]::Create(...)` form).

| Flag (`sh -s -- …`) | PowerShell | Environment | |
|---|---|---|---|
| `--version <v>` | `-Version` | `ADBC_VERSION` | a release, `X.Y.Z` or `vX.Y.Z` (default: the latest) |
| `--dir <dir>` | `-Dir` | `ADBC_DIR` | the drivers directory (default: the per-user one, below) |
| `--system` | | `ADBC_SYSTEM=1` | the system-wide drivers directory (run it with `sudo`); not on Windows, whose system level is the registry |
| `--name <name>` | `-Name` | `ADBC_NAME` | install under another name, side by side with a driver that has this one |
| `--archive <file>` | `-Archive` | `ADBC_ARCHIVE` | install a release archive you already have; it is still checked against the GitHub release's checksums (or `--sha256`) |
| `--base-url <url>` | `-BaseUrl` | `ADBC_BASE_URL` | download the archive from a mirror (`<url>/<archive>`); it is checked against the GitHub release's checksums, not the mirror's (or `--sha256`) |
| `--sha256 <hex>` | `-Sha256` | `ADBC_SHA256` | the archive's SHA-256 (from the release's `SHA256SUMS`), for a machine that can't reach github.com: check against it, fetch no checksums |
| `--allow-http` | `-AllowHttp` | `ADBC_ALLOW_HTTP=1` | allow a plain `http://` `--base-url` (the archive is checked all the same) |
| `--uninstall` | `-Uninstall` | `ADBC_UNINSTALL=1` | remove the driver's manifest and libraries |
| `<driver>` | `-Driver`, or the first argument | `ADBC_DRIVER` | only for the generic script at `/` (`/install.sh`) and `/install.ps1` |

```bash
curl https://install.adbc.gizmodata.com | sh -s -- hardcharger                  # by name, from the generic script
curl https://install.adbc.gizmodata.com/hardcharger | sh -s -- --uninstall
curl https://install.adbc.gizmodata.com/hardcharger | sudo sh -s -- --system
curl https://install.adbc.gizmodata.com/oracle | sh -s -- --name oracle-gizmodata  # beside another Oracle driver
```

## 🗂️ What it installs, and where

```text
<drivers dir>/
├── oracle.toml        the driver manifest: the library's absolute path and its entrypoint
└── oracle/
    └── 1.0.6/         the release's library (libadbc_driver_oracle.so/.dylib/.dll) and its LICENSE and NOTICE
```

`<drivers dir>` is the per-user directory the ADBC driver manager searches:

| | Per user (default) | System-wide (`--system`) |
|---|---|---|
| Linux | `$XDG_CONFIG_HOME/adbc/drivers` (`~/.config/adbc/drivers`) | `/etc/adbc/drivers` |
| macOS | `~/Library/Application Support/ADBC/Drivers` | `/Library/Application Support/ADBC/Drivers` |
| Windows | `%LOCALAPPDATA%\ADBC\Drivers` | (the registry; not written by this installer) |

A directory given with `--dir` is searched by driver managers only when it is on
`ADBC_DRIVER_PATH`. Installing another version replaces the previous one. At the end the
installer prints the library's path, the manifest's path and the name to load (`driver = "oracle"`).

## 🔁 Replacing another vendor's driver

If `<drivers dir>/<name>.toml` already exists and belongs to another driver (its `url` is not the
GizmoData driver's repository), the installer moves it aside to
`<name>.toml.replaced-<UTC time>`, installs GizmoData's, and prints what it replaced and the one
command that puts it back:

```text
note: .../oracle.toml belonged to another driver (url https://example.com/another-oracle-driver); it is kept as .../oracle.toml.replaced-20261118T232305Z
note: to go back to it: mv '.../oracle.toml.replaced-20261118T232305Z' '.../oracle.toml'
```

To keep both, install GizmoData's under another name with `--name` (then load it with
`driver = "oracle-gizmodata"`). `--uninstall` removes only GizmoData's manifest and its
`<name>/` directory, never another driver's, and reminds you of any manifest it replaced.

## 🛡️ What it checks

- **The platform, before downloading.** Linux and macOS on x86-64 and arm64 (a shell running
  under Rosetta on Apple silicon gets the arm64 driver), Windows on x64 and ARM64. It refuses
  musl (Alpine), 32-bit and other processors, and points Git Bash on Windows to the PowerShell
  installer.
- **The download.** It checks the archive against the release's `SHA256SUMS`, or
  `<archive>.sha256` when there is no `SHA256SUMS`, always read from the GitHub release over https,
  also when the archive came from `--base-url` or `--archive` (a mirror's own checksums are never
  trusted); `--sha256` replaces them for a machine that can't reach github.com. A mismatch, a
  `SHA256SUMS` without a line for the archive, or a release with no checksums at all is refused:
  it never installs bytes it could not verify. Downloads use https only, through every redirect
  (curl, wget and both PowerShells).
- **The archive's contents.** Only regular files and folders: an archive holding a link, a device
  or a pipe is refused. The installed files get fixed permissions (0644, the library 0755).
- **The version.** `ADBC_VERSION` must be one line of `[0-9A-Za-z.-]` matching `X.Y.Z[-suffix]`.
- **The library.** It must be in the archive, and its header must be for this machine (ELF,
  Mach-O or PE, and the processor), so an archive for another platform is refused.
- **Nothing half-written.** The manifest is written next to its final place and renamed into it,
  as UTF-8 without a byte order mark, with the path as a TOML string (backslashes and quotes
  escaped). A failed download or check changes nothing. All of `install.sh` runs from a function
  called on its last line, so a download cut short runs nothing.
- **Each driver's own folder.** `<drivers dir>/<name>/.adbc-install` records which driver's
  repository the folder was made for: another driver's script (say `db2 --name oracle`) neither
  installs into it nor removes it.

## 🧪 Tests

[`test-install.yml`](.github/workflows/test-install.yml) runs on every pull request, on pushes,
when a driver repository sends `repository_dispatch: driver-released`, weekly (against the live
site), and before every deploy and release. `CI result` is the check `main` requires.

**Fixture tests.** [`fake_github.py`](.github/scripts/fake_github.py) stands in for github.com's
release pages and downloads, with fixture releases whose libraries are a few bytes with a real ELF,
Mach-O or PE header.

| Job | Where | What |
|---|---|---|
| lint | ubuntu-24.04 | shellcheck, `dash -n`, `bash -n`, the served files build, PSScriptAnalyzer, and the platform checks with fake `uname`/`ldd`/`sysctl` (musl, Rosetta, Intel Mac, Git Bash, FreeBSD, 32-bit, ...) |
| fixtures linux-amd64, linux-arm64, macos-arm64, oraclelinux-8 | dash and bash, dash, `sh` and dash, `sh` | the generic script and every driver's script; pinned versions; `SHA256SUMS`, `<archive>.sha256`, a mismatch, a missing line, no checksums; an archive for another machine; no build for the platform; a version never released; another driver's manifest backed up, replaced and restored by the printed command; `--name`; uninstall; paths with spaces and both quotes; `--archive`; `--base-url`; `--system` without root; `XDG_CONFIG_HOME`; wget without curl |
| musl message | alpine | refused with the musl explanation before any download |
| fixtures windows-amd64, windows-arm64 | PowerShell 7 and Windows PowerShell 5.1 | the same, plus the `irm \| iex` form |

**Real releases.** Every driver's latest release, installed by its own script and loaded by name
through the ADBC driver manager ([`check_driver_by_name.py`](.github/scripts/check_driver_by_name.py)
gives each driver a URI with its own scheme pointing where nothing listens, and requires the error
only that driver writes), then uninstalled; on `oracle` also a pinned version, another driver's
manifest replaced and restored, and `--name`. On Linux x86-64 and arm64 (dash as `/bin/sh`),
Oracle Linux 8 (glibc 2.28), macOS arm64, and Windows x64 and ARM64 under both PowerShells. A
latest release without checksums fails the check, and a release without a build for the platform
(db2 on Windows ARM64) must be refused with a message that says so.

Run them locally (each uses a throwaway `HOME`):

```bash
.github/scripts/fixture-scenarios.sh                                 # SH=dash or SH=bash to pick the shell
.github/scripts/platform-tests.sh dash
PYTHON=<python with adbc-driver-manager> .github/scripts/real-release.sh
```

## 🚀 Deploy

[`deploy.yml`](.github/workflows/deploy.yml) runs on every push to `main`, and its upload waits
for Philip's approval in the `production` environment (the only required reviewer; admins may
bypass; `main` only). Its `deploy` job is the only
one that can reach AWS, and it runs nothing it downloads; a separate `verify` job, with no AWS
access, runs the live one-liners. Every action is pinned to a commit SHA
([`check_workflows.py`](.github/scripts/check_workflows.py) enforces both). Only after the tests
pass does it build the served files ([`build-site.sh`](.github/scripts/build-site.sh): `install.sh`
and `install.ps1`, and for each driver `<driver>` and `<driver>.ps1`, the same scripts with the
driver preset in one line), upload them as `text/plain` to the private S3 bucket
`gizmodata-adbc-install`, invalidate the CloudFront distribution, check that every live URL serves
exactly this commit's files over https and http without a redirect, and run the one-liners. It
reaches AWS by GitHub OIDC, with a role that trusts only this repo's `main` and can only write that
bucket and invalidate that distribution. The bucket, distribution, certificate, DNS and role are in
[gizmodata-infrastructure-terraform](https://github.com/gizmodata/gizmodata-infrastructure-terraform)
(`aws/dns/adbc_install.tf`).

## 📄 License

[Apache 2.0](LICENSE). Each driver has its own license (see its repository).

<p align="center">
  <a href="https://gizmodata.com"><img src="docs/assets/gizmodata-logo.png" alt="GizmoData™" width="56"></a><br>
  <sub>Built by <a href="https://gizmodata.com">GizmoData™</a></sub>
</p>

<p align="center"><sub>GizmoData™ and Hardcharger™ are trademarks of GizmoData LLC.</sub></p>
