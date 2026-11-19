# DadLAN-HardwareValidation.ps1
# v0.4.2-dev - safe Windows hardware validation orchestration.
#
# Remote/Action1-safe default: Baseline
# Guided load testing: run locally with -Mode GuidedFull -Interactive
#
# This script does not change BIOS/UEFI settings, clocks, voltages, drivers,
# firmware, power limits, or memory timings. It never starts a combined CPU+GPU
# power test. OCCT load generation remains operator-started because consumer
# OCCT editions do not expose a stable automation contract DadLAN can rely on.

[CmdletBinding()]
param(
    [ValidateSet("Baseline", "CpuRamGuide", "GpuGuide", "GuidedFull")]
    [string]$Mode = "Baseline",

    [ValidateRange(1, 30)]
    [int]$CpuRamMinutes = 5,

    [ValidateRange(1, 30)]
    [int]$GpuMinutes = 5,

    [ValidateRange(1, 15)]
    [int]$CooldownMinutes = 3,

    [ValidateRange(40, 100)]
    [double]$CpuAbortC = 70,

    [ValidateRange(50, 110)]
    [double]$GpuAbortC = 85,

    [ValidateRange(40, 90)]
    [double]$SsdAbortC = 60,

    [ValidateRange(1, 10)]
    [int]$SampleSeconds = 2,

    [switch]$Interactive,
    [switch]$AllowFallbackTemperature,
    [string]$OcctPath,
    [string]$OcctConfigPath,
    [string]$SensorSnapshotPath,
    [string]$EvidenceManifestPath,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$script:Version = "0.4.2-dev"
$script:Started = Get-Date
$script:Stamp = $script:Started.ToString("yyyyMMdd-HHmmss")
$script:OutDir = Join-Path $env:ProgramData "DadLAN\HardwareValidation\$env:COMPUTERNAME-$script:Stamp"
$script:ReportFile = Join-Path $script:OutDir "report.json"
$script:TelemetryFile = Join-Path $script:OutDir "telemetry.csv"
$script:EventsFile = Join-Path $script:OutDir "events.json"
$script:SummaryFile = Join-Path $script:OutDir "summary.txt"
$script:Telemetry = New-Object System.Collections.ArrayList
$script:Events = New-Object System.Collections.ArrayList
$script:LhmComputer = $null
$script:SensorProvider = "None"
$script:Inventory = $null
$script:BaselineTemps = @{}
$script:BaselineSample = $null
$script:ImportedEvidence = @()

New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null

function Add-DadLANEvent {
    param(
        [string]$Stage,
        [string]$Level,
        [string]$Message,
        $Data = $null
    )

    $entry = [pscustomobject]@{
        Timestamp = (Get-Date).ToString("o")
        Stage = $Stage
        Level = $Level
        Message = $Message
        Data = $Data
    }

    [void]$script:Events.Add($entry)
    Write-Host ("[{0}] [{1}] {2}" -f $Stage, $Level, $Message)
}

function Get-DadLANInventory {
    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $bb = Get-CimInstance Win32_BaseBoard
    $bios = Get-CimInstance Win32_BIOS

    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        Windows = [pscustomobject]@{
            Caption = $os.Caption
            Version = $os.Version
            Build = $os.BuildNumber
        }
        System = [pscustomobject]@{
            Manufacturer = $cs.Manufacturer
            Model = $cs.Model
            TotalRAMGB = [math]::Round([double]$cs.TotalPhysicalMemory / 1GB, 2)
        }
        Motherboard = [pscustomobject]@{
            Manufacturer = $bb.Manufacturer
            Product = $bb.Product
            Version = $bb.Version
        }
        BIOS = [pscustomobject]@{
            Manufacturer = $bios.Manufacturer
            Version = $bios.SMBIOSBIOSVersion
            ReleaseDate = $bios.ReleaseDate
        }
        CPU = @(Get-CimInstance Win32_Processor | ForEach-Object {
            [pscustomobject]@{
                Name = ([string]$_.Name).Trim()
                Cores = $_.NumberOfCores
                LogicalProcessors = $_.NumberOfLogicalProcessors
                MaxClockMHz = $_.MaxClockSpeed
                CurrentClockMHz = $_.CurrentClockSpeed
            }
        })
        RAM = @(Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
            [pscustomobject]@{
                DeviceLocator = $_.DeviceLocator
                Manufacturer = if ($null -ne $_.Manufacturer) { ([string]$_.Manufacturer).Trim() } else { $null }
                PartNumber = if ($null -ne $_.PartNumber) { ([string]$_.PartNumber).Trim() } else { $null }
                CapacityGB = [math]::Round([double]$_.Capacity / 1GB, 2)
                Speed = $_.Speed
                ConfiguredClockSpeed = $_.ConfiguredClockSpeed
            }
        })
        GPU = @(Get-CimInstance Win32_VideoController | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                VideoProcessor = $_.VideoProcessor
                AdapterRAMGB = if ($_.AdapterRAM) { [math]::Round([double]$_.AdapterRAM / 1GB, 2) } else { $null }
                DriverVersion = $_.DriverVersion
                PNPDeviceID = $_.PNPDeviceID
            }
        })
        Storage = @(Get-CimInstance Win32_DiskDrive | ForEach-Object {
            [pscustomobject]@{
                Model = if ($null -ne $_.Model) { ([string]$_.Model).Trim() } else { $null }
                SerialNumber = if ($null -ne $_.SerialNumber) { ([string]$_.SerialNumber).Trim() } else { $null }
                FirmwareRevision = $_.FirmwareRevision
                SizeGB = if ($_.Size) { [math]::Round([double]$_.Size / 1GB, 2) } else { $null }
                Status = $_.Status
            }
        })
    }
}

