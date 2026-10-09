# Field guide — running the survey

## One-time setup (in this order)

1. **Omada prep:** `docs/OMADA-PREP.md`. Create the Viewer account and the SURVEY-2G / SURVEY-5G / SURVEY-DUAL networks.
2. **Helper:** `server/README.md`. Deploy it, add the firewall rules, and run `--discover` once.
3. **Shortcut:** `docs/SHORTCUT.md`. Build "WiFiSurvey Radio" and run it once from the Shortcuts app.
4. **App:** open `ios/WiFiSurvey.xcodeproj` in **Xcode** (built with Xcode 27; older versions are untested).
   - Select the WiFiSurvey target → **Signing & Capabilities**.
   - Set **Team** to your developer team.
   - Check that **Access Wi-Fi Information** and **Hotspot Configuration** are listed. Add them with **+ Capability** if not.
   - Choose your iPhone as the run destination and press **Run**. The first time, trust the developer profile if iOS asks (Settings › General › VPN & Device Management).
5. **In the app:** tap **+**, enter the helper's address (the server's LAN IP), your router's address, and the survey passphrase. Keep the other defaults, then tap **Create**.

## Every survey session

1. On the server, start the helper in tmux (`server/README.md` → Run).
2. Prepare the phone:
   - Airplane Mode **on**, then Wi-Fi back **on**.
   - Bluetooth **off**.
   - In Settings › Wi-Fi › (i), turn **Auto-Join off** for your own networks, so iOS doesn't hop back to them mid-measurement.
   - Low Power Mode off, and at least 50% charge.
3. Open the app, then the survey, then **Pre-flight**. Everything should be green:
   - Location: allow **Precise** location.
   - Test joining each network: iOS may ask to confirm each join, so tap **Join**.
   - After the first join to each SURVEY network: Settings › Wi-Fi › (i) › Private Wi-Fi Address = **Fixed**.
   - Run the Shortcut once. When asked "share output with WiFi Survey", choose **Always Allow**.

## Measuring a room

1. **Add room:** give it a name and a floor. Add notes such as brick wall, fridge, or "AP is in here, on the ceiling".
2. Walk to each point. **N / E / S / W** means about 3 ft in from the middle of that wall; **C** is the room's center.
3. How to hold the phone:
   - Chest height, portrait, screen toward you.
   - Don't cover the top edge.
   - At N/E/S/W, face the room's center. At C, face the door.
   - **Stand still** until it finishes.
4. Tap the point. The app switches networks, measures, and runs the Shortcut on its own. It takes about 2 minutes per point, or about 3 at Center.
5. Tap **GLITCH!** whenever something feels stuck, including while you're walking.
6. **Small rooms** (under about 10×10 ft, such as bathrooms or closets): measure **C** only.
7. **Problem spots:** on the room screen, tap **Problem spot**, name it ("couch, left end"), and describe the symptom. These run longer: 60 s per band plus 3 minutes on SURVEY-DUAL.

The dots on each point are 2G / 5G / DUAL quality:
- 🟢 good: loss under 1% and p95 latency under 30 ms
- 🟡 marginal
- 🔴 bad: loss of 3% or more, p95 latency of 100 ms or more, or stalls

They're for your feedback in the moment. The real analysis happens later.

## Also do once

- **Soak (do this first):** survey screen → **Walk / soak** → tap **DUAL** to join SURVEY-DUAL → type where you are in the "where are you?" box → **Start soak**. Stand still (or set the phone down) for 20 minutes with the app on screen; tap **GLITCH!** whenever something stalls. Repeat on **5G** at the same spot. This is the only way to measure how often stalls happen.
- **Walk:** same screen, leave the box empty → **Start walk**, then walk every floor for about 10 minutes at a normal pace. Linger where things usually go wrong. Forces roams, so it tests whether stalls happen at AP changes.
- **Neighbor scan, once per floor:**
  1. In iOS Settings › AirPort Utility, turn **Wi-Fi Scanner** on.
  2. In AirPort Utility: Wi-Fi Scan → Scan, for about 30 s.
  3. Take a screenshot.
  4. Attach it to that floor's center room: room screen → Photos & screenshots.
- **Floor plan:** a hand sketch per floor showing rooms (named as in the app), each AP (ceiling or wall, rough height), and notable walls or materials. Photograph it and attach it on the survey screen (Floor plans & screenshots).

## Time budget

| | Time |
|---|---|
| 5-point room at 45 s per band | ~13 min |
| Center only | ~3 min |
| Problem spot | ~6 min |
| Soak | 20 min per network |
| Walk | 10 min |

Split the survey across 2–3 sessions. It resumes exactly where you left off. Survey at the time of day when the problems usually happen, and note that in the survey notes.

## Finishing

1. **Finish & export** → **Finish survey**. This makes the helper take a closing config snapshot, which takes about 8 s.
2. **Build export** → **Share / AirDrop to the Mac**. The zip lands in ~/Downloads.
3. Optionally, **Also upload to the server** as a backup.
4. On the Mac, run `python3 analysis/analyze.py ~/Downloads/WiFiSurvey_….zip` and work through `docs/ANALYSIS-PLAYBOOK.md`. The playbook and `SCHEMA.md` (inside every export) are written so an AI assistant can also follow them (see README → Using an AI assistant). The export holds your network's identifiers; keep it private.
5. Only after the analysis and re-test:
   - **Remove survey networks from this iPhone**.
   - Turn Auto-Join back on for your home networks.
   - Do the cleanup steps in `server/README.md`.

## If something goes wrong

| Problem | Fix |
|---|---|
| "Couldn't switch automatically" | Open Settings › Wi-Fi, join the named SURVEY network, and come back. The app notices and continues. Or tap **Skip this network**. |
| Shortcut never returns | Come back to the app. After 90 s it moves on. Check the Shortcut's name, **Always Allow**, and the fallback in SHORTCUT.md. |
| "Can't reach the helper… Is it running?" (leg not measured) | The helper hasn't answered in the last 20 minutes. Start it (`server/README.md`), check the firewall rules, and run Pre-flight from a spot that works. Then measure here again. |
| "helper unreachable at the start of this leg — measured anyway" | Nothing to fix. The helper answered recently, so this spot simply can't reach it. That outage is recorded as the result (100% loss, red), and the gateway ping shows whether the Wi-Fi link itself was alive. |
| "The app left the foreground during this measurement" | iOS paused the probes, so the gaps aren't Wi-Fi stalls. Measure the spot again, and don't switch apps or lock the phone mid-measurement. The automatic hop to Shortcuts at the end is fine. |
| App closed mid-measurement | Everything up to the last finished network is saved. Re-measure that point. |
