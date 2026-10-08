# Build the "WiFiSurvey Radio" Shortcut (one time, ~10 minutes)

iOS doesn't let apps read Wi-Fi signal strength, but the Shortcuts app can (iOS 17+, action
**Get Network Details**). The survey app runs this Shortcut after each network leg; it takes 10
readings a second apart and hands them back to the app automatically.

The name must be exactly **`WiFiSurvey Radio`** (or change the name in the app's survey settings).

## Steps

Open **Shortcuts** → **+** (new shortcut) → rename it `WiFiSurvey Radio` (tap the name at the top).

1. **Repeat** — search "Repeat", add it, set it to **10** times.

   Everything in steps 2–7 goes *inside* the Repeat block.

2. **Get Network Details** — add it **8 times**. It reads "Get **Wi-Fi** network's **Network Name**"; on each copy tap the blue detail word and pick, in this order:

   | # | Detail | (Network stays "Wi-Fi") |
   |---|---|---|
   | a | **RSSI** | |
   | b | **Noise** | |
   | c | **Channel Number** | |
   | d | **TX Rate** | |
   | e | **RX Rate** | |
   | f | **BSSID** | |
   | g | **Wi-Fi Standard** | |
   | h | **Hardware MAC Address** | (optional: this is the burned-in MAC, not the per-network private address the AP sees, so the helper matches the phone by IP instead) |

   Tip: build the first one, then long-press it → **Duplicate** seven times and change the detail on each copy.

3. **Date** — add the **Date** action (it defaults to *Current Date*).

4. **Format Date** — set **Date Format** to **ISO 8601** and turn **Include ISO 8601 Time** on.

5. **Text** — the most fiddly step. Build this one line, with `|` characters between the values:

   ```
   [Formatted Date]|[RSSI]|[Noise]|[Channel]|[TX]|[RX]|[BSSID]|[Standard]|[MAC]
   ```

   Insert each value as a variable, not typed text. Tap in the Text box → tap **Select Variable** in the
   bar above the keyboard → tap the matching action above (it highlights) → type `|` → repeat.
   All eight outputs are called "Network Details", so pick them **by position**: first copy (a) = RSSI,
   second copy (b) = Noise, and so on.

   *Alternative if Select Variable is awkward:* after each Get Network Details add **Set Variable**
   (named `rssi`, `noise`, `ch`, `tx`, `rx`, `bssid`, `std`, `mac`) and insert those named variables in the Text line.

6. **Add to Variable** — Variable name: `Samples`, input: the **Text** from step 5.

7. **Wait** — **1** second. *(still inside the Repeat)*

8. *(after* **End Repeat** *— if your output repeats lines in a growing pyramid of 55, this step is still inside the loop)* **Combine Text** — combine **Samples** with **New Lines**.

9. **Stop and Output** — output the **Combined Text**. If it asks what to do when there's nowhere to
   output, choose **Do Nothing**.

Done. The result should look like:

```
Repeat 10 times
    Get RSSI of Wi-Fi
    Get Noise of Wi-Fi
    Get Channel Number of Wi-Fi
    Get TX Rate of Wi-Fi
    Get RX Rate of Wi-Fi
    Get BSSID of Wi-Fi
    Get Wi-Fi Standard of Wi-Fi
    Get Hardware MAC Address of Wi-Fi
    Date: Current Date
    Format Date: ISO 8601 (with time)
    Text: [Formatted Date]|[RSSI]|[Noise]|[Channel Number]|[TX Rate]|[RX Rate]|[BSSID]|[Wi-Fi Standard]|[Hardware MAC Address]
    Add Text to Samples
    Wait 1 second
End Repeat
Combine Samples with New Lines
Stop and output Combined Text
```

## Test it

1. **Stop and Output shows nothing when you run the shortcut inside the Shortcuts app** — it hands its
   result to the caller (the survey app). To see it, temporarily add **Show Result** (*Combined Text*)
   just before Stop and Output, run it (~12 s), and expect ten lines like:
   `2025-01-01T12:00:00+00:00|-58|-94|44|864|720|aa:bb:cc:dd:ee:ff|802.11ax|12:34:56:78:9a:bc`
   Then **delete the Show Result**, or every spot will stop on a popup. If a single **Get Network Details
   (RSSI)** + **Show Result** comes back blank, set Location Services → Shortcuts to *While Using* with
   *Precise Location* on.
2. If iOS asks whether Shortcuts may use your location, allow it (while using). iOS needs this to show the BSSID.
3. In **WiFi Survey → Pre-flight → Run the Shortcut once**. The first time, iOS asks to open Shortcuts,
   then shows **"Allow 'WiFiSurvey Radio' to share output with WiFi Survey?"** — choose **Always Allow**
   (otherwise it asks at every spot). The check should turn green with "10 samples".

   *Verified 2026-09-29 in the iOS 26.5 Simulator: the action names above, the Select Variable bar, the
   share-output prompt, and the round trip back into the app. Also used on an iPhone running iOS 27.
   Apple renames Shortcuts actions between releases, so the pre-flight check is the real test.*

## If the app never gets the data back

Some iOS versions don't pass the Shortcut's output back through x-callback. Fallback — replace step 9 with:

9a. **URL Encode** the **Combined Text**.
9b. **Open URLs** → `wifisurvey://radio?data=` followed by the **URL Encoded Text** variable.

The app accepts both forms.
