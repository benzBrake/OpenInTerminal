#Requires -Version 5.1
# Run only on a disposable Windows CI runner with Developer Mode already enabled.
[CmdletBinding()]
param([Parameter(Mandatory)][string] $InstallerPath)
$ErrorActionPreference = 'Stop'
if (Get-AppxPackage -Name 'Ryan.OpenInTerminal') { throw 'Refusing to replace an existing installation in an installer smoke test.' }
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs/OpenInTerminal'
if (Test-Path -LiteralPath $installRoot) { throw 'The installer smoke test requires a clean installation directory.' }
$InstallerPath = (Resolve-Path -LiteralPath $InstallerPath).Path
function Run-Setup([string] $Executable, [string[]] $Arguments) {
    $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Installer process failed ($($process.ExitCode)): $Executable" }
}
try {
    Run-Setup $InstallerPath @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/TASKS=classic')
    $package = Get-AppxPackage -Name 'Ryan.OpenInTerminal'
    if (-not $package) { throw 'Installer did not register the package.' }
    $null = [Windows.Management.Deployment.PackageManager,Windows.Management.Deployment,ContentType=WindowsRuntime]
    $manager = [Windows.Management.Deployment.PackageManager]::new()
    $identity = $manager.FindPackageForUser('', $package.PackageFullName)
    if (-not $identity.EffectiveExternalLocation.Path) { throw 'Identity package must use an external location to hide its duplicate uninstall entry.' }
    $payload = & (Join-Path $installRoot 'scripts/get-package-location.ps1') -Package $package
    if ($payload -ne $identity.EffectiveExternalLocation.Path) { throw 'Installer must resolve the external payload directory.' }
    $uninstallKey = 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Uninstall/{895962A4-9AA3-44AC-B5EB-33044CF05043}_is1'
    $iconPath = (Get-ItemProperty -LiteralPath $uninstallKey).DisplayIcon
    if ($iconPath -ne (Join-Path $installRoot 'OpenInTerminal.ico')) { throw 'Uninstall entry must use the installed application icon.' }
    Add-Type -AssemblyName System.Drawing
    $icon = [Drawing.Icon]::new($iconPath)
    $icon.Dispose()
    $classic = 'HKCU:/Software/Classes/Directory/shell/OpenInTerminal'
    if (-not (Test-Path -LiteralPath $classic)) { throw 'Installer did not register the optional classic menu.' }
    & (Join-Path $payload 'OpenInTerminalCli.exe') --diagnose
    if ($LASTEXITCODE -ne 0) { throw 'Installed packaged COM activation failed.' }
    # Reinstall after COM activation to catch attempts to overwrite an already-loaded payload.
    Run-Setup $InstallerPath @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/TASKS=classic')
    Run-Setup (Join-Path $installRoot 'unins000.exe') @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
    if (Get-AppxPackage -Name 'Ryan.OpenInTerminal') { throw 'Uninstaller left the package registered.' }
    if (Test-Path -LiteralPath $classic) { throw 'Uninstaller left the classic menu registered.' }
    if (Test-Path -LiteralPath $installRoot) { throw 'Uninstaller left its installation directory behind.' }
    if (Test-Path -LiteralPath $uninstallKey) { throw 'Uninstaller left its uninstall entry behind.' }
    Write-Host 'Installer install/reinstall/COM/uninstall smoke test passed'
} finally {
    # Retain deployment transcripts in CI output, including on failure.
    foreach ($name in @('install.log','uninstall.log')) {
        $log = Join-Path $env:LOCALAPPDATA "OpenInTerminal/$name"
        if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log }
    }
}
