#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$LabPath)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Common.psm1') -Force
$lab = Read-LimiarWindowsLab $LabPath
if ($lab.VM.State.ToString() -ne 'Off' -or $lab.Record.status -ne 'install_ready') {
    throw 'Only a new, install-ready VM can enter unattended installation'
}
$vhd = Get-VHD -Path $lab.Record.disk_path
if ($vhd.Attached -or $vhd.FileSize -gt 64MB -or $vhd.VhdType.ToString() -ne 'Dynamic') {
    throw 'Refusing to install over an attached or previously used disk'
}
$dvds = @(Get-VMDvdDrive -VM $lab.VM)
if ($dvds.Count -ne 2 -or @($dvds.Path | Where-Object { $_ -notin @($lab.Record.iso_path, $lab.Record.payload_iso) }).Count -gt 0) {
    throw 'Unexpected installation media attachments'
}
if ((Get-VMFirmware -VM $lab.VM).SecureBoot.ToString() -ne 'On' -or -not (Get-VMSecurity -VM $lab.VM).TpmEnabled) {
    throw 'The Windows lab requires actual Secure Boot and vTPM'
}
$lab.Record.initial_disk_sha256 = (Get-FileHash -LiteralPath $lab.Record.disk_path).Hash.ToLowerInvariant()
$lab.Record.status = 'installing'
$lab.Record.install_started_at = (Get-Date).ToUniversalTime().ToString('o')
Write-LimiarWindowsLab $lab
Start-VM -VM $lab.VM
# Do not send timed keystrokes: setup may already be displaying an input field.
[ordered]@{status='installing';vm_id=$lab.Record.vm_id;physical_disks_attached=$false;network='none'} | ConvertTo-Json
