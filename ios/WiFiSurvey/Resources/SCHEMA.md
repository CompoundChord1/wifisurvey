# WiFi Survey data format — `wifisurvey/1`

This is the contract between the iPhone app, the helper, and `analysis/analyze.py`.
A copy ships inside every export so whoever analyzes a survey (person or AI assistant) can read it cold.

## Export package

`WiFiSurvey_<name>_<YYYYMMDD-HHMM>.zip` unpacks to one folder:

| Path | What |
|---|---|
| `survey.json` | The survey document: settings, rooms → spots → measurements → legs, with per-leg summaries computed on the phone |
| `raw/<legId>.jsonl` | Every raw record for one leg (one network at one spot) |
| `raw/walk-<walkId>.jsonl` | Raw records for a walk-mode lap |
| `attachments/<id>.<ext>` | Floor-plan photos, AirPort Utility scan screenshots |
| `server-data.zip` | The helper's files for the survey window (see below). Missing if the server was unreachable at export |
| `SCHEMA.md` | This file |

## Conventions

- **Times.** `ts`, `sent`, `*Ms` fields are Unix epoch **milliseconds** (float). Phone-side values use the phone clock; server-side values (`sr`, and every `ts` in `server-data.zip`) use the server's clock. `clockOffsetMs` = server − phone, estimated per leg from the UDP echo (lowest-RTT decile). Human-facing dates are ISO-8601.
- **Networks.** `network` is a key: `2G` (SURVEY-2G, 2.4 GHz only), `5G` (SURVEY-5G, 5 GHz only), `DUAL` (SURVEY-DUAL, both bands, band steering decides). `ssidTarget` is the SSID the app tried to be on.
- **A leg** is one network measured at one spot. A **measurement** is one tap of a spot button (a rotation of legs). A spot can be re-measured; the newest `complete` measurement is the one to use.
- `null` means "not measured / not available", never zero.

## survey.json

```jsonc
{
  "schema": "wifisurvey/1",
  "id": "UUID", "name": "Whole house", "notes": "evening, TV streaming",
  "createdAt": "2026-10-03T18:02:11Z", "finishedAt": "…|null",
  "timeZone": "UTC",
  "app": {"version": "1.0", "build": "1"},
  "device": {"model": "iPhone17,1", "system": "iOS 26.0"},
  "settings": {
    "helperHost": "192.168.1.10", "udpPort": 9750, "httpPort": 9751, "tcpPort": 9752,
    "gateway": "192.168.1.1", "dnsName": "apple.com",
    "networks": [{"key": "2G", "ssid": "SURVEY-2G"}, {"key": "5G", "ssid": "SURVEY-5G"}, {"key": "DUAL", "ssid": "SURVEY-DUAL"}],
    "presets": {                       // legs run for each spot type
      "grid":    [{"network": "2G", "seconds": 45}, {"network": "5G", "seconds": 45}],
      "center":  [{"network": "2G", "seconds": 45}, {"network": "5G", "seconds": 45}, {"network": "DUAL", "seconds": 30}],
      "problem": [{"network": "2G", "seconds": 60}, {"network": "5G", "seconds": 60}, {"network": "DUAL", "seconds": 180}]
    },
    "probePps": 25, "probeBytes": 200, "pingPps": 5,
    "useShortcut": true, "shortcutName": "WiFiSurvey Radio",
    "throughputSeconds": 5, "downloadAt": 15, "uploadAt": 25, "skipThroughputMinutes": [],
    "settleSeconds": 3, "joinTimeoutSeconds": 30, "demoMode": false
  },
  "checklist": {"airplaneWifiOn": true, "bluetoothOff": true, "autoJoinOff": true, "privateAddressFixed": true, "lowPowerOff": true},
  "attachments": [{"id": "…", "file": "attachments/….jpg", "caption": "Floor plan – main", "roomId": null, "addedAt": "…"}],
  "rooms": [{
    "id": "…", "name": "Kitchen", "floor": "Main", "notes": "", "createdAt": "…",
    "spots": [{
      "id": "…", "kind": "N|E|S|W|C|custom", "label": "N", "problem": false, "symptom": "", "createdAt": "…",
      "measurements": [{
        "id": "…", "startedAt": "…", "endedAt": "…", "status": "running|complete|cancelled|failed",
        "headingDeg": 212.0, "headingAccuracyDeg": 12.0,
        "legs": [ /* Leg */ ]
      }]
    }]
  }],
  "walks": [{"id": "…", "network": "DUAL", "startMs": 0, "endMs": 0, "rawFile": "raw/walk-….jsonl", "summary": { /* LegSummary subset */ }, "place": "master bedroom" /* soaks only; absent for walks */}],
  "glitches": [{"ts": 0, "roomId": "…", "spotId": "…", "measurementId": "…", "legId": "…", "walkId": null, "note": ""}],
  "events": [{"ts": 0, "type": "preflight|snapshot|export|note", "detail": "…"}]
}
```

