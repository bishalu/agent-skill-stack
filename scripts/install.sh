#!/usr/bin/env bash
# Link build/ into the global Claude Code config. Idempotent.
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G="${CLAUDE_HOME:-$HOME/.claude}"

# --config-only rewrites the CLAUDE.md block and the managed settings and nothing else:
# no relinking, no plugin reinstall, so it is safe while a sandbox mounts the plugin caches.
CONFIG_ONLY=0
case "${1:-}" in
  --config-only) CONFIG_ONLY=1 ;;
  "") ;;
  *) echo "usage: install.sh [--config-only]"; exit 2 ;;
esac

merge_config() {
echo "== global routing invariant"
# The block is delimited, so a changed rule replaces the old one instead of stacking
# a second copy underneath it.
python3 - "$G/CLAUDE.md" "$R/src/claude-md-snippet.md" <<'PY'
import pathlib, sys

target, source = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
block = source.read_text().strip()
START, END = "<!-- agent-skill-stack:start -->", "<!-- agent-skill-stack:end -->"
lines = target.read_text().splitlines() if target.exists() else []

# Drop any previous copy: the delimited block, or an undelimited legacy section left
# by an older installer. Line processing rather than a regex, so no escaping traps.
out, skipping, what = [], None, "appended"
for line in lines:
    if skipping == "delimited":
        if line.strip() == END:
            skipping = None
        continue
    if skipping == "legacy":
        if line.startswith("- ") or not line.strip():
            continue
        skipping = None
    if line.strip() == START:
        skipping, what = "delimited", "updated"
        continue
    if line.strip() == "## Engineering routing":
        skipping, what = "legacy", "migrated"
        continue
    out.append(line)

text = "\n".join(out).rstrip("\n")
text = (text + "\n\n" if text.strip() else "") + block + "\n"
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(text)
print("   " + what + " " + str(target))
PY

echo "== managed settings"
# Lists are unioned and the autoMode environment lines appended only when missing, so a
# rerun changes nothing and the owner's other keys and rules are never dropped. The write
# is a rename, because a running Claude Code session reads this file.
python3 - "$G/settings.json" "$R/src/settings-snippet.json" "$G" <<'PY'
import json, os, pathlib, sys, tempfile

target, source, home = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), os.path.abspath(sys.argv[3])
raw = source.read_text().replace("{{CLAUDE_HOME_ABS}}", "/" + home).replace("{{CLAUDE_HOME}}", home)
snippet = json.loads(raw)
snippet.pop("_comment", None)
settings = json.loads(target.read_text()) if target.exists() and target.read_text().strip() else {}

added = 0
def union(dst, key, items):
    global added
    have = dst.setdefault(key, [])
    if not isinstance(have, list):
        sys.exit(f"   {target}: {key} is not a list; leaving the file untouched")
    for item in items:
        if item not in have:
            have.append(item)
            added += 1

for section, lists in snippet.items():
    dst = settings.setdefault(section, {})
    if not isinstance(dst, dict):
        sys.exit(f"   {target}: {section} is not an object; leaving the file untouched")
    for key, items in lists.items():
        union(dst, key, items)

target.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=target.parent, prefix=".settings.", suffix=".json")
with os.fdopen(fd, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")
if target.exists():
    os.chmod(tmp, target.stat().st_mode & 0o777)
os.replace(tmp, target)
print(f"   {added} entr{'y' if added == 1 else 'ies'} added to {target}")
PY
}

if [ "$CONFIG_ONLY" = 1 ]; then
  merge_config
  exit 0
fi

[ -d "$R/build" ] || { echo "build/ missing — run scripts/build.py first"; exit 1; }

mkdir -p "$G/skills"
echo "== linking standalone skills into $G/skills"
for d in "$R"/build/skills/*/; do
  n="$(basename "$d")"
  t="$G/skills/$n"
  if [ -L "$t" ]; then rm "$t"
  elif [ -e "$t" ]; then
    mv "$t" "$t.pre-stack.$(date +%Y%m%d%H%M%S)"
    echo "   moved aside existing $n"
  fi
  ln -s "${d%/}" "$t"
  echo "   $n"
done

echo "== plugins"
claude plugin marketplace add EveryInc/compound-engineering-plugin >/dev/null 2>&1 || \
  claude plugin marketplace update compound-engineering-plugin >/dev/null 2>&1 || true
claude plugin install compound-engineering@compound-engineering-plugin --scope user -y

claude plugin marketplace add "$R/build/marketplace" >/dev/null 2>&1 || \
  claude plugin marketplace update trailofbits-curated >/dev/null 2>&1 || true
claude plugin marketplace add "$R/build/marketplace-aws" >/dev/null 2>&1 || \
  claude plugin marketplace update aws-curated >/dev/null 2>&1 || true
# Claude Code caches a plugin by version. An edited fork keeps its upstream version, so
# neither install nor update re-copies it. Reinstall exactly the plugins whose SKILL.md
# fingerprint changed since the last install.
STATE="$R/.install-state.json"
for entry in $(python3 -c "
import json
c=json.load(open('$R/curation.json'))
for k in ('trailofbits','aws'):
    for p in c[k]['plugins']:
        print(f\"{p}|{c[k]['marketplaceName']}|{c[k]['buildDir']}\")"); do
  p=${entry%%|*}; rest=${entry#*|}; mkt=${rest%%|*}; bdir=${rest##*|}
  now=$(python3 -c "import json;print(json.load(open('$R/build/$bdir/fingerprints.json'))['$p'])")
  was=$(python3 -c "
import json,os
s='$STATE'
print(json.load(open(s)).get('$p','') if os.path.exists(s) else '')" )
  if [ "$now" = "$was" ] && claude plugin list 2>/dev/null | grep -q "$p@$mkt"; then
    echo "   $p unchanged"
  else
    claude plugin uninstall "$p@$mkt" >/dev/null 2>&1 || true
    claude plugin install "$p@$mkt" --scope user -y >/dev/null
    echo "   $p installed"
  fi
done
python3 -c "
import json
a=json.load(open('$R/build/marketplace/fingerprints.json'))
a.update(json.load(open('$R/build/marketplace-aws/fingerprints.json')))
json.dump(a, open('$STATE','w'), indent=2)"

merge_config
echo
echo "Done. Restart Claude Code to pick up the new plugins."
