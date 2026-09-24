# Configurable Windows Reference

Limiar 0.5 adds an experimental QEMU/WHPX UEFI backend to the existing
profile registry and process supervisor. Windows 11 boots with 22
configurable SMBIOS Type 0/1/2/3 fields in this path. It is an identity-test
machine with a basic display, not the completed accelerated PC described
in the [core contract](CORE-CONTRACT.md).

## Capabilities

- Persistent QCOW2 disk and per-VM UEFI variable storage.
- BIOS, system, baseboard and chassis identity, including stable UUID and
  serials. See the [field contract](IDENTITY.md).
- CPU models `host`, `compatible` and `max`, plus vCPU count and memory.
- Local SDL console, keyboard and USB tablet pointer.
- Optional read-only optical media for guest tools.
- Registry leases, logs and owned process-tree cleanup.

It does not provide RX 9070 XT GPU-PV, dedicated GPU assignment, 240 Hz
presentation, audio, networking, full QEMU field parity or universal
application compatibility. The selected non-secure OVMF firmware does not
provide verified Secure Boot, and this profile has no vTPM.

The native Hyper-V Windows GPU-PV lab remains a separate fixture. Its
graphics and security results do not transfer to this QEMU machine.

## Isolated Runtime

```powershell
cargo build --release --locked
.\scripts\Initialize-Qemu.ps1
```

The initializer needs PowerShell 7 and a `7z.exe` command. It verifies the
publisher archive's pinned SHA-512, extracts it below `.limiar/tools/`,
and checks the executable version. It does not execute the installer or
replace a system QEMU installation.

For an already downloaded original installer:

```powershell
.\scripts\Initialize-Qemu.ps1 -ArchivePath "C:\Downloads\qemu-w64-setup-20260811.exe"
```

The same checksum is required. The optional **QEMU Runtime Cache** workflow
stores only the verified public installer for three days. It is a download
cache, not a hardware or Windows-boot test.

The local older QEMU 10.2 build could not initialize OVMF pflash through
WHPX. QEMU 11.1 passed that test. Retain the default Q35 interrupt controller:
forcing `kernel-irqchip=off` stalled the tested Windows guest.

## Import A Disk

Use a trusted, already installed Windows virtual disk whose source VM is
powered off. This copies/converts it; it does not install Windows, unlock
BitLocker, move a TPM or generalize the guest OS.

```powershell
.\scripts\qemu\New-LabVm.ps1 `
  -Name Limiar-Win11-Custom `
  -SourceDisk "C:\VMs\installed-windows.qcow2" `
  -SourceFormat qcow2
```

`vhdx` and `raw` source formats are also accepted. Normal image locks stay
enabled. Existing destinations and registrations are not overwritten.
Failed imports retain their record and files for inspection.

TPM-protected disks need their own migration procedure. The local
validation used a separate copy with BitLocker protection already off;
neither the source disk nor its protection was changed.

The import preserves the Windows installation, accounts and hostname.
It generates a new Limiar hardware identity at registration. Media and
activation remain user-managed. Optional `-CredentialPath` accepts a
machine-local, DPAPI-protected `PSCredential` exported with `Export-Clixml`.

## Start, Edit And Stop

```powershell
$lab = ".limiar/qemu/Limiar-Win11-Custom/lab.json"
.\scripts\qemu\Start-LabVm.ps1 -LabPath $lab
.\scripts\qemu\Stop-LabVm.ps1 -LabPath $lab
```

Start applies the editable `profile.json` beside `lab.json`, then starts a
background Limiar supervisor and visible QEMU console. It runs until guest
exit or explicit stop, without a scheduled runtime timeout. Starting an
already running lab does not apply pending edits.

Stop the VM, edit its `identity` section, then start it again. Lab helpers
retain the fixture's name, runtime, firmware, storage and control endpoint.
Those ownership checks do not restrict the exposed identity values. Use
separate trusted profiles for broader runtime experiments.

UUID, system serial, board serial and chassis serial survive updates when
omitted from a template. Explicit replacements are respected. Persisted
profile snapshots remain separate from the editable source.

Normal stop requests ACPI power-off and waits. It never silently falls back
to termination. `-Force` explicitly terminates the owned runtime and risks
guest data loss. No stop command deletes a disk. Prefer the guest shutdown
menu or stop helper over closing the QEMU process while Windows is writing.

Strict TOML and JSON profiles share the same validation:

```powershell
.\target\release\limiar.exe vm show Limiar-Win11-Custom
.\target\release\limiar.exe vm preview Limiar-Win11-Custom
.\target\release\limiar.exe vm start Limiar-Win11-Custom --until-shutdown
```

`--until-shutdown` cannot be combined with a timeout or smoke mode.
Direct `vm run` also accepts it; bounded diagnostics retain their timeouts.
For standalone QEMU profiles, `read_only_base = true` enables QEMU's
temporary snapshot writes, including the writable firmware-variable drive.
The persistent lab deliberately sets this to `false`.

## Identity Evidence

The collector uses Windows CIM and `GetSystemFirmwareTable('RSMB')`.
It writes a bounded report to COM1, an identity JSON file in the guest,
and an identity summary on the public desktop.

Prepare read-only tools media for an imported lab:

```powershell
.\scripts\qemu\Prepare-GuestTools.ps1 -LabPath $lab
```

This uses the pinned Python ISO-builder environment documented in
[Windows Lab](WINDOWS-LAB.md). The media contains no passwords. On the next
boot, run `setup.ps1` from the `LIMIAR_TOOLS` DVD as administrator inside
the guest. The installer checks the intended guest UUID, protects the
collector files and configures its startup task. Hibernation can be
disabled for full-boot validation.

The guest-only `Install-IdentityProbe.ps1` also has an explicit
`-PrepareStorage` option for built-in AHCI/NVMe/IDE boot drivers before
export. Do not run it against an unrelated Windows installation.

After a completed cold-boot run:

```powershell
.\scripts\qemu\Test-GuestIdentity.ps1 `
  -RunReport ".limiar/qemu/Limiar-Win11-Custom/runs/RUN/supervisor.json"
```

Validation uses values captured by the actual launch, not a later edited
profile. It rejects incomplete, duplicate or malformed reports and checks
the Windows system view against raw SMBIOS. Use one cold boot per validation
run. This is guest-reported consistency evidence, not remote attestation.

`vm verify-identity` remains the Linux DMI-probe command, not the Windows
report validator.

## Trust And Next Work

Keep `.limiar/` private: disks, identifiers, logs and optional credentials
belong to the local machine. `Show-Credential.ps1` displays a saved guest
credential in a local dialog only when invoked, not in terminal output.

QMP binds only to `127.0.0.1`. Lab controls check the supervised runtime PID,
listener ownership and QEMU name. This is local developer tooling, not an
authenticated multi-user service. Do not expose the port to other machines
or untrusted local users. Profiles and disk backing chains must be trusted;
selecting a runtime executable is not a sandbox.

Next is configurable identity and accelerated graphics in the same
backend. Looking Glass B7 is a reference for the future display/input
path; no Looking Glass code or high-refresh viewer is shipped here.
Proxmox is a reference for later advanced management, not a proposed
conversion of the Windows host.

## References

- [QEMU WHPX](https://www.qemu.org/docs/master/system/whpx.html)
- [Firmware mapping issue and resolution](https://gitlab.com/qemu-project/qemu/-/issues/513)
- [QEMU configuration reference](https://www.qemu.org/docs/master/system/invocation.html)
- [Looking Glass B7](https://looking-glass.io/docs/B7/)
- [Windows identity validation](validation/2026-09-24-windows-custom-identity.md)
