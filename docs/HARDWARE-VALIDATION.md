# DadLAN Hardware Validation

Status: **v0.4.1-dev preview**

DadLAN Hardware Validation extends the existing Action1 Command Centre instead of creating a separate burn-in application.

## Architecture

- **Action1 Command Centre** remains the remote execution and history owner.
- **DadLAN-HardwareValidation.ps1** performs Windows inventory, telemetry capture, storage-health checks and guided validation.
- **LibreHardwareMonitor** is the preferred Windows sensor provider, via its WMI namespace when available or its local DLL when installed.
- **OCCT** remains the load generator for guided testing.
- The script does not invent unsupported OCCT command-line arguments. Consumer OCCT testing is operator-started.
- Before any guided load starts, DadLAN reads the local `OCCT.config.json` and verifies OCCT's own stop-on-error, stop-on-WHEA and critical-temperature protection. DadLAN never changes that configuration automatically.
- **DadLAN Control Centre** can consume the resulting Action1 history and report files later.

## Safety model

The default mode is `Baseline`. This is the mode intended for Action1 deployment and it does **not** start a stress test.

Guided testing must be started locally with `-Interactive`. CPU/RAM and GPU are tested in separate stages. The runner never deliberately starts a combined CPU+GPU power test.

Default abort guards:

- CPU: 70 C
- GPU: 85 C
- SSD: 60 C

A guided stage is marked `INCOMPLETE` and is not started when OCCT's internal safeguards cannot be verified. The OCCT critical-temperature limit must be enabled at or below the DadLAN limit for the stage.

If a trustworthy CPU temperature is unavailable, CPU/RAM testing is marked `INCOMPLETE` rather than guessed. A fallback may be explicitly accepted with `-AllowFallbackTemperature`. For the known Crosshair V Formula-Z / FX-6300 sensor layout, the IT8721F Temperature #1 reading is treated only as an **unverified fallback guard** and its effective limit is capped at 60 C.

v0.4.1-dev also reads OCCT's visible monitoring UI when available. It records `CPU (Tctl)` and `CPU Package (TSI)` as separate measured sources and uses the most conservative available CPU/socket/Tctl/TSI value for the automatic abort guard. Tctl and TSI are not treated as independent corroboration when they expose the same underlying reading.

Some old motherboards expose incorrectly scaled voltage labels through LibreHardwareMonitor. DadLAN does not use generic motherboard voltage labels as automatic safety decisions.

## Results

Reports also carry an evidence class model:

- `CONFIRMED` — direct identity evidence or an explicit displayed result
- `MEASURED` — software/sensor observation with limitations retained
- `INFERRED` — plausible interpretation that is not independently established
- `UNKNOWN` — insufficient evidence; must not be promoted to a pass

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
2. OCCT safety preflight from the local configuration file
3. operator-started OCCT CPU + RAM test
4. automatic LibreHardwareMonitor + OCCT UI telemetry and threshold monitoring
5. cooldown
6. operator-started OCCT GPU-only test
7. automatic telemetry and threshold monitoring
8. Windows storage-health checks
9. structured report

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
- OCCT's internal error count is operator-confirmed rather than automatically parsed. The UI text `No errors detected` is captured as supporting evidence when visible, but is not sufficient by itself for `PASS`.
- If the OCCT config cannot be located or its temperature/error/WHEA stops are disabled, guided stress is refused and the stage is `INCOMPLETE`.
- OCCT's `AllowOcbaseUpload` setting is reported as a privacy warning when enabled; DadLAN does not change it automatically.
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


## Evidence recovered from the first DadLAN validation target

The Crosshair V Formula-Z / FX-6300 / R9 290 investigation provided several design corrections now reflected in the runner:

- the earlier one-minute OCCT CPU+RAM run is preserved as a short displayed result only, not a comprehensive stability pass;
- OCCT exposes `CPU (Tctl)` and `CPU Package (TSI)` on this system, while CPU-Z labels the first ITE board channel `CPU` and the second `Mainboard`;
- those sources are recorded separately because identical Tctl/TSI values do not prove independent agreement and old AMD FX readings can be unreliable near idle;
- the existing OCCT configuration had critical-temperature stop, stop-on-error and stop-on-WHEA disabled, so v0.4.1-dev now performs a read-only OCCT safety preflight before any guided load;
- historical GPU logs showed isolated high-load samples but no sustained GPU test, so short transients cannot satisfy the GPU validation stage;
- null Windows storage reliability counters are treated as unavailable rather than silently converted to zero;
- physical case, AIO, pump-header mapping, PSU revision and PSU electrical health remain outside what software validation can prove.
