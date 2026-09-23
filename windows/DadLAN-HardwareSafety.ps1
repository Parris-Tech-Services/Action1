# Safety helpers. Loading this file does not start a process or change hardware.

function Test-FiniteTemperature {
    param($Value)
    return ($null -ne $Value -and $Value -is [ValueType] -and
        -not [double]::IsNaN([double]$Value) -and -not [double]::IsInfinity([double]$Value) -and
        [double]$Value -ge -20 -and [double]$Value -le 150)
}

function Get-DadLANSensors {
    $rows = @(Get-DadLANPrimarySensors)
    foreach ($row in $rows) {
        $row | Add-Member NoteProperty Source $script:SensorProvider -Force
        $row | Add-Member NoteProperty ObservedAt ((Get-Date).ToString('o')) -Force
        $row | Add-Member NoteProperty Confidence 'ProviderReported' -Force
    }
    $rows += @(Get-OwnedOcctTemperatures)
    if ($SensorSnapshotPath) {
        # Optional adapter contract, NOT a reader of historical OCCT reports.
        $snapshot = Get-Content -LiteralPath $SensorSnapshotPath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($snapshot.SchemaVersion -ne 1 -or $snapshot.ComputerName -ne $env:COMPUTERNAME) {
            throw 'Sensor snapshot schema or computer identity does not match.'
        }
        $age = ([DateTimeOffset]::Now - [DateTimeOffset]::Parse($snapshot.CapturedAt)).TotalSeconds
        if ($age -lt -2 -or $age -gt 10) { throw 'Additional sensor snapshot is stale or future-dated.' }
        foreach ($row in @($snapshot.Sensors)) {
            if ($row.Source -ne 'OCCT' -or $row.SensorType -ne 'Temperature' -or
                $row.SensorName -notin @('CPU (Tctl)', 'CPU Package (TSI)') -or
                $row.Identifier -notmatch '^/occt/cpu/' -or -not (Test-FiniteTemperature $row.Value)) {
                throw 'Invalid OCCT temperature snapshot row.'
            }
            $rows += [pscustomobject]@{
                HardwareName = 'CPU'; HardwareType = 'Cpu'; SensorType = 'Temperature'
                SensorName = $row.SensorName; Identifier = $row.Identifier; Value = [double]$row.Value
                Source = 'OCCT'; ObservedAt = $snapshot.CapturedAt; Confidence = 'ProviderReported'
            }
        }
    }
    return $rows
}

function Get-OwnedOcctTemperatures {
    if (-not (Get-Variable ActiveGuidedJob -Scope Script -ErrorAction SilentlyContinue) -or
        $null -eq $script:ActiveGuidedJob) { return @() }
    Add-Type -AssemblyName UIAutomationClient
    $rows=@()
    foreach ($process in @(Get-Process -Name OCCT,OCCTGUI -ErrorAction SilentlyContinue)) {
        if ($process.MainWindowHandle -eq 0 -or -not $script:ActiveGuidedJob.Owns($process.Id)) { continue }
        $root=[System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
        $condition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Text)
        $nodes=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,$condition)
        $text=@(foreach($node in $nodes){$node.Current.Name})
        if (($text -join '|') -notmatch 'Name\|Value\|Min\|Avg\|Max') { continue }
        foreach ($label in @('CPU (Tctl)','CPU Package (TSI)')) {
            $index=[array]::IndexOf($text,$label)
            # OCCT 17.1.4 monitoring table: Name, current Value, Min, Avg, Max.
            # Reject unknown layouts instead of reading a neighbouring minimum.
            if ($index -lt 0 -or $index+1 -ge $text.Count -or $text[$index+1] -notmatch '^(-?\d+(?:[.,]\d+)?)\s*\u00b0C$') { continue }
            $value=[double]::Parse($Matches[1].Replace(',','.'),[Globalization.CultureInfo]::InvariantCulture)
            if (-not (Test-FiniteTemperature $value)) { throw 'Invalid OCCT UI temperature.' }
            $id=if($label -eq 'CPU (Tctl)'){'tctl'}else{'tsi'}
            $rows += [pscustomobject]@{
                HardwareName='CPU';HardwareType='Cpu';SensorType='Temperature';SensorName=$label
                Identifier="/occt/cpu/$($process.Id)/$id";Value=$value;Source='OCCT-UI'
                ObservedAt=(Get-Date).ToString('o');Confidence='ProviderReported'
            }
        }
    }
    return $rows
}

