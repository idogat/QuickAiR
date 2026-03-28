# Project Research Summary

**Project:** QuickAiR DFIR Toolkit — Production Documentation
**Domain:** Operational documentation for a PowerShell-based incident response collection and execution toolkit
**Researched:** 2026-03-24
**Confidence:** MEDIUM-HIGH (stack and architecture HIGH; DFIR community patterns MEDIUM due to unavailable external search)

## Executive Summary

This is a documentation-writing project, not a software project. The QuickAiR toolkit already exists as a mature codebase — the work is producing three operational reference documents that allow IR analysts to use the tool effectively without tribal knowledge. Research across all four areas converges on the same recommendation: write three focused, cross-linked documents (RUNBOOK.md, COVERAGE-MATRIX.md, INTERPRET.md) that divide content by analyst question, not by component. The format is constrained: GitHub-renderable CommonMark Markdown in a `docs/` folder, air-gap compatible, no external tooling required. These constraints are project-specified and eliminate all documentation site options.

The recommended approach has a firm build order driven by data dependencies: COVERAGE-MATRIX.md first (ground-truth for what is actually collected and at what fidelity), RUNBOOK.md second (operational commands and troubleshooting), INTERPRET.md third (Report.html analysis workflows). This order exists because the runbook's troubleshooting sections reference collection fallbacks that the coverage matrix documents, and the interpretation guide's "missing data" explanations reference specific gaps that the coverage matrix establishes. The end-to-end scenario workflow is a capstone that references all three and should be written last.

The highest-risk failure mode in this domain is aspirational documentation — writing for the happy path (PS 5.1, full WinRM connectivity, modern targets) without reflecting the fallback chains and degraded-mode behaviors analysts actually encounter on aging enterprise infrastructure. This toolkit has explicit PS 2.0 support, three executor fallback tiers, and multiple artifacts with no PS 2.0 collection path (DLLs.psm1, Users.psm1). These gaps must be first-class citizens in the documentation, not omissions. Wrong DFIR documentation is worse than no documentation — an analyst who trusts an inaccurate coverage matrix during an investigation will miss evidence.

## Key Findings

### Recommended Stack

The project format constraint is already resolved: CommonMark Markdown with GitHub Flavored Markdown extensions (tables, fenced code blocks) in a `docs/` folder. This is non-negotiable given the air-gap requirement and the need for GitHub rendering. No build tooling (MkDocs, GitBook, Sphinx) is appropriate. The "stack" for this project is a set of conventions: GFM tables for parameter and coverage grids, fenced `powershell` blocks for command examples, `> **Warning:**` blockquote callouts for critical notes, relative path anchor links for cross-document references. VS Code with built-in Markdown Preview is the authoring environment; GitHub.com is the post-push validation check.

See full details: `.planning/research/STACK.md`

**Core technologies:**
- CommonMark + GFM Markdown: all documentation — renders natively on GitHub, in VS Code, and in any local editor without tooling; survives air-gap; diff-friendly
- GFM tables: parameter references, artifact coverage grid, state/failure tables — scannable format analysts need under time pressure
- Fenced `powershell` code blocks: all command examples — enables syntax highlighting on GitHub and VS Code; clean copy-paste for analysts
- Blockquote callouts (`> **Warning:**`): prerequisites, critical notes, security warnings — visually distinct without requiring HTML or extensions
- Relative Markdown anchors (`[text](FILE.md#heading)`): cross-document links — works on GitHub, locally, and in VS Code without absolute URL dependencies

**Critical conventions:**
- Document only current codebase behavior — no aspirational documentation
- Quote exact console error output verbatim in troubleshooting (analysts Ctrl+F their error message)
- Always show full command examples with all required parameters, not minimal snippets
- Surface version numbers from script headers (Collector v2.2) so analysts can verify docs match binary

### Expected Features

All P1 features are table stakes — an analyst cannot operate the tool cold without them. P2 features meaningfully improve analysis quality. P3 features are high-value but deferred until v1 is validated.

See full details: `.planning/research/FEATURES.md`

**Must have (P1 — table stakes):**
- Prerequisites and setup steps (WinRM, TrustedHosts, admin rights, Register-QuickAiRProtocol.ps1) — first-run failure without this
- Full parameter reference for Collector.ps1, Executor.ps1, QuickAiRLaunch.ps1 — analysts cannot run tools without this
- Output file locations and naming conventions — analysts need to find results to load into Report.html
- Artifact inventory: what is collected, at what fidelity, via which fallback path — required to interpret results meaningfully
- Executor method chain explanation (WinRM → SMB+WMI → WMI) — analysts need to understand why their deployment fell back
- Troubleshooting sections keyed to actual terminal state names (CONNECTION_FAILED, TRANSFER_FAILED, LAUNCH_FAILED) — not generic advice
- Report.html tab navigation overview and data loading instructions — first-run friction removal for report use
- Cross-tab correlation patterns (Process → Network → DNS pivot) — core analytical value of the toolkit

