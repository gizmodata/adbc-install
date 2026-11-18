# install.ps1, and the per-driver scripts the deploy builds from it, end to end on Windows against
# fixture releases served by fake_github.py: no credentials, no real release. The stand-in DLLs are
# a few bytes with a real PE header, so the installer's machine check sees a real machine type.
# Runs under the PowerShell that runs it (pwsh, or Windows PowerShell 5.1), installer included.
#
# Covered: the generic script (no driver, a driver by argument or ADBC_DRIVER), every driver's
# script, the `irm | iex` form (success and failure), pinned versions, SHA256SUMS, <archive>.sha256,
# no checksums, a mismatch, no line for the archive, a DLL for another machine, no build for this
# platform, a version never released, another driver's manifest backed up, replaced and restored by
# the printed command, -Name side by side, uninstall, a -Dir with spaces and a quote, -Archive,
# -BaseUrl, -System, and the manifest written as UTF-8 without a byte order mark.
#
#   .github/scripts/build-site.sh site    (in Git Bash), then
#   pwsh -File .github/scripts/windows-tests.ps1 -Site site     (or powershell -File ... for 5.1)
param([Parameter(Mandatory = $true)][string]$Site)
# Continue: under 5.1 a native command's stderr is an error record, and the installer's own error
# message must reach the checks below instead of stopping this script.
$ErrorActionPreference = 'Continue'
$Site = (Resolve-Path -LiteralPath $Site).Path
$shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
$py = (Get-Command python -ErrorAction Stop).Source
$here = $PSScriptRoot
$root = Join-Path ([IO.Path]::GetTempPath()) "adbc-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $root | Out-Null
$failures = 0
$drivers = @('oracle', 'db2', 'quack', 'gizmosql', 'chargewire', 'hardcharger')
$repos = @{ oracle = 'adbc-driver-oracle'; db2 = 'adbc-driver-db2'; quack = 'adbc-driver-quack'; gizmosql = 'gizmosql-adbc'; chargewire = 'chargewire-adbc'; hardcharger = 'hardcharger-adbc' }
function Test-ByOs([string]$d) { $d -in @('oracle', 'db2', 'quack') }

$cpu = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE
$arch = if ($cpu -eq 'ARM64') { 'arm64' } else { 'amd64' }
$other = if ($arch -eq 'arm64') { 'amd64' } else { 'arm64' }
$platform = "windows_$arch"
$drv = Join-Path $root 'local app data\ADBC\Drivers'
Write-Host "shell: $shell $($PSVersionTable.PSVersion); platform: $platform"

function Check([string]$name, [bool]$ok) {
  if ($ok) { Write-Host "ok   $name" -ForegroundColor Green } else { Write-Host "FAIL $name" -ForegroundColor Red; $script:failures++ }
}
# Runs a script as a file (or, with -Iex, as `irm | iex` runs it), with these environment variables.
function Invoke-Installer([string]$script, [string[]]$installerArgs = @(), [hashtable]$envs = @{}, [switch]$Iex) {
  $all = @{ ADBC_INSTALL_GITHUB = $script:gh; ADBC_DIR = $script:drv }
  foreach ($k in $envs.Keys) { $all[$k] = $envs[$k] }
  $saved = @{}
  foreach ($k in $all.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $all[$k]) }
  try {
    if ($Iex) {
      $cmd = "Get-Content -Raw -LiteralPath '$($script.Replace("'", "''"))' | Invoke-Expression"
      $out = & $shell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String
    } else {
      $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $script @installerArgs 2>&1 | Out-String
    }
    $code = $LASTEXITCODE
  } finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
  }
  Write-Host ($out -replace '(?m)^', '  | ')
  return @{ Out = $out; Code = $code }
}
function Test-Manifest([string]$manifest, [string]$d, [string]$ver, [string]$libDir = '') {
  $a = @("$here\check_manifest.py", '--manifest', $manifest, '--driver', $d, '--version', $ver, '--platform', $platform)
  if ($libDir) { $a += @('--lib-dir', $libDir) }
  & $py @a 2>&1 | Write-Host
  return $LASTEXITCODE -eq 0
}
function Get-Sha([string]$f) { (Get-FileHash -Algorithm SHA256 -LiteralPath $f).Hash.ToLowerInvariant() }
function Get-Asset([string]$d, [string]$v) {
  if (Test-ByOs $d) { "libadbc_driver_$d-windows-$arch.tar.gz" } else { "libadbc_driver_$d-v$v-$platform.tar.gz" }
}

