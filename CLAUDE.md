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

<!-- verity-memory:start -->
## Project Memory

This project has a knowledge graph maintained at `.verity/memory/`. Before starting
non-trivial work, scan `.verity/memory/index.md` for decisions, gotchas, and patterns
that may apply to the change you are about to make. Open specific node files via
the Read tool when the title or scope suggests relevance.

The graph is auto-maintained by Verity. Files at `.verity/memory/_archive/` are
superseded — ignore them unless investigating history.

Knowledge the organization's other repositories learned is mirrored outside the
repo at `~/.verity/orgs/<host>/<owner>/memory/` (`verity memory org` lists it).
Each claim says where it came from; one that is wrong here is demoted for
everyone with `verity memory demote <id> --reason "…"`.

## Quality gate: accepted risks

When the Verity pre-commit/pre-push gate FAILs, fix the findings — that is the
default. Use `verity waive <pattern-id> --file <path> --reason "…"` ONLY to relay
a risk a human has explicitly accepted: a named code-review finding, an ADR, or
the user saying so in this conversation. The --reason must cite that source.

Never waive on your own judgment, to get past a block, or pre-emptively. A waive
binds to the file's current bytes and voids automatically when the file changes,
and every waive is recorded in the run ledger. For a pattern-level false positive
use `verity feedback finding <run-id> <pattern-id> false_positive` instead.

## Post-task reflection

When a task is complete (you've created a PR, the user says "done" or "ship it",
or the work is clearly finished), **draft the reflection yourself** — 1–3
concrete things worth remembering (a decision, a gotcha, or a pattern), each
cited with the files / PR / commands / error-signatures it came from. Skip
entirely if nothing non-obvious happened — that judgement is the ONLY filter,
because nothing reviews the reflection before it lands.

Then record it straight away. There is no confirm step, in any environment:

```bash
verity reflect --user-input - --kind <kind> <<'VERITY_EOF_<random>'
<your draft>
VERITY_EOF_<random>
```

The draft goes through the quoted heredoc, never inside `"…"` on the command
line, where a `"` or `$(…)` in it would run in the shell. Replace `<random>`
with 8 random letters and digits that you pick for this call, the same at both
ends. Text written before you picked them cannot end the heredoc early.

Add `--confirmed` ONLY when the user authored or dictated the words. Without
it the node is stored as `source: agent` — Verity thought this, nobody checked
it. With it, `source: user` at full confidence — a person stands behind this.
Never claim the second for your own draft, however good it is.

**Name the files in the text.** Verity scopes the reflection to the paths it
cites, and a reflection that names no file in this repo is never retrieved for
a later review — it is recorded and then invisible. The command says so when it
happens; `--file-globs '<path or glob>'` is the fix when the prose cannot carry
the paths.

Then tell the user, in one line, what you recorded and where: the command
prints the node id, the path under `.verity/memory/`, and a dashboard link.
They did not agree to it in advance, so say it happened — editing or deleting
that file is how they correct it.

> Durable, hand-curated guidance goes in the preserve region below (it survives
> regeneration) or anywhere OUTSIDE these markers. Everything else between the
> markers is tool-owned and overwritten on each run.

## Housekeeping Turns

When a turn will be pure housekeeping — pulling, installing dependencies,
rebasing, a formatting sweep you are not authoring — declare it BEFORE doing it:

```bash
verity ignore --turn --agent --reason "pulling latest before starting"
```

This skips the review for that turn, which saves the turn Verity would
otherwise spend saying it had nothing to say. Use `--for 30m` instead of
`--turn` when a single piece of housekeeping spans several turns.

**It is a claim about the turn, not a way to silence review.** The declaration
is checked against what the turn actually did: if anything is authored — by you,
by a subagent, or by a shell command that can write files — it voids, the review
runs anyway, and the broken declaration is reported. So declare housekeeping you
are about to do, never work you have already done, and never as a way to get past
a finding. Declarations are budgeted per session and every one is recorded with
its reason.

<!-- verity-memory:preserve -->
<!-- Add binding, hand-curated guidance here; it survives Verity regeneration. -->
<!-- /verity-memory:preserve -->
<!-- verity-memory:end -->
