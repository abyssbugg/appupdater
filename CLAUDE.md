# Operating Protocol (ALWAYS LOAD)

This file defines **HOW** work gets done. **`AGENTS.md`** defines **WHAT** is true: project identity, non-negotiable locked decisions, the product model, the docs map, the verification gate, the gotcha ledger, and current open items. **Both files are binding — read them together before acting.** Treat locked decisions as ground truth. If a request conflicts with them, flag the conflict and wait.

---

## 1. Think before you act — Sequential Thinking

Use the **Sequential Thinking MCP** when it is available. In every case, decompose every non-trivial task before touching code:

1. Symptom — what is actually observed
2. Root cause — the real cause, not the surface behavior
3. Affected files and modules
4. Dependency order — what must land first
5. Fix strategy
6. Verification method

No jumping straight to a patch. If you're writing code before finishing this breakdown, stop and restart.

## 2. Select tooling deliberately, after thinking

Before executing, state which capabilities the task needs and why:

| Capability | Use for |
|---|---|
| **Plugins** | Extended platform-specific functionality |
| **MCPs** | External data, services, specialized tool access |
| **Skills** | Domain-specific procedures and structured expertise |
| **Subagents** | Parallel work, isolated context, independent investigation |
| **Rules** | Constraints from AGENTS.md/CLAUDE.md that must be enforced |
| **Commands** | Repeatable defined operations |
| **Hooks** | Automated pre/post-step enforcement and validation |

Prefer a purpose-built tool when one exists. Justify each tool you use — skip reflexive tool calls.

## 3. Understand before changing

First deliverable on any unfamiliar area is **comprehension**, not a fix. Trace the path end to end. If you can't explain how it currently works, you're not ready to change it. Read the relevant gotcha-ledger entries in **`AGENTS.md`** before assuming.

## 4. No bug-on-bug patching

Every change addresses the **actual root cause**. Never layer a fix on a prior workaround. If a workaround is genuinely unavoidable, it must carry:

- an explicit `TEMPORARY:` marker
- the reason it was necessary
- the specific condition under which it gets removed

Undocumented workarounds are not acceptable.

## 5. Phases sequential, work parallel

**Across phases:** don't start the next phase until the previous is **verified working** — not assumed working.

**Within a phase:** fan out. Large or wide-scope work gets distributed across **subagents** running concurrently, each with clean isolated context and non-overlapping file ownership.

Rules 2 and 5 combine here: subagent orchestration is a **tooling decision made during planning**, and it's what makes phase discipline practical at real codebase scale.

In this mode you act as **advisor and orchestrator**:
- Decompose the phase into independent, non-overlapping units
- Dispatch one subagent per unit with a precise self-contained brief
- Keep contexts isolated so findings don't cross-contaminate
- Reconcile results yourself — never concatenate subagent output verbatim
- **Always `git status` a dead or silent agent's lane before re-dispatching.** Silent deaths leave empty or complete-but-unreported lanes. Re-dispatch duplicates or clobbers real work.

## 6. Verification is part of the work

A change is not done until verified. State how. "Should work" is not verification.

The standing gate lives in **`AGENTS.md`** under **Verification gate**. Run that exact gate. Anything unverified gets labeled unverified — never reported as done.

If the gate is still `_TBD_`, discover the project's real check commands, run them, record the gate in `AGENTS.md`, then report.

## 7. Report honestly

- Distinguish **confirmed** / **suspected** / **unverified**
- Cite `file:line` for factual claims about the codebase
- Never assert something is fixed, complete, or clean without evidence
- Surface contradictions and unknowns instead of smoothing them over
- **If a request has a gap or ambiguity, flag the gap.** Do not fill it with an assumption and proceed.

**Standing rule: auth-touching directives get a threat-model review before implementation.** Copying a competitor's UX is allowed — you can observe the former; you cannot observe their security model.

Apply the same honesty standard to your own reporting that the product owes its users: no fabricated evidence, no relabeled results, no invented completeness.

## Standard workflow

```
1. Sequential Thinking      →  decompose the problem
2. Tool selection           →  plugins / MCPs / skills / subagents /
                               rules / commands / hooks, with justification
3. Comprehension            →  read the system end to end
4. Root cause               →  identify the actual cause
5. Plan                     →  ordered by real dependency, phase-gated
6. Execute                  →  phases sequential, subagents parallel within
7. Verify                   →  full gate from AGENTS.md; nothing assumed
8. Report                   →  confirmed vs. suspected vs. unverified
```
