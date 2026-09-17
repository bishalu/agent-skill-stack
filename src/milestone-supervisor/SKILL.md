---
name: milestone-supervisor
description: Supervise a spec's numbered milestones being built unattended by sandboxed agents running the Compound Engineering loop. Set a project up for it, launch and watch a milestone, review its report and learnings, do or escalate owner actions, carry corrections backward and forward, merge and ship. Use when a spec has milestones with exit criteria and the owner is away from the keyboard.
---

# Milestone supervisor

Three roles. The **owner** is the human. The **supervisor** is this session: long-lived, on the host, holding the owner's tools and credentials. A **milestone agent** is one autonomous Claude Code run inside a disposable sandbox worktree, owning one milestone through the Compound Engineering loop. The agent plans, builds, reviews, commits and writes learnings. The supervisor verifies, fixes the environment, ships, and carries knowledge between milestones. Neither does the other's job, and neither approves anything: approvals are the owner's, typed at a terminal.

A project without a `.milestones/` folder is not set up: read [`SETUP.md`](SETUP.md) and do that first. Everything below assumes the driver, the folder, the CE config and the permission rules from there exist. The driver's header comment (`run-milestones.sh` next to this file) is the reference for every verb, key and refusal; this file says when to use them.

## How the agent uses Compound Engineering

The standing rules tell the agent to run CE's loop the way `lfg` runs it, minus the shipping tail the sandbox cannot perform:

1. `ce-plan` with the milestone section as the request. Pipeline runs always take the Durable contract: a plan file under the CE artifact root, grounded in `docs/solutions/` learnings and any declared Compound Pack, reviewed by `ce-doc-review`.
2. `ce-work mode:return-to-caller <plan path>`: implementation and local verification, unit-scoped commits.
3. `ce-simplify-code` on the branch diff.
4. `ce-code-review mode:agent apply:local plan:<plan path>`: findings applied and committed; residual findings written into the report.
5. `ce-compound mode:non-interactive` for each non-obvious lesson the milestone produced, so the next `ce-plan` reads it.
6. `ce-commit` for what remains, the report last. `ce-handoff create` at the very end, so a follow-up turn or a fresh sandbox can resume.

The supervisor does the shipping tail through `run-milestones.sh integrate`: merge, scan, gate, acceptance, delivery guard, push. Learnings ride forward only through that merge, which is why merge precedes the next brief.

## At session start: resume

A supervisor session can die under a running milestone; the units keep running, and a VM death ends everything at once. The first acts of a session, in order:

1. Read `.milestones/STATUS.md`: where every milestone stands (merged commit, gate evidence, unmet criteria, blockers, next action). A Next action starting `ESCALATED:` is an exhausted budget waiting on the owner (see "Budgets and escalation").
2. `run-milestones.sh status`: each sandbox's state, derived from Docker, the launcher and the systemd unit.
3. `run-milestones.sh resume`: for every sandbox that is not running or finished, what happened and the exact finishing command. Read the diagnosis against the log before issuing it with `--issue`, because a wrong finishing turn costs a model run and can double-apply fixes. `agent-sandbox status --reconcile` corrects run records whose containers are gone.
4. `run-milestones.sh audit`: one line per STATUS row with a Merged commit, `verified`, `stale`, `unverified` or `pre-evidence`. It writes nothing. A `stale` or `unverified` row is a finding for the owner: that commit reached the remote without a delivery record that still holds.

Done when every sandbox of this project is running, finished, or has its finishing turn issued and recorded in `chain.log`, and every audit line that is not `verified` or `pre-evidence` is written into `chain.log` with what you will do about it.

## Per milestone

Run these in order for every milestone. Each ends on a condition you can check.

### 1. Brief

Write `.milestones/notes-N.md` before launching. It carries only what a learning or the spec cannot: the branch to merge first, the files to extend rather than rewrite, a reading that moved, an owner action still open from the previous report. Everything durable goes elsewhere: a correction the supervisor made becomes a learning via `ce-compound mode:non-interactive` on the host, and a rule that every later milestone must honor becomes a pack rule. `ce-plan` reads both without being told. Commit the notes on the integration branch; a supervisor commit that changes only `.milestones/` is allowed ahead of the upstream.

