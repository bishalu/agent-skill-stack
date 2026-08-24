#!/usr/bin/env bash
# Link build/ into the global Claude Code config. Idempotent.
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G="${CLAUDE_HOME:-$HOME/.claude}"
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

echo "== global routing invariant"
MD="$G/CLAUDE.md"
if ! grep -q "^## Engineering routing" "$MD" 2>/dev/null; then
  { [ -s "$MD" ] && echo; cat "$R/src/claude-md-snippet.md"; } >> "$MD"
  echo "   appended to $MD"
else
  echo "   already present in $MD"
fi
echo
echo "Done. Restart Claude Code to pick up the new plugins."
