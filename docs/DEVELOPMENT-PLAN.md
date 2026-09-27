# Limiar Development Plan

Current status, September 27, 2026: native Hyper-V + OpenHCL in real VTL2 +
custom mu_msvm is the active development path. Configured firmware readback
and hardware GPU-PV offscreen rendering have passed in the same Windows
guest. EAC compatibility and end-to-end Looking Glass remain open.
QEMU/WHPX and VirGL are historical reference work, not the current focus.

Earlier CLI, managed identity, Linux GPU-PV and stock Windows fixtures
remain valid within their recorded scope. The QEMU 0.5/0.6 identity and
graphics experiments are retained without migration; their limitations
do not describe the later native OpenHCL result.

## Product

Limiar targets a configurable native Windows guest with useful
GPU-accelerated applications on a Windows host. Machine identity, firmware
and virtual hardware control are the central mission. The Hub makes that
platform practical to manage; a native Hyper-V management wrapper alone is
not the product.

Native Hyper-V + custom OpenHCL + custom mu_msvm is the selected development
direction as of September 25, 2026, reaffirmed on September 27. QEMU remains
a configuration comparison and regression fixture, not a development target.
The selected public status and limitations are summarized in
[OpenHCL compatibility](OPENHCL-COMPATIBILITY.md).
The [core contract](CORE-CONTRACT.md) defines the required combined outcome
and the criteria for extending, forking or replacing components, including
the execution provider if necessary.
The initial host is Windows 11 x64; the first shared GPU under test is an
AMD Radeon RX 9070 XT. Windows, Linux, and FreeBSD are target guest families.
macOS integration and custom console-style systems are later workstreams.

The complete roadmap below is not a claim that every phase is implemented.
Each phase must produce evidence before its status changes to complete.

## Active Order

1. Preserve the working native guest and investigate the remaining
   EAC compatibility failure with versioned, bounded evidence.
2. Implement and validate Looking Glass capture in the guest, frame
   transport and viewer/input on physical Windows. Measure performance.
3. Continue the applicable native firmware/device coverage and delivery
   gates without sacrificing working graphics or host isolation.

TPM remains deferred. A neutral Limiar firmware base is a limited release
candidate, not permission to publish the lab firmware or full study.
Looking Glass is the only intended complete public integration, subject
to its upstream GPL terms. Follow [component licensing](../LICENSING.md)
and the [publication review](PUBLICATION-REVIEW.md) for every selection.

## Decisions

- Retain the existing OpenVMM and QEMU fixtures without migrating them.
  Develop the combined guest using native OpenHCL and mu_msvm. Broad
  machine control remains the requirement; further QEMU feature work is
  not selected by default. Keep its regression coverage.
- Prioritize shared GPU-PV so the host retains the GPU; dedicated assignment
  remains another delivery path. HCS is the first experimental sharing path,
  not a required product management architecture.
- Treat PC identity as user configuration, with coherent project defaults
  and persistent UUID/serial values. Do not silently drop unsupported fields.
- Earlier standalone OpenVMM identity and HCS GPU-PV fixtures are separate.
  Native OpenHCL has since passed selected identity and offscreen GPU
  checks in one guest; presented graphics and full delivery remain open.
- Preserve the earlier stock Hyper-V fixture separately from the active
  custom OpenHCL VM. A management/UI change alone is not product completion.
- Revise VMM, firmware or hypervisor choices when a demonstrated blocker
  prevents the core result. A separate hypervisor is an available research
  direction, not an already implemented feature or an automatic next step.
- Pin the upstream revision and the Rust toolchain; do not silently track main.
- Keep the legacy PVGPU sources in place, outside the new Cargo workspace.
- Apply the Limiar Private-Use License only to its explicit original-file
  allowlist. Preserve previous MIT/Apache grants and upstream terms,
  including GPL Looking Glass. Review any expansion of restricted scope.
