# Pitfalls Research

**Domain:** DFIR toolkit production documentation (operational runbooks, artifact coverage maps, analyst interpretation guides)
**Researched:** 2026-03-24
**Confidence:** HIGH — derived from direct codebase analysis combined with established DFIR documentation practices

---

## Critical Pitfalls

### Pitfall 1: Documenting Aspirational Behavior Instead of Actual Behavior

**What goes wrong:**
Documentation describes how the tool *should* work in ideal conditions — clean WinRM connectivity, modern PS 5.1 targets, full administrative access — without reflecting the fallback chains, capability probing, and degraded-mode behavior that analysts actually encounter. The runbook says "run Collector.ps1 -Targets <host>" and shows a clean output. The analyst runs it against a Server 2008 R2 target, gets a netstat-based collection with partial data, and has no way to know if this is normal or a failure.

**Why it happens:**
Authors write from the happy path — the configuration they used to test. The fallback paths are invisible during development because they never trigger in the author's environment.

**How to avoid:**
For every command and feature, explicitly document all behavioral modes, not just the preferred one. For Collector.ps1: document what happens at PS 5.1 (CIM path), PS 3–4 (netstat/ipconfig fallback), and PS 2.0 (WMI direct). For Executor.ps1: document what the analyst sees at each state transition (CONNECTION_FAILED → tries SMB+WMI → etc.). The artifact coverage matrix must include a "data source used" column that maps PS version to collection method per artifact type.

**Warning signs:**
- Draft runbook never mentions fallback, degraded mode, or "if X is not available"
- Artifact matrix shows only one source per artifact type
- Troubleshooting section is absent or very short
- No mention of the manifest's `collection_errors` array or what it means

**Phase to address:** Runbook phase (operational runbook document). Validate during review by testing each documented behavior against the actual code path in ARCHITECTURE.md and CONCERNS.md.

---

### Pitfall 2: Artifact Coverage Map That Shows Coverage Without Showing Gaps

**What goes wrong:**
The matrix becomes a marketing document — it shows what the tool collects but omits what it *cannot* collect and under what conditions data is incomplete or missing. An analyst looking at a DNS tab with zero entries in Report.html cannot tell if the target had no DNS cache or if the DNS collector failed silently. An analyst running against PS 2.0 doesn't know that DNS cache collection falls back to `ipconfig /displaydns` and may miss entries.

**Why it happens:**
Coverage matrices are typically built from the feature list, not from the failure modes. Writers list capabilities; they omit limitations.

**How to avoid:**
The matrix must have explicit gap columns: "Coverage gap," "Data absent when," and "Fallback path." Specifically for this toolkit: DLLs.psm1 has no PS 2.0 fallback (only Win32_ProcessModule via CIM); Network.psm1's netstat fallback misses short-lived connections on high-churn targets (10% miss rate documented in T3); Users.psm1 relies solely on Win32_LogonSession with no fallback. These gaps must appear in the matrix, not be hidden.

**Warning signs:**
- Matrix has no "N/A" or "not collected" cells
- Matrix has no "PS version requirement" column
- No row for collection errors or manifest.collection_errors
- Every cell shows a checkmark or "yes"

**Phase to address:** Artifact coverage matrix phase. Cross-reference against CONCERNS.md Known Bugs and codebase STRUCTURE.md collector plugin list before finalizing.

---

### Pitfall 3: Runbook Omits the "What Did I Actually Get?" Verification Step

**What goes wrong:**
The runbook walks the analyst through running Collector.ps1 but does not tell them how to verify the collection succeeded, what a healthy output looks like vs. a degraded one, or what the manifest's metadata fields mean. The analyst gets a JSON file and opens Report.html with no guidance on whether the data is complete, partial, or suspect.

**Why it happens:**
Authors focus on the invocation (the command) and assume the output is self-evident. DFIR output is not self-evident — a process list of 0 entries could mean a clean system or a failed collection.

**How to avoid:**
Every collection workflow section must include a post-run verification checklist: check the manifest tab in Report.html for collection_errors; verify `Processes_source`, `Network_source`, etc. show the expected data source (CIM vs. netstat vs. legacy); confirm SHA256 integrity (auto-checked by Report.html but should be noted); note what the log output means (collection.log). Document what normal looks like: process count ranges for a healthy server, expected TCP connection count, etc.

