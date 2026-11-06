#Requires -Version 5.1
# Get-AppxPackage.InstallLocation points into WindowsApps for signed packages;
# an external-location package loads this application's payload from the installer.
[CmdletBinding()]
param([Parameter(Mandatory)] $Package)
$ErrorActionPreference = 'Stop'
if ($Package.PackageFullName) {
    $null = [Windows.Management.Deployment.PackageManager,Windows.Management.Deployment,ContentType=WindowsRuntime]
    $manager = [Windows.Management.Deployment.PackageManager]::new()
    $registered = $manager.FindPackageForUser('', $Package.PackageFullName)
    if ($registered -and $registered.EffectiveExternalLocation.Path) {
        return $registered.EffectiveExternalLocation.Path
    }
}
return $Package.InstallLocation
