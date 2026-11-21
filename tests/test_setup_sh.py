"""
L42 -- setup.sh says only what it checked (B6 + R6 of Sparta 0.1.14;
ruled 2026-11-21 02:10 CST).

    python3 tests/test_setup_sh.py [path/to/setup.sh]

With no argument it tests this repository's setup.sh. release.sh (in the
sparta repo) runs it on the PACKAGED setup.sh -- the exact file a customer
gets, after the version is substituted -- and refuses to package on a
failure. Standard library only; no Docker, no network.

What went wrong: the closing banner branched on "an .env exists" alone.
Every such run was told the console was upgraded, that the version line
was set, and that the relay was STILL RUNNING THE OLD VERSION -- a rerun
with nothing changed, a rerun before the wizard ("There is NO wizard to
complete"), and a rollback alike. Only the first prerequisite said it
passed (R6). And a rerun before the wizard made .env mode 600 while the
running console needed group write for the wizard's port range; nothing
restarted the console to give it back, and the wizard swallowed the
error (B6 (b)).

How: each case runs the real setup.sh in a temporary directory with a
PATH of its own -- the few system tools it uses, plus a fake `docker` and
`openssl` that answer as the case says and log every call. A call the
fake does not know fails the case. So the banner, .env's content and
mode, the exit status and the order of the calls are all the script's own.

Cases:
  F1 first install: "ready", the wizard steps, .env 600 with the version
  F2 first install, but the console's volumes say setup is complete (an
     .env deleted, or a new directory): STOP, exit 1, no backup advice
  F3 first install, the console cannot be asked: the first-install text
  E1 rerun before the wizard: the wizard steps, not "NO wizard"; .env's
     660 left alone (b); nothing claimed about a version change
  E1b the same with a relay already running: says it was started early
  E2 a version change with setup done: "Now on B (was A)", only the
     version line changed in .env, the relay on A named with the
     command, the agents paragraph; never "upgraded"
  E3 a rerun with nothing changed: "already", the relay is running B;
     no warning, no agents paragraph, no mode line, no claim of a change
  E4 relay absent / E5 stopped / E6 restarting / E7 the same tag pulled
     again since it started
  E8 the version line added
  E9 .env 644 and setup done: made 600, and the banner says it was 644
  E10 the console cannot be asked: says so, both paths, mode left alone
  R1 R6: Compose and openssl each say they passed; R1b Compose without
     --short falls back to the full line
  N1-N5 the refusals unchanged: no docker, no Compose, no openssl, a
     half-written .env, an unset version
  S1 one REPLACE_ME after the version substitution; S2 bash -n
  X  in every case: no call the fake does not know; setup.sh never
     starts, stops or restarts the relay

Run against sparta-deploy 4695594's setup.sh: see the commit message.
"""
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(HERE, "..", "setup.sh")
TEST_VERSION = "9.9.9"
OLD = "0.0.1"
TOOLS = ("bash", "sh", "dirname", "grep", "head", "cut", "sed", "chmod", "cat", "tr",
         "rm", "seq", "sleep", "stat")

PASSED = FAILED = 0


def check(label, cond, detail=""):
    global PASSED, FAILED
    if cond:
        PASSED += 1
        print(f"  PASS  {label}")
    else:
        FAILED += 1
        print(f"  FAIL  {label}" + (f"  -- {detail}" if detail else ""))


