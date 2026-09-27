#requires -Version 7.0
# SPDX-FileCopyrightText: 2026 SANSI GROUP
# SPDX-License-Identifier: LicenseRef-Limiar-Private-Use-1.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$path = Join-Path $root 'docs/GPU-PV-E-DDA.md'
$text = Get-Content -LiteralPath $path -Raw
$script:assertions = 0
function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
}
$blocks = @([regex]::Matches($text, '(?ms)^```powershell[ \t]*\r?\n(?<code>.*?)^```[ \t]*\r?$'))
Assert-True ($blocks.Count -eq 6) 'Expected six self-contained PowerShell example blocks'
$asts = @()
foreach ($block in $blocks) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($block.Groups['code'].Value, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) 'Invalid PowerShell syntax in the tutorial'
    $asts += $ast
}

# Every provider is a test double, including unexpected paths through the examples.
function Get-VM { throw 'Unexpected provider access' }
function Get-CimInstance { [pscustomobject]@{ProductType=$script:mockProductType} }
function Get-VMMemory { throw 'Unexpected provider access' }
function Get-VMGpuPartitionAdapter { throw 'Unexpected provider access' }
function Get-VMAssignableDevice { throw 'Unexpected provider access' }
function Get-VMHostAssignableDevice { throw 'Unexpected provider access' }
function Get-PnpDevice { throw 'Unexpected provider access' }
function Get-PnpDeviceProperty { throw 'Unexpected provider access' }
function Get-SelectedVm { throw 'Unexpected provider access' }
function Get-SelectedGpu { throw 'Unexpected provider access' }
function Set-VM { throw 'Unexpected mutation' }
function Add-VMGpuPartitionAdapter { throw 'Unexpected mutation' }
function Remove-VMGpuPartitionAdapter { throw 'Unexpected mutation' }
function Disable-PnpDevice { throw 'Unexpected mutation' }
function Enable-PnpDevice { throw 'Unexpected mutation' }
function Dismount-VMHostAssignableDevice { throw 'Unexpected mutation' }
function Mount-VMHostAssignableDevice { throw 'Unexpected mutation' }
function Add-VMAssignableDevice { throw 'Unexpected mutation' }
function Remove-VMAssignableDevice { throw 'Unexpected mutation' }

function Assert-Stops([string]$Code,[string]$Expected) {
    $observed = $null
    try { & ([scriptblock]::Create($Code)) | Out-Null }
    catch { $observed = $_.Exception.Message }
    Assert-True ($observed -ceq $Expected) ('Wrong gate result: ' + $observed)
}

$script:mockProductType = 1
Assert-Stops $blocks[1].Groups['code'].Value 'Preencha o GUID da VM, a interface exata e a versao do driver'
Assert-Stops $blocks[2].Groups['code'].Value 'Validar payload e backup antes da anexacao'
Assert-Stops $blocks[4].Groups['code'].Value 'Este fluxo DDA requer host Windows Server suportado'
$script:mockProductType = 3
Assert-Stops $blocks[4].Groups['code'].Value 'Concluir os requisitos DDA primeiro'
Assert-Stops $blocks[5].Groups['code'].Value 'Conferir o recibo da tentativa DDA antes do retorno'

$selectionStatements = @($asts[1].EndBlock.Statements)
$partitionChecks = $selectionStatements[-1].Extent.Text
Assert-True ($partitionChecks.StartsWith('if ($partitions.Count')) 'Selected the wrong partition-check statement'
function Test-ExistingPartition([int]$Count,[bool]$Same,[string]$Expected) {
    $selectedInterface = 'mock-interface'
    $partitions = @(for ($i = 0; $i -lt $Count; $i++) {
        [pscustomobject]@{InstancePath=if ($Same) {'mock-interface'} else {'other-interface'}}
    })
    $observed = $null
    try { $observed = (& ([scriptblock]::Create($partitionChecks)) | Out-String).Trim() }
    catch { $observed = $_.Exception.Message }
    Assert-True ($observed -ceq $Expected) 'Existing-partition behavior changed'
}
Test-ExistingPartition 0 $true ''
Test-ExistingPartition 1 $true 'GPU-PV ja anexada: validar o guest, sem anexar novamente.'
Test-ExistingPartition 1 $false 'Atribuicao existente diferente: revisar sem remover automaticamente'
Test-ExistingPartition 2 $true 'Atribuicao existente diferente: revisar sem remover automaticamente'

