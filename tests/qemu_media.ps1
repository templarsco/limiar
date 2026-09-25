#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\qemu\Media.psm1') -Force
$directory = Join-Path ([IO.Path]::GetTempPath()) ('limiar-media-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$iso = Join-Path $directory 'tools.iso'
$count = 0
try {
    [IO.File]::WriteAllBytes($iso, [byte[]]@(1,2,3))
    $cd = @{device='cdrom';removable=$true;inserted=@{ro=$true}}
    $request = New-LimiarOpticalMediaRequest -IsoPath $iso -Blocks @($cd)
    if ($request.device -ne 'cdrom' -or $request['read-only-mode'] -ne 'read-only' -or $request.filename -ne $iso) {
        throw 'Unexpected optical request'
    }
    $count++
    foreach ($blocks in @(
        @{items=@()},
        @{items=@(@{device='os';removable=$false;inserted=@{ro=$false}})},
        @{items=@(@{device='cdrom';removable=$false;inserted=@{ro=$true}})},
        @{items=@(@{device='cdrom';removable=$true;inserted=@{ro=$false}})},
        @{items=@($cd,$cd)}
    )) {
        $rejected = $false
        try { New-LimiarOpticalMediaRequest -IsoPath $iso -Blocks $blocks.items | Out-Null } catch { $rejected=$true }
        if (-not $rejected) { throw 'Unsafe block device selection was accepted' }
        $count++
    }
    [IO.File]::WriteAllBytes($iso, [byte[]]@())
    $rejected = $false
    try { New-LimiarOpticalMediaRequest -IsoPath $iso -Blocks @($cd) | Out-Null } catch { $rejected=$true }
    if (-not $rejected) { throw 'Empty image was accepted' }
    $count++
} finally {
    [IO.File]::Delete($iso)
    [IO.Directory]::Delete($directory)
}
"Optical media safety: $count assertions passed; no VM operations."
