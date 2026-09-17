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
#   GATE="just check"                            run inside the sandbox after each milestone; required
#                                                to gate (no default: the gate is the project's own)
#   GATE_SETUP="just replay"                     runs first, in the same shell, to rebuild derived state
#                                                from committed recordings before the gate reads it
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
#   GATE_TIMEOUT=30m                             bound on each gate run, sandbox and host
#   TEST_WEAKENING_PATTERN / TEST_ASSERT_PATTERN  grep -E patterns for integrate's weakening scan
#   TEST_GLOBS / SNAPSHOT_GLOBS                  space-separated globs of test and snapshot files
#                                                (defaults and matching rules at the integrate section)
# <repo>/.milestones/config.local  gitignored, sourced after config: this host's values
#                                                (a PATH prefix for its toolchain, say)
# <repo>/.milestones/standing-rules.md          rules every milestone gets; "milestone-N" is substituted
# <repo>/.milestones/milestone-N.md             optional extra paragraph for milestone N
# <repo>/.milestones/notes-N.md                 optional supervisor notes, appended if present and --note is not given
#
# Files under <repo>/logs/milestones/: chain.log (every decision), unit-<unit>.out (the
# unit's stdout+stderr), milestone-N.prompt, milestone-N.log and milestone-N.gate.log (the
# agent-sandbox result JSON, or the admission refusal), create-N-<stamp>.log (a new sandbox).
# Every gate run appends one evidence line to its gate log and to chain.log:
#   gate pass|FAIL exit=N milestone=N sha=<12> where=sandbox|host setup=yes|none env="..." at=<iso>
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
#   2. merge --no-ff agent-sandbox/<id> (skipped when already merged; a conflict aborts);
#   3. the weakening scan over @{upstream}..HEAD: every hit's path must appear in the
#      "Test expectation changes" section of REPORT_DIR/milestone-N.md at HEAD;
#   4. EVALUATE_N=1: .milestones/evaluation-N.md committed, no "owner action required" line;
#   5. GATE_SETUP, GATE_ENV and GATE on the host in a temporary detached worktree of HEAD
#      seeded with SEED_PATHS, under timeout GATE_TIMEOUT; evidence line where=host;
#   6. upsert the STATUS.md row (Lane, Sandbox, Merged = gated sha, Gate), commit only that
#      file, push to the upstream.
# A refusal or failure after step 2 keeps the merge local, pushes nothing, and logs the
# pre-merge sha with the `git reset --hard` that drops it. Exit 2 refused, 1 gate or push failed.
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
GATE_TIMEOUT="30m"
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

