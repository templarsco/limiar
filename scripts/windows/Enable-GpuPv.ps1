#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$LabPath)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Common.psm1') -Force
$lab = Read-LimiarWindowsLab $LabPath
if ($lab.Record.status -ne 'driver_staged') { throw 'GPU-PV requires a staged and verified guest driver' }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$inventory = & (Join-Path $root 'scripts\gpu-pv-inventory.ps1') | ConvertFrom-Json
$gpu = @($inventory.adapters | Where-Object { $_.device_interface -eq $lab.Record.gpu.device_interface })
if ($inventory.status -ne 'queried' -or $gpu.Count -ne 1 -or $gpu[0].driver_version -ne $lab.Record.gpu.driver_version) {
    throw 'The selected host GPU or driver changed; prepare a matching payload'
}
if (@(Get-VMGpuPartitionAdapter -VM $lab.VM).Count -ne 0) { throw 'The VM already has a GPU partition' }
if ($lab.VM.State.ToString() -eq 'Running') {
    $session = New-PSSession -VMId ([guid]$lab.Record.vm_id) -Credential (Get-LimiarGuestCredential $lab)
    try {
    Invoke-Command -Session $session -ScriptBlock {
        param($Name, $Uuid)
        if ($env:COMPUTERNAME -ne $Name -or (Get-CimInstance Win32_ComputerSystemProduct).UUID -ne $Uuid) {
            throw 'Shutdown refused: wrong guest'
        }
        & shutdown.exe /s /t 2
        if ($LASTEXITCODE -ne 0) { throw 'Guest shutdown request failed' }
    } -ArgumentList $lab.Record.computer_name, $lab.Record.bios_guid
    } finally { Remove-PSSession -Session $session }
}
$deadline = [DateTime]::UtcNow.AddSeconds(90)
do {
    $lab.VM = Get-VM -Id ([guid]$lab.Record.vm_id)
    if ($lab.VM.State.ToString() -eq 'Off') { break }
    if ([DateTime]::UtcNow -ge $deadline) { throw 'Guest did not shut down normally; no GPU was attached' }
    Start-Sleep -Seconds 2
} while ($true)
$lab = Read-LimiarWindowsLab $LabPath
Set-VM -VM $lab.VM -GuestControlledCacheTypes $true -LowMemoryMappedIoSpace 1GB -HighMemoryMappedIoSpace 32GB
$partition = Add-VMGpuPartitionAdapter -VM $lab.VM -InstancePath $lab.Record.gpu.device_interface -Passthru
if ($partition.InstancePath -ne $lab.Record.gpu.device_interface) {
    Remove-VMGpuPartitionAdapter -VMGpuPartitionAdapter $partition
    throw 'GPU assignment did not preserve the requested device path'
}
$lab.Record.gpu_adapter_id = $partition.Id
$lab.Record.status = 'gpu_attached'
Write-LimiarWindowsLab $lab
foreach ($dvd in @(Get-VMDvdDrive -VM $lab.VM)) {
    if ($dvd.Path -notin @($lab.Record.iso_path, $lab.Record.payload_iso, $lab.Record.gpu_payload_iso)) {
        throw 'Refusing to remove an unknown DVD attachment'
    }
    Remove-VMDvdDrive -VMDvdDrive $dvd
}
Set-VMFirmware -VM $lab.VM -FirstBootDevice (Get-VMHardDiskDrive -VM $lab.VM)
Start-VM -VM $lab.VM
[ordered]@{status='gpu_attached';adapter=$lab.Record.gpu.adapter_name;host_gpu_dismounted=$false;driver_version=$lab.Record.gpu.driver_version} | ConvertTo-Json
