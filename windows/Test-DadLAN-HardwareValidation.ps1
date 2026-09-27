# Test-DadLAN-HardwareValidation.ps1
# Parser/registry smoke check. Runtime safety behavior is exercised by
# Test-DadLAN-HardwareSafety.ps1 instead of source-string presence assertions.

[CmdletBinding()]
param(
    [switch]$RunBaseline
)

$ErrorActionPreference = "Stop"

$runner = Join-Path $PSScriptRoot "DadLAN-HardwareValidation.ps1"
$diagnostics = Join-Path $PSScriptRoot "DadLAN-Diagnostics.ps1"

if (-not (Test-Path $runner)) {
    throw "Missing runner: $runner"
}

if (-not (Test-Path $diagnostics)) {
    throw "Missing diagnostics registry: $diagnostics"
}

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $runner,
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -gt 0) {
    $details = $parseErrors | ForEach-Object {
        "Line $($_.Extent.StartLineNumber): $($_.Message)"
    }
    throw ("PowerShell parser found errors:" + [Environment]::NewLine + ($details -join [Environment]::NewLine))
}

. $diagnostics

$requiredDiagnostics = @(
    "System Snapshot",
    "Hardware Validation (Safe Baseline)"
)

foreach ($name in $requiredDiagnostics) {
    if ((Get-DadLANDiagnosticList) -notcontains $name) {
        throw "Missing diagnostic registration: $name"
    }

    $package = Get-DadLANDiagnosticPackageId -ActionName $name
    if ([string]::IsNullOrWhiteSpace($package)) {
        throw "Diagnostic has no package ID value: $name"
    }

    $poll = Get-DadLANDiagnosticPollSeconds -ActionName $name
    if ($poll -lt 30) {
        throw "Diagnostic polling window is unexpectedly short: $name = $poll seconds"
    }
}

Write-Host "PASS: PowerShell parser accepted DadLAN-HardwareValidation.ps1"
Write-Host "PASS: required diagnostic definitions are present"
Write-Host "Run Test-DadLAN-HardwareSafety.ps1 for failure-injection and owned-job tests."

if ($RunBaseline) {
    Write-Host "Running read-only baseline smoke test..."
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Mode Baseline -DryRun
    if ($LASTEXITCODE -ne 0) {
        throw "Baseline smoke test returned exit code $LASTEXITCODE"
    }
    Write-Host "PASS: baseline smoke test completed"
}
