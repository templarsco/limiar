# Limiar

[![Build](https://github.com/templarsco/limiar/actions/workflows/build.yml/badge.svg)](https://github.com/templarsco/limiar/actions/workflows/build.yml)

**A capability-aware virtualization hub, starting with a Windows CLI and
OpenVMM.** Formerly the PVGPU experimental GPU-remoting project.

This is an early developer release, not a completed desktop hypervisor or a
production-ready gaming VM. Version 0.2 provides local diagnostics, a bounded
native GPU test, validated VM profiles, a persistent VM registry, and controlled
foreground runtime launches. It does not implement GPU passthrough or GPU sharing.

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
