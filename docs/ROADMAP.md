# DadLAN Roadmap

## v0.2.2 — Fleet Grid & Layout Fix

- [x] Read-only Action1 connection
- [x] Endpoint fleet inventory
- [x] Responsive Windows layout
- [x] Fedora/Linux desktop client
- [x] Search and filters
- [x] local machine roles/notes/protection
- [x] activity history in the current session
- [x] read-only diagnostics
- [x] credentials excluded from repository

## v0.3 — Safe Remote Diagnostics

Goal: prove the full Action1 → endpoint → result loop without opening arbitrary scripting.

- [x] pre-defined diagnostic jobs only
- [x] target exactly one selected worker initially
- [x] block protected endpoints
- [x] show target + command summary before execution
- [x] collect stdout/stderr/status/timing
- [x] SQLite job history
- [x] API rate-limit handling (via retry loop / polling intervals)
- [x] timeout/cancel handling
- [ ] **TASK-00714** expand from one worker to selected workers only after validation

Suggested first diagnostics:

- hostname
- uptime
- CPU/RAM summary
- disk free space
- Python/Git presence
- ForgeGrid worker/service presence

## v0.4 — Fleet Operations

Only after v0.3 is reliable:

- [ ] **TASK-00715** multi-select jobs
- [ ] **TASK-00716** bounded concurrency
- [ ] **TASK-00717** reboot with confirmation
- [ ] **TASK-00718** software install from approved packages
- [ ] **TASK-00719** ForgeGrid deployment/update workflow
- [ ] **TASK-00720** controller excluded from fleet-wide actions by default
- [ ] **TASK-00721** audit/export of job history

## Later

- richer hardware inventory
- temperature/battery/SMART collection where available
- update/vulnerability summaries
- endpoint grouping
- scheduled fleet health checks
- web UI option for headless Fedora controller
