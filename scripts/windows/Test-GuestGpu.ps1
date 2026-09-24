#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LabPath,
    [ValidateRange(1, 20)][int]$Cycles = 3
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Common.psm1') -Force
$lab = Read-LimiarWindowsLab $LabPath
if ($lab.Record.status -notin @('gpu_attached', 'gpu_verified')) { throw 'The lab has no tracked GPU-PV attachment' }
$interface = $lab.Record.gpu.device_interface
if ($interface -notmatch 'VEN_([0-9A-Fa-f]{4})&DEV_([0-9A-Fa-f]{4})') { throw 'Invalid PCI identity in the tracked GPU path' }
$vendor = [Convert]::ToUInt32($Matches[1], 16)
$device = [Convert]::ToUInt32($Matches[2], 16)
$credential = Get-LimiarGuestCredential $lab
$deadline = [DateTime]::UtcNow.AddMinutes(5)
do {
    try {
        $session = New-PSSession -VMId ([guid]$lab.Record.vm_id) -Credential $credential -ErrorAction Stop
        break
    } catch {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Guest PowerShell session did not become available after GPU attach' }
        Start-Sleep -Seconds 5
    }
} while ($true)
try {
    $json = Invoke-Command -Session $session -ScriptBlock {
        param($Name, $Uuid, $Vendor, $Device, $Cycles)
        $ErrorActionPreference = 'Stop'
        $system = Get-CimInstance Win32_ComputerSystemProduct
        if ($env:COMPUTERNAME -ne $Name -or $system.UUID -ne $Uuid) { throw 'GPU test refused: wrong guest' }
        $list = & C:\Limiar\limiar.exe gpu list | Out-String
        if ($LASTEXITCODE -ne 0) { throw 'Guest DXGI enumeration failed' }
        $inventory = $list | ConvertFrom-Json
        $adapters = @($inventory.adapters | Where-Object { -not $_.software -and $_.vendor_id -eq $Vendor -and $_.device_id -eq $Device })
        if ($adapters.Count -eq 0 -or $adapters.Count -gt 8) { throw "No bounded set of matching guest adapters $Vendor/$Device; observed $list" }
        $runs = @(
            foreach ($adapter in $adapters) {
            for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
                $result = & C:\Limiar\limiar.exe gpu test --adapter ([string]$adapter.index) --iterations 3 | Out-String
                if ($LASTEXITCODE -ne 0) { throw "Guest D3D11 test failed: $result" }
                $parsed = $result | ConvertFrom-Json
                if ($parsed.pixels_verified -ne 12288 -or $parsed.adapter.index -ne $adapter.index `
                    -or $parsed.adapter.luid -ne $adapter.luid -or $parsed.adapter.vendor_id -ne $Vendor `
                    -or $parsed.adapter.device_id -ne $Device -or $parsed.adapter.software) {
                    throw 'Guest GPU result did not match the requested hardware workload'
                }
                $parsed
            }
            }
        )
        $os = Get-CimInstance Win32_OperatingSystem
        $secureBoot = Confirm-SecureBootUEFI
        $tpm = Get-CimInstance -Namespace root\CIMV2\Security\MicrosoftTpm -ClassName Win32_Tpm
        if (-not $secureBoot -or -not $tpm.IsEnabled_InitialValue) { throw 'Guest Secure Boot/vTPM state changed' }
        [ordered]@{
            schema_version = 1
            scope = 'windows_guest_gpu_pv_d3d11'
            passed = $true
            computer_name = $env:COMPUTERNAME
            system_uuid = $system.UUID
            os = $os.Caption
            secure_boot = [bool]$secureBoot
            tpm_enabled = [bool]$tpm.IsEnabled_InitialValue
            tpm_version = $tpm.SpecVersion
            adapters = $adapters
            cycles_per_adapter = $Cycles
            cycles = $runs
            limitation = 'Nested CLI reports are process-local native API tests executed inside this verified guest, not host-side GPU tests.'
        } | ConvertTo-Json -Depth 10
    } -ArgumentList $lab.Record.computer_name, $lab.Record.bios_guid, $vendor, $device, $Cycles
    $json | Set-Content -LiteralPath (Join-Path $lab.Directory 'windows-gpu.json') -Encoding UTF8
    $lab.Record.status = 'gpu_verified'
    Write-LimiarWindowsLab $lab
    $json
} finally { Remove-PSSession -Session $session }
