# DadLAN Action1 Command Centre

DadLAN is a small fleet dashboard for managing a lab of Action1-managed computers. 

Two front ends are included:

- **Windows** — PowerShell + WinForms + the official `PSAction1` module.
- **Fedora/Linux** — Python + Tkinter + the official Action1 REST API.

## Current status

Version: **v0.4.0-dev — Hardware Validation**

Implemented:

- Action1 authentication
- Australia region by default
- organisation selection
- endpoint inventory
- online/offline/problem summary
- DadLAN roles (`Controller`, `Worker`, `Legacy Worker`)
- protected controller metadata
- search and fleet filters
- endpoint details
- Action1 REST API payload construction and execution
- **System Snapshot** remote diagnostic execution
- **Hardware Validation (Safe Baseline)** remote diagnostic definition
- Windows hardware-validation runner with LibreHardwareMonitor telemetry and SMART/storage health
- Guided local OCCT CPU/RAM → cooldown → GPU workflow with temperature abort guards
- structured PASS/WARN/FAIL/INCOMPLETE reports and CSV/JSON evidence
- SQLite job history
- Local metadata persistence
- Worker-only targeting for remote actions (Controllers explicitly blocked)

Not implemented yet:

- arbitrary remote PowerShell/scripts
- reboot/shutdown
- software deployment
- multi-endpoint bulk write actions
- unattended consumer-OCCT stress automation (guided Start click remains intentional)

## Security

**Do not commit Action1 credentials.** This repository intentionally does not contain a Client ID, Client Secret, bearer token, or saved credential file.

The Windows and Fedora apps prompt for credentials at runtime and do not persist the Client Secret. Local fleet metadata is also ignored by Git because it can contain endpoint IDs and hostnames.

For v0.3, the API credential must have permissions sufficient to run scripts (`Use Scripts`) in Action1.

## Windows

### Requirements

- Windows 10/11
- Windows PowerShell 5.1 or newer
- Action1 API credentials

### Setup

Open **PowerShell as Administrator**:

```powershell
cd windows
.\Setup-Action1Controller.ps1
```

Then launch:

```powershell
.\DadLAN-Control.ps1
```

The app uses `PSAction1`, sets the region to Australia, asks for your Client ID/Secret, and loads the fleet.

Local metadata is stored outside the repo under:

```text
%LOCALAPPDATA%\DadLAN\machines.json
```

## Fedora / Linux

The Linux edition does not depend on PowerShell or WinForms. It talks directly to the Action1 REST API using Python's standard library.

### Install on Fedora

```bash
cd fedora
./install-fedora.sh
```

Then run:

```bash
dadlan
```

or launch **DadLAN Command Centre** from the Fedora application menu.

The installer only ensures Python/Tkinter are available and creates a per-user launcher. There are no pip dependencies.

Local metadata is stored under:

```text
~/.config/dadlan/machines.json
```
History DB is stored under:
```text
~/.local/share/dadlan/history.db
```

### Optional Client ID environment variable

You can pre-fill the Client ID without storing the secret:

```bash
export ACTION1_CLIENT_ID='your-client-id'
dadlan
```

The Client Secret is still requested interactively and is not written to disk.

## Action1 API regions

The Fedora client supports the region hosts used by Action1:

- North America
- North America 2
- Europe
- Australia

DadLAN defaults to Australia.

## DadLAN roles

When an endpoint name contains `Laptop #01` through `Laptop #10`, DadLAN automatically assigns:

- `#01` → Controller + Protected
- `#02`–`#08` → Worker
- `#09`–`#10` → Legacy Worker

Manual metadata edits are kept locally and are not written back to Action1.
Laptop #01 and protected endpoints are strictly blocked from receiving remote execution actions.

## Repository structure

```text
windows/
  DadLAN-Control.ps1
  DadLAN-HardwareValidation.ps1
  Setup-Action1Controller.ps1
fedora/
  dadlan.py
  action1_client.py
  diagnostics.py
  database.py
  test_dadlan.py
  install-fedora.sh
config/
  DadLAN-Machines.example.json
docs/
  HARDWARE-VALIDATION.md
  ROADMAP.md
  SECURITY-NOTES.md
```

## Hardware validation

See [docs/HARDWARE-VALIDATION.md](docs/HARDWARE-VALIDATION.md).

The Action1-safe default is a read-only baseline. Full CPU/RAM and GPU validation is deliberately local/interactive in v0.4-dev so consumer OCCT is never driven with guessed or undocumented command-line arguments.

## Next milestone

Finish real-machine validation of v0.4, then continue fleet operations:

1. validate the hardware runner on representative DadLAN machines
2. add approved Action1 package IDs
3. multi-select jobs with bounded concurrency
4. reboot/software install only with explicit confirmation
5. ForgeGrid deployment/update workflow
