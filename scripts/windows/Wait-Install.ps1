#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LabPath,
    [ValidateRange(60, 3600)][int]$TimeoutSeconds = 1800
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lab.Common.psm1') -Force
$lab = Read-LimiarWindowsLab $LabPath
if ($lab.Record.status -notin @('installing', 'installed')) { throw 'VM is not in an installation stage' }
$credential = Get-LimiarGuestCredential $lab
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$lastReason = 'Waiting for a configured guest account'
while ([DateTime]::UtcNow -lt $deadline) {
    $vm = Get-VM -Id ([guid]$lab.Record.vm_id)
    if ($vm.State.ToString() -ne 'Running') {
        $lastReason = "VM state: $($vm.State)"
        Start-Sleep -Seconds 10
        continue
    }
    $job = $null
    try {
        $job = Invoke-Command -VMId ([guid]$lab.Record.vm_id) -Credential $credential -AsJob -ScriptBlock {
            param($ExpectedName, $ExpectedUuid, $OwnerToken)
            $ErrorActionPreference = 'Stop'
            $product = Get-CimInstance Win32_ComputerSystemProduct
            if ($env:COMPUTERNAME -ne $ExpectedName -or $product.UUID -ne $ExpectedUuid) {
                throw 'Guest identity does not match the designated VM'
            }
            $bootstrap = Get-Content -LiteralPath 'C:\Limiar\bootstrap.json' -Raw | ConvertFrom-Json
            if (-not $bootstrap.bootstrap_complete -or $bootstrap.owner_token -ne $OwnerToken) {
                throw 'Guest bootstrap has not completed'
            }
            $os = Get-CimInstance Win32_OperatingSystem
            $tpm = Get-CimInstance -Namespace root\CIMV2\Security\MicrosoftTpm -ClassName Win32_Tpm
            $secureBoot = Confirm-SecureBootUEFI
            $version = & C:\Limiar\limiar.exe --version
            if ($LASTEXITCODE -ne 0 -or [string]$version -notmatch '^limiar \d+\.\d+\.\d+') {
                throw 'The guest CLI is not runnable; use the portable Windows build'
            }
            [ordered]@{
                schema_version = 1
                scope = 'windows_guest'
                computer_name = $env:COMPUTERNAME
                os_caption = $os.Caption
                os_version = $os.Version
                os_build = $os.BuildNumber
                system_vendor = $product.Vendor
                system_product = $product.Name
                system_uuid = $product.UUID
                secure_boot = [bool]$secureBoot
                tpm_present = $null -ne $tpm
                tpm_enabled = [bool]$tpm.IsEnabled_InitialValue
                tpm_version = $tpm.SpecVersion
                limiar_version = [string]$version
                bootstrap_complete = $true
                powershell_direct = $true
            } | ConvertTo-Json -Depth 5
        } -ArgumentList $lab.Record.computer_name, $lab.Record.bios_guid, $lab.Record.owner_token
        $finished = Wait-Job -Job $job -Timeout 15
        if ($finished -and $job.State -eq 'Completed') {
            $result = Receive-Job -Job $job -ErrorAction Stop | Out-String | ConvertFrom-Json
            if (-not ($result.secure_boot -and $result.tpm_present -and $result.tpm_enabled)) {
                throw 'Guest security configuration did not match the VM configuration'
            }
            $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $lab.Directory 'windows-boot.json') -Encoding UTF8
            $lab.Record.status = 'installed'
            $lab.Record.install_verified_at = [DateTime]::UtcNow.ToString('o')
            Write-LimiarWindowsLab $lab
            $result | ConvertTo-Json -Depth 6
            return
        }
        if ($job.State -eq 'Failed') {
            $lastReason = 'Guest session is not available yet'
        }
    } catch {
        $lastReason = $_.Exception.Message
    } finally {
        if ($job) {
            if ($job.State -in @('Running', 'NotStarted')) { Stop-Job -Job $job }
            Remove-Job -Job $job -Force
        }
    }
    Write-Host "Waiting for Windows setup: $lastReason"
    Start-Sleep -Seconds 15
}
throw "Windows installation was not verified within $TimeoutSeconds seconds. Last status: $lastReason"
