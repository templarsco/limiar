#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$LabPath)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Common.psm1') -Force
$lab = Read-LimiarQemuLab $LabPath
if ((Get-LimiarQemuStatus $lab).supervisor_active) { throw 'Stop the VM before changing its optical media' }
$profileHash = (Get-FileHash -LiteralPath $lab.Record.profile_path).Hash
$profile = Get-Content -LiteralPath $lab.Record.profile_path -Raw | ConvertFrom-Json -AsHashtable
$uuid = $profile.identity.system.uuid
if (-not $uuid) { $uuid = $lab.Registered.profile.identity.system.uuid }
if (-not $uuid -or [guid]$uuid -eq [guid]::Empty) { throw 'Guest tools require a materialized system UUID' }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$python = Join-Path $root '.limiar\tools\iso\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python)) { throw 'Create the pinned ISO-builder environment described in WINDOWS-LAB.md' }
$id = [guid]::NewGuid().ToString('N')
$payload = Join-Path $lab.Directory "tools-$id"
$iso = Join-Path $lab.Directory "tools-$id.iso"
[void][IO.Directory]::CreateDirectory($payload)
foreach ($file in @('Report-Identity.ps1','Install-IdentityProbe.ps1','setup.ps1')) {
    Copy-Item -LiteralPath (Join-Path $root "guest\windows\$file") -Destination (Join-Path $payload $file)
}
$configuration = @{
    schema_version=1;uuid=$uuid;owner_token=$lab.Record.owner_token
}
[IO.File]::WriteAllText((Join-Path $payload 'config.json'), ($configuration | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false))
$result = & $python (Join-Path $root 'scripts\windows\build_iso.py') $payload $iso --label LIMIAR_TOOLS
if ($LASTEXITCODE -ne 0) { throw 'Guest tools media creation failed' }
if ((Get-FileHash -LiteralPath $lab.Record.profile_path).Hash -ne $profileHash) {
    throw 'Profile changed while preparing media; generated ISO was not attached'
}
if ((Get-LimiarQemuStatus $lab).supervisor_active) { throw 'VM started while preparing media; generated ISO was not attached' }
$profile.boot.cdrom = $iso
Write-LimiarLabJson $lab.Record.profile_path $profile
[ordered]@{iso=$iso;contains_credentials=$false;requires_next_boot=$true;build=($result | ConvertFrom-Json)} |
    ConvertTo-Json -Depth 6
