param([Parameter(Mandatory=$true)][ValidateSet('Protect','Unprotect')][string]$Action)
$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName System.Security
    $inputBytes = [Convert]::FromBase64String([Console]::In.ReadToEnd().Trim())
    $entropy = [Text.Encoding]::UTF8.GetBytes('TNotes remembered login v1')
    $scope = [Security.Cryptography.DataProtectionScope]::CurrentUser
    if ($Action -eq 'Protect') {
        $outputBytes = [Security.Cryptography.ProtectedData]::Protect($inputBytes, $entropy, $scope)
    } else {
        $outputBytes = [Security.Cryptography.ProtectedData]::Unprotect($inputBytes, $entropy, $scope)
    }
    [Console]::Out.Write([Convert]::ToBase64String($outputBytes))
    [Array]::Clear($inputBytes, 0, $inputBytes.Length)
    [Array]::Clear($outputBytes, 0, $outputBytes.Length)
} catch {
    [Console]::Error.Write('Windows login protection failed.')
    exit 1
}