Done when the notes hold nothing a learning, a pack rule or the spec already says, name every upstream change that touches this milestone's inputs, and state the dependency reading: which milestones this one needs merged first, and which it may run beside.

### 2. Launch

Before the first launch of a session, run `agent-sandbox doctor --quick`. A red host disk, memory log or vhdx row means no launch: admission would refuse it anyway, and a launch that gets past a stale check can take the VM down. Fix or escalate the row first.

From the project root:

```
~/.claude/skills/milestone-supervisor/run-milestones.sh N [--sandbox ID]
```

A launch writes `.milestones/acceptance/N.json` from the milestone's `Exit:` paragraph when it is absent, and refuses (exit 2, nothing launched) when the record and that paragraph disagree or when no criteria extract: the record is the single copy of the exit criteria. The brief carries them as `N.c<i>: <text>` lines with the rule to cite the ids in the plan and report rather than restate them, so the report's measurements line up with the acceptance record without a second copy to drift.

The driver launches one milestone per call as a transient systemd user unit, so the run outlives this session, and returns as soon as systemd accepts the unit, printing the unit name and its log path under `logs/milestones/`. It refuses two milestones in one call: the supervisor reviews each milestone on its own. Fresh sandbox when the milestone opens a new area; `--sandbox` with the previous id when it builds directly on that branch. A deploy milestone needs `--deploy`, and the owner's yes before that flag. A launch of a milestone whose attempt budget is spent refuses (see "Budgets and escalation").

Resources come from `.milestones/config`: `MEMORY` and `CPUS` for every milestone, `MEMORY_N` and `CPUS_N` for one; likewise `MODEL` and `EFFORT`, with `MODEL_N` and `EFFORT_N`, for the model and effort the agent runs at. Set them from the milestone's shape: a milestone that plans a new subsystem, touches an external boundary or deploys gets the strongest model at high effort; a docs, measurement or follow-up milestone runs a tier down. Unset means the sandbox account's default, which is not necessarily the supervisor's own model, so set `MODEL` explicitly. The cap for everything the supervisor runs, in the sandbox or as its own subagents, is Opus: the supervisor session may run on a stronger model, and the agents and subagents must not inherit it. When dispatching subagents, pass the model on every call: `opus` for the strong tier (correctness, security, adversarial reviewers, validators, fix workers), `sonnet` for the rest. Write the reason next to the key. Size them to the job: a milestone that runs onnxruntime or a full test suite gets more memory than a documentation milestone, and the host's admission budget bounds the total. Admission inside `agent-sandbox` refuses a launch when the memory budget, the memory floor, the disk floor or the memory log's freshness says no, with exit code 3 and the reasons; the driver writes them to `chain.log`. A refusal is information, not a retry.

Every edit to `.milestones/config` or `config.local` changes the gate definition hash, so the owner has to approve the new definition before the next delivery (see "Owner approvals"). Batch config changes and ask once.

`run-milestones.sh config N` prints what milestone N resolves to (resources, model, lane, evaluation, gate setup, each gate step, where integrate gates, budgets); read it before a launch you have not run before.

**Choosing the shape.** Independent milestones run in lanes; tightly coupled work runs in one sandbox with an evaluator.

- Two milestones may run at the same time when neither the spec nor their plans put them in sequence: neither consumes the other's output, they do not both write the same mutable dataset, and they do not rewrite the same modules. Give each its own `LANE_N`; milestones that share a dataset or modules share a lane. agent-sandbox holds one milestone lock per repository and lane, and the driver refuses a launch while `STATUS.md` shows another milestone in the same lane not yet pushed. Admission's memory budget bounds how many run; raise it for a parallel pair only when the host's memory log shows room, and remember a host-route gate in `integrate` is not counted by admission. Each milestone is still reviewed and integrated on its own, and the second `integrate` gates a tree that already holds the first.
- Work whose parts only make sense together (a contract and its only consumer, a schema and the screen that reads it) stays one milestone in one sandbox with `EVALUATE_N=1`. Splitting it into lanes buys parallelism and pays for it in merges and re-measurements.