function Find-LibreHardwareMonitorLibrary {
    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($path in @(
        (Join-Path $PSScriptRoot "LibreHardwareMonitorLib.dll"),
        "C:\Program Files\LibreHardwareMonitor\LibreHardwareMonitorLib.dll",
        "C:\Program Files (x86)\LibreHardwareMonitor\LibreHardwareMonitorLib.dll",
        "C:\Tools\LibreHardwareMonitor\LibreHardwareMonitorLib.dll",
        "C:\DadLAN\Tools\LibreHardwareMonitor\LibreHardwareMonitorLib.dll",
        (Join-Path $HOME "Desktop\LibreHardwareMonitor\LibreHardwareMonitorLib.dll"),
        (Join-Path $HOME "Downloads\LibreHardwareMonitor\LibreHardwareMonitorLib.dll"),
        (Join-Path $HOME "Documents\LibreHardwareMonitor\LibreHardwareMonitorLib.dll")
    )) {
        if ($path) { [void]$candidates.Add($path) }
    }

    try {
        $runningLhm = Get-Process -Name "LibreHardwareMonitor" -ErrorAction Stop | Select-Object -First 1
        if ($runningLhm -and $runningLhm.Path) {
            $runningDir = Split-Path -Parent $runningLhm.Path
            if ($runningDir) {
                [void]$candidates.Insert(0, (Join-Path $runningDir "LibreHardwareMonitorLib.dll"))
            }
        }
    } catch {
    }

    foreach ($path in $candidates | Select-Object -Unique) {
        if ($path -and (Test-Path $path -PathType Leaf)) {
            return $path
        }
    }

    return $null
}

function Initialize-DadLANSensors {
    try {
        $probe = Get-CimInstance -Namespace "root\LibreHardwareMonitor" -ClassName Sensor -ErrorAction Stop | Select-Object -First 1
        if ($probe) {
            $script:SensorProvider = "LibreHardwareMonitor-WMI"
            Add-DadLANEvent "Sensors" "Info" "Using LibreHardwareMonitor WMI sensor provider."
            return
        }
    } catch {
    }

    $dll = Find-LibreHardwareMonitorLibrary
    if (-not $dll) {
        Add-DadLANEvent "Sensors" "Warning" "LibreHardwareMonitor sensors are unavailable. Baseline inventory will continue, but guided stress monitoring will not."
        return
    }

    try {
        Add-Type -Path $dll -ErrorAction Stop
        $computer = New-Object LibreHardwareMonitor.Hardware.Computer
        $computer.IsCpuEnabled = $true
        $computer.IsGpuEnabled = $true
        $computer.IsMemoryEnabled = $true
        $computer.IsMotherboardEnabled = $true
        $computer.IsStorageEnabled = $true
        $computer.Open()
        $script:LhmComputer = $computer
        $script:SensorProvider = "LibreHardwareMonitor-Library"
        Add-DadLANEvent "Sensors" "Info" "Loaded LibreHardwareMonitor library." @{ Path = $dll }
    } catch {
        $blockedByWindows = $false
        try {
            $zone = Get-Item -LiteralPath $dll -Stream Zone.Identifier -ErrorAction Stop
            $blockedByWindows = $null -ne $zone
        } catch {
        }

        $message = if ($blockedByWindows) {
            "LibreHardwareMonitor library is blocked by Windows (Mark-of-the-Web). Unblock the trusted LibreHardwareMonitor files before retrying."
        } else {
            "LibreHardwareMonitor library could not be loaded."
        }

        Add-DadLANEvent "Sensors" "Warning" $message @{
            Path = $dll
            Error = $_.Exception.Message
            MarkOfTheWeb = $blockedByWindows
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
            PSEdition = $PSVersionTable.PSEdition
        }
    }
}

