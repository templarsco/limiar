#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\qemu\Lab.Common.psm1') -Force
$assertions = 0
function Assert-Equal {
    param($Actual, $Expected)
    if ($Actual -cne $Expected) { throw "Expected '$Expected', observed '$Actual'" }
    $script:assertions++
}
Assert-Equal (ConvertTo-LimiarWindowsArgument 'plain') '"plain"'
Assert-Equal (ConvertTo-LimiarWindowsArgument 'with spaces') '"with spaces"'
Assert-Equal (ConvertTo-LimiarWindowsArgument 'a"b') '"a\"b"'
Assert-Equal (ConvertTo-LimiarWindowsArgument 'C:\with space\') '"C:\with space\\"'
Assert-Equal (ConvertTo-LimiarWindowsArgument '') '""'
foreach ($bad in @("bad`nargument", "bad`rargument", "bad`0argument")) {
    $rejected = $false
    try { [void](ConvertTo-LimiarWindowsArgument $bad) } catch { $rejected = $true }
    Assert-Equal $rejected $true
}
function Get-NetTCPConnection {
    param($State, $LocalPort, $ErrorAction)
    return [pscustomobject]@{LocalAddress='127.0.0.1';OwningProcess=$script:listenerOwner}
}
$lab = [pscustomobject]@{Record=@{qmp_port=61234}}
$status = @{supervisor_active=$true;state='running';last_run=@{runtime_pid=321}}
$script:listenerOwner = 321
Assert-LimiarQmpOwner $lab $status
$assertions++
$script:listenerOwner = 123
$rejected = $false
try { Assert-LimiarQmpOwner $lab $status } catch { $rejected = $true }
Assert-Equal $rejected $true
$status.supervisor_active = $false
$rejected = $false
try { Assert-LimiarQmpOwner $lab $status } catch { $rejected = $true }
Assert-Equal $rejected $true
function Get-CimInstance {
    param($ClassName)
    return [pscustomobject]@{UUID='00112233-4455-6677-8899-aabbccddeeff'}
}
$rejected = $false
try {
    & (Join-Path $PSScriptRoot '..\guest\windows\Install-IdentityProbe.ps1') `
        -ExpectedUuid '10112233-4455-6677-8899-aabbccddeeff' -OwnerToken '20112233-4455-6677-8899-aabbccddeeff'
} catch {
    $rejected = $_.Exception.Message -like 'Guest UUID mismatch*'
}
Assert-Equal $rejected $true
"QEMU control safety: $assertions assertions passed."