Right after launching, read `run-milestones.sh status`. Done when it lists the new sandbox as running under its unit, and `logs/milestones/milestone-N.prompt` reads as a complete brief: spec section, standing rules with the CE sequence, notes, stop rule.

### 3. Watch

`run-milestones.sh status` is the watch. It derives each sandbox's state from Docker, the launching process and the systemd unit, never from what the run record says, and labels it: running, waiting (admission is holding the launch until the budget has room), finished, vanished (container gone, no report committed), finished-unrecorded (the run ended without a committed report, or the report is committed but the gate never ran; `resume` prints the finishing command for either), auth-expired (a 401 in this run's own log segment), orphaned (container up, launcher gone). Arm one watch that fires once on any state other than running or waiting, then exits; a watch that only knows the happy path is silent through a crash, and silence looks like running. Poll `status` once a minute at most.

A vanished run is usually not a crash: the agent finished one long assistant turn partway through the loop, which is a limit of headless runs. Turns end soonest when the agent dispatches subagents and waits on them, so the standing rules tell the agent to implement inline and commit per unit; a finishing turn that repeats that instruction ends the pattern. `run-milestones.sh resume` reads the log's last output, prints the diagnosis and the finishing command per sandbox, and issues it with `--issue`. A finishing turn lists the remaining steps in order (suite green, commit the applied fixes, compound, the report as the last commit, handoff) and continues the sandbox's conversation; a relaunch would re-brief and lose it. Every `--continue` counts against the milestone's finishing-turn budget. Auth-expired needs the owner's re-login before the finishing turn.

While a sandbox runs, the supervisor stays light on the host: at most two of its own subagents at once, no `agent-sandbox build` (the guard refuses it while a container runs), no second milestone unless the lane test above clears it, and no full `install.sh` of the skill stack (it reinstalls plugins the sandboxes mount; switch only the skill link). The memory log under `agent-sandbox memlog show` tells whether the run approached the floor; write that into the review.

Done when the watch is armed and you have moved on. The event, not a poll, brings you back.

### 4. Review

Read the report, then the CE artifacts, then the evidence, then the tree. In order:

1. Every exit criterion in the spec section has a measured number beside it in the report. A criterion with a sentence and no number is unmeasured.
2. The gate evidence line (`gate pass ... sha=<12> tree=<12> def=<12> ... evidence=<bundle>` in `chain.log`) names the sandbox branch's head. Rerun `--gate` when it names an older commit. The report's gate table quotes that line, not a run of the agent's own.
3. The sealed evidence bundle behind that line, not only the line: `logs/milestones/evidence/<bundle>/evidence.json` (its sha256 is the `seal` line in `chain.log`) and the step logs under `steps/`. Check that each step ran the tests the report claims, that `dirty` is false, and which steps were `not run`. A gate with no `integration` step, on a milestone whose contract touches a store, a service or the browser, is a finding: its checks never exercised the thing the milestone promises.
4. The CE trail exists: a plan file for this milestone, review findings applied or listed as residual in the report, at least one learning under `docs/solutions/` or a stated reason none qualified, a handoff artifact. A milestone with code and no plan or no review skipped the loop.
5. The "Owner actions needed" section, classified per step 5.
6. The decisions list against the spec section, reading for scope narrowed without saying so. Log a `spec-clarification` finding per report decision that departs from the spec's wording (`kind=reinterpretation`), per appendix that contradicts another (`kind=conflict`), and per appendix contract no exit criterion covers (`kind=uncovered-appendix`). These are spec losses, not defects a stage caught: the report counts them by kind in their own section and keeps them out of the per-stage catch statistics.
7. Test integrity. `integrate` refuses every weakening-scan hit (an added skip or xfail marker, a removed assertion, a removed test definition, a deleted test file, a changed snapshot, a gate-config change) that has no owner approval of its current blob. A test file that only gains tests and assertions is no hit, so every hit is a specific signal worth reading. The report's "Test expectation changes" section is information for the owner and approves nothing. Read the listed diffs yourself, because the scan forces a change to be approved and cannot judge whether a rewritten assertion is weaker, and put each hit in front of the owner with your reading of it.
8. The data invariants from the pack, by counting: rows, distinct keys, sources. Then rebuild a handful of output rows from the data through the real code path and compare with the report's rows. A summary can say ten of ten while three rows are wrong underneath.
9. The run's memory, from `agent-sandbox memlog show --since <launch time>`: the container's peak, the host's minimum available, and the suggested `--memory` it prints (peak plus half, rounded up). Write the peak into the chain log and set the next milestone's `MEMORY_N` from it when the next job resembles this one. A minimum that approached the floor is a finding about the host, not the agent.
10. When `config N` shows `EVALUATE=1`: dispatch one independent evaluator on `opus` with [`EVALUATOR.md`](EVALUATOR.md), filling its three slots: the milestone section verbatim, `EVALUATE_TARGET` from `config N`, and the checkout path, which is either a fresh sandbox of the milestone branch or the host checkout with that branch checked out; state which in the chain log. Write its result to `.milestones/evaluation-N.md` and commit it before `integrate`: it is outside the metadata allowlist, so committing it after the gate makes the gate's bundle stale. Reproduced findings become a finishing turn; criteria that need the owner's sign-in to a third-party account stay marked `owner action required` until the owner confirms them, and `integrate` refuses while any remain.
11. Acceptance and planted defects, below.

Write the Unmet criteria, Open blockers and Next action cells of the milestone's `STATUS.md` row.

Done when each item has a written verdict in the chain log, pass or the specific gap, every finding is logged as an event (see "Logging"), and the STATUS row says the same.

#### Acceptance

`integrate` accepts a milestone only when every exit criterion has sealed evidence or an owner waiver. Start the record at review:

```
run-milestones.sh accept N --init
```

It splits the "Exit:" paragraph of milestone N's section into `.milestones/acceptance/N.json` with ids `N.c1`, `N.c2` and so on, and no evidence. Each criterion is then filled with one of two kinds of evidence:

- A step of a sealed integrate bundle, and the test ids in that step's log that exercise the criterion: `accept N --criterion N.c2 --evidence bundle:<bundle>#<step>:<test id>[,<test id>...]`. Only a bundle `integrate` produced qualifies (clean, milestone N's, the step passed, its log matching its seal and naming every test id as a whole token). Cite the tests that would fail if the promise broke, not every test in the step.
- A caught mutation: `accept N --criterion N.c3 --evidence mutation:<line of mutations/N.jsonl, or its patched seal>`. Only a `caught` verdict whose patch cites this criterion qualifies.

An evaluator's `met` line is context only: attach it with `--context evaluator:<text>` if it helps the owner, never as evidence. A criterion no check can reach needs the owner's `criterion-waiver` approval.

The integrate bundle exists only once `integrate` has gated, so the order is: mutation evidence at review; then `integrate`, which gates and, with criteria still open, refuses with `refused: acceptance incomplete`, keeps the merge local and prints the sealed bundle and the exact `accept` and `approve` commands; then `accept` against that bundle; then `integrate <id> --evidence <bundle>`, or `integrate` again. Evidence counts only on the gated tree and the current gate definition hash, so a code change or a definition change after it means gating and accepting again.

#### Planted defects

Before `integrate`, find out whether the gate would notice the milestone's riskiest promises breaking. Write one to three defect patches, or take them from the evaluator's "Defect patches" section. Each patch:

- aims at what would hurt most if silently broken: authorization, persistence, the interaction the spec names;
- is written from the spec section, never from the milestone's tests or report, reading the code only to find where the promise is kept;
- starts with a `# criterion: <id or text>` line before its first diff, naming the exit criterion it breaks, or `# criterion: appendix <path> §<section>` for a contract only the appendices state, such as a tenancy guard. `mutate` checks that the target tree holds that file and a heading with that section, records `criterion_kind=appendix`, and `accept` refuses such a record as evidence for an exit criterion: it proves the appendix contract, and may be cited as context;
- touches no gate definition file, no file a gate step or `GATE_SETUP` or `GATE_ENV` names, nothing under `.milestones/` and nothing outside the repository (`mutate` refuses those).

Save each as `.milestones/mutations/N-<slug>.patch` and run:

```
run-milestones.sh mutate N .milestones/mutations/N-<slug>.patch [--steps name,name]
```

It gates a temporary merge of the sandbox branch into the integration branch head (the baseline, which must pass), applies the patch, gates again running every step, and appends the verdict to `.milestones/mutations/N.jsonl`. `caught` (an integration or replay step failed) is acceptance evidence for the cited criterion. `missed`, or `caught-static` (only lint or types noticed), becomes a finishing turn: the agent adds the test that fails on that defect. `inconclusive` means the step that would catch it is `sandbox-only` and did not run on the host; re-run it where that step runs with `mutate N <patch> --where sandbox`, which overrides `INTEGRATE_GATE_WHERE` for that run alone. Do not edit the config for it: that changes the gate definition hash and costs the owner a fresh `gate-definition` approval.

### 5. Fix or escalate

Every owner action is one of three kinds. Sort each, then act.

- **Within the supervisor's tools**: a policy statement, a spend limit in a cloud account, a model subscription, a bucket, a seed file. Do it, record it in the milestone report, log it as an intervention, and give the sandbox a follow-up turn to re-take the readings it blocked:
  ```
  run-milestones.sh --sandbox ID --continue "The owner has done X. Re-take Y and update the report. Leave Z untouched."
  ```
  A follow-up turn continues the sandbox's last conversation, so it is a paragraph, not a re-brief. Without `N`, `--continue` takes the milestone from the sandbox's milestone tag.
- **Outward-facing or costly**: a deploy, a public endpoint, spend above the budget. Put the exact action and its cost in front of the owner and wait.
- **A scope change**: state the concern in two sentences, continue with everything else, and leave the cut to the owner.

Owner approvals (below) are never within the supervisor's tools: put the exact `approve` command in front of the owner.

Done when every owner action is either done and re-taken, or in front of the owner with a cost attached.

### 6. Coordinate

A milestone moves things outside itself in two directions. Check both before merging.

- **Backward**: a change here invalidates a reading, a fixture or a report in an earlier milestone. Re-take it: a follow-up turn in that sandbox if it still exists, otherwise the re-take on the host, and the earlier report updated either way. A report describing data that no longer exists is a defect.
- **Forward**: a decision here constrains later work. A one-milestone fact goes into the next `notes-N.md`. A rule every later milestone must honor becomes a pack rule with an `applies_when`. A lesson becomes a learning.

Done when no report in the repo describes a state that is no longer true, and every forward fact has landed in notes, pack or learning.

### 7. Ship

Nothing merges itself; the sandbox cannot push. From the project root, on the integration branch:

```
~/.claude/skills/milestone-supervisor/run-milestones.sh integrate <sandbox-id> [N]
~/.claude/skills/milestone-supervisor/run-milestones.sh integrate <sandbox-id> [N] --evidence logs/milestones/evidence/<bundle>
```

The two forms run the same checks and the same delivery guard; `--evidence` only replaces the gate run with a sealed bundle of the existing merge. In order, `integrate`:

1. refuses when the milestone's attempt budget is spent;
2. refuses tracked changes outside the metadata allowlist (`STATUS.md`, `events.jsonl`, `grades.jsonl`, `acceptance/`, `approvals/` and `mutations/` under `.milestones/`), the wrong branch, a branch behind its upstream, or one ahead of it with anything but this sandbox's merge, fixes on top of it, or supervisor commits touching only `.milestones/`;
3. refuses a sandbox branch that touches `.milestones/`, adds or changes a path the host's `.gitignore` ignores, or has no milestone report;
4. merges (with `--evidence`, the merge must already exist). A conflict only in paths `REGENERATE_ON_CONFLICT` names, with `REGENERATE_COMMAND` set, is resolved mechanically instead of refusing: after the candidate checks and the weakening and gate-config scans pass, `integrate` takes the integration branch's side of those paths, runs the command in a temporary worktree of the merge seeded from `SEED_PATHS` with its own `TMPDIR` (never in the owner's checkout), copies only those paths back, completes the merge and records `signal=regenerated` with the paths on that attempt's integrate event. A failing command aborts the merge as a `conflict` failure, one that cannot start as `environment`; a conflict in any other path refuses as before;
5. runs the weakening scan and refuses any hit without an owner approval of its kind, path and current blob; a scan that errors refuses;
6. with `EVALUATE_N=1`, refuses without a committed `evaluation-N.md` free of `owner action required`;
7. gates the merge where `INTEGRATE_GATE_WHERE` says: `host` in a temporary worktree seeded from `SEED_PATHS`, or `sandbox` in a fresh sandbox of the merge commit, removed after;
8. checks acceptance, and refuses with the bundle and the commands when a criterion is open;
9. runs the delivery guard, commits the STATUS row with `events.jsonl` and `acceptance/N.json`, runs the guard again on that commit, logs a `delivery milestone=N push=<sha> ...` line and pushes exactly that sha.

`SANDBOX_GATE_STEPS` keeps the gate after a milestone's turn to a named subset; `--gate` always runs every step, so the full sandbox gate stays one command away, and a subset bundle never delivers because its unselected steps are recorded `not run: not selected`.

Delivery evidence is one thing only: a sealed bundle directly under `logs/milestones/evidence/` that `integrate` produced for milestone N (`where=host-integrate` or `sandbox-integration`), with verdict pass, `dirty=false`, every step passed and none `not run`, each step log matching its sealed hash, and a gate definition hash equal both to the hash computed now and to the newest owner-approved one. The pushed tree must equal the bundle's tree or differ from it only in metadata allowlist paths. Bundles from a sandbox `--gate` or from `mutate` never deliver, and neither does a host run that skipped a `sandbox-only` step: a project with such steps gates with `INTEGRATE_GATE_WHERE=sandbox`.

A refusal or failure after the merge pushes nothing and keeps the merge local; the log names the pre-merge sha and the `git reset --hard` that drops it, or on a re-run the unpushed commits. Fix forward on the integration branch, or with a finishing turn merged again, and rerun `integrate`. When a later milestone builds on an earlier one that was still moving, it merges that branch first and again before its own exit measurements; write that into its notes. Run `ce-compound mode:non-interactive` on the host for anything the supervisor itself learned during review and coordination.

After the push, record the grade:

```
uv run --with mlflow ~/.claude/skills/milestone-supervisor/grade.py record N
```

When the owner is next present, ask for their minutes and anything the milestone missed, and amend the same line with `--owner-minutes`, `--missed` and `--regression`.

Done when `chain.log` holds the `delivery milestone=N` line and the push, the milestone's STATUS row shows the merged commit, `run-milestones.sh audit` reads `verified` for it, and `grades.jsonl` has its line.

## Owner approvals

Some things the owner decides. Each is given with `run-milestones.sh approve`, and `APPROVAL_MODE` in `.milestones/config` says who may give it:

- `approve N criterion-waiver N.c<i>...`: an exit criterion accepted without evidence.
- `approve N weakening <hit kind> <path>...`: a weakening-scan hit (`skip-marker`, `removed-assert`, `removed-test`, `deleted-test`, `snapshot`), approved for the path's current blob on the candidate branch, so a later change to the file is unapproved again.
- `approve N gate-config <path>...`: a change to a file that defines the gate (`GATE_DEFINITION_GLOBS`, or a file a step, `GATE_SETUP` or `GATE_ENV` names).
- `approve N gate-definition`: the current gate definition hash, over the step list, `GATE_SETUP`, `GATE_ENV`, `.milestones/config`, `config.local`, the driver and the `MAX_*` budget keys. Needed after any change to one of those, and once after installing a new driver: the first delivery after an install refuses until the owner approves the new definition.
- `approve N budget <failed_gates|finishing_turns|wall_hours>...`: one more attempt once that budget is exhausted.

`approve` appends to `.milestones/approvals/N.md` and commits that file alone. Readers use the committed file and ignore any line not in the exact format. Every entry records who granted it, and every entry written emits an `approval` event carrying the same `granted_by`, so `grade.py report` shows how much of a run went through unreviewed.

**`APPROVAL_MODE=supervisor` (the default) runs the whole spec unattended.** The supervisor records the approvals itself: each entry is written `confirm="-" by=supervisor reason="..."`, the reason names the integrate or delivery that needed it, and the log says so at the moment it happens. It covers weakening hits, gate-config changes, the gate definition and an exhausted budget. Anything the supervisor approves for itself is still in the ledger and still in `approvals/N.md` for the owner to read afterwards.

**`APPROVAL_MODE=owner` asks the owner every time.** `approve` then refuses unless stdin is a terminal, prints the lines it will write, and writes them only when the owner types `approve N <kind>` exactly. The supervisor's tool shell has no terminal, so it cannot give an approval: when `integrate` refuses for want of one, put the printed `approve` command, the diff or hash it covers and your reading of it in front of the owner, and wait.

**A criterion waiver is the owner's in both modes.** It says an exit criterion was met with no evidence, which is the one approval that cannot be checked afterwards, so `approve --as supervisor` refuses it. An unattended run that reaches an unevidenced criterion stops and escalates rather than waiving it. The unattended mode removes the owner from the loop; it does not remove the evidence requirement.

## Budgets and escalation

Each milestone has three attempt budgets: failed gates (`MAX_FAILED_GATES`, default 3), finishing turns (`MAX_FINISHING_TURNS`, default 3) and wall hours since its first launch (`MAX_HOURS`, default 24), each with a `_N` override. Counts are the larger of the `events.jsonl` and `chain.log` counts, so neither ledger alone resets them. When one is spent, a launch, `--continue`, `--gate`, `integrate` or `mutate` of that milestone refuses with exit 2, sets its STATUS Next action to `ESCALATED: ...` (left uncommitted), and keeps the sandboxes and bundles.

An exhausted budget is a stop, not a retry. Write into `chain.log` what the attempts were and why each failed, then put the milestone in front of the owner with a recommendation: one more attempt (`approve N budget <name>`), a spec change, or a cut. Under `APPROVAL_MODE=supervisor` the supervisor grants that one more attempt itself and logs it with `granted_by=supervisor`, so an exhaustion is visible in the ledger rather than being a stop; a budget that keeps needing extensions is the signal to read, and the escalation line is still written. A budget key edited in config changes the gate definition, so raising a limit also needs `approve N gate-definition`.

## Logging

The events ledger, `.milestones/events.jsonl`, is how the process is judged later; write to it as things happen, not from memory at the end. The driver writes integrate, push, budget, mutation, finishing-turn and gate-failure events itself. The supervisor writes two kinds:

```
uv run --with mlflow ~/.claude/skills/milestone-supervisor/grade.py event finding --change milestone:N \
  stage=<stage> title='<one line>' confirmation=<executable|reviewer|owner> [reviewer=<name>] [step=<step>] [bundle=<bundle>]
uv run --with mlflow ~/.claude/skills/milestone-supervisor/grade.py event intervention --change milestone:N \
  actor=<supervisor|owner|agent> intervention_class=<environment|context|reconciliation|spec> minutes=<M> detail='<what>'
```