**Warning signs:**
- Runbook has "run this command" sections with no "verify the output" subsection
- No documentation of what manifest fields mean
- No documentation of what collection_errors in the manifest indicates
- No mention of Report.html's SHA256 integrity check behavior

**Phase to address:** Runbook phase. Also referenced in the Report.html interpretation guide.

---

### Pitfall 4: Interpretation Guide Describes UI Instead of Analyst Workflow

**What goes wrong:**
The analyst guide becomes a UI tour — "The Processes tab shows a table with columns PID, Name, Path..." — rather than teaching analysts *how to investigate* using the tool. A junior analyst reading a UI tour learns what buttons exist but not what to do with them during an incident. They don't know to pivot from a suspicious process in the Processes tab to the Network tab to see its connections, then to the DNS tab to see what domains it resolved.

**Why it happens:**
Documentation authors default to describing what they see (UI elements) rather than modeling what analysts do (investigation workflows). UI tours are easier to write.

**How to avoid:**
Structure the interpretation guide around investigation scenarios, not UI elements. Cover: "How do I find a process with suspicious network connections?" (Processes tab → PID → Network tab filter by PID), "How do I check if a process loaded unsigned DLLs?" (Processes tab → DLLs pivot), "What does it mean when a DNS entry has no matching connection?" (DNS tab → no correlated TCP entry = possible prior C2 activity). The UI description should be secondary to the workflow.

**Warning signs:**
- Section headers match tab names exactly (Processes, Network, DNS, DLLs, Users) with no workflow sections
- No cross-tab workflow described
- No mention of what makes a finding suspicious vs. benign
- Guide can be written entirely from looking at the HTML without running the tool

**Phase to address:** Analyst interpretation guide phase.

---

### Pitfall 5: Executor and Launcher Documented in Isolation From Each Other

**What goes wrong:**
The runbook documents Executor.ps1 as a standalone tool and QuickerLaunch.ps1 as a separate tool, without explaining the integrated workflow: Report.html triggers quicker:// URI → QuickerLaunch receives the job batch → QuickerLaunch invokes Executor.ps1 for each job. An analyst who reads the runbook and tries to use QuickerLaunch standalone (not triggered from Report.html) will be confused by the URI parameter format. An analyst who tries to invoke Executor.ps1 manually in a loop to simulate QuickerLaunch will miss the job queue concurrency control and overload targets.

**Why it happens:**
Three distinct entry points (Collector, Executor, Launcher) invite documenting each as its own section. The integration path through the URI scheme is architecturally unusual and not obvious from the tool names alone.

**How to avoid:**
Open the runbook with a system architecture overview that shows the full workflow: collection → report viewing → job launch → execution → result refresh. Make the quicker:// URI scheme explicit — document that Register-QuickerProtocol.ps1 must be run first, and that QuickerLaunch is normally triggered by Report.html rather than directly. Document the direct invocation of Executor.ps1 as an advanced/standalone case, not the primary workflow.

**Warning signs:**
- Runbook sections for Collector, Executor, and Launcher are entirely independent with no cross-references
- Register-QuickerProtocol.ps1 is not mentioned
- quicker:// URI scheme is not explained
- "Prerequisites" section exists only at the global level, not per-workflow

**Phase to address:** Runbook phase, specifically the getting-started / architecture overview section written first before command reference sections.

---

### Pitfall 6: Troubleshooting Section Based on Guesses, Not Actual Failure Modes

**What goes wrong:**
Troubleshooting sections list generic errors ("if you get an error, check your credentials") rather than the specific failure modes the tool produces. For this toolkit specifically: WinRM TrustedHosts modification failures (non-admin), SMB+WMI fallback silent state transitions, capability probe retries and retry exhaustion, SHA256 mismatch on transfer, session-to-JSON correlation failures in Launcher when multiple jobs write to the same directory. If these are not documented, analysts waste time on the wrong diagnosis.

**Why it happens:**
Troubleshooting is written last, under time pressure, from memory rather than from a structured audit of error handling paths in the code.

**How to avoid:**
Derive the troubleshooting section directly from the codebase's error handling. For each CONCERNS.md entry (Known Bugs, Fragile Areas), write a troubleshooting entry. Review ARCHITECTURE.md's Error Handling section to enumerate all terminal failure states (CONNECTION_FAILED, TRANSFER_FAILED, LAUNCH_FAILED, TIMEOUT, FAILED) and document what analyst-visible symptoms correspond to each. Include the collection.log format and what WARN vs ERROR entries mean.

