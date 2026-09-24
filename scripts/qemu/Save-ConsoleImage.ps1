#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$LabPath)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Qmp.psm1') -Force
$lab = Read-LimiarQemuLab $LabPath
$status = Get-LimiarQemuStatus $lab
Assert-LimiarQmpOwner $lab $status
$path = Join-Path $lab.Directory ('console-' + [guid]::NewGuid().ToString('N') + '.png')
[void](Invoke-LimiarQmp -Port $lab.Record.qmp_port -Name $lab.Record.name -Command screendump `
    -Arguments @{filename=$path;format='png'})
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'QEMU did not write a console image' }
$path
