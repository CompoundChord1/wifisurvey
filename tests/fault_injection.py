#!/usr/bin/env python3
"""Fault-injection suite: does the app measure a *bad* link correctly?

Runs the app's debug self-test in an iOS Simulator against a local helper started with
--allow-impair, injects a fault, and compares what the app reported with what was injected.

    python3 tests/fault_injection.py --udid <simulator udid> --app <path/to/WiFiSurvey.app>
                                     [--only name,name] [--out DIR]

Scenarios: baseline, random loss (both directions), delay+jitter, a 6 s stall, UDP port closed
(ICMP unreachable), helper restart mid-leg, helper down for a whole leg, helper never started,
periodic loss bursts, a stall during the download test.
"""
import argparse
import builtins
import csv
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def print(*a, **k):   # progress must be visible when piped through tee
    k.setdefault("flush", True)
    builtins.print(*a, **k)
BUNDLE = "com.example.WiFiSurvey"
HTTP = "http://127.0.0.1:9751"
SETTLE = 3.0   # the app settles this long after the leg's "start" mark before measuring


class Ctx:
    def __init__(self, args):
        self.udid = args.udid
        self.app = args.app
        self.out = args.out
        self.base = tempfile.mkdtemp(prefix="wifisurvey-fi-")
        self.helper = None
        self.container = None
        self.t_launch = 0.0

    # ---- helper process
    def start_helper(self):
        self.helper = subprocess.Popen(
            [sys.executable, os.path.join(ROOT, "server", "wifisurvey_helper.py"), "--bind", "127.0.0.1",
             "--base", self.base, "--allow-impair", "--no-omada"],
            stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
        for _ in range(50):
            try:
                http("GET", "/health", timeout=1)
                return
            except OSError:
                time.sleep(0.1)
        raise SystemExit("helper did not start")

    def stop_helper(self):
        if self.helper and self.helper.poll() is None:
            self.helper.send_signal(signal.SIGTERM)
            try:
                self.helper.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.helper.kill()
        self.helper = None

    # ---- simulator
    def simctl(self, *a, check=True):
        return subprocess.run(["xcrun", "simctl", *a], capture_output=True, text=True, check=check).stdout.strip()

    def prepare_sim(self):
        if "Booted" not in self.simctl("list", "devices", self.udid):
            self.simctl("boot", self.udid, check=False)
            self.simctl("bootstatus", self.udid, "-b")
        self.simctl("install", self.udid, self.app)
        self.simctl("privacy", self.udid, "grant", "location", BUNDLE, check=False)
        self.container = self.simctl("get_app_container", self.udid, BUNDLE, "data")

    def launch(self, label, legs):
        self.simctl("terminate", self.udid, BUNDLE, check=False)
        for f in ("selftest-result-%s.json" % label, "selftest-export-%s.zip" % label):
            try:
                os.remove(os.path.join(self.container, "Documents", f))
            except OSError:
                pass
        self.t_launch = time.time()     # marks older than this belong to an earlier scenario
        self.simctl("launch", self.udid, BUNDLE, "-selftest", "127.0.0.1", "-legs", legs, "-noshortcut",
                    "-label", label)

    def wait_result(self, label, timeout):
        path = os.path.join(self.container, "Documents", "selftest-result-%s.json" % label)
        end = time.time() + timeout
        while time.time() < end:
            if os.path.exists(path):
                time.sleep(0.3)
                with open(path) as f:
                    return json.load(f)
            time.sleep(0.5)
        return None

    def export_path(self, label):
        return os.path.join(self.container, "Documents", "selftest-export-%s.zip" % label)


def http(method, path, body=None, timeout=5):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(HTTP + path, data=data, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def impair(**kw):
    return http("POST", "/impair", kw)


def wait_mark(ctx, event, nth=1, timeout=420):
    """Block until the helper has seen the nth mark of this kind since the app was launched;
    returns its server time (s). The timeout is generous: a freshly booted simulator can take
    minutes to launch an app."""
    end = time.time() + timeout
    while time.time() < end:
        try:
            marks = [m for m in http("GET", "/debug/marks", timeout=2)["marks"]
                     if m.get("event") == event and m["ts"] / 1000.0 >= ctx.t_launch]
            if len(marks) >= nth:
                return marks[nth - 1]["ts"] / 1000.0
        except OSError:
            pass
        time.sleep(0.2)
    raise TimeoutError("no %s mark #%d" % (event, nth))


def sleep_until(t):
    d = t - time.time()
    if d > 0:
        time.sleep(d)


class Checks:
    def __init__(self, name):
        self.name = name
        self.rows = []

    def ok(self, cond, text):
        self.rows.append((bool(cond), text))
        print("    %s %s" % ("ok  " if cond else "FAIL", text))

    @property
    def failed(self):
        return [t for c, t in self.rows if not c]


def leg(result, i):
    legs = (result or {}).get("legs") or []
    return legs[i] if i < len(legs) else {}


def between(v, lo, hi):
    return isinstance(v, (int, float)) and lo <= v <= hi


def analyze(ctx, label, outdir):
    zp = ctx.export_path(label)
    if not os.path.exists(zp):
        return []
    dest = os.path.join(outdir, label)
    os.makedirs(dest, exist_ok=True)
    shutil.copy(zp, os.path.join(dest, "export.zip"))
    subprocess.run([sys.executable, os.path.join(ROOT, "analysis", "analyze.py"), zp, "--out", dest],
                   capture_output=True, text=True)
    try:
        with open(os.path.join(dest, "legs.csv")) as f:
            return list(csv.DictReader(f))
    except OSError:
        return []


def fnum(row, key):
    try:
        return float(row.get(key, ""))
    except (TypeError, ValueError):
        return None


# ------------------------------------------------------------------------------- scenarios
def s_baseline(ctx, c, label):
    ctx.launch(label, "2G:25,5G:20")
    r = ctx.wait_result(label, 150)
    c.ok(r and r.get("measurementStatus") == "complete", "measurement completes")
    for i in (0, 1):
        l = leg(r, i)
        c.ok(l.get("lossPct") == 0 and l.get("grade") in ("green", "yellow"),
             "leg %d: 0%% loss, not red (p95 %s ms)" % (i + 1, l.get("rttP95")))
        c.ok(l.get("hbFailed") == 0 and not l.get("reconnects"), "leg %d: no stalls, no socket reconnects" % (i + 1))
    return r


def s_random_loss(ctx, c, label):
    impair(upLoss=0.05, downLoss=0.02)
    ctx.launch(label, "2G:40")
    r = ctx.wait_result(label, 150)
    l = leg(r, 0)
    c.ok(between(l.get("upLossPct"), 2.8, 7.6), "phone→AP loss ≈ 5%% injected, app says %s%%" % l.get("upLossPct"))
    c.ok(between(l.get("downLossPct"), 0.7, 3.8), "AP→phone loss ≈ 2%% injected, app says %s%%" % l.get("downLossPct"))
    c.ok(l.get("grade") == "red", "graded red")
    return r


def s_delay(ctx, c, label):
    impair(delayMs=80, jitterMs=30)
    ctx.launch(label, "2G:25")
    r = ctx.wait_result(label, 150)
    l = leg(r, 0)
    c.ok(between(l.get("rttP50"), 65, 100), "latency p50 ≈ 80 ms injected, app says %s ms" % l.get("rttP50"))
    c.ok(between(l.get("jitterMs"), 8, 40), "jitter seen (%s ms)" % l.get("jitterMs"))
    c.ok(between(l.get("lossPct"), 0, 0.5), "no loss invented (%s%%)" % l.get("lossPct"))
    return r


def s_stall(ctx, c, label):
    ctx.launch(label, "2G:25,5G:20")
    t = wait_mark(ctx, "start", 1)
    sleep_until(t + SETTLE + 7)
    impair(stallSec=6)
    r = ctx.wait_result(label, 180)
    l1, l2 = leg(r, 0), leg(r, 1)
    c.ok(between(l1.get("maxLossBurst"), 110, 190), "6 s stall → burst of ~150 probes, app says %s" % l1.get("maxLossBurst"))
    c.ok(between(l1.get("lossPct"), 17, 31), "leg loss ≈ 24%% (6 of 25 s), app says %s%%" % l1.get("lossPct"))
    c.ok((l1.get("hbFailed") or 0) >= 2, "heartbeat stalls counted (%s)" % l1.get("hbFailed"))
    c.ok(l1.get("grade") == "red", "graded red")
    c.ok(l2.get("lossPct") == 0 and l2.get("status") == "complete", "next leg is clean again (recovered)")
    return r


def s_udp_closed(ctx, c, label):
    ctx.launch(label, "2G:25,5G:20")
    t = wait_mark(ctx, "start", 1)
    sleep_until(t + SETTLE + 7)
    impair(closeUdpSec=5)
    r = ctx.wait_result(label, 180)
    l1, l2 = leg(r, 0), leg(r, 1)
    c.ok(between(l1.get("lossPct"), 13, 29),
         "port closed 5 of 25 s → ≈20%% loss, then echoes must resume; app says %s%%" % l1.get("lossPct"))
    c.ok(between(l1.get("maxLossBurst"), 90, 175), "one burst of ~125 probes, app says %s" % l1.get("maxLossBurst"))
    c.ok(l2.get("lossPct") == 0, "next leg clean (%s%%)" % l2.get("lossPct"))
    return r


def s_helper_restart(ctx, c, label):
    ctx.launch(label, "2G:25,5G:20")
    t = wait_mark(ctx, "start", 1)
    sleep_until(t + SETTLE + 7)
    ctx.stop_helper()
    time.sleep(4)
    ctx.start_helper()
    r = ctx.wait_result(label, 180)
    l1, l2 = leg(r, 0), leg(r, 1)
    c.ok(l1.get("status") == "complete", "leg survives a helper restart (%s)" % l1.get("status"))
    c.ok(between(l1.get("lossPct"), 10, 32), "≈4–5 s outage of 25 s → 16–20%% loss, app says %s%%" % l1.get("lossPct"))
    c.ok(l2.get("lossPct") == 0 and l2.get("status") == "complete", "next leg clean (%s%%)" % l2.get("lossPct"))
    return r


def s_helper_down(ctx, c, label):
    """The server dies in the middle of leg 2 and stays down: leg 2 shows the outage from that point,
    leg 3 starts with it unreachable and must still be measured (that outage is the finding)."""
    ctx.launch(label, "2G:20,5G:20,DUAL:20")
    t = wait_mark(ctx, "start", 2)
    sleep_until(t + SETTLE + 8)
    ctx.stop_helper()
    r = ctx.wait_result(label, 260)
    ctx.start_helper()
    l1, l2, l3 = leg(r, 0), leg(r, 1), leg(r, 2)
    c.ok(l1.get("lossPct") == 0, "leg 1 clean before the outage")
    c.ok(l2.get("status") == "complete" and between(l2.get("lossPct"), 45, 72),
         "leg 2: server died 8 s into 20 s → ≈60%% loss, app says %s%%" % l2.get("lossPct"))
    c.ok(l3.get("status") == "complete", "leg 3 is still measured with the server unreachable (%s)" % l3.get("status"))
    c.ok((l3.get("lossPct") or 0) >= 99 and l3.get("grade") == "red", "leg 3 shows total loss, red (%s%%)" % l3.get("lossPct"))
    c.ok(any("unreachable" in e for e in l3.get("errors") or []), "leg 3 says the server was unreachable at its start")
    c.ok((l3.get("reconnects") or 0) >= 3, "probe socket kept being rebuilt during the blackout (%s)" % l3.get("reconnects"))
    c.ok(between(l3.get("wallSeconds"), 25, 75), "leg 3 finished in bounded time (%s s)" % l3.get("wallSeconds"))
    return r


def s_helper_never_up(ctx, c, label):
    """The helper was never started: stop quickly with a clear error — don't record fake 100 % loss."""
    ctx.stop_helper()
    ctx.launch(label, "2G:20,5G:20")
    r = ctx.wait_result(label, 200)
    ctx.start_helper()
    for i in (0, 1):
        l = leg(r, i)
        c.ok(l.get("status") == "failed" and (l.get("udpSent") or 0) == 0,
             "leg %d not measured (%s, %s probes)" % (i + 1, l.get("status"), l.get("udpSent")))
        c.ok(any("Is it running" in e for e in l.get("errors") or []), "leg %d explains the helper isn't reachable" % (i + 1))
        c.ok(between(l.get("wallSeconds"), 5, 20), "leg %d gave up after ~10 s (%s s)" % (i + 1, l.get("wallSeconds")))
    return r


def s_periodic(ctx, c, label):
    impair(burstEverySec=8, burstLenSec=1)
    ctx.launch(label, "2G:45")
    r = ctx.wait_result(label, 180)
    l = leg(r, 0)
    c.ok((l.get("lossBursts3plus") or 0) >= 4, "bursts counted (%s)" % l.get("lossBursts3plus"))
    c.ok(between(l.get("lossPct"), 8, 17), "1 s of every 8 s lost → ≈12.5%%, app says %s%%" % l.get("lossPct"))
    return r


def s_stall_in_download(ctx, c, label):
    ctx.launch(label, "2G:30")
    t = wait_mark(ctx, "start", 1)
    sleep_until(t + SETTLE + 16)       # the download test runs 15–20 s into the leg
    impair(stallSec=6)
    r = ctx.wait_result(label, 200)
    l = leg(r, 0)
    c.ok(l.get("status") == "complete", "leg completes (%s)" % l.get("status"))
    c.ok(between(l.get("wallSeconds"), 30, 75), "no hang: leg took %s s for a 30 s plan" % l.get("wallSeconds"))
    c.ok(l.get("downMbps") is not None or l.get("downError"), "download reports a number or an error")
    c.ok((l.get("hbFailed") or 0) >= 2, "stall seen by the heartbeat (%s)" % l.get("hbFailed"))
    return r


SCENARIOS = [
    ("baseline", s_baseline), ("random_loss", s_random_loss), ("delay_jitter", s_delay), ("stall_6s", s_stall),
    ("udp_port_closed", s_udp_closed), ("helper_restart", s_helper_restart),
    ("helper_down", s_helper_down), ("helper_never_up", s_helper_never_up),
    ("periodic_bursts", s_periodic),
    ("stall_in_download", s_stall_in_download),
]


def analyzer_checks(c, name, rows):
    """The desktop analyzer must reach the same conclusions from the export."""
    if not rows:
        c.ok(False, "analyzer read the export")
        return
    first = rows[0]
    if name == "random_loss":
        c.ok(between(fnum(first, "upLossPct"), 2.8, 7.6) and first.get("lossDirectionSource") == "server",
             "analyzer: phone→AP loss %s%% from server log" % first.get("upLossPct"))
        c.ok("loss-mostly-phone→AP" in first.get("flags", ""), "analyzer flags loss-mostly-phone→AP")
    elif name == "stall_6s":
        c.ok(between(fnum(first, "maxGapMs"), 4500, 7500), "analyzer: longest gap %s ms" % first.get("maxGapMs"))
        c.ok((fnum(first, "stallEvents") or 0) >= 1, "analyzer counts a stall event")
    elif name == "periodic_bursts":
        c.ok(between(fnum(first, "periodicLossSec"), 7.5, 8.5),
             "analyzer finds the 8 s period (%s)" % first.get("periodicLossSec"))
        c.ok("periodic-loss" in first.get("flags", ""), "analyzer flags periodic loss")
    elif name == "delay_jitter":
        c.ok(between(fnum(first, "rttP50"), 65, 100), "analyzer: p50 %s ms" % first.get("rttP50"))
    elif name == "helper_down":
        last = rows[-1]
        flags = last.get("flags", "")
        c.ok("server-path-lost-gateway-ok" in flags and "server-unreachable-at-start" in flags,
             "analyzer: server path lost while the gateway still answered (not a Wi-Fi fault)")
        c.ok("worse-than-2G" not in flags and "DUAL-" not in flags,
             "analyzer doesn't blame the radio band for a server outage")
    elif name == "helper_restart":
        c.ok(first.get("lossDirectionSource") == "server", "analyzer merges arrivals across helper runs")
        c.ok(between(fnum(first, "upLossPct"), 10, 32), "analyzer: outage counted as phone→server loss (%s%%)"
             % first.get("upLossPct"))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--udid", required=True)
    ap.add_argument("--app", required=True, help="Debug-iphonesimulator/WiFiSurvey.app")
    ap.add_argument("--only", default="")
    ap.add_argument("--out", default=os.path.join(ROOT, "analysis-out", "fault-injection"))
    args = ap.parse_args()
    only = [x for x in args.only.split(",") if x]
    ctx = Ctx(args)
    os.makedirs(args.out, exist_ok=True)
    summary = []
    try:
        ctx.prepare_sim()
        ctx.start_helper()
        for name, fn in SCENARIOS:
            if only and name not in only:
                continue
            print("\n== %s" % name)
            c = Checks(name)
            try:
                if ctx.helper is None or ctx.helper.poll() is not None:
                    ctx.start_helper()
                impair(reset=True)
                result = fn(ctx, c, name)
                if ctx.helper is None or ctx.helper.poll() is not None:
                    ctx.start_helper()
                impair(reset=True)
                with open(os.path.join(args.out, "%s.json" % name), "w") as f:
                    json.dump(result, f, indent=1)
                analyzer_checks(c, name, analyze(ctx, name, args.out))
            except Exception as e:  # keep going; report it
                c.ok(False, "scenario crashed: %r" % e)
            summary.append(c)
    finally:
        ctx.stop_helper()
        ctx.simctl("terminate", ctx.udid, BUNDLE, check=False)
        shutil.rmtree(ctx.base, ignore_errors=True)
    print("\n================ summary")
    bad = 0
    for c in summary:
        n_fail = len(c.failed)
        bad += n_fail
        print("%-20s %s  (%d checks%s)" % (c.name, "PASS" if not n_fail else "FAIL", len(c.rows),
                                           "" if not n_fail else ", %d failed" % n_fail))
        for t in c.failed:
            print("      - " + t)
    print("\n%s" % ("ALL PASS" if not bad else "%d checks failed" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
