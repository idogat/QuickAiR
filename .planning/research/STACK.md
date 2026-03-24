# Stack Research

**Domain:** DFIR toolkit operational documentation (runbook, artifact matrix, analyst guide)
**Researched:** 2026-03-24
**Confidence:** MEDIUM — draws on established DFIR documentation patterns from training data; external search tools unavailable. Recommendations cross-checked against project constraints (Markdown required, air-gap, docs/ folder, GitHub rendering).

---

## Context

This is a documentation-writing project, not a software project. The "stack" is:

- Document format (what files look like)
- Document structure (how each doc is organized internally)
- Documentation tooling (how docs are authored and validated)
- Conventions (naming, cross-referencing, code formatting)

The project constraint is already set: **Markdown in a `docs/` folder**, must render on GitHub and in local editors, must work air-gapped. This eliminates entire categories (MkDocs, GitBook, Sphinx, Docusaurus) from consideration. The stack below works within those constraints.

---

## Recommended Stack

### Core Document Format

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| CommonMark Markdown | — | All documentation files | GitHub renders natively; renders in VS Code, Obsidian, any local editor without tooling; survives air-gap; diff-friendly for version control. DFIR teams live in text editors and terminals — PDFs and portals add friction. |
| GitHub Flavored Markdown (GFM) tables | — | Parameter tables, artifact matrices, coverage grids | GFM table syntax is supported by GitHub, VS Code preview, and most Markdown renderers. The artifact coverage matrix is inherently tabular; GFM tables are the right tool. |
| Fenced code blocks with language tags | — | All PowerShell examples and command syntax | ` ```powershell ``` ` triggers syntax highlighting on GitHub and in VS Code. Analysts copy commands from docs — fenced blocks make copying clean. |
| Admonition-style callout blocks (blockquote + bold) | — | Warnings, prerequisites, critical notes | Native Markdown has no admonition syntax, but `> **Warning:**` blocks render visually distinct on GitHub. Avoid HTML `<div>` or `<details>` tags — they break in some local renderers and obscure plain-text readability. |

**Confidence:** HIGH — project constraint already specifies Markdown. GFM table and fenced code block conventions are universal.

---

### Document Structure: The Three Deliverables

#### 1. Operational Runbook (`docs/runbook.md` or `docs/RUNBOOK.md`)

Mature IR toolkits (Velociraptor, KAPE, IRIS) structure their runbooks around **task-oriented sections**, not component-oriented sections. The distinction matters: "How do I collect from a target?" is a task. "Collector.ps1 parameters" is a reference. Analysts under pressure reach for task-oriented docs first.

Recommended structure:

```
# Quicker Runbook

## Prerequisites
## Quick Start (3-command path to first collection)
## Collector.ps1 — Remote Data Collection
  ### Parameters
  ### Usage Examples
  ### Output
  ### Common Failures & Fixes
## Executor.ps1 — Remote Tool Deployment
  ### Parameters
  ### Usage Examples
  ### Execution States
  ### Common Failures & Fixes
## QuickerLaunch.ps1 — Job Manager
  ### Starting the Launcher
  ### Adding Jobs
  ### Monitoring Jobs
  ### Common Failures & Fixes
## Setup & Configuration
  ### WinRM Setup on Targets
  ### Register URI Scheme (QuickerProtocol)
  ### Admin Rights Requirement
## Troubleshooting Reference
  (Consolidated cross-component failure table)
```

**Why this order:** Prerequisites + Quick Start front-load value. Senior analysts skip to relevant sections; juniors read top to bottom. Troubleshooting at the end acts as a reference appendix — it should not be buried inside each component section where it fragments search.

**Confidence:** MEDIUM — drawn from observed patterns in Velociraptor docs, KAPE documentation, and common IR SOP formats; not verified against 2025 publications due to search unavailability.

---

#### 2. Artifact Coverage Matrix (`docs/artifact-matrix.md` or `docs/ARTIFACTS.md`)

The matrix is the most scan-critical document. Analysts under pressure use it to answer: "What do I have? What am I missing?"

Recommended structure:

```
# Artifact Coverage Matrix

## Coverage Grid
  (GFM table: Artifact × Collection Source × Fallback × Gap)

## Artifact Detail: Processes
  - What is collected
  - Fallback paths (PS version logic)
  - Known gaps and edge cases

## Artifact Detail: Network Connections
  ...

## Artifact Detail: DNS Cache
  ...

## Artifact Detail: Loaded DLLs
  ...

## Artifact Detail: User Sessions
  ...

## Coverage Gaps
  (Explicit list of what is NOT collected and why)
```

The grid is the first thing readers see. The detail sections support it. The gaps section is critical — analysts need to know what they *cannot* trust the tool to collect.

