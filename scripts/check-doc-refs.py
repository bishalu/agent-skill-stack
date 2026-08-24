#!/usr/bin/env python3
"""Find references in markdown that no longer resolve.

Every documentation survey behind this repo found the same defect class: docs
citing paths, modules and commands the code no longer has. That is mechanically
checkable, so it is a command rather than a reading exercise.

    python3 check-doc-refs.py <repo> [--json out.json] [--exclude DIR ...]

Reports, per document, the referenced paths and module imports that do not exist
in the repo. Exits non-zero when anything is unresolved, so it works as a gate.

Deliberately conservative. A reference is only reported when it looks like a real
path or import AND fails to resolve anywhere sensible, because a checker that
cries wolf gets ignored and the drift comes back.
"""
import argparse, json, os, re, subprocess, sys

# `backticked/path.py`, or a bare path with a known code extension
CODE_EXT = (".py", ".ts", ".tsx", ".js", ".mjs", ".jsx", ".sh", ".yml", ".yaml",
            ".json", ".toml", ".cfg", ".ini", ".tf", ".sql", ".md", ".mdx",
            ".parquet", ".csv", ".pt", ".db", ".index", ".hcl", ".txt")
BACKTICK = re.compile(r"`([^`\n]{2,120})`")
MD_LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
PY_IMPORT = re.compile(r"^\s*(?:from\s+([\w.]+)\s+import|import\s+([\w.]+))", re.M)
FENCE = re.compile(r"```[a-zA-Z]*\n(.*?)```", re.S)

SKIP_DIRS = {".git", "node_modules", "venv", ".venv", "site-packages", "__pycache__",
             ".pytest_cache", ".next", "dist", "build", ".mypy_cache", ".ruff_cache",
             ".claude/worktrees"}


def ignored(repo, paths):
    """Ask git which of these are gitignored. Build outputs are expected to be absent
    from a clean checkout, so citing one is not a broken reference."""
    if not paths:
        return set()
    try:
        r = subprocess.run(["git", "-C", repo, "check-ignore", "--stdin"],
                           input="\n".join(paths), text=True,
                           capture_output=True)
        return {x for x in r.stdout.split("\n") if x}
    except (subprocess.CalledProcessError, FileNotFoundError):
        return set()


def tracked_files(repo):
    """Prefer git's index: it is the set that actually ships."""
    try:
        out = subprocess.check_output(["git", "-C", repo, "ls-files"], text=True,
                                      stderr=subprocess.DEVNULL)
        files = set(out.split("\n"))
        files.discard("")
        if files:
            return files
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    files = set()
    for dp, dn, fn in os.walk(repo):
        dn[:] = [d for d in dn if d not in SKIP_DIRS]
        for f in fn:
            files.add(os.path.relpath(os.path.join(dp, f), repo))
    return files


# Things that look like paths but are not references to files in this repo.
PLACEHOLDER = re.compile(r"[<>{}]|\.\.\.|\b[A-Z][A-Z0-9_]{2,}\b")


def looks_like_path(s):
    if s.startswith(("http://", "https://", "mailto:", "#", "<", "/")):
        return False        # leading / is an API route or an absolute path, not ours
    if any(c in s for c in " |*?$\n\t") or s.endswith(("/", ":")):
        return False
    if PLACEHOLDER.search(s):
        return False        # configs/<campaign>.yaml, experiments/RUN_ID/..., $VAR
    if "/" not in s:
        return False        # a bare basename is too generic to attribute
    if s.startswith("-"):
        return False
    if not re.fullmatch(r"[\w./@-]+", s):
        return False
    return s.endswith(CODE_EXT) or "/" in s


def in_repo_namespace(ref, tops):
    return ref.split("/")[0] in tops


