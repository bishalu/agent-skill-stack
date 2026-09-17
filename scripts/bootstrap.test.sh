#!/usr/bin/env bash
# Tests for the managed config merge in install.sh and for bootstrap.sh --dry-run.
# Everything runs against a temporary CLAUDE_HOME; the real ~/.claude is never read or
# written. Exits non-zero at the first failing assertion.
#
#   bash scripts/bootstrap.test.sh
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASSED=0

fail() { echo "FAIL: $*"; exit 1; }
ok() { PASSED=$((PASSED + 1)); echo "ok   $*"; }
count() { python3 - "$1" "$2" "$3" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
node = s
for k in sys.argv[2].split("."):
    node = node.get(k, {}) if isinstance(node, dict) else {}
print(node.count(sys.argv[3]) if isinstance(node, list) else 0)
PY
}
get() { python3 -c 'import json,sys
s=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): s=s[k]
print(s)' "$1" "$2"; }
merge() { CLAUDE_HOME="$1" "$R/scripts/install.sh" --config-only >"$T/merge.out" 2>&1; }

MILESTONE_LINE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["autoMode"]["environment"][0])' "$R/src/settings-snippet.json")"

# ---------------------------------------------------------------- existing settings.json
H="$T/home1"; mkdir -p "$H"
cat > "$H/settings.json" <<'EOF'
{
  "theme": "dark",
  "model": "opus",
  "permissions": {"allow": ["Bash(ls:*)", "Bash(agent-sandbox:*)"], "defaultMode": "auto"},
  "autoMode": {"soft_deny": ["$defaults"], "environment": ["### Org-wide", "an owner line"]},
  "hooks": {"Stop": []}
}
EOF
printf '# My notes\n\nkeep this paragraph\n' > "$H/CLAUDE.md"

merge "$H" || { cat "$T/merge.out"; fail "first merge exited non-zero"; }
cp "$H/settings.json" "$T/after1.json"; cp "$H/CLAUDE.md" "$T/after1.md"

[ "$(get "$H/settings.json" theme)" = dark ] || fail "unrelated key theme dropped"
[ "$(get "$H/settings.json" model)" = opus ] || fail "unrelated key model dropped"
[ "$(get "$H/settings.json" permissions.defaultMode)" = auto ] || fail "permissions.defaultMode dropped"
[ "$(get "$H/settings.json" autoMode.soft_deny)" = "['\$defaults']" ] || fail "autoMode.soft_deny changed"
python3 -c 'import json,sys; assert "hooks" in json.load(open(sys.argv[1]))' "$H/settings.json" || fail "hooks dropped"
ok "unrelated keys kept"

[ "$(count "$H/settings.json" permissions.allow 'Bash(ls:*)')" = 1 ] || fail "owner rule dropped"
[ "$(count "$H/settings.json" permissions.allow 'Bash(agent-sandbox:*)')" = 1 ] || fail "pre-existing snippet rule duplicated"
[ "$(count "$H/settings.json" autoMode.environment 'an owner line')" = 1 ] || fail "owner environment line dropped"
[ "$(count "$H/settings.json" autoMode.environment "$MILESTONE_LINE")" = 1 ] || fail "milestone environment line not appended once"
[ "$(python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))["autoMode"]["environment"]; print(e.index(sys.argv[2]) == len(e)-1)' "$H/settings.json" "$MILESTONE_LINE")" = True ] \
  || fail "milestone environment line not appended at the end"
ok "owner rules and lines kept, snippet entries present once"

HABS="$(cd "$H" && pwd)"
[ "$(count "$H/settings.json" permissions.allow "Bash($HABS/skills/milestone-supervisor/run-milestones.sh:*)")" = 1 ] \
  || fail "run-milestones.sh rule not expanded to CLAUDE_HOME"
