#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $BinaryDirectory,
    [string] $OutputDirectory,
    [ValidateSet('x64','arm64')][string] $Architecture = 'x64',
    [string] $Version,
    [string] $Publisher = 'CN=OpenInTerminal',
    [switch] $Msix
)
$ErrorActionPreference = 'Stop'
if (-not $BinaryDirectory) { $BinaryDirectory = Join-Path $PSScriptRoot '../dist/x64' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot '../dist/package' }
if (-not $Version) {
    $project = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../CMakeLists.txt'))
    if ($project -notmatch 'project\(OpenInTerminal VERSION (\d+\.\d+\.\d+)') { throw 'Project version not found.' }
    $Version = "$($Matches[1]).0"
}
if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw 'Version must have four numeric components.' }
$parts = $Version.Split('.') | ForEach-Object { [int]$_ }
if ($parts[0] -eq 0 -and ($parts | Where-Object { $_ -gt 0 }).Count -eq 0) { throw 'Version must not be zero.' }
if ($parts | Where-Object { $_ -gt 65535 }) { throw 'Version components must not exceed 65535.' }
if ([string]::IsNullOrWhiteSpace($Publisher)) { throw 'Publisher must not be empty.' }
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
foreach ($name in @('OpenInTerminal.dll','OpenInTerminalCli.exe')) {
    $binary = Join-Path $BinaryDirectory $name
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead((Resolve-Path -LiteralPath $binary).Path))
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "Not a Windows binary: $binary" }
        $reader.BaseStream.Position = 0x3C
        $offset = $reader.ReadInt32()
        $reader.BaseStream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw "Invalid PE header: $binary" }
        $machine = $reader.ReadUInt16()
        $expected = if ($Architecture -eq 'arm64') { 0xAA64 } else { 0x8664 }
        if ($machine -ne $expected) { throw "Binary architecture does not match ${Architecture}: $binary" }
    } finally { $reader.Dispose() }
    Copy-Item -LiteralPath $binary -Destination $OutputDirectory -Force
}
$template = Join-Path $PSScriptRoot '../packaging/AppxManifest.xml'
$manifest = [IO.File]::ReadAllText($template).Replace('@ARCH@', $Architecture).Replace('@VERSION@', $Version).Replace('@PUBLISHER@', [Security.SecurityElement]::Escape($Publisher))
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'AppxManifest.xml'), $manifest, [Text.UTF8Encoding]::new($false))
$assets = Join-Path $OutputDirectory 'Assets'
$null = New-Item -ItemType Directory -Force -Path $assets
Add-Type -AssemblyName System.Drawing
function New-TerminalBitmap([int] $Size) {
    $bitmap = [Drawing.Bitmap]::new($size,$size)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $pen = [Drawing.Pen]::new([Drawing.Color]::White, [single]($size * 0.055))
    try {
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([Drawing.Color]::FromArgb(32,34,40))
        $graphics.DrawLine($pen,[single]($size*.22),[single]($size*.30),[single]($size*.43),[single]($size*.50))
        $graphics.DrawLine($pen,[single]($size*.43),[single]($size*.50),[single]($size*.22),[single]($size*.70))
        $graphics.DrawLine($pen,[single]($size*.50),[single]($size*.70),[single]($size*.78),[single]($size*.70))
    } catch { $bitmap.Dispose(); throw }
    finally { $pen.Dispose(); $graphics.Dispose() }
    return $bitmap
}
foreach ($item in @(@('StoreLogo.png',50), @('Square44x44Logo.png',44), @('Square150x150Logo.png',150))) {
    $bitmap = New-TerminalBitmap ([int]$item[1])
    try { $bitmap.Save((Join-Path $assets $item[0]),[Drawing.Imaging.ImageFormat]::Png) }
    finally { $bitmap.Dispose() }
}
# ICO supports PNG frames on our Windows 11 minimum. Reuse the package artwork
# at native sizes so Setup and Installed apps render sharply at different scales.
$frames = foreach ($size in @(16,20,24,32,40,48,64,128,256)) {
    $bitmap = New-TerminalBitmap $size
    $stream = [IO.MemoryStream]::new()
    try {
        $bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Png)
        [pscustomobject]@{ Size = $size; Bytes = $stream.ToArray() }
    } finally { $stream.Dispose(); $bitmap.Dispose() }
}
$writer = [IO.BinaryWriter]::new([IO.File]::Create((Join-Path $assets 'OpenInTerminal.ico')))
try {
    $writer.Write([uint16]0) # Reserved
    $writer.Write([uint16]1) # Icon
    $writer.Write([uint16]$frames.Count)
    $offset = 6 + 16 * $frames.Count
    foreach ($frame in $frames) {
        $dimension = if ($frame.Size -eq 256) { 0 } else { $frame.Size }
        $writer.Write([byte]$dimension)
        $writer.Write([byte]$dimension)
        $writer.Write([byte]0) # Color palette
        $writer.Write([byte]0) # Reserved
        $writer.Write([uint16]1) # Planes
        $writer.Write([uint16]32) # Bits per pixel
        $writer.Write([uint32]$frame.Bytes.Length)
        $writer.Write([uint32]$offset)
        $offset += $frame.Bytes.Length
    }
    foreach ($frame in $frames) { $writer.Write([byte[]]$frame.Bytes) }
} finally { $writer.Dispose() }
if ($Msix) {
    $makeappx = Get-Command MakeAppx.exe -ErrorAction SilentlyContinue
    if (-not $makeappx) {
        $sdk = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
        $makeappx = Get-ChildItem $sdk -Filter MakeAppx.exe -Recurse | Where-Object FullName -Match '[\\/]x64[\\/]' | Sort-Object FullName -Descending | Select-Object -First 1
    }
    if (-not $makeappx) { throw 'MakeAppx.exe not found in Windows SDK.' }
    $tool = if ($makeappx.Source) { $makeappx.Source } else { $makeappx.FullName }
    $output = Join-Path (Split-Path $OutputDirectory -Parent) "OpenInTerminal-$Architecture-unsigned.msix"
    & $tool pack /d $OutputDirectory /p $output /o
    if ($LASTEXITCODE -ne 0) { throw 'MSIX packaging failed.' }
}
Write-Host "Package prepared: $OutputDirectory"

