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

I profiled the code before choosing anything. Four Python services on FastAPI,
SQLAlchemy and psycopg2. boto3 in every repo, with Bedrock, Secrets Manager, S3 and
CloudFront. Nineteen flat Terraform files under `vibeset-video/infra/` with no modules
and no tests. A Next.js portfolio. Weights and Biases wired into audio watermark
training in `fingerprinting/`. OpenAI and Bedrock in production with no evaluation
harness anywhere.

What that profile bought me:

**Fewer competing workflows.** A plain "review this PR" wakes one reviewer, not the
three that were fighting for it before curation. 78 sessions, zero duplicate owners.

**Security that fires on evidence, not on vocabulary.** "Review this PR" gets Compound
alone. "Review this authentication PR for security regressions" gets Compound plus the
Trail of Bits differential review, every run. So does "I changed how we compute refunds
and charge cards", which never says the word security.

**Python and AWS advice where I actually write it.** boto3 patterns fire on "upload the
rendered video to S3 and return a presigned URL". `modern-python` fires when a request
names Python and a dependency, and correctly stays quiet when the language is ambiguous.

**Terraform help aimed at my real problem.** Not provider development, which is what
twelve of HashiCorp's sixteen skills cover. `refactor-module` for a flat pile of `.tf`
files, `terraform-test` for the zero `.tftest.hcl` I have, `terraform-style-guide` for
authoring.

**Nothing installed for a tool I do not run.** No Supabase, no Prisma, no MLflow until I
stand up a tracking server, no Swift SDK, no Neptune or Keyspaces or DocumentDB, no
CloudFormation when the infrastructure is Terraform. The AWS plugin went from 21 skills
to 9 and from 5,005 always-on tokens to 2,421 on that basis alone.

**Deployment left alone.** The Vercel MCP already owns it here, so the Vercel deploy
skills stayed out rather than putting a second owner on the phase.

Three corrections came out of doing it this way rather than reasoning from reputation. I
excluded `modern-python` as out of scope before I had counted the Python repos, which
was wrong and is reversed. I recommended `aws-core` partly for the Terraform files, and
its infrastructure coverage turns out to be CDK and CloudFormation with no Terraform at
all. I suggested MLflow could replace Weights and Biases, and it cannot: the W&B usage
here is model training, which is the job W&B is good at, and MLflow's plugin solves
agent evaluation instead.

The exclusion list in [MANIFEST.md](MANIFEST.md) is as much the product as the include
list. It records what was considered and declined, with the reason, so the next pass
starts from a decision instead of from scratch.

## The rule

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

Latest full run: 78 sessions, 78 passes, **zero duplicate lifecycle owners**. A held-out
set of 21 cases uses deliberately different wording, to catch descriptions tuned to the
corpus rather than to the task.

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
