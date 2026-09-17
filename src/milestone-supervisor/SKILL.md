---
name: milestone-supervisor
description: Supervise a spec's numbered milestones being built unattended by sandboxed agents running the Compound Engineering loop. Set a project up for it, launch and watch a milestone, review its report and learnings, do or escalate owner actions, carry corrections backward and forward, merge and ship. Use when a spec has milestones with exit criteria and the owner is away from the keyboard.
---

# Milestone supervisor

Three roles. The **owner** is the human. The **supervisor** is this session: long-lived, on the host, holding the owner's tools and credentials. A **milestone agent** is one autonomous Claude Code run inside a disposable sandbox worktree, owning one milestone through the Compound Engineering loop. The agent plans, builds, reviews, commits and writes learnings. The supervisor verifies, fixes the environment, ships, and carries knowledge between milestones. Neither does the other's job.

A project without a `.milestones/` folder is not set up: read [`SETUP.md`](SETUP.md) and do that first. Everything below assumes the driver, the folder, the CE config and the permission rules from there exist.

## How the agent uses Compound Engineering

The standing rules tell the agent to run CE's loop the way `lfg` runs it, minus the shipping tail the sandbox cannot perform:

1. `ce-plan` with the milestone section as the request. Pipeline runs always take the Durable contract: a plan file under the CE artifact root, grounded in `docs/solutions/` learnings and any declared Compound Pack, reviewed by `ce-doc-review`.
2. `ce-work mode:return-to-caller <plan path>`: implementation and local verification, unit-scoped commits.
3. `ce-simplify-code` on the branch diff.
4. `ce-code-review mode:agent apply:local plan:<plan path>`: findings applied and committed; residual findings written into the report.
5. `ce-compound mode:non-interactive` for each non-obvious lesson the milestone produced, so the next `ce-plan` reads it.
6. `ce-commit` for what remains, the report last. `ce-handoff create` at the very end, so a follow-up turn or a fresh sandbox can resume.

The supervisor does the shipping tail through `run-milestones.sh integrate`: merge, gate on the host, push. Learnings ride forward only through that merge, which is why merge precedes the next brief.

## At session start: resume

A supervisor session can die under a running milestone; the units keep running, and a VM death ends everything at once. So the first act of a session is reading `.milestones/STATUS.md` (where every milestone stands: merged commit, gate evidence, unmet criteria, blockers, next action), then `run-milestones.sh status`, then `run-milestones.sh resume`. For every sandbox that is not running or finished, resume prints what happened and the exact finishing command; read the diagnosis against the log before issuing it with `--issue`, because a wrong finishing turn costs a model run and can double-apply fixes. `agent-sandbox status --reconcile` corrects run records whose containers are gone, so `list` and `status` stop reporting dead runs as running.

Done when every sandbox of this project is running, finished, or has its finishing turn issued and recorded in `chain.log`.

## Per milestone

Run these in order for every milestone. Each ends on a condition you can check.

### 1. Brief

Write `.milestones/notes-N.md` before launching. It carries only what a learning or the spec cannot: the branch to merge first, the files to extend rather than rewrite, a reading that moved, an owner action still open from the previous report. Everything durable goes elsewhere: a correction the supervisor made becomes a learning via `ce-compound mode:non-interactive` on the host, and a rule that every later milestone must honor becomes a pack rule. `ce-plan` reads both without being told.

Done when the notes hold nothing a learning, a pack rule or the spec already says, name every upstream change that touches this milestone's inputs, and state the dependency reading: which milestones this one needs merged first, and which it may run beside.

### 2. Launch

Before the first launch of a session, run `agent-sandbox doctor --quick`. A red host disk, memory log or vhdx row means no launch: admission would refuse it anyway, and a launch that gets past a stale check can take the VM down. Fix or escalate the row first.

From the project root:

```
~/.claude/skills/milestone-supervisor/run-milestones.sh N [--sandbox ID]
```

The driver launches one milestone per call as a transient systemd user unit, so the run outlives this session, and returns as soon as systemd accepts the unit, printing the unit name and its log path under `logs/milestones/`. It refuses two milestones in one call: the supervisor reviews each milestone on its own. Fresh sandbox when the milestone opens a new area; `--sandbox` with the previous id when it builds directly on that branch. A deploy milestone needs `--deploy`, and the owner's yes before that flag. The driver's header comment is its usage.

