# Experimental Windows Graphics Lab

Limiar 0.6 adds explicit QEMU graphics, networking and audio choices, a
bounded D3D11 presentation probe, and guest-only driver preparation.
This is a development laboratory, not a qualified Roblox machine.

## Separate The Paths

| Path | Current role |
|---|---|
| Basic QEMU display | Established Windows boot and custom SMBIOS reference |
| QEMU/WHPX + VirGL | Experimental Windows D3D10/OpenGL guest driver investigation |
| Native Hyper-V GPU-PV | Separate, previously validated RX 9070 XT pixel-test fixture |
| Looking Glass | Future display integration; not installed or represented by SDL |
| Linux/SteamOS | Future desktop/workload validation, not implied by Linux probe success |

VirGL forwards graphics commands; it is not full PCI passthrough or the
native Hyper-V GPU-PV path. The physical GPU remains attached to Windows.
Selecting the virtual adapter does not establish that it renders correctly.

## Profile Options

The following fields belong to a `qemu_uefi` boot configuration:

```toml
graphics = "virgl_experimental" # default: "basic"
network = "user_nat"            # default: "none"
audio = true                    # default: false
headless = false
```

Identity configuration is retained. VirGL requires a visible SDL OpenGL
display. Audio is output-only. NAT adds no inbound forwarding rules or
directory shares, but permits outbound host/LAN access; it is not a network
isolation guarantee. These choices are independent opt-ins.

## Guest Driver

The small pinned reference in `runtime/virgl-windows-reference.json` is
the March 15, 2026 **Win10 x64 experimental** driver. It is not the latest
upstream release. The separate June pin and CI cache are research inputs,
not a claim that either version is qualified on Windows 11.

Prepare an already installed, cleanly shut-down Windows disk. Do not import
a hibernated image. Keep a recovery copy before experimental driver changes.

```powershell
.\scripts\Build-PortableCli.ps1
.\scripts\qemu\New-LabVm.ps1 -Name Limiar-3D `
    -SourceDisk "C:\VMs\windows.qcow2" -SourceFormat qcow2 `
    -Graphics virgl_experimental -Network user_nat -Audio
$lab = ".limiar/qemu/Limiar-3D/lab.json"
.\scripts\qemu\Prepare-GraphicsProbe.ps1 -LabPath $lab `
    -ArchivePath "C:\Downloads\driver.zip" -Experimental
.\scripts\qemu\Start-LabVm.ps1 -LabPath $lab
```

The preparation verifies the pinned archive and builds read-only media.
It excludes upstream private test keys and debug symbols. It installs
**nothing on the physical host**.

Inside the **guest**, install Windows Graphics Tools for this debug driver:

```powershell
Add-WindowsCapability -Online -Name Tools.Graphics.DirectX~~~~0.0.1.0
```

Then, in an administrator PowerShell **inside that same guest**, run the
optical media's entry point (adjust its drive letter):

```powershell
D:\setup-graphics.ps1 -EnableGuestTestSigning
```

The UUID-bound installer verifies its payload, initializes guest test
certificate stores, enables guest test signing and schedules installation
for the next cold boot. It disables guest hibernation and shuts down normally.
Start the VM again with `Start-LabVm.ps1`.

`-Resume` accepts only the same UUID, owner and driver payload after a
partial preparation. Inspect `C:\Limiar\Graphics\preparation.json`,
`installation.json`, `driver-install.log` and `graphics.json` in the guest.
Never run certificate or boot-setting commands on the physical host.

## Renderer Reference

The bundled QEMU renderer and an experimental guest driver are not
automatically a compatible pair. The locally investigated renderer is pinned
in `runtime/virgl-renderer.json`, including a small Windows build patch.
It is built with MSYS2 mingw64, libepoxy and PyYAML, using the recorded Meson
options. EGL, GLX, Venus and video support are disabled in this callback-based
SDL reference build.

The Windows patch separates wire-protocol capability IDs from Unix DRM
ioctl headers. Its purpose is build portability, not altered guest identity.
The resulting library must be tested in a **separate copy** of the pinned
QEMU runtime. Never replace libraries used by an active or established VM.

The first local trial installed the virtual GPU but failed pixel readback.
The newer renderer corrected an observed clock-glyph rendering defect.
Neither result is an application qualification or a performance claim.

## Diagnostics

Run these in the environment being measured:

```powershell
limiar gpu list
limiar gpu test --adapter 0 --iterations 3
limiar gpu demo --adapter 0 --seconds 20
```

The probes reject software adapters. The demo draws an animated cube,
checks rendered pixels and counts successful presentation calls. Its timing
is CPU-side submit/Present wall time, not end-to-end latency or measured
monitor refresh. D3D11 API use does not imply feature level 11; the actual
negotiated feature level is reported.

An accelerated QEMU console may have no CPU surface for QMP `screendump`.
That error does not itself mean the displayed image is black. Visual checks
must capture the actual VM window without substituting host/browser pixels.

## Display And Linux

Windows as the physical PC/client remains a requirement. In Looking Glass,
the Windows **host application** is the capturer inside the guest; it is not
a native Windows viewer for the physical PC. The inspected B7/current client
uses Linux display backends. A Windows client and compatible transport need
their own implementation and tests. The present console is SDL/OpenGL.

That work will use the [Limiar-owned fork](https://github.com/templarsco/LookingGlass);
it is not waiting for an upstream Windows-client release. See the
[QEMU GPU-PV backend investigation](QEMU-GPU-PV.md) for the separate device
integration and the reusable OpenVMM components.

Linux/SteamOS tests must independently establish desktop boot, Vulkan and
gamescope requirements, input/audio and repeatable workload performance.
OpenGL VirGL support alone is insufficient proof. Sharing and dedicated GPU
assignment are separate tracks. Dedicated assignment requires a specific
iGPU recovery plan and confirmation before changing any host display device.

## Sources

- [Tsuki's Windows QEMU/VirGL experiment](https://github.com/Tsuki-Bakery/qemu-virgl-whpx)
- [Pinned guest-driver instructions](https://github.com/arehnman/yttrium-virtio-gpu/tree/viogpu3d-debug-2026-03-15)
- [Upstream glyph/blur issue and renderer correction](https://github.com/arehnman/yttrium-virtio-gpu/issues/4)
- [Looking Glass B7 documentation](https://looking-glass.io/docs/B7/)
- [Looking Glass client display backends](https://github.com/gnif/LookingGlass/tree/master/client/displayservers)
