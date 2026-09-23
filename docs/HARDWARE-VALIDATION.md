# DadLAN Hardware Validation

Status: **v0.4.2-dev preview**

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

Package `windows/DadLAN-HardwareValidation.ps1` **and** `windows/DadLAN-HardwareSafety.ps1` in the same directory in the predefined Action1 Software Repository package and configure:

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
.\DadLAN-HardwareValidation.ps1 -Mode GuidedFull -Interactive -OcctPath C:\Tools\OCCT\OCCTGUI.exe -OcctConfigPath C:\Tools\OCCT\OCCT.config.json
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

DadLAN terminates its owned OCCT process tree when the interval finishes, a sensor fails, or a thermal abort occurs. Record OCCT's error count during the interval: the confirmation prompt occurs **after shutdown**, so an unanswered prompt cannot leave a load running. Unknown error evidence is `INCOMPLETE`. The runner does not parse OCCT's result database.

### Older systems with fallback-only CPU telemetry

Only when you knowingly accept the lower-confidence sensor:

```powershell
.\DadLAN-HardwareValidation.ps1 -Mode CpuRamGuide -Interactive -CpuRamMinutes 5 -AllowFallbackTemperature -OcctPath C:\Tools\OCCT\OCCTGUI.exe -OcctConfigPath C:\Tools\OCCT\OCCT.config.json
```

The report records the sensor source and confidence. It does not silently promote a fallback sensor to a trusted CPU package temperature.

## Individual stages

CPU/RAM only:

```powershell
.\DadLAN-HardwareValidation.ps1 -Mode CpuRamGuide -Interactive -OcctPath C:\Tools\OCCT\OCCTGUI.exe -OcctConfigPath C:\Tools\OCCT\OCCT.config.json
```

GPU only:

