#!/bin/bash
# Copy the helper to ~/wifisurvey/ on your server (run from your Mac). Does not start it or touch the firewall.
# Usage: WIFISURVEY_HOST=user@192.168.1.10 server/deploy.sh
set -euo pipefail
HOST="${WIFISURVEY_HOST:?set WIFISURVEY_HOST=user@server first}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ssh "$HOST" 'mkdir -p ~/wifisurvey/runs ~/wifisurvey/surveys && chmod 700 ~/wifisurvey'
scp "$HERE/wifisurvey_helper.py" "$HERE/omada.py" "$HOST:~/wifisurvey/"
ssh "$HOST" 'cd ~/wifisurvey && python3 -m py_compile wifisurvey_helper.py omada.py && echo "helper deployed: $(pwd)" && ls -la'
cat <<NEXT

Next:
  1. Create ~/wifisurvey/.omada.env on the server (docs/OMADA-PREP.md §1), chmod 600.
  2. Open the helper's ports on the server's firewall, LAN only (server/README.md → Firewall).
  3. ssh $HOST 'cd ~/wifisurvey && python3 wifisurvey_helper.py --discover'
NEXT
