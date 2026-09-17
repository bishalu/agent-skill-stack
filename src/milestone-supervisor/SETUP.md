# Setting a project up for unattended milestones

Done once per project. When every item below holds, return to `SKILL.md` and start at step 1.

Start with `run-milestones.sh init` from the repository's top level. It writes the files sections 2 and 6 describe from the templates next to the driver (`.milestones/config`, `.milestones/standing-rules.md`, `.milestones/STATUS.md`, `.compound-engineering/config.yaml`, `compound-packs/milestones/README.md`), never overwriting one that exists, adds `logs/` and `.milestones/config.local` to `.gitignore`, and prints what is still yours to fill in. The sections below say what each file must end up holding.

## 1. The spec has gates

The milestones file has one `## Milestone N` section per milestone, each with a build list and exit criteria that are measurable: a number, a count, a pass or fail. A principles or thresholds file is the single place a threshold lives. An exit criterion without a measurement is not a gate; write the measurement before starting, or the review in step 4 has nothing to check.

## 2. Compound Engineering is configured in the repo

CE keeps repo defaults in `.compound-engineering/config.yaml`; `init` writes one naming the milestones pack, `/ce-setup` creates it interactively, or write it by hand. Two things belong there for milestone work:

- `docs_root`, only when `docs/` is owned by something else. Unset, plans go to `docs/plans/` and learnings to `docs/solutions/`, and every milestone's `ce-plan` reads the learnings of the ones before it. That return arrow is the point of the loop; keep one artifact tree across sandboxes by committing it.
- `packs:` naming a repo-local Compound Pack, for example `compound-packs/milestones/`, one markdown rule file per invariant with `title` and `applies_when` frontmatter. `ce-plan` quotes a matching rule into the plan as a constraint and `ce-code-review` flags a diff that contradicts it. The invariants `SKILL.md` lists go here in the project's words; `init` writes the folder's README, and `/ce-setup pack:milestones` scaffolds it too. The rule files are the owner's to write.

A rule reads like this:

```markdown
---
title: The catalog is seeded, never rebuilt, inside a sandbox
applies_when:
  - running or writing anything that ingests, imports or fills the catalog
  - a test or fixture needs catalog rows
tags: [data, ingest, sandbox]
---

The seeded database in the worktree holds refined values. Ingest overwrites them with first-pass ones. Read it; never run ingest.
```

## 3. The sandbox tool

`agent-sandbox` gives each run its own worktree and branch inside a disposable container, seeds gitignored paths on every start, mirrors the host's skills and plugins, and runs one-shot commands. In `~/agent-sandbox/config.json`, `worktree_seed` lists what every new sandbox receives: the env file, the secrets folder, model weights, the seeded copy of any mutable dataset. A file not on that list does not exist inside the sandbox. Push is denied inside, which is why the agent's loop ends at `ce-commit` and the supervisor ships.

## 4. Scoped credentials

The agent's cloud key sits behind a permission boundary that allows the milestone's work and refuses the rest; the supervisor holds the owner-level key. A denial is the agent's signal that it needs the supervisor, which is why the standing rules ask for denied calls to be recorded under "Owner actions needed" rather than worked around.

## 5. Record and replay

Every paid model call in the project has a record-and-replay path, so the test suite spends nothing and a run can be reproduced. A pack rule names the mechanism and the re-record decision.

## 6. The driver and the `.milestones/` folder

The driver is `run-milestones.sh` next to this file. Run from the project root, it builds one prompt per milestone and runs it as one `claude -p` turn inside the sandbox with the permission prompts off, gates after each, and refuses a deploy milestone without `--deploy`. Its header comment is the usage. `init` creates the `.milestones/` files below from templates; fill in what it prints:

- `MILESTONES_FILE` and `GATE` in `.milestones/config`. The template leaves `GATE` empty, so every launch, `--gate` and `integrate` refuses naming `GATE` until it is set. `MODEL=opus` is already set, as the cap.
- `SEED_PATHS` when the gate reads gitignored inputs.
- The project facts in `.milestones/standing-rules.md`; the template already carries the CE sequence, the report contract, the evidence-line and test-integrity rules and the inline-work rule.
- `.milestones/config.local` and the per-milestone files by hand, when needed.

