# Limiar Core Contract

Decision date: September 24, 2026. Status: accepted product direction;
the combined runtime described here is not implemented.

## Mission

Build a Windows-first PC virtualization platform with QEMU-class control
over the guest machine and hardware-accelerated desktop applications.
Machine identity, firmware and virtual hardware configuration are central
requirements, not optional decorations on a fixed Hyper-V guest.

The user should be able to configure and boot a coherent PC environment,
use everyday applications and games, and retain practical control of its
resources. Limiar supplies editable defaults and persistent identities.
The Hub makes that platform convenient to use; a new management interface
alone does not fulfill the mission.

Gaming is the initial application-compatibility reference. AI, rendering,
additional guest families and management conveniences build on the same
core. Performance, stability and interactive usability are acceptance
criteria, not claims inferred from successful boot or a GPU being listed.

## Required Outcome

| Requirement | Acceptance target |
|---|---|
| Machine ownership | User-controlled firmware and machine configuration, not only a display name or guest registry edits |
| SMBIOS coverage | Field-by-field parity with an explicitly pinned QEMU reference, including its binary-entry input path; coverage must be published |
| Coherent virtual hardware | CPU/topology, memory, ACPI, devices, storage and networking agree with the resources actually exposed |
| Combined graphics | Configurable identity and working accelerated graphics in the same persistent Windows guest |
| Shared GPU preference | Prefer keeping the RX 9070 XT usable on the Windows host; evaluate other transports when needed |
| Application experience | Rendered/presented frames, working input/audio and repeatable application sessions, not only graphics API probes |
| Quality and performance | Repeatable cold boots, normal shutdown, recovery and measured frame times, responsiveness and host impact |

QEMU-class configurability is a target, not a claim that Limiar already
implements every QEMU feature or every SMBIOS specification field.
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
| Native Hyper-V / HCS | Keep the existing GPU and Windows fixtures as controls. A management wrapper around these unchanged guests is not the target product. |
| OpenVMM and its firmware | First implementation candidate. Extend or fork the relevant components where needed; prove Windows identity and graphics together. Existing CLI limits are not permanent product limits. |
| QEMU-based machine model | Configuration and application reference, and an alternative implementation candidate. A Windows graphics transport still needs independent validation. |
| Different execution provider / custom hypervisor | Contingency when evidence locates a hard blocker below the VMM. Requires its own CPU, isolation, device, driver, security, performance and recovery investigation. |

OpenHCL is an execution environment that runs OpenVMM as a paravisor.
Its name alone does not establish an independent hypervisor or solve the
combined identity/graphics requirement.

Prefer shared GPU delivery first, not a particular management API at any
cost. Graphics-transport research moves forward when required by the core;
it must not be postponed behind building a Hub for a machine that cannot
meet the mission.

## Next Core Gate

This gate takes priority over broad service/UI work and new guest families.
It selects a viable architecture; passing an initial prototype does not
complete the full coverage target.

1. Capture a versioned QEMU reference: executable/source revision, firmware,
   machine options, Windows build, graphics path and application versions.
   The reported Roblox-on-QEMU result is a useful user observation, not yet
   a reproduced Limiar test.
2. Map the reference's configuration fields to their implementation owners
   and current support. Include SMBIOS Types 0, 1, 2, 3, 4, 9, 11, 17 and 41,
   binary entries, CPU/topology, ACPI and device configuration. Record gaps
   without treating unknown support as impossible.
3. Prove persistent Windows boot with distinct custom BIOS, system,
   baseboard and chassis profiles in a candidate VMM/firmware path.
   Read the resulting values inside the guest and compare them after reboot.
4. Add accelerated, presented graphics to that same VM. Test the requested
   adapter, input, audio and host display continuity. Separate successful
   device attachment from successful workloads.
5. Reproduce an interactive application session, with Roblox as the first
   candidate. Fix the scene, settings, resolution and measurement procedure
   before comparisons. Record guest and native baseline versions, frame-time
   distribution, average/low FPS, latency measurement method and host impact.
6. Publish a go/no-go decision for the candidate. If it cannot meet the
   combined requirements, record the blocking layer and advance the next
   candidate instead of redefining a Hyper-V wrapper as completion.

Real applications, including games with anti-cheat, belong in the test
matrix. Compatibility is recorded per application/version/configuration.
A failing application is a core investigation item, not automatically an
irrelevant edge case; a passing test is not universal compatibility.

## Evidence And Host Safety

Version 0.4 provides reusable evidence: Linux identity verification,
Linux GPU-PV rendering, and a separate Windows GPU-PV lab. Those results
remain valid within their documented scope. They do not pass this core gate.

Do not change host boot/security settings, load experimental kernel drivers,
or disable/dismount a display GPU as an incidental documentation or build
step. Such experiments need a specific recovery plan and confirmation
before touching the host. Keep credentials and identifying raw inventories
private. Do not represent guest-reported metadata as physical-hardware or
remote-attestation proof.

## References

- [QEMU Windows Hypervisor Platform backend](https://www.qemu.org/docs/master/system/whpx.html)
- [QEMU machine and SMBIOS configuration](https://www.qemu.org/docs/master/system/invocation.html)
- [Hosted OpenVMM and its devices](https://openvmm.dev/guide/user_guide/openvmm.html)
- [OpenHCL execution model](https://openvmm.dev/guide/user_guide/openhcl.html)
- [Current Limiar identity coverage](IDENTITY.md)
- [Implementation roadmap and evidence](DEVELOPMENT-PLAN.md)
