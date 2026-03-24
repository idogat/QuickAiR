# Architecture Research

**Domain:** DFIR toolkit production documentation set
**Researched:** 2026-03-24
**Confidence:** HIGH (derived from existing codebase map + established IR documentation practices)

## Standard Architecture

### System Overview

The three required documents serve different audiences at different points in the workflow. They are not independent — they form a reference triangle where each document delegates to the others rather than duplicating content.

```
┌─────────────────────────────────────────────────────────────┐
│                     ANALYST ENTRY POINT                      │
│                                                              │
│   "How do I run this?"    "What did I collect?"    "What    │
│   (new to tool)           (coverage question)       does    │
│                                                     this    │
│                                                    mean?"   │
└────────────┬──────────────────┬──────────────────────┬──────┘
             │                  │                      │
             ▼                  ▼                      ▼
┌────────────────┐  ┌──────────────────────┐  ┌──────────────┐
│   RUNBOOK.md   │  │  COVERAGE-MATRIX.md  │  │  INTERPRET.md│
│                │  │                      │  │              │
│ Operational    │  │ Artifact × data      │  │ Report.html  │
│ commands,      │  │ source grid.         │  │ tab-by-tab   │
│ parameters,    │  │ What's collected,    │  │ guide.       │
│ troubleshoot.  │  │ fallback paths,      │  │ What to look │
│                │  │ coverage gaps.       │  │ for, pivots, │
│ → links to     │  │ → links to RUNBOOK   │  │ anomaly      │
│   INTERPRET    │  │   for collection     │  │ patterns.    │
│   (next step)  │  │   parameters         │  │              │
│ → links to     │  │ → links to INTERPRET │  │ → links to   │
│   COVERAGE     │  │   for what gaps mean │  │   COVERAGE   │
│   (what you    │  │   at analysis time   │  │   (fallback  │
│   collected)   │  │                      │  │   context)   │
└────────────────┘  └──────────────────────┘  └──────────────┘
             │                  │                      │
             └──────────────────┴──────────────────────┘
                                │
                                ▼
                      ┌──────────────────┐
                      │    README.md     │
                      │  (entry point,   │
                      │  orientates to   │
                      │  all three)      │
                      └──────────────────┘
```

### Component Responsibilities

| Document | Owns | Does NOT Own |
|----------|------|--------------|
| `docs/RUNBOOK.md` | Command syntax, parameters, execution modes, troubleshooting failures | What artifacts mean forensically; what gaps mean for investigation |
| `docs/COVERAGE-MATRIX.md` | Artifact × data source grid, fallback paths, known gaps | How to run collection; how to interpret findings in Report.html |
| `docs/INTERPRET.md` | Report.html tab navigation, cross-tab pivots, anomaly patterns | Command syntax; codebase internals |
| `README.md` (root) | Orientation paragraph + links to all three docs | Any substantive detail (delegates immediately) |

## Recommended Project Structure

```
docs/
├── RUNBOOK.md               # Operational command reference + troubleshooting
├── COVERAGE-MATRIX.md       # Artifact coverage grid (what's collected where)
└── INTERPRET.md             # Report.html analyst interpretation guide

README.md                    # Root file links to docs/ (updated, not replaced)
```

### Structure Rationale

- **docs/ flat layout:** Three documents, no subdirectories needed. Subdirs create navigation friction for operational use — analysts under time pressure need one folder, not a tree.
- **Separate files per concern:** Each doc can be open in a separate browser tab or editor pane during an investigation. One monolithic doc forces scrolling past irrelevant content.
- **Root README preserved:** The existing README.md stays at root and gains a "Documentation" section pointing to docs/. This follows standard repo conventions and ensures GitHub renders it on the landing page.
- **Filename choices:** All uppercase to stand out in `ls` output. Avoid spaces. `COVERAGE-MATRIX.md` is more descriptive than `MATRIX.md` or `ARTIFACTS.md`.

## Architectural Patterns

### Pattern 1: Delegate, Don't Duplicate

**What:** When one document needs to reference material owned by another, it links with a one-line summary and a relative path anchor (`[See RUNBOOK.md — Collector parameters](RUNBOOK.md#collector-parameters)`). It does not copy the content.

