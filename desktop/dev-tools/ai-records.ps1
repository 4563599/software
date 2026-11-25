param(
    # Run without a window: copy new Claude conversations into the records folder, then exit.
    # The notes backend starts this when transcripts have changed, so rounds are kept (and synced)
    # even if the AI records window is never opened before Claude removes old transcripts.
    [switch]$Archive
)

function Initialize-AiRecords {
    if (-not ('Codex.AiRecords.AiRecordsWindow' -as [type])) { Add-AiRecordsTypes }
    # Codex conversations are exported from its SQLite databases by Node before each load.
    [Codex.AiRecords.ChatArchive]::CodexExporter = Join-Path (Split-Path -Parent $PSScriptRoot) 't-notes\client\codex-records.cjs'
}

function Add-AiRecordsTypes {

    # The two C# sources are compiled together once per process (the usings of both files merged at the top).
    $usingLines = [System.Collections.Generic.List[string]]::new()
    $bodies = [System.Collections.Generic.List[string]]::new()
    foreach ($name in 'AiRecords.cs.txt', 'AiRecordsWindow.cs.txt') {
        $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $name), [Text.Encoding]::UTF8)
        $parts = $source -split '(?m)(?=^namespace Codex\.AiRecords\b)', 2
        if ($parts.Count -ne 2) { throw "Invalid AI records source: $name" }
        foreach ($usingLine in [regex]::Matches($parts[0], '(?m)^using [^;]+;')) { $usingLines.Add($usingLine.Value) }
        $bodies.Add($parts[1])
    }
    $definition = (($usingLines | Select-Object -Unique) -join "`n") + "`n" + ($bodies -join "`n")
    Add-Type -TypeDefinition $definition -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll', 'System.Web.Extensions.dll')
}

function Show-AiRecords {
    param([Parameter(Mandatory)][System.Windows.Forms.Form]$Owner)

    Initialize-AiRecords
    [Codex.AiRecords.AiRecordsWindow]::Open($Owner)
}

if ($Archive) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Web.Extensions
    Initialize-AiRecords
    [void][Codex.AiRecords.ChatArchive]::LoadAll($null)
    [Codex.AiRecords.ChatArchive]::RequestSync()
}
