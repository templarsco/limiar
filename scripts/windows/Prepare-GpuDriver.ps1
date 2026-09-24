#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LabPath,
    [Parameter(Mandatory = $true)][string]$Adapter
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Common.psm1') -Force
$lab = Read-LimiarWindowsLab $LabPath
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$inventory = & (Join-Path $root 'scripts\gpu-pv-inventory.ps1') | ConvertFrom-Json
if ($inventory.status -ne 'queried') { throw 'Partitionable GPU inventory is unavailable' }
$matches = @($inventory.adapters | Where-Object {
    $_.device_interface -eq $Adapter -or $_.name.IndexOf($Adapter, [StringComparison]::OrdinalIgnoreCase) -ge 0
})
if ([string]::IsNullOrWhiteSpace($Adapter) -or $matches.Count -ne 1) { throw 'Select exactly one partitionable GPU' }
$gpu = $matches[0]
$parts = $gpu.device_interface.Substring(4).Split('#')
if ($parts.Count -lt 4 -or $parts[0] -ne 'PCI') { throw 'Expected a PCI GPU device interface' }
$instance = $parts[0..2] -join '\'
$serviceName = (Get-PnpDeviceProperty -InstanceId $instance -KeyName DEVPKEY_Device_Service).Data
if ($serviceName -notmatch '^[a-zA-Z0-9_-]{1,128}$') { throw 'Invalid GPU service identifier' }
$imagePath = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName").ImagePath
$imagePath = [Environment]::ExpandEnvironmentVariables($imagePath).Trim('"')
if ($imagePath.StartsWith('\SystemRoot\', [StringComparison]::OrdinalIgnoreCase)) {
    $imagePath = Join-Path $env:SystemRoot $imagePath.Substring(12)
}
if ($imagePath.StartsWith('\??\')) { $imagePath = $imagePath.Substring(4) }
$imagePath = [IO.Path]::GetFullPath($imagePath)
$repository = [IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'))
if (-not $imagePath.StartsWith($repository + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'GPU service image is not in the Windows driver store'
}
$package = Get-Item -LiteralPath ([IO.Path]::GetDirectoryName($imagePath))
while ($package.Parent.FullName -ne $repository) { $package = $package.Parent }
$files = @(Get-ChildItem -LiteralPath $package.FullName -Recurse -File |
    Where-Object { $_.Extension -notin @('.log', '.etl', '.tmp') })
if ($files.Count -eq 0 -or $files.Count -gt 10000 -or ($files | Measure-Object Length -Sum).Sum -gt 3GB) {
    throw 'Unexpected GPU driver package size'
}
if (@(Get-ChildItem -LiteralPath $package.FullName -Recurse | Where-Object {
    $_.Attributes -band [IO.FileAttributes]::ReparsePoint
}).Count -gt 0) { throw 'Driver package contains reparse points' }

$payload = Join-Path $lab.Directory 'gpu-payload'
$iso = Join-Path $lab.Directory 'gpu-payload.iso'
if (Test-Path -LiteralPath $payload) { throw 'GPU payload already exists; refusing to replace it' }
$target = Join-Path $payload "Windows\System32\HostDriverStore\FileRepository\$($package.Name)"
[void][IO.Directory]::CreateDirectory($target)
$hashes = @(
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($package.FullName, $file.FullName)
        $destination = Join-Path $target $relative
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        [IO.File]::Copy($file.FullName, $destination, $false)
        $hash = (Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        if ((Get-FileHash -LiteralPath $destination).Hash.ToLowerInvariant() -ne $hash) {
            throw 'A driver file changed while preparing the payload'
        }
        [ordered]@{path=$relative;sha256=$hash;bytes=$file.Length}
    }
)
$manifest = [ordered]@{
    schema_version = 1
    owner_token = $lab.Record.owner_token
    adapter_name = $gpu.name
    device_interface = $gpu.device_interface
    driver_version = $gpu.driver_version
    package = $package.Name
    files = $hashes
    contains_credentials = $false
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $payload 'driver-manifest.json') -Encoding UTF8
$python = Join-Path $root '.limiar\tools\iso\Scripts\python.exe'
$built = & $python (Join-Path $PSScriptRoot 'build_iso.py') $payload $iso --label LIMIAR_GPU | Out-String
if ($LASTEXITCODE -ne 0) { throw 'GPU payload ISO build failed' }
$lab.Record.gpu = @{
    adapter_name = $gpu.name
    device_interface = $gpu.device_interface
    driver_version = $gpu.driver_version
    package = $package.Name
}
$lab.Record.gpu_payload_iso = $iso
Write-LimiarWindowsLab $lab
[ordered]@{status='driver_payload_ready';adapter=$gpu.name;driver_version=$gpu.driver_version;files=$files.Count;bytes=($files|Measure-Object Length -Sum).Sum} | ConvertTo-Json
