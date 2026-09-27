<!-- SPDX-FileCopyrightText: 2026 SANSI GROUP -->
<!-- SPDX-License-Identifier: LicenseRef-Limiar-Private-Use-1.0 -->

# Public Release Review

Owner direction, September 27, 2026: Limiar is virtualization development
and compatibility research, not cheat development or use. Technical
sources are evaluated on their content and evidence, including material
found in game-security forums. Before publishing selected project work,
perform a separate source and artifact review with the owner.

The primary purpose is to enjoy games and applications in a controlled
environment separate from the main Windows installation. This includes
online games with kernel-level anti-cheat and other intrusive software.
The objective is to reduce the main host's exposure to those components,
untrusted applications and malware, without using gameplay cheats. The
same isolation-oriented use case may benefit other users, but it does not
authorize publishing the current lab firmware or the complete study.
The later same-day clarification approves a limited neutral firmware base
as the intended public scope, and Looking Glass as the only complete
public deliverable, as described below.

This document defines the review gate. The owner authorized the selected
September 27 source-reference update and the later selected GPU tutorial;
that approval does not extend to the entire working tree, private firmware
or later releases. Local research records are not automatically release-ready, and publication
controls cannot guarantee prevention of misuse.

## Licensing Gate

The owner requires no sale or redistribution of newly designated original
material. [The component license map](../LICENSING.md) and
[Limiar Private-Use License](../LICENSE-LIMIAR) implement that rule for
the explicit file allowlist while permitting own use and private edits.
Review additional source files before expanding that list.

Previously granted MIT/Apache rights remain intact. Looking Glass-derived
work remains under its GPL terms, which allow compliant sale and
redistribution; do not add the Limiar restriction to that fork. A public
GitHub repository also permits platform forking under its terms. Those
rights are preserved for this owner-authorized limited GitHub update;
the custom license does not grant general redistribution beyond its
exceptions and independently granted rights. No absolute copying
prevention is claimed.

The custom terms have not received independent legal review. Engineering
checks are not a legal opinion or clearance of the entire worktree.

## Intended Public Scope

| Material | Publication scope |
|---|---|
| Neutral Limiar firmware base | Selected project-named profile, metadata generator and tests, authorized for this limited source update with GitHub platform rights preserved; no firmware image, producer patches or turnkey build |
| Feasibility evidence | A concise account that custom guest firmware/SMBIOS and native GPU-PV can coexist in one guest; only measured capabilities and their limits |
| GPU tutorial | Reviewed GPU-PV setup/validation and conditional DDA reference with generic examples, official sources and mock tests; no private collectors, instance IDs, raw receipts, vendor binaries or firmware |
| Looking Glass integration | Complete guest capture integration, transport, physical-Windows viewer, input path, build, tests and documentation under compatible upstream GPL terms; no no-sale/no-redistribution condition on the GPL work |
| Lab firmware and broader study | Private: real-machine-model profiles, experimental images, detailed investigations, raw evidence and private environment data |

The neutral starting profile is `profiles/openhcl/limiar-reference.json`.
Its names are editable through the existing validated profile format; they
are defaults, not a hard-coded branding requirement for downstream users.
The [base overview](LIMIAR-FIRMWARE-BASE.md) describes the limited scope.
The current step validates profile generation only. It is not a compiled,
boot-tested image or a completed distributable firmware package.

Looking Glass is intended to be usable without publishing or depending on
the private firmware study. Complete publication is the intended scope,
not a statement that capture, transport or the Windows viewer is already
implemented and verified. This decision does not change the EAC-first
work order or authorize shipping third-party proprietary components.

## Private Lab Firmware

The owner requires the current experimental lab firmware to remain
private. Do not upload or distribute its UEFI/`MSVM.fd`
images, OpenHCL IGVM images, firmware-containing VM images, or boot-ready
bundles through repository history, CI artifacts, releases, attachments
or external download links. Private firmware profiles and packaged lab
inputs remain local. The neutral public base is a separately selected
artifact, not permission to release a lab image after changing its label.
Any neutral binary candidate needs its own reviewed inputs, build
provenance, validation and release approval.

Local development and validation may continue within the existing VM and
host-change approvals. This hold does not authorize deleting work,
rewriting history, changing infrastructure or stopping an unrelated task.
Source, tests and documentation outside the approved limited scope remain
candidates for a later selected review. Releasing the private lab firmware
or broader study requires a separate decision and explicit owner approval.

## Selection Criteria

Select only the implementation, tests and documentation needed for the
neutral base and its concise feasibility evidence. The complete Looking
Glass delivery is reviewed separately. Other VM lifecycle tooling,
firmware/device experiments and diagnostics are not automatically included.
Review behavior and dependencies, not just names or source locations.

Exclude game-memory manipulation, injectors, cheat payloads, offsets,
patches that disable anti-cheat clients and turnkey game-specific evasion
workflows. A generic memory/device API is not by itself a cheat; any
published example must stay within an explicit project-owned test fixture
and must not target a third-party game's process or protection logic.

Keep credentials, session tokens, private keys, owner tokens, private
profiles, raw machine/account identifiers, unsanitized logs and captured
application memory out of public source, artifacts, examples and CI output.
The ignored `.limiar/` directory is private, but ignore rules alone do not
protect already tracked files or historical commits.

Do not redistribute copied Windows/vendor drivers, OS images, generated
guest images or third-party archives without verifying their terms.
Check source licenses, attribution and provenance for each selected
dependency or patch. A public URL is not a redistribution license.

## Required Review

1. Fix the exact candidate commit/tree and artifact manifest. Do not stage
   the whole dirty workspace or publish an entire private research folder.
2. Inspect the selected diff, transitive dependencies, scripts and build
   output for behavior, secrets, private data and unintended payloads.
   Include every dependency needed for the selected base, but do not copy
   unrelated private profiles, reports or experiments to satisfy links.
   Verify the actual generated firmware fields, not just the profile text.
3. Review source licenses, the restricted-material allowlist, prior grants,
   hosting/forking terms and generated-image contents. Prefer reproducible
   builds using user-supplied licensed components where redistribution is
   not established.
4. Verify bounded inputs, VM ownership checks, resource cleanup, recovery
   behavior and tests using synthetic workloads. Existing persistent VMs
   must not enter cleanup paths intended to destroy disposable fixtures.
5. Review documentation, links, screenshots and logs as well as code.
   Keep exact version/configuration scope, failures and limitations; do not
   advertise universal acceptance, invisibility or unmeasured performance.
6. Produce a file-by-file include, redact, exclude or unresolved decision
   with reasons. Re-check the final exported artifact and selected history,
   obtain owner approval, and only then perform the requested publication.

The review must happen against the actual release candidate. This
September 27 authorization is limited to the selected source-reference
update and [GPU tutorial](GPU-PV-E-DDA.md). Future commits or release uploads
still require a scoped review and owner instruction; no private study or
image is included implicitly.
