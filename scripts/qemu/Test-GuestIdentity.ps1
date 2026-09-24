#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$RunReport)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Smbios.psm1') -Force
$runFile = (Resolve-Path -LiteralPath $RunReport).Path
if ((Get-Item -LiteralPath $runFile).Length -gt 1048576) { throw 'Run report exceeds 1 MiB' }
$run = Get-Content -LiteralPath $runFile -Raw | ConvertFrom-Json -AsHashtable
if ($run.schema_version -ne 1 -or -not $run.success -or $run.stop_reason -ne 'guest_exit') {
    throw 'Validation requires a successful run ending with normal guest exit'
}
if (-not $run.expected_dmi -or $run.expected_dmi.Count -eq 0) { throw 'Run has no captured expected identity' }
if ((Get-Item -LiteralPath $run.stdout_log).Length -gt 8MB) { throw 'Guest transcript exceeds 8 MiB' }
$reports = @(Get-Content -LiteralPath $run.stdout_log | Where-Object { $_.StartsWith('LIMIAR_IDENTITY_V1 ') })
if ($reports.Count -ne 1 -or $reports[0].Length -gt 131072) {
    throw 'Expected exactly one bounded Windows identity report; use one cold boot per validation run'
}
$json = [Text.UTF8Encoding]::new($false, $true).GetString([Convert]::FromBase64String($reports[0].Substring(19)))
$guest = $json | ConvertFrom-Json -AsHashtable
if ($guest.schema_version -ne 1 -or $guest.scope -ne 'guest_reported_identity') { throw 'Unknown guest identity protocol' }
$observed = ConvertFrom-LimiarSmbios -Data ([Convert]::FromBase64String($guest.raw_smbios_base64))
$comparisons = @()
foreach ($field in $run.expected_dmi.Keys) {
    $actual = $observed[$field]
    $expected = [string]$run.expected_dmi[$field]
    $matches = if ($field -eq 'product_uuid') {
        [string]::Equals($actual, $expected, [StringComparison]::OrdinalIgnoreCase)
    } else {
        [string]::Equals($actual, $expected, [StringComparison]::Ordinal)
    }
    $comparisons += [ordered]@{ field=$field; expected=$expected; observed=$actual; matches=$matches }
}
$wmiMatches = $true
foreach ($entry in @(
    @('manufacturer','sys_vendor'), @('product','product_name'), @('version','product_version'),
    @('serial','product_serial'), @('uuid','product_uuid'), @('sku','product_sku'), @('family','product_family')
)) {
    if (-not [string]::Equals([string]$guest.system[$entry[0]], [string]$observed[$entry[1]],
        [StringComparison]::OrdinalIgnoreCase)) { $wmiMatches = $false }
}
$passed = @($comparisons | Where-Object { -not $_.matches }).Count -eq 0 -and $wmiMatches -and $observed.bios_uefi -eq 'true'
[ordered]@{
    schema_version = 1
    scope = 'guest_reported_windows_smbios'
    passed = $passed
    fields = $comparisons
    wmi_system_agrees_with_raw_smbios = $wmiMatches
    uefi_flag = $observed.bios_uefi
    os = $guest.os
    boot_time = $guest.boot_time
    secure_boot = $guest.secure_boot
    tpm_present = $guest.tpm_present
    limitation = 'Guest-reported identity, not physical hardware or remote attestation.'
} | ConvertTo-Json -Depth 8
if (-not $passed) { throw 'Windows guest identity does not match the launched profile' }
