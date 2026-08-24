#!/usr/bin/env python3
"""Materialize build/ from upstream/ + curation.json.

Never writes to upstream/. Never writes to ~/.claude/plugins/cache.
Regenerating is always safe: build/ is deleted and rebuilt from scratch.
"""
import hashlib, json, os, re, shutil, subprocess, sys, datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UP = os.path.join(ROOT, "upstream")
BUILD = os.path.join(ROOT, "build")

SOURCES = json.load(open(os.path.join(ROOT, "sources.json")))["sources"]
CURATION = json.load(open(os.path.join(ROOT, "curation.json")))

deviations = []   # rows for DEVIATIONS.md
inventory = []    # rows for MANIFEST.md


def sha(clone):
    d = os.path.join(UP, clone)
    return subprocess.check_output(["git", "-C", d, "rev-parse", "HEAD"], text=True).strip()


def split_frontmatter(text):
    """Return (list_of_(key, raw_block), body, had_fm). Blocks keep original bytes."""
    if not text.startswith("---"):
        return [], text, False
    end = text.find("\n---", 3)
    if end < 0:
        return [], text, False
    fm = text[3:end].lstrip("\n")
    body = text[end + 4:]
    entries, cur_key, cur = [], None, []
    for line in fm.split("\n"):
        m = re.match(r"^([A-Za-z0-9_-]+):(.*)$", line)
        if m and not line[:1].isspace():
            if cur_key is not None:
                entries.append((cur_key, "\n".join(cur)))
            cur_key, cur = m.group(1), [line]
        else:
            cur.append(line)
    if cur_key is not None:
        entries.append((cur_key, "\n".join(cur)))
    return entries, body, True