```powershell
.\DadLAN-HardwareValidation.ps1 -Mode GpuGuide -Interactive -OcctPath C:\Tools\OCCT\OCCTGUI.exe -OcctConfigPath C:\Tools\OCCT\OCCT.config.json
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

## Required checks before the first real load

Run `-Mode GuidedFull -DryRun` first, then `-Mode Baseline`. Dry run never launches OCCT or prompts for a test; skipped stages remain `INCOMPLETE`. Review both reports before any real load. A baseline `PASS` means collection succeeded, not that the machine passed stability testing.

Use a local, attended five-minute `CpuRamGuide` first. Verify cleaning, pump/fan operation and usable temperature guards. Do not run `GuidedFull` on the FX-6300/R9 290 machine until its physical and sensor limitations are understood. Configuration and hardware validation remain required after code review.

`-OcctConfigPath` must point to the profile the selected executable actually uses. The runner reads the file and requires Boolean `true` for `IsTemperatureAlertValueEnabled`, `StopOnError` and `StopOnWheaError`. `TemperatureAlertValue` must be positive and no higher than the lowest active CPU/GPU/SSD limit (normally 60 C because SSD is 60 C). Missing fields, string booleans, invalid JSON or an excessive limit refuse the run. The runner **does not edit OCCT settings**. Verify them in OCCT, save/close it, then run DadLAN. The operator must attest that the supplied profile is active; a JSON file alone cannot establish the GUI's in-memory settings.

Existing OCCT processes block launching. The selected executable and descendants are assigned to a Windows Job Object before execution starts; unsupported job assignment fails without starting load. On exception, cancellation or normal completion, `finally` closes the job and terminates its tree. Windows also closes the job if the host dies. A native .NET timer stops the job if 15 seconds pass without a validated sample. That is a fail-safe timeout, not a guarantee against every hardware or OS failure. The launcher must remain alive: bootstrap executables that exit early cause `INCOMPLETE` and the owned tree is stopped. Select the actual GUI executable for versions with a transient bootstrapper.

There is no console prompt while a job is active. Startup has a monitored 60-second allowance; the requested interval begins only when intended load is observed. At least 90% of interval samples must show qualifying load (CPU >=70% with RAM use >=5 percentage points above baseline, or GPU >=50%). This is evidence of a bounded workload, not proof of full RAM coverage. Unknown OCCT error counts never pass.

Every finite preflight temperature identifier is pinned. Missing/null/non-finite guards abort immediately as `INCOMPLETE`; provider refresh exceptions are not suppressed or replaced by cached values. Newly observed guards are pinned too. CPU/RAM must pass and **all baseline guards** must return within 7 C before `GuidedFull` can start GPU. Timeout, missing telemetry and failed CPU stages skip GPU. Absolute temperature limits still apply during cooldown.

## CPU temperature sources and confidence

Raw telemetry records source, observation time, identifier and confidence. CPU package and socket-associated readings are retained together and each is checked, rather than discarding the socket channel when a package reading exists. AMD FX package telemetry is `FxRelative`, not silently promoted to a calibrated temperature; it requires explicit fallback acceptance. The known ITE channel remains `ProfileFallback` with a 60 C cap.

For an owned OCCT window, a read-only UI Automation adapter recognizes the English OCCT 17.1.4 monitoring-table rows `CPU (Tctl)` and `CPU Package (TSI)`. Keep the CPU monitoring table exposed. The adapter does not click controls or configure tests. Unrecognized layouts are not guessed. These rows are supplemental: preflight still requires a temperature guard before OCCT launches. Once discovered, switching away from the table or losing its rows aborts the stage. Reading the UI is a provider-reported observation, not proof that OCCT's underlying hardware sampling is fresh. Identical Tctl/TSI values are not independent corroboration.

An optional `-SensorSnapshotPath` accepts an external adapter's fresh JSON snapshot. It must have `SchemaVersion: 1`, the current `ComputerName`, ISO `CapturedAt` no older than 10 seconds, and a `Sensors` array of numeric temperature rows with `Source: OCCT`, exact supported CPU labels, `SensorType: Temperature`, and identifiers prefixed `/occt/cpu/`. Malformed, stale or future-dated input aborts. This is an integration contract; a historical evidence file is not a live sensor adapter. No generic OCCT CSV format or unsupported CLI is assumed.

## Importing existing forensic evidence

`-EvidenceManifestPath` accepts UTF-8 JSON with `SchemaVersion: 1`, the current `ComputerName`, and `Facts`. Every fact has `Name`, `Value`, `Status` (`CONFIRMED`, `MEASURED`, `INFERRED`, `UNKNOWN`), and `Source`; use `ObservedAt` and `Limitations` where known. The manifest is copied to the output folder and preserved as `ImportedFacts` alongside, never over, measured inventory. A claim is not upgraded simply because it is imported, and imported temperatures cannot satisfy live safety checks.

```json
{
  "SchemaVersion": 1,
  "ComputerName": "REPLACE_WITH_LOCAL_COMPUTER_NAME",
  "Facts": [
    { "Name": "AIO model", "Value": null, "Status": "UNKNOWN", "Source": "Physical label not yet inspected" },
    { "Name": "Earlier CPU/RAM test", "Value": "One minute, no errors displayed", "Status": "MEASURED", "Source": "Local OCCT result screenshot", "Limitations": "Not sustained stability certification" }
  ]
}
```

Keep identifying evidence bundles local unless publication is explicitly intended. The repository example is generic; it does not contain this PC's serial numbers or private screenshots.

## Automated verification and its limits

`Test-DadLAN-HardwareSafety.ps1` loads function definitions without executing the runner and injects provider exceptions, temperature dropout, invalid numeric readings, thermal trips, early process exit, missing baseline, cooldown timeout and invalid profiles. It checks stage gating, null SMBIOS fields, dry-run behavior, stale snapshots and evidence labels. Native integration checks create only sleeping PowerShell processes to verify child-tree termination and watchdog expiry. No stress test, OCCT invocation, hardware setting or driver change is performed by CI.

This goes beyond parsing but does **not** prove actual OCCT version compatibility, real thermals, pump health, PSU condition or machine stability. Real guided validation is still required; v0.4 remains a development preview.

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
