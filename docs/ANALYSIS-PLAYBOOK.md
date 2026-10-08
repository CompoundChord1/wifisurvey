# Analysis playbook

Written for whoever analyzes a survey export — you, or an AI assistant you hand the export and this file to.

**Goal.** Explain why the network "stays connected but stalls" (or whatever the household reports), say
exactly what to change in the controller, then verify the fix with a re-test at the same spots.

## 1. Gather the inputs

| Input | Where |
|---|---|
| Export zip | AirDropped into `~/Downloads/WiFiSurvey_<name>_<stamp>.zip`. A copy may also be on the server at `~/wifisurvey/surveys/` |
| Floor-plan sketches, AirPort Utility scans | Inside the zip under `attachments/`. Captions are in `survey.json` → `attachments` |
| AP-side data, events, config snapshots | Inside the zip, in `server-data.zip`. If it's missing (helper unreachable at export), pull it: `scp -r user@server:~/wifisurvey/runs ./runs` |
| Network context | Your own notes: AP models and locations, controller version, what changed recently |

The data format is in `docs/SCHEMA.md`, and a copy is inside every export.

## 2. Run the numbers

```bash
python3 analysis/analyze.py ~/Downloads/WiFiSurvey_<name>_<stamp>.zip
```

This writes `analysis-out/<name>/`:

- `report.md` — start here.
- `spots.csv` — 2G / 5G / DUAL side by side for each spot.
- `legs.csv` — every leg, all metrics.
- `summary.json`

Everything is recomputed from raw data. The loss direction comes from the server's echo log, not the phone.

Then look at the floor-plan attachments, and map each room onto the sketch before judging any numbers.

## 3. Check data quality first

- **Loss direction:** `report.md` → *Data completeness*. "legs with loss direction" should equal "legs with raw UDP".
- **Phone radio:** "legs with phone radio" low means the Shortcut failed. Phone-side RSSI is then missing, and the asymmetry test is weaker.
- **AP-side data:** "legs with AP-side data" low means the collector wasn't matching the phone. Check `marks.jsonl` IPs against `client.jsonl`.
- **Clock offset:** clock offsets per leg (`survey.json` → `summary.udp.clockOffsetMs`) should be within ±1000 ms. Otherwise, shift the server timestamps before correlating events.
- **Duplicates:** spots measured twice — only the newest complete measurement counts (`latest=True` in `legs.csv`).
- **Cancelled or failed legs:** `status` ≠ complete. A *failed join* is itself evidence (association or DHCP trouble). It is not missing data.
- **Invalid legs** (excluded from the per-band table; re-measure the spot):
  - `INVALID-app-backgrounded`: iOS suspended the probes mid-leg.
  - `INVALID-left-target-ssid`: more than 20 % of the 1 Hz Wi-Fi samples were on another SSID — iOS auto-joined a sibling SURVEY network mid-leg, so the leg mixes bands. `left-target-ssid-Ns` (shorter) is a warning. Check `ssidsSeen` / `offTargetSeconds` in `legs.csv`.
  - `INVALID-band-mismatch`: a band-locked leg whose phone channel or AP radio says the other band (join drift, or the SSID was created on the wrong band). If this appears on many legs, check the SURVEY SSIDs in Omada before anything else.