function Get-TemperatureContract {
    param($Sample, [string]$TestName)
    if ($TestName -eq 'CPU/RAM' -and (-not (Test-FiniteTemperature $Sample.Temperatures.CpuC) -or
        ($Sample.Temperatures.CpuTrust -ne 'Trusted' -and -not $AllowFallbackTemperature))) {
        throw 'No finite CPU temperature with accepted confidence is available.'
    }
    if ($TestName -eq 'GPU' -and -not (Test-FiniteTemperature $Sample.Temperatures.GpuC)) {
        throw 'No finite GPU temperature is available.'
    }
    $guards = @($Sample.Sensors | Where-Object {
        $_.SensorType -eq 'Temperature' -and (Test-FiniteTemperature $_.Value)
    } | ForEach-Object { $_.Identifier })
    if ($guards.Count -eq 0) { throw 'No temperature guards are available.' }
    return $guards
}

function Get-DadLANTemperatureState {
    param([object[]]$Sensors)
    $valid = @($Sensors | Where-Object { $_.SensorType -eq 'Temperature' -and (Test-FiniteTemperature $_.Value) })
    $fx = @($script:Inventory.CPU | Where-Object { $_.Name -match '(?i)AMD.*FX' }).Count -gt 0
    $knownBoard = $script:Inventory.Motherboard.Product -match '(?i)CROSSHAIR V FORMULA-Z'
    $readings = @(foreach ($sensor in $valid) {
        $digital = $sensor.Identifier -match '^/(cpu|amdcpu|intelcpu|occt/cpu)' -or $sensor.HardwareType -eq 'Cpu'
        $profile = $fx -and $knownBoard -and $sensor.Identifier -eq '/lpc/it8721f/0/temperature/0'
        $named = $sensor.SensorName -match '(?i)CPU|Package|Socket|Tctl|Tdie' -and $sensor.Identifier -notmatch '^/gpu'
        if ($digital -or $profile -or $named) {
            $trust = if ($profile) {'ProfileFallback'} elseif ($digital -and $fx) {'FxRelative'} elseif ($digital) {'Trusted'} else {'Fallback'}
            [pscustomobject]@{
                Identifier=$sensor.Identifier; Value=$sensor.Value
                Source="$($sensor.Source): $($sensor.HardwareName) / $($sensor.SensorName)"
                Confidence=$trust; EvidenceStatus='MEASURED'
                AbortC=if($profile){[math]::Min($CpuAbortC,60)}else{$CpuAbortC}
            }
        }
    })
    $cpu = $readings | Sort-Object Value -Descending | Select-Object -First 1
    $gpu = $valid | Where-Object { $_.Identifier -match '^/gpu' } | Sort-Object Value -Descending | Select-Object -First 1
    $ssd = $valid | Where-Object { $_.Identifier -match '^/(ssd|hdd|storage)' } | Sort-Object Value -Descending | Select-Object -First 1
    [pscustomobject]@{
        CpuC=if($cpu){$cpu.Value}else{$null}; CpuSource=if($cpu){$cpu.Source}else{$null}
        CpuTrust=if($cpu){$cpu.Confidence}else{'None'}; CpuReadings=$readings
        GpuC=if($gpu){$gpu.Value}else{$null}; GpuSource=if($gpu){$gpu.Identifier}else{$null}
        SsdC=if($ssd){$ssd.Value}else{$null}; SsdSource=if($ssd){$ssd.Identifier}else{$null}
    }
}

