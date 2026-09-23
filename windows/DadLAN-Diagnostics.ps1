# DadLAN-Diagnostics.ps1
# Contains predefined DadLAN diagnostic definitions.
#
# Every Action1 job remains a named, bounded diagnostic. There is intentionally
# no arbitrary PowerShell textbox or generic "run command" action.

$script:DadLANDiagnostics = [ordered]@{
    "System Snapshot" = [pscustomobject]@{
        PackageId = "REPLACE_WITH_SYSTEM_SNAPSHOT_PKG_ID"
        PollSeconds = 75
        Description = "Read-only hostname, uptime, CPU/RAM, disk and tool-presence snapshot."
        Interactive = $false
    }

    "Hardware Validation (Safe Baseline)" = [pscustomobject]@{
        PackageId = "REPLACE_WITH_HARDWARE_VALIDATION_PKG_ID"
        PollSeconds = 180
        Description = "Read-only hardware inventory, LibreHardwareMonitor telemetry where available, and Windows storage-health checks. No stress test is started remotely."
        Interactive = $false
    }
}

function Get-DadLANDiagnosticList {
    return $script:DadLANDiagnostics.Keys
}

function Get-DadLANDiagnosticDefinition {
    param([string]$ActionName)
    return $script:DadLANDiagnostics[$ActionName]
}

function Get-DadLANDiagnosticPackageId {
    param([string]$ActionName)
    $definition = Get-DadLANDiagnosticDefinition -ActionName $ActionName
    if ($definition) { return $definition.PackageId }
    return $null
}

function Get-DadLANDiagnosticPollSeconds {
    param([string]$ActionName)
    $definition = Get-DadLANDiagnosticDefinition -ActionName $ActionName
    if ($definition -and $definition.PollSeconds) { return [int]$definition.PollSeconds }
    return 75
}

function Get-DadLANDiagnosticDescription {
    param([string]$ActionName)
    $definition = Get-DadLANDiagnosticDefinition -ActionName $ActionName
    if ($definition -and $definition.Description) { return [string]$definition.Description }
    return ""
}

# Package payload guidance
# ------------------------
# System Snapshot:
# Keep the existing read-only snapshot package.
#
# Hardware Validation (Safe Baseline):
# Upload windows/DadLAN-HardwareValidation.ps1 to the Action1 Software Repository
# and configure the package to invoke it with its default parameters. The default
# mode is Baseline, so an Action1 deployment will NOT start OCCT or any load test.
#
# Full guided validation is intentionally local/interactive:
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DadLAN-HardwareValidation.ps1 -Mode GuidedFull -Interactive
#
# On older systems where only an explicitly accepted fallback CPU/socket sensor is
# available, add -AllowFallbackTemperature. The script records that lower-confidence
# sensor source in the report and uses a more conservative guard for the known
# Crosshair V Formula-Z / FX-6300 profile.
