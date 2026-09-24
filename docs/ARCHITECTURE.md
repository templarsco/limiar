# Limiar Architecture

## First Vertical Slice

```text
Limiar CLI
  |-- host inventory + WHP capability query (read-only)
  |-- explicit DXGI adapter -> bounded native D3D11 readback test
  |-- strict TOML + persisted identity -> supervised OpenVMM -> WHP -> guest
  |-- explicit GPU-PV laboratory -> HCS -> disposable Linux guest
  `-- Windows lab scripts -> native Hyper-V -> persistent Windows guest
```

The CLI is the first working surface for a future Hub. It is not a new
hypervisor and does not replace or patch Hyper-V. The Nitro inspiration is
separation of responsibilities and constrained device paths, not a claim to
reproduce AWS hardware offload in software.

## Managed Lifecycle

Version 0.2 adds a local registry of resolved configuration snapshots. Metadata
uses versioned JSON and atomic replacement. A short-lived registry lock protects
metadata mutations; a separate, long-lived per-VM lease identifies the active
supervisor. Other operations try that lease without waiting while holding the
registry lock.

The foreground supervisor owns the OpenVMM process tree. Stop requests carry
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

The OpenVMM identity and HCS graphics paths are not interchangeable.
The [identity contract](IDENTITY.md) and [GPU-PV laboratory](GPU-PV.md) describe
their separate capabilities. Dedicated device assignment remains future work
with host display/recovery preflight and explicit device-specific rollback.

## Licensing And Legacy

New Limiar code initially uses the repository's existing MIT OR Apache-2.0
terms. Upstream OpenVMM retains its MIT notices. The old QEMU device retains
its own GPL terms. A later per-component license decision does not erase
upstream notices or change already granted rights.

`backend/`, `driver/`, `protocol/`, and `qemu-device/` remain historical
prototype components. The new Cargo workspace does not compile or ship them.
Their presence is not a claim of supported, end-to-end functionality.

## Sources

- OpenVMM guide: https://openvmm.dev/guide/
- Pinned source: https://github.com/microsoft/openvmm/tree/f60e3d6a57ce5d0cfee48ead3bca5ce9908effba
- DDA prerequisites: https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/deploy/deploying-graphics-devices-using-dda
- D3D11 device creation: https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-d3d11createdevice