FAKE_DOCKER = r'''#!PYTHON
import json, os, sys
sc = json.load(open(os.environ["L42_SCENARIO"]))
a = sys.argv[1:]
with open(os.environ["L42_CALLS"], "a") as f:
    f.write(json.dumps(a) + "\n")
def out(t, rc=0):
    if t: print(t)
    sys.exit(rc)
def err(t, rc=1):
    print(t, file=sys.stderr); sys.exit(rc)
if a == ["--version"]:
    out("Docker version 29.1.3, build l42")
if a == ["compose", "version", "--short"]:
    if sc.get("compose") is False: err("docker: 'compose' is not a docker command.")
    if sc.get("no_short"): err("unknown flag: --short")
    out("2.40.3")
if a == ["compose", "version"]:
    if sc.get("compose") is False: err("docker: 'compose' is not a docker command.")
    out("Docker Compose version v2.40.3")
if a == ["compose", "--profile", "relay", "pull"]:
    out("", sc.get("pull_rc", 0))
if a == ["compose", "up", "-d", "console", "nginx"]:
    out("")
if a == ["inspect", "--format", "{{.State.Health.Status}}", "sparta-console"]:
    out("healthy")
if a[:2] == ["exec", "sparta-console"] and a[2:4] == ["sh", "-c"] and \
        a[4] == "grep -qx SETUP_COMPLETE=true /var/sparta/env/.env && echo complete || echo not-complete":
    s = sc["setup"]
    if s == "fail": err("Error response from daemon: container is restarting")
    out(s)
if a == ["inspect", "--format", "{{.State.Status}} {{.Image}} {{.Config.Image}}", "sparta-relay"]:
    r = sc.get("relay")
    if r is None: err("Error: No such object: sparta-relay")
    out(" ".join(r))
if a[:3] == ["image", "inspect", "--format"] and a[3] == "{{.Id}}" and len(a) == 5:
    i = sc.get("tag_ids", {}).get(a[4])
    if i is None: err(f"Error: No such image: {a[4]}")
    out(i)
with open(os.environ["L42_CALLS"], "a") as f:
    f.write("UNEXPECTED\n")
err("l42 fake docker: unexpected call " + " ".join(a), 99)
'''

FAKE_OPENSSL = r'''#!PYTHON
import sys
a = sys.argv[1:]
if a == ["version"]:
    print("OpenSSL 3.5.5 27 Jan 2026 (l42)"); sys.exit(0)
if a == ["rand", "-base64", "32"]:
    print("bDQyLWEtcmFuZG9tLWtleS10aGF0LWlzLTMyLWJ5dGVz"); sys.exit(0)
if a == ["rand", "-hex", "32"]:
    print("6c3432" * 10 + "6c34"); sys.exit(0)
print("l42 fake openssl: unexpected call " + " ".join(a), file=sys.stderr); sys.exit(99)
'''


def prepared(path):
    """The file under test with a real version in it, as release.sh does."""
    s = open(path, encoding="utf-8").read()
    m = re.search(r'^SPARTA_VERSION_DEFAULT="([^"]*)"$', s, re.M)
    assert m, "no SPARTA_VERSION_DEFAULT line"
    if m.group(1) == "REPLACE_ME":
        s = s.replace('SPARTA_VERSION_DEFAULT="REPLACE_ME"', f'SPARTA_VERSION_DEFAULT="{TEST_VERSION}"', 1)
        version = TEST_VERSION
    else:
        version = m.group(1)
    return s, version


SRC, V = prepared(SCRIPT)


def env_text(version=None, extra="", key="bDQyLWV4aXN0aW5nLWtleS10aGF0LWlzLTMyLWJ5dGVzIQ"):
    lines = ["# Sparta host environment", "# Generated by setup.sh"]
    if version is not None:
        lines.append(f"SPARTA_VERSION={version}")
    lines += ["PORT_RANGE_START=15000", "PORT_RANGE_END=15200",
              f"DB_ENCRYPTION_KEY={key}", "CONSOLE_SECRET_KEY=" + "ab" * 32]
    return "\n".join(lines) + "\n" + extra


