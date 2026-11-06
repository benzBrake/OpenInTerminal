#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $Image = 'openinterminal-build:bookworm',
    [switch] $Pull,
    [switch] $SkipWindowsTests
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not (Get-Command wslc -ErrorAction SilentlyContinue)) { throw 'WSLC is required. Install or enable WSL containers first.' }
$buildArgs = @('build', '--file', (Join-Path $root 'docker/Dockerfile'), '--tag', $Image)
if ($Pull) { $buildArgs += '--pull' }
$buildArgs += $root
& wslc @buildArgs
if ($LASTEXITCODE -ne 0) { throw 'Container image build failed.' }
& wslc run --rm --volume "${root}:/workspace" $Image
if ($LASTEXITCODE -ne 0) { throw 'Container compilation or native tests failed.' }
if (-not $SkipWindowsTests) {
    & (Join-Path $root 'dist/x64/core_tests.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Windows core tests failed.' }
    & (Join-Path $root 'dist/x64/shell_tests.exe') (Join-Path $root 'dist/x64/OpenInTerminal.dll')
    if ($LASTEXITCODE -ne 0) { throw 'Windows COM tests failed.' }
}
Write-Host "Build complete: $(Join-Path $root 'dist/x64')"

