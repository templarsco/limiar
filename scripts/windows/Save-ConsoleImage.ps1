#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LabPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [ValidateSet(640, 1024)][int]$Width = 1024,
    [ValidateSet(400, 480, 640, 768)][int]$Height = 768
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Common.psm1') -Force
$lab = Read-LimiarWindowsLab $LabPath
if (Test-Path -LiteralPath $OutputPath) { throw 'Image output already exists' }
$settings = Get-LimiarVmSettings ([guid]$lab.Record.vm_id)
$service = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService
$result = Invoke-CimMethod -InputObject $service -MethodName GetVirtualSystemThumbnailImage `
    -Arguments @{TargetSystem=$settings;WidthPixels=[uint16]$Width;HeightPixels=[uint16]$Height}
if ($result.ReturnValue -ne 0) { throw "VM console capture failed: $($result.ReturnValue)" }
$pixels = $Width * $Height * 2
$offset = 0
if ($result.ImageData.Length -eq $pixels + 4) {
    # Newer Hyper-V builds prefix the RGB565 payload with its big-endian packet size.
    $prefix = [byte[]]$result.ImageData[0..3]
    [Array]::Reverse($prefix)
    if ([BitConverter]::ToUInt32($prefix, 0) -ne $result.ImageData.Length) { throw 'Invalid console image packet size' }
    $offset = 4
} elseif ($result.ImageData.Length -ne $pixels) {
    throw 'Unexpected console image data length'
}
Add-Type -AssemblyName System.Drawing
$bitmap = [Drawing.Bitmap]::new($Width, $Height, [Drawing.Imaging.PixelFormat]::Format16bppRgb565)
try {
    $rectangle = [Drawing.Rectangle]::new(0, 0, $Width, $Height)
    $data = $bitmap.LockBits($rectangle, [Drawing.Imaging.ImageLockMode]::WriteOnly, [Drawing.Imaging.PixelFormat]::Format16bppRgb565)
    try {
        if ($data.Stride -ne $Width * 2) { throw 'Unexpected RGB565 stride' }
        [Runtime.InteropServices.Marshal]::Copy([byte[]]$result.ImageData, $offset, $data.Scan0, $pixels)
    } finally { $bitmap.UnlockBits($data) }
    $bitmap.Save([IO.Path]::GetFullPath($OutputPath), [Drawing.Imaging.ImageFormat]::Png)
} finally { $bitmap.Dispose() }
Write-Output ([IO.Path]::GetFullPath($OutputPath))