**Should have (P2 — differentiators):**
- Artifact coverage matrix with explicit fallback columns and known gap section — makes the matrix authoritative, not just aspirational
- Fallback behavior per-collector in table form (CIM vs WMI vs netstat, fidelity loss at each tier)
- Context-sensitive error table mapped to specific codebase state names
- Manifest tab interpretation guide (collection metadata, collection_errors, source field)
- Anomaly pattern examples for junior analysts (orphaned processes, unsigned DLLs, DNS with no matching connection)
- Decision callouts for junior/senior audience split (Quick Reference boxes at section top)

**Defer (P3 — v2+):**
- Annotated end-to-end scenario workflow (collect → load → investigate → deploy) — high effort, requires all three v1 docs to exist first
- Deep-dive junior/senior structural restructuring — do after v1 exists and analyst feedback confirms which sections need it

**Anti-features to exclude:**
- IR methodology tutorial ("how to triage a compromise") — out of scope per PROJECT.md
- MITRE ATT&CK mapping — explicitly excluded per PROJECT.md
- Architecture diagrams in analyst docs — belongs in codebase map, not usage docs

### Architecture Approach

The three documents form a reference triangle, not a hierarchy. Each document owns a distinct concern and delegates to the others via relative anchor links rather than duplicating content. RUNBOOK.md owns command syntax, parameters, and operational troubleshooting. COVERAGE-MATRIX.md owns the artifact-to-data-source grid, fallback paths, and known gaps. INTERPRET.md owns Report.html tab navigation, cross-tab investigation workflows, and anomaly pattern guidance. README.md at the repo root is preserved and gains a Documentation section linking to all three — it delegates immediately and contains no substantive detail. The flat `docs/` layout (three files, no subdirectories) is intentional: subdirectories create navigation friction for analysts under time pressure.

See full details: `.planning/research/ARCHITECTURE.md`

**Major components:**
1. `docs/RUNBOOK.md` — operational command reference; parameters, execution modes, troubleshooting; delegates to COVERAGE-MATRIX.md for artifact detail and INTERPRET.md for analysis workflows
2. `docs/COVERAGE-MATRIX.md` — artifact coverage grid; what is collected, at which fallback tier, with explicit gap columns; delegates to RUNBOOK.md for collection parameters and INTERPRET.md for how gaps surface in Report.html
3. `docs/INTERPRET.md` — Report.html analyst guide; tab navigation, cross-tab pivot patterns, anomaly examples; delegates to COVERAGE-MATRIX.md for missing data explanations
4. `README.md` (updated, not replaced) — orientation and links to all three docs; no substantive content

**Key patterns:**
- Delegate, Don't Duplicate: facts live in exactly one document; other documents link with one-line summary + anchor
- Junior-First, Senior-Skip: every section opens with 1-2 sentence orientation; Quick Reference at top of each major section
- Fallback Chain as First-Class Citizen: CIM/WMI/netstat tiers and their fidelity differences are explicit in every relevant section, not buried in footnotes

### Critical Pitfalls

See full details: `.planning/research/PITFALLS.md`

1. **Aspirational documentation (happy-path only)** — Read ARCHITECTURE.md Data Flow and CONCERNS.md before writing any command section. Every behavior must document all fallback modes: PS 5.1 (CIM path), PS 3-4 (netstat/ipconfig fallback), PS 2.0 (WMI direct). A runbook that only shows the clean case will fail analysts running against Server 2008 R2 targets.

2. **Coverage matrix hides gaps** — The matrix must have explicit "Coverage gap," "Data absent when," and "Fallback path" columns. DLLs.psm1 has no PS 2.0 fallback. Users.psm1 has no fallback. Network.psm1's netstat fallback has a documented ~10% miss rate on high-churn targets. These gaps are already documented in CONCERNS.md; they must surface in the matrix, not be omitted.

3. **Interpretation guide as UI tour** — Write investigation scenarios first, then build tab descriptions to support them. The guide must include at least 3 cross-tab workflows (Process → Network → DNS pivot; unusual user session → process tree; DLL inspection path). Section headers that match tab names exactly (Processes, Network, DNS) with no workflow sections is a warning sign.

