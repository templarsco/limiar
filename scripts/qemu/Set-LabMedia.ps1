#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$LabPath, [Parameter(Mandatory=$true)][string]$IsoPath)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Qmp.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Media.psm1') -Force
$lab = Read-LimiarQemuLab $LabPath
$status = Get-LimiarQemuStatus $lab
Assert-LimiarQmpOwner $lab $status
$connection = @{SocketPath=$lab.Record.qmp_socket;ProcessId=$status.last_run.runtime_pid;Name=$lab.Record.name}
$blocks = @(Invoke-LimiarQmp @connection -Command query-block)
$request = New-LimiarOpticalMediaRequest -IsoPath $IsoPath -Blocks $blocks
[void](Invoke-LimiarQmp @connection -Command blockdev-change-medium -Arguments $request)
$after = @(Invoke-LimiarQmp @connection -Command query-block)
[void](New-LimiarOpticalMediaRequest -IsoPath $IsoPath -Blocks $after)
$inserted = @($after | Where-Object device -eq 'cdrom')[0].inserted.file
if (-not [string]::Equals([IO.Path]::GetFullPath($inserted), $request.filename, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Optical media readback does not match the requested image'
}
$record = [ordered]@{
    schema_version=1;status='optical_media_changed';name=$lab.Record.name;owner_token=$lab.Record.owner_token
    run_id=$status.last_run.run_id;iso_path=$request.filename;read_only=$true
    persistent_profile_changed=$false;changed_at=[DateTime]::UtcNow.ToString('o')
}
Write-LimiarLabJson (Join-Path $lab.Directory ('media-' + [guid]::NewGuid().ToString('N') + '.json')) $record
$record | ConvertTo-Json
