$ErrorActionPreference = 'Stop'
$owner = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'owner.json') -Raw | ConvertFrom-Json
$product = Get-CimInstance Win32_ComputerSystemProduct
if ($env:COMPUTERNAME -ne $owner.computer_name -or $product.UUID -ne $owner.bios_guid) {
    throw 'Bootstrap refused: this is not the designated lab guest'
}
$destination = 'C:\Limiar'
New-Item -ItemType Directory -Path $destination -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'limiar.exe') -Destination (Join-Path $destination 'limiar.exe')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'owner.json') -Destination (Join-Path $destination 'owner.json')

$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -LiteralPath $winlogon -Name AutoAdminLogon -Value '0'
Remove-ItemProperty -LiteralPath $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
$os = Get-CimInstance Win32_OperatingSystem
[ordered]@{
    schema_version = 1
    owner_token = $owner.owner_token
    computer_name = $env:COMPUTERNAME
    os_caption = $os.Caption
    os_version = $os.Version
    bios_guid = $product.UUID
    bootstrap_complete = $true
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination 'bootstrap.json') -Encoding UTF8
