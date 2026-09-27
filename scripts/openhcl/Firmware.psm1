#requires -Version 7.0
# SPDX-FileCopyrightText: 2026 SANSI GROUP
# SPDX-License-Identifier: LicenseRef-Limiar-Private-Use-1.0
Set-StrictMode -Version Latest

function Assert-FirmwareKeys {
    param($Value, [string[]]$Keys, [string]$Name)
    if ($Value -isnot [Collections.IDictionary] -or $Value.Count -ne $Keys.Count) {
        throw "Invalid fields in $Name"
    }
    foreach ($key in $Value.Keys) {
        if ($Keys -cnotcontains $key) { throw "Unsupported field in ${Name}: $key" }
    }
}

function Assert-FirmwareInteger {
    param($Value, [uint64]$Maximum, [string]$Name)
    if (($Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [uint32]) -or
        $Value -lt 0 -or $Value -gt $Maximum) {
        throw "Invalid integer: $Name"
    }
}

function ConvertTo-FirmwareSignature {
    param([string]$Value)
    $bytes = [Text.Encoding]::ASCII.GetBytes($Value)
    [Array]::Reverse($bytes)
    return '0x' + [BitConverter]::ToString($bytes).Replace('-', '')
}

function ConvertTo-LimiarMachineDefines {
    param([Collections.IDictionary]$Machine)
    Assert-FirmwareKeys $Machine @('system', 'baseboard', 'chassis') 'machine'
    $sections = [ordered]@{
        system = [ordered]@{
            manufacturer = 'SYSTEM_MANUFACTURER'; product_name = 'SYSTEM_PRODUCT_NAME'
            version = 'SYSTEM_VERSION'; sku_number = 'SYSTEM_SKU_NUMBER'; family = 'SYSTEM_FAMILY'
        }
        baseboard = [ordered]@{
            manufacturer = 'BASEBOARD_MANUFACTURER'; product_name = 'BASEBOARD_PRODUCT_NAME'
            version = 'BASEBOARD_VERSION'; asset_tag = 'BASEBOARD_ASSET_TAG'; location = 'BASEBOARD_LOCATION'
        }
        chassis = [ordered]@{
            manufacturer = 'CHASSIS_MANUFACTURER'; version = 'CHASSIS_VERSION'
            asset_tag = 'CHASSIS_ASSET_TAG'; sku_number = 'CHASSIS_SKU_NUMBER'; type = 'CHASSIS_TYPE'
        }
    }
    $defines = [Collections.Generic.List[string]]::new()
    foreach ($section in $sections.Keys) {
        $values = $Machine[$section]
        $fields = $sections[$section]
        if ($values -isnot [Collections.IDictionary]) { throw "Invalid machine section: $section" }
        foreach ($key in $values.Keys) {
            if ($fields.Keys -cnotcontains $key) { throw "Unsupported field in machine.${section}: $key" }
        }
        foreach ($key in $fields.Keys) {
            if (-not $values.Contains($key)) { continue }
            $value = $values[$key]
            $macro = 'LIMIAR_' + $fields[$key]
            if ($section -ceq 'chassis' -and $key -ceq 'type') {
                Assert-FirmwareInteger $value 0x24 'machine.chassis.type'
                if ($value -lt 1) { throw 'Invalid machine.chassis.type' }
                $defines.Add("#define $macro $value")
            } else {
                if ($value -isnot [string] -or $value -cnotmatch '\A[A-Za-z0-9 ._,()+/-]{1,64}\z' -or
                    [string]::IsNullOrWhiteSpace($value)) { throw "Invalid machine string: ${section}.$key" }
                $defines.Add('#define ' + $macro + ' "' + $value + '"')
            }
        }
    }
    return $defines -join "`n"
}

