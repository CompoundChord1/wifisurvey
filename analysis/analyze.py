#!/usr/bin/env python3
"""Analyze a WiFi Survey export (docs/SCHEMA.md). Python 3.9+ stdlib only.

    python3 analysis/analyze.py ~/Downloads/WiFiSurvey_<name>_<stamp>.zip [--out DIR]

Accepts the export .zip or its unzipped folder. Writes to DIR (default analysis-out/<export name>/):
  legs.csv      one row per network leg (every measurement), everything recomputed from raw data
  spots.csv     one row per spot (newest complete measurement), 2G / 5G / DUAL side by side
  summary.json  per-band aggregates, hypothesis evidence, data-completeness counts
  report.md     human-readable tables by floor and room, flags, glitch timeline, config highlights

The flags are heuristics to point the analysis at the right evidence (docs/ANALYSIS-PLAYBOOK.md),
not conclusions.
"""
import argparse
import csv
import io
import json
import math
import os
import re
import statistics
import sys
import zipfile
from collections import Counter, defaultdict

# Thresholds (docs/ANALYSIS-PLAYBOOK.md explains each)
LOSS_WARN, LOSS_BAD = 1.0, 3.0           # % of UDP probes lost
P95_WARN, P95_BAD = 30.0, 100.0          # ms
GAP_STALL_MS = 2000                      # no echo for this long while sending = a stall
RSSI_WEAK_PHONE = -70.0                  # dBm, phone side (Shortcut)
RSSI_WEAK_AP = -75.0                     # dBm, AP side (Omada)
ASYM_DB = 10.0                           # phone hears AP this much better than AP hears phone (absolute fallback)
ASYM_ABOVE_MEDIAN_DB = 6.0               # … or this much more lopsided than the survey's median spot
UP_DOWN_RATIO = 2.0                      # loss mostly phone→AP
OFF_TARGET_INVALID = 0.2                 # fraction of Wi-Fi samples on another SSID that voids a leg
SERVER_EXCESS_MS = 20.0                  # UDP p95 (idle) this much above the gateway ping p95 = server path, not Wi-Fi
SERVER_QUEUE_MS = 5.0                    # p95 time a probe waited in the server's socket buffer
LOAD_TAIL_MS = 2000                      # after a speed test the phone's transmit queue is still draining
HB_TIMEOUT_MS = 2000                     # the app's heartbeat request timeout (Probes.swift)

HERE = os.path.dirname(os.path.abspath(__file__))


# --------------------------------------------------------------------------- loading
class Package:
    def __init__(self, path):
        self.path = path
        self.name = os.path.basename(path.rstrip("/")).replace(".zip", "")
        self.survey = None
        self.raw = {}           # relative raw file -> [records]
        self.server = defaultdict(list)   # file name (echo.jsonl, …) -> merged rows across runs
        self.configs = []       # (name, json)
        self.attachments = []
        if os.path.isdir(path):
            self._load_dir(path)
        else:
            self._load_zip(path)
        if self.survey is None:
            raise SystemExit("no survey.json found in %s" % path)

    def _load_zip(self, path):
        z = zipfile.ZipFile(path)
        names = z.namelist()
        sj = [n for n in names if n.endswith("survey.json")]
        if not sj:
            return
        root = sj[0][: -len("survey.json")]
        self.survey = json.loads(z.read(sj[0]))
        for n in names:
            rel = n[len(root):]
            if rel.startswith("raw/") and rel.endswith(".jsonl"):
                self.raw[rel] = parse_jsonl(z.read(n).decode("utf-8", "replace"))
            elif rel.startswith("attachments/") and not rel.endswith("/"):
                self.attachments.append(rel)
            elif rel == "server-data.zip":
                self._load_server(zipfile.ZipFile(io.BytesIO(z.read(n))))

    def _load_dir(self, path):
        sj = None
        for dirpath, _, files in os.walk(path):
            if "survey.json" in files:
                sj = os.path.join(dirpath, "survey.json")
                break
        if not sj:
            return
        root = os.path.dirname(sj)
        with open(sj) as f:
            self.survey = json.load(f)
        rawdir = os.path.join(root, "raw")
        if os.path.isdir(rawdir):
            for fn in os.listdir(rawdir):
                if fn.endswith(".jsonl"):
                    with open(os.path.join(rawdir, fn)) as f:
                        self.raw["raw/" + fn] = parse_jsonl(f.read())
        att = os.path.join(root, "attachments")
        if os.path.isdir(att):
            self.attachments = ["attachments/" + fn for fn in sorted(os.listdir(att))]
        sd = os.path.join(root, "server-data.zip")
        if os.path.exists(sd):
            self._load_server(zipfile.ZipFile(sd))

    def _load_server(self, z):
        for n in sorted(z.namelist()):
            base = n.split("/")[-1]
            if base.endswith(".jsonl"):
                self.server[base].extend(parse_jsonl(z.read(n).decode("utf-8", "replace")))
            elif base.startswith("config-") and base.endswith(".json"):
                try:
                    self.configs.append((n, json.loads(z.read(n))))
                except ValueError:
                    pass


def parse_jsonl(text):
    out = []
    for line in text.splitlines():
        line = line.strip()
        if line:
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


# --------------------------------------------------------------------------- helpers
def pct(part, whole):
    return round(100.0 * part / whole, 2) if whole else None


def quant(values, q):
    v = sorted(x for x in values if x is not None)
    if not v:
        return None
    pos = q * (len(v) - 1)
    lo = int(pos)
    hi = min(lo + 1, len(v) - 1)
    return round(v[lo] + (v[hi] - v[lo]) * (pos - lo), 2)


def med(values):
    v = [x for x in values if isinstance(x, (int, float))]
    return round(statistics.median(v), 2) if v else None


def num(x):
    return x if isinstance(x, (int, float)) and not isinstance(x, bool) else None


def band_of_channel(ch):
    if not isinstance(ch, (int, float)):
        return None
    return "2.4GHz" if ch <= 14 else "5GHz"


