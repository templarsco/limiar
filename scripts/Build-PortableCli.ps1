#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$oldFlags = $env:RUSTFLAGS
$oldTarget = $env:CARGO_TARGET_DIR
Push-Location -LiteralPath $root
try {
    $env:RUSTFLAGS = (($oldFlags + ' -C target-feature=+crt-static').Trim())
    $env:CARGO_TARGET_DIR = Join-Path $root 'target\portable'
    & cargo build --release --locked -p limiar --target x86_64-pc-windows-msvc
    if ($LASTEXITCODE -ne 0) { throw 'Portable CLI build failed' }
    Write-Host (Join-Path $env:CARGO_TARGET_DIR 'x86_64-pc-windows-msvc\release\limiar.exe')
} finally {
    $env:RUSTFLAGS = $oldFlags
    $env:CARGO_TARGET_DIR = $oldTarget
    Pop-Location
}