resolve_resources() {
  # MEMORY_<n>, CPUS_<n>; then MEMORY, CPUS; then nothing (agent-sandbox's config).
  # MODEL_<n>, EFFORT_<n>; then MODEL, EFFORT; then nothing (claude's session default).
  # The agent's model and effort are per milestone because the stages differ in
  # what they need: a plan or a review earns a strong model, a docs or a
  # measurement milestone does not.
  local n="$1" mem cpus mv cv model effort modv effv
  mv="MEMORY_$n"; cv="CPUS_$n"; modv="MODEL_$n"; effv="EFFORT_$n"
  mem="${!mv:-${MEMORY:-}}"; cpus="${!cv:-${CPUS:-}}"
  model="${!modv:-${MODEL:-}}"; effort="${!effv:-${EFFORT:-}}"
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

resolve_lane() {
  # LANE_<n>, then main. The value becomes an agent-sandbox tag, so keep it a plain word.
  local v="LANE_$1" lane
  lane="${!v:-main}"
  [[ "$lane" =~ ^[A-Za-z0-9_.-]+$ ]] || die "LANE_$1='$lane': a lane is letters, digits, _ . or -"
  echo "$lane"
}

require_gate() {
  # No default gate: a language-specific guess would pass or fail for the wrong reason.
  [[ -n "$GATE" ]] || die "no GATE in $REPO/.milestones/config: set GATE to the project's check command (and GATE_SETUP if derived state must be rebuilt first)"
}

gate_evidence() {
  # One line of gate evidence, to chain.log and appended to <gatelog>. Used by the
  # sandbox gate here (where=sandbox) and by a host-side gate (where=host).
  #   gate_evidence <exit> <milestone> <sha> <where> <setup yes|none> <env> <gatelog>
  local rc="$1" n="$2" sha="$3" where="$4" setup="$5" env="$6" gatelog="$7" result=FAIL
  (( rc == 0 )) && result=pass
  env="${env//\"/\'}"   # keep the quoted field one field
  local line at
  at="$(date -Is)"
  line="gate $result exit=$rc milestone=$n sha=${sha:-unknown} where=$where setup=$setup env=\"$env\" at=$at"
  echo "$line" >> "$gatelog"
  log "$line"
}

sandbox_worktree() {
  # The sandbox's worktree: the enter result's `.worktree`, else agent-sandbox's layout.
  local ws; ws="$(json_field "$2" worktree)"
  [[ -n "$ws" ]] || ws="${AGENT_SANDBOX_HOME:-$HOME/agent-sandbox}/worktrees/$1"
  echo "$ws"
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

sandbox_call() {
  # agent-sandbox <args...> with stdout+stderr in <logfile>. Returns its exit code;
  # an admission refusal (3) is written to chain.log with its reasons first.
  local logfile="$1"; shift
  local rc=0
  agent-sandbox "$@" >"$logfile" 2>&1 || rc=$?
  if (( rc == 3 )); then
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
    [0-9]|[0-9][0-9]) MILESTONES+=("$1"); shift ;;
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
gate_script() {
  # The shell script one gate run executes: GATE_SETUP, the GATE_ENV probe, GATE, then an
  # optional final check, as marker lines "@@<nonce> env=..." and "@@<nonce> step=<step>"
  # (the step that failed). An EXIT trap names the failing step, so a setup or gate that
  # calls `exit` itself is still attributed; `|| exit` keeps a failing step from falling
  # through to the next.
  local nonce="$1" final="${2:-}" script
  script="set +e"$'\n'"trap '__gate_rc=\$?; [ \$__gate_rc -eq 0 ] || echo \"@@$nonce step=\$__gate_step\"' EXIT"
  if [[ -n "$GATE_SETUP" ]]; then
    script+=$'\n'"__gate_step=setup"$'\n'"{
$GATE_SETUP
} || exit \$?"
  fi
  if [[ -n "$GATE_ENV" ]]; then
    script+=$'\n'"echo \"@@$nonce env=\$( {
$GATE_ENV
} 2>/dev/null | head -n 1)\""
  fi
  script+=$'\n'"__gate_step=gate"$'\n'"{
$GATE
} || exit \$?"
  [[ -n "$final" ]] && script+=$'\n'"__gate_step=report"$'\n'"$final"
  printf '%s\n' "$script"
}

