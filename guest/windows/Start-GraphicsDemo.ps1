#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'graphics-config.json') -Raw | ConvertFrom-Json
if ([guid](Get-CimInstance Win32_ComputerSystemProduct).UUID -ne [guid]$config.uuid) { throw 'Guest UUID mismatch' }
$cli = Join-Path $PSScriptRoot 'limiar.exe'
if ((Get-FileHash -LiteralPath $cli).Hash.ToLowerInvariant() -ne $config.cli_sha256) { throw 'Guest CLI changed' }
$directory = Join-Path $env:LOCALAPPDATA 'Limiar\Graphics'
[void][IO.Directory]::CreateDirectory($directory)
$output = Join-Path $directory ('demo-' + [guid]::NewGuid().ToString('N') + '.json')
& $cli --output $output gpu demo --adapter Hardsoft --seconds 120
if ($LASTEXITCODE -ne 0) { throw "Presentation probe failed; inspect $output" }
