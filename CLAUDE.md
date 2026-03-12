# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

PowerShell DFIR toolkit for volatile artifact collection. Two deliverables:
- `Collector.ps1` — collects volatile artifacts from a target Windows system
- `Report.html` — self-contained HTML report generated from collected data

## Output Paths

| Purpose | Path |
|---|---|
| Final deliverables | `C:\DFIRLab\FinalOutput\` |
| Working/intermediate files | `C:\DFIRLab\Scripts\` |
| Agent log | `C:\DFIRLab\agent.log` |

## Hard Rules (non-negotiable)

- Never prompt for user input — all decisions made autonomously
- Never write to Windows Event Log
- Never make external network calls — fully air-gap safe
- Collection is strictly read-only — never modify target system state
- Always enforce Administrator context; abort with user-facing instructions if not elevated
- All datetimes in UTC ISO 8601

## Code Style

**PowerShell (`Collector.ps1`):**
- Must be compatible with PS 2.0 on target machines
- Analyst machine is PS 5.1 (can use PS 5.1 features in any tooling that runs only on analyst side)

**HTML (`Report.html`):**
- Vanilla JS only — no frameworks, no CDN links, no external resources
- Must be fully self-contained (single file, works offline)

**JSON (intermediate data):**
- One file per host
- Schema: `manifest` + `processes` + `network` + `DNS`