def run(name, scenario, env=None, mode=None, docker=True, openssl=True, src=None):
    d = tempfile.mkdtemp(prefix=f"l42-{name}-")
    try:
        bindir = os.path.join(d, "bin")
        work = os.path.join(d, "install")
        os.makedirs(bindir)
        os.makedirs(work)
        for t in TOOLS:
            p = shutil.which(t)
            assert p, f"{t} not found on this host"
            os.symlink(p, os.path.join(bindir, t))
        for fname, body, want in (("docker", FAKE_DOCKER, docker), ("openssl", FAKE_OPENSSL, openssl)):
            if want:
                p = os.path.join(bindir, fname)
                open(p, "w").write(body.replace("#!PYTHON", "#!" + sys.executable, 1))
                os.chmod(p, 0o755)
        sc = os.path.join(d, "scenario.json")
        json.dump(scenario, open(sc, "w"))
        calls = os.path.join(d, "calls.log")
        open(calls, "w").close()
        script = os.path.join(work, "setup.sh")
        open(script, "w", encoding="utf-8").write(src if src is not None else SRC)
        os.chmod(script, 0o755)
        envp = os.path.join(work, ".env")
        if env is not None:
            open(envp, "w").write(env)
            os.chmod(envp, mode)
        r = subprocess.run(["./setup.sh"], cwd=work, capture_output=True, text=True, timeout=120,
                           env={"PATH": bindir, "L42_SCENARIO": sc, "L42_CALLS": calls,
                                "HOME": d, "LANG": "C.UTF-8"})
        res = {
            "rc": r.returncode,
            "out": r.stdout + r.stderr,
            "env": open(envp).read() if os.path.exists(envp) else None,
            "mode": stat.S_IMODE(os.stat(envp).st_mode) if os.path.exists(envp) else None,
            "calls": [l.rstrip("\n") for l in open(calls)],
        }
        return res
    finally:
        shutil.rmtree(d, ignore_errors=True)


def calls_ok(name, res):
    unexpected = [c for c in res["calls"] if c == "UNEXPECTED"]
    relay_moved = [c for c in res["calls"] if c.startswith("[") and "relay" in json.loads(c)
                   and any(w in json.loads(c) for w in ("up", "restart", "stop", "start", "down"))]
    check(f"{name} X no unknown docker call; the relay never started, stopped or restarted",
          not unexpected and not relay_moved, f"unexpected={len(unexpected)} relay={relay_moved}")


def has(res, *texts):
    return all(t in res["out"] for t in texts)


def hasnt(res, *texts):
    return not any(t in res["out"] for t in texts)


CLAIMS = ("upgraded", "STILL RUNNING THE OLD VERSION", "set the version line")
RELAY_CUR = ["running", "sha256:aaa", f"spartahq/sparta:relay-{V}"]
TAGS_CUR = {f"spartahq/sparta:relay-{V}": "sha256:aaa"}


