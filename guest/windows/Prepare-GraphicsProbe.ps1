#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][guid]$ExpectedUuid,
    [Parameter(Mandatory = $true)][guid]$OwnerToken,
    [switch]$EnableGuestTestSigning,
    [switch]$Resume
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
if (Test-Path -LiteralPath $directory) {
    if (-not $Resume) { throw 'Graphics tools already exist; use -Resume only for this same laboratory payload' }
    foreach ($path in @($directory, (Join-Path $directory 'driver'))) {
        if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked graphics directory' }
    }
    $previous = Get-Content -LiteralPath (Join-Path $directory 'graphics-config.json') -Raw | ConvertFrom-Json
    foreach ($key in @('schema_version','uuid','owner_token','cli_sha256','driver_tag','test_certificate_thumbprint')) {
        if ($previous.$key -ne $config.$key) { throw 'Resume requires the original owner and payload' }
    }
    foreach ($file in $manifest.files) {
        $target = Join-Path $directory "driver\$($file.name)"
        if ((Get-Item -LiteralPath $target).Attributes -band [IO.FileAttributes]::ReparsePoint -or
            (Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant() -ne $file.sha256) {
            throw 'Existing driver payload differs; resume refused'
        }
    }
}
[void][IO.Directory]::CreateDirectory($directory)
foreach ($file in @('graphics-config.json','limiar.exe','Install-GraphicsDriver.ps1','Report-Graphics.ps1','Start-GraphicsDemo.ps1')) {
    $target = Join-Path $directory $file
    if ((Test-Path -LiteralPath $target) -and
        ((Get-Item -LiteralPath $target).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked graphics tool' }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $target -Force
}
if (-not (Test-Path -LiteralPath (Join-Path $directory 'driver'))) {
    Copy-Item -LiteralPath $source -Destination (Join-Path $directory 'driver') -Recurse
}
$stage = 'certificate'
$receipt = [ordered]@{schema_version=1;uuid=$config.uuid;owner_token=$config.owner_token;status='preparing';stage=$stage}
try {
    $certificatePath = Join-Path $directory 'driver\VirtIOTestCert.cer'
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificatePath)
    if ($certificate.Thumbprint -ne $config.test_certificate_thumbprint) { throw 'Unexpected test certificate' }
    foreach ($name in @('Root','TrustedPublisher')) {
        # ReadWrite also initializes an empty store on a fresh guest.
        $store = [Security.Cryptography.X509Certificates.X509Store]::new(
            $name, [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
        try {
            $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            $store.Add($certificate)
        } finally { $store.Close() }
    }
    $stage = 'test_signing'
    & "$env:SystemRoot\System32\bcdedit.exe" /set testsigning on
    if ($LASTEXITCODE -ne 0) { throw 'Guest test-signing could not be enabled; no host setting was changed' }
    $stage = 'startup_task'
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument '-NoProfile -ExecutionPolicy RemoteSigned -File C:\Limiar\Graphics\Install-GraphicsDriver.ps1'
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 4)
    $existing = Get-ScheduledTask -TaskName LimiarGraphicsInstall -ErrorAction SilentlyContinue
    if ($existing -and (-not $Resume -or $existing.Description -ne "Limiar.Graphics:$OwnerToken")) {
        throw 'Installation task already exists and is not owned by this preparation'
    }
    Register-ScheduledTask -TaskName LimiarGraphicsInstall -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description "Limiar.Graphics:$OwnerToken" -Force | Out-Null
    $receipt.status = 'prepared'
    $receipt.stage = 'awaiting_cold_boot'
} catch {
    $receipt.status = 'failed'
    $receipt.stage = $stage
    $receipt.error = $_.Exception.ToString()
    throw
} finally {
    [IO.File]::WriteAllText((Join-Path $directory 'preparation.json'), ($receipt | ConvertTo-Json -Depth 4),
        [Text.UTF8Encoding]::new($false))
}
[ordered]@{status='prepared';guest_test_signing=$true;uuid=$ExpectedUuid.ToString();requires_cold_boot=$true} |
    ConvertTo-Json
& "$env:SystemRoot\System32\shutdown.exe" /s /t 3
if ($LASTEXITCODE -ne 0) { throw 'Guest shutdown request failed' }
