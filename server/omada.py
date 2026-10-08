"""Read-only client for the Omada controller's web API (Viewer session).

Every call after login is a GET. On loopback the controller's self-signed certificate is accepted;
for a controller on another host set OMADA_INSECURE=1 (or give it a trusted certificate).
Endpoint paths (written against controller 6.2/6.3) are best-effort; `discover()` probes the
candidates and reports which ones answer, without printing any values.
"""
import http.cookiejar
import json
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

# String values under keys containing any of these are replaced with "<redacted>".
SECRET_MARKERS = (
    "password", "passwd", "pwd", "pass", "passphrase", "secret", "token", "securitykey",
    "psk", "community", "credential", "cookie", "privatekey", "presharedkey", "sharedkey",
)

RADIO_BANDS = {0: "2.4GHz", 1: "5GHz", 2: "5GHz-2", 3: "6GHz"}

# Compact client fields the analysis relies on (whatever subset the controller returns).
CLIENT_FIELDS = (
    "mac", "ip", "name", "hostName", "ssid", "apName", "apMac", "radioId", "channel", "rssi", "snr",
    "signalLevel", "signalRank", "rxRate", "txRate", "wifiMode", "activity", "powerSave", "uptime",
    "trafficDown", "trafficUp", "wireless", "vid", "healthScore",
    # seen on 6.3.x: per-client retry and packet counters (link-quality evidence for H3/H6)
    "txRetries", "downPacket", "upPacket",
)


# Keys that are or end in "key"/"pin" (key, wepKey1, apiKey, securityKey, wpsPin …) are treated as secrets too.
SECRET_KEY_RE = re.compile(r"(key|pin)\d*$")
# Under these keys every string is redacted, whatever its own name — credentials live here.
SENSITIVE_SUBTREE_RE = re.compile(r"(psk|wep|enterprise|radius|portal|credential|account|vpn|wireguard|ipsec|"
                                  r"l2tp|pptp|ddns|smtp|mail|snmp)", re.I)


def is_secret_key(k):
    kl = str(k).lower()
    return any(m in kl for m in SECRET_MARKERS) or SECRET_KEY_RE.search(kl) is not None


def redact(obj, _sensitive=False):
    """Replace secrets with "<redacted>". Deliberately over-redacts: numbers and booleans survive
    (WPA version, PMF mode …), strings under credential-bearing keys do not."""
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if isinstance(v, str):
                out[k] = "<redacted>" if v and (_sensitive or is_secret_key(k)) else v
            else:
                out[k] = redact(v, _sensitive or SENSITIVE_SUBTREE_RE.search(str(k)) is not None)
        return out
    if isinstance(obj, list):
        return ["<redacted>" if (_sensitive and isinstance(x, str) and x) else redact(x, _sensitive) for x in obj]
    return obj


def scrub(obj, canaries, _path="", _hits=None):
    """Belt and braces for `redact`: replace any string that *contains* a known secret (the survey
    passphrase, typed into .omada.env as SURVEY_PSK or CANARY_*) whatever key it sits under.
    Returns (scrubbed object, list of key paths where a canary was found). A hit means the
    pattern-based redaction missed a field name — report it, never the value."""
    if _hits is None:
        _hits = []
    if not canaries:
        return obj, _hits
    if isinstance(obj, dict):
        return {k: scrub(v, canaries, "%s.%s" % (_path, k), _hits)[0] for k, v in obj.items()}, _hits
    if isinstance(obj, list):
        return [scrub(v, canaries, "%s[%d]" % (_path, i), _hits)[0] for i, v in enumerate(obj)], _hits
    if isinstance(obj, str) and obj != "<redacted>" and any(c and c in obj for c in canaries):
        _hits.append(_path or ".")
        return "<redacted-canary>", _hits
    return obj, _hits


def canaries_from_env(env):
    """Secrets the helper must never write: SURVEY_PSK and any CANARY_* entry of .omada.env."""
    return [v for k, v in env.items() if v and (k == "SURVEY_PSK" or k.startswith("CANARY_"))]


def compact_client(rec):
    c = {k: rec.get(k) for k in CLIENT_FIELDS if k in rec}
    rid = rec.get("radioId")
    if isinstance(rid, int):
        c["band"] = RADIO_BANDS.get(rid, str(rid))
    return c


