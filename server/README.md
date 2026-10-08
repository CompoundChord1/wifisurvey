# Survey helper

Runs on an always-on Linux machine on the same LAN as the test SSIDs, only while you survey.
Python 3 stdlib — nothing to install. The examples below use `user@192.168.1.10` for that machine and
`192.168.1.0/24` for the LAN; substitute your own.

| Port | What |
|---|---|
| UDP 9750 | Echo. The phone sends 25 probes/s; every arrival is logged, so loss splits into phone→AP vs AP→phone |
| TCP 9751 | HTTP control: `/health` `/status` `/mark` `/arrivals` `/snapshot` `/export` `/survey-upload` |
| TCP 9752 | Throughput: 5 s download and 5 s upload per leg |

Omada access is a **read-only Viewer session** (GET only) to the URL in `.omada.env`. If the controller runs
on the same machine, use `https://127.0.0.1:8043`. For a controller on another host (OC200/OC300 or a separate
server), add `OMADA_INSECURE=1` to accept its self-signed certificate (see `docs/OMADA-PREP.md` §1).
Snapshots, client records and events are written with passphrases and passwords redacted — by field-name
pattern, plus a **canary scrub**: put the survey passphrase in `.omada.env` as `SURVEY_PSK=…` and any string
containing it is replaced wherever it appears. A hit is logged in `errors.jsonl` by key path (never value),
counted in `/health` (`canaryHits`), and means the pattern list needs that field name added.

Also written: `sys.jsonl` (load average and kernel UDP drop counters every 5 s) and `qUs` on every echo row
(how long a probe waited in the socket buffer before the helper read it) — so the server's own load can be
told apart from Wi-Fi loss and latency.

## Deploy (from your Mac)

```bash
WIFISURVEY_HOST=user@192.168.1.10 server/deploy.sh
```

This copies `wifisurvey_helper.py` and `omada.py` to `~/wifisurvey/` on the server and creates `runs/` and `surveys/`.
Then create `~/wifisurvey/.omada.env` (chmod 600) as described in `docs/OMADA-PREP.md` §1.

## Firewall (temporary, LAN only)

If the server's firewall denies inbound by default, allow the three ports from your LAN only. With ufw:

```bash
sudo ufw allow from 192.168.1.0/24 to any port 9750 proto udp comment wifisurvey
sudo ufw allow from 192.168.1.0/24 to any port 9751:9752 proto tcp comment wifisurvey
```

## Check Omada access once

```bash
cd ~/wifisurvey && python3 wifisurvey_helper.py --discover
```

This prints which API endpoints answer on your controller version and the *shape* of each result (never values).

Then, before you walk the house, read the controller's own history (redacted) — radar/DFS events,
channel changes, roams and disconnects over the last month are free evidence:

```bash
cd ~/wifisurvey && python3 wifisurvey_helper.py --dump-events 30
```

## Run (each survey session)

```bash
tmux new -A -s wifisurvey "cd ~/wifisurvey && python3 wifisurvey_helper.py --bind 192.168.1.10"
```

- `--bind` is the server's own LAN address. Detach with `Ctrl-b d`. Stop it with `Ctrl-c` inside tmux.
- It prints a status line every minute: echo packets, legs, whether the collector is polling.
- Data lands in `~/wifisurvey/runs/<start time>/`, with one run per start.
- The app's export pulls everything for the survey window automatically.

## Test locally (no server, no Omada)

```bash
python3 server/tests/test_helper.py
```

This runs an end-to-end test against a fake Omada controller. It checks:
- loss split by direction
- throughput
- the phone's AP-side record
- redaction of passphrases, including awkwardly named secret fields
- export and upload
- that fault injection is refused unless explicitly enabled

**Fault injection.** `--allow-impair` enables `POST /impair` (drop, delay, stall, close the UDP port) for the
suite in `tests/fault_injection.py`, which runs the app in a Simulator against degraded-link scenarios.
**Never start a real survey helper with it.** Without the flag the endpoint answers 403, and `/health` of a
test instance shows an `impair` block so it can't be mistaken for a real one.

## Cleanup (after the analysis and re-test)

On the server:

```bash
tmux kill-session -t wifisurvey; shred -u ~/wifisurvey/.omada.env
sudo ufw delete allow from 192.168.1.0/24 to any port 9750 proto udp
sudo ufw delete allow from 192.168.1.0/24 to any port 9751:9752 proto tcp
```

Then, in Omada:
- Delete SURVEY-2G, SURVEY-5G and SURVEY-DUAL.
- Delete the `wifisurvey-viewer` account.
- Revert any radio you turned on for the survey.

Keep `~/wifisurvey/runs` and `surveys/` if you want the evidence.
