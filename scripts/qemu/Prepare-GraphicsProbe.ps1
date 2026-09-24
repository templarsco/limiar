#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LabPath,
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [string]$GuestCliPath,
    [switch]$Experimental
)
$ErrorActionPreference = 'Stop'
if (-not $Experimental) { throw 'Use -Experimental to prepare test-signed guest graphics media' }
Import-Module (Join-Path $PSScriptRoot 'Lab.Common.psm1') -Force
$lab = Read-LimiarQemuLab $LabPath
if ((Get-LimiarQemuStatus $lab).supervisor_active) { throw 'Stop the VM before preparing graphics media' }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$pin = Get-Content -LiteralPath (Join-Path $root 'runtime\virgl-windows-reference.json') -Raw | ConvertFrom-Json
if ($pin.schema_version -ne 1 -or $pin.sha256 -ne '33151648f83e2d8203d9954d39a4eaff02e66a7bb566dc5836cc8ae63868f219' -or
    $pin.driver_directory -ne 'Install_Debug/Win10/amd64') { throw 'Unsupported reference driver pin' }
$archive = (Resolve-Path -LiteralPath $ArchivePath).Path
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pin.sha256) {
    throw 'Guest driver archive checksum mismatch'
}
$cli = if ($GuestCliPath) { (Resolve-Path -LiteralPath $GuestCliPath).Path } else {
    Join-Path $root 'target\portable\x86_64-pc-windows-msvc\release\limiar.exe'
}
if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) { throw 'Build the portable guest CLI first' }
$profileHash = (Get-FileHash -LiteralPath $lab.Record.profile_path).Hash
$profile = Get-Content -LiteralPath $lab.Record.profile_path -Raw | ConvertFrom-Json -AsHashtable
if (-not $profile.identity.system.uuid) { throw 'A materialized guest UUID is required' }
$id = [guid]::NewGuid().ToString('N')
$payload = Join-Path $lab.Directory "graphics-$id"
$driver = Join-Path $payload 'driver'
$iso = Join-Path $lab.Directory "graphics-$id.iso"
New-LimiarPrivateDirectory $payload
[void][IO.Directory]::CreateDirectory($driver)
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
$members = @()
$total = 0L
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
try {
    $prefix = $pin.driver_directory + '/'
    foreach ($entry in $zip.Entries) {
        if (-not $entry.FullName.StartsWith($prefix, [StringComparison]::Ordinal) -or $entry.Name.Length -eq 0) { continue }
        $name = $entry.FullName.Substring($prefix.Length)
        if ($name -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Unexpected driver archive layout' }
        if ([IO.Path]::GetExtension($name).ToLowerInvariant() -notin @('.dll','.sys','.cat','.inf','.json','.exe','.cer')) { continue }
        if (-not $seen.Add($name) -or (($entry.ExternalAttributes -shr 16) -band 0xf000) -eq 0xa000) {
            throw 'Duplicate or linked driver archive member'
        }
        $total += $entry.Length
        if ($entry.Length -gt 128MB -or $total -gt 256MB) { throw 'Driver payload exceeds the reference bound' }
        $destination = Join-Path $driver $name
        $inputStream = $entry.Open()
        try {
            $outputStream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
        } finally { $inputStream.Dispose() }
        $members += @{name=$name;sha256=(Get-FileHash -LiteralPath $destination).Hash.ToLowerInvariant();bytes=$entry.Length}
    }
} finally { $zip.Dispose() }
foreach ($name in @('viogpu3d.inf','viogpu3d.cat','viogpu3d.sys','viogpu_d3d10.dll','VirtIOTestCert.cer')) {
    if (-not $seen.Contains($name)) { throw "Missing guest driver member: $name" }
}
Write-LimiarLabJson (Join-Path $driver 'files.json') @{
    schema_version=1;source_sha256=$pin.sha256;driver_tag=$pin.tag;files=$members
}
$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new((Join-Path $driver 'VirtIOTestCert.cer'))
Write-LimiarLabJson (Join-Path $payload 'graphics-config.json') @{
    schema_version=1;uuid=$profile.identity.system.uuid;owner_token=$lab.Record.owner_token
    cli_sha256=(Get-FileHash -LiteralPath $cli).Hash.ToLowerInvariant();driver_tag=$pin.tag
    test_certificate_thumbprint=$certificate.Thumbprint
}
foreach ($file in @('Report-Identity.ps1','Install-IdentityProbe.ps1','Prepare-GraphicsProbe.ps1',
    'Install-GraphicsDriver.ps1','Report-Graphics.ps1','Start-GraphicsDemo.ps1','setup-graphics.ps1')) {
    Copy-Item -LiteralPath (Join-Path $root "guest\windows\$file") -Destination (Join-Path $payload $file)
}
Copy-Item -LiteralPath $cli -Destination (Join-Path $payload 'limiar.exe')
$python = Join-Path $root '.limiar\tools\iso\Scripts\python.exe'
$result = & $python (Join-Path $root 'scripts\windows\build_iso.py') $payload $iso --label LIMIAR_GRAPHICS
if ($LASTEXITCODE -ne 0) { throw 'Graphics media creation failed' }
if ((Get-LimiarQemuStatus $lab).supervisor_active -or
    (Get-FileHash -LiteralPath $lab.Record.profile_path).Hash -ne $profileHash) {
    throw 'VM/profile changed while preparing media; the ISO was not attached'
}
$profile.boot.cdrom = $iso
Write-LimiarLabJson $lab.Record.profile_path $profile
[ordered]@{
    status='prepared';iso=$iso;driver_tag=$pin.tag;files=$members.Count
    includes_private_keys=$false;contains_credentials=$false;host_driver_installed=$false
    requires_explicit_guest_test_signing=$true;build=($result | ConvertFrom-Json)
} | ConvertTo-Json -Depth 5
