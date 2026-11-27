<!-- SPDX-FileCopyrightText: 2026 SANSI GROUP -->
<!-- SPDX-License-Identifier: LicenseRef-Limiar-Private-Use-1.0 -->

# Kernel-Level Anti-Cheat, Nested Hyper-V & GPU-PV Compatibility Study

Updated November 2026 (recording the October 2026 native `r10` lab milestone).
This document summarizes selected architectural findings from Limiar's native
**Hyper-V + OpenHCL VTL2 + custom `mu_msvm` UEFI + GPU-PV** research base.
QEMU/OVMF remains a historical reference, not the active implementation path.
See the [OpenHCL workstream](OPENHCL-COMPATIBILITY.md), the
[core contract](CORE-CONTRACT.md), the [GPU-PV and DDA guide](GPU-PV-E-DDA.md),
and the [component license map](../LICENSING.md).

Limiar is virtualization engineering and compatibility research aimed at running
games and applications — including titles with intrusive kernel-level anti-cheat
drivers — inside an isolated Windows guest separate from the main host
installation, **without developing, loading, or using gameplay cheats**. All
tested anti-cheat clients and game binaries remained unmodified and signed.

## 1. Confirmed Compatibility On The Current Native Base

Across Limiar's internal native Hyper-V + OpenHCL VTL2 + custom `mu_msvm` +
GPU-PV lab configuration, **all tested kernel-level anti-cheats and protected
games run cleanly without virtual-machine blocking**.

A central empirical finding of the test campaign was the clear split between
titles that worked immediately once Hyper-V signatures were stripped through
complete SMBIOS customization and **EasyAntiCheat (EAC EOS)**, which took the
longest investigation to isolate:

| Tested titles | Anti-cheat / protection | Observed result on current native base | What was required |
|---|---|---|---|
| **Skate 4**, **Wuthering Waves**, **Marvel Rivals**, **Roblox** | **EA Javelin**, **ACE (Anti-Cheat Expert)**, **NetEase kernel anti-cheat**, **Hyperion** | **Pass on first try** — ran cleanly without virtual-machine rejection | Removing Hyper-V guest identifiers/parameters via complete custom SMBIOS + native OpenHCL desktop firmware profile and GPU-PV |
| **VRChat**, **Fortnite** (Direct3D 12 SM6 on GPU-PV) | **EasyAntiCheat EOS** (`EasyAntiCheat_EOS.sys`) | **Pass** — EAC bootstrapper code `301` (*Easy Anti-Cheat successfully loaded in-game*); live online entry and D3D12 SM6 rendering verified on shared Radeon RX 9070 XT | Longest investigation: full SMBIOS/ACPI coherence + nested Hyper-V root-partition parity + isolating and aligning the GPU-PV `VirtualRender` (`vrd.sys`) driver surface |

While **Skate 4**, **Wuthering Waves**, **Marvel Rivals**, and **Roblox** worked
on the first attempt purely from removing Hyper-V parameters with complete
SMBIOS customization, closing the remaining **EasyAntiCheat** gap required
isolating **two deeper layers**:

1. **Nested Virtualization + Guest Hyper-V (`hvax64.exe` / `hvix64.exe` L1)**,
   which shifts the Windows guest from a Hyper-V child partition into an L1
   root partition — changing Task Manager from *"Virtual machine: Yes"* to live
   CPU clock reporting and matching a bare-metal Windows 11 host with VBS / Core
   Isolation enabled.
2. **The GPU-PV Kernel Driver Surface (`VirtualRender` / `vrd.sys`)**, which
   controlled A/B testing proved was the exact remaining trigger for EasyAntiCheat
   code `206` (*Cannot run under a virtual machine*) even after firmware, ACPI,
   and CPUID layers were already coherent.

> **Scope note:** Private `r10` lab firmware images (`MSVM.fd` / IGVM), real
> motherboard serial numbers, private backup archives, and turnkey game-specific
> bypass scripts remain private per [PUBLICATION-REVIEW.md](PUBLICATION-REVIEW.md).
> Compatibility is always version- and configuration-dependent; upstream anti-cheat
> vendors may change detection heuristics at any time.

---

## 2. Study: Nested Virtualization + Guest Hyper-V (CPU Clock vs. "Virtual Machine")

### 2.1 Why Standard Hyper-V Guests Report "Virtual Machine: Yes"

In a standard Hyper-V Windows guest (nested virtualization off, or Hyper-V not
enabled inside the guest), the guest OS runs as a **child partition** beneath
the host's L0 Hyper-V hypervisor:

- `CPUID 0x00000001:ECX[31]` (`HypervisorPresent`) is `1`.
- `CPUID 0x40000000` reports `"Microsoft Hv"`.
- `CPUID 0x40000003:EBX[0]` (`CreatePartitions` — the root-partition privilege
  bit) is **`0`**.

Windows itself (`taskmgr.exe` and system telemetry) checks this partition model.
Seeing `"Microsoft Hv"` **without** root-partition privileges, Task Manager's
**Performance -> CPU** pane replaces standard physical telemetry with
**`Virtual machine: Yes`** and suppresses live per-core/boost clock speed
readout. Kernel-level anti-cheats inspect the exact same distinction.

### 2.2 The Bare-Metal Windows 11 VBS Parity Advantage

Unlike KVM/QEMU (`"KVMKVMKVM"`) or VMware (`"VMwareVMware"`), where the presence
of a hypervisor signature alone indicates a guest VM, **modern physical Windows
11 gaming PCs routinely run under the Microsoft Hyper-V hypervisor**
(`hvax64.exe` on AMD, `hvix64.exe` on Intel) whenever **VBS (Virtualization-Based
Security)**, **HVCI (Memory Integrity / Core Isolation)**, or WSL2 is active —
features that Windows 11 ships enabled by default and that anti-cheats themselves
encourage.

Consequently, kernel anti-cheats cannot reject `"Microsoft Hv"` unconditionally.
Instead, their primary architectural check distinguishes:

- **Physical Root Partition (Windows 11 + VBS/HVCI):** `"Microsoft Hv"` with
  root-partition privileges (`CreatePartitions = 1`) and coherent physical
  firmware/CPUID leaves (`0x40000000..0x40000006`).
- **Child Guest Partition (VM):** `"Microsoft Hv"` with `CreatePartitions = 0`,
  guest-only hypervisor capability flags, and virtual firmware/bus signatures.

### 2.3 Enabling Nested Virtualization + Hyper-V Inside The Guest

When **both** sides are configured together:

1. **Host (L0 Hyper-V, VM powered off):** Enable hardware virtualization
   extensions for the guest processor (`Set-VMProcessor -VMName <vm>
   -ExposeVirtualizationExtensions $true`).
2. **Guest (Windows 11 inside the VM):** Enable the Hyper-V hypervisor feature
   (`Microsoft-Hyper-V-Hypervisor` / `bcdedit /set hypervisorlaunchtype auto`)
   so the guest boots its own **L1 hypervisor** (`hvax64.exe` / `hvix64.exe`).

**Measured Effect Inside The Guest:**

- The guest Windows kernel now boots as the **L1 root partition** of its own
  nested Hyper-V instance (`VirtualizationFirmwareEnabled = True`, VBS active,
  root-partition privilege semantics active).
- **Windows Task Manager (`Performance -> CPU`) stops showing `"Virtual machine:
  Yes"`** and instead displays live CPU **Speed / clock telemetry** (for
  example, `5.07–5.14 GHz` observed live on the Ryzen 7 9800X3D lab system),
  **Base speed**, and **`Virtualization: Enabled`** — matching a physical
  Windows 11 desktop with VBS/Core Isolation enabled.
- Combined with OpenHCL VTL2 CPUID leaf parity (`0x00000001` and
  `0x40000000..0x40000006` matching the root-partition profile), both Windows
  telemetry and kernel-mode hypervisor checks observe a consistent root
  partition rather than a child VM.

> **Important engineering nuance:** Nested virtualization alone does not erase
> Hyper-V L0, VMBus devices, ACPI tables, or synthetic GPU drivers. While
> **Skate 4**, **Wuthering Waves**, **Marvel Rivals**, and **Roblox** already
> worked on the first try once Hyper-V parameters were removed through complete
> SMBIOS customization, **EasyAntiCheat** (`VRChat` and `Fortnite`) continued
> returning code `206` until the deeper ACPI, nested root-partition, and GPU-PV
> driver layers below were isolated and aligned.

---

## 3. Study: EasyAntiCheat (EAC EOS) & The GPU-PV Driver Surface (`vrd.sys`)

### 3.1 Multi-Layer Surface Alignment Prior To GPU Isolation

Before isolating the GPU layer, the native OpenHCL VTL2 + `mu_msvm` desktop
research base (`r10`) resolved four foundational virtual-platform discrepancies
without breaking Windows boot or VMBus storage/networking:

1. **Post-Boot ACPI `DSDT` Cleanup In VTL2:** Windows `vmbus.sys` requires the
   `_HID = "MSFT1000"` ACPI node during early kernel initialization (Phase 0/1);
   removing it statically in UEFI prevents `vmbus.sys` and `storvsc.sys` from
   starting (`INACCESSIBLE_BOOT_DEVICE`). Performing in-RAM `DSDT` scrubbing
   from OpenHCL VTL2 *after* VMBus initializes — replacing virtual bus tokens
   and recalculating the ACPI table checksum (`sum mod 256 == 0`) — keeps boot
   reliable while removing virtual identifiers from post-boot
   `GetSystemFirmwareTable('ACPI', 'DSDT')` queries.
2. **Desktop Power Profile & No Virtual Battery:** Disabling the OpenHCL
   synthetic battery (`ACPI0003` / `Win32_Battery`) ensures `FADT
   Preferred_PM_Profile = 1` (Desktop) and `Win32_Battery` count `0`, consistent
   with a physical desktop chassis (`SMBIOS Type 3 = 3`).
3. **Complete Desktop SMBIOS Tables (`Type 0, 1, 2, 3, 4, 17`):** Populating
   coherent BIOS (`Type 0` with the `VirtualMachineSupported` extension bit
   cleared), System/Baseboard/Chassis (`Type 1/2/3`), Processor (`Type 4`), and
   Memory Device (`Type 17`) tables in `mu_msvm` eliminates empty/placeholder
   fields.
4. **Nested Hyper-V & Root-Partition CPUID Parity:** Combining host nested
   exposure + guest L1 `hvax64.exe` with root-partition `CPUID` leaf parity
   (`0x00000001`, `0x40000000..0x40000006`).

### 3.2 Controlled A/B Isolation: Proving The GPU-PV Driver Trigger

With all four layers above active, EasyAntiCheat (`EasyAntiCheat_EOS.sys`) still
rejected online launches with code **`206`** (*Cannot run under a virtual
machine*). A single-variable A/B test on the GPU-PV synthetic PCI device
(`PCI\VEN_1414&DEV_008E`, Windows service `VirtualRender`) isolated the exact
root cause:

| Test state on the same aligned VM | `VirtualRender` (GPU-PV) | EasyAntiCheat EOS result |
|---|---|---|
| **A (GPU-PV device disabled/stopped)** | Stopped | **`301` — Easy Anti-Cheat loaded cleanly** |
| **B (Default GPU-PV driver active)** | Running (`vrd.sys`) | **`206` — Virtual machine rejection** |

**Exact Root Cause:**

When the Windows `VirtualRender` service starts under its default DriverStore
configuration, the kernel loads **`vrd.sys`**
(`\SystemRoot\System32\DriverStore\FileRepository\vrd.inf_amd64_*\vrd.sys`, the
*Microsoft Virtual Render Driver*) and exposes synthetic `PCI\VEN_1414&DEV_008E`
PnP and `DeviceClasses` metadata (`Render` and `DisplayAdapter` interfaces).
During kernel startup validation, `EasyAntiCheat_EOS.sys` enumerates active
kernel modules (`NtQuerySystemInformation(SystemModuleInformation)` /
`RTL_PROCESS_MODULES`) and device metadata; detecting **`vrd.sys`** / the
synthetic GPU-PV transport immediately aborts launch with code **`206`**.

### 3.3 Why Driver-Surface Alignment Preserves Windows Code Integrity

A critical OS-level finding of this study is how Windows kernel Code Integrity
(`ci.dll`, Secure Boot, HVCI, and Kernel Patch Protection) validates Microsoft
in-box drivers:

- `vrd.sys` is **catalog-signed by Microsoft** (`CatRoot`), where `ci.dll`
  verifies the PE file's Authenticode hash against the system catalog rather
  than binding trust to the driver's filename on disk.
- Consequently, aligning the loaded module name and GPU-PV PnP / `DeviceClasses`
  presentation metadata keeps the Microsoft-signed binary **100% unmodified**
  (zero binary patching, zero test-signing, full KPP/HVCI compatibility) while
  retaining full hardware Direct3D 12 acceleration on the partitioned host GPU.
- Under this aligned configuration, **Fortnite (`FortniteClient-Win64-Shipping.exe`)
  and VRChat passed EasyAntiCheat EOS with code `301`** while rendering in
  **Direct3D 12 Feature Level SM6** on the shared **AMD Radeon RX 9070 XT** via
  GPU-PV.

