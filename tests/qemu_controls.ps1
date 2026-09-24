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
$module = Get-Module Lab.Common
$processMock = @{Path='qemu.exe';Calls=0}
& $module {
    param($State)
    $script:LimiarProcessMock = $State
    function script:Get-Process {
        [CmdletBinding()]
        param($Id)
        $script:LimiarProcessMock.Calls++
        return [pscustomobject]@{Id=$Id;Path=$script:LimiarProcessMock.Path}
    }
} $processMock
try {
    $lab = [pscustomobject]@{Record=@{runtime_path='qemu.exe'}}
    $status = @{supervisor_active=$true;state='running';last_run=@{runtime_pid=321}}
    Assert-LimiarQmpOwner $lab $status
    $assertions++
    Assert-Equal $processMock.Calls 1
    $processMock.Path = 'another-program.exe'
    $rejected = $false
    try { Assert-LimiarQmpOwner $lab $status }
    catch { $rejected = $_.Exception.Message -eq 'Unexpected supervised runtime executable' }
    Assert-Equal $rejected $true
    Assert-Equal $processMock.Calls 2
    $status.supervisor_active = $false
    $rejected = $false
    try { Assert-LimiarQmpOwner $lab $status } catch { $rejected = $true }
    Assert-Equal $rejected $true
    Assert-Equal $processMock.Calls 2
} finally {
    & $module {
        Remove-Item Function:Get-Process -ErrorAction Stop
        Remove-Variable LimiarProcessMock -Scope Script -ErrorAction Stop
    }
}
Assert-Equal (& $module { (Get-Command Get-Process).CommandType.ToString() }) 'Cmdlet'
$cliDirectory = Join-Path ([IO.Path]::GetTempPath()) ('limiar-cli-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($cliDirectory)
$cliFile = Join-Path $cliDirectory 'limiar.exe'
try {
    [IO.File]::WriteAllText($cliFile, 'fixture, never executed')
    $record = @{cli_path=$cliFile;cli_sha256=(Get-FileHash -LiteralPath $cliFile).Hash.ToLowerInvariant()}
    Assert-Equal (& $module { param($Record) Resolve-LimiarLabCli $Record '' } $record) $cliFile
    foreach ($invalid in @(
        @{cli_path='relative.exe';cli_sha256=$record.cli_sha256},
        @{cli_path=$cliDirectory;cli_sha256=$record.cli_sha256},
        @{cli_path=$cliFile},
        @{cli_path='';cli_sha256=$record.cli_sha256},
        @{cli_path=$cliFile;cli_sha256=('0' * 64)}
    )) {
        $rejected = $false
        try { & $module { param($Record) Resolve-LimiarLabCli $Record '' } $invalid | Out-Null }
        catch { $rejected = $true }
        Assert-Equal $rejected $true
    }
    [IO.File]::AppendAllText($cliFile, 'modified')
    $rejected = $false
    try { & $module { param($Record) Resolve-LimiarLabCli $Record '' } $record | Out-Null }
    catch { $rejected = $_.Exception.Message -eq 'Lab CLI changed since this lab was prepared' }
    Assert-Equal $rejected $true
} finally {
    [IO.File]::Delete($cliFile)
    [IO.Directory]::Delete($cliDirectory)
}
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
