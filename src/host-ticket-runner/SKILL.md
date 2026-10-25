---
name: host-ticket-runner
description: Launch one headless Claude Code agent on a GitHub issue, on a macOS or Windows host with no container, that implements it through the Compound Engineering lifecycle and opens a PR; per-run hooks refuse to let it stop until every step is shown. Manual invocation only.
disable-model-invocation: true
---

# Host ticket runner

Three roles. The **owner** is the human. The **orchestrator** is this session: it picks tickets, launches, watches, reviews the PR and merges it. A **ticket agent** is one `claude -p` run with permissions bypassed, in its own git worktree of the target repo, that sees only the ticket body and takes it from implementation to an open PR. The agent never merges; the orchestrator never writes the ticket's code.

This is the light-host sibling of `milestone-supervisor`: same Compound Engineering order, acceptance ids, budgets, escalation and resume discipline, but no Docker sandbox, no systemd and no gate run by the host. Enforcement lives in hooks inside the agent's own session. A host that has never run it needs [`SETUP.md`](SETUP.md) first; the AWS principal the agents use is the owner's to create, from [`AWS.md`](AWS.md).

The driver is `htr.py` next to this file. `htr.py --help` lists the verbs and `htr.py <verb> --help` gives each one's options with examples; this file says when to use them. On Windows run it as `py htr.py`.

## The lifecycle a ticket agent runs

The brief (`templates/brief.md`, filled per ticket) gives the agent this order:

1. **Thin ticket only** (no acceptance criteria found): `ce-plan` with the ticket file as the request, Durable contract, plan committed. Its acceptance criteria get written there.
2. `ce-work mode:return-to-caller <ticket file or plan path>`: implementation and local verification, unit-scoped commits.
3. `ce-simplify-code` on the branch diff.
4. `ce-code-review apply:local plan:<same path>`: verified findings applied and committed, residuals kept for the PR body.
5. `ce-compound mode:non-interactive depth:lightweight`, invoked once; "Documentation skipped" is an acceptable end. It comes before the checks because a learning it writes is an edit.
6. The project's full test suite and linters, green, after the last edit.
7. `ce-commit-push-pr mode:pipeline babysit:off`: push the branch, open the PR. Its body cites every criterion id, has a "Review findings" heading and an "Owner actions needed" section.

A ticket with acceptance criteria goes straight to step 2: the criteria are the plan. Its `cycle:` decides which of the steps above it is held to (see the routing section). They are extracted at launch from a heading such as "Acceptance criteria" or "Done when" (its list items, else its sentences), or from an `Exit:` paragraph, into `acceptance.json` with ids `T<issue>.c1`, `T<issue>.c2`. The brief hands the agent those ids and the PR must cite each one, so the record stays the one copy of the criteria. `--route plan-first` forces step 1 for a ticket whose criteria are not enough of a plan.

## Model and effort: the routing table

A run's model and effort follow its lifecycle phase. **build** writes the change (`ce-plan` when the ticket has one, `ce-work`, `ce-simplify-code`), **judge** checks it (`ce-code-review`, and `ce-debug` when the agent uses it), **finish** ships it (`ce-compound`, the tests and linters, `ce-commit-push-pr`, the PR). Each phase is one turn of the same session. `htr.py route --repo R --issue N` prints what a ticket resolves to and why, phase by phase. First matching row wins:

| Tier | When | Build | Judge | Finish | Default cycle |
|---|---|---|---|---|---|
| **heavy** | a label `size:l`, `size:xl`, `risk`, `security`, `infra`, `migration`, `breaking` or `cross-boundary`; or risk words in the title or body (auth, OAuth, login, credentials, secrets, IAM, payments, billing, migrations, schema change, Terraform, deploy, security, encryption, concurrency, race condition, breaking change, public API, tenancy); or 6000+ characters or 9+ criteria | `opus` / `high` | `opus` / `high` | `sonnet` / `medium` | `full` |
| **light** | a label `docs`, `documentation`, `typo`, `chore`, `trivial`, `size:xs`, `size:s` or `good first issue` on a ticket with criteria (these labels outrank risk words, the heavy labels outrank them); or a ticket with criteria, at most 1500 characters and 3 criteria, and no risk words | `sonnet` / `medium` | `opus` / `medium` | `sonnet` / `low` | `lean` |
| **standard** | everything else, including every thin ticket | `sonnet` / `medium` | `opus` / `high` | `sonnet` / `low` | `full` |

