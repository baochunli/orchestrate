#!/usr/bin/env python3
"""Fake `gh` for the merge-train tests. State lives in $FAKE_GH; the "GitHub" repo is the bare repo $FAKE_BARE.

PR state is derived like GitHub: MERGED once the PR head commit is in main, CLOSED after `pr close`, else OPEN.
CI for a commit (only commits that are, or were, a PR head) is decided by its tree:
  file "early-red"                 -> job "unit" fails
  files "needs-old-api" and "new-api" -> job "unit" fails (a branch that only breaks on top of the new main)
  files "pair-a" and "pair-b"      -> job "unit" fails (two branches, each green alone, red together)
a PR head that conflicts with main gets no checks at all (like GitHub); `pr view` reports mergeable
$FAKE_GH/fail-view present          -> `pr view` fails (GitHub unreachable)
  file "flaky"                     -> the first run on a commit fails, a rerun (`gh run rerun --failed`) passes
  file "infra-flake" (content K, default 1) -> the first K runs fail with an infrastructure error in the run log (HTTP 503)
  file "infra-always"              -> every run fails with an infrastructure error in the run log
  file "slow"                      -> pending for $FAKE_SLOW queries (default 8), else $FAKE_PENDING (default 2)
Every CI start (a new head on an open PR, or a rerun) is appended to $FAKE_GH/triggers.log.
Every commit whose CI reached a verdict is appended once to $FAKE_GH/ci-runs.log ("<sha> pass|fail").

$FAKE_TURN_LABEL set (e.g. merge-turn) -> a label-gated workflow, modelled as workflow runs ($FAKE_GH/runs.json):
  a new head on an open PR starts a "sync" run; adding the label starts a "labeled" run on the current head.
  A run is full (heavy) only while the PR carries the label; otherwise it is cheap: it completes at once with
  conclusion success and the jobs "unit" and "publish" skipped (only "audit" runs). A full run is pending for
  $FAKE_PENDING polls, then completes like the classic CI above ("unit" fails on a red tree, "publish" then skipped).
  A labeled run stays invisible for its first $FAKE_LABEL_DELAY run listings (GitHub starting it late).
  Every full run start is appended to $FAKE_GH/full-runs.log ("<sha> <kind>"); every run to $FAKE_GH/runs.log.
  $FAKE_UNGATED also set -> the workflow before the gate: every sync run is full and labels start no run.
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
        if h:
            p["oid"] = h; p.setdefault("heads", [])
            if h not in p["heads"]:
                p["heads"].append(h); open(f"{ST}/triggers.log", "a").write(f"#{p['number']} {p['head']} {h}\n")
                if GATED: start_run(p, h, "sync")
        main = ref("main")
        if p.get("oid") and main and is_anc(p["oid"], main): p["state"] = "MERGED"
        save(p)
    return p

def conflicting(sha):
    main = ref("main")
    return bool(main and sha) and git("merge-tree", "--write-tree", main, sha, check=False).returncode != 0

def view(p):
    return {"mergeable": "CONFLICTING" if p["state"] == "OPEN" and conflicting(p.get("oid")) else "MERGEABLE","number": p["number"], "url": p["url"], "state": p["state"], "headRefOid": p.get("oid", ""),
            "headRefName": p["head"], "title": p["title"], "labels": [{"name": n} for n in p.get("labels", [])]}

GATED = os.environ.get("FAKE_TURN_LABEL", ""); UNGATED = bool(os.environ.get("FAKE_UNGATED"))
def runs(): return json.load(open(f"{ST}/runs.json")) if os.path.exists(f"{ST}/runs.json") else []
def save_runs(rs): json.dump(rs, open(f"{ST}/runs.json", "w"))
def start_run(p, sha, kind):
    rs = runs(); heavy = UNGATED or GATED in p.get("labels", [])
    delay = int(os.environ.get("FAKE_LABEL_DELAY", 0)) if kind == "labeled" else 0
    rs.append({"id": 1000 + len(rs), "sha": sha, "pr": p["number"], "kind": kind, "heavy": heavy, "n": 0, "hide": delay})
    save_runs(rs); open(f"{ST}/runs.log", "a").write(f"{sha} {kind} {'full' if heavy else 'cheap'}\n")
    if heavy: open(f"{ST}/full-runs.log", "a").write(f"{sha} {kind}\n")
def red(sha):
    files = set(git("ls-tree", "-r", "--name-only", sha).stdout.split())
    return "early-red" in files or {"needs-old-api", "new-api"} <= files or {"pair-a", "pair-b"} <= files
def run_state(r):
    """(status, conclusion, {job: conclusion}) of a run; advances a full run by one poll."""
    if not r["heavy"]: return "completed", "success", {"audit": "success", "unit": "skipped", "publish": "skipped"}
    r["n"] += 1; need = int(os.environ.get("FAKE_PENDING", 2))
    if r["n"] <= need: return "in_progress", None, {"audit": None, "unit": None, "publish": None}
    v = "fail" if red(r["sha"]) else "pass"
    if r["n"] == need + 1: open(f"{ST}/ci-runs.log", "a").write(f"{r['sha']} {v}\n")
    if v == "fail": return "completed", "failure", {"audit": "success", "unit": "failure", "publish": "skipped"}
    return "completed", "success", {"audit": "success", "unit": "success", "publish": "success"}
def visible(sha):
    """Runs on sha that GitHub shows now, with their states (one poll each)."""
    rs = runs(); outl = []
    for r in rs:
        if r["sha"] != sha: continue
        if r["hide"] > 0: r["hide"] -= 1; continue
        outl.append((r, *run_state(r)))
    save_runs(rs); return outl

def ci(sha):
    if not any(sha in p.get("heads", []) for p in allprs()): return None
    files = set(git("ls-tree", "-r", "--name-only", sha).stdout.split())
    red = "early-red" in files or {"needs-old-api", "new-api"} <= files or {"pair-a", "pair-b"} <= files
    need = int(os.environ.get("FAKE_SLOW", 8)) if "slow" in files else int(os.environ.get("FAKE_PENDING", 2))
    cf = f"{ST}/ci/{sha}"; c = json.load(open(cf)) if os.path.exists(cf) else {"n": 0, "runs": 1}
    if c["n"] == 0 and c["runs"] == 1 and conflicting(sha): return None   # no pull_request CI on a conflicting PR
    c["n"] += 1; json.dump(c, open(cf, "w"))
    if c["n"] <= need: return "pending"
    k = int(git("show", f"{sha}:infra-flake").stdout.strip() or 1) if "infra-flake" in files else 0
    v = "fail" if red or ("flaky" in files and c["runs"] == 1) or "infra-always" in files or c["runs"] <= k else "pass"
    if c["n"] == need + 1: open(f"{ST}/ci-runs.log", "a").write(f"{sha} {v}\n")
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
if a[0] == "api" and GATED and "/actions/runs?" in a[1]:
    from urllib.parse import parse_qs
    sha = parse_qs(a[1].split("?", 1)[1])["head_sha"][0]
    out({"workflow_runs": [{"id": r["id"], "head_sha": sha, "status": st, "conclusion": co} for r, st, co, _ in visible(sha)]}, a); sys.exit(0)
if a[0] == "api" and GATED and a[1].endswith("/jobs") or (a[0] == "api" and GATED and "/jobs?" in a[1]):
    rid = int(a[1].split("/actions/runs/")[1].split("/")[0]); r = next(x for x in runs() if x["id"] == rid)
    _, _, jobs = run_state(dict(r, n=10**6)) if r["heavy"] else run_state(r)   # read-only: the verdict, no poll
    out({"jobs": [{"name": k, "conclusion": v} for k, v in jobs.items()]}, a); sys.exit(0)
if a[0] == "api" and GATED:   # check runs: every job of every visible run (the classic ci-wait reads these)
    sha = a[1].split("/commits/")[1].split("/")[0]
    crs = [{"name": k, "status": st if v is None or st != "completed" else "completed", "conclusion": v} for _, st, _, jobs in visible(sha) for k, v in jobs.items()]
    out({"total_count": len(crs), "check_runs": crs}, a); sys.exit(0)
if a[0] == "api":
    sha = a[1].split("/commits/")[1].split("/")[0]; v = ci(sha)
    runs = [] if v is None else [{"name": "unit", "status": "in_progress" if v == "pending" else "completed"}]
    out({"total_count": len(runs), "check_runs": runs}, a); sys.exit(0)
if a[:2] == ["run", "list"]:
    sha = opt(a, "--commit"); v = ci(sha) if os.path.exists(f"{ST}/ci/{sha}") else None
    out([] if v is None else [{"databaseId": int(sha[:7], 16), "status": "in_progress" if v == "pending" else "completed",
          "conclusion": "failure" if v == "fail" else ("success" if v == "pass" else "")}], a); sys.exit(0)
if a[:2] == ["run", "view"] and "--log-failed" in a:
    for f in os.listdir(f"{ST}/ci"):
        if int(f[:7], 16) == int(a[2]):
            files = set(git("ls-tree", "-r", "--name-only", f).stdout.split())
            if files & {"infra-flake", "infra-always"}:
                print("unit\tSet up job\t2026-01-01T00:00:00Z curl: (22) The requested URL returned error: 503")
                print("unit\tSet up job\t2026-01-01T00:00:01Z ##[error]Process completed with exit code 22.")
            else:
                print("unit\tRun tests\t2026-01-01T00:00:00Z \x1b[31m FAIL \x1b[39m src/a.test.ts > b")
    sys.exit(0)
if a[:2] == ["run", "rerun"]:
    for f in os.listdir(f"{ST}/ci"):
        if int(f[:7], 16) == int(a[2]):
            c = json.load(open(f"{ST}/ci/{f}")); c["runs"] += 1; c["n"] = 0; json.dump(c, open(f"{ST}/ci/{f}", "w"))
            open(f"{ST}/triggers.log", "a").write(f"rerun {f}\n")
    sys.exit(0)
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
    p = load(num(a[2])); p["title"] = opt(a, "--title", p["title"]); labels = p.setdefault("labels", [])
    rm = opt(a, "--remove-label"); add = opt(a, "--add-label")
    if rm in labels: labels.remove(rm)
    save(p)
    if add and add not in labels:
        labels.append(add); save(p); open(f"{ST}/labels.log", "a").write(f"#{p['number']} labeled {add}\n")
        if GATED and not UNGATED and add == GATED and p["state"] == "OPEN": start_run(refresh(p), p["oid"], "labeled")
    if rm: open(f"{ST}/labels.log", "a").write(f"#{p['number']} unlabeled {rm}\n")
elif c == "view":
    if os.path.exists(f"{ST}/fail-view"): sys.exit("fake gh: HTTP 502")
    out(view(refresh(load(num(a[2])))), a)
elif c == "checks":
    p = refresh(load(num(a[2])))
    if GATED:   # latest run's conclusion per job name, like gh pr checks
        b = {}
        for _, st, _, jobs in visible(p["oid"]):
            for k, v in jobs.items(): b[k] = "pending" if v is None else {"success": "pass", "skipped": "skipping"}.get(v, "fail")
        out([{"name": k, "bucket": v} for k, v in b.items()], a); sys.exit(0)
    v = ci(p["oid"])
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
