# Feature Research

**Domain:** DFIR toolkit production documentation (operational runbook, artifact coverage matrix, analyst interpretation guide)
**Researched:** 2026-03-24
**Confidence:** HIGH — based on verified codebase analysis and DFIR documentation domain knowledge

---

## Feature Landscape

### Table Stakes (Users Expect These)

Features analysts assume exist. Missing these = docs feel incomplete, analysts revert to guessing.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Complete parameter reference for all entry points | Analysts can't safely run Collector.ps1, Executor.ps1, or QuickAiRLaunch.ps1 without knowing required vs optional params, types, and defaults | LOW | Must cover: `-Targets`, `-Credential`, `-OutputPath`, `-AliveCheck`, `-Method`, `-Binary`, `-RemoteDest`. Defaults must match codebase (not aspirational). |
| Prerequisites and setup steps (WinRM, admin rights, URI scheme registration) | Junior analysts will try to run the tool on an unconfigured machine and fail silently — or with inscrutable errors | LOW | Must cover: `winrm quickconfig`, `Register-QuickAiRProtocol.ps1`, admin rights requirement, `TrustedHosts` setup. Common error: "Access denied" when not admin. |
| Troubleshooting section per entry point | First question from any analyst after a failure is "why did this not work?" — without this, they page senior staff | MEDIUM | Must map symptoms to causes: CONNECTION_FAILED, TRANSFER_FAILED, WinRM disabled, credential errors, SHA256 mismatch. Should use actual state names from the codebase. |
| Artifact inventory — what data is collected | Before an analyst collects, they need to know what they're getting — especially for scope-of-collection conversations with legal/management | LOW | Processes, TCP connections, DNS cache, DLL inventory, user sessions — plus which fallback path affects fidelity (CIM vs netstat vs cmd). |
| Report.html navigation overview | Analysts interact with all data through this one file — without a tab map, the report feels opaque | LOW | Must cover: Fleet tab, Processes, Network, DNS, DLLs, Users, Manifest, Execute. Tab function, not just tab name. |
| How to load data into Report.html | File picker vs drag-and-drop is non-obvious. First-run friction is high if not documented | LOW | Drag-and-drop JSON files or use file picker. Multi-host loading. What file to load from which output directory. |
| Executor method chain explanation | Analysts need to understand WHY their tool deployment fell back to WMI — not just that it did | LOW | WinRM (preferred) → SMB+WMI → WMI (legacy). Include when each method fails and which network ports are required. |
| Output file location reference | Analysts need to find their collection results to load into the report | LOW | `DFIROutput\<hostname>\<hostname>_<timestamp>.json` and `ExecutionResults\<hostname>_execution_<timestamp>.json`. Customizable via `-OutputPath`. |
| SHA256 integrity verification — what it means | Analysts see a sha256 field in every JSON output and need to know if/how to verify it | LOW | Embedded hash, checked by Report.html on load. Analyst doesn't need to verify manually — but should know what a "SHA256 mismatch" warning means. |
| Cross-reference between tabs in Report.html | The cross-tab correlation (process→network→DNS→DLL pivot) is the toolkit's core analytical value — if analysts don't know it exists, they miss it | MEDIUM | Pivot from Processes tab to Network tab by clicking a process. Filter Network tab by PID. DNS cross-reference with active connections. |

### Differentiators (What Makes These Docs Stand Out)