**When to use:** Everywhere a second document would need to know the same fact. The test: "if this fact changes, how many files need updating?" Should always be one.

**Trade-offs:** Requires working anchor links (Markdown heading anchors). If heading text changes, links break. Mitigate by keeping heading names stable and descriptive.

### Pattern 2: Junior-First, Senior-Skip Pattern

**What:** Each major section opens with a 1-2 sentence orientation ("what this section is for, what you need before reading it"), then provides the full detail. Senior analysts can read the heading, skip the orientation, and proceed. Junior analysts read straight through.

**When to use:** All three documents. Especially important in RUNBOOK.md (juniors need more hand-holding on parameters) and INTERPRET.md (juniors need anomaly explanations; seniors want the pattern list without the explanation).

**Trade-offs:** Slightly more text. Worth it given the mixed-audience requirement stated in PROJECT.md.

### Pattern 3: Fallback Chain as First-Class Citizen

**What:** The toolkit's core design is tiered fallback (WinRM → SMB+WMI → WMI for execution; CIM → WMI → netstat for collection). Documentation must reflect this explicitly — not bury it in footnotes. COVERAGE-MATRIX.md is structured around fallback columns. RUNBOOK.md troubleshooting is organized by which tier failed.

**When to use:** Whenever documenting a behavior that has a fallback. Make the fallback visible, not assumed.

**Trade-offs:** Can feel repetitive if the reader already understands the fallback model. Acceptable cost for clarity.

## Data Flow

### How a New Analyst Navigates the Docs

```
Analyst arrives with task: "Collect from 10 targets, then review results"
    │
    ▼
README.md (root)
    │  "For operational use, see docs/"
    ▼
docs/RUNBOOK.md
    │  Runs Collector.ps1 and Executor.ps1
    │  Sees collection complete
    │  "What did I actually collect? → COVERAGE-MATRIX.md"
    ▼
docs/COVERAGE-MATRIX.md
    │  Confirms processes, network, DNS, users, DLLs collected
    │  Notes: DLLs only collected on CIM-capable targets
    │  "Now I need to analyze. → INTERPRET.md"
    ▼
docs/INTERPRET.md
    │  Opens Report.html
    │  Navigates Processes tab, sees anomalous parent-child relationship
    │  Pivots to Network tab using cross-reference guidance
    │  "Why is DNS data missing for one host? → COVERAGE-MATRIX.md"
    ▼
docs/COVERAGE-MATRIX.md
    │  Confirms: DNS collection requires CIM or ipconfig fallback
    │  Legacy target fell back to netstat; DNS cache not captured
    ▼
Analyst understands gap, proceeds with investigation
```

### Cross-Reference Flow

```
RUNBOOK.md
  → COVERAGE-MATRIX.md  ("After collection, see coverage matrix for what was gathered")
  → INTERPRET.md        ("To analyze results, see interpretation guide")

COVERAGE-MATRIX.md
  → RUNBOOK.md          ("To control collection parameters, see runbook")
  → INTERPRET.md        ("For what gaps mean during analysis, see interpretation guide")

INTERPRET.md
  → COVERAGE-MATRIX.md  ("For fallback context on missing data, see coverage matrix")
  (no link to RUNBOOK — interpretation happens after collection, forward direction only)
```

## Document Boundaries (What Goes Where)

### RUNBOOK.md

Owns all operational content:

- **Prerequisites** — admin rights requirement, WinRM setup, TrustedHosts, quicker:// URI registration
- **Collector.ps1** — all parameters with types, defaults, and examples; output path and file naming; what happens on each target type (local vs remote)
- **Executor.ps1** — all parameters; execution method selection; result JSON location and fields
- **QuickerLaunch.ps1** — how it launches (URI scheme, not CLI); job batch format; bridge file mechanism; single-instance behavior
- **Troubleshooting** — organized by symptom ("Collection returns zero processes", "WinRM connection refused", "Launcher does not open"); maps to executor fallback chain
- **TestSuite.ps1** — how to run, what passes/fails mean

Does NOT own:
- Artifact definitions (what a process, connection, DLL means forensically)
- Report.html navigation
- The artifact-to-data-source mapping grid

### COVERAGE-MATRIX.md

Owns the artifact grid:

- **Matrix table** — rows: artifact types (Processes, TCP Connections, DNS Cache, DLLs, Users); columns: collection method (CIM/PS5.1, WMI/PS2.0, Legacy fallback, Not available); cells: checkmark / partial / gap
- **Fallback path descriptions** — one paragraph per artifact explaining the three collection tiers and what degrades at each tier
- **Known gaps** — DLLs on PS2.0 targets (not collected), DNS on legacy OS (ipconfig fallback returns subset), netstat miss rate on high-churn workloads
- **Manifest errors** — what collection_errors in the manifest JSON means; how to read it to understand what failed

Does NOT own:
- Command syntax for controlling collection
- How to view the data in Report.html

### INTERPRET.md

Owns all Report.html analysis content:

- **Loading data** — file picker and drag-and-drop; SHA256 validation; what the "invalid JSON" error means
- **Fleet tab** — host summary counts; how to switch active host; what "no data" for a host means
- **Processes tab** — tree structure; parent-child columns; how to spot orphaned processes; network pivot from process row
- **Network tab** — TCP connection fields; process correlation column; filtering by state; what CLOSE_WAIT/TIME_WAIT indicate
- **DNS tab** — cache entries; cross-reference with connections; what missing DNS for a connected IP means
- **DLLs tab** — per-process DLL list; what to look for (unsigned DLLs, unusual paths)
- **Users tab** — session types; what logon type codes mean
- **Manifest tab** — reading collection metadata; interpreting collection_errors; checking source field to understand which fallback ran
- **Execute tab** — building a job batch; launching QuickerLaunch; refreshing execution results
- **Cross-tab investigation patterns** — 3-4 worked examples (suspicious outbound connection → pivot to process → check DLLs; unusual user session → pivot to process tree)

