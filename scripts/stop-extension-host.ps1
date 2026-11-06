#Requires -Version 5.1
# Release only this user's COM surrogate that actually loaded the installed extension.
[CmdletBinding()]
param([Parameter(Mandatory)][string] $DllPath)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $DllPath)) { return }
$DllPath = (Resolve-Path -LiteralPath $DllPath).Path
$sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
$userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$hosts = Get-CimInstance Win32_Process -Filter "Name='dllhost.exe' AND SessionId=$sessionId"
foreach ($hostProcess in $hosts) {
    if ($hostProcess.CommandLine -notmatch '(?i)/Processid:\{A763E1D5-05EB-43A3-9C82-7DA5B86F6B41\}(?:\s|$)') { continue }
    $owner = Invoke-CimMethod -InputObject $hostProcess -MethodName GetOwnerSid
    if ($owner.ReturnValue -ne 0 -or $owner.Sid -ne $userSid) { continue }
    $process = Get-Process -Id $hostProcess.ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { continue }
    $loaded = @($process.Modules | Where-Object FileName -EQ $DllPath)
    if ($loaded.Count) {
        # Kill only after checking session, owner, COM class and the loaded DLL's exact path.
        Stop-Process -InputObject $process -ErrorAction Stop
        if (-not $process.WaitForExit(10000)) { throw 'The Open In Terminal COM surrogate did not exit.' }
        Write-Host "Released Open In Terminal COM surrogate ($($hostProcess.ProcessId))."
    }
}