# --------------------------------------------------------------------------- per-leg analysis
def analyze_leg(pkg, leg, room, spot, meas, arrivals_by_leg, clients, events, marks_by_leg, server=None):
    server = server or {}
    recs = pkg.raw.get(leg.get("rawFile") or "", [])
    by = defaultdict(list)
    for r in recs:
        by[r.get("k")].append(r)
    summ = leg.get("summary") or {}
    # The server's clock minus the phone's, from the echo (SCHEMA: clockOffsetMs). Server-side rows are
    # matched to the leg window in server time.
    clock_off = num((summ.get("udp") or {}).get("clockOffsetMs")) or 0.0
    row = {
        "floor": room["floor"], "room": room["name"], "spot": spot["label"], "spotKind": spot["kind"],
        "problem": spot.get("problem", False), "measurementId": meas["id"], "measurementStatus": meas["status"],
        "legId": leg["id"], "network": leg["network"], "ssid": leg["ssidTarget"], "status": leg["status"],
        "startMs": leg.get("startMs"), "endMs": leg.get("endMs"), "plannedSeconds": leg.get("plannedSeconds"),
        "joinMethod": (leg.get("join") or {}).get("method"), "joinMs": (leg.get("join") or {}).get("totalMs"),
        "joinError": (leg.get("join") or {}).get("error"), "ip": leg.get("ip"),
        "glitches": len(leg.get("glitchMs") or []), "errors": "; ".join(leg.get("errors") or []),
        "headingDeg": meas.get("headingDeg"),
        "reconnects": (summ.get("udp") or {}).get("reconnects"),
        # The app was backgrounded mid-leg: iOS suspended the probes, so gaps are not Wi-Fi stalls.
        "appBackgrounded": bool(leg.get("interrupted")) or any(r.get("state") == "background"
                                                               for r in by.get("app", [])),
        "serverUnreachableAtStart": "unreachable" in ((leg.get("join") or {}).get("error") or ""),
        "selfAssignedIp": str(leg.get("ip") or "").startswith("169.254."),   # DHCP failed on this network
        "clockOffsetMs": clock_off,
    }

    # UDP echo: loss (split by direction using server arrivals), latency, gaps
    udp = sorted(by.get("udp", []), key=lambda r: r.get("seq", 0))
    arrivals = arrivals_by_leg.get(leg["id"])
    if udp:
        lost = [r for r in udp if r.get("rtt") is None]
        rtts = [r["rtt"] for r in udp if r.get("rtt") is not None]
        row.update(udpSent=len(udp), udpLossPct=pct(len(lost), len(udp)),
                   rttP50=quant(rtts, 0.5), rttP95=quant(rtts, 0.95), rttP99=quant(rtts, 0.99),
                   rttMax=round(max(rtts), 1) if rtts else None)
        if arrivals is not None:
            up = sum(1 for r in lost if r["seq"] not in arrivals)
            row.update(upLossPct=pct(up, len(udp)), downLossPct=pct(len(lost) - up, len(udp)),
                       lossDirectionSource="server")
        else:
            u = summ.get("udp") or {}
            row.update(upLossPct=u.get("upLossPct"), downLossPct=u.get("downLossPct"),
                       lossDirectionSource="phone" if u.get("upLossPct") is not None else None)
        diffs = [abs(b - a) for a, b in zip(rtts, rtts[1:])]
        row["jitterMs"] = round(sum(diffs) / len(diffs), 2) if diffs else None
        # Idle vs loaded: probes sent during the 5 s speed tests see the phone's own transmit queue
        # (bufferbloat), which is load, not a stall — and so do probes sent just after a test, while that
        # queue drains. A full queue tail-drops consecutive probes, so a loaded window can hold a ≥ 2 s gap
        # on a link that never stalled. Grades, stall events and flags use the idle probes.
        windows = load_windows(udp)
        idle = [r for r in udp if not in_windows(r.get("sent"), windows)]
        loaded = [r for r in udp if in_windows(r.get("sent"), windows)]
        # longest run without an echo, measured on the phone's send clock, idle and loaded separately
        gi, gl = gaps_by_segment(udp, windows, loaded=False), gaps_by_segment(udp, windows, loaded=True)
        row["maxGapMs"] = round(max(b - a for a, b in gi), 0) if gi else None
        row["stallEvents"] = sum(1 for a, b in gi if b - a >= GAP_STALL_MS)
        if windows:
            row["maxGapMsLoaded"] = round(max(b - a for a, b in gl), 0) if gl else None
            row["stallEventsLoaded"] = sum(1 for a, b in gl if b - a >= GAP_STALL_MS)
            # A loaded gap is still a stall if the speed test's TCP stream made no progress at the same
            # time (a dead link stops everything; a full queue keeps TCP moving).
            frozen = tcp_frozen(by.get("tput", []))
            row["stallEvents"] += sum(1 for a, b in gl if b - a >= GAP_STALL_MS
                                      and any(fa < b and a < fb for fa, fb in frozen))
        run = best = bursts = 0
        burst_starts = []       # starts of runs of ≥ 3 lost probes: single random losses are not a rhythm
        start = None
        for r in udp + [{"rtt": 0}]:
            if r.get("rtt") is None:
                if run == 0:
                    start = r["sent"]
                run += 1
                best = max(best, run)
            else:
                if run >= 3:
                    bursts += 1
                    burst_starts.append(start)
                run = 0
        row.update(maxLossBurst=best, lossBursts3plus=bursts)
        row["periodicLossSec"] = periodicity(burst_starts)
        if idle:
            lost_i = sum(1 for r in idle if r.get("rtt") is None)
            row.update(udpSentIdle=len(idle), udpLossPctIdle=pct(lost_i, len(idle)),
                       rttP95Idle=quant([r["rtt"] for r in idle if r.get("rtt") is not None], 0.95))
        if loaded:
            lost_l = sum(1 for r in loaded if r.get("rtt") is None)
            row.update(udpSentLoaded=len(loaded), udpLossPctLoaded=pct(lost_l, len(loaded)),
                       rttP95Loaded=quant([r["rtt"] for r in loaded if r.get("rtt") is not None], 0.95))
        row["udpSendErrors"] = sum(1 for r in udp if r.get("se"))   # never left the phone (no route)
        # The server's own queueing: how long each probe waited in the socket buffer before the helper read it
        q = [e.get("qUs") for e in server.get("echo_by_leg", {}).get(leg["id"], []) if num(e.get("qUs")) is not None]
        if q:
            row["serverQueueP95Ms"] = round(quant(q, 0.95) / 1000.0, 2)
    # gateway ping, heartbeat, DNS
    ping = by.get("ping", [])
    if ping:
        ok = [r["rtt"] for r in ping if r.get("rtt") is not None]
        row.update(pingLossPct=pct(len(ping) - len(ok), len(ping)), pingP50=quant(ok, 0.5), pingP95=quant(ok, 0.95))
        if row.get("rttP95Idle") is not None and row.get("pingP95") is not None:
            # latency the UDP path has beyond the gateway: the wired path and the server, not the radio
            row["rttExcessOverPingMs"] = round(row["rttP95Idle"] - row["pingP95"], 1)
    hb = by.get("hb", [])
    if hb:
        hb_windows = load_windows(udp) if udp else []
        row.update(hbSent=len(hb), hbFailed=sum(1 for r in hb if r.get("err")),
                   # a heartbeat stuck behind the speed test's queue is load, not a stall (graded on idle)
                   hbFailedIdle=sum(1 for r in hb if r.get("err")
                                    and not in_windows(r.get("sent"), hb_windows, before=HB_TIMEOUT_MS)),
                   hbP95=quant([r["rtt"] for r in hb if r.get("rtt") is not None], 0.95))
    dns = by.get("dns", [])
    if dns:
        row.update(dnsSent=len(dns), dnsFailed=sum(1 for r in dns if r.get("rtt") is None),
                   dnsP50=quant([r["rtt"] for r in dns if r.get("rtt") is not None], 0.5),
                   dnsServer=dns[0].get("server"))
    for t in by.get("tput", []):
        key = "down" if t.get("dir") == "down" else "up"
        row[key + "Mbps"] = t.get("mbpsSteady") or t.get("mbps")
    if "downMbps" not in row and (summ.get("throughput") or {}).get("skipped"):
        row["tputSkipped"] = summ["throughput"]["skipped"]
    # Wi-Fi association timeline (phone side)
    row["wifiInfoTimeouts"] = sum(1 for r in by.get("wifi", []) if r.get("timeout"))
    wifi = [r for r in by.get("wifi", []) if not r.get("timeout")]   # a timeout is not "no Wi-Fi"
    bss = []
    if wifi:
        bss = [r.get("bssid") for r in wifi if r.get("bssid")]
        roams = sum(1 for a, b in zip(bss, bss[1:]) if a != b)
        # Samples on another SSID: iOS auto-joined a sibling network mid-leg (e.g. SURVEY-2G while the
        # 5G leg was weak). Those seconds were measured on the wrong band.
        target = leg.get("ssidTarget")
        off = sum(1 for r in wifi if r.get("ssid") and target and r.get("ssid") != target)
        row.update(bssids=" ".join(sorted(set(bss))), roams=roams,
                   noWifiSeconds=sum(1 for r in wifi if not r.get("ssid")),
                   ssidsSeen=" ".join(sorted(set(r.get("ssid") or "-" for r in wifi))),
                   offTargetSeconds=off, offTargetFrac=round(off / len(wifi), 3))
    # phone radio (Shortcut) — taken ~12 s after the probes, with the app in the background
    radio = by.get("radio", []) or leg.get("radio") or []
    if radio:
        rb = {WiFiBSSID(r.get("bssid")) for r in radio if r.get("bssid")}
        if rb and bss:
            # The Shortcut ran after the leg; if the phone had moved to another AP/SSID by then, its
            # RSSI describes a different link than the probes measured.
            row["radioOnLegBssid"] = bool(rb & {WiFiBSSID(b) for b in bss})
        rssi = [num(r.get("rssi")) for r in radio]
        noise = [num(r.get("noise")) for r in radio]
        snr = [a - b for a, b in zip(rssi, noise) if a is not None and b is not None]
        chans = sorted(set(int(r["channel"]) for r in radio if num(r.get("channel")) is not None))
        row.update(phoneRssi=med(rssi), phoneRssiMin=min([x for x in rssi if x is not None], default=None),
                   phoneNoise=med(noise), phoneSnr=med(snr), phoneChannel=" ".join(map(str, chans)),
                   phoneBand=band_of_channel(chans[0]) if chans else None,
                   phoneTxRate=med([num(r.get("txRate")) for r in radio]),
                   phoneRxRate=med([num(r.get("rxRate")) for r in radio]),
                   phoneStandard=" ".join(sorted(set(r.get("standard") or "" for r in radio) - {""})),
                   radioSamples=len(radio))
    # AP side (Omada): helper's client.jsonl in the leg window (server clock), matched by the leg's IPs
    ips = {leg.get("ip")} | {m.get("ip") for m in marks_by_leg.get(leg["id"], [])}
    ips.discard(None)
    t0 = (leg.get("startMs") or 0) + clock_off - 5000
    t1 = (leg.get("endMs") or leg.get("startMs") or 0) + clock_off + 5000
    ap_rows = [c for c in clients if t0 <= c.get("ts", 0) <= t1 and c.get("ip") in ips]
    if not ap_rows:
        ap_rows = [dict(ts=r.get("ts"), c=r) for r in by.get("ap", [])]  # phone's own polls of /status
    if ap_rows:
        cs = [r.get("c") or {} for r in ap_rows]
        names = Counter(c.get("apName") for c in cs if c.get("apName"))
        bands = Counter(c.get("band") for c in cs if c.get("band"))
        # The helper polls every 5 s but the controller refreshes a client's stats far less often, so
        # most polls repeat the previous values. Count the distinct observations too.
        # Compare only signal/rate fields: traffic counters and uptime can change on every poll.
        sig = [tuple(c.get(k) for k in AP_SIGNAL_FIELDS) for c in cs]
        fresh = sum(1 for a, b in zip([None] + sig, sig) if a != b)
        row.update(apName=names.most_common(1)[0][0] if names else None,
                   apNames=" ".join(sorted(names)), apBand=bands.most_common(1)[0][0] if bands else None,
                   apChannel=med([num(c.get("channel")) for c in cs]),
                   apRssi=med([num(c.get("rssi")) for c in cs]),
                   apRssiMin=min([num(c.get("rssi")) for c in cs if num(c.get("rssi")) is not None], default=None),
                   apSnr=med([num(c.get("snr")) for c in cs]),
                   apTxRate=med([num(c.get("txRate")) for c in cs]),
                   apRxRate=med([num(c.get("rxRate")) for c in cs]),
                   apSamples=len(cs), apFreshSamples=fresh)
    if row.get("phoneRssi") is not None and row.get("apRssi") is not None and row.get("radioOnLegBssid") is not False:
        row["rssiAsymDb"] = round(row["phoneRssi"] - row["apRssi"], 1)
    # Band the phone was actually on, from whichever side reported it
    row["bandSeen"] = row.get("apBand") or row.get("phoneBand")
    # Other clients' DHCP leases are routine noise (the 6.3 gateway logs ~70/hour); the phone's own lease
    # mid-leg is kept — it means the phone re-associated.
    macs = {re.sub(r"[^0-9a-f]", "", str(r.get("mac") or "").lower()) for r in ap_rows} - {""}
    ev = [e for e in events if t0 <= (e.get("ts") or 0) <= t1 and not (
        is_dhcp_lease(e) and not any(m in re.sub(r"[^0-9a-f]", "", event_text(e).lower()) for m in macs))]
    row["controllerEvents"] = len(ev)
    row["controllerEventText"] = " | ".join(event_text(e) for e in ev)[:400]
    # Server host health during the leg (sys.jsonl): kernel UDP drops would otherwise be blamed on the phone
    sysrows = [s for s in server.get("sys", []) if t0 <= (s.get("ts") or 0) <= t1]
    if len(sysrows) >= 2:
        def delta(k):
            a, b = num(sysrows[0].get(k)), num(sysrows[-1].get(k))
            return (b - a) if a is not None and b is not None else None
        drops = [d for d in (delta("udpInErrors"), delta("udpRcvbufErrors")) if d is not None]
        row["serverUdpDrops"] = sum(drops) if drops else None
        row["serverLoad1Max"] = max([num(s.get("load1")) for s in sysrows if num(s.get("load1")) is not None],
                                     default=None)
    row["grade"] = grade(row)
    return row