[ "$(count "$H/settings.json" permissions.allow "Edit(/$HABS/skills/milestone-supervisor/**)")" = 1 ] \
  || fail "Edit rule not written as an absolute // path"
[ "$(count "$H/settings.json" permissions.allow 'Write(**/.milestones/**)')" = 1 ] || fail "Write .milestones rule missing"
! grep -q '{{' "$H/settings.json" || fail "a placeholder survived the merge"
! grep -q '_comment' "$H/settings.json" || fail "the snippet's _comment leaked into settings.json"
ok "placeholders expanded"

grep -q 'keep this paragraph' "$H/CLAUDE.md" || fail "CLAUDE.md owner content dropped"
[ "$(grep -c 'agent-skill-stack:start' "$H/CLAUDE.md")" = 1 ] || fail "CLAUDE.md block not present once"
grep -q 'Opus at most' "$H/CLAUDE.md" || fail "Opus cap preference missing from the block"
grep -q '/login' "$H/CLAUDE.md" || fail "no-login preference missing from the block"
ok "CLAUDE.md block carries the owner preferences"

merge "$H" || { cat "$T/merge.out"; fail "second merge exited non-zero"; }
cmp -s "$H/settings.json" "$T/after1.json" || { diff "$T/after1.json" "$H/settings.json"; fail "second merge changed settings.json"; }
cmp -s "$H/CLAUDE.md" "$T/after1.md" || fail "second merge changed CLAUDE.md"
grep -q '0 entries added' "$T/merge.out" || fail "second merge did not report 0 entries added"
ok "second merge is a no-op"

# ---------------------------------------------------------------- absent settings.json
H2="$T/home2"
merge "$H2" || { cat "$T/merge.out"; fail "merge into an absent CLAUDE_HOME exited non-zero"; }
[ -s "$H2/settings.json" ] || fail "settings.json not created"
[ "$(count "$H2/settings.json" autoMode.environment "$MILESTONE_LINE")" = 1 ] || fail "created file lacks the environment line"
ok "settings.json created when absent"

# ---------------------------------------------------------------- unreadable settings.json
H3="$T/home3"; mkdir -p "$H3"; printf '{ not json' > "$H3/settings.json"
if merge "$H3"; then fail "merge over invalid JSON succeeded"; fi
[ "$(cat "$H3/settings.json")" = '{ not json' ] || fail "invalid settings.json was overwritten"
ok "invalid settings.json left untouched and the merge fails"

# ---------------------------------------------------------------- bootstrap.sh --dry-run
H4="$T/home4"; mkdir -p "$H4"; echo '{"theme":"light"}' > "$H4/settings.json"
before="$(find "$H4" -type f -exec sha256sum {} + | sort)"
set +e
CLAUDE_HOME="$H4" AGENT_SANDBOX_DIR="$T/no-sandbox" "$R/scripts/bootstrap.sh" --dry-run >"$T/dry.out" 2>&1
rc=$?
set -e
[ "$rc" = 0 ] || { tail -20 "$T/dry.out"; fail "--dry-run exited $rc"; }
for n in 1 2 3 4 5 6; do grep -q "^== phase $n:" "$T/dry.out" || fail "--dry-run did not print phase $n"; done
[ "$before" = "$(find "$H4" -type f -exec sha256sum {} + | sort)" ] || fail "--dry-run changed CLAUDE_HOME"
[ ! -e "$T/no-sandbox" ] || fail "--dry-run created the agent-sandbox directory"
grep -q "would run: git clone https://github.com/bishalu/agent-sandbox.git" "$T/dry.out" || fail "--dry-run did not show the clone"
grep -q "Logins only the owner can do" "$T/dry.out" || fail "--dry-run did not print the login checklist"
ok "--dry-run exits 0, prints every phase, changes nothing"

CLAUDE_HOME="$H4" AGENT_SANDBOX_DIR="$T/no-sandbox" "$R/scripts/bootstrap.sh" --dry-run --phase 3 >"$T/p3.out" 2>&1 || fail "--phase 3 exited non-zero"
grep -q '^== phase 3:' "$T/p3.out" || fail "--phase 3 did not run phase 3"
! grep -q '^== phase [124-6]:' "$T/p3.out" || fail "--phase 3 ran other phases"
ok "--phase selects phases"

set +e; "$R/scripts/bootstrap.sh" --bogus >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 2 ] || fail "unknown argument exited $rc, want 2"
ok "unknown argument exits 2"

echo
echo "$PASSED passed"
