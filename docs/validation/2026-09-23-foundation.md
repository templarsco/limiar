# Foundation Validation: September 23, 2026

Sanitized evidence from the initial Windows development host. No PCI instance
paths, hostnames, network addresses, serial numbers, or VM images are included.
This report describes a development build, not certified hardware support.

## Environment

| Item | Observed |
| --- | --- |
| Host | Windows 11 Enterprise x64, build 26200 |
| CPU | AMD Ryzen 7 9800X3D |
| Dedicated GPU | AMD Radeon RX 9070 XT |
| Dedicated GPU driver | 32.0.31041.3013 |
| Integrated GPU | AMD Radeon Graphics |
| WHP | Hypervisor present, queried through WHvGetCapability |
| Elevation | Tests ran without administrator elevation |
| Rust | 1.95.0, installed alongside the existing default toolchain |
| OpenVMM | 0.1.0+gf60e3d6a5 |
| OpenVMM commit | f60e3d6a57ce5d0cfee48ead3bca5ce9908effba |
| Runtime features | virt_whp, net_consomme; no optional TPM build |

## Automated Checks

Passed locally:
- `cargo fmt --all -- --check`
- `cargo clippy --workspace --all-targets --locked -- -D warnings`
- `cargo test --workspace --all-targets --locked`: 14 unit tests and
  6 CLI integration tests passed on Windows. Two ignored helper tests are
  intentionally started in child processes by the supervisor tests.
- `cargo build --release --locked -p limiar`
- Pinned OpenVMM release build with `--locked --no-default-features
  --features virt_whp,net_consomme`
- `Initialize-OpenVmm.ps1 -SkipBuild`: package restore with
  `--no-compat-igvm` completed successfully.

The checks cover strict profiles, resource bounds, path resolution, report
non-overwrite behavior, adapter selection, software-adapter rejection, timeouts,
process cleanup, log read limits, and rejection of panic/unverified exits.

### Ubuntu CLI Parity

An additional local Ubuntu/WSL run used an isolated Linux Rust 1.95.0
installation under ignored `.limiar/wsl/`. Formatting, Clippy, release build,
13 unit tests, and 6 CLI integration tests passed. The two supervisor helpers
remained intentionally ignored in the parent test run. The Windows-only pixel
validation unit test accounts for the difference from the Windows count.

This checks the platform-independent CLI and supervisor, not a Linux-host
OpenVMM, KVM/VFIO, or GPU implementation. WHP execution and D3D11 diagnostics
remain Windows-only in this release.

### Hosted CI

The initial GitHub-hosted attempts did not start because of an account-level
service restriction. After that restriction was cleared, attempt 2 of the
[Limiar workflow run 35906575204](https://github.com/templarsco/limiar/actions/runs/35906575204)
passed on September 23, 2026, against commit
`1a0b9bdb600b746820d5191eaeae9123722cd059`.

| Hosted job | Result |
| --- | --- |
| Ubuntu | Formatting, Clippy, 13 unit tests, 6 CLI tests, release build, and CLI smoke passed |
| Windows | Formatting, Clippy, 14 unit tests, 6 CLI tests, release build, and CLI smoke passed |
| Windows packaging | Dependency notices collected and CLI artifact uploaded |

The published artifact is `limiar-cli-windows-x64` (ID `10782405898`,
681,638 bytes). GPU hardware and guest-boot results below remain local tests;
they are not inferred from these hosted runners. CodeQL analysis is a separate
workflow and is not covered by the CLI result above.

## Native GPU

```powershell
.\target\release\limiar.exe gpu test --adapter "RX 9070 XT" --iterations 3
```

Result: **passed** on the RX 9070 XT, DXGI software flag false.

- D3D11 feature level: `0xb100` (11.1).
- Three clear/copy/readback iterations on a 64x64 RGBA8 render target.
- 12,288 pixels verified, including row-pitch handling.
- Observed release-test wall time: 42 ms, including host-side setup.
- No WARP fallback, custom WDDM driver, device reset, dismount, or assignment.

Additional native tests also passed, including a 35 ms release run. These are
individual observations, not a statistical performance comparison.

This is not a sustained-load benchmark or a guest GPU test. The wall time is
not a GPU timestamp measurement and cannot be converted to a gaming FPS claim.

## Linux Guest

```powershell
.\target\release\limiar.exe vm smoke examples/linux-smoke.toml --timeout-seconds 90
```

Result: **passed**. The pinned runtime used WHP, two vCPUs, 512 MiB RAM, and the
official upstream test kernel/initrd. Serial output reached:

```text
Run /init as init process
No root device specified. Dropping to a shell.
sh: can't access tty; job control turned off
~ #
```

The initrd is intentionally diskless. The missing root device message is its
documented shell path, not a failure to locate a configured system disk.
The serial marker was observed, followed by a two-second observation interval.
The runner then stopped its owned runtime process tree. The recorded reason was
`verified_then_stopped`, not a successful guest-requested shutdown. No remaining
`openvmm.exe` processes were found after the first test.
Three additional consecutive smoke runs also passed, taking 2673, 2766, and
2675 ms including the fixed observation interval and process cleanup. These
times are supervisor durations, not isolated guest boot-time benchmarks.

Nonfatal upstream logs included CPU/MSR warnings. Forced supervisor termination
can also produce mesh-disconnection messages at the end of the log. Neither is
being represented as proof of production stability.

## Input Fingerprints

SHA-256 of the files used locally:

| File | SHA-256 |
| --- | --- |
| OpenVMM executable | `35d149edf07dbec43c9264337fbf0438d9b914690326670a798edf9ab965765e` |
| Linux vmlinux | `10c258147174efbc05583515333beebfc898a1e51f1702356ea18a103713a31b` |
| Linux initrd | `50e9cbc64fb2d6a3a679f0e0704762fd000ed4ed945564a3e69358fa0aa43ada` |

The executable hash identifies this build, not a promise of bit-for-bit
reproducibility across toolchain/SDK installations. Kernel and initrd came from
the upstream `openvmm-deps` release `0.3.0-141`.

## GPU Assignment Gate

The read-only active-display query identified two active paths using the
RX 9070 XT and none using the integrated adapter. The host-assignable-device
inventory query succeeded but returned no devices; that is not a feasibility
verdict for this GPU.

**No assignment was attempted.** Before such a test, establish and confirm a
working host display/recovery path independent of the RX, review OS/IOMMU/MMIO
support, and prepare exact device-specific recovery actions. Physical monitor
wiring must not be inferred from inventory alone.

## Not Yet Validated

- Windows guest boot: no Windows image was selected for this test.
- Windows 11 Secure Boot/vTPM integration.
- RX 9070 XT passthrough, GPU-P, reset/return-to-host cycles, or guest rendering.
- Vulkan/DX12, games, audio, USB, persistent storage, or network workloads.
- A desktop Hub UI, macOS backend, or Linux-host GPU assignment.

Raw logs and reports remain locally under ignored `.limiar/`. The complete
roadmap is tracked in [DEVELOPMENT-PLAN.md](../DEVELOPMENT-PLAN.md).