The files:

| file | holds |
|---|---|
| `.milestones/config` | shell assignments: `MILESTONES_FILE`, `REPORT_DIR`, `GATE` (required: the command run after each milestone, in the sandbox and by `integrate` on the host), `GATE_SETUP` (runs first to rebuild derived state from committed recordings), `GATE_ENV` (a probe whose first line goes into the evidence line), `SEED_PATHS` (the gitignored paths `integrate` copies into its temporary worktree; mirror agent-sandbox's `worktree_seed`), `INTEGRATION_BRANCH`, `DEPLOY_MILESTONES`, `TIMEOUT` (per-milestone wall clock), `GATE_TIMEOUT` (bound on each gate run), `MEMORY`, `CPUS`, `MODEL` and `EFFORT` with their `_N` per-milestone forms, `LANE_N`, `EVALUATE_N` and `EVALUATE_TARGET_N`. The weakening scan's `TEST_WEAKENING_PATTERN`, `TEST_ASSERT_PATTERN`, `TEST_GLOBS`, `SNAPSHOT_GLOBS` and `GATE_DEFINITION_GLOBS` (the files that define the gate, such as the justfile or a runner's config) have cross-framework defaults; override them when the project's layout differs. The driver's header comment is the complete key reference |
| `.milestones/config.local` | gitignored, sourced after `config`: this host's values, such as a PATH prefix putting the gate's toolchain first. `integrate` runs the gate in a non-interactive shell, which does not read `.bashrc`, so a version manager's default is what it finds unless this file says otherwise |
| `.milestones/STATUS.md` | one row per milestone, header `\| Milestone \| Lane \| Sandbox \| Merged \| Gate \| Unmet criteria \| Open blockers \| Next action \|`; `integrate` creates it when absent |
| `.milestones/standing-rules.md` | the process rules every milestone agent gets: the CE sequence from `SKILL.md` with its headless tokens, the report contract (a measured number per exit criterion, an "Owner actions needed" section, the report as the last commit, then `ce-handoff create`), that there is nobody to ask, and the project facts no learning holds yet. Two rules belong in every project's copy: the report's gate table quotes the driver's evidence line for the report's own commit; and tests are never skipped, xfailed, loosened, deleted or re-baselined to pass, with every changed expectation listed by path and reason under a "Test expectation changes" heading. `milestone-N` and `REPORT_DIR` are substituted. |
| `.milestones/milestone-N.md` | optional paragraph for one milestone: what to merge first, which files to extend rather than rewrite |
| `.milestones/notes-N.md` | the supervisor's notes for milestone N, written at step 1 of the loop |

The prompt the driver assembles, in order: pointer to the spec section and its appendices, standing rules, the spec section verbatim, the milestone paragraph, the notes, and the stop rule "when the exit criteria are met, or you have measured why one is not, stop". `run-milestones.sh prompt N` builds that prompt without launching, prints it and writes `logs/milestones/milestone-N.prompt`; read it before spending a run on it.

## 7. Permission rules for the supervising session

The driver switches the agent's permission prompts off, which the supervising session's own permission layer reads as creating an unsafe agent unless told otherwise. In `~/.claude/settings.json`:

- `permissions.allow`: the driver by absolute path; the `agent-sandbox` verbs `status`, `list`, `doctor`, `memlog show`, `enter` and `run`; the read-only `systemctl --user` verbs `status`, `list-units` and `is-active`; and `Edit`/`Write` on `**/.milestones/STATUS.md`, `**/.milestones/notes-*.md`, `**/.milestones/evaluation-*.md` and `**/.milestones/mutations/**`.
- `autoMode.environment`: one line stating that the driver launches agents inside rootless containers behind a scoped key, that the skip-permissions flag inside the sandbox is by design, that running the driver and those `agent-sandbox` verbs and editing the STATUS, notes and evaluation records is routine supervisor work, and that editing the driver or the gate config is not.

Without both, the session stops at launch and the owner has to approve by hand each time.

What stays prompting, and why. The driver calls `systemd-run --user` itself, so the session needs no rule for it, and a `systemd-run` or bare `systemctl --user` rule would run any host command without a prompt. `agent-sandbox rm`, `clean`, `build` and `config set` destroy work or change every later launch. `.milestones/config`, `config.local` and `standing-rules.md` stay prompting because the driver sources the config as shell and the allowed driver rule then runs it: an allowed edit there, or to the skill folder, would be an allowed arbitrary command. The skill is edited in its source repository and installed as a link, never in place. The skill stack's installer only adds rules, so a broader rule an older install wrote stays in `settings.json` until the owner removes it; the stack's bootstrap test fails if its snippet ever grants one again.

## 8. Credentials the sandbox borrows

The sandbox mounts the host's Claude OAuth credentials read-only. A re-login on the host revokes the token the running agent holds, and its next API call fails with a 401 and the turn ends. Do not run `/login` on the host while a milestone is running; if one dies that way, refresh the login and give it a finishing follow-up turn. The same applies to any host-side rotation of a key the sandbox was seeded with.

## 9. Detachment

Closing the operator shell ends every process it owns, so the driver launches each milestone as a transient systemd user unit (`systemd-run --user`), one milestone per unit, with the unit's output appended under `logs/milestones/`. The unit outlives the supervisor session; only a VM death ends it, and `run-milestones.sh resume` covers that. `logs/` is gitignored. The driver exports `XDG_RUNTIME_DIR` and the session bus address from the uid before calling systemd, so it works from a shell with neither. `loginctl enable-linger <user>` must be on, or the user manager stops with the last login; `agent-sandbox doctor` checks it.

## 10. Host disk and memory

A sandbox that outgrows the VM takes the whole host down, not just its own turn, and so does a VM whose disk image cannot grow. On 2026-09-13 a WSL2 host rebooted four times. The first suspicion was memory (two 16 GB sandboxes, onnxruntime tests and an image build at once). The memory log then showed 48 GB available seconds before a death, and the actual cause was the disk: the Windows drive holding the distro's `ext4.vhdx` had 1 GB free, and the image was not sparse, so every write burst inside the guest that needed new allocation (an image build, the ~800 MB agent-home copy at every sandbox launch) failed with SIGBUS across processes until init died. Check both before the first launch.

Disk. On WSL2, `df -h /mnt/c` must show tens of gigabytes free, and the distro's image must be sparse so space freed inside the guest returns to Windows. From a Windows terminal, with nothing running: `wsl --shutdown`, then `wsl --manage <Distro> --set-sparse true`, then inside the guest `fstrim -v /` as root (`wsl.exe -u root -- fstrim -v /` works without sudo). `sparseVhd=true` in `.wslconfig` only affects distros created after it was set; `fsutil sparse queryflag <path to ext4.vhdx>` tells the truth. Trim, delete and prune inside the guest reclaim nothing on the host until then.

Memory. Every long-lived container on the host carries a memory limit. Sandboxes get theirs from `agent-sandbox` (`memory`, `memory_swap` equal to it so swap is not a second budget). Anything else that runs as a container, such as an MCP server started from `.mcp.json`, gets `--memory` and `--memory-swap` on its `docker run` line, because admission counts an unlimited container at its live usage plus a quarter and cannot bound it.

Admission is on for the host (`agent-sandbox config set admission_enabled true`, then `agent-sandbox admission install`, which caps the `agent-sandbox.slice` at the budget), and the memory log runs (`agent-sandbox memlog install`). With the log stopped, every launch refuses within three minutes; `agent-sandbox doctor` names the dead timer.

The VM's own cap is the owner's to set, in `%USERPROFILE%\.wslconfig` on the Windows side, and it takes effect only after `wsl --shutdown` from a Windows terminal, which ends every running sandbox. Recommend this on a 64 GB machine:

```ini
[wsl2]
memory=40GB
swap=16GB
processors=20

[experimental]
autoMemoryReclaim=dropCache
sparseVhd=true
maxCrashDumpCount=2
```

40 GB leaves Windows 24 GB, so a page-cache spike inside the VM cannot starve the host. `dropCache` replaces `gradual`, which is documented to hang systemd-based distributions. Two crash dumps cap the disk cost. Ask the owner to apply it between milestones, never while one runs.
