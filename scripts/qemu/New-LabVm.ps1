#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceDisk,
    [Parameter(Mandatory = $true)][ValidateSet('qcow2','vhdx','raw')][string]$SourceFormat,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,39}$')][string]$Name = 'Limiar-Win11-Custom',
    [ValidateRange(2,16)][int]$CpuCount = 4,
    [ValidateRange(4096,32768)][int]$MemoryMiB = 8192,
    [ValidateSet('host','compatible','max')][string]$CpuModel = 'host',
    [ValidateSet('basic','virgl_experimental')][string]$Graphics = 'basic',
    [ValidateSet('none','user_nat')][string]$Network = 'none',
    [switch]$Audio,
    [string]$CliPath,
    [string]$CredentialPath,
    [string]$ArchivePath
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Common.psm1') -Force
if ($Name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { throw 'Reserved VM name' }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$cli = if ($CliPath) { (Resolve-Path -LiteralPath $CliPath).Path } else { Join-Path $root 'target\release\limiar.exe' }
if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) { throw 'Build the release CLI first' }
$cliFile = Get-Item -LiteralPath $cli
if ($cliFile -isnot [IO.FileInfo] -or $cliFile.Extension -ine '.exe' -or
    ($cliFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Lab CLI must be a regular executable' }
$cliHash = (Get-FileHash -LiteralPath $cliFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$version = & $cli --version
if ($LASTEXITCODE -ne 0 -or [version]($version -replace '^limiar ', '') -lt [version]'0.6.0') {
    throw 'New QEMU lab profiles require Limiar 0.6 or later'
}
$source = Get-Item -LiteralPath $SourceDisk -ErrorAction Stop
if ($source -isnot [IO.FileInfo] -or $source.Length -eq 0) { throw 'Source must be an existing virtual disk file' }
$sourcePath = $source.FullName
$credential = $null
if ($CredentialPath) {
    $credential = Import-Clixml -LiteralPath $CredentialPath
    if ($credential -isnot [pscredential]) { throw 'Credential file is not a locally protected PSCredential' }
}
$runtime = (& (Join-Path $root 'scripts\Initialize-Qemu.ps1') -ArchivePath $ArchivePath) -join "`n" |
    ConvertFrom-Json -AsHashtable
$storage = Join-Path $root '.limiar\qemu'
[void][IO.Directory]::CreateDirectory($storage)
foreach ($path in @((Join-Path $root '.limiar'), $storage)) {
    if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'QEMU lab storage cannot be a junction or link'
    }
}
$directory = Join-Path $storage $Name
if (Test-Path -LiteralPath $directory) { throw 'Lab directory exists; refusing to overwrite it' }
$control = Join-Path $directory 'control'
$socketPath = Join-Path $control 'qmp.sock'
if ([Text.Encoding]::UTF8.GetByteCount($socketPath) -gt 107) { throw 'Use a shorter lab name or repository path for the local control socket' }
$registry = Join-Path $root '.limiar\vms'
if (Test-Path -LiteralPath (Join-Path $registry $Name.ToLowerInvariant())) { throw 'VM name is already registered' }
New-LimiarPrivateDirectory $directory
New-LimiarPrivateDirectory $control
$owner = [guid]::NewGuid().ToString()
$disk = Join-Path $directory 'system.qcow2'
$variables = Join-Path $directory 'variables.fd'
$profilePath = Join-Path $directory 'profile.json'
$recordPath = Join-Path $directory 'lab.json'
$record = [ordered]@{
    schema_version=1;provider='qemu_whpx';name=$Name;owner_token=$owner;directory=$directory
    status='importing';source_disk=$sourcePath;source_format=$SourceFormat;disk_path=$disk
    variables_path=$variables;profile_path=$profilePath;registry_path=$registry
    qmp_socket=$socketPath
    runtime_path=$runtime.executable;runtime_sha256=$runtime.executable_sha256
    firmware_path=(Join-Path $runtime.directory 'share\edk2-x86_64-code.fd')
    cli_path=$cli;cli_sha256=$cliHash;gpu_mode=$Graphics;network=$Network;audio=[bool]$Audio
    contains_private_credentials=($null -ne $credential)
}
function Save-Record {
    Write-LimiarLabJson $recordPath $record
}
Save-Record
try {
    # qemu-img's normal image locks remain enabled; never use --force-share.
    & $runtime.image_tool convert -f $SourceFormat -O qcow2 $sourcePath $disk
    if ($LASTEXITCODE -ne 0) { throw 'Disk copy/conversion failed; ensure the source VM is off' }
    & $runtime.image_tool check -f qcow2 $disk | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Converted disk metadata did not pass qemu-img check' }
    Copy-Item -LiteralPath (Join-Path $runtime.directory 'share\edk2-i386-vars.fd') -Destination $variables
    if ($null -ne $credential) { $credential | Export-Clixml -LiteralPath (Join-Path $directory 'credential.xml') }
    $profile = [ordered]@{
        schema_version=1;name=$Name;cpus=$CpuCount;memory_mib=$MemoryMiB
        runtime=@{executable=$runtime.executable}
        boot=[ordered]@{
            kind='qemu_uefi';firmware=$record.firmware_path;variables=$variables;disk=$disk
            cpu_model=$CpuModel;read_only_base=$false;headless=$false;qmp_socket=$socketPath
            graphics=$Graphics;network=$Network;audio=[bool]$Audio
        }
        identity=@{
            preset='limiar'
            bios=@{vendor='Limiar';version='UEFI 0.6';date='09/24/2026';release='0.6'}
        }
    }
    Write-LimiarLabJson $profilePath $profile
    $result = & $cli vm register $profilePath --registry $registry
    if ($LASTEXITCODE -ne 0) { throw ($result -join "`n") }
    $registered = ($result -join "`n") | ConvertFrom-Json -AsHashtable
    $record.registry_created_at_unix_ms = $registered.created_at_unix_ms
    Write-LimiarLabJson $profilePath $registered.profile
    $record.status = 'prepared'
    Save-Record
    [ordered]@{status='prepared';name=$Name;lab_path=$recordPath;profile_path=$profilePath;source_modified=$false} |
        ConvertTo-Json
} catch {
    $record.status = 'import_failed'
    $record.error = $_.Exception.Message
    Save-Record
    throw
}
