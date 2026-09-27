#requires -Version 7.0
# SPDX-FileCopyrightText: 2026 SANSI GROUP
# SPDX-License-Identifier: LicenseRef-Limiar-Private-Use-1.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\scripts\openhcl\Firmware.psm1') -Force
$path = Join-Path $PSScriptRoot '..\profiles\openhcl\limiar-reference.json'
$text = Get-Content -LiteralPath $path -Raw
$profile = $text | ConvertFrom-Json -AsHashtable
$assertions = 0
function Assert-True {
    param([bool]$Value, [string]$Name)
    if (-not $Value) { throw "Assertion failed: $Name" }
    $script:assertions++
}
function Assert-Rejected {
    param([scriptblock]$Mutate, [string]$Name)
    $candidate = $text | ConvertFrom-Json -AsHashtable
    & $Mutate $candidate
    $rejected = $false
    try { [void](ConvertTo-LimiarFirmwareFiles $candidate) } catch { $rejected = $true }
    Assert-True $rejected $Name
}

$files = ConvertTo-LimiarFirmwareFiles $profile
Assert-True ($text -cnotmatch '[^\x00-\x7F]') 'reference contains only ASCII'
Assert-True ($profile.schema_version -eq 2) 'machine schema selected'
Assert-True ($profile.bios.vendor -ceq 'Limiar') 'neutral BIOS vendor'
Assert-True ($profile.bios.version -ceq 'Limiar OpenHCL 0.2') 'neutral BIOS version'
Assert-True ($profile.bios.release_date -ceq '09/27/2026') 'explicit reference date'
Assert-True ($profile.bios.virtual_machine -eq $true) 'VM characteristic retained by default'
Assert-True ($profile.acpi.oem_id -ceq 'LIMIAR') 'neutral ACPI OEM'
Assert-True ($profile.acpi.oem_table_id -ceq 'LMRBOARD') 'neutral ACPI table'
Assert-True ($profile.acpi.creator_id -ceq 'LMAR') 'neutral ACPI creator'
Assert-True ($profile.acpi.preferred_pm_profile -eq 1) 'desktop power profile'
Assert-True (-not $profile.acpi.Contains('profile_replacement_headers')) 'replacement-header policy not selected'
Assert-True (-not $profile.acpi.Contains('waet_enabled')) 'WAET policy not selected'

$expected = [ordered]@{
    system = [ordered]@{
        manufacturer = 'Limiar'; product_name = 'Limiar Virtual Desktop'
        version = '1.0'; sku_number = 'LIMIAR-DESKTOP-REF'; family = 'Limiar Desktop'
    }
    baseboard = [ordered]@{
        manufacturer = 'Limiar'; product_name = 'Limiar Reference Board'
        version = '1.0'; asset_tag = 'Limiar Reference'; location = 'Limiar System Board'
    }
    chassis = [ordered]@{
        manufacturer = 'Limiar'; version = '1.0'; asset_tag = 'Limiar Reference'
        sku_number = 'LIMIAR-DESKTOP'; type = 3
    }
}
$lines = $files.Header -split "`n"
foreach ($section in $expected.Keys) {
    Assert-True ($profile.machine[$section].Count -eq $expected[$section].Count) "only reference fields: $section"
    foreach ($key in $expected[$section].Keys) {
        $value = $expected[$section][$key]
        Assert-True ($profile.machine[$section][$key] -ceq $value) "neutral value: $section.$key"
        $macro = 'LIMIAR_' + $section.ToUpperInvariant() + '_' + $key.ToUpperInvariant()
        $literal = if ($value -is [string]) { '"' + $value + '"' } else { [string]$value }
        $define = '#define ' + $macro + ' ' + $literal
        Assert-True (@($lines | Where-Object { $_ -ceq $define }).Count -eq 1) "generated reference field: $section.$key"
    }
}
Assert-True ($files.Header.Contains('#define LIMIAR_BIOS_CHARACTERISTICS_EXT2 0x1C')) 'VM bit emitted'
Assert-True ($files.Header.Contains('#define LIMIAR_ACPI_PREFERRED_PM_PROFILE 1')) 'desktop field emitted'
Assert-True ($files.Dsc.Contains('PcdFirmwareVendor|L"Limiar"')) 'UEFI vendor matches BIOS'
Assert-True (-not $files.Header.Contains('LIMIAR_ACPI_WAET_ENABLED')) 'upstream WAET behavior inherited'
Assert-True (-not $files.Header.Contains('LIMIAR_ACPI_PROFILE_REPLACEMENT_HEADERS')) 'upstream replacement behavior inherited'
Assert-True (-not $files.Header.Contains("`r") -and -not $files.Dsc.Contains("`r")) 'portable generated line endings'
$again = ConvertTo-LimiarFirmwareFiles $profile
Assert-True ($files.Header -ceq $again.Header -and $files.Dsc -ceq $again.Dsc) 'deterministic output'

$custom = $text | ConvertFrom-Json -AsHashtable
$custom.bios.vendor = 'Example Lab'
$custom.machine.system.product_name = 'Example Desktop'
$custom.machine.baseboard.manufacturer = 'Example Lab'
$customFiles = ConvertTo-LimiarFirmwareFiles $custom
Assert-True ($customFiles.Header.Contains('#define LIMIAR_SYSTEM_PRODUCT_NAME "Example Desktop"')) 'product can be customized'
Assert-True ($customFiles.Header.Contains('#define LIMIAR_BASEBOARD_MANUFACTURER "Example Lab"')) 'board can be customized'
Assert-True ($customFiles.Dsc.Contains('PcdFirmwareVendor|L"Example Lab"')) 'vendor can be customized'
$custom.machine.system.product_name = "Invalid`nProduct"
$rejected = $false
try { [void](ConvertTo-LimiarFirmwareFiles $custom) } catch { $rejected = $true }
Assert-True $rejected 'customization keeps input validation'
Assert-True ($profile.machine.system.product_name -ceq 'Limiar Virtual Desktop') 'customization leaves reference unchanged'

foreach ($name in @('profile_replacement_headers', 'waet_enabled')) {
    foreach ($value in @($true, $false)) {
        Assert-Rejected { param($p) $p.acpi[$name] = $value } 'experimental publication controls are not part of the public generator'
    }
}
foreach ($value in @($null, 'false', 0)) {
    Assert-Rejected { param($p) $p.bios.virtual_machine = $value } 'VM characteristic requires a boolean'
}
foreach ($value in @('', ' ', ('x' * 65), 'x"y', 'x\y')) {
    Assert-Rejected { param($p) $p.machine.baseboard.product_name = $value } 'invalid machine text rejected'
}
foreach ($value in @('02/30/2026', '2026-09-27', $null)) {
    Assert-Rejected { param($p) $p.bios.release_date = $value } 'invalid release date rejected'
}
foreach ($value in @(-1, 9, '1', $true)) {
    Assert-Rejected { param($p) $p.acpi.preferred_pm_profile = $value } 'invalid desktop enum rejected'
}
Assert-Rejected { param($p) $p.machine.system['serial_number'] = 'fixed' } 'fixed serial is outside the profile'
Assert-Rejected { param($p) $p.machine.system['uuid'] = 'fixed' } 'fixed UUID is outside the profile'
Assert-Rejected { param($p) $p.acpi.oem_id = 'TOO-LONG' } 'ACPI width validated'
Assert-Rejected { param($p) $p.bios.release_major = 256 } 'BIOS release range validated'
Assert-Rejected { param($p) $p['extra'] = 'unknown' } 'unknown top-level field rejected'

Write-Host "$assertions neutral Limiar profile assertions passed"
