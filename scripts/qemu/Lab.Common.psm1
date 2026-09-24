#requires -Version 7.0
Set-StrictMode -Version Latest

function Write-LimiarLabJson {
    param([string]$Path, $Value)
    $path = [IO.Path]::GetFullPath($Path)
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($path)) ('.limiar-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 16))
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        [IO.File]::Move($temporary, $path, $true)
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Invoke-LimiarCli {
    param([string]$Executable, [string[]]$Arguments)
    $output = & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Limiar command failed: $($output -join [Environment]::NewLine)" }
    return ($output -join "`n") | ConvertFrom-Json -AsHashtable
}

function ConvertTo-LimiarWindowsArgument {
    param([string]$Value)
    if ($Value.Contains("`0") -or $Value.Contains("`r") -or $Value.Contains("`n")) {
        throw 'Process arguments must not contain control characters'
    }
    # Start-Process joins its arguments; apply Win32 argv quoting explicitly.
    $result = [Text.StringBuilder]::new()
    [void]$result.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) { $slashes++; continue }
        if ($character -eq [char]34) {
            [void]$result.Append([char]92, (2 * $slashes + 1))
        } else {
            [void]$result.Append([char]92, $slashes)
        }
        [void]$result.Append($character)
        $slashes = 0
    }
    [void]$result.Append([char]92, (2 * $slashes))
    [void]$result.Append('"')
    return $result.ToString()
}

function Read-LimiarQemuLab {
    param([Parameter(Mandatory = $true)][string]$Path)
    $file = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if ((Get-Item -LiteralPath $file).Length -gt 131072) { throw 'QEMU lab metadata exceeds 128 KiB' }
    $record = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
    if ($record.schema_version -ne 1 -or $record.provider -ne 'qemu_whpx') { throw 'Unknown QEMU lab format' }
    $directory = [IO.Path]::GetDirectoryName($file)
    if ($record.directory -ne $directory -or $record.name -ne [IO.Path]::GetFileName($directory)) {
        throw 'QEMU lab directory or name mismatch'
    }
    $owner = [guid]::Empty
    if (-not [guid]::TryParseExact($record.owner_token, 'D', [ref]$owner)) { throw 'Invalid lab owner token' }
    foreach ($entry in @(@('disk_path','system.qcow2'), @('variables_path','variables.fd'),
        @('profile_path','profile.json'))) {
        if ($record[$entry[0]] -ne (Join-Path $directory $entry[1])) { throw 'QEMU lab input path mismatch' }
        if ((Get-Item -LiteralPath $record[$entry[0]]).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'QEMU lab inputs cannot be links or junctions'
        }
    }
    if ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'QEMU lab directory cannot be a link or junction'
    }
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $cli = Join-Path $root 'target\release\limiar.exe'
    if ($record.registry_path -ne (Join-Path $root '.limiar\vms')) { throw 'Unexpected VM registry' }
    $registered = Invoke-LimiarCli $cli @('vm','show',$record.name,'--registry',$record.registry_path)
    if ($registered.created_at_unix_ms -ne $record.registry_created_at_unix_ms) {
        throw 'This registration has been replaced; lab ownership must be checked'
    }
    $profile = $registered.profile
    if ($profile.boot.kind -ne 'qemu_uefi' -or $profile.boot.disk -ne $record.disk_path -or
        $profile.boot.variables -ne $record.variables_path -or $profile.boot.qmp_port -ne $record.qmp_port -or
        $profile.runtime.executable -ne $record.runtime_path -or $profile.boot.firmware -ne $record.firmware_path) {
        throw 'Registered QEMU machine no longer matches this lab'
    }
    return [pscustomobject]@{
        Record=$record; Registered=$registered; Directory=$directory; Path=$file; Cli=$cli
    }
}

function Get-LimiarQemuStatus {
    param($Lab)
    return Invoke-LimiarCli $Lab.Cli @('vm','status',$Lab.Record.name,'--registry',$Lab.Record.registry_path)
}

function Assert-LimiarQmpOwner {
    param($Lab, $Status)
    if (-not $Status.supervisor_active -or $Status.state -ne 'running' -or
        $null -eq $Status.last_run.runtime_pid) { throw 'A supervised QEMU runtime is not running' }
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Lab.Record.qmp_port -ErrorAction Stop |
        Where-Object { $_.LocalAddress -eq '127.0.0.1' })
    if ($listeners.Count -ne 1 -or $listeners[0].OwningProcess -ne $Status.last_run.runtime_pid) {
        throw 'QMP listener is not owned by this VM runtime'
    }
}

Export-ModuleMember -Function Write-LimiarLabJson,Invoke-LimiarCli,ConvertTo-LimiarWindowsArgument,Read-LimiarQemuLab,Get-LimiarQemuStatus,Assert-LimiarQmpOwner
