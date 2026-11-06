#Requires -Version 5.1
# Install a pinned compiler into the ignored workspace cache (no C++ toolchain needed on Windows).
[CmdletBinding()]
param([string] $ToolDirectory)
$ErrorActionPreference = 'Stop'
if (-not $ToolDirectory) { $ToolDirectory = Join-Path $PSScriptRoot '../.cache/inno-6.7.4' }
$null = New-Item -ItemType Directory -Force -Path $ToolDirectory
$ToolDirectory = (Resolve-Path -LiteralPath $ToolDirectory).Path
$compiler = Join-Path $ToolDirectory 'compiler/ISCC.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    $installer = Join-Path $ToolDirectory 'innosetup-6.7.4.exe'
    Invoke-WebRequest 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_4/innosetup-6.7.4.exe' -OutFile $installer -UseBasicParsing
    $expected = 'A549929319F9120716677C685535CA4671E4B937B5FDC87E2585F32D8EB30E8C'
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ne $expected) { throw 'Inno Setup download checksum mismatch.' }
    if ((Get-AuthenticodeSignature -LiteralPath $installer).Status -ne 'Valid') { throw 'Inno Setup installer signature is not trusted.' }
    $arguments = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/CURRENTUSER','/NOICONS',
        ('/DIR="' + (Join-Path $ToolDirectory 'compiler') + '"'), ('/LOG="' + (Join-Path $ToolDirectory 'install.log') + '"'))
    $process = Start-Process -FilePath $installer -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $compiler)) { throw "Inno Setup installation failed ($($process.ExitCode))." }
}
Write-Output $compiler
