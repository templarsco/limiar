#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\qemu\Smbios.psm1') -Force
$assertions = 0
function Assert-Equal {
    param($Actual, $Expected)
    if ($Actual -cne $Expected) { throw "Expected '$Expected', observed '$Actual'" }
    $script:assertions++
}
function Assert-Rejected {
    param([byte[]]$Bytes)
    $failed = $false
    try { [void](ConvertFrom-LimiarSmbios -Data $Bytes) } catch { $failed = $true }
    if (-not $failed) { throw 'Malformed SMBIOS fixture was accepted' }
    $script:assertions++
}
function New-Structure {
    param([byte[]]$Formatted, [string[]]$Strings)
    $bytes = [Collections.Generic.List[byte]]::new()
    $bytes.AddRange($Formatted)
    foreach ($string in $Strings) {
        $bytes.AddRange([Text.Encoding]::UTF8.GetBytes($string))
        $bytes.Add(0)
    }
    if ($Strings.Count -eq 0) { $bytes.Add(0) }
    $bytes.Add(0)
    return ,$bytes.ToArray()
}
function New-RawTable {
    param([byte[]]$Table)
    $raw = [byte[]]::new(8 + $Table.Length)
    $raw[1] = 3
    $raw[2] = 2
    [BitConverter]::GetBytes([uint32]$Table.Length).CopyTo($raw, 4)
    $Table.CopyTo($raw, 8)
    return ,$raw
}
$bios = [byte[]]::new(24)
$bios[0] = 0
$bios[1] = 24
$bios[4] = 1
$bios[5] = 2
$bios[8] = 3
$bios[19] = 8
$bios[21] = 5
$system = [byte[]]::new(27)
$system[0] = 1
$system[1] = 27
$system[4] = 1
$system[5] = 2
$system[6] = 3
$system[7] = 4
$uuid = [guid]'00112233-4455-6677-8899-aabbccddeeff'
$uuid.ToByteArray().CopyTo($system, 8)
$system[25] = 5
$system[26] = 6
$board = [byte[]]::new(15)
$board[0] = 2
$board[1] = 15
$board[4] = 1
$board[5] = 2
$board[6] = 3
$board[7] = 4
$board[8] = 5
$board[10] = 6
$chassis = [byte[]]::new(22)
$chassis[0] = 3
$chassis[1] = 22
$chassis[4] = 1
$chassis[5] = 3
$chassis[6] = 2
$chassis[7] = 3
$chassis[8] = 4
$chassis[21] = 5
$table = [Collections.Generic.List[byte]]::new()
$table.AddRange((New-Structure $bios @('Limiar','UEFI 0.5','09/24/2026')))
$table.AddRange((New-Structure $system @('Limiar','One','1.0','SERIAL','LMR-ONE','Desktop')))
$table.AddRange((New-Structure $board @('Limiar','Mainboard','1.0','BOARD','BOARD-ASSET','Mainboard')))
$table.AddRange((New-Structure $chassis @('Limiar','Desktop','CHASSIS','CHASSIS-ASSET','LMR-DESKTOP')))
$end = [byte[]]@(127,4,255,255,0,0)
$table.AddRange($end)
$raw = New-RawTable $table.ToArray()
$fields = ConvertFrom-LimiarSmbios -Data $raw
Assert-Equal $fields.Count 23
Assert-Equal $fields.bios_vendor 'Limiar'
Assert-Equal $fields.bios_release '0.5'
Assert-Equal $fields.bios_uefi 'true'
Assert-Equal $fields.product_uuid $uuid.ToString()
Assert-Equal $fields.board_asset_tag 'BOARD-ASSET'
Assert-Equal $fields.board_location 'Mainboard'
Assert-Equal $fields.chassis_sku 'LMR-DESKTOP'
$legacy = $raw.Clone()
$legacy[1] = 2
$legacy[2] = 5
$systemOffset = 8 + (New-Structure $bios @('Limiar','UEFI 0.5','09/24/2026')).Length
[Array]::Reverse($legacy, ($systemOffset + 8), 4)
[Array]::Reverse($legacy, ($systemOffset + 12), 2)
[Array]::Reverse($legacy, ($systemOffset + 14), 2)
Assert-Equal (ConvertFrom-LimiarSmbios -Data $legacy).product_uuid $uuid.ToString()
Assert-Rejected ([byte[]]@(0,1,2))
$invalid = $raw.Clone()
$invalid[9] = 3
Assert-Rejected $invalid
$invalid = $raw.Clone()
$invalid[12] = 99
Assert-Rejected $invalid
Assert-Rejected (New-RawTable ([byte[]]@(0,4,0,0,65,66)))
Assert-Rejected (New-RawTable (New-Structure $bios @('Limiar','UEFI 0.5','09/24/2026')))
$duplicate = [Collections.Generic.List[byte]]::new()
$duplicate.AddRange((New-Structure $bios @('Limiar','UEFI 0.5','09/24/2026')))
$duplicate.AddRange((New-Structure $bios @('Limiar','UEFI 0.5','09/24/2026')))
$duplicate.AddRange($end)
Assert-Rejected (New-RawTable $duplicate.ToArray())
"QEMU SMBIOS parser: $assertions assertions passed."
