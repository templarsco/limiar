<!-- SPDX-FileCopyrightText: 2026 SANSI GROUP -->
<!-- SPDX-License-Identifier: LicenseRef-Limiar-Private-Use-1.0 -->

# GPUs in Limiar: GPU-PV and DDA

Updated September 27, 2026. A selected public tutorial from Limiar's
virtualization research. The current focus is native Hyper-V with OpenHCL
and mu_msvm firmware; QEMU remains a historical reference.
See the [OpenHCL status](OPENHCL-COMPATIBILITY.md).

This guide explains how to prepare and verify GPU access in an existing VM.
It is not an OpenHCL installer and does not provide firmware, drivers, disks,
private profiles, credentials, or internal lab collectors. Each operator
must obtain the identifiers used in the examples from their own host.

## Choose a Mode

| Mode | What the guest receives | GPU available to the host | Project status |
| --- | --- | --- | --- |
| GPU-PV / GPU-P | Paravirtualized or partitioned access | Yes, shared | Demonstrated experimentally on Windows with a Radeon RX 9070 XT, OpenHCL, and custom firmware |
| DDA | A dedicated physical PCIe device | No, for the assigned device | Conditional reference; not validated with the lab's OpenHCL/Radeon combination |

**The same GPU cannot be fully dedicated through DDA while remaining
shared through GPU-PV.** Two physical GPUs allow planning for separate
roles, subject to platform support. Setting a GPU-PV quota to "100%" does
not turn sharing into DDA. Two DXGI entries do not mean two physical GPUs,
either.

Firmware, GPU assignment, and image transport are separate layers. Custom
SMBIOS/ACPI does not create DDA or IOMMU support. Looking Glass captures
the guest's image and presents it on the host; it does not assign the GPU
itself. Limiar's intended integration places capture in the guest and the
viewer/input path on physical Windows. It is not yet a complete delivery,
and no latency advantage over Parsec/Moonlight has been demonstrated.

## Support and Evidence

- **DDA:** Microsoft documents a Windows Server 2016 or later host,
  server-class hardware, and compatible devices [1, 2].
- **GPU-P on Server:** requires Windows Server 2025 or later and the
  appropriate GPU/driver support matrix [3, 4]. The Radeon PRO V710 being
  listed does not establish official RX 9070 XT support.
- **Windows client:** Microsoft's troubleshooting guide excludes these
  Hyper-V DDA/GPU-P scenarios on client operating systems and desktop
  hardware from that support matrix [5]. This does not deny other uses of
  GPU-PV in Windows, such as WSL. The experimental results recorded here
  do not change the official matrix.
- **OpenHCL:** Windows Client/Server provides development support, not
  production support, for these VMs [6]. The existence of VMBus/VPCI relay
  or a cmdlet does not prove that any GPU can be assigned through that
  path [7].

The local evidence summary authorized for publication is:

| Check | Result and limit |
| --- | --- |
| Combined configuration | Windows 11, native Hyper-V, OpenHCL in VTL2, custom firmware, and one GPU-PV partition coexisted in the same VM |
| AMD driver | Version 32.0.31041.3013; 133 expected payload files matched between host and guest by size and SHA-256 |
| Earlier D3D11 checks | Two logical RX entries passed clear/copy/readback: 12,288 pixels each, 24,576 total |
| Verification for this update | Configuration and hash reads; no new rendering test, DDA test, or VM change |
| Limits | Not proof of Present, complete OpenGL/Vulkan support, encoding, latency, endurance, GPU operation with relay enabled, or universal compatibility |

Raw receipts, instance identities, and firmware images remain private.
This result does not validate a binary generated from the
[published neutral reference](LIMIAR-FIRMWARE-BASE.md), which does not
include a complete firmware build.

## GPU-PV: Inventory Before Changes

Use elevated PowerShell 7 x64 on the **host**, from the checkout root.
This first block only queries state; it does not create or change a VM.

```powershell
$ErrorActionPreference = 'Stop'
Import-Module Hyper-V
$repo = (Get-Location).Path
$inventoryScript = Join-Path $repo 'scripts\gpu-pv-inventory.ps1'
if (-not (Test-Path -LiteralPath $inventoryScript -PathType Leaf)) {
    throw 'Run from the Limiar checkout root'
}
$inventory = & $inventoryScript | ConvertFrom-Json
if ($inventory.status -cne 'queried') { throw 'GPU inventory is unavailable' }
$inventory.adapters | Select-Object name,driver_version,device_interface
Get-VM | Select-Object Name,Id,State
```