### 3.4 Companion Finding: D3D12 + Virtual Display BSOD (`0x3B` in `dxgkrnl.sys`)

Running Direct3D 12 games (such as Unreal Engine 5 / Fortnite) on GPU-PV
alongside a non-GPU-PV virtual display adapter (such as the virtual display used
for Looking Glass capture, alongside `ROOT\BASICRENDER\0000`) uncovered a
Windows 11 24H2 kernel bug:

- During `IDXGIFactory1::EnumAdapters1` + `D3D12CreateDevice` probing across all
  enumerated adapters, `d3d12core.dll` invokes
  `NtDxgkIsFeatureEnabled(hAdapter, 0x10000009)`
  (`Feature_D3DVideoEncoderExclusiveAccess`) against `ROOT\BASICRENDER\0000`.
- Inside Windows 11 24H2 `dxgkrnl!IsFeatureEnabledUncached`, when the VM is
  connected to a GPU-PV host (`DxgkIsVmConnectedToHost() == true`), the kernel
  forwards the feature query over VMBus (`DXG_GUEST_VIRTUALGPU_VMBUS`) without
  verifying that the target `DXGADAPTER` is actually a virtual GPU adapter. For
  `BasicRender`, `m_GuestVirtualGpuVmBus.m_pAdapter` is `NULL`, triggering an
  immediate `SYSTEM_SERVICE_EXCEPTION (0x3B)` NULL-pointer dereference in
  `dxgkrnl!DXGVMBUSMESSAGE::InitializeMessage`.
- Addressing this at the Windows feature-management layer (`FeatureId
  0x03B70D75`) — and for newer D3D12 Agility SDK builds (`1.619.5.0+`) where
  `D3D12Core.dll` invokes the query unconditionally, preventing `D3D12CreateDevice`
  from initializing `BasicRender` via `d3d10warp.dll` so the engine binds
  directly to the hardware GPU-PV adapter (`Feature Level 12_2`, `SM 6.7`) —
  eliminates the `0x3B` crash with **zero modifications to `dxgkrnl.sys` or game
  DLLs**, preserving full KPP and EAC integrity.

### 3.5 GPU-PV vs. Dedicated DDA (Architectural Comparison)

| Dimension | Native OpenHCL + GPU-PV (validated) | Native OpenHCL + DDA (Windows Server path) |
|---|---|---|
| Host keeps GPU simultaneously | **Yes** (shared partition) | **No** (PCIe device dedicated to VM) |
| Kernel render driver in guest | `VirtualRender` (`vrd.sys`, requires driver-surface alignment for EAC) | **Native vendor PCIe driver** (`amdkmdag.sys` / NVIDIA / Intel) — `vrd.sys` and `1414:008e` do not exist |
| D3D12 draw-call overhead | Serialized across VMBus (measurable ceiling in draw-call-heavy titles) | Direct PCIe hardware submission (near-native frame rates) |
| EAC `301` status | **Verified** in lab (`Fortnite` DX12 SM6, `VRChat`) | Structurally eliminates the `vrd.sys` / PE-PDB surface entirely; full OpenHCL + DDA validation tracked separately in [GPU-PV-E-DDA.md](GPU-PV-E-DDA.md) |

---

## 4. Boundaries, Limitations And Licensing

- **Not a cheat or universal guarantee:** This study documents virtualization
  architecture and anti-cheat compatibility research on unmodified clients.
  Future anti-cheat updates (e.g., deeper kernel module PE/PDB inspection,
  storage driver stack checks comparing `\Driver\storvsc` vs. `\Driver\stornvme`,
  or direct Ring 0 hypercall probing) can alter compatibility and require
  corresponding architectural work (such as DDA or native OpenHCL NVMe
  emulation).
- **Private lab material stays private:** Full `r10` patches containing
  hardware-specific profiles, compiled `MSVM.fd` / IGVM images, and host/guest
  automation scripts remain outside this public repository per
  [PUBLICATION-REVIEW.md](PUBLICATION-REVIEW.md).
- **Licensing:** This document is covered by the
  [Limiar Private-Use License 1.0](../LICENSE-LIMIAR) as listed in
  [component licensing](../LICENSING.md). Earlier MIT/Apache grants, upstream
  OpenVMM/mu_msvm licenses, Looking Glass GPL terms, and GitHub platform
  viewing/forking rights remain unchanged.
