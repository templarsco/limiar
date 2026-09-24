# GPU-PV On The QEMU Backend

Investigation date: September 24, 2026. Status: backend integration required;
native GPU-PV is not implemented for a Limiar QEMU VM.

This is a work item, not a permanent product limitation. Preserving the
QEMU machine model and the user's identity configuration remains mandatory.

## What Already Passed

The RX 9070 XT correctness tests used two distinct paths:

| Evidence | Actual VM/device owner |
|---|---|
| Linux D3D12 GPU-PV probe | Disposable VM created and modified through HCS |
| Windows D3D11 GPU-PV fixture | Native Hyper-V VM with a GPU partition and matched AMD user-mode files |
| Custom Windows SMBIOS reference | QEMU/WHPX VM, separate from those GPU-PV fixtures |

The Linux GPU probe lives in `crates/limiar/src/hcs.rs` and
`crates/limiar/src/gpu_pv.rs`. `HcsModifyComputeSystem` targets the compute
system created by `HcsCreateComputeSystem`. An existing QEMU WHP partition
is not that HCS compute system. Copying the GPU JSON, a VM identifier, or
the AMD files does not attach a GPU to the QEMU guest.

See the [GPU-PV workflow](GPU-PV.md) and
[Windows GPU-PV evidence](validation/2026-09-24-windows-gpu-pv.md).

## Reusable Components

Retain exact-adapter selection, immutable driver manifests, GPU correctness
tests, lifecycle ownership and host display-continuity checks. Reuse source
and protocol definitions where applicable; do not imply that their OS
resource handles are interchangeable.

OpenVMM's pinned Windows implementation includes:

- `vm/whp`: resource allocation and vPCI device APIs.
- `vmm_core/virt_whp/src/device.rs`: BAR/MMIO, configuration and interrupt handling.
- `vm/devices/pci/vpci`: the guest-facing vPCI bus.
- `openvmm/openvmm_core/src/worker/dispatch.rs`: connects assigned devices to VMBus.

The inspected `--device` path requests a standard SR-IOV/discretely
assignable resource. This is not evidence that it allocates a shared Radeon
GPU-PV resource. A registered provider can receive an opaque descriptor
through `WHvAllocateVpciResource`, but a suitable GPU-PV provider/descriptor
has not been identified or validated for this host.

In the QEMU upstream source inspected on September 24, `hw/hyperv/Kconfig`
defines `HYPERV` as depending on `KVM` and `VMBUS` on `HYPERV`. Its existing
VMBus is therefore not a ready WHPX GPU-PV transport.

## Platform Probe

```powershell
limiar gpu pv capabilities
```

This performs `WHvGetCapability` queries and inspects vPCI function exports
in the Windows system library. It does not allocate a resource, create a VM,
or change any display device.

Local readback:

- Hypervisor present: true.
- Feature bits: `0x00000000000002ff`.
- WHP virtual PCI feature: true.
- WHP IOMMU feature: false.
- All twelve inspected vPCI API exports: present.
- Physical/shared device allocation: not attempted.

The false IOMMU feature is what **this WHP API context reports**. It is
not a firmware inventory or proof that the physical machine lacks an IOMMU.
Generic vPCI support and exported functions also do not prove that an AMD
shared-GPU resource can be allocated for a third-party VMM.

## Implementation Gates

1. Identify a supported resource-provider path for a shared RX GPU on an
   independently created WHP partition. Do not replace this with DDA or
   dismount the display GPU implicitly. If no suitable provider exists,
   evaluate an explicit graphics-remoting backend rather than claim native
   GPU-PV support.
2. Implement the required WHPX guest transport: interrupts/events, shared
   memory/GPADLs, VMBus discovery and device services. Review which OpenVMM
   components can be reused and which must be adapted to QEMU's lifetime
   and memory model.
3. Implement the matching guest device/driver contract. Keep PCI assignment,
   GPU-PV and graphics-API forwarding distinct in the profile and reports.
4. Validate actual resource allocation, rendering fences/pixels, presentation,
   input and recovery in the same persistent custom-SMBIOS Windows guest.
5. Run application sessions and host-continuity checks before declaring
   compatibility or measuring game performance.

The comment about OpenVMM gaining non-native architecture emulation concerns
**CPU execution backends**. It supports architectural extensibility, but it
does not establish GPU-PV interoperation between QEMU and HCS.

## Looking Glass

The Limiar-owned [Looking Glass fork](https://github.com/templarsco/LookingGlass)
is the separate Windows-client workstream. We do not depend on an upstream
Windows-client release. Preserve upstream licensing and protocol attribution,
and keep this component separate from Limiar's MIT/Apache launcher.

A viewer port does not create the guest GPU device. Its own milestones are
native Windows window/input support, a compatible local memory transport,
frame presentation and recovery, audio, and measured high-refresh behavior.
Neither creating a fork nor installing the guest capturer completes these
milestones.

## Source References

- [OpenVMM pinned device allocation](https://github.com/microsoft/openvmm/blob/f60e3d6a57ce5d0cfee48ead3bca5ce9908effba/openvmm/openvmm_entry/src/lib.rs)
- [OpenVMM pinned VMBus/vPCI integration](https://github.com/microsoft/openvmm/blob/f60e3d6a57ce5d0cfee48ead3bca5ce9908effba/openvmm/openvmm_core/src/worker/dispatch.rs)
- [QEMU inspected Hyper-V device configuration](https://github.com/qemu/qemu/blob/19b46407eefb24736bd46c3f7f4537d5550ab5ea/hw/hyperv/Kconfig)
- [Microsoft WHvAllocateVpciResource](https://learn.microsoft.com/en-us/virtualization/api/hypervisor-platform/funcs/whvallocatevpciresource)
- [Microsoft WHvCreateVpciDevice](https://learn.microsoft.com/en-us/virtualization/api/hypervisor-platform/funcs/whvcreatevpcidevice)
- [Microsoft WHvGetCapability](https://learn.microsoft.com/en-us/virtualization/api/hypervisor-platform/funcs/whvgetcapability)
