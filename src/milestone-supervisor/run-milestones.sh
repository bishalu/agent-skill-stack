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
# evidence.json is written after the last step, and its sha256 is logged as the seal.
# Each run appends to its gate log and chain.log:
#   gate pass|FAIL exit=N milestone=N sha=<12> tree=<12> def=<12> dirty=yes|no
#     where=sandbox|host-integrate|sandbox-integration|local setup=yes|none
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
#   1. refuse on tracked changes, a detached HEAD, a branch other than INTEGRATION_BRANCH,
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
#   4. the weakening scan over @{upstream}..HEAD: every hit's path (skip-marker,
#      removed-assert, deleted-test, snapshot, gate-config) must appear whole in the
#      "Test expectation changes" section of REPORT_DIR/milestone-N.md at HEAD;
#   5. EVALUATE_N=1: .milestones/evaluation-N.md committed, no "owner action required" line;
#   6. the gate steps under GATE_TIMEOUT: INTEGRATE_GATE_WHERE=host in a temporary detached
#      worktree of HEAD seeded with SEED_PATHS (where=host-integrate); =sandbox in a fresh
#      `agent-sandbox run <repo> --new` tagged purpose=integration-gate, refused unless its
#      HEAD is the merge commit, removed on every exit path (where=sandbox-integration); then
#      refuse unless the bundle still matches its seal and HEAD is still the gated commit on
#      the same branch with no tracked change;
#   7. upsert the STATUS.md row (Lane, Sandbox, Merged = gated sha, Gate = pass <sha> tree=
#      def= and the kind counts), commit only that
#      file, check the commit's parent is the gated sha, and push that commit to the
#      upstream under timeout GATE_TIMEOUT with stdin closed.
# A refusal or failure after step 3 pushes nothing. When this run made the merge, it keeps
# the merge local and logs the pre-merge sha with the `git reset --hard` that drops it; on
# an already-merged re-run it logs `git log --oneline <upstream>..HEAD` instead, because a
# reset would also drop fix-forward commits. Exit 2 refused, 1 gate or push failed.
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
PORTS=(); PORT_TOKEN=""
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
  local keep=() cands=() held=" "
  if [[ ! "$GATE_PORT_RANGE" =~ ^([0-9]+)-([0-9]+)$ ]]; then log "GATE_PORT_RANGE='$GATE_PORT_RANGE': want <low>-<high>"; return 1; fi
  lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
  if (( lo < 1024 || hi > 65535 || hi - lo < 3 )); then log "GATE_PORT_RANGE=$GATE_PORT_RANGE: want four or more ports within 1024-65535"; return 1; fi
  exec {fd}>> "$reg.lock"
  if ! flock -w 60 "$fd"; then exec {fd}>&-; log "could not lock $reg within 60s"; return 1; fi
  if [[ -f "$reg" ]]; then
    while read -r p tok pid at; do
      if [[ ! "$p" =~ ^[0-9]+$ || ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2> /dev/null; then continue; fi
      keep+=("$p $tok $pid $at"); held+="$p "
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
    PORTS=(); exec {fd}>&-
    log "no four free, unregistered ports in GATE_PORT_RANGE=$GATE_PORT_RANGE"; return 1
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
GATE_TMP=""; INTEGRATE_TREE=""; GATE_SANDBOX_CREATED=""
on_exit() {
  release_ports
  [[ -z "$GATE_TMP" ]] || rm -rf "$GATE_TMP" 2> /dev/null || true
  GATE_TMP=""
  integrate_cleanup
  remove_gate_sandbox
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
import json, sys
a = sys.argv[1:]
path = a.pop(0)
cut = a.index("--")
h = dict(x.split("=", 1) for x in a[:cut])
r = a[cut + 1:]
steps = []
for i in range(0, len(r), 8):
    kind, name, cmd, flag, status, ex, ms, log = r[i:i + 8]
    steps.append({"index": i // 8 + 1, "name": name, "kind": kind, "command": cmd,
                  "sandbox_only": flag == "sandbox-only", "status": status,
                  "exit": int(ex) if ex else None, "duration_ms": int(ms) if ms else None,
                  "log": log or None})
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
gate_run() {
  # gate_run <where> <milestone> <dir> <sha> [sandbox-id]
  #   where: sandbox (a milestone's own sandbox, whose report must exist), host-integrate,
  #   sandbox-integration, local. <dir> is the gated worktree as the host sees it.
  # Returns GATE_RC: 0, or the failing step's exit. Returns 1 with no bundle when the run
  # could not start (unreadable tree, no ports). Sets GATE_BUNDLE, GATE_FAILED_STEP,
  # GATE_COUNTS, GATE_TREE, GATE_DEF and GATE_ADMISSION (a step enter not admitted).
  local where="$1" n="$2" dir="$3" sha="$4" sb="${5:-}" route=host target="$3"
  case "$where" in sandbox|sandbox-integration) route=sandbox; target="$sb" ;; esac
  GATE_RC=0; GATE_BUNDLE=""; GATE_FAILED_STEP=""; GATE_COUNTS=""; GATE_ADMISSION=0; SB_STDOUT=""; SB_RUNDIR=""
  arm_cleanup
  GATE_TREE="$(git -C "$dir" rev-parse --verify -q "$sha^{tree}" 2> /dev/null)" \
    || { log "milestone $n: cannot read the tree of ${sha:0:12} in $dir; no gate step ran"; return 1; }
  GATE_DEF="$(gate_definition_hash)"
  local stamp b i=1
  stamp="$(date +%Y%m%dT%H%M%S)"; mkdir -p "$LOGS/evidence"
  b="$LOGS/evidence/$n-$where-$stamp"
  until mkdir "$b" 2> /dev/null; do
    i=$(( i + 1 )); b="$LOGS/evidence/$n-$where-$stamp.$i"
    (( i < 100 )) || { log "milestone $n: cannot create an evidence directory under $LOGS/evidence; no gate step ran"; return 1; }
  done
  mkdir -p "$b/steps"
  GATE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/gate-$PROJECT-$n.XXXXXX")"; mkdir -p "$GATE_TMP/tmp"
  if [[ "$route" == host ]] && ! alloc_ports "$(basename "$b")"; then
    rm -rf "$b"; log "milestone $n: no gate step ran"; return 1
  fi
  GATE_BUNDLE="$b"

  local started seed_kept="" seed_read=0 dirty=no env="-" probed=0 total deadline rem k rc t0 report=""
  local s_status=() s_exit=() s_ms=() s_log=()
  started="$(date -Is)"
  gate_dirty "$dir" "$b" "$sha" || log "  could not read the dirt of $dir; the bundle counts as dirty"
  [[ -z "$GATE_ENV" ]] || env="unavailable"
  total="$(to_seconds "$GATE_TIMEOUT")"; deadline=$(( SECONDS + total ))
  for k in "${!ST_NAME[@]}"; do
    s_log[k]=""; s_exit[k]=""; s_ms[k]=""
    if (( GATE_RC )); then s_status[k]="not run"; continue; fi
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
    if [[ "$route" == sandbox ]] && (( rc == 3 && ADMISSION_REFUSED )); then s_status[k]="not admitted"; GATE_ADMISSION=1; fi
    GATE_RC="$rc"; GATE_FAILED_STEP="${ST_NAME[k]}"
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
VERB=""; INTEGRATE_ID=""; SANDBOX=""; DEPLOY=0; NOTE=""; CONTINUE=""; INSIDE=""; UNIT=""; GATE_ONLY=0; ISSUE=0
MILESTONES=(); RES=(); TAGS=(); AGENT_OPTS=()
while (($#)); do
  case "$1" in
    status|resume|config|prompt) VERB="$1"; shift ;;
    init) die "init takes no other arguments: run-milestones.sh init" ;;
    integrate) VERB=integrate; shift; INTEGRATE_ID="${1-}"; if (($#)); then shift; fi ;;   # the next argument is the id
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

report_expectation_section() {
  # The body of every heading containing "Test expectation changes" (any level, case
  # insensitive) in <text on stdin>, up to the next heading of the same or a higher level.
  awk '
    match($0, /^#+[ \t]/) {
      lvl = RLENGTH - 1
      if (on && lvl <= onl) on = 0
      if (tolower($0) ~ /test expectation changes/) { on = 1; onl = lvl; next }
    }
    on'
}

weakening_hits() {
  # "<kind> <path>" per hit in the diff <base>..HEAD:
  #   skip-marker     an added line matching TEST_WEAKENING_PATTERN in a TEST_GLOBS file
  #   removed-assert  a removed line matching TEST_ASSERT_PATTERN in a TEST_GLOBS file
  #   deleted-test    a deleted TEST_GLOBS file
  #   snapshot        a modified or deleted SNAPSHOT_GLOBS file (a new baseline is not a change)
  #   gate-config     an added, modified or deleted GATE_DEFINITION_GLOBS file (the runner's
  #                   config or the gate recipe can narrow the suite without touching a test)
  # The line checks are limited to test files so application code (an iterator's .skip(,
  # a production assert) and the report quoting a marker are not hits.
  local base="$1" status path body
  while IFS= read -r -d '' status && IFS= read -r -d '' path; do
    if path_matches "$path" "$SNAPSHOT_GLOBS" && [[ "$status" != A ]]; then
      echo "snapshot $path"
    fi
    if path_matches "$path" "$GATE_DEFINITION_GLOBS"; then echo "gate-config $path"; fi
    path_matches "$path" "$TEST_GLOBS" || continue
    if [[ "$status" == D ]]; then echo "deleted-test $path"; continue; fi
    body="$(git -c core.quotePath=false diff --no-color --no-ext-diff --no-renames --unified=0 "$base" HEAD -- "$path" \
      | awk '/^@@/ { b = 1; next } /^diff --git / { b = 0 } b')"
    # grep reads a here-string, never a pipe: `sed | grep -q` under pipefail fails when grep
    # exits at its first match while sed still writes, which hides a hit in a large diff.
    if grep -Eq -- "$TEST_WEAKENING_PATTERN" <<< "$(sed -n 's/^+//p' <<< "$body")"; then echo "skip-marker $path"; fi
    if grep -Eq -- "$TEST_ASSERT_PATTERN" <<< "$(sed -n 's/^-//p' <<< "$body")"; then echo "removed-assert $path"; fi
  done < <(git -c core.quotePath=false diff --no-renames --name-status -z "$base" HEAD)
}

section_lists() {
  # section_lists <path> <section text>: the path appears whole, bounded on each side by
  # the line's start or end or a character that cannot continue a path (a space, a
  # backtick, a colon); a trailing sentence period is allowed. pkg/a_test.go does not
  # list a_test.go, and a_test.go.orig does not either.
  P="$1" awk '
    function pathch(c) { return c != "" && c ~ /[A-Za-z0-9._\/-]/ }
    BEGIN { p = ENVIRON["P"]; n = length(p); if (n == 0) exit }
    {
      line = $0; from = 0
      while ((i = index(substr(line, from + 1), p)) > 0) {
        j = from + i
        pre = (j > 1) ? substr(line, j - 1, 1) : ""
        post = substr(line, j + n, 1); post2 = substr(line, j + n + 1, 1)
        if (!pathch(pre) && (!pathch(post) || (post == "." && !pathch(post2)))) { found = 1; exit }
        from = j
      }
    }
    END { exit !found }' <<< "$2"
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

host_gate() {
  # Gate HEAD on the host in a temporary detached worktree seeded with SEED_PATHS copies,
  # so GATE_SETUP never writes the host files every sandbox is seeded from. The bundle is
  # written under the project's logs before the worktree is removed. Returns the gate's exit.
  local n="$1" sha="$2" rc=0 p
  arm_cleanup
  INTEGRATE_TREE="$(mktemp -d "${TMPDIR:-/tmp}/integrate-$PROJECT-$n.XXXXXX")"
  git worktree add -q --detach "$INTEGRATE_TREE/tree" "$sha" > /dev/null || { log "  could not add a worktree of ${sha:0:12}"; return 1; }
  local -
  set -f
  for p in ${SEED_PATHS:-}; do
    if [[ "$p" == /* || "/$p/" == */../* ]]; then log "  seed path '$p' skipped: not a path inside the repository"; continue; fi
    [[ -e "$REPO/$p" ]] || { log "  seed path $p absent on the host; skipped"; continue; }
    if [[ -d "$REPO/$p" ]]; then mkdir -p "$INTEGRATE_TREE/tree/$p"; cp -a "$REPO/$p/." "$INTEGRATE_TREE/tree/$p/"
    else mkdir -p "$(dirname "$INTEGRATE_TREE/tree/$p")"; cp -a "$REPO/$p" "$INTEGRATE_TREE/tree/$p"; fi
    log "  seeded $p"
  done
  set +f
  log "  host gate in $INTEGRATE_TREE/tree (timeout $GATE_TIMEOUT)"
  gate_run host-integrate "$n" "$INTEGRATE_TREE/tree" "$sha" || rc=$?
  integrate_cleanup
  return "$rc"
}

GATE_REFUSED=""
sandbox_integration_gate() {
  # INTEGRATE_GATE_WHERE=sandbox: a fresh sandbox of the host checkout, whose HEAD is the
  # merge commit, refused unless its worktree is at that commit, gated step by step through
  # enter and removed on every exit path. Sets GATE_REFUSED for a sandbox at another commit.
  local n="$1" head="$2" lane="$3" created id ws wsha rc=0
  arm_cleanup
  resolve_resources "$n"
  TAGS=(--tag "milestone=$n" --tag "lane=$lane" --tag purpose=integration-gate)
  created="$LOGS/integrate-$n-sandbox-$(date +%Y%m%dT%H%M%S).log"
  log "  integration sandbox for ${head:0:12}, created from $REPO (log $created)"
  sandbox_call "$created" run "$REPO" --new "${RES[@]}" "${TAGS[@]}" --json -- true || rc=$?
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
    GATE_REFUSED="integration sandbox $id is at ${wsha:-an unreadable HEAD}, not the merge commit $head"
    remove_gate_sandbox; return 2
  fi
  gate_run sandbox-integration "$n" "$ws" "$head" "$id" || rc=$?
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
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] || refuse "the host checkout has tracked changes; commit or stash them first"
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
  local base p rc_ig=0 bad=() ignored=() report="$REPORT_DIR/milestone-$n.md" rblob bblob
  base="$(git merge-base "$upstream" "$sbranch")" || refuse "$sbranch shares no history with the upstream of $branch"
  # Supervisor files (STATUS.md cells, evaluation-N.md, config) come only from host
  # commits, which the ahead rule's .milestones-only allowance covers.
  while IFS= read -r p; do
    [[ -n "$p" ]] && bad+=("$p")
  done < <(git -c core.quotePath=false log --no-renames --format= --name-only "$base..$sbranch" -- .milestones | sort -u)
  (( ${#bad[@]} == 0 )) || refuse "$sbranch touches supervisor files under .milestones/, which only host commits may change: ${bad[*]}"
  # A merge writes over an ignored host file (an env file, seeded data) without a word.
  local changed ig_out
  changed="$(mktemp "${TMPDIR:-/tmp}/integrate-paths.XXXXXX")"
  git -c core.quotePath=false diff --no-renames --name-only -z --diff-filter=d "$base" "$sbranch" > "$changed" \
    || { rm -f "$changed"; refuse "could not list the paths $sbranch changes"; }
  ig_out="$(git -c core.quotePath=false check-ignore -z --stdin < "$changed" | tr '\0' '\n')" || rc_ig=$?
  rm -f "$changed"
  (( rc_ig <= 1 )) || refuse "git check-ignore failed (exit $rc_ig) while checking $sbranch for ignored paths"
  while IFS= read -r p; do
    [[ -n "$p" ]] && ignored+=("$p")
  done <<< "$ig_out"
  (( ${#ignored[@]} == 0 )) || refuse "$sbranch adds or changes paths ignored in this checkout, which a merge would overwrite: ${ignored[*]}"
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
  local hits unlisted=() section="" kind path
  hits="$(weakening_hits "$upstream" | sort -u)"
  if [[ -n "$hits" ]]; then
    section="$(git show "HEAD:$report" 2>/dev/null | report_expectation_section || true)"
    while read -r kind path; do
      section_lists "$path" "$section" || unlisted+=("$kind $path")
    done <<< "$hits"
    if (( ${#unlisted[@]} )); then
      kept "refused: test weakening not listed in the 'Test expectation changes' section of $report:"
      for c in "${unlisted[@]}"; do log "    $c"; done
      exit 2
    fi
    log "  weakening hits all listed in $report: $(tr '\n' ';' <<< "$hits")"
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
  GATE_FAILED_STEP=""; GATE_REFUSED=""; GATE_BUNDLE=""
  if [[ "$gwhere" == sandbox ]]; then sandbox_integration_gate "$n" "$head" "$(resolve_lane "$n")" || grc=$?
  else host_gate "$n" "$head" || grc=$?; fi
  [[ -z "$GATE_REFUSED" ]] || { kept "refused: $GATE_REFUSED"; exit 2; }
  if (( grc )); then
    why="${GATE_FAILED_STEP:+ at $GATE_FAILED_STEP}"; (( grc != 124 )) || why+=" (timed out after $GATE_TIMEOUT)"
    kept "$glabel FAILED$why; evidence: ${GATE_BUNDLE:-none}"
    exit 1
  fi
  bundle_sealed "$GATE_BUNDLE" || { kept "refused: $GATE_BUNDLE/evidence.json does not match its seal in chain.log"; exit 2; }

  # The checkout is shared: a commit or edit landing while the gate ran was never gated.
  if [[ "$(git rev-parse HEAD)" != "$head" || "$(git symbolic-ref --quiet --short HEAD || true)" != "$branch" \
        || -n "$(git status --porcelain --untracked-files=no)" ]]; then
    kept "refused: HEAD or the tracked tree changed while the $glabel ran; the gated commit is ${head:0:12}, HEAD is now $(git rev-parse --short=12 HEAD)"
    exit 2
  fi

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