Features that distinguish useful operational docs from a README dump. Aligned with the project's core value: analysts operate the tool correctly without tribal knowledge.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Artifact coverage matrix with fallback path visibility | Senior analysts need to assess collection fidelity per target. Knowing that a PS 2.0 target gives netstat-only network data vs full CIM data changes how they interpret results. | MEDIUM | Grid: artifact (rows) × data source / fallback tier (columns). Mark which fidelity level each path provides. Include known gaps (no event logs, no registry). |
| Anomaly pattern examples in the interpretation guide | Telling a junior analyst "look for suspicious processes" is useless. Showing them a concrete example — a process with no parent, or a DNS entry for a known malicious domain pattern — is actionable. | HIGH | Examples should be realistic but synthetic. Cover: orphaned processes, unsigned binaries, connections to private IPs from unusual ports, DNS entries with no matching connection, DLL injection indicators. |
| Decision callouts for mixed junior/senior audience | Some sections need a "junior analyst: do this" path and a "senior analyst: also consider this" path. Mixing them creates noise for both audiences. | MEDIUM | Use callout boxes or clearly labeled subsections. Examples: "Quick start — run this command to collect" vs "Advanced — adjusting AliveCheck for slow networks." |
| Explicit coverage gap section in the artifact matrix | Documenting what the tool DOES NOT collect is as important as what it does. Analysts working a case need to know they must collect event logs separately. | LOW | Coverage gaps: no Windows Event Log, no registry hives, no file system triage, no memory (RAM) acquisition. Each gap should name an alternative tool/method. |
| Manifest tab interpretation guide | The Manifest tab is the best place to diagnose collection quality — it contains errors, source paths, and collection timestamps. Most analysts don't look at it. | MEDIUM | What each manifest field means. How to identify partial collection (errors array). How to read collection timestamps for timeline reconstruction. |
| Annotated example workflow (end-to-end scenario) | A worked example from "target identified" through "report loaded and findings noted" removes all the "what do I do next?" gaps | HIGH | Walk through: run Collector.ps1 against a single host, load JSON in Report.html, pivot from suspicious process to network connection to DNS lookup, deploy a triage tool via Execute tab. |
| Context-sensitive error table | Actual error messages or state names from the codebase mapped to likely cause and fix. Not generic "check your network." | MEDIUM | Map CONNECTION_FAILED, TRANSFER_FAILED, LAUNCH_FAILED, ALIVE check timeout to specific root causes. Include WinRM-specific codes. Use exact terminal state strings from Executor.ps1. |
| Fallback behavior explanation per collector | Analysts looking at a CIM-sourced result vs a netstat-fallback result need to know the fidelity difference — netstat misses short-lived connections and has no PID correlation for all connections on legacy OS | MEDIUM | Per-collector table: primary source, fallback source, what fidelity is lost in fallback, which OS versions trigger fallback. |

### Anti-Features (Commonly Requested, Often Problematic)

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| IR methodology tutorial ("how to triage a compromise") | Junior analysts want a guide for what to do, not just how to use the tool | Out of scope per PROJECT.md; adds maintenance burden when IR practices evolve; creates scope creep into textbook territory | Link or reference to a separate methodology document; keep toolkit docs focused on tool operation |
| MITRE ATT&CK mapping for each artifact | Looks comprehensive; gives the docs a "professional" feel | Explicitly excluded per PROJECT.md; MITRE mappings require ongoing maintenance and can mislead analysts into over-indexing on ATT&CK coverage | If needed later, treat as a separate milestone; don't embed in operational runbook |
| Code-level developer documentation | Developers want to understand internal PowerShell module design | Codebase map already covers this (.planning/codebase/); duplicating it creates drift; analyst docs and dev docs have different update cadences | Reference .planning/codebase/ for development context; keep analyst docs tool-usage focused |
| Video walkthroughs or interactive tutorials | High engagement format; some teams prefer it | Out of scope per PROJECT.md; written-docs-only constraint; videos become outdated faster than text and can't be version-controlled | Annotated example workflow in written form serves the same orientation purpose |
| Exhaustive "all possible parameter combinations" reference | Feels complete; useful as a reference grid | Creates documentation noise; most combinations are obvious once individual parameters are understood; increases maintenance surface | Cover meaningful examples per use case; let the parameters reference stand on its own |
| Troubleshooting FAQ with 40+ entries | Comprehensive coverage feels thorough | Padded FAQs lose the high-value entries in noise; analysts stop reading; low-value entries go stale | Keep troubleshooting to actual failure modes confirmed by the codebase (state machine errors, WinRM config failures, credential issues, SHA256 mismatch) |
| Architecture diagram in analyst docs | Tech-curious analysts want to understand internals | Architecture is in the codebase map; redundant in analyst docs; confuses usage docs with design docs | One sentence describing the component's role is enough; link to ARCHITECTURE.md for detail |

