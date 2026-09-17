#!/usr/bin/env bash
# Run one of a project's spec milestones as one autonomous Claude Code run inside one
# agent-sandbox, with a gate after it, the whole thing as a transient `systemd --user`
# unit that outlives the shell that launched it. Project-agnostic: the project
# describes itself in <repo>/.milestones/ (see the milestone-supervisor skill).
#
#   run-milestones.sh 6                          # milestone 6 in a fresh sandbox
#   run-milestones.sh 6 --sandbox app-1a2b3c4d   # milestone 6 in an existing sandbox
#   run-milestones.sh 7 --deploy                 # a deploy milestone is refused without --deploy
#   run-milestones.sh 6 --note path/to/notes.md  # supervisor notes appended to the prompt
#   run-milestones.sh 6 --sandbox ID --continue "the owner did X; re-take the readings"
#   run-milestones.sh --sandbox ID --continue "..."  # the milestone is the sandbox's milestone tag;
#                                                # refused when the sandbox has no numeric tag
#   run-milestones.sh 6 --sandbox ID --gate      # only the gate (report committed, gate never ran)
#   run-milestones.sh status                     # this project's sandboxes, with the milestone meaning
#   run-milestones.sh resume [--issue]           # the finishing command per unfinished sandbox
#   run-milestones.sh config 6                   # the keys milestone 6 resolves to, KEY=value per line
#   run-milestones.sh prompt 6                   # build milestone 6's prompt without launching: print it and
#                                                # write logs/milestones/milestone-6.prompt
#   run-milestones.sh init                       # set up a repository: .milestones/, CE config, a starter pack
#   run-milestones.sh integrate app-1a2b3c4d [6]  # merge, check, gate on the host, record STATUS.md, push
#   run-milestones.sh mutate 6 .milestones/mutations/6-drop-limit.patch [--ref REF] [--steps api,lint]
#                                                # does the gate catch a planted defect in what integrate would gate
#   run-milestones.sh accept 6 --init            # the exit criteria of milestone 6 into .milestones/acceptance/6.json
#   run-milestones.sh accept 6 --criterion 6.c2 --evidence bundle:<bundle>#<step>:<test id>[,<test id>...]
#   run-milestones.sh accept 6 --criterion 6.c3 --evidence mutation:<line or patched seal> [--context evaluator:<text>]
#   run-milestones.sh approve 6 <kind> <item...>  # an owner approval, typed at a terminal (kinds below)
#
# One milestone per invocation: the supervisor reviews between milestones, so the
# driver refuses `run-milestones.sh 5 6`. The launch returns as soon as systemd accepts
# the unit; read `status` right after, because admission runs inside the unit.
#
# A milestone launch refuses while .milestones/STATUS.md holds a row for another milestone
# in the same lane whose Merged cell is empty or "-": that milestone's work is not pushed
# yet, and a lane says "these share a dataset or modules". The table's header:
#   | Milestone | Lane | Sandbox | Merged | Gate | Unmet criteria | Open blockers | Next action |
#
# init, from a git repository's top level (the one verb that runs without .milestones/),
# copies each file under templates/ next to this script to its target only when the target
# is absent, printing "wrote <path>" or "kept <path>":
#   templates/config             -> .milestones/config (GATE left empty, so gating refuses until set)
#   templates/standing-rules.md  -> .milestones/standing-rules.md
#   templates/STATUS.md          -> .milestones/STATUS.md
#   templates/ce-config.yaml     -> .compound-engineering/config.yaml
#   templates/pack-README.md     -> compound-packs/milestones/README.md
# and appends each line of templates/gitignore-lines missing from .gitignore. It ends with
# what the owner still fills in.
#
# <repo>/.milestones/config      shell assignments, all optional:
#   MILESTONES_FILE=docs/spec/11-milestones.md   file whose "## Milestone N" sections are the briefs
#   REPORT_DIR=docs/reports                      the agent writes milestone-N.md here
#   GATE="just check"                            the gate as one step (kind static, named gate); this
#                                                or GATE_STEPS is required to gate (no default)
#   GATE_STEPS=("integration|pg|just test-pg|sandbox-only" "replay|api|just test-replay" "static|lint|just lint")
#                                                the gate as labeled steps, in order, instead of GATE:
#                                                kind|name|command[|sandbox-only]. kind: integration (real
#                                                services or stores), replay (recorded external calls) or
#                                                static (lint, types, drift). A sandbox-only step is recorded
#                                                "not run: sandbox-only" on the host, never as a pass. The
#                                                command may hold "|"; a trailing "|sandbox-only" is the flag
#   GATE_SETUP="just replay"                     step `setup` (kind static), first, to rebuild derived state
#                                                from committed recordings in the worktree before the gate
#                                                reads it (steps share the worktree, not a shell or /tmp)
#   GATE_ENV="sha256sum data/catalog.db | cut -c1-12"   a probe; its first stdout line goes
#                                                into the gate's evidence line as env="..."
#   DEPLOY_MILESTONES="7"                        numbers that need --deploy
#   TIMEOUT=12h                                  per-milestone wall clock (12h, 90m, 3600)
#   MEMORY=8g CPUS=6                             container resources for every milestone
#   MEMORY_6=12g CPUS_6=8                        overrides for one milestone; unset keys fall back
#   MODEL=opus EFFORT=high                         the model and effort the agent runs at (claude --model/--effort)
#   MODEL_7=opus EFFORT_7=max                      per-milestone overrides; unset keys mean the session default (Opus at most)
#                                                to MEMORY/CPUS, then to agent-sandbox's config
#   LANE_12=library                              the lane milestone 12 runs in (default main); every
#                                                agent-sandbox call is tagged lane=<lane>
#   EVALUATE_16=1 EVALUATE_TARGET_16="pnpm dev"  milestone 16 gets an independent evaluation
#   INTEGRATION_BRANCH=main                      integrate refuses on any other branch (unset: any branch)
#   SEED_PATHS="data/catalog.db .env"            gitignored paths copied into integrate's temporary worktree
#   GATE_TIMEOUT=30m                             bound on each gate run, sandbox and host: every step gets
#                                                what is left of it
#   GATE_PORT_RANGE=20000-29999                  where a host gate run's GATE_PORT_1..4 come from
#   INTEGRATE_GATE_WHERE=host                    where integrate gates: host (a temporary worktree) or
#                                                sandbox (a fresh sandbox of the merge commit, removed after)
#   TEST_WEAKENING_PATTERN / TEST_ASSERT_PATTERN  grep -E patterns for integrate's weakening scan
#   TEST_GLOBS / SNAPSHOT_GLOBS                  space-separated globs of test and snapshot files
#   GATE_DEFINITION_GLOBS                        globs of the files that define what the gate runs
#                                                (justfile, Makefile, package.json, pyproject.toml, runner
#                                                configs, .github/); a change to one is a gate-config hit
#                                                (defaults and matching rules at the integrate section)
# <repo>/.milestones/config.local  gitignored, sourced after config: this host's values
#                                                (a PATH prefix for its toolchain, say)
# <repo>/.milestones/standing-rules.md          rules every milestone gets; "milestone-N" is substituted
# <repo>/.milestones/milestone-N.md             optional extra paragraph for milestone N
# <repo>/.milestones/notes-N.md                 optional supervisor notes, appended if present and --note is not given
#
# Files under <repo>/logs/milestones/: chain.log (every decision), unit-<unit>.out (the
# unit's stdout+stderr), milestone-N.prompt, milestone-N.log and milestone-N.gate.log (the
# agent-sandbox result JSON, or the admission refusal), create-N-<stamp>.log (a new sandbox),
# continue-<stamp>.log (a --continue turn's result JSON). An exit 3 is an admission refusal
# only when its JSON is the admission payload; otherwise it is the command's own exit.
#
# Every gate run runs each step as its own invocation (a `bash -c` child on the host, an
# `agent-sandbox enter` per step in a sandbox) and takes the step's exit code from that
# invocation, stopping at the first failure; later steps are recorded "not run". A run gets
# a fresh TMPDIR and, on the host, GATE_PORT_1..4 registered in logs/milestones/ports.registry
# until it ends (in a sandbox the container's own namespace isolates them). Before any step
# the host reads the gated commit's tree, a definition hash (the step list, GATE_SETUP,
# GATE_ENV, config, config.local, this driver, MAX_* budget keys) and the dirt: tracked
# changes and untracked files git does not ignore, SEED_PATHS excluded, plus a sandbox's
# seed_kept paths. The bundle, always on the host, is
#   logs/milestones/evidence/<milestone>-<where>-<stamp>/
#     evidence.json  dirty.patch  untracked.txt  steps/<i>-<name>.log  steps/env.log
# evidence.json is written after the last step (each step's log_sha256 in it), and its sha256 is
# logged as the seal. Its
# produced_by names the verb that made it (gate, integrate, check, mutate); only an
# integrate bundle is ever delivery evidence.
# Each run appends to its gate log and chain.log:
#   gate pass|FAIL exit=N milestone=N sha=<12> tree=<12> def=<12> dirty=yes|no
#     where=sandbox|host-integrate|sandbox-integration|local|host-mutate|sandbox-mutate setup=yes|none
#     steps=integration:<passed>/<n> replay:<passed>/<n> static:<passed>/<n> skipped:sandbox-only:<k>
#     env="..." evidence=<bundle> at=<iso>                                  (one line)
# and to chain.log only:
#   seal <sha256 of evidence.json> <bundle>
# The agent's transcript is the sandbox's own runs/<id>/stdout.log, which `status` scans.
#
# A failed gate stops the unit and leaves the sandbox for inspection. Nothing is merged
# or pushed: the work stays on the sandbox branch, and push is denied inside the container.
#
# integrate <id> [N], run from the host checkout on the integration branch. N is the
# sandbox record's milestone tag, else the positional number; the two must agree. In order:
#   1. refuse on tracked changes outside METADATA_ALLOWLIST (STATUS.md, events.jsonl, grades.jsonl,
#      acceptance/, approvals/, mutations/ under .milestones/), a detached HEAD, a branch other than INTEGRATION_BRANCH,
#      no agent-sandbox/<id> branch, no upstream, a branch behind its upstream, or a branch
#      ahead of its upstream with a commit that is not (a) reachable from agent-sandbox/<id>,
#      (b) an earlier merge of that branch or a descendant of one, or (c) a non-merge commit
#      changing only .milestones/ (the supervisor's STATUS.md cells, evaluation-N.md);
#   2. refuse when the sandbox's own range (merge-base with the upstream..agent-sandbox/<id>)
#      touches anything under .milestones/ (supervisor files come only from host commits),
#      adds or changes a path `git check-ignore` reports ignored in the host checkout (a
#      merge would overwrite it), or does not add or change a non-empty REPORT_DIR/milestone-N.md;
#   3. merge --no-ff --no-overwrite-ignore agent-sandbox/<id> (skipped when already merged;
#      a conflict aborts);
#   4. the weakening scan over @{upstream}..HEAD: every hit (skip-marker, removed-assert,
#      deleted-test, test-change, snapshot, gate-config; see weakening_hits) needs an owner
#      approval of its kind, path and current blob in .milestones/approvals/N.md as committed at
#      HEAD. The report approves nothing. Any git error in the scan refuses (fails closed);
#   5. EVALUATE_N=1: .milestones/evaluation-N.md committed, no "owner action required" line;
#   6. the gate steps under GATE_TIMEOUT: INTEGRATE_GATE_WHERE=host in a temporary detached
#      worktree of HEAD seeded with SEED_PATHS (where=host-integrate); =sandbox in a fresh
#      `agent-sandbox run <repo> --new` tagged purpose=integration-gate, refused unless its
#      HEAD is the merge commit, removed on every exit path (where=sandbox-integration); then
#      refuse unless the bundle still matches its seal and HEAD is still the gated commit on
#      the same branch with no tracked change outside METADATA_ALLOWLIST;
#   6b. acceptance (acceptance_complete): every criterion of .milestones/acceptance/N.json has
#      evidence recorded on the gated tree and definition hash with its seals intact, or a
#      criterion-waiver approval at HEAD. Otherwise it prints "refused: acceptance incomplete",
#      the sealed bundle and the exact accept and approve commands, keeps the merge local and
#      exits 2 (run accept, then integrate again);
#   7. upsert the STATUS.md row (Lane, Sandbox, Merged = gated sha, Gate = pass <sha> tree=
#      def= and the kind counts), commit only that
#      file, check the commit's parent is the gated sha, and push that commit to the
#      upstream under timeout GATE_TIMEOUT with stdin closed.
# A refusal or failure after step 3 pushes nothing. When this run made the merge, it keeps
# the merge local and logs the pre-merge sha with the `git reset --hard` that drops it; on
# an already-merged re-run it logs `git log --oneline <upstream>..HEAD` instead, because a
# reset would also drop fix-forward commits. Exit 2 refused (acceptance incomplete included), 1
# gate or push failed. A gate that could not start (no ports, no worktree) writes no bundle and
# logs why in chain.log; the failure line reads "evidence: none (could not start: <why>)".
#
# accept N --init [--force]: the "Exit:" paragraph of milestone N's section, split at sentence
# ends and at semicolons outside (), [], {} and `code`, into .milestones/acceptance/N.json with
# ids N.c1.. and null evidence; refuses to replace the file without --force.
# accept N --criterion N.c<i> --evidence bundle:<bundle>#<step>:<test ids>: the bundle must be
# sealed, milestone N's, produced_by=integrate (host-integrate or sandbox-integration), dirty=false,
# the step passed, its log matching its sealed sha256 and naming every test id as a whole token.
# --evidence mutation:<line of .milestones/mutations/N.jsonl, 1-based, or its patched_seal>: verdict
# caught, citing the criterion (id, index, "<id or index>: ..." or text), both seals intact.
# --context evaluator:<text> appends reviewer-grade context, never evidence. Exit 2 on a refusal.
#
# approve N <kind> <item...> [--sandbox ID | --ref REF]: refused unless stdin is a terminal; the
# owner types "approve N <kind>" exactly. Kinds: criterion-waiver <N.c<i>...>; weakening <hit kind>
# <path...>; gate-config <path...>; gate-definition (the current definition hash); budget <name...>.
# Blob ids come from --ref, else the unmerged sandbox branch (--sandbox, else the STATUS.md cell),
# else HEAD. One line per item is appended to .milestones/approvals/N.md in the format at
# APPROVAL_LINE_RE, and that file alone is committed; it refuses while the file has uncommitted
# edits. Readers use the committed file and ignore any line not in that exact format.
#
# mutate N <patch> [--ref REF] [--steps name,name] [--sandbox ID], from the host checkout.
# The sandbox is the Sandbox cell of milestone N's STATUS.md row, else --sandbox. In order:
#   1. integrate's candidate checks on agent-sandbox/<id>: its range touches no .milestones/
#      path and no path ignored in the host checkout, and every weakening or gate-config hit
#      is approved in .milestones/approvals/N.md (unapproved_hits, as integrate);
#   2. the patch carries a "# criterion: <exit criterion text or index>" line before its
#      first diff, and changes no GATE_DEFINITION_GLOBS file, no .milestones/ path, no path
#      outside the repository and no file a step, GATE_SETUP or GATE_ENV command names;
#   3. the target: a temporary merge of agent-sandbox/<id> into the integration branch head
#      (INTEGRATION_BRANCH, else the checked-out branch), or into --ref, built in a temporary
#      worktree; the patch must `git apply --check` there and is committed on top. Both
#      commits are held by refs under refs/run-milestones/mutate/ until the run ends;
#   4. the baseline: the selected steps (all, or --steps; setup always runs) on the target,
#      where INTEGRATE_GATE_WHERE says (host-mutate: a temporary worktree; sandbox-mutate: a
#      fresh sandbox of the commit, removed after). It must pass;
#   5. the patched commit, same steps, every step run even after a failure;
#   6. the verdict from the patched bundle: caught (an integration or replay step failed,
#      exit 0), inconclusive (none failed, and one of them was not run, sandbox-only on the
#      host, exit 3), caught-static (only a static step failed, exit 1), missed (exit 1);
#   7. one line appended to .milestones/mutations/N.jsonl: patch, criterion, verdict,
#      failing_step, steps, where, sha and tree (the baseline's), patched_sha, both bundles
#      and seals, definition_hash, at; then grade.py events: control-proof for every
#      verdict, and a finding (stage mutate, executable) when caught.
# Worktrees, refs, sandboxes and ports are removed on every exit path. A refusal, a patch
# that does not apply, a failing baseline or any other error exits 2 and writes no record.
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REPO="$(pwd -P)"

do_init() {
  # Everything the supervisor needs to run a first milestone, never overwriting a file.
  local tpl top src dst line
  tpl="$(dirname "$SELF")/templates"
  (( $# == 0 )) || { echo "init takes no arguments: run-milestones.sh init" >&2; exit 2; }
  [[ -d "$tpl" ]] || { echo "init: no templates/ next to $SELF" >&2; exit 2; }
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
  [[ -n "$top" && "$(cd "$top" && pwd -P)" == "$REPO" ]] \
    || { echo "init: $REPO is not the top level of a git repository; run init from the repository's top level" >&2; exit 2; }
  for line in config:.milestones/config standing-rules.md:.milestones/standing-rules.md STATUS.md:.milestones/STATUS.md \
              ce-config.yaml:.compound-engineering/config.yaml pack-README.md:compound-packs/milestones/README.md; do
    src="$tpl/${line%%:*}"; dst="${line#*:}"
    if [[ -e "$REPO/$dst" ]]; then echo "kept $dst"; continue; fi
    mkdir -p "$(dirname "$REPO/$dst")"
    cp "$src" "$REPO/$dst"
    echo "wrote $dst"
  done
  local gi="$REPO/.gitignore" added=0
  if [[ -s "$gi" && -n "$(tail -c 1 "$gi")" ]]; then echo >> "$gi"; fi   # a last line without a newline stays whole
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    grep -qxF -- "$line" "$gi" 2>/dev/null && continue
    echo "$line" >> "$gi"; added=1
  done < "$tpl/gitignore-lines"
  if (( added )); then echo "wrote .gitignore lines"; else echo "kept .gitignore"; fi
  cat <<'EOF'

Still to fill in before the first launch:
  .milestones/config   MILESTONES_FILE: the path of the file whose "## Milestone N" sections are the briefs
  .milestones/config   GATE: the project's full check; empty, every launch, --gate and integrate refuse
  .milestones/config   SEED_PATHS: the gitignored inputs the gate needs (env file, seeded data), if any
  .milestones/standing-rules.md   the project facts no learning holds yet
  compound-packs/milestones/      one rule file per invariant (see its README)
Then: run-milestones.sh config 1, and run-milestones.sh prompt 1 to read the assembled prompt.
EOF
}
if [[ "${1-}" == init ]]; then shift; do_init "$@"; exit 0; fi

[[ -d "$REPO/.milestones" ]] || { echo "no .milestones/ in $REPO; run from the project root" >&2; exit 2; }
PROJECT="$(basename "$REPO")"
MILESTONES_FILE="docs/spec/11-milestones.md"; REPORT_DIR="docs/reports"   # defaults; .milestones/config overrides
GATE=""; GATE_SETUP=""; GATE_ENV=""; DEPLOY_MILESTONES=""; TIMEOUT="12h"
GATE_TIMEOUT="30m"; GATE_STEPS=(); GATE_PORT_RANGE="20000-29999"; INTEGRATE_GATE_WHERE="host"
# shellcheck disable=SC1091
[[ -f "$REPO/.milestones/config" ]] && source "$REPO/.milestones/config"
# A host's own values (its toolchain's PATH) stay out of the committed config.
# shellcheck disable=SC1091
[[ -f "$REPO/.milestones/config.local" ]] && source "$REPO/.milestones/config.local"
LOGS="$REPO/logs/milestones"; mkdir -p "$LOGS"
CHAIN="$LOGS/chain.log"

# ---------------------------------------------------------------- helpers
log() { echo "$*" | tee -a "$CHAIN"; }

die() { echo "$*" >&2; exit 2; }

to_seconds() {
  # 12h, 90m, 45s or a bare number of seconds.
  local v="$1"
  case "$v" in
    *h) [[ "${v%h}" =~ ^[0-9]+$ ]] && { echo $(( ${v%h} * 3600 )); return; } ;;
    *m) [[ "${v%m}" =~ ^[0-9]+$ ]] && { echo $(( ${v%m} * 60 )); return; } ;;
    *s) [[ "${v%s}" =~ ^[0-9]+$ ]] && { echo "${v%s}"; return; } ;;
    *)  [[ "$v" =~ ^[0-9]+$ ]] && { echo "$v"; return; } ;;
  esac
  die "cannot read timeout '$v' (want 12h, 90m, 45s or seconds)"
}

have_jq() { [[ -z "${RUN_MILESTONES_NO_JQ:-}" ]] && command -v jq >/dev/null 2>&1; }

resolve_override() {
  # KEY_<n>, then KEY, then empty: the fallback every per-milestone key follows.
  local per="$1_$2"
  echo "${!per:-${!1:-}}"
}

resolve_resources() {
  # MEMORY_<n>, CPUS_<n>; then MEMORY, CPUS; then nothing (agent-sandbox's config).
  # MODEL_<n>, EFFORT_<n>; then MODEL, EFFORT; then nothing (claude's session default).
  # The agent's model and effort are per milestone because the stages differ in
  # what they need: a plan or a review earns a strong model, a docs or a
  # measurement milestone does not.
  local n="$1" mem cpus model effort
  mem="$(resolve_override MEMORY "$n")"; cpus="$(resolve_override CPUS "$n")"
  model="$(resolve_override MODEL "$n")"; effort="$(resolve_override EFFORT "$n")"
  RES=(); AGENT_OPTS=()
  [[ -n "$mem" ]] && RES+=(--memory "$mem")
  [[ -n "$cpus" ]] && RES+=(--cpus "$cpus")
  [[ -n "$model" ]] && AGENT_OPTS+=(--model "$model")
  [[ -n "$effort" ]] && AGENT_OPTS+=(--effort "$effort")
  return 0   # an empty last test must not fail the call under set -e
}

