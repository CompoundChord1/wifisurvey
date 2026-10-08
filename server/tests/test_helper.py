#!/usr/bin/env python3
"""End-to-end test of the helper on localhost, against the fake Omada controller.

    python3 server/tests/test_helper.py

Starts the helper on high ports with a temp data dir, then exercises: UDP echo with injected
phone→server and server→phone loss, the /arrivals split, TCP down/up, the collector (phone record,
AP detail, events, config snapshot with redaction), /export and /survey-upload.
"""
import io
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fake_omada  # noqa: E402

UDP, HTTP, TCP = 19750, 19751, 19752
BASE_URL = "http://127.0.0.1:%d" % HTTP
failures = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        failures.append(what)


def http(method, path, body=None, raw=False, timeout=30):
    data = json.dumps(body).encode() if isinstance(body, (dict, list)) else body
    req = urllib.request.Request(BASE_URL + path, data=data, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        out = r.read()
    return out if raw else json.loads(out)


def udp_probe(leg, n, pps, skip_send, ignore_reply):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(0.001)
    got = {}
    sent_at = {}
    for seq in range(n):
        if seq not in skip_send:
            t = time.time() * 1000
            msg = {"l": leg, "s": seq, "t": t, "p": "x" * 120}
            sock.sendto(json.dumps(msg).encode(), ("127.0.0.1", UDP))
            sent_at[seq] = time.perf_counter()
        deadline = time.perf_counter() + 1.0 / pps
        while time.perf_counter() < deadline:
            try:
                data, _ = sock.recvfrom(4096)
            except socket.timeout:
                continue
            r = json.loads(data)
            if r["s"] in ignore_reply:
                continue
            got[r["s"]] = ((time.perf_counter() - sent_at[r["s"]]) * 1000, r.get("sr"))
    time.sleep(0.3)
    return got


def main():
    base = tempfile.mkdtemp(prefix="wifisurvey-test-")
    env = os.path.join(base, ".omada.env")
    with open(env, "w") as f:
        f.write("OMADA_URL=http://127.0.0.1:18143\nOMADA_USER=viewer\nOMADA_PASS=pw\n"
                "SURVEY_PSK=%s\n" % fake_omada.CANARY_SECRET)
    os.chmod(env, 0o600)
    fake_omada.start(18143)
    helper = os.path.join(os.path.dirname(HERE), "wifisurvey_helper.py")
    proc = subprocess.Popen([sys.executable, helper, "--bind", "127.0.0.1", "--base", base,
                             "--udp-port", str(UDP), "--http-port", str(HTTP), "--tcp-port", str(TCP)],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        for _ in range(50):
            try:
                h = http("GET", "/health")
                break
            except OSError:
                time.sleep(0.1)
        print("health / collector")
        check(h.get("ok") is True, "/health answers")
        t_start = time.time() * 1000
        http("POST", "/mark", {"event": "survey-start", "surveyId": "S1", "ip": fake_omada.PHONE_IP,
                               "phoneMs": t_start})
        http("POST", "/mark", {"event": "start", "surveyId": "S1", "legId": "L1", "network": "5G",
                               "ssid": "SURVEY-5G", "ip": fake_omada.PHONE_IP, "phoneMs": t_start})

        print("udp echo + loss split")
        up_lost = set(range(10, 15))      # never sent -> server never saw them
        down_lost = {20, 21, 22}          # server saw them, reply "lost"
        got = udp_probe("L1", 250, 25, up_lost, down_lost)
        a = http("GET", "/arrivals?leg=L1")
        arrived = set()
        for lo, hi in a["ranges"]:
            arrived.update(range(lo, hi + 1))
        lost = [s for s in range(250) if s not in got]
        up = [s for s in lost if s not in arrived]
        down = [s for s in lost if s in arrived]
        check(len(got) == 242, "242 of 250 echoes received (got %d)" % len(got))
        check(set(up) == up_lost, "phone→server loss identified: %s" % up)
        check(set(down) == down_lost, "server→phone loss identified: %s" % down)
        rtts = sorted(v[0] for v in got.values())
        check(rtts[len(rtts) // 2] < 20, "median loopback RTT %.2f ms" % rtts[len(rtts) // 2])
        check(all(v[1] for v in got.values()), "every echo carries server receive time")
        h = http("GET", "/health")
        check(h.get("canaries") == 1 and h.get("canaryHits", 0) >= 1,
              "/health shows the canary scrub armed and that it fired (%s/%s)" % (h.get("canaries"), h.get("canaryHits")))

        print("tcp throughput")
        s = socket.create_connection(("127.0.0.1", TCP))
        s.sendall(b"DOWN 2 L1\n")
        n, t0 = 0, time.time()
        while True:
            d = s.recv(1 << 20)
            if not d:
                break
            n += len(d)
        dt = time.time() - t0
        s.close()
        check(n > 10 * 1024 * 1024 and 1.5 < dt < 4, "download %.0f Mbps over %.2fs" % (n * 8 / dt / 1e6, dt))
        s = socket.create_connection(("127.0.0.1", TCP))
        s.sendall(b"UP 2 L1\n")
        buf = os.urandom(64 * 1024)
        sent, t0 = 0, time.time()
        while time.time() - t0 < 2:
            s.sendall(buf)
            sent += len(buf)
        s.shutdown(socket.SHUT_WR)
        reply = s.recv(200).decode()
        s.close()
        parts = reply.split()
        check(parts[0] == "OK" and int(parts[1]) == sent, "upload: server counted %s of %d bytes" % (parts[1], sent))

        print("collector (fake Omada)")
        rec = None
        for _ in range(40):
            st = http("GET", "/status?ip=" + fake_omada.PHONE_IP)
            if st.get("ok"):
                rec = st["c"]
                break
            time.sleep(0.5)
        check(rec is not None, "/status returns the phone's AP-side record")
        if rec:
            check(rec.get("apName") == "AP_Living" and rec.get("band") == "5GHz" and rec.get("rssi") == -67,
                  "compact record: %s %s rssi %s" % (rec.get("apName"), rec.get("band"), rec.get("rssi")))
        time.sleep(1.5)
        http("POST", "/mark", {"event": "end", "surveyId": "S1", "legId": "L1", "ip": fake_omada.PHONE_IP})
        http("POST", "/mark", {"event": "survey-end", "surveyId": "S1", "ip": fake_omada.PHONE_IP})
        time.sleep(2.5)

        print("export")
        z = zipfile.ZipFile(io.BytesIO(http("POST", "/export", {"surveyId": "S1", "fromMs": t_start,
                                                                "toMs": time.time() * 1000, "legs": ["L1"]},
                                            raw=True)))
        names = z.namelist()
        base_names = {n.split("/", 1)[1] for n in names}
        for want in ("echo.jsonl", "marks.jsonl", "throughput.jsonl", "client.jsonl", "radios.jsonl",
                     "events.jsonl", "helper.json"):
            check(want in base_names, "export has %s" % want)
        configs = [n for n in names if "/config-" in n]
        check(len(configs) >= 2, "config snapshots taken (%d)" % len(configs))
        blob = b"".join(z.read(n) for n in names)
        check(fake_omada.FAKE_PSK.encode() not in blob, "PSK never appears in exported data")
        check(fake_omada.FAKE_DEVICE_PWD.encode() not in blob, "device password never appears in exported data")
        for secret in fake_omada.ODD_SECRETS:
            check(secret.encode() not in blob, "oddly named secret never appears: %s" % secret.split("-", 1)[1])
        check(fake_omada.CANARY_SECRET.encode() not in blob, "canary secret under an unguessable key never appears")
        errs = [json.loads(l) for n in names if n.endswith("errors.jsonl") for l in z.read(n).splitlines()]
        canary_errs = [e for e in errs if e.get("where", "").startswith("canary")]
        check(canary_errs and all("magic" in e["error"] and fake_omada.CANARY_SECRET not in e["error"] for e in canary_errs),
              "canary hits reported by key path, never by value (%d hits)" % len(canary_errs))
        check("sys.jsonl" in base_names, "export has sys.jsonl (host load + kernel UDP drop counters)")
        snap = json.loads(z.read(configs[0]))
        ssids = snap["endpoints"].get("ssids:Default", {})
        check(ssids.get("ok") and ssids["data"]["data"][0]["pskSetting"]["securityKey"] == "<redacted>",
              "securityKey redacted in snapshot")
        check(snap["endpoints"]["siteSetting"]["data"]["bandSteering"]["enable"] is True,
              "band steering setting captured")
        ssid0 = ssids["data"]["data"][0]
        check(ssid0["pskSetting"]["versionPsk"] == 2 and ssid0["enable11r"] is True and ssid0["name"] == "HomeNet",
              "non-secret SSID settings survive redaction (WPA version, 802.11r, name)")
        echo_rows = [json.loads(l) for n in names if n.endswith("echo.jsonl") for l in z.read(n).splitlines()]
        check(len(echo_rows) == 245, "echo.jsonl has 245 arrivals (%d)" % len(echo_rows))
        q = [r.get("qUs") for r in echo_rows]
        check(all(isinstance(x, int) and 0 <= x < 500000 for x in q),
              "every arrival has a kernel->userspace queue time (median %s us)" % (sorted(q)[len(q) // 2] if q else None))
        radios = [json.loads(l) for n in names if n.endswith("radios.jsonl") for l in z.read(n).splitlines()]
        check(any(r["kind"] == "ap" and r["rec"]["wp5g"]["interUtil"] == 31 for r in radios), "AP radio detail logged")
        check(any(r["kind"] == "load" for r in radios), "per-radio client load logged")
        events = [json.loads(l) for n in names if n.endswith("events.jsonl") for l in z.read(n).splitlines()]
        check(any("roamed" in json.dumps(e) for e in events), "controller events logged")

        print("fault injection is off by default")
        try:
            http("POST", "/impair", {"upLoss": 0.5})
            refused = False
        except urllib.error.HTTPError as e:
            refused = e.code == 403
        check(refused, "/impair refused without --allow-impair")
        check("impair" not in http("GET", "/health"), "/health shows no impairment block on a normal instance")

        print("survey upload")
        r = http("POST", "/survey-upload?name=test.zip", b"PK-fake-zip-bytes" * 1000)
        check(r.get("ok") and os.path.getsize(r["path"]) == 17000, "upload saved (%s)" % r.get("path"))
    finally:
        proc.send_signal(signal.SIGTERM)
        try:
            out = proc.communicate(timeout=10)[0]
        except subprocess.TimeoutExpired:
            proc.kill()
            out = proc.communicate()[0]
        print("--- helper output ---\n" + out.strip())
        shutil.rmtree(base, ignore_errors=True)
    print("\n%s (%d failures)" % ("PASS" if not failures else "FAIL", len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