function Get-LhmRows {
    param($Hardware)

    $rows = @()
    # A failed refresh must never reuse the previous, potentially cold value.
    $Hardware.Update()

    foreach ($sensor in @($Hardware.Sensors)) {
        $rows += [pscustomobject]@{
            HardwareName = [string]$Hardware.Name
            HardwareType = [string]$Hardware.HardwareType
            SensorName = [string]$sensor.Name
            SensorType = [string]$sensor.SensorType
            Identifier = [string]$sensor.Identifier
            Value = if ($null -ne $sensor.Value) { [double]$sensor.Value } else { $null }
        }
    }

    foreach ($sub in @($Hardware.SubHardware)) {
        $rows += Get-LhmRows -Hardware $sub
    }

    return $rows
}

function Get-DadLANPrimarySensors {
    if ($script:SensorProvider -eq "LibreHardwareMonitor-WMI") {
        try {
            return @(Get-CimInstance -Namespace "root\LibreHardwareMonitor" -ClassName Sensor -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    HardwareName = [string]$_.Parent
                    HardwareType = ""
                    SensorName = [string]$_.Name
                    SensorType = [string]$_.SensorType
                    Identifier = [string]$_.Identifier
                    Value = if ($null -ne $_.Value) { [double]$_.Value } else { $null }
                }
            })
        } catch {
            throw "LibreHardwareMonitor telemetry failed: $($_.Exception.Message)"
        }
    }

    if ($script:LhmComputer) {
        $rows = @()
        foreach ($hardware in @($script:LhmComputer.Hardware)) {
            $rows += Get-LhmRows -Hardware $hardware
        }
        return $rows
    }

    return @()
}

function Get-DadLANUsage {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpus = @(Get-CimInstance Win32_Processor)
    $cpuLoad = if ($cpus.Count -gt 0) {
        [math]::Round(($cpus | Measure-Object -Property LoadPercentage -Average).Average, 1)
    } else {
        $null
    }

    $totalKB = [double]$os.TotalVisibleMemorySize
    $freeKB = [double]$os.FreePhysicalMemory

    [pscustomobject]@{
        CpuLoadPercent = $cpuLoad
        RamUsedPercent = if ($totalKB -gt 0) { [math]::Round((($totalKB - $freeKB) / $totalKB) * 100, 1) } else { $null }
        RamFreeGB = [math]::Round($freeKB / 1MB, 2)
    }
}



function Get-DadLANGpuLoad {
    param([object[]]$Sensors)

    $loads = @($Sensors | Where-Object {
        $_.SensorType -eq "Load" -and $_.Identifier -match "^/gpu" -and
        $_.SensorName -match '^(GPU Core|D3D 3D|GPU D3D Usage|GPU Utilization)$' -and
        $null -ne $_.Value -and -not [double]::IsNaN([double]$_.Value) -and
        -not [double]::IsInfinity([double]$_.Value)
    })

    if ($loads.Count -eq 0) {
        return $null
    }

    return [double](($loads | Sort-Object Value -Descending | Select-Object -First 1).Value)
}