**Each ticket gets its own calls.** `model:` (haiku, sonnet, opus; never above Opus) and `effort:` (low to max) labels set the build phase, `judge-model:` and `judge-effort:` the judge phase, and `cycle:` the cycle. They decide ahead of every heuristic row above, independently of each other, and a `tier:` label only sets the defaults. The judge is Opus, and its effort is the higher of the table's and the build phase's, so an `effort:xhigh` ticket is judged at `xhigh`. A `judge-effort:` label overrides that. The finish phase follows the table.

**How the phases run.** The launch turn starts the session on the build model and effort. When the build steps are all shown, the Stop hook lets that turn end instead of blocking it, and the supervisor resumes the same session (`claude -p --resume <session id> --model <next> --effort <next>`) in the same worktree with a message that names the next phase, lists its steps and says to read `git status` and `git log` first. The hook blocks each turn's stop only for the steps of its own phase or an earlier one. A phase whose steps the cycle leaves out has no turn: a `lean` run has no simplify step and no `ce-compound`, and a `none` run has no step to show for building, so its one turn runs everything on the build model. Phase turns are not finishing turns. A run launched before phases existed (no `phases` in its `run.json`) keeps one model for the whole run and one turn that the hook holds until the whole cycle is shown.

The cycle is how much of Compound Engineering the run is held to:

| Cycle | Steps the Stop hook requires |
|---|---|
| `none` | implement directly (no CE skills, a self-review against each criterion), the full checks, the PR |
| `lean` | `ce-work`, a quick `ce-code-review`, the full checks, `ce-commit-push-pr` |
| `full` | `ce-work`, `ce-simplify-code`, `ce-code-review`, `ce-compound`, the full checks, `ce-commit-push-pr` |

`ce-plan` runs first only for a ticket with no acceptance criteria, or one labelled `plan:first`. Every cycle keeps the full checks after the last edit and a PR that cites every criterion, and the orchestrator reviews every PR before merging. The labels are how the orchestrator records its call on the ticket, so a relaunch routes the same way.

Overrides per ticket: `--tier`, `--model`, `--effort` (the build phase), `--judge-model`, `--judge-effort`, `--cycle`, which beat the labels. The cap is Opus, from the owner's CLAUDE.md rule: `--model` and `--judge-model` (and their labels) accept `haiku`, `sonnet`, `opus` or a `claude-haiku|sonnet|opus-*` id and refuse anything else with exit 2, whatever model this session runs on. Effort may go up to `xhigh` or `max` on a ticket that earns it. Raise a tier when the ticket is small in words but touches a boundary the table cannot see (a shared schema, a public contract); lower one only for a ticket you have read.

## How the hooks enforce it

`launch` writes the run's own `settings.json` and passes it with `--settings`; nothing goes into the owner's settings or the target repo. Each hook runs `htr_hooks.py <verb> --run <run dir>` in exec form.