run_gate() {
  # Setup, the env probe, the gate and the report check run in one `bash -lc`, so the
  # state setup rebuilds is the state the gate reads. With --json, agent-sandbox sends
  # the container's stdout only to the sandbox's stdout.log, so the script prints marker
  # lines carrying a per-run nonce, and the driver reads them back from that log.
  local n="$1"
  local rc=0 gatelog="$LOGS/milestone-$n.gate.log" nonce setup=none script
  require_gate
  nonce="rm-gate-$(date +%s)-$$-$RANDOM"
  [[ -n "$GATE_SETUP" ]] && setup=yes
  script="$(gate_script "$nonce" "test -s $REPORT_DIR/milestone-$n.md")"
  sandbox_call "$gatelog" enter "$SANDBOX" --timeout "$GATE_TIMEOUT" "${RES[@]}" "${TAGS[@]}" --json -- \
    bash -lc "$script" || rc=$?
  if (( rc == 3 )); then
    log "milestone $n: gate not admitted; unit stops"; return 3
  fi

  # The gated commit, read on the host: the worktree is a host directory.
  local ws sha stdout_log marks="" env="-" step
  ws="$(sandbox_worktree "$SANDBOX" "$gatelog")"
  sha="$(git -C "$ws" rev-parse HEAD 2>/dev/null | cut -c1-12 || true)"
  stdout_log="$(json_field "$gatelog" logs.stdout)"
  [[ -n "$stdout_log" && -f "$stdout_log" ]] && marks="$(grep -a "^@@$nonce " "$stdout_log" || true)"
  step="$(sed -n "s/^@@$nonce step=//p" <<< "$marks" | tail -n 1)"
  if [[ -n "$GATE_ENV" ]]; then
    # A marker that never came back (no log, or the probe's line lost) is not an empty probe.
    if grep -q "^@@$nonce env=" <<< "$marks"; then env="$(sed -n "s/^@@$nonce env=//p" <<< "$marks" | tail -n 1)"
    else env="unavailable"; fi
  fi
  gate_evidence "$rc" "$n" "$sha" sandbox "$setup" "$env" "$gatelog"

  if (( rc == 0 )); then
    log "milestone $n: gate passed $(date -Is)"; return 0
  fi
  log "milestone $n: gate FAILED (exit $rc${step:+, at $step}), see $gatelog and the sandbox transcript; unit stops"
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
    (( rc == 3 )) && { log "continue: not admitted; unit stops"; return 3; }
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
    (( rc == 3 )) && { log "milestone $n: sandbox creation not admitted; unit stops"; return 3; }
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
  (( rc == 3 )) && { log "milestone $n: not admitted; unit stops"; return 3; }
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

# Defaults for the weakening scan, overridable in config. A glob with no "/" matches the
# file name; one ending in "/" matches that directory anywhere in the path; any other
# glob matches the path from the root or from any directory ("*" and "**" cross "/").
TEST_WEAKENING_PATTERN="${TEST_WEAKENING_PATTERN:-pytest\.mark\.(skip|skipif|xfail)|pytest\.(skip|xfail)\(|unittest\.(skip|expectedFailure)|\.skip\(|\.only\(|(^|[^A-Za-z0-9_.])(xit|xdescribe|xtest)\(|\.fixme\(|t\.Skip(Now|f)?\(|@Disabled|@Ignore}"
TEST_ASSERT_PATTERN="${TEST_ASSERT_PATTERN:-(^|[^A-Za-z0-9_])assert|expect\(|\.should|(^|[^A-Za-z0-9_])t\.(Error|Errorf|Fatal|Fatalf)\(|require\.[A-Z]}"
TEST_GLOBS="${TEST_GLOBS:-tests/ test/ __tests__/ e2e/ test_*.py *_test.py conftest.py *.test.* *.spec.* *_test.go *Test.java *Tests.java}"
SNAPSHOT_GLOBS="${SNAPSHOT_GLOBS:-__snapshots__/ *.snap *-snapshots/}"

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

sandbox_milestone_tag() {
  # The `milestone` tag of sandbox <id>'s record in agent-sandbox status --json; empty
  # when the record, the tag or agent-sandbox itself is missing.
  local js
  js="$(agent-sandbox status --json 2>/dev/null)" || return 0
  if have_jq; then
    printf '%s' "$js" | jq -r --arg id "$1" '.[]? | select(.sandbox_id == $id) | .tags.milestone // empty' 2>/dev/null | head -n 1 || true
  else
    printf '%s' "$js" | python3 -c '
import json, sys
try:
    for r in json.load(sys.stdin):
        if r.get("sandbox_id") == sys.argv[1]:
            m = (r.get("tags") or {}).get("milestone")
            if m not in (None, ""): print(m)
            break
except Exception: pass' "$1" 2>/dev/null || true
  fi
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
  # The line checks are limited to test files so application code (an iterator's .skip(,
  # a production assert) and the report quoting a marker are not hits.
  local base="$1" status path body
  while IFS= read -r -d '' status && IFS= read -r -d '' path; do
    if path_matches "$path" "$SNAPSHOT_GLOBS" && [[ "$status" != A ]]; then
      echo "snapshot $path"
    fi
    path_matches "$path" "$TEST_GLOBS" || continue
    if [[ "$status" == D ]]; then echo "deleted-test $path"; continue; fi
    body="$(git -c core.quotePath=false diff --no-color --no-ext-diff --no-renames --unified=0 "$base" HEAD -- "$path" \
      | awk '/^@@/ { b = 1; next } /^diff --git / { b = 0 } b')"
    if sed -n 's/^+//p' <<< "$body" | grep -Eq -- "$TEST_WEAKENING_PATTERN"; then echo "skip-marker $path"; fi
    if sed -n 's/^-//p' <<< "$body" | grep -Eq -- "$TEST_ASSERT_PATTERN"; then echo "removed-assert $path"; fi
  done < <(git -c core.quotePath=false diff --no-renames --name-status -z "$base" HEAD)
}

status_upsert() {
  # Upsert milestone <n>'s row in .milestones/STATUS.md: Lane, Sandbox, Merged and Gate are
  # set; Unmet criteria, Open blockers and Next action of an existing row are kept.
  local sfile="$REPO/.milestones/STATUS.md" n="$1" lane="$2" id="$3" merged="$4" gate="$5" tmp
  if [[ ! -f "$sfile" ]]; then
    printf '# Milestone status\n\n| Milestone | Lane | Sandbox | Merged | Gate | Unmet criteria | Open blockers | Next action |\n|---|---|---|---|---|---|---|---|\n' > "$sfile"
  fi
  tmp="$(mktemp "$sfile.XXXXXX")"
  awk -F'|' -v n="$n" -v lane="$lane" -v id="$id" -v merged="$merged" -v gate="$gate" '
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
        print "| Milestone | Lane | Sandbox | Merged | Gate | Unmet criteria | Open blockers | Next action |"
        print "|---|---|---|---|---|---|---|---|"
        print "| " n " | " lane " | " id " | " merged " | " gate " | - | - | - |"
      }
    }' "$sfile" > "$tmp"
  cat "$tmp" > "$sfile"; rm -f "$tmp"   # keep the file's own mode
}

