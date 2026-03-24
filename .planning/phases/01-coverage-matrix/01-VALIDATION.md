---
phase: 1
slug: coverage-matrix
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-24
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Pester 5.x (PowerShell) |
| **Config file** | none — Wave 0 installs if needed |
| **Quick run command** | `Invoke-Pester -Path tests/ -Tag "Phase1" -Output Minimal` |
| **Full suite command** | `Invoke-Pester -Path tests/ -Tag "Phase1" -Output Detailed` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `Invoke-Pester -Path tests/ -Tag "Phase1" -Output Minimal`
- **After every plan wave:** Run `Invoke-Pester -Path tests/ -Tag "Phase1" -Output Detailed`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 01-01-01 | 01 | 1 | COV-01 | unit | `Invoke-Pester -Path tests/ -Tag "COV-01"` | ❌ W0 | ⬜ pending |
| 01-01-02 | 01 | 1 | COV-02 | unit | `Invoke-Pester -Path tests/ -Tag "COV-02"` | ❌ W0 | ⬜ pending |
| 01-01-03 | 01 | 1 | COV-03 | unit | `Invoke-Pester -Path tests/ -Tag "COV-03"` | ❌ W0 | ⬜ pending |
| 01-01-04 | 01 | 1 | COV-04 | unit | `Invoke-Pester -Path tests/ -Tag "COV-04"` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/CoverageMatrix.Tests.ps1` — stubs for COV-01 through COV-04
- [ ] Pester 5.x installed — if not already available

*If none: "Existing infrastructure covers all phase requirements."*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Analyst readability of matrix format | COV-01 | Subjective layout judgment | Open COVERAGE-MATRIX.md, verify artifact types are scannable by row |
| Coverage gap completeness | COV-03 | Requires domain knowledge | Confirm DLLs/Users PS 2.0 absence, netstat PID loss, DNS TTL loss all listed |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