- The GitHub repository was renamed to `templarsco/limiar` on September 23,
  2026. Preserve the existing history and issues; PVGPU remains the name of the
  historical prototype.
- Treat GPU passthrough on Windows client as an experiment, not a supported
  feature merely because an API or PowerShell command exists.
- Do not promise universal game or anti-cheat compatibility.

## Core Gate: Configurable Accelerated PC

Status: initial native same-VM firmware/GPU feasibility passed; full
interactive delivery remains pending. The active order above takes
priority. M0-M2 preserve earlier work and outstanding engineering tasks;
their numbering does not put management/UI ahead of this gate.

- [x] Make machine control and application experience the central product
  contract, with management/UI subordinate to a viable runtime.
- [x] Pin native OpenHCL/mu_msvm sources and record their first implemented
  firmware controls and native boot evidence.
- [ ] Build a field-level coverage matrix, including the full reference
  SMBIOS input surface, and identify the owner of every implementation gap.
- [x] Prove Windows UEFI boot with distinct custom BIOS/system/baseboard/chassis
  profiles, persistence and guest-side value verification.
- [x] Verify configured native firmware and hardware GPU-PV offscreen
  rendering in the same OpenHCL Windows guest.
- [ ] Resolve the remaining EAC application gate without relabeling
  offline startup as online acceptance.
- [ ] Add accelerated presented graphics to that same configurable VM.
- [ ] Validate Looking Glass input/audio and repeatable interactive
  sessions. Owner-reported game passes are recorded separately from
  agent-reproduced tests and performance measurements.
- [ ] Record native/guest performance under fixed settings and account for
  host graphics continuity, frame times and recovery.
- [ ] Record a candidate go/no-go decision and select only approved
  evidence for publication; do not release the complete private study.

The earlier identity/boot fixture is preserved in the 0.5
[Windows validation](validation/2026-09-24-windows-custom-identity.md).
The active same-VM result and remaining gates are recorded in
[OpenHCL compatibility](OPENHCL-COMPATIBILITY.md). Offscreen correctness
does not complete the interactive application or Looking Glass gate.

Exit criteria: one candidate demonstrates configurable Windows identity and
accelerated interactive applications together, with its remaining coverage
gaps explicit. Broader field coverage remains a separate target, with
QEMU as comparison only; do not advertise the prototype as 100% coverage.

Application compatibility, performance and stability are part of this gate.
Broader product/UI work cannot substitute for it. Consult the
[core contract](CORE-CONTRACT.md) for candidate paths and evidence rules.

## M0: Reproducible Foundation

Status: complete for the initial development slice. Local checks and the
hosted Limiar workflow passed on Windows and Ubuntu after the initial service
restriction was cleared. CodeQL is tracked separately from the CLI workflow.
This does not mean that the full Hub roadmap is complete.

- [x] Inspect the current repository and preserve unrelated local changes.
- [x] Select and record the upstream OpenVMM commit.
- [x] Install Rust 1.95.0 alongside the existing default toolchain.
- [x] Add the Limiar workspace, CLI, tests, and CI.
- [x] Add strict, versioned VM profiles and a previewable launch plan.
- [x] Collect read-only host and GPU inventory.
- [x] Run a bounded native D3D11 test on the explicitly selected RX 9070 XT.
- [x] Restore required dependencies and build the pinned OpenVMM runtime.
- [x] Boot a Linux guest through WHP and retain serial evidence.
- [x] Publish the first tested implementation and an honest capability matrix.

Exit criteria: a fresh checkout can build the CLI; unit and integration tests
pass; hardware evidence identifies the adapter actually tested; at least one
guest boot is demonstrated or a specific runtime blocker is documented.
Native GPU success must never be presented as guest GPU success.

## M1: Reproducible Guest Lifecycle

Status: in progress. The 0.2 development slice adds managed profile snapshots
and foreground VM supervision; it does not complete every item in this phase.

