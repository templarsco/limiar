# Limiar Development Plan

Status: foundation and managed lifecycle published; the 0.3 slice adds
guest-verified identity and a shared GPU-PV Linux laboratory, September 24,
2026. Later product milestones remain planned.

## Product

Limiar is a capability-aware hub for creating, running, and managing virtual
machines. OpenVMM is the first execution backend, not the product identity.
The initial host is Windows 11 x64; the first shared GPU under test is an
AMD Radeon RX 9070 XT. Windows, Linux, and FreeBSD are target guest families.
macOS integration and custom console-style systems are later workstreams.

The complete roadmap below is not a claim that every phase is implemented.
Each phase must produce evidence before its status changes to complete.

## Decisions

- Start from upstream OpenVMM through a supervised process boundary.
- Prioritize shared GPU-PV so the host retains the GPU; dedicated assignment
  follows later. HCS is the first experimental sharing path.
- Treat PC identity as user configuration, with coherent project defaults
  and persistent UUID/serial values. Do not silently drop unsupported fields.
- OpenVMM identity and HCS GPU-PV are separate paths today; a combined
  Windows desktop VM is still an acceptance requirement, not a delivered feature.
- Pin the upstream revision and the Rust toolchain; do not silently track main.
- Keep the legacy PVGPU sources in place, outside the new Cargo workspace.
- Keep existing licenses and third-party notices. Licensing changes require a
  separate ownership and dependency review.
- The GitHub repository was renamed to `templarsco/limiar` on September 23,
  2026. Preserve the existing history and issues; PVGPU remains the name of the
  historical prototype.
- Treat GPU passthrough on Windows client as an experiment, not a supported
  feature merely because an API or PowerShell command exists.
- Do not promise universal game or anti-cheat compatibility.

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
- [ ] Windows 11 installation/boot, Secure Boot, and vTPM validation.

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

Status: in progress. HCS attachment, Linux boot, dxgkrnl visibility and a
bounded D3D12 pixel readback are implemented and have local evidence.

- [x] Query partitionable GPUs; keep raw quota units and unknown states explicit.
- [x] Select the exact RX 9070 XT without default-adapter fallback.
- [x] Create/start a disposable HCS VM and attach the selected GPU-PV device.
- [x] Boot Linux with the installed WSL kernel and observe `/dev/dxg`.
- [x] Build a local guest probe with pinned headers and installed runtime components.
- [x] Verify 64x64 D3D12 clear/copy/readback on the requested hardware adapter.
- [x] Observe guest graceful exit and confirm removal by HCS ID.
- [x] Record ten share/use/cleanup cycles; native host graphics and active display routes unchanged.
- [ ] Provision Windows media and the matching guest graphics driver.
- [ ] Validate an interactive Windows desktop and guest graphics APIs.
- [ ] Integrate identity controls and shared graphics into one supported backend.
- [ ] Add resource controls, multiple guests, upgrade and recovery tests.

Exit criteria: repeated validated guest GPU workloads while the host retains
its display and graphics path, then a working Windows guest with its own
driver/console evidence. A native test, partitionable-GPU query, successful
attachment or `/dev/dxg` node alone does not satisfy graphics validation.

## M2b: Dedicated GPU Feasibility

Status: planned; prerequisite is M0's host inventory.

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

Status: planned; requires a stable M1 lifecycle contract.

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

Status: planned; build on the service API, not direct shell commands.

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
- Publish only reviewed, sanitized summaries under `docs/validation/`.
- A test result records command, versions, outcome, and limitations.
- Update this checklist incrementally. Do not mark later phases complete
  because a plan, scaffold, or native-only test exists.
- Unknown, unsupported, failed, and passed are different states.