AP_SIGNAL_FIELDS = ("apMac", "apName", "channel", "rssi", "snr", "signalLevel", "rxRate", "txRate")


def WiFiBSSID(b):
    """aa:bb:cc:dd:ee:ff, lower case, zero-padded (iOS and Omada format MACs differently)."""
    parts = re.split(r"[:-]", str(b or "").lower())
    return ":".join(p.zfill(2) for p in parts) if len(parts) == 6 else str(b or "").lower()


def load_windows(udp):
    """[start, end] send-time windows of each speed test (probes tagged down/up), extended by
    LOAD_TAIL_MS while the queue drains."""
    out = []
    for r in udp:
        if r.get("ph") in ("down", "up") and num(r.get("sent")) is not None:
            if out and r["sent"] - out[-1][1] <= 1000:
                out[-1][1] = r["sent"]
            else:
                out.append([r["sent"], r["sent"]])
    return [(a, b + LOAD_TAIL_MS) for a, b in out]


def in_windows(ts, windows, before=0):
    return ts is not None and any(a - before <= ts <= b for a, b in windows)


def gaps_by_segment(udp, windows, loaded):
    """Runs without an echo inside each idle (or loaded) stretch of the leg. Stretches are cut at the
    window edges, so idle silence is never stretched across a speed test or vice versa."""
    segs, cur, prev_in = [], [], None
    for r in udp:
        inside = in_windows(r.get("sent"), windows)
        if prev_in is not None and inside != prev_in and cur:
            segs.append((prev_in, cur))
            cur = []
        cur.append(r)
        prev_in = inside
    if cur:
        segs.append((prev_in, cur))
    gaps = []      # (start, end) on the phone's send clock
    for inside, seg in segs:
        if inside != loaded:
            continue
        got = [r["sent"] for r in seg if r.get("rtt") is not None]
        if not got:
            gaps.append((seg[0]["sent"], seg[-1]["sent"]))
            continue
        gaps.extend(zip(got, got[1:]))
        gaps.append((seg[0]["sent"], got[0]))
        gaps.append((got[-1], seg[-1]["sent"]))
    return gaps


