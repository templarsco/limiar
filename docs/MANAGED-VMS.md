# Managed VMs

Limiar 0.2 adds a local registry and foreground supervision. The registry belongs
to one host OS; Windows and WSL must use separate registry directories. It is
not a network service or a cross-host distributed coordinator.

## Register And Inspect

```powershell
.\target\release\limiar.exe vm register examples/linux-smoke.toml
.\target\release\limiar.exe vm list
.\target\release\limiar.exe vm show linux-smoke
.\target\release\limiar.exe vm preview linux-smoke
.\target\release\limiar.exe vm status linux-smoke
```

Registration saves a validated snapshot with absolute input paths. It does not
copy or modify the kernel, initrd, firmware, or disk images. Changes to the
original TOML file do not silently change a registered VM.

Names are case-insensitive. Names must start with an ASCII letter/digit, be at
most 48 characters, and otherwise contain only letters, digits, `-`, `_`, or
`.`. Trailing dots and Windows device names such as `CON` are rejected.

The default registry is `.limiar/vms`. Override it with
`--registry <directory>` on any `vm` command. Use a local filesystem supporting
OS file locks and atomic replacement. Do not share the registry between hosts.

## Start And Stop

In one terminal:

```powershell
.\target\release\limiar.exe vm start linux-smoke --timeout-seconds 300
```

In another:

```powershell
.\target\release\limiar.exe vm status linux-smoke
.\target\release\limiar.exe vm stop linux-smoke --force
```

`start` remains in the foreground and owns the runtime process tree. It is
bounded by its timeout. This release does not install a background service.
Serial output is captured in logs; these commands do not provide an interactive
guest console yet.

**`stop --force` terminates the runtime. It is not a graceful guest shutdown.**
Unsaved guest state is lost, and writable disk images can require recovery.
Prefer disposable guests and the default memory-backed disk overlay while
testing. Graceful shutdown remains a separate milestone.

A `stop_requested` result with `success: true` means the requested runtime
termination completed. It does not prove that the guest booted or shut down
cleanly. Check `boot_verified` / `marker_seen` and the recorded stop reason.

A bounded managed smoke test is also available:

```powershell
.\target\release\limiar.exe vm start linux-smoke --smoke --timeout-seconds 60
```

## Update And Unregister

After stopping:

```powershell
.\target\release\limiar.exe vm update linux-smoke examples/linux-smoke.toml
.\target\release\limiar.exe vm unregister linux-smoke
```

Updating requires the same VM name and increments its profile revision. The
last run retains the revision it actually used.

Unregistering removes only known registry metadata. It never removes input
images or run logs, and it refuses to remove a directory containing unknown
files. Running VMs cannot be updated or unregistered.

## State And Recovery

`status` distinguishes `registered`, `starting`, `running`, `stopping`,
`stopped`, `failed`, and `interrupted`. `running` means the supervisor owns its
lease; the guest's readiness is reported separately as `boot_verified`.

An exclusive OS file lock prevents duplicate supervisors. The lock is released
by the OS if a supervisor dies; a stale running record is then reported as
`interrupted`. Stored process IDs are informational only. Stop requests target
a run identifier, and no command kills a process based on a persisted PID.

Profiles and state are persisted through atomic file replacement. Each VM's
directory contains `profile.json`, `state.json`, `run.lock`, and, when requested,
`stop.json`. Do not edit these while a VM is running. Root registry metadata
prevents accidentally mixing Windows and Linux operations in the same store.

These files and VM profiles are trusted local configuration. The registry is
not a sandbox for untrusted host executables or an authenticated multi-user API.
No command in this release assigns or dismounts a physical GPU.

## Reproduce The Local Test

After building Limiar and preparing OpenVMM:

```powershell
.\scripts\Invoke-ManagedValidation.ps1
```

This creates an isolated test registry, verifies boot, rejects duplicate start
and live unregister, requests a forced stop, updates and restarts the profile,
then unregisters it and verifies that input hashes are unchanged. Evidence is
stored under ignored `.limiar/validation/`.
