# agent-skill-stack

Seven upstream skill collections, curated into one Claude Code environment where exactly
one workflow owns each phase of engineering work.

The problem this repo solves is not "which skills are good". It is that four
independently authored collections all describe themselves as the thing to use when you
review code, debug a failure, or plan a feature. Install them side by side and a plain
"review this PR" can wake three reviewers at once, each starting its own loop over the
same diff.

Nothing here rewrites anyone's skill. The fix is routing metadata. Every change this
repo makes is a `description` or a `disable-model-invocation` flag, applied at build
time from one file, and every one of them is listed with the upstream text it replaced.

## What is installed

| Layer | Source | What it owns |
|---|---|---|
| Lifecycle | [Compound Engineering](https://github.com/EveryInc/compound-engineering-plugin) | Brainstorm, plan, implement, debug, review, PR, ship, capture the learning |
| Methodology | [Matt Pocock](https://github.com/mattpocock/skills) | Domain modeling, module design, test-first, deep diagnosis |
| Frontend | [Vercel Labs](https://github.com/vercel-labs/agent-skills) | React and Next.js performance, component API shape, accessibility audit |
| Security | [Trail of Bits](https://github.com/trailofbits/skills) | Security diffs, supply chain, static analysis, variant hunting, Python tooling |
| Infrastructure | [AWS](https://github.com/aws/agent-toolkit-for-aws), [HashiCorp](https://github.com/hashicorp/agent-skills) | boto3, Bedrock, IAM, CloudWatch, Terraform authoring and tests |
| Tooling | [Cursor](https://github.com/cursor/plugins) | CLI design, design-rationale archaeology, prose editing, documentation style |

31 curated skills carry routing metadata from this repo. Compound Engineering's 33
install unmodified, because it is the default owner and its triggers are meant to be
broad.

## What it does for a working day

Install seven skill collections raw and they fight each other. These do not, and the
difference shows up in ordinary work rather than in a diagram.

**You stop refereeing your own tools.** Ask for a review and you get a reviewer. Nine
workflows advertised for "review this PR" before curation: Matt Pocock's two-axis review,
three from Trail of Bits, two from Vercel, and three from Cursor. Now the bare phrase
routes to `ce-code-review` alone, three runs out of three. So does "take a look at my
changes", and so does "find bugs in this repository", which never wakes a scanner.

**The security specialist arrives on evidence, not on the word security.** Say "review
this authentication PR for security regressions" and you get the review owner plus Trail
of Bits `differential-review`, three out of three. Say "I changed how we compute refunds
and charge cards", which contains no security vocabulary at all, and you get the same
pair, two out of two. Payments sits on the list of surfaces that trigger escalation, so
the specialist threat-models the change whether or not you thought to ask.

**Small work stays small.** "Change this string typo" fires nothing, nine runs out of
nine. "What does canEditWorkspace do" fires nothing, seven out of seven. "Rename the
prefs variable to preferences" fires nothing, six out of six. Twenty-two sessions of
trivial work, no skill selected and no plan written.

**The specialist you asked for is the one you get.** "Audit our npm dependencies for
supply-chain risk" runs `supply-chain-risk-auditor` directly, three out of three, with no
feature lifecycle wrapped around a dependency audit.

**Escalation waits for a reason.** "Fix this hydration mismatch" gets `ce-debug` and the
React overlay, and Matt Pocock's deep diagnosis stays out of it. Add the evidence, as in
"I have tried three fixes and still cannot explain this race condition", and
`diagnosing-bugs` joins the same owner. Three out of three both ways.

**Advice shows up where you write code, without taking over.** Ask for an export-to-CSV
button and you get the implementation owner plus Vercel's React rules, seven out of
seven. Ask why a page feels slow and you get the debugger plus those rules, six out of
six. The overlay advises. It never runs the phase.

### What stacking seven collections should have cost

Three costs are worth expecting. Each one is measured rather than argued.

**Workflows fighting over the same code.** `eval/results/` holds 204 scored sessions.
None of them fired two lifecycle owners. That is the number this repo
exists to hold at zero, and it is the only one that was never allowed to move.

**Noise on work too small to need it.** The trivial cases above cover 22 sessions across
three phrasings, and no skill fired in any of them. Those cases forbid every passive overlay by
name, so a widened trigger cannot slip past unnoticed.

**Context you pay for on every prompt.** About 8,800 tokens of always-on skill
descriptions, roughly 1% of a 1M window. Trimming got it there. The AWS plugin dropped from 21 skills
to 9, and four skills that only run when you type them carry
`disable-model-invocation`, which drops them out of the model's listing.

Every count above comes from the stored runs, not from memory. Regenerate them with:

```bash
python3 scripts/render-verification.py    # coverage matrix and fire counts
python3 eval/rescore.py eval/results/final-corpus.json
```

[VERIFICATION.md](VERIFICATION.md) has the method behind each claim, and a generated
coverage matrix naming which cases exercise which skill.

## How the rule works

Compound Engineering owns every phase by default. A non-Compound workflow becomes the
owner only when the request is a different operation, not a differently worded version of
the same one. When two candidates fit, Compound wins.

Five lines go in `~/.claude/CLAUDE.md`, where they are always in context. Everything else
lives in the `engineering-router` skill. Where the rule lives decides whether it holds. A rule
that has to work when routing goes wrong cannot live in a skill that routing has to select
first. The eval measured the gap. The same invariant held 1 time in 2 from the router and
3 times in 3 from the global file.

Every other skill falls into one of three classes.

**Passive.** Cheap knowledge that advises whoever is running. React performance rules,
HCL conventions, boto3 patterns.

**Conditional.** Fires on a narrow trigger, or when the owner hands off. Deep bug
diagnosis after ordinary debugging failed. A security diff review when the change touches
authentication.

**Manual.** Expensive or side-effecting, so `disable-model-invocation: true` hides it
from the model. CodeQL, a whole-codebase audit pass, a second-opinion review. The model
cannot pick these. You type them.

That last class is what makes "do not compete with the default reviewer" enforceable
instead of aspirational.

Read [ARCHITECTURE.md](ARCHITECTURE.md) for the conflict matrix and the ownership model,
and [ROUTING-EVAL.md](ROUTING-EVAL.md) for the eval harness and the three defects it
found that reading the descriptions never would have.

## Install

```bash
./scripts/sync.sh      # clone or update upstreams, rebuild, regenerate the docs
./scripts/install.sh   # symlink skills, install plugins, append the CLAUDE.md rule
```

Restart Claude Code afterwards.

`sync.sh` pulls every clone in `upstream/`, rebuilds `build/` from scratch, and rewrites
`MANIFEST.md` and `DEVIATIONS.md` so they cannot drift from what is installed. Read
`git diff` after a sync. That is the review step, and it is the point of the whole
arrangement: if upstream has already narrowed a description this repo was narrowing, the
diff is where you see it, and the right move is to delete the override rather than keep
carrying it.

## How it is built

```
upstream/        read-only git clones, never edited, never committed
curation.json    what is included, what is excluded and why, every routing change
overlay/         reserved for changes that cannot be expressed as frontmatter
src/             the engineering-router skill and the CLAUDE.md snippet
build/           generated: vendored skills, plus a forked Trail of Bits marketplace
eval/            corpus, held-out set, runner, fixture repo, results
scripts/         sync, build, render-docs, install
```

Three install mechanisms, picked per source by what the source needs.

Compound Engineering installs natively from its own marketplace, unmodified. Its skills
depend on plugin assets under `src/`, and nothing about its routing needed changing.

Pocock, Vercel, Cursor and HashiCorp ship self-contained skill directories with no
plugin-level dependencies, so the selected ones get copied into `build/skills/` and
symlinked into `~/.claude/skills`.

Trail of Bits gets forked. Its plugins carry agents, hooks, commands and
`CLAUDE_PLUGIN_ROOT`-relative workflows that only survive a real plugin install, and a
plugin's routing metadata cannot be changed from outside the plugin. So the selected
plugins are rebuilt into `build/marketplace/` and installed from there as
`trailofbits-curated`. Claude's plugin cache is never hand-edited.

## What was left out, and why

`MANIFEST.md` lists every skill considered and declined, with the reason. Some of it is
worth knowing before you go adding more.

Trail of Bits `second-opinion` runs an external LLM review of a diff. Good skill, but it
would have been a third owner in the review domain. Cursor's `review-and-ship` and
`thermo-nuclear-review` are the same story.

HashiCorp ships sixteen Terraform skills. Twelve are for people writing Terraform
*providers*, and three more are Azure or paid HCP products. Three are useful here, so
three are installed, and the plugin is not.

The Vercel deploy skills are out because the Vercel MCP server already owns deployment
in this environment. Installing them would put two owners on that phase for no gain.

## Credits

Almost none of this is my work. [CREDITS.md](CREDITS.md) names every author and licence.
The short version: Compound Engineering is by Kieran Klaassen and Trevin Chow at Every,
and it does most of the heavy lifting here. The Trail of Bits plugins are CC BY-SA 4.0,
so the fork under `build/marketplace/` stays CC BY-SA 4.0 and says so. The three
HashiCorp files are MPL 2.0. Everything original in this repo is MIT.

## Reading order

[ARCHITECTURE.md](ARCHITECTURE.md) has the ownership model, the four invocation classes,
and the conflict matrix showing who was fighting over what before curation.
[VERIFICATION.md](VERIFICATION.md) has the testing method per invocation class and a
generated coverage matrix showing which cases exercise which skill.
[DEVIATIONS.md](DEVIATIONS.md) has every changed description next to the upstream text.
[MANIFEST.md](MANIFEST.md) has pinned commits and the exclusion list.
[UPDATING.md](UPDATING.md) is the update procedure.
