#Requires -Version 5.1
# CI credentials stay in environment variables, never in command-line arguments or repository files.
[CmdletBinding()]
param([Parameter(Mandatory)][string] $Path)
$ErrorActionPreference = 'Stop'
if (-not $env:MSIX_CERTIFICATE_BASE64) { throw 'MSIX_CERTIFICATE_BASE64 is required.' }
$sdk = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
$tool = Get-ChildItem -LiteralPath $sdk -Filter signtool.exe -Recurse |
    Where-Object FullName -Match '[\\/]x64[\\/]' | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $tool) { throw 'SignTool.exe not found in Windows SDK.' }
$pfx = Join-Path ([IO.Path]::GetTempPath()) ("OpenInTerminal-" + [guid]::NewGuid().ToString('N') + '.pfx')
$certificate = $null
$existingThumbprints = @(Get-ChildItem Cert:/CurrentUser/My | ForEach-Object Thumbprint)
try {
    [IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($env:MSIX_CERTIFICATE_BASE64))
    $password = [Security.SecureString]::new()
    if ($env:MSIX_CERTIFICATE_PASSWORD) { $password = ConvertTo-SecureString $env:MSIX_CERTIFICATE_PASSWORD -AsPlainText -Force }
    $certificate = @(Import-PfxCertificate -FilePath $pfx -CertStoreLocation Cert:/CurrentUser/My -Password $password |
        Where-Object HasPrivateKey)
    if ($certificate.Count -ne 1) { throw 'Expected exactly one signing certificate with a private key.' }
    & $tool.FullName sign /sha1 $certificate[0].Thumbprint /fd SHA256 /tr 'http://timestamp.digicert.com' /td SHA256 $Path
    if ($LASTEXITCODE -ne 0) { throw 'MSIX signing failed; check that Publisher matches the certificate Subject.' }
    & $tool.FullName verify /pa $Path
    if ($LASTEXITCODE -ne 0) { throw 'MSIX signature verification failed.' }
} finally {
    if (Test-Path -LiteralPath $pfx) { Remove-Item -LiteralPath $pfx -Force }
    foreach ($item in $certificate) {
        if ($item.Thumbprint -notin $existingThumbprints) {
            Remove-Item -LiteralPath ("Cert:/CurrentUser/My/" + $item.Thumbprint) -DeleteKey -ErrorAction SilentlyContinue
        }
    }
}
