[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Adapter,
    [switch]$RunSmoke
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$reports = Join-Path $root ".limiar\validation\$stamp"
New-Item -ItemType Directory -Path $reports -Force | Out-Null

function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed with exit code $LASTEXITCODE"
    }
}

Push-Location -LiteralPath $root
try {
    Invoke-Checked cargo @('fmt', '--all', '--', '--check')
    Invoke-Checked cargo @('clippy', '--workspace', '--all-targets', '--locked', '--', '-D', 'warnings')
    Invoke-Checked cargo @('test', '--workspace', '--all-targets', '--locked')
    Invoke-Checked cargo @('build', '--release', '--locked', '-p', 'limiar')
    $limiar = Join-Path $root 'target\release\limiar.exe'
    Invoke-Checked $limiar @('--output', (Join-Path $reports 'doctor.json'), 'doctor')
    Invoke-Checked $limiar @(
        '--output', (Join-Path $reports 'gpu-native.json'), 'gpu', 'test',
        '--adapter', $Adapter, '--iterations', '3'
    )
    if ($RunSmoke) {
        Invoke-Checked $limiar @(
            '--output', (Join-Path $reports 'linux-smoke.json'), 'vm', 'smoke',
            'examples\linux-smoke.toml', '--timeout-seconds', '90'
        )
    }
} finally {
    Pop-Location
}
Write-Host "Local evidence: $reports"
Write-Host 'No GPU was disabled, dismounted, or assigned.'
