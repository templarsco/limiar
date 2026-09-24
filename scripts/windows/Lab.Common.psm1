#requires -Version 7.0
Set-StrictMode -Version Latest

function Read-LimiarWindowsLab {
    param([Parameter(Mandatory = $true)][string]$Path)
    $file = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $record = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
    if ($record.schema_version -ne 1 -or $record.provider -ne 'hyperv') { throw 'Unsupported Windows lab record' }
    $directory = [IO.Path]::GetDirectoryName($file)
    if ($directory -ne [IO.Path]::GetFullPath($record.directory)) { throw 'Lab record directory mismatch' }
    if ($record.disk_path -ne (Join-Path $directory 'system.vhdx')) { throw 'Unexpected lab disk path' }
    $ownerGuid = [guid]::Empty
    if (-not [guid]::TryParseExact($record.owner_token, 'D', [ref]$ownerGuid) -or $record.computer_name -notmatch '^LMR-W11-[0-9A-F]{6}$') {
        throw 'Invalid lab ownership values'
    }
    $vm = Get-VM -Id ([guid]$record.vm_id) -ErrorAction Stop
    if ($vm.Name -ne $record.name -or $vm.Notes -ne "Limiar.Windows:$($record.owner_token)") {
        throw 'VM ownership does not match the lab record'
    }
    $drives = @(Get-VMHardDiskDrive -VM $vm)
    if ($drives.Count -ne 1 -or $drives[0].Path -ne $record.disk_path -or $null -ne $drives[0].DiskNumber) {
        throw 'Refusing a VM with unexpected or physical disks'
    }
    if (@(Get-VMNetworkAdapter -VM $vm).Count -ne 0) { throw 'The lab must remain disconnected from host networks' }
    $original = ($record | ConvertTo-Json -Depth 10) | ConvertFrom-Json -AsHashtable
    return [pscustomobject]@{ Record = $record; Original = $original; VM = $vm; Path = $file; Directory = $directory }
}

function Write-LimiarWindowsLab {
    param([Parameter(Mandatory = $true)]$Lab)
    $lock = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ($null -eq $lock) {
        try {
            $lock = [IO.File]::Open((Join-Path $Lab.Directory 'lab.lock'), [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Lab metadata is busy' }
            Start-Sleep -Milliseconds 50
        }
    }
    try {
        $latest = Get-Content -LiteralPath $Lab.Path -Raw | ConvertFrom-Json -AsHashtable
        if ($latest.vm_id -ne $Lab.Original.vm_id -or $latest.owner_token -ne $Lab.Original.owner_token) {
            throw 'Lab ownership changed during the operation'
        }
        # Merge unrelated concurrent updates, but refuse competing changes to one field.
        foreach ($key in $Lab.Record.Keys) {
            $before = ConvertTo-Json -InputObject $Lab.Original[$key] -Depth 10 -Compress
            $after = ConvertTo-Json -InputObject $Lab.Record[$key] -Depth 10 -Compress
            if ($before -eq $after) { continue }
            $current = ConvertTo-Json -InputObject $latest[$key] -Depth 10 -Compress
            if ($current -ne $before -and $current -ne $after) { throw "Concurrent update to lab field: $key" }
            $latest[$key] = $Lab.Record[$key]
        }
        $temporary = Join-Path $Lab.Directory ('record-' + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($temporary, ($latest | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Lab.Path, $true)
        $Lab.Record = $latest
        $Lab.Original = ($latest | ConvertTo-Json -Depth 10) | ConvertFrom-Json -AsHashtable
    } finally { $lock.Dispose() }
}

function Get-LimiarVmSettings {
    param([Parameter(Mandatory = $true)][guid]$Id)
    $settings = @(Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemSettingData `
        -Filter "VirtualSystemIdentifier='$Id' AND VirtualSystemType='Microsoft:Hyper-V:System:Realized'")
    if ($settings.Count -ne 1) { throw 'Expected one realized VM settings object' }
    return $settings[0]
}

function Get-LimiarGuestCredential {
    param([Parameter(Mandatory = $true)]$Lab)
    $credential = Import-Clixml -LiteralPath (Join-Path $Lab.Directory 'credential.xml')
    if ($credential -isnot [pscredential] -or $credential.UserName -ne 'limiar') {
        throw 'Unexpected guest credential'
    }
    return $credential
}

Export-ModuleMember -Function Read-LimiarWindowsLab,Write-LimiarWindowsLab,Get-LimiarVmSettings,Get-LimiarGuestCredential
