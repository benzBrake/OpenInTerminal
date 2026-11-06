#Requires -Version 5.1
# Private entry point used by Inno Setup; turn all deployment errors into a failing exit code.
[CmdletBinding()]
param(
    [ValidateSet('Install','Uninstall')][string] $Action = 'Install',
    [string] $PackageDirectory,
    [string] $SignedMsixPath,
    [switch] $IncludeClassicMenu,
    [Parameter(Mandatory)][string] $LogPath
)
$ErrorActionPreference = 'Stop'
# Setup may inherit PowerShell 7's module search path via its parent process.
# This private Windows PowerShell child needs only the matching Windows system modules.
$env:PSModulePath = Join-Path $PSHOME 'Modules'
try {
    Start-Transcript -LiteralPath $LogPath -Force | Out-Null
    Write-Host "Windows PowerShell home: $PSHOME; 64-bit process: $([Environment]::Is64BitProcess)"
    if (-not [Environment]::Is64BitProcess) { throw 'Context menu registration requires native 64-bit Windows PowerShell.' }
    if ($Action -eq 'Uninstall') {
        & (Join-Path $PSScriptRoot 'uninstall.ps1') -KeepFiles
    } else {
        & (Join-Path $PSScriptRoot 'install.ps1') -PackageDirectory $PackageDirectory `
            -SignedMsixPath $SignedMsixPath -RegisterInPlace `
            -IncludeClassicMenu:$IncludeClassicMenu -RemoveClassicMenu:(!$IncludeClassicMenu)
    }
} catch {
    Write-Host ($_ | Out-String)
    exit 1
} finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
