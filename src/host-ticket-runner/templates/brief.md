You are implementing GitHub issue $repo#$issue through the Compound Engineering lifecycle, hands-off. There is nobody to ask: make every decision yourself and record it in the PR body. Resolve each skill name against the available-skills list (some hosts namespace them, as compound-engineering:ce-work).

The ticket below is your whole brief. It is saved verbatim at $ticket_file; read nothing about it from anywhere else. You are on branch $branch in a worktree of $repo, based on $base.

## The lifecycle, in order

$steps

Then stop. Do not merge the PR: a person or the orchestrating session reviews and merges it.
$phases
## The PR body

ce-commit-push-pr writes it; make sure it holds:

- `Closes #$issue`;
$criteria_rule- a section headed "Review findings" listing what ce-code-review found, which findings you applied, and every residual one with the reason it stays;
- the test and lint commands you ran last and their result;
- a section headed "Owner actions needed" listing each denied or out-of-scope action as the exact command or API call. A denied call goes there and the work continues.

## What checks you

A Stop hook reads the tool calls this run recorded, not what you write. It will not let the run end until it sees each skill above invoked, the test suite and the linters run after your last edit and exiting 0, the worktree clean, and an open PR for $branch whose head is your HEAD and whose body cites every criterion id and has the review heading. When it blocks, it lists what is missing; do exactly that. Run the full test suite and linters as plain commands, not piped into `tail`, behind `|| true` or ended with `&`, and in the foreground with a Bash timeout long enough for them: a run sent to the background has no exit code the hook can see, and a subset (`-k`, a single test id, `--collect-only`) is not the suite, so neither counts.

## Tests are evidence

Never skip, xfail, loosen an assertion, delete a test or re-baseline a snapshot to make a check pass. A failing test is telling you something: fix the code, or measure and report in the PR body why the expectation was wrong. List every changed test file in the PR body with the reason. Keep the full suite and the linters green at every commit.

## Ports

Other tickets may be running on this machine at the same time. Every server, dev server or browser check you start listens on a port from `HTR_PORT_BASE` to `HTR_PORT_BASE`+99 (`HTR_PORT_BASE`=$port_base is in your environment), never on a fixed port another run could hold. If the project hard-codes a port, use the project's own override for it; if it has none, say so under "Owner actions needed".

## Long commands

Bash's foreground limit is raised to 45 minutes for this run. Run the final check as one foreground command with `timeout: 2700000`, never in the background: with other runs sharing the machine it can take longer than 10 minutes, and the Stop hook only counts a foreground run.

## AWS

This run has only the provisioned profile `$aws_profile`. The host's own AWS credentials are not yours, and a hook refuses reads of the real ~/.aws. When an AWS call is denied, record it under "Owner actions needed" and continue.

## Headless turns end early

You run as one headless turn, and a turn can end while you wait on a subagent you dispatched, leaving half-applied edits uncommitted. Work inline: do each unit yourself rather than dispatching subagents for implementation, commit each unit as soon as its tests pass, and never leave the tree dirty at a point where you might stop.

## The ticket, verbatim

# $title

$body