def tcp_frozen(tputs):
    """Wall-clock intervals ≥ GAP_STALL_MS in which a speed test's byte count did not grow."""
    out = []
    for t in tputs:
        t0, tl = num(t.get("startMs")), t.get("timeline") or []
        if t0 is None:
            continue
        pts = [(0.0, 0)] + [(p[0], p[1]) for p in tl if isinstance(p, list) and len(p) == 2]
        i = 0
        while i < len(pts) - 1:
            j = i
            while j + 1 < len(pts) and pts[j + 1][1] == pts[i][1]:
                j += 1
            # bytes flat from i to j; the next sample (if any) is where they grew again
            end = pts[j + 1][0] if j + 1 < len(pts) else pts[j][0]
            if end - pts[i][0] >= GAP_STALL_MS:
                out.append((t0 + pts[i][0], t0 + end))
            i = j + 1
    return out


def periodicity(starts):
    """If loss bursts recur at a steady interval, return it in seconds (e.g. scanning, rekeying)."""
    if len(starts) < 4:
        return None
    iv = [(b - a) / 1000 for a, b in zip(starts, starts[1:]) if b - a > 1500]
    if len(iv) < 3:
        return None
    m = statistics.mean(iv)
    if m > 0 and statistics.pstdev(iv) / m < 0.2:
        return round(m, 1)
    return None


def is_dhcp_lease(e):
    """Gateway DHCP lease log line. Helpers before 2026-10-05 redacted the event's type code ("key"), so
    fall back to the text."""
    rec = e.get("rec") or {}
    return rec.get("key") == "OSG_DHCP_S" or event_text(e).startswith("DHCP Server allocated")


def event_text(e):
    rec = e.get("rec") or {}
    for k in ("content", "msg", "message", "desc", "detail"):
        if isinstance(rec.get(k), str):
            return rec[k]
    return json.dumps(rec)[:120]


def idle_loss(r):
    """UDP loss % of the probes sent outside the speed tests (falls back to the whole leg)."""
    return r.get("udpLossPctIdle") if r.get("udpLossPctIdle") is not None else r.get("udpLossPct")


def idle_p95(r):
    return r.get("rttP95Idle") if r.get("rttP95Idle") is not None else r.get("rttP95")


def hb_idle(r):
    """Heartbeat failures outside the speed tests (falls back to all)."""
    return r.get("hbFailedIdle") if r.get("hbFailedIdle") is not None else r.get("hbFailed")


def grade(r):
    loss = idle_loss(r)
    if loss is None:
        return "red" if r.get("status") == "failed" else "none"
    p95 = idle_p95(r) or 9999
    hb = hb_idle(r)
    if loss >= LOSS_BAD or p95 >= P95_BAD or (hb or 0) >= 2 or (r.get("stallEvents") or 0) >= 1:
        return "red"
    if loss < LOSS_WARN and p95 < P95_WARN and not hb:
        return "green"
    return "yellow"


def band_mismatch(r):
    """A band-locked leg whose phone channel or AP radio says the other band: the phone was not on
    the network the leg claims (join drift, or the SSIDs were created on the wrong band)."""
    net, band = r["network"], r.get("bandSeen") or ""
    if net == "5G" and band.startswith("2.4"):
        return True
    if net == "2G" and band.startswith("5"):
        return True
    return False


