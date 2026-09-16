# Action1 ↔ JoshMemory

Last updated: 15 September 2026

## Boundary

Action1 is the fleet's out-of-band Windows bootstrap, maintenance and recovery side channel. JoshMemory is the shared development-continuity/provenance layer. GitHub and live machine evidence remain authoritative for code/runtime state.

JoshMemory now stores shared handoffs, durable facts and accountability references in a private GitHub-backed append-only store (`joshualparris/JoshDashboard4`, `joshmemory-cloud/v1/`). Therefore Action1 is not required to keep project memory online and should not be turned into the primary continuity database.

## Appropriate Action1 uses

Action1 may be used to:

- recover a broken worker;
- bootstrap/update approved fleet tooling;
- repair a Windows service or prerequisite when the normal execution path is unavailable;
- gather independent machine evidence where appropriate.

Any meaningful result can be referenced from JoshMemory with provenance. JoshMemory should not claim the Action1 operation happened unless there is actual evidence.

## Do not

- Do not store a live shared SQLite database on an Action1-accessible file share.
- Do not treat Action1 inventory or scripts as canonical Git source state.
- Do not regenerate credentials or change machine identity merely to make a remembered handoff fit reality.
- Do not expose tokens/passwords in JoshMemory handoffs.

## Fleet precedence

1. live Git/API/machine evidence;
2. independent verification/receipts;
3. JoshMemory handoffs/facts;
4. older transcripts or inference.

Canonical JoshMemory implementation/history: https://github.com/joshualparris/JoshMemory
