# PVGPU - Paravirtualized GPU for Windows VMs

> Historical prototype documentation, preserved during the Limiar transition.
> Checkboxes below describe the old implementation's claims, not verified
> capabilities of Limiar. Paths in command examples assume the repository root.
> See the [current README](../../README.md) for the supported development path.

[![Build](https://github.com/SANSI-GROUP/pvgpu/actions/workflows/build.yml/badge.svg)](https://github.com/SANSI-GROUP/pvgpu/actions/workflows/build.yml)
[![License](https://img.shields.io/badge/license-MIT%2FApache--2.0-blue.svg)](../../LICENSE-MIT)

**GPU paravirtualization for Windows guests on Windows hosts** - bringing QEMU/KVM-style VM customization freedom to Windows while providing GPU acceleration for gaming.

## 🎯 The Problem We Solve

On Linux, QEMU/KVM + VFIO gives you:
- ✅ Full VM identity customization (SMBIOS, CPUID, firmware)
- ✅ GPU passthrough for near-native gaming performance

On Windows, your options are limited:
- **Hyper-V/NanaBox**: GPU-PV works, but no identity customization
- **QEMU with WHPX**: Full customization, but no GPU acceleration for Windows guests
- **VMware/Parallels**: Proprietary, limited customization

**PVGPU bridges this gap** - run Windows VMs with QEMU's customization AND GPU acceleration, all on a Windows host.

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Windows Guest (10/11)                                          │
│  └── Game/App (DX11) → WDDM Paravirt Driver (KMD + UMD)         │
│            │                                                    │
│            ▼ Shared Memory (Command Rings + Fences)             │
├─────────────────────────────────────────────────────────────────┤
│  QEMU (WHPX acceleration)                                       │
│  └── qemu-pvgpu device (PCIe virtual, BAR0 config, BAR2 shmem)  │
│            │                                                    │
│            ▼                                                    │
├─────────────────────────────────────────────────────────────────┤
│  Host Backend Service (Rust)                                    │
│  └── D3D11 Renderer → Real GPU (NVIDIA/AMD)                     │
│  └── Presentation: Local window + Headless/Streaming            │
└─────────────────────────────────────────────────────────────────┘
```

## 📦 Components

| Component | Language | Description |
|-----------|----------|-------------|
| `protocol/` | C | Shared protocol definitions |
| `qemu-device/` | C | QEMU PCIe device emulation |
| `backend/` | Rust | Host rendering service (D3D11) |
| `driver/kmd/` | C | Windows kernel-mode WDDM driver |
| `driver/umd/` | C++ | Windows user-mode D3D11 driver |

## 🚀 Quick Start

### Prerequisites

- Windows 11 with Hyper-V/WHPX enabled
- NVIDIA (10 series+) or AMD (RDNA+) GPU
- [Rust](https://rustup.rs/) (for backend)
- [QEMU](https://www.qemu.org/) with WHPX support
- [Windows Driver Kit](https://docs.microsoft.com/en-us/windows-hardware/drivers/download-the-wdk) (for driver development)

### Building

```powershell
# Build the backend service
cd backend
cargo build --release

# For QEMU device - see qemu-device/README.md
# For drivers - see driver/README.md
```

### Running

```powershell
# Start the backend service
.\backend\target\release\pvgpu-backend.exe

# Start QEMU with pvgpu device
qemu-system-x86_64 -accel whpx -device pvgpu,shmem_size=256M ...
```

## 🎮 Use Cases

- **Gaming in VMs** with GPU acceleration AND custom VM identity
- **Anti-fingerprinting** - appear as different hardware to guest OS
- **Development/Testing** - test on various "hardware" configurations
- **Streaming** - works with Parsec, Moonlight, Sunshine

## 📊 Performance Targets

- **Target**: 60-80% of native GPU performance
- **Latency**: <50ms additional input latency
- **API**: DirectX 11 (DX12 planned for future)

## 🛣️ Roadmap

- [x] Protocol definition (shared header, command types, feature flags)
- [x] QEMU PCIe device (BAR0 config, BAR2 shared memory, MSI-X, named pipe IPC)
- [x] Rust backend service (D3D11 renderer, command processor, presentation pipeline)
- [x] Full D3D11 command implementation (50+ DDI functions, all draw/state/resource commands)
- [x] WDDM kernel-mode driver (BAR mapping, ring buffer, heap allocator, VidPn, interrupt handler)
- [x] WDDM user-mode driver (D3D11 DDI, staging buffer, fence sync, compute shader support)
- [x] Display mode support (720p-4K, 60-144Hz, dynamic resolution change)
- [x] Presentation pipeline (windowed, headless, dual mode, VSync, frame events)
- [x] Format support data (78 DXGI formats with capability flags)
- [x] Shared resource opening (cross-process resource sharing)
- [x] Compute shader support (CS dispatch, UAV, SRV, sampler, constant buffer binding)
- [x] Error handling and robustness (device lost, OOM, shader errors, backend crash)
- [x] Driver packaging (INF, WDK build configs, CI pipeline)
- [ ] Integration testing (requires VM environment)
- [ ] Performance optimization (profiling, command batching, telemetry)
- [ ] DX12 support (future)

## 🤝 Contributing

Contributions are welcome! This is an ambitious project that needs help with:

- D3D11/D3D12 expertise
- Windows driver development
- QEMU device development
- Testing on various hardware

See [CONTRIBUTING.md](../../CONTRIBUTING.md) for guidelines.

## 📜 License

Dual-licensed under MIT and Apache 2.0. See [LICENSE-MIT](../../LICENSE-MIT) and [LICENSE-APACHE](../../LICENSE-APACHE).

QEMU device code is GPL-2.0-or-later to match QEMU's license.

## 🙏 Acknowledgments

Inspired by:
- [dxgkrnl](https://github.com/microsoft/WSL2-Linux-Kernel) - GPU-PV for WSL2
- [virtio-gpu](https://www.qemu.org/) - QEMU's GPU virtualization
- [Looking Glass](https://looking-glass.io/) - Low-latency VM display

## ⚠️ Disclaimer

This project is for legitimate use cases like development, testing, and privacy. It is not intended for bypassing anti-cheat systems or any malicious purposes.
