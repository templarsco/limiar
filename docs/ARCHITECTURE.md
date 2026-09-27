# Limiar Architecture

## Product Direction

The [core contract](CORE-CONTRACT.md) makes user-controlled guest firmware,
coherent virtual hardware and accelerated applications the main requirement.
Native Hyper-V/OpenHCL is the active path; QEMU is a historical reference,
not the current development focus. The future Hub is a management surface.

Architecture decisions separate management, guest machine construction and
CPU/memory execution. Native Hyper-V + custom OpenHCL in real VTL2 +
custom mu_msvm UEFI is the selected development direction as of September
25, 2026, reaffirmed on September 27. QEMU remains a configuration reference. The
[public OpenHCL summary](OPENHCL-COMPATIBILITY.md) separates demonstrated
firmware and same-guest GPU-PV results from unproven Hyper-V-owned CPU
controls, presentation and device transport capabilities.
Using an API is not the acceptance test; delivering the required machine
behavior is.

The local OpenHCL guest has passed configured SMBIOS/ACPI readback and
offscreen hardware D3D11 tests in the same VM. Full platform delivery,
EAC compatibility and end-to-end Looking Glass remain open.

## AWS Nitro Inspiration

The [AWS Nitro System](https://aws.amazon.com/ec2/nitro/) is an architectural
inspiration for Limiar. Nitro separates functions traditionally grouped
inside a virtualization stack, using dedicated hardware and software for
I/O and management alongside a lightweight hypervisor.

The principles informing Limiar's design are:

- Separate management from CPU/memory execution and device services.
- Keep component responsibilities and cross-boundary interfaces narrow.
- Minimize unnecessary privilege and shared access, then validate isolation
  and performance at the actual boundaries.

Limiar pursues these principles through native Hyper-V, OpenHCL in VTL2
and custom guest firmware on a Windows PC. OpenHCL is a guest-partition
paravisor, not a Nitro Card or a replacement for Hyper-V L0. This is a
design inspiration, not a Nitro port or a claim of equivalent hardware
offload, security guarantees or performance.

## Active Native Path

```text
Hardware + host UEFI
  `-- Hyper-V (type 1)
      |-- Windows root partition: management, device services, physical desktop
      `-- Guest partition
          |-- OpenHCL in VTL2: paravisor services and guest firmware path
          `-- Custom mu_msvm boot -> Windows guest + native GPU-PV
```

Changing guest UEFI does not flash the physical machine or replace Hyper-V
L0. Device transport and management integration require independent
qualification. The current order is EAC investigation, then Looking Glass
capture/transport and a viewer on physical Windows; TPM is deferred.

## Retained CLI Fixtures

```text
Limiar CLI
  |-- host inventory + WHP capability query (read-only)
  |-- explicit DXGI adapter -> bounded native D3D11 readback test
  |-- strict TOML + persisted identity -> supervised OpenVMM -> WHP -> guest
  |-- JSON/TOML + Type 0/1/2/3 identity -> supervised QEMU -> WHPX -> Windows
  |-- explicit GPU-PV laboratory -> HCS -> disposable Linux guest
  `-- Windows lab scripts -> native Hyper-V -> persistent Windows guest
```

The current CLI is not a new hypervisor and does not replace or patch
Hyper-V. The diagram above describes earlier fixtures, not the active
OpenHCL setup procedure. QEMU and standalone OpenVMM remain for regression
testing and source reference; they are not being deleted or migrated.
The earlier stock Hyper-V lab remains a separate validation fixture.

## Historical QEMU Reference

Version 0.5 adds `qemu_uefi` to the same registry and supervisor. Its
argument vector configures Q35, WHPX, explicit QCOW2 storage, per-VM UEFI
variables, basic display/input and optional read-only optical media.
No guest NIC or physical-device assignment is enabled. QMP is optional
and uses an ACL-protected AF_UNIX filesystem endpoint, not TCP.

The backend maps 22 SMBIOS Type 0/1/2/3 fields. Windows reads the firmware
tables rather than guest registry substitutions. Startup reports carry
CIM and raw `GetSystemFirmwareTable` data over COM1. Validation uses
captured expectations and rejects ambiguous/truncated or duplicate reports.

Lab controls bind registration creation time, input paths, the kernel-reported
QMP peer PID and machine name. Local credentials remain DPAPI-protected. The console
is QEMU's SDL window, not Looking Glass or high-refresh streaming.
[QEMU Windows](QEMU-WINDOWS.md) documents the workflow and trust boundary.

## Managed Lifecycle

Version 0.2 adds a local registry of resolved configuration snapshots. Metadata
uses versioned JSON and atomic replacement. A short-lived registry lock protects
metadata mutations; a separate, long-lived per-VM lease identifies the active
supervisor. Other operations try that lease without waiting while holding the
registry lock.

The foreground supervisor owns the selected runtime's process tree. Stop requests carry
the active run identifier through a local control file. Persisted PIDs are
informational and are never used to kill a process. A running record without a
held lease is reported as interrupted.

Forced stop, guest boot verification, and graceful shutdown are separate
outcomes. `stop_requested` acknowledges runtime termination, not a clean guest
shutdown. The registry is tied to its creating host OS and is not an
authenticated multi-user API or a cross-host coordination mechanism.

Unregister removes only the registry's fixed metadata filenames. Input paths
are never used as deletion targets, and unknown files prevent removal.

## Runtime Boundary

Upstream command-line restrictions describe the pinned runtime, not the
maximum product scope. The next gate evaluates the VMM, firmware and graphics
path together. Extending only the Limiar profile schema without implementing
and verifying the corresponding guest behavior does not satisfy it.

The upstream runtime lives under ignored `third_party/openvmm`. Its immutable
revision, source repository, toolchain, and enabled build features are recorded
in `runtime/openvmm.json`. The initial build excludes optional TPM features;
a Windows 11 Secure Boot/vTPM profile is a separate acceptance milestone.
Package restore skips optional OpenHCL compatibility images with
`--no-compat-igvm`; this standalone runtime does not need those authenticated
GitHub Actions downloads.

Limiar constructs an argument vector and launches the executable directly.
Profiles cannot inject shell commands, arbitrary runtime flags, physical disks,
or PCI assignment operations. Paths resolve relative to the profile, not the
current working directory. Structured OpenVMM path arguments reject delimiters
that could change their meaning.

The runner captures stdout/stderr, distinguishes timeout from a successful
exit, and checks a guest-specific serial marker when one is configured.
Passing a process-start test is not sufficient evidence of a guest boot.

## Windows Lab

Version 0.4 adds a separate PowerShell 7 workflow around the native Hyper-V
management APIs. This supplies the persistent VHDX, Secure Boot/vTPM,
installer DVD and PowerShell Direct required for Windows validation.
It does not reuse the OpenVMM registry as if their capabilities were equal.

Every action checks a recorded VM GUID, name, ownership marker, sole VHDX and
absence of a network adapter. Guest writes additionally verify the hostname,
SMBIOS UUID and payload owner. Credential-bearing data stays in a private
directory; the host credential file uses Windows DPAPI.

Metadata writes take a short lock, merge unrelated changes and reject
conflicts. VM/guest operations are sequential. An explicit force stop never
becomes an implicit fallback, and no stop operation deletes the disk.

The Windows guest runs the same D3D11 diagnostic through PowerShell Direct.
Its report is correlated with the recorded VM and the assigned physical
GPU. DXGI index/LUID distinguishes logical entries. The standalone diagnostic
now reports `process_local_d3d11`; it cannot infer host/guest context itself.
The portable build statically links the CRT in an isolated Cargo target so
the guest does not require a preinstalled Visual C++ runtime.

## Graphics

Native graphics diagnostics enumerate DXGI adapters and reject software
adapters for the hardware test. Selection is explicit and ambiguous matches
fail. The test clears a small render target, copies it to staging memory, and
verifies every returned pixel over a bounded number of iterations.

This establishes that the selected host adapter can perform this D3D11
workload. It does not establish passthrough, GPU-P, Vulkan/DX12 support,
game compatibility, sustained performance, or guest acceleration.

Version 0.3 adds a separate HCS GPU-PV laboratory. It queries the exact adapter,
creates an owned transient compute system, starts it, then requests the GPU
partition. It never disables/dismounts a GPU, attaches a host physical disk or
falls back to another adapter. No network or host directory sharing is enabled.
Native HCS APIs are loaded from System32 only when requested.

The serial protocol acknowledges the guest's report before allowing power-off.
Rendering verification requires the matching PCI vendor/device and all 4096
pixels from a D3D12 clear/copy/readback, not merely a boot marker. HCS must
report `GracefulExit`; cleanup is checked by querying the fresh compute-system
ID after the owned handle closes. Termination-on-last-handle-close provides
process-exit cleanup as well.

The earlier standalone OpenVMM identity and HCS graphics paths are not interchangeable.
The [identity contract](IDENTITY.md) and [GPU-PV laboratory](GPU-PV.md) describe
their separate capabilities. Dedicated device assignment remains future work
with host display/recovery preflight and explicit device-specific rollback.
The native OpenHCL path has since demonstrated selected identity controls
and GPU-PV offscreen rendering in one VM. That does not extend the earlier
fixtures' capabilities or complete display/input, performance or security
qualification. Those gates still take precedence over broad management/UI work.

## Licensing And Legacy

The [component license map](../LICENSING.md) governs current licensing.
Explicitly designated original material uses the no-sale/no-redistribution
Limiar Private-Use License; existing MIT/Apache grants and upstream terms
remain intact. Looking Glass-derived work retains GPL terms and cannot be
subject to that restriction. Private lab firmware remains unreleased.

`backend/`, `driver/`, `protocol/`, and `qemu-device/` remain historical
prototype components. The new Cargo workspace does not compile or ship them.
Their presence is not a claim of supported, end-to-end functionality.

## Sources

- OpenVMM guide: https://openvmm.dev/guide/
- Pinned source: https://github.com/microsoft/openvmm/tree/f60e3d6a57ce5d0cfee48ead3bca5ce9908effba
- DDA prerequisites: https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/deploy/deploying-graphics-devices-using-dda
- D3D11 device creation: https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-d3d11createdevice
