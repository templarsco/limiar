[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $root
try {
    $raw = & cargo metadata --format-version 1 --locked --filter-platform x86_64-pc-windows-msvc
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read Cargo dependency metadata' }
    $metadata = ($raw -join "`n") | ConvertFrom-Json
} finally {
    Pop-Location
}

$text = [Text.StringBuilder]::new()
[void]$text.AppendLine('Limiar third-party dependency notices')
[void]$text.AppendLine('Collected from the pinned Cargo graph; includes development dependencies.')
[void]$text.AppendLine('This inventory is not a substitute for a production distribution review.')

foreach ($package in @($metadata.packages | Where-Object { $_.source } | Sort-Object name, version)) {
    [void]$text.AppendLine("`n============================================================")
    [void]$text.AppendLine("$($package.name) $($package.version)")
    [void]$text.AppendLine("Declared license: $($package.license)")
    if ($package.repository) { [void]$text.AppendLine("Source: $($package.repository)") }
    $directory = Split-Path -Parent $package.manifest_path
    $files = @(Get-ChildItem -LiteralPath $directory -File |
        Where-Object { $_.Name -match '^(LICEN[CS]E|COPYING|NOTICE)' } |
        Sort-Object Name)
    if ($package.license_file) {
        $extra = Join-Path $directory $package.license_file
        if (Test-Path -LiteralPath $extra -PathType Leaf) {
            $files = @($files) + @(Get-Item -LiteralPath $extra)
        }
    }
    foreach ($file in @($files | Sort-Object FullName -Unique)) {
        [void]$text.AppendLine("`n--- $($file.Name) ---")
        [void]$text.AppendLine([IO.File]::ReadAllText($file.FullName))
    }
    if ($files.Count -eq 0) {
        throw "No license/notice file found for $($package.name); review before packaging"
    }
}

$destination = [IO.Path]::GetFullPath($OutputPath)
$parent = Split-Path -Parent $destination
New-Item -ItemType Directory -Path $parent -Force | Out-Null
if (Test-Path -LiteralPath $destination) { throw "Refusing to overwrite $destination" }
[IO.File]::WriteAllText($destination, $text.ToString(), [Text.UTF8Encoding]::new($false))
Write-Host "Dependency notices: $destination"
