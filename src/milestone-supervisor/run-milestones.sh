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
#
# One milestone per invocation: the supervisor reviews between milestones, so the
# driver refuses `run-milestones.sh 5 6`. The launch returns as soon as systemd accepts
# the unit; read `status` right after, because admission runs inside the unit.
#
# <repo>/.milestones/config      shell assignments, all optional:
#   MILESTONES_FILE=docs/spec/11-milestones.md   file whose "## Milestone N" sections are the briefs
#   REPORT_DIR=docs/reports                      the agent writes milestone-N.md here
#   GATE="uv run pytest -q -x && uv run ruff check src tests"   run inside the sandbox after each milestone
#   DEPLOY_MILESTONES="7"                        numbers that need --deploy
#   TIMEOUT=12h                                  per-milestone wall clock (12h, 90m, 3600)
#   MEMORY=8g CPUS=6                             container resources for every milestone
#   MEMORY_6=12g CPUS_6=8                        overrides for one milestone; unset keys fall back
#   MODEL=opus EFFORT=high                         the model and effort the agent runs at (claude --model/--effort)
#   MODEL_7=opus EFFORT_7=max                      per-milestone overrides; unset keys mean the session default (Opus at most)
#                                                to MEMORY/CPUS, then to agent-sandbox's config
# <repo>/.milestones/standing-rules.md          rules every milestone gets; "milestone-N" is substituted
# <repo>/.milestones/milestone-N.md             optional extra paragraph for milestone N
# <repo>/.milestones/notes-N.md                 optional supervisor notes, appended if present and --note is not given
#
# Files under <repo>/logs/milestones/: chain.log (every decision), unit-<unit>.out (the
# unit's stdout+stderr), milestone-N.prompt, milestone-N.log and milestone-N.gate.log (the
# agent-sandbox result JSON, or the admission refusal). The agent's transcript is the
# sandbox's own runs/<id>/stdout.log, which `status` scans.
#
# A failed gate stops the unit and leaves the sandbox for inspection. Nothing is merged
# or pushed: the work stays on the sandbox branch, and push is denied inside the container.
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REPO="$(pwd -P)"
[[ -d "$REPO/.milestones" ]] || { echo "no .milestones/ in $REPO; run from the project root" >&2; exit 2; }
PROJECT="$(basename "$REPO")"
MILESTONES_FILE="docs/spec/11-milestones.md"; REPORT_DIR="docs/reports"   # defaults; .milestones/config overrides
GATE="uv run pytest -q -x && uv run ruff check src tests"; DEPLOY_MILESTONES=""; TIMEOUT="12h"
GATE_TIMEOUT="30m"
# shellcheck disable=SC1091
[[ -f "$REPO/.milestones/config" ]] && source "$REPO/.milestones/config"
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

json_sandbox_id() {
  # `.sandbox_id` from a run/enter --json result; empty when absent.
  if have_jq; then
    json_from "$1" | jq -r '.sandbox_id // empty' 2>/dev/null || true
  else
    json_from "$1" | python3 -c '
import json, sys
try: print(json.load(sys.stdin).get("sandbox_id") or "")
except Exception: pass' 2>/dev/null || true
  fi
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
VERB=""; SANDBOX=""; DEPLOY=0; NOTE=""; CONTINUE=""; INSIDE=""; UNIT=""; GATE_ONLY=0; ISSUE=0
MILESTONES=(); RES=(); TAGS=(); AGENT_OPTS=()
while (($#)); do
  case "$1" in
    status|resume) VERB="$1"; shift ;;
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
    --tag) TAGS+=(--tag "$2"); shift 2 ;;      # (inside) unit=<unit> milestone=<n>
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
run_gate() {
  local n="$1" rc=0
  sandbox_call "$LOGS/milestone-$n.gate.log" enter "$SANDBOX" --timeout "$GATE_TIMEOUT" "${RES[@]}" "${TAGS[@]}" --json -- \
    bash -lc "$GATE && test -s $REPORT_DIR/milestone-$n.md" || rc=$?
  if (( rc == 3 )); then
    log "milestone $n: gate not admitted; unit stops"; return 3
  elif (( rc == 0 )); then
    log "milestone $n: gate passed $(date -Is)"; return 0
  fi
  log "milestone $n: gate FAILED (exit $rc), see $LOGS/milestone-$n.gate.log and the sandbox transcript; unit stops"
  return 1
}

inside_body() {
  local n="$INSIDE" rc=0
  UNIT="${UNIT:-${MILESTONE_UNIT:-untracked}}"
  ((${#TAGS[@]})) || TAGS=(--tag "unit=$UNIT" --tag "milestone=$n")

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
    sandbox_call "$LOGS/create.log" run "$REPO" --new "${RES[@]}" "${TAGS[@]}" --json -- true || rc=$?
    (( rc == 3 )) && { log "milestone $n: sandbox creation not admitted; unit stops"; return 3; }
    # The id comes from the result JSON, else the create log's own "workspace
    # preserved" line. Never pick the newest worktree by mtime: a running agent keeps
    # its worktree newer than a freshly created one.
    SANDBOX="$(json_sandbox_id "$LOGS/create.log")"
    [[ -n "$SANDBOX" ]] || SANDBOX="$(sed -n 's#.*workspace preserved: .*/worktrees/\([^/ ]*\).*#\1#p' "$LOGS/create.log" | tail -1)"
    [[ -n "$SANDBOX" ]] || { log "could not read the new sandbox id from $LOGS/create.log (agent-sandbox exit $rc)"; return 1; }
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
  local kind="$1" n="$2" max t g stamp unit out
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

  local inner=("$SELF" --inside "$n" --unit "$unit" "${RES[@]}" "${AGENT_OPTS[@]}" --tag "unit=$unit" --tag "milestone=$n")
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

# ---------------------------------------------------------------- dispatch
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
if (( GATE_ONLY )); then
  [[ -n "$SANDBOX" ]] || die "--gate needs --sandbox ID"
  launch_unit gate "$n"
  exit 0
fi
for d in $DEPLOY_MILESTONES; do
  [[ "$n" == "$d" && $DEPLOY == 0 ]] && die "milestone $n deploys; pass --deploy to allow it"
done
launch_unit milestone "$n"
