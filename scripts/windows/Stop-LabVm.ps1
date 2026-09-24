#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LabPath,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Common.psm1') -Force
$lab = Read-LimiarWindowsLab $LabPath
if ($lab.VM.State.ToString() -ne 'Off') {
    if ($Force) {
        Stop-VM -VM $lab.VM -TurnOff -Confirm:$false
    } else {
        if ($lab.Record.status -notin @('installed', 'driver_staged', 'gpu_attached', 'gpu_verified')) {
            throw 'Normal shutdown requires an installed guest; --Force explicitly powers off an incomplete lab'
        }
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
        $deadline = [DateTime]::UtcNow.AddSeconds(90)
        while ((Get-VM -Id ([guid]$lab.Record.vm_id)).State.ToString() -ne 'Off') {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Guest did not shut down; use -Force only to acknowledge data-loss risk' }
            Start-Sleep -Seconds 2
        }
    }
}
[ordered]@{status='off';vm_id=$lab.Record.vm_id;forced=[bool]$Force;disks_deleted=$false} | ConvertTo-Json
