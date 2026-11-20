function Initialize-BleAnalyzer {
    if ('Codex.Ble.AnalyzerWindow' -as [type]) { return }

    $usingLines = [System.Collections.Generic.List[string]]::new()
    $bodies = [System.Collections.Generic.List[string]]::new()
    foreach ($name in 'BleAnalyzerWindow.cs.txt', 'BleLogParser.cs.txt', 'BleProtocol.cs.txt', 'BleLogcatCapture.cs.txt', 'BleProtocolDoc.cs.txt') {
        $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $name), [Text.Encoding]::UTF8)
        $parts = $source -split '(?m)(?=^namespace Codex\.Ble\b)', 2
        if ($parts.Count -ne 2) { throw "Invalid BLE Analyzer source: $name" }
        foreach ($usingLine in [regex]::Matches($parts[0], '(?m)^using [^;]+;')) { $usingLines.Add($usingLine.Value) }
        $bodies.Add($parts[1])
    }
    $definition = (($usingLines | Select-Object -Unique) -join "`n") + "`n" + ($bodies -join "`n")
    Add-Type -TypeDefinition $definition -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll')
}

function Show-BleAnalyzer {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory)][AllowEmptyString()][string]$AdbPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Serial,
        [string]$DeviceName = '',
        # Log lines to parse right away (the file open in the log viewer), and where they came from.
        [string[]]$Lines = @(),
        [string]$Source = ''
    )

    Initialize-BleAnalyzer
    $window = [Codex.Ble.AnalyzerWindow]::Open($Owner, $AdbPath, $Serial, $DeviceName)
    if ($Lines.Count -gt 0) { $window.ImportLog($Lines, $Source) }
}