json_from() {
  # The JSON object agent-sandbox printed to stdout, from a log that may hold other
  # lines before it (admission's effective-numbers lines, image notices).
  sed -n '/^{/,$p' "$1"
}

refusal_reasons() {
  # "message; reason; reason. remedy" from an exit-3 admission payload in a log file.
  local out
  if have_jq; then
    out="$(json_from "$1" | jq -r '([.message // empty] + (.reasons // []) | join("; ")) + (if .remedy then ". " + (.remedy|tostring) else "" end)' 2>/dev/null || true)"
  else
    out="$(json_from "$1" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
s = "; ".join([x for x in [d.get("message")] + list(d.get("reasons") or []) if x])
if d.get("remedy"): s += ". " + str(d["remedy"])
print(s)' 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] && { echo "$out"; return; }
  tail -n 5 "$1" | tr '\n' ' '
}

json_field() {
  # A string field (dotted path, e.g. logs.stdout) of a run/enter --json result in a
  # log file; empty when absent or unreadable.
  if have_jq; then
    json_from "$1" | jq -r --arg p "$2" 'getpath($p | split(".")) // empty' 2>/dev/null || true
  else
    json_from "$1" | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin)
    for k in sys.argv[1].split("."): v = v.get(k) if isinstance(v, dict) else None
    print(v if v is not None else "")
except Exception: pass' "$2" 2>/dev/null || true
  fi
}

json_sandbox_id() { json_field "$1" sandbox_id; }   # empty when absent

admission_kind() {
  # "refused" or "timeout" when the log holds agent-sandbox's exit-3 admission payload,
  # whose `admission` is a string; empty otherwise. A run record's `admission` is an
  # object (the decision that admitted it), and a command of its own may exit 3.
  if have_jq; then
    json_from "$1" | jq -r '.admission | strings' 2>/dev/null || true
  else
    json_from "$1" | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin).get("admission")
    if isinstance(v, str): print(v)
except Exception: pass' 2>/dev/null || true
  fi
}

resolve_lane() {
  # LANE_<n>, then main. The value becomes an agent-sandbox tag, so keep it a plain word.
  local v="LANE_$1" lane
  lane="${!v:-main}"
  [[ "$lane" =~ ^[A-Za-z0-9_.-]+$ ]] || die "LANE_$1='$lane': a lane is letters, digits, _ . or -"
  echo "$lane"
}

