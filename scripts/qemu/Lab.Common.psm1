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

function New-LimiarPrivateDirectory {
    param([string]$Path)
    if ((Test-Path -LiteralPath $Path) -and
        ((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Private control directory cannot be a link or junction'
    }
    [void][IO.Directory]::CreateDirectory($Path)
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    if (-not ('LimiarPrivateDirectoryAcl' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class LimiarPrivateDirectoryAcl {
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetSecurityDescriptorDacl(IntPtr descriptor, out bool present, out IntPtr dacl, out bool defaulted);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "SetNamedSecurityInfoW")]
    static extern uint SetNamedSecurityInfo(string path, uint type, uint info, IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);
    public static void Apply(string path, byte[] descriptor) {
        var pin = GCHandle.Alloc(descriptor, GCHandleType.Pinned);
        try {
            bool present, defaulted;
            IntPtr dacl;
            if (!GetSecurityDescriptorDacl(pin.AddrOfPinnedObject(), out present, out dacl, out defaulted) || !present || dacl == IntPtr.Zero)
                throw new InvalidOperationException("Missing private directory DACL");
            // Update only the DACL, retaining any host audit/integrity policy.
            uint error = SetNamedSecurityInfo(path, 1, 0x80000004, IntPtr.Zero, IntPtr.Zero, dacl, IntPtr.Zero);
            if (error != 0) throw new Win32Exception((int)error);
        } finally { pin.Free(); }
    }
}
'@
    }
    [LimiarPrivateDirectoryAcl]::Apply([IO.Path]::GetFullPath($Path), $acl.GetSecurityDescriptorBinaryForm())
}

function Assert-LimiarPrivateDirectory {
    param([string]$Path)
    if ((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Private control directory cannot be a link or junction'
    }
    $allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $allowed) {
        throw 'Control directory must have a protected, owner-controlled ACL'
    }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $allowed) {
            throw 'Control directory grants access to an untrusted principal'
        }
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

function Resolve-LimiarLabCli {
    param([hashtable]$Record, [string]$Root)
    if (-not $Record.ContainsKey('cli_path')) { return Join-Path $Root 'target\release\limiar.exe' }
    if (-not $Record.cli_path -or -not [IO.Path]::IsPathFullyQualified($Record.cli_path) -or
        $Record.cli_sha256 -notmatch '^[0-9a-f]{64}$') { throw 'Invalid pinned lab CLI' }
    $file = Get-Item -LiteralPath $Record.cli_path -ErrorAction Stop
    if ($file -isnot [IO.FileInfo] -or $file.Extension -ine '.exe' -or
        ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Lab CLI must be a regular executable' }
    if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Record.cli_sha256) {
        throw 'Lab CLI changed since this lab was prepared'
    }
    return $file.FullName
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
    Assert-LimiarPrivateDirectory $directory
    if ($record.qmp_socket -ne (Join-Path $directory 'control\qmp.sock')) { throw 'Unexpected control socket path' }
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
    $cli = Resolve-LimiarLabCli $record $root
    if ($record.registry_path -ne (Join-Path $root '.limiar\vms')) { throw 'Unexpected VM registry' }
    $registered = Invoke-LimiarCli $cli @('vm','show',$record.name,'--registry',$record.registry_path)
    if ($registered.created_at_unix_ms -ne $record.registry_created_at_unix_ms) {
        throw 'This registration has been replaced; lab ownership must be checked'
    }
    $profile = $registered.profile
    if ($profile.boot.kind -ne 'qemu_uefi' -or $profile.boot.disk -ne $record.disk_path -or
        $profile.boot.variables -ne $record.variables_path -or $profile.boot.qmp_socket -ne $record.qmp_socket -or
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
    $process = Get-Process -Id $Status.last_run.runtime_pid -ErrorAction Stop
    if ($process.Path -ne $Lab.Record.runtime_path) { throw 'Unexpected supervised runtime executable' }
}

Export-ModuleMember -Function Write-LimiarLabJson,New-LimiarPrivateDirectory,Assert-LimiarPrivateDirectory,Invoke-LimiarCli,ConvertTo-LimiarWindowsArgument,Read-LimiarQemuLab,Get-LimiarQemuStatus,Assert-LimiarQmpOwner
