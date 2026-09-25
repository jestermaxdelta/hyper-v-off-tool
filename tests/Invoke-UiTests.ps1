#requires -version 5.1
# Runs on Windows (GitHub Actions windows-latest). Parses both scripts under
# Windows PowerShell 5.1, then boots the real console with its final
# ShowDialog() swapped for tests\UiScenarios.ps1 so every scenario runs in the
# console's own script scope against the real XAML.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$outputs = Join-Path $root 'outputs'

$parseFailed = $false
foreach ($file in 'HyperV-Off-Console.ps1', 'Disable-HyperV-Fully.ps1') {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $outputs $file), [ref]$tokens, [ref]$errors)
    if ($errors.Count) {
        $parseFailed = $true
        $errors | ForEach-Object { Write-Host "PARSE ERROR $file L$($_.Extent.StartLineNumber): $($_.Message)" }
    } else { Write-Host "ok: $file parses under PowerShell $($PSVersionTable.PSVersion)" }
}
if ($parseFailed) { exit 1 }

$source = Get-Content -LiteralPath (Join-Path $outputs 'HyperV-Off-Console.ps1') -Raw -Encoding UTF8
$marker = '[void]$window.ShowDialog()'
if (-not $source.Contains($marker)) { Write-Host 'FAIL: ShowDialog marker not found'; exit 1 }
$hostPath = Join-Path $outputs '.ui-test-host.ps1'
$source.Replace($marker, ". (Join-Path `$PSScriptRoot '..\tests\UiScenarios.ps1')") |
    Set-Content -LiteralPath $hostPath -Encoding UTF8

try {
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $hostPath
    $code = $LASTEXITCODE
}
finally { Remove-Item -LiteralPath $hostPath -Force -ErrorAction SilentlyContinue }
Write-Host "Scenario host exited with $code"
exit $code
