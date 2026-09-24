#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$LabPath)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Common.psm1') -Force
$lab = Read-LimiarQemuLab $LabPath
$operation = [IO.File]::Open((Join-Path $lab.Directory 'launch.lock'), [IO.FileMode]::OpenOrCreate,
    [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $status = Get-LimiarQemuStatus $lab
    if ($status.supervisor_active) { $status | ConvertTo-Json -Depth 8; return }
    $editable = Get-Content -LiteralPath $lab.Record.profile_path -Raw | ConvertFrom-Json -AsHashtable
    if ($editable.name -ne $lab.Record.name -or $editable.boot.kind -ne 'qemu_uefi' -or
        $editable.boot.disk -ne $lab.Record.disk_path -or $editable.boot.variables -ne $lab.Record.variables_path -or
        $editable.boot.qmp_port -ne $lab.Record.qmp_port -or $editable.boot.read_only_base -ne $false -or
        $editable.runtime.executable -ne $lab.Record.runtime_path -or $editable.boot.firmware -ne $lab.Record.firmware_path) {
        throw 'Lab name, runtime, firmware, storage, persistence and control endpoint must remain unchanged'
    }
    if ((Get-FileHash -LiteralPath $lab.Record.runtime_path).Hash.ToLowerInvariant() -ne $lab.Record.runtime_sha256) {
        throw 'QEMU executable changed since this lab was prepared'
    }
    $updated = Invoke-LimiarCli $lab.Cli @('vm','update',$lab.Record.name,$lab.Record.profile_path,
        '--registry',$lab.Record.registry_path)
    Write-LimiarLabJson $lab.Record.profile_path $updated.profile
    $plan = Invoke-LimiarCli $lab.Cli @('vm','preview',$lab.Record.name,'--registry',$lab.Record.registry_path)
    if (-not $plan.ready) { throw 'QEMU profile is not ready' }
    $run = Join-Path $lab.Directory ('runs\' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($run)
    Write-LimiarLabJson (Join-Path $run 'plan.json') $plan
    $stdout = Join-Path $run 'supervisor.json'
    $stderr = Join-Path $run 'supervisor.stderr.log'
    $arguments = @('vm','start',$lab.Record.name,'--registry',$lab.Record.registry_path,'--logs',
        (Join-Path $run 'runtime'),'--until-shutdown')
    $quoted = @($arguments | ForEach-Object { ConvertTo-LimiarWindowsArgument $_ })
    $process = Start-Process -FilePath $lab.Cli -ArgumentList $quoted -WindowStyle Hidden `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $launch = [ordered]@{
        schema_version=1;owner_token=$lab.Record.owner_token;name=$lab.Record.name
        supervisor_pid=$process.Id;run_directory=$run;report_path=$stdout;started_at=[DateTime]::UtcNow.ToString('o')
    }
    Write-LimiarLabJson (Join-Path $lab.Directory 'launch.json') $launch
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 200
        $status = Get-LimiarQemuStatus $lab
        if ($status.supervisor_active -and $status.state -eq 'running') {
            [ordered]@{status='running';name=$lab.Record.name;run_directory=$run;graphics='basic_display'} | ConvertTo-Json
            return
        }
        if ($process.HasExited) { throw "QEMU startup failed; inspect $run" }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Runtime startup was not confirmed; inspect $run before retrying"
} finally { $operation.Dispose() }