def yaml_scalar(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    return json.dumps(str(v), ensure_ascii=False)   # JSON strings are valid YAML flow scalars


def apply_overrides(path, overrides, origin):
    """Rewrite only the named frontmatter keys, byte-preserving everything else."""
    if not overrides:
        return []
    text = open(path, encoding="utf-8").read()
    entries, body, had = split_frontmatter(text)
    if not had:
        sys.exit(f"FATAL: no frontmatter in {path}")
    before = {k: v for k, v in entries}
    seen, out = set(), []
    for k, raw in entries:
        if k in overrides:
            out.append(f"{k}: {yaml_scalar(overrides[k])}")
            seen.add(k)
        else:
            out.append(raw)
    for k, v in overrides.items():
        if k not in seen:
            out.append(f"{k}: {yaml_scalar(v)}")
    open(path, "w", encoding="utf-8").write("---\n" + "\n".join(out) + "\n---" + body)
    return [(k, before.get(k, "(absent upstream)"), overrides[k], origin) for k in overrides]


def write_provenance(dest, **kw):
    with open(os.path.join(dest, ".provenance.json"), "w") as f:
        json.dump(kw, f, indent=2)


def copytree(src, dst, skip=()):
    def ignore(d, names):
        return [n for n in names if n in skip or n == ".git"]
    shutil.copytree(src, dst, ignore=ignore)


# ---------------------------------------------------------------- vendored skills
def build_vendored(vendor):
    cfg = CURATION[vendor]
    clone = cfg["cloneDir"]
    head = sha(clone)
    src_meta = SOURCES[vendor]
    for name, s in cfg["skills"].items():
        src = os.path.join(UP, clone, s["path"])
        if not os.path.isdir(src):
            sys.exit(f"FATAL: missing upstream skill {src}")
        dest = os.path.join(BUILD, "skills", name)
        inc = s.get("include")
        if inc:
            # Skill lives at a repo root alongside CI, docs, and eval fixtures — take only
            # what the skill itself loads.
            os.makedirs(dest)
            for item in inc:
                a, b = os.path.join(src, item), os.path.join(dest, item)
                if os.path.isdir(a):
                    copytree(a, b)
                elif os.path.exists(a):
                    shutil.copy(a, b)
                else:
                    sys.exit(f"FATAL: missing upstream include {a}")
        else:
            copytree(src, dest)
        skill_md = os.path.join(dest, "SKILL.md")
        rows = apply_overrides(skill_md, s.get("frontmatter", {}), f"{vendor}/{name}")
        for k, old, new, origin in rows:
            deviations.append(dict(skill=name, vendor=vendor, key=k, old=old, new=new,
                                   reason=s["reason"], cls=s["class"]))
        write_provenance(dest, source_repo=src_meta["repo"], source_path=s["path"],
                         upstream_sha=head, license=src_meta["license"],
                         authors=src_meta["authors"], invocation_class=s["class"],
                         modified_keys=sorted(s.get("frontmatter", {}).keys()),
                         reason=s["reason"])
        # Copyleft sources want their licence text to travel with the file, not just a
        # provenance record. MPL is file-level, so each vendored skill carries its own.
        if src_meta["license"] not in ("MIT", "Apache-2.0"):
            up_lic = os.path.join(UP, clone, "LICENSE")
            if os.path.exists(up_lic):
                shutil.copy(up_lic, os.path.join(dest, "LICENSE"))
        inventory.append(dict(name=name, vendor=vendor, cls=s["class"], domain=s["domain"],
                              install="vendored skill → ~/.claude/skills",
                              modified=bool(s.get("frontmatter"))))


# ---------------------------------------------------------------- forked ToB marketplace
def build_fork(key):
    cfg = CURATION[key]
    clone = cfg["cloneDir"]
    head = sha(clone)
    mkt = os.path.join(BUILD, cfg["buildDir"])
    os.makedirs(os.path.join(mkt, "plugins"))
    up_mkt = json.load(open(os.path.join(UP, clone, ".claude-plugin", "marketplace.json")))
    by_name = {p["name"]: p for p in up_mkt["plugins"]}
    entries = []
    for pname, p in cfg["plugins"].items():
        src = os.path.join(UP, clone, "plugins", pname)
        if not os.path.isdir(src):
            sys.exit(f"FATAL: missing upstream plugin {src}")
        dest = os.path.join(mkt, "plugins", pname)
        skip = ("evals", "tests") + tuple(p.get("excludePaths", ()))
        copytree(src, dest, skip=skip)   # non-runtime fixtures; keeps the fork small
        keep = p.get("includeSkills")
        if keep:
            # Trim a large first-party plugin to the skills this environment actually uses.
            # Everything dropped is listed in curation.json with the reason.
            sdir = os.path.join(dest, "skills")
            for s in sorted(os.listdir(sdir)):
                if s not in keep:
                    shutil.rmtree(os.path.join(sdir, s))
        for sname, s in p.get("skills", {}).items():
            skill_md = os.path.join(dest, "skills", sname, "SKILL.md")
            rows = apply_overrides(skill_md, s.get("frontmatter", {}), f"trailofbits/{pname}:{sname}")
            for k, old, new, origin in rows:
                deviations.append(dict(skill=sname, vendor=key, key=k, old=old, new=new,
                                       reason=s["reason"], cls=s.get("class", p["class"])))
            inventory.append(dict(name=sname, vendor=key, cls=s.get("class", p["class"]), domain=p["domain"],
                                  install=f"forked plugin {pname} → local marketplace",
                                  modified=bool(s.get("frontmatter"))))
        if not p.get("skills"):
            inventory.append(dict(name=pname + " (commands only)", vendor=key, cls=p["class"],
                                  domain=p["domain"], install=f"forked plugin {pname} → local marketplace",
                                  modified=False))
        write_provenance(dest, source_repo=SOURCES[key]["repo"],
                         source_path=f"plugins/{pname}", upstream_sha=head,
                         license=SOURCES[key]["license"],
                         authors=SOURCES[key]["authors"],
                         invocation_class=p["class"], fork_reason=cfg["note"])
        e = dict(by_name.get(pname, {"name": pname, "description": ""}))
        e["source"] = f"./plugins/{pname}"
        pd = p.get("pluginDescription")
        if pd:
            # Trimming a plugin's skills makes its own blurb inaccurate; keep them in step.
            e["description"] = pd
            mf = os.path.join(dest, ".claude-plugin", "plugin.json")
            if os.path.exists(mf):
                man = json.load(open(mf)); man["description"] = pd
                json.dump(man, open(mf, "w"), indent=2)
            mf2 = os.path.join(dest, "plugin.json")
            if os.path.exists(mf2):
                man = json.load(open(mf2)); man["description"] = pd
                json.dump(man, open(mf2, "w"), indent=2)
            deviations.append(dict(skill=pname + " (plugin manifest)", vendor=key,
                                   key="description", old=by_name.get(pname, {}).get("description", ""),
                                   new=pd, reason=p.get("pluginDescriptionReason", ""), cls=p["class"]))
        entries.append(e)
    # Claude Code caches a plugin by version, so an edited fork at an unchanged version
    # is never re-copied. Fingerprint each plugin's SKILL.md set; install.sh reinstalls
    # only the ones whose fingerprint moved.
    fp = {}
    for pname in cfg["plugins"]:
        h = hashlib.sha256()
        pdir = os.path.join(mkt, "plugins", pname)
        for dp, _, files in sorted(os.walk(pdir)):
            for f in sorted(files):
                if f == "SKILL.md":
                    h.update(open(os.path.join(dp, f), "rb").read())
        fp[pname] = h.hexdigest()[:16]
    json.dump(fp, open(os.path.join(mkt, "fingerprints.json"), "w"), indent=2)

    os.makedirs(os.path.join(mkt, ".claude-plugin"))
    json.dump({
        "name": cfg["marketplaceName"],
        "owner": {"name": "Local curated fork of Trail of Bits skills"},
        "metadata": {
            "description": ("Curated, routing-adjusted fork of selected Trail of Bits security plugins. "
                            f"Original work by {SOURCES[key]['authors']}, {SOURCES[key]['license']}. "
                            f"Forked from {SOURCES[key]['repo']} @ {head}."),
            "version": "1.0.0",
        },
        "plugins": entries,
    }, open(os.path.join(mkt, ".claude-plugin", "marketplace.json"), "w"), indent=2)
    lic = os.path.join(UP, clone, "LICENSE")
    if os.path.exists(lic):
        shutil.copy(lic, os.path.join(mkt, "LICENSE"))
    open(os.path.join(mkt, "NOTICE.md"), "w").write(
        "# NOTICE\n\nThe plugins in this directory are a fork of "
        f"[{SOURCES[key]['repo']}]({SOURCES[key]['url']}) at commit `{head}`, "
        f"by {SOURCES[key]['authors']}, licensed {SOURCES[key]['license']}.\n\n"
        "Changes from upstream are limited to SKILL.md frontmatter (`description`, "
        "`disable-model-invocation`), the removal of non-runtime `evals/` and `tests/` "
        "directories, and where noted the removal of skills this environment does not use. "
        "Every change is listed in ../../DEVIATIONS.md. Skill bodies are unmodified.\n\n"
        f"This fork inherits {SOURCES[key]['license']}.\n")


# ---------------------------------------------------------------- router
def build_router():
    src = os.path.join(ROOT, "src", "engineering-router")
    dest = os.path.join(BUILD, "skills", "engineering-router")
    copytree(src, dest)
    inventory.append(dict(name="engineering-router", vendor="this repo", cls="PASSIVE",
                          domain="routing", install="local skill → ~/.claude/skills", modified=False))


def main():
    if os.path.isdir(BUILD):
        shutil.rmtree(BUILD)
    os.makedirs(os.path.join(BUILD, "skills"))
    build_router()
    build_vendored("mattpocock")
    build_vendored("vercel")
    build_vendored("cursor")
    build_vendored("hashicorp")
    build_fork("trailofbits")
    build_fork("aws")

    stamp = datetime.date.today().isoformat()
    for k, s in SOURCES.items():
        clone = CURATION.get(k, {}).get("cloneDir")
        s["pinnedSha"] = sha(clone) if clone else sha("EveryInc_compound-engineering-plugin")
    json.dump({"$comment": json.load(open(os.path.join(ROOT, "sources.json")))["$comment"],
               "sources": SOURCES}, open(os.path.join(ROOT, "sources.json"), "w"), indent=2)

    json.dump({"builtOn": stamp, "inventory": inventory, "deviations": deviations},
              open(os.path.join(BUILD, "build-report.json"), "w"), indent=2)
    print(f"built {len(inventory)} curated skills, {len(deviations)} frontmatter deviations")
    for d in deviations:
        print(f"  {d['vendor']}/{d['skill']}: {d['key']}")


if __name__ == "__main__":
    main()