Do not automatically select the first GPU. Obtain the GUID and name of
the VM you administer and the desired GPU's complete `device_interface`.
The interface path, possibly ending in `GPUPARAV`, is not the PCIROOT
`LocationPath` used by DDA. Keep this inventory local: it may contain
machine identifiers.

Fill in the next block with your local results. Empty values make the
example stop by default; they do not identify a VM belonging to the author.

```powershell
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[guid]$vmId = [guid]::Empty
$expectedVmName = 'Limiar-GPU-Example'
$selectedInterface = ''
$expectedDriverVersion = ''
if ($vmId -eq [guid]::Empty -or
    [string]::IsNullOrWhiteSpace($selectedInterface) -or
    [string]::IsNullOrWhiteSpace($expectedDriverVersion)) {
    throw 'Enter the VM GUID, exact interface, and driver version'
}

function Get-SelectedVm {
    $target = Get-VM -Id $vmId
    if ($target.Name -cne $expectedVmName) { throw 'The VM name does not match the GUID' }
    $target
}

function Get-SelectedGpu {
    $current = & $inventoryScript | ConvertFrom-Json
    $selected = @($current.adapters | Where-Object {
        $_.device_interface -ieq $selectedInterface
    })
    if ($current.status -cne 'queried' -or $selected.Count -ne 1 -or
        $selected[0].driver_version -cne $expectedDriverVersion) {
        throw 'GPU is missing, ambiguous, or has a different driver than the prepared version'
    }
    $selected[0]
}

$vm = Get-SelectedVm
$gpu = Get-SelectedGpu
$partitions = @(Get-VMGpuPartitionAdapter -VM $vm)
if ($partitions.Count -eq 1 -and
    $partitions[0].InstancePath -ieq $selectedInterface) {
    'GPU-PV is already attached: validate the guest without attaching it again.'
} elseif ($partitions.Count -ne 0) {
    throw 'A different assignment exists: review it without automatic removal'
}
```

Raw counts and quotas returned by the driver are not necessarily VRAM
bytes or performance percentages. For example, values such as `1000000000`
or the maximum value of a 64-bit integer may represent driver conventions,
not physical memory or unlimited encoder capacity. An advertised count of
32 does not demonstrate 32 useful VMs. This guide does not change the
global partition count or set arbitrary quotas.

## GPU-PV: Prepare the Complete Driver Payload

For an officially supported Server deployment, follow the vendor's GPU-P
driver procedure [4]. Copying files to HostDriverStore as described here
is the technique used in the **experimental Windows client lab**; it does
not replace that support documentation.

1. For the selected GPU, resolve the PnP instance ID from the interface and
   query `DEVPKEY_Device_Service`. The service's `ImagePath` identifies the
   active main package. Do not choose a folder by its modification date.
2. Query `DEVPKEY_Device_Driver`, which points to the active key under
   `HKLM\SYSTEM\CurrentControlSet\Control\Class`. For the tested AMD GPU,
   `OpenGLVendorName` and `OpenGLVendorNameWow` identify libraries in a
   separate OpenGL package.
3. Resolve paths only within
   `C:\Windows\System32\DriverStore\FileRepository`. Check the INF version,
   provenance, and signature/catalog. Reject reparse points. Not every file
   has an embedded Authenticode signature; catalog signing is a separate
   mechanism.
4. Prepare a manifest of relative paths, sizes, and SHA-256 hashes for all
   required files, preserving subfolders. Exclude only the expected
   log/ETL/temporary files. Do not assemble a package from mixed versions.
5. Use authenticated PowerShell Direct or controlled payload media to
   transfer files to the **UUID-verified guest**, under
   `C:\Windows\System32\HostDriverStore\FileRepository\<package>`.
   Do not share the host's DriverStore over the network or install a guest
   driver on the host. Reject destinations redirected by links.
6. If a destination folder already exists, compare it first. Matching
   content requires no copy; a mismatch requires separate maintenance,
   not a bulk overwrite. Check each file against the manifest after
   transfer. Do not proceed with attachment if files are missing or differ.

