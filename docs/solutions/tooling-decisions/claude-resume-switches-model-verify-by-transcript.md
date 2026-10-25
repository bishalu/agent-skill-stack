---
title: "claude -p --resume with --model switches the model mid-session; verify it from the transcript, not modelUsage"
date: 2026-10-25
category: tooling-decisions
module: host-ticket-runner
problem_type: tooling_decision
component: tooling
severity: medium
applies_when:
  - "A runner routes one Claude Code session through turns on different models (htr phase turns)"
  - "You need proof of which model answered a headless turn"
retire_when: "Claude Code stops honouring --model on --resume, or its --output-format json modelUsage reports only the main loop's model; rerun the check below on the current CLI to find out."
tags: [claude-cli, resume, model-routing, headless, htr, phases]
---

# claude -p --resume with --model switches the model mid-session; verify it from the transcript, not modelUsage

## Context

htr's phases run in one session: the launch turn is `claude -p --session-id <id> --model <build> --effort <build>`, and each later phase is `claude -p --resume <id> --model <next> --effort <next> "<phase prompt>"` (`run_turn` in `src/host-ticket-runner/htr.py`). That design only holds if `--model` on a resumed turn changes the model that answers. A resumed session might have kept the model it started with.

## Guidance

`--model` and `--effort` on `claude -p --resume <id>` do apply to the resumed turn. A live check ran one throwaway session in a temp dir for three turns: haiku, then a resume on sonnet/low, then a resume on haiku. The assistant messages in `~/.claude/projects/<cwd-slug>/<session-id>.jsonl` carried `message.model` claude-haiku-5-5, then claude-sonnet-5-5, then claude-haiku-5-5, all under the same `session_id`, and each turn could see the earlier ones.

Read the transcript's assistant `message.model` to prove which model answered. The `modelUsage` map in `--output-format json` is not enough on its own. It also counts the CLI's auxiliary calls, so the sonnet turn's `modelUsage` listed haiku as well as sonnet. Taken alone, it would suggest the switch failed or happened only partly.

When you script the check, run it from Python rather than zsh. zsh does not word-split an unquoted `$VAR`, so an `env -u A -u B` prefix kept in a variable runs as a single command name and fails with "command not found". Strip the parent session's `CLAUDE*` and `AWS_*` variables in the Python script, as `agent_env` does, and keep `CLAUDE_CONFIG_DIR` and the auth token.

## Why This Matters

If the switch had not worked, every phase would have run on the build model while `markers.jsonl`, `agent.log` and `htr.py status` all recorded the phase's model, because they log what the supervisor asked for. The judge would then be Sonnet on light and standard tickets while the records said Opus. A test against the fake `claude` in `htr_test.py` checks only the argv the supervisor passes, not what the real CLI does with it.

## When to Apply

- Before you rely on per-turn model routing in any runner built on one `claude -p` session.
- After a Claude Code upgrade, if htr's phase records and its bills stop agreeing.

## Examples

The shape of the check, which reads the transcript and records no secrets:

```python
turns = [(["--session-id", sid, "--model", "haiku"], "say ok"),
         (["--resume", sid, "--model", "sonnet", "--effort", "low"], "say ok again"),
         (["--resume", sid, "--model", "haiku"], "say ok a third time")]
# then, for each assistant line in <config>/projects/*/<sid>.jsonl:
#   print(line["message"]["model"])
```

## Related

- `src/host-ticket-runner/SKILL.md`, "How the phases run"
- A related rule in the same change: `ce-code-review` counts only inside a judge-phase turn (`judged_reviews` in `htr_hooks.py`). Without it, a review run early on the build model would satisfy the Stop hook, and the Opus turn would never run.
