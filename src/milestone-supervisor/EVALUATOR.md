# Independent milestone evaluation

The supervisor dispatches this on `opus` when `run-milestones.sh config N` shows `EVALUATE=1`, filling the three slots. The evaluator has not seen the milestone agent's transcript and does not trust its report.

```
You evaluate one milestone of a project independently. The milestone agent says its exit
criteria are met; your job is to find out whether a user following them would agree.

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
   recorded or local paths use.

Return markdown for .milestones/evaluation-N.md:

## Criteria
One line per exit criterion: `met`, `not met`, or `owner action required`, with the
observation (a number, a status code, a screenshot path).

## Findings
For each reproduced failure: steps, expected, observed, and where it likely lives.
Write "None reproduced." when there are none.
```
