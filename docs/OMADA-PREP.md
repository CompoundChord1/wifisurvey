# Omada prep (in the controller UI — about 15 minutes)

Nothing here touches your existing SSIDs, so the household keeps working normally throughout.
"Your main SSID" below means the network that has the problem.

## 1. Temporary read-only account for the collector

1. Global View → **Accounts** (Admin accounts) → **Add**.
2. Username e.g. `wifisurvey-viewer`, a long random password, **Role: Viewer**, access to your site only.
3. On the server that runs the helper, put the credentials in a file only you can read:

   ```bash
   install -m 600 /dev/null ~/wifisurvey/.omada.env && nano ~/wifisurvey/.omada.env
   ```

   Contents:

   ```
   OMADA_URL=https://<controller address>:8043
   OMADA_USER=wifisurvey-viewer
   OMADA_PASS=<the password>
   SURVEY_PSK=<the SURVEY-* passphrase from §2>
   ```

   If the controller runs on the same machine as the helper, use `OMADA_URL=https://127.0.0.1:8043`.
   If it's elsewhere (an OC200/OC300, or another server), its self-signed certificate will fail
   verification; add `OMADA_INSECURE=1` to accept it. Only do that on your own LAN. `OMADA_SITE=<name>`
   picks a site if the controller has more than one.

   `SURVEY_PSK` arms the helper's canary scrub: if the controller returns that passphrase under a field
   name the redaction patterns don't know, it is scrubbed anyway and the field name is logged.

4. Check it (prints which API endpoints answer and their *shape* — never values):

   ```bash
   cd ~/wifisurvey && python3 wifisurvey_helper.py --discover
   ```

   It confirms the endpoint names on your controller version and whether the 5 GHz radios
   are currently on at the AP level.

## 2. Three temporary survey networks

Settings → **Wireless Networks** → your WLAN group → **Create New Wireless Network**, three times:

| SSID | Band | Notes |
|---|---|---|
| `SURVEY-2G` | 2.4 GHz only | |
| `SURVEY-5G` | 5 GHz only | |
| `SURVEY-DUAL` | 2.4 GHz **and** 5 GHz | reproduces your main SSID's dual-band setup |

For all three:

- **Network / VLAN:** the same one as your main SSID, so the phone reaches the helper directly.
- **Security:** WPA-Personal with the same version/encryption as your main SSID, and one **long random passphrase** shared by all three. You'll type it once into the app; the app keeps it in the iPhone Keychain.
- **Advanced settings: copy your main SSID exactly** — 802.11r / fast transition, PMF, multicast/broadcast
  management, rate limits (none), SSID broadcast on. The only intended difference between the three is the band.
- Site-wide features (band steering, roaming, mesh, channel/power) are not per-SSID, so SURVEY-DUAL
  automatically behaves like your main SSID does.

**5 GHz radios:** if you turned 5 GHz off at the *radio* level (Devices → AP → Config → Radios), SURVEY-5G
and SURVEY-DUAL will have nowhere to broadcast. Turn the 5 GHz radio back on for each AP for the survey
window. The `--discover` output tells you which case you're in.

**Per-AP tests:** Devices → AP → Config → WLANs lets you turn one SSID off on one AP. Turning SURVEY-5G off on
the AP a problem spot uses forces the phone onto another AP (and channel) without touching the household.

## 3. Freeze everything else

Until the survey is done, **don't change channels, power, band steering, roaming or firmware** — you're
measuring today's configuration. The helper snapshots the full config at start and finish, so any drift
(including automatic channel changes) will show up in the data. Check whether **WLAN Optimization** has a
schedule; it can re-plan channels, widths and power overnight.

## Cleanup (after the analysis)

Delete the three SURVEY networks and the `wifisurvey-viewer` account; revert any radio you turned on;
on the server `shred -u ~/wifisurvey/.omada.env`. Full list: `server/README.md` → Cleanup.
