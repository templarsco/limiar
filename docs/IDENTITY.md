# VM Identity

Limiar aims to provide coherent, user-owned PC profiles. A profile describes
the machine being configured; it is not a promise that synthetic devices or
the hypervisor disappear. Capabilities must be checked for each backend and
boot method.

## Implemented Contract

The optional `[identity]` section uses `preset = "limiar"` by default.
`preset = "custom"` requires a system manufacturer and product. Both presets
permit explicit values for every implemented field.

| Profile key | SMBIOS | Linux guest field |
|---|---|---|
| `system.manufacturer` | Type 1 | `sys_vendor` |
| `system.product` | Type 1 | `product_name` |
| `system.version` | Type 1 | `product_version` |
| `system.serial` | Type 1 | `product_serial` |
| `system.uuid` | Type 1 | `product_uuid` |
| `system.sku` | Type 1 | `product_sku` |
| `system.family` | Type 1 | `product_family` |
| `bios.vendor` | Type 0 | `bios_vendor` |
| `bios.version` | Type 0 | `bios_version` |
| `bios.date` | Type 0 | `bios_date` |
| `bios.release` | Type 0 | `bios_release` |

Keys in this table are relative to `identity`. See the
[custom profile](../examples/linux-custom-identity.toml).
Strings accept 1-64 printable ASCII bytes, without surrounding whitespace or
OpenVMM's comma/equal delimiters. Dates require a real `MM/DD/YYYY` date.
BIOS release uses two integers in 0-255. UUIDs must be nonzero and not all-ones.
Arbitrary shell/runtime arguments are not accepted.

## Limiar Preset

System defaults: manufacturer `Limiar`, product `Limiar One`, version `1.0`,
SKU `LMR-ONE`, family `Limiar Desktop`. Linux direct-boot BIOS defaults:
vendor `Limiar`, version/release `0.3`, date `09/24/2026`.
These describe the project's test profile, not a copied OEM motherboard.

Registration materializes the defaults, generates a UUID v4 if omitted, and
generates a project serial if omitted. They are persisted in the profile
snapshot and remain stable across boots.

Updating from a template with omitted UUID/serial preserves the registered
values. Explicit replacements are respected. Unregistering and registering
an unmaterialized template creates a new identity. Export the materialized
snapshot before discarding a registration whose identity must be retained.

`vm plan` is read-only and never generates identifiers. It reports
`requires_registration: true` and `ready: false` until registration, or until
both UUID and serial are explicitly provided for a direct launch.
Omitting the entire identity section opts out, including on profile update.
Version 0.3 reads 0.2 records; older binaries cannot be assumed to read new fields.

## Backend Limits

| Backend / boot | Type 0 | Type 1 | Type 2/3 | Shared GPU |
|---|---|---|---|---|
| OpenVMM / Linux direct | Implemented and tested | Implemented and tested | Not implemented | Not implemented |
| OpenVMM / UEFI | Rejected | Mapped to upstream fields; Windows guest validation pending | Not implemented | Not implemented |
| HCS / Linux probe | No override | No override | No override | Experimental GPU-PV path |
| Native Hyper-V / Windows lab | No override | Hyper-V-generated, observed in guest | No override | Windows D3D11 tests passed in 0.4 |

The HCS probe does not consume OpenVMM profiles or their identity values.
Combining full identity controls with shared graphics in one production VM
requires more backend/firmware work. There is no automatic fallback that drops
identity settings to make an unsupported backend start.

## Historical And Future Inventory

The original README named SMBIOS, CPUID and firmware. The detailed historical
QEMU example in `GAMING-VM-CONFIG.md` listed BIOS vendor/version, system
manufacturer/product/version/serial/UUID, board manufacturer/product, chassis
manufacturer/type/version, CPU flags/topology and local-time RTC.
It was a proposed configuration, not a successful compatibility test.

The new inventory also tracks:

- Baseboard and chassis serials, asset tags, location and cross-references.
- Processor identity versus actually allocated sockets/cores/threads.
- SMBIOS memory arrays/devices, capacity, slots, module data and consistency.
- Firmware version, boot mode, Secure Boot state, TPM and persistent variables.
- ACPI OEM/table identity and topology matching actual virtual resources.
- PCI device/function identifiers and the selected device delivery backend.
- Storage model/serial and volume identifiers without copying host disks.
- Locally administered, stable MAC addresses and configurable guest hostname.
- GPU identity/capabilities as reported by the actual driver, including synthetic devices.
- Agreement between Windows WMI/device inventory and Linux DMI/sysfs views.

These additional controls are a roadmap, not supported TOML keys.
Do not fake capability claims such as a TPM, firmware security state, GPU
feature level or physical DIMM arrangement that the VM does not implement.

## Verification

`vm verify-identity NAME` launches the registered Linux probe and compares all
requested values against the guest's `/sys/class/dmi/id/` report. Expected
values are captured from the actual run plan, not a later mutable profile.
Missing, mismatched, duplicate or incomplete evidence fails validation.
Logs are bounded; the managed runner also rejects kernel panic and bad exits.

This is a guest-reported consistency test, not remote attestation. Local
reports contain per-VM identifiers and must be reviewed before publication.

## Upstream References

- [Pinned OpenVMM SMBIOS CLI and loader restrictions](https://github.com/microsoft/openvmm/blob/f60e3d6a57ce5d0cfee48ead3bca5ce9908effba/openvmm/openvmm_entry/src/cli_args.rs)
- [Linux direct-boot identity mapping](https://github.com/microsoft/openvmm/blob/f60e3d6a57ce5d0cfee48ead3bca5ce9908effba/openvmm/openvmm_core/src/worker/vm_loaders/linux.rs)
- [UEFI identity mapping and explicit BIOS rejection](https://github.com/microsoft/openvmm/blob/f60e3d6a57ce5d0cfee48ead3bca5ce9908effba/openvmm/openvmm_core/src/worker/vm_loaders/uefi.rs)
