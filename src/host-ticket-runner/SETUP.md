# Setting up a host for host-ticket-runner

Once per host. Done when `htr.py preflight` prints every row `ok`, and `htr.py preflight --agent` shows an agent with no ambient AWS identity.

## What the host needs

| Tool | macOS | Windows |
|---|---|---|
| Python 3.9 or later | the system `python3` is enough | python.org installer; run the driver as `py htr.py` |
| Claude Code, logged in | `claude` on PATH | `claude` on PATH (native installer) |
| GitHub CLI, logged in with `repo` scope | `gh auth login` | `gh auth login` |
| git with worktrees | Xcode tools or Homebrew | Git for Windows; its `bash.exe` is what Claude Code runs Bash tool calls in |
| AWS CLI (only for the AWS check and tickets that call AWS) | `brew install awscli` | the MSI installer |

The driver and its hooks are standard-library Python. Nothing is installed into the target repository and nothing into the owner's Claude settings: each run's hooks live in that run's `settings.json`, passed with `--settings`.

The skills the brief names (`ce-plan`, `ce-work`, `ce-simplify-code`, `ce-code-review`, `ce-compound`, `ce-commit-push-pr`) must be installed for the user the runner runs as; `scripts/install.sh` in this repository does that. A run whose agent cannot find one blocks at the Stop hook and escalates.

## State

`HTR_HOME` holds every run's record, worktree, clone and the agents' AWS files. It defaults to `~/.local/state/host-ticket-runner` on macOS and `%LOCALAPPDATA%\host-ticket-runner` on Windows; set it in the shell profile to move it. It is the only directory the runner writes outside the target repository's worktrees.

## Keeping a run alive

`launch` returns at once; the agent runs on in a supervisor process that outlives the session that launched it.

- `--detach process` (default): a new session (POSIX `setsid`) on macOS; `DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB` on Windows. It survives the terminal and the Claude session closing. It does not survive a reboot, a logout, or a sleep long enough for the API call to time out; `status` then shows `dead` and `resume` continues it.
- `--detach launchd` (macOS): a per-run launchd agent in the owner's GUI domain (`launchctl bootstrap gui/<uid>`), owned by launchd rather than any shell. `clean` boots it out.
- `--detach schtasks` (Windows): a one-shot Task Scheduler task running a per-run `.cmd`. `clean` deletes it.

A laptop that sleeps with the lid closed pauses every mode; keep it awake for the run (`caffeinate -i` on macOS, the power plan on Windows).

## The login rule

Never run a host `/login` or `claude auth login` while `htr.py status` shows a run `running`. Logging in issues a new token and revokes the one every running agent holds; their next API call fails with a 401, `status` shows `auth-expired`, and each needs `resume --send` once the owner is logged in again. Preflight and every `launch` print this warning.

## AWS

[`AWS.md`](AWS.md). Until the owner provisions the ticket agents' key, agents run with no AWS credentials at all, which is the right state for a ticket that does not call AWS.

## Letting the orchestrator run the driver

An orchestrating Claude session runs `htr.py` through its Bash tool. The stack's `src/settings-snippet.json` does not grant it: launching an agent with permissions bypassed is the owner's call to pre-approve, so the rule is the owner's to add to `~/.claude/settings.json`, with the absolute path of the installed skill:

```
"Bash(/Users/<you>/.claude/skills/host-ticket-runner/htr.py:*)"
```

Without it the orchestrator asks the owner for each `htr.py` command, or auto mode refuses it. Never grant Edit or Write on the skill's folder alongside it: `bootstrap.test.sh` fails a snippet that does, because the rule runs whatever that folder holds.

## Windows: what was tested

The runner was built and tested on macOS. On Windows:

- **Tested** (by the unit tests, which run on any OS): routing, criteria extraction, the Opus cap, marker parsing, the Stop hook's evaluation and budgets, the `~/.aws` deny, the env scrub, the launch record and resume budgets, with `claude` and `gh` faked.
- **Not tested on a Windows host:** the detached `process` launch with its Windows creation flags, `--detach schtasks`, the hooks running under Claude Code for Windows (exec form, `sys.executable`, paths with backslashes), `gh pr view` from a Windows worktree, and the `~/.aws` deny against real Windows tool payloads. The deny's patterns cover `%USERPROFILE%\.aws`, `$env:USERPROFILE\.aws` and backslashed paths, and its unit tests pass on macOS, but no Claude Code for Windows payload has been run through them.

Run the first Windows ticket attended: `htr.py preflight --agent`, then a docs-only ticket, watching `status` until `complete`.
