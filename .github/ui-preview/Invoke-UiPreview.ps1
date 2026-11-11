#requires -version 5.1
# TEMPORARY review harness (removed before merge). Parses both scripts under
# Windows PowerShell 5.1, then boots the real console with ShowDialog()
# swapped for Scenarios.ps1, which renders every screen state to PNG.
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$outputs = Join-Path $root 'outputs'

$parseFailed = $false
foreach ($file in 'HyperV-Off-Console.ps1', 'Disable-HyperV-Fully.ps1') {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $outputs $file), [ref]$tokens, [ref]$errors)
    if ($errors.Count) {
        $parseFailed = $true
        $errors | ForEach-Object { Write-Host "PARSE ERROR $file L$($_.Extent.StartLineNumber): $($_.Message)" }
    }
    else { Write-Host "ok: $file parses under PowerShell $($PSVersionTable.PSVersion)" }
}
if ($parseFailed) { exit 1 }

$source = Get-Content -LiteralPath (Join-Path $outputs 'HyperV-Off-Console.ps1') -Raw -Encoding UTF8
$marker = '[void]$window.ShowDialog()'
if (-not $source.Contains($marker)) { Write-Host 'FAIL: ShowDialog marker not found'; exit 1 }
$hostPath = Join-Path $outputs '.ui-preview-host.ps1'
$scenarioPath = Join-Path $PSScriptRoot 'Scenarios.ps1'
$source.Replace($marker, ". '$scenarioPath'") | Set-Content -LiteralPath $hostPath -Encoding UTF8

try {
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $hostPath
    $code = $LASTEXITCODE
}
finally { Remove-Item -LiteralPath $hostPath -Force -ErrorAction SilentlyContinue }

$trace = Join-Path $env:ProgramData 'Disable-HyperV-Fully\Console-UI.log'
if (Test-Path -LiteralPath $trace) {
    Write-Host '----- Console-UI.log -----'
    Get-Content -LiteralPath $trace | ForEach-Object { Write-Host $_ }
}
Write-Host "Scenario host exited with $code"
exit $code
