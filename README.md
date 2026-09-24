# Limiar

[![Build](https://github.com/templarsco/limiar/actions/workflows/build.yml/badge.svg)](https://github.com/templarsco/limiar/actions/workflows/build.yml)

**A Windows-first virtualization project targeting QEMU-class machine
control and GPU-accelerated desktop applications.** Formerly the PVGPU
experimental GPU-remoting project.

## Mission

User-owned machine configuration is the reason for Limiar: firmware,
SMBIOS and virtual hardware control, combined with useful graphics and
application performance in the same VM. The Hub is the management surface
for that platform, not the main differentiator.

A new interface around unchanged native Hyper-V guests does not meet this
goal. OpenVMM is the first implementation candidate, not a permanent limit
on the product. Extending or replacing VMM, firmware or execution-provider
components remains in scope when required by measured constraints.
See the [core contract and next acceptance gate](docs/CORE-CONTRACT.md).

## Current Implementation

This is an early developer release, not a completed desktop hypervisor or a
production-ready gaming VM. Version 0.4 adds a persistent **Windows 11
GPU-PV laboratory**, with Secure Boot, vTPM and guest-side graphics verification.
Configurable SMBIOS remains available through OpenVMM. Dedicated passthrough
comes later.

Local validation: **11 SMBIOS fields matched inside Linux** and **10 GPU-PV
D3D12 pixel-test cycles passed on an RX 9070 XT**, with the host graphics path
checked before and after.

The Windows 11 Pro guest now boots from a persistent VHDX and executes D3D11
clear/copy/readback on the shared RX 9070 XT. This is separate from the
OpenVMM identity path and the disposable HCS Linux probe. **A Windows VM with
full custom SMBIOS/CPUID/ACPI/PCI identity is not implemented.**

## Windows 11 Lab

The workflow uses native Hyper-V management, a new dedicated virtual disk,
read-only installation/provisioning ISOs, and PowerShell Direct. It does not
attach physical disks, connect the guest to a host network, or dismount the GPU.

```powershell
.\scripts\Build-PortableCli.ps1
.\scripts\windows\New-LabVm.ps1 -Name Limiar-Win11-25H2
$lab = ".limiar/windows/Limiar-Win11-25H2/lab.json"
.\scripts\windows\Prepare-Install.ps1 -LabPath $lab -Iso "F:\ISOs\your-windows.iso"
.\scripts\windows\Start-Install.ps1 -LabPath $lab
```

The ISO builder needs the pinned Python dependency and a 7-Zip-compatible
reader; follow the [complete Windows lab procedure](docs/WINDOWS-LAB.md).
The current template targets pt-BR x64 media. It may pause at the ordinary
product-key page; activation is not automated.

After Windows installation and driver provisioning, use `Start-LabVm.ps1`,
`Stop-LabVm.ps1` and `Test-GuestGpu.ps1`. Records contain ownership checks and
machine-local protected credentials, so keep `.limiar/` private.
The [Windows validation report](docs/validation/2026-09-24-windows-gpu-pv.md)
distinguishes guest GPU work from host-only diagnostics.

## PC Identity

Identity is a core requirement expressed through the VM profile, not a set
of randomly changing values.
The `limiar` preset presents **Limiar One / Limiar Desktop**, with a per-VM UUID
and serial generated once on registration. Users can override every exposed
field or select the `custom` preset. Existing profiles without an identity
section keep their previous behavior.

This recovers the identity checklist from the historical project and makes
the implementation status explicit:

| Surface | Fields | Status in 0.4 |
|---|---|---|
| SMBIOS 0: BIOS | Vendor, version, release date, major/minor release | Configurable and guest-verified with OpenVMM Linux direct boot |
| SMBIOS 1: system | Manufacturer, product, version, serial, UUID, SKU, family | Configurable; all seven guest-verified on Linux |
| SMBIOS 2: baseboard | Manufacturer, product, version, serial, asset tag | Not exposed by the pinned OpenVMM CLI |
| SMBIOS 3: chassis | Manufacturer, type, version, serial, asset tag | Not exposed by the pinned OpenVMM CLI |
| SMBIOS 4: processor | Socket, manufacturer, version, serial, asset and part information | Not implemented |
| SMBIOS 9 / 11 / 41 | Slots, OEM strings and onboard devices | Not implemented |
| SMBIOS binary entries | Explicit user-provided table data with validation | Not implemented |
| CPU / CPUID / topology | Vendor, model, features, sockets, cores, threads | vCPU count configurable; arbitrary CPU identity is not implemented |
| Memory / SMBIOS 16-17 | Capacity, slots, module identities, speed | Total VM memory configurable; DIMM identity is not implemented |
| Firmware / clock | UEFI, RTC, Secure Boot, TPM, persistent variables | Windows lab has verified Secure Boot/vTPM; full firmware identity controls pending |
| ACPI / PCI / devices | OEM/table IDs, topology, device IDs, bus information | Backend-generated, not fully customizable |
| Storage / network | Disk identities, MAC addresses, guest hostname | Persistent VHDX and unique Windows hostname; detailed identity controls pending |
| Graphics | GPU identity, driver, capabilities, shared/dedicated mode | Windows/Linux GPU-PV labs; device identity remains backend/driver-reported |

The historical example listed types 0-3, CPU/topology, firmware and RTC; it
was not a validated bare-metal-equivalence configuration. The expanded
[identity specification and field mapping](docs/IDENTITY.md) distinguishes
that old list from the new work.

**SMBIOS customization does not make every observable property equivalent to
physical hardware.** Unsupported fields are rejected, not silently ignored.
OpenVMM UEFI only accepts Type 1 overrides; its BIOS self-description is not replaced.
These are current implementation limits, not a reduction of the target
coverage. The next core gate requires extending or revisiting the backend
instead of dropping identity controls to obtain graphics.

```powershell
.\scripts\Build-LinuxProbe.ps1
.\target\release\limiar.exe vm register examples/linux-identity.toml
.\target\release\limiar.exe vm verify-identity limiar-one
```

The builder needs WSL with Bash, BusyBox and gzip. The guest reports its DMI
values, checks userspace and powers off. `verify-identity` compares the guest
report to the exact configuration used for that run. See also the
[fully customized example](examples/linux-custom-identity.toml).

## Shared GPU First

GPU-PV keeps the physical GPU available to the host. The local laboratory
selects an exact partitionable adapter and creates a temporary HCS VM; it
does not disable or dismount that device.

```powershell
.\target\release\limiar.exe gpu pv list
.\target\release\limiar.exe gpu pv probe --experimental `
  --adapter "RX 9070 XT" `
  --kernel "C:\Program Files\WSL\tools\kernel" `
  --initrd .limiar/images/linux-probe.initrd
```

This command checks assignment, Linux boot, guest shutdown and cleanup,
**not rendering**. The optional `--verify-rendering` mode requires a separately
built GPU probe image and verifies a bounded D3D12 clear/copy/readback workload.
See [GPU-PV setup, evidence and limitations](docs/GPU-PV.md).
Windows client / consumer Radeon compatibility remains experimental.

## Try The CLI

Prerequisites: Rust via rustup, Visual Studio C++ Build Tools, and a Windows SDK.
The repository pins Rust 1.95.0. No WDK or custom kernel driver is needed for
the Limiar CLI. Graphics diagnostics and WHP execution require Windows.

```powershell
cargo build --release --locked
.\target\release\limiar.exe doctor
.\target\release\limiar.exe gpu list
.\target\release\limiar.exe gpu test --adapter "RX 9070 XT" --iterations 3
```

For a clean Windows machine without the Visual C++ runtime installed, use
`scripts/Build-PortableCli.ps1`. It links the CRT statically in an isolated
build target and does not change the OpenVMM build environment.

Adapter selection is explicit: use a DXGI index or an unambiguous name from
`gpu list`. Software adapters are rejected by the hardware test. The test
clears/copies a 64x64 texture and verifies its pixels; it is not a benchmark
or proof of guest GPU acceleration.

Version 0.4 includes DXGI LUIDs and reports this operation as
`process_local_d3d11`: the surrounding workflow must establish host/guest
context. The Windows lab correlates its VM identity and tests every matching
hardware entry; two DXGI entries are not evidence of two physical GPUs.

Commands produce JSON. `--output <new-file>` also saves a report and refuses
to overwrite an existing file. Local reports can contain hardware instance
paths; review them before sharing.

## Build And Launch OpenVMM

```powershell
.\scripts\Initialize-OpenVmm.ps1
.\target\release\limiar.exe vm plan .\examples\linux-smoke.toml
.\target\release\limiar.exe vm smoke .\examples\linux-smoke.toml --timeout-seconds 90
```

The setup script restores official upstream dependencies and builds the exact
revision in [runtime/openvmm.json](runtime/openvmm.json). It refuses to overwrite
a different or modified checkout. The runtime is a separate build and is not
bundled into the CLI.
The runtime setup also needs Git, the Windows `tar`/`curl` tools, network access,
and several gigabytes of free disk space for dependencies and build artifacts.

Profiles resolve file paths relative to the profile. `vm plan` reports missing
inputs and returns a nonzero status until all required files exist. `vm smoke`
requires a serial marker, records logs, and terminates the runtime after
verification or timeout. `vm run` instead waits for a guest exit, bounded by
its timeout. Logs and results are saved under `.limiar/runs/`.

Load only profiles you trust: `runtime.executable` selects a local program to
execute. Profile validation is not a sandbox for untrusted host executables.
The supplied Linux smoke checks that the upstream initrd reaches its shell,
then deliberately stops the disposable VM; it is not an orderly shutdown test.

The [Windows UEFI example](examples/windows-uefi.toml) needs an existing
licensed disk image. It does not install Windows or configure Secure Boot/vTPM.
The default memory overlay avoids persisting guest writes to that base image.

## Manage Registered VMs

```powershell
.\target\release\limiar.exe vm register examples/linux-smoke.toml
.\target\release\limiar.exe vm list
.\target\release\limiar.exe vm preview linux-smoke
.\target\release\limiar.exe vm start linux-smoke --smoke
.\target\release\limiar.exe vm status linux-smoke
```

For a longer foreground session, use `vm start linux-smoke --timeout-seconds 300`.
From another terminal, `vm stop linux-smoke --force` terminates that runtime.
**This is a forced stop, not a graceful guest shutdown.**

`vm update <name> <profile>` replaces a stopped VM's configuration snapshot.
`vm unregister <name>` removes only registration metadata, never input images
or logs. Duplicate starts and changes to an active VM are rejected.

The default registry is `.limiar/vms`; use `--registry <directory>` to select
another. Each registry belongs to one host OS and must not be shared between
Windows and WSL. See [Managed VMs](docs/MANAGED-VMS.md) for lifecycle, recovery,
and trust boundaries. Configuration snapshots are not disk or memory snapshots.

## Development

```powershell
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --all-targets --locked
.\scripts\Invoke-LocalValidation.ps1 -Adapter "RX 9070 XT" -RunSmoke
.\scripts\Invoke-ManagedValidation.ps1
```

- [Complete development plan and status](docs/DEVELOPMENT-PLAN.md)
- [Core mission, architecture choices and acceptance gate](docs/CORE-CONTRACT.md)
- [Architecture and implementation boundaries](docs/ARCHITECTURE.md)
- [Local validation: Windows 11 and RX 9070 XT](docs/validation/2026-09-23-foundation.md)
- [Managed VM lifecycle validation](docs/validation/2026-09-24-managed-vms.md)
- [Identity and GPU-PV validation](docs/validation/2026-09-24-identity-gpu-pv.md)
- [Contribution guide](CONTRIBUTING.md)

Windows client device assignment is still an experiment. Limiar never disables
or dismounts a GPU in this release. The existence of WHP/vPCI APIs does not
establish that a particular GPU/OS combination supports assignment.

## Legacy And Licensing

`backend/`, `driver/`, `protocol/`, and `qemu-device/` remain the old PVGPU
prototype, outside the Limiar workspace. They are not required by this release.
Their [historical README](docs/legacy/README.md) is preserved separately; old
feature checkboxes are not evidence of end-to-end functionality.

Limiar currently retains the repository's [MIT](LICENSE-MIT) OR
[Apache-2.0](LICENSE-APACHE) licensing. OpenVMM keeps its MIT notices; the legacy
QEMU device keeps its GPL terms. Future licensing changes remain a separate
decision.

Windows CI packages collect dependency notices with
`scripts/Write-ThirdPartyNotices.ps1`. The generated inventory includes
development dependencies and is not a substitute for a production license review.