def resolves(ref, files, dirs, repo, doc_dir):
    ref = ref[2:] if ref.startswith("./") else ref
    ref = ref.rstrip("/")
    if not ref:
        return True
    if ref in files or ref in dirs:
        return True
    # relative to the document that cites it
    rel = os.path.normpath(os.path.join(doc_dir, ref)) if doc_dir else ref
    if rel in files or rel in dirs:
        return True
    # a basename that exists somewhere: the path drifted, the file did not
    base = os.path.basename(ref)
    if any(f.endswith("/" + base) or f == base for f in files):
        return "moved"
    if os.path.exists(os.path.join(repo, ref)):
        return True          # untracked but present, e.g. gitignored artifacts
    # "utils/beat_grid.detect_beat_grid" is a module.function reference, not a
    # path. Resolve it when the module exists and the tail is an identifier
    # rather than a file extension.
    head, _, tail = ref.rpartition(".")
    if head and tail and not tail.startswith(tuple(e[1:] for e in CODE_EXT)):
        if tail.isidentifier() and (head + ".py" in files or head in dirs):
            return True
    return False


def module_path(mod):
    return mod.replace(".", "/")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("repo")
    ap.add_argument("--json", default=None)
    ap.add_argument("--exclude", nargs="*", default=[])
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    repo = os.path.abspath(os.path.expanduser(a.repo))
    files = tracked_files(repo)
    files = {f for f in files if not any(f.startswith(x.rstrip("/") + "/") for x in a.exclude)}
    dirs = set()
    for f in files:
        p = os.path.dirname(f)
        while p:
            dirs.add(p)
            p = os.path.dirname(p)
    top_modules = {f.split("/")[0] for f in files if f.endswith(".py")}
    tops = {f.split("/")[0] for f in files}       # the repo's own top-level namespace

    docs = sorted(f for f in files if f.endswith((".md", ".mdx")))
    report, dead, moved = {}, 0, 0

    for doc in docs:
        full = os.path.join(repo, doc)
        try:
            text = open(full, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        doc_dir = os.path.dirname(doc)
        refs = set()
        for m in BACKTICK.finditer(text):
            s = m.group(1).strip()
            if looks_like_path(s):
                refs.add(s)
        for m in MD_LINK.finditer(text):
            s = m.group(1).strip()
            if looks_like_path(s):
                refs.add(s.split("#")[0])

        bad, relocated = [], []
        for r in sorted(refs):
            v = resolves(r, files, dirs, repo, doc_dir)
            if v == "moved":
                relocated.append(r)
            elif v is False and in_repo_namespace(r, tops):
                # Report a miss only when the first segment names something this repo
                # actually has. Filters roles/owner, 35.235.240.0/20, multipart/form-data
                # and next/font, none of which are paths in this tree.
                bad.append(r)
        skip = ignored(repo, bad)
        bad = [b for b in bad if b not in skip]

        # imports inside python fences, checked against first-party modules only
        bad_imports = []
        for fence in FENCE.findall(text):
            for m in PY_IMPORT.finditer(fence):
                mod = (m.group(1) or m.group(2) or "").strip()
                root = mod.split(".")[0]
                if root not in top_modules:
                    continue                     # third-party, not ours to check
                mp = module_path(mod)
                if not (mp + ".py" in files or mp in dirs or mp + "/__init__.py" in files):
                    bad_imports.append(mod)

        if bad or relocated or bad_imports:
            report[doc] = {"dead": bad, "moved": relocated,
                           "dead_imports": sorted(set(bad_imports))}
            dead += len(bad) + len(set(bad_imports))
            moved += len(relocated)

    if not a.quiet:
        name = os.path.basename(repo)
        print(f"\n{name}: {len(docs)} documents, {dead} unresolved, {moved} moved\n")
        for doc, r in sorted(report.items(), key=lambda x: -(len(x[1]["dead"]) + len(x[1]["dead_imports"]))):
            n = len(r["dead"]) + len(r["dead_imports"])
            if not n and not r["moved"]:
                continue
            print(f"  {doc}")
            for x in r["dead"]:
                print(f"      dead   {x}")
            for x in r["dead_imports"]:
                print(f"      dead   import {x}")
            for x in r["moved"]:
                print(f"      moved  {x}")

    if a.json:
        json.dump({"repo": repo, "documents": len(docs), "unresolved": dead,
                   "moved": moved, "report": report}, open(a.json, "w"), indent=2)

    sys.exit(1 if dead else 0)


if __name__ == "__main__":
    main()
