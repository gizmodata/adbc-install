<#
.SYNOPSIS
    GizmoData ADBC driver installer for Windows (Windows PowerShell 5.1 and PowerShell 7).

.DESCRIPTION
    Installs one of GizmoData's ADBC drivers (oracle, db2, quack, gizmosql, chargewire,
    hardcharger) from its GitHub release for every ADBC driver manager on this machine (C/C++, Go,
    Python, R, Rust, ...), so that `driver = "<name>"` loads it:

        <drivers dir>\<name>\<version>\   the release's library (and its LICENSE/NOTICE files)
        <drivers dir>\<name>.toml         the driver manifest: the library's absolute path and entrypoint

    <drivers dir> is the per-user directory the ADBC driver manager searches,
    %LOCALAPPDATA%\ADBC\Drivers.

        irm https://install.adbc.gizmodata.com/oracle.ps1 | iex
        $env:ADBC_VERSION = '1.0.6'; irm https://install.adbc.gizmodata.com/oracle.ps1 | iex
        & ([scriptblock]::Create((irm https://install.adbc.gizmodata.com/install.ps1))) oracle -Version 1.0.6

    The archive is checked against the release's SHA256SUMS (or <archive>.sha256) before anything
    is installed; a release with neither, or a mismatch, is refused. Another driver's <name>.toml
    (one whose url is not ours) is moved aside to <name>.toml.replaced-<UTC time> first, and the
    installer prints the command that puts it back; -Name installs side by side instead.

.PARAMETER Driver
    Which driver (only in the generic install.ps1). Also $env:ADBC_DRIVER.
.PARAMETER Version
    A release, X.Y.Z or vX.Y.Z (default: the latest). Also $env:ADBC_VERSION.
.PARAMETER Dir
    The drivers directory (default %LOCALAPPDATA%\ADBC\Drivers). Also $env:ADBC_DIR.
.PARAMETER System
    Not supported on Windows: the system-wide level there is the registry. Also $env:ADBC_SYSTEM.
.PARAMETER Name
    Install under another manifest name, side by side with a driver that has this one. Also $env:ADBC_NAME.
.PARAMETER Archive
    Install this local release archive; nothing is downloaded. Also $env:ADBC_ARCHIVE.
.PARAMETER BaseUrl
    Where the release files are (a mirror of the GitHub release's downloads). Also $env:ADBC_BASE_URL.
.PARAMETER Uninstall
    Remove the manifest and <drivers dir>\<name>\. Also $env:ADBC_UNINSTALL = '1'.

.LINK
    https://github.com/gizmodata/adbc-install
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Driver = '',
  [string]$Version = '',
  [string]$Dir = '',
  [switch]$System,
  [string]$Name = '',
  [string]$Archive = '',
  [string]$BaseUrl = '',
  [switch]$Uninstall,
  [switch]$Help
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest's progress bar slows downloads badly in 5.1
# Windows PowerShell 5.1 may default to TLS 1.0, which GitHub refuses.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# The deploy sets this to one driver for https://install.adbc.gizmodata.com/<driver>.ps1; empty here.
$AdbcInstallPreset = ''

$InstallUrl = 'https://install.adbc.gizmodata.com'
$Drivers = @('oracle', 'db2', 'quack', 'gizmosql', 'chargewire', 'hardcharger')
# For tests only: another github.com (fake_github.py).
$Gh = if ($env:ADBC_INSTALL_GITHUB) { $env:ADBC_INSTALL_GITHUB.TrimEnd('/') } else { 'https://github.com' }
# Run as a file, a failure exits non-zero; piped into iex, it throws (exit would close the window).
$RunAsFile = [bool]$PSCommandPath

function Info([string]$m) { Write-Host "==> $m" -ForegroundColor Green }
function Note([string]$m) { Write-Host "note: $m" -ForegroundColor Yellow }
function Fail([string]$m) { $e = New-Object System.Exception $m; $e.Data['adbc-install'] = $true; throw $e }

# The driver table: see install.sh, which has the same one.
#   by_os:  libadbc_driver_<d>-windows-<amd64|arm64>.tar.gz  (+ <archive>.sha256)
#   by_tag: libadbc_driver_<d>-v<version>-windows_<amd64|arm64>.tar.gz
function Get-DriverInfo([string]$d) {
  $t = switch ($d) {
    'oracle'      { @{ Repo = 'gizmodata/adbc-driver-oracle'; Entry = 'AdbcDriverOracleInit';      Title = 'Oracle';      MName = 'ADBC Oracle Driver - Go'; License = 'MIT';        Naming = 'by_os';  About = 'Oracle Database, pure Go (no Oracle Client libraries)' } }
    'db2'         { @{ Repo = 'gizmodata/adbc-driver-db2';    Entry = 'AdbcDriverDb2Init';         Title = 'Db2';         MName = 'ADBC Db2 Driver - Go';    License = 'MIT';        Naming = 'by_os';  About = 'IBM Db2, pure Go (no IBM CLI libraries)' } }
    'quack'       { @{ Repo = 'gizmodata/adbc-driver-quack';  Entry = 'AdbcDriverQuackInit';       Title = 'Quack';       MName = 'ADBC Quack Driver - Go';  License = 'MIT';        Naming = 'by_os';  About = "DuckDB's Quack remote protocol" } }
    'gizmosql'    { @{ Repo = 'gizmodata/gizmosql-adbc';      Entry = 'AdbcDriverInit';            Title = 'GizmoSQL';    MName = 'GizmoSQL';                License = 'Apache-2.0'; Naming = 'by_tag'; About = 'GizmoSQL (Arrow Flight SQL)' } }
    'chargewire'  { @{ Repo = 'gizmodata/chargewire-adbc';    Entry = 'AdbcDriverChargewireInit';  Title = 'Chargewire';  MName = 'Chargewire';              License = 'Apache-2.0'; Naming = 'by_tag'; About = 'any Chargewire server' } }
    'hardcharger' { @{ Repo = 'gizmodata/hardcharger-adbc';   Entry = 'AdbcDriverHardchargerInit'; Title = 'Hardcharger'; MName = 'Hardcharger';             License = 'Apache-2.0'; Naming = 'by_tag'; About = 'Hardcharger' } }
    default { $null }
  }
  if ($t) { $t.Lib = "libadbc_driver_$d" }
  return $t
}

function Get-Usage {
  $lines = New-Object System.Collections.Generic.List[string]
  if ($AdbcInstallPreset) {
    $u = "$InstallUrl/$AdbcInstallPreset.ps1"
    $lines.Add("GizmoData ADBC driver installer: $AdbcInstallPreset (Windows)")
    $lines.Add('')
    $lines.Add("  irm $u | iex                                  # the latest release")
    $lines.Add("  `$env:ADBC_VERSION = 'X.Y.Z'; irm $u | iex     # a given release")
    $lines.Add("  & ([scriptblock]::Create((irm $u))) -Uninstall")
  } else {
    $lines.Add('GizmoData ADBC driver installer (Windows)')
    $lines.Add('')
    $lines.Add("  irm $InstallUrl/<driver>.ps1 | iex                                # the latest release")
    $lines.Add("  `$env:ADBC_VERSION = 'X.Y.Z'; irm $InstallUrl/<driver>.ps1 | iex   # a given release")
    $lines.Add("  & ([scriptblock]::Create((irm $InstallUrl/install.ps1))) <driver> [options]")
    $lines.Add('')
    $lines.Add('Drivers:')
    foreach ($d in $Drivers) { $i = Get-DriverInfo $d; $lines.Add(('  {0,-12} {1} (https://github.com/{2})' -f $d, $i.About, $i.Repo)) }
  }
  $lines.Add('')
  $lines.Add('Options (a parameter, or the environment variable):')
  $lines.Add('  -Version <v>      ADBC_VERSION      X.Y.Z or vX.Y.Z (default: the latest release)')
  $lines.Add('  -Dir <dir>        ADBC_DIR          drivers directory (default %LOCALAPPDATA%\ADBC\Drivers)')
  $lines.Add('  -Name <name>      ADBC_NAME         install under another name, side by side')
  $lines.Add('  -Archive <file>   ADBC_ARCHIVE      install a local release archive, download nothing')
  $lines.Add('  -BaseUrl <url>    ADBC_BASE_URL     a mirror of the release''s files')
  $lines.Add('  -Uninstall        ADBC_UNINSTALL=1  remove the driver''s manifest and libraries')
  $lines.Add('')
  $lines.Add("macOS and Linux: curl $InstallUrl/$(if ($AdbcInstallPreset) { $AdbcInstallPreset } else { '<driver>' }) | sh")
  $lines.Add('Source: https://github.com/gizmodata/adbc-install')
  return ($lines -join "`n")
}

function Test-Flag([string]$value, [string]$what) {
  switch -Regex ($value) {
    '^(1|true|yes)$' { return $true }
    '^(|0|false|no)$' { return $false }
    default { Fail "$what must be 1 or 0 (got '$value')" }
  }
}

function ConvertTo-Version([string]$v) {
  $n = $v -replace '^v', ''
  if ($n -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') { return $null }
  return $n
}

# Downloads $url to $file; returns the HTTP status (0 when there was no answer).
function Get-Url([string]$url, [string]$file) {
  $script:LastError = ''
  for ($try = 1; $try -le 3; $try++) {
    try {
      Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $file
      return 200
    } catch {
      $resp = $_.Exception.Response
      $code = 0
      if ($resp) { try { $code = [int]$resp.StatusCode } catch { $code = 0 } }
      $script:LastError = $_.Exception.Message
      if ($code -ge 400 -and $code -lt 500) { return $code }
      if ($try -lt 3) { Start-Sleep -Seconds (2 * $try) }
    }
  }
  return $code
}

# The final URL of a redirect chain (the releases/latest lookup), or '' when there's no answer.
function Get-RedirectTarget([string]$url) {
  try {
    $request = [Net.HttpWebRequest]::Create($url)
    $request.Method = 'HEAD'
    $request.AllowAutoRedirect = $true
    $response = $request.GetResponse()
    try { return $response.ResponseUri.AbsoluteUri } finally { $response.Close() }
  } catch {
    $script:LastError = $_.Exception.Message
    return ''
  }
}

# The checksum for $asset in a sha256sum-style file ("<sha256>  [*][./]<name>"; with $one, a bare
# "<sha256>" line counts too, as in <asset>.sha256).
function Get-SumsEntry([string]$file, [string]$asset, [bool]$one) {
  foreach ($line in Get-Content -LiteralPath $file) {
    $parts = @($line.Trim() -split '\s+', 2)
    if ($parts[0] -notmatch '^[0-9A-Fa-f]{64}$') { continue }
    if ($parts.Count -eq 1) { if ($one) { return $parts[0].ToLowerInvariant() } else { continue } }
    $n = ($parts[1] -replace '^\*', '') -replace '^.*/', ''
    if ($n -eq $asset) { return $parts[0].ToLowerInvariant() }
  }
  return $null
}

# The machine a DLL is built for, from its PE header: windows_amd64, windows_arm64, or what else.
function Get-DllPlatform([string]$path) {
  $fs = [IO.File]::OpenRead($path)
  try {
    $buf = New-Object byte[] 4096
    $n = $fs.Read($buf, 0, $buf.Length)
  } finally { $fs.Close() }
  if ($n -lt 64 -or $buf[0] -ne 0x4D -or $buf[1] -ne 0x5A) { return 'not a Windows DLL' }
  $pe = [BitConverter]::ToInt32($buf, 0x3C)
  if ($pe -lt 0 -or $pe + 6 -gt $n -or $buf[$pe] -ne 0x50 -or $buf[$pe + 1] -ne 0x45) { return 'not a Windows DLL' }
  switch ([BitConverter]::ToUInt16($buf, $pe + 4)) {
    0x8664 { return 'windows_amd64' }
    0xAA64 { return 'windows_arm64' }
    0x014C { return 'windows_386' }
    default { return 'an unknown machine' }
  }
}

function Format-Literal([string]$s) { "'" + $s.Replace("'", "''") + "'" }

# Ours: the manifest's url is our repository's (this script, the driver's own Python package, or a
# person following the driver's template wrote it).
function Test-Ours([string]$manifest, [string]$ourUrl) {
  $pattern = '^\s*url\s*=\s*[''"]' + [regex]::Escape($ourUrl) + '/?[''"]'
  foreach ($line in [IO.File]::ReadAllLines($manifest)) { if ($line -match $pattern) { return $true } }
  return $false
}

function Invoke-Main {
  if ($Help) { Write-Host (Get-Usage); return }
  $drv = if ($AdbcInstallPreset) { $AdbcInstallPreset } elseif ($Driver) { $Driver } else { [string]$env:ADBC_DRIVER }
  if ($AdbcInstallPreset -and $Driver -and $Driver -ne $AdbcInstallPreset) {
    Fail "unexpected argument: $Driver (this is the $AdbcInstallPreset installer; see -Help)"
  }
  if (-not $drv) {
    Write-Host (Get-Usage)
    Write-Host ''
    Fail "no driver chosen: pick one of: $($Drivers -join ' ')"
  }
  $info = Get-DriverInfo $drv
  if (-not $info) { Fail "unknown driver '$drv': pick one of: $($Drivers -join ' ')" }

  $ver = if ($Version) { $Version } else { [string]$env:ADBC_VERSION }
  $dirArg = if ($Dir) { $Dir } else { [string]$env:ADBC_DIR }
  $nameArg = if ($Name) { $Name } else { [string]$env:ADBC_NAME }
  $archiveArg = if ($Archive) { $Archive } else { [string]$env:ADBC_ARCHIVE }
  $baseArg = if ($BaseUrl) { $BaseUrl } else { [string]$env:ADBC_BASE_URL }
  $doUninstall = [bool]$Uninstall -or (Test-Flag ([string]$env:ADBC_UNINSTALL) 'ADBC_UNINSTALL')
  if ([bool]$System -or (Test-Flag ([string]$env:ADBC_SYSTEM) 'ADBC_SYSTEM')) {
    Fail 'the system-wide level on Windows is the registry, which this installer does not write; it installs per user (or into -Dir)'
  }

  $mname = if ($nameArg) { $nameArg } else { $drv }
  if ($mname -notmatch '^[A-Za-z0-9_-][A-Za-z0-9_.-]*$') {
    Fail "-Name must be letters, digits, '_', '-' or '.', not starting with '.' (got '$mname')"
  }

  # The platform: the machine's, not this PowerShell's (an x64 PowerShell can run emulated on ARM64).
  $machine = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -ErrorAction SilentlyContinue).PROCESSOR_ARCHITECTURE
  if (-not $machine) { $machine = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE } }
  $arch = switch ($machine) { 'AMD64' { 'amd64' } 'ARM64' { 'arm64' } default { $null } }
  if (-not $arch) { Fail "GizmoData's ADBC drivers are built for x64 and ARM64 Windows, not $machine" }
  $platform = "windows_$arch"

  # The drivers directory, as the ADBC driver manager computes it (FOLDERID_LocalAppData\ADBC\Drivers).
  $customDir = [bool]$dirArg
  if (-not $dirArg) {
    $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not $local) { Fail 'cannot find the LocalAppData folder; pass -Dir' }
    $dirArg = Join-Path $local 'ADBC\Drivers'
  }
  $dirPath = [IO.Path]::GetFullPath($dirArg).TrimEnd('\')
  if ($dirPath -match '[\r\n]') { Fail "the drivers directory's path contains a line break" }
  $manifest = Join-Path $dirPath "$mname.toml"
  $libRoot = Join-Path $dirPath $mname
  $marker = Join-Path $libRoot '.adbc-install'
  $ourUrl = "https://github.com/$($info.Repo)"

  if ($doUninstall) {
    $removed = $false
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
      if (Test-Ours $manifest $ourUrl) {
        Remove-Item -LiteralPath $manifest -Force
        $removed = $true; Info "Removed $manifest"
      } else {
        Note "$manifest belongs to another driver (its url is not $ourUrl); left as it is"
      }
    }
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
      Remove-Item -LiteralPath $libRoot -Recurse -Force
      $removed = $true; Info "Removed $libRoot"
    } elseif (Test-Path -LiteralPath $libRoot) {
      Note "$libRoot was not made by this installer; left as it is"
    }
    if (-not $removed) { Info "Nothing to remove: no $($info.Title) driver named '$mname' in $dirPath" }
    foreach ($b in @(Get-ChildItem -LiteralPath $dirPath -Filter "$mname.toml.replaced-*" -File -ErrorAction SilentlyContinue)) {
      Note "the manifest this installer replaced is kept as $($b.FullName); to restore it: Move-Item -LiteralPath $(Format-Literal $b.FullName) -Destination $(Format-Literal $manifest)"
    }
    return
  }

  if ($ver) {
    $n = ConvertTo-Version $ver
    if (-not $n) { Fail "ADBC_VERSION/-Version must be X.Y.Z or vX.Y.Z (got '$ver')" }
    $ver = $n
  }

  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('adbc-install-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  $stage = $null
  try {
    if (-not $archiveArg) {
      if (-not $ver) {
        # /releases/latest redirects to /releases/tag/<tag>: no GitHub API call, so no rate limit.
        $latest = Get-RedirectTarget "$Gh/$($info.Repo)/releases/latest"
        if ($latest -notmatch '/releases/tag/([^/?#]+)$') {
          Fail "could not find the latest $($info.Title) release at $Gh/$($info.Repo)/releases/latest $script:LastError (try again, or set `$env:ADBC_VERSION)"
        }
        $tagName = [Uri]::UnescapeDataString($Matches[1])
        $ver = ConvertTo-Version $tagName
        if (-not $ver) { Fail "the latest $($info.Title) release is tagged '$tagName', which is not a version this installer knows; set `$env:ADBC_VERSION" }
      }
      $tag = "v$ver"
      $asset = if ($info.Naming -eq 'by_os') { "$($info.Lib)-windows-$arch.tar.gz" } else { "$($info.Lib)-v$ver-$platform.tar.gz" }
      $base = if ($baseArg) { $baseArg.TrimEnd('/') } else { "$Gh/$($info.Repo)/releases/download/$tag" }

      Info "Downloading the $($info.Title) ADBC driver $ver for $platform"
      $archivePath = Join-Path $tmp $asset
      $code = Get-Url "$base/$asset" $archivePath
      if ($code -ne 200) {
        if ($code -eq 404 -and -not $baseArg) {
          $rel = Get-Url "$Gh/$($info.Repo)/releases/tag/$tag" (Join-Path $tmp 'release.html')
          if ($rel -eq 404) { Fail "$($info.Repo) has no release $tag (releases: $Gh/$($info.Repo)/releases)" }
          Fail "$($info.Title) $ver has no build for $platform ($asset is not in $Gh/$($info.Repo)/releases/tag/$tag)"
        }
        Fail "could not download $base/$asset (HTTP $code) $script:LastError"
      }

      # The checksum: the release's SHA256SUMS, else <asset>.sha256. Never install unverified bytes.
      $sums = Join-Path $tmp 'SHA256SUMS'
      $code = Get-Url "$base/SHA256SUMS" $sums
      if ($code -eq 200) {
        $want = Get-SumsEntry $sums $asset $false
        if (-not $want) { Fail "the release's SHA256SUMS has no line for $asset; not installing it" }
        $from = 'SHA256SUMS'
      } elseif ($code -eq 404) {
        $one = Join-Path $tmp 'asset.sha256'
        $code = Get-Url "$base/$asset.sha256" $one
        if ($code -eq 200) {
          $want = Get-SumsEntry $one $asset $true
          if (-not $want) { Fail "$asset.sha256 is not a checksum of $asset; not installing it" }
          $from = "$asset.sha256"
        } elseif ($code -eq 404) {
          Fail "$($info.Title) $ver publishes no checksums (neither SHA256SUMS nor $asset.sha256 is in the release), and this installer never installs files it cannot verify. Install a release that has them, or check $asset yourself and pass -Archive <file>."
        } else {
          Fail "could not download $base/$asset.sha256 (HTTP $code) $script:LastError"
        }
      } else {
        Fail "could not download $base/SHA256SUMS (HTTP $code) $script:LastError"
      }
      $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
      if ($got -ne $want) { Fail "checksum mismatch for ${asset}: $from says $want, the download is $got; not installing it" }
      Info "Checksum OK ($from)"
    } else {
      if (-not (Test-Path -LiteralPath $archiveArg -PathType Leaf)) { Fail "no such archive: $archiveArg" }
      $archivePath = (Resolve-Path -LiteralPath $archiveArg).Path
      if (-not $ver) {
        # Archives named by tag carry the version: libadbc_driver_<d>-v1.2.3-<platform>.tar.gz
        $leaf = [IO.Path]::GetFileName($archivePath)
        if ($leaf -match ('^' + [regex]::Escape($info.Lib) + '-v?(\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?)-[a-z]+_[a-z0-9]+\.tar\.gz$')) { $ver = $Matches[1] }
        else { Fail "can't tell the version of $leaf from its name; set `$env:ADBC_VERSION (or -Version) with -Archive" }
      }
      Info "Installing the $($info.Title) ADBC driver $ver for $platform from $archivePath"
    }

    # tar.exe (bsdtar) ships with Windows 10 1803 and later.
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tar)) { $tar = 'tar' }
    $extract = Join-Path $tmp 'x'
    New-Item -ItemType Directory -Path $extract | Out-Null
    $tarOut = & $tar -xzf $archivePath -C $extract 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "could not unpack $([IO.Path]::GetFileName($archivePath)): $tarOut" }
    $dlls = @(Get-ChildItem -LiteralPath $extract -Recurse -File -Filter "$($info.Lib).dll")
    if ($dlls.Count -eq 0) { Fail "$([IO.Path]::GetFileName($archivePath)) holds no $($info.Lib).dll: is it the $($info.Title) archive for $platform?" }
    if ($dlls.Count -gt 1) { Fail "$([IO.Path]::GetFileName($archivePath)) holds more than one $($info.Lib).dll" }
    $built = Get-DllPlatform $dlls[0].FullName
    if ($built -ne $platform) { Fail "$([IO.Path]::GetFileName($archivePath)) holds a $built library, and this machine is ${platform}: is it the right archive?" }

    New-Item -ItemType Directory -Force -Path $dirPath | Out-Null
    if ((Test-Path -LiteralPath $libRoot) -and -not (Test-Path -LiteralPath $marker) -and @(Get-ChildItem -LiteralPath $libRoot -Force).Count) {
      Fail "$libRoot exists and was not made by this installer; move it away, or pass -Name <other name>"
    }
    New-Item -ItemType Directory -Force -Path $libRoot | Out-Null
    [IO.File]::WriteAllText($marker, "Made by $InstallUrl for $ourUrl; removed by -Uninstall.`n", (New-Object Text.UTF8Encoding $false))
    $dest = Join-Path $libRoot $ver
    $stage = Join-Path $libRoot ".staging.$PID"
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage | Out-Null
    Copy-Item -Path (Join-Path ([Management.Automation.WildcardPattern]::Escape($dlls[0].Directory.FullName)) '*') -Destination $stage -Force
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    [IO.Directory]::Move($stage, $dest)
    $stage = $null
    $libPath = Join-Path $dest "$($info.Lib).dll"

    # A TOML basic string: backslashes and double quotes escaped.
    $escaped = $libPath.Replace('\', '\\').Replace('"', '\"')
    $text = @(
      "# Written by $InstallUrl (https://github.com/gizmodata/adbc-install).",
      "# Load it by name: driver = `"$mname`" in any ADBC driver manager.",
      'manifest_version = 1',
      '',
      "name = '$($info.MName)'",
      "version = '$ver'",
      "publisher = 'GizmoData'",
      "license = '$($info.License)'",
      "url = '$ourUrl'",
      '',
      '[ADBC]',
      "version = '1.1.0'",
      '',
      '[Driver]',
      "entrypoint = '$($info.Entry)'",
      '',
      '[Driver.shared]',
      "$platform = `"$escaped`""
    ) -join "`n"
    # UTF-8 without a byte order mark (5.1's -Encoding UTF8 writes one), staged next to the manifest.
    $staged = Join-Path $dirPath ".$mname.toml.tmp.$PID"
    [IO.File]::WriteAllText($staged, $text + "`n", (New-Object Text.UTF8Encoding $false))
    $replaced = $null
    $theirs = $null
    if ((Test-Path -LiteralPath $manifest -PathType Leaf) -and -not (Test-Ours $manifest $ourUrl)) {
      $stamp = "$manifest.replaced-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))"
      $replaced = $stamp
      for ($n = 2; Test-Path -LiteralPath $replaced; $n++) { $replaced = "$stamp-$n" }
      foreach ($line in [IO.File]::ReadAllLines($manifest)) {
        if ($line -match '^\s*url\s*=\s*[''"]([^''"]*)[''"]') { $theirs = $Matches[1]; break }
      }
      Move-Item -LiteralPath $manifest -Destination $replaced
    }
    # Into place in one step, so a driver manager never reads half a manifest.
    # (A $null argument would reach .NET as "", which Replace refuses: [NullString]::Value is a real null.)
    if (Test-Path -LiteralPath $manifest) { [IO.File]::Replace($staged, $manifest, [NullString]::Value) } else { [IO.File]::Move($staged, $manifest) }

    # Earlier versions this installer put here are no longer in use (a running program may still
    # hold one open: it stays until the next install).
    foreach ($old in @(Get-ChildItem -LiteralPath $libRoot -Directory)) {
      if ($old.FullName -ne $dest) { Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Info "Installed the $($info.Title) ADBC driver $ver"
    Write-Host "  library:  $libPath"
    Write-Host "  manifest: $manifest"
    Write-Host "  driver = `"$mname`""
    if ($replaced) {
      Note "$manifest belonged to another driver (url $(if ($theirs) { $theirs } else { 'unknown' })); it is kept as $replaced"
      Note "to go back to it: Move-Item -LiteralPath $(Format-Literal $replaced) -Destination $(Format-Literal $manifest) -Force"
    }
    if ($customDir) { Write-Host "  (driver managers search $dirPath only when it is on ADBC_DRIVER_PATH)" }
    Write-Host "Python: adbc_driver_manager.dbapi.connect(driver=`"$mname`", uri=`"...`")"
  } finally {
    if ($stage -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

try {
  Invoke-Main
} catch {
  if (-not $_.Exception.Data['adbc-install']) { throw }
  if ($RunAsFile) {
    Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
  }
  throw "error: $($_.Exception.Message)"
}