INTEGRATE_TREE=""
integrate_cleanup() {
  # Remove the temporary worktree on every exit path.
  [[ -n "$INTEGRATE_TREE" ]] || return 0
  git -C "$REPO" worktree remove --force "$INTEGRATE_TREE/tree" >/dev/null 2>&1 || true
  rm -rf "$INTEGRATE_TREE"
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  INTEGRATE_TREE=""
}

host_gate() {
  # Gate HEAD on the host in a temporary detached worktree seeded with SEED_PATHS copies,
  # so GATE_SETUP never writes the host files every sandbox is seeded from. Writes the
  # evidence line (where=host); returns the gate's exit code. Sets GATE_STEP on failure.
  local n="$1" sha="$2" rc=0 nonce script out setup=none env="-" p marks
  local gatelog="$LOGS/milestone-$n.gate.log"
  INTEGRATE_TREE="$(mktemp -d "${TMPDIR:-/tmp}/integrate-$PROJECT-$n.XXXXXX")"
  trap integrate_cleanup EXIT
  trap 'exit 130' INT TERM
  git worktree add -q --detach "$INTEGRATE_TREE/tree" "$sha" >/dev/null
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
  nonce="rm-gate-$(date +%s)-$$-$RANDOM"
  [[ -n "$GATE_SETUP" ]] && setup=yes
  script="$(gate_script "$nonce")"
  out="$LOGS/integrate-$n-$(date +%Y%m%dT%H%M%S).out"
  log "  host gate in $INTEGRATE_TREE/tree (timeout $GATE_TIMEOUT), output: $out"
  (cd "$INTEGRATE_TREE/tree" && timeout "$GATE_TIMEOUT" bash -c "$script") > "$out" 2>&1 < /dev/null || rc=$?
  marks="$(grep -a "^@@$nonce " "$out" || true)"
  GATE_STEP="$(sed -n "s/^@@$nonce step=//p" <<< "$marks" | tail -n 1)"
  (( rc == 124 )) && GATE_STEP="timeout $GATE_TIMEOUT"
  if [[ -n "$GATE_ENV" ]]; then
    if grep -q "^@@$nonce env=" <<< "$marks"; then env="$(sed -n "s/^@@$nonce env=//p" <<< "$marks" | tail -n 1)"
    else env="unavailable"; fi
  fi
  gate_evidence "$rc" "$n" "${sha:0:12}" host "$setup" "$env" "$gatelog"
  integrate_cleanup
  return "$rc"
}

