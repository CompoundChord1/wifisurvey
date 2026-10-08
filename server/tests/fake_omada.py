"""A tiny stand-in for the Omada controller's web API, for testing the helper locally.

Serves plain HTTP. The shapes mimic controller 6.x closely enough to exercise the collector,
including a pre-shared key that the helper must redact.
"""
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

OMADAC = "fakeomadac123"
SITE = "site-abc"
TOKEN = "tok-123"
FAKE_PSK = "SuperSecretPSK-do-not-leak"
FAKE_DEVICE_PWD = "device-ssh-password-xyz"
# Secrets under awkward names: a bare "key", a numbered WEP key, an oddly named RADIUS field, an AP override.
ODD_SECRETS = ["PPSK-SECRET-bare-key", "WEPSECRET-numbered", "RADIUS-SECRET-odd-name", "OVERRIDE-PSK-on-ap",
               "WPS-SECRET-pin", "USERPASS-SECRET-short-marker"]
# A secret under a key no pattern could anticipate: only the canary scrub (SURVEY_PSK / CANARY_* in
# .omada.env) catches it.
CANARY_SECRET = "CANARY-SECRET-unguessable-key-name"
PHONE_IP = os.environ.get("FAKE_PHONE_IP", "127.0.0.1")


def ok(result):
    return {"errorCode": 0, "msg": "Success.", "result": result}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authed(self):
        return self.headers.get("Csrf-Token") == TOKEN

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        if self.path == "/%s/api/v2/login" % OMADAC:
            if body.get("username") == "viewer" and body.get("password") == "pw":
                return self.reply(ok({"roleType": 3, "token": TOKEN}))
            return self.reply({"errorCode": -30109, "msg": "bad credentials"})
        self.reply({"errorCode": -1, "msg": "nope"}, 404)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/info":
            return self.reply(ok({"controllerVer": "6.2.10.17", "apiVer": "3", "omadacId": OMADAC}))
        if not self.authed():
            return self.reply({"errorCode": -1200, "msg": "Login required"})
        p = path.replace("/%s/api/v2" % OMADAC, "")
        s = "/sites/%s" % SITE
        t = int(time.time() * 1000)
        if p == "/users/current":
            return self.reply(ok({"privilege": {"sites": [{"key": SITE, "name": "Home"}]}}))
        if p == s + "/clients":
            return self.reply(ok({"totalRows": 2, "data": [
                {"mac": "AA-BB-CC-DD-EE-01", "ip": PHONE_IP, "ssid": "SURVEY-5G", "wireless": True,
                 "apName": "AP_Living", "apMac": "02-00-00-00-00-A1", "radioId": 1, "channel": 44,
                 "rssi": -67, "snr": 28, "signalLevel": 70, "rxRate": 650000, "txRate": 780000, "wifiMode": 5,
                 "activity": 1200, "powerSave": False},
                {"mac": "AA-BB-CC-DD-EE-02", "ip": "192.168.2.44", "ssid": "HomeNet_IoT", "wireless": True,
                 "apName": "AP_Garage", "apMac": "02-00-00-00-00-A2", "radioId": 0, "channel": 6, "rssi": -71},
            ]}))
        if p == s + "/devices":
            return self.reply(ok([
                {"type": "ap", "mac": "02-00-00-00-00-A1", "name": "AP_Living", "model": "EAP650(US) v1.0"},
                {"type": "switch", "mac": "02-00-00-00-00-B1", "name": "sw", "model": "ES216G v1.0"},
            ]))
        if p.startswith(s + "/eaps/"):
            return self.reply(ok({"mac": p.rsplit("/", 1)[1], "name": "AP_Living",
                                  "wp2g": {"actualChannel": "6 / 2437MHz", "bandWidth": "20MHz", "txPower": 20,
                                           "txUtil": 5, "rxUtil": 9, "interUtil": 22},
                                  "wp5g": {"actualChannel": "44 / 5220MHz", "bandWidth": "80MHz", "txPower": 23,
                                           "txUtil": 7, "rxUtil": 4, "interUtil": 31},
                                  "clientNum2g": 11, "clientNum5g": 1,
                                  "ssidOverrides": [{"ssid": "HomeNet", "enable": True, "psk": ODD_SECRETS[3]}]}))
        if p == s + "/setting":
            return self.reply(ok({"bandSteering": {"enable": True, "mode": 1},
                                  "roaming": {"fastRoamingEnable": True, "aiRoamingEnable": True},
                                  "deviceAccount": {"username": "admin", "password": FAKE_DEVICE_PWD}}))
        if p == s + "/setting/wlans":
            return self.reply(ok({"data": [{"id": "wlan1", "name": "Default"}]}))
        if p == s + "/setting/wlans/wlan1/ssids":
            return self.reply(ok({"data": [
                {"name": "HomeNet", "band": 3, "security": 3, "enable11r": True, "pmfMode": 2,
                 "pskSetting": {"securityKey": FAKE_PSK, "versionPsk": 2, "encryptionPsk": 3},
                 "ppskProfiles": [{"name": "kids", "key": ODD_SECRETS[0]}],
                 "legacy": {"wepKey1": ODD_SECRETS[1]},
                 "enterpriseSetting": {"radiusServer": "10.0.0.5", "sharedValue": ODD_SECRETS[2]},
                 "wpsPin": ODD_SECRETS[4], "guestUserPass": ODD_SECRETS[5],
                 "magicValue": CANARY_SECRET, "magicList": ["plain", CANARY_SECRET + "-suffixed"]},
            ]}))
        if p == s + "/logs/events":
            return self.reply(ok({"data": [
                {"time": t - 5000, "content": "Client AA-BB-CC-DD-EE-01 roamed from AP_Garage to AP_Living"},
            ]}))
        return self.reply({"errorCode": -1001, "msg": "Invalid request"})


def start(port=18043):
    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


if __name__ == "__main__":
    start()
    print("fake omada on http://127.0.0.1:18043")
    while True:
        time.sleep(60)