def main():
    print(f"\nL42 -- setup.sh says only what it checked ({SCRIPT}, version {V})")

    print("\nS -- the file")
    check("S1 exactly one REPLACE_ME once the version is substituted (the .env guard)",
          SRC.count("REPLACE_ME") == 1, f"{SRC.count('REPLACE_ME')}")
    n = subprocess.run(["bash", "-n", SCRIPT], capture_output=True, text=True)
    check("S2 bash -n", n.returncode == 0, n.stderr[:200])

    print("\nF -- first install (no .env)")
    r = run("F1", {"setup": "not-complete", "relay": None})
    check("F1 exit 0, 'ready', the wizard steps, no 'NO wizard'",
          r["rc"] == 0 and has(r, "Sparta Console is ready!", "complete the setup wizard",
                               "docker compose --profile relay up -d relay",
                               "docker compose restart console")
          and hasnt(r, "NO wizard", *CLAIMS), r["out"][-600:])
    check("F1 .env created 600 with this version and generated secrets",
          r["mode"] == 0o600 and f"SPARTA_VERSION={V}\n" in (r["env"] or "")
          and "__DBKEY__" not in (r["env"] or "") and "__SECRETKEY__" not in (r["env"] or ""),
          f"mode={r['mode'] and oct(r['mode'])}")
    check("F1 the backup advice is given", has(r, "BACK UP .env NOW"))
    calls_ok("F1", r)

    r = run("F2", {"setup": "complete", "relay": RELAY_CUR, "tag_ids": TAGS_CUR})
    check("F2 the volumes say set up before: STOP, exit 1",
          r["rc"] == 1 and has(r, "STOP — this console was set up before", "NEW encryption key",
                               "run ./setup.sh again", "docker compose logs console")
          and hasnt(r, "Sparta Console is ready!", "complete the setup wizard"), r["out"][-600:])
    check("F2 no backup advice (it would copy the useless key over the good backup)",
          hasnt(r, "BACK UP .env NOW", "cp ") and has(r, "Do NOT back up this .env"))
    calls_ok("F2", r)

    r = run("F3", {"setup": "fail", "relay": None})
    check("F3 first install, the console cannot be asked: the first-install text",
          r["rc"] == 0 and has(r, "Sparta Console is ready!", "complete the setup wizard")
          and hasnt(r, "STOP", *CLAIMS), r["out"][-400:])
    calls_ok("F3", r)

    print("\nE -- an .env was there")
    r = run("E1", {"setup": "not-complete", "relay": None}, env=env_text(V), mode=0o660)
    check("E1 rerun before the wizard: the wizard steps, not 'NO wizard'",
          r["rc"] == 0 and has(r, "setup not done", "complete the setup wizard",
                               "docker compose --profile relay up -d relay")
          and hasnt(r, "NO wizard", "Sparta Console is ready!", *CLAIMS), r["out"][-600:])
    check("E1 .env's 660 left alone (b) -- the console's group still writes it",
          r["mode"] == 0o660, f"mode={r['mode'] and oct(r['mode'])}")
    check("E1 no version change claimed; no early-relay note",
          has(r, f"The version in .env was already") and hasnt(r, "Now on", "already running: it was started"))
    calls_ok("E1", r)

    r = run("E1b", {"setup": "not-complete", "relay": ["running", "sha256:bbb", f"spartahq/sparta:relay-{V}"],
                    "tag_ids": {f"spartahq/sparta:relay-{V}": "sha256:bbb"}}, env=env_text(V), mode=0o660)
    check("E1b a relay started before the wizard: said, with what to run after it",
          r["rc"] == 0 and has(r, "The relay is already running: it was started before",
                               "recreates it with the ports you choose"), r["out"][-500:])
    calls_ok("E1b", r)

    before = env_text(OLD)
    r = run("E2", {"setup": "complete", "relay": ["running", "sha256:old", f"spartahq/sparta:relay-{OLD}"],
                   "tag_ids": {f"spartahq/sparta:relay-{OLD}": "sha256:old"}}, env=before, mode=0o600)
    check("E2 a version change: 'Now on B (was A)', 'NO wizard', never 'upgraded'",
          r["rc"] == 0 and has(r, "Sparta Console is running", f"Now on {V} (was {OLD})", "NO wizard")
          and hasnt(r, *CLAIMS), r["out"][-800:])
    check("E2 only the version line changed in .env",
          r["env"] == before.replace(f"SPARTA_VERSION={OLD}", f"SPARTA_VERSION={V}"), "")
    check("E2 the relay on the old release named, with the command",
          has(r, f"The relay is still running relay-{OLD}.", "Bring it up on",
              "docker compose --profile relay up -d relay"), r["out"][-600:])
    check("E2 the agents paragraph", has(r, "Agent hosts are not changed by this script", "--upgrade"))
    check("E2 no mode line (already 600)", hasnt(r, "Made .env mode 600"))
    calls_ok("E2", r)

    r = run("E3", {"setup": "complete", "relay": RELAY_CUR, "tag_ids": TAGS_CUR}, env=env_text(V), mode=0o600)
    check("E3 nothing changed: 'already', the relay running B",
          r["rc"] == 0 and has(r, f"On {V}. The version in .env was already",
                               f"✓ The relay is running {V}.", "If you extracted a new release before this run",
                               "is still the old setup.sh", "Check the extraction actually happened")
          and hasnt(r, *CLAIMS), r["out"][-800:])
    check("E3 no warning, no agents paragraph, no mode line, no 'Now on'",
          hasnt(r, "⚠  The relay", "Agent hosts are not changed", "Made .env mode", "Now on"),
          r["out"][-800:])
    check("E3 .env byte for byte, 600", r["env"] == env_text(V) and r["mode"] == 0o600)
    calls_ok("E3", r)

    for name, relay, want in (
            ("E4", None, "The relay is not running. Start it:"),
            ("E5", ["exited", "sha256:aaa", f"spartahq/sparta:relay-{V}"], "The relay is not running. Start it:"),
            ("E6", ["restarting", "sha256:aaa", f"spartahq/sparta:relay-{V}"], "restarting over and over"),
            ("E7", ["running", "sha256:old", f"spartahq/sparta:relay-{V}"],
             f"The relay is still running an earlier pull of relay-{V}.")):
        r = run(name, {"setup": "complete", "relay": relay, "tag_ids": TAGS_CUR}, env=env_text(V), mode=0o600)
        check(f"{name} relay {relay[0] if relay else 'absent'}{' (tag pulled again)' if name == 'E7' else ''}: says so",
              r["rc"] == 0 and has(r, want) and hasnt(r, "✓ The relay is running", *CLAIMS), r["out"][-500:])
        calls_ok(name, r)

    r = run("E8", {"setup": "complete", "relay": RELAY_CUR, "tag_ids": TAGS_CUR}, env=env_text(None), mode=0o600)
    check("E8 the version line added: said, in .env, the agents paragraph",
          r["rc"] == 0 and has(r, f"Now on {V}: this run added the version line",
                               "Agent hosts are not changed by this script")
          and f"SPARTA_VERSION={V}\n" in (r["env"] or ""), r["out"][-600:])
    calls_ok("E8", r)

    r = run("E9", {"setup": "complete", "relay": RELAY_CUR, "tag_ids": TAGS_CUR}, env=env_text(V), mode=0o644)
    check("E9 .env 644 and setup done: made 600, and the banner says it was 644",
          r["mode"] == 0o600 and has(r, "Made .env mode 600 (owner only); it was 644."),
          f"mode={r['mode'] and oct(r['mode'])} {r['out'][-400:]}")
    calls_ok("E9", r)

    r = run("E10", {"setup": "fail", "relay": None}, env=env_text(V), mode=0o660)
    check("E10 the console cannot be asked: said; both paths given; mode left alone",
          r["rc"] == 0 and has(r, "Could not ask the console whether its setup",
                               "If you have NOT completed the setup wizard", "If you HAVE completed it",
                               "The relay is not running")
          and hasnt(r, "NO wizard to complete", *CLAIMS) and r["mode"] == 0o660,
          f"mode={r['mode'] and oct(r['mode'])} {r['out'][-500:]}")
    calls_ok("E10", r)

    print("\nR -- every prerequisite says it passed (R6)")
    r = run("R1", {"setup": "not-complete", "relay": None})
    check("R1 Docker, Compose and openssl each say so",
          has(r, "✓ Docker detected: Docker version 29.1.3", "✓ Docker Compose detected: 2.40.3",
              "✓ openssl detected: OpenSSL 3.5.5"), r["out"][:500])
    r = run("R1b", {"setup": "not-complete", "relay": None, "no_short": True})
    check("R1b Compose without --short: the full line",
          r["rc"] == 0 and has(r, "✓ Docker Compose detected: Docker Compose version v2.40.3"), r["out"][:500])

    print("\nN -- the refusals are unchanged")
    r = run("N1", {"setup": "not-complete"}, docker=False)
    check("N1 no docker: refused, exit 1", r["rc"] == 1 and has(r, "ERROR: Docker is not installed."), r["out"][-300:])
    r = run("N2", {"setup": "not-complete", "compose": False})
    check("N2 no Compose v2: refused, exit 1",
          r["rc"] == 1 and has(r, "ERROR: Docker Compose v2 is not installed."), r["out"][-300:])
    r = run("N3", {"setup": "not-complete"}, openssl=False)
    check("N3 no openssl: refused, exit 1", r["rc"] == 1 and has(r, "ERROR: openssl is not installed."),
          r["out"][-300:])
    r = run("N4", {"setup": "complete"}, env=env_text(V, key=""), mode=0o600)
    check("N4 a half-written .env: refused, exit 1, before any pull",
          r["rc"] == 1 and has(r, "ERROR: .env exists but is incomplete.")
          and not any("pull" in c for c in r["calls"]), r["out"][-300:])
    unset = SRC.replace(f'SPARTA_VERSION_DEFAULT="{V}"', 'SPARTA_VERSION_DEFAULT="REPLACE_ME"', 1)
    r = run("N5", {"setup": "not-complete"}, src=unset)
    check("N5 an unset version: refused, exit 1, before any pull",
          r["rc"] == 1 and has(r, "SPARTA_VERSION is not set to a real release tag")
          and not any("pull" in c for c in r["calls"]), r["out"][-300:])

    print(f"\nL42: {PASSED} passed, {FAILED} failed")
    return FAILED


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