def norm_mac(mac):
    if not mac:
        return ""
    return re.sub(r"[^0-9a-f]", "", str(mac).lower())


def load_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


class OmadaError(Exception):
    pass


class OmadaClient:
    def __init__(self, url, username, password, site=None, timeout=10, insecure=False):
        self.base = url.rstrip("/")
        self.username = username
        self.password = password
        self.site_wanted = site
        self.timeout = timeout
        ctx = ssl.create_default_context()
        if insecure or urllib.parse.urlparse(self.base).hostname in ("127.0.0.1", "localhost", "::1"):
            # Omada controllers ship a self-signed certificate. Skipping verification is safe over loopback;
            # for another host it's an explicit opt-in (OMADA_INSECURE=1), meant for a trusted LAN.
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=ctx),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
        )
        self.omadac_id = None
        self.controller_ver = None
        self.token = None
        self.site_id = None
        self.site_name = None

    # -- transport -----------------------------------------------------------
    def _request(self, method, path, body=None, params=None, auth=True):
        url = self.base + path
        if params:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
        headers = {"Accept": "application/json"}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        if auth and self.token:
            headers["Csrf-Token"] = self.token
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with self.opener.open(req, timeout=self.timeout) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            raise OmadaError("HTTP %s on %s" % (e.code, path))
        try:
            return json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            raise OmadaError("non-JSON reply on %s (session expired?)" % path)

    # -- session -------------------------------------------------------------
    def login(self):
        info = self._request("GET", "/api/info", auth=False)
        res = info.get("result") or {}
        self.omadac_id = res.get("omadacId")
        self.controller_ver = res.get("controllerVer")
        if not self.omadac_id:
            raise OmadaError("controller /api/info had no omadacId")
        j = self._request("POST", "/%s/api/v2/login" % self.omadac_id,
                          body={"username": self.username, "password": self.password}, auth=False)
        if j.get("errorCode") != 0:
            raise OmadaError("login failed: errorCode=%s msg=%s" % (j.get("errorCode"), j.get("msg")))
        self.token = (j.get("result") or {}).get("token")
        if not self.token:
            raise OmadaError("login reply had no token")
        self._pick_site()

    def _pick_site(self):
        sites = []
        try:
            j = self.get_raw("/users/current")
            priv = ((j.get("result") or {}).get("privilege") or {})
            for s in priv.get("sites") or []:
                sites.append((s.get("key") or s.get("id"), s.get("name")))
        except OmadaError:
            pass
        if not sites:
            j = self.get_raw("/sites", params={"currentPage": 1, "currentPageSize": 100})
            for s in ((j.get("result") or {}).get("data") or []):
                sites.append((s.get("id") or s.get("key"), s.get("name")))
        if not sites:
            raise OmadaError("no sites visible to this account")
        chosen = sites[0]
        if self.site_wanted:
            for sid, name in sites:
                if self.site_wanted in (sid, name):
                    chosen = (sid, name)
        self.site_id, self.site_name = chosen

    def get_raw(self, path, params=None):
        return self._request("GET", "/%s/api/v2%s" % (self.omadac_id, path), params=params)

    def get(self, path, params=None):
        """GET with one automatic re-login when the session has expired."""
        try:
            j = self.get_raw(path, params)
            if j.get("errorCode") == 0:
                return j
        except OmadaError:
            pass
        self.login()
        return self.get_raw(path, params)

    def site_path(self, suffix):
        return "/sites/%s%s" % (self.site_id, suffix)

    # -- data ----------------------------------------------------------------
    def clients(self):
        j = self.get(self.site_path("/clients"),
                     {"currentPage": 1, "currentPageSize": 1000, "filters.active": "true"})
        return ((j.get("result") or {}).get("data") or [])

    def devices(self):
        j = self.get(self.site_path("/devices"))
        res = j.get("result")
        if isinstance(res, dict):
            res = res.get("data") or []
        return res or []

    def aps(self):
        return [d for d in self.devices() if str(d.get("type", "")).lower() == "ap"]

    def ap_detail(self, mac):
        return self.get(self.site_path("/eaps/%s" % mac)).get("result")

    # Candidates for the config snapshot. Paths the controller rejects are recorded as not-ok.
    def snapshot_candidates(self):
        c = {
            "devices": self.site_path("/devices"),
            "siteSetting": self.site_path("/setting"),
            "wlans": self.site_path("/setting/wlans"),
            "bandSteering": self.site_path("/setting/bandSteering"),
            "roaming": self.site_path("/setting/roaming"),
            "mesh": self.site_path("/setting/mesh"),
            "rogueApSetting": self.site_path("/setting/rogueAp"),
            "wlanOptimization": self.site_path("/wlanOptimization"),
            "rfPlanning": self.site_path("/rfPlanning"),
            "rogueAps": self.site_path("/insight/rogueAps?currentPage=1&currentPageSize=200"),
            "rogueAps2": self.site_path("/rogueAps?currentPage=1&currentPageSize=200"),
        }
        return c

    def event_candidates(self, start_ms, end_ms):
        q = "?currentPage=1&currentPageSize=200&filters.timeStart=%d&filters.timeEnd=%d" % (start_ms, end_ms)
        return [
            self.site_path("/logs/events" + q),
            self.site_path("/events" + q),
            self.site_path("/logs" + q),
            self.site_path("/logs/alerts" + q),
        ]

    def snapshot(self, reason):
        """Config snapshot: every candidate endpoint + per-WLAN SSIDs + per-AP detail. Redacted."""
        endpoints = {}
        for name, path in self.snapshot_candidates().items():
            endpoints[name] = self._probe(path)
        wl = endpoints.get("wlans", {}).get("data")
        wlan_list = []
        if isinstance(wl, dict):
            wlan_list = wl.get("data") or []
        elif isinstance(wl, list):
            wlan_list = wl
        for w in wlan_list:
            wid = w.get("id")
            if wid:
                endpoints["ssids:%s" % (w.get("name") or wid)] = self._probe(
                    self.site_path("/setting/wlans/%s/ssids" % wid))
        try:
            for ap in self.aps():
                mac = ap.get("mac")
                if mac:
                    endpoints["ap:%s" % (ap.get("name") or mac)] = self._probe(self.site_path("/eaps/%s" % mac))
        except OmadaError as e:
            endpoints["aps"] = {"ok": False, "error": str(e)}
        return {
            "ts": time.time() * 1000.0,
            "reason": reason,
            "controller": {"version": self.controller_ver},
            "site": {"name": self.site_name},
            "endpoints": endpoints,
        }

    def _probe(self, path):
        try:
            j = self.get_raw(path)
        except OmadaError as e:
            return {"path": path, "ok": False, "error": str(e)}
        ok = j.get("errorCode") == 0
        out = {"path": path, "ok": ok, "errorCode": j.get("errorCode")}
        if ok:
            out["data"] = redact(j.get("result"))
        else:
            out["msg"] = j.get("msg")
        return out

    def discover(self):
        """Print which endpoints answer and the shape of each result. Never prints values."""
        print("controller %s  site=%r" % (self.controller_ver, self.site_name))
        now = int(time.time() * 1000)
        paths = list(self.snapshot_candidates().items())
        paths.append(("clients", self.site_path("/clients?currentPage=1&currentPageSize=5&filters.active=true")))
        for i, p in enumerate(self.event_candidates(now - 3600000, now)):
            paths.append(("events%d" % i, p))
        try:
            for ap in self.aps()[:1]:
                paths.append(("apDetail", self.site_path("/eaps/%s" % ap.get("mac"))))
        except OmadaError as e:
            print("aps: %s" % e)
        for name, path in paths:
            r = self._probe(path)
            shape = describe(r.get("data")) if r.get("ok") else (r.get("error") or r.get("msg"))
            print("%-18s %-4s %s\n    %s" % (name, "OK" if r.get("ok") else "--", path, shape))


def describe(data, depth=0):
    """Shape of a JSON value: keys and types only, never values."""
    if isinstance(data, dict):
        if depth >= 2:
            # names only, so the analysis can be checked against the real field names
            return "{%d keys: %s}" % (len(data), ", ".join(str(k) for k in list(data)[:60]))
        return "{" + ", ".join("%s: %s" % (k, describe(v, depth + 1)) for k, v in list(data.items())[:40]) + "}"
    if isinstance(data, list):
        return "[%d × %s]" % (len(data), describe(data[0], depth + 1) if data else "")
    return type(data).__name__
