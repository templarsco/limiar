# Limiar Core Contract

Decision date: September 24, 2026; current status updated September 27.
Native Hyper-V/OpenHCL is the active path. Initial same-VM custom firmware
and GPU-PV offscreen rendering passed; complete platform delivery is open.

## Mission

Build a Windows-first PC virtualization platform with configurable native
guest firmware/hardware and accelerated desktop applications.
Machine identity, firmware and virtual hardware configuration are central
requirements, not optional decorations on a fixed Hyper-V guest.

The user should be able to configure and boot a coherent PC environment,
use everyday applications and games, and retain practical control of its
resources. Limiar supplies editable defaults and persistent identities.
The purpose is to separate intrusive applications from the main Windows
installation, without cheating. Isolation remains a property to validate.
The Hub makes that platform convenient to use; a new management interface
alone does not fulfill the mission.

Gaming is the initial application-compatibility reference. AI, rendering,
additional guest families and management conveniences build on the same
core. Performance, stability and interactive usability are acceptance
criteria, not claims inferred from successful boot or a GPU being listed.

## Selected Composition

Superseding decision, September 25, 2026: the user approved native Hyper-V
with custom OpenHCL in real VTL2 and custom mu_msvm UEFI as the development
direction, reaffirmed September 27. QEMU is not the current focus:
QEMU/OVMF remains a historical configuration and compatibility reference,
not the final machine-model owner or an active development gate.
Standalone OpenVMM/WHP, emulated VTL2 and WSL-nested KVM are not the
selected delivery runtime.

Firmware, device and CPU behavior must be mapped to the component that
actually owns it. A management wrapper around an unchanged Hyper-V VM
remains insufficient. Running a paravisor does not automatically grant
control over all behavior owned by the underlying hypervisor.

Prefer shared GPU-PV while retaining the RX 9070 XT on the Windows host.
The user also admitted IOMMU-backed assignment as an alternative. This is
not authorization to dismount the display GPU: assignment needs a concrete
available device, host support, explicit approval and recovery procedure.
Allocation, guest transport, graphics-driver behavior and presentation
must be implemented and measured together. Separate successful Hyper-V
GPU and QEMU identity fixtures do not constitute this result.

The [public OpenHCL summary](OPENHCL-COMPATIBILITY.md)
describes the current direction. The [earlier QEMU GPU investigation](QEMU-GPU-PV.md)
is retained as historical research. Neither generic VMBus relay nor a
custom firmware build alone establishes working GPU-PV through OpenHCL.
The later same-VM firmware readback and D3D11 pixel evidence does establish
bounded native feasibility; it does not establish complete delivery.

## Required Outcome

| Requirement | Acceptance target |
|---|---|
| Machine ownership | User-controlled firmware and machine configuration, not only a display name or guest registry edits |
| SMBIOS coverage | Field-by-field native coverage with implementation owners and explicit gaps; QEMU is a comparison reference, not an active backend requirement; publish only selected reviewed evidence |
| Coherent virtual hardware | CPU/topology, memory, ACPI, devices, storage and networking agree with the resources actually exposed |
| Combined graphics | Configurable identity and working accelerated graphics in the same persistent Windows guest |
| Shared GPU preference | Prefer keeping the RX 9070 XT usable on the Windows host; evaluate other transports when needed |
| Application experience | Rendered/presented frames, working input/audio and repeatable application sessions, not only graphics API probes |
| Quality and performance | Repeatable cold boots, normal shutdown, recovery and measured frame times, responsiveness and host impact |

Broad machine configurability is a target, not a claim that Limiar already
implements every reference feature or every SMBIOS specification field.
Unsupported configuration must fail explicitly until its implementation
exists. GPU acceleration must not silently discard the requested identity.

## Architecture Serves The Mission

There are three different boundaries:

1. Management: profiles, lifecycle, storage, console and the future Hub.
2. Machine construction: firmware, tables, CPU/device model and GPU delivery.
3. Execution: the provider that runs guest CPUs and enforces memory isolation.

Owning only the first boundary is insufficient. The second is essential.
The third must also be open to revision if it prevents the required machine
behavior or application experience.

Using a Windows API is not, on its own, the acceptance test. QEMU's WHPX
backend and hosted OpenVMM both use Windows Hypervisor Platform, while
constructing their guests through their own VMM code. WHP still uses the
Microsoft hypervisor; a WHP-backed build must not be described as independent
of that hypervisor. Replacing guest metadata does not replace the execution
provider.

The investigation must identify which boundary owns each limitation.
Extending firmware or a VMM is appropriate for a machine-construction gap.
A hard execution-provider gap requires evaluating a different provider,
including a separate hypervisor workstream if necessary. That option is
in scope, but no replacement has been implemented or selected.

## Candidate Paths

