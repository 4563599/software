Set-StrictMode -Version Latest

function ConvertFrom-CodexIpTrace {
    param(
        [AllowEmptyString()][string]$Trace,
        [Parameter(Mandatory = $true)][string]$ExpectedIp
    )

    $expectedAddress = $null
    if (-not [System.Net.IPAddress]::TryParse($ExpectedIp, [ref]$expectedAddress)) {
        throw 'The expected static IP is invalid.'
    }

    $match = [regex]::Match($Trace, '(?m)^ip=([^\r\n]+)\r?$')
    $address = $null
    if (-not $match.Success -or
        -not [System.Net.IPAddress]::TryParse($match.Groups[1].Value.Trim(), [ref]$address)) {
        throw 'The network check did not return a valid IP address.'
    }

    $status = if ($address.Equals($expectedAddress)) { 'Verified' } else { 'Mismatch' }
    return [pscustomobject]@{
        Status = $status
        ActualIp = $address.ToString()
        ExpectedIp = $expectedAddress.ToString()
        Error = $null
    }
}

function Get-CodexNetworkCheck {
    param(
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [string]$ProxyUri
    )

    $expectedIp = ''
    $request = $null
    $response = $null
    $reader = $null
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $settings = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        $expectedIp = [string]$settings.ExpectedStaticIp
        $expectedAddress = $null
        if (-not [System.Net.IPAddress]::TryParse($expectedIp, [ref]$expectedAddress)) {
            throw 'The expected static IP is missing or invalid.'
        }

        $request = [System.Net.HttpWebRequest]::Create('https://chatgpt.com/cdn-cgi/trace')
        $request.Proxy = if ($ProxyUri) {
            New-Object System.Net.WebProxy($ProxyUri)
        } else {
            [System.Net.WebRequest]::GetSystemWebProxy()
        }
        $request.Timeout = 6000
        $request.ReadWriteTimeout = 6000
        $request.AllowAutoRedirect = $false
        $request.KeepAlive = $false
        $request.UserAgent = 'CodexFloatingButton-StaticIpCheck/1.0'
        $request.CachePolicy = New-Object System.Net.Cache.RequestCachePolicy(
            [System.Net.Cache.RequestCacheLevel]::NoCacheNoStore
        )

        $responseTask = $request.GetResponseAsync()
        if (-not $responseTask.Wait([Math]::Max(1, 7500 - [int]$watch.ElapsedMilliseconds))) {
            throw 'The network check timed out.'
        }
        $response = $responseTask.GetAwaiter().GetResult()
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        $readTask = $reader.ReadToEndAsync()
        if (-not $readTask.Wait([Math]::Max(1, 7500 - [int]$watch.ElapsedMilliseconds))) {
            throw 'The network check timed out while reading the response.'
        }
        return ConvertFrom-CodexIpTrace -Trace $readTask.GetAwaiter().GetResult() -ExpectedIp $expectedIp
    }
    catch {
        return [pscustomobject]@{
            Status = 'Unknown'
            ActualIp = ''
            ExpectedIp = $expectedIp
            Error = $_.Exception.GetBaseException().Message
        }
    }
    finally {
        if ($null -ne $request) { $request.Abort() }
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        $watch.Stop()
    }
}

function Confirm-CodexStaticIp {
    param(
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [Parameter(Mandatory = $true)]$Owner
    )

    $result = Get-CodexNetworkCheck -SettingsPath $SettingsPath
    try {
        $result | Add-Member -NotePropertyName CheckedAt -NotePropertyValue (Get-Date -Format 'o')
        $result | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    }
    catch {
        # A diagnostic write failure must not change the IP check outcome.
    }

    if ($result.Status -eq 'Verified') { return $true }

    if ($result.Status -eq 'Mismatch') {
        $message = "当前出口 IP：$($result.ActualIp)`r`n预期静态 IP：$($result.ExpectedIp)"
    } else {
        $message = "未能确认静态 IP。`r`n预期静态 IP：$($result.ExpectedIp)`r`n原因：$($result.Error)"
    }
    $message += "`r`n`r`n请确认 Clash 已开启系统代理，AI 已选择静态出口。`r`n仍要打开 Codex 吗？"
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $Owner,
        $message,
        'Codex 静态 IP 检查',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    return $answer -eq [System.Windows.Forms.DialogResult]::Yes
}
