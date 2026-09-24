# Limiar

[![Build](https://github.com/templarsco/limiar/actions/workflows/build.yml/badge.svg)](https://github.com/templarsco/limiar/actions/workflows/build.yml)

**A capability-aware virtualization hub, starting with a Windows CLI and
OpenVMM.** Formerly the PVGPU experimental GPU-remoting project.

This is an early developer release, not a completed desktop hypervisor or a
production-ready gaming VM. Version 0.3 adds persistent, configurable SMBIOS
identity and an experimental **shared GPU-PV** laboratory on Windows.
Dedicated GPU passthrough comes later.

Local validation: **11 SMBIOS fields matched inside Linux** and **10 GPU-PV
D3D12 pixel-test cycles passed on an RX 9070 XT**, with the host graphics path
checked before and after.

There are currently **two separate execution paths**: OpenVMM for managed VMs
with custom identity, and HCS for the disposable GPU-PV Linux probe. A single
Windows desktop VM combining all identity controls and GPU-PV is not implemented.

## PC Identity

Identity is part of the VM profile, not a set of randomly changing values.
The `limiar` preset presents **Limiar One / Limiar Desktop**, with a per-VM UUID
and serial generated once on registration. Users can override every exposed
field or select the `custom` preset. Existing profiles without an identity
section keep their previous behavior.

This recovers the identity checklist from the historical project and makes
the implementation status explicit:

| Surface | Fields | Status in 0.3 |
|---|---|---|
| SMBIOS 0: BIOS | Vendor, version, release date, major/minor release | Configurable and guest-verified with OpenVMM Linux direct boot |
| SMBIOS 1: system | Manufacturer, product, version, serial, UUID, SKU, family | Configurable; all seven guest-verified on Linux |
| SMBIOS 2: baseboard | Manufacturer, product, version, serial, asset tag | Not exposed by the pinned OpenVMM CLI |
| SMBIOS 3: chassis | Manufacturer, type, version, serial, asset tag | Not exposed by the pinned OpenVMM CLI |
| CPU / CPUID / topology | Vendor, model, features, sockets, cores, threads | vCPU count configurable; arbitrary CPU identity is not implemented |
| Memory / SMBIOS 16-17 | Capacity, slots, module identities, speed | Total VM memory configurable; DIMM identity is not implemented |
| Firmware / clock | UEFI, RTC, Secure Boot, TPM, persistent variables | UEFI launch available; complete firmware identity and vTPM workflow pending |
| ACPI / PCI / devices | OEM/table IDs, topology, device IDs, bus information | Backend-generated, not fully customizable |
| Storage / network | Disk identities, MAC addresses, guest hostname | Dedicated identity controls pending |
| Graphics | GPU identity, driver, capabilities, shared/dedicated mode | GPU-PV laboratory; device identity remains backend/driver-reported |

The historical example listed types 0-3, CPU/topology, firmware and RTC; it
was not a validated bare-metal-equivalence configuration. The expanded
[identity specification and field mapping](docs/IDENTITY.md) distinguishes
that old list from the new work.

**SMBIOS customization does not make every observable property equivalent to
physical hardware.** Unsupported fields are rejected, not silently ignored.
UEFI only accepts Type 1 overrides; its BIOS self-description is not replaced.

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

Adapter selection is explicit: use a DXGI index or an unambiguous name from
`gpu list`. Software adapters are rejected by the hardware test. The test
clears/copies a 64x64 texture and verifies its pixels; it is not a benchmark
or proof of guest GPU acceleration.

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
