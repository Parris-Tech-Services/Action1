# Security Notes

DadLAN controls or observes remote computers through Action1, so credentials and action boundaries matter.

## Credentials

- Never commit Client Secrets, bearer tokens, `.clixml` credentials, or exported credential files.
- DadLAN v0.3.0 does not persist the Client Secret.
- The Client ID may be supplied through `ACTION1_CLIENT_ID`, but the secret is prompted interactively.
- Local machine metadata can contain endpoint IDs and hostnames, so it is stored outside the repository and ignored by Git.

## API credential permissions

Use least privilege. For v0.3.0 which supports remote diagnostics, give the credential only the permissions necessary to view endpoints and run scripts (`Use Scripts` permission in Action1) for the intended endpoints.

## Protected controller

Laptop #01 is auto-marked as `Controller` and `protected=true`. Fleet actions actively exclude the Controller (Laptop #01) at the logic level, regardless of the `protected` flag in metadata. Protected endpoints are also strictly blocked.

## Remote execution safeguards

Remote actions are strictly bounded:

1. Only predefined harmless diagnostics (like System Snapshot) are allowed.
2. Actions can only target one worker at a time.
3. Controllers and non-workers are explicitly blocked.
4. The Action1 payload uses explicit `run_script` templates, preventing arbitrary PowerShell injection.
5. All executions require an explicit confirmation prompt.

Do not add an unrestricted fleet-wide arbitrary-script button.


## Hardware validation safeguards

v0.4-dev adds hardware validation without adding an unrestricted remote shell.

- Action1 runs the Hardware Validation script in its safe default `Baseline` mode only.
- The baseline collects inventory, telemetry and Windows storage-health data; it does not start OCCT or another load generator.
- Guided OCCT stages require local `-Interactive` execution and an operator Start click.
- DadLAN does not invent undocumented OCCT command-line arguments.
- CPU/RAM and GPU stages are separated by cooldown; the workflow never deliberately starts a combined CPU+GPU power test.
- Thermal guards are explicit. If a trustworthy CPU sensor is unavailable, the CPU/RAM stage is `INCOMPLETE` unless the operator explicitly accepts a fallback sensor.
- The runner may close the OCCT process at the end of a bounded interval or after a thermal abort; it does not terminate unrelated processes.
- BIOS/UEFI settings, XMP, clocks, voltages, GPU power limits, firmware and drivers are not modified.
- `INCOMPLETE` must never be promoted to `PASS` merely because no crash occurred.
- Both hardware runner files must be packaged together. Guided jobs use suspended launch into a kill-on-close Job Object; process-tree ownership avoids killing unrelated applications. A 15-second sampling watchdog and `finally` cleanup terminate the owned job on stalled or failed monitoring.
- No console input is awaited under active load. Sensor loss and failed/timed-out cooldown prevent subsequent stages. OCCT's temperature/error/WHEA stops must be checked before launch; the operator verifies that the supplied configuration is active.
- Imported historical facts retain their evidence labels and never replace live sensor guards. Public examples contain no endpoint serial numbers or private screenshots.

### OCCT preflight added in v0.4.1-dev

- Guided OCCT stages now read the local OCCT configuration before starting load.
- DadLAN requires OCCT stop-on-error and stop-on-WHEA to be enabled and its temperature stop to be enabled at or below the DadLAN stage limit. If that cannot be verified, the stage is `INCOMPLETE` and no load is started.
- The OCCT configuration is read-only. DadLAN does not silently enable, disable or rewrite OCCT settings.
- When available, DadLAN records OCCT UI `CPU (Tctl)` and `CPU Package (TSI)` readings alongside LibreHardwareMonitor data. It uses the conservative maximum of available CPU/socket/Tctl/TSI readings for its own guard, while retaining the source limitations in the report.
- If critical temperature telemetry disappears during a guided stage, DadLAN stops the active guided load and marks the stage `INCOMPLETE` rather than assuming the machine is safe.
- `AllowOcbaseUpload=true` is surfaced as a privacy warning but is not modified automatically.
