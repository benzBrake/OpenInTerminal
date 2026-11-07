#Requires -Version 5.1
[CmdletBinding()]
param([switch] $KeepFiles)
$ErrorActionPreference = 'Stop'
$packages = @(Get-AppxPackage -Name 'Ryan.OpenInTerminal')
foreach ($package in $packages) {
    $payload = & (Join-Path $PSScriptRoot 'get-package-location.ps1') -Package $package
    foreach ($location in @($payload, $package.InstallLocation) | Select-Object -Unique) {
        & (Join-Path $PSScriptRoot 'stop-extension-host.ps1') -DllPath (Join-Path $location 'OpenInTerminal.dll')
    }
}
foreach ($package in $packages) {
    # Deployment can transiently fail to load a Windows extension handler even
    # though our payload is intact. Retry only that failure, retaining all files
    # and registry entries if Windows still cannot remove the package.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $package | Remove-AppxPackage
            break
        } catch {
            if (-not (Get-AppxPackage -Name 'Ryan.OpenInTerminal')) { break }
            if ($attempt -eq 3 -or ($_ | Out-String) -notmatch '(?i)0x8007007e') { throw }
            Write-Warning "Windows could not load a deployment extension; retrying package removal ($attempt/3)."
            Start-Sleep -Seconds 1
        }
    }
}
if (Get-AppxPackage -Name 'Ryan.OpenInTerminal') {
    throw 'Windows still reports Open In Terminal as registered. Installation files have been preserved; retry uninstalling.'
}
foreach ($type in @('Directory','Directory/Background','Drive')) {
    $key = "HKCU:/Software/Classes/$type/shell/OpenInTerminal"
    if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force }
}
$com = 'HKCU:/Software/Classes/CLSID/{A763E1D5-05EB-43A3-9C82-7DA5B86F6B41}'
if (Test-Path -LiteralPath $com) { Remove-Item -LiteralPath $com -Recurse -Force }
# Verify the exact destination before removing this application's files.
$programs = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs'))
$target = [IO.Path]::GetFullPath((Join-Path $programs 'OpenInTerminal'))
if ((Split-Path $target -Parent) -ne $programs -or (Split-Path $target -Leaf) -ne 'OpenInTerminal') { throw 'Unexpected installation path.' }
if (-not $KeepFiles -and (Test-Path -LiteralPath $target)) {
    try { Remove-Item -LiteralPath $target -Recurse -Force }
    catch { Write-Warning "Menu registration removed; close Explorer windows before deleting locked files in $target" }
}
Write-Host 'Open In Terminal unregistered. Your Terminal settings and old menu entries are preserved.'