| Path | Role and required evidence |
|---|---|
| Native Hyper-V + OpenHCL + mu_msvm | Active development path; selected firmware fields and GPU-PV offscreen rendering verified in one guest. EAC, Looking Glass, broader device control and full delivery remain open. |
| Existing native Hyper-V / HCS labs | GPU controls only. Existing VM state and ownership remain unchanged. |
| Standalone OpenVMM/WHP | Source reference and development fixture; no established native GPU-PV binding. |
| QEMU/OVMF and WSL-nested compatibility lab | Preserve configuration/patch evidence; no further migration into this runtime without a new decision. |
| Different execution provider / custom hypervisor | Contingency when evidence locates a hard blocker below the VMM. Requires its own CPU, isolation, device, driver, security, performance and recovery investigation. |

OpenHCL is an execution environment that runs OpenVMM as a paravisor.
Its name alone does not establish an independent hypervisor or solve the
combined identity/graphics requirement.

Prefer shared GPU delivery first, not a particular management API at any
cost. Graphics-transport research moves forward when required by the core;
it must not be postponed behind building a Hub for a machine that cannot
meet the mission.

## Current Acceptance Gates

These gates take priority over broad service/UI work and new guest
families. They qualify the selected native architecture; passing an
initial prototype does not complete the full coverage target.

1. Preserve the completed source pins, first custom firmware/IGVM build,
   native boot, selected identity readback and same-VM GPU-PV pixel evidence.
   Those establish feasibility, not a finished product.
2. Investigate the outstanding EAC gate in the current native guest;
   distinguish offline startup, online acceptance and owner reports.
3. Implement and verify Looking Glass capture in the guest, transport and
   viewer/input on physical Windows. TPM remains deferred.
4. Extend applicable native identity/device/CPU controls and verify readback.
   Include SMBIOS Types 0, 1, 2, 3, 4, 9, 11, 17 and 41, binary entries,
   CPU/topology, ACPI and the devices actually exposed. Unsupported fields
   remain explicit gaps rather than silently accepted profile entries.
5. Reproduce interactive application sessions without changing the scope
   of earlier owner-reported passes. Fix settings and measurement procedure
   before comparisons. Record guest and native baseline versions, frame-time
   distribution, average/low FPS, latency measurement method and host impact.
6. Record a go/no-go decision and select approved release evidence. If
   native GPU binding, required CPU behavior or host restrictions block it, record that layer
   and return the decision to the user. Do not start another sequence of
   hypervisor migrations or redefine a Hyper-V wrapper as completion.

Real applications, including games with anti-cheat, belong in the test
matrix. Compatibility is recorded per application/version/configuration.
A failing application is a core investigation item, not automatically an
irrelevant edge case; a passing test is not universal compatibility.

## Evidence And Host Safety

Version 0.4 provides reusable evidence: Linux identity verification,
Linux GPU-PV rendering, and a separate Windows GPU-PV lab. Those results
remain valid within their documented scope. They do not pass this core gate.

Version 0.5 additionally verifies 22 Type 0/1/2/3 fields in a persistent
QEMU/WHPX Windows guest with basic desktop output. Its four validated cold
boots include custom values and restoration. This advances the identity
requirement; shared GPU acceleration and the combined application gate
remain open.

The later OpenHCL result is recorded in
[the active workstream](OPENHCL-COMPATIBILITY.md). It supersedes the old
combined-feasibility gap for the measured native configuration, not for
QEMU. Preserve QEMU code, tests and VMs without resuming that work by default.

Do not change host boot/security settings, load experimental kernel drivers,
or disable/dismount a display GPU as an incidental documentation or build
step. Such experiments need a specific recovery plan and confirmation
before touching the host. Keep credentials and identifying raw inventories
private. Do not represent guest-reported metadata as physical-hardware or
remote-attestation proof.

## Publication And Licensing

Only a limited neutral Limiar firmware base and selected feasibility
evidence are intended for technical release; the lab firmware and complete
study stay private. Looking Glass is the only intended complete public
integration, under compatible upstream GPL terms.
The [component license map](../LICENSING.md) assigns no-sale/no-redistribution
terms to an explicit set of new original files, not earlier MIT/Apache
releases or third-party code. Follow the
[publication review](PUBLICATION-REVIEW.md) before any distribution.

## References

- [QEMU Windows Hypervisor Platform backend](https://www.qemu.org/docs/master/system/whpx.html)
- [QEMU machine and SMBIOS configuration](https://www.qemu.org/docs/master/system/invocation.html)
- [Hosted OpenVMM and its devices](https://openvmm.dev/guide/user_guide/openvmm.html)
- [OpenHCL execution model](https://openvmm.dev/guide/user_guide/openhcl.html)
- [Current Limiar identity coverage](IDENTITY.md)
- [Implementation roadmap and evidence](DEVELOPMENT-PLAN.md)