---

## Feature Dependencies

```
Operational Runbook (prerequisites + params + troubleshooting)
    └──must precede──> Analyst Interpretation Guide
                           (analysts need to understand what data was collected
                            before they can interpret it in Report.html)

Artifact Coverage Matrix
    └──feeds into──> Interpretation Guide (fallback behavior sections)
    └──feeds into──> Runbook (troubleshooting: "why is my data lower fidelity?")

Cross-tab correlation examples (Interpretation Guide)
    └──requires──> Tab navigation overview (Table Stakes)
                       (analysts need the map before the examples make sense)

Anomaly pattern examples (Differentiator)
    └──requires──> Cross-tab correlation section (Differentiator)
                       (examples use cross-tab workflows)

Coverage gap section (Differentiator)
    └──enhances──> Artifact Coverage Matrix (Table Stakes)
                       (matrix answers "what's collected"; gap section answers "what's missing")

Annotated end-to-end workflow (Differentiator)
    └──requires──> All three docs to exist in draft form
                       (workflow references runbook commands, matrix artifacts,
                        and report navigation in a single scenario)
```

### Dependency Notes

- **Runbook must precede Interpretation Guide:** The guide assumes analysts already know how to collect data successfully. If they can't run Collector.ps1, the report guidance is useless.
- **Artifact Coverage Matrix feeds both other docs:** The matrix is the source of truth for what data exists and at what fidelity. Both the runbook (troubleshooting fidelity issues) and the interpretation guide (what to look for and its limitations) reference it.
- **Tab navigation is a prerequisite for examples:** Anomaly pattern examples that say "pivot to Network tab" are meaningless if the analyst doesn't have a mental model of what the Network tab is.
- **Coverage gap section enhances but does not block the matrix:** Write the matrix first; add the gap section in the same pass or immediately after.
- **End-to-end workflow is a capstone:** It's the last thing written, after the other three docs are drafted, because it synthesizes all of them into a coherent scenario.

---

## MVP Definition

This is a documentation milestone for a mature tool, not a product MVP. Reframed: what must the first-draft docs contain to be usable for an analyst picking up the tool cold?

### Launch With (v1 — minimum usable docs)

- [ ] Runbook: prerequisites + setup (WinRM, admin rights, URI scheme registration) — blocks all other doc use
- [ ] Runbook: full parameter reference for Collector.ps1, Executor.ps1, QuickAiRLaunch.ps1 — analysts can't run the tool without this
- [ ] Runbook: troubleshooting table keyed to actual terminal state names (CONNECTION_FAILED, TRANSFER_FAILED, etc.) — covers the most common failure modes
- [ ] Artifact Coverage Matrix: what's collected, at what fidelity, via which fallback path — required to interpret results meaningfully
- [ ] Interpretation Guide: Report.html tab navigation overview — blocks any meaningful report use
- [ ] Interpretation Guide: how to load data and navigate between hosts — first-run friction removal
- [ ] Interpretation Guide: cross-tab correlation patterns — core analytical value of the tool

### Add After Validation (v1.x — differentiating content)

- [ ] Anomaly pattern examples — add when junior analyst feedback confirms they struggle to identify what to look for
- [ ] Coverage gap section in artifact matrix — add to make the matrix authoritative (not just "what's there" but "what isn't")
- [ ] Context-sensitive error table mapped to specific codebase state names — add when support burden from WinRM/execution failures is confirmed
- [ ] Fallback behavior per-collector in table form — add if fidelity confusion is reported after v1 release

### Future Consideration (v2+)

