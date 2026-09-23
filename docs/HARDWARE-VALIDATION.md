# DadLAN Hardware Validation

Status: **v0.4.0-dev preview**

DadLAN Hardware Validation extends the existing Action1 Command Centre instead of creating a separate burn-in application.

## Architecture

- **Action1 Command Centre** remains the remote execution and history owner.
- **DadLAN-HardwareValidation.ps1** performs Windows inventory, telemetry capture, storage-health checks and guided validation.
- **LibreHardwareMonitor** is the preferred Windows sensor provider, via its WMI namespace when available or its local DLL when installed.
- **OCCT** remains the load generator for guided testing.
- The script does not invent unsupported OCCT command-line arguments. Consumer OCCT testing is operator-started.
- **DadLAN Control Centre** can consume the resulting Action1 history and report files later.

## Safety model

The default mode is `Baseline`. This is the mode intended for Action1 deployment and it does **not** start a stress test.

Guided testing must be started locally with `-Interactive`. CPU/RAM and GPU are tested in separate stages. The runner never deliberately starts a combined CPU+GPU power test.

Default abort guards:

- CPU: 70 C
- GPU: 85 C
- SSD: 60 C

If a trustworthy CPU temperature is unavailable, CPU/RAM testing is marked `INCOMPLETE` rather than guessed. A fallback may be explicitly accepted with `-AllowFallbackTemperature`. For the known Crosshair V Formula-Z / FX-6300 sensor layout, the IT8721F Temperature #1 reading is treated only as an **unverified fallback guard** and its effective limit is capped at 60 C.

Some old motherboards expose incorrectly scaled voltage labels through LibreHardwareMonitor. DadLAN does not use generic motherboard voltage labels as automatic safety decisions.

## Results

Every stage returns one of:

- `PASS` — requested evidence was collected and the stage completed without a detected problem.
- `WARN` — the stage completed but some evidence is weaker or incomplete.
- `FAIL` — an abort threshold, operator-reported OCCT error, unhealthy disk state or other definite failure occurred.
- `INCOMPLETE` — DadLAN cannot prove the requested test actually ran or cannot monitor it safely.

`INCOMPLETE` is intentionally different from `PASS`.

## Output

Each run writes a timestamped folder under:

```text
C:\ProgramData\DadLAN\HardwareValidation\
```

Files include:

- `report.json` — complete structured report
- `summary.txt` — concise human-readable result
- `telemetry.csv` — timestamped sensor/load samples
- `events.json` — orchestration and abort events

The console also prints a compact JSON result between:

```text
DADLAN_VALIDATION_BEGIN
...
DADLAN_VALIDATION_END
```

This is suitable for Action1 stdout capture.

## Action1 baseline deployment

Upload `windows/DadLAN-HardwareValidation.ps1` as a predefined Action1 Software Repository package and configure:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File DadLAN-HardwareValidation.ps1
```

No parameters are required because `Baseline` is the safe default.

Then replace:

```text
REPLACE_WITH_HARDWARE_VALIDATION_PKG_ID
```

in `windows/DadLAN-Diagnostics.ps1` with the package ID.

## Local guided validation

Run PowerShell as Administrator:

```powershell
cd windows
.\DadLAN-HardwareValidation.ps1 -Mode GuidedFull -Interactive
```

The sequence is:

1. baseline inventory and sensors
2. operator-started OCCT CPU + RAM test
3. automatic telemetry and threshold monitoring
4. cooldown
5. operator-started OCCT GPU-only test
6. automatic telemetry and threshold monitoring
7. Windows storage-health checks
8. structured report

DadLAN closes the OCCT process when a monitored interval finishes or when a thermal abort occurs. The operator confirms whether OCCT displayed zero errors because v0.4-dev does not parse OCCT's internal result database.

### Older systems with fallback-only CPU telemetry

Only when you knowingly accept the lower-confidence sensor:

```powershell
.\DadLAN-HardwareValidation.ps1 -Mode GuidedFull -Interactive -AllowFallbackTemperature
```

The report records the sensor source and confidence. It does not silently promote a fallback sensor to a trusted CPU package temperature.

## Individual stages

CPU/RAM only:

```powershell
.\DadLAN-HardwareValidation.ps1 -Mode CpuRamGuide -Interactive
```

GPU only:

```powershell
.\DadLAN-HardwareValidation.ps1 -Mode GpuGuide -Interactive
```

Read-only dry run:

```powershell
.\DadLAN-HardwareValidation.ps1 -Mode GuidedFull -Interactive -DryRun
```

## Current v0.4-dev limitations

- Consumer OCCT still requires the operator to click **Start**.
- OCCT's internal error count is operator-confirmed rather than automatically parsed.
- Action1 deployments run the safe baseline only; interactive stress tests are not attempted in the non-interactive SYSTEM session.
- A Windows in-OS RAM churn test is deliberately not presented as equivalent to MemTest86/86+.
- PSU ripple/electrical health, exact AIO coolant condition and physical component identity cannot be established by software.
- Exact case/cooler/PSU model identification still requires physical evidence.

## Relationship to Fedora Crash Doctor

The design deliberately reuses principles already proven in Fedora Crash Doctor:

- explicit bounded tests
- independent stages instead of one giant torture test
- progress/evidence capture
- clear abort conditions
- separate `PASS`, `WARN`, `FAIL` and incomplete evidence states
- no arbitrary command execution

The Windows implementation uses existing Windows tools rather than attempting to transplant `stress-ng`.
