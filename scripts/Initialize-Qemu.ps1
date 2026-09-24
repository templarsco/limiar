#requires -Version 7.0
[CmdletBinding()]
param([string]$ArchivePath)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pin = Get-Content -LiteralPath (Join-Path $root 'runtime\qemu.json') -Raw | ConvertFrom-Json
if ($pin.schema_version -ne 1 -or $pin.archive -notmatch '^qemu-w64-setup-[0-9]{8}\.exe$' -or
    $pin.sha512 -notmatch '^[0-9a-f]{128}$' -or $pin.url -ne "https://qemu.weilnetz.de/w64/$($pin.archive)") {
    throw 'Invalid QEMU runtime pin'
}
$tools = Join-Path $root '.limiar\tools'
[void][IO.Directory]::CreateDirectory($tools)
foreach ($path in @((Join-Path $root '.limiar'), $tools)) {
    if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Runtime storage cannot be a junction or symbolic link'
    }
}
$name = [IO.Path]::GetFileNameWithoutExtension($pin.archive)
$directory = Join-Path $tools $name
$receiptPath = Join-Path $directory 'limiar-runtime.json'
if (Test-Path -LiteralPath $directory) {
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        throw 'An incomplete runtime directory already exists; refusing to overwrite it'
    }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    $executable = Join-Path $directory 'qemu-system-x86_64.exe'
    if ($receipt.archive_sha512 -ne $pin.sha512 -or
        (Get-FileHash -LiteralPath $executable).Hash.ToLowerInvariant() -ne $receipt.executable_sha256) {
        throw 'Existing QEMU runtime does not match its receipt'
    }
    $receipt | ConvertTo-Json -Depth 5
    return
}
$archive = if ($ArchivePath) {
    (Resolve-Path -LiteralPath $ArchivePath -ErrorAction Stop).Path
} else {
    Join-Path $tools $pin.archive
}
if (-not (Test-Path -LiteralPath $archive)) {
    & (Join-Path $env:SystemRoot 'System32\curl.exe') --fail --location --retry 2 --proto '=https' `
        --output $archive $pin.url
    if ($LASTEXITCODE -ne 0) { throw 'QEMU download failed' }
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA512).Hash.ToLowerInvariant() -ne $pin.sha512) {
    throw 'QEMU archive SHA-512 does not match the pinned publisher hash'
}
$sevenZip = Get-Command 7z.exe -ErrorAction Stop
[void][IO.Directory]::CreateDirectory($directory)
& $sevenZip.Source x $archive "-o$directory" -y -bsp0 -bso0
if ($LASTEXITCODE -ne 0) { throw 'QEMU archive extraction failed' }
$executable = Join-Path $directory 'qemu-system-x86_64.exe'
$imageTool = Join-Path $directory 'qemu-img.exe'
foreach ($path in @($executable, $imageTool, (Join-Path $directory 'share\edk2-x86_64-code.fd'),
    (Join-Path $directory 'share\edk2-i386-vars.fd'))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing runtime component: $path" }
}
$version = & $executable --version
if ($LASTEXITCODE -ne 0 -or $version[0] -notmatch ('^QEMU emulator version ' + [regex]::Escape($pin.version) + '(?:\s|$)')) {
    throw 'Extracted QEMU version does not match the pin'
}
$receipt = [ordered]@{
    schema_version = 1
    version = $pin.version
    version_output = @($version)
    directory = $directory
    executable = $executable
    executable_sha256 = (Get-FileHash -LiteralPath $executable).Hash.ToLowerInvariant()
    image_tool = $imageTool
    archive_sha512 = $pin.sha512
    source_url = $pin.url
    installer_executed = $false
}
[IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json -Depth 5
