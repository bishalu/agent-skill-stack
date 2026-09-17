Run this milestone through the Compound Engineering loop, hands-off. There is nobody to ask: make every decision yourself and record it in the report. Resolve each skill name against the available-skills list (some hosts namespace them, as compound-engineering:ce-plan).

1. ce-plan with the milestone section below as the request. Take the Durable contract: write the plan file, grounded in docs/solutions/ and the milestones pack, and run ce-doc-review on it.
2. ce-work mode:return-to-caller <plan path>. Implementation and local verification, unit-scoped commits.
3. ce-simplify-code on the branch diff.
4. ce-code-review mode:agent apply:local plan:<plan path>. Apply and commit the findings; list residuals in the report.
5. ce-compound mode:non-interactive for every non-obvious lesson this milestone produced, so the next milestone's plan reads it.
6. ce-commit for what remains. The report is the last commit. Then ce-handoff create, and copy the handoff file into docs/handoffs/milestone-N.md and commit it: the container's /tmp does not survive the run.

## The report

The report goes to REPORT_DIR/milestone-N.md and holds:

- the decisions taken, each with its reason;
- every exit criterion from the milestone section with its measured number, or the measurement of why it is not met;
- the residual review findings;
- a gate table that quotes the driver's evidence line for the report's own commit (`gate pass exit=0 milestone=N sha=<12> ...`, from `logs/milestones/chain.log` or the gate log), not a run of your own. Quote the line as it stands, including the bundle it names;
- a section headed "Owner actions needed" listing each denied or out-of-scope action as the exact command or API call. A denied call goes there and the work continues.

Nothing in the report approves anything. It is read by the supervisor and the owner; the checks that decide whether this milestone ships read the driver's own evidence and the owner's approvals, never your text.

The gate rebuilds derived state first (`GATE_SETUP`) from committed recordings, because every sandbox start re-copies the host's gitignored inputs: a value your run wrote into one of them is not a result the gate will see. Commit what a result depends on.

## Tests are evidence

Never skip, xfail, loosen an assertion, delete a test or re-baseline a snapshot to make a check pass. A test that fails is telling you something: fix the code, or measure and report why the expectation was wrong.

When a test's expectation genuinely changes, the report has a section headed "Test expectation changes" that lists each changed test file by path with the reason. That list is information for the owner, who decides. It does not approve the change: the supervisor's integrate refuses every added skip marker, removed assertion, deleted or modified test file, changed snapshot and gate-config change until the owner has approved it at a terminal, whether or not the report lists it.

Extend earlier milestones' modules; do not rewrite them. Keep the full suite and the linters green at every commit. The spec is scope authority: a scope narrowed without saying so is a defect.

## Headless turns end early

You run as one headless turn, and a turn can end while the orchestrating agent waits on a subagent it dispatched, leaving half-applied edits uncommitted. Work inline: do each unit yourself rather than dispatching subagents for implementation, commit each unit as soon as its tests pass, and never leave the tree dirty at a point where you might stop. A follow-up turn can resume the conversation, but every early end costs a re-brief and a gate run.