function ConvertTo-LimiarFirmwareFiles {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Profile)

    if (-not $Profile.Contains('schema_version')) { throw 'Missing firmware profile version' }
    Assert-FirmwareInteger $Profile.schema_version 2 'schema_version'
    if ($Profile.schema_version -notin @(1, 2)) { throw 'Unsupported firmware profile version' }
    $keys = @('schema_version', 'bios', 'acpi')
    if ($Profile.schema_version -eq 2) { $keys += 'machine' }
    Assert-FirmwareKeys $Profile $keys 'profile'
    $machineDefines = if ($Profile.schema_version -eq 2) {
        if ($Profile.machine -isnot [Collections.IDictionary]) { throw 'Invalid machine profile' }
        ConvertTo-LimiarMachineDefines $Profile.machine
    } else { '' }
    $bios = $Profile.bios
    $acpi = $Profile.acpi
    Assert-FirmwareKeys $bios @('vendor', 'version', 'release_date', 'release_major',
        'release_minor', 'virtual_machine') 'bios'
    $acpiKeys = @('oem_id', 'oem_table_id', 'oem_revision', 'creator_id', 'creator_revision')
    $platformDefine = ''
    if ($Profile.schema_version -eq 2 -and $acpi -is [Collections.IDictionary] -and
        $acpi.Contains('preferred_pm_profile')) {
        $acpiKeys += 'preferred_pm_profile'
        Assert-FirmwareInteger $acpi.preferred_pm_profile 8 'acpi.preferred_pm_profile'
        $platformDefine = "#define LIMIAR_ACPI_PREFERRED_PM_PROFILE $($acpi.preferred_pm_profile)"
    }
    Assert-FirmwareKeys $acpi $acpiKeys 'acpi'

    foreach ($key in @('vendor', 'version')) {
        if ($bios[$key] -isnot [string] -or
            $bios[$key] -cnotmatch '\A[A-Za-z0-9 ._,()+/-]{1,64}\z' -or
            [string]::IsNullOrWhiteSpace($bios[$key])) {
            throw "Invalid BIOS string: $key"
        }
    }
    $date = [DateTime]::MinValue
    if ($bios.release_date -isnot [string] -or
        $bios.release_date -cnotmatch '\A[0-9]{2}/[0-9]{2}/[0-9]{4}\z' -or
        -not [DateTime]::TryParseExact($bios.release_date, 'MM/dd/yyyy',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$date)) {
        throw 'Invalid BIOS release date; use MM/dd/yyyy'
    }
    Assert-FirmwareInteger $bios.release_major 255 'release_major'
    Assert-FirmwareInteger $bios.release_minor 255 'release_minor'
    if ($bios.virtual_machine -isnot [bool]) { throw 'virtual_machine must be a boolean' }

    foreach ($field in @(@('oem_id', 6), @('oem_table_id', 8), @('creator_id', 4))) {
        $key, $length = $field
        if ($acpi[$key] -isnot [string] -or $acpi[$key].Length -ne $length -or
            $acpi[$key] -cnotmatch '\A[A-Za-z0-9_ -]+\z' -or
            [string]::IsNullOrWhiteSpace($acpi[$key])) {
            throw "ACPI $key must contain exactly $length printable identifier bytes"
        }
    }
    Assert-FirmwareInteger $acpi.oem_revision ([uint32]::MaxValue) 'oem_revision'
    Assert-FirmwareInteger $acpi.creator_revision ([uint32]::MaxValue) 'creator_revision'
    $tableId = ConvertTo-FirmwareSignature $acpi.oem_table_id
    $creatorId = ConvertTo-FirmwareSignature $acpi.creator_id
    $oemRevision = '0x{0:X8}' -f $acpi.oem_revision
    $creatorRevision = '0x{0:X8}' -f $acpi.creator_revision
    # Keep target-content distribution and UEFI bits independent from bit 4.
    $extension = if ($bios.virtual_machine) { '0x1C' } else { '0x0C' }

    $header = @"
/* Generated from a validated Limiar firmware profile. */
#ifndef LIMIAR_FIRMWARE_PROFILE_H
#define LIMIAR_FIRMWARE_PROFILE_H
#define LIMIAR_BIOS_VENDOR "$($bios.vendor)"
#define LIMIAR_BIOS_VERSION "$($bios.version)"
#define LIMIAR_BIOS_DATE "$($bios.release_date)"
#define LIMIAR_BIOS_RELEASE_MAJOR $($bios.release_major)
#define LIMIAR_BIOS_RELEASE_MINOR $($bios.release_minor)
#define LIMIAR_BIOS_CHARACTERISTICS_EXT2 $extension
#define LIMIAR_ACPI_OEM_ID "$($acpi.oem_id)"
#define LIMIAR_ACPI_OEM_TABLE_ID ${tableId}ULL
#define LIMIAR_ACPI_OEM_REVISION $oemRevision
#define LIMIAR_ACPI_CREATOR_ID $creatorId
#define LIMIAR_ACPI_CREATOR_REVISION $creatorRevision
#endif
"@
    if ($machineDefines) { $header = $header.Replace('#endif', "$machineDefines`n#endif") }
    if ($platformDefine) { $header = $header.Replace('#endif', "$platformDefine`n#endif") }
    $dsc = @"
# Generated from the same profile as LimiarFirmwareProfile.h.
  gEfiMdeModulePkgTokenSpaceGuid.PcdFirmwareVendor|L"$($bios.vendor)"
  gEfiMdeModulePkgTokenSpaceGuid.PcdAcpiDefaultOemId|"$($acpi.oem_id)"
  gEfiMdeModulePkgTokenSpaceGuid.PcdAcpiDefaultOemTableId|$tableId
  gEfiMdeModulePkgTokenSpaceGuid.PcdAcpiDefaultOemRevision|$oemRevision
  gEfiMdeModulePkgTokenSpaceGuid.PcdAcpiDefaultCreatorId|$creatorId
  gEfiMdeModulePkgTokenSpaceGuid.PcdAcpiDefaultCreatorRevision|$creatorRevision
"@
    return [pscustomobject]@{
        Header = $header.Replace("`r`n", "`n") + "`n"
        Dsc = $dsc.Replace("`r`n", "`n") + "`n"
    }
}

function Resolve-LimiarFirmwarePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )
    $root = [IO.Path]::GetFullPath($ProjectRoot)
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $resolved.StartsWith($root + [IO.Path]::DirectorySeparatorChar,
            $comparison)) {
        throw "Path must be inside the project: $resolved"
    }
    $item = Get-Item -LiteralPath $resolved -Force
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Reparse points are not accepted: $($item.FullName)"
        }
        $item = if ($item -is [IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
    }
    return $resolved
}

Export-ModuleMember -Function ConvertTo-LimiarFirmwareFiles,Resolve-LimiarFirmwarePath