# ---- fixtures ----------------------------------------------------------------------------------
$fx = Join-Path $root 'fixtures\gizmodata'
function New-FakeDll([string]$a, [string]$path) {
  $b = New-Object byte[] 256
  $b[0] = 0x4D; $b[1] = 0x5A                          # MZ
  $b[0x3C] = 0x80                                     # e_lfanew
  $b[0x80] = 0x50; $b[0x81] = 0x45                    # PE\0\0
  if ($a -eq 'amd64') { $b[0x84] = 0x64; $b[0x85] = 0x86 } else { $b[0x84] = 0x64; $b[0x85] = 0xAA }
  [IO.File]::WriteAllBytes($path, $b)
}
function New-Release([string]$d, [string]$v, [string]$sums = 'both', [string]$libArch = $arch) {
  $dir = Join-Path $fx "$($repos[$d])\v$v"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $asset = Get-Asset $d $v
  $b = Join-Path $root "build\$d-$v"
  if (Test-Path $b) { Remove-Item -Recurse -Force $b }
  $pkg = if ($d -in @('oracle', 'db2')) { $b } else { Join-Path $b ($asset -replace '\.tar\.gz$', '') }
  New-Item -ItemType Directory -Force -Path $pkg | Out-Null
  New-FakeDll $libArch (Join-Path $pkg "libadbc_driver_$d.dll")
  Set-Content -LiteralPath (Join-Path $pkg 'LICENSE') -Value "license of $d $v" -Encoding ascii
  Push-Location $b
  & "$env:SystemRoot\System32\tar.exe" -czf (Join-Path $dir $asset) *
  Pop-Location
  $o = if (Test-ByOs $d) { "libadbc_driver_$d-linux-amd64.tar.gz" } else { "libadbc_driver_$d-v$v-linux_amd64.tar.gz" }
  Set-Content -LiteralPath (Join-Path $dir $o) -Value 'not this platform' -Encoding ascii
  $h = Get-Sha (Join-Path $dir $asset)
  $n = if ($d -eq 'quack') { "./$asset" } else { $asset }
  $nl = "`n"
  switch ($sums) {
    'both' {
      [IO.File]::WriteAllText((Join-Path $dir 'SHA256SUMS'), "$(Get-Sha (Join-Path $dir $o))  $o$nl$h  $n$nl")
      if (Test-ByOs $d) { [IO.File]::WriteAllText((Join-Path $dir "$asset.sha256"), "$h  $asset$nl") }
    }
    'sha256' { [IO.File]::WriteAllText((Join-Path $dir "$asset.sha256"), "$h  $asset$nl") }
    'none' { }
    'noline' { [IO.File]::WriteAllText((Join-Path $dir 'SHA256SUMS'), "$(Get-Sha (Join-Path $dir $o))  $o$nl") }
    'mismatch' { [IO.File]::WriteAllText((Join-Path $dir 'SHA256SUMS'), "$('0' * 64)  $n$nl") }
  }
}
foreach ($d in $drivers) { New-Release $d '9.9.8'; New-Release $d '9.9.9' }
New-Release oracle '9.9.7' mismatch
New-Release oracle '9.9.6' sha256
New-Release oracle '9.9.5' none
New-Release oracle '9.9.4' noline
New-Release oracle '9.9.3' both $other
New-Item -ItemType Directory -Force -Path (Join-Path $fx 'adbc-driver-oracle\v9.9.2') | Out-Null
Set-Content -LiteralPath (Join-Path $fx 'adbc-driver-oracle\v9.9.2\libadbc_driver_oracle-linux-amd64.tar.gz') -Value 'other' -Encoding ascii
New-Release chargewire '9.9.5' none

