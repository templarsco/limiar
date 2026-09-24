#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$LabPath)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Common.psm1') -Force
$lab = Read-LimiarWindowsLab $LabPath
if ($lab.Record.status -notin @('installed', 'driver_staged', 'gpu_attached', 'gpu_verified')) {
    throw 'Use the installer workflow for a VM without a verified Windows installation'
}
if ($lab.VM.State.ToString() -ne 'Off') { throw 'VM must be off before starting' }
if (-not (Get-VMSecurity -VM $lab.VM).TpmEnabled -or (Get-VMFirmware -VM $lab.VM).SecureBoot.ToString() -ne 'On') {
    throw 'VM security settings no longer match the verified lab configuration'
}
if ($lab.Record.status -in @('gpu_attached', 'gpu_verified')) {
    $partitions = @(Get-VMGpuPartitionAdapter -VM $lab.VM)
    if ($partitions.Count -ne 1 -or $partitions[0].Id -ne $lab.Record.gpu_adapter_id `
        -or $partitions[0].InstancePath -ne $lab.Record.gpu.device_interface) { throw 'GPU partition configuration changed' }
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $inventory = & (Join-Path $root 'scripts\gpu-pv-inventory.ps1') | ConvertFrom-Json
    $gpu = @($inventory.adapters | Where-Object { $_.device_interface -eq $lab.Record.gpu.device_interface })
    if ($inventory.status -ne 'queried' -or $gpu.Count -ne 1 -or $gpu[0].driver_version -ne $lab.Record.gpu.driver_version) {
        throw 'Host GPU/driver changed; refresh and verify the guest driver before starting'
    }
}
Start-VM -VM $lab.VM
[ordered]@{status='started';vm_id=$lab.Record.vm_id;name=$lab.Record.name} | ConvertTo-Json
