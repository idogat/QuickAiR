# Roadmap: QuickAiR DFIR Toolkit — Production Documentation

## Overview

Four phases deliver three focused reference documents plus integration review. The build order follows hard data dependencies: the coverage matrix is the ground-truth anchor that both the runbook and interpretation guide reference — it must exist first. The runbook must exist before the interpretation guide because analysts cannot meaningfully analyze results until they can successfully collect data. The final phase wires everything together with a README update and a cross-document consistency pass to catch broken anchors and parameter drift.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Coverage Matrix** - Write docs/COVERAGE-MATRIX.md — artifact x data source grid with fallback paths and explicit gap columns
- [ ] **Phase 2: Operational Runbook** - Write docs/RUNBOOK.md — prerequisites, full parameter references, executor method chain, troubleshooting
- [ ] **Phase 3: Interpretation Guide** - Write docs/INTERPRET.md — Report.html navigation, cross-tab workflows, anomaly patterns
- [ ] **Phase 4: README and Integration Review** - Update README.md with docs links; verify all cross-references and parameter names across all docs

## Phase Details

### Phase 1: Coverage Matrix
**Goal**: Analysts and document authors have a verified, accurate reference showing exactly what each collector gathers, at which fallback tier, and where coverage gaps exist
**Depends on**: Nothing (first phase)
**Requirements**: COV-01, COV-02, COV-03, COV-04
**Success Criteria** (what must be TRUE):
  1. An analyst can look up any artifact type (Processes, Network, DNS, DLLs, Users) and immediately see which data fields are collected at each PS version tier
  2. Fallback path columns are populated for each artifact showing the specific collection method at each tier (CIM, WMI, netstat, etc.)
  3. Coverage gaps are explicitly listed — DLLs/Users PS 2.0 absence, netstat PID correlation loss, DNS TTL loss — not omitted or minimized
  4. Fidelity notes per fallback tier make clear what data is degraded or absent at each tier compared to the preferred path
**Plans:** 1/2 plans executed

Plans:
- [x] 01-01-PLAN.md — Write complete docs/COVERAGE-MATRIX.md with all collector sections, fallback chains, field fidelity tables, and coverage gaps
- [x] 01-02-PLAN.md — Human verification of document accuracy against collector source files

### Phase 2: Operational Runbook
**Goal**: An analyst new to the toolkit can go from zero to successfully collecting data from a remote host, and can diagnose and resolve common failures without tribal knowledge
**Depends on**: Phase 1
**Requirements**: RUN-01, RUN-02, RUN-03, RUN-04
**Success Criteria** (what must be TRUE):
  1. An analyst can follow the prerequisites section and configure WinRM, TrustedHosts, credentials, and the quickair:// protocol registration without prior toolkit knowledge
  2. An analyst can look up any parameter for Collector.ps1, Executor.ps1, or QuickAiRLaunch.ps1 and find the correct name, type, and default value verified against the actual codebase param blocks
  3. An analyst can read the architecture overview and understand how Collector, Executor, Launcher, and Report connect end-to-end before running any command
  4. An analyst who encounters a terminal failure (CONNECTION_FAILED, TRANSFER_FAILED, LAUNCH_FAILED, etc.) can find that exact error state in the troubleshooting section and follow concrete resolution steps derived from the actual codebase
**Plans**: TBD

### Phase 3: Interpretation Guide
**Goal**: An analyst who has successfully collected data can load results into Report.html, navigate its tabs, run cross-tab investigation workflows, and identify anomalies without guidance from a senior analyst
**Depends on**: Phase 2
**Requirements**: INT-01, INT-02, INT-03, INT-04
**Success Criteria** (what must be TRUE):
  1. An analyst opening Report.html for the first time can load a JSON data file, switch between hosts in fleet view, and navigate all tabs using only the guide
  2. An analyst can follow at least three complete cross-tab investigation workflows (e.g., Process to Network to DNS pivot) from start to finish using the documented steps
  3. An analyst can look up any data field in any Report.html tab and find a forensic definition explaining what that field means and why it matters
  4. A junior analyst can use the anomaly pattern examples to identify suspicious indicators in Processes, Network, DLLs, Users, and DNS tabs without senior guidance
**Plans**: TBD

### Phase 4: README and Integration Review
**Goal**: The repository has a working Documentation entry point in README.md, all cross-document anchor links resolve correctly, and all parameter names across all three docs match the current codebase
**Depends on**: Phase 3
**Requirements**: (integration phase — no standalone v1 requirements; delivers cross-document coherence and discoverability for COV-01–INT-04)
**Success Criteria** (what must be TRUE):
  1. README.md contains a Documentation section with accurate one-line descriptions and working relative links to all three docs in docs/
  2. Every cross-document anchor link (e.g., RUNBOOK.md → COVERAGE-MATRIX.md#heading) resolves to the correct heading in the target file
  3. Every parameter name, default value, and output path documented across all three files matches the corresponding param block in the current codebase source files
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Coverage Matrix | 1/2 | In Progress|  |
| 2. Operational Runbook | 0/TBD | Not started | - |
| 3. Interpretation Guide | 0/TBD | Not started | - |
| 4. README and Integration Review | 0/TBD | Not started | - |
