# Failure-injection tests: no OCCT, hardware load, driver or firmware changes.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$runner=Join-Path $PSScriptRoot 'DadLAN-HardwareValidation.ps1'
$helper=Join-Path $PSScriptRoot 'DadLAN-HardwareSafety.ps1'
foreach($file in @($runner,$helper)) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($errors | Out-String)}
    # Load functions only, never execute the runner's top-level collection/load path.
    foreach($fn in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
        . ([scriptblock]::Create($fn.Extent.Text))
    }
}
$temp=Join-Path $env:TEMP ('DadLAN-safety-tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$CpuAbortC=70; $GpuAbortC=85; $SsdAbortC=60; $SampleSeconds=1
$AllowFallbackTemperature=$true; $Interactive=$true; $DryRun=$false
$OcctPath='unused'; $OcctConfigPath=Join-Path $temp 'occt.json'
$SensorSnapshotPath=''; $EvidenceManifestPath=''
$script:Inventory=[pscustomobject]@{Motherboard=[pscustomobject]@{Product='CROSSHAIR V FORMULA-Z'};CPU=@([pscustomobject]@{Name='AMD FX-6300'})}
$script:OutDir=$temp; $script:SensorProvider='Test'; $script:Stopped=0; $script:Calls=0
function Assert($Condition,[string]$Message) { if(-not $Condition){throw $Message} }
function Check([string]$Name,[scriptblock]$Body) { & $Body; Write-Host "PASS: $Name" }
function Make-Sample([double]$Cpu=35,[double]$Gpu=40) {
    $sensors=@(
        [pscustomobject]@{SensorType='Temperature';HardwareType='Cpu';HardwareName='CPU';SensorName='Package';Identifier='/cpu/0/temperature/0';Value=$Cpu;Source='Test'},
        [pscustomobject]@{SensorType='Temperature';HardwareType='GpuAmd';HardwareName='GPU';SensorName='Core';Identifier='/gpu-amd/0/temperature/0';Value=$Gpu;Source='Test'}
    )
    [pscustomobject]@{Sensors=$sensors;Temperatures=(Get-DadLANTemperatureState $sensors);Usage=[pscustomobject]@{CpuLoadPercent=80;RamUsedPercent=60}}
}
function Get-Process { @() }
function Find-Occt { 'not-launched.exe' }
function Read-Host { 'READY' }
function Start-GuidedTool {
    $job=[pscustomobject]@{HasExited=$false;WatchdogExpired=$false}
    $job | Add-Member ScriptMethod Touch {}
    $job
}
function Stop-GuidedTool($Process) { if($null -ne $Process){$script:Stopped++} }
function Get-OcctSafetySettings { [pscustomobject]@{TemperatureLimit=60} }

Check 'missing sensor never becomes zero or PASS' {
    $before=Make-Sample; $required=@(Get-TemperatureContract $before 'CPU/RAM')
    $after=Make-Sample; $after.Sensors=@($after.Sensors | Where-Object {$_.Identifier -notmatch '^/cpu'})
    $after.Temperatures=Get-DadLANTemperatureState $after.Sensors
    $caught=$false;try{Assert-TemperatureContract $after $required 'CPU/RAM'}catch{$caught=$true}
    Assert $caught 'Missing CPU sensor was accepted'
}
Check 'null, NaN and infinity rejected' {
    foreach($value in @($null,[double]::NaN,[double]::PositiveInfinity)) { Assert (-not (Test-FiniteTemperature $value)) 'Invalid temperature accepted' }
}
Check 'GPU memory utilization cannot qualify as GPU core load' {
    $sensor=[pscustomobject]@{SensorType='Load';Identifier='/gpu-amd/0/load/1';SensorName='GPU Memory';Value=99}
    Assert ($null -eq (Get-DadLANGpuLoad @($sensor))) 'Memory occupancy qualified as load'
    $sensor.SensorName='GPU Core';Assert ((Get-DadLANGpuLoad @($sensor)) -eq 99) 'Core load rejected'
}
Check 'CPU and socket independently retained and guarded' {
    $s=Make-Sample 30
    $s.Sensors += [pscustomobject]@{SensorType='Temperature';HardwareType='SuperIO';HardwareName='ITE';SensorName='Temperature #1';Identifier='/lpc/it8721f/0/temperature/0';Value=61;Source='LHM'}
    $s.Temperatures=Get-DadLANTemperatureState $s.Sensors
    Assert ($s.Temperatures.CpuReadings.Count -eq 2) 'Lost one CPU reading'
    Assert ([bool](Test-ThermalAbort $s)) 'Socket fallback limit ignored'
    Assert ($s.Temperatures.CpuTrust -eq 'ProfileFallback') 'Fallback promoted'
}
Check 'unexpected monitoring exception stops owned job' {
    $script:Stopped=0; $script:Calls=0
    function Add-DadLANTelemetrySample { $script:Calls++; if($script:Calls -ge 3){throw 'Injected CIM failure'}; Make-Sample }
    $r=Invoke-GuidedOcctStage 'CPU/RAM' 1
    Assert ($r.Result -eq 'INCOMPLETE' -and $r.Reason -match 'Injected CIM') 'Exception not incomplete'
    Assert ($script:Stopped -eq 1) 'Job was not stopped in finally'
}
Check 'temperature dropout after launch stops job immediately' {
    $script:Stopped=0;$script:Calls=0
    function Add-DadLANTelemetrySample {
        $script:Calls++;$s=Make-Sample
        if($script:Calls -ge 3){$s.Sensors[0].Value=$null;$s.Temperatures=Get-DadLANTemperatureState $s.Sensors}
        $s
    }
    $r=Invoke-GuidedOcctStage 'CPU/RAM' 1
    Assert ($r.Result -eq 'INCOMPLETE') 'Dropout passed'
    Assert ($script:Stopped -eq 1 -and $script:Calls -eq 3) 'Dropout was not immediate'
}
Check 'thermal trip stops job and returns FAIL' {
    $script:Stopped=0;$script:Calls=0
    function Add-DadLANTelemetrySample { $script:Calls++; if($script:Calls -ge 3){Make-Sample 75}else{Make-Sample} }
    $r=Invoke-GuidedOcctStage 'CPU/RAM' 1
    Assert ($r.Result -eq 'FAIL' -and $script:Stopped -eq 1) 'Thermal abort failed'
}
Check 'early launcher exit stops descendants and is INCOMPLETE' {
    $script:Stopped=0
    function Add-DadLANTelemetrySample { Make-Sample }
    function Start-GuidedTool { [pscustomobject]@{HasExited=$true;WatchdogExpired=$false} }
    $r=Invoke-GuidedOcctStage 'CPU/RAM' 1
    Assert ($r.Result -eq 'INCOMPLETE' -and $script:Stopped -eq 1) 'Early exit escaped cleanup'
}
Check 'dry run launches nothing and asks no questions' {
    $DryRun=$true
    function Start-GuidedTool { throw 'Launch forbidden' }
    function Read-Host { throw 'Prompt forbidden' }
    $r=Invoke-GuidedOcctStage 'CPU/RAM' 1
    Assert ($r.Result -eq 'INCOMPLETE' -and $r.Reason -match 'Dry run') 'DryRun failed'
}
Check 'cooldown timeout is INCOMPLETE' {
    $CooldownMinutes=0.0001;$script:BaselineSample=Make-Sample
    function Add-DadLANTelemetrySample { Make-Sample 50 55 }
    function Start-Sleep { [Threading.Thread]::Sleep(5) }
    $r=Invoke-Cooldown
    Assert ($r.Result -eq 'INCOMPLETE') 'Cooldown timeout passed'
}
Check 'cooldown missing baseline or sensor is INCOMPLETE' {
    $CooldownMinutes=1;$script:BaselineSample=$null
    $r=Invoke-Cooldown;Assert ($r.Result -eq 'INCOMPLETE') 'Missing baseline passed'
    $script:BaselineSample=Make-Sample
    function Add-DadLANTelemetrySample { $s=Make-Sample;$s.Sensors=@();$s.Temperatures=Get-DadLANTemperatureState @();$s }
    $r=Invoke-Cooldown;Assert ($r.Result -eq 'INCOMPLETE') 'Cooldown dropout passed'
}
Check 'successful cooldown requires measured return to baseline' {
    $CooldownMinutes=1;$script:BaselineSample=Make-Sample
    function Add-DadLANTelemetrySample { Make-Sample 37 42 }
    $r=Invoke-Cooldown;Assert ($r.Result -eq 'PASS') 'Valid cooldown rejected'
}
Check 'GuidedFull blocks GPU on non-PASS CPU or cooldown' {
    $Mode='GuidedFull';$CpuRamMinutes=1;$GpuMinutes=1
    foreach($bad in @('FAIL','WARN','INCOMPLETE')) {
        function Invoke-GuidedOcctStage($TestName,$Minutes) { if($TestName -eq 'GPU'){throw 'GPU launched'};[pscustomobject]@{Name=$TestName;Result=$bad} }
        function Invoke-Cooldown { throw 'Cooldown should be skipped' }
        $r=@(Invoke-RequestedLoadStages);Assert ($r[-1].Result -eq 'INCOMPLETE') 'CPU gating failed'
    }
    function Invoke-GuidedOcctStage($TestName,$Minutes) { if($TestName -eq 'GPU'){throw 'GPU launched'};[pscustomobject]@{Name=$TestName;Result='PASS'} }
    function Invoke-Cooldown { [pscustomobject]@{Name='Cooldown';Result='INCOMPLETE'} }
    $r=@(Invoke-RequestedLoadStages);Assert ($r[-1].Result -eq 'INCOMPLETE') 'Cooldown gating failed'
}
Check 'nullable SMBIOS fields preserve partial inventory' {
    function Get-CimInstance($ClassName) {
        switch($ClassName) {
            'Win32_ComputerSystem' {[pscustomobject]@{Manufacturer='';Model='';TotalPhysicalMemory=1GB}}
            'Win32_OperatingSystem' {[pscustomobject]@{Caption='Windows';Version='';BuildNumber=''}}
            'Win32_BaseBoard' {[pscustomobject]@{Manufacturer='';Product='';Version=''}}
            'Win32_BIOS' {[pscustomobject]@{Manufacturer='';SMBIOSBIOSVersion='';ReleaseDate=$null}}
            'Win32_PhysicalMemory' {[pscustomobject]@{DeviceLocator='';Manufacturer=$null;PartNumber=$null;Capacity=1GB;Speed=0;ConfiguredClockSpeed=0}}
            'Win32_DiskDrive' {[pscustomobject]@{Model=$null;SerialNumber=$null;FirmwareRevision='';Size=1GB;Status='OK'}}
            default {@()}
        }
    }
    $i=Get-DadLANInventory;Assert ($null -eq $i.RAM[0].Manufacturer -and $null -eq $i.RAM[0].PartNumber) 'Null memory crash'
    Assert ($null -eq $i.Storage[0].Model) 'Null storage crash'
}
# Restore actual helper functions for configuration, adapter and native job tests.
. $helper
Check 'disabled and malformed OCCT safety profiles are refused' {
    foreach($bad in @($false,'true',$null)) {
        @{IsTemperatureAlertValueEnabled=$true;StopOnError=$bad;StopOnWheaError=$true;TemperatureAlertValue=60} | ConvertTo-Json | Set-Content $OcctConfigPath
        $caught=$false;try{Get-OcctSafetySettings $OcctConfigPath 60 | Out-Null}catch{$caught=$true}
        Assert $caught 'Unsafe OCCT profile accepted'
    }
    @{IsTemperatureAlertValueEnabled=$true;StopOnError=$true;StopOnWheaError=$true;TemperatureAlertValue=90} | ConvertTo-Json | Set-Content $OcctConfigPath
    $caught=$false;try{Get-OcctSafetySettings $OcctConfigPath 60 | Out-Null}catch{$caught=$true}
    Assert $caught 'Excessive OCCT limit accepted'
    @{IsTemperatureAlertValueEnabled=$true;StopOnError=$true;StopOnWheaError=$true;TemperatureAlertValue=60} | ConvertTo-Json | Set-Content $OcctConfigPath
    Assert ((Get-OcctSafetySettings $OcctConfigPath 60).ErrorStop) 'Valid profile rejected'
}
Check 'stale OCCT sensor snapshot is refused' {
    $SensorSnapshotPath=Join-Path $temp 'sensors.json'
    function Get-DadLANPrimarySensors {@()}
    @{SchemaVersion=1;ComputerName=$env:COMPUTERNAME;CapturedAt=(Get-Date).AddMinutes(-1).ToString('o');Sensors=@()} | ConvertTo-Json | Set-Content $SensorSnapshotPath
    $caught=$false;try{Get-DadLANSensors | Out-Null}catch{$caught=$true}
    Assert $caught 'Stale snapshot accepted'
}
Check 'imported confidence labels retained and invalid labels refused' {
    $EvidenceManifestPath=Join-Path $temp 'facts.json'
    @{SchemaVersion=1;ComputerName=$env:COMPUTERNAME;Facts=@(@{Name='Cooler';Status='UNKNOWN';Source='Physical inspection pending';Value=$null})} | ConvertTo-Json -Depth 5 | Set-Content $EvidenceManifestPath
    $facts=@(Import-DadLANEvidence);Assert ($facts[0].Status -eq 'UNKNOWN') 'Evidence label changed'
    @{SchemaVersion=1;ComputerName=$env:COMPUTERNAME;Facts=@(@{Name='Cooler';Status='PASS';Source='Guess';Value='Seidon'})} | ConvertTo-Json -Depth 5 | Set-Content $EvidenceManifestPath
    $caught=$false;try{Import-DadLANEvidence | Out-Null}catch{$caught=$true};Assert $caught 'Invalid label accepted'
}
Check 'native job terminates harmless child tree on Dispose' {
    Initialize-GuidedJobType
    $childPidFile=Join-Path $temp 'child.pid'
    $command="`$p=Start-Process powershell.exe -ArgumentList '-NoProfile -Command Start-Sleep -Seconds 120' -WindowStyle Hidden -PassThru; Set-Content -LiteralPath '$childPidFile' -Value `$p.Id; Start-Sleep -Seconds 120"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $job=New-Object DadLAN.SafeJob((Join-Path $PSHOME 'powershell.exe'),"-NoProfile -WindowStyle Hidden -EncodedCommand $encoded",15)
    try {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        while(-not (Test-Path $childPidFile) -and $watch.Elapsed.TotalSeconds -lt 10){[Threading.Thread]::Sleep(100)}
        Assert (Test-Path $childPidFile) 'Harmless child did not launch'
        $childId=[int](Get-Content $childPidFile);$parentId=$job.Process.Id
    } finally {$job.Dispose()}
    [Threading.Thread]::Sleep(300)
    Assert ($null -eq (Microsoft.PowerShell.Management\Get-Process -Id $childId -ErrorAction SilentlyContinue)) 'Child survived job disposal'
    Assert ($null -eq (Microsoft.PowerShell.Management\Get-Process -Id $parentId -ErrorAction SilentlyContinue)) 'Parent survived job disposal'
}
Check 'native watchdog kills harmless process when sampling stalls' {
    $job=New-Object DadLAN.SafeJob((Join-Path $PSHOME 'powershell.exe'),'-NoProfile -WindowStyle Hidden -Command Start-Sleep -Seconds 120',1)
    try {[Threading.Thread]::Sleep(2000);Assert ($job.WatchdogExpired -and $job.HasExited) 'Watchdog did not terminate job'} finally {$job.Dispose()}
}
Write-Host "All safety regression checks passed. Test artifacts: $temp"
