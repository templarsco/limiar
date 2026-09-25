#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'graphics-config.json') -Raw | ConvertFrom-Json
if ($config.schema_version -ne 1 -or [guid](Get-CimInstance Win32_ComputerSystemProduct).UUID -ne [guid]$config.uuid) {
    throw 'Guest UUID mismatch'
}
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'driver\files.json') -Raw | ConvertFrom-Json
foreach ($file in $manifest.files) {
    if ($file.name -notmatch '^[A-Za-z0-9_.-]+$' -or
        (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot "driver\$($file.name)")).Hash.ToLowerInvariant() -ne $file.sha256) {
        throw 'Stored driver payload changed'
    }
}
$graphicsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
$oldTdr = Get-ItemProperty -LiteralPath $graphicsKey -Name TdrDebugMode -ErrorAction SilentlyContinue
$receipt = [ordered]@{schema_version=1;status='installing';uuid=$config.uuid;owner_token=$config.owner_token}
try {
    $log = & "$env:SystemRoot\System32\pnputil.exe" /add-driver (Join-Path $PSScriptRoot 'driver\viogpu3d.inf') /install 2>&1
    $code = $LASTEXITCODE
    [IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'driver-install.log'), [string[]]$log)
    if ($code -notin @(0,3010)) { throw "Guest driver installation returned $code" }
    $receipt.status = 'installed'
    $receipt.reboot_required = ($code -eq 3010)
} catch {
    $receipt.status = 'failed'
    $receipt.error = $_.Exception.Message
} finally {
    # The upstream experimental INF disables normal TDR handling. Preserve the guest's prior policy.
    if ($null -ne $oldTdr) {
        Set-ItemProperty -LiteralPath $graphicsKey -Name TdrDebugMode -Type DWord -Value $oldTdr.TdrDebugMode
    } else {
        Remove-ItemProperty -LiteralPath $graphicsKey -Name TdrDebugMode -ErrorAction SilentlyContinue
    }
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'installation.json'), ($receipt | ConvertTo-Json),
        [Text.UTF8Encoding]::new($false))
    Unregister-ScheduledTask -TaskName LimiarGraphicsInstall -Confirm:$false
}
if ($receipt.status -ne 'installed') { throw $receipt.error }
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut('C:\Users\Public\Desktop\Limiar 3D.lnk')
$shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$shortcut.Arguments = '-NoProfile -ExecutionPolicy RemoteSigned -File C:\Limiar\Graphics\Start-GraphicsDemo.ps1'
$shortcut.Save()
& (Join-Path $PSScriptRoot 'Report-Graphics.ps1')
