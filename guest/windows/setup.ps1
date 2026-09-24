#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$configuration = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
if ($configuration.schema_version -ne 1) { throw 'Unsupported guest tools media' }
& (Join-Path $PSScriptRoot 'Install-IdentityProbe.ps1') -ExpectedUuid ([guid]$configuration.uuid) `
    -OwnerToken ([guid]$configuration.owner_token) -DisableHibernate
