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
| Held-out, 2 runs per case | 44 | 44 (100%) | **0** |

Across every run in this repo, roughly 300 sessions, **no session ever fired two lifecycle
owners**. That was the hard acceptance criterion, and it is the only number here that was
never allowed to move.

The 100% is younger and less impressive than it looks. It arrived after four rounds of
fixes, three to descriptions and one to where the global rule lives, and after four of my
own cases turned out to encode expectations the design never had. Those corrections are
recorded next to the results rather than folded away.

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

**A description whose first clause was doing the routing.** `react-best-practices` fired
3/3 on "add a settings page to this Next.js application" and 0/2 on "build me an
export-to-CSV button on the settings page". Same work, same files.

Widening the trigger to name unnamed-framework UI work lifted it to 1/2. Still
unreliable, and the second round found why: the description opened with "React and
Next.js performance rules", so on a plain feature build with no performance angle the
model read the whole skill as irrelevant and never got to the trigger. Rewriting the
opening to "Vercel Engineering's rules for writing React and Next.js" and saying consult
by default took it to 5/5 across both prompts, with the trivial-edit negatives still
firing nothing and `web-design-guidelines` still owning accessibility alone.

The lesson generalises. A trigger clause cannot rescue an opening clause that has already
told the model this skill is about something else.

**A built-in skill swallowing the owner, and a router that could not stop it.** On "our
Bedrock summariser returns incomplete answers", Claude Code's own `claude-api` skill fired
and no lifecycle owner did, 4/4. Not the duplicate-owner failure this stack exists to
prevent, the mirror image of it.

Adding an invariant to the router helped and did not hold: the case went to 2/2, then back
to 1/2. The reason is structural. The router is itself a skill, so when the reference skill
wins the selection the router is not selected either, and its invariant never loads. A rule
that only applies when routing went well cannot fix routing going badly.

Moving that one sentence into `~/.claude/CLAUDE.md`, which is always in context, fixed it.
The Bedrock case went to 3/3, and "the settings page feels slow, why" went from 1/2 to 3/3
after the same change. The trivial-edit negatives still fire nothing, so the rule did not
simply manufacture owners.

That is the strongest argument in this repo for keeping the global rule tiny and keeping it
global. Five lines that always apply beat a well-argued skill that has to be chosen first.

**An installer shipping stale plugins.** Claude Code caches a plugin by version and an
edited fork keeps its upstream version, so a rebuilt fork was never re-copied. I spent an
eval round testing an old description while reading the new one. `build.py` now
fingerprints each forked plugin and `install.sh` reinstalls only what moved.

**Two skills whose triggers named the library instead of the task.** `aws-sdk-python-usage`
lists "S3 file transfers and presigned URLs" in its own description, and still fired 1/3 on
"add a function that uploads the rendered video to S3 and returns a presigned URL". Every
clause of its trigger was conditioned on the prompt naming Python, boto3, or botocore, and
in a repo holding both a `package.json` and a `requirements.txt` the model cannot confirm
that without opening files. Rewriting the trigger to key on the AWS operation in a Python
codebase took it to 3/3.

`react-best-practices` had the same shape and needed the same fix. Two of the three
description defects found here were this one pattern: a trigger that describes the
technology rather than the moment.

**Two of my own cases were wrong, not the routing.** One expected `modern-python` to fire
on "write a standalone script to re-encode the audio fixtures". It never did, across five
runs, and it was right: the prompt never says Python and the fixture holds both a
`package.json` and a `requirements.txt`. That case became a negative and a positive twin
naming Python replaced it, which passes 2/2. The other treated `diagnosing-bugs` as a
lifecycle owner, so the intended escalation scored as a duplicate.

## Known limitations

**`claude-api` still wins sometimes.** On LLM-related work Claude Code's own reference
skill occasionally claims the prompt and leaves the phase unowned. It ships with the host
and this repo cannot change its trigger, so the router invariant is the only lever. The
worst case went from 0/2 to 1/2, which is better rather than fixed.

**Every case is scored on skill selection, not on outcome.** The harness proves the right
skills were chosen. Whether the work that follows is any good is a different question and
this corpus does not ask it.

**Cost.** A full corpus run at 2 runs per case is roughly 100 headless Opus sessions and
about $12. Use `--case` and `--tag` while iterating, and `rescore.py` whenever the
scoring rule rather than the routing is what changed.
