# DadLAN-HardwareValidation.ps1
# v0.4.0-dev - safe Windows hardware validation orchestration.
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
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$script:Version = "0.4.0-dev"
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
$script:ActiveGuidedProcess = $null

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
                Name = $_.Name.Trim()
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
    $candidates = @(
        (Join-Path $PSScriptRoot "LibreHardwareMonitorLib.dll"),
        "C:\Program Files\LibreHardwareMonitor\LibreHardwareMonitorLib.dll",
        "C:\Program Files (x86)\LibreHardwareMonitor\LibreHardwareMonitorLib.dll",
        "C:\Tools\LibreHardwareMonitor\LibreHardwareMonitorLib.dll",
        "C:\DadLAN\Tools\LibreHardwareMonitor\LibreHardwareMonitorLib.dll"
    )

    foreach ($path in $candidates) {
        if ($path -and (Test-Path $path)) {
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
        Add-DadLANEvent "Sensors" "Warning" "LibreHardwareMonitor library could not be loaded." @{ Error = $_.Exception.Message }
    }
}

function Get-LhmRows {
    param($Hardware)

    $rows = @()
    try { $Hardware.Update() } catch {}

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

function Get-DadLANSensors {
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
            return @()
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

function Get-DadLANTemperatureState {
    param([object[]]$Sensors)

    $trustedCpu = @($Sensors | Where-Object {
        $_.SensorType -eq "Temperature" -and
        ($_.Identifier -match "^/cpu" -or $_.HardwareType -match "(?i)cpu")
    })

    $namedCpu = @($Sensors | Where-Object {
        $_.SensorType -eq "Temperature" -and
        $_.SensorName -match "(?i)CPU|Package|Socket|Tctl|Tdie"
    })

    $profileCpu = @()
    $isKnownFxBoard =
        ($script:Inventory.Motherboard.Product -match "(?i)CROSSHAIR V FORMULA-Z") -and
        (($script:Inventory.CPU | Select-Object -First 1).Name -match "(?i)FX.*6300")

    if ($isKnownFxBoard) {
        $profileCpu = @($Sensors | Where-Object {
            $_.SensorType -eq "Temperature" -and
            $_.Identifier -eq "/lpc/it8721f/0/temperature/0"
        })
    }

    $cpuC = $null
    $cpuSource = $null
    $cpuTrust = "None"

    if ($trustedCpu.Count -gt 0) {
        $s = $trustedCpu | Sort-Object Value -Descending | Select-Object -First 1
        $cpuC = $s.Value
        $cpuSource = "$($s.HardwareName) / $($s.SensorName)"
        $cpuTrust = "Trusted"
    } elseif ($namedCpu.Count -gt 0) {
        $s = $namedCpu | Sort-Object Value -Descending | Select-Object -First 1
        $cpuC = $s.Value
        $cpuSource = "$($s.HardwareName) / $($s.SensorName)"
        $cpuTrust = "Fallback"
    } elseif ($profileCpu.Count -gt 0) {
        $s = $profileCpu | Select-Object -First 1
        $cpuC = $s.Value
        $cpuSource = "Crosshair V Formula-Z IT8721F Temperature #1 (unverified CPU/socket fallback)"
        $cpuTrust = "ProfileFallback"
    }

    $gpu = @($Sensors | Where-Object {
        $_.SensorType -eq "Temperature" -and $_.Identifier -match "^/gpu"
    } | Sort-Object Value -Descending) | Select-Object -First 1

    $ssd = @($Sensors | Where-Object {
        $_.SensorType -eq "Temperature" -and $_.Identifier -match "^/(ssd|hdd|storage)"
    } | Sort-Object Value -Descending) | Select-Object -First 1

    [pscustomobject]@{
        CpuC = $cpuC
        CpuSource = $cpuSource
        CpuTrust = $cpuTrust
        GpuC = if ($gpu) { $gpu.Value } else { $null }
        GpuSource = if ($gpu) { "$($gpu.HardwareName) / $($gpu.SensorName)" } else { $null }
        SsdC = if ($ssd) { $ssd.Value } else { $null }
        SsdSource = if ($ssd) { "$($ssd.HardwareName) / $($ssd.SensorName)" } else { $null }
    }
}

function Get-DadLANGpuLoad {
    param([object[]]$Sensors)

    $loads = @($Sensors | Where-Object {
        $_.SensorType -eq "Load" -and $_.Identifier -match "^/gpu"
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
    $sample = Add-DadLANTelemetrySample -Stage "Baseline"

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

function Stop-GuidedTool {
    param($Process)

    if (-not $Process) {
        return
    }

    try {
        if (-not $Process.HasExited) {
            [void]$Process.CloseMainWindow()
            Start-Sleep -Seconds 2
        }
    } catch {
    }

    try {
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        }
    } catch {
    }

    try {
        if ($script:ActiveGuidedProcess -and $script:ActiveGuidedProcess.Id -eq $Process.Id) {
            $script:ActiveGuidedProcess = $null
        }
    } catch {
        $script:ActiveGuidedProcess = $null
    }
}

function Ask-OcctErrorResult {
    $answer = Read-Host "Does OCCT currently show ZERO errors for this monitored interval? Type Y, N, or U for unknown"
    if ($answer -match "^(?i)y") { return "ZeroErrorsConfirmed" }
    if ($answer -match "^(?i)n") { return "ErrorsReported" }
    return "Unknown"
}

function Invoke-GuidedOcctStage {
    param(
        [ValidateSet("CPU/RAM", "GPU")]
        [string]$TestName,
        [int]$Minutes
    )

    $stageStart = Get-Date
    $pre = Add-DadLANTelemetrySample -Stage "$TestName-Preflight"

    if (-not $Interactive) {
        return [pscustomobject]@{
            Name = $TestName
            Result = "INCOMPLETE"
            Reason = "Interactive mode is required for consumer OCCT guided testing."
        }
    }

    if ($script:SensorProvider -eq "None") {
        return [pscustomobject]@{
            Name = $TestName
            Result = "INCOMPLETE"
            Reason = "LibreHardwareMonitor sensors are unavailable, so automatic thermal abort protection is unavailable."
        }
    }

    if ($TestName -eq "CPU/RAM") {
        if ($pre.Temperatures.CpuTrust -eq "None") {
            return [pscustomobject]@{
                Name = $TestName
                Result = "INCOMPLETE"
                Reason = "No CPU temperature or accepted fallback sensor is available."
            }
        }

        if ($pre.Temperatures.CpuTrust -ne "Trusted" -and -not $AllowFallbackTemperature) {
            return [pscustomobject]@{
                Name = $TestName
                Result = "INCOMPLETE"
                Reason = "Only a fallback CPU temperature source is available. Re-run with -AllowFallbackTemperature only if you accept that limitation."
                CpuTemperatureSource = $pre.Temperatures.CpuSource
                CpuTemperatureTrust = $pre.Temperatures.CpuTrust
            }
        }
    }

    if ($TestName -eq "GPU" -and $null -eq $pre.Temperatures.GpuC) {
        return [pscustomobject]@{
            Name = $TestName
            Result = "INCOMPLETE"
            Reason = "No GPU temperature sensor is available."
        }
    }

    $occt = Find-Occt
    if (-not $occt) {
        return [pscustomobject]@{
            Name = $TestName
            Result = "INCOMPLETE"
            Reason = "OCCT executable was not found in known locations."
        }
    }

    if ($DryRun) {
        return [pscustomobject]@{
            Name = $TestName
            Result = "INCOMPLETE"
            Reason = "Dry-run mode; OCCT was not launched."
            OCCTPath = $occt
        }
    }

    $instruction = if ($TestName -eq "CPU/RAM") {
        "In OCCT start a CPU + RAM test only. Do NOT select Power or a combined GPU load."
    } else {
        "In OCCT start a GPU-only test. Do NOT select Power or a combined CPU + GPU test."
    }

    Add-DadLANEvent $TestName "Info" "Launching OCCT. $instruction"
    $proc = Start-Process -FilePath $occt -PassThru
    $script:ActiveGuidedProcess = $proc
    Read-Host "$instruction Once the test is visibly running, press Enter here"

    $deadline = (Get-Date).AddMinutes($Minutes)
    $maxCpuC = $pre.Temperatures.CpuC
    $maxGpuC = $pre.Temperatures.GpuC
    $maxSsdC = $pre.Temperatures.SsdC
    $maxCpuLoad = 0
    $maxGpuLoad = 0
    $maxRamUsed = if ($null -ne $pre.Usage.RamUsedPercent) { [double]$pre.Usage.RamUsedPercent } else { 0 }
    $baselineRamUsed = $maxRamUsed
    $qualifiedLoadSamples = 0
    $requiredQualifiedSamples = [math]::Max(3, [math]::Ceiling(10.0 / $SampleSeconds))
    $exitEarly = $false

    while ((Get-Date) -lt $deadline) {
        if ($proc.HasExited) {
            $exitEarly = $true
            break
        }

        $sample = Add-DadLANTelemetrySample -Stage $TestName

        $requiredTelemetryMissing = $false
        $requiredTelemetryReason = $null
        if ($TestName -eq "CPU/RAM" -and $null -eq $sample.Temperatures.CpuC) {
            $requiredTelemetryMissing = $true
            $requiredTelemetryReason = "Required CPU temperature telemetry disappeared during the guided CPU/RAM stage."
        } elseif ($TestName -eq "GPU" -and $null -eq $sample.Temperatures.GpuC) {
            $requiredTelemetryMissing = $true
            $requiredTelemetryReason = "Required GPU temperature telemetry disappeared during the guided GPU stage."
        }

        if ($requiredTelemetryMissing) {
            Add-DadLANEvent $TestName "Error" $requiredTelemetryReason
            Stop-GuidedTool -Process $proc
            return [pscustomobject]@{
                Name = $TestName
                Result = "INCOMPLETE"
                Reason = $requiredTelemetryReason
                Started = $stageStart.ToString("o")
                Finished = (Get-Date).ToString("o")
                MaxCpuC = $maxCpuC
                MaxGpuC = $maxGpuC
                MaxSsdC = $maxSsdC
                MaxCpuLoadPercent = $maxCpuLoad
                MaxGpuLoadPercent = $maxGpuLoad
                MaxRamUsedPercent = $maxRamUsed
                QualifiedLoadSamples = $qualifiedLoadSamples
            }
        }

        if ($null -ne $sample.Temperatures.CpuC) { $maxCpuC = [math]::Max([double]$maxCpuC, [double]$sample.Temperatures.CpuC) }
        if ($null -ne $sample.Temperatures.GpuC) { $maxGpuC = [math]::Max([double]$maxGpuC, [double]$sample.Temperatures.GpuC) }
        if ($null -ne $sample.Temperatures.SsdC) { $maxSsdC = [math]::Max([double]$maxSsdC, [double]$sample.Temperatures.SsdC) }
        if ($null -ne $sample.Usage.CpuLoadPercent) { $maxCpuLoad = [math]::Max($maxCpuLoad, [double]$sample.Usage.CpuLoadPercent) }
        if ($null -ne $sample.Usage.RamUsedPercent) { $maxRamUsed = [math]::Max($maxRamUsed, [double]$sample.Usage.RamUsedPercent) }

        $gpuLoad = Get-DadLANGpuLoad -Sensors $sample.Sensors
        if ($null -ne $gpuLoad) {
            $maxGpuLoad = [math]::Max($maxGpuLoad, $gpuLoad)
        }

        if ($TestName -eq "CPU/RAM") {
            if ($null -ne $sample.Usage.CpuLoadPercent -and $sample.Usage.CpuLoadPercent -ge 70) {
                $qualifiedLoadSamples++
            }
        } elseif ($null -ne $gpuLoad -and $gpuLoad -ge 50) {
            $qualifiedLoadSamples++
        }

        $thermalAbort = Test-ThermalAbort -Sample $sample
        if ($thermalAbort) {
            Add-DadLANEvent $TestName "Error" $thermalAbort
            Stop-GuidedTool -Process $proc
            return [pscustomobject]@{
                Name = $TestName
                Result = "FAIL"
                Reason = $thermalAbort
                Started = $stageStart.ToString("o")
                Finished = (Get-Date).ToString("o")
                MaxCpuC = $maxCpuC
                MaxGpuC = $maxGpuC
                MaxSsdC = $maxSsdC
                MaxCpuLoadPercent = $maxCpuLoad
                MaxGpuLoadPercent = $maxGpuLoad
                MaxRamUsedPercent = $maxRamUsed
                QualifiedLoadSamples = $qualifiedLoadSamples
            }
        }

        Start-Sleep -Seconds $SampleSeconds
    }

    if ($exitEarly) {
        return [pscustomobject]@{
            Name = $TestName
            Result = "INCOMPLETE"
            Reason = "OCCT exited before the requested monitoring interval completed."
            Started = $stageStart.ToString("o")
            Finished = (Get-Date).ToString("o")
            MaxCpuC = $maxCpuC
            MaxGpuC = $maxGpuC
            MaxSsdC = $maxSsdC
            MaxCpuLoadPercent = $maxCpuLoad
            MaxGpuLoadPercent = $maxGpuLoad
            MaxRamUsedPercent = $maxRamUsed
            QualifiedLoadSamples = $qualifiedLoadSamples
        }
    }

    $loadSufficient = $false
    if ($TestName -eq "CPU/RAM") {
        $ramIncrease = $maxRamUsed - $baselineRamUsed
        $loadSufficient = ($qualifiedLoadSamples -ge $requiredQualifiedSamples) -and ($ramIncrease -ge 5)
    } else {
        $ramIncrease = $null
        $loadSufficient = $qualifiedLoadSamples -ge $requiredQualifiedSamples
    }

    if (-not $loadSufficient) {
        Stop-GuidedTool -Process $proc
        return [pscustomobject]@{
            Name = $TestName
            Result = "INCOMPLETE"
            Reason = if ($TestName -eq "CPU/RAM") {
                "The interval did not show sustained CPU load plus a meaningful RAM-use increase, so DadLAN cannot prove that the intended CPU + RAM test ran."
            } else {
                "The interval did not show sustained GPU load, so DadLAN cannot prove that the intended GPU test ran."
            }
            Started = $stageStart.ToString("o")
            Finished = (Get-Date).ToString("o")
            MaxCpuC = $maxCpuC
            MaxGpuC = $maxGpuC
            MaxSsdC = $maxSsdC
            MaxCpuLoadPercent = $maxCpuLoad
            MaxGpuLoadPercent = $maxGpuLoad
            MaxRamUsedPercent = $maxRamUsed
            BaselineRamUsedPercent = $baselineRamUsed
            RamUsedIncreasePercent = $ramIncrease
            QualifiedLoadSamples = $qualifiedLoadSamples
            RequiredQualifiedSamples = $requiredQualifiedSamples
        }
    }

    Write-Host "Monitoring interval complete. OCCT is still open so you can read its error counter."
    $errorResult = Ask-OcctErrorResult
    Stop-GuidedTool -Process $proc

    $result = "WARN"
    $reason = "The test interval completed, but OCCT error status was not confirmed."

    if ($errorResult -eq "ZeroErrorsConfirmed") {
        $result = "PASS"
        $reason = "The monitored interval completed and the operator confirmed OCCT reported zero errors."
    } elseif ($errorResult -eq "ErrorsReported") {
        $result = "FAIL"
        $reason = "The operator reported OCCT errors."
    }

    [pscustomobject]@{
        Name = $TestName
        Result = $result
        Reason = $reason
        Started = $stageStart.ToString("o")
        Finished = (Get-Date).ToString("o")
        RequestedMinutes = $Minutes
        MaxCpuC = $maxCpuC
        MaxGpuC = $maxGpuC
        MaxSsdC = $maxSsdC
        MaxCpuLoadPercent = $maxCpuLoad
        MaxGpuLoadPercent = $maxGpuLoad
        MaxRamUsedPercent = $maxRamUsed
        BaselineRamUsedPercent = $baselineRamUsed
        RamUsedIncreasePercent = $ramIncrease
        QualifiedLoadSamples = $qualifiedLoadSamples
        RequiredQualifiedSamples = $requiredQualifiedSamples
        CpuTemperatureSource = $pre.Temperatures.CpuSource
        CpuTemperatureTrust = $pre.Temperatures.CpuTrust
        OcctErrorConfirmation = $errorResult
        OCCTPath = $occt
    }
}

function Invoke-Cooldown {
    $start = Get-Date
    $deadline = $start.AddMinutes($CooldownMinutes)
    $last = $null
    $cooled = $false

    Add-DadLANEvent "Cooldown" "Info" "Waiting for temperatures to return near baseline before the next load stage."

    while ((Get-Date) -lt $deadline) {
        $last = Add-DadLANTelemetrySample -Stage "Cooldown"

        $cpuReady = $true
        $gpuReady = $true

        if ($null -ne $script:BaselineTemps.CpuC) {
            $cpuReady = ($null -ne $last.Temperatures.CpuC) -and
                ($last.Temperatures.CpuC -le ([double]$script:BaselineTemps.CpuC + 7))
        }

        if ($null -ne $script:BaselineTemps.GpuC) {
            $gpuReady = ($null -ne $last.Temperatures.GpuC) -and
                ($last.Temperatures.GpuC -le ([double]$script:BaselineTemps.GpuC + 7))
        }

        if ($cpuReady -and $gpuReady) {
            $cooled = $true
            break
        }

        Start-Sleep -Seconds 5
    }

    [pscustomobject]@{
        Name = "Cooldown"
        Result = if ($cooled) { "PASS" } else { "INCOMPLETE" }
        Reason = if ($cooled) {
            "Temperatures returned within 7 C of baseline."
        } else {
            "Cooldown timed out before temperatures returned within 7 C of baseline; the next load stage must not start."
        }
        ReadyForNextLoad = $cooled
        FinalTemperatures = if ($last) { $last.Temperatures } else { $null }
    }
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
        Reason = $reason
        Disks = $rows
        SmartPrediction = $predict
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

try {
    Add-DadLANEvent "Start" "Info" "DadLAN Hardware Validation $script:Version started." @{
        Mode = $Mode
        Interactive = [bool]$Interactive
        DryRun = [bool]$DryRun
    }

    $script:Inventory = Get-DadLANInventory
    Initialize-DadLANSensors

    $stages = @()
    $baseline = Invoke-Baseline
    $stages += $baseline

    if ($Mode -in @("CpuRamGuide", "GuidedFull")) {
        $stages += Invoke-GuidedOcctStage -TestName "CPU/RAM" -Minutes $CpuRamMinutes
    }

    $cooldown = $null
    if ($Mode -eq "GuidedFull") {
        $cooldown = Invoke-Cooldown
        $stages += $cooldown
    }

    if ($Mode -eq "GpuGuide") {
        $stages += Invoke-GuidedOcctStage -TestName "GPU" -Minutes $GpuMinutes
    } elseif ($Mode -eq "GuidedFull") {
        if ($cooldown -and $cooldown.Result -eq "PASS" -and $cooldown.ReadyForNextLoad) {
            $stages += Invoke-GuidedOcctStage -TestName "GPU" -Minutes $GpuMinutes
        } else {
            $reason = "GPU stage skipped because cooldown readiness was not established."
            Add-DadLANEvent "GPU" "Warning" $reason
            $stages += [pscustomobject]@{
                Name = "GPU"
                Result = "INCOMPLETE"
                Reason = $reason
            }
        }
    }

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
        Safety = [pscustomobject]@{
            CpuAbortC = $CpuAbortC
            GpuAbortC = $GpuAbortC
            SsdAbortC = $SsdAbortC
            AllowFallbackTemperature = [bool]$AllowFallbackTemperature
            CombinedCpuGpuStressAllowed = $false
            BiosOrClockChanges = $false
            LoadGenerator = "Operator-started OCCT only"
        }
        SensorProvider = $script:SensorProvider
        Inventory = $script:Inventory
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
    if ($script:ActiveGuidedProcess) {
        try {
            Add-DadLANEvent "Safety" "Warning" "Stopping active guided load generator during final cleanup."
        } catch {
        }
        Stop-GuidedTool -Process $script:ActiveGuidedProcess
    }

    if ($script:LhmComputer) {
        try { $script:LhmComputer.Close() } catch {}
    }
}
