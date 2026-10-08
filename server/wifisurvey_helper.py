#!/usr/bin/env python3
"""WiFi Survey helper — runs on the server while a survey is in progress.

  UDP 9750  echo for loss/latency; logs every arrival so loss splits into phone→AP vs AP→phone
  TCP 9752  throughput: "DOWN <sec> <leg>" streams to the phone, "UP <sec> <leg>" receives
  HTTP 9751 /health /status /mark /arrivals /snapshot /export /survey-upload
            (+ /impair and /debug/marks only with --allow-impair, for fault-injection tests)
  Omada     read-only Viewer session on localhost; logs the phone's AP-side record,
            AP radio stats, controller events, and redacted config snapshots

Python 3.9+ stdlib only. Data lands in <base>/runs/<runId>/ as JSONL (docs/SCHEMA.md).
"""
import argparse
import glob
import io
import json
import os
import random
import re
import signal
import socket
import socketserver
import stat
import struct
import sys
import threading
import time
import zipfile
from collections import Counter, deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import omada

VERSION = "1.0"
IDLE_TARGET_SECONDS = 1800  # stop polling the phone's client record 30 min after its last mark


def now_ms():
    return time.time() * 1000.0


def log(msg):
    print("%s %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


class JsonlWriter:
    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.buf = []

    def write(self, obj):
        line = json.dumps(obj, separators=(",", ":"))
        with self.lock:
            self.buf.append(line)
            if len(self.buf) >= 500:
                self._flush()

    def _flush(self):
        if self.buf:
            with open(self.path, "a") as f:
                f.write("\n".join(self.buf) + "\n")
            self.buf = []

    def flush(self):
        with self.lock:
            self._flush()


class Impair:
    """Test-only link impairments for fault-injection runs (tests/fault_injection.py).

    Off unless the helper is started with --allow-impair; a real survey never uses it.
      upLoss / downLoss   fraction of probes dropped before logging (phone→AP) / logged but not echoed (AP→phone)
      delayMs / jitterMs  hold each echo this long
      stallSec            for N seconds: probes vanish, HTTP and TCP are held ("connected but stalls")
      closeUdpSec         close the UDP port for N seconds (clients get ICMP port-unreachable)
      burstEverySec / burstLenSec   periodic loss bursts
    """

    def __init__(self, allowed):
        self.allowed = allowed
        self.lock = threading.Lock()
        self.reset()

    def reset(self):
        self.up_loss = self.down_loss = self.delay_ms = self.jitter_ms = 0.0
        self.stall_until = self.udp_closed_until = 0.0
        self.burst_every = self.burst_len = self.burst_anchor = 0.0

    def set(self, d):
        with self.lock:
            if d.get("reset"):
                self.reset()
            now = time.time()
            for key, attr in (("upLoss", "up_loss"), ("downLoss", "down_loss"), ("delayMs", "delay_ms"),
                              ("jitterMs", "jitter_ms"), ("burstEverySec", "burst_every"),
                              ("burstLenSec", "burst_len")):
                if key in d:
                    setattr(self, attr, float(d[key]))
            if "burstEverySec" in d:
                self.burst_anchor = now
            if "stallSec" in d:
                self.stall_until = now + float(d["stallSec"])
            if "closeUdpSec" in d:
                self.udp_closed_until = now + float(d["closeUdpSec"])
            return self.describe()

    def describe(self):
        now = time.time()
        return {"upLoss": self.up_loss, "downLoss": self.down_loss, "delayMs": self.delay_ms,
                "jitterMs": self.jitter_ms, "stallSecLeft": round(max(0.0, self.stall_until - now), 2),
                "udpClosedSecLeft": round(max(0.0, self.udp_closed_until - now), 2),
                "burstEverySec": self.burst_every, "burstLenSec": self.burst_len}

    def in_burst(self, now):
        return self.burst_every > 0 and ((now - self.burst_anchor) % self.burst_every) < self.burst_len

    def hold(self):
        """Block while a stall is in effect (used by HTTP and TCP handlers)."""
        while self.allowed:
            left = self.stall_until - time.time()
            if left <= 0:
                return
            time.sleep(min(left, 0.2))


class State:
    FILES = ("echo", "marks", "throughput", "client", "radios", "events", "errors", "impair", "sys")

    def __init__(self, base, run_id, allow_impair=False):
        self.impair = Impair(allow_impair)
        self.canaries = []          # secrets that must never be written (omada.canaries_from_env)
        self.canary_hits = 0
        self.recent_marks = deque(maxlen=200)
        self.base = base
        self.run_id = run_id
        self.run_dir = os.path.join(base, "runs", run_id)
        os.makedirs(self.run_dir, exist_ok=True)
        os.makedirs(os.path.join(base, "surveys"), exist_ok=True)
        self.w = {name: JsonlWriter(os.path.join(self.run_dir, name + ".jsonl")) for name in self.FILES}
        self.lock = threading.Lock()
        self.arrivals = {}          # leg -> set(seq)
        self.targets = {}           # phone ip -> last mark time (s)
        self.target_macs = {}       # normalized mac -> ip
        self.latest = {}            # ip -> {"ts":…, "c":…}
        self.echo_count = 0
        self.snapshot_requests = []
        self.collector = {"state": "disabled", "error": None, "lastPollMs": None, "site": None,
                          "controller": None, "snapshots": 0}

    def error(self, where, err):
        self.w["errors"].write({"ts": now_ms(), "where": where, "error": str(err)})

    def redacted(self, obj, where):
        """omada.redact plus the canary scrub. A canary hit is logged by key path (never value)."""
        out, hits = omada.scrub(omada.redact(obj), self.canaries)
        for path in hits:
            self.canary_hits += 1
            self.error("canary " + where, "secret found under %s — pattern redaction missed it" % path)
            log("WARNING: canary secret found in %s under %s (scrubbed)" % (where, path))
        return out

    def record_arrival(self, leg, seq, src, sent, ts, proc_us, queue_us=None):
        with self.lock:
            self.arrivals.setdefault(leg, set()).add(seq)
            self.echo_count += 1
        self.w["echo"].write({"ts": round(ts, 3), "leg": leg, "seq": seq, "src": src, "sent": sent,
                              "procUs": proc_us, "qUs": queue_us})

    def arrival_ranges(self, leg):
        with self.lock:
            seqs = sorted(self.arrivals.get(leg, ()))
        ranges = []
        for s in seqs:
            if ranges and s == ranges[-1][1] + 1:
                ranges[-1][1] = s
            else:
                ranges.append([s, s])
        return ranges, len(seqs)

    def active_targets(self):
        cutoff = time.time() - IDLE_TARGET_SECONDS
        with self.lock:
            return {ip for ip, t in self.targets.items() if t >= cutoff}

    def flush(self):
        for w in self.w.values():
            w.flush()


# --------------------------------------------------------------------------- UDP echo
# Kernel receive timestamps (SO_TIMESTAMP / SCM_TIMESTAMP, struct timeval). Python doesn't export the
# constants; the values are the platform ABI's. qUs = how long a probe sat in the socket buffer before
# this thread got to it — server load shows up here, not in procUs.
SO_TIMESTAMP = 29 if sys.platform.startswith("linux") else 0x0400


def kernel_timestamp(ancdata):
    for level, _type, data in ancdata:
        if level == socket.SOL_SOCKET and len(data) >= 16:
            sec, usec = struct.unpack("ll", data[:16])
            return sec + usec / 1e6
    return None


def udp_echo_loop(state, bind, port):
    def open_socket():
        sk = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sk.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
        try:
            sk.setsockopt(socket.SOL_SOCKET, SO_TIMESTAMP, 1)
            stamps = True
        except OSError:
            stamps = False
        sk.bind((bind, port))
        sk.settimeout(0.2)
        return sk, stamps

    def send(sk, payload, addr):
        try:
            sk.sendto(payload, addr)
        except OSError as e:
            state.error("udp-send", e)

    sock, stamps = open_socket()
    imp = state.impair
    log("udp echo on %s:%d (kernel timestamps %s)" % (bind, port, "on" if stamps else "off"))
    while True:
        if imp.allowed:
            closed = imp.udp_closed_until - time.time()
            if closed > 0:          # fault injection: port closed -> ICMP port-unreachable
                sock.close()
                time.sleep(closed)
                sock, stamps = open_socket()
                continue
        try:
            if stamps:
                data, anc, _flags, addr = sock.recvmsg(4096, 256)
            else:
                data, addr = sock.recvfrom(4096)
                anc = ()
        except socket.timeout:
            continue
        except OSError as e:
            state.error("udp-recv", e)
            continue
        t_recv = time.time()
        t0 = time.perf_counter()
        k_ts = kernel_timestamp(anc)
        queue_us = int((t_recv - k_ts) * 1e6) if k_ts else None
        try:
            msg = json.loads(data)
            leg = str(msg.get("l", ""))
            seq = int(msg.get("s", -1))
            sent = msg.get("t")
        except (ValueError, TypeError, AttributeError):
            continue
        drop_reply = False
        delay = 0.0
        if imp.allowed:
            if t_recv < imp.stall_until or imp.in_burst(t_recv) or random.random() < imp.up_loss:
                continue            # as if the probe never arrived (phone->AP loss)
            drop_reply = random.random() < imp.down_loss
            if imp.delay_ms or imp.jitter_ms:
                delay = max(0.0, imp.delay_ms + random.uniform(-imp.jitter_ms, imp.jitter_ms)) / 1000.0
        msg["sr"] = round(t_recv * 1000.0, 3)
        payload = json.dumps(msg, separators=(",", ":")).encode()
        if not drop_reply:
            if delay > 0:
                threading.Timer(delay, send, (sock, payload, addr)).start()
            else:
                send(sock, payload, addr)
        state.record_arrival(leg, seq, addr[0], sent, t_recv * 1000.0, int((time.perf_counter() - t0) * 1e6),
                             queue_us)


# --------------------------------------------------------------------------- TCP throughput
CHUNK = os.urandom(64 * 1024)


class TputHandler(socketserver.BaseRequestHandler):
    def handle(self):
        state = self.server.state
        sock = self.request
        sock.settimeout(10)
        try:
            line = b""
            while not line.endswith(b"\n") and len(line) < 200:
                b = sock.recv(1)
                if not b:
                    return
                line += b
            parts = line.decode("ascii", "replace").split()
            cmd = parts[0].upper() if parts else ""
            secs = min(max(float(parts[1]) if len(parts) > 1 else 5.0, 1.0), 30.0)
            leg = parts[2] if len(parts) > 2 else ""
        except (OSError, ValueError) as e:
            state.error("tput-cmd", e)
            return
        src = self.client_address[0]
        if cmd == "DOWN":
            sent = 0
            t0 = time.time()
            try:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 << 20)
                while time.time() - t0 < secs:
                    state.impair.hold()
                    sock.sendall(CHUNK)
                    sent += len(CHUNK)
            except OSError:
                pass
            dur = time.time() - t0
            state.w["throughput"].write({"ts": now_ms(), "leg": leg, "dir": "down", "bytes": sent,
                                         "seconds": round(dur, 4), "src": src})
        elif cmd == "UP":
            received = 0
            t_first = None
            deadline = time.time() + secs + 10
            sock.settimeout(4)
            try:
                while time.time() < deadline:
                    state.impair.hold()
                    data = sock.recv(1 << 20)
                    if not data:
                        break
                    if t_first is None:
                        t_first = time.time()
                    received += len(data)
            except OSError:
                pass
            dur = (time.time() - t_first) if t_first else 0.0
            try:
                sock.sendall(("OK %d %.4f\n" % (received, dur)).encode())
            except OSError:
                pass
            state.w["throughput"].write({"ts": now_ms(), "leg": leg, "dir": "up", "bytes": received,
                                         "seconds": round(dur, 4), "src": src})


class TputServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


# --------------------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "wifisurvey/" + VERSION
    timeout = 120  # drop idle keep-alive connections

    def log_message(self, fmt, *args):  # keep tmux quiet
        pass

    @property
    def state(self):
        return self.server.state

    def send_json(self, obj, code=200):
        body = json.dumps(obj, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def read_body(self, limit=5 * 1024 * 1024):
        n = int(self.headers.get("Content-Length") or 0)
        if n > limit:
            raise ValueError("body too large")
        return self.rfile.read(n) if n else b""

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        try:
            if not u.path.startswith("/debug"):
                self.state.impair.hold()
            if u.path == "/health":
                c = dict(self.state.collector)
                h = {"ok": True, "version": VERSION, "serverMs": now_ms(), "run": self.state.run_id,
                     "collector": c, "echoPackets": self.state.echo_count,
                     "canaries": len(self.state.canaries), "canaryHits": self.state.canary_hits}
                if self.state.impair.allowed:
                    h["impair"] = self.state.impair.describe()   # visible proof this is a test instance
                self.send_json(h)
            elif u.path == "/debug/marks" and self.state.impair.allowed:
                self.send_json({"ok": True, "marks": list(self.state.recent_marks)})
            elif u.path == "/status":
                ip = (q.get("ip") or [""])[0]
                rec = self.state.latest.get(ip)
                if rec:
                    self.send_json({"ok": True, "ageMs": now_ms() - rec["ts"], "ts": rec["ts"], "c": rec["c"]})
                else:
                    self.send_json({"ok": False, "reason": "no record for %s yet" % ip,
                                    "collector": self.state.collector.get("state")})
            elif u.path == "/arrivals":
                leg = (q.get("leg") or [""])[0]
                ranges, count = self.state.arrival_ranges(leg)
                self.send_json({"ok": True, "leg": leg, "count": count, "ranges": ranges})
            elif u.path == "/":
                self.send_json({"ok": True, "service": "wifisurvey helper", "version": VERSION})
            else:
                self.send_json({"ok": False, "error": "not found"}, 404)
        except Exception as e:  # never let one request kill the helper
            self.state.error("http-get " + u.path, e)
            self.send_json({"ok": False, "error": str(e)}, 500)

    def do_POST(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        try:
            if u.path == "/impair":
                if not self.state.impair.allowed:
                    self.send_json({"ok": False, "error": "impairment disabled (start with --allow-impair)"}, 403)
                    return
                d = json.loads(self.read_body() or b"{}")
                desc = self.state.impair.set(d)
                self.state.w["impair"].write({"ts": now_ms(), "set": d, "state": desc})
                log("IMPAIR %s" % json.dumps(d))
                self.send_json({"ok": True, "impair": desc})
                return
            self.state.impair.hold()
            if u.path == "/mark":
                m = json.loads(self.read_body() or b"{}")
                m = {k: m.get(k) for k in ("phoneMs", "event", "surveyId", "measurementId", "legId", "network",
                                           "ssid", "bssid", "ip", "mac", "room", "spot", "note")}
                m["ts"] = now_ms()
                self.state.w["marks"].write(m)
                self.state.recent_marks.append(m)
                ip = m.get("ip")
                if ip:
                    with self.state.lock:
                        self.state.targets[ip] = time.time()
                if m.get("mac"):
                    self.state.target_macs[omada.norm_mac(m["mac"])] = ip or ""
                if m.get("event") in ("survey-start", "survey-end"):
                    self.state.snapshot_requests.append(m["event"])
                self.send_json({"ok": True, "serverMs": m["ts"]})
            elif u.path == "/snapshot":
                reason = (q.get("reason") or ["manual"])[0]
                self.state.snapshot_requests.append(reason)
                self.send_json({"ok": True, "queued": reason})
            elif u.path == "/export":
                req = json.loads(self.read_body() or b"{}")
                body = build_export(self.state, req)
                self.send_response(200)
                self.send_header("Content-Type", "application/zip")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif u.path == "/survey-upload":
                name = re.sub(r"[^A-Za-z0-9._-]", "_", (q.get("name") or ["survey.zip"])[0])[:120]
                n = int(self.headers.get("Content-Length") or 0)
                if n <= 0 or n > 2 * 1024 ** 3:
                    raise ValueError("bad Content-Length")
                path = os.path.join(self.state.base, "surveys", time.strftime("%Y%m%d-%H%M%S-") + name)
                left = n
                with open(path, "wb") as f:
                    while left > 0:
                        chunk = self.rfile.read(min(left, 1 << 20))
                        if not chunk:
                            break
                        f.write(chunk)
                        left -= len(chunk)
                log("survey upload saved: %s (%d bytes)" % (path, n - left))
                self.send_json({"ok": left == 0, "path": path, "bytes": n - left})
            else:
                self.send_json({"ok": False, "error": "not found"}, 404)
        except Exception as e:
            self.state.error("http-post " + u.path, e)
            self.send_json({"ok": False, "error": str(e)}, 500)


def build_export(state, req):
    """Zip every run's files for the requested window (±2 min). echo rows are kept by leg id too."""
    state.flush()
    t_from = float(req.get("fromMs") or 0) - 120000
    t_to = float(req.get("toMs") or now_ms()) + 120000
    legs = set(req.get("legs") or [])
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for run_dir in sorted(glob.glob(os.path.join(state.base, "runs", "*"))):
            run = os.path.basename(run_dir)
            for path in sorted(glob.glob(os.path.join(run_dir, "*"))):
                name = os.path.basename(path)
                if name.endswith(".jsonl"):
                    kept = []
                    with open(path) as f:
                        for line in f:
                            try:
                                rec = json.loads(line)
                            except ValueError:
                                continue
                            ts = rec.get("ts") or 0
                            if t_from <= ts <= t_to or (name == "echo.jsonl" and rec.get("leg") in legs):
                                kept.append(line if line.endswith("\n") else line + "\n")
                    if kept:
                        z.writestr("%s/%s" % (run, name), "".join(kept))
                elif name.startswith("config-") and name.endswith(".json"):
                    try:
                        with open(path) as f:
                            ts = json.load(f).get("ts") or 0
                    except ValueError:
                        continue
                    if t_from - 86400000 <= ts <= t_to + 86400000:
                        z.write(path, "%s/%s" % (run, name))
                elif name == "helper.json":
                    z.write(path, "%s/%s" % (run, name))
    return buf.getvalue()


# --------------------------------------------------------------------------- Omada collector
def collector_loop(state, env_path):
    try:
        mode = os.stat(env_path).st_mode
        if mode & (stat.S_IRWXG | stat.S_IRWXO):
            log("WARNING: %s is readable by group/other — run: chmod 600 %s" % (env_path, env_path))
        env = omada.load_env(env_path)
        client = omada.OmadaClient(env.get("OMADA_URL", "https://127.0.0.1:8043"), env["OMADA_USER"],
                                   env["OMADA_PASS"], site=env.get("OMADA_SITE") or None,
                                   insecure=env.get("OMADA_INSECURE") == "1")
        if env.get("OMADA_INSECURE") == "1":
            log("OMADA_INSECURE=1: not verifying the controller's TLS certificate")
    except (OSError, KeyError) as e:
        state.collector.update(state="disabled", error="no usable %s (%s)" % (env_path, e))
        log("collector disabled: %s" % state.collector["error"])
        return
    state.canaries = omada.canaries_from_env(env)
    if state.canaries:
        log("canary scrub armed with %d secret(s) from %s" % (len(state.canaries), os.path.basename(env_path)))
    else:
        log("no SURVEY_PSK in %s: add it to catch any passphrase the pattern redaction misses" % env_path)

    state.snapshot_requests.append("helper-start")
    next_client = next_radio = next_event = 0.0
    last_event_ms = now_ms() - 3600000
    event_idx = None          # which event endpoint candidate works on this controller
    seen_events = set()
    backoff = 0.0
    while True:
        try:
            if client.token is None:
                client.login()
                state.collector.update(state="ok", error=None, site=client.site_name,
                                       controller=client.controller_ver)
                log("collector logged in: controller %s, site %r" % (client.controller_ver, client.site_name))
            while state.snapshot_requests:
                take_snapshot(state, client, state.snapshot_requests.pop(0))

            now = time.time()
            targets = state.active_targets()
            want_clients = now >= next_client and bool(targets)
            want_radios = now >= next_radio
            if want_clients or want_radios:
                t = now_ms()
                clients = client.clients()
                if want_clients:
                    next_client = now + 5
                    log_phone_records(state, clients, targets, t)
                if want_radios:
                    next_radio = now + 30
                    log_radios(state, client, clients, t)
                state.collector["lastPollMs"] = t

            if now >= next_event:
                next_event = now + 60
                t = now_ms()
                event_idx = log_events(state, client, event_idx, last_event_ms - 120000, t, seen_events)
                last_event_ms = t
            backoff = 0.0
        except Exception as e:  # network blips, expired sessions, controller restarts
            state.collector.update(state="error", error=str(e))
            state.error("collector", e)
            client.token = None
            backoff = min(backoff * 2 or 5.0, 60.0)
            log("collector error (%s); retry in %.0fs" % (e, backoff))
            time.sleep(backoff)
            continue
        time.sleep(0.5)


def take_snapshot(state, client, reason):
    snap = state.redacted(client.snapshot(reason), "snapshot")   # snapshot() already pattern-redacts; add the canary scrub
    tag = re.sub(r"[^a-z0-9-]", "", reason.lower())[:24]
    path = os.path.join(state.run_dir, "config-%s-%s.json" % (time.strftime("%Y%m%d-%H%M%S"), tag))
    with open(path, "w") as f:
        json.dump(snap, f, indent=1)
    state.collector["snapshots"] += 1
    ok = sum(1 for v in snap["endpoints"].values() if v.get("ok"))
    log("config snapshot (%s): %d/%d endpoints ok -> %s" % (reason, ok, len(snap["endpoints"]),
                                                           os.path.basename(path)))


def log_phone_records(state, clients, targets, t):
    for rec in clients:
        ip = rec.get("ip")
        mac = omada.norm_mac(rec.get("mac"))
        if ip in targets or (mac and mac in state.target_macs):
            if ip in targets and mac:
                state.target_macs[mac] = ip
            c = omada.compact_client(rec)
            state.latest[ip or state.target_macs.get(mac, "")] = {"ts": t, "c": c}
            state.w["client"].write({"ts": t, "ip": ip, "mac": rec.get("mac"), "c": c,
                                     "rec": state.redacted(rec, "client")})


def log_radios(state, client, clients, t):
    load = {}
    for rec in clients:
        if rec.get("wireless") or rec.get("apMac"):
            key = "%s|%s" % (rec.get("apName") or rec.get("apMac"), rec.get("radioId"))
            e = load.setdefault(key, {"n": 0, "rssi": []})
            e["n"] += 1
            if isinstance(rec.get("rssi"), (int, float)):
                e["rssi"].append(rec["rssi"])
    state.w["radios"].write({"ts": t, "kind": "load", "c": {
        k: {"clients": v["n"], "rssiMedian": sorted(v["rssi"])[len(v["rssi"]) // 2] if v["rssi"] else None}
        for k, v in load.items()}})
    for ap in client.aps():
        mac = ap.get("mac")
        try:
            detail = client.ap_detail(mac) or {}
        except omada.OmadaError as e:
            state.error("ap-detail %s" % mac, e)
            continue
        state.w["radios"].write({"ts": t, "kind": "ap",
                                 "ap": {"mac": mac, "name": ap.get("name"), "model": ap.get("model")},
                                 "rec": state.redacted(detail, "ap-detail")})


def log_events(state, client, event_idx, start_ms, end_ms, seen):
    """Write new controller log entries. Returns the index of the endpoint that worked (or None)."""
    cands = client.event_candidates(int(start_ms), int(end_ms))
    order = [event_idx] if event_idx is not None else range(len(cands))
    for i in order:
        try:
            j = client.get_raw(cands[i])
        except omada.OmadaError:
            continue
        if j.get("errorCode") != 0:
            continue
        res = j.get("result")
        rows = res.get("data") if isinstance(res, dict) else res
        if not isinstance(rows, list):
            continue
        for row in rows:
            key = json.dumps(row, sort_keys=True)[:400]
            if key in seen:
                continue
            seen.add(key)
            ts = row.get("time") or row.get("timestamp") or row.get("ts") or end_ms
            rec = state.redacted(row, "event")
            # An event's "key" is its type code (OSG_DHCP_S, AP_RADAR …), not a secret: keep it when it looks like one.
            if isinstance(row.get("key"), str) and re.fullmatch(r"[A-Z][A-Z0-9_]{1,48}", row["key"]):
                rec["key"] = row["key"]
            state.w["events"].write({"ts": ts, "rec": rec})
        return i
    return None


def dump_events(client, days):
    """Print the controller's recent log (redacted) — DFS/radar, channel changes, roams, disconnects.
    A free look at history before anyone walks the house."""
    end = int(time.time() * 1000)
    start = end - int(days * 86400000)
    for path in client.event_candidates(start, end):
        # The log can hold tens of thousands of rows (6.3 logs every DHCP lease): page through all of them.
        rows, total, page = [], None, 1
        while True:
            p = path.replace("currentPage=1&currentPageSize=200", "currentPage=%d&currentPageSize=1000" % page)
            try:
                j = client.get_raw(p)
            except omada.OmadaError as e:
                print("%s -> %s" % (p, e))
                break
            if j.get("errorCode") != 0:
                print("%s -> errorCode %s %s" % (p, j.get("errorCode"), j.get("msg")))
                break
            res = j.get("result")
            chunk = res.get("data") if isinstance(res, dict) else res
            if not isinstance(chunk, list):
                break
            total = res.get("totalRows") if isinstance(res, dict) else len(chunk)
            rows.extend(chunk)
            if not chunk or len(rows) >= (total or 0) or page >= 200:
                break
            page += 1
        if total is None:
            continue
        print("%s: %d of %d rows" % (path.split("?")[0], len(rows), total))
        kinds = Counter((r.get("module"), r.get("key")) for r in rows)
        print("by type (module key: count):")
        for (mod, key), n in kinds.most_common():
            print("  %6d  %s %s" % (n, mod, key))
        # DHCP leases are routine and drown everything else; list the rest in time order
        rows = sorted((r for r in rows if r.get("key") != "OSG_DHCP_S"), key=lambda r: r.get("time") or 0)
        print("all events except DHCP leases (%d):" % len(rows))
        for row in rows:
            r = omada.redact(row)
            ts = r.get("time") or r.get("timestamp") or r.get("ts")
            when = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts / 1000.0)) if isinstance(ts, (int, float)) else "?"
            text = next((r[k] for k in ("content", "msg", "message", "desc", "detail") if isinstance(r.get(k), str)),
                        json.dumps(r)[:200])
            print("  %s  %s" % (when, text))
        return
    print("no event endpoint answered")


# --------------------------------------------------------------------------- host health (Linux)
def read_udp_counters():
    """Kernel UDP counters from /proc/net/snmp: InErrors and RcvbufErrors say whether the server itself
    dropped probes (a drop here would otherwise be blamed on the phone's uplink)."""
    try:
        with open("/proc/net/snmp") as f:
            lines = [l.split() for l in f if l.startswith("Udp:")]
        if len(lines) >= 2:
            return dict(zip(lines[0][1:], (int(x) for x in lines[1][1:])))
    except (OSError, ValueError):
        pass
    return None


def sys_loop(state):
    """Every 5 s: load average and kernel UDP drop counters -> sys.jsonl."""
    while True:
        rec = {"ts": now_ms()}
        try:
            rec["load1"], rec["load5"], _ = (round(x, 2) for x in os.getloadavg())
        except OSError:
            pass
        udp = read_udp_counters()
        if udp:
            rec["udpInErrors"] = udp.get("InErrors")
            rec["udpRcvbufErrors"] = udp.get("RcvbufErrors")
            rec["udpInDatagrams"] = udp.get("InDatagrams")
        rec["canaryHits"] = state.canary_hits
        state.w["sys"].write(rec)
        time.sleep(5)


# --------------------------------------------------------------------------- main
def status_loop(state):
    while True:
        time.sleep(1)
        state.flush()
        if int(time.time()) % 60 == 0:
            c = state.collector
            age = ("%.0fs ago" % ((now_ms() - c["lastPollMs"]) / 1000)) if c.get("lastPollMs") else "never"
            log("echo=%d legs=%d targets=%d collector=%s (last poll %s)" % (
                state.echo_count, len(state.arrivals), len(state.active_targets()), c["state"], age))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bind", default="127.0.0.1", help="address to listen on (the server's LAN address, e.g. 192.168.1.10)")
    ap.add_argument("--base", default=os.path.expanduser("~/wifisurvey"), help="data directory")
    ap.add_argument("--env", default=None, help="Omada credentials file (default <base>/.omada.env)")
    ap.add_argument("--udp-port", type=int, default=9750)
    ap.add_argument("--http-port", type=int, default=9751)
    ap.add_argument("--tcp-port", type=int, default=9752)
    ap.add_argument("--no-omada", action="store_true", help="run without the Omada collector")
    ap.add_argument("--discover", action="store_true", help="probe Omada endpoints, print shapes, exit")
    ap.add_argument("--dump-events", type=float, metavar="DAYS",
                    help="print the controller log for the last DAYS days (redacted) and exit")
    ap.add_argument("--allow-impair", action="store_true",
                    help="TEST ONLY: enable POST /impair fault injection (never use for a real survey)")
    args = ap.parse_args()
    env_path = args.env or os.path.join(args.base, ".omada.env")

    if args.discover or args.dump_events:
        env = omada.load_env(env_path)
        c = omada.OmadaClient(env.get("OMADA_URL", "https://127.0.0.1:8043"), env["OMADA_USER"], env["OMADA_PASS"],
                              site=env.get("OMADA_SITE") or None, insecure=env.get("OMADA_INSECURE") == "1")
        c.login()
        if args.discover:
            c.discover()
        if args.dump_events:
            dump_events(c, args.dump_events)
        return

    run_id = time.strftime("%Y%m%d-%H%M%S")
    state = State(args.base, run_id, allow_impair=args.allow_impair)
    if args.allow_impair:
        log("*** --allow-impair: fault injection ENABLED — test instance, not for a real survey ***")
    with open(os.path.join(state.run_dir, "helper.json"), "w") as f:
        json.dump({"version": VERSION, "run": run_id, "bind": args.bind, "startedMs": now_ms(),
                   "allowImpair": args.allow_impair,
                   "ports": {"udp": args.udp_port, "http": args.http_port, "tcp": args.tcp_port}}, f)

    threading.Thread(target=udp_echo_loop, args=(state, args.bind, args.udp_port), daemon=True).start()
    tput = TputServer((args.bind, args.tcp_port), TputHandler)
    tput.state = state
    threading.Thread(target=tput.serve_forever, daemon=True).start()
    log("tcp throughput on %s:%d" % (args.bind, args.tcp_port))
    httpd = ThreadingHTTPServer((args.bind, args.http_port), Handler)
    httpd.daemon_threads = True
    httpd.state = state
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    log("http on %s:%d  data -> %s" % (args.bind, args.http_port, state.run_dir))
    if args.no_omada:
        state.collector.update(state="disabled", error="--no-omada")
    else:
        threading.Thread(target=collector_loop, args=(state, env_path), daemon=True).start()
    threading.Thread(target=status_loop, args=(state,), daemon=True).start()
    threading.Thread(target=sys_loop, args=(state,), daemon=True).start()

    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *a: stop.set())
    try:
        while not stop.is_set():
            stop.wait(1)
    except KeyboardInterrupt:
        pass
    state.flush()
    log("stopped; data in %s" % state.run_dir)


if __name__ == "__main__":
    sys.exit(main())
