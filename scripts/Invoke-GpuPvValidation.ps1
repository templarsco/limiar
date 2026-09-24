[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Adapter,
    [Parameter(Mandatory = $true)][string]$Kernel,
    [string]$Initrd,
    [ValidateRange(1, 20)][int]$Cycles = 10
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$limiar = Join-Path $root 'target\release\limiar.exe'
if (-not $Initrd) { $Initrd = Join-Path $root '.limiar\images\linux-gpu-probe.initrd' }
$kernelPath = (Resolve-Path -LiteralPath $Kernel).Path
$initrdPath = (Resolve-Path -LiteralPath $Initrd).Path
$stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$reports = Join-Path $root ".limiar\validation\gpu-pv-$stamp"
New-Item -ItemType Directory -Path $reports | Out-Null
$before = @{}
foreach ($path in @($kernelPath, $initrdPath)) { $before[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }

function Invoke-Limiar([string]$File, [string[]]$Arguments) {
    $json = & $limiar --output (Join-Path $reports $File) @Arguments | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Limiar failed; inspect $reports\$File" }
    return $json | ConvertFrom-Json
}

Push-Location -LiteralPath $root
try {
    $hostBefore = Invoke-Limiar 'host-before.json' @('doctor')
    $nativeBefore = Invoke-Limiar 'native-before.json' @('gpu', 'test', '--adapter', $Adapter)
    $runs = @(
        for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
            $run = Invoke-Limiar "cycle-$cycle.json" @(
                'gpu', 'pv', 'probe', '--experimental', '--verify-rendering',
                '--adapter', $Adapter, '--kernel', $kernelPath, '--initrd', $initrdPath,
                '--timeout-seconds', '60'
            )
            if (-not ($run.success -and $run.gpu_request_accepted -and $run.guest_boot_verified `
                -and $run.guest_rendering_verified -and $run.guest_shutdown_verified -and $run.cleanup_verified)) {
                throw "Cycle $cycle did not satisfy every acceptance condition"
            }
            Write-Host "GPU-PV cycle $cycle/${Cycles}: pixels, graceful exit and cleanup verified."
            [ordered]@{ cycle = $cycle; success = $true; elapsed_ms = $run.elapsed_ms }
        }
    )
    $nativeAfter = Invoke-Limiar 'native-after.json' @('gpu', 'test', '--adapter', $Adapter)
    $hostAfter = Invoke-Limiar 'host-after.json' @('doctor')
    if ($hostBefore.display_routing.status -ne 'queried' -or $hostAfter.display_routing.status -ne 'queried' `
        -or @($hostBefore.display_routing.active_paths).Count -eq 0 -or @($hostAfter.display_routing.active_paths).Count -eq 0) {
        throw 'Active host display routing could not be verified'
    }
    foreach ($path in $before.Keys) {
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $before[$path]) {
            throw "Boot input changed: $path"
        }
    }
    $routesBefore = $hostBefore.display_routing.active_paths | Sort-Object adapter_index,source_id,target_id | ConvertTo-Json -Compress -Depth 4
    $routesAfter = $hostAfter.display_routing.active_paths | Sort-Object adapter_index,source_id,target_id | ConvertTo-Json -Compress -Depth 4
    if ($routesBefore -ne $routesAfter) { throw 'Active display routing changed during validation' }
    [ordered]@{
        schema_version = 1
        passed = $true
        scope = 'hcs_linux_gpu_pv_d3d12_clear_readback'
        cycles = $runs
        host_native_pixels_before = $nativeBefore.pixels_verified
        host_native_pixels_after = $nativeAfter.pixels_verified
        active_display_routes_unchanged = $true
        boot_input_hashes_unchanged = $true
        windows_guest_tested = $false
        combined_smbios_and_gpu_backend = $false
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $reports 'summary.json') -Encoding UTF8
} finally {
    Pop-Location
}
Write-Host "Evidence: $reports"