- **Idle vs loaded probes:** grades, `loss`/`p95` in the report and the per-band table use the probes sent *outside* the 5 s speed tests (`udpLossPctIdle`, `rttP95Idle`). Probes during a speed test queue in the phone's own transmit buffer — that is load, not a stall. `rttP95Loaded` is reported next to it; `degrades-under-load` marks spots that are clean idle but bad under load (airtime / low PHY rate, not a stall). "Loaded" covers each speed test plus a 2 s tail while the phone's queue drains. Stall events (`stallEvents`, ≥ 2 s without an echo) and heartbeat failures used for grading (`hbFailedIdle`) are counted in idle time; a gap under load (`stallEventsLoaded`, `maxGapMsLoaded`) counts as a stall only if the speed test's TCP stream made no progress at the same time — a dead link stops TCP too, a full queue does not. `hbFailed` is still the total.
- **Phone radio vs probes:** `radio-sample-off-bssid` means the Shortcut (which runs ~12 s after the probes) saw another BSSID than the probes did; its RSSI is then not used for the asymmetry test.
- **The server itself:** `server-queueing` (probes waited ≥ 5 ms in the server's socket buffer, `qUs` in `echo.jsonl`), `server-udp-drops` (kernel UDP error counters rose during the leg, `sys.jsonl`) and `server-path-latency` (idle UDP p95 ≥ 20 ms above the gateway ping p95) all say the problem is beyond the radio. Treat loss direction and latency on such legs with suspicion.
- **DHCP:** `self-assigned-ip` (169.254.x.x) means the phone associated but never got a lease on that network — a finding in itself, not a stall. `phone-had-no-route` means probes failed to leave the phone (interface down).
- **Server path vs Wi-Fi:**
  - `server-unreachable-at-start` + `server-path-lost-gateway-ok`: the phone could ping the gateway but not reach the server. That is a helper or wired-path outage, **not** a Wi-Fi finding.
  - `link-dead`: the gateway was unreachable too. That is a real Wi-Fi outage.
- **`reconnects` > 0:** the probe socket had to be rebuilt (no echo for 3 s, or a socket error). Expected during real stalls. If it appears on otherwise clean legs, suspect the app, not the network.
- **Test runs:** `impair.jsonl` rows or `allowImpair: true` in `helper.json` mean the data came from a fault-injection run, not a survey.
- **Mark timing:** marks are delivered reliably but possibly late on a bad link. Use `phoneMs` (phone clock, plus the leg's clock offset) for timing, not the server `ts`.

## 4. Test each hypothesis

The data was designed to separate these. For each one, say **supported / not supported / can't tell** and cite spots.

| # | Hypothesis | Supporting evidence | Against |
|---|---|---|---|
| H1 | **5 GHz can't cover the house** (walls, floors), and band steering pushes clients onto it anyway | `5G-worse-than-2G` at many spots. 5G phone RSSI < −70 where 2G is fine. `DUAL-chose-5G-and-did-worse-than-2G` | 5G good wherever RSSI is good, yet stalls persist |
| H2 | **Lopsided link:** the AP transmits too loudly, and the AP can't hear the phone | `lopsided-link` (phone RSSI − AP-side RSSI ≥ 6 dB above the survey's median asymmetry, or AP-side ≤ −75 while phone-side ≥ −67). Some asymmetry is normal everywhere (AP TX power and antenna gain exceed the phone's); the report prints the median. `loss-mostly-phone→AP`. Low phone TX PHY rate | Symmetric RSSI. Loss mostly AP→phone |
| H3 | **Channel contention / co-channel interference** (several APs + neighbors on the same or overlapping 5 GHz channels, wide channels) | `bad-despite-good-signal` (RSSI ≥ −65 but p95 ≥ 30 ms, jitter ≥ 10 ms, or loss). The snapshot shows APs sharing a channel, 80/160 MHz width, high `interUtil` / busy in `radios.jsonl`, many neighbors in the AirPort Utility screenshots | Clean channels, low utilization |
| H4 | **Sticky client / roaming trouble** (802.11r, AI roaming, forced disassociation) | `roamed-during-leg`. Stalls or glitches cluster at BSSID changes. `DUAL-on-different-AP` (phone sits on a far AP). Walk-mode stalls at roams | No roams near stalls |
| H5 | **Automatic changes:** DFS radar, auto channel/power ("WLAN optimization"), off-channel rogue-AP scanning | Channel differs between config snapshots. Radar/channel events in `events.jsonl`. `periodic-loss-Ns` (loss bursts of ≥ 3 probes recurring at a steady interval, e.g. a scan) | Snapshots identical, no periodic pattern |
| H6 | **Wi-Fi 6 feature or firmware interop** (TWT, OFDMA, MU-MIMO, PMF on iOS) | Stalls with good RSSI, low utilization, symmetric link, often periodic. Worse on Wi-Fi 6 APs than on Wi-Fi 5 ones | Problem follows RSSI instead |
| H7 | **Not Wi-Fi at all** (DNS, wired path, server load) | `dns-failures` while UDP is clean. Gateway ping loss equals UDP loss everywhere. `server-queueing` / `server-udp-drops` / `server-path-latency` (`qUs` in `echo.jsonl`, `sys.jsonl`) | DNS clean. Problem differs by band. Gateway ping clean while UDP is bad is **not** H7 — it points beyond the gateway |
| H8 | **Local non-Wi-Fi interference at one spot** on one channel (motion sensors, wireless video, other 5 GHz devices the AP can't hear) | One spot (or a few metres around it) is bad on one 5 GHz channel and clean nearby; loss is almost all `up` (phone→AP); the AP still lists the phone with good RSSI/SNR but its upload bytes stop; 2.4 GHz and other 5 GHz channels are clean there; AirPort Utility shows no Wi-Fi network on that channel | The problem moves with the AP or follows RSSI, not the channel |

**Soaks and walks** (`walks.csv`, report section "Soaks and walks"): continuous 10 pps logging. Each row
gives loss by direction, RTT, stall events with their times, a stall rate (or a 95 % upper bound of 3 events
per exposure when none were seen), roams with times, `stallsAtRoams` (stalls within 5 s of a BSSID change —
the H4 test), the AP-side timeline, and how each Glitch tap lines up (`stall`, `roam`, or `nothing-seen`).
A soak has a `place`; a walk does not.

**What 45 s per band can and cannot see.** A 45 s leg catches a stall only if stalls come at least every few minutes (P ≥ 50 % per leg needs roughly one stall a minute). Rarer stalls show up, if at all, in the 3-minute DUAL legs at problem spots and in walk mode — so before trusting a "no stalls" verdict, check the soak legs and walks, and compare the stall rate they show with what the household reports.

**Why the gradual onset matters.** It points at things that drift: neighbor networks multiplying (H3), auto channel/power changes (H5), firmware updates (H6), and household client growth. Check the AP firmware versions in the snapshot, and compare the neighbor count in the scans.

**The Glitch! timeline** is ground truth for "stall felt here". For each glitch, look at the ±10 s window in that leg's `raw/<legId>.jsonl`:
- UDP gaps
- Heartbeat errors
- BSSID changes
- AP-side RSSI
- Controller events

## 5. Read the config (latest `config-*.json`; highlights in report.md)

For each AP and radio, record:
- channel, width, transmit power
- DFS or not
- client count
- mesh / uplink

For the site, record:
- band steering mode
- fast roaming, AI roaming, 802.11k/v
- min-RSSI / force disassociation
- rogue-AP scanning
- WLAN optimization schedule
- multicast settings

For the SSIDs: security version, PMF, 802.11r.

Things to spot:
- Two indoor APs on the same 5 GHz channel.
- 80/160 MHz width in a dense house.
- 2.4 GHz not on 1/6/11 at 20 MHz.
- 5 GHz power at maximum.
- Mesh enabled on wired APs.
- DFS channels.

## 6. Write the recommendations (the deliverable)

The write-up should contain:

1. **Verdict:** ranked causes with the evidence behind each (spot names, numbers).
2. **Floor-by-floor picture:** for each room, 2.4 vs 5 GHz grade, which AP served it, and phone/AP RSSI. Draw it on the floor-plan sketch where possible.
3. **Concrete Omada changes** with click paths, starting points to adjust by evidence:
   - 5 GHz channels non-overlapping per AP, mostly 40 MHz. Use 80 MHz only for isolated APs. Avoid DFS if radar or channel changes were seen.
   - If H8 holds, move every AP that serves that spot off the bad channel (and off its 80/160 MHz block), then re-soak the same spot.
   - 2.4 GHz on 1/6/11 at 20 MHz. Set 2.4 GHz power about 6 dB below 5 GHz.
   - Lower 5 GHz power if H2 holds. The target is AP-side RSSI of the phone within ~6 dB of the phone-side RSSI.
   - Band steering: disable, or keep "prefer 5 GHz" only where 5 GHz covers.
   - 802.11r / AI roaming: A/B test off if H4 holds.
   - Turn off rogue-AP scanning if H5 holds, and turn off scheduled WLAN Optimization before setting channels by hand (it re-plans channel, width and power on its own).
   - Wi-Fi 6 features: TWT/OFDMA off as an A/B test if H6 holds.
4. **Re-test plan:** one change at a time. After each, re-soak the worst spot (same app, same spot, same SSID), then re-measure the worst 6–10 spots on SURVEY-DUAL and compare with this survey.
5. **Caveats:**
   - One phone was measured.
   - Time of day matters.
   - Body position matters.
   - Omada rate units are as the controller reports them (often kbps).

## 7. Cleanup reminder

`server/README.md` → Cleanup:
- Delete the SURVEY SSIDs and the Viewer account.
- Shred `.omada.env`.
- Remove the firewall rules.
