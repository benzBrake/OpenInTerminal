#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $PackageDirectory,
    [string] $SignedMsixPath,
    [switch] $RegisterInPlace,
    [switch] $IncludeClassicMenu,
    [switch] $RemoveClassicMenu
)
$ErrorActionPreference = 'Stop'
if (-not $PackageDirectory) { $PackageDirectory = Join-Path $PSScriptRoot '../dist/package' }
if ($IncludeClassicMenu -and $RemoveClassicMenu) { throw 'Choose only one classic menu option.' }
$source = (Resolve-Path -LiteralPath $PackageDirectory).Path
if (-not (Test-Path -LiteralPath (Join-Path $source 'AppxManifest.xml'))) {
    throw 'Run scripts/package.ps1 first, or pass -PackageDirectory from a downloaded build.'
}
[xml] $manifest = Get-Content -LiteralPath (Join-Path $source 'AppxManifest.xml') -Raw
if ($manifest.Package.Identity.Name -ne 'Ryan.OpenInTerminal') { throw 'Unexpected package identity.' }
$externalContent = $manifest.Package.Properties.GetElementsByTagName('AllowExternalContent', 'http://schemas.microsoft.com/appx/manifest/uap/windows10/10')
$usesExternalLocation = $externalContent.Count -eq 1 -and $externalContent[0].InnerText -eq 'true'
# Rollback may restore an older, ordinary package that does not allow external content.
function Register-DevelopmentPackage([string] $ManifestPath) {
    [xml] $registrationManifest = Get-Content -LiteralPath $ManifestPath -Raw
    $external = $registrationManifest.Package.Properties.GetElementsByTagName('AllowExternalContent', 'http://schemas.microsoft.com/appx/manifest/uap/windows10/10')
    $arguments = @{ Register = $true; Path = $ManifestPath; ForceTargetApplicationShutdown = $true }
    if ($external.Count -eq 1 -and $external[0].InnerText -eq 'true') {
        $arguments.ExternalLocation = Split-Path -Parent $ManifestPath
    }
    Add-AppxPackage @arguments
}
$development = Get-ItemProperty 'HKLM:/SOFTWARE/Microsoft/Windows/CurrentVersion/AppModelUnlock' -ErrorAction SilentlyContinue
if (-not $SignedMsixPath -and $development.AllowDevelopmentWithoutDevLicense -ne 1) {
    throw 'Unsigned development installation requires Windows Developer Mode. Alternatively, sign the MSIX with a trusted certificate and install it.'
}
# Include manifest/CLI/assets so packaging-only fixes also install as a new build.
$hashText = (Get-ChildItem -LiteralPath $source -File -Recurse | Sort-Object FullName | ForEach-Object {
    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
}) -join ''
$hasher = [Security.Cryptography.SHA256]::Create()
try { $hash = ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($hashText)))).Replace('-','').Substring(0,16).ToLowerInvariant() }
finally { $hasher.Dispose() }
$destination = if ($RegisterInPlace) { $source } else { Join-Path $env:LOCALAPPDATA "Programs/OpenInTerminal/$hash" }
$existing = Get-AppxPackage -Name 'Ryan.OpenInTerminal'
if (@($existing).Count -gt 1) { throw 'Multiple package identities are installed. Uninstall older identities before updating.' }
if ($existing -and $existing.Publisher -ne $manifest.Package.Identity.Publisher) {
    throw 'The installed package has a different Publisher. Uninstall it before changing signing identity.'
}
if (-not $SignedMsixPath -and $existing -and -not $existing.IsDevelopmentMode) {
    throw 'Uninstall the signed package before switching to a development installation.'
}
$classicCom = 'HKCU:/Software/Classes/CLSID/{A763E1D5-05EB-43A3-9C82-7DA5B86F6B41}/InprocServer32'
$previousClassicDll = $null
if (($IncludeClassicMenu -or $RemoveClassicMenu) -and (Test-Path -LiteralPath $classicCom)) {
    $previousClassicDll = (Get-Item -LiteralPath $classicCom).GetValue('')
}
if ($existing -and ($SignedMsixPath -or $existing.InstallLocation -ne $destination)) {
    $existingLocation = & (Join-Path $PSScriptRoot 'get-package-location.ps1') -Package $existing
    foreach ($location in @($existingLocation, $existing.InstallLocation) | Select-Object -Unique) {
        & (Join-Path $PSScriptRoot 'stop-extension-host.ps1') -DllPath (Join-Path $location 'OpenInTerminal.dll')
    }
}
if ($SignedMsixPath) {
    if ($usesExternalLocation -and -not $RegisterInPlace) {
        $null = New-Item -ItemType Directory -Force -Path $destination
        Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force
    }
    # AppX deployment handles replacement transactionally; never remove the working package first.
    $arguments = @{ Path = (Resolve-Path -LiteralPath $SignedMsixPath).Path; ForceTargetApplicationShutdown = $true }
    if ($usesExternalLocation) { $arguments.ExternalLocation = $destination }
    Add-AppxPackage @arguments
    $destination = & (Join-Path $PSScriptRoot 'get-package-location.ps1') -Package (Get-AppxPackage -Name 'Ryan.OpenInTerminal')
    if (-not $destination) { throw 'The installed MSIX package could not be located.' }
} elseif ($existing -and $existing.InstallLocation -eq $destination) {
    Write-Host "This build is already installed: $destination"
} else {
    if (-not $RegisterInPlace) {
        $null = New-Item -ItemType Directory -Force -Path $destination
        Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force
    }
    # Windows silently retains the old directory for an equal-version development registration.
    # Only this case needs removal; retain its manifest so a failed replacement can be restored.
    $restoreManifest = $null
    if ($existing -and [version]$existing.Version -eq [version]$manifest.Package.Identity.Version) {
        $restoreManifest = Join-Path $existing.InstallLocation 'AppxManifest.xml'
        $existing | Remove-AppxPackage
    }
    try {
        Register-DevelopmentPackage (Join-Path $destination 'AppxManifest.xml')
    } catch {
        $failure = $_
        if ($restoreManifest) {
            try { Register-DevelopmentPackage $restoreManifest }
            catch { Write-Warning "Could not restore the previous package: $_" }
        }
        throw $failure
    }
}
function Set-ClassicMenuRegistration([string] $DllPath) {
    $clsid = '{A763E1D5-05EB-43A3-9C82-7DA5B86F6B41}'
    if (-not $DllPath) {
        foreach ($type in @('Directory','Directory/Background','Drive')) {
            $key = "HKCU:/Software/Classes/$type/shell/OpenInTerminal"
            if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force }
        }
        $com = "HKCU:/Software/Classes/CLSID/$clsid"
        if (Test-Path -LiteralPath $com) { Remove-Item -LiteralPath $com -Recurse -Force }
        return
    }
    $com = "HKCU:/Software/Classes/CLSID/$clsid/InprocServer32"
    $null = New-Item -Path $com -Force
    Set-Item -LiteralPath $com -Value $DllPath
    $null = New-ItemProperty -Path $com -Name ThreadingModel -Value Apartment -Force
    foreach ($type in @('Directory','Directory/Background','Drive')) {
        $key = "HKCU:/Software/Classes/$type/shell/OpenInTerminal"
        $null = New-Item -Path $key -Force
        $null = New-ItemProperty -Path $key -Name MUIVerb -Value 'Open In Terminal' -Force
        $null = New-ItemProperty -Path $key -Name ExplorerCommandHandler -Value $clsid -Force
    }
}
try {
    if ($IncludeClassicMenu) { Set-ClassicMenuRegistration (Join-Path $destination 'OpenInTerminal.dll') }
    elseif ($RemoveClassicMenu) { Set-ClassicMenuRegistration '' }
} catch {
    $failure = $_
    # Inno will roll back payload files: do not leave a development registration pointing at them.
    try {
        if (-not $existing) { Get-AppxPackage -Name 'Ryan.OpenInTerminal' | Remove-AppxPackage }
        elseif (-not $SignedMsixPath -and $existing.InstallLocation -ne $destination) {
            Get-AppxPackage -Name 'Ryan.OpenInTerminal' | Remove-AppxPackage
            Register-DevelopmentPackage (Join-Path $existing.InstallLocation 'AppxManifest.xml')
        }
        Set-ClassicMenuRegistration $previousClassicDll
    } catch { Write-Warning "Could not completely restore the previous installation: $_" }
    throw $failure
}
Write-Host "Installed: $destination"
Write-Host 'Open a new File Explorer window. Hold Ctrl while clicking a profile to run as administrator.'

