$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

try {
    if (-not (Get-Command Get-VMHostPartitionableGpu -ErrorAction SilentlyContinue)) {
        throw 'The Hyper-V PowerShell GPU inventory command is not installed.'
    }
    $displays = @(Get-CimInstance Win32_VideoController)
    $devices = @(
        foreach ($gpu in @(Get-VMHostPartitionableGpu -ErrorAction Stop)) {
            $interface = [string]$gpu.Name
            $parts = $interface.Substring(4).Split('#')
            $instance = if ($parts.Count -ge 3) { $parts[0..2] -join '\' } else { '' }
            $display = @($displays | Where-Object { $_.PNPDeviceID -eq $instance })
            $name = if ($display.Count -eq 1) { [string]$display[0].Name } else { $interface }
            $driver = if ($display.Count -eq 1) { [string]$display[0].DriverVersion } else { $null }
            $quotas = [ordered]@{}
            foreach ($resource in @('VRAM', 'Encode', 'Decode', 'Compute')) {
                $values = [ordered]@{}
                foreach ($prefix in @('Total', 'Available', 'MinPartition', 'MaxPartition', 'OptimalPartition')) {
                    $property = $prefix + $resource
                    $values[$prefix] = [string]$gpu.$property
                }
                $quotas[$resource] = $values
            }
            [ordered]@{
                name = $name
                device_interface = $interface
                driver_version = $driver
                partition_count = [uint32]$gpu.PartitionCount
                valid_partition_counts = @($gpu.ValidPartitionCounts | ForEach-Object { [uint32]$_ })
                raw_quotas = $quotas
            }
        }
    )
    [ordered]@{
        schema_version = 1
        status = 'queried'
        adapters = $devices
        error = $null
        limitations = @(
            'Advertised capability only; guest rendering has not been verified.'
            'Raw quota values are driver-defined units, not physical VRAM bytes or guaranteed shares.'
            'A partition count is not a guarantee that that many usable VMs can run.'
            'Windows client / consumer Radeon GPU-PV is an experimental compatibility target.'
        )
    } | ConvertTo-Json -Depth 7
} catch {
    [ordered]@{
        schema_version = 1
        status = 'unknown'
        adapters = @()
        error = $_.Exception.Message
        limitations = @('An unavailable query does not establish that the hardware lacks GPU-PV.')
    } | ConvertTo-Json -Depth 4
}