Resources come from `.milestones/config`: `MEMORY` and `CPUS` for every milestone, `MEMORY_N` and `CPUS_N` for one; likewise `MODEL` and `EFFORT`, with `MODEL_N` and `EFFORT_N`, for the model and effort the agent runs at. Set them from the milestone's shape: a milestone that plans a new subsystem, touches an external boundary or deploys gets the strongest model at high effort; a docs, measurement or follow-up milestone runs a tier down. Unset means the sandbox account's default, which is not necessarily the supervisor's own model, so set `MODEL` explicitly. The cap for everything the supervisor runs, in the sandbox or as its own subagents, is Opus: the supervisor session may run on a stronger model, and the agents and subagents must not inherit it. When dispatching subagents, pass the model on every call: `opus` for the strong tier (correctness, security, adversarial reviewers, validators, fix workers), `sonnet` for the rest. Write the reason next to the key. Size them to the job: a milestone that runs onnxruntime or a full test suite gets more memory than a documentation milestone, and the host's admission budget bounds the total. Admission inside `agent-sandbox` refuses a launch when the memory budget, the memory floor, the disk floor or the memory log's freshness says no, with exit code 3 and the reasons; the driver writes them to `chain.log`. A refusal is information, not a retry.

`run-milestones.sh config N` prints what milestone N resolves to (resources, model, lane, evaluation, gate setup and gate); read it before a launch you have not run before.

**Parallel milestones.** Two milestones may run at the same time when neither the spec nor their plans put them in sequence: neither consumes the other's output, they do not both write the same mutable dataset, and they do not rewrite the same modules. Give each its own `LANE_N`; milestones that share a dataset or modules share a lane. agent-sandbox holds one milestone lock per repository and lane, and the driver refuses a launch while `STATUS.md` shows another milestone in the same lane not yet pushed. Admission's memory budget bounds how many run; raise it for a parallel pair only when the host's memory log shows room, and remember the host gate in `integrate` is not counted by admission. Each milestone is still reviewed and integrated on its own, and the second `integrate` gates a tree that already holds the first.

Right after launching, read `run-milestones.sh status`. Done when it lists the new sandbox as running under its unit, and `logs/milestones/milestone-N.prompt` reads as a complete brief: spec section, standing rules with the CE sequence, notes, stop rule.

### 3. Watch

`run-milestones.sh status` is the watch. It derives each sandbox's state from Docker, the launching process and the systemd unit, never from what the run record says, and labels it: running, finished, vanished (container gone, no report committed), finished-unrecorded (report committed, gate not run), auth-expired (a 401 in this run's own log segment), orphaned (container up, launcher gone). Arm one watch that fires once on any state other than running, then exits; a watch that only knows the happy path is silent through a crash, and silence looks like running. Poll `status` once a minute at most.

A vanished run is usually not a crash: the agent finished one long assistant turn partway through the loop, which is a limit of headless runs. Turns end soonest when the agent dispatches subagents and waits on them, so the standing rules should tell the agent to implement inline and commit per unit; a finishing turn that repeats that instruction ends the pattern. `run-milestones.sh resume` reads the log's last output, prints the diagnosis and the finishing command per sandbox, and issues it with `--issue`. A finishing turn lists the remaining steps in order (suite green, commit the applied fixes, compound, the report as the last commit, handoff) and continues the sandbox's conversation; a relaunch would re-brief and lose it. Auth-expired needs the owner's re-login before the finishing turn.

While a sandbox runs, the supervisor stays light on the host: at most two of its own subagents at once, no `agent-sandbox build` (the guard refuses it while a container runs), no second milestone unless the parallel test above clears it, and no full `install.sh` of the skill stack (it reinstalls plugins the sandboxes mount; switch only the skill link). The memory log under `agent-sandbox memlog show` tells whether the run approached the floor; write that into the review.

Done when the watch is armed and you have moved on. The event, not a poll, brings you back.

### 4. Review

Read the report, then the CE artifacts, then the tree. In order:

1. Every exit criterion in the spec section has a measured number beside it in the report. A criterion with a sentence and no number is unmeasured.
2. The gate evidence line (`gate pass ... sha=<12> ...` in `chain.log`) names the sandbox branch's head. Rerun `--gate` when it names an older commit. The report's gate table quotes that line, not a run of the agent's own.
3. The CE trail exists: a plan file for this milestone, review findings applied or listed as residual in the report, at least one learning under `docs/solutions/` or a stated reason none qualified, a handoff artifact. A milestone with code and no plan or no review skipped the loop.
4. The "Owner actions needed" section, classified per step 5.
5. The decisions list against the spec section, reading for scope narrowed without saying so.
6. Test integrity: `integrate` refuses any added skip or xfail marker, removed assertion, deleted test file or changed snapshot whose path the report's "Test expectation changes" section does not list. Read the listed diffs yourself: the scan forces a change to be named, it cannot judge whether a rewritten assertion is weaker.
7. The data invariants from the pack, by counting: rows, distinct keys, sources. Then rebuild a handful of output rows from the data through the real code path and compare with the report's rows. A summary can say ten of ten while three rows are wrong underneath.
8. The run's memory, from `agent-sandbox memlog show --since <launch time>`: the container's peak, the host's minimum available, and the suggested `--memory` it prints (peak plus half, rounded up). Write the peak into the chain log and set the next milestone's `MEMORY_N` from it when the next job resembles this one; leave the default only when nothing has been measured. A request sized to the job leaves budget for a second container and keeps the host far from its floor. A minimum that approached the floor is a finding about the host, not the agent.

