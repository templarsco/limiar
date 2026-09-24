#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$LabPath)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Common.psm1') -Force
$lab = Read-LimiarQemuLab $LabPath
$path = Join-Path $lab.Directory 'credential.xml'
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'No credential was saved for this imported guest' }
$credential = Import-Clixml -LiteralPath $path
if ($credential -isnot [pscredential]) { throw 'Invalid local credential file' }
Add-Type -AssemblyName System.Windows.Forms
$password = $credential.GetNetworkCredential().Password
try {
    [void][Windows.Forms.MessageBox]::Show(
        "VM: $($lab.Record.name)`r`nUsuario: $($credential.UserName)`r`nSenha: $password",
        'Limiar - Credenciais locais', [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Information)
} finally {
    $password = $null
    $credential = $null
}
