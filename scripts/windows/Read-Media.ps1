#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Iso,
    [string]$SevenZip = '7z.exe'
)

$ErrorActionPreference = 'Stop'
$path = (Resolve-Path -LiteralPath $Iso).Path
if ([IO.Path]::GetExtension($path) -ne '.iso') { throw 'Expected an ISO file' }
$file = Get-Item -LiteralPath $path
$hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
$mountedHere = $false
try {
    $image = Get-DiskImage -ImagePath $path
    if (-not $image.Attached) {
        $image = Mount-DiskImage -ImagePath $path -StorageType ISO -Access ReadOnly -PassThru
        $mountedHere = $true
    }
    $volumes = @($image | Get-Volume | Where-Object { $_.DriveLetter })
    if ($volumes.Count -ne 1) { throw 'Expected exactly one mounted ISO volume' }
    $volume = "$($volumes[0].DriveLetter):\"
    $wim = Join-Path $volume 'sources\install.wim'
    if (-not (Test-Path -LiteralPath $wim -PathType Leaf)) { throw 'This workflow currently requires sources/install.wim' }
    $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $volume 'setup.exe')
    if ($signature.Status.ToString() -ne 'Valid') { throw 'The setup.exe signature is not valid' }

    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command $SevenZip -ErrorAction Stop).Source)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('x', '-so', '-spd', $wim, '[1].xml')) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $bytes = [IO.MemoryStream]::new()
    $started = $false
    try {
        [void]$process.Start()
        $started = $true
        $errors = $process.StandardError.ReadToEndAsync()
        $buffer = [byte[]]::new(8192)
        while (($count = $process.StandardOutput.BaseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($bytes.Length + $count -gt 1MB) { throw 'WIM metadata exceeds 1 MiB' }
            $bytes.Write($buffer, 0, $count)
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "WIM metadata extraction failed: $($errors.Result)" }
        $xmlText = [Text.Encoding]::Unicode.GetString($bytes.ToArray()).Trim([char]0xFEFF, [char]0)
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
        $bytes.Dispose()
    }
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 1MB
    $reader = [Xml.XmlReader]::Create([IO.StringReader]::new($xmlText), $settings)
    try {
        $xml = [Xml.XmlDocument]::new()
        $xml.XmlResolver = $null
        $xml.Load($reader)
    } finally { $reader.Dispose() }
    $images = @($xml.WIM.IMAGE | ForEach-Object {
        [ordered]@{
            index = [int]$_.INDEX
            name = [string]$_.NAME
            edition = [string]$_.WINDOWS.EDITIONID
            architecture = [int]$_.WINDOWS.ARCH
            language = [string]$_.WINDOWS.LANGUAGES.DEFAULT
            version = '{0}.{1}.{2}.{3}' -f $_.WINDOWS.VERSION.MAJOR, $_.WINDOWS.VERSION.MINOR,
                $_.WINDOWS.VERSION.BUILD, $_.WINDOWS.VERSION.SPBUILD
        }
    })
    if ($images.Count -eq 0 -or $images.Count -gt 64) { throw 'Invalid WIM image count' }
    [ordered]@{
        schema_version = 1
        path = $path
        bytes = $file.Length
        sha256 = $hash
        setup_signature = $signature.Status.ToString()
        setup_signer = $signature.SignerCertificate.Subject
        volume_label = $volumes[0].FileSystemLabel
        images = $images
        limitation = 'A signed setup executable and a recorded ISO hash are not a full-media authenticity attestation.'
    } | ConvertTo-Json -Depth 6
} finally {
    if ($mountedHere) { Dismount-DiskImage -ImagePath $path | Out-Null }
}
