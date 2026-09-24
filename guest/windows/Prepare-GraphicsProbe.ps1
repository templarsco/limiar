#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][guid]$ExpectedUuid,
    [Parameter(Mandatory = $true)][guid]$OwnerToken,
    [switch]$EnableGuestTestSigning
)
$ErrorActionPreference = 'Stop'
if ($ExpectedUuid -eq [guid]::Empty -or $OwnerToken -eq [guid]::Empty -or
    [guid](Get-CimInstance Win32_ComputerSystemProduct).UUID -ne $ExpectedUuid) {
    throw 'Guest UUID mismatch; this installer must not run on the host or another VM'
}
if (-not $EnableGuestTestSigning) { throw 'Explicit -EnableGuestTestSigning acknowledgement is required' }
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'graphics-config.json') -Raw | ConvertFrom-Json
if ($config.schema_version -ne 1 -or [guid]$config.uuid -ne $ExpectedUuid -or
    [guid]$config.owner_token -ne $OwnerToken) { throw 'Graphics media ownership mismatch' }
$source = Join-Path $PSScriptRoot 'driver'
$manifest = Get-Content -LiteralPath (Join-Path $source 'files.json') -Raw | ConvertFrom-Json
foreach ($file in $manifest.files) {
    if ($file.name -notmatch '^[A-Za-z0-9_.-]+$' -or $file.sha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'Invalid driver member'
    }
    if ((Get-FileHash -LiteralPath (Join-Path $source $file.name)).Hash.ToLowerInvariant() -ne $file.sha256) {
        throw 'Graphics driver media checksum mismatch'
    }
}
if ((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'limiar.exe')).Hash.ToLowerInvariant() -ne $config.cli_sha256) {
    throw 'Guest CLI media checksum mismatch'
}
& (Join-Path $PSScriptRoot 'Install-IdentityProbe.ps1') -ExpectedUuid $ExpectedUuid -OwnerToken $OwnerToken -DisableHibernate
$directory = 'C:\Limiar\Graphics'
if (Test-Path -LiteralPath $directory) { throw 'Graphics tools already exist; refusing to overwrite the laboratory state' }
[void][IO.Directory]::CreateDirectory($directory)
foreach ($file in @('graphics-config.json','limiar.exe','Install-GraphicsDriver.ps1','Report-Graphics.ps1','Start-GraphicsDemo.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $directory $file)
}
Copy-Item -LiteralPath $source -Destination (Join-Path $directory 'driver') -Recurse
$certificatePath = Join-Path $directory 'driver\VirtIOTestCert.cer'
$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificatePath)
if ($certificate.Thumbprint -ne $config.test_certificate_thumbprint) { throw 'Unexpected test certificate' }
foreach ($store in @('Cert:\LocalMachine\Root','Cert:\LocalMachine\TrustedPublisher')) {
    Import-Certificate -FilePath $certificatePath -CertStoreLocation $store | Out-Null
}
& "$env:SystemRoot\System32\bcdedit.exe" /set testsigning on
if ($LASTEXITCODE -ne 0) { throw 'Guest test-signing could not be enabled; no host setting was changed' }
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument '-NoProfile -ExecutionPolicy RemoteSigned -File C:\Limiar\Graphics\Install-GraphicsDriver.ps1'
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 4)
if (Get-ScheduledTask -TaskName LimiarGraphicsInstall -ErrorAction SilentlyContinue) { throw 'Installation task already exists' }
Register-ScheduledTask -TaskName LimiarGraphicsInstall -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings | Out-Null
[ordered]@{status='prepared';guest_test_signing=$true;uuid=$ExpectedUuid.ToString();requires_cold_boot=$true} |
    ConvertTo-Json
& "$env:SystemRoot\System32\shutdown.exe" /s /t 3
if ($LASTEXITCODE -ne 0) { throw 'Guest shutdown request failed' }
