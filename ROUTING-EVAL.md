# Routing eval

Descriptions were not judged by reading them. Every case runs as a real headless Claude
Code session with the whole stack installed, and the runner records which skills actually
fired.

## How it works

`eval/run-eval.py` spawns `claude -p` in `eval/fixture/`, a small repo carrying the
surfaces the cases talk about: a Next.js page with a request waterfall, a JWT helper with
a fallback secret, a concurrency-limited queue with a flaky test, a Bedrock summariser,
boto3 code, Terraform, and a GitHub Actions workflow that pipes issue comments into an AI
agent.

Mutating tools are disallowed and an appended system prompt cuts the run short once
routing has happened, so a case costs a routing decision instead of a full workflow. Every
`Skill` tool call in the stream is a real selection. The raw `fired` list is stored per
run, and `eval/rescore.py` re-scores stored runs against the current corpus without
spending anything, which matters because several early failures were bad expectations
rather than bad routing.

The runner exits non-zero the moment two lifecycle owners fire in one session.

## Corpus

26 cases in `eval/corpus.jsonl`, covering clear positives, clear negatives, ambiguous
prompts, cross-domain prompts, and cases built to force a collision. 18 more in
`eval/heldout.jsonl` use deliberately different wording for the same routing intents, to
catch descriptions tuned to the corpus.

Each case declares the owners it will accept, the supporting skills it requires, the
skills it forbids, and whether an owner is needed at all.

## Results

| Run | Sessions | Pass | Duplicate owners |
|---|---|---|---|
| Corpus, 2 runs per case | 52 | 52 (100%) | **0** |
| Held-out, 2 runs per case | 44 | 42 (95%) | **0** |

Across every run in this repo, roughly 190 sessions, **no session ever fired two
lifecycle owners**. That was the hard acceptance criterion.

Selected behaviour, from the final sweep:

| Prompt | Fired |
|---|---|
| Review this PR | `ce-code-review` |
| Review this authentication PR for security regressions | `ce-code-review` + `differential-review` |
| I changed how we compute refunds and charge cards | `ce-code-review` + `differential-review` |
| Fix this hydration mismatch | `ce-debug` + `react-best-practices` |
| I have tried three fixes and cannot explain this race | `ce-debug` + `diagnosing-bugs` |
| Clarify whether Organization, Workspace and Tenant differ | `domain-modeling` |
| Audit our npm dependencies for supply-chain risk | `supply-chain-risk-auditor` |
| Change this string typo | nothing |
| What does canEditWorkspace do | nothing |
| Find bugs in this repository | `ce-code-review`, no scanner |
| Why do we hash the beatmap before uploading | `why` |
| infra/ is nineteen flat .tf files | one planning owner + `refactor-module` + `codebase-design` |

## What running it found that reading would not

**A description that only fired when the framework was named.**
`react-best-practices` fired 3/3 on "add a settings page to this Next.js application" and
0/2 on "build me an export-to-CSV button on the settings page". Same work, same files. The
trigger now covers UI work described without naming the framework.

**A built-in skill swallowing the owner.** On "our Bedrock summariser returns incomplete
answers", Claude Code's own `claude-api` skill fired and no lifecycle owner did, 4/4. Not
the duplicate-owner failure this stack exists to prevent, the mirror image of it. The
router now says a knowledge skill firing is not a phase being owned. The case went to 2/2,
then settled at 1/2 over more runs, so it is improved rather than solved.

**An installer shipping stale plugins.** Claude Code caches a plugin by version and an
edited fork keeps its upstream version, so a rebuilt fork was never re-copied. I spent an
eval round testing an old description while reading the new one. `build.py` now
fingerprints each forked plugin and `install.sh` reinstalls only what moved.

**Two of my own cases were wrong, not the routing.** One expected `modern-python` to fire
on "write a standalone script to re-encode the audio fixtures". It never did, across five
runs, and it was right: the prompt never says Python and the fixture holds both a
`package.json` and a `requirements.txt`. That case became a negative and a positive twin
naming Python replaced it, which passes 2/2. The other treated `diagnosing-bugs` as a
lifecycle owner, so the intended escalation scored as a duplicate.

## Known limitations

**Passive overlays are probabilistic.** `react-best-practices` sits around 1/2 on the
hardest held-out phrasing. It advises rather than owns, so a miss costs advice, not
correctness. Worth another description pass.

**`claude-api` still wins sometimes.** On LLM-related work it occasionally claims the
prompt and leaves the phase unowned. It ships with Claude Code and this repo cannot change
its trigger, so the router invariant is the only lever.

**Cost.** A full corpus run at 2 runs per case is roughly 100 headless Opus sessions and
about $12. Use `--case` and `--tag` while iterating, and `rescore.py` whenever the
scoring rule rather than the routing is what changed.