**Warning signs:**
- Troubleshooting section has fewer than 8-10 distinct failure scenarios for a toolkit this complex
- No mention of collection.log or ExecutionResults JSON as diagnostic sources
- No mention of WinRM TrustedHosts, capability probe retries, or executor state transitions
- Troubleshooting entries are "check your credentials" / "make sure you have admin rights" generics

**Phase to address:** Runbook phase. Build troubleshooting table directly from CONCERNS.md and ARCHITECTURE.md Error Handling section, not from inference.

---

### Pitfall 7: Mixed-Experience Audience Served Poorly by Single Document Voice

**What goes wrong:**
Documentation written for senior analysts alienates juniors (assumes deep Windows internals knowledge — "the CIM provider," "Win32_LogonSession," "NTLM vs Kerberos auth"). Documentation written for juniors bores seniors and wastes space with basics they know. A single document serving both audiences ends up doing neither well: juniors are lost at the technical detail, seniors skip-scan and miss the operational nuance.

**Why it happens:**
The project brief (PROJECT.md) correctly identifies a mixed-experience audience. Writers default to one level of assumed knowledge rather than architecting the document to serve both.

**How to avoid:**
Use a layered structure: a quick-reference summary at the top of each section for experienced analysts (parameter table, one-paragraph behavior summary, one-line troubleshooting hint), with expanded detail below for juniors. Use callout boxes or clearly marked subsections ("Background: What WinRM is and why it's needed" as a collapsible/optional section). Never assume knowledge of fallback chains, WMI, or IR methodology, but don't force seniors to wade through primer content to find the command they need.

