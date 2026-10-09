# Notes for an AI coding assistant working in this repo

This repo is a Wi-Fi survey toolkit: an iPhone app (`ios/`), a LAN helper with a read-only Omada collector
(`server/`), and an analyzer (`analysis/`). The person you're helping wants to find out why their Wi-Fi
stalls. They will often be partway through setup or a survey, or holding an export zip.

## Rules

- **The controller is read-only.** The helper uses a Viewer account and only makes GET requests. Never add
  write calls to `server/omada.py`. Never change Omada settings yourself. When a change is needed, give
  the user the click path and let them make it.
- **One network change at a time.** After each change, re-soak the same spot on the same SSID and compare
  the results before suggesting the next change. Before the user changes anything, tell them how to undo it.
- **Secrets.** Never read, print or copy `~/wifisurvey/.omada.env`. It holds the controller password and the
  survey passphrase. If you need to know whether a key is set, check that the key name exists, for example
  `grep -c '^OMADA_URL=' ~/wifisurvey/.omada.env`, without printing any values. Never ask for or echo the
  survey passphrase.
- **Survey data is private.** Exports (`WiFiSurvey_*.zip`), `analysis-out/`, `runs/` and `surveys/` contain
  the user's MACs, BSSIDs, IPs, SSIDs, AP names and room names. Never commit them (`.gitignore` covers
  them), never paste them into an issue or a public post, and before anything is shared, offer to scrub it.
- **Never start a real helper with `--allow-impair`.** That flag is only for `tests/fault_injection.py`.
- **The helper's machine is often a headless server.** Before you change its firewall, check that you can
  still reach it over SSH. Only open the three ports to the LAN subnet, as `server/README.md` shows.

## Setting it up

The steps are in `README.md` → "Start here". The usual sticking points:

1. **`--discover` reports a TLS or certificate error.** The controller is on another host. Add
   `OMADA_INSECURE=1` to `.omada.env` (see `docs/OMADA-PREP.md` §1). Use the port the controller's web UI is on
   (8043 for the software controller; check yours for hardware controllers).
2. **The app can't reach the helper.** Check, in this order:
   - Is the helper running (`pgrep -af "[w]ifisurvey_helper"`)?
   - Is it bound to the server's LAN IP (`--bind`)?
   - Are the firewall rules in place?
   - Is the SURVEY SSID on the same VLAN as the server?
   - Run `curl http://<server>:9751/health` from another machine on the LAN.
3. **Pre-flight's Shortcut check fails.** Check the Shortcut's exact name, **Always Allow** on the
   share-output prompt, and *Precise Location* for Shortcuts. See `docs/SHORTCUT.md` → Test it.
4. **Xcode signing.** Set the Team. Both capabilities, Access Wi-Fi Information and Hotspot Configuration,
   must be present. A free Apple ID may not be able to sign them.

## Analyzing an export

1. Read `docs/ANALYSIS-PLAYBOOK.md` in full, and `docs/SCHEMA.md` for field meanings.
2. Run `python3 analysis/analyze.py <export.zip>`, then read `analysis-out/<name>/report.md`.
3. Check data quality before you draw any conclusion (playbook §3).
4. Ask the user for what the data can't tell you: where each AP is, the floor plan, which spots are the
   problem spots, and when the problem happens. Soaks record only the place name the user typed, so ask
   where a walk went.
5. Rank causes against the playbook's hypotheses (H1–H8) and cite the evidence for each: spot names,
   numbers, and the AP-side records.
6. Recommend changes one at a time, each with a re-test (playbook §6).

## Tests

```bash
python3 server/tests/test_helper.py
python3 analysis/tests/test_analyze.py
```

Neither test needs a network or a controller. `tests/fault_injection.py` needs Xcode and a booted Simulator.
