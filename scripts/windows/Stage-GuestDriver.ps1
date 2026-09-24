#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$LabPath)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Common.psm1') -Force
$lab = Read-LimiarWindowsLab $LabPath
if ($lab.Record.status -ne 'installed' -or $lab.VM.State.ToString() -ne 'Running') {
    throw 'Driver staging requires a verified, running Windows guest'
}
$credential = Get-LimiarGuestCredential $lab
$existing = @(Get-VMDvdDrive -VM $lab.VM | Where-Object { $_.ControllerLocation -eq 3 })
if ($existing.Count -eq 0) {
    Add-VMDvdDrive -VM $lab.VM -ControllerNumber 0 -ControllerLocation 3 -Path $lab.Record.gpu_payload_iso | Out-Null
} elseif ($existing.Count -ne 1 -or $existing[0].Path -ne $lab.Record.gpu_payload_iso) {
    throw 'Unexpected media in the GPU payload slot'
}
$session = New-PSSession -VMId ([guid]$lab.Record.vm_id) -Credential $credential
try {
$result = Invoke-Command -Session $session -ScriptBlock {
    param($ExpectedName, $ExpectedUuid, $OwnerToken, $Package)
    $ErrorActionPreference = 'Stop'
    if ($env:COMPUTERNAME -ne $ExpectedName -or (Get-CimInstance Win32_ComputerSystemProduct).UUID -ne $ExpectedUuid) {
        throw 'Refusing driver writes outside the designated guest'
    }
    $media = @(Get-CimInstance Win32_LogicalDisk | Where-Object { $_.VolumeName -eq 'LIMIAR_GPU' })
    if ($media.Count -ne 1) { throw 'GPU provisioning media is not mounted' }
    $root = $media[0].DeviceID + '\'
    $manifest = Get-Content -LiteralPath (Join-Path $root 'driver-manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.owner_token -ne $OwnerToken -or $manifest.package -ne $Package -or $Package -notmatch '^[a-zA-Z0-9_.-]+$') {
        throw 'GPU payload does not match the lab'
    }
    $destination = Join-Path $env:SystemRoot "System32\HostDriverStore\FileRepository\$Package"
    $source = Join-Path $root "Windows\System32\HostDriverStore\FileRepository\$Package"
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $verified = 0
    foreach ($file in $manifest.files) {
        $target = [IO.Path]::GetFullPath((Join-Path $destination $file.path))
        if (-not $target.StartsWith($destination + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Driver payload path escaped its package'
        }
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $source $file.path) -Destination $target -Force
        if ((Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant() -ne $file.sha256) { throw 'Guest driver hash mismatch' }
        $verified++
    }
    $result = [ordered]@{schema_version=1;scope='windows_guest';driver_version=$manifest.driver_version;package=$Package;files_verified=$verified}
    $result | ConvertTo-Json | Set-Content -LiteralPath 'C:\Limiar\gpu-driver.json' -Encoding UTF8
    $result | ConvertTo-Json
} -ArgumentList $lab.Record.computer_name, $lab.Record.bios_guid, $lab.Record.owner_token, $lab.Record.gpu.package
} finally { Remove-PSSession -Session $session }
$result | Set-Content -LiteralPath (Join-Path $lab.Directory 'guest-driver.json') -Encoding UTF8
$lab.Record.status = 'driver_staged'
Write-LimiarWindowsLab $lab
$result