# --------------------------------------------------------------------------- flags
def leg_flags(r, spot_legs, ctx=None):
    ctx = ctx or {}
    f = []
    net = r["network"]
    # INVALID-*: nothing else about this leg can be trusted, and it is excluded from the per-band tables
    if r.get("appBackgrounded"):
        return ["INVALID-app-backgrounded"]
    if (r.get("offTargetFrac") or 0) > OFF_TARGET_INVALID:
        return ["INVALID-left-target-ssid"]
    if band_mismatch(r):
        return ["INVALID-band-mismatch"]
    if r.get("offTargetSeconds"):
        f.append("left-target-ssid-%ds" % r["offTargetSeconds"])
    loss, ping = r.get("udpLossPct"), r.get("pingLossPct")
    if r.get("serverUnreachableAtStart"):
        f.append("server-unreachable-at-start")
    if r.get("selfAssignedIp"):
        f.append("self-assigned-ip")             # DHCP failed: a finding in itself (not a stall)
    if (r.get("udpSendErrors") or 0) >= 25:
        f.append("phone-had-no-route")           # ≥ 1 s of probes never left the phone
    server_lost = False
    if loss is not None and loss >= 50 and ping is not None:
        # Gateway still answering while the server doesn't = not a Wi-Fi problem (helper/server path).
        server_lost = ping < 5
        f.append("server-path-lost-gateway-ok" if server_lost else "link-dead")
    if server_lost:
        return f        # band and signal comparisons would blame the radio for a server-side outage
    if (r.get("serverUdpDrops") or 0) > 0:
        f.append("server-udp-drops")            # the server's kernel dropped UDP during this leg
    if (r.get("serverQueueP95Ms") or 0) >= SERVER_QUEUE_MS:
        f.append("server-queueing")             # probes waited in the server's socket buffer (host load)
    if (r.get("rttExcessOverPingMs") or 0) >= SERVER_EXCESS_MS and (r.get("pingP95") or 999) < 10:
        f.append("server-path-latency")          # UDP p95 far above the gateway ping: beyond the radio
    two = spot_legs.get("2G")
    if net == "5G" and two and two.get("grade") in ("green", "yellow"):
        weak = (r.get("phoneRssi") is not None and r["phoneRssi"] < RSSI_WEAK_PHONE)
        if r.get("grade") == "red" or weak:
            f.append("5G-worse-than-2G")
    # Lopsided link: relative to the survey's own median asymmetry (the AP's higher TX power and antenna
    # gain make a few dB of asymmetry normal everywhere), or the AP simply hears the phone badly.
    asym_cut = ASYM_DB if ctx.get("asymMedianDb") is None else max(ASYM_DB, ctx["asymMedianDb"] + ASYM_ABOVE_MEDIAN_DB)
    if (r.get("rssiAsymDb") or 0) >= asym_cut or (
            (r.get("apRssi") is not None and r["apRssi"] <= RSSI_WEAK_AP)
            and (r.get("phoneRssi") or -999) >= RSSI_WEAK_PHONE + 3):
        f.append("lopsided-link")
    if r.get("radioOnLegBssid") is False:
        f.append("radio-sample-off-bssid")       # Shortcut RSSI describes another AP/SSID than the probes
    up, down = r.get("upLossPct"), r.get("downLossPct")
    if up is not None and down is not None and up >= 1 and up >= UP_DOWN_RATIO * max(down, 0.01):
        f.append("loss-mostly-phone→AP")
    if (r.get("phoneRssi") or -999) >= -65 and ((idle_p95(r) or 0) >= P95_WARN or (r.get("jitterMs") or 0) >= 10
                                              or (idle_loss(r) or 0) >= LOSS_WARN):
        f.append("bad-despite-good-signal")
    if (idle_loss(r) or 0) < LOSS_WARN and (idle_p95(r) or 0) < P95_WARN and not r.get("stallEvents") and (
            (r.get("udpLossPctLoaded") or 0) >= LOSS_BAD or (r.get("rttP95Loaded") or 0) >= P95_BAD
            or (r.get("stallEventsLoaded") or 0) >= 1):
        f.append("degrades-under-load")          # clean when idle, bad during the speed tests: airtime/rate, not a stall
    if (r.get("roams") or 0) > 0:
        f.append("roamed-during-leg")
    if r.get("periodicLossSec"):
        f.append("periodic-loss-%ss" % r["periodicLossSec"])
    if (r.get("dnsFailed") or 0) >= 2 and (r.get("udpLossPct") or 0) < LOSS_WARN:
        f.append("dns-failures")
    if net == "DUAL":
        band = r.get("apBand") or r.get("phoneBand")
        if band and band.startswith("5") and two and grade_rank(r.get("grade")) > grade_rank(two.get("grade")):
            f.append("DUAL-chose-5G-and-did-worse-than-2G")
        others = {l.get("apName") for k, l in spot_legs.items() if k != "DUAL" and l.get("apName")}
        if r.get("apName") and others and r["apName"] not in others:
            f.append("DUAL-on-different-AP")
    if r.get("controllerEvents"):
        f.append("controller-events")
    return f


def grade_rank(g):
    return {"green": 0, "yellow": 1, "red": 2}.get(g, -1)


