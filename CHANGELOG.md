# Changelog

All notable changes to the GizmoData ADBC driver installer are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). `main` is deployed to
<https://install.adbc.gizmodata.com> on every push, after the tests pass.

## [Unreleased]

### Security

Fixes from an independent review of the installers (findings F5 to F10):

- **Checksums always come from the GitHub release** (over https), also when the archive comes from
  `--base-url` or `--archive`: a mirror's own `SHA256SUMS` is no longer trusted, so a mirror can't
  vouch for a build it serves. New `--sha256` / `ADBC_SHA256` / `-Sha256` gives the archive's
  SHA-256 for a machine that can't reach github.com. `--archive` without either is refused (it was
  installed unchecked). An `http://` `--base-url` needs `--allow-http` / `ADBC_ALLOW_HTTP=1`.
- **Versions are checked as a whole value**: `ADBC_VERSION` with a line break (which `install.sh`
  accepted when any line was a version, and wrote into the manifest) or non-ASCII digits
  (`install.ps1`) is refused.
- **`install.sh` runs from `main()`, called on its last line**: a download cut short runs nothing
  (a cut after the old library was removed used to leave a manifest pointing at nothing). A
  reinstall now moves the new version into place before removing the old one.
- **`<name>/.adbc-install` records the driver's repository**: another driver's script with the same
  `--name` no longer installs into, or uninstalls, that folder. Folders marked by 1.0.0 are still
  recognised.
- **Archives may hold only regular files and folders**: a symbolic link, device or named pipe is
  refused (a link was copied by its target's contents); installed files get fixed permissions.
- **https only through redirects** for wget and Windows PowerShell 5.1 too (curl already was), and
  the test-only `ADBC_INSTALL_GITHUB` override refuses `http://` unless `ADBC_INSTALL_TEST_INSECURE=1`.

### Security (workflows)

- **The deploy's AWS session never meets downloaded code** (review finding F2): `deploy` (the only
  job with `id-token: write`) checks out, builds, uploads, invalidates and byte-compares the live
  files; a new `verify` job without `id-token` runs the one-liners, the pip install and the drivers
  they load.
- **Every action is pinned to a full commit SHA** (F3), with its version in a comment
  (`actions/checkout@3d3c42e… # v7.0.1`, `aws-actions/configure-aws-credentials@e125382… # v6.3.0`, …).
- **Every deploy waits for Philip's approval** (review finding F4): the `deploy` job runs in the
  `production` environment (required reviewer prmoore77, admin bypass allowed, `main` only), and the
  deploy role trusts that environment's OIDC subject. GitHub records the deployments itself, so
  the workflow no longer writes deployment records through the API.
- `check_workflows.py` (in the lint job) fails on an unpinned action or a credentialed job that
  installs packages, pipes into a shell or runs Python.

### Changed

- **Plain http no longer serves the installers.** `http://install.adbc.gizmodata.com/<path>` (and a
  scheme-less `curl install.adbc.gizmodata.com/<path>`) answers 200 with a one-line stub,
  `echo 'error: use https://install.adbc.gizmodata.com/<path> …' >&2; exit 1` (`throw '…'` for `*.ps1`), from a
  CloudFront Function (gizmodata-infrastructure-terraform `aws/dns/installers_https_only.tf`), so a piped http
  one-liner fails loudly instead of running a script anyone on the path could have swapped. The README drops the
  `curl http://…` example; the deploy checks that https serves these exact files and http only the stub, and that
  `curl http://… | sh` exits non-zero and installs nothing.
- Hardcharger first: the drivers are listed in the order hardcharger, chargewire, gizmosql, oracle,
  db2, quack (the bare URL's list, "unknown driver" and "no driver chosen" errors, the README's
  table), and the README's examples install Hardcharger (`ADBC_VERSION=2.6.1` for a pinned one),
  with a Python example that queries a local Hardcharger server.

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
  or a release without checksums is refused. The library (at the archive's root or one folder
  down) must have a header for this machine. A release with no build for this platform is refused
  with the list of platforms it has builds for.
- Another vendor's `<name>.toml` is moved to `<name>.toml.replaced-<UTC time>` and replaced, with
  the command that restores it printed; `--name` installs side by side instead.
- Tests: fixture releases from a stand-in for github.com on Linux (amd64, arm64, Oracle Linux 8),
  macOS and Windows (x64, ARM64; both PowerShells), platform checks, a musl check, and every
  driver's real latest release installed and loaded by name through the ADBC driver manager;
  weekly against the live site.
- Deploy to S3 and CloudFront by GitHub OIDC, with the live URLs checked byte for byte over https
  and http and the one-liners run, on Linux and Windows.
