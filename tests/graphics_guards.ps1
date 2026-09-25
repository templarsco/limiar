#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$directory = Join-Path ([IO.Path]::GetTempPath()) ('limiar-graphics-guards-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$actual = '00112233-4455-6677-8899-aabbccddeeff'
$expected = '10112233-4455-6677-8899-aabbccddeeff'
$owner = '20112233-4455-6677-8899-aabbccddeeff'
function Get-CimInstance {
    param($ClassName)
    return [pscustomobject]@{UUID='00112233-4455-6677-8899-aabbccddeeff'}
}
$files = @('Prepare-GraphicsProbe.ps1','Install-GraphicsDriver.ps1','Report-Graphics.ps1','Start-GraphicsDemo.ps1')
$assertions = 0
try {
    [IO.File]::WriteAllText((Join-Path $directory 'graphics-config.json'), (@{
        schema_version=1;uuid=$expected;owner_token=$owner
    } | ConvertTo-Json))
    foreach ($name in $files) {
        $scriptPath = Join-Path $directory $name
        Copy-Item -LiteralPath (Join-Path $root "guest\windows\$name") -Destination $scriptPath
        $rejected = $false
        try {
            if ($name -eq 'Prepare-GraphicsProbe.ps1') {
                & $scriptPath -ExpectedUuid $expected -OwnerToken $owner -EnableGuestTestSigning
            } else { & $scriptPath }
        } catch { $rejected = $_.Exception.Message -like 'Guest UUID mismatch*' }
        if (-not $rejected) { throw "$name did not reject the wrong guest before reading its payload" }
        $assertions++
    }
    $rejected = $false
    try { & (Join-Path $directory 'Prepare-GraphicsProbe.ps1') -ExpectedUuid $actual -OwnerToken $owner }
    catch { $rejected = $_.Exception.Message -like 'Explicit -EnableGuestTestSigning*' }
    if (-not $rejected) { throw 'Missing test-signing acknowledgement was accepted' }
    $assertions++
    $rejected = $false
    try { & (Join-Path $root 'scripts\qemu\Prepare-GraphicsProbe.ps1') -LabPath missing -ArchivePath missing }
    catch { $rejected = $_.Exception.Message -like 'Use -Experimental*' }
    if (-not $rejected) { throw 'Missing experimental acknowledgement was accepted' }
    $assertions++
} finally {
    foreach ($name in ($files + 'graphics-config.json')) { [IO.File]::Delete((Join-Path $directory $name)) }
    [IO.Directory]::Delete($directory)
}
"Graphics preparation guards: $assertions assertions passed; no real driver/boot changes."
