# WiFi Survey

A small toolkit for finding out *why* a Wi-Fi network "stays connected but stalls": an iPhone app that
measures room by room, a helper that runs on a server on your LAN, and an analyzer that merges the two.
Built for a home on **TP-Link Omada** (it reads AP-side data from the controller with a read-only account).

It was built to chase one problem: stalls whenever 5 GHz was enabled. In that house the cause turned out to be
**one 5 GHz channel (149) at one spot**, with all the loss going phone → AP while the phone still showed a good
connection. Moving the AP off that channel fixed it. The tooling is what made that visible; your cause will
probably be different.

| Part | What it does | Folder |
|---|---|---|
| iPhone app | Labels rooms and spots; switches between three test networks (2.4 GHz, 5 GHz, dual-band); measures loss split by direction, latency, stalls, DNS and speed; soak and walk modes; exports one zip | `ios/` |
| Helper | Python 3 stdlib, runs on any Linux box on the same LAN: UDP echo, speed-test endpoint, and a read-only Omada collector (AP-side signal, radio stats, events, config snapshots) | `server/` |
| Shortcut | The only way on iOS to read the phone's RSSI, noise, channel and PHY rates | `docs/SHORTCUT.md` |
| Analyzer | Merges phone and server data and flags likely causes | `analysis/analyze.py` |

## What you need

- A TP-Link **Omada** controller (used with controller 6.3; written against the 6.2/6.3 web API) and admin access to create a Viewer account and three temporary SSIDs.
  Without Omada the app and helper still work; you just lose the AP-side view.
- A Mac with **Xcode** and an Apple developer team to build and install the app on your own iPhone. It uses the Access Wi-Fi Information and Hotspot Configuration capabilities; it has only been built with a paid developer account, so a free Apple ID may not be able to sign it.
- An always-on Linux machine on the same LAN/VLAN as the test SSIDs, with Python 3.
- About an hour of setup, then 20-minute soaks at your problem spots.

## Start here

1. `docs/OMADA-PREP.md` — Viewer account and the three temporary SSIDs.
2. `server/README.md` — deploy and run the helper.
3. `docs/SHORTCUT.md` — build the "WiFiSurvey Radio" Shortcut.
4. `docs/FIELD-GUIDE.md` — build the app in Xcode, and how to survey.
5. After the survey: `docs/ANALYSIS-PLAYBOOK.md`.

The data format is in `docs/SCHEMA.md`, and a copy ships inside every export.

## The method, if you don't want the code

1. **Soak at the problem spot.** Stand still for 20 minutes on one band, then the other. Short spot tests miss
   stalls that come every few minutes.
2. **Split loss by direction.** Log every probe that reaches the server. "Never arrived" is phone → AP;
   "arrived but the echo was lost" is AP → phone. A phone that shows full bars can still be unable to transmit.
3. **Look at the AP side at the same time.** Upload bytes that stop while the client is still associated
   point at the phone's transmit side (often local interference it hears and the AP doesn't).
4. **Change one thing, re-soak the same spot.** Move the AP's channel, keep everything else the same.
5. **Check what the controller changes on its own.** Omada's scheduled WLAN Optimization re-plans channels,
   widths and power nightly and can undo a manual plan.

## Testing

- `python3 server/tests/test_helper.py` — helper end to end against a fake Omada controller (loss split,
  throughput, AP-side record, passphrase redaction, export and upload).
- `python3 analysis/tests/test_analyze.py` — analyzer against synthetic exports with known faults.
- `tests/fault_injection.py` — runs the app in the iOS Simulator against ten degraded-link scenarios
  (loss each direction, delay and jitter, a 6 s stall, port closed, helper restart / down / never started,
  periodic bursts, a stall during the speed test). Needs Xcode and a booted simulator.

Debug self-test (Simulator only): `xcrun simctl launch <udid> com.example.WiFiSurvey -selftest [helperHost]` writes
`Documents/selftest-result.json` and `selftest-export.zip` in the app's container.

## Caveats

- Shared as-is. It solved one house's problem; it isn't a product and there's no support.
- iPhone only. Used on an iPhone running iOS 27, and tested in the iOS 26.5 and 27 Simulators; Apple's Wi-Fi APIs and Shortcuts actions change between releases.
- The helper's Omada client uses the controller's web API with a **Viewer** account, read-only (GET only).
  Endpoint names differ between controller versions; `--discover` shows what yours answers.
- The test SSIDs share your main network's VLAN so the phone can reach the helper. Remove them afterwards.

## License

MIT — see `LICENSE`.