- **PostToolUse on `Skill`, `Bash`, `Edit`, `Write`** (and `PostToolUseFailure` on `Skill`, `Bash`) append one line each to `markers.jsonl`: which skill ran (namespace stripped), each Bash command with its exit code (0 on PostToolUse; the code from `Exit code N` on failure), each file edit.
- **Stop** evaluates the markers and the repository, and blocks with the list of what is missing until all of these hold:
  - each required skill was invoked, a `ce-work` after the first `ce-plan`, the last `ce-code-review` after the last `ce-work` and `ce-simplify-code`, and the last `ce-commit-push-pr` after the last review;
  - the last command classed as a test run, and the last classed as a lint run, exited 0, ran after the last edit inside the worktree, ran in the foreground, and own the command's exit code (anything after them chained only with `&&`, so not `| tail`, `|| true`, `; echo $?` or a trailing `&`). A command counts by how a segment starts: `pytest`, `uv run pytest`, `pnpm test`, `just gate` and so on for tests; `ruff`, `eslint`, `tsc`, `just lint`, `just gate` and so on for lint. A segment that prints a version or help, lists tests (`--collect-only`), or picks a subset (`-k`, `-t`, `-run`, a `file::test` node id, `--lf`) does not count. `--test-regex` and `--lint-regex` replace the patterns (an invalid one is refused at launch with exit 2); `--skip-step tests|lint` drops a step for a repo that has none;
  - the worktree is clean, and `gh pr view <branch>` finds an open (or merged) PR whose head is the worktree's HEAD, whose body cites every criterion id and has a heading naming the review findings.
  When all hold it writes `complete.json` and lets the run end. In a phased run it lets a turn end (a `phase-done` marker naming the next phase) once nothing of that turn's phase or an earlier one is missing, and blocks only for those steps. A `run.json` it cannot read, or one with no required steps, escalates rather than completing.
- **Budgets.** The Stop hook blocks at most 8 times per turn (`--max-stop-blocks`; a finishing turn starts a fresh count), and escalates early when the agent stops twice in a row with the same steps missing and no tool call in between: `stop_hook_active` is how it tells a stop it already blocked from a fresh one. On either, it writes `escalation.md` (what is missing, why it stopped, the agent's last message, the resume command) and lets the run end. An escalation is a stop, not a retry.
- **PreToolUse on file tools and `Bash`** denies anything that reaches the real `~/.aws`: a file tool path inside it (any letter case on macOS and Windows, or another name for the same folder), a `Grep` or `Glob` rooted at it or at a folder that holds it (home, `/`), and a Bash command that names it, a bare `.aws`, drops or repoints the runner's AWS variables (`env -i`, `env -u AWS_*`, `unset AWS_*`, `AWS_SHARED_CREDENTIALS_FILE=`, `AWS_CONFIG_FILE=`, an `AWS_PROFILE=` other than the runner's), or searches or copies from home or `/` (`grep -r … ~`, `find / …`). It is the only deny hook: no other guardrail is installed, by the owner's decision.

**No MCP servers.** Every agent starts with `--strict-mcp-config` and an empty `mcp.json` in its run folder, so no user, project or plugin MCP server loads. An MCP server starts with its own environment, which the AWS scrub does not reach, so a host server holding the owner's credentials would otherwise hand them to the agent. A ticket that needs an MCP server is run attended, not through this runner.

What the hooks prove is that the steps ran in order and the checks exited 0 after the last edit. They do not prove that `ce-code-review`'s findings were good or that the tests cover the criteria; the PR review below does that.

## Running a ticket

