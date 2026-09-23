# Test-DadLAN-HardwareValidation.ps1
# Lightweight Windows-side validation for the v0.4.1-dev hardware runner.

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

$runnerText = Get-Content -Path $runner -Raw

$requiredSafetyPatterns = [ordered]@{
    "tracked guided process" = '$script:ActiveGuidedProcess'
    "fatal cleanup stops active load" = 'Stop-GuidedTool -Process $script:ActiveGuidedProcess'
    "CPU telemetry loss abort" = 'All usable CPU temperature telemetry disappeared'
    "GPU telemetry loss abort" = 'Required GPU temperature telemetry disappeared'
    "cooldown readiness gate" = 'ReadyForNextLoad = $cooled'
    "cooldown requires current CPU telemetry when baseline exists" = '($null -ne $last.Temperatures.CpuC) -and'
    "cooldown requires current GPU telemetry when baseline exists" = '($null -ne $last.Temperatures.GpuC) -and'
    "GPU skipped after failed cooldown" = 'GPU stage skipped because cooldown readiness was not established.'
    "portable LibreHardwareMonitor discovery" = 'Get-Process -Name "LibreHardwareMonitor"'
    "OCCT configuration discovery" = 'function Find-OcctConfig'
    "OCCT safety preflight" = 'function Get-OcctSafetyStatus'
    "OCCT stop-on-error requirement" = 'StopOnError=true'
    "OCCT stop-on-WHEA requirement" = 'StopOnWheaError=true'
    "OCCT temperature-stop requirement" = 'temperature stop enabled at or below'
    "OCCT Tctl UI telemetry" = 'CPU (Tctl)'
    "OCCT TSI UI telemetry" = 'CPU Package (TSI)'
    "conservative multi-source CPU guard" = 'conservative maximum across available socket/Tctl/TSI sources'
    "null storage counters remain unavailable" = 'Null reliability counters mean unavailable, not zero'
}

foreach ($check in $requiredSafetyPatterns.GetEnumerator()) {
    if ($runnerText -notlike ("*" + $check.Value + "*")) {
        throw "Missing hardware-validation safety guard: $($check.Key)"
    }
}

if ($runnerText -match '\(\$_\.Manufacturer -as \[string\]\)\.Trim\(\)' -or
    $runnerText -match '\(\$_\.PartNumber -as \[string\]\)\.Trim\(\)') {
    throw "SMBIOS memory strings are not null-safe."
}

Write-Host "PASS: PowerShell parser accepted DadLAN-HardwareValidation.ps1"
Write-Host "PASS: required diagnostic definitions are present"
Write-Host "PASS: critical guided-load safety guards are present"

if ($RunBaseline) {
    Write-Host "Running read-only baseline smoke test..."
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Mode Baseline -DryRun
    if ($LASTEXITCODE -ne 0) {
        throw "Baseline smoke test returned exit code $LASTEXITCODE"
    }
    Write-Host "PASS: baseline smoke test completed"
}