### Leg

```jsonc
{
  "id": "…", "network": "5G", "ssidTarget": "SURVEY-5G", "plannedSeconds": 45,
  "startMs": 0, "endMs": 0, "status": "complete|cancelled|failed|skipped",
  "join": {"method": "already|hotspot|manual|demo", "requestMs": 0, "ssidSeenMs": 0, "ipMs": 0,
           "helperOkMs": 0, "totalMs": 0, "error": null},
           // helperOkMs null + error "helper unreachable … measured anyway": the phone was on the
           // network but the server didn't answer within 10 s. The leg was still measured (expect ~100 % loss);
           // the gateway ping tells whether the Wi-Fi link itself was alive.
  "ip": "192.168.1.x",
  "rawFile": "raw/<legId>.jsonl",
  "grade": "green|yellow|red|none",
  "glitchMs": [0],
  "errors": ["…"],
  "interrupted": true,             // only present when the app was backgrounded mid-leg: the data has gaps that are NOT Wi-Fi. Discard the leg.
  "radio": [ /* RadioSample */ ],
  "summary": { /* LegSummary */ }
}
```

**Grade** (quick field feedback only; the analysis recomputes everything): green = UDP loss < 1 %, RTT p95 < 30 ms, no heartbeat failures. Red = loss ≥ 3 %, p95 ≥ 100 ms, ≥ 2 heartbeat failures, or the join failed. Yellow otherwise.

### LegSummary

```jsonc
{
  "wifi": {"ssids": ["SURVEY-5G"], "bssids": [{"bssid": "aa:bb:…", "seconds": 44}], "roams": 0, "noWifiSeconds": 0},
  "udp": {
    "sent": 1125, "received": 1119, "lossPct": 0.53,
    "upLost": 4, "downLost": 2, "unknownLost": 0,        // up = phone→AP never reached the server; down = reached the server, echo lost
    "upLossPct": 0.36, "downLossPct": 0.18,
    "late": 0, "dup": 0,
    "rtt": {"p50": 4.1, "p90": 9.8, "p95": 14.2, "p99": 61.0, "max": 212.0, "mean": 6.3},
    "jitterMs": 2.1,                                     // mean |Δrtt| between consecutive received probes
    "maxLossBurst": 3, "lossBursts3plus": 1,             // consecutive lost probes
    "clockOffsetMs": -12.4,
    "reconnects": 0,                                     // times a new probe socket was opened (no echo for 3 s, or a socket error); the old one keeps listening
    "sendErrors": 0,                                     // probes whose local send failed (no route): they never left the phone
    "idle":   {"sent": 0, "received": 0, "lossPct": 0, "rtt": {…}},   // probes sent outside the speed tests
    "loaded": {"sent": 0, "received": 0, "lossPct": 0, "rtt": {…}}    // probes sent during a speed test
  },
  "ping":      {"target": "192.168.1.1", "sent": 225, "received": 225, "lossPct": 0, "rtt": {…}},
  "heartbeat": {"sent": 45, "ok": 45, "failed": 0, "skipped": 0, "rtt": {…}},   // HTTP GET every 1 s, 2 s timeout
  "dns":       {"server": "192.168.1.1", "sent": 22, "ok": 22, "failed": 0, "rtt": {…}},
  "throughput": {
    "down": {"mbps": 212.4, "mbpsSteady": 230.1, "bytes": 0, "seconds": 5.0, "error": null},
    "up":   {"mbps": 180.0, "mbpsSteady": 181.0, "bytes": 0, "seconds": 5.0, "error": null},
    "skipped": null                                      // e.g. "quiet-window"
  },
  "radioStats": {"samples": 10, "rssiMedian": -58, "rssiMin": -61, "rssiMax": -55, "noiseMedian": -92,
                 "snrMedian": 34, "channels": [44], "standards": ["802.11ax"], "txRateMedian": 864, "rxRateMedian": 720,
                 "bssids": ["aa:bb:…"]},
  "apSide": {"samples": 9, "apName": "AP_Living", "apMac": "…", "radioId": 1, "band": "5GHz", "channel": 44,
             "rssiMedian": -67, "rssiMin": -70, "snrMedian": 28, "txRateMedian": 780, "rxRateMedian": 650}
}
```

