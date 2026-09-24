[CmdletBinding()]
param(
    [string]$Distribution = 'Ubuntu',
    [string]$OutputPath,
    [switch]$WithGpu
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutputPath) {
    $filename = if ($WithGpu) { 'linux-gpu-probe.initrd' } else { 'linux-probe.initrd' }
    $OutputPath = Join-Path $root ".limiar\images\$filename"
}
$output = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $output) { throw "Refusing to overwrite $output" }
$base = Join-Path $root 'third_party\openvmm\.packages\underhill-deps-private\x64\initrd'
if (-not (Test-Path -LiteralPath $base -PathType Leaf)) {
    throw 'Build the pinned OpenVMM runtime and restore its packages first.'
}

function ConvertTo-WslPath([string]$Path) {
    $converted = & wsl.exe -d $Distribution --exec wslpath -a -u $Path.Replace('\', '/')
    if ($LASTEXITCODE -ne 0) { throw "Cannot convert path for WSL: $Path" }
    return ($converted | Out-String).Trim()
}

$probe = ConvertTo-WslPath (Join-Path $root 'guest\linux\probe-init.sh')
$source = ConvertTo-WslPath $base
$destination = ConvertTo-WslPath $output
if ($WithGpu) {
    $pin = Get-Content -LiteralPath (Join-Path $root 'runtime\directx-headers.json') -Raw | ConvertFrom-Json
    $headers = Join-Path $root 'third_party\directx-headers'
    if (-not (Test-Path -LiteralPath $headers)) {
        & git init $headers
        if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize DirectX-Headers checkout' }
        & git -C $headers remote add origin $pin.repository
        if ($LASTEXITCODE -ne 0) { throw 'Cannot set DirectX-Headers origin' }
        & git -C $headers fetch --depth 1 origin $pin.revision
        if ($LASTEXITCODE -ne 0) { throw 'Cannot fetch pinned DirectX-Headers revision' }
        & git -C $headers checkout --detach FETCH_HEAD
        if ($LASTEXITCODE -ne 0) { throw 'Cannot check out pinned DirectX-Headers revision' }
    }
    $revision = & git -C $headers rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $revision -ne $pin.revision) { throw 'DirectX-Headers revision differs from pin' }
    $changes = & git -C $headers status --porcelain
    if ($LASTEXITCODE -ne 0 -or $changes) { throw 'DirectX-Headers checkout must be clean' }
    $builder = ConvertTo-WslPath (Join-Path $PSScriptRoot 'build-linux-gpu-probe.sh')
    $cpp = ConvertTo-WslPath (Join-Path $root 'guest\linux\gpu-probe.cpp')
    $headersPath = ConvertTo-WslPath $headers
    & wsl.exe -d $Distribution --exec bash $builder $source $probe $cpp $headersPath $destination
} else {
    $builder = ConvertTo-WslPath (Join-Path $PSScriptRoot 'build-linux-probe.sh')
    & wsl.exe -d $Distribution --exec bash $builder $source $probe $destination
}
if ($LASTEXITCODE -ne 0) { throw 'Linux probe build failed' }
Write-Host "Probe initrd: $output"
Write-Host 'The probe boots Linux, reports guest DMI, tests userspace, and powers off.'