- [x] Persistent profile registry, case-insensitive names, and immutable input-path snapshots.
- [x] List/show/preview/status and stopped-profile updates with revision tracking.
- [x] Exclusive supervisor leases, stale-state detection, and run-specific stop requests.
- [x] Metadata-only unregister; no VM image deletion.
- [x] Unit and CLI tests for registry safety and process control.
- [x] Real Linux start/stop/restart validation through the managed commands.
- [x] Hosted Windows/Ubuntu CI and CodeQL for this development slice.
- [x] Persistent Limiar/custom identity with explicit backend/boot restrictions.
- [x] Linux guest verification of all eleven Type 0/1 fields and guest power-off.
- [ ] Guest-requested graceful shutdown and persistent disk management.
- [x] Windows 11 installation/boot, Secure Boot, and vTPM validation through native Hyper-V.
- [x] Windows lab start/normal shutdown, persistent VHDX and protected local credentials.

Deliverables:
- Linux direct-boot and UEFI profiles with immutable input image hashes.
- Windows 11 installation/boot with explicit firmware and storage settings.
- Secure Boot and vTPM integration, including persistent TPM/UEFI state.
- Process ownership, timeout handling, logs, exit reasons, and cleanup.
- Persistent disks, read-only base images, copy-on-write overlays, and
  transactional profile edits.

Tests: cold boot, orderly shutdown, repeated boot, invalid images, missing
firmware, process failures, timeouts, and disk recovery after interruption.
Use disposable images; never attach a host physical disk by default.

Exit criteria: documented Windows and Linux boot fixtures, a repeatable
lifecycle test, and no false-success result on timeout or early failure.
Windows media acquisition and redistribution must respect its license.

## M2: Shared GPU-PV First

Status: in progress. The earlier HCS/Linux and stock Windows GPU fixtures
below are retained. The later native OpenHCL same-guest firmware/D3D11
result advances feasibility but is not a completed supported product.

- [x] Query partitionable GPUs; keep raw quota units and unknown states explicit.
- [x] Select the exact RX 9070 XT without default-adapter fallback.
- [x] Create/start a disposable HCS VM and attach the selected GPU-PV device.
- [x] Boot Linux with the installed WSL kernel and observe `/dev/dxg`.
- [x] Build a local guest probe with pinned headers and installed runtime components.
- [x] Verify 64x64 D3D12 clear/copy/readback on the requested hardware adapter.
- [x] Observe guest graceful exit and confirm removal by HCS ID.
- [x] Record ten share/use/cleanup cycles; native host graphics and active display routes unchanged.
- [x] Provision selected Windows media and the matching guest graphics driver.
- [x] Validate Windows desktop boot and D3D11 readback; other graphics APIs remain untested.
- [x] Repeat three Windows cold boots with the GPU, Secure Boot/vTPM and host graphics checks.
- [ ] Integrate identity controls and shared graphics into one supported backend.
- [ ] Add resource controls, multiple guests, upgrade and recovery tests.

Exit criteria: repeated validated guest GPU workloads while the host retains
its display and graphics path, then a working Windows guest with its own
driver/console evidence. A native test, partitionable-GPU query, successful
attachment or `/dev/dxg` node alone does not satisfy graphics validation.

## M2b: Dedicated GPU Feasibility

Status: planned; prerequisite is M0's host inventory.
Pull this investigation forward if needed for the core candidate comparison;
shared use remains the preferred user experience.

1. Identify the exact GPU and all associated PCI functions.
2. Check platform/OS support, IOMMU/ACS capability, firmware settings, BAR/MMIO
   requirements, and device-assignment APIs. Unknown is a distinct result.
3. Verify a working host display/recovery path and obtain confirmation before
   disabling or dismounting any device. Never infer monitor wiring from a GPU
   merely appearing in inventory.
4. Prepare and review exact device-specific assignment and recovery actions.
5. Assign the GPU to a disposable VM and install its vendor driver.
6. Test rendering, compute where supported, display/audio, shutdown, return to
   the host, reset, and repeated assignment cycles.
