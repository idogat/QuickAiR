# Quicker DFIR Toolkit — Production Documentation

## What This Is

Production documentation suite for the Quicker DFIR toolkit — an operational runbook, artifact coverage matrix, and analyst interpretation guide. Written for a mixed team of junior and senior DFIR analysts who need both onboarding material and quick-reference resources for day-to-day incident response work.

## Core Value

Analysts can pick up the toolkit and operate it correctly without tribal knowledge — from running collections through interpreting results in the report viewer.

## Requirements

### Validated

- Existing capability: PowerShell-based remote data collection (Collector.ps1)
- Existing capability: Multi-method tool deployment (Executor.ps1 — WinRM/SMB+WMI/WMI)
- Existing capability: Persistent job manager with WinForms UI (QuickerLaunch.ps1)
- Existing capability: Offline browser-based report viewer (Report.html)
- Existing capability: Plugin architecture for collectors (auto-discovery)
- Existing capability: Fallback-chain execution with capability probing
- Existing capability: SHA256 integrity verification on collected data

### Active

- [ ] Operational runbook covering Collector, Executor, and Launcher command usage, parameters, and troubleshooting common failures
- [x] Artifact coverage matrix — artifact x data source grid showing what's collected, fallback paths, and coverage gaps (Validated in Phase 01: coverage-matrix)
- [ ] Analyst interpretation guide for Report.html — navigating tabs, cross-referencing data, and spotting anomalies
- [ ] All docs in docs/ folder, accessible to mixed-experience IR teams

### Out of Scope

- Forensic analysis methodology beyond what the tool collects — this is tool documentation, not an IR textbook
- MITRE ATT&CK mapping — not requested for this milestone
- Code-level developer documentation — codebase map already covers architecture
- Video or interactive tutorials — written docs only

## Context

- Brownfield project: mature PowerShell DFIR toolkit with collector plugins, remote executors, job launcher, and offline HTML report viewer
- Codebase map exists at .planning/codebase/ with full architecture, stack, and conventions analysis
- No external dependencies — fully air-gappable, runs on Windows 10/11 and Server 2008 R2+
- Existing test suite (TestSuite.ps1) with 11 automated checks
- Report.html is assembled from ReportStages/ via build_report.ps1
- Collectors: Processes, Network, DLLs, Users (each with tiered fallback paths)
- Executors: WinRM (preferred), SMB+WMI, WMI (legacy)

## Constraints

- **Format**: Markdown files in docs/ folder — must render cleanly on GitHub and in local editors
- **Audience**: Mixed junior/senior analysts — avoid assuming deep tool familiarity but don't over-explain IR fundamentals
- **Accuracy**: All parameters, paths, and behaviors must match current codebase (not aspirational)
- **Air-gap**: Docs must not reference or require external URLs for core content

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| docs/ folder for all documentation | Keeps docs separate from code, standard repo convention | -- Pending |
| Matrix-style artifact coverage | Quick visual scan of what's collected and where gaps exist | Delivered — Phase 01 |
| Report-focused interpretation guide | Analysts interact with data through Report.html, not raw JSON | -- Pending |
| Combined command reference + troubleshooting in runbook | Mixed team needs both "how to run" and "what went wrong" in one place | -- Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd:transition`):
1. Requirements invalidated? -> Move to Out of Scope with reason
2. Requirements validated? -> Move to Validated with phase reference
3. New requirements emerged? -> Add to Active
4. Decisions to log? -> Add to Key Decisions
5. "What This Is" still accurate? -> Update if drifted

**After each milestone** (via `/gsd:complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-03-24 after Phase 01 completion*
