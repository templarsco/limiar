#requires -Version 5.1
param([switch]$EnableGuestTestSigning, [switch]$Resume)
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'graphics-config.json') -Raw | ConvertFrom-Json
& (Join-Path $PSScriptRoot 'Prepare-GraphicsProbe.ps1') -ExpectedUuid ([guid]$config.uuid) `
    -OwnerToken ([guid]$config.owner_token) -EnableGuestTestSigning:$EnableGuestTestSigning -Resume:$Resume
