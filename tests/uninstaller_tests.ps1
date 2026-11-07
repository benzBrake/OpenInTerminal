#Requires -Version 5.1
# Simulate AppX failures without changing installed packages or user registry.
$ErrorActionPreference = 'Stop'
$global:oitUninstallerTest = @{}
$global:oitUninstallerTest.package = [pscustomobject]@{ InstallLocation = 'C:\OpenInTerminal-uninstaller-test-missing' }
function Assert($condition, [string] $message) { if (-not $condition) { throw $message } }
function Get-AppxPackage { param($Name) if ($global:oitUninstallerTest.registered) { $global:oitUninstallerTest.package } }
function Test-Path { param($LiteralPath) return $false }
function Start-Sleep { param($Seconds) $global:oitUninstallerTest.waits++ }
function Remove-Item { throw 'Cleanup must not run in these fixtures.' }
function Remove-AppxPackage {
    param([Parameter(ValueFromPipeline)] $Package)
    process {
        $global:oitUninstallerTest.calls++
        if ($global:oitUninstallerTest.calls -le $global:oitUninstallerTest.failures) { throw $global:oitUninstallerTest.failure }
        if (-not $global:oitUninstallerTest.leaveRegistered) { $global:oitUninstallerTest.registered = $false }
    }
}
$uninstall = Join-Path $PSScriptRoot '../scripts/uninstall.ps1'
foreach ($case in @(
    @{ failures = 1; error = 'Deployment failed: 0x80073CF6; extension DLL: 0x8007007E'; calls = 2; fails = $false },
    @{ failures = 3; error = 'Extension DLL: 0x8007007E'; calls = 3; fails = $true },
    @{ failures = 1; error = 'Access denied: 0x80070005'; calls = 1; fails = $true },
    @{ failures = 0; error = ''; calls = 1; fails = $true; leaveRegistered = $true }
)) {
    $global:oitUninstallerTest.registered = $true
    $global:oitUninstallerTest.calls = 0
    $global:oitUninstallerTest.waits = 0
    $global:oitUninstallerTest.failures = $case.failures
    $global:oitUninstallerTest.failure = $case.error
    $global:oitUninstallerTest.leaveRegistered = $case.leaveRegistered
    $failed = $false
    try { & $uninstall -KeepFiles } catch { $failed = $true }
    Assert ($failed -eq $case.fails) 'Uninstall must propagate persistent failures and verify removal.'
    Assert ($global:oitUninstallerTest.calls -eq $case.calls) 'Only the transient missing-module error should be retried, at most three times.'
    Assert ($global:oitUninstallerTest.waits -eq ($case.calls - 1)) 'Retries should wait briefly between attempts.'
}
$global:oitUninstallerTest.registered = $false
$global:oitUninstallerTest.calls = 0
& $uninstall -KeepFiles
Assert ($global:oitUninstallerTest.calls -eq 0) 'Uninstall should succeed when the package is already absent.'
Write-Host 'Uninstaller recovery tests passed'

Remove-Variable -Name oitUninstallerTest -Scope Global
