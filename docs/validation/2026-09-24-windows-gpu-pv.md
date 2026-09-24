# Limiar 0.4 Windows GPU-PV Validation

Date: September 24, 2026. This report is sanitized; credentials, full
installation artifacts, host paths and unique VM/device identifiers remain
local and are not published.

## Environment

- Host: Windows 11 Enterprise build 26200; Ryzen 7 9800X3D.
- GPU: AMD Radeon RX 9070 XT, vendor/device `1002:7550`.
- Host GPU driver: `32.0.31041.3013`.
- User-supplied Windows 11 25H2 pt-BR x64 ISO, 8172068864 bytes.
- ISO SHA-256: `50fe4703cf0df0072e093d1f5d58ed450e4c49d8ca960433bbe6278d5ef10107`.
- `setup.exe` signature verified as valid, signed by Microsoft Corporation.
- WIM edition `Professional`, index 4, version `10.0.26200.8037`.
- VM: generation 2; 4 vCPUs; 8 GiB RAM; new 80 GiB dynamic VHDX.
- No guest NIC, host directory share or attached physical disk.
- Host process was non-elevated, with existing Hyper-V Administrators membership.

The file hash and signed setup executable identify the chosen input but are
not a full-media provenance attestation.

## Results

| Check | Outcome |
|---|---|
| Windows installation and desktop | Passed; Windows 11 Pro pt-BR booted |
| Guest correlation | PowerShell Direct hostname, SMBIOS UUID and ownership marker matched |
| Secure Boot | Confirmed in the VM configuration and inside Windows |
| TPM | Enabled and present; guest reported TPM 2.0 |
| Portable CLI | `limiar 0.4.0` ran in clean Windows; copied binary hash matched |
| GPU driver provisioning | 128 files copied and hash-verified in guest HostDriverStore |
| Host GPU attachment | Exactly one partition from the explicitly selected RX |
| Device status | Guest video devices reported status OK / error code 0 |
| DXGI enumeration | Two logical RX entries with distinct LUIDs; not two physical assignments |
| D3D11 correctness | Every selected logical entry passed clear/copy/readback |
| Cold boots | Three normal shutdown/start cycles passed |
| Per cold boot | Six GPU tests, 73728 verified pixels, Secure Boot and TPM retained |
| Total cold-boot run | 18 GPU tests; 221184 verified guest pixels |
| Host graphics | 12288 native pixels passed before and after |
| Host display routes | Unchanged before and after the cold-boot run |
| Interactive console | Guest login and desktop captured after GPU-PV attachment |
| Rust tests | 46 passed on Windows and Ubuntu/WSL |
| PowerShell workflow checks | 30 assertions with fake providers; no hardware operations in the test suite |
| ISO builder tests | Five passed on Windows; symlink test is platform-gated |

These are small correctness tests, not sustained-load or game benchmarks.
Each diagnostic run verifies 3 x 64 x 64 pixels, selects an explicit DXGI
index, and checks vendor/device, software flag and LUID.

The guest uses the Windows synthetic GPU-PV device (`1414:008e`) with a
Microsoft transport driver and the copied AMD user-mode components. Its
transport driver version is not expected to equal the host vendor package
version. Those differences are retained in diagnostics rather than hidden.

## Issues Found And Corrected

- DISM's PowerShell image metadata command required elevation. The read-only
  media inspector now uses the installed archive reader's WIM XML output.
- The pinned ISO library supports UDF 2.60, and publication is now atomic so
  failed builds do not leave reusable partial images.
- Timed boot-key injection could arrive at the product-key field. It was
  removed. The standard "I don't have a product key" option was selected for
  this lab; Windows activation was not performed.
- The original CLI required `VCRUNTIME140.dll`, absent in the clean guest.
  The new isolated portable build statically links the CRT and runs without
  installing a host or guest redistributable.
- A driver-store log file was actively changing/locked. Transient logs are
  excluded; immutable package files remain hash-checked.
- Single-use remoting calls showed transport errors. Provisioning uses
  explicit persistent PowerShell Direct sessions and closes them afterward.
- DXGI exposed two matching logical entries. The verifier tests each
  explicitly, with LUID checks, instead of choosing a hidden default.
- On this host, console image data has a four-byte big-endian packet-size
  prefix. The reader validates it and accepts the supported bounded capture
  sizes; it does not misinterpret the prefix as pixel data.

## Remaining Boundaries

The Windows guest still reports Hyper-V's system manufacturer/model.
OpenVMM's configurable Type 0/1 identity does not carry into this native
Windows lab. Full SMBIOS/CPUID/ACPI/PCI customization remains unresolved.

The installer workflow can require the normal product-key choice. It is
not a completely unattended production installer. Driver upgrade/rollback,
recovery partitions, migration, signed packaging, GUI integration and
sustained graphics workloads remain future work.

No host GPU was disabled or dismounted. No existing VM was modified.
No host BIOS, driver, security-policy or activation setting was changed.
Generated installation/driver ISOs, VM disks and credentials are private,
local artifacts and are not part of the release package.
