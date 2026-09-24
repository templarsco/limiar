# VM Identity

User-owned PC identity and machine configuration are central to Limiar,
not an optional cosmetic layer. The [core contract](CORE-CONTRACT.md)
targets QEMU-class control together with accelerated applications in the
same Windows guest.

A profile describes the machine being configured; it is not a promise that
synthetic devices or the hypervisor disappear. Capabilities must be checked
for each backend and boot method. A current backend restriction is an
implementation gap to investigate, not automatically a permanent product
restriction.

## QEMU Coverage Target

The reference surface includes configurable SMBIOS Types 0, 1, 2, 3, 4, 9,
11, 17 and 41, plus explicit binary entries. Track parity by field against
a pinned QEMU revision and firmware configuration before claiming complete
coverage. That baseline capture is still pending.

System/baseboard/chassis identifiers, processor information, memory devices,
slots, OEM strings and onboard devices belong in that coverage work.
Binary input needs bounded parsing and structural validation; it is not a
reason to accept malformed tables or arbitrary runtime commands.
Resource-bearing fields must remain coherent with the actual machine.

The implementation below is only a subset. Future fields are not accepted
TOML keys until their generation and guest verification exist. CPU/CPUID,
ACPI, PCI and graphics-driver behavior are separate parts of the machine
contract; SMBIOS coverage alone does not complete it.

## Implemented Contract

The optional `[identity]` section uses `preset = "limiar"` by default.
`preset = "custom"` requires a system manufacturer and product. Both presets
permit explicit values for every implemented field.

| Profile key | SMBIOS | Comparison key |
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
| `baseboard.manufacturer` | Type 2, QEMU only | `board_vendor` |
| `baseboard.product` | Type 2, QEMU only | `board_name` |
| `baseboard.version` | Type 2, QEMU only | `board_version` |
| `baseboard.serial` | Type 2, QEMU only | `board_serial` |
| `baseboard.asset` | Type 2, QEMU only | `board_asset_tag` |
| `baseboard.location` | Type 2, QEMU only | `board_location` |
| `chassis.manufacturer` | Type 3, QEMU only | `chassis_vendor` |
| `chassis.version` | Type 3, QEMU only | `chassis_version` |
| `chassis.serial` | Type 3, QEMU only | `chassis_serial` |
| `chassis.asset` | Type 3, QEMU only | `chassis_asset_tag` |
| `chassis.sku` | Type 3, QEMU only | `chassis_sku` |

The third column names comparison keys, including fields decoded from
raw Windows SMBIOS in 0.5. Not every key has a Linux sysfs file or has
been validated on Linux.

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

For `qemu_uefi`, the Limiar preset also fills board/chassis defaults and
stable serials. Updates preserve those serials unless replacements are
supplied. All 22 fields are overrideable. Version 0.5 does not change
OpenVMM defaults; older binaries cannot read the new backend/extensions.

## Backend Limits

| Backend / boot | Type 0 | Type 1 | Type 2/3 | Shared GPU |
|---|---|---|---|---|
| OpenVMM / Linux direct | Implemented and tested | Implemented and tested | Not implemented | Not implemented |
| OpenVMM / UEFI | Rejected | Mapped to upstream fields; Windows guest validation pending | Not implemented | Not implemented |
| QEMU / UEFI | Implemented and Windows-verified | Implemented and Windows-verified | 11 fields implemented and Windows-verified | Not implemented |
| HCS / Linux probe | No override | No override | No override | Experimental GPU-PV path |
| Native Hyper-V / Windows lab | No override | Hyper-V-generated, observed in guest | No override | Windows D3D11 tests passed in 0.4 |

The HCS probe does not consume OpenVMM profiles or their identity values.
Combining full identity controls with shared graphics in one production VM
requires more backend/firmware work. There is no automatic fallback that drops
identity settings to make an unsupported backend start.
The QEMU reference now combines Type 0/1/2/3 identity and basic desktop
output, but not shared GPU acceleration. See [QEMU Windows](QEMU-WINDOWS.md).
The native Hyper-V lab cannot close this gap through a UI change. The core
gate must extend or revise the machine/firmware path and verify the configured
identity in the same Windows guest that performs the graphics workload.

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
The baseboard/chassis string fields in the implemented table above are
the exception added in 0.5. Broader topology and binary-table controls
remain planned. JSON profiles share TOML's validation.
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

Windows uses `scripts/qemu/Test-GuestIdentity.ps1` with a completed Limiar
run report. It decodes raw `RSMB` data, compares captured expectations and
cross-checks the Windows system view. `vm verify-identity` remains the
Linux probe workflow.

## Upstream References

- [QEMU configuration and SMBIOS reference](https://www.qemu.org/docs/master/system/invocation.html)
- [Pinned OpenVMM SMBIOS CLI and loader restrictions](https://github.com/microsoft/openvmm/blob/f60e3d6a57ce5d0cfee48ead3bca5ce9908effba/openvmm/openvmm_entry/src/cli_args.rs)
- [Linux direct-boot identity mapping](https://github.com/microsoft/openvmm/blob/f60e3d6a57ce5d0cfee48ead3bca5ce9908effba/openvmm/openvmm_core/src/worker/vm_loaders/linux.rs)
- [UEFI identity mapping and explicit BIOS rejection](https://github.com/microsoft/openvmm/blob/f60e3d6a57ce5d0cfee48ead3bca5ce9908effba/openvmm/openvmm_core/src/worker/vm_loaders/uefi.rs)