require_gate() {
  # No default gate: a language-specific guess would pass or fail for the wrong reason.
  [[ -n "$GATE" || ${#GATE_STEPS[@]} -gt 0 ]] || die "no GATE in $REPO/.milestones/config: set GATE to the project's check command, or GATE_STEPS to its labeled steps (and GATE_SETUP if derived state must be rebuilt first)"
  load_gate_steps
}

# ---------------------------------------------------------------- gate runner
# The effective step list, parallel arrays: kind, name, command, "sandbox-only" or empty.
ST_KIND=(); ST_NAME=(); ST_CMD=(); ST_ONLY=()

add_gate_step() {
  local kind="$1" name="$2" cmd="$3" only="$4" seen
  [[ "$kind" == integration || "$kind" == replay || "$kind" == static ]] \
    || die "gate step '$name': kind '$kind' is not integration, replay or static"
  [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || die "gate step name '$name': letters, digits, _ . or -"
  [[ "$cmd" =~ [^[:space:]] ]] || die "gate step '$name' has no command"
  for seen in "${ST_NAME[@]}"; do
    [[ "$seen" != "$name" ]] || die "gate step name '$name' appears twice (GATE_SETUP is the step named setup)"
  done
  ST_KIND+=("$kind"); ST_NAME+=("$name"); ST_CMD+=("$cmd"); ST_ONLY+=("$only")
}

load_gate_steps() {
  # GATE_SETUP as step `setup`, then GATE_STEPS, or GATE as one static step named `gate`.
  local e kind rest name cmd only
  ST_KIND=(); ST_NAME=(); ST_CMD=(); ST_ONLY=()
  [[ -z "$GATE" || ${#GATE_STEPS[@]} -eq 0 ]] || die "set GATE or GATE_STEPS in .milestones/config, not both"
  [[ -z "$GATE_SETUP" ]] || add_gate_step static setup "$GATE_SETUP" ""
  if (( ${#GATE_STEPS[@]} )); then
    for e in "${GATE_STEPS[@]}"; do
      [[ "$e" == *"|"*"|"* ]] || die "GATE_STEPS entry '$e': want kind|name|command[|sandbox-only]"
      kind="${e%%|*}"; rest="${e#*|}"; name="${rest%%|*}"; cmd="${rest#*|}"; only=""
      if [[ "$cmd" == *"|sandbox-only" ]]; then cmd="${cmd%|sandbox-only}"; only=sandbox-only; fi
      add_gate_step "$kind" "$name" "$cmd" "$only"
    done
  else
    add_gate_step static gate "$GATE" ""
  fi
}

gate_definition_hash() {
  # sha256 over what decides a run's verdict: the effective steps, GATE_SETUP, GATE_ENV,
  # .milestones/config and config.local as files, this driver, and the MAX_* budget keys.
  local k f v
  {
    printf 'steps\0'
    for k in "${!ST_NAME[@]}"; do printf '%s|%s|%s|%s\0' "${ST_KIND[k]}" "${ST_NAME[k]}" "${ST_CMD[k]}" "${ST_ONLY[k]}"; done
    printf 'setup\0%s\0env\0%s\0' "$GATE_SETUP" "$GATE_ENV"
    for f in config config.local; do
      printf '%s\0' "$f"
      if [[ -f "$REPO/.milestones/$f" ]]; then cat "$REPO/.milestones/$f"; else printf 'absent'; fi
      printf '\0'
    done
    printf 'driver\0'; cat "$SELF"; printf '\0budgets\0'
    for v in $(compgen -v MAX_ | LC_ALL=C sort); do printf '%s=%s\0' "$v" "${!v}"; done
  } | sha256sum | cut -d' ' -f1
}

file_size() { if [[ -f "$1" ]]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }

# ---- ports: a host gate run's GATE_PORT_1..4
PORTS=(); PORT_TOKEN=""; PORT_WHY=""
free_ports() {
  # free_ports <count> <candidate>...: the first <count> candidates nothing is bound to, by a
  # bind on every address (IPv4 and IPv6); /dev/tcp connects when python3 is absent.
  local want="$1" p free=()
  shift
  if command -v python3 > /dev/null 2>&1; then
    python3 -c '
import errno, socket, sys
want, out = int(sys.argv[1]), []
for a in sys.argv[2:]:
    busy = False
    for fam, host in ((socket.AF_INET, "0.0.0.0"), (socket.AF_INET6, "::")):
        try:
            s = socket.socket(fam, socket.SOCK_STREAM)
        except OSError:
            continue
        try:
            if fam == socket.AF_INET6:
                s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            s.bind((host, int(a)))
        except OSError as e:
            busy = e.errno in (errno.EADDRINUSE, errno.EACCES)
        finally:
            s.close()
        if busy:
            break
    if not busy:
        out.append(a)
        if len(out) == want:
            break
print(" ".join(out))' "$want" "$@"
    return
  fi
  for p in "$@"; do
    (exec 3<> "/dev/tcp/127.0.0.1/$p") 2> /dev/null && continue
    free+=("$p"); (( ${#free[@]} < want )) || break
  done
  echo "${free[*]}"
}

alloc_ports() {
  # Four ports into PORTS, under an flock on logs/milestones/ports.registry: a port is taken
  # only when no live run has it registered and nothing is bound to it, and it stays
  # registered until release_ports, because an app binds it minutes later. Registry lines:
  # "<port> <token> <pid> <at>"; a line whose pid is gone is pruned.
  local token="$1" reg="$LOGS/ports.registry" lo hi fd p tok pid at span start i got
  PORT_WHY=""
  local keep=() cands=() held=" " inrange=() busy=() pruned=0 eph why
  if [[ ! "$GATE_PORT_RANGE" =~ ^([0-9]+)-([0-9]+)$ ]]; then PORT_WHY="GATE_PORT_RANGE='$GATE_PORT_RANGE': want <low>-<high>"; log "$PORT_WHY"; return 1; fi
  lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
  if (( lo < 1024 || hi > 65535 || hi - lo < 3 )); then PORT_WHY="GATE_PORT_RANGE=$GATE_PORT_RANGE: want four or more ports within 1024-65535"; log "$PORT_WHY"; return 1; fi
  exec {fd}>> "$reg.lock"
  if ! flock -w 60 "$fd"; then exec {fd}>&-; PORT_WHY="could not lock $reg within 60s"; log "$PORT_WHY"; return 1; fi
  if [[ -f "$reg" ]]; then
    while read -r p tok pid at; do
      if [[ ! "$p" =~ ^[0-9]+$ || ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2> /dev/null; then pruned=$(( pruned + 1 )); continue; fi
      keep+=("$p $tok $pid $at"); held+="$p "
      (( p < lo || p > hi )) || inrange+=("$p")
    done < "$reg"
  fi
  span=$(( hi - lo + 1 )); start=$(( RANDOM % span ))
  for (( i = 0; i < span; i++ )); do
    p=$(( lo + (start + i) % span ))
    [[ "$held" == *" $p "* ]] || cands+=("$p")
  done
  got=""; (( ${#cands[@]} )) && got="$(free_ports 4 "${cands[@]}")"
  read -r -a PORTS <<< "$got"
  if (( ${#PORTS[@]} < 4 )); then
    # Say why, port by port: fewer than four were found, so every candidate was probed.
    for p in "${cands[@]}"; do [[ " $got " == *" $p "* ]] || busy+=("$p"); done
    why="no four free, unregistered ports in GATE_PORT_RANGE=$GATE_PORT_RANGE ($span ports):"
    why+=" registered to live runs in $reg: $(( ${#inrange[@]} ))${inrange[*]:+ ($(printf '%s\n' "${inrange[@]}" | sort -n | tr '\n' ' ' | sed 's/ $//'))};"
    why+=" in use on this host (a listener, a connection or TIME_WAIT): ${#busy[@]}${busy[*]:+ ($(printf '%s\n' "${busy[@]}" | sort -n | tr '\n' ' ' | sed 's/ $//'))};"
    why+=" free: ${got:-none}; dead registrations pruned: $pruned"
    eph="$(cat /proc/sys/net/ipv4/ip_local_port_range 2> /dev/null | tr -s ' \t' '-' || true)"
    if [[ "$eph" =~ ^([0-9]+)-([0-9]+)$ ]] && (( lo <= BASH_REMATCH[2] && hi >= BASH_REMATCH[1] )); then
      why+="; the range overlaps the kernel's ephemeral range $eph, where outbound connections take ports: pick one outside it"
    fi
    PORTS=(); exec {fd}>&-
    PORT_WHY="$why"; log "$why"; return 1
  fi
  at="$(date -Is)"
  { if (( ${#keep[@]} )); then printf '%s\n' "${keep[@]}"; fi
    for p in "${PORTS[@]}"; do echo "$p $token $$ $at"; done; } > "$reg.$$"
  mv -f "$reg.$$" "$reg"
  PORT_TOKEN="$token"
  exec {fd}>&-
}

release_ports() {
  [[ -n "$PORT_TOKEN" ]] || return 0
  local reg="$LOGS/ports.registry" tok="$PORT_TOKEN" fd
  PORT_TOKEN=""; PORTS=()
  exec {fd}>> "$reg.lock"
  flock -w 60 "$fd" || true
  if [[ -f "$reg" ]]; then awk -v t="$tok" '$2 != t' "$reg" > "$reg.$$" && mv -f "$reg.$$" "$reg"; fi
  exec {fd}>&-
}

# ---- cleanup on every exit path of a gate run
GATE_TMP=""; INTEGRATE_TREE=""; GATE_SANDBOX_CREATED=""; MUTATE_TMP=""; MUTATE_REFS=()
on_exit() {
  release_ports
  [[ -z "$GATE_TMP" ]] || rm -rf "$GATE_TMP" 2> /dev/null || true
  GATE_TMP=""
  integrate_cleanup
  remove_gate_sandbox
  mutate_cleanup
}
arm_cleanup() { trap on_exit EXIT; trap 'exit 130' INT TERM; }

integrate_cleanup() {
  # Remove the temporary worktree on every exit path.
  [[ -n "$INTEGRATE_TREE" ]] || return 0
  git -C "$REPO" worktree remove --force "$INTEGRATE_TREE/tree" > /dev/null 2>&1 || true
  rm -rf "$INTEGRATE_TREE"
  git -C "$REPO" worktree prune > /dev/null 2>&1 || true
  INTEGRATE_TREE=""
}

remove_gate_sandbox() {
  # agent-sandbox rm for the integration sandbox this run created, and only that one:
  # GATE_SANDBOX_CREATED is set only after the id read back from `run --new` passed the id
  # rule, and the rule is checked again here. --force: the sandbox holds no work (its HEAD
  # is the merge commit already on the host branch), only what the steps left in its tree.
  local id="$GATE_SANDBOX_CREATED" rc=0
  [[ -n "$id" ]] || return 0
  GATE_SANDBOX_CREATED=""
  if [[ ! "$id" =~ $SANDBOX_ID_RE || "$id" == *..* ]]; then log "  integration sandbox id '$id' fails the id rule; not removed"; return 0; fi
  agent-sandbox rm "$id" --force > "$LOGS/integrate-rm-$id.log" 2>&1 || rc=$?
  if (( rc )); then log "  could not remove integration sandbox $id (exit $rc, see $LOGS/integrate-rm-$id.log)"
  else log "  removed integration sandbox $id"; fi
}

# ---- identity and dirt, read on the host before any step
DIRTY_TRACKED=1; DIRTY_UNTRACKED=1
gate_dirty() {
  # gate_dirty <dir> <bundle> <sha>: dirty.patch (tracked changes and untracked files, one
  # patch that applies to <sha>) and untracked.txt. Ignored files and SEED_PATHS never enter
  # either. Returns non-zero on a git error, leaving both flags dirty.
  local dir="$1" b="$2" sha="$3" idx="$GATE_TMP/dirty.index" z="$GATE_TMP/untracked.z" p rc=0
  local ex=()
  DIRTY_TRACKED=1; DIRTY_UNTRACKED=1
  local -
  set -f
  for p in ${SEED_PATHS:-}; do
    [[ "$p" == /* || "/$p/" == */../* ]] || ex+=(":(top,exclude)${p%/}")
  done
  set +f
  : > "$b/dirty.patch"; : > "$b/untracked.txt"
  git -C "$dir" ls-files --others --exclude-standard -z -- . "${ex[@]}" > "$z" || return 1
  tr '\0' '\n' < "$z" > "$b/untracked.txt"
  GIT_INDEX_FILE="$idx" git -C "$dir" read-tree "$sha" || return 1
  if [[ -s "$z" ]]; then
    GIT_INDEX_FILE="$idx" GIT_LITERAL_PATHSPECS=1 git -C "$dir" add -N --pathspec-from-file="$z" --pathspec-file-nul || return 1
  fi
  GIT_INDEX_FILE="$idx" git -C "$dir" -c core.quotePath=false diff --binary --no-color --no-ext-diff --no-renames "$sha" -- . "${ex[@]}" > "$b/dirty.patch" || return 1
  git -C "$dir" diff --quiet --no-ext-diff "$sha" -- . "${ex[@]}" || rc=$?
  (( rc <= 1 )) || return 1
  DIRTY_TRACKED="$rc"; DIRTY_UNTRACKED=0
  [[ ! -s "$z" ]] || DIRTY_UNTRACKED=1
}

seed_kept_of() {
  # The seed_kept paths of an agent-sandbox run.json: seeded files the run changed, which
  # the sandbox kept instead of refreshing from the host. One per line.
  [[ -f "$1" ]] || return 0
  if have_jq; then jq -r '(.seed_kept // [])[] | strings' "$1" 2> /dev/null || true
  else python3 -c '
import json, sys
try:
    for p in json.load(open(sys.argv[1])).get("seed_kept") or []:
        if isinstance(p, str): print(p)
except Exception: pass' "$1" 2> /dev/null || true
  fi
}

# ---- one invocation
host_step_script() { printf 'set -o pipefail\n%s\n' "$1"; }

sandbox_step_script() {
  # Each enter is a fresh container: its own ports and /tmp, so any values work.
  # shellcheck disable=SC2016
  printf 'set -o pipefail\nexport GATE_PORT_1=20001 GATE_PORT_2=20002 GATE_PORT_3=20003 GATE_PORT_4=20004\nTMPDIR="$(mktemp -d)" && export TMPDIR\n(\n%s\n)\n__gate_rc=$?\nrm -rf "$TMPDIR"\nexit "$__gate_rc"\n' "$1"
}

SB_STDOUT=""; SB_RUNDIR=""
gate_invoke() {
  # gate_invoke host <dir> <script> <log> <seconds>
  # gate_invoke sandbox <id> <script> <log> <seconds>
  # Returns the invocation's exit code, read from the driver's own wait (host) or from that
  # invocation's own `enter` (sandbox, whose container output is sliced back into <log>
  # from the sandbox's stdout.log and stderr.log).
  local route="$1" target="$2" script="$3" out="$4" secs="$5" rc=0
  if [[ "$route" == host ]]; then
    (cd "$target" && TMPDIR="$GATE_TMP/tmp" GATE_PORT_1="${PORTS[0]}" GATE_PORT_2="${PORTS[1]}" \
      GATE_PORT_3="${PORTS[2]}" GATE_PORT_4="${PORTS[3]}" timeout "${secs}s" bash -c "$script") > "$out" 2>&1 < /dev/null || rc=$?
    return "$rc"
  fi
  local so se o0 e0 jo res="${out%.log}.enter.json"
  so="${SB_STDOUT:-${AGENT_SANDBOX_HOME:-$HOME/agent-sandbox}/runs/$target/stdout.log}"; se="$(dirname "$so")/stderr.log"
  o0="$(file_size "$so")"; e0="$(file_size "$se")"
  sandbox_call "$res" enter "$target" --timeout "${secs}s" "${RES[@]}" "${TAGS[@]}" --json -- bash -lc "$script" || rc=$?
  jo="$(json_field "$res" logs.stdout)"
  if [[ -n "$jo" ]]; then
    [[ "$jo" == "$so" ]] || { o0=0; e0=0; }
    so="$jo"; se="$(json_field "$res" logs.stderr)"; se="${se:-$(dirname "$so")/stderr.log}"
    SB_STDOUT="$jo"; SB_RUNDIR="$(json_field "$res" logs.dir)"
  fi
  { log_segment "$so" "$o0" "$(file_size "$so")"
    if (( $(file_size "$se") > e0 )); then echo "--- stderr"; log_segment "$se" "$e0" "$(file_size "$se")"; fi
  } > "$out" 2> /dev/null || true
  return "$rc"
}

write_evidence() {
  # write_evidence <file> key=value... -- <kind name command flag status exit ms log>...
  # Writes evidence.json and prints the kind counts for the evidence line.
  python3 - "$@" <<'PY'
import hashlib, json, os, sys
a = sys.argv[1:]
path = a.pop(0)
cut = a.index("--")
h = dict(x.split("=", 1) for x in a[:cut])
r = a[cut + 1:]
steps = []
for i in range(0, len(r), 8):
    kind, name, cmd, flag, status, ex, ms, log = r[i:i + 8]
    lp = os.path.join(os.path.dirname(path), log) if log else ""
    # The step log's sha256 is sealed with evidence.json, so a line added to the log later shows.
    lsha = hashlib.sha256(open(lp, "rb").read()).hexdigest() if lp and os.path.isfile(lp) else None
    steps.append({"index": i // 8 + 1, "name": name, "kind": kind, "command": cmd,
                  "sandbox_only": flag == "sandbox-only", "status": status,
                  "exit": int(ex) if ex else None, "duration_ms": int(ms) if ms else None,
                  "log": log or None, "log_sha256": lsha})
counts = {}
for k in ("integration", "replay", "static"):
    mine = [s for s in steps if s["kind"] == k]
    counts[k] = {"passed": sum(s["status"] == "pass" for s in mine), "total": len(mine)}
counts["skipped_sandbox_only"] = sum(s["status"] == "not run: sandbox-only" for s in steps)
doc = {
    "schema": 1,
    "milestone": h["milestone"], "where": h["where"],
    "verdict": "pass" if h["exit"] == "0" else "fail", "exit": int(h["exit"]),
    "failed_step": h["failed_step"] or None,
    "sha": h["sha"], "tree": h["tree"], "definition_hash": h["definition_hash"],
    "dirty": h["dirty"] == "yes", "dirty_tracked": h["dirty_tracked"] == "1",
    "dirty_untracked": h["dirty_untracked"] == "1",
    "seed_kept": [p for p in h["seed_kept"].split("\n") if p],
    "dirty_patch": "dirty.patch", "untracked": "untracked.txt",
    "sandbox": h["sandbox"] or None, "setup": h["setup"], "env": h["env"],
    "report": h["report"] or None, "timeout": h["timeout"],
    "ports": [int(p) for p in h["ports"].split()],
    "produced_by": h["produced_by"],
    "selected": [x for x in h["selected"].split(",") if x] or None,
    "keep_going": h["keep_going"] == "1",
    "driver": h["driver"], "started_at": h["started_at"], "finished_at": h["finished_at"],
    "counts": counts, "steps": steps,
}
with open(path, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
print(" ".join("%s:%d/%d" % (k, counts[k]["passed"], counts[k]["total"]) for k in ("integration", "replay", "static"))
      + " skipped:sandbox-only:%d" % counts["skipped_sandbox_only"])
PY
}

# ---- one gate run
GATE_RC=0; GATE_BUNDLE=""; GATE_FAILED_STEP=""; GATE_COUNTS=""; GATE_TREE=""; GATE_DEF=""; GATE_ADMISSION=0
# GATE_NOSTART: why the last gate run wrote no bundle (empty when it wrote one). Every such
# path also logs that reason to chain.log.
GATE_NOSTART=""
gate_nostart() { GATE_NOSTART="$1"; log "milestone $2: gate could not start: $1; no gate step ran"; }
# Set by a caller for its next gate_run: GATE_SELECT holds step names (space separated; empty
# runs every step, and setup always runs), the rest are recorded "not run: not selected".
# GATE_KEEP_GOING=1 runs the later steps after a failure (mutate's patched run needs to
# know which kinds fail), stopping only at an admission refusal or a spent GATE_TIMEOUT.
GATE_SELECT=""; GATE_KEEP_GOING=0
gate_run() {
  # gate_run <where> <milestone> <dir> <sha> [sandbox-id]
  #   where: sandbox (a milestone's own sandbox, whose report must exist), host-integrate,
  #   sandbox-integration, local, host-mutate, sandbox-mutate. <dir> is the gated worktree as
  #   the host sees it. evidence.json's produced_by follows where: sandbox -> gate,
  #   *-integrate/*-integration -> integrate, local -> check, *-mutate -> mutate.
  # Returns GATE_RC: 0, or the failing step's exit. Returns 1 with no bundle when the run
  # could not start (unreadable tree, no ports), with the reason in GATE_NOSTART and chain.log.
  # Sets GATE_BUNDLE, GATE_FAILED_STEP,
  # GATE_COUNTS, GATE_TREE, GATE_DEF and GATE_ADMISSION (a step enter not admitted).
  local where="$1" n="$2" dir="$3" sha="$4" sb="${5:-}" route=host target="$3" produced_by
  case "$where" in sandbox|sandbox-integration|sandbox-mutate) route=sandbox; target="$sb" ;; esac
  case "$where" in
    sandbox) produced_by=gate ;;
    host-integrate|sandbox-integration) produced_by=integrate ;;
    local) produced_by=check ;;
    host-mutate|sandbox-mutate) produced_by=mutate ;;
    *) gate_nostart "unknown gate location '$where'" "$n"; return 1 ;;
  esac
  GATE_RC=0; GATE_BUNDLE=""; GATE_FAILED_STEP=""; GATE_COUNTS=""; GATE_ADMISSION=0; SB_STDOUT=""; SB_RUNDIR=""; GATE_NOSTART=""
  arm_cleanup
  GATE_TREE="$(git -C "$dir" rev-parse --verify -q "$sha^{tree}" 2> /dev/null)" \
    || { gate_nostart "cannot read the tree of ${sha:0:12} in $dir" "$n"; return 1; }
  GATE_DEF="$(gate_definition_hash)"
  local stamp b i=1
  stamp="$(date +%Y%m%dT%H%M%S)"; mkdir -p "$LOGS/evidence"
  b="$LOGS/evidence/$n-$where-$stamp"
  until mkdir "$b" 2> /dev/null; do
    i=$(( i + 1 )); b="$LOGS/evidence/$n-$where-$stamp.$i"
    (( i < 100 )) || { gate_nostart "cannot create an evidence directory under $LOGS/evidence" "$n"; return 1; }
  done
  if ! mkdir -p "$b/steps" || ! GATE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/gate-$PROJECT-$n.XXXXXX")" || ! mkdir -p "$GATE_TMP/tmp"; then
    rm -rf "$b"; gate_nostart "cannot create the bundle's steps/ or a temporary directory under ${TMPDIR:-/tmp}" "$n"; return 1
  fi
  if [[ "$route" == host ]] && ! alloc_ports "$(basename "$b")"; then
    rm -rf "$b"; gate_nostart "no ports: ${PORT_WHY:-alloc_ports failed without a reason}" "$n"; return 1
  fi
  GATE_BUNDLE="$b"

  local started seed_kept="" seed_read=0 dirty=no env="-" probed=0 total deadline rem k rc t0 report="" halt=0
  local s_status=() s_exit=() s_ms=() s_log=()
  started="$(date -Is)"
  gate_dirty "$dir" "$b" "$sha" || log "  could not read the dirt of $dir; the bundle counts as dirty"
  [[ -z "$GATE_ENV" ]] || env="unavailable"
  total="$(to_seconds "$GATE_TIMEOUT")"; deadline=$(( SECONDS + total ))
  for k in "${!ST_NAME[@]}"; do
    s_log[k]=""; s_exit[k]=""; s_ms[k]=""
    if (( GATE_RC )) && [[ "$GATE_KEEP_GOING" != 1 || "$halt" == 1 ]]; then
      s_status[k]="not run"; continue
    fi
    if [[ -n "$GATE_SELECT" && "${ST_NAME[k]}" != setup && " $GATE_SELECT " != *" ${ST_NAME[k]} "* ]]; then
      s_status[k]="not run: not selected"; continue
    fi
    # The GATE_ENV probe: once, after setup, before the first other step. Not a step.
    if [[ -n "$GATE_ENV" && "$probed" == 0 && "${ST_NAME[k]}" != setup ]]; then
      probed=1; rem=$(( deadline - SECONDS ))
      if (( rem > 0 )); then
        ADMISSION_REFUSED=0
        gate_invoke "$route" "$target" "$(printf '{\n%s\n} 2>/dev/null | head -n 1' "$GATE_ENV")" "$b/steps/env.log" "$rem" || true
        (( ADMISSION_REFUSED )) || env="$(head -n 1 "$b/steps/env.log" 2> /dev/null || true)"
        if [[ "$route" == sandbox && "$seed_read" == 0 ]]; then seed_read=1; seed_kept="$(seed_kept_of "$SB_RUNDIR/run.json")"; fi
      fi
    fi
    if [[ "$route" == host && "${ST_ONLY[k]}" == sandbox-only ]]; then s_status[k]="not run: sandbox-only"; continue; fi
    s_log[k]="steps/$(( k + 1 ))-${ST_NAME[k]}.log"
    rem=$(( deadline - SECONDS )); rc=0; t0="${EPOCHREALTIME//[.,]/}"
    if (( rem <= 0 )); then
      rc=124; echo "not started: GATE_TIMEOUT $GATE_TIMEOUT was spent" > "$b/${s_log[k]}"
    elif [[ "$route" == host ]]; then
      gate_invoke host "$dir" "$(host_step_script "${ST_CMD[k]}")" "$b/${s_log[k]}" "$rem" || rc=$?
    else
      gate_invoke sandbox "$sb" "$(sandbox_step_script "${ST_CMD[k]}")" "$b/${s_log[k]}" "$rem" || rc=$?
      if [[ "$seed_read" == 0 ]]; then seed_read=1; seed_kept="$(seed_kept_of "$SB_RUNDIR/run.json")"; fi
    fi
    s_ms[k]=$(( (${EPOCHREALTIME//[.,]/} - t0) / 1000 )); s_exit[k]="$rc"
    if (( rc == 0 )); then s_status[k]=pass; continue; fi
    s_status[k]=fail
    if [[ "$route" == sandbox ]] && (( rc == 3 && ADMISSION_REFUSED )); then s_status[k]="not admitted"; GATE_ADMISSION=1; halt=1; fi
    (( rc != 124 )) || halt=1
    if (( ! GATE_RC )); then GATE_RC="$rc"; GATE_FAILED_STEP="${ST_NAME[k]}"; fi
  done
  if [[ "$where" == sandbox ]]; then
    # The milestone's report, read on the host after the steps.
    report=missing; [[ ! -s "$dir/$REPORT_DIR/milestone-$n.md" ]] || report=present
    if (( GATE_RC == 0 )) && [[ "$report" == missing ]]; then GATE_RC=1; GATE_FAILED_STEP=report; fi
  fi
  [[ "$DIRTY_TRACKED" == 0 && "$DIRTY_UNTRACKED" == 0 && -z "$seed_kept" ]] || dirty=yes

  local args=() setup=none result=FAIL rel="${b#"$REPO"/}" seal line
  for k in "${!ST_NAME[@]}"; do
    args+=("${ST_KIND[k]}" "${ST_NAME[k]}" "${ST_CMD[k]}" "${ST_ONLY[k]}" "${s_status[k]}" "${s_exit[k]}" "${s_ms[k]}" "${s_log[k]}")
  done
  [[ -z "$GATE_SETUP" ]] || setup=yes
  if ! GATE_COUNTS="$(write_evidence "$b/evidence.json" milestone="$n" where="$where" exit="$GATE_RC" \
      failed_step="$GATE_FAILED_STEP" sha="$sha" tree="$GATE_TREE" definition_hash="$GATE_DEF" dirty="$dirty" \
      dirty_tracked="$DIRTY_TRACKED" dirty_untracked="$DIRTY_UNTRACKED" seed_kept="$seed_kept" sandbox="$sb" \
      setup="$setup" env="$env" report="$report" timeout="$GATE_TIMEOUT" ports="${PORTS[*]}" driver="$SELF" \
      produced_by="$produced_by" selected="${GATE_SELECT// /,}" keep_going="$GATE_KEEP_GOING" \
      started_at="$started" finished_at="$(date -Is)" -- "${args[@]}")" || [[ ! -s "$b/evidence.json" ]]; then
    log "milestone $n: could not write $b/evidence.json (python3); the gate counts as failed"
    (( GATE_RC )) || GATE_RC=1
    release_ports
    return "$GATE_RC"
  fi
  (( GATE_RC )) || result=pass
  env="${env//\"/\'}"   # keep the quoted field one field
  seal="$(sha256sum "$b/evidence.json" | cut -d' ' -f1)"
  line="gate $result exit=$GATE_RC milestone=$n sha=${sha:0:12} tree=${GATE_TREE:0:12} def=${GATE_DEF:0:12} dirty=$dirty where=$where setup=$setup steps=$GATE_COUNTS env=\"$env\" evidence=$rel at=$(date -Is)"
  echo "$line" >> "$LOGS/milestone-$n.gate.log"
  log "$line"
  log "seal $seal $rel"
  release_ports
  rm -rf "$GATE_TMP" 2> /dev/null || true
  GATE_TMP=""
  return "$GATE_RC"
}

seal_of() {
  # The seal chain.log holds for <bundle> (absolute, or relative to the project): the sha256
  # of its "seal <sha256> <bundle>" line. Empty unless exactly one such line exists, so an
  # extra line appended by anything but the run that sealed it voids the seal.
  local rel="${1#"$REPO"/}"
  rel="${rel%/}"
  [[ -f "$CHAIN" ]] || return 0
  awk -v b="$rel" '$1 == "seal" && $3 == b && NF == 3 { s = $2; c++ } END { if (c == 1) print s }' "$CHAIN"
}

bundle_sealed() {
  # True when <bundle>/evidence.json's sha256 equals its seal in chain.log now.
  local rel="${1#"$REPO"/}" want have
  rel="${rel%/}"
  want="$(seal_of "$rel")"
  [[ -n "$want" && -f "$REPO/$rel/evidence.json" ]] || return 1
  have="$(sha256sum "$REPO/$rel/evidence.json" | cut -d' ' -f1)"
  [[ "$have" == "$want" ]]
}

lane_blocker() {
  # The first STATUS.md row, other than milestone <n>, in lane <lane> whose Merged cell
  # is empty or "-": "<milestone> <sandbox>". Nothing when the file or such a row is absent.
  # Columns: | Milestone | Lane | Sandbox | Merged | Gate | Unmet criteria | Open blockers | Next action |
  local f="$REPO/.milestones/STATUS.md"
  [[ -f "$f" ]] || return 0
  awk -F'|' -v n="$1" -v lane="$2" '
    function t(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^[ \t]*\|/ {
      m = t($2); if (m !~ /^[0-9]+$/ || m == n) next
      l = t($3); if (l == "") l = "main"
      g = t($5); if (l == lane && (g == "" || g == "-")) { print m, (t($4) == "" ? "-" : t($4)); exit }
    }' "$f"
}

ADMISSION_REFUSED=0
sandbox_call() {
  # agent-sandbox <args...> with stdout+stderr in <logfile>. Returns its exit code. An
  # admission refusal (exit 3 with the admission payload) sets ADMISSION_REFUSED=1 and is
  # written to chain.log with its reasons; an exit 3 without that payload is the
  # command's own exit and leaves ADMISSION_REFUSED=0.
  local logfile="$1"; shift
  local rc=0
  ADMISSION_REFUSED=0
  agent-sandbox "$@" >"$logfile" 2>&1 || rc=$?
  if (( rc == 3 )) && [[ -n "$(admission_kind "$logfile")" ]]; then
    ADMISSION_REFUSED=1
    log "admission refused ($(date -Is)): $(refusal_reasons "$logfile")"
    log "  payload: $logfile"
  fi
  return $rc
}

# ---------------------------------------------------------------- arguments
MUTATE_PATCH=""; MUTATE_REF=""; MUTATE_STEPS=""; MUTATE_EXIT=2
ACCEPT_INIT=0; ACCEPT_FORCE=0; ACCEPT_CRITERION=""; ACCEPT_EVIDENCE=""; ACCEPT_CONTEXT=""
APPROVE_KIND=""; APPROVE_ITEMS=()
VERB=""; INTEGRATE_ID=""; SANDBOX=""; DEPLOY=0; NOTE=""; CONTINUE=""; INSIDE=""; UNIT=""; GATE_ONLY=0; ISSUE=0
MILESTONES=(); RES=(); TAGS=(); AGENT_OPTS=()
while (($#)); do
  case "$1" in
    status|resume|config|prompt) VERB="$1"; shift ;;
    init) die "init takes no other arguments: run-milestones.sh init" ;;
    integrate) VERB=integrate; shift; INTEGRATE_ID="${1-}"; if (($#)); then shift; fi ;;   # the next argument is the id
    accept) VERB=accept; shift
            if (($#)) && [[ "$1" =~ ^[0-9]+$ ]]; then MILESTONES+=("$1"); shift; fi ;;
    approve) VERB=approve; shift   # approve N <kind> <item...>: items may start with a digit (7.c1)
            if (($#)) && [[ "$1" =~ ^[0-9]+$ ]]; then MILESTONES+=("$1"); shift; fi
            if (($#)) && [[ "$1" != --* ]]; then APPROVE_KIND="$1"; shift; fi
            while (($#)) && [[ "$1" != --* ]]; do APPROVE_ITEMS+=("$1"); shift; done ;;
    --init) ACCEPT_INIT=1; shift ;;
    --force) ACCEPT_FORCE=1; shift ;;
    --criterion|--evidence|--context) (($# >= 2)) || die "$1 needs a value"
            case "$1" in --criterion) ACCEPT_CRITERION="$2" ;; --evidence) ACCEPT_EVIDENCE="$2" ;; *) ACCEPT_CONTEXT="$2" ;; esac
            shift 2 ;;
    mutate) VERB=mutate; shift   # mutate N <patch>: the patch path may start with a digit
            if (($#)) && [[ "$1" =~ ^[0-9]+$ ]]; then MILESTONES+=("$1"); shift; fi
            if (($#)) && [[ "$1" != --* ]]; then MUTATE_PATCH="$1"; shift; fi ;;
    --ref|--steps) (($# >= 2)) || die "$1 needs a value"
            if [[ "$1" == --ref ]]; then MUTATE_REF="$2"; else MUTATE_STEPS="$2"; fi; shift 2 ;;
    --sandbox) SANDBOX="$2"; shift 2 ;;
    --deploy) DEPLOY=1; shift ;;
    --note) NOTE="$2"; shift 2 ;;
    --continue) CONTINUE="$2"; shift 2 ;;
    --gate) GATE_ONLY=1; shift ;;
    --issue) ISSUE=1; shift ;;
    --inside) INSIDE="$2"; shift 2 ;;          # the unit's body: milestone turn, then the gate
    --unit) UNIT="$2"; shift 2 ;;              # (inside) the systemd unit this body runs under
    --memory|--cpus) RES+=("$1" "$2"); shift 2 ;;   # (inside) resolved by the launcher
    --model|--effort) AGENT_OPTS+=("$1" "$2"); shift 2 ;;   # (inside) the agent's model and effort
    --tag) TAGS+=(--tag "$2"); shift 2 ;;      # (inside) unit=<unit> milestone=<n> lane=<lane>
    [0-9]*) [[ "$1" =~ ^[0-9]+$ ]] || die "unknown argument: $1"; MILESTONES+=("$1"); shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------- prompt
milestone_section() {
  # The "## Milestone N" section of the milestones file, up to the next "## ".
  awk -v n="$1" '
    /^## /{ if (on) exit; on = ($0 ~ "^## Milestone " n "( |$|[^0-9])") }
    on' "$REPO/$MILESTONES_FILE"
}

milestone_prompt() {
  local n="$1"
  echo "Milestone $n of $MILESTONES_FILE. Read that section, then every appendix it names, then the principles file the spec points to."
  echo
  if [[ -f "$REPO/.milestones/standing-rules.md" ]]; then
    sed "s/milestone-N/milestone-$n/g; s#REPORT_DIR#$REPORT_DIR#g" "$REPO/.milestones/standing-rules.md"; echo
  fi
  echo "The milestone section, verbatim:"; echo
  milestone_section "$n"; echo
  [[ -f "$REPO/.milestones/milestone-$n.md" ]] && { cat "$REPO/.milestones/milestone-$n.md"; echo; }
  local note="$NOTE"; [[ -z "$note" && -f "$REPO/.milestones/notes-$n.md" ]] && note="$REPO/.milestones/notes-$n.md"
  [[ -n "$note" ]] && { echo "Notes from the supervisor:"; echo; cat "$note"; echo; }
  echo "When the exit criteria are met, or you have measured why one is not, stop."
}

# ---------------------------------------------------------------- the unit's body
run_gate() {
  # A milestone's own sandbox: identity, dirt and the report read on the host from its
  # worktree, each step through its own enter.
  local n="$1" ws sha rc=0
  require_gate
  ws="$(sandbox_workspace "$SANDBOX")"
  sha="$(git -C "$ws" rev-parse --verify -q HEAD 2> /dev/null || true)"
  if [[ ! -d "$ws" || -z "$sha" ]]; then
    log "milestone $n: gate FAILED: cannot read the gated commit in $ws; no step ran; unit stops"; return 1
  fi
  gate_run sandbox "$n" "$ws" "$sha" "$SANDBOX" || rc=$?
  if (( GATE_ADMISSION )); then log "milestone $n: gate not admitted; unit stops"; return 3; fi
  if (( rc == 0 )); then log "milestone $n: gate passed $(date -Is)"; return 0; fi
  log "milestone $n: gate FAILED (exit $rc${GATE_FAILED_STEP:+, at $GATE_FAILED_STEP}), see ${GATE_BUNDLE:-$LOGS} and the sandbox transcript; unit stops"
  return 1
}

inside_body() {
  local n="$INSIDE" rc=0
  UNIT="${UNIT:-${MILESTONE_UNIT:-untracked}}"
  ((${#TAGS[@]})) || TAGS=(--tag "unit=$UNIT" --tag "milestone=$n" --tag "lane=$(resolve_lane "$n")")
  # Fail before a sandbox or a turn is spent when the milestone could never be gated.
  [[ -n "$CONTINUE" ]] || require_gate

  if [[ -n "$CONTINUE" ]]; then
    # A follow-up turn in the sandbox's last conversation: owner actions done, a
    # correction from another milestone, a reading to re-take. No gate; the
    # supervisor reads the transcript and decides.
    [[ -n "$SANDBOX" ]] || die "--continue needs --sandbox ID"
    local stamp; stamp="$(date +%Y%m%dT%H%M%S)"
    log "=== continue in $SANDBOX (unit $UNIT): $(date -Is) ==="
    sandbox_call "$LOGS/continue-$stamp.log" enter "$SANDBOX" --timeout "$TIMEOUT" "${RES[@]}" "${TAGS[@]}" --json -- \
      claude --dangerously-skip-permissions --output-format text "${AGENT_OPTS[@]}" -c -p "$CONTINUE" || rc=$?
    (( rc == 3 && ADMISSION_REFUSED )) && { log "continue: not admitted; unit stops"; return 3; }
    (( rc )) && log "continue: claude exited $rc"
    log "continue done $(date -Is): $LOGS/continue-$stamp.log"
    return 0
  fi

  if (( GATE_ONLY )); then
    [[ -n "$SANDBOX" ]] || die "--gate needs --sandbox ID"
    log "=== gate only, milestone $n in $SANDBOX (unit $UNIT): $(date -Is) ==="
    run_gate "$n"
    return
  fi

  if [[ -z "$SANDBOX" ]]; then
    # A fresh worktree, seeded with whatever the sandbox config lists. Created inside
    # the unit so its admission (and any wait) is visible in status, not blocking the caller.
    # One log per creation: two units starting together must not read each other's id.
    local created; created="$LOGS/create-$n-$(date +%Y%m%dT%H%M%S).log"
    sandbox_call "$created" run "$REPO" --new "${RES[@]}" "${TAGS[@]}" --json -- true || rc=$?
    (( rc == 3 && ADMISSION_REFUSED )) && { log "milestone $n: sandbox creation not admitted; unit stops"; return 3; }
    # The id comes from the result JSON, else the create log's own "workspace
    # preserved" line. Never pick the newest worktree by mtime: a running agent keeps
    # its worktree newer than a freshly created one.
    SANDBOX="$(json_sandbox_id "$created")"
    [[ -n "$SANDBOX" ]] || SANDBOX="$(sed -n 's#.*workspace preserved: .*/worktrees/\([^/ ]*\).*#\1#p' "$created" | tail -1)"
    [[ -n "$SANDBOX" ]] || { log "could not read the new sandbox id from $created (agent-sandbox exit $rc)"; return 1; }
    log "sandbox: $SANDBOX"
    rc=0
  fi

  log "=== milestone $n in $SANDBOX (unit $UNIT): $(date -Is) ==="
  milestone_prompt "$n" > "$LOGS/milestone-$n.prompt"
  sandbox_call "$LOGS/milestone-$n.log" enter "$SANDBOX" --timeout "$TIMEOUT" "${RES[@]}" "${TAGS[@]}" --json -- \
    claude --dangerously-skip-permissions --output-format text "${AGENT_OPTS[@]}" -p "$(cat "$LOGS/milestone-$n.prompt")" || rc=$?
  (( rc == 3 && ADMISSION_REFUSED )) && { log "milestone $n: not admitted; unit stops"; return 3; }
  (( rc )) && log "milestone $n: claude exited $rc"
  run_gate "$n" || return $?
  log "milestone $n done: $(date -Is). Branch agent-sandbox/$SANDBOX holds the work."
}

# ---------------------------------------------------------------- launch
launch_unit() {
  # kind: milestone | continue | gate. The body is this script under --inside.
  local kind="$1" n="$2" max t g stamp unit out lane
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
  t="$(to_seconds "$TIMEOUT")"; g="$(to_seconds "$GATE_TIMEOUT")"
  case "$kind" in
    milestone) max=$(( t + g + 300 )) ;;   # the turn, the gate, five minutes
    continue)  max=$(( t + 300 )) ;;
    gate)      max=$(( g + 300 )) ;;
  esac
  stamp="$(date +%Y%m%dT%H%M%S)"
  unit="milestone-$(printf '%s' "$PROJECT" | tr -c 'A-Za-z0-9_.-' '-')-$n-$stamp"
  out="$LOGS/unit-$unit.out"
  resolve_resources "$n"
  lane="$(resolve_lane "$n")"

  local inner=("$SELF" --inside "$n" --unit "$unit" "${RES[@]}" "${AGENT_OPTS[@]}" --tag "unit=$unit" --tag "milestone=$n" --tag "lane=$lane")
  [[ -n "$SANDBOX" ]] && inner+=(--sandbox "$SANDBOX")
  (( DEPLOY )) && inner+=(--deploy)
  [[ -n "$NOTE" ]] && inner+=(--note "$NOTE")
  [[ "$kind" == continue ]] && inner+=(--continue "$CONTINUE")
  [[ "$kind" == gate ]] && inner+=(--gate)

  local cmd=(systemd-run --user --collect "--unit=$unit"
    "--property=RuntimeMaxSec=$max"
    "--property=StandardOutput=append:$out" "--property=StandardError=append:$out"
    "--working-directory=$REPO"
    "--setenv=PATH=$PATH" "--setenv=HOME=$HOME" "--setenv=MILESTONE_UNIT=$unit")
  local v
  for v in $(compgen -e | grep -E '^(AGENT_SANDBOX_|LANG$|LC_ALL$)' || true); do cmd+=("--setenv=$v=${!v}"); done
  cmd+=(-- "${inner[@]}")

  log "=== launch $kind $n${SANDBOX:+ in $SANDBOX} as $unit: $(date -Is) ==="
  local rc=0
  "${cmd[@]}" || rc=$?
  (( rc )) && { log "systemd-run refused $unit (exit $rc); nothing launched"; exit 1; }
  log "unit: $unit (RuntimeMaxSec=$max${RES[*]:+, ${RES[*]}})"
  log "unit log: $out"
  echo "watch: systemctl --user status $unit   |   $(basename "$SELF") status"
}

# ---------------------------------------------------------------- status and resume
UNITS_UP=""
load_units() {
  UNITS_UP=" $(systemctl --user list-units --plain --no-legend 'milestone-*' 2>/dev/null | awk '{print $1}' | sed 's/\.service$//' | tr '\n' ' ' || true) "
}

project_rows() {
  # agent-sandbox status --json, this project's sandboxes only (worktree basename or
  # branch `agent-sandbox/<project>-<hash>`), one TSV line each:
  # id state newest_status evidence container off_start off_end unit milestone workspace branch stdout
  local js re
  js="$(agent-sandbox status --json)" || die "agent-sandbox status --json failed"
  re="^$(printf '%s' "$PROJECT" | sed 's/[.[\*^$]/\\&/g')-[0-9a-f]+$"
  if have_jq; then
    printf '%s' "$js" | jq -r --arg re "$re" '
      def s: if . == null then "-" else tostring end;
      .[] | select((((.workspace // "") | split("/") | last) | test($re))
                   or ((.branch // "") | ltrimstr("agent-sandbox/") | test($re)))
      | [.sandbox_id, .state, (.newest.status|s), (.newest.evidence|s), (.newest.container|s),
         (.newest.stdout_offset_start|s), (.newest.stdout_offset_end|s),
         (.tags.unit|s), (.tags.milestone|s), (.workspace|s), (.branch|s), (.logs.stdout|s)]
      | map(gsub("[\t\n]"; " ")) | @tsv'
  else
    printf '%s' "$js" | python3 -c '
import json, re, sys
rx = re.compile(sys.argv[1])
def s(v): return "-" if v is None else str(v).replace("\t", " ").replace("\n", " ")
for r in json.load(sys.stdin):
    ws = (r.get("workspace") or "").rstrip("/").split("/")[-1]
    br = (r.get("branch") or "")
    br = br[len("agent-sandbox/"):] if br.startswith("agent-sandbox/") else br
    if not (rx.search(ws) or rx.search(br)): continue
    n = r.get("newest") or {}; t = r.get("tags") or {}; lg = r.get("logs") or {}
    print("\t".join(s(x) for x in [r.get("sandbox_id"), r.get("state"), n.get("status"), n.get("evidence"),
          n.get("container"), n.get("stdout_offset_start"), n.get("stdout_offset_end"),
          t.get("unit"), t.get("milestone"), r.get("workspace"), r.get("branch"), lg.get("stdout")]))' "$re"
  fi
}

log_segment() {
  # The newest entry's own bytes of the sandbox stdout.log: [start, end); to EOF when
  # end is unrecorded; the last 200 lines when the record has no offsets.
  local f="$1" start="$2" end="$3"
  [[ -f "$f" ]] || return 0
  if [[ "$start" =~ ^[0-9]+$ ]]; then
    if [[ "$end" =~ ^[0-9]+$ ]] && (( end >= start )); then
      tail -c "+$(( start + 1 ))" "$f" | head -c "$(( end - start ))" || true   # head closing early is not an error
    else
      tail -c "+$(( start + 1 ))" "$f" || true
    fi
  else
    tail -n 200 "$f" || true
  fi
}

# Per-row facts, filled by judge_row.
J_LABEL=""; J_UNIT=""; J_REPORT=""; J_401=""; J_LAST=""; J_DIRTY=""
judge_row() {
  local id="$1" state="$2" start="$6" end="$7" unit="$8" m="$9" ws="${10}" stdout="${12}"
  J_UNIT="gone"; [[ "$unit" != "-" && "$UNITS_UP" == *" $unit "* ]] && J_UNIT="up"
  J_REPORT="-"; J_DIRTY="-"
  if [[ "$ws" != "-" && -d "$ws" ]]; then
    J_DIRTY="$(git -C "$ws" status --porcelain 2>/dev/null | wc -l | tr -d ' ' || true)"
    if [[ "$m" =~ ^[0-9]+$ ]]; then
      if [[ -n "$(git -C "$ws" log --oneline -n 1 -- "$REPORT_DIR/milestone-$m.md" 2>/dev/null)" ]]; then J_REPORT="committed"
      elif [[ -s "$ws/$REPORT_DIR/milestone-$m.md" ]]; then J_REPORT="uncommitted"
      else J_REPORT="none"; fi
    fi
  fi
  local seg; seg="$(log_segment "$stdout" "$start" "$end")"
  J_401="no"; printf '%s\n' "$seg" | grep -Eq '(^|[^0-9])401([^0-9]|$)' && J_401="yes"
  J_LAST="$(printf '%s\n' "$seg" | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-100 || true)"   # an empty log matches nothing; not an error
  case "$state" in
    running|waiting) J_LABEL="$state" ;;
    orphaned) J_LABEL="orphaned" ;;
    crashed)
      if [[ "$J_REPORT" == committed ]]; then J_LABEL="finished-unrecorded"
      elif [[ "$J_401" == yes ]]; then J_LABEL="auth-expired"
      else J_LABEL="vanished"; fi ;;
    finished)
      if [[ "$J_REPORT" == committed || ! "$m" =~ ^[0-9]+$ ]]; then J_LABEL="finished"
      elif [[ "$J_401" == yes ]]; then J_LABEL="auth-expired"
      else J_LABEL="finished-unrecorded"; fi ;;
    *) J_LABEL="$state" ;;
  esac
}

do_status() {
  load_units
  local rows; rows="$(project_rows)"
  [[ -n "$rows" ]] || { echo "no sandboxes of $PROJECT"; return 0; }
  printf '%-28s %-3s %-9s %-4s %-11s %-3s %-19s %s\n' "SANDBOX" "MS" "STATE" "UNIT" "REPORT" "401" "LABEL" "LAST OUTPUT"
  local IFS=$'\t' f
  while read -r -a f; do
    judge_row "${f[@]}"
    printf '%-28s %-3s %-9s %-4s %-11s %-3s %-19s %s\n' "${f[0]}" "${f[8]}" "${f[1]}" "$J_UNIT" "$J_REPORT" "$J_401" "$J_LABEL" "$J_LAST"
  done <<< "$rows"
}

resume_command() {
  # Sets CMD (array) and NOTE_LINE for a judged row; CMD empty when none derives.
  local id="$1" container="$5" m="$9"
  local self_cmd=("$SELF"); [[ "$m" =~ ^[0-9]+$ ]] && self_cmd+=("$m")
  CMD=(); NOTE_LINE=""
  case "$J_LABEL" in
    vanished)
      CMD=("${self_cmd[@]}" --sandbox "$id" --continue "The previous turn of milestone $m ended without a record: its container vanished (${4}). Read git status and git log in the worktree, finish the milestone's exit criteria, write $REPORT_DIR/milestone-$m.md and commit.") ;;
    auth-expired)
      NOTE_LINE="owner: the token this agent held was revoked (a 401 ends its segment; a host re-login does that). Log in again on the host before issuing:"
      CMD=("${self_cmd[@]}" --sandbox "$id" --continue "The previous turn of milestone $m ended when its credentials were revoked (401). Read git status and git log in the worktree, finish the milestone's exit criteria, write $REPORT_DIR/milestone-$m.md and commit.") ;;
    finished-unrecorded)
      if [[ "$m" =~ ^[0-9]+$ ]]; then CMD=("$SELF" "$m" --sandbox "$id" --gate)
      else NOTE_LINE="no milestone tag on this record; run the gate by hand"; fi ;;
    orphaned)
      CMD=(bash -c "docker stop $(printf '%q' "$container") && agent-sandbox status --reconcile $(printf '%q' "$id")") ;;
  esac
}

do_resume() {
  load_units
  local rows; rows="$(project_rows)"
  [[ -n "$rows" ]] || { echo "no sandboxes of $PROJECT"; return 0; }
  local IFS=$'\t' f any=0
  while read -r -a f; do
    judge_row "${f[@]}"
    case "$J_LABEL" in running|waiting|finished) continue ;; esac
    any=1
    log "=== resume ${f[0]} (milestone ${f[8]}) $(date -Is): $J_LABEL ==="
    log "  evidence: ${f[3]}"
    log "  unit ${f[7]}: $J_UNIT; report: $J_REPORT; dirty files: $J_DIRTY; 401 in segment: $J_401"
    log "  last output: ${J_LAST:--}"
    resume_command "${f[@]}"
    [[ -n "$NOTE_LINE" ]] && log "  $NOTE_LINE"
    if ((${#CMD[@]} == 0)); then log "  no finishing command derives from this state"; continue; fi
    local q; q="$(printf '%q ' "${CMD[@]}")"
    log "  finish: (cd $(printf '%q' "$REPO") && ${q% })"
    if (( ISSUE )); then
      log "  issuing $(date -Is)"
      (cd "$REPO" && "${CMD[@]}") 2>&1 | tee -a "$CHAIN" || log "  issue failed (exit ${PIPESTATUS[0]})"
    fi
  done <<< "$rows"
  (( any )) || echo "nothing to resume: every sandbox of $PROJECT is running or finished"
  (( ISSUE )) || (( ! any )) || echo "(printed only; add --issue to run them)"
}

# ---------------------------------------------------------------- integrate
# `integrate <sandbox-id> [N]` merges agent-sandbox/<id> into the current branch, checks
# the unpushed range, gates it on the host in a temporary worktree, records STATUS.md and
# pushes. Every refusal and failure pushes nothing; after the merge it keeps the merge
# local and logs the pre-merge sha for a manual reset.
SANDBOX_ID_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'   # agent-sandbox's own id rule
# Host metadata written beside a gate, never code: integrate's clean-tree checks ignore these paths
# (a trailing "/" is a directory). Defined once; the delivery guard reads the same list.
METADATA_ALLOWLIST=(.milestones/STATUS.md .milestones/events.jsonl .milestones/grades.jsonl
  .milestones/acceptance/ .milestones/approvals/ .milestones/mutations/)
METADATA_EXCLUDES=()
for _p in "${METADATA_ALLOWLIST[@]}"; do METADATA_EXCLUDES+=(":(top,exclude)${_p%/}"); done
unset _p
STATUS_HEADER='| Milestone | Lane | Sandbox | Merged | Gate | Unmet criteria | Open blockers | Next action |'

# Defaults for the weakening scan, overridable in config. A glob with no "/" matches the
# file name; one ending in "/" matches that directory anywhere in the path; any other
# glob matches the path from the root or from any directory ("*" and "**" cross "/").
TEST_WEAKENING_PATTERN="${TEST_WEAKENING_PATTERN:-pytest\.mark\.(skip|skipif|xfail)|pytest\.(skip|xfail)\(|unittest\.(skip|expectedFailure)|\.skip\(|\.only\(|(^|[^A-Za-z0-9_.])(xit|xdescribe|xtest)\(|\.fixme\(|t\.Skip(Now|f)?\(|@Disabled|@Ignore}"
TEST_ASSERT_PATTERN="${TEST_ASSERT_PATTERN:-(^|[^A-Za-z0-9_])assert|expect\(|\.should|(^|[^A-Za-z0-9_])t\.(Error|Errorf|Fatal|Fatalf)\(|require\.[A-Z]}"
TEST_GLOBS="${TEST_GLOBS:-tests/ test/ __tests__/ e2e/ test_*.py *_test.py conftest.py *.test.* *.spec.* *_test.go *Test.java *Tests.java}"
SNAPSHOT_GLOBS="${SNAPSHOT_GLOBS:-__snapshots__/ *.snap *-snapshots/}"
GATE_DEFINITION_GLOBS="${GATE_DEFINITION_GLOBS:-justfile Makefile package.json pyproject.toml pytest.ini setup.cfg tox.ini conftest.py vitest.config.* jest.config.* playwright.config.* .github/}"

path_matches() {
  # path_matches <path> <space-separated globs>
  local path="$1" glob
  local -
  set -f   # the globs are patterns, not file names to expand
  for glob in $2; do
    glob="${glob//\*\*/*}"
    if [[ "$glob" == */ ]]; then
      # shellcheck disable=SC2053
      [[ "/$path" == */$glob* ]] && return 0
    elif [[ "$glob" == */* ]]; then
      # shellcheck disable=SC2053
      [[ "$path" == $glob || "$path" == */$glob ]] && return 0
    else
      # shellcheck disable=SC2053
      [[ "${path##*/}" == $glob ]] && return 0
    fi
  done
  return 1
}

sandbox_record_field() {
  # A field (dotted path) of sandbox <id>'s record in agent-sandbox status --json; empty when
  # the record, the field or agent-sandbox itself is missing.
  local js
  js="$(agent-sandbox status --json 2> /dev/null)" || return 0
  if have_jq; then
    printf '%s' "$js" | jq -r --arg id "$1" --arg p "$2" '.[]? | select(.sandbox_id == $id) | getpath($p | split(".")) // empty' 2> /dev/null | head -n 1 || true
  else
    printf '%s' "$js" | python3 -c '
import json, sys
try:
    for r in json.load(sys.stdin):
        if r.get("sandbox_id") == sys.argv[1]:
            v = r
            for k in sys.argv[2].split("."): v = v.get(k) if isinstance(v, dict) else None
            if v not in (None, ""): print(v)
            break
except Exception: pass' "$1" "$2" 2> /dev/null || true
  fi
}

sandbox_milestone_tag() { sandbox_record_field "$1" tags.milestone; }

sandbox_workspace() {
  # Sandbox <id>'s worktree on the host: its record's workspace, else agent-sandbox's layout.
  local ws; ws="$(sandbox_record_field "$1" workspace)"
  [[ -n "$ws" ]] || ws="${AGENT_SANDBOX_HOME:-$HOME/agent-sandbox}/worktrees/$1"
  echo "$ws"
}

WEAKENING_KINDS="skip-marker removed-assert deleted-test snapshot test-change"

weakening_hits() {
  # weakening_hits <base> [<head>, default HEAD]: "<kind> <path>" per hit in the diff <base>..<head>:
  #   skip-marker     an added line matching TEST_WEAKENING_PATTERN in a TEST_GLOBS file
  #   removed-assert  a removed line matching TEST_ASSERT_PATTERN in a TEST_GLOBS file
  #   deleted-test    a deleted TEST_GLOBS file
  #   test-change     a modified existing TEST_GLOBS file (an added test file is not a hit; a
  #                   deleted one is deleted-test)
  #   snapshot        a modified or deleted SNAPSHOT_GLOBS file (a new baseline is not a change)
  #   gate-config     an added, modified or deleted GATE_DEFINITION_GLOBS file (the runner's
  #                   config or the gate recipe can narrow the suite without touching a test), or a
  #                   path a step command, GATE_SETUP or GATE_ENV names as a word (gate_named_paths)
  # The line checks are limited to test files so application code (an iterator's .skip(,
  # a production assert) and the report quoting a marker are not hits.
  # Fails closed: a git or reader error prints "error: <why>" as the last line and returns 1, so
  # no caller can read a failed scan as a scan with no hits.
  local base="$1" head="${2:-HEAD}" status path body named names rc=0 i
  local entries=()
  if ! git rev-parse --verify -q "$base^{commit}" > /dev/null; then echo "error: the scan base '$base' does not resolve to a commit"; return 1; fi
  if ! git rev-parse --verify -q "$head^{commit}" > /dev/null; then echo "error: the scan head '$head' does not resolve to a commit"; return 1; fi
  named="$(gate_named_paths)" || { echo "error: could not read the paths the gate commands name"; return 1; }
  names="$(mktemp "${TMPDIR:-/tmp}/scan-names.XXXXXX")" || { echo "error: could not create a temporary file"; return 1; }
  git -c core.quotePath=false diff --no-renames --name-status -z "$base" "$head" > "$names" || rc=$?
  if (( rc )); then rm -f "$names"; echo "error: git diff --name-status ${base:0:12} ${head:0:12} failed (exit $rc)"; return 1; fi
  mapfile -d '' -t entries < "$names" || rc=$?
  rm -f "$names"
  if (( rc )) || (( ${#entries[@]} % 2 )); then echo "error: could not read the name-status list of ${base:0:12}..${head:0:12}"; return 1; fi
  for (( i = 0; i < ${#entries[@]}; i += 2 )); do
    status="${entries[i]}"; path="${entries[i + 1]}"
    if path_matches "$path" "$SNAPSHOT_GLOBS" && [[ "$status" != A ]]; then
      echo "snapshot $path"
    fi
    if path_matches "$path" "$GATE_DEFINITION_GLOBS" || grep -qxF -- "$path" <<< "$named"; then echo "gate-config $path"; fi
    path_matches "$path" "$TEST_GLOBS" || continue
    if [[ "$status" == D ]]; then echo "deleted-test $path"; continue; fi
    if [[ "$status" == M || "$status" == T ]]; then echo "test-change $path"; fi
    rc=0
    body="$(git -c core.quotePath=false diff --no-color --no-ext-diff --no-renames --unified=0 "$base" "$head" -- ":(literal)$path" \
      | awk '/^@@/ { b = 1; next } /^diff --git / { b = 0 } b')" || rc=$?
    if (( rc )); then echo "error: git diff of $path between ${base:0:12} and ${head:0:12} failed (exit $rc)"; return 1; fi
    # grep reads a here-string, never a pipe: `sed | grep -q` under pipefail fails when grep
    # exits at its first match while sed still writes, which hides a hit in a large diff.
    if grep -Eq -- "$TEST_WEAKENING_PATTERN" <<< "$(sed -n 's/^+//p' <<< "$body")"; then echo "skip-marker $path"; fi
    if grep -Eq -- "$TEST_ASSERT_PATTERN" <<< "$(sed -n 's/^-//p' <<< "$body")"; then echo "removed-assert $path"; fi
  done
}

path_blob() {
  # path_blob <commit> <path>: the object id <path> has at <commit>, "none" when it is absent.
  # Returns 1 on a git error, never "none".
  local out line meta p
  out="$(GIT_LITERAL_PATHSPECS=1 git ls-tree --full-tree -z "$1" -- "$2" | tr '\0' '\n')" || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    meta="${line%%$'\t'*}"; p="${line#*$'\t'}"
    if [[ "$p" == "$2" ]]; then
      read -r _ _ p <<< "$meta"
      [[ "$p" =~ ^[0-9a-f]{40,64}$ ]] || return 1
      echo "$p"; return 0
    fi
  done <<< "$out"
  echo none
}

# ---- owner approvals (R31): .milestones/approvals/N.md, written only by `approve`
# One entry per line, every field present, "-" where a field does not apply:
#   - approved <iso time> milestone=<N> kind=<kind> hit=<hit kind|-> path="<path>"|- blob=<object id|none|-> hash=<sha256|-> criterion=<N.c<i>|-> budget=<name|-> confirm="approve <N> <kind>"
# kinds and their fields: criterion-waiver (criterion), weakening (hit, path, blob), gate-config
# (path, blob), gate-definition (hash: the gate definition hash), budget (budget). blob is the
# path's object id at the candidate head, "none" for a deleted path. Readers take the file as
# committed at the commit they check, and ignore every line not in exactly this form.
APPROVAL_LINE_RE='^- approved ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}:[0-9]{2}|Z)) milestone=([0-9]+) kind=(criterion-waiver|weakening|gate-config|gate-definition|budget) hit=([a-z-]+) path=("[^"]+"|-) blob=([0-9a-f]{40}|[0-9a-f]{64}|none|-) hash=([0-9a-f]{64}|-) criterion=([0-9]+\.c[0-9]+|-) budget=([A-Za-z0-9_.-]+|-) confirm="approve ([0-9]+) ([a-z-]+)"$'

approval_entries() {
  # approval_entries <n> <commit>: the valid entries of .milestones/approvals/<n>.md as committed
  # at <commit>, one per line, tab separated: kind hit path blob hash criterion budget. Nothing
  # when the file is absent there; returns 1 on a git error.
  local n="$1" at="$2" af=".milestones/approvals/$1.md" have text line m kind hit path blob hash crit budget cn ck
  have="$(GIT_LITERAL_PATHSPECS=1 git ls-tree --full-tree --name-only "$at" -- "$af")" || return 1
  [[ -n "$have" ]] || return 0
  text="$(git cat-file blob "$at:$af")" || return 1
  while IFS= read -r line; do
    [[ "$line" =~ $APPROVAL_LINE_RE ]] || continue
    m="${BASH_REMATCH[3]}"; kind="${BASH_REMATCH[4]}"; hit="${BASH_REMATCH[5]}"; path="${BASH_REMATCH[6]}"
    blob="${BASH_REMATCH[7]}"; hash="${BASH_REMATCH[8]}"; crit="${BASH_REMATCH[9]}"; budget="${BASH_REMATCH[10]}"
    cn="${BASH_REMATCH[11]}"; ck="${BASH_REMATCH[12]}"
    [[ "$m" == "$n" && "$cn" == "$n" && "$ck" == "$kind" ]] || continue
    [[ "$path" == - ]] || path="${path:1:${#path}-2}"
    case "$kind" in
      criterion-waiver) [[ "$hit|$path|$blob|$hash|$budget" == "-|-|-|-|-" && "$crit" == "$n".c* ]] || continue ;;
      weakening)        [[ " $WEAKENING_KINDS " == *" $hit "* && "$path" != - && "$blob" != - && "$hash|$crit|$budget" == "-|-|-" ]] || continue ;;
      gate-config)      [[ "$hit" == - && "$path" != - && "$blob" != - && "$hash|$crit|$budget" == "-|-|-" ]] || continue ;;
      gate-definition)  [[ "$hit|$path|$blob|$crit|$budget" == "-|-|-|-|-" && "$hash" != - ]] || continue ;;
      budget)           [[ "$hit|$path|$blob|$hash|$crit" == "-|-|-|-|-" && "$budget" != - ]] || continue ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$hit" "$path" "$blob" "$hash" "$crit" "$budget"
  done <<< "$text"
}

HITS=""; UNAPPROVED=""; SCAN_ERROR=""
unapproved_hits() {
  # unapproved_hits <base> <head> <milestone>: HITS gets every hit weakening_hits finds in
  # <base>..<head>, UNAPPROVED the ones no owner approval covers, one "<kind> <path>" per line.
  # The one place approval is decided: a hit is approved when .milestones/approvals/<milestone>.md,
  # as committed at <head>, holds a valid entry for it (kind=weakening with hit=<kind>, or
  # kind=gate-config) naming its path at the object id the path has at <head> ("none" when
  # deleted), so a later change to the file is unapproved again. Nothing the candidate branch
  # writes (its report, a section in it) approves anything. Returns 1 with SCAN_ERROR set when
  # any read fails: an error never passes.
  local base="$1" head="$2" n="$3" out rc=0 approvals kind path blob want
  HITS=""; UNAPPROVED=""; SCAN_ERROR=""
  out="$(weakening_hits "$base" "$head")" || rc=$?
  if (( rc )); then
    SCAN_ERROR="$(grep '^error: ' <<< "$out" | tail -n 1 || true)"; SCAN_ERROR="${SCAN_ERROR#error: }"
    SCAN_ERROR="${SCAN_ERROR:-the scan exited $rc}"; return 1
  fi
  HITS="$(grep -v '^$' <<< "$out" | sort -u || true)"
  [[ -n "$HITS" ]] || return 0
  approvals="$(approval_entries "$n" "$head")" \
    || { SCAN_ERROR="could not read .milestones/approvals/$n.md at ${head:0:12}"; return 1; }
  approvals="$(cut -f1-4 <<< "$approvals")"
  while read -r kind path; do
    blob="$(path_blob "$head" "$path")" || { SCAN_ERROR="could not read the object id of $path at ${head:0:12}"; return 1; }
    if [[ "$kind" == gate-config ]]; then want="gate-config"$'\t'"-"; else want="weakening"$'\t'"$kind"; fi
    want+=$'\t'"$path"$'\t'"$blob"
    grep -qxF -- "$want" <<< "$approvals" || UNAPPROVED+="$kind $path"$'\n'
  done <<< "$HITS"
  UNAPPROVED="${UNAPPROVED%$'\n'}"
}

approve_commands() {
  # approve_commands <n>: the approve command for each "<kind> <path>" line on stdin.
  local n="$1" kind path
  while read -r kind path; do
    if [[ "$kind" == gate-config ]]; then echo "$SELF approve $n gate-config $(printf '%q' "$path")"
    else echo "$SELF approve $n weakening $kind $(printf '%q' "$path")"; fi
  done
}

# ---- candidate preconditions, shared by integrate and mutate
CANDIDATE_REFUSAL=""
candidate_range_refusal() {
  # candidate_range_refusal <base> <sandbox-branch>: returns 1 with CANDIDATE_REFUSAL set when
  # the branch's own range <base>..<branch> touches .milestones/ (supervisor files come only
  # from host commits) or adds or changes a path `git check-ignore` reports ignored in the
  # host checkout (a merge would overwrite it). A git error refuses too.
  local base="$1" sbranch="$2" p rc=0 bad=() ignored=() changed ig_out listed
  CANDIDATE_REFUSAL=""
  listed="$(git -c core.quotePath=false log --no-renames --format= --name-only "$base..$sbranch" -- .milestones)" \
    || { CANDIDATE_REFUSAL="could not list the supervisor files $sbranch touches"; return 1; }
  while IFS= read -r p; do
    [[ -n "$p" ]] && bad+=("$p")
  done < <(sort -u <<< "$listed")
  if (( ${#bad[@]} )); then
    CANDIDATE_REFUSAL="$sbranch touches supervisor files under .milestones/, which only host commits may change: ${bad[*]}"; return 1
  fi
  changed="$(mktemp "${TMPDIR:-/tmp}/candidate-paths.XXXXXX")"
  git -c core.quotePath=false diff --no-renames --name-only -z --diff-filter=d "$base" "$sbranch" > "$changed" \
    || { rm -f "$changed"; CANDIDATE_REFUSAL="could not list the paths $sbranch changes"; return 1; }
  ig_out="$(git -c core.quotePath=false check-ignore -z --stdin < "$changed" | tr '\0' '\n')" || rc=$?
  rm -f "$changed"
  (( rc <= 1 )) || { CANDIDATE_REFUSAL="git check-ignore failed (exit $rc) while checking $sbranch for ignored paths"; return 1; }
  while IFS= read -r p; do
    [[ -n "$p" ]] && ignored+=("$p")
  done <<< "$ig_out"
  if (( ${#ignored[@]} )); then
    CANDIDATE_REFUSAL="$sbranch adds or changes paths ignored in this checkout, which a merge would overwrite: ${ignored[*]}"; return 1
  fi
}

status_upsert() {
  # Upsert milestone <n>'s row in .milestones/STATUS.md: Lane, Sandbox, Merged and Gate are
  # set; Unmet criteria, Open blockers and Next action of an existing row are kept.
  local sfile="$REPO/.milestones/STATUS.md" n="$1" lane="$2" id="$3" merged="$4" gate="$5" tmp
  if [[ ! -f "$sfile" ]]; then
    printf '# Milestone status\n\n%s\n|---|---|---|---|---|---|---|---|\n' "$STATUS_HEADER" > "$sfile"
  fi
  tmp="$(mktemp "$sfile.XXXXXX")"
  awk -F'|' -v n="$n" -v lane="$lane" -v id="$id" -v merged="$merged" -v gate="$gate" -v hdr="$STATUS_HEADER" '
    function t(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function c(s) { s = t(s); return s == "" ? "-" : s }
    { line[NR] = $0 }
    /^[ \t]*\|/ {
      last = NR
      if (t($2) == n && !done) {
        line[NR] = "| " n " | " lane " | " id " | " merged " | " gate " | " c($7) " | " c($8) " | " c($9) " |"
        done = 1
      }
    }
    END {
      for (i = 1; i <= NR; i++) {
        print line[i]
        if (i == last && !done) print "| " n " | " lane " | " id " | " merged " | " gate " | - | - | - |"
      }
      if (!last) {
        print hdr
        print "|---|---|---|---|---|---|---|---|"
        print "| " n " | " lane " | " id " | " merged " | " gate " | - | - | - |"
      }
    }' "$sfile" > "$tmp"
  cat "$tmp" > "$sfile"; rm -f "$tmp"   # keep the file's own mode
}

seed_worktree() {
  # Copy each SEED_PATHS entry from the host checkout into worktree <dir>.
  local dir="$1" p
  local -
  set -f
  for p in ${SEED_PATHS:-}; do
    if [[ "$p" == /* || "/$p/" == */../* ]]; then log "  seed path '$p' skipped: not a path inside the repository"; continue; fi
    [[ -e "$REPO/$p" ]] || { log "  seed path $p absent on the host; skipped"; continue; }
    if [[ -d "$REPO/$p" ]]; then mkdir -p "$dir/$p"; cp -a "$REPO/$p/." "$dir/$p/"
    else mkdir -p "$(dirname "$dir/$p")"; cp -a "$REPO/$p" "$dir/$p"; fi
    log "  seeded $p"
  done
}

host_gate() {
  # host_gate <milestone> <sha> [where, default host-integrate]
  # Gate <sha> on the host in a temporary detached worktree seeded with SEED_PATHS copies,
  # so GATE_SETUP never writes the host files every sandbox is seeded from. The bundle is
  # written under the project's logs before the worktree is removed. Returns the gate's exit.
  local n="$1" sha="$2" where="${3:-host-integrate}" rc=0
  arm_cleanup
  INTEGRATE_TREE="$(mktemp -d "${TMPDIR:-/tmp}/integrate-$PROJECT-$n.XXXXXX")"
  GATE_NOSTART=""
  git worktree add -q --detach "$INTEGRATE_TREE/tree" "$sha" > /dev/null \
    || { GATE_NOSTART="could not add a worktree of ${sha:0:12}"; log "  $GATE_NOSTART"; return 1; }
  seed_worktree "$INTEGRATE_TREE/tree"
  log "  host gate in $INTEGRATE_TREE/tree (timeout $GATE_TIMEOUT)"
  gate_run "$where" "$n" "$INTEGRATE_TREE/tree" "$sha" || rc=$?
  integrate_cleanup
  return "$rc"
}

GATE_REFUSED=""
sandbox_integration_gate() {
  # sandbox_integration_gate <milestone> <head> <lane> [source, default the host checkout]
  #   [where, default sandbox-integration]
  # INTEGRATE_GATE_WHERE=sandbox: a fresh sandbox of <source> (a checkout whose HEAD is
  # <head>), refused unless its worktree is at that commit, gated step by step through enter
  # and removed on every exit path. Sets GATE_REFUSED for a sandbox at another commit.
  local n="$1" head="$2" lane="$3" src="${4:-$REPO}" where="${5:-sandbox-integration}" created id ws wsha rc=0
  local purpose=integration-gate what="the merge commit" verb=integrate
  [[ "$where" != sandbox-mutate ]] || { purpose=mutation-gate; what="the commit to gate"; verb=mutate; }
  arm_cleanup
  resolve_resources "$n"
  TAGS=(--tag "milestone=$n" --tag "lane=$lane" --tag "purpose=$purpose")
  created="$LOGS/$verb-$n-sandbox-$(date +%Y%m%dT%H%M%S%N).log"
  log "  $purpose sandbox for ${head:0:12}, created from $src (log $created)"
  sandbox_call "$created" run "$src" --new "${RES[@]}" "${TAGS[@]}" --json -- true || rc=$?
  if (( rc == 3 && ADMISSION_REFUSED )); then GATE_FAILED_STEP="sandbox creation, not admitted"; return 3; fi
  id="$(json_sandbox_id "$created")"
  if [[ -z "$id" || ! "$id" =~ $SANDBOX_ID_RE || "$id" == *..* ]]; then
    log "  no valid sandbox id in $created (agent-sandbox exit $rc); nothing to remove"
    GATE_FAILED_STEP="sandbox creation"; return 1
  fi
  GATE_SANDBOX_CREATED="$id"
  log "  integration sandbox: $id"
  if (( rc )); then GATE_FAILED_STEP="sandbox creation (exit $rc)"; remove_gate_sandbox; return 1; fi
  ws="$(json_field "$created" worktree)"
  wsha=""
  [[ -z "$ws" || ! -d "$ws" ]] || wsha="$(git -C "$ws" rev-parse --verify -q HEAD 2> /dev/null || true)"
  if [[ "$wsha" != "$head" ]]; then
    GATE_REFUSED="integration sandbox $id is at ${wsha:-an unreadable HEAD}, not $what $head"
    remove_gate_sandbox; return 2
  fi
  gate_run "$where" "$n" "$ws" "$head" "$id" || rc=$?
  remove_gate_sandbox
  return "$rc"
}

do_integrate() {
  local id="$INTEGRATE_ID" n="" tag branch upstream remote mref pre sbranch c m ok
  # The id reaches git as a ref name: check it before any git command runs.
  [[ -n "$id" ]] || die "integrate needs a sandbox id: integrate <sandbox-id> [milestone]"
  [[ "$id" =~ $SANDBOX_ID_RE && "$id" != *..* ]] || die "integrate: '$id' is not a sandbox id (letters, digits, . _ -, at most 128, no '..')"
  (( ${#MILESTONES[@]} <= 1 )) || die "integrate takes one sandbox id and at most one milestone"

  tag="$(sandbox_milestone_tag "$id")"
  if [[ -n "$tag" ]]; then
    [[ "$tag" =~ ^[0-9]+$ ]] || die "integrate: sandbox $id has milestone tag '$tag', not a number"
    [[ -z "${MILESTONES[0]:-}" || "${MILESTONES[0]}" == "$tag" ]] \
      || die "integrate: sandbox $id is tagged milestone $tag, not ${MILESTONES[0]}; drop the number or name the right sandbox"
    n="$tag"
  else
    n="${MILESTONES[0]:-}"
    [[ -n "$n" ]] || die "integrate: sandbox $id has no milestone tag; name the milestone: integrate $id <N>"
  fi
  require_gate
  sbranch="agent-sandbox/$id"
  log "=== integrate milestone $n from $sbranch: $(date -Is) ==="
  refuse() { log "integrate milestone $n refused: $*"; exit 2; }
  local gwhere="${INTEGRATE_GATE_WHERE:-host}" glabel="host gate"
  [[ "$gwhere" == host || "$gwhere" == sandbox ]] || refuse "INTEGRATE_GATE_WHERE=$gwhere: want host or sandbox"
  [[ "$gwhere" == host ]] || glabel="sandbox-integration gate"

  # ---- preconditions: nothing below merges until all hold
  local tracked
  tracked="$(git status --porcelain --untracked-files=no -- . "${METADATA_EXCLUDES[@]}")" || refuse "git status failed in $REPO"
  [[ -z "$tracked" ]] || refuse "the host checkout has tracked changes outside the metadata allowlist (${METADATA_ALLOWLIST[*]}); commit or stash them first"
  branch="$(git symbolic-ref --quiet --short HEAD)" || refuse "HEAD is detached; check out the integration branch"
  if [[ -n "${INTEGRATION_BRANCH:-}" && "$branch" != "$INTEGRATION_BRANCH" ]]; then
    refuse "on branch $branch, but INTEGRATION_BRANCH=$INTEGRATION_BRANCH"
  fi
  git rev-parse --quiet --verify "refs/heads/$sbranch^{commit}" > /dev/null || refuse "no branch $sbranch in $REPO"
  upstream="$(git rev-parse --quiet --verify "$branch@{upstream}")" || refuse "branch $branch has no upstream; set one with git branch -u <remote>/<branch>"
  remote="$(git config "branch.$branch.remote")"; mref="$(git config "branch.$branch.merge")"
  [[ -z "$(git rev-list "HEAD..$upstream")" ]] || refuse "branch $branch is behind its upstream; pull first"
  # The ahead rule. Every commit on the branch that its upstream lacks must be
  #   a) reachable from agent-sandbox/<id> (this sandbox's own work),
  #   b) an earlier merge of agent-sandbox/<id> (its second parent is an ancestor of that
  #      branch) or a descendant of one (fix-forward and STATUS commits on top of it), or
  #   c) a non-merge commit that changes only .milestones/ (the supervisor's STATUS.md
  #      review cells, an evaluation record).
  # Anything else is another milestone's kept merge or unrelated work, which must not be
  # pushed under this milestone's gate evidence.
  local own=()
  for m in $(git rev-list --merges "$upstream..HEAD"); do
    git merge-base --is-ancestor "$m^2" "$sbranch" && own+=("$m")
  done
  for c in $(git rev-list "$upstream..HEAD"); do
    ok=0
    if git merge-base --is-ancestor "$c" "$sbranch"; then ok=1
    else
      for m in "${own[@]}"; do git merge-base --is-ancestor "$m" "$c" && { ok=1; break; }; done
      if (( ! ok )) && [[ -z "$(git rev-list --merges -n 1 "$c^!")" ]] \
        && [[ -z "$(git diff-tree --no-commit-id --name-only -r "$c" | grep -v '^\.milestones/' || true)" ]]; then ok=1; fi
    fi
    (( ok )) || refuse "branch $branch is ahead of its upstream with $(git log -1 --format='%h %s' "$c"), which is neither $sbranch's work nor on top of its earlier merge; push or reset that first"
  done

  # ---- the sandbox's own range: what agent-sandbox/<id> brings beyond the upstream
  local base report="$REPORT_DIR/milestone-$n.md" rblob bblob
  base="$(git merge-base "$upstream" "$sbranch")" || refuse "$sbranch shares no history with the upstream of $branch"
  # Supervisor files (STATUS.md cells, evaluation-N.md, config) come only from host
  # commits, which the ahead rule's .milestones-only allowance covers; a merge writes over an
  # ignored host file (an env file, seeded data) without a word.
  candidate_range_refusal "$base" "$sbranch" || refuse "$CANDIDATE_REFUSAL"
  # The report the sandbox gate checked with test -s: added or changed by this range, non-empty.
  rblob="$(git rev-parse -q --verify "$sbranch:$report" 2>/dev/null || true)"
  bblob="$(git rev-parse -q --verify "$base:$report" 2>/dev/null || true)"
  if [[ -z "$rblob" || "$rblob" == "$bblob" || "$(git cat-file -s "$rblob")" == 0 ]]; then
    refuse "$sbranch does not add or change a non-empty $report beyond the upstream"
  fi

  # ---- merge
  local merged_now=0
  if git merge-base --is-ancestor "$sbranch" HEAD; then
    pre="$upstream"
    log "  $sbranch already merged; re-checking and re-gating HEAD (nothing merged by this run)"
  else
    pre="$(git rev-parse HEAD)"
    log "  pre-merge $pre"
    merged_now=1
    # --no-overwrite-ignore: a second guard for the ignored-path check above.
    if ! git merge --no-ff --no-overwrite-ignore -q -m "Merge $sbranch: milestone $n (sandbox $id)" "$sbranch" > "$LOGS/integrate-$n.merge.log" 2>&1; then
      git merge --abort > /dev/null 2>&1 || true
      refuse "merging $sbranch hit a conflict or failed (see $LOGS/integrate-$n.merge.log); merge aborted, HEAD back at $pre"
    fi
    log "  merged $sbranch as $(git rev-parse --short=12 HEAD)"
  fi
  local head; head="$(git rev-parse HEAD)"
  recovery() {  # how to see or drop what stays local
    if (( merged_now )); then echo "the merge stays local. pre-merge $pre; to drop it: git reset --hard $pre"
    else echo "HEAD stays as it was (this run merged nothing); the unpushed commits: git log --oneline $upstream..HEAD"; fi
  }
  kept() {  # after the merge: a refusal or failure keeps the merge local
    log "integrate milestone $n: $*"
    log "  nothing pushed; $(recovery)"
  }

  # ---- weakening scan over everything about to be pushed
  unapproved_hits "$upstream" HEAD "$n" || { kept "refused: the weakening scan failed: $SCAN_ERROR"; exit 2; }
  if [[ -n "$HITS" ]]; then
    if [[ -n "$UNAPPROVED" ]]; then
      kept "refused: test weakening, test changes or gate-config changes with no owner approval of their current blob in .milestones/approvals/$n.md:"
      while IFS= read -r c; do log "    $c"; done <<< "$UNAPPROVED"
      log "  the owner approves each at a terminal (a report section approves nothing):"
      while IFS= read -r c; do log "    $c"; done < <(approve_commands "$n" <<< "$UNAPPROVED")
      exit 2
    fi
    log "  weakening hits all approved in .milestones/approvals/$n.md: $(tr '\n' ';' <<< "$HITS")"
  else
    log "  weakening scan: no hits in $upstream..HEAD"
  fi

  # ---- evaluation record
  local ev="EVALUATE_$n" evf=".milestones/evaluation-$n.md"
  if [[ "${!ev:-}" == 1 ]]; then
    local evcontent
    evcontent="$(git show "HEAD:$evf" 2>/dev/null)" || { kept "refused: EVALUATE_$n=1 and $evf is not committed"; exit 2; }
    if grep -qi 'owner action required' <<< "$evcontent"; then
      kept "refused: $evf still has a line marked owner action required"; exit 2
    fi
    log "  evaluation record $evf present, no owner action left"
  fi

  # ---- the gate, where INTEGRATE_GATE_WHERE says
  local grc=0 why=""
  GATE_FAILED_STEP=""; GATE_REFUSED=""; GATE_BUNDLE=""; GATE_NOSTART=""
  if [[ "$gwhere" == sandbox ]]; then sandbox_integration_gate "$n" "$head" "$(resolve_lane "$n")" || grc=$?
  else host_gate "$n" "$head" || grc=$?; fi
  [[ -z "$GATE_REFUSED" ]] || { kept "refused: $GATE_REFUSED"; exit 2; }
  if (( grc )); then
    why="${GATE_FAILED_STEP:+ at $GATE_FAILED_STEP}"; (( grc != 124 )) || why+=" (timed out after $GATE_TIMEOUT)"
    kept "$glabel FAILED$why; evidence: ${GATE_BUNDLE:-none${GATE_NOSTART:+ (could not start: $GATE_NOSTART)}}"
    exit 1
  fi
  bundle_sealed "$GATE_BUNDLE" || { kept "refused: $GATE_BUNDLE/evidence.json does not match its seal in chain.log"; exit 2; }

  # The checkout is shared: a commit or edit landing while the gate ran was never gated.
  if [[ "$(git rev-parse HEAD)" != "$head" || "$(git symbolic-ref --quiet --short HEAD || true)" != "$branch" \
        || -n "$(git status --porcelain --untracked-files=no -- . "${METADATA_EXCLUDES[@]}" || echo error)" ]]; then
    kept "refused: HEAD or the tracked tree changed while the $glabel ran; the gated commit is ${head:0:12}, HEAD is now $(git rev-parse --short=12 HEAD)"
    exit 2
  fi

  # ---- acceptance: every exit criterion has evidence on this gated identity, or an owner waiver
  if ! acceptance_complete "$n" "$GATE_TREE" "$GATE_DEF"; then
    acceptance_refusal "$n" "${GATE_BUNDLE#"$REPO"/}"
    log "  nothing pushed; $(recovery)"
    exit 2
  fi
  log "  acceptance: every exit criterion of milestone $n has evidence on tree ${GATE_TREE:0:12} def=${GATE_DEF:0:12}, or an owner waiver"

  # ---- STATUS.md, then push
  local sha12="${head:0:12}" lane final
  lane="$(resolve_lane "$n")"
  status_upsert "$n" "$lane" "$id" "$sha12" "pass $sha12 tree=${GATE_TREE:0:12} def=${GATE_DEF:0:12} $GATE_COUNTS $(date +%Y-%m-%d)"
  git add -- .milestones/STATUS.md
  if git diff --cached --quiet -- .milestones/STATUS.md; then
    log "  STATUS.md row for milestone $n unchanged"
    final="$(git rev-parse HEAD)"
    [[ "$final" == "$head" ]] || { kept "refused: HEAD moved off the gated commit ${head:0:12} before the push"; exit 2; }
  else
    git commit -q -m "milestone $n: STATUS.md after a passing $glabel on $sha12" -- .milestones/STATUS.md
    final="$(git rev-parse HEAD)"
    log "  STATUS.md row for milestone $n committed as ${final:0:12}"
    [[ "$(git rev-parse "$final^")" == "$head" ]] \
      || { kept "refused: the STATUS.md commit ${final:0:12} does not sit on the gated commit ${head:0:12}"; exit 2; }
  fi
  # The verified sha is pushed, not HEAD, so nothing landing after the check rides along.
  local prc=0
  timeout "$GATE_TIMEOUT" git push -q "$remote" "$final:$mref" > "$LOGS/integrate-$n.push.log" 2>&1 </dev/null || prc=$?
  if (( prc )); then
    local why="exit $prc"; (( prc == 124 )) && why="timed out after $GATE_TIMEOUT"
    log "integrate milestone $n: push failed ($why) to $remote $mref (see $LOGS/integrate-$n.push.log); the gated commit and STATUS commit stay local; $(recovery)"
    exit 1
  fi
  log "integrate milestone $n: pushed $branch to $remote as ${final:0:12} ($final) $(date -Is)"
}

# ---------------------------------------------------------------- mutate
# `mutate N <patch>` plants a defect in what integrate would gate and reports whether the
# gate steps reject it. Nothing touches the host checkout's HEAD, index or branches: the
# target is built in a temporary worktree, its commits are held by throwaway refs under
# MUTATE_REF_PREFIX, and every worktree, ref and sandbox it made is removed on every exit.
MUTATE_REF_PREFIX="refs/run-milestones/mutate/"

mutate_cleanup() {
  local d r
  if [[ -n "$MUTATE_TMP" ]]; then
    for d in "$MUTATE_TMP"/*/; do
      [[ -d "$d" ]] || continue
      git -C "$REPO" worktree remove --force "${d%/}" > /dev/null 2>&1 || true
    done
    rm -rf "$MUTATE_TMP"
    git -C "$REPO" worktree prune > /dev/null 2>&1 || true
    MUTATE_TMP=""
  fi
  # Only refs this run named under the prefix are deleted, never an empty or foreign name.
  for r in "${MUTATE_REFS[@]}"; do
    [[ "$r" == "$MUTATE_REF_PREFIX"?* && "$r" != *..* ]] || continue
    git -C "$REPO" update-ref -d "$r" > /dev/null 2>&1 || true
  done
  MUTATE_REFS=()
}

status_sandbox_cell() {
  # The Sandbox cell of milestone <n>'s STATUS.md row in the host checkout; empty when absent.
  local sfile="$REPO/.milestones/STATUS.md"
  [[ -f "$sfile" ]] || return 0
  awk -F'|' -v n="$1" '
    function t(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^[ \t]*\|/ && t($2) == n { v = t($4); if (v != "-") print v; exit }' "$sfile"
}

patch_criterion() {
  # The first "# criterion: <text>" line before the patch's first diff header.
  awk '/^(diff --git |--- |\+\+\+ |@@ )/ { exit }
    match($0, /^#[ \t]*criterion:[ \t]*/) { v = substr($0, RLENGTH + 1); sub(/[ \t\r]+$/, "", v); if (v != "") { print v; exit } }' "$1"
}

patch_paths() {
  # Every path patch <file> names, one per line: the diff --git header, ---/+++ lines and
  # rename/copy lines, outside hunk bodies, with a/ and b/ stripped and /dev/null skipped.
  python3 - "$1" <<'PY'
import re, sys

def unq(p):
    if len(p) >= 2 and p[0] == '"' and p[-1] == '"':
        p = p[1:-1].encode("latin-1", "backslashreplace").decode("unicode_escape").encode("latin-1", "replace").decode("utf-8", "replace")
    return p

def strip(p):
    return p[2:] if p[:2] in ("a/", "b/") else p

out, old, new = set(), 0, 0
for line in open(sys.argv[1], "rb").read().decode("utf-8", "replace").splitlines():
    if old > 0 or new > 0:  # a hunk body: its lines are content, never headers
        c = line[:1]
        if c == "\\":
            continue
        if c == "-":
            old -= 1
            continue
        if c == "+":
            new -= 1
            continue
        if c == " " or line == "":
            old -= 1
            new -= 1
            continue
        old = new = 0  # a short hunk: read the line as a header
    m = re.match(r"^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@", line)
    if m:
        old = int(m.group(1)) if m.group(1) is not None else 1
        new = int(m.group(2)) if m.group(2) is not None else 1
        continue
    if line.startswith(("--- ", "+++ ")):
        p = unq(line[4:].split("\t")[0])
        if p != "/dev/null":
            out.add(strip(p))
    elif line.startswith(("rename from ", "rename to ", "copy from ", "copy to ")):
        out.add(unq(line.split(" ", 2)[2]))
    elif line.startswith("diff --git "):
        rest = line[len("diff --git "):]
        q = re.match(r'^("(?:[^"\\]|\\.)*"|\S+) ("(?:[^"\\]|\\.)*"|.+)$', rest) if rest.startswith('"') else None
        if q:
            out.update((strip(unq(q.group(1))), strip(unq(q.group(2)))))
        elif rest.startswith("a/") and rest.rfind(" b/") > 0:
            i = rest.rfind(" b/")
            out.update((rest[2:i], rest[i + 3:]))
        else:
            out.add(rest)
for p in sorted(out):
    print(p)
PY
}

gate_named_paths() {
  # The repository-relative words of every step command, GATE_SETUP and GATE_ENV that could
  # name a file (split as the shell would, also at "="), one per line. A patch may not
  # change a file the gate itself runs, like a check script.
  python3 - "${ST_CMD[@]}" "$GATE_ENV" <<'PY'
import posixpath, shlex, sys
out = set()
for cmd in sys.argv[1:]:
    try:
        lx = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lx.whitespace_split = True
        words = list(lx)
    except ValueError:
        words = cmd.split()
    for w in words:
        for part in w.split("="):
            part = part.strip()
            if not part or part[0] in "-$/~" or "$" in part:
                continue
            p = posixpath.normpath(part)
            if p == "." or p == ".." or p.startswith("../"):
                continue
            out.add(p)
for p in sorted(out):
    print(p)
PY
}

mutate_path_refusal() {
  # Why patch path <path> may not be changed by a mutation, given the gate-named paths in
  # <named>; nothing when it may.
  local p="$1" named="$2"
  if [[ -z "$p" || "$p" == /* ]]; then echo "not a relative path"; return; fi
  if [[ "/$p/" == */../* || "/$p/" == */./* ]]; then echo "outside the repository"; return; fi
  if [[ "/$p/" == */.git/* ]]; then echo "git's own files"; return; fi
  if [[ "$p" == .milestones || "$p" == .milestones/* ]]; then echo "a supervisor file under .milestones/"; return; fi
  if path_matches "$p" "$GATE_DEFINITION_GLOBS"; then echo "a gate definition file (GATE_DEFINITION_GLOBS)"; return; fi
  if grep -qxF -- "$p" <<< "$named"; then echo "a file a gate step, GATE_SETUP or GATE_ENV names"; fi
  return 0
}

mutate_gate() {
  # mutate_gate <milestone> <sha> <where> <label>: one gate run of <sha> on the route
  # INTEGRATE_GATE_WHERE names. host-mutate: a temporary worktree (host_gate).
  # sandbox-mutate: a fresh sandbox created from a temporary seeded worktree at <sha>,
  # removed after. Returns the run's exit; GATE_BUNDLE is empty when no bundle was written.
  local n="$1" sha="$2" where="$3" label="$4" rc=0 src
  GATE_FAILED_STEP=""; GATE_REFUSED=""; GATE_BUNDLE=""; GATE_ADMISSION=0; GATE_NOSTART=""
  if [[ "$where" == host-mutate ]]; then
    host_gate "$n" "$sha" host-mutate || rc=$?
    return "$rc"
  fi
  src="$MUTATE_TMP/src-$label"
  git worktree add -q --detach "$src" "$sha" > /dev/null 2>&1 || { log "  could not add a worktree of ${sha:0:12}"; return 1; }
  seed_worktree "$src"
  sandbox_integration_gate "$n" "$sha" "$(resolve_lane "$n")" "$src" sandbox-mutate || rc=$?
  git worktree remove --force "$src" > /dev/null 2>&1 || true
  return "$rc"
}

do_mutate() {
  local n="${MILESTONES[0]:-}" patch="$MUTATE_PATCH" ref="$MUTATE_REF" usage
  usage="mutate N <patch> [--ref REF] [--steps name,name] [--sandbox ID]"
  [[ "$n" =~ ^[0-9]+$ ]] || die "mutate needs a milestone number: $usage"
  [[ -n "$patch" ]] || die "mutate needs a patch file: $usage"
  [[ -f "$patch" && -r "$patch" ]] || die "mutate: no readable patch file $patch"
  [[ "$ref" != -* ]] || die "mutate: --ref '$ref' is not a ref"
  require_gate
  arm_cleanup
  local patch_abs patch_rel
  patch_abs="$(readlink -f -- "$patch")"; patch_rel="${patch_abs#"$REPO"/}"
  log "=== mutate milestone $n with $patch_rel: $(date -Is) ==="
  merr() { log "mutate milestone $n: $*; no record written"; exit 2; }
  mrefuse() { log "mutate milestone $n refused: $*; no record written"; exit 2; }

  local where gwhere="${INTEGRATE_GATE_WHERE:-host}"
  case "$gwhere" in
    host) where=host-mutate ;;
    sandbox) where=sandbox-mutate ;;
    *) mrefuse "INTEGRATE_GATE_WHERE=$gwhere: want host or sandbox" ;;
  esac

  # ---- the steps: all, or --steps (setup always runs when GATE_SETUP is set)
  local sel="" s k found names=()
  if [[ -n "$MUTATE_STEPS" ]]; then
    IFS=, read -r -a names <<< "$MUTATE_STEPS"
    for s in "${names[@]}"; do
      [[ -n "$s" ]] || continue
      found=0
      for k in "${!ST_NAME[@]}"; do [[ "${ST_NAME[k]}" != "$s" ]] || found=1; done
      (( found )) || merr "--steps: no gate step named '$s' (the steps: ${ST_NAME[*]})"
      [[ " $sel " == *" $s "* ]] || sel+="${sel:+ }$s"
    done
    [[ -n "$sel" ]] || merr "--steps names no step"
  fi

  # ---- the candidate: milestone N's sandbox branch
  local id cell tag sbranch
  cell="$(status_sandbox_cell "$n")"
  if [[ -n "$cell" ]]; then
    [[ -z "$SANDBOX" || "$SANDBOX" == "$cell" ]] || mrefuse "STATUS.md names sandbox $cell for milestone $n, not --sandbox $SANDBOX"
    id="$cell"
  else
    id="$SANDBOX"
  fi
  [[ -n "$id" ]] || merr "STATUS.md names no sandbox for milestone $n; name it with --sandbox ID"
  [[ "$id" =~ $SANDBOX_ID_RE && "$id" != *..* ]] || mrefuse "'$id' is not a sandbox id (letters, digits, . _ -, at most 128, no '..')"
  tag="$(sandbox_milestone_tag "$id")"
  [[ -z "$tag" || "$tag" == "$n" ]] || mrefuse "sandbox $id is tagged milestone $tag, not $n"
  sbranch="agent-sandbox/$id"
  git rev-parse --quiet --verify "refs/heads/$sbranch^{commit}" > /dev/null || merr "no branch $sbranch in $REPO"

  # ---- the target base: --ref, else the integration branch head (INTEGRATION_BRANCH, else
  # the checked-out branch). The scans run from its upstream, as integrate's do.
  local base_sha against branch=""
  if [[ -n "$ref" ]]; then
    base_sha="$(git rev-parse --quiet --verify "$ref^{commit}")" || merr "--ref $ref is not a commit"
    against="$base_sha"
  else
    branch="${INTEGRATION_BRANCH:-}"
    if [[ -z "$branch" ]]; then
      branch="$(git symbolic-ref --quiet --short HEAD)" || merr "HEAD is detached and INTEGRATION_BRANCH is unset; name the target base with --ref"
    fi
    base_sha="$(git rev-parse --quiet --verify "refs/heads/$branch^{commit}")" || merr "no integration branch $branch"
    against="$(git rev-parse --quiet --verify "$branch@{upstream}" 2> /dev/null)" || against="$base_sha"
  fi
  local mbase
  mbase="$(git merge-base "$against" "$sbranch")" || mrefuse "$sbranch shares no history with ${against:0:12}"
  candidate_range_refusal "$mbase" "$sbranch" || mrefuse "$CANDIDATE_REFUSAL"

  # ---- the patch: a cited criterion, and no path the gate or the supervisor owns
  local criterion paths named p why bad=()
  criterion="$(patch_criterion "$patch_abs")"
  [[ -n "$criterion" ]] || merr "$patch_rel has no '# criterion: <exit criterion text or index>' line before its first diff; a mutation cites the exit criterion it breaks"
  paths="$(patch_paths "$patch_abs")" || merr "could not read the paths $patch_rel changes"
  [[ -n "$paths" ]] || merr "$patch_rel names no file"
  named="$(gate_named_paths)" || merr "could not read the paths the gate commands name"
  while IFS= read -r p; do
    why="$(mutate_path_refusal "$p" "$named")"
    [[ -z "$why" ]] || bad+=("$p ($why)")
  done <<< "$paths"
  (( ${#bad[@]} == 0 )) || mrefuse "the patch changes paths a mutation may not: ${bad[*]}"

  # ---- the target tree: a temporary merge, then the patched commit on top of it
  local build stamp target patched bref pref gitid=(-c user.name=run-milestones -c user.email=run-milestones@localhost -c commit.gpgsign=false)
  MUTATE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/mutate-$PROJECT-$n.XXXXXX")"
  build="$MUTATE_TMP/build"; stamp="$(date +%Y%m%dT%H%M%S)-$$"
  git worktree add -q --detach "$build" "$base_sha" > /dev/null 2>&1 || merr "could not add a worktree of ${base_sha:0:12}"
  if git merge-base --is-ancestor "$sbranch" "$base_sha"; then
    log "  $sbranch is already in ${base_sha:0:12}; the target is that commit"
  elif ! git -C "$build" "${gitid[@]}" merge --no-ff --no-verify --no-overwrite-ignore -q \
         -m "mutate: merge $sbranch for milestone $n" "$sbranch" > "$MUTATE_TMP/merge.log" 2>&1; then
    merr "merging $sbranch into ${base_sha:0:12} failed: $(tail -n 3 "$MUTATE_TMP/merge.log" | tr '\n' ' ')"
  fi
  target="$(git -C "$build" rev-parse HEAD)"
  bref="${MUTATE_REF_PREFIX}$n-$stamp/baseline"; MUTATE_REFS+=("$bref")
  git update-ref "$bref" "$target" || merr "could not hold ${target:0:12} under $bref"
  log "  target ${target:0:12}: $sbranch merged into ${base_sha:0:12}${ref:+ (--ref $ref)}${branch:+ ($branch)}"

  unapproved_hits "$against" "$target" "$n" || mrefuse "the weakening scan failed: $SCAN_ERROR"
  if [[ -n "$UNAPPROVED" ]]; then
    log "mutate milestone $n refused: test weakening, test changes or gate-config changes with no owner approval of their current blob in .milestones/approvals/$n.md:"
    while IFS= read -r p; do log "    $p"; done <<< "$UNAPPROVED"
    log "  no record written"; exit 2
  fi

  if ! git -C "$build" apply --check "$patch_abs" > "$MUTATE_TMP/apply.log" 2>&1; then
    log "mutate milestone $n: $patch_rel does not apply to ${target:0:12}:"
    while IFS= read -r p; do log "    $p"; done < "$MUTATE_TMP/apply.log"
    log "  no record written"; exit 2
  fi
  git -C "$build" apply --index "$patch_abs" > "$MUTATE_TMP/apply.log" 2>&1 \
    || merr "applying $patch_rel failed: $(tail -n 3 "$MUTATE_TMP/apply.log" | tr '\n' ' ')"
  git -C "$build" "${gitid[@]}" commit --no-verify -q -m "mutate: $patch_rel (criterion: $criterion)" > "$MUTATE_TMP/commit.log" 2>&1 \
    || merr "$patch_rel changes nothing in ${target:0:12}"
  patched="$(git -C "$build" rev-parse HEAD)"
  pref="${MUTATE_REF_PREFIX}$n-$stamp/patched"; MUTATE_REFS+=("$pref")
  git update-ref "$pref" "$patched" || merr "could not hold ${patched:0:12} under $pref"
  git worktree remove --force "$build" > /dev/null 2>&1 || true

  # ---- baseline: the selected steps on the unpatched target must pass
  local brc=0 bbundle btree bdef bseal
  GATE_SELECT="$sel"; GATE_KEEP_GOING=0
  log "  baseline run on ${target:0:12} ($where${sel:+, steps: $sel})"
  mutate_gate "$n" "$target" "$where" baseline || brc=$?
  bbundle="$GATE_BUNDLE"; btree="$GATE_TREE"; bdef="$GATE_DEF"
  [[ -z "$GATE_REFUSED" ]] || merr "baseline: $GATE_REFUSED"
  [[ -n "$bbundle" || "$brc" != 3 ]] || merr "the baseline sandbox was not admitted"
  [[ -n "$bbundle" ]] || merr "the baseline run could not start${GATE_FAILED_STEP:+ ($GATE_FAILED_STEP)}${GATE_NOSTART:+: $GATE_NOSTART}"
  (( ! GATE_ADMISSION )) || merr "a baseline step was not admitted (evidence: ${bbundle#"$REPO"/})"
  (( brc == 0 )) || merr "the baseline failed (exit $brc${GATE_FAILED_STEP:+ at $GATE_FAILED_STEP}) on the unpatched target ${target:0:12}; a mutation needs a passing baseline (evidence: ${bbundle#"$REPO"/})"
  bundle_sealed "$bbundle" || merr "the baseline bundle ${bbundle#"$REPO"/} does not match its seal"
  bseal="$(seal_of "$bbundle")"

  # ---- patched: the same steps, every one run, on the patched commit
  local prc=0 pbundle pseal pcounts
  GATE_SELECT="$sel"; GATE_KEEP_GOING=1
  log "  patched run on ${patched:0:12}"
  mutate_gate "$n" "$patched" "$where" patched || prc=$?
  GATE_SELECT=""; GATE_KEEP_GOING=0
  pbundle="$GATE_BUNDLE"; pcounts="$GATE_COUNTS"
  [[ -z "$GATE_REFUSED" ]] || merr "patched: $GATE_REFUSED"
  [[ -n "$pbundle" || "$prc" != 3 ]] || merr "the patched sandbox was not admitted"
  [[ -n "$pbundle" ]] || merr "the patched run could not start${GATE_FAILED_STEP:+ ($GATE_FAILED_STEP)}${GATE_NOSTART:+: $GATE_NOSTART}"
  (( ! GATE_ADMISSION )) || merr "a patched step was not admitted (evidence: ${pbundle#"$REPO"/})"
  bundle_sealed "$pbundle" || merr "the patched bundle ${pbundle#"$REPO"/} does not match its seal"
  [[ "$GATE_DEF" == "$bdef" ]] || merr "the gate definition changed between the baseline and patched runs"
  pseal="$(seal_of "$pbundle")"
  log "  patched run exit $prc${GATE_FAILED_STEP:+ (first failure at $GATE_FAILED_STEP)}"

  # ---- verdict (R7), record, events
  local out verdict step at live line
  out="$(python3 - "$pbundle/evidence.json" <<'PY'
import json, sys
steps = json.load(open(sys.argv[1]))["steps"]
real = ("integration", "replay")
fails = [s for s in steps if s["status"] == "fail"]
real_fail = [s for s in fails if s["kind"] in real]
real_unrun = [s for s in steps if s["kind"] in real and s["status"].startswith("not run") and s["status"] != "not run: not selected"]
if real_fail:
    print("caught", real_fail[0]["name"])
elif real_unrun:
    print("inconclusive", fails[0]["name"] if fails else "-")
elif fails:
    print("caught-static", fails[0]["name"])
else:
    print("missed", "-")
PY
)" || merr "could not read ${pbundle#"$REPO"/}/evidence.json"
  read -r verdict step <<< "$out"
  case "$verdict" in
    caught) MUTATE_EXIT=0 ;;
    caught-static|missed) MUTATE_EXIT=1 ;;
    inconclusive) MUTATE_EXIT=3 ;;
    *) merr "no verdict from ${pbundle#"$REPO"/}/evidence.json" ;;
  esac
  at="$(date -Is)"; live="$(gate_definition_hash)"
  line="mutate milestone=$n verdict=$verdict failing_step=$step exit=$MUTATE_EXIT criterion=\"${criterion//\"/\'}\" patch=$patch_rel sha=${target:0:12} tree=${btree:0:12} def=${bdef:0:12} where=$where baseline=${bbundle#"$REPO"/} patched=${pbundle#"$REPO"/} at=$at"
  mkdir -p "$REPO/.milestones/mutations"
  local rec_rc=0 grade events
  events="$(python3 - "$REPO/.milestones/mutations/$n.jsonl" "$n" "$id" "$patch_rel" "$criterion" "$verdict" "$step" \
      "$sel" "$(IFS=' '; echo "${ST_NAME[*]}")" "$where" "${ref:-${branch}}" "$target" "$btree" "$patched" \
      "${bbundle#"$REPO"/}" "$bseal" "${pbundle#"$REPO"/}" "$pseal" "$bdef" "$live" "$at" "$MUTATE_EXIT" "$line" "$pcounts" \
      "$pbundle/evidence.json" <<'PY'
import json, sys
(path, n, sandbox, patch, criterion, verdict, step, sel, allsteps, where, base, sha, tree, patched,
 bb, bs, pb, ps, dh, live, at, code, line, counts, pev) = sys.argv[1:]
ev = json.load(open(pev))
names = sel.split() if sel else [s for s in allsteps.split() if s != "setup"]
rec = {"milestone": int(n), "sandbox": sandbox, "patch": patch, "criterion": criterion, "verdict": verdict,
       "failing_step": None if step == "-" else step, "steps": names, "where": where, "base": base,
       "sha": sha, "tree": tree, "patched_sha": patched, "patched_tree": ev.get("tree"),
       "baseline_bundle": bb, "baseline_seal": bs, "patched_bundle": pb, "patched_seal": ps,
       "definition_hash": dh, "produced_by": "mutate", "at": at}
with open(path, "a") as f:
    f.write(json.dumps(rec) + "\n")
change = "milestone:" + n
not_run = sum(1 for s in ev["steps"] if s["status"].startswith("not run"))
proof = {"control": "mutate", "attempt": patch, "criterion": criterion, "expected": "caught", "observed": verdict,
         "exit_code": int(code), "outcome_line": line, "demonstrated": dh == live, "gate_hash": dh,
         "live_gate_hash": live, "sha": sha, "tree": tree, "seal": ps, "bundle": pb, "where": where,
         "dirty": bool(ev.get("dirty")), "not_run": not_run, "steps": counts, "produced_by": "mutate", "at": at}
print("control-proof\t" + json.dumps(proof))
if verdict == "caught":
    finding = {"stage": "mutate", "confirmation": "executable",
               "title": "planted defect %s (criterion %s)" % (patch, criterion), "step": step, "bundle": pb,
               "detail": "caught by step %s on %s" % (step, where), "at": at}
    print("finding\t" + json.dumps(finding))
PY
)" || rec_rc=$?
  (( rec_rc == 0 )) || merr "could not write .milestones/mutations/$n.jsonl"
  log "$line"
  grade="$(dirname "$SELF")/grade.py"
  local kind js
  while IFS=$'\t' read -r kind js; do
    [[ -n "$kind" ]] || continue
    if [[ ! -f "$grade" ]]; then log "  no grade.py beside the driver; $kind event not written"; continue; fi
    python3 "$grade" event "$kind" --change "milestone:$n" --project "$REPO" --no-mlflow --json "$js" >> "$CHAIN" 2>&1 \
      || log "  grade.py refused the $kind event (see chain.log); the mutation record stands"
  done <<< "$events"
}

# ---------------------------------------------------------------- accept and approve
# .milestones/acceptance/N.json, written by `accept`:
#   {"schema": 1, "milestone": N, "source": {"file": MILESTONES_FILE, "blob": <its git blob id>},
#    "criteria": [{"id": "N.c<i>", "text": "...", "evidence": null | {...}, "context": [...]}]}
# evidence of a passing step:  {"kind": "bundle", "bundle", "step", "tests", "seal", "sha", "tree",
#                               "definition_hash", "where", "recorded_at"}
# evidence of a caught mutation: {"kind": "mutation", "record": <line>, "patch", "criterion",
#                               "baseline_bundle", "baseline_seal", "patched_bundle", "patched_seal",
#                               "tree", "definition_hash", "recorded_at"}
# context: [{"source": "evaluator", "text", "at"}], reviewer-grade and never evidence. There is no
# waiver field: a criterion is waived only by a criterion-waiver approval (approve).

milestone_criteria() {
  # milestone_criteria <n>: milestone <n>'s exit criteria as a JSON array of strings, from the
  # section's paragraph that begins "Exit:" (up to a blank line or a heading), split at semicolons
  # and at sentence ends (".", "!" or "?" followed by the end or by a space and a word that does
  # not start lowercase), never inside (), [], {} or `code`. Errors go to stderr and return 1.
  local sec
  [[ -f "$REPO/$MILESTONES_FILE" ]] || { echo "no milestones file $MILESTONES_FILE" >&2; return 1; }
  sec="$(milestone_section "$1")" || { echo "could not read $MILESTONES_FILE" >&2; return 1; }
  [[ -n "$sec" ]] || { echo "no '## Milestone $1' section in $MILESTONES_FILE" >&2; return 1; }
  python3 -c '
import json, re, sys
lines = sys.stdin.read().split("\n")
start = next((i for i, l in enumerate(lines) if re.match(r"^\s*Exit:", l)), None)
if start is None:
    sys.exit("the milestone section has no paragraph beginning Exit:")
para = []
for l in lines[start:]:
    if not l.strip() or l.startswith("#"):
        break
    para.append(l.strip())
s = re.sub(r"^Exit:\s*", "", re.sub(r"\s+", " ", " ".join(para)))
out, cur, depth, code = [], "", 0, False
for i, c in enumerate(s):
    cur += c
    if c == "`":
        code = not code
    elif code:
        continue
    elif c in "([{":
        depth += 1
    elif c in ")]}":
        depth = max(0, depth - 1)
    elif depth == 0 and (c == ";" or (c in ".!?" and re.match(r"\s*$|\s+[^a-z]", s[i + 1:]))):
        out.append(cur)
        cur = ""
out.append(cur)
crit = [x for x in (re.sub(r"[\s;.!?]+$", "", x).strip() for x in out) if x]
if not crit:
    sys.exit("the Exit: paragraph holds no criterion")
print(json.dumps(crit))' <<< "$sec"
}

accept_bundle_evidence() {
  # accept_bundle_evidence <n> <bundle>#<step>:<test id>[,<test id>...]: the evidence object as JSON
  # on stdout, or the reason on stdout and 1. The bundle must be sealed now, milestone <n>'s,
  # produced by integrate (host-integrate or sandbox-integration), clean, with the step passed, the
  # step log matching its sealed sha256, and every test id in that log as a whole token.
  local n="$1" spec="$2" path rest step tests rel
  [[ "$spec" == *"#"*":"* ]] || { echo "want bundle:<bundle>#<step>:<test id>[,<test id>...]"; return 1; }
  path="${spec%%#*}"; rest="${spec#*#}"; step="${rest%%:*}"; tests="${rest#*:}"
  rel="${path#"$REPO"/}"; rel="${rel%/}"
  if [[ ! "$rel" =~ ^logs/milestones/evidence/[A-Za-z0-9._-]+$ || "$rel" == *..* ]]; then
    echo "$path is not a bundle directly under logs/milestones/evidence/"; return 1
  fi
  [[ -f "$REPO/$rel/evidence.json" ]] || { echo "no bundle $rel"; return 1; }
  bundle_sealed "$rel" || { echo "$rel/evidence.json does not match exactly one seal in chain.log (unsealed or altered)"; return 1; }
  python3 - "$REPO/$rel" "$rel" "$n" "$step" "$tests" "$(seal_of "$rel")" <<'PY'
import hashlib, json, os, re, sys
b, rel, n, step, tests, seal = sys.argv[1:]
def no(msg):
    print(msg)
    sys.exit(1)
try:
    d = json.load(open(os.path.join(b, "evidence.json")))
except Exception as e:
    no("cannot read %s/evidence.json: %s" % (rel, e))
if str(d.get("milestone")) != n:
    no("%s is milestone %s's bundle, not %s's" % (rel, d.get("milestone"), n))
if d.get("produced_by") != "integrate" or d.get("where") not in ("host-integrate", "sandbox-integration"):
    no("%s was produced by %s at %s; only an integrate bundle (host-integrate or sandbox-integration) is evidence" % (rel, d.get("produced_by"), d.get("where")))
if d.get("dirty") is not False:
    no("%s is dirty; a dirty bundle is never evidence" % rel)
ids = tests.split(",")
if any(not t.strip() for t in ids):
    no("name one or more test ids, comma separated, none empty")
st = [s for s in d.get("steps") or [] if isinstance(s, dict) and s.get("name") == step]
if len(st) != 1:
    no("%s has no step named %s (its steps: %s)" % (rel, step, " ".join(str(s.get("name")) for s in d.get("steps") or [] if isinstance(s, dict))))
s = st[0]
if s.get("status") != "pass":
    no("step %s in %s did not pass (%s)" % (step, rel, s.get("status")))
log = s.get("log") or ""
if not re.match(r"^steps/[A-Za-z0-9._-]+\.log$", log) or not os.path.isfile(os.path.join(b, log)):
    no("step %s has no log in %s" % (step, rel))
data = open(os.path.join(b, log), "rb").read()
if not s.get("log_sha256") or hashlib.sha256(data).hexdigest() != s.get("log_sha256"):
    no("the log of step %s does not match the sha256 sealed in %s/evidence.json" % (step, rel))
text = data.decode("utf-8", "replace")
missing = [t for t in ids if not re.search(r"(?<![A-Za-z0-9_])" + re.escape(t) + r"(?![A-Za-z0-9_])", text)]
if missing:
    no("test ids absent from step %s's log: %s" % (step, ", ".join(missing)))
tree, dh = d.get("tree"), d.get("definition_hash")
if not (isinstance(tree, str) and re.match(r"^[0-9a-f]{40,64}$", tree) and isinstance(dh, str) and re.match(r"^[0-9a-f]{64}$", dh)):
    no("%s lacks a tree or a definition hash" % rel)
print(json.dumps({"kind": "bundle", "bundle": rel, "step": step, "tests": ids, "seal": seal, "sha": d.get("sha"),
                  "tree": tree, "definition_hash": dh, "where": d.get("where")}))
PY
}

accept_mutation_evidence() {
  # accept_mutation_evidence <n> <criterion id> <line number or patched seal>: the evidence object as
  # JSON on stdout, or the reason and 1. The record in .milestones/mutations/<n>.jsonl must be
  # milestone <n>'s, verdict caught, citing the criterion (its id, its index, "<id or index>: ..."
  # or its text), with both bundles sealed now at the seals the record holds.
  local n="$1" cid="$2" sel="$3" out bb bs pb ps ev
  out="$(python3 - "$REPO/.milestones/mutations/$n.jsonl" "$REPO/.milestones/acceptance/$n.json" "$n" "$cid" "$sel" <<'PY'
import json, re, sys
mf, af, n, cid, sel = sys.argv[1:]
def no(msg):
    print(msg)
    sys.exit(1)
try:
    crit = [c for c in json.load(open(af))["criteria"] if c.get("id") == cid]
    lines = open(mf).read().split("\n")
except Exception as e:
    no("cannot read the mutation records or the acceptance record: %s" % e)
if len(crit) != 1:
    no("no criterion %s in the acceptance record" % cid)
idx, text = cid.split(".c", 1)[1], crit[0].get("text")
recs = []
for i, l in enumerate(lines, 1):
    if not l.strip():
        continue
    try:
        r = json.loads(l)
    except Exception:
        r = None
    if (re.match(r"^[0-9]+$", sel) and i == int(sel)) or (re.match(r"^[0-9a-f]{64}$", sel) and isinstance(r, dict) and r.get("patched_seal") == sel):
        recs.append((i, r))
if not re.match(r"^([0-9]+|[0-9a-f]{64})$", sel):
    no("mutation:<line number of .milestones/mutations/%s.jsonl or a patched seal>" % n)
if len(recs) != 1 or not isinstance(recs[0][1], dict):
    no("mutation:%s selects %d readable records in .milestones/mutations/%s.jsonl" % (sel, len(recs), n))
line, r = recs[0]
if str(r.get("milestone")) != n:
    no("record %d is milestone %s's" % (line, r.get("milestone")))
if r.get("verdict") != "caught":
    no("record %d's verdict is %s; only a caught mutation is evidence" % (line, r.get("verdict")))
c = str(r.get("criterion") or "")
if not (c in (cid, idx, text) or re.match(r"^(%s|%s)\s*[:)]" % (re.escape(cid), re.escape(idx)), c)):
    no("record %d cites criterion '%s', not %s" % (line, c, cid))
for k in ("baseline_bundle", "patched_bundle"):
    if not re.match(r"^logs/milestones/evidence/[A-Za-z0-9._-]+$", str(r.get(k))) or ".." in str(r.get(k)):
        no("record %d's %s is not a bundle path" % (line, k))
if not (re.match(r"^[0-9a-f]{40,64}$", str(r.get("tree"))) and re.match(r"^[0-9a-f]{64}$", str(r.get("definition_hash")))):
    no("record %d lacks a tree or a definition hash" % line)
ev = {"kind": "mutation", "record": line, "patch": r.get("patch"), "criterion": c,
      "baseline_bundle": r["baseline_bundle"], "baseline_seal": r.get("baseline_seal"),
      "patched_bundle": r["patched_bundle"], "patched_seal": r.get("patched_seal"),
      "tree": r["tree"], "definition_hash": r["definition_hash"]}
print("\t".join([r["baseline_bundle"], str(r.get("baseline_seal")), r["patched_bundle"], str(r.get("patched_seal")), json.dumps(ev)]))
PY
)" || { echo "$out"; return 1; }
  IFS=$'\t' read -r bb bs pb ps ev <<< "$out"
  if ! bundle_sealed "$bb" || [[ "$(seal_of "$bb")" != "$bs" ]]; then echo "the baseline bundle $bb does not match the seal the record holds"; return 1; fi
  if ! bundle_sealed "$pb" || [[ "$(seal_of "$pb")" != "$ps" ]]; then echo "the patched bundle $pb does not match the seal the record holds"; return 1; fi
  echo "$ev"
}

do_accept() {
  local n="${MILESTONES[0]:-}" usage rel f
  usage="accept N --init [--force] | accept N --criterion N.c<i> [--evidence bundle:<bundle>#<step>:<test id>[,<test id>...] | --evidence mutation:<line or patched seal>] [--context evaluator:<text>]"
  [[ "$n" =~ ^[0-9]+$ ]] || die "accept needs a milestone number: $usage"
  rel=".milestones/acceptance/$n.json"; f="$REPO/$rel"
  if (( ACCEPT_INIT )); then
    [[ -z "$ACCEPT_CRITERION$ACCEPT_EVIDENCE$ACCEPT_CONTEXT" ]] || die "accept --init takes no --criterion, --evidence or --context: $usage"
    if [[ -e "$f" ]] && (( ! ACCEPT_FORCE )); then
      die "accept: $rel exists; accept $n --init --force replaces it and drops its evidence and context"
    fi
    local blob crit out
    [[ -f "$REPO/$MILESTONES_FILE" ]] || die "accept: no milestones file $MILESTONES_FILE (MILESTONES_FILE in .milestones/config); nothing written"
    blob="$(git hash-object -- "$REPO/$MILESTONES_FILE")" && [[ "$blob" =~ ^[0-9a-f]{40,64}$ ]] \
      || die "accept: git hash-object $MILESTONES_FILE failed; nothing written"
    crit="$(milestone_criteria "$n" 2>&1)" || die "accept milestone $n: $crit; nothing written"
    mkdir -p "$(dirname "$f")" || die "accept: cannot create $(dirname "$rel")"
    out="$(python3 - "$f" "$n" "$MILESTONES_FILE" "$blob" "$crit" <<'PY'
import json, os, sys
f, n, src, blob, crit = sys.argv[1:]
doc = {"schema": 1, "milestone": int(n), "source": {"file": src, "blob": blob},
       "criteria": [{"id": "%s.c%d" % (n, i + 1), "text": t, "evidence": None, "context": []}
                    for i, t in enumerate(json.loads(crit))]}
with open(f + ".tmp", "w") as o:
    json.dump(doc, o, indent=2)
    o.write("\n")
os.replace(f + ".tmp", f)
for c in doc["criteria"]:
    print("  %s  %s" % (c["id"], c["text"]))
PY
)" || die "accept: could not write $rel"
    log "accept milestone $n: $rel written from $MILESTONES_FILE (blob ${blob:0:12}), $(grep -c . <<< "$out") criteria"
    echo "$out"
    return 0
  fi

  (( ! ACCEPT_FORCE )) || die "--force belongs to accept N --init"
  [[ -n "$ACCEPT_CRITERION" ]] || die "accept: name the criterion: $usage"
  [[ -n "$ACCEPT_EVIDENCE$ACCEPT_CONTEXT" ]] || die "accept: give --evidence or --context: $usage"
  [[ "$ACCEPT_CRITERION" =~ ^$n\.c[0-9]+$ ]] || die "accept: '$ACCEPT_CRITERION' is not a criterion id of milestone $n (N.c<i>)"
  [[ -f "$f" ]] || die "accept: no $rel; run accept $n --init first"
  [[ -z "$ACCEPT_CONTEXT" || "$ACCEPT_CONTEXT" == evaluator:?* ]] || die "accept: --context is evaluator:<text>; context is recorded beside a criterion and is never evidence"
  local ev="" why
  case "$ACCEPT_EVIDENCE" in
    "") ;;
    bundle:*)   ev="$(accept_bundle_evidence "$n" "${ACCEPT_EVIDENCE#bundle:}")" || { why="$ev"; log "accept milestone $n refused for $ACCEPT_CRITERION: $why"; exit 2; } ;;
    mutation:*) ev="$(accept_mutation_evidence "$n" "$ACCEPT_CRITERION" "${ACCEPT_EVIDENCE#mutation:}")" || { why="$ev"; log "accept milestone $n refused for $ACCEPT_CRITERION: $why"; exit 2; } ;;
    *) die "accept: --evidence is bundle:<bundle>#<step>:<test ids> or mutation:<line or patched seal>" ;;
  esac
  why="$(python3 - "$f" "$n" "$ACCEPT_CRITERION" "$ev" "${ACCEPT_CONTEXT#evaluator:}" "$(date -Is)" <<'PY'
import json, os, sys
f, n, cid, ev, ctx, at = sys.argv[1:]
try:
    doc = json.load(open(f))
    crit = [c for c in doc["criteria"] if isinstance(c, dict) and c.get("id") == cid]
except Exception as e:
    print("cannot read %s: %s" % (f, e))
    sys.exit(1)
if str(doc.get("milestone")) != n or len(crit) != 1:
    print("no criterion %s in %s" % (cid, f))
    sys.exit(1)
c = crit[0]
if ev:
    e = json.loads(ev)
    e["recorded_at"] = at
    c["evidence"] = e
if ctx:
    c.setdefault("context", []).append({"source": "evaluator", "text": ctx, "at": at})
with open(f + ".tmp", "w") as o:
    json.dump(doc, o, indent=2)
    o.write("\n")
os.replace(f + ".tmp", f)
PY
)" || { log "accept milestone $n refused for $ACCEPT_CRITERION: $why"; exit 2; }
  [[ -z "$ev" ]] || log "accept milestone $n: $ACCEPT_CRITERION evidence $ACCEPT_EVIDENCE"
  [[ -z "$ACCEPT_CONTEXT" ]] || log "accept milestone $n: $ACCEPT_CRITERION evaluator context recorded (context, not evidence)"
}

ACCEPT_STATE=""; ACCEPT_UNMET=""; ACCEPT_IDS=""
acceptance_complete() {
  # acceptance_complete <n> <tree> <definition hash>: 0 when every criterion in
  # .milestones/acceptance/<n>.json, whose criteria still equal the Exit paragraph's, has evidence
  # recorded on exactly <tree> and <definition hash> whose seals still hold, or is waived by a
  # criterion-waiver approval committed at HEAD. Otherwise 1, with ACCEPT_STATE (missing, invalid,
  # incomplete or error), ACCEPT_UNMET ("<id>: <why>" lines, or the one reason) and ACCEPT_IDS
  # (the ids that still need evidence). This is the boundary `integrate --evidence` reuses.
  local n="$1" tree="$2" def="$3" f="$REPO/.milestones/acceptance/$1.json" approvals waived fresh out kind id a b c d
  ACCEPT_STATE=""; ACCEPT_UNMET=""; ACCEPT_IDS=""
  fresh="$(milestone_criteria "$n" 2>&1)" \
    || { ACCEPT_STATE=error; ACCEPT_UNMET="the exit criteria cannot be read from $MILESTONES_FILE: $fresh"; return 1; }
  if [[ ! -f "$f" ]]; then
    ACCEPT_STATE=missing
    ACCEPT_IDS="$(python3 -c 'import json, sys; print(" ".join("%s.c%d" % (sys.argv[1], i + 1) for i in range(len(json.loads(sys.argv[2])))))' "$n" "$fresh")"
    return 1
  fi
  approvals="$(approval_entries "$n" HEAD)" \
    || { ACCEPT_STATE=error; ACCEPT_UNMET="could not read .milestones/approvals/$n.md at HEAD"; return 1; }
  waived="$(awk -F'\t' '$1 == "criterion-waiver" { print $6 }' <<< "$approvals")"
  out="$(python3 - "$f" "$n" "$tree" "$def" "$fresh" "$waived" <<'PY'
import json, sys
f, n, tree, dh, fresh, waived = sys.argv[1:]
waived = set(waived.split())
try:
    doc = json.load(open(f))
    crit = doc["criteria"]
    have = [(c["id"], c["text"]) for c in crit]
except Exception as e:
    print("invalid\t-\t%s is not a readable acceptance record (%s)" % (f, e))
    sys.exit(0)
if str(doc.get("milestone")) != n or not crit:
    print("invalid\t-\t%s is not an acceptance record of milestone %s with criteria" % (f, n))
    sys.exit(0)
if have != [("%s.c%d" % (n, i + 1), t) for i, t in enumerate(json.loads(fresh))]:
    print("invalid\t-\tits criteria differ from the Exit paragraph in the milestones file now; accept %s --init --force re-extracts them" % n)
    sys.exit(0)
for c in crit:
    cid, e = c["id"], c.get("evidence")
    if cid in waived:
        print("waived\t" + cid)
    elif not isinstance(e, dict):
        print("unmet\t%s\tno evidence%s" % (cid, " (evaluator context is not evidence)" if c.get("context") else ""))
    elif e.get("tree") != tree:
        print("unmet\t%s\tits evidence is on tree %s, the gated tree is %s" % (cid, str(e.get("tree"))[:12], tree[:12]))
    elif e.get("definition_hash") != dh:
        print("unmet\t%s\tits evidence has gate definition %s, the gate ran with %s" % (cid, str(e.get("definition_hash"))[:12], dh[:12]))
    elif e.get("kind") == "bundle":
        print("bundle\t%s\t%s\t%s" % (cid, e.get("bundle"), e.get("seal")))
    elif e.get("kind") == "mutation":
        print("mutation\t%s\t%s\t%s\t%s\t%s" % (cid, e.get("baseline_bundle"), e.get("baseline_seal"), e.get("patched_bundle"), e.get("patched_seal")))
    else:
        print("unmet\t%s\tunknown evidence kind %s" % (cid, e.get("kind")))
PY
)" || { ACCEPT_STATE=error; ACCEPT_UNMET="could not check $f"; return 1; }
  while IFS=$'\t' read -r kind id a b c d; do
    case "$kind" in
      invalid) ACCEPT_STATE=invalid; ACCEPT_UNMET="$a"; return 1 ;;
      waived) ;;
      unmet) ACCEPT_UNMET+="$id: $a"$'\n'; ACCEPT_IDS+="$id " ;;
      bundle)
        if ! bundle_sealed "$a" || [[ "$(seal_of "$a")" != "$b" ]]; then
          ACCEPT_UNMET+="$id: its evidence bundle $a no longer matches the seal recorded"$'\n'; ACCEPT_IDS+="$id "
        fi ;;
      mutation)
        if ! bundle_sealed "$a" || [[ "$(seal_of "$a")" != "$b" ]] || ! bundle_sealed "$c" || [[ "$(seal_of "$c")" != "$d" ]]; then
          ACCEPT_UNMET+="$id: its mutation bundles no longer match the seals recorded"$'\n'; ACCEPT_IDS+="$id "
        fi ;;
      *) ACCEPT_STATE=error; ACCEPT_UNMET="unexpected acceptance check output: $kind"; return 1 ;;
    esac
  done <<< "$out"
  ACCEPT_UNMET="${ACCEPT_UNMET%$'\n'}"; ACCEPT_IDS="${ACCEPT_IDS% }"
  [[ -z "$ACCEPT_IDS" ]] || { ACCEPT_STATE=incomplete; return 1; }
}

acceptance_refusal() {
  # acceptance_refusal <n> <bundle>: integrate's refusal when acceptance_complete failed: the sealed
  # bundle and the exact commands that record evidence or ask for a waiver.
  local n="$1" rel="$2" id l
  log "integrate milestone $n: refused: acceptance incomplete ($ACCEPT_STATE); the gate passed and the merge stays local"
  log "  sealed bundle: $rel"
  case "$ACCEPT_STATE" in
    missing) log "  no .milestones/acceptance/$n.json; record the exit criteria first:"
             log "    $SELF accept $n --init" ;;
    invalid) log "  $ACCEPT_UNMET"
             log "    $SELF accept $n --init --force" ;;
    incomplete) while IFS= read -r l; do log "  unmet $l"; done <<< "$ACCEPT_UNMET" ;;
    *) log "  $ACCEPT_UNMET" ;;
  esac
  [[ -n "$ACCEPT_IDS" ]] || return 0
  log "  record evidence for each criterion (a step of this bundle that passed and the test ids its log shows), then run integrate again:"
  for id in $ACCEPT_IDS; do
    log "    $SELF accept $n --criterion $id --evidence bundle:$rel#<step>:<test id>[,<test id>...]"
  done
  log "  or a caught mutation citing the criterion: $SELF accept $n --criterion <id> --evidence mutation:<line of .milestones/mutations/$n.jsonl>"
  log "  or an owner waiver, typed by the owner at a terminal: $SELF approve $n criterion-waiver $ACCEPT_IDS"
}

approve_candidate_head() {
  # The commit whose blobs an approval binds: --ref, else the sandbox branch (--sandbox, else
  # milestone <n>'s STATUS.md Sandbox cell) when it is not merged yet, else HEAD.
  local n="$1" id="${SANDBOX:-}" h rc=0
  if [[ -n "$MUTATE_REF" ]]; then
    [[ -z "$id" ]] || { echo "approve: give --ref or --sandbox, not both" >&2; return 1; }
    git rev-parse --verify -q "$MUTATE_REF^{commit}" || { echo "approve: --ref $MUTATE_REF is not a commit" >&2; return 1; }
    return 0
  fi
  [[ -n "$id" ]] || id="$(status_sandbox_cell "$n")"
  if [[ -n "$id" ]]; then
    [[ "$id" =~ $SANDBOX_ID_RE && "$id" != *..* ]] || { echo "approve: '$id' is not a sandbox id" >&2; return 1; }
    h="$(git rev-parse --verify -q "refs/heads/agent-sandbox/$id^{commit}")" || { echo "approve: no branch agent-sandbox/$id" >&2; return 1; }
    git merge-base --is-ancestor "$h" HEAD || rc=$?
    if (( rc == 0 )); then git rev-parse --verify -q "HEAD^{commit}" || { echo "approve: HEAD does not resolve" >&2; return 1; }
    elif (( rc == 1 )); then echo "$h"
    else echo "approve: git merge-base failed (exit $rc)" >&2; return 1; fi
    return 0
  fi
  git rev-parse --verify -q "HEAD^{commit}" || { echo "approve: HEAD does not resolve" >&2; return 1; }
}

do_approve() {
  local n="${MILESTONES[0]:-}" kind="$APPROVE_KIND" usage rel f at head="" typed p h hash ids st existed=1 sha
  local items=("${APPROVE_ITEMS[@]}") entries=()
  usage="approve N criterion-waiver N.c<i>... | approve N weakening <hit kind> <path>... | approve N gate-config <path>... | approve N gate-definition | approve N budget <name>...  ([--sandbox ID | --ref REF] picks the candidate head for blob ids)"
  [[ "$n" =~ ^[0-9]+$ && -n "$kind" ]] || die "approve needs a milestone and a kind: $usage"
  # Consent is typed by the owner at a terminal. Nothing is read or written before this check, and
  # there is no flag or variable that stands in for it.
  [[ -t 0 ]] || die "approve refused: stdin is not a terminal. An owner approval is typed by the owner at an interactive terminal; a headless shell cannot give one. Nothing written."
  rel=".milestones/approvals/$n.md"; f="$REPO/$rel"
  at="$(date -Is)"
  entry() { printf -- '- approved %s milestone=%s kind=%s hit=%s path=%s blob=%s hash=%s criterion=%s budget=%s confirm="approve %s %s"' \
              "$at" "$n" "$kind" "$1" "$2" "$3" "$4" "$5" "$6" "$n" "$kind"; }
  path_ok() { [[ -n "$1" && "$1" != /* && "$1" != *'"'* && "$1" =~ ^[[:print:]]+$ && "/$1/" != */../* ]]; }
  case "$kind" in
    criterion-waiver)
      (( ${#items[@]} )) || die "approve: name the criteria: $usage"
      [[ -f "$REPO/.milestones/acceptance/$n.json" ]] || die "approve: no .milestones/acceptance/$n.json; run accept $n --init first. Nothing written."
      ids="$(python3 -c 'import json, sys; print(" ".join(c["id"] for c in json.load(open(sys.argv[1]))["criteria"]))' "$REPO/.milestones/acceptance/$n.json")" \
        || die "approve: cannot read .milestones/acceptance/$n.json. Nothing written."
      for p in "${items[@]}"; do
        [[ "$p" =~ ^$n\.c[0-9]+$ && " $ids " == *" $p "* ]] || die "approve: no criterion $p in .milestones/acceptance/$n.json (its ids: $ids). Nothing written."
        entries+=("$(entry - - - - "$p" -)")
      done ;;
    weakening|gate-config)
      local hit=-
      if [[ "$kind" == weakening ]]; then
        hit="${items[0]:-}"
        [[ " $WEAKENING_KINDS " == *" $hit "* ]] || die "approve: '$hit' is not a hit kind ($WEAKENING_KINDS). Nothing written."
        items=("${items[@]:1}")
      fi
      (( ${#items[@]} )) || die "approve: name the paths: $usage"
      head="$(approve_candidate_head "$n")" || die "approve: no candidate head. Nothing written."
      for p in "${items[@]}"; do
        path_ok "$p" || die "approve: '$p' is not a repository-relative path without quotes. Nothing written."
        h="$(path_blob "$head" "$p")" || die "approve: git could not read $p at ${head:0:12}. Nothing written."
        entries+=("$(entry "$hit" "\"$p\"" "$h" - - -)")
      done ;;
    gate-definition)
      (( ${#items[@]} == 0 )) || die "approve: gate-definition takes no items: $usage"
      require_gate
      hash="$(gate_definition_hash)"
      [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || die "approve: could not compute the gate definition hash. Nothing written."
      entries+=("$(entry - - - "$hash" - -)") ;;
    budget)
      (( ${#items[@]} )) || die "approve: name the budgets: $usage"
      for p in "${items[@]}"; do
        [[ "$p" =~ ^[A-Za-z0-9_.-]+$ ]] || die "approve: '$p' is not a budget name. Nothing written."
        entries+=("$(entry - - - - - "$p")")
      done ;;
    *) die "approve: unknown kind '$kind': $usage" ;;
  esac
  git symbolic-ref -q HEAD > /dev/null || die "approve: HEAD is detached; check out the integration branch. Nothing written."
  st="$(git status --porcelain --untracked-files=all -- "$rel")" || die "approve: git status failed. Nothing written."
  [[ -z "$st" ]] || die "approve: $rel has uncommitted edits; a line not written by approve is never committed by it. Restore it (git checkout -- $rel, or remove it). Nothing written."
  echo "Milestone $n, approval of kind $kind${head:+ (blob ids at ${head:0:12})}:"
  printf '  %s\n' "${entries[@]}"
  echo "Type exactly: approve $n $kind"
  IFS= read -r typed || typed=""
  typed="${typed%$'\r'}"
  [[ "$typed" == "approve $n $kind" ]] || die "approve refused: the confirmation typed was not 'approve $n $kind'. Nothing written."
  git cat-file -e "HEAD:$rel" 2> /dev/null || existed=0
  mkdir -p "$(dirname "$f")" || die "approve: cannot create $(dirname "$rel"). Nothing written."
  if [[ ! -e "$f" ]]; then
    printf '# Owner approvals, milestone %s\n\nWritten only by run-milestones.sh approve at a terminal; every line in another form is ignored.\n\n' "$n" > "$f" \
      || die "approve: cannot write $rel"
  fi
  printf '%s\n' "${entries[@]}" >> "$f" || die "approve: cannot write $rel"
  if ! git add -- "$rel" || ! git commit -q -m "approvals: milestone $n $kind ${APPROVE_ITEMS[*]}" -- "$rel" > /dev/null; then
    if (( existed )); then git reset -q -- "$rel" > /dev/null 2>&1; git checkout -q -- "$rel" > /dev/null 2>&1
    else git rm -q --cached -- "$rel" > /dev/null 2>&1; rm -f "$f"; fi
    die "approve: committing $rel failed; the file is restored and nothing is approved"
  fi
  sha="$(git rev-parse --short=12 HEAD)"
  log "approve milestone $n: $kind ${APPROVE_ITEMS[*]} committed in $rel as $sha$( [[ -z "$head" ]] || echo " (blobs at ${head:0:12})")"
}

# ---------------------------------------------------------------- config
do_config() {
  # What milestone <n> resolves to, one KEY=value per line, so a launch can be checked
  # before a run is spent on it.
  local n="$1" key
  local ev="EVALUATE_$n" tv="EVALUATE_TARGET_$n"
  for key in MEMORY CPUS MODEL EFFORT; do echo "$key=$(resolve_override "$key" "$n")"; done
  echo "LANE=$(resolve_lane "$n")"
  if [[ "${!ev:-}" == 1 ]]; then echo "EVALUATE=1"; else echo "EVALUATE=0"; fi
  echo "EVALUATE_TARGET=${!tv:-}"
  echo "GATE_SETUP=$GATE_SETUP"
  echo "GATE=$GATE"
  echo "GATE_ENV=$GATE_ENV"
  echo "INTEGRATE_GATE_WHERE=$INTEGRATE_GATE_WHERE"
  if [[ -n "$GATE" || ${#GATE_STEPS[@]} -gt 0 ]]; then
    load_gate_steps
    for key in "${!ST_NAME[@]}"; do echo "GATE_STEP=${ST_KIND[key]}|${ST_NAME[key]}|${ST_CMD[key]}${ST_ONLY[key]:+|${ST_ONLY[key]}}"; done
  fi
}

# ---------------------------------------------------------------- prompt verb
do_prompt() {
  # The prompt a launch of milestone <n> would send, built without launching: written to
  # logs/milestones/milestone-<n>.prompt and printed.
  local n="$1"
  [[ -f "$REPO/$MILESTONES_FILE" ]] || die "no milestones file $MILESTONES_FILE: set MILESTONES_FILE in .milestones/config"
  [[ -n "$(milestone_section "$n")" ]] || die "no '## Milestone $n' section in $MILESTONES_FILE"
  milestone_prompt "$n" > "$LOGS/milestone-$n.prompt"
  cat "$LOGS/milestone-$n.prompt"
}

# ---------------------------------------------------------------- dispatch
if [[ "$VERB" != mutate && -n "$MUTATE_STEPS" ]]; then die "--steps belongs to mutate"; fi
if [[ "$VERB" != mutate && "$VERB" != approve && -n "$MUTATE_REF" ]]; then die "--ref belongs to mutate and approve"; fi
if [[ "$VERB" != accept ]] && (( ACCEPT_INIT || ACCEPT_FORCE )) || [[ "$VERB" != accept && -n "$ACCEPT_CRITERION$ACCEPT_EVIDENCE$ACCEPT_CONTEXT" ]]; then
  die "--init, --force, --criterion, --evidence and --context belong to accept"
fi
if [[ "$VERB" == accept ]]; then
  [[ -z "$INSIDE" && -z "$CONTINUE" && -z "$SANDBOX" && ${#MILESTONES[@]} -eq 1 ]] || die "accept takes one milestone: accept N --init | accept N --criterion N.c<i> --evidence ... | --context evaluator:<text>"
  do_accept; exit 0
fi
if [[ "$VERB" == approve ]]; then
  [[ -z "$INSIDE" && -z "$CONTINUE" && ${#MILESTONES[@]} -eq 1 ]] || die "approve takes one milestone: approve N <kind> <item...>"
  do_approve; exit 0
fi
if [[ "$VERB" == mutate ]]; then
  [[ -z "$INSIDE" && -z "$CONTINUE" && ${#MILESTONES[@]} -eq 1 ]] || die "mutate takes one milestone and a patch: mutate N <patch> [--ref REF] [--steps name,name] [--sandbox ID]"
  do_mutate; exit "$MUTATE_EXIT"
fi
if [[ "$VERB" == integrate ]]; then
  [[ -z "$INSIDE" && -z "$CONTINUE" && -z "$SANDBOX" ]] || die "integrate takes a sandbox id and an optional milestone, nothing else"
  do_integrate; exit 0
fi
if [[ "$VERB" == config ]]; then
  [[ -z "$INSIDE" && -z "$CONTINUE" && ${#MILESTONES[@]} -eq 1 ]] || die "config takes one milestone, e.g. config 6"
  do_config "${MILESTONES[0]}"; exit 0
fi
if [[ "$VERB" == prompt ]]; then
  [[ -z "$INSIDE" && -z "$CONTINUE" && -z "$SANDBOX" && ${#MILESTONES[@]} -eq 1 ]] || die "prompt takes one milestone, e.g. prompt 6"
  do_prompt "${MILESTONES[0]}"; exit 0
fi
if [[ -n "$VERB" ]]; then
  [[ -z "$INSIDE" && -z "$CONTINUE" && ${#MILESTONES[@]} -eq 0 ]] || die "$VERB takes no milestone or --continue"
  "do_$VERB"; exit 0
fi

if [[ -n "$INSIDE" ]]; then
  inside_body
  exit $?
fi

if (( ${#MILESTONES[@]} > 1 )); then
  die "one milestone per launch (asked for ${MILESTONES[*]}): the supervisor reviews between milestones, so a chain inside one unit would skip that review. Launch ${MILESTONES[0]}, review, then the next."
fi

if [[ -n "$CONTINUE" ]]; then
  [[ -n "$SANDBOX" ]] || die "--continue needs --sandbox ID"
  n="${MILESTONES[0]:-}"
  if [[ -z "$n" ]]; then
    # The unit is tagged milestone=<n>, and integrate reads that tag back: never a word.
    n="$(sandbox_milestone_tag "$SANDBOX")"
    found=""; [[ -n "$n" ]] && found=" that is a number (found \"$n\")"
    [[ "$n" =~ ^[0-9]+$ ]] || die "--continue: sandbox $SANDBOX has no milestone tag$found; name the milestone: $(basename "$SELF") N --sandbox $SANDBOX --continue \"...\""
  fi
  launch_unit continue "$n"
  exit 0
fi

((${#MILESTONES[@]})) || die "say which milestone, e.g. 6"
n="${MILESTONES[0]}"
require_gate
if (( GATE_ONLY )); then
  [[ -n "$SANDBOX" ]] || die "--gate needs --sandbox ID"
  launch_unit gate "$n"
  exit 0
fi
for d in $DEPLOY_MILESTONES; do
  [[ "$n" == "$d" && $DEPLOY == 0 ]] && die "milestone $n deploys; pass --deploy to allow it"
done
lane="$(resolve_lane "$n")"
blocker="$(lane_blocker "$n" "$lane")"
if [[ -n "$blocker" ]]; then
  log "refused: milestone ${blocker%% *} (sandbox ${blocker#* }) in lane $lane has a STATUS.md row with nothing pushed; integrate it, or give milestone $n another lane (LANE_$n) if the two share no dataset or modules"
  exit 2
fi
launch_unit milestone "$n"