# --------------------------------------------------------------------------- walks and soaks
def analyze_walk(pkg, walk, arrivals_by_leg, clients, events, marks_by_leg, glitches):
    """A walk (moving) or soak (standing at `place`): continuous 10 pps UDP + 1 Hz heartbeat + 1 Hz BSSID.
    This is where stall *rates* come from, so report every stall with its time, every roam, and how the
    user's Glitch taps line up with them."""
    recs = pkg.raw.get(walk.get("rawFile") or "", [])
    by = defaultdict(list)
    for r in recs:
        by[r.get("k")].append(r)
    summ = walk.get("summary") or {}
    clock_off = num((summ.get("udp") or {}).get("clockOffsetMs")) or 0.0
    t0 = walk.get("startMs") or 0
    t1 = walk.get("endMs") or max([r.get("sent") or r.get("ts") or 0 for r in recs] or [t0])
    minutes = max((t1 - t0) / 60000.0, 0.0)
    row = {"walkId": walk["id"], "kind": "soak" if walk.get("place") else "walk", "place": walk.get("place"),
           "network": walk.get("network"), "start": ts_text(t0), "minutes": round(minutes, 1)}
    udp = sorted(by.get("udp", []), key=lambda r: r.get("seq", 0))
    stalls = []
    if udp:
        lost = [r for r in udp if r.get("rtt") is None]
        rtts = [r["rtt"] for r in udp if r.get("rtt") is not None]
        row.update(udpSent=len(udp), udpLossPct=pct(len(lost), len(udp)), rttP50=quant(rtts, 0.5),
                   rttP95=quant(rtts, 0.95), rttP99=quant(rtts, 0.99), rttMax=round(max(rtts), 1) if rtts else None,
                   rttOver100=sum(1 for x in rtts if x > 100), udpSendErrors=sum(1 for r in udp if r.get("se")))
        arrivals = arrivals_by_leg.get(walk["id"])
        if arrivals is not None:
            up = sum(1 for r in lost if r["seq"] not in arrivals)
            row.update(upLossPct=pct(up, len(udp)), downLossPct=pct(len(lost) - up, len(udp)), lossDirectionSource="server")
        gaps = gaps_by_segment(udp, [], loaded=False)
        stalls = sorted((a, b) for a, b in gaps if b - a >= GAP_STALL_MS)
        row.update(maxGapMs=round(max(b - a for a, b in gaps), 0) if gaps else None, stallEvents=len(stalls))
    hb = by.get("hb", [])
    if hb:
        row.update(hbSent=len(hb), hbFailed=sum(1 for r in hb if r.get("err")))
    # Wi-Fi timeline: roams (BSSID changes), time off the network, other SSIDs
    wifi = sorted((r for r in by.get("wifi", []) if not r.get("timeout")), key=lambda r: r.get("ts") or 0)
    roams = []
    prev = None
    for r in wifi:
        b = r.get("bssid")
        if b and prev and b != prev:
            roams.append((r["ts"], prev, b))
        if b:
            prev = b
    row.update(wifiSamples=len(wifi), roams=len(roams), bssids=" ".join(sorted({r["bssid"] for r in wifi if r.get("bssid")})),
               noWifiSeconds=sum(1 for r in wifi if not r.get("ssid")),
               ssidsSeen=" ".join(sorted({r.get("ssid") or "-" for r in wifi})),
               pathChanges=max(0, len(by.get("path", [])) - 1))
    # AP side (Omada), matched by the walk's IP(s) in server time
    ips = {m.get("ip") for m in marks_by_leg.get(walk["id"], [])} - {None}
    ap = [c for c in clients if c.get("ip") in ips and t0 + clock_off - 5000 <= (c.get("ts") or 0) <= t1 + clock_off + 5000]
    if not ap:
        ap = [dict(ts=r.get("ts"), c=r) for r in by.get("ap", [])]
    if ap:
        cs = [r.get("c") or {} for r in ap]
        timeline, last = [], None
        for r in ap:
            c = r.get("c") or {}
            key = (c.get("apName"), c.get("band"), c.get("channel"))
            if key != last:
                timeline.append("%s %s/%s ch%s" % (ts_text((r.get("ts") or 0) - clock_off)[11:], c.get("apName"), c.get("band"), c.get("channel")))
                last = key
        rs = [num(c.get("rssi")) for c in cs if num(c.get("rssi")) is not None]
        row.update(apTimeline=" → ".join(timeline), apRssiMin=min(rs) if rs else None, apRssiMax=max(rs) if rs else None,
                   apRssiMedian=med(rs), apSnrMedian=med([num(c.get("snr")) for c in cs]))
    # Stall rate: observed, or a 95 % upper bound when none were seen (Poisson: 3 events / exposure)
    if minutes > 0 and udp:
        n = len(stalls)
        row["stallsPerHour"] = round(60.0 * n / minutes, 1)
        row["stallsPerHour95Upper"] = round(60.0 * (3.0 if n == 0 else n + 2 * math.sqrt(n) + 1) / minutes, 1)
    # Glitch taps vs what the probes saw (±10 s)
    gl = [g for g in glitches if g.get("walkId") == walk["id"]]
    notes = []
    for g in gl:
        ts = g.get("ts") or 0
        near_stall = any(a - 10000 <= ts <= b + 10000 for a, b in stalls)
        near_roam = any(abs(rt - ts) <= 10000 for rt, _, _ in roams)
        seen = [x for x, hit in (("stall", near_stall), ("roam", near_roam)) if hit] or ["nothing-seen"]
        notes.append("%s:%s" % (ts_text(ts)[11:], "+".join(seen)))
    row.update(glitches=len(gl), glitchMatch=" ".join(notes))
    # Do stalls happen at roams? (the H4 test)
    row["stallsAtRoams"] = sum(1 for a, b in stalls if any(a - 5000 <= rt <= b + 5000 for rt, _, _ in roams))
    row["stallTimes"] = " ".join("%s(%.1fs)" % (ts_text(a)[11:], (b - a) / 1000) for a, b in stalls[:30])
    row["roamTimes"] = " ".join("%s" % ts_text(rt)[11:] for rt, _, _ in roams[:30])
    controller = [e for e in events if t0 + clock_off - 5000 <= (e.get("ts") or 0) <= t1 + clock_off + 5000
                  and not is_dhcp_lease(e)]
    row["controllerEvents"] = len(controller)
    return row


# --------------------------------------------------------------------------- config highlights
KEY_RE = re.compile(r"(channel|bandwidth|width|txpower|power|steer|roam|11r|fast|mesh|pmf|dfs|rssi|band|"
                    r"optimi|rogue|beacon|dtim|airtime|ofdma|mu-?mimo|twt|wifimode|security|version)", re.I)


def config_highlights(configs, limit=160):
    if not configs:
        return []
    name, snap = configs[-1]
    out = ["snapshot `%s` (reason: %s)" % (name, snap.get("reason"))]
    for ep, v in sorted((snap.get("endpoints") or {}).items()):
        if not v.get("ok"):
            continue
        for path, val in walk(v.get("data"), ep):
            if KEY_RE.search(path.split(".")[-1]) and not isinstance(val, (dict, list)):
                out.append("%s = %s" % (path, val))
                if len(out) >= limit:
                    return out
    return out


def walk(obj, prefix):
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from walk(v, "%s.%s" % (prefix, k))
    elif isinstance(obj, list):
        for i, v in enumerate(obj[:20]):
            label = v.get("name") if isinstance(v, dict) and isinstance(v.get("name"), str) else str(i)
            yield from walk(v, "%s[%s]" % (prefix, label))
    else:
        yield prefix, obj


# --------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("export", help="WiFiSurvey_*.zip or its unzipped folder")
    ap.add_argument("--out", help="output directory")
    args = ap.parse_args()
    pkg = Package(args.export)
    out = args.out or os.path.join(os.path.dirname(HERE), "analysis-out", pkg.name)
    os.makedirs(out, exist_ok=True)
    s = pkg.survey

    arrivals = defaultdict(set)
    for e in pkg.server.get("echo.jsonl", []):
        arrivals[e.get("leg")].add(e.get("seq"))
    marks_by_leg = defaultdict(list)
    for m in pkg.server.get("marks.jsonl", []):
        if m.get("legId"):
            marks_by_leg[m["legId"]].append(m)
    clients = pkg.server.get("client.jsonl", [])
    events = pkg.server.get("events.jsonl", [])
    echo_by_leg = defaultdict(list)
    for e in pkg.server.get("echo.jsonl", []):
        echo_by_leg[e.get("leg")].append(e)
    server = {"echo_by_leg": echo_by_leg, "sys": sorted(pkg.server.get("sys.jsonl", []), key=lambda s: s.get("ts") or 0)}

    legs, spots = [], []
    for room in s.get("rooms", []):
        for spot in room.get("spots", []):
            meas_list = spot.get("measurements", [])
            latest = next((m for m in reversed(meas_list) if m.get("status") == "complete"),
                          meas_list[-1] if meas_list else None)
            spot_rows = {}
            for m in meas_list:
                for leg in m.get("legs", []):
                    r = analyze_leg(pkg, leg, room, spot, m, arrivals, clients, events, marks_by_leg, server)
                    r["latest"] = latest is not None and m["id"] == latest["id"]
                    legs.append(r)
                    if r["latest"]:
                        spot_rows[leg["network"]] = r
            if spot_rows:
                spots.append((room, spot, spot_rows))
    # Survey-wide context the flags need: the typical phone-vs-AP RSSI asymmetry
    ctx = {"asymMedianDb": med([r.get("rssiAsymDb") for r in legs if r.get("latest")])}
    for _room, _spot, spot_rows in spots:
        for r in spot_rows.values():
            r["flags"] = " ".join(leg_flags(r, spot_rows, ctx))
    for r in legs:
        r.setdefault("flags", "")

    walks = [analyze_walk(pkg, w, arrivals, clients, events, marks_by_leg, s.get("glitches", []))
             for w in s.get("walks", [])]
    if walks:
        write_csv(os.path.join(out, "walks.csv"), walks)
    write_csv(os.path.join(out, "legs.csv"), legs)
    write_csv(os.path.join(out, "spots.csv"), [spot_row(room, spot, rows) for room, spot, rows in spots])
    summary = build_summary(pkg, legs, spots)
    summary["asymMedianDb"] = ctx["asymMedianDb"]
    summary["walks"] = walks
    with open(os.path.join(out, "summary.json"), "w") as f:
        json.dump(summary, f, indent=1)
    with open(os.path.join(out, "report.md"), "w") as f:
        f.write(render_report(pkg, legs, spots, summary))
    print("%d legs, %d spots -> %s" % (len(legs), len(spots), out))
    for k, v in summary["completeness"].items():
        print("  %-28s %s" % (k, v))
    for h, v in summary["flagCounts"].items():
        print("  flag %-40s %d" % (h, v))


