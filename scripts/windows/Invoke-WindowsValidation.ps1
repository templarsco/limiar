#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LabPath,
    [ValidateRange(1, 5)][int]$BootCycles = 3
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Common.psm1') -Force
$lab = Read-LimiarWindowsLab $LabPath
if ($lab.Record.status -ne 'gpu_verified') { throw 'First verify the Windows GPU before repeated cold-boot tests' }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$cli = Join-Path $root 'target\portable\x86_64-pc-windows-msvc\release\limiar.exe'
$evidence = Join-Path $lab.Directory ('validation-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $evidence | Out-Null
function Invoke-HostCheck([string]$Name, [string[]]$Arguments) {
    $text = & $cli --output (Join-Path $evidence $Name) @Arguments | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Host check failed: $Name" }
    return $text | ConvertFrom-Json
}
$before = Invoke-HostCheck 'host-before.json' @('doctor')
$nativeBefore = Invoke-HostCheck 'native-before.json' @('gpu','test','--adapter',$lab.Record.gpu.adapter_name)
$runs = @(
    for ($cycle = 1; $cycle -le $BootCycles; $cycle++) {
        & (Join-Path $PSScriptRoot 'Stop-LabVm.ps1') -LabPath $LabPath | Out-Null
        & (Join-Path $PSScriptRoot 'Start-LabVm.ps1') -LabPath $LabPath | Out-Null
        $json = & (Join-Path $PSScriptRoot 'Test-GuestGpu.ps1') -LabPath $LabPath -Cycles 3 | Out-String
        $result = $json | ConvertFrom-Json
        if (-not $result.passed -or -not $result.secure_boot -or -not $result.tpm_enabled) {
            throw 'Cold-boot GPU/security validation failed'
        }
        $json | Set-Content -LiteralPath (Join-Path $evidence "boot-$cycle.json") -Encoding UTF8
        $pixels = ($result.cycles | Measure-Object pixels_verified -Sum).Sum
        Write-Host "Windows boot ${cycle}: $pixels guest pixels verified."
        [ordered]@{cycle=$cycle;adapters=$result.adapters.Count;gpu_tests=$result.cycles.Count;pixels_verified=$pixels;secure_boot=$true;tpm_enabled=$true}
    }
)
$nativeAfter = Invoke-HostCheck 'native-after.json' @('gpu','test','--adapter',$lab.Record.gpu.adapter_name)
$after = Invoke-HostCheck 'host-after.json' @('doctor')
if ($before.display_routing.status -ne 'queried' -or $after.display_routing.status -ne 'queried') {
    throw 'Host display routing could not be verified'
}
$routesBefore = $before.display_routing.active_paths | Sort-Object adapter_index,source_id,target_id | ConvertTo-Json -Compress
$routesAfter = $after.display_routing.active_paths | Sort-Object adapter_index,source_id,target_id | ConvertTo-Json -Compress
if ($routesBefore -ne $routesAfter) { throw 'Host display routes changed' }
$summary = [ordered]@{
    schema_version=1;passed=$true;scope='windows_guest_gpu_pv_cold_boot'
    boot_cycles=$runs;host_pixels_before=$nativeBefore.pixels_verified;host_pixels_after=$nativeAfter.pixels_verified
    host_display_routes_unchanged=$true;physical_gpu_dismounted=$false
    full_smbios_customization=$false
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $evidence 'summary.json') -Encoding UTF8
$summary | ConvertTo-Json -Depth 8
Write-Host "Evidence: $evidence"
