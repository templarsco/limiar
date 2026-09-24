# Shared GPU Laboratory

GPU-PV is the first graphics workstream: share the GPU while retaining host
use. Dedicated vPCI/DDA comes later, with separate recovery requirements.
No Limiar command disables or dismounts the physical GPU.

## Two Paths, Not One Completed Product

Managed OpenVMM profiles provide the tested SMBIOS controls. The new HCS path
creates a disposable Linux laboratory VM with a shared GPU. HCS does not apply
those OpenVMM identity profiles. This is not yet a Windows desktop installer,
interactive graphics console, resource-sharing UI, or combined identity/GPU VM.

## Read-Only Inventory

```powershell
.\target\release\limiar.exe gpu pv list
```

This uses `Get-VMHostPartitionableGpu`, so the Hyper-V PowerShell module is
needed for this inventory implementation even though HCS itself is a separate
Windows API. Query failures remain `unknown`, not proof of unsupported hardware.

Select an unambiguous adapter name or exact `device_interface`.
Ambiguity and missing adapters fail; the implementation never falls back to
another GPU or `Mirror` mode. Raw quotas are serialized as decimal strings to
preserve their precision. They are not physical VRAM byte counts or guaranteed
performance shares. An advertised count of 32 does not prove 32 useful VMs.

## Boot And Attachment Probe

Build the standard initrd with `scripts/Build-LinuxProbe.ps1`. The host needs
working HCS/Virtual Machine Platform and permission to create compute systems.
No host feature, driver, BIOS or security setting is changed automatically.

```powershell
.\target\release\limiar.exe gpu pv plan --adapter "RX 9070 XT" `
  --kernel "C:\Program Files\WSL\tools\kernel" `
  --initrd .limiar/images/linux-probe.initrd

.\target\release\limiar.exe gpu pv probe --experimental --adapter "RX 9070 XT" `
  --kernel "C:\Program Files\WSL\tools\kernel" `
  --initrd .limiar/images/linux-probe.initrd --timeout-seconds 60
```

The kernel path shown is from a local WSL installation, not a bundled kernel.
The upstream OpenVMM `vmlinux` fixture can boot here too, but the tested build
does not provide `dxgkrnl`. Merely finding `/dev/dxg` is not rendering evidence.

The lifecycle is create -> start -> request GPU-PV -> verify guest -> acknowledge
power-off -> verify `GracefulExit` -> close -> verify removal by HCS identifier.
The guest waits for a serial acknowledgement to avoid losing its final report
when the pipe closes. Each VM has a fresh identifier and termination-on-last-
handle-close enabled. Cleanup only targets the handle created by that probe,
never a persisted PID or an existing Hyper-V VM.

The request uses the documented GPU-PV partition sentinel `65535` in an exact
adapter `AssignmentRequest`. There is no network, host filesystem share,
attached guest disk, or persistent VM. Reports and serial logs remain locally
under `.limiar/`. HCS create/start/modify operations have separate 30-second
timeouts; the CLI timeout bounds guest observation, not the entire operation.

## D3D12 Pixel Probe

```powershell
.\scripts\Build-LinuxProbe.ps1 -WithGpu
.\target\release\limiar.exe gpu pv probe --experimental --verify-rendering `
  --adapter "RX 9070 XT" `
  --kernel "C:\Program Files\WSL\tools\kernel" `
  --initrd .limiar/images/linux-gpu-probe.initrd
```

The optional builder needs WSL, Bash, g++, BusyBox, gzip and the installed
WSL DirectX libraries/drivers, plus OpenSSL 3 runtime libraries. The AMD shader
cache loads OpenSSL dynamically, so dependency discovery cannot rely on `ldd`
alone. It compiles against the exact Microsoft
DirectX-Headers revision in `runtime/directx-headers.json`. Runtime and Linux
driver binaries are copied into a local initrd, with an input hash manifest.
**Do not redistribute that generated image**: its system/vendor components
retain their own terms and are not part of Limiar's source license.

The guest uses DXCore to select exactly one hardware adapter matching the
requested PCI vendor/device. It creates a D3D12 render target, clears 64x64
pixels, copies to a readback resource, waits for a GPU fence, and checks every
RGBA byte. Software fallback, a different adapter, timeout, crash, missing
evidence or pixel mismatch cannot pass `--verify-rendering`.

The Linux render request also uses WSL's headless GPU settings
`DisableGdiAcceleration` and `DisablePresentation`, which need the newer HCS
implementation used by the tested Windows 11 host. Older hosts may reject
them. This is a narrowly scoped graphics test, not a game benchmark, Vulkan/
OpenGL result, hardware-encoding validation or interactive desktop.
Consult the [recorded results](validation/2026-09-24-identity-gpu-pv.md).

`scripts/Invoke-GpuPvValidation.ps1` repeats the rendering probe, checks native
host graphics before/after, compares active display routes and hashes the
boot inputs. The generated images remain local and are never CI artifacts.

## Remaining Work

- Windows installation and guest driver provisioning from selected media.
- A repeatable Windows guest graphics test and interactive console.
- Persistent HCS guest storage/state and explicit lifecycle ownership.
- A backend/firmware design combining identity controls with GPU-PV.
- Resource limit controls with real vendor-specific quota interpretation.
- Multiple concurrent guests, repeated cycles, driver upgrade and recovery tests.
- Dedicated GPU assignment after host display/recovery validation.
- Other sharing/remoting transports only after independent feasibility tests.

## References

- [Microsoft HCS schema: GPU configuration and lifecycle](https://learn.microsoft.com/en-us/virtualization/api/hcs/schemareference)
- [Microsoft WSL's GPU configuration](https://github.com/microsoft/WSL/blob/master/src/windows/service/exe/WslCoreVm.cpp)
- [HCS operation completion semantics](https://learn.microsoft.com/en-us/virtualization/api/hcs/reference/hcswaitforoperationresult)
- [App Sandbox's create/start/modify GPU reference flow](https://github.com/jamesstringer90/appsandbox/blob/main/src/backend_win/hcs_vm.c)
- [DirectX-Headers Linux/WSL ABI](https://github.com/microsoft/DirectX-Headers/tree/adbd6f3ba40795c46a8d0f33af00bcb57ff0f0a4)
- [Windows Server GPU partitioning support matrix](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/gpu-partitioning)

The Server support matrix is not a certification of Windows client/RX 9070 XT
support. This project records that consumer configuration as experimental.
