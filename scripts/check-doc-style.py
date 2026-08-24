#!/usr/bin/env python3
"""Score markdown for the tells unslop and technical-writing name.

    python3 check-doc-style.py <repo> [--json out.json] [--min-score N]

This measures. It does not edit, and it is not a gate you can pass by running a
regex over the text. Both source skills say the same thing in different words:
a rule that makes a sentence worse should be broken. A document full of em
dashes that states falsifiable claims and records its own errors is better
writing than a clean one that says nothing, so the score is a reading list
ordered by suspicion, not a verdict.

Two AI signatures show up in practice and they look nothing alike:

  older, list-heavy   bold-label-colon bullets, title-case headings, emoji
                      status markers, near-zero em dashes
  newer, prose-heavy  em-dash pileups, hedging, "not just X but Y", colons
                      used as mid-sentence connectors

Both are counted. A document scoring high on neither is not necessarily good;
it is just not obviously machine-shaped.
"""
import argparse, json, os, re, subprocess, sys

# unslop's catalogue, plus the technical-writing rules that are countable
CHECKS = {
    "em_dash": (re.compile(r"—"),
                "em dashes; end the sentence or use a comma"),
    "bold_label_colon": (re.compile(r"^\s*[-*+]\s+\*\*[^*]+\*\*:", re.M),
                         "bold-label-colon bullets that restate the line"),
    "title_case_heading": (re.compile(r"^#{1,6}\s+(?:[A-Z][a-z]+\s+){2,}[A-Z][a-z]+\s*$", re.M),
                           "title-case headings; use sentence case"),
    "emoji": (re.compile(r"[\U0001F300-\U0001FAFF✅❌⚠⭐✨\U0001F947-\U0001F949]"),
              "decorative emoji"),
    # Case-sensitive on purpose. "Robust Neural AFP" is a paper title and
    # "Seamless" is a model name; a capitalised hit is usually a proper noun the
    # docs are right to quote verbatim. Matching lowercase only costs the
    # sentence-initial case and buys back every citation.
    "ai_vocab": (re.compile(r"\b(crucial|delve|pivotal|showcase|underscore|tapestry|"
                            r"leverage|utilize|facilitate|robust|seamless|holistic|"
                            r"myriad|garner|interplay|intricate|enduring|testament)\b"),
                 "AI vocabulary; use the plain word"),
    "not_just_but": (re.compile(r"\bnot (?:just|only)\b[^.\n]{0,60}\bbut\b", re.I),
                     "\"not just X but Y\"; state the point directly"),
    "fancy_is": (re.compile(r"\b(serves as|stands as|boasts|acts as a)\b", re.I),
                 "fancy ways to say is or has"),
    "filler": (re.compile(r"\b(in order to|due to the fact that|it is important to note that|"
                          r"it should be noted that|needless to say)\b", re.I),
               "filler that survives deletion"),
    "hedge_stack": (re.compile(r"\b(?:could|might|may)\s+(?:potentially|possibly|perhaps)\b", re.I),
                    "stacked hedging"),
    "semicolon": (re.compile(r"[^;]\;(?!\s*$)"),
                  "semicolons; technical-writing says use periods"),
    "curly_quote": (re.compile(r"[‘’“”]"),
                    "curly quotes"),
    "abstract_metaphor": (re.compile(r"\b(substrate|north star|flywheel|bedrock|"
                                     r"paradigm|modality|gold-plating|load-bearing)\b", re.I),
                          "abstract metaphor nouns; pick the concrete word"),
    "simply": (re.compile(r"\b(simply|easily|just simply|quickly)\b", re.I),
               "simply/easily/quickly in a procedure"),
    "passive_hint": (re.compile(r"\b(?:is|are|was|were|be|been)\s+\w+(?:ed|wn|en)\s+by\b", re.I),
                     "passive with a nameable actor"),
}

SKIP = {".git", "node_modules", "venv", ".venv", "site-packages", "__pycache__",
        ".pytest_cache", ".next", "dist", "build", ".claude/worktrees"}

# Weight the signatures that most reliably mean "nobody reread this".
WEIGHT = {"bold_label_colon": 3, "title_case_heading": 2, "emoji": 2,
          "ai_vocab": 3, "not_just_but": 3, "fancy_is": 2, "filler": 3,
          "hedge_stack": 3, "abstract_metaphor": 2, "simply": 2,
          "curly_quote": 1, "semicolon": 1, "em_dash": 1, "passive_hint": 1}


def code_stripped(text):
    """Fenced code and inline code are not prose. Neither is a table of numbers."""
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    text = re.sub(r"`[^`\n]*`", "", text)
    return text


def tracked_docs(repo):
    try:
        out = subprocess.check_output(["git", "-C", repo, "ls-files"], text=True,
                                      stderr=subprocess.DEVNULL)
        docs = [f for f in out.split("\n") if f.endswith((".md", ".mdx"))]
        if docs:
            return docs
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    docs = []
    for dp, dn, fn in os.walk(repo):
        dn[:] = [d for d in dn if d not in SKIP]
        for f in fn:
            if f.endswith((".md", ".mdx")):
                docs.append(os.path.relpath(os.path.join(dp, f), repo))
    return docs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("repo")
    ap.add_argument("--json", default=None)
    ap.add_argument("--min-score", type=int, default=1)
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    repo = os.path.abspath(os.path.expanduser(a.repo))
    rows = []
    for doc in sorted(tracked_docs(repo)):
        try:
            raw = open(os.path.join(repo, doc), encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        lines = max(1, raw.count("\n"))
        prose = code_stripped(raw)
        hits = {}
        for name, (rx, _) in CHECKS.items():
            n = len(rx.findall(prose))
            if n:
                hits[name] = n
        score = sum(WEIGHT[k] * v for k, v in hits.items())
        density = round(score / lines * 100, 1)
        if score >= a.min_score:
            rows.append({"doc": doc, "lines": lines, "score": score,
                         "per_100_lines": density, "hits": hits})

    rows.sort(key=lambda r: -r["per_100_lines"])
    total = sum(r["score"] for r in rows)

    if not a.quiet:
        print(f"\n{os.path.basename(repo)}: {len(rows)} documents with tells, {total} weighted\n")
        print(f"  {'per 100 ln':>10}  {'score':>5}  {'lines':>5}  document")
        for r in rows[:40]:
            top = ", ".join(f"{k}x{v}" for k, v in
                            sorted(r["hits"].items(), key=lambda x: -WEIGHT[x[0]] * x[1])[:4])
            print(f"  {r['per_100_lines']:>10}  {r['score']:>5}  {r['lines']:>5}  {r['doc']}")
            print(f"  {'':>10}  {'':>5}  {'':>5}    {top}")
        if len(rows) > 40:
            print(f"\n  ... {len(rows) - 40} more below the top 40")

    if a.json:
        json.dump({"repo": repo, "documents": len(rows), "weighted_total": total,
                   "rows": rows}, open(a.json, "w"), indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
