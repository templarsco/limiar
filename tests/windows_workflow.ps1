#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$temporary = Join-Path $temporaryParent ('limiar-workflow-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
$script:passed = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:passed++
}
function Assert-Fails([scriptblock]$Action, [string]$Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert-True $failed $Message
}

# Tests use isolated fake providers. No real Hyper-V or GPU operation is invoked.
function global:Get-VM {
    [CmdletBinding()]param([guid]$Id)
    return $script:fakeVm
}
function global:Get-VMHardDiskDrive {
    [CmdletBinding()]param($VM)
    return $script:fakeDisks
}
function global:Get-VMNetworkAdapter {
    [CmdletBinding()]param($VM)
    return $script:fakeNetwork
}

try {
    Import-Module (Join-Path $root 'scripts/windows/Lab.Common.psm1') -Force
    $id = '11111111-1111-4111-8111-111111111111'
    $token = '22222222-2222-4222-8222-222222222222'
    $record = @{
        schema_version=1;provider='hyperv';name='Limiar-Fixture';vm_id=$id;owner_token=$token
        computer_name='LMR-W11-222222';directory=$temporary
        disk_path=(Join-Path $temporary 'system.vhdx');status='installed'
    }
    $path = Join-Path $temporary 'lab.json'
    $record | ConvertTo-Json | Set-Content -LiteralPath $path
    $script:fakeVm = [pscustomobject]@{Id=[guid]$id;Name=$record.name;Notes="Limiar.Windows:$token"}
    $script:fakeDisks = @([pscustomobject]@{Path=$record.disk_path;DiskNumber=$null})
    $script:fakeNetwork = @()
    $lab = Read-LimiarWindowsLab $path
    Assert-True ($lab.Record.vm_id -eq $id) 'Valid lab was rejected'

    $script:fakeVm.Notes = 'not owned'
    Assert-Fails { Read-LimiarWindowsLab $path } 'Unowned VM was accepted'
    $script:fakeVm.Notes = "Limiar.Windows:$token"
    $script:fakeVm.Name = 'Unrelated VM'
    Assert-Fails { Read-LimiarWindowsLab $path } 'Wrong VM name was accepted'
    $script:fakeVm.Name = $record.name
    $script:fakeDisks[0].DiskNumber = 0
    Assert-Fails { Read-LimiarWindowsLab $path } 'Physical disk was accepted'
    $script:fakeDisks[0].DiskNumber = $null
    $script:fakeDisks += [pscustomobject]@{Path='other.vhdx';DiskNumber=$null}
    Assert-Fails { Read-LimiarWindowsLab $path } 'Extra disk was accepted'
    $script:fakeDisks = @($script:fakeDisks[0])
    $script:fakeNetwork = @([pscustomobject]@{Name='network'})
    Assert-Fails { Read-LimiarWindowsLab $path } 'Network attachment was accepted'
    $script:fakeNetwork = @()

    $a = Read-LimiarWindowsLab $path
    $b = Read-LimiarWindowsLab $path
    $a.Record.cli_version = 'limiar fixture'
    Write-LimiarWindowsLab $a
    $b.Record.gpu_payload_iso = 'fixture.iso'
    Write-LimiarWindowsLab $b
    $merged = Read-LimiarWindowsLab $path
    Assert-True ($merged.Record.cli_version -eq 'limiar fixture' -and $merged.Record.gpu_payload_iso -eq 'fixture.iso') 'Concurrent independent updates were lost'
    $a = Read-LimiarWindowsLab $path
    $b = Read-LimiarWindowsLab $path
    $a.Record.status = 'driver_staged'
    $b.Record.status = 'different'
    Write-LimiarWindowsLab $a
    Assert-Fails { Write-LimiarWindowsLab $b } 'Conflicting state changes were silently overwritten'

    $bad = $record.Clone()
    $bad.disk_path = Join-Path $temporaryParent 'outside.vhdx'
    $bad | ConvertTo-Json | Set-Content -LiteralPath $path
    Assert-Fails { Read-LimiarWindowsLab $path } 'Escaping disk path was accepted'
    $bad = $record.Clone()
    $bad.schema_version = 99
    $bad | ConvertTo-Json | Set-Content -LiteralPath $path
    Assert-Fails { Read-LimiarWindowsLab $path } 'Unsupported schema was accepted'

    $xml = [xml](Get-Content -LiteralPath (Join-Path $root 'guest/windows/Autounattend.xml') -Raw)
    $ns = [Xml.XmlNamespaceManager]::new($xml.NameTable)
    $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
    Assert-True ($xml.SelectNodes('//u:DiskConfiguration/u:Disk', $ns).Count -eq 1) 'Installer config targets more than one disk'
    Assert-True ($xml.SelectSingleNode('//u:DiskConfiguration/u:Disk/u:DiskID', $ns).InnerText -eq '0') 'Installer targets the wrong disk'
    Assert-True ($xml.SelectNodes('//u:Password/u:Value', $ns).Count -eq 2) 'Unattend credential fields changed'
    foreach ($node in $xml.SelectNodes('//u:Password/u:Value', $ns)) {
        Assert-True ($node.InnerText -eq 'GENERATED-AT-PROVISIONING') 'A fixed credential was committed'
    }
    Get-ChildItem -LiteralPath (Join-Path $root 'scripts/windows') -File | Where-Object { $_.Extension -in @('.ps1','.psm1') } | ForEach-Object {
        $errors=$null
        $tokens=$null
        [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors)
        Assert-True ($errors.Count -eq 0) "Invalid PowerShell syntax: $($_.Name)"
    }
    [ordered]@{passed=$script:passed;real_vm_operations=0} | ConvertTo-Json
} finally {
    $resolved = [IO.Path]::GetFullPath($temporary)
    if ([IO.Path]::GetDirectoryName($resolved) -ne $temporaryParent -or [IO.Path]::GetFileName($resolved) -notmatch '^limiar-workflow-test-[0-9a-f]{32}$') {
        throw 'Refusing cleanup outside the isolated test directory'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
