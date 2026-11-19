# Every driver's real latest release on Windows, installed by its own script (as a file, and for
# oracle also the way `irm | iex` runs it), loaded by name through the ADBC driver manager
# (check_driver_by_name.py), then uninstalled. The Windows twin of real-release.sh: see its header
# for how each driver's expected outcome is decided, including gizmosql, chargewire and hardcharger,
# whose latest releases have no checksums yet, so they must be refused until a release with
# SHA256SUMS ships (then this expects, and checks, a real install).
#
# It installs into this user's real %LOCALAPPDATA%\ADBC\Drivers (the driver manager reads the known
# folder, not the environment variable): run it on a throwaway CI machine.
#
#   pwsh -File .github/scripts/windows-real-release.ps1 -Site site -Python <python with adbc-driver-manager>
param([Parameter(Mandatory = $true)][string]$Site, [Parameter(Mandatory = $true)][string]$Python)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
$Site = (Resolve-Path -LiteralPath $Site).Path
$shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
$here = $PSScriptRoot
$failures = 0
$cpu = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE
$arch = if ($cpu -eq 'ARM64') { 'arm64' } else { 'amd64' }
$platform = "windows_$arch"
$drv = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'ADBC\Drivers'
Write-Host "shell: $shell $($PSVersionTable.PSVersion); platform: $platform; drivers dir: $drv"
& $Python -c 'import adbc_driver_manager, sys; print(sys.version.split()[0], "adbc_driver_manager", adbc_driver_manager.__version__)'
if ($LASTEXITCODE) { Write-Host "::error::$Python has no adbc_driver_manager"; exit 1 }

$repos = [ordered]@{ oracle = 'adbc-driver-oracle'; db2 = 'adbc-driver-db2'; quack = 'adbc-driver-quack'; gizmosql = 'gizmosql-adbc'; chargewire = 'chargewire-adbc'; hardcharger = 'hardcharger-adbc' }
# The Windows builds each driver's releases have (as of their latest releases, 2026-11-18).
$builds = @{ oracle = @('windows_amd64', 'windows_arm64'); db2 = @('windows_amd64'); quack = @('windows_amd64', 'windows_arm64')
  gizmosql = @('windows_amd64', 'windows_arm64'); chargewire = @('windows_amd64', 'windows_arm64'); hardcharger = @('windows_amd64', 'windows_arm64') }

function Bad([string]$m) { Write-Host "::error::${d}: $m"; $script:failures++ }
# github.com answers a release file that exists with a redirect to its storage, one that doesn't with 404.
function Test-Exists([string]$url) {
  for ($try = 1; $try -le 5; $try++) {
    try {
      $req = [Net.HttpWebRequest]::Create($url); $req.Method = 'HEAD'; $req.AllowAutoRedirect = $false
      $resp = $req.GetResponse(); $code = [int]$resp.StatusCode; $resp.Close()
    } catch { $code = if ($_.Exception.InnerException.Response) { [int]$_.Exception.InnerException.Response.StatusCode } elseif ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 } }
    if ($code -eq 302) { return $true }
    if ($code -eq 404) { return $false }
    Start-Sleep -Seconds (3 * $try)
  }
  Write-Host "::error::couldn't tell whether $url exists (HTTP $code)"; exit 1
}
function Get-Latest([string]$repo) {
  $req = [Net.HttpWebRequest]::Create("https://github.com/$repo/releases/latest"); $req.Method = 'HEAD'
  $resp = $req.GetResponse(); try { return $resp.ResponseUri.AbsoluteUri } finally { $resp.Close() }
}
function Invoke-Installer([string]$d, [string[]]$installerArgs = @(), [hashtable]$envs = @{}, [switch]$Iex) {
  $saved = @{}
  foreach ($k in $envs.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $envs[$k]) }
  try {
    if ($Iex) { $out = & $shell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -Raw -LiteralPath '$Site\$d.ps1' | Invoke-Expression" 2>&1 | Out-String }
    else { $out = & $shell -NoProfile -ExecutionPolicy Bypass -File "$Site\$d.ps1" @installerArgs 2>&1 | Out-String }
    $code = $LASTEXITCODE
  } finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
  Write-Host ($out -replace '(?m)^', '  | ')
  $script:last = $out
  return ($code -eq 0)
}
function Test-ByName([string[]]$a) { & $Python -I "$here\check_driver_by_name.py" --driver $d @a 2>&1 | Write-Host; return ($LASTEXITCODE -eq 0) }

