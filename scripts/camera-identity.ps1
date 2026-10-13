param([string]$CameraIP = '192.168.54.1')
$ErrorActionPreference = 'Stop'
$gxAddress = [System.Net.IPAddress]::Parse($CameraIP)
if ($gxAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { throw 'Only IPv4 camera addresses are supported.' }
$gxOctets = $gxAddress.GetAddressBytes()
if ($gxOctets[0] -eq 0 -or $gxOctets[0] -ge 224) { throw 'Enter a unicast camera address.' }
Write-Output 'Connect this Windows PC to the GX85 Wi-Fi before continuing.'
$gxSocket = [System.Net.Sockets.UdpClient]::new()
$gxSocket.Client.ReceiveTimeout = 5000
try {
    # Desktop diagnostic can use multicast if a camera does not answer unicast searches.
    # Replies are accepted only from the camera address explicitly supplied by the user.
    $gxSearch = "M-SEARCH * HTTP/1.1`r`nHOST: 239.255.255.250:1900`r`nMAN: `"ssdp:discover`"`r`nMX: 2`r`nST: urn:schemas-upnp-org:device:MediaServer:1`r`n`r`n"
    $gxBytes = [System.Text.Encoding]::ASCII.GetBytes($gxSearch)
    $gxTarget = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse('239.255.255.250'), 1900)
    $gxSocket.Send($gxBytes, $gxBytes.Length, $gxTarget) | Out-Null
    $gxDeadline = [DateTime]::UtcNow.AddSeconds(5)
    $gxLocation = $null
    while ([DateTime]::UtcNow -lt $gxDeadline) {
        $gxRemote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $gxReply = $gxSocket.Receive([ref]$gxRemote)
        if ($gxRemote.Address.ToString() -ne $gxAddress.ToString()) { continue }
        $gxText = [System.Text.Encoding]::UTF8.GetString($gxReply)
        foreach ($gxLine in ($gxText -split "`r?`n")) {
            if ($gxLine -match '^LOCATION:\s*(.+)$') {
                $gxUrl = [uri]$Matches[1].Trim()
                if ($gxUrl.Scheme -eq 'http' -and $gxUrl.Host -eq $gxAddress.ToString() -and [string]::IsNullOrEmpty($gxUrl.UserInfo)) { $gxLocation = $gxUrl }
            }
        }
        if ($gxLocation) { break }
    }
    if (-not $gxLocation) { throw 'Camera identity was not found. Check camera remote mode, Wi-Fi and Windows network permissions.' }
    $gxReply = Invoke-WebRequest -Uri $gxLocation -TimeoutSec 3 -MaximumRedirection 0 -UseBasicParsing
    $gxXMLSettings = [System.Xml.XmlReaderSettings]::new()
    $gxXMLSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $gxXMLSettings.MaxCharactersInDocument = 262144
    $gxXMLReader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($gxReply.Content), $gxXMLSettings)
    $gxDocument = [System.Xml.XmlDocument]::new()
    $gxDocument.XmlResolver = $null
    $gxDocument.Load($gxXMLReader)
    $gxXMLReader.Dispose()
    $gxUDN = $gxDocument.SelectSingleNode("//*[local-name()='UDN']")
    if (-not $gxUDN) { throw 'Camera replied without a UDN field.' }
    $gxIdentity = $gxUDN.InnerText -replace '^uuid:', ''
    if ($gxIdentity -notmatch '^[A-Za-z0-9-]{1,128}$') { throw 'Unexpected identity format.' }
    Write-Output 'Copy this value into the iPhone app: Settings > Advanced connection settings > Camera identity.'
    Write-Output $gxIdentity
} finally { $gxSocket.Dispose() }