7. Record compatibility by host OS build, GPU, driver, firmware, and backend.

Exit criteria: at least ten successful assign/use/return cycles, no persistent
loss of the host display, and measured native-versus-guest results. Record
unsupported Windows client configurations honestly. A supported Server or
Linux host is an alternative experiment, not an automatic machine conversion.

## M3: VM Management Service

Status: planned; requires the core gate and a stable M1 lifecycle contract.

Deliverables: versioned local API; VM registry; job state machine; capabilities;
image library; storage/network management; log/event streaming; permissions;
backup/export; and VM-specific resource limits.

Design requirements: least privilege, authenticated local IPC, bounded inputs,
no arbitrary shell arguments in profiles, explicit elevated operations, and
durable state that survives service restarts.

Tests: concurrent starts, stale process IDs, partial writes, duplicate names,
resource exhaustion, unauthorized IPC, and recovery after service termination.
Do not use snapshots with passthrough until device state semantics are proven.

## M4: Desktop Hub

Status: planned; requires the core gate. Build on the service API, not direct
shell commands.

Views: VM library; creation/import; hardware configuration; live console;
jobs/logs; images/storage; networking; GPU capabilities; and diagnostics.
Include empty, error, unavailable-feature, running, stopped, and recovery states.

Exit criteria: a user can create, run, stop, inspect, export, and remove a
disposable VM through the UI. Removing a VM must distinguish its registration
from its disks and require confirmation for destructive storage actions.
Verify keyboard accessibility, scaling, layout, and end-to-end workflows.

## M5: Additional Platforms And Guest Families

Status: planned.

- FreeBSD boot/lifecycle fixtures and console-oriented image templates.
- Linux hosts through an independently validated KVM/VFIO backend.
- Apple-host integration using suitable Apple virtualization APIs.
- Architecture-aware image selection; host support does not imply support for
  every guest OS, guest architecture, or accelerated graphics path.
- A provider/capability contract based on implemented backends, not speculative
  interfaces. Investigate remote hosts only after authentication is designed.

Exit criteria: independent per-platform test matrices and graceful degradation
when a requested feature is unavailable.

## M6: Additional GPU Delivery Modes

Status: research, not a commitment to a particular transport.
Required transport experiments move into the core gate if the initial
GPU-PV path cannot coexist with the configurable machine model.

Extend the GPU-PV-first work with independently validated alternatives.
Compare host-supported partitioning, dedicated assignment and API remoting. Prototype one narrow
workload before choosing a protocol. Evaluate guest driver support, graphics
API coverage, synchronization, memory isolation, copies, latency, and recovery.
Do not assume DXVK/VKD3D or a custom Vulkan ICD makes arbitrary Windows
applications work. The legacy PVGPU code is reference material, not a trusted
guest/host boundary.

Exit criteria: an isolated demonstrator, adversarial input tests, reproducible
measurements, and a written go/no-go decision before product integration.

## M7: Release Engineering And Maintenance

Status: planned; security and reproducibility work also apply to every phase.

Deliverables: signed installers/binaries where applicable; dependency inventory
and notices; update/rollback strategy; support matrix; migration guides;
performance baselines; threat model; fuzzing of parsing boundaries; and
explicit compatibility/deprecation policies.

Exit criteria: clean-machine installation, upgrade and rollback rehearsals,
documented recovery procedures, and evidence for every advertised capability.

## Execution And Evidence

- Local, potentially identifying reports and VM logs live under `.limiar/`
  (ignored by Git).
- Keep the full lab study private. Select only reviewed, sanitized
  summaries for any release; a file under `docs/validation/` is not
  automatically approved for publication.
- A test result records command, versions, outcome, and limitations.
- Update this checklist incrementally. Do not mark later phases complete
  because a plan, scaffold, or native-only test exists.
- Unknown, unsupported, failed, and passed are different states.
