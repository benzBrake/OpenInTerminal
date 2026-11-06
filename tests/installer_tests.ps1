#Requires -Version 5.1
# Exercise deployment failures without changing the real AppX registration or registry.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('OpenInTerminal-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture
$global:oitInstallerTest = @{}
function Assert($condition, [string] $message) { if (-not $condition) { throw $message } }
function Get-ItemProperty { [pscustomobject]@{ AllowDevelopmentWithoutDevLicense = $global:oitInstallerTest.developerMode } }
function Get-AppxPackage { param($Name) $global:oitInstallerTest.installed }
function Get-Content {
    param($LiteralPath, [switch]$Raw)
    if ($LiteralPath -eq 'C:\Previous\AppxManifest.xml') { return $global:oitInstallerTest.previousManifest }
    Microsoft.PowerShell.Management\Get-Content -LiteralPath $LiteralPath -Raw:$Raw
}
function Test-Path {
    param($LiteralPath)
    if ($LiteralPath -like 'HKCU:*') { return $false }
    Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
}
function New-Item { param($Path, [switch]$Force) throw 'Simulated registry failure' }
function Remove-AppxPackage { param([Parameter(ValueFromPipeline)]$Package) process { $global:oitInstallerTest.events.Add('remove'); $global:oitInstallerTest.installed = $null } }
function Add-AppxPackage {
    param([switch]$Register, $Path, $ExternalLocation, [switch]$ForceTargetApplicationShutdown)
    $global:oitInstallerTest.events.Add($Path)
    $global:oitInstallerTest.locations.Add([string]$ExternalLocation)
    if ($global:oitInstallerTest.failDeployment -and $Path -ne 'C:\Previous\AppxManifest.xml') { throw 'Simulated deployment failure' }
    if ($Register -and $Path -eq 'C:\Previous\AppxManifest.xml') { $global:oitInstallerTest.installed = $global:oitInstallerTest.previous }
    else { $global:oitInstallerTest.installed = [pscustomobject]@{ InstallLocation = 'C:\Replacement' } }
}
try {
    $manifest = [IO.File]::ReadAllText((Join-Path $root 'packaging/AppxManifest.xml')).Replace('@ARCH@','x64').Replace('@VERSION@','0.1.0.0').Replace('@PUBLISHER@','CN=OpenInTerminal')
    [IO.File]::WriteAllText((Join-Path $fixture 'AppxManifest.xml'), $manifest)
    $global:oitInstallerTest.developerMode = 1
    # Exercise migration rollback to a legacy manifest without external content.
    $global:oitInstallerTest.previousManifest = $manifest -replace '<uap10:AllowExternalContent>true</uap10:AllowExternalContent>', ''
    $global:oitInstallerTest.previous = [pscustomobject]@{ Publisher = 'CN=OpenInTerminal'; Version = '0.1.0.0'; IsDevelopmentMode = $true; InstallLocation = 'C:\Previous' }
    $global:oitInstallerTest.installed = $global:oitInstallerTest.previous
    $global:oitInstallerTest.failDeployment = $true
    $global:oitInstallerTest.events = [Collections.Generic.List[string]]::new()
    $global:oitInstallerTest.locations = [Collections.Generic.List[string]]::new()
    $failed = $false
    try { & (Join-Path $root 'scripts/install.ps1') -PackageDirectory $fixture -RegisterInPlace }
    catch { $failed = $_.Exception.Message -eq 'Simulated deployment failure' }
    Assert $failed 'A failed deployment must propagate its error.'
    Assert ($global:oitInstallerTest.events.Count -eq 3 -and $global:oitInstallerTest.events[0] -eq 'remove' -and $global:oitInstallerTest.events[2] -eq 'C:\Previous\AppxManifest.xml') 'Equal-version failure must restore the previous registration.'
    Assert ($global:oitInstallerTest.installed -eq $global:oitInstallerTest.previous) 'The old package must remain installed after rollback.'
    Assert ($global:oitInstallerTest.locations[0] -eq $fixture) 'Development registration must associate the external payload location.'
    Assert ($global:oitInstallerTest.locations[1] -eq '') 'Rollback to a legacy manifest must omit ExternalLocation.'

    $global:oitInstallerTest.previousManifest = $manifest
    $global:oitInstallerTest.events.Clear()
    $global:oitInstallerTest.locations.Clear()
    try { & (Join-Path $root 'scripts/install.ps1') -PackageDirectory $fixture -RegisterInPlace } catch {}
    Assert ($global:oitInstallerTest.installed -eq $global:oitInstallerTest.previous -and $global:oitInstallerTest.locations[1] -eq 'C:\Previous') 'Rollback to an external-location package must restore its external directory.'

    $global:oitInstallerTest.previous.Version = '0.0.9.0'
    $global:oitInstallerTest.events.Clear()
    try { & (Join-Path $root 'scripts/install.ps1') -PackageDirectory $fixture -RegisterInPlace } catch {}
    Assert ($global:oitInstallerTest.events.Count -eq 1 -and $global:oitInstallerTest.events[0] -ne 'remove') 'Version upgrades must not remove the old package before deployment.'

    $global:oitInstallerTest.developerMode = 0
    $global:oitInstallerTest.events.Clear()
    $failed = $false
    try { & (Join-Path $root 'scripts/install.ps1') -PackageDirectory $fixture -RegisterInPlace }
    catch { $failed = $_.Exception.Message -match 'Developer Mode' }
    Assert ($failed -and $global:oitInstallerTest.events.Count -eq 0) 'Missing Developer Mode must fail before touching registration.'

    $signed = Join-Path $fixture 'test.msix'
    Set-Content -LiteralPath $signed -Value 'Invalid package used to simulate deployment failure'
    $global:oitInstallerTest.events.Clear()
    $global:oitInstallerTest.locations.Clear()
    $failed = $false
    try { & (Join-Path $root 'scripts/install.ps1') -PackageDirectory $fixture -SignedMsixPath $signed -RegisterInPlace }
    catch { $failed = $_.Exception.Message -eq 'Simulated deployment failure' }
    Assert ($failed -and $global:oitInstallerTest.events.Count -eq 1 -and $global:oitInstallerTest.events[0] -eq $signed) 'Signed deployment must bypass Developer Mode and leave the previous package on failure.'
    Assert ($global:oitInstallerTest.locations[0] -eq $fixture) 'Signed deployment must associate the external payload location.'

    $global:oitInstallerTest.developerMode = 1
    $global:oitInstallerTest.failDeployment = $false
    $global:oitInstallerTest.events.Clear()
    $failed = $false
    try { & (Join-Path $root 'scripts/install.ps1') -PackageDirectory $fixture -RegisterInPlace -IncludeClassicMenu }
    catch { $failed = $_.Exception.Message -eq 'Simulated registry failure' }
    Assert ($failed -and $global:oitInstallerTest.installed -eq $global:oitInstallerTest.previous) 'Classic-menu failure must restore the previous development package before Inno rolls back its files.'
    Write-Host 'Installer deployment tests passed'
} finally {
    Remove-Variable -Name oitInstallerTest -Scope Global
    $target = [IO.Path]::GetFullPath($fixture)
    if ((Split-Path $target -Parent) -ne ([IO.Path]::GetTempPath()).TrimEnd('\') -or (Split-Path $target -Leaf) -notmatch '^OpenInTerminal-tests-[0-9a-f]{32}$') { throw 'Unexpected fixture path.' }
    Remove-Item -LiteralPath $target -Recurse -Force
}