The UUID to verify inside the guest comes from `Win32_ComputerSystemProduct`;
do not assume it equals the administrative GUID returned by `Get-VM`.
Obtain and record both while preparing the fixture. Use protected local
credentials; never put a password, token, or credential export in the
repository, a published command, or a distributed installation image.

### AMD OpenGL and Error 126

In the tested AMD driver, the main `u*.inf_amd64_<id>` package contained
the `atig6pxx.dll`/`atiglpxx.dll` loaders, but the
`atio6axx.dll`/`atioglxx.dll` libraries belonged to `amdogl.inf_amd64_<id>`.
Copying only the first package left this dependency missing.

The local fix used the companion identified by the active registry, with
the same version. There were 128 main payload files and five OpenGL files;
all 133 expected files were compared again. The x64/x86 library load test
went from error 126 to success without running the package installer.
This does not prove complete OpenGL rendering or that every occurrence of
error 126 has this cause. The error may also indicate another missing
dependency. The count is specific to this version, not a rule for future
drivers. Do not add Vulkan/OpenCL or other packages based on assumptions.

### Limits of Previously Published Helpers

[Prepare-GpuDriver.ps1](../scripts/windows/Prepare-GpuDriver.ps1) prepares
only the main package. It does not automate discovery of all companions.
[Enable-GpuPv.ps1](../scripts/windows/Enable-GpuPv.ps1) belongs to the
[historical Windows lab](WINDOWS-LAB.md), with its own ownership contract,
one disk, and no network. It also changes boot settings and DVDs.
Do not run these helpers directly against an existing OpenHCL VM or edit
its records to force the checks to pass.

## GPU-PV: Attach Once

Before making changes, record the firmware, VM configuration, disks,
partitions, and host graphics state. Prepare a consistent disk copy,
shutting down according to the VM's lifecycle; a VHDX copied while in use
is not automatically a consistent backup. Do not assume checkpoint or
save/restore support for the OpenHCL/GPU combination.

Finish your work and shut down the guest **normally**. Wait for `Off`, not
`Saved`. The block below requires the preceding variables/functions and
stops by default. It is an attachment reference, not a transactional
installer.

```powershell
$preparationVerified = $false
if (-not $preparationVerified) { throw 'Validate the payload and backup before attachment' }
$ErrorActionPreference = 'Stop'
$vm = Get-SelectedVm
$gpu = Get-SelectedGpu
if ($vm.State.ToString() -cne 'Off') { throw 'Wait for the VM to shut down normally' }
if (@(Get-VMGpuPartitionAdapter -VM $vm).Count -ne 0 -or
    @(Get-VMAssignableDevice -VM $vm).Count -ne 0) {
    throw 'The VM already has GPU-PV or DDA; do not change it automatically'
}
$previousMmio = @{
    GuestControlledCacheTypes = $vm.GuestControlledCacheTypes
    LowMemoryMappedIoSpace = $vm.LowMemoryMappedIoSpace
    HighMemoryMappedIoSpace = $vm.HighMemoryMappedIoSpace
}
# Record these values before making changes, alongside the fixture backup.
Set-VM -VM $vm -GuestControlledCacheTypes $true `
    -LowMemoryMappedIoSpace 1GB -HighMemoryMappedIoSpace 32GB
$addedPartition = Add-VMGpuPartitionAdapter -VM $vm `
    -InstancePath $gpu.device_interface -Passthru
if ($addedPartition.InstancePath -ine $gpu.device_interface) {
    Remove-VMGpuPartitionAdapter -VMGpuPartitionAdapter $addedPartition
    Set-VM -VM $vm @previousMmio
    throw 'Attachment did not preserve the selected GPU'
}
Get-VMGpuPartitionAdapter -VM $vm | Select-Object Id,InstancePath
```

The 1/32 GiB MMIO windows are the values used in the lab, not a universal
formula. They are address space, not extra RAM or reserved VRAM. Size them
for the platform and driver. Record the returned ID, read back the
configuration/attachments, and start the VM through its normal lifecycle.

**GPU-PV does not require dismounting the GPU from the host.** Do not use
`Disable-PnpDevice` or `Dismount-VMHostAssignableDevice` for this mode.
Do not change Secure Boot, HVCI, BCD, VBS, or nested virtualization as part
of this tutorial.

