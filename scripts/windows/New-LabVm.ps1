#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,39}$')]
    [string]$Name = 'Limiar-Win11-25H2',
    [ValidateRange(2, 16)][int]$CpuCount = 4,
    [ValidateRange(4096, 32768)][int]$MemoryMiB = 8192,
    [ValidateRange(64, 256)][int]$DiskGiB = 80
)

$ErrorActionPreference = 'Stop'
if ($Name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { throw 'VM name is reserved by Windows' }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$storage = Join-Path $root '.limiar\windows'
[void][IO.Directory]::CreateDirectory($storage)
if ((Get-Item -LiteralPath $storage).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw 'Windows VM storage cannot be a junction or symbolic link'
}
$directory = [IO.Path]::GetFullPath((Join-Path $storage $Name))
if ([IO.Path]::GetDirectoryName($directory) -ne [IO.Path]::GetFullPath($storage)) {
    throw 'VM directory escaped Windows VM storage'
}
if (Test-Path -LiteralPath $directory) { throw 'VM directory already exists; refusing to overwrite it' }
if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw 'A VM with this name already exists' }
New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @($identity.User, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
    [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $directory -AclObject $acl

$token = [guid]::NewGuid().ToString()
$disk = Join-Path $directory 'system.vhdx'
$recordPath = Join-Path $directory 'lab.json'
$record = [ordered]@{
    schema_version = 1
    provider = 'hyperv'
    name = $Name
    owner_token = $token
    vm_id = $null
    computer_name = 'LMR-W11-' + $token.Substring(0, 6).ToUpperInvariant()
    directory = $directory
    disk_path = $disk
    cpu_count = $CpuCount
    memory_mib = $MemoryMiB
    disk_gib = $DiskGiB
    status = 'creating'
    secure_boot = $false
    tpm_enabled = $false
    network = 'none'
}
function Write-Record {
    $temporary = Join-Path $directory ('record-' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temporary, ($record | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $recordPath -Force
}
Write-Record
try {
    $vm = New-VM -Name $Name -Generation 2 -MemoryStartupBytes ([long]$MemoryMiB * 1MB) `
        -NewVHDPath $disk -NewVHDSizeBytes ([ulong]$DiskGiB * 1GB) -Path (Join-Path $directory 'vm')
    $record.vm_id = $vm.Id.ToString()
    Write-Record
    Set-VM -VM $vm -Notes "Limiar.Windows:$token" -AutomaticStartAction Nothing `
        -AutomaticStopAction ShutDown -AutomaticCheckpointsEnabled $false -CheckpointType Disabled `
        -StaticMemory
    Set-VMProcessor -VM $vm -Count $CpuCount
    Get-VMNetworkAdapter -VM $vm | Remove-VMNetworkAdapter
    Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
    Set-VMKeyProtector -VM $vm -NewLocalKeyProtector
    Enable-VMTPM -VM $vm

    $drives = @(Get-VMHardDiskDrive -VM $vm)
    if ($drives.Count -ne 1 -or $drives[0].Path -ne $disk -or $null -ne $drives[0].DiskNumber) {
        throw 'VM disk layout does not match the exclusively created virtual disk'
    }
    if (@(Get-VMNetworkAdapter -VM $vm).Count -ne 0) { throw 'The lab VM must have no network adapter' }
    $record.secure_boot = (Get-VMFirmware -VM $vm).SecureBoot.ToString() -eq 'On'
    $record.tpm_enabled = (Get-VMSecurity -VM $vm).TpmEnabled
    if (-not ($record.secure_boot -and $record.tpm_enabled)) { throw 'Secure Boot/vTPM confirmation failed' }
    $record.status = 'prepared'
    Write-Record
    $record | ConvertTo-Json -Depth 8
} catch {
    $record.status = 'preparation_failed'
    $record.error = $_.Exception.Message
    Write-Record
    throw
}