- A `spec-clarification` finding also takes `kind=<conflict|reinterpretation|uncovered-appendix>`; no other stage takes a kind.
- Plan doc-review is logged from its commit, not by hand: `grade.py plan-review N --commit <sha> [--minutes M] [--tokens T]` writes one `plan-doc-review` finding per changed section of the plan file that commit modifies, plus a stage event carrying the minutes and tokens. It refuses a commit that adds the plan rather than modifying it, which is why the standing rules have the plan committed before `ce-doc-review` and its corrections in their own commit. The report shows plan review as corrections applied against the escapes attributed to it, and never lists it as a drop candidate.
- A finding names the stage that raised it (`spec-clarification`, `plan-doc-review`, `code-review`, `supervisor-review`, `evaluator`, `gate`, `mutate`, `integrate`, `owner`) and how it was confirmed: `executable` only when a failing check exposed it, `reviewer` when one or more agents asserted it, `owner` when the owner found it. Agreement between reviewers never makes a finding `executable`. When a check later confirms it, log the same title again with `confirmation=executable`.
- An intervention is anything the supervisor or owner did so the run could continue: `environment` (a tool installed, a seed fixed), `context` (information the agent lacked), `reconciliation` (ledgers, branches or reports brought back into agreement), `spec` (the spec clarified or changed). Minutes are required unless the actor is the owner.

Every 10 changes, run `uv run --with mlflow ~/.claude/skills/milestone-supervisor/grade.py report --last 10` and act on it: narrow or drop a stage with no confirmed catch in the window, and fix the cause of the top intervention class. Gate failures the driver wrote are listed apart from findings. Write what you changed, or why you changed nothing, into `chain.log`.

## Limits of these controls

The controls stop a headless session and a candidate branch from approving or delivering their own work. They do not stop everything:

- An approvals line committed by hand in the exact format is accepted. The terminal check stops a headless session; it does not stop a process running as the owner's user with a terminal.
- A host-route gate (`INTEGRATE_GATE_WHERE=host`, and `mutate` on that route) runs candidate code as the owner's user, with that user's files and credentials in reach. The sandbox route runs it in a container.
- `logs/milestones/chain.log` and the evidence bundles are ordinary files writable by that user. A seal catches a bundle changed after the fact, not a process that rewrites both the bundle and its seal line.

## Invariants the pack must carry

These break silently across milestones, so they live as pack rules that `ce-plan` grounds in and `ce-code-review` enforces, in the project's own words, each with the `applies_when` that triggers it.

- **Seed, never rebuild, mutable data.** A pipeline that fills a table from sources overwrites refined values with first-pass ones. The agent gets a seeded copy of the current data and reads it; one sandbox at a time owns a mutable dataset, everyone else reads a pinned copy.
- **Replay fixtures are keyed on prompt text.** Changing anything that feeds a model prompt means a new recorded run. Decide re-record or revert at the moment of the change.
- **Derived keys move when derivation changes.** Remap every fixture in one commit and record the mapping as a learning.
- **Tunables live in config.** A bake-off winner is read from config, so the next milestone changes it without a code edit.

The standing rules carry the process rules instead: the CE sequence above, the report contract, and that there is nobody to ask, so every decision is the agent's to make and record.

## What the supervisor keeps

`.milestones/STATUS.md` is the committed summary: one row per milestone, what anyone opening the repo reads first. Beside it, `acceptance/N.json` holds each criterion's evidence, `approvals/N.md` the owner's approvals, `mutations/N.jsonl` the planted-defect verdicts, `events.jsonl` the typed events and `grades.jsonl` one grade line per change. `logs/milestones/chain.log` is the running record: per milestone, the sandbox id, launch time, gate lines and seals, review verdicts, owner actions taken, follow-up turns given, delivery lines, what moved backward or forward; the sealed bundles sit beside it under `evidence/`. `docs/solutions/` carries the lessons, the pack carries the rules, the project's memory file carries where things live, the milestone reports carry the numbers. One meaning, one place.
