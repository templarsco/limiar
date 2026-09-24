#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$LabPath, [switch]$Force)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Qmp.psm1') -Force
$lab = Read-LimiarQemuLab $LabPath
$status = Get-LimiarQemuStatus $lab
if ($status.supervisor_active) {
    if ($Force) {
        [void](Invoke-LimiarCli $lab.Cli @('vm','stop',$lab.Record.name,'--registry',$lab.Record.registry_path,
            '--force','--wait-seconds','15'))
    } else {
        Assert-LimiarQmpOwner $lab $status
        [void](Invoke-LimiarQmp -Port $lab.Record.qmp_port -Name $lab.Record.name -Command system_powerdown)
        $deadline = [DateTime]::UtcNow.AddSeconds(120)
        do {
            Start-Sleep -Seconds 1
            $status = Get-LimiarQemuStatus $lab
            if (-not $status.supervisor_active) { break }
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($status.supervisor_active) { throw 'Guest did not exit after the power-button request; no forced stop was attempted' }
    }
}
[ordered]@{status='off';name=$lab.Record.name;forced=[bool]$Force;disks_deleted=$false} | ConvertTo-Json