If an attempt fails, keep the fixture off, read back the assignments, and
remove only the partition created by that attempt, using its ID/object.
Restore the recorded MMIO/cache values. If the command failed before
returning an object, inspect the state before removing anything. Do not
remove a healthy preexisting partition or use a global removal command.

## Validate the Guest and Preserve the Host

Verify in layers: one correct host partition; guest identity; driver
hashes; PnP devices without errors; DXGI enumeration; pixels; then
presentation, specific APIs, and extended tests.

Prepare the [portable CLI](../scripts/Build-PortableCli.ps1) and copy it
to the guest through a controlled channel. Confirm its hash. In the example
below, `C:\Limiar\limiar.exe` is an installation path chosen by the operator,
not a binary supplied with this tutorial. Run it **inside the guest**.
The IDs 1002:7550 select the RX 9070 XT model; for another model, use the
expected IDs from your inventory.

```powershell
$ErrorActionPreference = 'Stop'
$exe = 'C:\Limiar\limiar.exe'
$text = & $exe gpu list | Out-String
if ($LASTEXITCODE -ne 0) { throw 'DXGI enumeration failed' }
$inventory = $text | ConvertFrom-Json
$adapters = @($inventory.adapters | Where-Object {
    -not $_.software -and $_.vendor_id -eq 0x1002 -and $_.device_id -eq 0x7550
})
if ($adapters.Count -eq 0) { throw 'Expected GPU not found through DXGI' }
foreach ($adapter in $adapters) {
    $text = & $exe gpu test --adapter ([string]$adapter.index) --iterations 3 | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'D3D11 test failed' }
    $result = $text | ConvertFrom-Json
    if ($result.status -cne 'passed' -or $result.adapter.software -or
        $result.adapter.luid -cne $adapter.luid -or $result.pixels_verified -ne 12288) {
        throw 'GPU or pixels do not match the expected result'
    }
    $result
}
```

The test verifies clear/copy/readback of a 64x64 texture. It does not
measure FPS or latency and does not test swap-chain Present, encoding,
HDR, OpenGL, or Vulkan. Correlate the index and LUID from the same
enumeration; do not reuse old indices after device changes. With multiple
identical physical GPUs, model IDs alone do not identify the desired card.

In the guest, the synthetic transport may appear as `1414:008e`, with a
Microsoft driver version in `Win32_VideoController`, while the AMD DLLs
have the payload version. That field alone does not prove driver
incompatibility. A virtual display adapter used for remoting is not the
physical GPU, either. Verify rendering and monitor topology separately.

Check host graphics/display before and after. When updating the physical
driver, rediscover the matching payload, plan maintenance/rollback, and
repeat the checks. Do not copy all of System32 or mix DLLs from different
versions. Comparing expected files is not a complete guest integrity audit.

## DDA: Requirements and Conditional Procedure

DDA has not yet been validated with Limiar's OpenHCL/Radeon combination.
The following workflow is a reference for a **conventional Hyper-V fixture
on Windows Server**, before any OpenHCL integration. It is not a ready-to-use
feature for the current Windows client lab.

1. Confirm a supported Windows Server host, Native PCI Express Control,
   IOMMU (AMD-Vi/VT-d), ACS, and compatible GPU/driver [1, 2]. Devices with
   legacy INTx interrupts are unsupported. SR-IOV may enable relevant
   platform capabilities; DDA does not necessarily mean that the GPU
   itself must expose SR-IOV virtual functions.
