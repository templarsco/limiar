#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$LabPath)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Common.psm1') -Force
$lab = Read-LimiarWindowsLab $LabPath
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$executable = Join-Path $root 'target\portable\x86_64-pc-windows-msvc\release\limiar.exe'
$hash = (Get-FileHash -LiteralPath $executable).Hash
$session = New-PSSession -VMId ([guid]$lab.Record.vm_id) -Credential (Get-LimiarGuestCredential $lab)
try {
    Invoke-Command -Session $session -ScriptBlock {
        param($Name, $Uuid, $Token)
        if ($env:COMPUTERNAME -ne $Name -or (Get-CimInstance Win32_ComputerSystemProduct).UUID -ne $Uuid) {
            throw 'CLI update refused: guest identity mismatch'
        }
        $owner = Get-Content -LiteralPath C:\Limiar\owner.json -Raw | ConvertFrom-Json
        if ($owner.owner_token -ne $Token) { throw 'CLI update refused: guest ownership mismatch' }
        if (Get-Process -Name limiar -ErrorAction SilentlyContinue) { throw 'A guest CLI process is still running' }
    } -ArgumentList $lab.Record.computer_name, $lab.Record.bios_guid, $lab.Record.owner_token
    Copy-Item -ToSession $session -LiteralPath $executable -Destination C:\Limiar\limiar.exe -Force
    $version = Invoke-Command -Session $session -ScriptBlock {
        param($Hash)
        if ((Get-FileHash -LiteralPath C:\Limiar\limiar.exe).Hash -ne $Hash) { throw 'Guest CLI hash mismatch' }
        $version = & C:\Limiar\limiar.exe --version
        if ($LASTEXITCODE -ne 0 -or [string]$version -notmatch '^limiar \d+\.\d+\.\d+') { throw 'Guest CLI could not run' }
        [string]$version
    } -ArgumentList $hash
    $lab.Record.cli_sha256 = $hash.ToLowerInvariant()
    $lab.Record.cli_version = [string]$version
    Write-LimiarWindowsLab $lab
    [ordered]@{guest_cli=$version;hash_verified=$true;transport='powershell_direct'} | ConvertTo-Json
} finally { Remove-PSSession -Session $session }
