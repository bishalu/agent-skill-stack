# Updating

```bash
./scripts/sync.sh      # fetch upstreams, rebuild build/, regenerate MANIFEST.md and DEVIATIONS.md
git diff               # read what upstream changed underneath you
./scripts/install.sh   # relink skills, reinstall changed plugins
```

Then restart Claude Code.

## What each step does

`sync.sh` pulls every clone in `upstream/`, re-runs `build.py`, and re-renders the
generated docs. The routing edits live in `curation.json` and are re-applied to freshly
copied files, so an upstream skill can rewrite its whole body and the curation survives.
The only thing that breaks it is an upstream rename.

`git diff` after a sync is the review step, and it is the point of the whole
arrangement. `MANIFEST.md` shows the new pinned commits. `DEVIATIONS.md` shows each
changed description next to the upstream text it replaced. If upstream has already
narrowed a description this repo was narrowing, the diff is where you notice, and the
right move is to delete the override from `curation.json` rather than keep carrying it.

`install.sh` is idempotent. It relinks `~/.claude/skills`, updates all three
marketplaces, reinstalls plugins whose fingerprint changed, and appends the routing
block to `~/.claude/CLAUDE.md` only if it is not already there.

## The stale-plugin trap

Claude Code caches a plugin by version. An edited fork keeps its upstream version, so
neither `claude plugin install` nor `claude plugin update` re-copies it, and you end up
testing the old description while reading the new one. This cost me an eval round.

`build.py` writes a `fingerprints.json` next to each forked marketplace, hashing every
`SKILL.md` in each plugin. `install.sh` compares against `.install-state.json` and
uninstalls then reinstalls only the plugins whose fingerprint moved. If you ever suspect
a stale plugin, delete `.install-state.json` and run `install.sh` again to force a clean
reinstall of everything.

## When a build fails

`FATAL: missing upstream skill <path>` means a path in `curation.json` no longer exists,
usually a rename. Find the new path in `upstream/`, update `curation.json`, rebuild.
Nothing is half-written: `build/` is deleted and rebuilt from scratch every run.

`FATAL: no frontmatter in <path>` means an upstream SKILL.md lost its YAML header. That
is an upstream bug. Report it there.

## After any change to a description

Re-run the routing eval. A narrowed description that stops firing is as broken as a broad
one that fires too often, and only a run tells you which you have.

```bash
python3 eval/run-eval.py --runs 3                       # full corpus
python3 eval/run-eval.py --case review                  # one case while iterating
python3 eval/run-eval.py --tag collision                # only the deliberate fights
python3 eval/run-eval.py --corpus eval/heldout.jsonl    # the held-out set
python3 eval/rescore.py eval/results/x.json             # rescore stored runs, no new sessions
```

The runner exits non-zero if any session fired two lifecycle owners. That is the
acceptance gate.

`rescore.py` matters more than it looks. The stored `fired` list per run is the raw
observation and scoring is derived, so when a scoring rule turns out to be wrong you fix
the rule and rescore rather than paying for the sessions again. Two of my early failures
were bad expectations, not bad routing.

## Writing a good eval case

Say what you mean in the prompt. One of my cases asked for "a standalone script to
re-encode the audio fixtures" and expected `modern-python` to fire. It never did, across
five runs, and it was right not to: the prompt never said Python and the fixture repo
holds both a `package.json` and a `requirements.txt`. The case became a negative, and a
positive twin that names Python replaced it.

Every positive case wants a negative twin using the neighbouring wording. That is what
catches a description tuned to your corpus instead of to the task.

## Adding a skill

Add an entry under the right source in `curation.json` with its upstream `path`, an
invocation `class`, a `domain`, and, if its trigger needs narrowing, a `frontmatter`
override with a `reason`. Rebuild, then add eval cases covering both the trigger you want
and the neighbour you are afraid of stealing from.

## Removing a skill

Delete its entry from `curation.json`, rebuild, then remove the stale symlink in
`~/.claude/skills`, or `claude plugin uninstall <name>@<marketplace>`. The installer will
not remove links it did not create in this run.

## Upstream drift worth watching

Trail of Bits ships new plugins often, and `MANIFEST.md`'s exclusion list records what
was considered and declined. Read it before adding more. Matt Pocock's `in-progress/`
directory is explicitly unstable and nothing from it is vendored here, which should stay
true. AWS adds skills to `aws-core` regularly, and the fork's `includeSkills` list means
new ones are ignored until you add them deliberately.
