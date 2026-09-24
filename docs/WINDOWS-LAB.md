# Windows 11 GPU-PV Lab

This development workflow installs a persistent Windows VM and verifies GPU
work from inside it. It uses native Hyper-V management, not the OpenVMM
profile registry or the disposable HCS Linux probe.

## Requirements And Boundaries

- Windows with Hyper-V management, PowerShell 7, and rights to manage VMs.
- Python 3.10+ and a 7-Zip-compatible CLI (`7z.exe`, including NanaZip).
- User-supplied Windows 11 x64 ISO containing `sources/install.wim`.
- Current template: pt-BR, edition ID `Professional`; edition index is read
  from the WIM, not assumed to be the English ISO's index.
- A partitionable GPU and a Windows driver package in the host driver store.
- Rust/Visual Studio build tools for the portable CLI.

Default VM resources: 4 vCPUs, 8 GiB RAM and an 80 GiB dynamic VHDX. No physical
disk, host directory share or network adapter is attached. Secure Boot and
vTPM are configured through Hyper-V and verified again inside Windows.
No host firmware/security policy or GPU driver is changed.

Consumer Radeon/Windows client GPU-PV remains an experimental combination.
Guest system manufacturer/model and synthetic device information remain
Hyper-V-generated. Do not treat registered owner, hostname or GPU driver
labels as full SMBIOS customization.

## Prepare And Install

Run from the checkout in PowerShell 7:

```powershell
python -m venv .limiar/tools/iso
.\.limiar\tools\iso\Scripts\python.exe -m pip install --require-hashes `
  --only-binary=:all: -r runtime/windows-tools-requirements.txt
.\scripts\Build-PortableCli.ps1

.\scripts\windows\New-LabVm.ps1 -Name Limiar-Win11-25H2
$lab = ".limiar/windows/Limiar-Win11-25H2/lab.json"
.\scripts\windows\Prepare-Install.ps1 -LabPath $lab -Iso "F:\ISOs\your-windows.iso"
.\scripts\windows\Start-Install.ps1 -LabPath $lab
.\scripts\windows\Wait-Install.ps1 -LabPath $lab
```

`New-LabVm` creates a new directory/disk and refuses existing names or paths.
It records the VM GUID and ownership marker. The setup answer file targets
disk 0 **inside that exclusively configured VM**, not disk 0 on the host.
The lab layout is EFI/MSR/Windows; production recovery/backup workflows remain
future work.

`Read-Media.ps1` hashes the ISO, checks the signature on `setup.exe`, and reads
the WIM XML using the archive reader. It mounts only the selected ISO as
read-only, and unmounts it only if this invocation mounted it. This is not a
full-media authenticity attestation.

Preparation creates a random local administrator password and a one-time
autologon bootstrap. Credentials are protected with the current Windows
user's DPAPI in `credential.xml`. The provisioning ISO contains an answer
file with that password, so its entire directory has a private ACL and must
never be published. Autologon and its registry password are removed by the
guest bootstrap.

The current template can stop at the normal product-key screen. Select
**I don't have a product key**, or use your own license. This lab does not
activate Windows, fetch activation keys, or bypass Windows hardware checks.
Do not send blind timed keyboard input: it can arrive after setup has
already moved to another screen.

Preparation can resume with `-Resume` before installation. It checks the
existing owner, edition and credentials instead of generating new secrets.
The raw XML template is not deployment media; use the preparation script.

## Driver And GPU

After the guest has a configured user and its bootstrap has completed:

```powershell
.\scripts\windows\Prepare-GpuDriver.ps1 -LabPath $lab -Adapter "RX 9070 XT"
.\scripts\windows\Stage-GuestDriver.ps1 -LabPath $lab
.\scripts\windows\Enable-GpuPv.ps1 -LabPath $lab
.\scripts\windows\Test-GuestGpu.ps1 -LabPath $lab -Cycles 3
```

The preparer resolves the explicitly selected GPU service's driver-store
package. It excludes transient log/ETL/temp files, copies immutable package
files to a local ISO, and records file hashes. Staging runs inside the
authenticated guest and verifies every copied file under `HostDriverStore`.
Source driver packages and generated ISOs are local-only, not redistributable
Limiar artifacts.

GPU attachment requires a normal guest shutdown. It adds one partition from
the selected host device, keeps the physical GPU on the host, and switches
boot order to the installed VHDX. Installation and driver DVDs are removed.
The workflow never silently selects another GPU or changes global partition
counts/quotas.

The validation enumerates DXGI in the guest, matches PCI vendor/device and
checks the per-run index/LUID. If the guest exposes multiple matching logical
entries, each is tested explicitly. It checks D3D11 clear/copy/readback pixels,
Secure Boot and TPM. These are small correctness workloads, not a benchmark
or proof of Vulkan/OpenGL/encoding/game compatibility.

## Lifecycle And Inspection

```powershell
.\scripts\windows\Stop-LabVm.ps1 -LabPath $lab
.\scripts\windows\Start-LabVm.ps1 -LabPath $lab
.\scripts\windows\Save-ConsoleImage.ps1 -LabPath $lab -OutputPath .limiar/windows/console.png
.\scripts\windows\Invoke-WindowsValidation.ps1 -LabPath $lab -BootCycles 3
```

Stop requests normally use guest shutdown. `-Force` explicitly powers off
the owned VM and can lose guest data; it never deletes the VHDX. Starting a
GPU-enabled VM checks the recorded partition and host driver version again.
After a host driver update, prepare and verify a matching guest driver before
reusing the lab; an automated upgrade path is not implemented yet.

Use Hyper-V Manager/VMConnect to interact with the desktop. The account is
`limiar`. Its password can be retrieved locally by the same host user through
`Import-Clixml` on the lab's `credential.xml`; never put it in public reports.
The protected credential and vTPM state are machine-specific, not a portable
standalone disk image.

PowerShell Direct requires no guest network/WinRM configuration. Persistent
sessions are used for file transfer and GPU provisioning. Run guest operations
sequentially. Metadata updates have a short file lock, merge independent
changes, and reject conflicting updates.

## Results And Remaining Work

See [local Windows evidence](validation/2026-09-24-windows-gpu-pv.md).
Still pending: full identity control in the GPU-enabled backend, a unified
registry/service, interactive console integration in Limiar, installer
packaging, storage recovery, driver upgrades and sustained workload testing.

## References

- [PowerShell Direct](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/powershell-direct)
- [VM key protectors](https://learn.microsoft.com/en-us/powershell/module/hyper-v/set-vmkeyprotector)
- [Windows setup disk configuration](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-setup-diskconfiguration)
- [Windows local-account setup](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-useraccounts-localaccounts-localaccount)
- [Hyper-V console thumbnails](https://learn.microsoft.com/en-us/windows/win32/hyperv_v2/getvirtualsystemthumbnailimage-msvm-virtualsystemmanagementservice)
- [pycdlib](https://github.com/clalancette/pycdlib), pinned external ISO-builder tool, LGPL-2.1-only.