do_integrate() {
  local id="$INTEGRATE_ID" n="" tag branch upstream remote mref pre base sbranch c m ok
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
  # The ahead rule (KTD5). Every commit on the branch that its upstream lacks must be
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

  # ---- merge
  if git merge-base --is-ancestor "$sbranch" HEAD; then
    pre="$upstream"
    log "  $sbranch already merged; re-checking and re-gating HEAD (pre-merge $pre = the upstream)"
  else
    pre="$(git rev-parse HEAD)"
    log "  pre-merge $pre"
    if ! git merge --no-ff -q -m "Merge $sbranch: milestone $n (sandbox $id)" "$sbranch" > "$LOGS/integrate-$n.merge.log" 2>&1; then
      git merge --abort > /dev/null 2>&1 || true
      refuse "merging $sbranch hit a conflict or failed (see $LOGS/integrate-$n.merge.log); merge aborted, HEAD back at $pre"
    fi
    log "  merged $sbranch as $(git rev-parse --short=12 HEAD)"
  fi
  local head; head="$(git rev-parse HEAD)"
  kept() {  # after the merge: a refusal or failure keeps the merge local
    log "integrate milestone $n: $*"
    log "  nothing pushed; the merge stays local. pre-merge $pre; to drop it: git reset --hard $pre"
  }

  # ---- weakening scan over everything about to be pushed
  local hits unlisted=() section="" report="$REPORT_DIR/milestone-$n.md" kind path
  hits="$(weakening_hits "$upstream" | sort -u)"
  if [[ -n "$hits" ]]; then
    section="$(git show "HEAD:$report" 2>/dev/null | report_expectation_section || true)"
    while read -r kind path; do
      grep -Fq -- "$path" <<< "$section" || unlisted+=("$kind $path")
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
    git cat-file -e "HEAD:$evf" 2>/dev/null || { kept "refused: EVALUATE_$n=1 and $evf is not committed"; exit 2; }
    if git show "HEAD:$evf" | grep -qi 'owner action required'; then
      kept "refused: $evf still has a line marked owner action required"; exit 2
    fi
    log "  evaluation record $evf present, no owner action left"
  fi

  # ---- host gate
  GATE_STEP=""
  if ! host_gate "$n" "$head"; then
    kept "host gate FAILED${GATE_STEP:+ at $GATE_STEP}; output under $LOGS/integrate-$n-*.out"
    exit 1
  fi

  # ---- STATUS.md, then push
  local sha12="${head:0:12}" lane
  lane="$(resolve_lane "$n")"
  status_upsert "$n" "$lane" "$id" "$sha12" "pass $sha12 $(date +%Y-%m-%d)"
  git add -- .milestones/STATUS.md
  if git diff --cached --quiet -- .milestones/STATUS.md; then
    log "  STATUS.md row for milestone $n unchanged"
  else
    git commit -q -m "milestone $n: STATUS.md after a passing host gate on $sha12" -- .milestones/STATUS.md
    log "  STATUS.md row for milestone $n committed as $(git rev-parse --short=12 HEAD)"
  fi
  if ! git push -q "$remote" "HEAD:$mref" > "$LOGS/integrate-$n.push.log" 2>&1; then
    log "integrate milestone $n: push failed to $remote $mref (see $LOGS/integrate-$n.push.log); the gated merge and STATUS commit stay local. pre-merge $pre"
    exit 1
  fi
  log "integrate milestone $n: pushed $branch to $remote as $(git rev-parse --short=12 HEAD) ($(git rev-parse HEAD)) $(date -Is)"
}

# ---------------------------------------------------------------- config
do_config() {
  # What milestone <n> resolves to, one KEY=value per line, so a launch can be checked
  # before a run is spent on it.
  local n="$1" mem cpus model effort ev tv
  mem="MEMORY_$n"; cpus="CPUS_$n"; model="MODEL_$n"; effort="EFFORT_$n"; ev="EVALUATE_$n"; tv="EVALUATE_TARGET_$n"
  echo "MEMORY=${!mem:-${MEMORY:-}}"
  echo "CPUS=${!cpus:-${CPUS:-}}"
  echo "MODEL=${!model:-${MODEL:-}}"
  echo "EFFORT=${!effort:-${EFFORT:-}}"
  echo "LANE=$(resolve_lane "$n")"
  if [[ "${!ev:-}" == 1 ]]; then echo "EVALUATE=1"; else echo "EVALUATE=0"; fi
  echo "EVALUATE_TARGET=${!tv:-}"
  echo "GATE_SETUP=$GATE_SETUP"
  echo "GATE=$GATE"
  echo "GATE_ENV=$GATE_ENV"
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
  launch_unit continue "${MILESTONES[0]:-continue}"
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