$portFile = Join-Path $root 'port'
$server = Start-Process -FilePath $py -ArgumentList @("`"$here\fake_github.py`"", '--root', "`"$root\fixtures`"", '--port-file', "`"$portFile`"", '--log', "`"$root\requests.log`"") -PassThru -WindowStyle Hidden
try {
  for ($i = 0; $i -lt 300 -and -not ((Test-Path $portFile) -and (Get-Content $portFile)); $i++) { Start-Sleep -Milliseconds 100 }
  if (-not (Test-Path $portFile)) { throw 'fake github.com did not start' }
  $url = "http://127.0.0.1:$(Get-Content $portFile)"
  $gh = $url

  # ---- the generic script -------------------------------------------------------------------------
  $r = Invoke-Installer "$Site\install.ps1"
  Check 'generic: no driver prints the list and fails' ($r.Code -ne 0 -and $r.Out -match 'no driver chosen: pick one of: oracle db2 quack gizmosql chargewire hardcharger' -and $r.Out -match 'gizmodata/hardcharger-adbc')
  $r = Invoke-Installer "$Site\install.ps1" @('mysql')
  Check 'generic: an unknown driver is refused' ($r.Code -ne 0 -and $r.Out -match "unknown driver 'mysql'")
  $r = Invoke-Installer "$Site\install.ps1" @('db2')
  Check 'generic: driver by argument' ($r.Code -eq 0 -and (Test-Manifest "$drv\db2.toml" db2 '9.9.9'))
  $r = Invoke-Installer "$Site\install.ps1" @() @{ ADBC_DRIVER = 'quack' }
  Check 'generic: driver by ADBC_DRIVER' ($r.Code -eq 0 -and (Test-Manifest "$drv\quack.toml" quack '9.9.9'))
  $r = Invoke-Installer "$Site\oracle.ps1" @('db2')
  Check 'oracle.ps1 refuses another driver' ($r.Code -ne 0 -and $r.Out -match 'this is the oracle installer')

  # ---- every driver's script -------------------------------------------------------------------
  foreach ($d in $drivers) {
    $r = Invoke-Installer "$Site\$d.ps1"
    $ok = $r.Code -eq 0 -and $r.Out.Contains('Checksum OK (SHA256SUMS)') -and $r.Out.Contains("library:  $drv\$d\9.9.9\libadbc_driver_$d.dll") -and
      $r.Out.Contains("manifest: $drv\$d.toml") -and $r.Out.Contains("driver = `"$d`"") -and (Test-Manifest "$drv\$d.toml" $d '9.9.9')
    Check "$d.ps1 installs the latest" $ok
  }

  # ---- irm | iex ------------------------------------------------------------------------------
  $r = Invoke-Installer "$Site\oracle.ps1" -Iex -envs @{ ADBC_VERSION = '9.9.8' }
  Check 'iex: ADBC_VERSION=9.9.8' ($r.Code -eq 0 -and (Test-Manifest "$drv\oracle.toml" oracle '9.9.8') -and -not (Test-Path "$drv\oracle\9.9.9"))
  $r = Invoke-Installer "$Site\oracle.ps1" -Iex -envs @{ ADBC_VERSION = '9.9.5' }
  Check 'iex: a refusal fails with its message' ($r.Code -ne 0 -and $r.Out -match 'Oracle 9\.9\.5 publishes no checksums')
  $r = Invoke-Installer "$Site\install.ps1" -Iex
  Check 'iex: the generic script with no driver fails with the list' ($r.Code -ne 0 -and $r.Out -match 'no driver chosen')
  $r = Invoke-Installer "$Site\oracle.ps1" @('-Version', 'v9.9.9')
  Check '-Version v9.9.9' ($r.Code -eq 0 -and (Test-Manifest "$drv\oracle.toml" oracle '9.9.9'))

  # ---- checksums and refusals: nothing may change ------------------------------------------------
  $before = [IO.File]::ReadAllText("$drv\oracle.toml")
  function Test-Unchanged { ([IO.File]::ReadAllText("$drv\oracle.toml") -eq $before) -and (@(Get-ChildItem "$drv\oracle" -Directory).Name -join ',') -eq '9.9.9' }
  $r = Invoke-Installer "$Site\oracle.ps1" @('-Version', '9.9.7')
  Check 'a checksum mismatch is refused' ($r.Code -ne 0 -and $r.Out.Contains("checksum mismatch for $(Get-Asset oracle '9.9.7'): SHA256SUMS says $('0' * 64)") -and (Test-Unchanged))
  $r = Invoke-Installer "$Site\oracle.ps1" @('-Version', '9.9.6')
  Check '<archive>.sha256 without SHA256SUMS' ($r.Code -eq 0 -and $r.Out.Contains("Checksum OK ($(Get-Asset oracle '9.9.6').sha256)") -and (Test-Manifest "$drv\oracle.toml" oracle '9.9.6'))
  $r = Invoke-Installer "$Site\oracle.ps1"
  $before = [IO.File]::ReadAllText("$drv\oracle.toml")
  $r = Invoke-Installer "$Site\oracle.ps1" @('-Version', '9.9.5')
  Check 'no checksums: refused' ($r.Code -ne 0 -and $r.Out.Contains("Oracle 9.9.5 publishes no checksums (neither SHA256SUMS nor $(Get-Asset oracle '9.9.5').sha256 is in the release)") -and (Test-Unchanged))
  $r = Invoke-Installer "$Site\chargewire.ps1" @('-Version', '9.9.5')
  Check 'no checksums (by tag): refused' ($r.Code -ne 0 -and $r.Out.Contains('Chargewire 9.9.5 publishes no checksums'))
  $r = Invoke-Installer "$Site\oracle.ps1" @('-Version', '9.9.4')
  Check 'SHA256SUMS without the archive: refused' ($r.Code -ne 0 -and $r.Out.Contains("the release's SHA256SUMS has no line for $(Get-Asset oracle '9.9.4')") -and (Test-Unchanged))
  $r = Invoke-Installer "$Site\oracle.ps1" @('-Version', '9.9.3')
  Check 'a DLL for another machine: refused' ($r.Code -ne 0 -and $r.Out.Contains("holds a windows_$other library, and this machine is $platform") -and (Test-Unchanged))
  $r = Invoke-Installer "$Site\oracle.ps1" @('-Version', '9.9.2')
  Check 'no build for this platform' ($r.Code -ne 0 -and $r.Out.Contains("Oracle 9.9.2 has no build for $platform"))
  $r = Invoke-Installer "$Site\oracle.ps1" @('-Version', '1.2.3')
  Check 'a version never released' ($r.Code -ne 0 -and $r.Out.Contains('gizmodata/adbc-driver-oracle has no release v1.2.3'))
  $r = Invoke-Installer "$Site\oracle.ps1" @('-Version', '1.2')
  Check 'a bad version string' ($r.Code -ne 0 -and $r.Out.Contains("must be X.Y.Z or vX.Y.Z (got '1.2')"))
  $saveGh = $gh; $gh = 'http://127.0.0.1:9'
  $r = Invoke-Installer "$Site\oracle.ps1"
  $gh = $saveGh
  Check 'github.com not answering' ($r.Code -ne 0 -and $r.Out.Contains('could not find the latest Oracle release') -and (Test-Unchanged))

  # ---- another driver's manifest, -Name, uninstall -------------------------------------------------
  $foreign = "manifest_version = 1`nname = 'Someone else'`nurl = 'https://example.com/another-oracle-driver'`n[Driver.shared]`nwindows_amd64 = 'C:\\nonexistent\\x.dll'`n"
  [IO.File]::WriteAllText("$drv\oracle.toml", $foreign)
  $r = Invoke-Installer "$Site\oracle.ps1"
  $backups = @(Get-ChildItem -LiteralPath $drv -Filter 'oracle.toml.replaced-*')
  Check "another driver's manifest is backed up and replaced" ($r.Code -eq 0 -and $r.Out.Contains('belonged to another driver (url https://example.com/another-oracle-driver)') -and
    $backups.Count -eq 1 -and [IO.File]::ReadAllText($backups[0].FullName) -eq $foreign -and (Test-Manifest "$drv\oracle.toml" oracle '9.9.9'))
  $restore = ([regex]::Match($r.Out, 'to go back to it: (Move-Item .*)')).Groups[1].Value.Trim()
  & $shell -NoProfile -Command $restore
  Check 'the printed command restores it' ($restore -and [IO.File]::ReadAllText("$drv\oracle.toml") -eq $foreign)
  $r = Invoke-Installer "$Site\oracle.ps1" @('-Name', 'oracle-gizmodata')
  Check '-Name installs side by side' ($r.Code -eq 0 -and [IO.File]::ReadAllText("$drv\oracle.toml") -eq $foreign -and (Test-Manifest "$drv\oracle-gizmodata.toml" oracle '9.9.9'))
  $r = Invoke-Installer "$Site\oracle.ps1" @('-Uninstall') @{ ADBC_NAME = 'oracle-gizmodata' }
  Check '-Name uninstall' ($r.Code -eq 0 -and -not (Test-Path "$drv\oracle-gizmodata.toml") -and -not (Test-Path "$drv\oracle-gizmodata") -and [IO.File]::ReadAllText("$drv\oracle.toml") -eq $foreign)
  $r = Invoke-Installer "$Site\oracle.ps1" @('-Uninstall')
  Check "uninstall leaves another driver's manifest alone" ($r.Code -eq 0 -and $r.Out.Contains('belongs to another driver') -and [IO.File]::ReadAllText("$drv\oracle.toml") -eq $foreign -and -not (Test-Path "$drv\oracle"))
  Remove-Item -LiteralPath "$drv\oracle.toml"
  Get-ChildItem -LiteralPath $drv -Filter 'oracle.toml.replaced-*' | Remove-Item
  $r = Invoke-Installer "$Site\db2.ps1" @() @{ ADBC_UNINSTALL = '1' }
  Check 'uninstall (ADBC_UNINSTALL=1)' ($r.Code -eq 0 -and -not (Test-Path "$drv\db2.toml") -and -not (Test-Path "$drv\db2"))
  $r = Invoke-Installer "$Site\db2.ps1" @('-Uninstall')
  Check 'uninstall again: nothing to remove' ($r.Code -eq 0 -and $r.Out.Contains("Nothing to remove: no Db2 driver named 'db2'"))

  # ---- paths, archives, mirrors, system ----------------------------------------------------------
  $q = Join-Path $root "we'ird dir with spaces"
  $r = Invoke-Installer "$Site\oracle.ps1" @() @{ ADBC_DIR = $q }
  Check 'a -Dir with spaces and a quote' ($r.Code -eq 0 -and (Test-Manifest "$q\oracle.toml" oracle '9.9.9') -and $r.Out.Contains('only when it is on ADBC_DRIVER_PATH'))
  [IO.File]::WriteAllText("$q\oracle.toml", $foreign)
  $r = Invoke-Installer "$Site\oracle.ps1" @('-Dir', $q)
  $restore = ([regex]::Match($r.Out, 'to go back to it: (Move-Item .*)')).Groups[1].Value.Trim()
  & $shell -NoProfile -Command $restore
  Check 'the restore command quotes the path' ($restore -and [IO.File]::ReadAllText("$q\oracle.toml") -eq $foreign)

  $arch1 = Join-Path $root 'archives dir'
  New-Item -ItemType Directory -Force -Path $arch1 | Out-Null
  Copy-Item (Join-Path $fx "chargewire-adbc\v9.9.8\$(Get-Asset chargewire '9.9.8')") $arch1
  Copy-Item (Join-Path $fx "adbc-driver-oracle\v9.9.8\$(Get-Asset oracle '9.9.8')") $arch1
  $saveGh = $gh; $gh = 'http://127.0.0.1:9'
  $r = Invoke-Installer "$Site\chargewire.ps1" @('-Archive', "$arch1\$(Get-Asset chargewire '9.9.8')")
  Check '-Archive (version from the name)' ($r.Code -eq 0 -and (Test-Manifest "$drv\chargewire.toml" chargewire '9.9.8'))
  $r = Invoke-Installer "$Site\oracle.ps1" @('-Archive', "$arch1\$(Get-Asset oracle '9.9.8')")
  Check '-Archive named by OS needs a version' ($r.Code -ne 0 -and $r.Out.Contains("can't tell the version of $(Get-Asset oracle '9.9.8') from its name"))
  $r = Invoke-Installer "$Site\oracle.ps1" @() @{ ADBC_VERSION = '9.9.8'; ADBC_ARCHIVE = "$arch1\$(Get-Asset oracle '9.9.8')" }
  Check 'ADBC_ARCHIVE with ADBC_VERSION' ($r.Code -eq 0 -and (Test-Manifest "$drv\oracle.toml" oracle '9.9.8'))
  $gh = $saveGh
  $r = Invoke-Installer "$Site\gizmosql.ps1" @('-Version', '9.9.8', '-BaseUrl', "$url/storage/gizmodata/gizmosql-adbc/v9.9.8/")
  Check '-BaseUrl mirror' ($r.Code -eq 0 -and (Test-Manifest "$drv\gizmosql.toml" gizmosql '9.9.8'))
  $r = Invoke-Installer "$Site\oracle.ps1" @('-System')
  Check '-System is refused on Windows' ($r.Code -ne 0 -and $r.Out.Contains('the system-wide level on Windows is the registry'))
} finally {
  Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures) { Write-Host "$failures Windows test(s) failed ($shell)" -ForegroundColor Red; exit 1 }
Write-Host "all Windows tests passed ($shell, $platform)" -ForegroundColor Green
# Explicitly: GitHub's pwsh step exits with $LASTEXITCODE, the last (expected) installer failure's.
exit 0
