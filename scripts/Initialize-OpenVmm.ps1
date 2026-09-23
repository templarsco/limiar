[CmdletBinding()]
param(
    [switch]$SkipRestore,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pin = Get-Content -LiteralPath (Join-Path $root 'runtime\openvmm.json') -Raw |
    ConvertFrom-Json
if ($pin.schema_version -ne 1 -or $pin.revision -notmatch '^[a-f0-9]{40}$') {
    throw 'Invalid OpenVMM runtime pin'
}
$source = Join-Path $root 'third_party\openvmm'

function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed with exit code $LASTEXITCODE"
    }
}

if (-not (Test-Path -LiteralPath $source)) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force | Out-Null
    Invoke-Checked git @(
        '-c', 'core.longpaths=true', 'clone', '--filter=blob:none', '--no-checkout',
        $pin.repository, $source
    )
    Invoke-Checked git @('-C', $source, 'checkout', '--detach', $pin.revision)
}
if (-not (Test-Path -LiteralPath (Join-Path $source '.git'))) {
    throw "$source exists but is not an independent Git checkout"
}
$revision = & git -C $source rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision -ne $pin.revision) {
    throw "OpenVMM revision differs from the pin. No checkout/reset was performed: $revision"
}
$origin = & git -C $source remote get-url origin
if ($LASTEXITCODE -ne 0 -or $origin.TrimEnd('/') -ne $pin.repository.TrimEnd('/')) {
    throw "Unexpected OpenVMM origin: $origin"
}
$changes = @(& git -C $source status --porcelain)
if ($LASTEXITCODE -ne 0 -or $changes.Count -gt 0) {
    throw 'OpenVMM has local changes; refusing to overwrite or build an unrecorded revision'
}

Invoke-Checked rustup @(
    'toolchain', 'install', $pin.rust_toolchain, '--profile', 'minimal',
    '--component', 'rustfmt', '--component', 'clippy'
)

$toolchain = "+$($pin.rust_toolchain)"
Push-Location -LiteralPath $source
try {
    if (-not $SkipRestore) {
        Invoke-Checked cargo @($toolchain, 'xflowey', 'restore-packages', '--no-compat-igvm')
    }
    if (-not $SkipBuild) {
        Invoke-Checked cargo @(
            $toolchain, 'build', '--locked', '--release', '-p', 'openvmm',
            '--no-default-features', '--features', ($pin.features -join ',')
        )
    }
} finally {
    Pop-Location
}

Write-Host "Pinned OpenVMM source: $source"
if (-not $SkipBuild) {
    Write-Host "Runtime: $(Join-Path $source 'target\release\openvmm.exe')"
}
