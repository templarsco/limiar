#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$QemuExecutable)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This integration test requires Windows AF_UNIX support' }
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\qemu\Lab.Common.psm1') -Force
Import-Module (Join-Path $root 'scripts\qemu\Qmp.psm1') -Force
$directory = Join-Path $root ('.limiar\qmp-test-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-LimiarPrivateDirectory $directory
Assert-LimiarPrivateDirectory $directory
$socketPath = Join-Path $directory 'qmp.sock'
if ([Text.Encoding]::UTF8.GetByteCount($socketPath) -gt 107) { throw 'Integration test socket path is too long' }
$start = [Diagnostics.ProcessStartInfo]::new((Resolve-Path -LiteralPath $QemuExecutable).Path)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
foreach ($argument in @('-name','limiar-transport-probe','-machine','q35','-accel','whpx','-cpu','host',
    '-m','128','-nodefaults','-display','none','-nic','none','-S',
    '-qmp',"unix:$socketPath,server=on,wait=off")) { $start.ArgumentList.Add($argument) }
$process = [Diagnostics.Process]::new()
$process.StartInfo = $start
[void]$process.Start()
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
try {
    Start-Sleep -Seconds 1
    if ($process.HasExited) { throw $stderr.GetAwaiter().GetResult() }
    $connection = @{SocketPath=$socketPath;ProcessId=$process.Id;Name='limiar-transport-probe'}
    [void](Invoke-LimiarQmp @connection -Command query-status)
    $wrongPidRejected = $false
    try {
        [void](Invoke-LimiarQmp -SocketPath $socketPath -ProcessId ($process.Id + 1) `
            -Name 'limiar-transport-probe' -Command query-status)
    } catch { $wrongPidRejected = $_.Exception.Message -like '*peer is not the supervised runtime*' }
    if (-not $wrongPidRejected) { throw 'Client accepted the wrong peer process' }
    $acl = Get-Acl -LiteralPath $socketPath
    $sddl = $acl.Sddl
    $denied = $false
    try {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new('S-1-1-0'),
            [Security.AccessControl.FileSystemRights]3, [Security.AccessControl.AccessControlType]::Deny))
        Set-Acl -LiteralPath $socketPath -AclObject $acl
        try { [void](Invoke-LimiarQmp @connection -Command query-status) }
        catch { $denied = $_.Exception.GetBaseException().SocketErrorCode -eq [Net.Sockets.SocketError]::AccessDenied }
    } finally {
        $restored = [Security.AccessControl.FileSecurity]::new()
        $restored.SetSecurityDescriptorSddlForm($sddl)
        Set-Acl -LiteralPath $socketPath -AclObject $restored
    }
    if (-not $denied) { throw 'Windows did not enforce the endpoint DACL' }
    [void](Invoke-LimiarQmp @connection -Command query-status)
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.OwningProcess -eq $process.Id })
    if ($listeners.Count) { throw 'Transport probe unexpectedly opened a TCP listener' }
    [ordered]@{
        passed=$true;unix_qmp=$true;wrong_peer_rejected=$true;acl_denied_connect=$true
        restored_connect=$true;tcp_listeners=0;guest_disk_attached=$false
    } | ConvertTo-Json
} finally {
    if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
    [IO.File]::WriteAllText((Join-Path $directory 'stderr.log'), $stderr.GetAwaiter().GetResult())
    $process.Dispose()
}