- [ ] Annotated end-to-end workflow scenario — valuable but high effort; defer until v1 docs are validated by actual analyst use
- [ ] Decision callouts for junior/senior split content — restructuring exercise; do after v1 exists to avoid designing in a vacuum
- [ ] Manifest tab deep-dive — useful but low urgency; analysts can learn the Manifest tab from the basic navigation guide initially

---

## Feature Prioritization Matrix

| Feature | Analyst Value | Implementation Cost | Priority |
|---------|--------------|---------------------|----------|
| Prerequisites and setup steps | HIGH | LOW | P1 |
| Parameter reference (Collector, Executor, Launcher) | HIGH | LOW | P1 |
| Output file locations | HIGH | LOW | P1 |
| Artifact inventory (what's collected) | HIGH | LOW | P1 |
| Report.html tab navigation overview | HIGH | LOW | P1 |
| How to load data into Report.html | HIGH | LOW | P1 |
| Executor method chain explanation | HIGH | LOW | P1 |
| Troubleshooting section per entry point | HIGH | MEDIUM | P1 |
| Cross-tab correlation patterns | HIGH | MEDIUM | P1 |
| SHA256 integrity — what it means | MEDIUM | LOW | P1 |
| Artifact coverage matrix (what + fidelity + fallback) | HIGH | MEDIUM | P1 |
| Coverage gap section | HIGH | LOW | P2 |
| Fallback behavior per-collector in table form | MEDIUM | MEDIUM | P2 |
| Context-sensitive error table (exact state names) | MEDIUM | MEDIUM | P2 |
| Manifest tab interpretation guide | MEDIUM | MEDIUM | P2 |
| Anomaly pattern examples | HIGH | HIGH | P2 |
| Decision callouts (junior/senior split) | MEDIUM | MEDIUM | P2 |
| Annotated end-to-end workflow scenario | HIGH | HIGH | P3 |

**Priority key:**
- P1: Must have for launch — analyst can't operate tool effectively without this
- P2: Should have — meaningfully improves quality of analysis; add in same milestone if time allows
- P3: Nice to have — high value but high effort; defer to next iteration

---

## Comparable Documentation Patterns (DFIR Domain)

Rather than competitor products, this reflects patterns observed in high-quality operational IR tool docs:

| Documentation Pattern | Common Approach | What Makes It Great |
|-----------------------|-----------------|---------------------|
| Parameter reference | List all params alphabetically | Group by workflow (collection params together, output params together); mark required vs optional inline |
| Artifact coverage | Prose description per artifact | Matrix grid: artifact × collection method × fidelity level — scannable in 10 seconds |
| Troubleshooting | Generic "check your network" advice | Exact error/state names from tool output mapped to specific fix; junior analyst can self-serve |
| Report navigation | Screenshot-heavy walkthroughs | Concise tab function descriptions plus one "pivot path" example per tab — screenshots go stale |
| Coverage gaps | Implied by omission | Explicit "not collected" section so analysts don't assume completeness |
| Fallback behavior | "The tool automatically adjusts" | Named fallback path, named fidelity impact — analyst knows whether to trust the data |

---

## Sources

- Codebase analysis: `.planning/codebase/ARCHITECTURE.md`, `.planning/codebase/STRUCTURE.md`, `.planning/codebase/STACK.md`, `.planning/codebase/CONCERNS.md` — HIGH confidence (verified against actual code)
- Project requirements: `.planning/PROJECT.md` — HIGH confidence (authoritative)
- DFIR documentation domain knowledge: Training data covering IR tool documentation patterns (Velociraptor, CyberTriage, Kansa, KAPE documentation conventions) — MEDIUM confidence (no external verification available; WebSearch not permitted in this environment)
- Audience analysis (mixed junior/senior IR teams): Consistent with PROJECT.md constraint "avoid assuming deep tool familiarity but don't over-explain IR fundamentals" — HIGH confidence

---

*Feature research for: QuickAiR DFIR Toolkit — Production Documentation*
*Researched: 2026-03-24*