`rtt` objects always have `p50 p90 p95 p99 max mean` (ms) or are `null` when nothing was received.
`mbpsSteady` ignores the first second (TCP ramp-up).

### RadioSample (from the Shortcut)

`{"ts": 0, "rssi": -58, "noise": -92, "channel": 44, "txRate": 864, "rxRate": 720, "bssid": "aa:bb:…", "standard": "802.11ax", "mac": "…|null", "raw": "…"}`
`ts` comes from the Shortcut's own timestamp when it parses, otherwise it is reconstructed (1 s apart, ending at the callback).

## raw/<legId>.jsonl

One JSON object per line; `k` is the record kind.

| `k` | Fields | Rate |
|---|---|---|
| `leg` | `id network ssidTarget plannedSeconds startMs` | first line |
| `join` | the Leg `join` object | once |
| `wifi` | `ts ssid bssid` — or `ts timeout:true` when iOS didn't answer in 1.5 s (not a disconnect) | 1 Hz |
| `app` | `ts state` — `background`/`foreground`; the app left the foreground mid-leg, so probes were suspended | on change |
| `path` | `ts status wifi cellular` | on change |
| `udp` | `seq sent rtt sr ph [se]` — `rtt` null = no echo; `sr` = server receive time; `ph` = `idle`/`down`/`up` (probes tagged `down`/`up` were sent during a speed test: judge stalls on the `idle` ones); `se: true` = the send itself failed, the probe never left the phone | one per probe (25/s), written at leg end |
| `ping` | `seq sent rtt` | 5/s |
| `hb` | `sent rtt err` | 1/s |
| `dns` | `sent rtt rcode err server` | every 2 s |
| `tput` | `dir startMs endMs bytes mbps mbpsSteady timeline[[ms,bytes]…] serverBytes serverSeconds error` | twice |
| `ap` | `ts` + the helper's `/status` record for this phone (AP-side view) | every 5 s |
| `radio` | a RadioSample | ~10 per leg |
| `glitch` | `ts note` | when tapped |
| `end` | `endMs status` | last line |

Walk files use the same kinds (`udp` is written every few seconds instead of at the end).

## server-data.zip (from the helper)

Entries are `<runId>/<file>`; a run is one helper start. JSONL lines are filtered to the survey window (±2 min).

| File | Fields |
|---|---|
| `helper.json` | helper version, run id, bind address, started |
| `config-<YYYYMMDD-HHMMSS>-<reason>.json` | Omada config snapshot: `{ts, reason, controller, site, endpoints: {name: {path, ok, errorCode, data}}}`. **Secrets are redacted** (`<redacted>`). Taken at helper start, survey start and survey finish |
| `marks.jsonl` | `ts phoneMs event surveyId measurementId legId network ssid bssid ip mac room spot` — `event` = `start`/`end`/`ip-change`/`phone-mac`/`survey-start`/`survey-end`/`glitch` |
| `echo.jsonl` | `ts leg seq src sent procUs qUs` — every probe that reached the server (`ts` = server receive). `qUs` = how long it waited in the kernel socket buffer before the helper read it (SO_TIMESTAMP; null if unavailable): the server load shows up here, not in `procUs` |
| `throughput.jsonl` | `ts leg dir bytes seconds src` |
| `client.jsonl` | `ts ip mac c rec` — the phone's Omada client record every ~5 s. `c` is a compact view: `apName apMac radioId band channel rssi snr signalLevel txRate rxRate wifiMode ssid activity powerSave`; `rec` is the full (redacted) record |
| `radios.jsonl` | `ts kind ap c rec` — `kind: "ap"` = full AP detail every ~30 s; `kind: "load"` = wireless client counts per AP radio |
| `events.jsonl` | `ts rec` — controller log entries (connect/disconnect/roam/channel/radar) |
| `sys.jsonl` | `ts load1 load5 udpInErrors udpRcvbufErrors udpInDatagrams canaryHits` — server host health every 5 s. A rise in the UDP error counters during a leg means the server itself dropped probes (they would otherwise be blamed on the phone's uplink) |
| `errors.jsonl` | `ts where error` — includes `canary …` rows when a secret listed in `.omada.env` (`SURVEY_PSK`, `CANARY_*`) was found under a key the pattern redaction missed; the row names the key path, never the value |
| `impair.jsonl` | `ts set state` — **only on test instances** started with `--allow-impair` (fault injection). If this file has rows, the run was a test, not a survey. `helper.json` has `allowImpair` |

Field names inside `rec` are whatever your controller version returns (written against 6.2/6.3); `c` is the stable subset the analysis relies on.
