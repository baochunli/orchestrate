#!/usr/bin/env python3
"""Fake `gh` for the merge-train tests. State lives in $FAKE_GH; the "GitHub" repo is the bare repo $FAKE_BARE.

PR state is derived like GitHub: MERGED once the PR head commit is in main, CLOSED after `pr close`, else OPEN.
CI for a commit (only commits that are, or were, a PR head) is decided by its tree:
  file "early-red"                 -> job "unit" fails
  files "needs-old-api" and "new-api" -> job "unit" fails (a branch that only breaks on top of the new main)
  files "pair-a" and "pair-b"      -> job "unit" fails (two branches, each green alone, red together)
$FAKE_GH/fail-view present          -> `pr view` fails (GitHub unreachable)
  file "slow"                      -> pending for $FAKE_SLOW queries (default 8), else $FAKE_PENDING (default 2)
Every commit whose CI reached a verdict is appended once to $FAKE_GH/ci-runs.log ("<sha> pass|fail").
"""
import fcntl, json, os, subprocess, sys

ST = os.environ["FAKE_GH"]; BARE = os.environ["FAKE_BARE"]
os.makedirs(f"{ST}/prs", exist_ok=True); os.makedirs(f"{ST}/ci", exist_ok=True)
lockf = open(f"{ST}/lock", "w"); fcntl.flock(lockf, fcntl.LOCK_EX)

def git(*a, cwd=BARE, check=True):
    r = subprocess.run(["git", *a], cwd=cwd, capture_output=True, text=True)
    if check and r.returncode: sys.stderr.write(r.stderr); sys.exit(1)
    return r

def ref(name):
    r = git("rev-parse", "-q", "--verify", f"refs/heads/{name}^{{commit}}", check=False)
    return r.stdout.strip() if r.returncode == 0 else None

def is_anc(a, b): return git("merge-base", "--is-ancestor", a, b, check=False).returncode == 0

def load(n): return json.load(open(f"{ST}/prs/{n}.json"))
def save(p): json.dump(p, open(f"{ST}/prs/{p['number']}.json", "w"))
def allprs(): return [load(f[:-5]) for f in sorted(os.listdir(f"{ST}/prs"), key=lambda x: int(x[:-5]))]
def num(u): return int(str(u).rstrip("/").split("/")[-1].lstrip("#"))

def refresh(p):
    if p["state"] == "OPEN":
        h = ref(p["head"])
        if h: p["oid"] = h; p.setdefault("heads", []); h in p["heads"] or p["heads"].append(h)
        main = ref("main")
        if p.get("oid") and main and is_anc(p["oid"], main): p["state"] = "MERGED"
        save(p)
    return p

def view(p):
    return {"number": p["number"], "url": p["url"], "state": p["state"], "headRefOid": p.get("oid", ""),
            "headRefName": p["head"], "title": p["title"]}

def ci(sha):
    if not any(sha in p.get("heads", []) for p in allprs()): return None
    files = set(git("ls-tree", "-r", "--name-only", sha).stdout.split())
    red = "early-red" in files or {"needs-old-api", "new-api"} <= files or {"pair-a", "pair-b"} <= files
    need = int(os.environ.get("FAKE_SLOW", 8)) if "slow" in files else int(os.environ.get("FAKE_PENDING", 2))
    cf = f"{ST}/ci/{sha}"; n = int(open(cf).read()) if os.path.exists(cf) else 0
    n += 1; open(cf, "w").write(str(n))
    if n <= need: return "pending"
    v = "fail" if red else "pass"
    if n == need + 1: open(f"{ST}/ci-runs.log", "a").write(f"{sha} {v}\n")
    return v

def out(obj, args):
    q = None
    for k in ("-q", "--jq"):
        if k in args: q = args[args.index(k) + 1]
    s = json.dumps(obj)
    if q is None: print(s); return
    r = subprocess.run(["jq", "-r", f"({q}) // empty"], input=s, capture_output=True, text=True)
    sys.stdout.write(r.stdout); sys.exit(r.returncode)

def opt(args, k, d=None): return args[args.index(k) + 1] if k in args else d

a = sys.argv[1:]
open(f"{ST}/calls.log", "a").write(" ".join(a) + "\n")
if a[:2] == ["repo", "view"]: out({"nameWithOwner": "o/r"}, a); sys.exit(0)
if a[0] == "api":
    sha = a[1].split("/commits/")[1].split("/")[0]; v = ci(sha)
    runs = [] if v is None else [{"name": "unit", "status": "in_progress" if v == "pending" else "completed"}]
    out({"total_count": len(runs), "check_runs": runs}, a); sys.exit(0)
if a[0] != "pr": sys.exit("fake gh: unsupported " + " ".join(a))
c = a[1]
if c == "list":
    st = opt(a, "--state", "open").upper(); hd = opt(a, "--head")
    ps = [view(refresh(p)) for p in allprs()]
    ps = [p for p in ps if (st == "ALL" or p["state"] == st) and (hd is None or p["headRefName"] == hd)]
    ps.reverse(); out(ps, a)
elif c == "create":
    hd = opt(a, "--head"); n = len(os.listdir(f"{ST}/prs")) + 1
    if not ref(hd): sys.exit("fake gh: no remote branch " + hd)
    p = {"number": n, "url": f"https://github.com/o/r/pull/{n}", "head": hd, "title": opt(a, "--title"),
         "body": open(opt(a, "--body-file")).read(), "state": "OPEN"}
    save(p); refresh(p); print(p["url"])
elif c == "edit":
    p = load(num(a[2])); p["title"] = opt(a, "--title", p["title"]); save(p)
elif c == "view":
    if os.path.exists(f"{ST}/fail-view"): sys.exit("fake gh: HTTP 502")
    out(view(refresh(load(num(a[2])))), a)
elif c == "checks":
    p = refresh(load(num(a[2]))); v = ci(p["oid"])
    out([] if v is None else [{"name": "unit", "bucket": v}, {"name": "lint", "bucket": "pass" if v != "pending" else "pending"}], a)
elif c == "merge":
    p = refresh(load(num(a[2]))); h = opt(a, "--match-head-commit")
    if p["state"] != "OPEN" or (h and h != p["oid"]): sys.exit("fake gh: cannot merge")
    sc = f"{ST}/scratch"
    if not os.path.isdir(sc): git("clone", "-q", BARE, sc, cwd=ST)
    git("fetch", "-q", "origin", cwd=sc); git("checkout", "-q", "-B", "main", "origin/main", cwd=sc)
    git("-c", "user.name=gh", "-c", "user.email=gh@x", "merge", "-q", "--no-ff", "-m",
        f"Merge pull request #{p['number']} from {p['head']}", p["oid"], cwd=sc)
    git("push", "-q", "origin", "main", cwd=sc)
    open(f"{ST}/merges.log", "a").write(f"#{p['number']} {p['head']}\n"); refresh(p)
elif c == "close":
    p = load(num(a[2])); p["state"] = "CLOSED"; save(p)
    if "--delete-branch" in a: git("update-ref", "-d", f"refs/heads/{p['head']}", check=False)
else: sys.exit("fake gh: unsupported pr " + c)