function Add-DadLANTelemetrySample {
    param([string]$Stage)

    $now = Get-Date
    $sensors = @(Get-DadLANSensors)
    $usage = Get-DadLANUsage
    $temps = Get-DadLANTemperatureState -Sensors $sensors

    foreach ($sensor in $sensors) {
        [void]$script:Telemetry.Add([pscustomobject]@{
            Timestamp = $now.ToString("o")
            Stage = $Stage
            Kind = "Sensor"
            Hardware = $sensor.HardwareName
            Sensor = $sensor.SensorName
            SensorType = $sensor.SensorType
            Identifier = $sensor.Identifier
            Value = $sensor.Value
            Source = $sensor.Source
            ObservedAt = $sensor.ObservedAt
            Confidence = $sensor.Confidence
            EvidenceStatus = 'MEASURED'
        })
    }

    foreach ($item in @(
        [pscustomobject]@{ Name = "CPU Load"; Value = $usage.CpuLoadPercent; Id = "/dadlan/cpu-load" },
        [pscustomobject]@{ Name = "RAM Used"; Value = $usage.RamUsedPercent; Id = "/dadlan/ram-used" }
    )) {
        [void]$script:Telemetry.Add([pscustomobject]@{
            Timestamp = $now.ToString("o")
            Stage = $Stage
            Kind = "Usage"
            Hardware = "System"
            Sensor = $item.Name
            SensorType = "Load"
            Identifier = $item.Id
            Value = $item.Value
            Source = 'Windows CIM'
            ObservedAt = $now.ToString('o')
            Confidence = 'ProviderReported'
            EvidenceStatus = 'MEASURED'
        })
    }

    [pscustomobject]@{
        Sensors = $sensors
        Usage = $usage
        Temperatures = $temps
    }
}

function Get-EffectiveCpuAbort {
    param($TemperatureState)

    if ($TemperatureState.CpuTrust -eq "ProfileFallback") {
        return [math]::Min($CpuAbortC, 60)
    }

    return $CpuAbortC
}

function Test-ThermalAbort {
    param($Sample)

    foreach ($reading in @($Sample.Temperatures.CpuReadings)) {
        if ($reading.Value -ge $reading.AbortC) {
            return "CPU guard $($reading.Source) reached $($reading.Value) C (limit $($reading.AbortC) C)."
        }
    }

    $effectiveCpuAbort = Get-EffectiveCpuAbort -TemperatureState $Sample.Temperatures

    if ($null -ne $Sample.Temperatures.CpuC -and $Sample.Temperatures.CpuC -ge $effectiveCpuAbort) {
        return "CPU/fallback temperature $($Sample.Temperatures.CpuC) C reached the $effectiveCpuAbort C abort limit."
    }

    if ($null -ne $Sample.Temperatures.GpuC -and $Sample.Temperatures.GpuC -ge $GpuAbortC) {
        return "GPU temperature $($Sample.Temperatures.GpuC) C reached the $GpuAbortC C abort limit."
    }

    if ($null -ne $Sample.Temperatures.SsdC -and $Sample.Temperatures.SsdC -ge $SsdAbortC) {
        return "SSD temperature $($Sample.Temperatures.SsdC) C reached the $SsdAbortC C abort limit."
    }

    return $null
}

function Invoke-Baseline {
    try { $sample = Add-DadLANTelemetrySample -Stage "Baseline" } catch {
        return [pscustomobject]@{Name='Baseline';Result='INCOMPLETE';Reason="Inventory collected; telemetry unavailable: $($_.Exception.Message)"}
    }
    $script:BaselineSample = $sample

    $script:BaselineTemps = @{
        CpuC = $sample.Temperatures.CpuC
        GpuC = $sample.Temperatures.GpuC
        SsdC = $sample.Temperatures.SsdC
    }

    [pscustomobject]@{
        Name = "Baseline"
        Result = "PASS"
        Reason = "Baseline inventory and telemetry captured."
        SensorProvider = $script:SensorProvider
        Temperatures = $sample.Temperatures
        Usage = $sample.Usage
    }
}

function Find-Occt {
    if ($OcctPath) {
        if (Test-Path -LiteralPath $OcctPath -PathType Leaf) { return (Resolve-Path -LiteralPath $OcctPath).Path }
        return $null
    }
    $paths = @(
        "C:\Program Files\OCCT\OCCT.exe",
        "C:\Program Files (x86)\OCCT\OCCT.exe",
        "C:\OCCT\OCCT.exe",
        "C:\DadLAN\Tools\OCCT\OCCT.exe"
    )

    $cmd = Get-Command "OCCT.exe" -ErrorAction SilentlyContinue
    if ($cmd) {
        $paths = @($cmd.Source) + $paths
    }

    foreach ($path in $paths | Select-Object -Unique) {
        if ($path -and (Test-Path $path)) {
            return $path
        }
    }

    return $null
}