**Warning signs:**
- No "Quick Reference" summary section
- All sections are uniform depth (either all shallow or all deep)
- No explanation of why fallbacks exist (juniors won't know to check which path was used)
- Terms like "CIM," "WMI," "WinRM," "PSSession" used without at least a one-line definition on first use

**Phase to address:** All documentation phases. Address in the structural template/outline created at the start of each phase, before writing begins.

---

## Technical Debt Patterns

Shortcuts that seem reasonable but create long-term documentation problems.

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Copy parameter descriptions from code comments | Fast to write | Code comments are terse/incomplete; docs inherit the gaps; parameters like `-BinaryTypeOverride` have no inline explanation | Never — verify each parameter description against actual behavior |
| Document only PS 5.1 happy path | Simpler, cleaner docs | Analysts on legacy targets get no guidance; CONCERNS.md already documents known PS 2.0 issues that will surface | Never for a tool with explicit PS 2.0 support |
| Write artifact matrix from feature list without testing fallback paths | Faster to produce | Matrix overstates coverage; junior analysts trust it and miss gaps | Never |
| Skip documenting error JSON format in ExecutionResults | Saves time | Analysts can't interpret execution failures; need to reverse-engineer JSON schema from Executor.ps1 source | Never — the schema is stable and small |
| Defer "known limitations" section to a later version | Clean initial doc | Analysts hit known bugs (column width reset, netstat miss rate) with no context; bugs in CONCERNS.md are already documented | Never — existing known bugs must be acknowledged on day one |

---

## Integration Gotchas

Common mistakes when documenting the integrations between toolkit components.

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| quicker:// URI scheme | Not mentioned or buried in appendix | Lead section of Launcher documentation; requires Register-QuickerProtocol.ps1 pre-step — if analyst skips this, nothing works |
| Report.html → QuickerLaunch job batch | Documenting as "click Launch All" with no explanation of what happens next | Explain the full state machine: base64 encode → URI trigger → bridge file → PipeListener → JobQueue → Executor.ps1 invocation per job |
| Executor.ps1 → ExecutionResults JSON → Report.html refresh | Omitting the "refresh JSON in Report.html" step after execution | Document the complete loop: execute → wait → drag new ExecutionResults JSON into Report.html to see results |
| Collector.ps1 → DFIROutput → Report.html | Omitting SHA256 integrity check explanation | Document that Report.html validates sha256 on load; if hash fails (corrupted file), tab content will not render |
| WinRM TrustedHosts modification | Not warning analysts this requires local admin on the analyst machine, not just the target | This is a common first-run failure; must be in Prerequisites with explicit "run as Administrator" requirement |

---

## Performance Traps

Patterns that work at small scale but fail as usage grows — documentation should set analyst expectations.

| Trap | Symptoms | Prevention in Docs | When It Breaks |
|------|----------|--------------------|----------------|
| Loading 20+ JSON files into Report.html | Browser tab hangs or crashes | Document recommended batch size (<15 hosts per Report.html session); note 1-5MB per JSON file | Browser heap ~500MB-2GB; ~100-200 host practical limit |
| Running Collector.ps1 against 50+ targets sequentially | Collection takes hours; analyst cannot interrupt without losing progress | Document sequential execution limitation; recommend batching targets; note absence of cancel capability | 10 targets ≈ 5 min; 50 targets ≈ 25 min minimum |
| DNS PTR reverse lookups on public IPs | Collection hangs on targets with many external connections | Warn analysts that collections against hosts with many public outbound connections may be slow | ~50+ unique public IPs triggers multi-minute delay |
| QuickerLaunch with 500+ jobs | WinForms grid stalls; job status updates lag | Document recommended max concurrent job batch size (50-100 jobs per launch batch); note max concurrent workers = 5 | ~500+ jobs in queue |

---

## Security Mistakes

Documentation-specific security mistakes for this DFIR toolkit.

| Mistake | Risk | Prevention |
|---------|------|------------|
| Documenting `-SkipCACheck -SkipCNCheck -SkipRevocationCheck` as standard practice without warning | Analysts normalize MITM-susceptible WinRM for production use | Document this as lab/trusted-network only; note from CONCERNS.md that this is a known risk; include disclaimer in Prerequisites |
| Documenting credential cache in QuickerLaunch without noting the in-memory retention risk | Analysts leave Launcher open indefinitely; credentials retained in memory | Note that `$script:CredCache` holds credentials for the session lifetime; recommend closing Launcher after job completion |
| Documenting hardcoded bridge directory `C:\DFIRLab\QuickerBridge\` without explaining access control assumption | Analysts deploy to shared machines; bridge dir readable by non-admin accounts | Note from CONCERNS.md: bridge dir requires Administrator access; document the risk of shared analyst workstations |
| Omitting the SHA256 verification step from the collection workflow | Analysts trust tampered or corrupted collection data | Document that Collector.ps1 computes and embeds SHA256; document that Report.html validates it on load; note what "integrity check failed" looks like |

---

## UX Pitfalls

Documentation mistakes that make docs hard to use under operational pressure.

| Pitfall | Analyst Impact | Better Approach |
|---------|----------------|-----------------|
| Long narrative prose for command parameters | Analyst under time pressure cannot scan; must read paragraph to find flag name | Use parameter tables with Name, Type, Required, Default, Description columns for all scripts |
| No quick-reference summary at section top | Senior analyst must read full section to find the one command they need | Add a "TL;DR" or "Quick Reference" box at top of each major section |
| Artifact matrix in prose description instead of grid | Cannot visually scan coverage across artifact types | Enforce table/grid format; rows = artifact types, columns = PS version / data source / fallback / gap |
| Troubleshooting as paragraphs | Cannot scan for symptom match under pressure | Use symptom → cause → fix format; table preferred over prose |
| All documentation in a single large file | Ctrl+F becomes the only navigation; hard to hand to a specific analyst | Separate files per domain: RUNBOOK.md, ARTIFACT-COVERAGE.md, INTERPRETATION-GUIDE.md |
| No "known limitations" section | Analysts hit bugs (column width reset, netstat miss rate) with no warning | Include known limitations from CONCERNS.md as a first-class section, not buried in appendix |

---

## "Looks Done But Isn't" Checklist

Things that appear complete but are missing critical pieces.

- [ ] **Runbook:** Has command syntax documented — verify it also documents all fallback behaviors (PS 2.0, CIM vs WMI vs netstat paths) and executor state transitions (CONNECTION_FAILED through ALIVE)
- [ ] **Runbook:** Has a troubleshooting section — verify it contains specific failure modes from CONCERNS.md (Known Bugs, Fragile Areas) not just generic connectivity advice
- [ ] **Artifact coverage matrix:** Has a row per artifact type — verify it also has "Coverage gap," "Data absent when," "Fallback path," and "PS version requirement" columns
- [ ] **Artifact coverage matrix:** Shows what's collected — verify it also shows what's *not* collected (DLLs.psm1 no PS 2.0 fallback, Users.psm1 no fallback, netstat miss rate on high-churn targets)
- [ ] **Interpretation guide:** Documents each Report.html tab — verify it also documents cross-tab investigation workflows (Process → Network → DNS pivot), not just per-tab UI descriptions
- [ ] **Interpretation guide:** Explains what to look at — verify it also explains what "suspicious" vs. "benign" looks like for each data type
- [ ] **Any document:** Contains examples — verify examples use realistic IR scenario data (suspicious process, unusual network connection) not synthetic "example.com" or "test" placeholders
- [ ] **Runbook:** Documents Collector.ps1 invocation — verify it also documents Register-QuickerProtocol.ps1 prerequisite and explains when/why to run it
- [ ] **All docs:** Accurate to current code — verify all parameter names, output paths, and default values match actual current codebase (not README.md which may lag the code)

---

## Recovery Strategies

When pitfalls occur despite prevention, how to recover.

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Aspirational behavior documented (happy path only) | MEDIUM | Audit each command section against ARCHITECTURE.md Data Flow; add "degraded mode" callouts; does not require structural rewrite |
| Coverage matrix missing gaps | LOW | Add gap columns to existing matrix; cross-reference CONCERNS.md Known Bugs; one-day task |
| Interpretation guide is a UI tour | HIGH | Structural rewrite required; UI tour content can be repurposed as reference appendix; new lead sections needed for investigation workflows |
| Troubleshooting section is generic | LOW | Derive specific entries from CONCERNS.md Known Bugs + Fragile Areas; replace generic entries; half-day task |
| Executor/Launcher integration workflow missing | MEDIUM | Add architecture overview section to runbook; add cross-references between Executor and Launcher sections; does not require rewriting existing content |
| Mixed-audience voice problem | MEDIUM | Add Quick Reference summaries to top of each section without removing existing detail; add "Background" collapsible sections for primer content |

---

## Pitfall-to-Phase Mapping

How roadmap phases should address these pitfalls.

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Aspirational vs. actual behavior | Runbook phase — start by reading ARCHITECTURE.md Data Flow and CONCERNS.md before writing any command section | Review: does every command section mention at least one fallback or failure mode? |
| Coverage matrix hides gaps | Artifact coverage matrix phase — derive gap column from CONCERNS.md Known Bugs and codebase collector list | Review: does every artifact row have a "Data absent when" cell that isn't empty? |
| No post-collection verification step | Runbook phase — add "verify output" subsection immediately after each collection workflow | Review: is there a manifest.collection_errors explanation in the runbook? |
| UI tour instead of analyst workflow | Interpretation guide phase — write investigation scenarios first, then build UI descriptions to support them | Review: does the guide include at least 3 cross-tab investigation workflows? |
| Executor/Launcher documented in isolation | Runbook phase — write architecture overview section before any component-specific section | Review: does the runbook have a section explaining the quicker:// URI trigger and Register-QuickerProtocol.ps1? |
| Troubleshooting from guesses | Runbook phase — explicitly derive troubleshooting table from CONCERNS.md before closing the runbook | Review: is each Known Bug and Fragile Area from CONCERNS.md represented in troubleshooting? |
| Mixed-audience voice | All documentation phases — add Quick Reference table to each section during initial draft | Review: can a senior analyst find any command syntax within 10 seconds of opening the doc? |
| Security risks undisclosed | Runbook phase (Prerequisites section) and interpretation guide (Collection tab notes) | Review: are all three CONCERNS.md Security Considerations items acknowledged in the docs? |

---

## Sources

- Direct analysis: `.planning/codebase/ARCHITECTURE.md` — fallback chains, error handling, data flow
- Direct analysis: `.planning/codebase/CONCERNS.md` — known bugs, fragile areas, security considerations, documentation gaps
- Direct analysis: `.planning/codebase/STRUCTURE.md` — plugin architecture, collector modules, executor modules
- Direct analysis: `.planning/PROJECT.md` — audience requirements (mixed junior/senior), scope constraints
- Domain knowledge: DFIR operational documentation patterns (training data, confidence HIGH for stable documentation practices)
- Domain knowledge: Incident response runbook anti-patterns (training data, confidence HIGH)

---

*Pitfalls research for: DFIR toolkit production documentation (Quicker)*
*Researched: 2026-03-24*