1. **Preflight.** `htr.py preflight` once per session (add `--agent` after any change to the AWS setup: it launches a short haiku agent with a run's env and hooks and shows what AWS it sees). Done when every row is ok. Never run a host `/login` while `htr.py status` shows a run `running`: it revokes the token the agent uses, its next call fails with a 401 and the run ends.
2. **Route.** `htr.py route --repo R --issue N`. Done when the tier, model and effort are ones you would defend, and the criteria listed are the ticket's own. Override on the launch line otherwise.
3. **Launch.** `htr.py launch --repo R --issue N [--checkout PATH]`. It fetches the base, creates `htr/<issue>-<slug>` in a fresh worktree under `HTR_HOME/worktrees/`, writes the brief, hooks and acceptance record, and starts the agent detached, so the run outlives this session (`--detach launchd` on macOS or `schtasks` on Windows for a scheduler-owned process). It returns at once. Relaunching a running or completed ticket prints the existing run and does nothing; `--again` overrides. Done when `htr.py status --run <id>` shows `running`.
4. **Watch.** Poll `htr.py status` at most once a minute, or arm one watch that fires on any state other than `running`. States: `running`, `complete`, `escalated`, `ended-incomplete` (the turn ended without the PR), `auth-expired` (the last turn's log shows the CLI's 401 or expired-token error), `dead` (no exit recorded and no process: a reboot or a kill). Parallel tickets are fine: each has its own worktree and branch, and its own 100-port block (`HTR_PORT_BASE`, from 20000 up, held while the run is live) that the brief tells it to start every server in. `--copy-in PATH` (repeatable) copies an untracked file from the checkout into the worktree at the same path, such as a seeded database the repo gitignores, and the brief names it. Each run's Bash foreground limit is 45 minutes (`BASH_MAX_TIMEOUT_MS`), because a full repo gate on a shared machine outlasts the default 10 and the Stop hook counts only foreground runs. Run in parallel only tickets that touch different files, or the second PR to merge inherits the conflict.
5. **Finish a run that ended early.** `htr.py resume` prints, per unfinished run, the finishing turn listing what the markers do not show; read it against `agent.log`, then `htr.py resume --run <id> --send`. It continues the same conversation (`--resume <session id>`) with the same hooks. In a phased run the finishing turn runs on the phase of the first missing step, with that phase's model and effort (unfinished review findings go to the judge, a missing PR to the finish model), and the later phases follow as phase turns. Two finishing turns per run (`--max-finishing-turns`); past that, or for an escalated run, `--send --extend` grants one more and records who did (an escalated run sent without `--extend` is refused with exit 2). Auth-expired needs the owner's re-login first.
6. **Review and merge.** On `complete`, read the PR, not the agent's summary: each criterion id against the diff and the tests that would fail if it broke, the review section's residuals, the "Owner actions needed" list. For a ticket with a runnable surface, an independent evaluator on `opus` using [`../milestone-supervisor/EVALUATOR.md`](../milestone-supervisor/EVALUATOR.md), with the ticket body as the milestone section and its findings posted as a PR comment, catches what the tests do not. Merge it yourself, then `htr.py clean --run <id>` removes the worktree. Done when the PR is merged or sent back with a comment, and the run's worktree is gone.

## Limits

- No sandbox: the agent runs as the owner's user with the owner's files, network and `gh` login. The hooks steer it; they do not contain it.
- The `~/.aws` deny matches paths and command text. A command that builds the path or drops the variables at run time (`cat $(echo ~)/.a''ws/...`, a script, a program that clears its own environment) gets past it, and an AWS CLI or SDK that loses the runner's `AWS_*` variables falls back to the real `~/.aws`; only a separate OS user would close that. The env scrub and the runner-owned AWS files are what keep the host's keys out of reach by default.
- The test-run check reads command text: a run whose exit code is hidden inside a script or by `set +e` in a recipe, or a subset named by file path (`pytest tests/test_one.py`), still counts. The PR review is the backstop.
- The worktree is a fresh checkout: gitignored inputs the repo's checks need (a local database, a `.env`, a downloaded fixture) are not in it, so a repo whose gates read them fails its tests in the run, and the Stop hook escalates. Launch such a repo with `--skip-step tests` or `lint` only when the owner accepts that, or make its gates work from a clean clone first.
- Windows support is implemented and unit-tested only for what runs on any OS; the detached launch, Task Scheduler mode and hooks under Windows have not been run on a Windows host (see `SETUP.md`).

## What a run keeps

Under `HTR_HOME/runs/<id>/`: `run.json` (route, tier, the phases with their steps, model and effort, required steps, budgets, session id), `ticket.md`, `acceptance.json`, `prompt.md`, `settings.json`, `markers.jsonl`, `agent.log`, `supervisor.log`, `exit.json`, and `complete.json` or `escalation.md`. The worktree is under `HTR_HOME/worktrees/<id>/` until `clean`. `htr_hooks.py evaluate --run <dir>` prints the step evaluation as JSON.