foreach ($d in $repos.Keys) {
  Write-Host "`n### $d"
  $repo = "gizmodata/$($repos[$d])"
  $latest = Get-Latest $repo
  if ($latest -notmatch '/releases/tag/(v[^/]+)$') { Bad "no latest release ($latest)"; continue }
  $tag = $Matches[1]; $ver = $tag.Substring(1)
  # Every run of the installer below asks for the release probed here (a release published while
  # this runs would otherwise be installed instead); oracle's first install looks up the latest.
  $pin = @{ ADBC_VERSION = $ver }
  $asset = if ($d -in @('oracle', 'db2', 'quack')) { "libadbc_driver_$d-windows-$arch.tar.gz" } else { "libadbc_driver_$d-$tag-$platform.tar.gz" }
  $base = "https://github.com/$repo/releases/download/$tag"
  $listed = $builds[$d] -contains $platform

  if (-not (Test-Exists "$base/$asset")) {
    if ($listed) { Bad "$tag has no $asset, and $d has had $platform builds"; continue }
    Write-Host "$d $tag has no $platform build: the installer must say so"
    if (Invoke-Installer $d -envs $pin) { Bad "the installer succeeded without a $platform build"; continue }
    if (-not $last.Contains("$ver has no build for $platform")) { Bad "refused, but not with 'has no build for $platform'" }
    continue
  }
  if (-not $listed) { Write-Host "note: $d $tag now has a $platform build; add it to `$builds" }

  if (-not (Test-Exists "$base/SHA256SUMS") -and -not (Test-Exists "$base/$asset.sha256")) {
    if ($d -notin @('gizmosql', 'chargewire', 'hardcharger')) { Bad "$tag publishes no checksums; $d's releases have had them"; continue }
    # Expected until the driver's first release with SHA256SUMS (see real-release.sh's header).
    Write-Host "$d $tag has no checksums yet: the installer must refuse it"
    if (Invoke-Installer $d -envs $pin) { Bad "the installer installed $tag without checksums"; continue }
    if (-not $last.Contains("publishes no checksums (neither SHA256SUMS nor $asset.sha256 is in the release), and this installer never installs files it cannot verify")) { Bad 'refused, but not for the missing checksums' }
    if (Test-Path -LiteralPath "$drv\$d.toml") { Bad 'a manifest was written anyway' }
    if (-not (Test-ByName @('--absent'))) { Bad "'$d' loads although nothing was installed" }
    continue
  }

  Write-Host "$d ${tag}: install, load by name, uninstall"
  if (-not (Test-ByName @('--absent'))) { Bad "'$d' was found before installing" }
  $first = if ($d -eq 'oracle') { @{} } else { $pin }
  if (-not (Invoke-Installer $d -envs $first)) { Bad 'the installer failed'; continue }
  foreach ($want in @('Checksum OK (', "library:  $drv\$d\$ver\libadbc_driver_$d.dll", "manifest: $drv\$d.toml", "driver = `"$d`"")) {
    if (-not $last.Contains($want)) { Bad "no '$want' in the output" }
  }
  & $Python -I "$here\check_manifest.py" --manifest "$drv\$d.toml" --driver $d --version $ver --platform $platform 2>&1 | Write-Host
  if ($LASTEXITCODE) { Bad 'manifest' }
  if (-not (Test-ByName @())) { Bad "'$d' does not load by name" }

  if ($d -eq 'oracle') {
    Write-Host "-- oracle: irm | iex with `$env:ADBC_VERSION = '$ver'"
    if (-not (Invoke-Installer $d -Iex -envs @{ ADBC_VERSION = $ver })) { Bad 'the iex form failed' }
    if (-not (Test-ByName @())) { Bad "'oracle' does not load after the iex install" }
    Write-Host "-- oracle: another driver's oracle.toml is backed up, replaced, and restored"
    $foreign = "manifest_version = 1`nname = 'Another Oracle driver'`nurl = 'https://example.com/another-oracle-driver'`n[Driver]`nshared = 'C:\\nonexistent\\another.dll'`n"
    [IO.File]::WriteAllText("$drv\oracle.toml", $foreign)
    if (-not (Invoke-Installer $d)) { Bad 'install over another manifest failed' }
    if (-not (Test-ByName @())) { Bad "'oracle' does not load after replacing another driver's manifest" }
    $restore = ([regex]::Match($last, 'to go back to it: (Move-Item .*)')).Groups[1].Value.Trim()
    & $shell -NoProfile -Command $restore
    if (-not $restore -or [IO.File]::ReadAllText("$drv\oracle.toml") -ne $foreign) { Bad "the restore command didn't restore the other manifest" }
    Write-Host '-- oracle: -Name oracle-gizmodata side by side with it'
    if (-not (Invoke-Installer $d @('-Name', 'oracle-gizmodata'))) { Bad '-Name install failed' }
    if ([IO.File]::ReadAllText("$drv\oracle.toml") -ne $foreign) { Bad "-Name touched the other driver's manifest" }
    if (-not (Test-ByName @('--name', 'oracle-gizmodata'))) { Bad "'oracle-gizmodata' does not load the Oracle driver" }
    if (-not (Invoke-Installer $d @('-Name', 'oracle-gizmodata', '-Uninstall'))) { Bad '-Name uninstall failed' }
    if (-not (Test-ByName @('--name', 'oracle-gizmodata', '--absent'))) { Bad "'oracle-gizmodata' still loads after uninstall" }
    Remove-Item -LiteralPath "$drv\oracle.toml"
    Get-ChildItem -LiteralPath $drv -Filter 'oracle.toml.replaced-*' | Remove-Item
    if (-not (Invoke-Installer $d)) { Bad 'reinstall failed' }
  }

  if (-not (Invoke-Installer $d @('-Uninstall'))) { Bad 'uninstall failed' }
  if (-not (Test-ByName @('--absent'))) { Bad "'$d' still loads after uninstall" }
  if (Test-Path -LiteralPath "$drv\$d") { Bad "$drv\$d is still there" }
}

if ($failures) { Write-Host "$failures real-release check(s) failed ($shell)" -ForegroundColor Red; exit 1 }
Write-Host "all real-release checks passed ($shell, $platform)" -ForegroundColor Green
# Explicitly: GitHub's pwsh step exits with $LASTEXITCODE, the last (expected) installer failure's.
exit 0