2. Obtain a pinned revision of the
   [official SurveyDDA.ps1](https://github.com/MicrosoftDocs/Virtualization-Documentation/blob/main/hyperv-tools/DiscreteDeviceAssignment/SurveyDDA.ps1),
   review the script, and record its hash before running it on the test
   host. Check the exact device and its MMIO requirements. An available
   cmdlet or empty `Get-VMHostAssignableDevice` result does not replace
   the survey.
3. Prepare another GPU or a tested management/recovery path for the host.
   Do not dismount its only usable graphics output. The selected GPU must
   stop serving the host, GPU-PV, and any other VM during this window.
4. Check related PCIe functions, such as HDMI audio, without automatically
   assigning every function or bridge. Follow the isolation domain and
   reset limitations specified by the platform/vendor.
5. Prepare the powered-off VM with fixed RAM and
   `AutomaticStopAction=TurnOff`. Do not depend on save/restore. Calculate
   MMIO from the sum of BAR/device requirements plus the documented margin.
   Microsoft's 3 GiB/33280 MiB examples are not a measurement of your card [2].
6. Evaluate/install the vendor-provided device mitigation. Disable and
   dismount only the selected GPU, then assign it to the VM. Install its
   native driver inside the guest. The GPU-PV HostDriverStore procedure
   does not replace that installation.
7. Validate rendering, presentation, stability, restarts, and return to
   the host. Then evaluate the OpenHCL/VPCI/MMIO/interrupt path separately.
   Do not enable VMBus relay on a working VM by trial and error.

This example is deliberately blocked by default. Fill it in only after
meeting the requirements above, using your own fixture and a secondary
GPU. Do not run individual lines in isolation or replace placeholders
with identifiers from someone else's machine.

```powershell
$ErrorActionPreference = 'Stop'
$ddaPrerequisitesVerified = $false
if ((Get-CimInstance Win32_OperatingSystem).ProductType -eq 1) {
    throw 'This DDA workflow requires a supported Windows Server host'
}
if (-not $ddaPrerequisitesVerified) { throw 'Complete the DDA prerequisites first' }
[guid]$ddaVmId = [guid]::Empty
$ddaVmName = 'Limiar-DDA-Example'
$ddaInstance = ''
$ddaLocation = ''
[uint32]$ddaLowMmio = 0
[uint64]$ddaHighMmio = 0
if ($ddaVmId -eq [guid]::Empty -or $ddaInstance -notlike 'PCI\VEN_*' -or
    $ddaLocation -notlike 'PCIROOT(*)*' -or $ddaLowMmio -eq 0 -or $ddaHighMmio -eq 0) {
    throw 'Enter the GUID, exact device, and measured MMIO values'
}
$ddaVm = Get-VM -Id $ddaVmId
if ($ddaVm.Name -cne $ddaVmName -or $ddaVm.State.ToString() -cne 'Off' -or
    (Get-VMMemory -VM $ddaVm).DynamicMemoryEnabled -or
    @(Get-VMGpuPartitionAdapter -VM $ddaVm).Count -ne 0 -or
    @(Get-VMAssignableDevice -VM $ddaVm).Count -ne 0) {
    throw 'Review the DDA fixture identity and configuration'
}
$ddaSettings = @(Get-CimInstance -Namespace root\virtualization\v2 `
    -ClassName Msvm_VirtualSystemSettingData `
    -Filter "VirtualSystemIdentifier='$($ddaVm.Id)' AND VirtualSystemType='Microsoft:Hyper-V:System:Realized'")
if ($ddaSettings.Count -ne 1 -or $ddaSettings[0].GuestStateIsolationType -ne 0) {
    throw 'This example uses a conventional fixture; OpenHCL requires separate validation'
}
$ddaPaths = @((Get-PnpDeviceProperty -InstanceId $ddaInstance `
    -KeyName DEVPKEY_Device_LocationPaths).Data)
if ($ddaLocation -notin $ddaPaths) { throw 'LocationPath does not match the device' }
# Record the original configuration and recovery plan before these writes.
Set-VM -VM $ddaVm -AutomaticStopAction TurnOff -GuestControlledCacheTypes $true `
    -LowMemoryMappedIoSpace $ddaLowMmio -HighMemoryMappedIoSpace $ddaHighMmio
Disable-PnpDevice -InstanceId $ddaInstance -Confirm
if ((Get-PnpDevice -InstanceId $ddaInstance).Problem -ne 'CM_PROB_DISABLED') {
    throw 'The device was not disabled; do not dismount it'
}
Dismount-VMHostAssignableDevice -LocationPath $ddaLocation -Confirm
if (@(Get-VMHostAssignableDevice -LocationPath $ddaLocation).Count -ne 1) {
    throw 'The device was not dismounted; do not assign it'
}
Add-VMAssignableDevice -VM $ddaVm -LocationPath $ddaLocation
Get-VMAssignableDevice -VM $ddaVm -LocationPath $ddaLocation
```

Stop if a step fails. The example does not use `-Force` for dismounting:
that option bypasses mitigation checks; it does not increase isolation.
DDA may give the guest capabilities such as updating device firmware;
Microsoft recommends trusted tenants or appropriate mitigation [2].
When containing potentially intrusive software, missing mitigation is an
unresolved requirement, not a step to skip.

### Return the GPU to the Host

