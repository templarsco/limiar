# Managed VM Validation: Limiar 0.2

Validated on September 24, 2026 UTC (September 23 on the UTC-03 development
host). This is a lifecycle development slice, not completion of the entire M1
roadmap or proof of production readiness.

## Scope

- Windows 11 x64 host and the previously pinned OpenVMM runtime.
- Linux direct boot with two vCPUs and 512 MiB RAM.
- Local VM profile registration, updates, lifecycle state, and forced stop.
- No physical GPU assignment, dismount, driver replacement, or host reboot.
- No Windows guest, persistent guest disk, or graceful shutdown validation.

## Automated Checks

The local Windows and Ubuntu/WSL runs each passed:

- Formatting and Clippy with warnings treated as errors.
- 24 unit tests and 9 CLI integration tests.
- Release build of Limiar 0.2.0.

The Windows regression script also passed the native RX 9070 XT D3D11 test
(12,288 pixels over three iterations) and the original file-based Linux smoke
command. No software adapter fallback or physical device assignment was used.

Two ignored helper tests are intentionally launched in subprocesses by their
parent supervisor tests. The Windows-only pixel test and Unix-only linked
directory test account for platform-specific coverage.

Registry tests cover case-insensitive names, immutable path snapshots, profile
revisions, duplicate starts, active-VM mutation rejection, stale stop requests,
interrupted supervisors, corrupt entries, OS separation, and preservation of
input images and unknown files. A stale record containing the test process's
own PID is treated as interrupted without signalling that PID.

CLI tests also confirm that an existing `--output` file prevents registration
from starting, rather than failing only after the mutation has occurred.

## Real Guest Workflow

The manual and scripted Windows tests completed this sequence:

1. Register the Linux profile and resolve its runtime/kernel/initrd paths.
2. Start a foreground supervisor and observe the guest's initrd shell marker.
3. Confirm live state is `running`, with `boot_verified: true`.
4. Reject a duplicate start and unregister while the supervisor owns its lease.
5. Request `vm stop --force` and confirm `stop_requested`, `stopped`, and an
   inactive supervisor.
6. Update the stopped profile to revision 2.
7. Start again in managed smoke mode, with a new run identifier and the new
   profile revision. The previous stop request did not terminate this run.
8. Unregister the isolated test VM and verify input SHA-256 hashes were unchanged.

The standalone script `scripts/Invoke-ManagedValidation.ps1` passed the entire
sequence. It launches its owned supervisor hidden, imposes bounded waits, and
cleans up that supervisor on failure.

The separately registered demonstration VM `linux-smoke` was left registered
and stopped in the development host's default registry. No `openvmm.exe`
processes remained after the completed tests.

## Boundaries

`vm start` is foreground supervision, not a background service. `vm stop
--force` terminates the runtime and can discard unsaved guest state. Its success
does not imply a clean guest shutdown or boot verification.

Configuration snapshots preserve resolved paths, not the contents of kernel,
firmware, or disk files. Those files are neither copied nor deleted by registry
operations. The registry is trusted local metadata, not a sandbox for arbitrary
host executables.

Raw records, process identifiers, and logs remain under ignored `.limiar/`.

## Hosted Validation

PR #3 validated application commit
`5f70042dbe26d7472f0cf71f1f4fc7dd6b18ec95`:

- [Limiar CI](https://github.com/templarsco/limiar/actions/runs/35938476827)
  passed on Windows and Ubuntu.
- [CodeQL](https://github.com/templarsco/limiar/actions/runs/35938475175)
  completed successfully for Actions, C/C++, and Rust.

Successful analysis execution is not a claim that every security finding has
been reviewed or that the application is production-ready.
