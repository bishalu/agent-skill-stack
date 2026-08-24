#!/usr/bin/env python3
"""Prove a documentation restyle changed prose and nothing else.

    python3 check-fact-drift.py <repo> [--base HEAD] [--json out.json]

Compares every changed markdown file against its committed version and reports
facts that appear in one and not the other: numbers, file paths, commands,
environment variables, endpoints, and the contents of code fences.

The point is that "I only changed the wording" is a claim, and a claim about a
few hundred edits is not one a human can check by reading. This makes it a
command that fails.

Two rules keep the signal honest:

  A fact that MOVED is fine. Restyling reorders sentences, so position is not
  compared, only presence and count.

  A fact RESTATED in prose is fine and common. Turning a bullet list into a
  sentence legitimately repeats a number that was already in the document, so an
  added occurrence of a value that already appears elsewhere in the same file is
  not drift. A value appearing that is nowhere in the original is.
"""
import argparse, json, os, re, subprocess, sys
from collections import Counter

NUM = re.compile(r"(?<![\w.])\d+(?:\.\d+)?(?![\w])")
PATH = re.compile(r"`([\w./@-]*/[\w./@-]+)`")
# An env var, not a shouty word in prose. Require it to be backticked, assigned,
# or dereferenced. Debolding "**CRITICAL**:" is a style fix, not a fact change.
ENVVAR = re.compile(r"`([A-Z][A-Z0-9_]{3,})`|\$\{?([A-Z][A-Z0-9_]{3,})\}?|"
                    r"\b([A-Z][A-Z0-9_]{3,})=")
# An endpoint, not the tail of "v1/v2". Require the slash to start a path rather
# than separate two words.
ENDPOINT = re.compile(r"(?<![\w/])(/(?:api|v\d)[\w/{}.-]*)")
FENCE = re.compile(r"```[a-zA-Z]*\n(.*?)```", re.S)
FLAG = re.compile(r"(?<![\w-])(--[a-z][\w-]+)")

KINDS = {
    "number": NUM,
    "path": PATH,
    "env_var": ENVVAR,
    "endpoint": ENDPOINT,
    "flag": FLAG,
}


def facts(text):
    out = {}
    for kind, rx in KINDS.items():
        vals = []
        for f in rx.findall(text):
            if isinstance(f, tuple):
                f = next((x for x in f if x), "")
            if f:
                vals.append(f)
        out[kind] = Counter(vals)
    # Dedent before comparing: moving a fence out of a list changes its indent and
    # nothing else. Compare the code, not its position on the page.
    out["fence"] = Counter(dedent(f) for f in FENCE.findall(text))
    # Prose legitimately spells small numbers, so "4 features" becoming "four
    # additions" is a style fix. Track small integers separately, low signal.
    small = {v for v in out["number"] if v.isdigit() and int(v) < 21}
    out["small_int"] = Counter({k: out["number"][k] for k in small})
    for k in small:
        del out["number"][k]
    return out


def dedent(block):
    lines = [l for l in block.split("\n")]
    strip = min((len(l) - len(l.lstrip()) for l in lines if l.strip()), default=0)
    return "\n".join(l[strip:] if l.strip() else "" for l in lines).strip()


def changed_docs(repo, base):
    out = subprocess.check_output(
        ["git", "-C", repo, "diff", "--name-only", base, "--", "*.md", "*.mdx"],
        text=True)
    return [f for f in out.split("\n") if f]


def show(repo, base, path):
    try:
        return subprocess.check_output(["git", "-C", repo, "show", f"{base}:{path}"],
                                       text=True, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("repo")
    ap.add_argument("--base", default="HEAD")
    ap.add_argument("--json", default=None)
    a = ap.parse_args()

    repo = os.path.abspath(os.path.expanduser(a.repo))
    docs = changed_docs(repo, a.base)
    report, total = {}, 0

    for doc in docs:
        old = show(repo, a.base, doc)
        if not old:
            continue                       # newly added file, nothing to drift from
        try:
            new = open(os.path.join(repo, doc), encoding="utf-8").read()
        except OSError:
            continue                       # deleted, handled by the diff review

        fo, fn = facts(old), facts(new)
        drift = {}
        for kind in fo:
            lost = fo[kind] - fn[kind]
            gained = fn[kind] - fo[kind]
            # A value restated in prose is not drift: it was already in the file.
            gained = Counter({k: v for k, v in gained.items() if k not in fo[kind]})
            if lost or gained:
                drift[kind] = {"lost": dict(lost), "gained": dict(gained)}
        if drift:
            report[doc] = drift
            # small_int churn is prose spelling, reported but not counted as failure
            total += sum(len(d["lost"]) + len(d["gained"])
                         for k, d in drift.items() if k != "small_int")

    print(f"\n{os.path.basename(repo)}: {len(docs)} changed documents, "
          f"{len(report)} with possible fact drift, {total} items\n")
    for doc, drift in sorted(report.items(), key=lambda x: -sum(
            len(d['lost']) + len(d['gained']) for d in x[1].values())):
        print(f"  {doc}")
        for kind, d in drift.items():
            for k, v in d["lost"].items():
                print(f"      LOST   {kind:<9} {k[:100]!r} x{v}")
            for k, v in d["gained"].items():
                print(f"      NEW    {kind:<9} {k[:100]!r} x{v}")

    if a.json:
        json.dump({"repo": repo, "changed": len(docs), "drifted": len(report),
                   "items": total, "report": report}, open(a.json, "w"), indent=2)

    sys.exit(1 if total else 0)


if __name__ == "__main__":
    main()