Does NOT own:
- Why data may be missing (that's COVERAGE-MATRIX.md)
- How to re-run collection (that's RUNBOOK.md)
- General DFIR methodology beyond the tool's scope

## Build Order

**Write COVERAGE-MATRIX.md first.** Rationale:

1. The matrix requires reading the actual collector modules (Processes.psm1, Network.psm1, DLLs.psm1, Users.psm1) to confirm what each collects at each fallback tier. This is ground-truth validation work that anchors the other documents.
2. RUNBOOK.md troubleshooting sections reference collection fallbacks — writing coverage first means runbook authors have a reference to link to rather than re-explain.
3. INTERPRET.md's "missing data" explanations reference specific gaps documented in the coverage matrix. Writing coverage first means interpretation authors don't have to derive this independently.

**Write RUNBOOK.md second.** It depends only on the codebase (which is already mapped) and needs no dependency on INTERPRET.md or COVERAGE-MATRIX.md beyond links.

**Write INTERPRET.md third.** It is the most content-dense document and benefits from coverage gaps already being documented so it can link rather than explain them inline.

```
Build order:
1. COVERAGE-MATRIX.md  (ground truth: what's actually collected)
2. RUNBOOK.md          (operations: how to run the tools)
3. INTERPRET.md        (analysis: how to read the results)
4. README.md update    (orientation: links to all three)
```

## Anti-Patterns

### Anti-Pattern 1: One Large File

**What people do:** Combine runbook + coverage + interpretation into a single `DOCUMENTATION.md` or extend README.md.

**Why it's wrong:** Analysts use these docs at different times in an investigation. Combining them forces scrolling past irrelevant material during time-sensitive IR work. A 3000-line single file is also harder to maintain — a parameter change in Collector.ps1 requires hunting through prose to find every mention.

**Do this instead:** Three focused files with explicit cross-reference links. Each file can be found, open, and navigated independently.

### Anti-Pattern 2: Duplicating Fallback Explanations Across Docs

**What people do:** Each document explains the WinRM → SMB+WMI → WMI fallback chain, the CIM → WMI → netstat tiers, and the capability probe.

**Why it's wrong:** When the codebase changes (new executor method, new fallback tier), the explanation must be updated in multiple places. One will be missed.

**Do this instead:** COVERAGE-MATRIX.md owns the canonical fallback path descriptions. RUNBOOK.md and INTERPRET.md link to it with one-line summaries ("For full fallback details, see COVERAGE-MATRIX.md").

### Anti-Pattern 3: Aspirational Documentation

**What people do:** Document parameters, behaviors, or fallback paths that don't yet exist or that differ from the current implementation.

**Why it's wrong:** In DFIR, wrong documentation is worse than no documentation. An analyst who trusts a doc that says "DLLs are collected on all targets" and acts on that assumption during an investigation will miss evidence.

**Do this instead:** All parameters, paths, and behaviors must be verified against the current codebase before writing. The codebase map at `.planning/codebase/` is the authoritative source. When in doubt, read the source file.

### Anti-Pattern 4: Mixing Audience Levels Without Structure

**What people do:** Write for one audience (usually senior), leaving juniors unable to follow; or write everything for juniors, bloating the doc so seniors stop using it.

**Do this instead:** Junior-First, Senior-Skip pattern (see Pattern 2 above). Orientation paragraph + skip-friendly section headers allow both audiences to use the same document efficiently.

### Anti-Pattern 5: Embedding Tool Output Examples Without Context

**What people do:** Paste raw JSON output or PowerShell error text without explaining which fields are significant.

**Why it's wrong:** Junior analysts can't distinguish significant fields from boilerplate. The doc becomes a wall of output that nobody reads.

**Do this instead:** Show abbreviated output with callout comments inline. In Markdown: use code blocks with `# <-- this field indicates...` comments. Show only the fields being discussed, not entire JSON objects.

## Integration Points

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| RUNBOOK.md → COVERAGE-MATRIX.md | Relative link to heading anchor | "After collection, see [COVERAGE-MATRIX.md — Artifact Grid](COVERAGE-MATRIX.md#artifact-grid)" |
| RUNBOOK.md → INTERPRET.md | Relative link | "To analyze results, see [INTERPRET.md](INTERPRET.md)" — only at end of runbook sections, not inline |
| COVERAGE-MATRIX.md → RUNBOOK.md | Relative link to parameter section | "To adjust collection parameters, see [Collector.ps1 parameters](RUNBOOK.md#collector-parameters)" |
| COVERAGE-MATRIX.md → INTERPRET.md | Relative link to Manifest tab section | "For how gaps surface in Report.html, see [INTERPRET.md — Manifest tab](INTERPRET.md#manifest-tab)" |
| INTERPRET.md → COVERAGE-MATRIX.md | Relative link from "missing data" callouts | "If data is absent for this tab, see [COVERAGE-MATRIX.md — Known Gaps](COVERAGE-MATRIX.md#known-gaps)" |
| README.md → all three | Relative links from Documentation section | Simple list: three files, one-line description each |

### Codebase Dependency Map

The documentation set does not modify code. It reads from these sources during authoring:

| Source | Used by |
|--------|---------|
| `Collector.ps1` parameter block | RUNBOOK.md parameter table |
| `Executor.ps1` parameter block | RUNBOOK.md parameter table |
| `QuickerLaunch.ps1` launch mechanism | RUNBOOK.md launch section |
| `Modules/Collectors/*.psm1` source functions | COVERAGE-MATRIX.md artifact rows |
| `Modules/Executors/*.psm1` method logic | RUNBOOK.md troubleshooting + COVERAGE-MATRIX.md executor column |
| `ReportStages/*.js` tab names and behavior | INTERPRET.md section structure |
| `.planning/codebase/ARCHITECTURE.md` | All three docs (fallback chains, data flow) |
| `.planning/codebase/CONCERNS.md` | RUNBOOK.md troubleshooting (known bugs, fragile areas) |

## Scaling Considerations

| Concern | Now (3 docs) | If toolkit grows |
|---------|--------------|------------------|
| New collector plugin added | Add row to COVERAGE-MATRIX.md; add tab section to INTERPRET.md | Pattern scales linearly — one row, one section per artifact |
| New executor method added | Add troubleshooting section to RUNBOOK.md; add column to COVERAGE-MATRIX.md | Same linear pattern |
| New Report.html tab added | Add section to INTERPRET.md | One section per tab |
| Docs outgrow flat structure | Still manageable up to ~10 docs | At 10+ docs, add docs/index.md as navigation hub |

---

*Architecture research for: DFIR toolkit production documentation*
*Researched: 2026-03-24*
