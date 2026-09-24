#requires -Version 7.0
Set-StrictMode -Version Latest

function Read-QmpLine {
    param([IO.StreamReader]$Reader)
    $line = [Text.StringBuilder]::new()
    while ($line.Length -lt 1048576) {
        $next = $Reader.Read()
        if ($next -lt 0) { throw 'QMP connection closed before a complete message' }
        if ($next -eq 10) { return $line.ToString().TrimEnd("`r") }
        [void]$line.Append([char]$next)
    }
    throw 'QMP message exceeds 1 MiB'
}

function Send-QmpRequest {
    param([IO.StreamReader]$Reader, [IO.StreamWriter]$Writer, [string]$Command, [hashtable]$Arguments)
    $id = [guid]::NewGuid().ToString('N')
    $message = @{ execute = $Command; id = $id }
    if ($Arguments.Count) { $message.arguments = $Arguments }
    $Writer.WriteLine(($message | ConvertTo-Json -Depth 12 -Compress))
    $Writer.Flush()
    for ($i = 0; $i -lt 64; $i++) {
        $reply = Read-QmpLine $Reader | ConvertFrom-Json -AsHashtable
        if (-not $reply.ContainsKey('id') -or $reply.id -ne $id) { continue }
        if ($reply.ContainsKey('error')) { throw "QMP $Command failed: $($reply.error.desc)" }
        if (-not $reply.ContainsKey('return')) { throw 'QMP response has no return value' }
        return $reply['return']
    }
    throw 'QMP response was not received within 64 messages'
}

function Invoke-LimiarQmp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1024,65535)][int]$Port,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]
        [ValidateSet('query-status','screendump','system_powerdown','send-key','input-send-event','query-cpus-fast')]
        [string]$Command,
        [hashtable]$Arguments = @{}
    )
    $client = [Net.Sockets.TcpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
    $reader = $null
    $writer = $null
    try {
        $connection = $client.ConnectAsync([Net.IPAddress]::Loopback, $Port)
        if (-not $connection.Wait(5000)) { throw 'QMP connection timed out' }
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000
        $stream.WriteTimeout = 5000
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $false, 4096, $true)
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false), 4096, $true)
        $writer.NewLine = "`n"
        $greeting = Read-QmpLine $reader | ConvertFrom-Json -AsHashtable
        if (-not $greeting.ContainsKey('QMP')) { throw 'Endpoint did not provide a QMP greeting' }
        [void](Send-QmpRequest $reader $writer 'qmp_capabilities' @{})
        $identity = Send-QmpRequest $reader $writer 'query-name' @{}
        if ($identity.name -ne $Name) { throw 'QMP machine name does not match this lab' }
        Send-QmpRequest $reader $writer $Command $Arguments
    } finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $reader) { $reader.Dispose() }
        $client.Dispose()
    }
}

Export-ModuleMember -Function Invoke-LimiarQmp
