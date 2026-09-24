# Limiar 0.3 Identity And GPU-PV Validation

Date: September 24, 2026 UTC (September 23 local, UTC-03).
This is a sanitized local hardware report. Full logs and unique device/VM
identifiers remain outside version control.

## Environment

- Windows 11 Enterprise x64, build 26200.
- AMD Ryzen 7 9800X3D.
- AMD Radeon RX 9070 XT, PCI vendor/device `1002:7550`.
- RX host driver `32.0.31041.3013`.
- AMD integrated graphics also present; the RX was selected explicitly.
- Both active display paths used the RX before and after the cycle test.
- Non-elevated process; account belongs to the Hyper-V Administrators group.
- OpenVMM pinned at `f60e3d6a57ce5d0cfee48ead3bca5ce9908effba`.
- OpenVMM dependency kernel: Linux `6.18.33`.
- Local WSL kernel: `6.6.87.2-microsoft-standard-WSL2`.
- Rust 1.95.0; Windows and Ubuntu/WSL builds.
- DirectX-Headers pinned at `adbd6f3ba40795c46a8d0f33af00bcb57ff0f0a4`.

## Results

| Check | Outcome |
|---|---|
| Rust format, Clippy with warnings denied, release build | Passed on Windows and Ubuntu/WSL |
| Rust unit/CLI tests | 46 passed on each OS; two helper tests intentionally invoked by parent tests |
| C++ guest source | Compiled with official headers; `-Wall -Wextra -Werror` syntax check passed |
| Shell and PowerShell source syntax | Passed |
| Managed VM regression | Register/start/duplicate refusal/forced stop/update/restart/unregister passed |
| Limiar preset, Linux guest | All 11 requested Type 0/1 fields matched |
| Custom profile, Linux guest | All 11 requested Type 0/1 fields matched |
| Identity persistence | UUID/serial retained across repeated boots and template updates |
| HCS GPU-PV attachment | Exact RX device request accepted |
| HCS Linux with OpenVMM dependency kernel | Booted; no dxg device in this kernel |
| HCS Linux with WSL kernel | Booted; `/dev/dxg` observed |
| WSL control workload | Requested RX hardware adapter; 4096 D3D12 pixels verified |
| Limiar-created HCS guest workload | Requested RX hardware adapter; 4096 D3D12 pixels verified |
| Repeated GPU-PV runs | Ten consecutive create/start/attach/render/shutdown/cleanup cycles passed |
| Guest exit | `GracefulExit` reported by HCS |
| Cleanup | Fresh compute-system ID absent after each probe |
| Host graphics before/after | 12288 native D3D11 pixels verified in each check |
| Host display routes | Unchanged before/after the ten-cycle run |
| Boot input SHA-256 | Unchanged across the ten-cycle run |
| Negative rendering check without GPU probe binary | Failed as required, with graceful exit and cleanup still confirmed |

Each guest render cycle clears a 64x64 RGBA8 target, copies it to a readback
resource, waits for a GPU fence and compares all bytes. Total across the ten
cycles: 40960 verified guest pixels. This is not a sustained-load benchmark;
cycle duration includes a deliberate guest startup delay.

## Corrections Found During Validation

1. HCS GPU-PV modification must follow start for this path. Applying it before
   start returned `0x80041001`; the flow was corrected.
2. A fast guest shutdown can discard unread serial-pipe output. The guest now
   waits for an explicit host acknowledgement before powering off.
3. The first minimal GPU initrd omitted libraries loaded dynamically by the
   AMD shader-cache implementation. The guest enumerated the correct RX but
   crashed in `amdxc64.so`. Comparing file traces with the working WSL control
   revealed missing OpenSSL. Including `libssl.so.3`, `libcrypto.so.3` and their
   dependencies restored the pixel test. No host driver was changed.

Failures remained failures in the JSON reports. A boot marker, GPU attachment
or `/dev/dxg` alone did not satisfy the rendering acceptance condition.

## Reproduction

From a built checkout with the pinned runtime and WSL prerequisites:

```powershell
.\scripts\Build-LinuxProbe.ps1
.\target\release\limiar.exe vm register examples/linux-identity.toml
.\target\release\limiar.exe vm verify-identity limiar-one
.\target\release\limiar.exe vm register examples/linux-custom-identity.toml
.\target\release\limiar.exe vm verify-identity custom-desktop

.\scripts\Build-LinuxProbe.ps1 -WithGpu
.\scripts\Invoke-GpuPvValidation.ps1 -Adapter "RX 9070 XT" `
  -Kernel "C:\Program Files\WSL\tools\kernel" -Cycles 10
```

Builders refuse existing output paths. Select a new output with `-OutputPath`
and pass that initrd explicitly if retaining earlier fixtures.
Do not redistribute the locally generated GPU initrd or vendor components.

## Not Established

- A Windows 11 guest installation or interactive desktop.
- Full SMBIOS/CPUID/ACPI/PCI identity control or physical-machine equivalence.
- Custom identity and GPU-PV combined in the same supported VM backend.
- OpenVMM GPU-PV support; the working sharing test uses HCS.
- Dedicated passthrough, vendor reset/reassignment cycles, or DDA support.
- Vulkan, OpenGL, encoding/decoding, games, or sustained performance.
- Stable partition quotas or a guarantee of 32 concurrent VMs.
- Host display recovery for future dedicated assignment.

No GPU was disabled or dismounted. No existing Hyper-V VM was modified.
No host reboot, firmware change, driver replacement or security-policy change
was performed. The Limiar workflow covers source/build checks; actual GPU and
VM hardware evidence is local, not provided by hosted CI.