function Ask-OcctErrorResult {
    $answer = Read-Host "OCCT is now stopped. Did you record ZERO errors for the complete interval? Type Y, N, or U if not recorded"
    if ($answer -match "^(?i)y$") { return "ZeroErrorsConfirmed" }
    if ($answer -match "^(?i)n$") { return "ErrorsReported" }
    return "Unknown"
}





function Invoke-StorageHealth {
    $rows = @()

    if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
        foreach ($disk in @(Get-PhysicalDisk)) {
            $reliability = $null
            try {
                $reliability = Get-StorageReliabilityCounter -PhysicalDisk $disk -ErrorAction Stop
            } catch {
            }

            $rows += [pscustomobject]@{
                FriendlyName = $disk.FriendlyName
                SerialNumber = $disk.SerialNumber
                MediaType = $disk.MediaType
                BusType = $disk.BusType
                HealthStatus = $disk.HealthStatus
                OperationalStatus = @($disk.OperationalStatus)
                SizeGB = [math]::Round([double]$disk.Size / 1GB, 2)
                TemperatureC = if ($reliability) { $reliability.Temperature } else { $null }
                WearPercent = if ($reliability) { $reliability.Wear } else { $null }
                PowerOnHours = if ($reliability) { $reliability.PowerOnHours } else { $null }
                ReadErrorsTotal = if ($reliability) { $reliability.ReadErrorsTotal } else { $null }
                ReadErrorsUncorrected = if ($reliability) { $reliability.ReadErrorsUncorrected } else { $null }
                WriteErrorsTotal = if ($reliability) { $reliability.WriteErrorsTotal } else { $null }
                WriteErrorsUncorrected = if ($reliability) { $reliability.WriteErrorsUncorrected } else { $null }
            }
        }
    }

    $predict = @()
    try {
        $predict = @(Get-CimInstance -Namespace "root\wmi" -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                InstanceName = $_.InstanceName
                PredictFailure = [bool]$_.PredictFailure
                Reason = $_.Reason
            }
        })
    } catch {
    }

    $failure = @($predict | Where-Object { $_.PredictFailure }).Count -gt 0
    $unhealthy = @($rows | Where-Object { $_.HealthStatus -and $_.HealthStatus -ne "Healthy" }).Count -gt 0

    $result = if ($failure -or $unhealthy) { "FAIL" } elseif ($rows.Count -eq 0 -and $predict.Count -eq 0) { "WARN" } else { "PASS" }
    $reason = if ($failure) {
        "A drive reports PredictFailure=True."
    } elseif ($unhealthy) {
        "A physical disk does not report Healthy."
    } elseif ($result -eq "WARN") {
        "Windows did not expose physical disk health or SMART prediction data."
    } else {
        "No Windows storage-health failure indication was detected."
    }

    [pscustomobject]@{
        Name = "Storage"
        Result = $result
        EvidenceClass = "MEASURED"
        Reason = $reason
        Disks = $rows
        SmartPrediction = $predict
        Note = "Null reliability counters mean unavailable, not zero. Healthy telemetry does not guarantee future reliability."
    }
}

function Get-OverallResult {
    param([object[]]$Stages)

    $results = @($Stages | ForEach-Object { $_.Result })
    if ($results -contains "FAIL") { return "FAIL" }
    if ($results -contains "INCOMPLETE") { return "INCOMPLETE" }
    if ($results -contains "WARN") { return "WARN" }
    return "PASS"
}

. (Join-Path $PSScriptRoot 'DadLAN-HardwareSafety.ps1')