4. **Executor and Launcher documented in isolation** — Open the runbook with a system architecture overview showing the full integrated workflow: collection → report viewing → job launch (quickair:// URI) → execution → result refresh. Register-QuickAiRProtocol.ps1 is a required prerequisite; if not documented prominently, analysts will see a silent failure when nothing launches from Report.html.

5. **Troubleshooting derived from guesses, not code** — Build the troubleshooting table directly from CONCERNS.md Known Bugs and Fragile Areas + ARCHITECTURE.md Error Handling terminal states. Fewer than 8-10 distinct failure scenarios for a toolkit this complex is a warning sign. Generic "check your credentials" entries must not appear.

## Implications for Roadmap

Based on the combined research, a 4-phase structure is recommended. The build order is not arbitrary — it follows hard data dependencies between documents and between documents and their source material.

### Phase 1: Artifact Coverage Matrix

**Rationale:** COVERAGE-MATRIX.md is the ground-truth anchor for both other documents. The runbook's troubleshooting sections and the interpretation guide's "missing data" explanations both reference it. Writing it first means subsequent document authors have a reference to link to, not a gap to re-explain. This phase requires reading the actual collector modules (Processes.psm1, Network.psm1, DLLs.psm1, Users.psm1) to confirm what each collects at each fallback tier — this is validation work that must happen before prose is written.
**Delivers:** `docs/COVERAGE-MATRIX.md` — artifact × data source grid with explicit fallback columns, known gap section, manifest error interpretation, PS version requirements per artifact
**Addresses (P1):** Artifact inventory; fallback path visibility; coverage gap documentation
**Addresses (P2):** Fallback behavior per-collector; manifest tab interpretation groundwork
**Avoids:** Pitfall 2 (matrix hides gaps) — gap columns are structural requirements from the start, not additions after the fact
**Research flag:** Standard patterns — codebase map is authoritative; no external research needed; read collector .psm1 source files directly

### Phase 2: Operational Runbook

**Rationale:** The runbook is the entry point for analysts new to the tool. It must exist before the interpretation guide because analysts cannot meaningfully analyze results until they can successfully collect data. This phase is the most complex — it covers three entry points (Collector, Executor, Launcher) and their integration via the quickair:// URI scheme, and must derive troubleshooting from CONCERNS.md rather than inference.
**Delivers:** `docs/RUNBOOK.md` — prerequisites and setup, full parameter references for all three scripts, executor method chain, integrated workflow overview, troubleshooting tables keyed to actual terminal state names
**Addresses (P1):** Prerequisites; parameter references; output file locations; executor method chain; troubleshooting; SHA256 integrity explanation
**Addresses (P2):** Context-sensitive error table; decision callouts (Quick Reference boxes)
**Avoids:** Pitfall 1 (aspirational documentation) — start by reading ARCHITECTURE.md Data Flow and CONCERNS.md before any writing; Pitfall 5 (Executor/Launcher isolation) — architecture overview section written before component sections; Pitfall 6 (troubleshooting from guesses) — derive from CONCERNS.md explicitly
**Research flag:** Standard patterns — ARCHITECTURE.md and CONCERNS.md are authoritative; codebase param blocks are source of truth; no external research needed

### Phase 3: Report.html Analyst Interpretation Guide

**Rationale:** INTERPRET.md is the most content-dense document. It benefits from coverage gaps being documented (Phase 1) so it can link rather than re-explain missing data, and from the runbook existing (Phase 2) so it can assume analysts know how to collect. Investigation workflow sections must be written before tab reference sections — scenarios drive the structure, not UI element enumeration.
**Delivers:** `docs/INTERPRET.md` — data loading, tab navigation, cross-tab investigation workflows (minimum 3), anomaly pattern examples for each major artifact type, manifest tab interpretation, Execute tab workflow
**Addresses (P1):** Report.html navigation; data loading; cross-tab correlation patterns
**Addresses (P2):** Anomaly pattern examples; manifest tab guide
**Avoids:** Pitfall 4 (UI tour instead of analyst workflow) — write investigation scenarios first, tab descriptions second
**Research flag:** Standard patterns — Report.html tab behavior is documented in ReportStages/*.js and codebase map; no external research needed; verify tab interaction behavior against actual Report.html source

### Phase 4: README Update and Integration Review

**Rationale:** The root README.md is the repo landing page. It must be updated last — after all three docs exist — so the links it adds are accurate and the one-line descriptions of each doc reflect the actual content written. This phase also includes a cross-document consistency pass: verify all anchor links resolve, all cross-references are bidirectional and accurate, and all parameter names match the current codebase.
**Delivers:** Updated `README.md` with Documentation section linking to all three docs; verified anchor links across all docs; consistency review against current codebase
**Addresses:** Cross-reference integrity; first-impression orientation for new analysts
**Avoids:** Broken links (anchor links break if heading text changes during authoring — final review catches these); parameter name drift (docs written at different times may reference outdated param names)
**Research flag:** Skip — README update and link verification are mechanical tasks; no research needed

### Phase Ordering Rationale

- **Data dependency drives order:** COVERAGE-MATRIX.md must precede both other docs because it is referenced by both. RUNBOOK.md must precede INTERPRET.md because analysts cannot meaningfully use the report without knowing how to collect successfully.
- **Pitfall prevention drives structure within each phase:** The most dangerous pitfalls (aspirational documentation, coverage gaps, UI tour) are phase-specific. Addressing them requires structural decisions at the start of each phase, not corrections after drafting.
- **Codebase is authoritative, not README.md:** The existing README.md may lag the codebase. All parameter names, defaults, and output paths must be verified against the actual `.ps1` and `.psm1` source files before documentation is finalized.
- **End-to-end scenario is a capstone, not Phase 1:** The annotated workflow that references all three docs cannot be written until all three docs exist. It is a P3 feature deferred until v1 docs are validated.

### Research Flags

Phases with standard patterns (skip `/gsd:research-phase`):
- **Phase 1 (Coverage Matrix):** Ground truth is the collector .psm1 source files and CONCERNS.md. Both are available in the codebase map. Read source, write matrix.
- **Phase 2 (Runbook):** Ground truth is the script param blocks, ARCHITECTURE.md, and CONCERNS.md. All available. Derive troubleshooting from error handling code, not inference.
- **Phase 3 (Interpretation Guide):** Ground truth is ReportStages/*.js for tab behavior and the existing codebase map. Verify against actual Report.html behavior.
- **Phase 4 (README + Review):** Mechanical — no research needed.

No phases require external research. All source material exists in the codebase or is project-specified. DFIR community documentation patterns are MEDIUM confidence but sufficient — the key decisions (three documents, build order, fallback visibility, junior-first structure) are grounded in the codebase constraints, not community convention.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Project constraint specifies Markdown; format is non-negotiable. GFM table and fenced block conventions are universal. Verified against codebase and rendering requirements. |
| Features | HIGH | Based on verified codebase analysis (param blocks, collector modules, Report.html tabs). Feature list derived from actual code, not inference. DFIR audience patterns MEDIUM but adequate. |
| Architecture | HIGH | Three-document structure derived from clear content ownership boundaries. Build order follows hard data dependencies. Patterns (delegate, junior-first, fallback-visible) are straightforward to apply. |
| Pitfalls | HIGH | Derived from direct codebase analysis (ARCHITECTURE.md, CONCERNS.md, STRUCTURE.md). Known bugs and fragile areas are documented in CONCERNS.md — pitfall prevention is a matter of reading that file before writing, not guesswork. |

**Overall confidence:** HIGH for structure, build order, and format decisions. MEDIUM for DFIR community documentation conventions (no external search available — recommendations cross-checked against project constraints and codebase but not against 2025-2026 community publications).

### Gaps to Address

- **CONCERNS.md must be read before Phase 2 begins:** The troubleshooting section quality depends entirely on deriving entries from Known Bugs and Fragile Areas in CONCERNS.md. If this file has been updated since the codebase map was created, re-read it.
- **Collector .psm1 source files must be read before Phase 1 begins:** The coverage matrix fallback paths and gap cells must match actual collection behavior, not the architecture summary. Read Processes.psm1, Network.psm1, DLLs.psm1, Users.psm1 directly.
- **Report.html tab behavior verification:** INTERPRET.md must reflect actual tab behavior. The codebase map covers ReportStages/*.js but behavior should be verified against the actual HTML file, especially for the Execute tab and Manifest tab fields.
- **Parameter defaults:** All parameter default values documented in RUNBOOK.md must be verified against actual param block defaults in the .ps1 files — not from README.md or memory.

## Sources

### Primary (HIGH confidence)
- `.planning/codebase/ARCHITECTURE.md` — fallback chains, error handling, data flow, terminal failure states
- `.planning/codebase/CONCERNS.md` — known bugs, fragile areas, security considerations, documentation gaps
- `.planning/codebase/STRUCTURE.md` — collector plugin list, executor modules, ReportStages structure
- `.planning/codebase/STACK.md` — PowerShell version requirements, WinForms usage, JSON output schema
- `.planning/PROJECT.md` — scope constraints, audience requirements, format requirements (authoritative)
- Codebase param blocks (Collector.ps1, Executor.ps1, QuickAiRLaunch.ps1) — parameter source of truth

### Secondary (MEDIUM confidence)
- DFIR tool documentation patterns (Velociraptor, KAPE, Eric Zimmerman's tools, IRIS-H) — training data knowledge, not verified against current publications; used to inform structural recommendations
- Technical writing conventions for CLI tools and operational runbooks — well-established patterns; verified against project constraints

### Tertiary (LOW confidence — validate if needed)
- Current DFIR community standards for artifact coverage documentation — not verified due to search tool unavailability; spot-check against SANS FOR508 materials or Velociraptor docs if community alignment is required before roadmap finalization

---
*Research completed: 2026-03-24*
*Ready for roadmap: yes*
