#Requires -Version 5.1
# Verify that real AppX rejection aborts Inno, returns failure, and removes copied files.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PackageDirectory,
    [Parameter(Mandatory)][string] $IsccPath
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs/OpenInTerminal'
if ((Get-AppxPackage -Name Ryan.OpenInTerminal) -or (Test-Path -LiteralPath $installRoot)) {
    throw 'The installer rollback test requires a clean installation.'
}
$cache = [IO.Path]::GetFullPath((Join-Path $root '.cache'))
$fixture = Join-Path $cache ('installer-rollback-' + [guid]::NewGuid().ToString('N'))
try {
    $package = Join-Path $fixture 'package'
    $null = New-Item -ItemType Directory -Path $package -Force
    Copy-Item -Path (Join-Path $PackageDirectory '*') -Destination $package -Recurse
    [xml] $manifest = Get-Content -LiteralPath (Join-Path $package 'AppxManifest.xml') -Raw
    # Require an unavailable Windows version to make AppX fail without changing system settings.
    $manifest.Package.Dependencies.TargetDeviceFamily.MinVersion = '99.0.0.0'
    $manifest.Package.Dependencies.TargetDeviceFamily.MaxVersionTested = '99.0.0.0'
    $manifest.Save((Join-Path $package 'AppxManifest.xml'))
    $output = Join-Path $fixture 'output'
    & (Join-Path $root 'scripts/build-installer.ps1') -PackageDirectory $package -IsccPath $IsccPath -OutputDirectory $output
    $installer = Get-ChildItem -LiteralPath $output -Filter '*-setup-dev.exe' | Select-Object -First 1
    $log = Join-Path $fixture 'setup.log'
    $process = Start-Process -FilePath $installer.FullName -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG="' + $log + '"')) -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -eq 0) { throw 'Failed registration incorrectly reported installation success.' }
    if (Get-AppxPackage -Name Ryan.OpenInTerminal) { throw 'Failed installation left a package registered.' }
    if (Test-Path -LiteralPath $installRoot) { throw 'Failed installation did not roll back copied files.' }
    if (Test-Path -LiteralPath 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Uninstall/{895962A4-9AA3-44AC-B5EB-33044CF05043}_is1') {
        throw 'Failed installation left an uninstall entry.'
    }
    if (-not (Select-String -LiteralPath $log -SimpleMatch 'Rolling back changes.')) { throw 'Inno did not report rolling back the failed installation.' }
    Write-Host "Installer registration-failure rollback passed (exit code $($process.ExitCode))."
} finally {
    if ($log -and (Test-Path -LiteralPath $log)) {
        Copy-Item -LiteralPath $log -Destination (Join-Path $cache 'installer-rollback-last.log') -Force
    }
    $target = [IO.Path]::GetFullPath($fixture)
    if ((Split-Path $target -Parent) -ne $cache -or (Split-Path $target -Leaf) -notmatch '^installer-rollback-[0-9a-f]{32}$') {
        throw 'Unexpected rollback test path.'
    }
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
}