function Assert-TemperatureContract {
    param($Sample, [string[]]$RequiredIdentifiers, [string]$TestName)
    [void](Get-TemperatureContract -Sample $Sample -TestName $TestName)
    foreach ($id in $RequiredIdentifiers) {
        $rows = @($Sample.Sensors | Where-Object { $_.Identifier -eq $id })
        if ($rows.Count -ne 1 -or -not (Test-FiniteTemperature $rows[0].Value)) {
            throw "Required temperature sensor disappeared or became invalid: $id"
        }
    }
}

function Get-OcctSafetySettings {
    param([string]$Path, [double]$MaximumLimit)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'An explicit, readable OCCT configuration is required for guided testing.'
    }
    $settings = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    foreach ($key in @('IsTemperatureAlertValueEnabled', 'StopOnError', 'StopOnWheaError')) {
        if ($settings.$key -isnot [bool] -or $settings.$key -ne $true) {
            throw "OCCT safety setting must be enabled: $key"
        }
    }
    if (-not (Test-FiniteTemperature $settings.TemperatureAlertValue) -or
        $settings.TemperatureAlertValue -le 0 -or $settings.TemperatureAlertValue -gt $MaximumLimit) {
        throw "OCCT temperature stop must be positive and no higher than $MaximumLimit C."
    }
    [pscustomobject]@{
        Path = (Resolve-Path -LiteralPath $Path).Path
        SHA256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        TemperatureLimit = $settings.TemperatureAlertValue
        AllowOcbaseUpload = if($settings.PSObject.Properties.Name -contains 'AllowOcbaseUpload'){$settings.AllowOcbaseUpload}else{$null}
        ErrorStop = $true; WheaStop = $true; TemperatureStop = $true
        EvidenceStatus = 'MEASURED'
        Limitation = 'File checked; operator must verify this is the active OCCT profile.'
    }
}

function Import-DadLANEvidence {
    if (-not $EvidenceManifestPath) { return @() }
    $manifest = Get-Content -LiteralPath $EvidenceManifestPath -Raw | ConvertFrom-Json
    if ($manifest.SchemaVersion -ne 1 -or $manifest.ComputerName -ne $env:COMPUTERNAME) {
        throw 'Evidence manifest schema or computer identity does not match.'
    }
    foreach ($fact in @($manifest.Facts)) {
        if ($fact.Status -notin @('CONFIRMED','MEASURED','INFERRED','UNKNOWN') -or
            [string]::IsNullOrWhiteSpace($fact.Source) -or [string]::IsNullOrWhiteSpace($fact.Name)) {
            throw 'Evidence facts require a valid status, name and source.'
        }
    }
    Copy-Item -LiteralPath $EvidenceManifestPath -Destination (Join-Path $script:OutDir 'imported-evidence.json')
    return @($manifest.Facts)
}

