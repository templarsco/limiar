#requires -Version 7.0
Set-StrictMode -Version Latest

function ConvertFrom-LimiarSmbios {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][byte[]]$Data)
    if ($Data.Length -lt 8 -or $Data.Length -gt 1048576) { throw 'Invalid RawSMBIOSData size' }
    $size = [BitConverter]::ToUInt32($Data, 4)
    if ($size -gt $Data.Length - 8) { throw 'Truncated SMBIOS table data' }
    $limit = 8 + $size
    $offset = 8
    $fields = [ordered]@{}
    $seen = [Collections.Generic.HashSet[int]]::new()
    $terminated = $false
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    while ($offset -lt $limit) {
        if ($limit - $offset -lt 4) { throw 'Truncated SMBIOS structure header' }
        $kind = [int]$Data[$offset]
        $length = [int]$Data[$offset + 1]
        if ($length -lt 4 -or $length -gt $limit - $offset) { throw 'Invalid SMBIOS structure length' }
        $stringStart = $offset + $length
        $stringEnd = $stringStart
        while ($stringEnd + 1 -lt $limit -and -not ($Data[$stringEnd] -eq 0 -and $Data[$stringEnd + 1] -eq 0)) {
            $stringEnd++
        }
        if ($stringEnd + 1 -ge $limit) { throw 'Unterminated SMBIOS string set' }
        $strings = @()
        if ($stringEnd -gt $stringStart) {
            $strings = @($encoding.GetString($Data, $stringStart, ($stringEnd - $stringStart)).Split([char]0))
        }
        if ($kind -le 3 -and -not $seen.Add($kind)) { throw "Ambiguous duplicate SMBIOS type $kind" }
        $mapping = switch ($kind) {
            0 { @(@('bios_vendor',4), @('bios_version',5), @('bios_date',8)) }
            1 { @(@('sys_vendor',4), @('product_name',5), @('product_version',6),
                @('product_serial',7), @('product_sku',25), @('product_family',26)) }
            2 { @(@('board_vendor',4), @('board_name',5), @('board_version',6),
                @('board_serial',7), @('board_asset_tag',8), @('board_location',10)) }
            3 { @(@('chassis_vendor',4), @('chassis_version',6), @('chassis_serial',7),
                @('chassis_asset_tag',8)) }
            default { @() }
        }
        foreach ($entry in $mapping) {
            $position = [int]$entry[1]
            if ($position -ge $length) { continue }
            $index = [int]$Data[$offset + $position]
            if ($index -gt $strings.Count) { throw 'SMBIOS string index is outside its string set' }
            $fields[$entry[0]] = if ($index -eq 0) { '' } else { $strings[$index - 1] }
        }
        if ($kind -eq 0) {
            if ($length -ge 22) { $fields.bios_release = "$($Data[$offset + 20]).$($Data[$offset + 21])" }
            if ($length -ge 20) { $fields.bios_uefi = (($Data[$offset + 19] -band 8) -ne 0).ToString().ToLowerInvariant() }
        } elseif ($kind -eq 1 -and $length -ge 24) {
            $uuid = [byte[]]::new(16)
            [Array]::Copy($Data, ($offset + 8), $uuid, 0, 16)
            if ($Data[1] -lt 2 -or ($Data[1] -eq 2 -and $Data[2] -lt 6)) {
                [Array]::Reverse($uuid, 0, 4)
                [Array]::Reverse($uuid, 4, 2)
                [Array]::Reverse($uuid, 6, 2)
            }
            $fields.product_uuid = [guid]::new($uuid).ToString()
        } elseif ($kind -eq 3 -and $length -ge 21) {
            $count = [int]$Data[$offset + 19]
            $recordLength = [int]$Data[$offset + 20]
            if ($count -gt 0 -and $recordLength -eq 0) { throw 'Invalid chassis contained-record length' }
            $skuOffset = 21 + $count * $recordLength
            if ($skuOffset -gt $length) { throw 'Chassis contained records exceed the structure' }
            if ($skuOffset -lt $length) {
                $index = [int]$Data[$offset + $skuOffset]
                if ($index -gt $strings.Count) { throw 'Chassis SKU string index is invalid' }
                $fields.chassis_sku = if ($index -eq 0) { '' } else { $strings[$index - 1] }
            }
        }
        $offset = $stringEnd + 2
        if ($kind -eq 127) {
            $terminated = $true
            break
        }
    }
    if (-not $terminated) { throw 'SMBIOS end-of-table structure was not found' }
    return $fields
}

Export-ModuleMember -Function ConvertFrom-LimiarSmbios
