# Changelog

All notable changes to the GizmoData ADBC driver installer are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). `main` is deployed to
<https://install.adbc.gizmodata.com> on every push, after the tests pass.

## [Unreleased]

## [1.0.0] - 2026-11-18

### Added

- `install.sh` (POSIX `sh`: dash, bash, macOS `sh`) and `install.ps1` (Windows PowerShell 5.1 and
  PowerShell 7) install any of GizmoData's six ADBC drivers (`oracle`, `db2`, `quack`, `gizmosql`,
  `chargewire`, `hardcharger`) from its GitHub release into the per-user drivers directory the ADBC
  driver manager searches, and write the driver manifest `<name>.toml` with the library's absolute
  path and the driver's entrypoint, so `driver = "<name>"` loads it in any driver manager.
- Served at <https://install.adbc.gizmodata.com>: `/<driver>` and `/<driver>.ps1` (the scripts with
  the driver preset, built at deploy time by `build-site.sh`), and the generic `/` (`install.sh`)
  and `/install.ps1`, which take the driver as an argument or `ADBC_DRIVER` and print the driver
  list when given none. Plain http works; no redirect.
- Options as environment variables or flags: `ADBC_VERSION`, `ADBC_DIR`, `ADBC_SYSTEM`,
  `ADBC_NAME`, `ADBC_ARCHIVE`, `ADBC_BASE_URL`, `ADBC_UNINSTALL`.
- Every download is checked against the release's `SHA256SUMS` (or `<archive>.sha256`); a mismatch
  or a release without checksums is refused. The library's header must match the machine.
- Another vendor's `<name>.toml` is moved to `<name>.toml.replaced-<UTC time>` and replaced, with
  the command that restores it printed; `--name` installs side by side instead.
- Tests: fixture releases from a stand-in for github.com on Linux (amd64, arm64, Oracle Linux 8),
  macOS and Windows (x64, ARM64; both PowerShells), platform checks, a musl check, and every
  driver's real latest release installed and loaded by name through the ADBC driver manager;
  weekly against the live site.
- Deploy to S3 and CloudFront by GitHub OIDC, with the live URLs checked byte for byte over https
  and http and the one-liners run, on Linux and Windows.
