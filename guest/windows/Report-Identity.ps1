#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f-]{36}$')][string]$OwnerToken,
    [string]$Directory = 'C:\Limiar\Custom'
)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LimiarFirmware {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint GetSystemFirmwareTable(uint provider, uint id, IntPtr buffer, uint size);
    public static byte[] Read() {
        const uint provider = 0x52534D42;
        uint size = GetSystemFirmwareTable(provider, 0, IntPtr.Zero, 0);
        if (size < 8 || size > 1048576) throw new InvalidOperationException("Invalid firmware table size");
        IntPtr buffer = Marshal.AllocHGlobal((int)size);
        try {
            uint read = GetSystemFirmwareTable(provider, 0, buffer, size);
            if (read != size) throw new InvalidOperationException("Firmware table size changed");
            byte[] result = new byte[size];
            Marshal.Copy(buffer, result, 0, (int)size);
            return result;
        } finally { Marshal.FreeHGlobal(buffer); }
    }
}
'@
[void][IO.Directory]::CreateDirectory($Directory)
try {
    $system = Get-CimInstance Win32_ComputerSystem
    $product = Get-CimInstance Win32_ComputerSystemProduct
    $bios = Get-CimInstance Win32_BIOS
    $board = Get-CimInstance Win32_BaseBoard
    $chassis = Get-CimInstance Win32_SystemEnclosure
    $os = Get-CimInstance Win32_OperatingSystem
    $secureBoot = $null
    $tpmPresent = $null
    try { $secureBoot = [bool](Confirm-SecureBootUEFI) } catch {}
    try { $tpmPresent = [bool](Get-Tpm).TpmPresent } catch {}
    $report = [ordered]@{
        schema_version = 1
        scope = 'guest_reported_identity'
        owner_token = $OwnerToken
        captured_at = [DateTime]::UtcNow.ToString('o')
        boot_time = $os.LastBootUpTime.ToUniversalTime().ToString('o')
        computer_name = $env:COMPUTERNAME
        os = [ordered]@{ caption = $os.Caption; version = $os.Version; build = $os.BuildNumber }
        system = [ordered]@{
            manufacturer = $system.Manufacturer; product = $system.Model
            version = $product.Version; serial = $product.IdentifyingNumber
            uuid = $product.UUID; sku = $system.SystemSKUNumber; family = $system.SystemFamily
        }
        bios = [ordered]@{
            vendor = $bios.Manufacturer; version = $bios.SMBIOSBIOSVersion
            date = $bios.ReleaseDate.ToUniversalTime().ToString('MM/dd/yyyy', [Globalization.CultureInfo]::InvariantCulture)
        }
        baseboard = @($board | Select-Object Manufacturer,Product,Version,SerialNumber)
        chassis = @($chassis | Select-Object Manufacturer,Version,SerialNumber,SMBIOSAssetTag,ChassisTypes)
        displays = @(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,PNPDeviceID)
        secure_boot = $secureBoot
        tpm_present = $tpmPresent
        raw_smbios_base64 = [Convert]::ToBase64String([LimiarFirmware]::Read())
    }
    $json = $report | ConvertTo-Json -Depth 8 -Compress
    [IO.File]::WriteAllText((Join-Path $Directory 'identity.json'), $json, [Text.UTF8Encoding]::new($false))
    $summary = @(
        'Limiar - Guest Identity'
        ''
        "Computer: $($report.computer_name)"
        "OS: $($os.Caption) $($os.Version)"
        "System: $($system.Manufacturer) / $($system.Model)"
        "BIOS: $($bios.Manufacturer) / $($bios.SMBIOSBIOSVersion)"
        "Board: $($board.Manufacturer) / $($board.Product)"
        "Chassis: $($chassis.Manufacturer) / $($chassis.Version)"
        "UUID: $($product.UUID)"
        "Serial: $($product.IdentifyingNumber)"
        "Secure Boot: $secureBoot"
        "TPM present: $tpmPresent"
        ''
        'This report describes this guest. It is not hardware attestation.'
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText('C:\Users\Public\Desktop\Limiar Identity.txt', $summary, [Text.UTF8Encoding]::new($false))
    $payload = 'LIMIAR_IDENTITY_V1 ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    if ($payload.Length -gt 131072) { throw 'Identity report exceeds serial limit' }
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    do {
        $port = [IO.Ports.SerialPort]::new('COM1', 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
        $port.WriteTimeout = 5000
        try {
            $port.Open()
            $port.WriteLine($payload)
            break
        } catch {
            if ([DateTime]::UtcNow -ge $deadline) { throw }
            Start-Sleep -Seconds 3
        } finally { $port.Dispose() }
    } while ($true)
} catch {
    [IO.File]::WriteAllText((Join-Path $Directory 'identity-error.txt'), $_.Exception.ToString())
    throw
}
