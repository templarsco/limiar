#requires -Version 7.0
Set-StrictMode -Version Latest

function New-LimiarOpticalMediaRequest {
    param([Parameter(Mandatory=$true)][string]$IsoPath, [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Blocks)
    $file = Get-Item -LiteralPath $IsoPath -ErrorAction Stop
    if ($file -isnot [IO.FileInfo] -or $file.Extension -ine '.iso' -or $file.Length -eq 0 -or
        $file.FullName.StartsWith('\\') -or
        ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Optical media must be a nonempty regular local ISO file'
    }
    $cdrom = @($Blocks | Where-Object {
        $_.device -eq 'cdrom' -and $_.removable -and $_.inserted -and $_.inserted.ro
    })
    if ($cdrom.Count -ne 1) { throw 'Expected exactly one read-only optical medium named cdrom' }
    return @{
        device='cdrom';filename=$file.FullName;format='raw';'read-only-mode'='read-only'
    }
}

Export-ModuleMember -Function New-LimiarOpticalMediaRequest