Use the IDs recorded during the attempt, shut down the fixture normally,
and check the state before each action. Do not reuse this block without
the assignment records. It also stops by default.

```powershell
$ErrorActionPreference = 'Stop'
$ddaRecoveryVerified = $false
if (-not $ddaRecoveryVerified) { throw 'Check the DDA attempt receipt before returning the device' }
$ddaVm = Get-VM -Id $ddaVmId
if ($ddaVm.Name -cne $ddaVmName -or $ddaVm.State.ToString() -cne 'Off') {
    throw 'Identity mismatch or fixture still running'
}
$assigned = @(Get-VMAssignableDevice -VM $ddaVm -LocationPath $ddaLocation)
if ($assigned.Count -gt 1) { throw 'Ambiguous assignment' }
if ($assigned.Count -eq 1) {
    Remove-VMAssignableDevice -VMAssignableDevice $assigned[0] -Confirm
}
$remaining = @(foreach ($candidate in Get-VM) {
    Get-VMAssignableDevice -VM $candidate -LocationPath $ddaLocation
})
if ($remaining.Count -ne 0) { throw 'The device still belongs to a VM' }
$dismounted = @(Get-VMHostAssignableDevice -LocationPath $ddaLocation)
if ($dismounted.Count -gt 1) { throw 'Ambiguous dismounted device' }
if ($dismounted.Count -eq 1) {
    Mount-VMHostAssignableDevice -LocationPath $ddaLocation -Confirm
}
if (@(Get-VMHostAssignableDevice -LocationPath $ddaLocation).Count -ne 0) {
    throw 'The device is still dismounted; do not enable it'
}
Enable-PnpDevice -InstanceId $ddaInstance -Confirm
```

Restore the fixture's previous settings from the record and verify host
drivers/display. If dismounting never occurred, do not invent an assignment
to undo. A reset failure may require planned recovery; removing and mounting
the device does not guarantee recovery without a restart.

## Isolation and Publication

GPU-PV retains a shared path through the host driver; DDA gives the guest
more hardware control. Neither mode guarantees the absence of guest-to-host
vulnerabilities. Networking, shared files, the clipboard, peripherals, and
the capture/input channel also belong to the threat model. AWS Nitro is
an architectural inspiration, not certified security or performance
equivalence.

This tutorial does not provide process-hiding techniques, loaders, or
game/anti-cheat modifications. Successful GPU operation does not demonstrate
application acceptance, and switching from GPU-PV to DDA does not guarantee
that a VM rejection will be resolved. Compatibility tests are separate from
graphics and isolation checks.

The original text and tests in this reference use the
[Limiar license](../LICENSING.md). Earlier MIT/Apache rights, Looking Glass
GPL rights, and GitHub platform rights remain preserved. This license does
not authorize redistribution of Windows, GPU drivers, or generated images.
The [publication review](PUBLICATION-REVIEW.md) keeps private firmware,
profiles, and research outside this selected material.

## Official Sources

Consulted September 27, 2026, through the official Exa MCP. The Server
pages are not perfectly synchronized in their GPU lists or wording about
multiple partitions. This guide does not expand support by combining claims
from different scenarios: the local evidence is for one partition per VM.

1. [Microsoft: Deploy graphics devices using DDA](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/deploy/deploying-graphics-devices-using-dda).
2. [Microsoft: Plan for deploying devices using DDA](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/plan/plan-for-deploying-devices-using-discrete-device-assignment).
3. [Microsoft: GPU partitioning](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/gpu-partitioning).
4. [Microsoft: Partition and assign GPUs to a VM](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/partition-assign-vm-gpu).
5. [Microsoft: GPU assignment, partitioning and passthrough troubleshooting](https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/troubleshoot-hyper-v-gpu-assignment-partitioning-passthrough-issues).
6. [OpenVMM: OpenHCL on Hyper-V/Windows](https://openvmm.dev/guide/user_guide/openhcl/run/hyperv.html).
7. [OpenVMM: VMBus relay and device interception](https://openvmm.dev/guide/reference/architecture/openhcl/vmbus.html).
8. [Microsoft: PowerShell Direct](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/powershell-direct).

The examples are checked by
[tests with mock providers](../tests/gpu_tutorial.ps1), without GPU assignment
in CI. Tested syntax and guards do not establish hardware-validated DDA
or certify an OpenHCL configuration.
