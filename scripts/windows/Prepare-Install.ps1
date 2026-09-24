#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LabPath,
    [Parameter(Mandatory = $true)][string]$Iso,
    [string]$Edition = 'Professional',
    [switch]$Resume
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Common.psm1') -Force
$lab = Read-LimiarWindowsLab $LabPath
if ($lab.VM.State.ToString() -ne 'Off' -or $lab.Record.status -notin @('prepared', 'install_preparing')) {
    throw 'Installation preparation requires a newly prepared, powered-off VM'
}
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$python = Join-Path $root '.limiar\tools\iso\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python)) { throw 'Create the ISO builder environment first' }
$cli = Join-Path $root 'target\portable\x86_64-pc-windows-msvc\release\limiar.exe'
if (-not (Test-Path -LiteralPath $cli)) { throw 'Build the clean-Windows CLI with scripts/Build-PortableCli.ps1 first' }
$media = & (Join-Path $PSScriptRoot 'Read-Media.ps1') -Iso $Iso | ConvertFrom-Json
$selected = @($media.images | Where-Object { $_.edition -eq $Edition -and $_.architecture -eq 9 -and $_.language -eq 'pt-BR' })
if ($selected.Count -ne 1) { throw 'Expected exactly one matching pt-BR x64 edition in the media' }

$payload = Join-Path $lab.Directory 'install-payload'
$payloadIso = Join-Path $lab.Directory 'install-payload.iso'
$settings = Get-LimiarVmSettings ([guid]$lab.Record.vm_id)
$lab.Record.status = 'install_preparing'
$lab.Record.contains_private_credentials = $true
Write-LimiarWindowsLab $lab
if (Test-Path -LiteralPath $payload) {
    if (-not $Resume) { throw 'Payload exists; use -Resume to validate and retain its credentials' }
    $owner = Get-Content -LiteralPath (Join-Path $payload 'Limiar\owner.json') -Raw | ConvertFrom-Json
    if ($owner.owner_token -ne $lab.Record.owner_token -or $owner.bios_guid -ne $settings.BIOSGUID `
        -or $owner.computer_name -ne $lab.Record.computer_name) { throw 'Existing payload belongs to a different VM' }
    $credential = Get-LimiarGuestCredential $lab
    $xml = [Xml.XmlDocument]::new()
    $xml.XmlResolver = $null
    $xml.Load((Join-Path $payload 'Autounattend.xml'))
    $ns = [Xml.XmlNamespaceManager]::new($xml.NameTable)
    $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
    if ($xml.SelectSingleNode('//u:MetaData/u:Value', $ns).InnerText -ne [string]$selected[0].index) {
        throw 'Existing payload selects a different edition'
    }
    foreach ($node in $xml.SelectNodes('//u:Password/u:Value', $ns)) {
        if ($node.InnerText -ne $credential.GetNetworkCredential().Password) { throw 'Existing payload credential mismatch' }
    }
} else {
    [void][IO.Directory]::CreateDirectory((Join-Path $payload 'Limiar'))
    $random = [byte[]]::new(24)
    [Security.Cryptography.RandomNumberGenerator]::Fill($random)
    $password = 'Lm!4' + [Convert]::ToBase64String($random)
    $secure = ConvertTo-SecureString $password -AsPlainText -Force
    $credential = [pscredential]::new('limiar', $secure)
    $credential | Export-Clixml -LiteralPath (Join-Path $lab.Directory 'credential.xml')

    $xml = [Xml.XmlDocument]::new()
    $xml.XmlResolver = $null
    $xml.Load((Join-Path $root 'guest\windows\Autounattend.xml'))
    $ns = [Xml.XmlNamespaceManager]::new($xml.NameTable)
    $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
    $xml.SelectSingleNode('//u:ComputerName', $ns).InnerText = $lab.Record.computer_name
    $xml.SelectSingleNode('//u:TimeZone', $ns).InnerText = (Get-TimeZone).Id
    $xml.SelectSingleNode('//u:MetaData/u:Value', $ns).InnerText = [string]$selected[0].index
    foreach ($node in $xml.SelectNodes('//u:Password/u:Value', $ns)) { $node.InnerText = $password }
    $xml.Save((Join-Path $payload 'Autounattend.xml'))
    $password = $null

    $owner = [ordered]@{
        schema_version = 1
        owner_token = $lab.Record.owner_token
        computer_name = $lab.Record.computer_name
        bios_guid = $settings.BIOSGUID
    }
    $owner | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $payload 'Limiar\owner.json') -Encoding UTF8
    foreach ($file in @('bootstrap.ps1', 'bootstrap.cmd')) {
        Copy-Item -LiteralPath (Join-Path $root "guest\windows\$file") -Destination (Join-Path $payload "Limiar\$file")
    }
    Copy-Item -LiteralPath $cli -Destination (Join-Path $payload 'Limiar\limiar.exe')
}
if (-not (Test-Path -LiteralPath $payloadIso)) {
    $build = & $python (Join-Path $PSScriptRoot 'build_iso.py') $payload $payloadIso | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'Provisioning ISO build failed' }
    Write-Verbose $build
} elseif (-not $Resume) {
    throw 'Provisioning ISO already exists'
}

$installer = $null
foreach ($location in @(1, 2)) {
    $desiredPath = if ($location -eq 1) { $media.path } else { $payloadIso }
    $existing = @(Get-VMDvdDrive -VM $lab.VM | Where-Object { $_.ControllerNumber -eq 0 -and $_.ControllerLocation -eq $location })
    if ($existing.Count -eq 0) {
        $dvd = Add-VMDvdDrive -VM $lab.VM -ControllerNumber 0 -ControllerLocation $location -Path $desiredPath -Passthru
    } elseif ($existing.Count -eq 1 -and $existing[0].Path -eq $desiredPath -and $Resume) {
        $dvd = $existing[0]
    } else { throw 'Unexpected DVD attachment' }
    if ($location -eq 1) { $installer = $dvd }
}
Set-VMFirmware -VM $lab.VM -FirstBootDevice $installer
$lab.Record.status = 'install_ready'
$lab.Record.iso_path = $media.path
$lab.Record.iso_sha256 = $media.sha256
$lab.Record.image_index = $selected[0].index
$lab.Record.edition = $selected[0].edition
$lab.Record.media_version = $selected[0].version
$lab.Record.bios_guid = $settings.BIOSGUID
$lab.Record.payload_iso = $payloadIso
$lab.Record.contains_private_credentials = $true
Write-LimiarWindowsLab $lab
$media | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $lab.Directory 'media.json') -Encoding UTF8
[ordered]@{status='install_ready';vm_id=$lab.Record.vm_id;edition=$selected[0].name;version=$selected[0].version;secure_boot=$true;tpm=$true;network='none'} | ConvertTo-Json
