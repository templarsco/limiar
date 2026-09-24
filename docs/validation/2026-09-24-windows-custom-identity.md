# Windows Custom Identity Validation

Date: September 24, 2026.
Scope: Limiar 0.5 QEMU/WHPX Windows identity reference.

## Environment

- Windows host with WHP already enabled.
- AMD Ryzen 7 9800X3D; guest allocated four vCPUs and 8 GiB RAM.
- Separate 80 GiB virtual disk, converted from an owned Windows 11 Pro
  laboratory copy. Windows build 26200, pt-BR.
- QEMU 11.1.0, pinned publisher installer from August 11, 2026, extracted
  locally without modifying the system installation.
- OVMF UEFI with persistent variable storage; Q35 and its default interrupt
  controller. CPU `host` used for the final configuration.
- Basic VGA/SDL display, keyboard and USB tablet; no guest NIC.
- No shared or dedicated physical GPU in this backend.

The original Windows GPU-PV lab and other existing VMs were not modified.
No physical GPU was disabled or dismounted, and host boot/security settings
were not changed. The copied disk had BitLocker protection already off;
no automatic decryption or TPM transfer was performed.

## Boot Investigation

The pre-existing QEMU 10.2 build failed during UEFI pflash initialization
with WHPX MMIO-emulation errors. Firmware-only tests reproduced the failure
without a Windows disk. TCG reached the firmware shell, but was not adopted
as the delivered Windows execution path.

The isolated QEMU 11.1 runtime reached the UEFI shell through WHPX.
Windows initially stalled with a forced emulated interrupt controller;
some CPU configurations also emitted XSAVE-state warnings. Removing that
override and using the default interrupt controller allowed Windows to
boot with both `compatible` and `host` CPU models.

Failed diagnostic boots were explicitly terminated. They are not included
in the successful lifecycle count below.

## Completed Evidence

Four successful cold-boot runs each matched all 22 configured Type 0/1/2/3
fields: **88 field comparisons passed**. Every run had its own captured
launch expectations and serial report. Windows CIM system identity agreed
with the raw SMBIOS system identity.

| Run | CPU | Identity | Result |
|---|---|---|---|
| 1 | Compatible | Limiar preset with explicit BIOS values | 22/22 |
| 2 | Host | Same identity and persistent identifiers | 22/22 |
| 3 | Host | Alternate BIOS/system/board/chassis values | 22/22 |
| 4 | Host | Restored Limiar identity | 22/22 |

The alternate profile changed system manufacturer/product/family,
BIOS vendor/version, board product and chassis version. UUID and all
serials remained stable. Restoration did not recreate the disk.

Windows reached its login screen and desktop. System Information visibly
showed selected manufacturer, model, BIOS and baseboard values. Keyboard
interaction, login and basic pointer movement were exercised. These are
not input-latency or high-refresh measurements.

Normal stop requests followed by runtime exit were observed for all four
successful runs, without the force option. Guest hibernation/fast startup
was disabled and its unavailable state checked. Later checks used complete
boots rather than resumed kernel state. The generic runtime exit code
alone is not filesystem-shutdown attestation.

The collector's BIOS date formatting was corrected for CIM's timezone
conversion. Raw SMBIOS and System Information retained the configured
calendar date throughout.

## Limits

- Shared RX 9070 XT graphics remain demonstrated only in the separate
  native Hyper-V/HCS labs, not in this QEMU guest.
- System Information reports Secure Boot as unsupported with the selected
  firmware; its PowerShell query was unavailable. No vTPM is configured.
- No listed game, anti-cheat system, sustained graphics workload, audio,
  240 Hz presentation, HDR or VRR was validated.
- Coverage is the 22 mapped fields, not every QEMU field or the entire
  SMBIOS specification. Binary overrides and further table types remain
  future work.
- A tiny disposable-image import test checked copying, source preservation,
  registration, duplicate rejection and metadata-only unregister. That
  fixture was not presented as a bootable Windows test.

Raw reports, identifiers, images and credentials remain in ignored local
state. This summary contains no credentials.