SPOT_COLS = ("grade", "udpLossPct", "udpLossPctIdle", "upLossPct", "downLossPct", "rttP95", "rttP95Idle",
             "rttP95Loaded", "maxGapMs", "maxGapMsLoaded", "hbFailed", "hbFailedIdle", "phoneRssi", "apRssi", "rssiAsymDb", "apName", "apBand",
             "phoneChannel", "downMbps", "upMbps", "roams", "offTargetSeconds", "flags")


def invalid(r):
    return any(fl.startswith("INVALID") for fl in (r.get("flags") or "").split()) or r.get("appBackgrounded")


def spot_row(room, spot, rows):
    out = {"floor": room["floor"], "room": room["name"], "spot": spot["label"], "problem": spot.get("problem"),
           "symptom": spot.get("symptom", "")}
    for net in ("2G", "5G", "DUAL"):
        r = rows.get(net) or {}
        for c in SPOT_COLS:
            out["%s_%s" % (net, c)] = r.get(c)
    return out


def write_csv(path, rows):
    cols = []
    for r in rows:
        for k in r:
            if k not in cols:
                cols.append(k)
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for r in rows:
            w.writerow(r)


def build_summary(pkg, legs, spots):
    latest = [r for r in legs if r.get("latest") and not invalid(r)]
    per_net = {}
    for net in ("2G", "5G", "DUAL"):
        rs = [r for r in latest if r["network"] == net and r.get("udpSent")]
        if not rs:
            continue
        per_net[net] = {
            "legs": len(rs),
            "grades": dict(Counter(r["grade"] for r in rs)),
            "lossPctMedian": med([idle_loss(r) for r in rs]),
            "rttP95Median": med([idle_p95(r) for r in rs]),
            "rttP95LoadedMedian": med([r.get("rttP95Loaded") for r in rs]),
            "phoneRssiMedian": med([r.get("phoneRssi") for r in rs]),
            "apRssiMedian": med([r.get("apRssi") for r in rs]),
            "downMbpsMedian": med([r.get("downMbps") for r in rs]),
            "upMbpsMedian": med([r.get("upMbps") for r in rs]),
            "stallLegs": sum(1 for r in rs if (r.get("stallEvents") or 0) > 0 or (hb_idle(r) or 0) > 0),
            "apsUsed": dict(Counter(r.get("apName") for r in rs if r.get("apName"))),
        }
    flags = Counter()
    for r in latest:
        for fl in (r.get("flags") or "").split():
            flags[re.sub(r"-\d+(\.\d+)?s$", "", fl)] += 1
    s = pkg.survey
    completeness = {
        "rooms": len(s.get("rooms", [])),
        "spots measured": len(spots),
        "legs (all measurements)": len(legs),
        "legs with raw UDP": sum(1 for r in legs if r.get("udpSent")),
        "legs with loss direction": sum(1 for r in legs if r.get("lossDirectionSource")),
        "legs with phone radio": sum(1 for r in legs if r.get("radioSamples")),
        "legs with AP-side data": sum(1 for r in legs if r.get("apSamples")),
        "legs INVALID (app backgrounded)": sum(1 for r in legs if r.get("appBackgrounded")),
        "legs INVALID (left target SSID / band mismatch)": sum(
            1 for r in legs if any(x in (r.get("flags") or "") for x in ("INVALID-left", "INVALID-band"))),
        "legs with Wi-Fi samples off the target SSID": sum(1 for r in legs if r.get("offTargetSeconds")),
        "legs measured with the server unreachable": sum(1 for r in legs if r.get("serverUnreachableAtStart")),
        "legs where the probe socket was rebuilt": sum(1 for r in legs if r.get("reconnects")),
        "legs with server queue times (qUs)": sum(1 for r in legs if r.get("serverQueueP95Ms") is not None),
        "legs with server host health (sys.jsonl)": sum(1 for r in legs if r.get("serverLoad1Max") is not None),
        "clock offset |ms| max": max([abs(r.get("clockOffsetMs") or 0) for r in legs], default=0),
        "config snapshots": len(pkg.configs),
        "controller events": len(pkg.server.get("events.jsonl", [])),
        "walks": len(s.get("walks", [])),
        "glitches": len(s.get("glitches", [])),
        "attachments": len(pkg.attachments),
    }
    return {"survey": {k: s.get(k) for k in ("name", "createdAt", "finishedAt", "timeZone", "device", "notes")},
            "perNetwork": per_net, "flagCounts": dict(flags.most_common()), "completeness": completeness}


def fmt(v, unit="", nd=0):
    if v is None or v == "":
        return "–"
    if isinstance(v, float):
        v = round(v, nd) if nd else int(round(v))
    return "%s%s" % (v, unit)


GRADE_ICON = {"green": "🟢", "yellow": "🟡", "red": "🔴", "none": "⚪"}


