[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$limiar = Join-Path $root 'target\release\limiar.exe'
$profile = Join-Path $root 'examples\linux-smoke.toml'
$stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$reports = Join-Path $root ".limiar\validation\managed-$stamp"
$registry = Join-Path $reports 'registry'
$logs = Join-Path $reports 'runs'
New-Item -ItemType Directory -Path $reports -Force | Out-Null

function Invoke-Json {
    param([string[]]$Arguments)
    $output = & $limiar @Arguments
    if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
    return (($output -join "`n") | ConvertFrom-Json)
}

$registered = Invoke-Json @('vm', 'register', $profile, '--registry', $registry)
$plan = Invoke-Json @('vm', 'preview', $registered.name, '--registry', $registry)
if (-not $plan.ready) { throw 'The OpenVMM runtime or test kernel/initrd is missing' }
$before = @{}
foreach ($inputFile in $plan.inputs) {
    $before[$inputFile.path] = (Get-FileHash -Algorithm SHA256 -LiteralPath $inputFile.path).Hash
}

$supervisor = $null
try {
    # Start-Process takes a Windows command-line string; paths cannot contain quotes.
    $arguments = @(
        'vm', 'start', $registered.name,
        '--registry', ('"' + $registry + '"'),
        '--logs', ('"' + $logs + '"'),
        '--timeout-seconds', '90'
    )
    $supervisor = Start-Process -FilePath $limiar -ArgumentList $arguments `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $reports 'start.json') `
        -RedirectStandardError (Join-Path $reports 'start.stderr.log')

    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $status = Invoke-Json @('vm', 'status', $registered.name, '--registry', $registry)
        if ($status.supervisor_active -and $status.last_run.boot_verified) { break }
        if ($supervisor.HasExited) { throw 'Supervisor exited before the guest was verified' }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Guest did not become ready in 30 seconds' }
        Start-Sleep -Milliseconds 100
    } while ($true)
    $firstRun = $status.last_run.run_id

    $duplicate = & $limiar vm start $registered.name --registry $registry --timeout-seconds 1
    if ($LASTEXITCODE -eq 0 -or ($duplicate -join "`n") -notmatch 'active supervisor') {
        throw 'Duplicate start was not correctly rejected'
    }
    $unregister = & $limiar vm unregister $registered.name --registry $registry
    if ($LASTEXITCODE -eq 0 -or ($unregister -join "`n") -notmatch 'VM is running') {
        throw 'Unregistering a running VM was not correctly rejected'
    }
    $status = Invoke-Json @('vm', 'status', $registered.name, '--registry', $registry)
    if ($status.last_run.run_id -ne $firstRun) { throw 'Rejected operation changed the active run' }

    $stopped = Invoke-Json @('vm', 'stop', $registered.name, '--registry', $registry, '--force')
    if ($stopped.supervisor_active -or $stopped.state -ne 'stopped') {
        throw 'VM did not stop'
    }
    if (-not $supervisor.WaitForExit(10000) -or $supervisor.ExitCode -ne 0) {
        throw 'Foreground supervisor did not exit successfully'
    }

    $updated = Invoke-Json @('vm', 'update', $registered.name, $profile, '--registry', $registry)
    if ($updated.revision -ne 2) { throw 'Profile revision did not advance' }
    $restart = Invoke-Json @(
        'vm', 'start', $registered.name, '--registry', $registry,
        '--logs', $logs, '--smoke', '--timeout-seconds', '30'
    )
    if (-not $restart.success -or -not $restart.marker_seen -or $restart.stop_reason -ne 'verified_then_stopped') {
        throw 'Managed restart did not reach the guest marker'
    }
    $final = Invoke-Json @('vm', 'status', $registered.name, '--registry', $registry)
    if ($final.supervisor_active -or $final.last_run.run_id -eq $firstRun -or $final.last_run.profile_revision -ne 2) {
        throw 'Restart state was not persisted correctly'
    }
    $removed = Invoke-Json @('vm', 'unregister', $registered.name, '--registry', $registry)
    if (-not $removed.unregistered -or $removed.input_images_deleted) { throw 'Unregister result is incorrect' }

    foreach ($inputFile in $plan.inputs) {
        $after = (Get-FileHash -Algorithm SHA256 -LiteralPath $inputFile.path).Hash
        if ($before[$inputFile.path] -ne $after) { throw 'An input image or runtime changed' }
    }
    [ordered]@{
        schema_version = 1
        status = 'passed'
        registered = $true
        guest_marker_seen = $true
        duplicate_start_rejected = $true
        running_unregister_rejected = $true
        forced_stop_confirmed = $true
        profile_revision = $updated.revision
        restart_verified = $true
        unregister_preserved_inputs = $true
        graceful_guest_shutdown = $false
        gpu_assignment = $false
        evidence_directory = $reports
    } | ConvertTo-Json | Tee-Object -FilePath (Join-Path $reports 'summary.json')
} finally {
    if ($null -ne $supervisor -and -not $supervisor.HasExited) {
        & $limiar vm stop $registered.name --registry $registry --force 2>&1 | Out-Null
        if (-not $supervisor.WaitForExit(10000)) {
            $supervisor.Kill()
            $supervisor.WaitForExit()
        }
    }
}
