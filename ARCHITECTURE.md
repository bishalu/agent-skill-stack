# Architecture

Seven upstream skill collections, one engineering environment.

The problem is not "which skills are good". It is that four independently authored
collections all describe themselves as the thing to use when you review code, debug a
failure, or plan a feature. Installed side by side, they race.

## The ownership model

Every lifecycle phase has exactly one owner. Everything else advises that owner or waits
to be called.

| Layer | Source | Role |
|---|---|---|
| Lifecycle | Compound Engineering | Owns brainstorming, planning, implementation, debugging, review, PR and CI, shipping, learning. The default. |
| Methodology | Matt Pocock | Disciplines applied inside a phase: domain modeling, module design, test-first, deep diagnosis. |
| Frontend | Vercel Labs | Knowledge overlays for React and Next.js, plus an explicit UI and accessibility audit. |
| Security | Trail of Bits | Specialists that fire on a named security surface, never on "review this". |
| Infrastructure | AWS, HashiCorp | SDK and service patterns, Terraform conventions, module structure, tests. |
| Tooling | Cursor | CLI design, design-rationale archaeology, prose editing. |

Compound wins ties. When a non-Compound workflow could plausibly own a phase, it is
either narrowed until it describes a different operation, or demoted to manual
invocation. It is never left to race.

## Invocation classes

| Class | Meaning | Mechanism |
|---|---|---|
| **Owner** | Runs the phase. One at a time. | Broad trigger, Compound only |
| **Passive** | Cheap knowledge that advises whoever is running. | Narrow trigger plus an explicit non-ownership clause |
| **Conditional** | Fires on a narrow trigger, or when the owner hands off. | Trigger names the precondition, negative boundary names the neighbour |
| **Manual** | Expensive, side-effecting, or deliberately user-controlled. | `disable-model-invocation: true` |

Manual is not a soft preference. A manual skill never appears in the model's skill
listing, so it cannot be selected at all. You type `/name`. That is what makes "do not
compete with the default reviewer" enforceable rather than aspirational, and it is where
most of the context-budget saving comes from.

## Conflict matrix

Who owns each domain, who was competing for it as shipped, and what was done.