def render_report(pkg, legs, spots, summary):
    s = pkg.survey
    L = []
    L.append("# WiFi survey — %s\n" % s.get("name"))
    L.append("%s → %s · %s · %s\n" % (s.get("createdAt"), s.get("finishedAt") or "not finished",
                                      (s.get("device") or {}).get("model"), (s.get("device") or {}).get("system")))
    if s.get("notes"):
        L.append("> %s\n" % s["notes"])
    L.append("## Data completeness\n")
    for k, v in summary["completeness"].items():
        L.append("- %s: **%s**" % (k, v))
    L.append("")
    L.append("## By band (newest valid measurement per spot; loss and p95 from idle probes)\n")
    L.append("| Network | Legs | Grades | Loss med % | p95 med ms | p95 loaded | Phone RSSI | AP-side RSSI | Down/Up Mbps | Legs with stalls | APs used |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for net, v in summary["perNetwork"].items():
        L.append("| %s | %d | %s | %s | %s | %s | %s | %s | %s / %s | %d | %s |" % (
            net, v["legs"], " ".join("%s%d" % (GRADE_ICON.get(g, g), n) for g, n in v["grades"].items()),
            fmt(v["lossPctMedian"], nd=2), fmt(v["rttP95Median"]), fmt(v.get("rttP95LoadedMedian")),
            fmt(v["phoneRssiMedian"]), fmt(v["apRssiMedian"]), fmt(v["downMbpsMedian"]), fmt(v["upMbpsMedian"]),
            v["stallLegs"], ", ".join("%s×%d" % kv for kv in v["apsUsed"].items()) or "–"))
    if summary.get("asymMedianDb") is not None:
        L.append("\nMedian phone-minus-AP RSSI asymmetry across spots: **%s dB** (`lopsided-link` flags spots ≥ %s dB above it)."
                 % (summary["asymMedianDb"], ASYM_ABOVE_MEDIAN_DB))
    L.append("")
    L.append("## Flags (newest measurement per spot)\n")
    if summary["flagCounts"]:
        for k, v in summary["flagCounts"].items():
            L.append("- `%s`: %d" % (k, v))
    else:
        L.append("- none")
    L.append("")
    by_floor = defaultdict(list)
    for room, spot, rows in spots:
        by_floor[room["floor"]].append((room, spot, rows))
    for floor, items in by_floor.items():
        L.append("## Floor: %s\n" % floor)
        L.append("| Room | Spot | 2.4 GHz | 5 GHz | Dual-band (what the phone chose) | Flags |")
        L.append("|---|---|---|---|---|---|")
        for room, spot, rows in items:
            label = spot["label"] + (" ⚠️" if spot.get("problem") else "")
            flags = sorted({fl for r in rows.values() for fl in (r.get("flags") or "").split()})
            L.append("| %s | %s | %s | %s | %s | %s |" % (room["name"], label, cell(rows.get("2G")),
                                                        cell(rows.get("5G")), cell(rows.get("DUAL"), dual=True),
                                                        " ".join("`%s`" % x for x in flags) or ""))
        L.append("")
    glitches = s.get("glitches", [])
    if glitches:
        L.append("## Glitch timeline\n")
        leg_by_id = {r["legId"]: r for r in legs}
        for g in sorted(glitches, key=lambda g: g.get("ts") or 0):
            r = leg_by_id.get(g.get("legId"))
            where = "%s · %s · %s" % (r["room"], r["spot"], r["network"]) if r else ("walk" if g.get("walkId") else "?")
            L.append("- %s — %s %s" % (ts_text(g.get("ts")), where, g.get("note") or ""))
        L.append("")
    walks = summary.get("walks") or []
    if walks:
        L.append("## Soaks and walks\n")
        L.append("Continuous logging (10 probes/s, 1 Hz heartbeat and BSSID). A stall = no echo for ≥ 2 s. With no stall "
                 "seen, the rate is given as a 95 % upper bound.\n")
        for w in walks:
            what = "Soak at **%s**" % w["place"] if w.get("place") else "Walk"
            L.append("### %s — %s, %s, %.1f min\n" % (what, w.get("network"), w.get("start"), w.get("minutes") or 0))
            rate = ("%s stalls/hour" % w["stallsPerHour"] if w.get("stallEvents")
                    else "no stalls — rate below %s/hour (95 %%)" % w.get("stallsPerHour95Upper"))
            L.append("- probes %s · loss %s%% (↑%s ↓%s) · RTT p50 %s / p95 %s / max %s ms · >100 ms: %s" % (
                w.get("udpSent"), fmt(w.get("udpLossPct"), nd=2), fmt(w.get("upLossPct"), nd=2), fmt(w.get("downLossPct"), nd=2),
                fmt(w.get("rttP50"), nd=1), fmt(w.get("rttP95"), nd=1), fmt(w.get("rttMax"), nd=1), w.get("rttOver100")))
            L.append("- stalls: **%s** (longest gap %s ms) · %s · heartbeat failures %s/%s" % (
                w.get("stallEvents"), fmt(w.get("maxGapMs")), rate, w.get("hbFailed"), w.get("hbSent")))
            L.append("- roams: **%s** · stalls at a roam: %s · BSSIDs %s · SSIDs %s" % (
                w.get("roams"), w.get("stallsAtRoams"), w.get("bssids") or "–", w.get("ssidsSeen") or "–"))
            if w.get("apTimeline"):
                L.append("- AP side: %s · RSSI %s…%s (median %s), SNR median %s" % (
                    w["apTimeline"], fmt(w.get("apRssiMin")), fmt(w.get("apRssiMax")), fmt(w.get("apRssiMedian")),
                    fmt(w.get("apSnrMedian"))))
            if w.get("stallTimes"):
                L.append("- stall times: %s" % w["stallTimes"])
            if w.get("glitches"):
                L.append("- Glitch taps: %s → %s" % (w["glitches"], w.get("glitchMatch")))
            L.append("")
    hl = config_highlights(pkg.configs)
    if hl:
        L.append("## Config highlights (latest snapshot; full JSON in server-data.zip)\n")
        L.append("```")
        L.extend(hl)
        L.append("```")
    if pkg.attachments:
        L.append("\n## Attachments\n")
        caps = {a["file"]: a.get("caption") for a in s.get("attachments", [])}
        for a in pkg.attachments:
            L.append("- `%s` %s" % (a, caps.get(a) or ""))
    return "\n".join(L) + "\n"


def cell(r, dual=False):
    if not r:
        return "–"
    bad = [fl for fl in (r.get("flags") or "").split() if fl.startswith("INVALID")]
    if r.get("appBackgrounded") or bad:
        return "⚪ %s; redo" % (bad[0] if bad else "INVALID — app was backgrounded")
    parts = [GRADE_ICON.get(r.get("grade"), "")]
    parts.append("loss %s%%" % fmt(idle_loss(r), nd=1))
    if r.get("upLossPct") is not None:
        parts.append("(↑%s ↓%s)" % (fmt(r.get("upLossPct"), nd=1), fmt(r.get("downLossPct"), nd=1)))
    parts.append("p95 %s" % fmt(idle_p95(r)))
    if r.get("rttP95Loaded") is not None:
        parts.append("(%s loaded)" % fmt(r.get("rttP95Loaded")))
    if r.get("stallEvents") or hb_idle(r):
        parts.append("stalls %s/%s" % (r.get("stallEvents") or 0, hb_idle(r) or 0))
    if r.get("phoneRssi") is not None or r.get("apRssi") is not None:
        parts.append("RSSI %s/%s" % (fmt(r.get("phoneRssi")), fmt(r.get("apRssi"))))
    if dual:
        parts.append("→ %s %s" % (r.get("apName") or "?", r.get("apBand") or r.get("phoneBand") or ""))
    return " ".join(parts)


def ts_text(ms):
    if not ms:
        return "?"
    import datetime
    return datetime.datetime.fromtimestamp(ms / 1000).strftime("%Y-%m-%d %H:%M:%S")


if __name__ == "__main__":
    sys.exit(main())
