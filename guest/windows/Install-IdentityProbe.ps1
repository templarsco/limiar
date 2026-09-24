#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][guid]$ExpectedUuid,
    [Parameter(Mandatory = $true)][guid]$OwnerToken,
    [switch]$DisableHibernate,
    [switch]$PrepareStorage
)
$ErrorActionPreference = 'Stop'
if ($ExpectedUuid -eq [guid]::Empty -or $OwnerToken -eq [guid]::Empty) { throw 'Guest UUID and owner token must be nonzero' }
if ([guid](Get-CimInstance Win32_ComputerSystemProduct).UUID -ne $ExpectedUuid) {
    throw 'Guest UUID mismatch; this installer must not run on the host or another VM'
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this guest-only installer as administrator'
}
$base = 'C:\Limiar'
$directory = Join-Path $base 'Custom'
foreach ($path in @($base, $directory)) {
    if ((Test-Path -LiteralPath $path) -and
        ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Guest tool directory must not be a link or junction'
    }
}
[void][IO.Directory]::CreateDirectory($directory)
$admins = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
foreach ($path in @($base, $directory)) {
    if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Guest tool directory must not be a link or junction'
    }
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($admins)
    foreach ($sid in @($admins, $system)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $users, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    Set-Acl -LiteralPath $path -AclObject $acl
}
$destination = Join-Path $directory 'Report-Identity.ps1'
if ((Test-Path -LiteralPath $destination) -and
    ((Get-Item -LiteralPath $destination).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Guest probe destination must not be a link'
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Report-Identity.ps1') -Destination $destination -Force
$fileAcl = [Security.AccessControl.FileSecurity]::new()
$fileAcl.SetAccessRuleProtection($true, $false)
$fileAcl.SetOwner($admins)
foreach ($sid in @($admins, $system)) {
    $fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
}
$fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($users, 'ReadAndExecute', 'Allow'))
Set-Acl -LiteralPath $destination -AclObject $fileAcl
if ($DisableHibernate) {
    & "$env:SystemRoot\System32\powercfg.exe" /hibernate off
    if ($LASTEXITCODE -ne 0) { throw 'Could not disable guest hibernation' }
    & "$env:SystemRoot\System32\powercfg.exe" /setacvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3
    if ($LASTEXITCODE -ne 0) { throw 'Could not configure guest power-button shutdown' }
    & "$env:SystemRoot\System32\powercfg.exe" /setactive SCHEME_CURRENT
    if ($LASTEXITCODE -ne 0) { throw 'Could not apply guest power settings' }
}
if ($PrepareStorage) {
    foreach ($service in @('storahci','stornvme','pciide')) {
        $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$service"
        if (Test-Path -LiteralPath $path) {
            Set-ItemProperty -LiteralPath $path -Name Start -Type DWord -Value 0
            $override = Join-Path $path StartOverride
            if (Test-Path -LiteralPath $override) { Set-ItemProperty -LiteralPath $override -Name 0 -Type DWord -Value 0 }
        }
    }
}
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy RemoteSigned -File $destination -OwnerToken $OwnerToken"
$trigger = New-ScheduledTaskTrigger -AtStartup
$taskPrincipal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
Register-ScheduledTask -TaskName LimiarCustomIdentity -Action $action -Trigger $trigger `
    -Principal $taskPrincipal -Settings $settings -Force | Out-Null
$receipt = [ordered]@{
    schema_version=1;owner_token=$OwnerToken.ToString();installed_on_uuid=$ExpectedUuid.ToString()
    script_sha256=(Get-FileHash -LiteralPath $destination).Hash.ToLowerInvariant()
    installed_at=[DateTime]::UtcNow.ToString('o')
    hibernation_disabled=[bool]$DisableHibernate
    storage_prepared=[bool]$PrepareStorage
}
[IO.File]::WriteAllText((Join-Path $directory 'probe-installation.json'), ($receipt | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json
