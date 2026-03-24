---
phase: 01-coverage-matrix
verified: 2026-03-25T00:00:00Z
status: passed
score: 5/5 must-haves verified
re_verification: false
human_verification:
  - test: "Verify collector source file accuracy — Processes fallback chain"
    expected: "Processes.psm1 uses Get-CimInstance Win32_Process for PS3+, ManagementObjectSearcher Win32_Process (WMI) for PS2, and [System.Diagnostics.Process]::GetProcesses() as supplement; dotnet_fallback nulls ParentProcessId/CommandLine/SessionId/HandleCount"
    why_human: "01-02-PLAN.md human gate was executed and 01-02-SUMMARY.md claims approval, but ROADMAP.md progress table still shows plan 01-02 as incomplete ([ ]). Either the human approval happened and ROADMAP was not updated, or the approval was not genuine. A human reviewer must confirm the matrix accurately reflects the source psm1 files."
  - test: "Verify collector source file accuracy — DLLs protected process list"
    expected: "DLLs.psm1 contains hardcoded exclusion for lsass, csrss, smss, wininit, System, Idle at two locations (PS3+ path ~line 39, PS2 path ~line 172)"
    why_human: "Same reason as above — the 01-02 human gate completion is disputed by ROADMAP state. This is the highest-risk fact claim in the document because the exact line locations and exact list membership must match source."
  - test: "Verify collector source file accuracy — Users no PS-version branching"
    expected: "Users.psm1 USERS_SB scriptblock uses Get-WmiObject throughout with no PSVersion conditional — confirming the document's key architectural claim that Users has no PS-version fallback"
    why_human: "Same dispute. This architectural claim is structurally important for downstream documents."
  - test: "Confirm ROADMAP.md status update"
    expected: "ROADMAP.md plan list updated to mark 01-02-PLAN.md as complete ([x]) and progress table updated to 2/2 plans / Complete"
    why_human: "ROADMAP.md currently shows Phase 1 as 'In Progress, 1/2 plans complete'. 01-02-SUMMARY.md claims the human gate completed with approval. These are contradictory. If the human review genuinely occurred and was approved, ROADMAP.md must be updated to reflect completion."
---

# Phase 01: Coverage Matrix Verification Report

**Phase Goal:** Analysts and document authors have a verified, accurate reference showing exactly what each collector gathers, at which fallback tier, and where coverage gaps exist
**Verified:** 2026-03-25
**Status:** human_needed — all automated checks pass; one process-state discrepancy requires human resolution
**Re-verification:** No — initial verification


## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | An analyst can look up any artifact type (Processes, Network TCP, Network DNS, DLLs, Users) and see which data fields are collected at each PS version tier | VERIFIED | All five collectors documented at lines 67–290. Each has a Field Fidelity table with per-tier columns. |
| 2 | Fallback chains are documented per-collector with exact source field string values from the codebase | VERIFIED | All 13 authoritative source string values present: `cim`, `wmi`, `dotnet_fallback`, `cim+dotnet_fallback`, `wmi+dotnet_fallback`, `netstat_fallback`, `netstat_legacy`, `ipconfig_fallback`, `ipconfig_legacy`, `dotnet`, `WMI`, `WMI+Get-ADUser`, `WMI+ADSI` |
| 3 | Coverage gaps are explicitly listed per-collector and toolkit-wide — DLLs protected process exclusion, Users replication lag, netstat timestamp absence, toolkit scope boundaries | VERIFIED | Per-collector Coverage Gaps subsections at lines 109–112, 143–147, 172–175, 219–225, 271–275. Toolkit-Wide table at lines 278–291 lists all 7 out-of-scope types. |
| 4 | Fidelity notes name exact fields that are null or degraded at each tier, not vague "degraded" labels | VERIFIED | Specific null fields named throughout: dotnet_fallback nulls `ParentProcessId`/`CommandLine`/`SessionId`/`HandleCount`; PS2 Signature nulls `IsValid`/`Thumbprint`/`NotAfter`/`TimeStamper`; `CreationTime` null all tiers; `LoadedAt` null all tiers. No vague "degraded" labels found. |
| 5 | Document renders cleanly as GitHub-flavored Markdown with stable anchor slugs for Phase 2/3 cross-references | VERIFIED | All 9 H2 headings present with stable slug-compatible text. No external URLs. No placeholder markers. 290 lines, exceeds 200-line minimum. |

**Score:** 5/5 truths verified


### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `docs/COVERAGE-MATRIX.md` | Complete artifact coverage matrix reference document containing `# DFIR Artifact Coverage Matrix`, min 200 lines | VERIFIED | File exists, 290 lines, starts with `# DFIR Artifact Coverage Matrix` at line 1. |


### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `docs/COVERAGE-MATRIX.md` | `Modules/Collectors/Processes.psm1` | Fallback chain and field fidelity derived from source; pattern `cim.*wmi.*dotnet_fallback` | VERIFIED (automated) | Lines 75–77 contain `cim`, `wmi`, `dotnet_fallback` source values in fallback chain table. |
| `docs/COVERAGE-MATRIX.md` | `Modules/Collectors/Network.psm1` | TCP and DNS independent fallback chains; pattern `netstat_fallback.*ipconfig_fallback` | VERIFIED (automated) | Lines 123–125 (`netstat_fallback`, `netstat_legacy`), lines 158–160 (`ipconfig_fallback`, `ipconfig_legacy`). Both chains present. |
| `docs/COVERAGE-MATRIX.md` | `Modules/Collectors/DLLs.psm1` | DLLs .NET vs WMI enumeration and protected process list; pattern `lsass.*csrss.*smss.*wininit.*System.*Idle` | VERIFIED (automated) | Lines 195 and 221 contain all six protected process names in the correct set. |
| `docs/COVERAGE-MATRIX.md` | `Modules/Collectors/Users.psm1` | Users WMI+Registry collection and DC detection; pattern `WMI\+Get-ADUser.*WMI\+ADSI` | VERIFIED (automated) | Lines 250–251 contain `WMI+Get-ADUser` and `WMI+ADSI`. |


