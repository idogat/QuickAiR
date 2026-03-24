# Phase 1: Coverage Matrix - Discussion Log (Assumptions Mode)

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions captured in CONTEXT.md — this log preserves the analysis.

**Date:** 2026-03-24
**Phase:** 01-coverage-matrix
**Mode:** assumptions
**Areas analyzed:** Fallback Tier Structure, Collector-Specific Fallback Chains, Data Field Fidelity Degradation, Coverage Gaps Documentation

## Assumptions Presented

### Fallback Tier Structure
| Assumption | Confidence | Evidence |
|------------|-----------|----------|
| Three-tier model: PS 2.0, PS 3+ (partial CIM), PS 5.1 (full CIM) with capability flags for sub-tier behavior | Confident | Connection.psm1 lines 90-93, all four collector modules branch on PSVersion >= 3, Network sub-branches on HasNetTCPIP/HasDNSClient |

### Collector-Specific Fallback Chains
| Assumption | Confidence | Evidence |
|------------|-----------|----------|
| Each collector has unique fallback structure — Network most complex (3+3 paths), DLLs uses different APIs per tier, Users has no PS branching, Processes CIM/WMI with .NET supplement | Confident | Network.psm1 lines 292-294, DLLs.psm1 line 327-328, Users.psm1 single scriptblock, Processes.psm1 line 296 |

### Data Field Fidelity Degradation
| Assumption | Confidence | Evidence |
|------------|-----------|----------|
| Document specific field-level losses per tier: Processes Signature detail, .NET fallback field nulls, Network InterfaceAlias/CreationTime, DNS Type/TTL, DLLs Signature/Version | Confident | Processes.psm1 lines 62-79 vs 180-209, Network.psm1 lines 169-193, DLLs.psm1 lines 280-294 |

### Coverage Gaps Documentation
| Assumption | Confidence | Evidence |
|------------|-----------|----------|
| Inline gaps per collector row plus summary callout. Key gaps: DLLs protected process exclusion, .NET fallback field losses, netstat no timestamps, Users no PS degradation | Likely | DLLs.psm1 lines 39 and 172, Processes.psm1 lines 117-121 and 249-256, Users.psm1 lines 23-256 |

## Corrections Made

No corrections — all assumptions confirmed.

## External Research Flagged

- ipconfig /displaydns output format stability across Windows versions (affects DNS parse reliability)
- Win32_ProcessVMMapsFiles availability on Server Core installations (affects DLLs PS 2.0 collection)
