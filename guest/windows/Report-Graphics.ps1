#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'graphics-config.json') -Raw | ConvertFrom-Json
if ($config.schema_version -ne 1 -or [guid](Get-CimInstance Win32_ComputerSystemProduct).UUID -ne [guid]$config.uuid) {
    throw 'Guest UUID mismatch'
}
$cli = Join-Path $PSScriptRoot 'limiar.exe'
if ((Get-FileHash -LiteralPath $cli).Hash.ToLowerInvariant() -ne $config.cli_sha256) { throw 'Guest CLI changed' }
function Invoke-Probe {
    param([string]$Arguments)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $cli
    $start.Arguments = $Arguments
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    try {
        if (-not $process.WaitForExit(20000)) {
            $process.Kill()
            $process.WaitForExit()
            throw 'Guest graphics probe timed out'
        }
        $text = $stdout.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw ("Guest graphics probe failed: " + $text + $stderr.GetAwaiter().GetResult()) }
        return $text | ConvertFrom-Json
    } finally { $process.Dispose() }
}
$report = [ordered]@{
    schema_version=1;scope='guest_reported_graphics';uuid=$config.uuid;owner_token=$config.owner_token
    driver_tag=$config.driver_tag;boot_time=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    passed=$false;error=$null;adapters=@();render=$null
    display=@(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,PNPDeviceID,ConfigManagerErrorCode)
}
try {
    $inventory = Invoke-Probe 'gpu list'
    $report.adapters = $inventory.adapters
    $selected = @($inventory.adapters | Where-Object { $_.vendor_id -eq 0x1af4 -and -not $_.software })
    if ($selected.Count -ne 1) { throw 'Expected exactly one non-software VirtIO DXGI adapter' }
    $report.render = Invoke-Probe ("gpu test --adapter {0} --iterations 3" -f [uint32]$selected[0].index)
    $report.passed = $report.render.status -eq 'passed' -and -not $report.render.adapter.software
} catch { $report.error = $_.Exception.Message }
$json = $report | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'graphics.json'), $json, [Text.UTF8Encoding]::new($false))
$payload = 'LIMIAR_GRAPHICS_V1 ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
if ($payload.Length -gt 131072) { throw 'Graphics report exceeds the serial bound' }
$port = [IO.Ports.SerialPort]::new('COM1',115200)
$port.WriteTimeout = 5000
try { $port.Open(); $port.WriteLine($payload) } finally { $port.Dispose() }
$json