### Data-Flow Trace (Level 4)

Not applicable. `docs/COVERAGE-MATRIX.md` is a static reference document — no dynamic data rendering, no state, no API calls. Level 4 data-flow tracing applies to runnable code artifacts only.


### Behavioral Spot-Checks

Skipped. This phase produces a documentation artifact (`docs/COVERAGE-MATRIX.md`), not runnable code. No entry points to invoke.


### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| COV-01 | 01-01-PLAN.md | Artifact x data source grid covering all collectors (Processes, Network, DNS, DLLs, Users) | SATISFIED | All five collectors documented with fallback chain tables. Grid structure present. |
| COV-02 | 01-01-PLAN.md | Fallback path columns showing PS version tiers and collection method per artifact | SATISFIED | Per-tier columns in every field fidelity table. All 13 source string values documented. |
| COV-03 | 01-01-PLAN.md | Coverage gap column — explicit gaps (no event logs, no registry, no RAM, DLL/Users fallback limitations) | SATISFIED | Per-collector Coverage Gaps sections plus 7-item Toolkit-Wide Coverage Gaps table. |
| COV-04 | 01-01-PLAN.md | Fidelity notes per fallback tier (e.g., netstat path loses PID correlation, DNS fallback loses TTL) | SATISFIED | Exact null fields named per tier throughout. No vague labels. |

No orphaned requirements: REQUIREMENTS.md maps COV-01 through COV-04 to Phase 1, and all four appear in 01-01-PLAN.md. No Phase 1 requirements are unaccounted for.

Note: COV-02 description in REQUIREMENTS.md mentions "netstat PID correlation loss" and "DNS TTL loss." The document addresses `CreationTime` (connection timestamp loss) and DNS Type/TTL parsing fragility. PID itself is populated at netstat tiers (line 135) — PID correlation loss is not a gap in this collector's data. The requirement wording in REQUIREMENTS.md is slightly imprecise; the document's more accurate treatment is correct.


### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| None found | — | No TODO/FIXME/placeholder markers, no empty implementations, no external URLs | — | — |

No anti-patterns detected. Document is substantive throughout.


### Human Verification Required

#### 1. Resolve ROADMAP.md / 01-02-SUMMARY.md Discrepancy

**Test:** Check whether human review of `docs/COVERAGE-MATRIX.md` against collector source files genuinely occurred and was approved.

**Expected:** If approved, ROADMAP.md should be updated: plan `01-02-PLAN.md` marked `[x]` complete, progress table updated to "2/2 / Complete".

**Why human:** `01-02-SUMMARY.md` (frontmatter `status: complete`) states human reviewed and approved the document with no issues. However, ROADMAP.md still shows Phase 1 as "In Progress, 1/2 plans complete" with `01-02-PLAN.md` unchecked (`[ ]`). These are contradictory. The verifier cannot determine from code alone whether the human gate was genuinely satisfied — this requires a human to either confirm the review happened and update ROADMAP, or perform the review now if it was not done.

#### 2. Spot-check Processes.psm1 fallback chain accuracy

**Test:** Open `Modules/Collectors/Processes.psm1`. Verify: (a) PS3+ path uses `Get-CimInstance Win32_Process`, (b) PS2 path uses `ManagementObjectSearcher Win32_Process`, (c) dotnet_fallback supplement fires for PIDs not in WMI/CIM, (d) `ParentProcessId`, `CommandLine`, `SessionId`, `HandleCount` are null in dotnet_fallback entries.

**Expected:** All four points confirmed in source.

**Why human:** The 01-02 human gate that was supposed to verify this is in disputed state (see item 1). The document's accuracy against the source psm1 files is the core deliverable of this phase.

#### 3. Spot-check DLLs.psm1 protected process list

**Test:** Open `Modules/Collectors/DLLs.psm1`. Verify the hardcoded exclusion list at approximately lines 39 and 172 contains exactly: `lsass`, `csrss`, `smss`, `wininit`, `System`, `Idle` — no more, no fewer.

**Expected:** Exact match confirmed at both locations.

**Why human:** Same reason as item 2. The exact membership of this list is a specific factual claim in the document.

#### 4. Spot-check Users.psm1 no-PSVersion-branching architectural claim

**Test:** Open `Modules/Collectors/Users.psm1`. Verify that `$script:USERS_SB` uses `Get-WmiObject` throughout with no `$PSVersionTable` or `$caps.PSVersion` conditional that would branch local/profile collection.

**Expected:** Confirmed — `USERS_SB` is PS-version-independent for local/profile collection.

**Why human:** Same reason. This architectural claim affects how Phase 2 and Phase 3 documents will describe Users behavior.


### Gaps Summary

No content gaps identified. All five observable truths are verified. All four requirement IDs (COV-01 through COV-04) are satisfied. The document is substantive, accurate in structure, free of placeholders, and contains all required sections.

The single open item is a process-state discrepancy: `01-02-SUMMARY.md` claims human review completed, but ROADMAP.md was not updated to reflect it. This is a lightweight resolution — either confirm the review occurred and update ROADMAP.md, or perform the review now. No content changes to `docs/COVERAGE-MATRIX.md` are anticipated.

---

_Verified: 2026-03-25_
_Verifier: Claude (gsd-verifier)_
