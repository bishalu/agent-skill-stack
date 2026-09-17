# Independent milestone evaluation

The supervisor dispatches this on `opus` when `run-milestones.sh config N` shows `EVALUATE=1`, filling the three slots: the milestone section verbatim, `EVALUATE_TARGET` from `config N`, and the checkout path (a fresh sandbox of the milestone branch, or the host checkout with that branch checked out). The evaluator has not seen the milestone agent's transcript and does not trust its report.

What comes back is reviewer-grade: a `met` line is context for the owner, never acceptance evidence. The defect patches it returns become evidence only through `run-milestones.sh mutate`, when the gate catches them.

```
You evaluate one milestone of a project independently. The milestone agent says its exit
criteria are met; your job is to find out whether a user following them would agree, and
whether its checks would notice if the most important promises broke.

Milestone section, verbatim:
{milestone_section}

Target to drive: {evaluate_target}
Repository checkout: {checkout_path}

1. Start or open the target. A command: run it from the checkout and wait for the app to
   answer. A URL: open it. If the target will not start, that is your only finding; stop.
2. For each exit criterion, drive it the way a user would, with Playwright against the
   running app, and read the API or files it names. Do not read the milestone report
   until every criterion has your own observation.
3. A criterion that needs the owner's sign-in to a third-party account (an OAuth consent,
   a streaming service's authorization) is not yours to pass. Record it as
   `owner action required: <criterion> — <what the owner must do and what to look for>`.
4. Reproduce every failure a second time from a fresh page before reporting it. Report
   only what reproduced.
5. Read-only: change no code, commit nothing, spend nothing beyond what the criteria's
   recorded or local paths use. The defect patches below are text you return, never
   applied.
6. Write one to three defect patches. Choose what to break from the milestone section
   alone, never from the milestone's tests or report: the riskiest promises, such as
   authorization, persistence, or the interaction the section names. Read the code only
   to find where that promise is kept, then write the smallest change that silently
   breaks it while the app still starts. Each patch:
   - starts with the line `# criterion: <exit criterion text or its id>   (or: # criterion: appendix <path> §<section> for a contract only an appendix states)` before the
     first diff line;
   - is a unified diff that applies with `git apply` at the repository root;
   - touches only application code: no gate or test-runner configuration (justfile,
     Makefile, package.json, pyproject.toml, runner configs, CI files), no script or file
     a gate command names, nothing under .milestones/, and no path outside the repository.

Return markdown for .milestones/evaluation-N.md:

## Criteria
One line per exit criterion: `met`, `not met`, or `owner action required`, with the
observation (a number, a status code, a screenshot path).

## Findings
For each reproduced failure: steps, expected, observed, and where it likely lives.
Write "None reproduced." when there are none.

## Defect patches
For each patch: a file name `N-<slug>.patch`, one sentence on the promise it breaks and
which check should fail, and the patch in a fenced block.
```

The supervisor saves each patch as `.milestones/mutations/N-<slug>.patch` and runs `run-milestones.sh mutate N <patch>` before `integrate` (SKILL.md, "Planted defects"). The patch text in `evaluation-N.md` stays as the record of what was asked.
