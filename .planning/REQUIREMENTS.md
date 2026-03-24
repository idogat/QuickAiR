# Requirements: Quicker DFIR Toolkit — Production Documentation

**Defined:** 2026-03-24
**Core Value:** Analysts can pick up the toolkit and operate it correctly without tribal knowledge

## v1 Requirements

### Coverage Matrix

- [x] **COV-01**: Artifact x data source grid covering all collectors (Processes, Network, DNS, DLLs, Users)
- [x] **COV-02**: Fallback path columns showing PS version tiers and collection method per artifact
- [x] **COV-03**: Coverage gap column — explicit gaps (no event logs, no registry, no RAM, DLL/Users fallback limitations)
- [x] **COV-04**: Fidelity notes per fallback tier (e.g., netstat path loses PID correlation, DNS fallback loses TTL)

### Operational Runbook

- [ ] **RUN-01**: Architecture overview showing how Collector, Executor, Launcher, and Report connect end-to-end
- [ ] **RUN-02**: Command reference with all parameters derived from actual param() blocks in Collector.ps1, Executor.ps1, QuickerLaunch.ps1
- [ ] **RUN-03**: Prerequisites and setup documentation (WinRM configuration, credential handling, quicker:// protocol registration)
- [ ] **RUN-04**: Troubleshooting section with verbatim error messages from codebase and resolution steps

### Interpretation Guide

- [ ] **INT-01**: Report.html navigation — loading JSON data, switching hosts in fleet view, using tab interface
- [ ] **INT-02**: Cross-tab investigation workflows — Process to Network to DNS pivot scenarios
- [ ] **INT-03**: Data field definitions — what each field means forensically for every tab
- [ ] **INT-04**: Anomaly pattern examples — what "suspicious" looks like in this specific report format

## v2 Requirements

### Coverage Matrix Enhancements

- **COV-05**: PS version compatibility matrix per collector module
- **COV-06**: Data field inventory per artifact per fallback tier (exact properties returned)

### Runbook Enhancements

- **RUN-05**: Degraded-mode behavior details per fallback tier
- **RUN-06**: Edge case documentation (localhost collection, PS 2.0 targets, concurrent job limits)

## Out of Scope

| Feature | Reason |
|---------|--------|
| MITRE ATT&CK mapping | Not requested for this milestone |
| IR methodology tutorials | Tool documentation, not an IR textbook |
| Code-level developer docs | Codebase map at .planning/codebase/ already covers architecture |
| Video/interactive tutorials | Written markdown docs only |
| README.md rewrite | Separate effort; README update limited to adding docs/ links |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| COV-01 | Phase 1 | Complete |
| COV-02 | Phase 1 | Complete |
| COV-03 | Phase 1 | Complete |
| COV-04 | Phase 1 | Complete |
| RUN-01 | Phase 2 | Pending |
| RUN-02 | Phase 2 | Pending |
| RUN-03 | Phase 2 | Pending |
| RUN-04 | Phase 2 | Pending |
| INT-01 | Phase 3 | Pending |
| INT-02 | Phase 3 | Pending |
| INT-03 | Phase 3 | Pending |
| INT-04 | Phase 3 | Pending |

**Coverage:**
- v1 requirements: 12 total
- Mapped to phases: 12
- Unmapped: 0

---
*Requirements defined: 2026-03-24*
*Last updated: 2026-03-24 after roadmap creation — all 12 v1 requirements mapped*