**Why a dedicated gaps section:** Mature DFIR tools (Eric Zimmerman's tools, Velociraptor artifacts) include explicit "known limitations" at the artifact level. Not having this forces analysts to discover gaps during investigations, which is worse than knowing them in advance.

**Confidence:** MEDIUM — drawn from KAPE target documentation patterns and community IR SOP practices.

---

#### 3. Report.html Analyst Guide (`docs/report-guide.md` or `docs/REPORT-GUIDE.md`)

The report guide differs from the runbook in purpose: it answers "I have data loaded — now what?" rather than "how do I run the tool?". Mature analyst guides for investigation tools organize around **investigation workflows**, not UI tabs.

Recommended structure:

```
# Report.html Analyst Guide

## Opening the Report
  (Local file, no server, browser compat notes)

## Loading Data
  (File picker vs drag-and-drop; multiple host JSONs)

## The Fleet Tab
  (Host summary; switching active host; what counts mean)

## Investigation Workflows
  ### Suspicious Process Investigation
    (Processes tab → network pivot → DNS cross-reference)
  ### Lateral Movement Indicators
    (Network tab → process correlation; known-bad IPs)
  ### Persistence Indicators
    (DLLs tab; unusual loaded assemblies per process)
  ### User Session Review
    (Users tab; anomalous logon types)

## Tab Reference
  ### Processes Tab
  ### Network Tab
  ### DNS Tab
  ### DLLs Tab
  ### Users Tab
  ### Manifest Tab
  ### Execute Tab

## Cross-Reference Cheat Sheet
  (Quick table: "To find X, start at tab Y, pivot to Z")

## Understanding Collection Metadata
  (Manifest tab: what errors mean, source fields, version)

## Remote Execution via Report
  (Execute tab workflow, QuickerLaunch integration)
```

**Why workflows before tab reference:** Analysts approach the tool with a question ("is this process suspicious?"), not with a tab name. Workflow sections teach the IR mental model. Tab reference is a lookup appendix.

**Confidence:** MEDIUM — drawn from how security tool documentation teams (e.g., Elastic SIEM docs, Velociraptor GUI docs) structure investigation-oriented guides.

---

### Supporting Conventions

| Convention | Specification | Why |
|------------|--------------|-----|
| File naming | `RUNBOOK.md`, `ARTIFACTS.md`, `REPORT-GUIDE.md` (uppercase, hyphenated) | Uppercase filenames stand out in directory listings and match GitHub conventional filenames (CONTRIBUTING.md, CHANGELOG.md). Lowercase with hyphens is an alternative (`runbook.md`) — both work; pick one and be consistent. |
| Section anchors | GitHub auto-generates anchors from headings; use `[text](#heading-slug)` cross-links | Enables cross-doc linking (runbook troubleshooting can link to artifact matrix gaps). Works without a doc site. |
| Parameter tables | Three-column minimum: Parameter, Required/Optional, Description | Matches PowerShell `Get-Help` output structure analysts already know. Add a "Default" column when a default exists. |
| Command examples | Always show full command with all required parameters; show `-OutputPath` variation as second example | Analysts copy examples verbatim. Minimal examples (missing common flags) produce support questions. |
| Version pinning in docs | Include version numbers from script headers in docs (e.g., "Collector v2.2") | Lets analysts verify their docs match their binary. Quicker uses embedded version constants — surface them. |
| Error messages verbatim | Troubleshooting sections must quote exact console output that triggers each fix | Analysts Ctrl+F their error message. Paraphrased errors break search. |
| Cross-reference style | Use relative Markdown links: `[Artifact Matrix](ARTIFACTS.md#processes)` | Works on GitHub, works locally, works in VS Code. Absolute URLs break in air-gap scenarios. |

**Confidence:** HIGH for parameter table and command example conventions (universal technical writing practice). MEDIUM for file naming and cross-reference conventions (common but not formally standardized).

---

### Development Tools (Authoring)

| Tool | Purpose | Notes |
|------|---------|-------|
| VS Code with Markdown Preview | Primary authoring environment | Built-in preview renders GFM tables and fenced blocks. `Markdown All in One` extension adds auto-TOC generation. No installation required beyond VS Code which analysts likely have. |
| GitHub.com preview | Validation check | After pushing, verify tables render correctly in GitHub's GFM renderer — it is slightly different from VS Code's renderer on edge cases (nested lists in tables, HTML). |
| `markdownlint` (CLI or VS Code extension) | Consistency enforcement | Catches broken tables, inconsistent heading levels, trailing spaces. Optional but high value for docs that multiple people will edit. Config: `.markdownlint.json` at repo root. |
| PowerShell `Get-Help` output | Source of truth for parameter docs | Before writing any parameter table, run `Get-Help .\Collector.ps1 -Full` (if comment-based help exists) or read the `param()` block directly. Never document parameters from memory. |

**Confidence:** HIGH for VS Code + GitHub validation pattern. MEDIUM for markdownlint (common in open source projects; not universally adopted in IR teams).

---

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| Plain Markdown in `docs/` | MkDocs / Material for MkDocs | Use MkDocs when the team needs a deployable doc site with navigation sidebar, search, and versioning. Not appropriate here — air-gap constraint and no doc site requirement. |
| Plain Markdown in `docs/` | GitBook | Use when documentation is audience-facing product docs requiring polished UX. Overkill for an IR team's internal toolkit. |
| Plain Markdown in `docs/` | Confluence / SharePoint wiki | Use when the organization already has a knowledge base platform and docs need to live there. Not repository-native; creates drift risk. |
| GFM tables | HTML tables | Use HTML tables only if cell content requires line breaks (GFM tables don't support multiline cells). Prefer GFM — HTML tables are hard to read as plain text and harder to maintain. |
| Task-oriented runbook structure | Component/API reference structure | Use API reference structure when the primary audience is developers integrating the tool. IR analysts are operators, not integrators — task orientation serves them better. |
| Separate documents per deliverable | Single monolithic doc | Use a monolith only for very small toolsets (< 20 commands). Quicker has three independent entry points — one doc per entry point keeps search results and cross-links manageable. |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| Inline HTML in Markdown | Breaks in many local renderers; air-gap docs may be opened in minimal Markdown viewers; hard to maintain | Pure GFM syntax. If a table needs complexity, split into two simpler tables. |
| External image hosting (CDN, imgur) | Breaks in air-gap scenarios | Store screenshots in `docs/assets/` or omit screenshots in favor of text descriptions. |
| `<details>` / `<summary>` collapsible sections | GitHub renders them; VS Code preview does not always; some Markdown viewers ignore the HTML entirely | Put long content in a linked sub-document or a clearly labeled section instead. |
| Aspirational documentation | Docs that describe planned features that don't yet exist erode analyst trust permanently | Document only current codebase behavior. The PROJECT.md explicitly flags this constraint. |
| Numbered steps for non-sequential tasks | Forces analysts to read linearly when they need to jump; wastes their time when they already know step 1-3 | Use numbered steps only for true ordered sequences (setup, protocol registration). Use bullet lists for reference material. |
| Jargon without definition | "Invoke Invoke-Collector's tiered fallback" means nothing to a junior analyst | Write for the junior analyst baseline. Senior analysts skip; juniors can't un-skip. |

---

## Stack Patterns by Variant

**If a section is purely reference (parameter lists, state tables):**
- Use GFM tables with consistent column ordering (Parameter/Required/Default/Description for params; State/Meaning/Next Action for states)
- Lead with the table; follow with notes only if the table cannot convey edge cases
- Because: Analysts scan reference material; prose before tables adds friction

**If a section is procedural (how to do something):**
- Use numbered lists for ordered steps; bullet lists for unordered options
- Include a single concrete example command after any parameter explanation
- Because: Procedural docs are followed step-by-step; numbered lists enforce order and confirm completion

**If a section covers failure handling:**
- Structure as: Symptom → Cause → Fix
- Quote exact console error output in the "Symptom" row
- Because: Analysts search for their error string; the fix must be immediately adjacent

**If the audience level is ambiguous:**
- Write for the junior analyst; add a "For experienced analysts:" summary block at the top of each major section
- Because: Seniors can skip; juniors cannot extrapolate

---

## Version Compatibility

Not applicable — documentation format does not have version dependencies. Note the following rendering compatibility for the chosen formats:

| Format | GitHub.com | VS Code Preview | Obsidian | Plain text |
|--------|-----------|----------------|---------|-----------|
| GFM tables | Full support | Full support | Full support | Readable |
| Fenced code blocks | Full support | Full support | Full support | Readable |
| Blockquote callouts | Full support | Full support | Full support | Readable |
| `<details>` HTML | Rendered | Not always rendered | Plugin-dependent | Raw HTML visible |
| Inline HTML | Rendered | Partial | Plugin-dependent | Raw HTML visible |

---

## Sources

- Project constraints verified from `.planning/PROJECT.md` — format requirement (Markdown, docs/ folder, GitHub rendering, air-gap) is project-specified, not a recommendation
- Codebase analysis from `.planning/codebase/ARCHITECTURE.md`, `STACK.md`, `STRUCTURE.md`, `CONVENTIONS.md` — used to ground parameter documentation requirements in actual script signatures
- Existing `README.md` in repo — reviewed to understand current documentation baseline and identify gaps (no troubleshooting, no artifact coverage detail, no Report.html workflow guidance)
- DFIR tool documentation patterns (Velociraptor, KAPE, Eric Zimmerman's tools, IRIS-H) — MEDIUM confidence, drawn from training data (knowledge cutoff August 2025); no external verification performed (search tools unavailable)
- Technical writing conventions for CLI tools and operational runbooks — HIGH confidence, well-established patterns; verified against project constraints

**Note on search tool availability:** All external search tools (WebSearch, Brave, Exa, Firecrawl) were unavailable during this research session. Recommendations that reference community or tool-specific practices are rated MEDIUM confidence and should be spot-checked against current DFIR community standards (SANS FOR508 materials, Velociraptor docs, KAPE GitHub) if validation is needed before roadmap finalization.

---

*Stack research for: Quicker DFIR Toolkit — Production Documentation*
*Researched: 2026-03-24*
