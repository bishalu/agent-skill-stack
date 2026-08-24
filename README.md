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
| Tooling | [Cursor](https://github.com/cursor/plugins) | CLI design, design-rationale archaeology, prose editing |

31 curated skills carry routing metadata from this repo. Compound Engineering's 33
install unmodified, because it is the default owner and its triggers are meant to be
broad.

## Curated for this environment

This is not a general-purpose bundle. Every include and exclude was decided against the
repos on this machine, and that is the reason it is worth running.

I read the code before choosing anything, and the profile decided the stack: Python
services on FastAPI and SQLAlchemy, boto3 and Bedrock throughout, Terraform for
infrastructure, a Next.js frontend, and Weights and Biases for model training runs.

Run the same exercise against a Django and GCP shop and you should end up with a
different set. That is the point. The method transfers, the selection does not.

What the profile bought:

**Fewer competing workflows.** A plain "review this PR" wakes one reviewer, not the
three that were fighting for it before curation. Across every run in this repo, roughly
300 headless sessions, no session has ever fired two.

**Security that fires on evidence, not on vocabulary.** "Review this PR" gets Compound
alone. "Review this authentication PR for security regressions" gets Compound plus the
Trail of Bits differential review, every run. So does "I changed how we compute refunds
and charge cards", which never says the word security.

**Python and AWS advice where I actually write it.** boto3 patterns fire on "upload the
rendered video to S3 and return a presigned URL". `modern-python` fires when a request
names Python and a dependency, and correctly stays quiet when the language is ambiguous.

**Terraform help aimed at authoring, not provider development.** Twelve of HashiCorp's
sixteen skills are for people writing Terraform providers. Three are for people writing
Terraform: `terraform-style-guide` for conventions, `refactor-module` for turning flat
configuration into modules, `terraform-test` for `.tftest.hcl`.

**Nothing installed for a tool that is not running here.** No Supabase, no Prisma, no
Swift SDK, no Neptune or Keyspaces or DocumentDB, no CloudFormation when the
infrastructure is Terraform, no MLflow without a tracking server to point it at. The AWS
plugin went from 21 skills to 9, and from 5,005 always-on tokens to 2,421, on that basis
alone.

**Deployment left alone.** The Vercel MCP already owns it here, so the Vercel deploy
skills stayed out rather than putting a second owner on the phase.

Three corrections came out of profiling rather than reasoning from reputation.
`modern-python` was excluded as out of scope before anyone had counted the Python
services, which was wrong and is reversed. `aws-core` was recommended partly for
Terraform coverage it does not have, since its infrastructure skills are CDK and
CloudFormation. And MLflow was floated as a replacement for Weights and Biases, which it
is not: W&B is doing model training here, the job it is good at, while MLflow's plugin
solves agent evaluation.

The exclusion list in [MANIFEST.md](MANIFEST.md) is as much the product as the include
list. It records what was considered and declined, with the reason, so the next pass
starts from a decision instead of from scratch.

## The rule

Five lines go into `~/.claude/CLAUDE.md`, where they are always in context. Everything
else is in the `engineering-router` skill. That split matters: a rule that has to work
when routing goes wrong cannot live in a skill that routing has to select first.

Compound Engineering owns every phase by default. A non-Compound workflow becomes the
owner only when the request is a different operation, not a differently worded version
of the same one. When two candidates fit, Compound wins.

Everything else falls into three classes.

**Passive.** Cheap knowledge that advises whoever is running. React performance rules,
HCL conventions, boto3 patterns.

**Conditional.** Fires on a narrow trigger, or when the owner hands off. Deep bug
diagnosis after ordinary debugging failed. A security diff review when the change
touches authentication.

**Manual.** Expensive or side-effecting, so `disable-model-invocation: true` hides it
from the model entirely. CodeQL, a whole-codebase audit pass, a second-opinion review.
The model cannot pick these. You type them.

That last class is what makes "do not compete with the default reviewer" enforceable
rather than aspirational.

## Does it work

I did not judge this by reading descriptions. The eval runs each prompt through a real
headless Claude Code session with the whole stack installed, and records which skills
actually fired.

```bash
python3 eval/run-eval.py --runs 3              # 26 cases, three runs each
python3 eval/run-eval.py --tag collision       # only the cases built to force a fight
python3 eval/rescore.py eval/results/x.json    # rescore stored runs, no new sessions
```

Latest full run: 26 corpus cases over 52 sessions and 22 held-out cases over 44 sessions,
both at 100%, with **zero duplicate lifecycle owners**. The held-out set uses
deliberately different wording for the same routing intents, to catch descriptions tuned
to the corpus rather than to the task.

The pass rate is the less interesting number. Duplicate owners is the one the stack
exists to drive to zero, and it has never been anything else.

The runner exits non-zero the moment two lifecycle owners fire in one session. Treat
that as the gate it is.

Three real defects came out of running it, none of which reading would have caught.

`react-best-practices` only fired when a prompt said "React" or "Next.js" by name.
"Add a settings page to this Next.js application" fired it 3/3. "Build me an
export-to-CSV button on the settings page" fired it 0/2. Same work, same files.

A Claude Code built-in was swallowing the owner. On "our Bedrock summariser returns
incomplete answers", the `claude-api` skill fired and no lifecycle owner did, 4/4 runs.
Not the duplicate-owner failure this stack was built to prevent, the mirror image of it.
The router now carries an invariant saying a knowledge skill firing is not a phase being
owned.

My own installer was shipping stale plugins. Claude Code caches a plugin by version, and
an edited fork keeps its upstream version, so neither install nor update re-copied it.
`build.py` now fingerprints each forked plugin and `install.sh` reinstalls only what
moved.

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
[DEVIATIONS.md](DEVIATIONS.md) has every changed description next to the upstream text.
[MANIFEST.md](MANIFEST.md) has pinned commits and the exclusion list.
[UPDATING.md](UPDATING.md) is the update procedure.