| Domain | Owner | Competing as shipped upstream | Resolution |
|---|---|---|---|
| Planning | `ce-plan` | Pocock `implement`, `to-spec`, `wayfinder`; Cursor `architect`, `figure-it-out` | Excluded. Owner-level competitors |
| Requirements | `ce-brainstorm` | Pocock `grill-with-docs`, `grill-me` | Excluded |
| Implementation | `ce-work` | Pocock `implement`; MLflow `fix-agent-issue` | Pocock excluded. `fix-agent-issue` probed and never fired, then removed with mlflow |
| TDD and testing | `ce-work` plus `tdd` | Pocock `tdd`; Cursor `tdd`; ToB `property-based-testing`, `mutation-testing` | Pocock `tdd` narrowed to a methodology overlay with an explicit non-ownership clause. The rest excluded |
| Architecture | `ce-plan` plus `codebase-design` | Pocock `codebase-design`, `improve-codebase-architecture`; Cursor `how` | `codebase-design` narrowed to boundary questions and delegation. The rest excluded |
| Domain modeling | `domain-modeling` | Pocock `domain-modeling` against `ce-plan` and `ce-brainstorm` | Narrowed to "are these the same concept" and to CONTEXT.md and ADR authoring |
| Debugging | `ce-debug` | Pocock `diagnosing-bugs`, a direct collision, both triggered on "debug this" | Rewritten as an escalation trigger: failed prior attempts, or delegation from `ce-debug` |
| Code review | `ce-code-review` | Pocock `code-review`; ToB `differential-review`, `semgrep`, `second-opinion`; Vercel `react-best-practices` and `web-design-guidelines`; Cursor `review-and-ship`, `thermo-nuclear-review`, `interrogate`. A nine-way collision | Pocock `code-review` demoted to manual. `differential-review` gated on security surfaces. `semgrep` lost "find bugs" and "security audit". The Vercel pair lost their review verbs. Everything else excluded |
| Frontend implementation | `ce-work` plus `react-best-practices` | Vercel `react-best-practices` | Kept as a passive overlay, non-ownership stated, trigger widened after it missed unnamed-framework work |
| Component API design | `composition-patterns` | Vercel `composition-patterns` against `codebase-design` | Narrowed to the public prop shape of a reusable component |
| UI and UX review | `web-design-guidelines` | Vercel `web-design-guidelines` against `ce-code-review` and `ce-polish` | Narrowed to explicit request or delegation |
| Security review | `differential-review` | ToB `differential-review`, `audit-context-building`, `sharp-edges` | Gated on named surfaces. `audit-context-building` demoted to manual. `sharp-edges` reframed as a misuse-resistance question |
| Static analysis | `semgrep` | ToB `semgrep`, `codeql` | `semgrep` narrowed. `codeql` demoted to manual because it builds databases |
| Dependency and supply chain | `supply-chain-risk-auditor` | none | Unmodified. The router keeps it out of the feature lifecycle |
| Git, PR, CI | `ce-commit*`, `ce-babysit-pr`, `ce-resolve-pr-feedback` | ToB `gh-cli`, `git-cleanup`, `github-triage`; Cursor `fix-ci`, `loop-on-ci`, `new-branch-and-pr` | Excluded |
| Deployment | Vercel MCP server | Vercel `deploy-to-vercel`, `vercel-cli-with-tokens`, `vercel-optimize`; AWS `launch-with-aws` | Deploy skills excluded, the MCP already owns it. `vercel-optimize` demoted to manual. `launch-with-aws` removed in the AWS trim |
| Infrastructure as code | `ce-work` plus `terraform-style-guide` | HashiCorp `terraform-style-guide`; AWS `aws-cdk`, `aws-cloudformation` | The style guide lost its review verb. The AWS IaC skills were dropped, this environment uses Terraform |
| Python tooling | `modern-python` | ToB `modern-python` | Trigger widened to name the moments Python tooling is chosen |
| Learning and documentation | `ce-compound`, `ce-explain` | Pocock `retro`, `teach`, `handoff`, `writing-*`; Cursor `teach`, `continual-learning`, `recall`, `reflect` | Excluded, all duplicates of a Compound skill |
| Design rationale | `why` | nothing | New domain. `ce-explain` teaches how something works, `why` reconstructs why it was decided |
| CLI design | `cli-for-agents` | nothing | New domain |
| Prose editing | `unslop` | nothing | Trigger narrowed from "must always apply" to human-facing prose |

## Installation strategy

Three mechanisms, chosen per source by what the source needs.

**Compound Engineering installs natively, unmodified.** Its skills lean on plugin assets
under `src/`, and as the default owner its broad triggers are the intended ones.

**Pocock, Vercel, Cursor and HashiCorp are vendored.** All four ship self-contained skill
directories with no plugin-level dependencies, so each selected skill is copied to
`build/skills/` and symlinked into `~/.claude/skills`. The copy is regenerated from the
upstream clone on every build, and the routing edits live in `curation.json`, not in the
copy.

**Trail of Bits and AWS are forked into local marketplaces.** Their plugins carry agents,
hooks, MCP servers, commands, and `CLAUDE_PLUGIN_ROOT`-relative workflows that only
survive a real plugin install, and a plugin's routing metadata cannot be changed from
outside the plugin. So the selected plugins are rebuilt into `build/marketplace/` and
`build/marketplace-aws/` and installed from there. Claude's plugin cache is never
hand-edited.

Nothing under `upstream/` is ever modified. Every edit is a frontmatter key in
`curation.json`, applied at build time, and listed in [DEVIATIONS.md](DEVIATIONS.md).

## One thing the eval taught the architecture

The stack was built to stop two owners running at once. Running it found the opposite
failure and it is just as bad.

On "our Bedrock summariser returns incomplete answers", the Claude Code built-in
`claude-api` skill fired and no lifecycle owner did, four runs out of four. A knowledge
skill had claimed the prompt and the phase went unowned. The router now carries an
invariant for it: a knowledge skill firing is not a phase being owned, and when a
reference skill is the only thing that fired on non-trivial work, an owner is still
missing.

That case went from 0/2 to 2/2 after the change.