function Initialize-GuidedJobType {
    if ('DadLAN.SafeJob' -as [type]) { return }
    # The suspended launch removes the spawn/assignment race. Kill-on-close
    # contains descendants even if OCCT's bootstrap executable exits early.
    # A .NET timer terminates the job if the PowerShell sampling loop stalls.
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
namespace DadLAN {
 public sealed class SafeJob : IDisposable {
  [StructLayout(LayoutKind.Sequential)] struct IO { public ulong a,b,c,d,e,f; }
  [StructLayout(LayoutKind.Sequential)] struct BASIC { public long a,b; public uint flags; public UIntPtr min,max; public uint active; public UIntPtr affinity; public uint priority,scheduling; }
  [StructLayout(LayoutKind.Sequential)] struct LIMIT { public BASIC basic; public IO io; public UIntPtr process,job,peakProcess,peakJob; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct START { public int cb; public string reserved,desktop,title; public uint x,y,xs,ys,xc,yc,fill,flags; public short show,reserved2; public IntPtr data,input,output,error; }
  [StructLayout(LayoutKind.Sequential)] struct INFO { public IntPtr process,thread; public uint pid,tid; }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr a,string n);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr j,int c,IntPtr p,uint n);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr j,IntPtr p);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr j,uint code);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr p,uint code);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool IsProcessInJob(IntPtr p,IntPtr j,out bool result);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcess(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref START si,out INFO pi);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr t);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  readonly object gate=new object(); IntPtr job; Timer timer; long last; bool stopped;
  public Process Process { get; private set; }
  public bool WatchdogExpired { get; private set; }
  public SafeJob(string path, string arguments, int timeoutSeconds) {
   INFO pi=new INFO();
   try {
    job=CreateJobObject(IntPtr.Zero,null); if(job==IntPtr.Zero) throw new Win32Exception();
    LIMIT lim=new LIMIT(); lim.basic.flags=0x2000;
    int size=Marshal.SizeOf(lim); IntPtr p=Marshal.AllocHGlobal(size);
    try { Marshal.StructureToPtr(lim,p,false); if(!SetInformationJobObject(job,9,p,(uint)size)) throw new Win32Exception(); } finally {Marshal.FreeHGlobal(p);}
    START si=new START(); si.cb=Marshal.SizeOf(si);
    if(!CreateProcess(path,new StringBuilder("\""+path+"\" "+arguments),IntPtr.Zero,IntPtr.Zero,false,4,IntPtr.Zero,System.IO.Path.GetDirectoryName(path),ref si,out pi)) throw new Win32Exception();
    if(!AssignProcessToJobObject(job,pi.process)) throw new Win32Exception();
    Process=Process.GetProcessById((int)pi.pid); Touch();
    timer=new Timer(delegate { lock(gate) { if(!stopped && (Stopwatch.GetTimestamp()-Interlocked.Read(ref last))/(double)Stopwatch.Frequency > timeoutSeconds) { WatchdogExpired=true; TerminateJobObject(job,1); stopped=true; } } },null,250,250);
    if(ResumeThread(pi.thread)==0xffffffff) throw new Win32Exception();
   } catch { if(pi.process!=IntPtr.Zero) TerminateProcess(pi.process,1); Dispose(); throw; }
   finally { if(pi.thread!=IntPtr.Zero) CloseHandle(pi.thread); if(pi.process!=IntPtr.Zero) CloseHandle(pi.process); }
  }
  public void Touch() { Interlocked.Exchange(ref last,Stopwatch.GetTimestamp()); }
  public bool Owns(int pid) { using(Process p=Process.GetProcessById(pid)) { bool result; if(!IsProcessInJob(p.Handle,job,out result)) throw new Win32Exception(); return result; } }
  public bool HasExited { get { Process.Refresh(); return Process.HasExited; } }
  public void Dispose() { lock(gate) { if(timer!=null) {timer.Dispose();timer=null;} if(job!=IntPtr.Zero) {TerminateJobObject(job,1);CloseHandle(job);job=IntPtr.Zero;} stopped=true; } }
 }
}
'@
}

function Start-GuidedTool {
    param([string]$Path)
    Initialize-GuidedJobType
    return New-Object DadLAN.SafeJob($Path, '', 15)
}

function Stop-GuidedTool {
    param($Process)
    if ($null -ne $Process) { $Process.Dispose() }
}

function Invoke-Cooldown {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $last = $null
    try {
        $required = @(Get-TemperatureContract -Sample $script:BaselineSample -TestName 'CPU/RAM')
        [void](Get-TemperatureContract -Sample $script:BaselineSample -TestName 'GPU')
        while ($watch.Elapsed.TotalMinutes -lt $CooldownMinutes) {
            $last = Add-DadLANTelemetrySample -Stage 'Cooldown'
            Assert-TemperatureContract $last $required 'CPU/RAM'
            [void](Get-TemperatureContract $last 'GPU')
            $abort = Test-ThermalAbort $last
            if ($abort) { return [pscustomobject]@{Name='Cooldown';Result='FAIL';Reason=$abort} }
            $ready = $true
            foreach ($id in $required) {
                $before = $script:BaselineSample.Sensors | Where-Object { $_.Identifier -eq $id }
                $now = $last.Sensors | Where-Object { $_.Identifier -eq $id }
                if ($now.Value -gt ([double]$before.Value + 7)) { $ready = $false }
            }
            if ($ready) { return [pscustomobject]@{Name='Cooldown';Result='PASS';Reason='All baseline temperature guards returned within 7 C of baseline.'} }
            Start-Sleep -Seconds 5
        }
        return [pscustomobject]@{Name='Cooldown';Result='INCOMPLETE';Reason='Cooldown timed out; next load is blocked.'}
    } catch {
        return [pscustomobject]@{Name='Cooldown';Result='INCOMPLETE';Reason="Cooldown telemetry unavailable: $($_.Exception.Message)"}
    }
}

