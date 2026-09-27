# Native OpenHCL Workstream

Public status summary, September 27, 2026. Limiar's active direction is
Windows + native Hyper-V + OpenHCL in real VTL2 + custom mu_msvm guest
firmware, with shared GPU-PV. QEMU/WHPX and VirGL are retained historical
references and regression fixtures, not the current implementation focus.

This page is a selected feasibility summary. The full lab study, private
profiles, runtime experiments and firmware images are not published here.

## Purpose And Architecture

The goal is to run games and applications in a controlled guest separate
from the main Windows installation, while retaining useful graphics and
user-controlled machine configuration. This is virtualization development
and compatibility research, not cheat development. Isolation is a security
property to validate, not a guarantee inferred from booting a VM.

The [AWS Nitro System](https://aws.amazon.com/ec2/nitro/) inspires the
separation of management, execution and device services. Limiar uses
Hyper-V/OpenHCL on a Windows PC, not Nitro hardware or its security model.
Hyper-V is type 1; the desktop runs in the root partition. OpenHCL runs
inside the guest partition and is not a replacement for Hyper-V L0.
See the [architecture](ARCHITECTURE.md) and [core contract](CORE-CONTRACT.md).

## Demonstrated Feasibility

The following observations belong to an internal lab configuration. They
do not validate a binary built from the newly published neutral profile.

| Area | Local result | Limit |
|---|---|---|
| Runtime | Persistent Windows boot under native Hyper-V with OpenHCL in VTL2 and custom mu_msvm | Not a turnkey public VM installer |
| Guest firmware | Configured BIOS, SMBIOS Type 0/1/2/3 and selected ACPI values verified through guest readback | Not every SMBIOS, CPU or device field is implemented |
| Graphics | Hardware D3D11 offscreen pixel checks passed in that same guest through GPU-PV; physical-host GPU retained | Not a latency, presentation or universal graphics-API result |
| Combined requirement | Custom guest firmware metadata and hardware GPU-PV coexist in one guest | Does not imply unrestricted L0 control or universal application acceptance |

This demonstrates more than changing a VM display name or guest registry
label. It does not establish equivalence to physical hardware, protection
from every guest-to-host vulnerability or support for every application.

## Selected Source Reference

The [neutral Limiar base](LIMIAR-FIRMWARE-BASE.md) includes an editable
project-named JSON profile, a metadata generator and tests. It does not
contain upstream firmware sources, the private producer patches, an image
builder/installer, or a compiled UEFI/IGVM image. Generating C/DSC metadata
is not the same as building or booting firmware.

The profile keeps the VM characteristic enabled, contains no copied
physical-machine identities and leaves runtime-owned UUID/serial values
outside its schema. The experimental ACPI publication controls and native
CPU investigations are not included in this public reference.

## Current Priorities

1. Continue the remaining EAC compatibility investigation without
   presenting an offline startup or isolated report as universal support.
2. Implement and validate Looking Glass capture in the guest, transport,
   and viewer/input on physical Windows; measure the resulting performance.
3. Complete the applicable native device, reliability and isolation gates.

TPM work remains deferred. Looking Glass is the intended complete public
integration under its upstream GPL terms; it is not delivered by this
source-reference update. Neither QEMU work nor a different runtime is
automatically resumed by these open gates.

## Publication Boundaries

The private lab firmware, detailed study and raw evidence remain local.
The selected original reference uses the [component license map](../LICENSING.md);
earlier MIT/Apache and third-party grants are preserved. GitHub platform
viewing/forking rights remain applicable to this public publication.
Follow the [publication review](PUBLICATION-REVIEW.md) for future updates.

## References

- [Microsoft Hyper-V architecture](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/architecture)
- [OpenHCL architecture](https://openvmm.dev/guide/reference/architecture/openhcl.html)
- [mu_msvm](https://github.com/microsoft/mu_msvm)
- [Development plan](DEVELOPMENT-PLAN.md)
