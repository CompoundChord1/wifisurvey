#!/usr/bin/env python3
"""Unit checks for analyze.py's per-leg maths and flag logic on synthetic exports.

    python3 analysis/tests/test_analyze.py

Builds small unzipped export folders (docs/SCHEMA.md) with known faults baked into the raw records and
checks that the analyzer recomputes the right numbers and raises the right flags — including the
validity flags (left the target SSID, band mismatch, app backgrounded) and the idle/loaded split.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
import io
import csv

HERE = os.path.dirname(os.path.abspath(__file__))
ANALYZE = os.path.join(os.path.dirname(HERE), "analyze.py")
failures = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        failures.append(what)


T0 = 1_790_000_000_000.0   # phone clock, ms


class Builder:
    """One survey with one room; add legs with `leg(...)`."""

    def __init__(self, root, clock_offset_ms=0.0):
        self.root = root
        self.off = clock_offset_ms
        os.makedirs(os.path.join(root, "raw"))
        self.spots = {}
        self.echo = []
        self.clients = []
        self.sys = []
        self.marks = []
        self.walks = []
        self.glitches = []
        self.t = T0

    def leg(self, spot, network, seconds=20, loss_seqs=(), up_loss_seqs=(), rtt=4.0, loaded_rtt=None,
            loaded_loss_seqs=(), ssid_timeline=None, phone_rssi=-58, phone_channel=None, ap_rssi=-66,
            ap_band=None, ap_name="AP_A", radio_bssid=None, backgrounded=False, send_error_seqs=(),
            ip="192.168.1.50", ping_rtt=2.0, qus=None, udp_drops=0, ssid=None, hb_fail_secs=(), tcp_freeze=None):
        """Default: 25 pps, download test at 10–15 s tags probes 'down'."""
        leg_id = "%s-%s-%d" % (spot, network, int(self.t))
        target = ssid or {"2G": "SURVEY-2G", "5G": "SURVEY-5G", "DUAL": "SURVEY-DUAL"}[network]
        start, end = self.t, self.t + seconds * 1000
        bssid = "aa:bb:cc:00:00:0%d" % (1 if network == "2G" else 2)
        if phone_channel is None:
            phone_channel = 6 if network == "2G" else 44
        if ap_band is None:
            ap_band = "2.4GHz" if network == "2G" else "5GHz"
        rows = [{"k": "leg", "id": leg_id, "network": network, "ssidTarget": target, "plannedSeconds": seconds,
                 "startMs": start},
                {"k": "join", "method": "hotspot", "requestMs": start, "ssidSeenMs": start, "ipMs": start,
                 "helperOkMs": start, "totalMs": 1200, "error": None}]
        n = seconds * 25
        for seq in range(n):
            sent = start + seq * 40
            ph = "down" if 10_000 <= seq * 40 < 15_000 else "idle"
            lost = seq in loss_seqs or seq in up_loss_seqs or (ph == "down" and seq in loaded_loss_seqs)
            r = {"k": "udp", "seq": seq, "sent": sent, "ph": ph,
                 "rtt": None if lost else (loaded_rtt if (ph == "down" and loaded_rtt) else rtt),
                 "sr": None if lost else sent + self.off + rtt / 2}
            if seq in send_error_seqs:
                r["se"] = True
            rows.append(r)
            if not (seq in up_loss_seqs or seq in send_error_seqs):     # reached the server
                self.echo.append({"ts": sent + self.off + rtt / 2, "leg": leg_id, "seq": seq, "src": ip,
                                  "sent": sent, "procUs": 40, "qUs": qus if qus is not None else 60})
        for i in range(seconds * 5):
            rows.append({"k": "ping", "seq": i, "sent": start + i * 200, "rtt": ping_rtt})
        for i in range(seconds):
            fail = i in hb_fail_secs
            rows.append({"k": "hb", "sent": start + i * 1000, "rtt": None if fail else 3.0,
                         "err": "timeout" if fail else None})
            s = (ssid_timeline[i] if ssid_timeline and i < len(ssid_timeline) else target)
            b = bssid if s == target else "aa:bb:cc:00:00:09"
            rows.append({"k": "wifi", "ts": start + i * 1000, "ssid": s, "bssid": b})
        if backgrounded:
            rows.append({"k": "app", "ts": start + 5000, "state": "background"})
        # download test at 10–15 s: [ms, cumulative bytes] every 250 ms; tcp_freeze=(a, b) holds bytes flat
        tl, got = [], 0
        for ms in range(250, 5001, 250):
            if not (tcp_freeze and tcp_freeze[0] < ms <= tcp_freeze[1]):
                got += 5_000_000
            tl.append([ms, got])
        rows.append({"k": "tput", "dir": "down", "startMs": start + 10_000, "endMs": start + 15_000,
                     "bytes": got, "mbps": got * 8 / 5e6, "mbpsSteady": None, "timeline": tl, "error": None})
        for i in range(10):
            rows.append({"k": "radio", "ts": end + 2000 + i * 1000, "rssi": phone_rssi, "noise": -92,
                         "channel": phone_channel, "txRate": 500, "rxRate": 400,
                         "bssid": radio_bssid or bssid, "standard": "802.11ax", "mac": None, "raw": ""})
        rows.append({"k": "end", "endMs": end, "status": "complete"})
        with open(os.path.join(self.root, "raw", leg_id + ".jsonl"), "w") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")
        # server side (server clock = phone + offset)
        for k in range(0, seconds, 5):
            ts = start + self.off + k * 1000
            self.clients.append({"ts": ts, "ip": ip, "mac": "AA-BB", "c": {
                "apName": ap_name, "band": ap_band, "channel": phone_channel, "rssi": ap_rssi, "snr": 26,
                "txRate": 400000, "rxRate": 300000, "trafficDown": 1000 * k, "uptime": 60 + k}, "rec": {}})
            self.sys.append({"ts": ts, "load1": 0.9, "udpInErrors": 0,
                             "udpRcvbufErrors": udp_drops if k >= 10 else 0})
        self.marks.append({"ts": start + self.off, "phoneMs": start, "event": "start", "legId": leg_id, "ip": ip})
        legobj = {"id": leg_id, "network": network, "ssidTarget": target, "plannedSeconds": seconds,
                  "startMs": start, "endMs": end, "status": "complete", "ip": ip,
                  "rawFile": "raw/%s.jsonl" % leg_id, "grade": "none", "glitchMs": [], "errors": [], "radio": [],
                  "join": {"method": "hotspot", "requestMs": start, "totalMs": 1200},
                  "summary": {"udp": {"clockOffsetMs": self.off}}}
        if backgrounded:
            legobj["interrupted"] = True
        self.spots.setdefault(spot, []).append(legobj)
        self.t = end + 20_000
        return leg_id

    def walk(self, minutes=10, place=None, stall_at_s=None, stall_s=3.0, roam_at_s=None, glitch_at_s=None,
             ip="192.168.1.43"):
        """A walk/soak: 10 pps UDP, 1 Hz heartbeat and BSSID; optional stall (probes lost both ways), roam, glitch."""
        wid = "walk-%d" % int(self.t)
        start = self.t
        n = int(minutes * 600)
        rows = [{"k": "leg", "id": wid, "network": "DUAL", "ssidTarget": "SURVEY-DUAL", "plannedSeconds": 0,
                 "startMs": start, "walk": True, "place": place}]
        for seq in range(n):
            sent = start + seq * 100
            lost = stall_at_s is not None and stall_at_s * 1000 <= seq * 100 < (stall_at_s + stall_s) * 1000
            rows.append({"k": "udp", "seq": seq, "sent": sent, "ph": "idle", "rtt": None if lost else 5.0,
                         "sr": None if lost else sent + self.off + 2.5})
            if not lost:
                self.echo.append({"ts": sent + self.off + 2.5, "leg": wid, "seq": seq, "src": ip, "sent": sent, "qUs": 50})
        for i in range(int(minutes * 60)):
            rows.append({"k": "hb", "sent": start + i * 1000, "rtt": 9.0, "err": None})
            b = "aa:bb:cc:00:00:02" if roam_at_s is None or i < roam_at_s else "aa:bb:cc:00:00:07"
            rows.append({"k": "wifi", "ts": start + i * 1000, "ssid": "SURVEY-DUAL", "bssid": b})
        end = start + minutes * 60000
        rows.append({"k": "end", "endMs": end, "status": "complete"})
        with open(os.path.join(self.root, "raw", wid + ".jsonl"), "w") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")
        self.marks.append({"ts": start + self.off, "event": "start", "legId": wid, "ip": ip})
        for k in range(0, int(minutes * 60), 5):
            self.clients.append({"ts": start + self.off + k * 1000, "ip": ip, "mac": "CC-DD", "c": {
                "apName": "AP_A" if roam_at_s is None or k < roam_at_s else "AP_B", "band": "5GHz", "channel": 44,
                "rssi": -72, "snr": 22}, "rec": {}})
        self.walks.append({"id": wid, "network": "DUAL", "startMs": start, "endMs": end,
                           "rawFile": "raw/%s.jsonl" % wid, "summary": {"udp": {"clockOffsetMs": self.off}}, "place": place})
        if glitch_at_s is not None:
            self.glitches.append({"ts": start + glitch_at_s * 1000, "walkId": wid, "note": ""})
        self.t = end + 20_000
        return wid

    def write(self):
        rooms = [{"id": "r1", "name": "Room", "floor": "Main", "notes": "", "createdAt": "2026-10-01T00:00:00Z",
                  "spots": [{"id": sp, "kind": "custom", "label": sp, "problem": False, "symptom": "",
                             "createdAt": "2026-10-01T00:00:00Z",
                             "measurements": [{"id": "m-" + sp, "startedAt": "2026-10-01T00:00:00Z",
                                               "endedAt": "2026-10-01T00:10:00Z", "status": "complete",
                                               "legs": legs}]}
                            for sp, legs in self.spots.items()]}]
        survey = {"schema": "wifisurvey/1", "id": "S", "name": "unit", "notes": "", "createdAt": "2026-10-01T00:00:00Z",
                  "finishedAt": None, "timeZone": "UTC", "app": {"version": "1", "build": "1"},
                  "device": {"model": "test", "system": "test"}, "settings": {}, "checklist": {},
                  "attachments": [], "rooms": rooms, "walks": self.walks, "glitches": self.glitches, "events": []}
        with open(os.path.join(self.root, "survey.json"), "w") as f:
            json.dump(survey, f)
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            # controller log: another client's DHCP lease in every leg (noise) and the phone's own lease in the second leg
            events = [{"ts": c["ts"] + 1000, "rec": {"key": "<redacted>" if i % 2 else "OSG_DHCP_S", "module": "Device",
                                                     "content": "DHCP Server allocated IP address 192.168.1.77 for the [client:02-00-00-00-00-C1 ]."}}
                      for i, c in enumerate(self.clients[::4])]
            events.append({"ts": self.clients[4]["ts"] + 2000, "rec": {"key": "OSG_DHCP_S", "module": "Device",
                           "content": "DHCP Server allocated IP address 192.168.1.50 for the [client:AA-BB ]."}})
            for name, rows in (("echo.jsonl", self.echo), ("client.jsonl", self.clients), ("sys.jsonl", self.sys),
                               ("marks.jsonl", self.marks), ("events.jsonl", events)):
                z.writestr("run1/" + name, "".join(json.dumps(r) + "\n" for r in rows))
            z.writestr("run1/helper.json", json.dumps({"version": "1.0", "run": "run1", "allowImpair": False}))
        with open(os.path.join(self.root, "server-data.zip"), "wb") as f:
            f.write(buf.getvalue())


def run(root):
    out = os.path.join(root, "out")
    p = subprocess.run([sys.executable, ANALYZE, root, "--out", out], capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit("analyze.py failed:\n" + p.stdout + p.stderr)
    with open(os.path.join(out, "legs.csv")) as f:
        legs = {r["legId"]: r for r in csv.DictReader(f)}
    with open(os.path.join(out, "summary.json")) as f:
        summary = json.load(f)
    with open(os.path.join(out, "report.md")) as f:
        report = f.read()
    return legs, summary, report


def f(row, key):
    try:
        return float(row.get(key, ""))
    except (TypeError, ValueError):
        return None


def main():
    base = tempfile.mkdtemp(prefix="wifisurvey-analyze-test-")
    try:
        b = Builder(os.path.join(base, "pkg"), clock_offset_ms=1500.0)   # server clock 1.5 s ahead
        clean = b.leg("clean", "2G")
        clean5 = b.leg("clean", "5G")
        # loaded-only degradation: idle probes perfect, the download window has 200 ms RTTs and loss
        bloat = b.leg("bloat", "2G")
        bloat5 = b.leg("bloat", "5G", loaded_rtt=220.0, loaded_loss_seqs=set(range(250, 350, 2)))   # 50 lost, none consecutive
        # tail drop under load: the download's queue overflows (60 consecutive probes, 2.4 s) and two
        # heartbeats time out behind it; idle probes perfect. Load, not a stall.
        tail2 = b.leg("taildrop", "2G")
        tail5 = b.leg("taildrop", "5G", loaded_rtt=400.0, loaded_loss_seqs=set(range(260, 320)), hb_fail_secs={11, 12})
        # a real stall while idle: 60 consecutive idle probes (2.4 s) and two heartbeats
        stall = b.leg("stall", "2G", loss_seqs=set(range(50, 110)), hb_fail_secs={2, 3})
        # a real stall during the download: probes lost AND the TCP stream frozen for the same 2.4 s
        frz = b.leg("frozen", "2G", loaded_loss_seqs=set(range(260, 320)), tcp_freeze=(400, 2800))
        # random 7 % loss: no bursts, so no rhythm
        import random
        rnd = random.Random(7)
        rand = b.leg("random", "2G", seconds=40, loss_seqs={q for q in range(1000) if rnd.random() < 0.07})
        # direction: 30 probes never reached the server (phone→AP), 5 echoes lost (AP→phone)
        direction = b.leg("dir", "2G", up_loss_seqs=set(range(100, 130)), loss_seqs={200, 201, 202, 203, 204})
        # drifted to SURVEY-2G for 8 of 20 s during the 5G leg
        drift5 = b.leg("drift", "5G", ssid_timeline=["SURVEY-5G"] * 12 + ["SURVEY-2G"] * 8)
        drift2 = b.leg("drift", "2G")
        # a brief 2 s drift only
        brief5 = b.leg("brief", "5G", ssid_timeline=["SURVEY-5G"] * 18 + ["SURVEY-2G"] * 2)
        brief2 = b.leg("brief", "2G")
        # 5G leg whose phone channel and AP radio say 2.4 GHz
        mismatch5 = b.leg("mismatch", "5G", phone_channel=11, ap_band="2.4GHz")
        mismatch2 = b.leg("mismatch", "2G")
        # app backgrounded
        bg = b.leg("bg", "2G", backgrounded=True)
        # lopsided: phone hears AP at -55, AP hears phone at -78 (asym 23 dB vs survey median 8)
        lop2 = b.leg("lop", "2G")
        lop5 = b.leg("lop", "5G", phone_rssi=-55, ap_rssi=-78)
        # Shortcut sampled on another BSSID than the probes
        offb = b.leg("offbssid", "5G", radio_bssid="de:ad:be:ef:00:01", phone_rssi=-50, ap_rssi=-80)
        # server path: idle UDP p95 45 ms while the gateway ping is 2 ms; server queueing 12 ms; kernel drops
        srv = b.leg("server", "5G", rtt=45.0, ping_rtt=2.0, qus=12000, udp_drops=7)
        # no route: 40 probes failed to send locally
        noroute = b.leg("noroute", "5G", send_error_seqs=set(range(0, 40)), up_loss_seqs=set(range(0, 40)))
        # 169.254 address
        apipa = b.leg("apipa", "5G", ip="169.254.10.9")
        # soak with a 3 s stall at the moment of a roam, a Glitch tap 4 s later; and a clean 20-min soak
        soak = b.walk(minutes=10, place="master bedroom", stall_at_s=120, roam_at_s=121, glitch_at_s=124)
        quiet = b.walk(minutes=20, place="office")
        b.write()
        legs, summary, report = run(b.root)

        print("idle / loaded split")
        c = legs[clean]
        check(f(c, "udpLossPct") == 0 and f(c, "udpLossPctIdle") == 0 and c["grade"] == "green", "clean leg is green")
        # 5 s download + 2 s queue-drain tail count as loaded
        check(f(c, "udpSentIdle") == 325 and f(c, "udpSentLoaded") == 175, "probe phases counted (%s idle, %s loaded)"
              % (c.get("udpSentIdle"), c.get("udpSentLoaded")))
        bl = legs[bloat5]
        check(bl["grade"] == "green", "bufferbloat only during the download does not grade the leg red (%s)" % bl["grade"])
        check("degrades-under-load" in bl["flags"], "…but is flagged degrades-under-load (%s)" % bl["flags"])
        check(f(bl, "rttP95Loaded") == 220 and f(bl, "rttP95Idle") == 4, "loaded p95 %s, idle p95 %s"
              % (bl.get("rttP95Loaded"), bl.get("rttP95Idle")))
        check("5G-worse-than-2G" not in bl["flags"], "load-only degradation is not called 5G-worse-than-2G")
        check(f(bl, "udpLossPct") == 10 and f(bl, "udpLossPctIdle") == 0,
              "headline loss %s%% vs idle loss %s%%" % (bl.get("udpLossPct"), bl.get("udpLossPctIdle")))

        t = legs[tail5]
        check(t["grade"] == "green" and f(t, "stallEvents") == 0 and f(t, "hbFailedIdle") == 0,
              "tail drop + heartbeat timeouts during the download are not a stall (grade %s, stalls %s, hb idle %s)"
              % (t["grade"], t.get("stallEvents"), t.get("hbFailedIdle")))
        check(f(t, "stallEventsLoaded") == 1 and f(t, "hbFailed") == 2 and "degrades-under-load" in t["flags"]
              and "5G-worse-than-2G" not in t["flags"], "…reported as loaded gap / degrades-under-load (%s)" % t["flags"])
        st = legs[stall]
        check(st["grade"] == "red" and f(st, "stallEvents") == 1 and f(st, "maxGapMs") >= 2400
              and f(st, "hbFailedIdle") == 2, "an idle 2.4 s stall is still red (gap %s, hb %s)"
              % (st.get("maxGapMs"), st.get("hbFailedIdle")))

        fz = legs[frz]
        check(fz["grade"] == "red" and f(fz, "stallEvents") == 1 and "degrades-under-load" not in fz["flags"],
              "a gap during the download with the TCP stream frozen is a stall (grade %s, stalls %s, %s)"
              % (fz["grade"], fz.get("stallEvents"), fz["flags"]))
        check(not legs[rand].get("periodicLossSec") and "periodic" not in legs[rand]["flags"],
              "random 7 %% loss is not called periodic (%s)" % legs[rand].get("periodicLossSec"))

        print("loss direction + clock offset")
        d = legs[direction]
        check(f(d, "upLossPct") == 6 and f(d, "downLossPct") == 1 and d["lossDirectionSource"] == "server",
              "direction from echo.jsonl: up %s%% down %s%%" % (d.get("upLossPct"), d.get("downLossPct")))
        check("loss-mostly-phone→AP" in d["flags"], "flagged loss-mostly-phone→AP")
        check(f(d, "apSamples") == 4 and f(c, "apSamples") == 4,
              "AP-side rows matched with a 1.5 s clock offset (%s rows)" % d.get("apSamples"))
        check(f(d, "apFreshSamples") == 1, "repeated controller signal values counted once, though traffic/uptime "
              "change every poll (%s fresh)" % d.get("apFreshSamples"))

        print("validity flags")
        check(legs[drift5]["flags"] == "INVALID-left-target-ssid", "5G leg that spent 40%% on SURVEY-2G is INVALID (%s)"
              % legs[drift5]["flags"])
        check(f(legs[drift5], "offTargetSeconds") == 8, "off-target seconds counted (%s)" % legs[drift5].get("offTargetSeconds"))
        check("left-target-ssid-2s" in legs[brief5]["flags"] and "INVALID" not in legs[brief5]["flags"],
              "a 2 s drift is a warning, not invalid (%s)" % legs[brief5]["flags"])
        check(legs[mismatch5]["flags"] == "INVALID-band-mismatch", "5G leg seen on 2.4 GHz is INVALID (%s)" % legs[mismatch5]["flags"])
        check(legs[bg]["flags"] == "INVALID-app-backgrounded", "backgrounded leg is INVALID")
        n5 = summary["perNetwork"]["5G"]["legs"]
        check(n5 == 9, "INVALID 5G legs excluded from the per-band table (%d of 11 kept)" % n5)
        check("INVALID-left-target-ssid; redo" in report, "report cell shows why the leg is invalid")

        print("signal flags")
        check(summary["asymMedianDb"] is not None and 5 <= summary["asymMedianDb"] <= 12,
              "survey median asymmetry computed (%s dB)" % summary["asymMedianDb"])
        check("lopsided-link" in legs[lop5]["flags"], "23 dB asymmetry flagged lopsided")
        check("lopsided-link" not in legs[clean5]["flags"], "the normal 8 dB asymmetry is not flagged")
        ob = legs[offb]
        check(ob["radioOnLegBssid"] == "False" and "radio-sample-off-bssid" in ob["flags"],
              "Shortcut sample on another BSSID flagged (%s)" % ob["flags"])
        check(ob.get("rssiAsymDb") in ("", None), "…and no asymmetry computed from it")

        print("server-path flags")
        s = legs[srv]
        check(f(s, "rttExcessOverPingMs") == 43 and "server-path-latency" in s["flags"],
              "UDP p95 43 ms above the gateway ping → server-path-latency")
        check(f(s, "serverQueueP95Ms") == 12 and "server-queueing" in s["flags"], "12 ms socket-buffer wait → server-queueing")
        check(f(s, "serverUdpDrops") == 7 and "server-udp-drops" in s["flags"], "kernel RcvbufErrors grew by 7 → server-udp-drops")
        check("bad-despite-good-signal" in s["flags"], "…and still bad-despite-good-signal (both are true)")
        check(legs[clean]["flags"] == "", "clean leg has no flags (%r)" % legs[clean]["flags"])
        check(f(legs[clean], "controllerEvents") == 0 and f(legs[clean5], "controllerEvents") == 1,
              "other clients' DHCP leases ignored, the phone's own lease kept (%s, %s)"
              % (legs[clean].get("controllerEvents"), legs[clean5].get("controllerEvents")))

        print("soaks and walks")
        ws = {w["walkId"]: w for w in summary["walks"]}
        w = ws[soak]
        check(w["kind"] == "soak" and w["place"] == "master bedroom" and w["stallEvents"] == 1 and w["maxGapMs"] >= 3000,
              "soak stall found (%s events, gap %s ms)" % (w["stallEvents"], w["maxGapMs"]))
        check(w["roams"] == 1 and w["stallsAtRoams"] == 1, "roam found and the stall attributed to it (%s/%s)"
              % (w["roams"], w["stallsAtRoams"]))
        check(w["glitches"] == 1 and "stall+roam" in w["glitchMatch"], "Glitch tap matched to the stall and roam (%s)"
              % w["glitchMatch"])
        check(w["downLossPct"] == 0 and w["upLossPct"] == 0.5, "loss direction from the server log (up %s, down %s)"
              % (w["upLossPct"], w["downLossPct"]))
        check("AP_A" in w["apTimeline"] and "AP_B" in w["apTimeline"], "AP-side timeline shows the roam (%s)" % w["apTimeline"])
        q = ws[quiet]
        check(q["stallEvents"] == 0 and q["stallsPerHour95Upper"] == 9.0,
              "clean 20-min soak: no stalls, 95 %% upper bound 9/hour (%s)" % q["stallsPerHour95Upper"])
        check("Soak at **master bedroom**" in report and "rate below 9.0/hour" in report, "report shows soaks with place and bound")

        print("phone-side faults")
        check(f(legs[noroute], "udpSendErrors") == 40 and "phone-had-no-route" in legs[noroute]["flags"],
              "40 local send failures → phone-had-no-route")
        check("self-assigned-ip" in legs[apipa]["flags"], "169.254 address flagged self-assigned-ip")
        comp = summary["completeness"]
        check(comp["legs with server queue times (qUs)"] == len(legs), "qUs read for every leg")
        check(comp["clock offset |ms| max"] == 1500, "clock offset reported (%s)" % comp["clock offset |ms| max"])
    finally:
        shutil.rmtree(base, ignore_errors=True)
    print("\n%s (%d failures)" % ("PASS" if not failures else "FAIL", len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