9. When `config N` shows `EVALUATE=1`: dispatch one independent evaluator on `opus` with [`EVALUATOR.md`](EVALUATOR.md), filled with the milestone section and `EVALUATE_TARGET`. Write its result to `.milestones/evaluation-N.md` and commit it. Reproduced findings become a finishing turn; criteria that need the owner's sign-in to a third-party account stay marked `owner action required` until the owner confirms them, and `integrate` refuses while any remain.

Write the Unmet criteria, Open blockers and Next action cells of the milestone's `STATUS.md` row.

Done when each item has a written verdict in the chain log, pass or the specific gap, and the STATUS row says the same.

### 5. Fix or escalate

Every owner action is one of three kinds. Sort each, then act.

- **Within the supervisor's tools**: a policy statement, a budget, a model subscription, a bucket, a seed file. Do it, record it in the milestone report, and give the sandbox a follow-up turn to re-take the readings it blocked:
  ```
  run-milestones.sh --sandbox ID --continue "The owner has done X. Re-take Y and update the report. Leave Z untouched."
  ```
  A follow-up turn continues the sandbox's last conversation, so it is a paragraph, not a re-brief.
- **Outward-facing or costly**: a deploy, a public endpoint, spend above the budget. Put the exact action and its cost in front of the owner and wait.
- **A scope change**: state the concern in two sentences, continue with everything else, and leave the cut to the owner.

Done when every owner action is either done and re-taken, or in front of the owner with a cost attached.

### 6. Coordinate

A milestone moves things outside itself in two directions. Check both before merging.

- **Backward**: a change here invalidates a reading, a fixture or a report in an earlier milestone. Re-take it: a follow-up turn in that sandbox if it still exists, otherwise the re-take on the host, and the earlier report updated either way. A report describing data that no longer exists is a defect.
- **Forward**: a decision here constrains later work. A one-milestone fact goes into the next `notes-N.md`. A rule every later milestone must honor becomes a pack rule with an `applies_when`. A lesson becomes a learning.

Done when no report in the repo describes a state that is no longer true, and every forward fact has landed in notes, pack or learning.

### 7. Ship

Nothing merges itself; the sandbox cannot push. From the project root:

```
~/.claude/skills/milestone-supervisor/run-milestones.sh integrate <sandbox-id>
```

It refuses on tracked changes, on the wrong branch, and when the branch is ahead of its upstream with anything but this sandbox's merge, fixes on top of it, or supervisor commits touching only `.milestones/` (the STATUS cells and `evaluation-N.md` you commit at review). It merges, runs the weakening scan and the evaluation check, gates a temporary worktree of the merge (seeded from `SEED_PATHS`, so `GATE_SETUP` never writes the files every sandbox copies), and pushes only on a pass, with the `STATUS.md` row committed on top. A failed gate keeps the merge local and logs the pre-merge sha: fix forward on the integration branch, or with a finishing turn merged again, and rerun `integrate`. When a later milestone builds on an earlier one that was still moving, it merges that branch first and again before its own exit measurements; write that into its notes. Run `ce-compound mode:non-interactive` on the host for anything the supervisor itself learned during review and coordination.

Done when `integrate` logged a `gate pass ... where=host` line and the push, and the milestone's STATUS row shows the merged commit.

## Invariants the pack must carry

These break silently across milestones, so they live as pack rules that `ce-plan` grounds in and `ce-code-review` enforces, in the project's own words, each with the `applies_when` that triggers it.

- **Seed, never rebuild, mutable data.** A pipeline that fills a table from sources overwrites refined values with first-pass ones. The agent gets a seeded copy of the current data and reads it; one sandbox at a time owns a mutable dataset, everyone else reads a pinned copy.
- **Replay fixtures are keyed on prompt text.** Changing anything that feeds a model prompt means a new recorded run. Decide re-record or revert at the moment of the change.
- **Derived keys move when derivation changes.** Remap every fixture in one commit and record the mapping as a learning.
- **Tunables live in config.** A bake-off winner is read from config, so the next milestone changes it without a code edit.

The standing rules carry the process rules instead: the CE sequence above, the report contract, and that there is nobody to ask, so every decision is the agent's to make and record.

## What the supervisor keeps

`.milestones/STATUS.md` is the committed summary: one row per milestone, what anyone opening the repo reads first. `logs/milestones/chain.log` is the running record: per milestone, the sandbox id, launch time, gate result, review verdicts, owner actions taken, follow-up turns given, what moved backward or forward. `docs/solutions/` carries the lessons, the pack carries the rules, the project's memory file carries where things live, the milestone reports carry the numbers. One meaning, one place.