$selectionFunctions = @($asts[1].FindAll({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $true))
Assert-True ($selectionFunctions.Count -eq 2) 'Selection helpers changed'
$vmFunction = $selectionFunctions | Where-Object Name -eq 'Get-SelectedVm'
function Test-VmSelection([bool]$Same) {
    [guid]$vmId = [guid]::NewGuid()
    $expectedVmName = 'Mock-Owned-VM'
    function Get-VM { [pscustomobject]@{Id=$vmId;Name=if ($Same) {$expectedVmName} else {'Other-VM'}} }
    . ([scriptblock]::Create($vmFunction.Extent.Text))
    if ($Same) {
        Assert-True ((Get-SelectedVm).Id -eq $vmId) 'Correct VM identity rejected'
    } else {
        Assert-Stops 'Get-SelectedVm' 'O nome da VM nao corresponde ao GUID'
    }
}
Test-VmSelection $true
Test-VmSelection $false

$gpuFunction = $selectionFunctions | Where-Object Name -eq 'Get-SelectedGpu'
function Test-GpuSelection([int]$Count,[string]$Status,[string]$Version,[bool]$ExpectedPass) {
    $selectedInterface = 'mock-interface'
    $expectedDriverVersion = '1.2.3.4'
    $inventoryScript = {
        [ordered]@{
            status=$Status
            adapters=@(for ($i = 0; $i -lt $Count; $i++) {
                [ordered]@{device_interface='mock-interface';driver_version=$Version}
            })
        } | ConvertTo-Json -Depth 4
    }
    . ([scriptblock]::Create($gpuFunction.Extent.Text))
    if ($ExpectedPass) {
        Assert-True ((Get-SelectedGpu).device_interface -ceq $selectedInterface) 'Exact GPU rejected'
    } else {
        Assert-Stops 'Get-SelectedGpu' 'GPU ausente, ambigua ou com driver diferente do preparado'
    }
}
Test-GpuSelection 1 'queried' '1.2.3.4' $true
Test-GpuSelection 0 'queried' '1.2.3.4' $false
Test-GpuSelection 2 'queried' '1.2.3.4' $false
Test-GpuSelection 1 'unknown' '1.2.3.4' $false
Test-GpuSelection 1 'queried' '9.9.9.9' $false

$mutators = @('Set-VM','Add-VMGpuPartitionAdapter','Remove-VMGpuPartitionAdapter',
    'Disable-PnpDevice','Enable-PnpDevice','Dismount-VMHostAssignableDevice',
    'Mount-VMHostAssignableDevice','Add-VMAssignableDevice','Remove-VMAssignableDevice')
for ($index = 0; $index -lt $asts.Count; $index++) {
    $commands = @($asts[$index].FindAll({param($node)
        $node -is [Management.Automation.Language.CommandAst]
    }, $true))
    foreach ($command in $commands) {
        $name = $command.GetCommandName()
        if ($name -in $mutators) {
            Assert-True ($index -in @(2,4,5)) 'Mutation found outside a gated example'
        }
        if ($name -ceq 'Dismount-VMHostAssignableDevice') {
            $force = @($command.CommandElements | Where-Object {
                $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Force'
            })
            Assert-True ($force.Count -eq 0) 'DDA example bypasses device mitigation checks'
        }
    }
}
foreach ($forbidden in @('C:\Users\','C:/Users/','.limiar/reviews/','.limiar\reviews\',
    '.limiar/windows/','.limiar\windows\','credential.xml','owner_token','openhcl-limiar-desktop')) {
    Assert-True (-not $text.Contains($forbidden)) 'Private path or metadata dependency in the public tutorial'
}
Assert-True ($text -cnotmatch '[0-9a-fA-F]{64}') 'Private artifact hash should not be published in this guide'
Assert-True ($text.Contains('HostDriverStore') -and $text.Contains('amdogl.inf_amd64_<id>')) 'AMD companion guidance missing'
Assert-True ($text.Contains('DDA ainda nao foi validado')) 'DDA status is not explicit'
Assert-True ($text.Contains('tests/gpu_tutorial.ps1')) 'Tutorial should link its executable checks'
[ordered]@{passed=$script:assertions;powershell_examples=$blocks.Count;real_vm_operations=0;gpu_tests_run=0} | ConvertTo-Json
