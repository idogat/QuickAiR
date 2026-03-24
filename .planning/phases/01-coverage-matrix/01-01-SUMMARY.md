---
phase: 01-coverage-matrix
plan: "01"
subsystem: documentation
tags: [coverage-matrix, docs, collectors, fallback-chains, fidelity]
dependency_graph:
  requires: []
  provides:
    - docs/COVERAGE-MATRIX.md
  affects:
    - Phase 2 (RUNBOOK.md) — cross-references collector sections by heading anchor
    - Phase 3 (INTERPRET.md) — cross-references field fidelity tables by heading anchor
tech_stack:
  added: []
  patterns:
    - GitHub-flavored Markdown with stable heading anchors
    - Per-collector sub-table pattern (fallback chain + field fidelity + coverage gaps)
key_files:
  created:
    - docs/COVERAGE-MATRIX.md
  modified: []
decisions:
  - "Per-collector sub-table pattern chosen over single monolithic table — branching logic and fidelity losses differ enough across collectors that one flat table would obscure critical distinctions"
  - "dotnet_fallback documented as column in Processes field fidelity table (not a separate tier) — it is a supplement at all tiers, and the column approach makes null fields immediately visible"
  - "Network TCP and Network DNS documented as separate sections with independent fallback chains — HasNetTCPIP and HasDNSClient are independent flags per D-04"
metrics:
  duration: "3 minutes"
  completed_date: "2026-03-24"
  tasks_completed: 3
  files_created: 1
---

# Phase 01 Plan 01: Coverage Matrix Document Summary

**One-liner:** Complete artifact coverage matrix for five DFIR collectors with per-tier fallback chains, field fidelity tables, and explicit coverage gaps — derived from collector source files.

## What Was Built

`docs/COVERAGE-MATRIX.md` — a 290-line GitHub-flavored Markdown reference document covering all five collectors (Processes, Network TCP, Network DNS, DLLs, Users) and toolkit-wide coverage gaps. The document serves as the ground-truth anchor for Phase 2 (RUNBOOK.md) and Phase 3 (INTERPRET.md) cross-references.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Create skeleton with Legend, Tier Model, Capability Probe | `628fa37` | `docs/COVERAGE-MATRIX.md` (created) |
| 2 | Write Processes and Network (TCP + DNS) collector sections | `3311b1f` | `docs/COVERAGE-MATRIX.md` |
| 3 | Write DLLs, Users, and Toolkit-Wide Coverage Gaps sections | `04a7205` | `docs/COVERAGE-MATRIX.md` |

## Requirements Covered

| Req ID | Requirement | Status |
|--------|-------------|--------|
| COV-01 | Artifact x data source grid covering all five collectors | DONE — all five collectors documented with fallback chain tables |
| COV-02 | Fallback path columns showing PS version tiers and collection method per artifact | DONE — all 13 source string values present and documented |
| COV-03 | Coverage gaps — explicit named gaps per collector and toolkit-wide | DONE — per-collector gaps plus 7-item toolkit-wide gaps table |
| COV-04 | Fidelity notes naming exact fields and null/degraded state per tier | DONE — exact field names and null values at each tier, not vague "degraded" |

## Document Structure

The document uses 9 H2 headings with stable GitHub anchor slugs per the UI-SPEC Anchor Stability Contract:

1. `## Legend` — tier labels, cell state notation, coverage gap format
2. `## Tier Model` — three-tier model table with CIM classes available per tier
3. `## Capability Probe` — `Get-TargetCaps` flag table from `Connection.psm1` source
4. `## Processes` — CIM/WMI/dotnet_fallback chain, 17-field fidelity table
5. `## Network — TCP Connections` — independent CIM/netstat_fallback/netstat_legacy chain
6. `## Network — DNS Cache` — independent CIM/ipconfig_fallback/ipconfig_legacy chain
7. `## DLLs` — dotnet/.NET vs WMI chain, protected process exclusion list
8. `## Users` — no PS-version branching, WMI+Get-ADUser/WMI+ADSI DC paths
9. `## Toolkit-Wide Coverage Gaps` — 7 out-of-scope artifact types

## Decisions Made

1. **Per-collector sub-table pattern:** Each collector gets its own fallback chain table, field fidelity table, and coverage gaps list. The monolithic single-table approach was rejected because Processes/Network/DLLs/Users have fundamentally different branching logic that would be obscured in a flat table.

2. **dotnet_fallback as fidelity column (not a tier):** The `dotnet_fallback` supplement is documented as a fourth column in the Processes field fidelity table rather than as a separate tier, making the four null fields (`ParentProcessId`, `CommandLine`, `SessionId`, `HandleCount`) immediately visible in context with the CIM/WMI columns.

3. **Network TCP and DNS as separate sections:** Documented independently because `HasNetTCPIP` and `HasDNSClient` are independent capability flags — a PS 5.1 target can have `HasNetTCPIP=false` while `HasDNSClient=true`, making separate treatment correct.

## Deviations from Plan

None — plan executed exactly as written. All source string values, protected process lists, field fidelity data, and coverage gaps were derived directly from the pre-verified RESEARCH.md findings and the UI-SPEC copywriting contract. No additional source file reads were required beyond what was specified in Task 1's `read_first` list.

## Known Stubs

None. All data fields in the document are sourced from verified collector source files (`Processes.psm1`, `Network.psm1`, `DLLs.psm1`, `Users.psm1`, `Connection.psm1`). No placeholder text or TODO markers were introduced.

## Self-Check: PASSED

- `docs/COVERAGE-MATRIX.md` exists (290 lines, exceeds 200-line minimum) ✓
- All 9 H2 headings present per UI-SPEC Anchor Stability Contract ✓
- All 13 authoritative source string values in backtick code spans ✓
- Protected process list exactly: `lsass`, `csrss`, `smss`, `wininit`, `System`, `Idle` ✓
- No external URLs (air-gap compliant) ✓
- No deferred items (COV-05, COV-06, MITRE ATT&CK) appear in document ✓
- Task commits exist: `628fa37`, `3311b1f`, `04a7205` ✓