function Invoke-GuidedOcctStage {
    param([ValidateSet('CPU/RAM','GPU')][string]$TestName, [int]$Minutes)
    $job = $null
    $stage = [ordered]@{Name=$TestName;Result='INCOMPLETE';Reason='Stage did not complete.';RequestedMinutes=$Minutes}
    try {
        if ($DryRun) { $stage.Reason='Dry run: no OCCT launch or operator prompts.'; return [pscustomobject]$stage }
        if (-not $Interactive) { throw 'Local Interactive mode is required.' }
        $pre = Add-DadLANTelemetrySample -Stage "$TestName-Preflight"
        $required = @(Get-TemperatureContract $pre $TestName)
        $abort = Test-ThermalAbort $pre
        if ($abort) { $stage.Result='FAIL'; $stage.Reason=$abort; return [pscustomobject]$stage }
        $path = Find-Occt
        if (-not $path) { throw 'OCCT executable was not found; supply -OcctPath.' }
        if (@(Get-Process -Name '*OCCT*' -ErrorAction SilentlyContinue).Count -gt 0) { throw 'Close existing OCCT instances before guided testing.' }
        $limit = [math]::Min([math]::Min((Get-EffectiveCpuAbort $pre.Temperatures),$GpuAbortC),$SsdAbortC)
        $stage.OcctSafety = Get-OcctSafetySettings -Path $OcctConfigPath -MaximumLimit $limit
        if ($stage.OcctSafety.PSObject.Properties.Name -contains 'AllowOcbaseUpload' -and $stage.OcctSafety.AllowOcbaseUpload -eq $true) {
            Write-Warning 'OCCT allows OCBASE upload; review this if local-only evidence is preferred. DadLAN does not change the setting.'
        }
        $answer = Read-Host "Verify the supplied OCCT profile is active, its temperature/error/WHEA stops are enabled, and you are present to observe noise/smell/artifacts. Start ONLY $TestName after launch; NEVER Power/combined load. Record errors during the run; OCCT will close automatically. Type READY"
        if ($answer -cne 'READY') { throw 'Operator did not confirm safety configuration and attendance.' }
        # Recheck after the prompt; no potentially unbounded prompt is allowed under load.
        $stage.OcctSafety = Get-OcctSafetySettings -Path $OcctConfigPath -MaximumLimit $limit
        $pre = Add-DadLANTelemetrySample -Stage "$TestName-LaunchGuard"
        Assert-TemperatureContract $pre $required $TestName
        $abort = Test-ThermalAbort $pre
        if ($abort) { $stage.Result='FAIL'; $stage.Reason=$abort; return [pscustomobject]$stage }
        $stage.TemperatureEvidence = $pre.Temperatures
        $stage.Started = (Get-Date).ToString('o')
        if (@(Get-Process -Name '*OCCT*' -ErrorAction SilentlyContinue).Count -gt 0) { throw 'OCCT appeared during preflight; close it and retry.' }
        $job = Start-GuidedTool -Path $path
        $script:ActiveGuidedJob=$job
        $startup = [Diagnostics.Stopwatch]::StartNew()
        $run = $null; $qualified=0; $total=0
        $baselineRam = $pre.Usage.RamUsedPercent
        while ($null -eq $run -or $run.Elapsed.TotalMinutes -lt $Minutes) {
            if ($job.WatchdogExpired) { throw 'Telemetry watchdog expired; owned process tree was terminated.' }
            if ($job.HasExited) { throw 'OCCT launcher exited early; stage cannot prove completion.' }
            $sample = Add-DadLANTelemetrySample -Stage $TestName
            Assert-TemperatureContract $sample $required $TestName
            # Once an additional OCCT/socket guard is observed, losing it is fatal.
            $required=@($required + @(Get-TemperatureContract $sample $TestName) | Select-Object -Unique)
            $abort = Test-ThermalAbort $sample
            if ($abort) { $stage.Result='FAIL'; $stage.Reason=$abort; return [pscustomobject]$stage }
            if ($job.WatchdogExpired) { throw 'Telemetry watchdog expired during sampling.' }
            $job.Touch()
            $loaded = if ($TestName -eq 'CPU/RAM') {
                $null -ne $sample.Usage.CpuLoadPercent -and $sample.Usage.CpuLoadPercent -ge 70 -and
                $null -ne $baselineRam -and $null -ne $sample.Usage.RamUsedPercent -and
                ($sample.Usage.RamUsedPercent - $baselineRam) -ge 5
            } else { (Get-DadLANGpuLoad $sample.Sensors) -ge 50 }
            if ($null -eq $run -and $loaded) { $run=[Diagnostics.Stopwatch]::StartNew() }
            if ($null -eq $run -and $startup.Elapsed.TotalSeconds -ge 60) { throw 'No qualifying load within the monitored 60-second startup window.' }
            if ($null -ne $run) { $total++; if ($loaded) { $qualified++ } }
            Start-Sleep -Seconds $SampleSeconds
        }
        if ($job.WatchdogExpired -or $job.HasExited) { throw 'OCCT stopped before final verification.' }
        $stage.MonitoredSeconds = $run.Elapsed.TotalSeconds
        $stage.QualifiedLoadSamples=$qualified; $stage.TotalLoadSamples=$total
        Stop-GuidedTool $job
        $script:ActiveGuidedJob=$null
        $job=$null
        if ($total -lt 3 -or ($qualified / [double]$total) -lt 0.9) { throw 'Less than 90% of monitored samples showed the intended load.' }
        $errors = Ask-OcctErrorResult
        $stage.OcctErrorConfirmation=$errors
        if ($errors -eq 'ErrorsReported') { $stage.Result='FAIL'; $stage.Reason='Operator reported OCCT errors.' }
        elseif ($errors -eq 'ZeroErrorsConfirmed') { $stage.Result='PASS'; $stage.Reason='Bounded monitored interval completed; operator reported zero errors. Not a stability certification.' }
        else { $stage.Reason='OCCT error evidence unavailable after shutdown.' }
    } catch {
        $stage.Reason=$_.Exception.Message
    } finally {
        # Covers telemetry exceptions, thermal aborts, early exits and cancellation.
        Stop-GuidedTool $job
        $script:ActiveGuidedJob=$null
    }
    $stage.Finished=(Get-Date).ToString('o')
    return [pscustomobject]$stage
}

function Invoke-RequestedLoadStages {
    $cpu=$null; $cool=$null
    if ($Mode -in @('CpuRamGuide','GuidedFull')) {
        $cpu=Invoke-GuidedOcctStage -TestName 'CPU/RAM' -Minutes $CpuRamMinutes
        $cpu
    }
    if ($Mode -eq 'GuidedFull') {
        if ($cpu.Result -eq 'PASS' -and -not $DryRun) { $cool=Invoke-Cooldown }
        else { $cool=[pscustomobject]@{Name='Cooldown';Result='INCOMPLETE';Reason='CPU/RAM did not pass; no next load permitted.'} }
        $cool
    }
    if ($Mode -eq 'GpuGuide' -or ($Mode -eq 'GuidedFull' -and $cool.Result -eq 'PASS')) {
        Invoke-GuidedOcctStage -TestName 'GPU' -Minutes $GpuMinutes
    } elseif ($Mode -eq 'GuidedFull') {
        [pscustomobject]@{Name='GPU';Result='INCOMPLETE';Reason='Skipped because CPU/RAM or cooldown did not pass.'}
    }
}