try {
    Add-DadLANEvent "Start" "Info" "DadLAN Hardware Validation $script:Version started." @{
        Mode = $Mode
        Interactive = [bool]$Interactive
        DryRun = [bool]$DryRun
    }

    $script:Inventory = Get-DadLANInventory
    $script:ImportedEvidence = @(Import-DadLANEvidence)
    Initialize-DadLANSensors

    $stages = @()
    $baseline = Invoke-Baseline
    $stages += $baseline

    $stages += @(Invoke-RequestedLoadStages)

    $stages += Invoke-StorageHealth

    $overall = Get-OverallResult -Stages $stages
    $finished = Get-Date

    $report = [pscustomobject]@{
        Tool = "DadLAN Hardware Validation"
        Version = $script:Version
        ComputerName = $env:COMPUTERNAME
        Mode = $Mode
        Started = $script:Started.ToString("o")
        Finished = $finished.ToString("o")
        DurationSeconds = [math]::Round(($finished - $script:Started).TotalSeconds, 1)
        OverallResult = $overall
        EvidenceModel = [pscustomobject]@{
            CONFIRMED = 'Direct identity evidence or explicit displayed result.'
            MEASURED = 'Software or sensor observation; limitations remain attached.'
            INFERRED = 'Plausible interpretation that is not independently established.'
            UNKNOWN = 'Insufficient evidence; do not promote to PASS.'
        }
        Safety = [pscustomobject]@{
            CpuAbortC = $CpuAbortC
            GpuAbortC = $GpuAbortC
            SsdAbortC = $SsdAbortC
            AllowFallbackTemperature = [bool]$AllowFallbackTemperature
            CombinedCpuGpuStressAllowed = $false
            BiosOrClockChanges = $false
            LoadGenerator = "Operator-started OCCT only"
            OcctConfigPath = $OcctConfigPath
            OcctConfigIsReadOnly = $true
        }
        SensorProvider = $script:SensorProvider
        Inventory = $script:Inventory
        InventoryEvidenceStatus = 'MEASURED'
        ImportedFacts = $script:ImportedEvidence
        Readiness = 'Not certified: results apply only to recorded observations and bounded intervals.'
        Stages = $stages
        Evidence = [pscustomobject]@{
            ReportJson = $script:ReportFile
            SummaryTxt = $script:SummaryFile
            TelemetryCsv = $script:TelemetryFile
            EventsJson = $script:EventsFile
        }
    }

    $script:Telemetry | Export-Csv -Path $script:TelemetryFile -NoTypeInformation -Encoding UTF8
    $script:Events | ConvertTo-Json -Depth 8 | Set-Content -Path $script:EventsFile -Encoding UTF8
    $report | ConvertTo-Json -Depth 12 | Set-Content -Path $script:ReportFile -Encoding UTF8

    $summary = @(
        "DadLAN Hardware Validation $script:Version",
        "Computer: $env:COMPUTERNAME",
        "Mode: $Mode",
        "Overall: $overall",
        "Sensor provider: $script:SensorProvider",
        "",
        "Stages:"
    )

    foreach ($stage in $stages) {
        $summary += ("- {0}: {1} - {2}" -f $stage.Name, $stage.Result, $stage.Reason)
    }

    $summary += ""
    $summary += "Evidence:"
    $summary += "- $script:ReportFile"
    $summary += "- $script:TelemetryFile"
    $summary += "- $script:EventsFile"
    $summary -join [Environment]::NewLine | Set-Content -Path $script:SummaryFile -Encoding UTF8

    Write-Output ""
    Write-Output "DADLAN_VALIDATION_BEGIN"
    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        Version = $script:Version
        Mode = $Mode
        OverallResult = $overall
        Stages = @($stages | Select-Object Name, Result, Reason)
        Evidence = $report.Evidence
    } | ConvertTo-Json -Depth 6
    Write-Output "DADLAN_VALIDATION_END"
} catch {
    Add-DadLANEvent "Fatal" "Error" $_.Exception.Message

    try {
        $script:Telemetry | Export-Csv -Path $script:TelemetryFile -NoTypeInformation -Encoding UTF8
        $script:Events | ConvertTo-Json -Depth 8 | Set-Content -Path $script:EventsFile -Encoding UTF8
    } catch {
    }

    Write-Output "DADLAN_VALIDATION_BEGIN"
    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        Version = $script:Version
        Mode = $Mode
        OverallResult = "FAIL"
        Error = $_.Exception.Message
        EvidenceDirectory = $script:OutDir
    } | ConvertTo-Json -Depth 6
    Write-Output "DADLAN_VALIDATION_END"
    exit 1
} finally {
    if ($script:LhmComputer) {
        try { $script:LhmComputer.Close() } catch {}
    }
}
