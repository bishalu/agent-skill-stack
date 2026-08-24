---
name: engineering-router
description: Decide which engineering skills should run before starting non-trivial engineering work — a feature, a refactor, a bug, a review, or an audit — when more than one installed skill could plausibly claim it. Picks at most one lifecycle owner, names the supporting skills that augment it, and says when to escalate to a security or diagnosis specialist. Skip for a one-line edit, a direct question, or work already inside a chosen skill.
---

# Engineering router

Answer four questions in order, then act. Do not print the reasoning unless asked.

## 1. Is this trivial?

A typo, a string change, a rename, a one-file edit with an obvious shape, or a
question with a factual answer: **do the work directly.** No owner, no orchestration.
Passive knowledge overlays still apply. Most tasks stop here.

## 2. Which lifecycle phase is this?

Pick **exactly one** owner, or none. Never two.

| The user wants | Owner |
| --- | --- |
| to explore a vague or ambitious idea, decide scope | `ce-brainstorm` |
| a plan, a breakdown, a spec turned into steps | `ce-plan` |
| a plan or clear build request executed | `ce-work` |
| something broken explained and fixed | `ce-debug` |
| recently written code tightened before review | `ce-simplify-code` |
| code, a branch, or a PR reviewed | `ce-code-review` |
| feedback already on a PR resolved | `ce-resolve-pr-feedback` |
| the change committed, pushed, shipped | `ce-commit` / `ce-commit-push-pr` |
| the lesson from this work kept | `ce-compound` |

Compound Engineering owns every phase by default. A non-Compound workflow becomes
the owner only when the request is a genuinely different operation — a dependency
audit, a static-analysis scan, a deployment — not a differently worded version of
the same phase.

**A single request that spans phases still gets one owner at a time.** Finish the
phase, then re-enter here for the next one.

## 3. Which supporting skills augment it?

Supporting skills advise the owner. They never replace it, and they never run a
competing loop over the same code.

- **React or Next.js is being written or refactored** → `vercel-react-best-practices`.
- **A reusable component's prop interface is being designed** → `vercel-composition-patterns`.
- **The work turns on what a term means, or on a CONTEXT.md or ADR** → `domain-modeling`.
- **The work turns on where a boundary or interface belongs** → `codebase-design`.
- **The user asked for test-first, or the change is best proven by tests** → `tdd`.
- **An interface surface needs an accessibility or UX judgment** → `web-design-guidelines`.

## 4. Does a specialist need to be escalated?

Escalate when the evidence is there, not because the topic sounds serious.

- **Debugging has produced inconclusive hypotheses, or the user says earlier fixes
  failed** → hand the diagnosis to `diagnosing-bugs` and keep `ce-debug` as owner.
- **The change touches authentication, authorization, permissions, secrets,
  cryptography, payments or value transfer, untrusted input, deserialization, file
  upload, external calls, unsafe or native boundaries, dependency updates, or
  security configuration** → run `differential-review` alongside the review owner.
  A review request with no such surface gets the review owner alone.
- **A vulnerability or bad pattern has just been found** → `variant-analysis` for
  its siblings, `fp-check` before reporting a finding as real.
- **Dependencies, lockfiles, or third-party package risk are the subject** →
  `supply-chain-risk-auditor`, directly. Do not wrap a dependency audit in the
  feature lifecycle.
- **A CI workflow invokes an AI agent** → `agentic-actions-auditor`.
- **An API or config surface is being judged for misuse-resistance** → `sharp-edges`.

Expensive and side-effecting workflows are never auto-selected. `codeql`,
`audit-context-building`, `vercel-optimize`, `code-review` (the two-axis second
opinion), and `lfg` run only when the user names them.

## Invariants

1. One lifecycle owner per phase. If two candidates fit, Compound wins.
2. Supporting skills augment; they do not open their own loop over the same code.
3. **A knowledge skill firing is not a phase being owned.** Reference and overlay
   skills — API references, SDK guides, framework rules — load knowledge; they do
   not run the work. When one of them is the only thing that fired on a non-trivial
   task, an owner is still missing. Pick it. This bites hardest on LLM and cloud-SDK
   work, where a reference skill claims the prompt and the phase silently goes
   unowned.
4. Escalation needs evidence — a named surface, a failed attempt, a found bug.
5. Trivial work gets no orchestration at all.
