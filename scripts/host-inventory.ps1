$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$errors = [System.Collections.Generic.List[string]]::new()
$os = Get-CimInstance -ClassName Win32_OperatingSystem
$computer = Get-CimInstance -ClassName Win32_ComputerSystem
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$displays = @(
    foreach ($gpu in @(Get-CimInstance -ClassName Win32_VideoController)) {
        $locations = @()
        try {
            $property = Get-PnpDeviceProperty -InstanceId $gpu.PNPDeviceID `
                -KeyName 'DEVPKEY_Device_LocationPaths' -ErrorAction Stop
            $locations = @($property.Data)
        } catch {
            $errors.Add("GPU location query: $($_.Exception.Message)")
        }
        [ordered]@{
            name = $gpu.Name
            driver_version = $gpu.DriverVersion
            status = $gpu.Status
            instance_id = $gpu.PNPDeviceID
            location_paths = $locations
        }
    }
)

$dda = [ordered]@{
    status = 'unknown'
    devices = @()
    reason = 'Not queried'
}
try {
    if (-not (Get-Command Get-VMHostAssignableDevice -ErrorAction SilentlyContinue)) {
        throw 'Hyper-V device inventory command is not installed'
    }
    $devices = @(Get-VMHostAssignableDevice -ErrorAction Stop |
        Select-Object Name, InstancePath, LocationPath)
    $dda = [ordered]@{
        status = 'queried'
        devices = $devices
        reason = 'This lists host-assignable devices; it does not prove GPU assignment works.'
    }
} catch {
    $dda.reason = $_.Exception.Message
}

$security = $null
try {
    $guard = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' `
        -ClassName Win32_DeviceGuard -ErrorAction Stop
    $security = [ordered]@{
        virtualization_based_security_status = $guard.VirtualizationBasedSecurityStatus
        available_security_properties = @($guard.AvailableSecurityProperties)
        security_services_running = @($guard.SecurityServicesRunning)
    }
} catch {
    $errors.Add("Device Guard query: $($_.Exception.Message)")
}

[ordered]@{
    os = [ordered]@{
        caption = $os.Caption
        version = $os.Version
        build = $os.BuildNumber
        product_type = $os.ProductType
        architecture = $os.OSArchitecture
    }
    processor = @(Get-CimInstance -ClassName Win32_Processor | ForEach-Object { $_.Name })
    memory_bytes = $computer.TotalPhysicalMemory
    hypervisor_present = $computer.HypervisorPresent
    is_admin = $isAdmin
    displays = $displays
    dda_inventory = $dda
    device_guard = $security
    host_display_wiring = 'not_verified'
    errors = @($errors)
} | ConvertTo-Json -Depth 8
