#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $BinaryDirectory,
    [string] $PackageDirectory,
    [string] $OutputDirectory,
    [ValidateSet('x64','arm64')][string] $Architecture = 'x64',
    [string] $Version,
    [string] $Publisher = 'CN=OpenInTerminal',
    [string] $SignedMsixPath,
    [string] $IsccPath
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $BinaryDirectory) { $BinaryDirectory = Join-Path $root 'dist/x64' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'dist/installer' }
if (-not $IsccPath) {
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command) { $IsccPath = $command.Source }
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, (Join-Path $env:LOCALAPPDATA 'Programs'))) {
        if ($IsccPath -or -not $base) { continue }
        foreach ($name in @('Inno Setup 7', 'Inno Setup 6')) {
            $candidate = Join-Path $base "$name/ISCC.exe"
            if (Test-Path -LiteralPath $candidate) { $IsccPath = $candidate; break }
        }
    }
}
if (-not $IsccPath -or -not (Test-Path -LiteralPath $IsccPath)) {
    throw 'Install Inno Setup 6.3 or newer, or pass -IsccPath pointing to ISCC.exe. C++ compilation still uses wslc.'
}
if (-not $PackageDirectory) {
    $PackageDirectory = Join-Path $root "dist/installer-package/$Architecture"
    $arguments = @{ BinaryDirectory = $BinaryDirectory; OutputDirectory = $PackageDirectory; Architecture = $Architecture; Publisher = $Publisher }
    if ($Version) { $arguments.Version = $Version }
    & (Join-Path $PSScriptRoot 'package.ps1') @arguments
}
$PackageDirectory = (Resolve-Path -LiteralPath $PackageDirectory).Path
foreach ($name in @('AppxManifest.xml','OpenInTerminal.dll','OpenInTerminalCli.exe','Assets/OpenInTerminal.ico')) {
    if (-not (Test-Path -LiteralPath (Join-Path $PackageDirectory $name))) { throw "Package is missing $name" }
}
[xml] $manifest = Get-Content -LiteralPath (Join-Path $PackageDirectory 'AppxManifest.xml') -Raw
$identity = $manifest.Package.Identity
if ($identity.Name -ne 'Ryan.OpenInTerminal' -or $identity.ProcessorArchitecture -ne $Architecture) {
    throw 'Package identity or architecture does not match the requested installer.'
}
if ($Version -and $Version -ne $identity.Version) { throw 'Version does not match the prepared package.' }
$Version = [string]$identity.Version
$payloadFiles = @(Get-ChildItem -LiteralPath $PackageDirectory -Recurse -File | Sort-Object FullName)
$hashText = ($payloadFiles | ForEach-Object {
    $_.FullName.Substring($PackageDirectory.Length) + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
}) -join "`n"
$suffix = '-dev'
if ($SignedMsixPath) {
    $SignedMsixPath = (Resolve-Path -LiteralPath $SignedMsixPath).Path
    # Verify that a caller-supplied MSIX really contains this package, not another build.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($SignedMsixPath)
    try {
        if (-not $archive.GetEntry('AppxSignature.p7x')) { throw 'The supplied MSIX is not signed.' }
        foreach ($file in $payloadFiles) {
            $relative = $file.FullName.Substring($PackageDirectory.Length).TrimStart('\','/').Replace('\','/')
            $entry = $archive.GetEntry($relative)
            if (-not $entry) { throw "MSIX is missing $relative" }
            $stream = $entry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $entryHash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','') }
            finally { $stream.Dispose(); $sha.Dispose() }
            if ($entryHash -ne (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) {
                throw "MSIX content differs from the prepared package: $relative"
            }
        }
    } finally { $archive.Dispose() }
    $hashText += (Get-FileHash -LiteralPath $SignedMsixPath -Algorithm SHA256).Hash
    $suffix = ''
}
$sha = [Security.Cryptography.SHA256]::Create()
try { $payloadId = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($hashText)))).Replace('-','').Substring(0,16).ToLowerInvariant() }
finally { $sha.Dispose() }
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$compilerArguments = @(
    '/Q', "/DAppVersion=$Version", "/DAppArchitecture=$Architecture", "/DPayloadId=$payloadId",
    "/DPackageDirectory=$PackageDirectory", "/DProjectRoot=$root", "/DInstallerOutput=$OutputDirectory", "/DBuildSuffix=$suffix"
)
if ($SignedMsixPath) { $compilerArguments += "/DSignedMsixPath=$SignedMsixPath" }
& $IsccPath @compilerArguments (Join-Path $root 'packaging/OpenInTerminal.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed ($LASTEXITCODE)." }
Write-Host "Installer: $(Join-Path $OutputDirectory "OpenInTerminal-$Version-$Architecture-setup$suffix.exe")"
