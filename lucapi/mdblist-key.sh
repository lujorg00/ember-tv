#!/usr/bin/env bash
# Adds a free MDBList key to ember-feed: Rotten Tomatoes and Metacritic scores when OMDb hasn't got them
# (most series, many newer films). Get one: log in at https://mdblist.com (Trakt login works), open
# https://mdblist.com/preferences/, API Access, Copy. Then run: bash lucapi/mdblist-key.sh
set -euo pipefail
CFG=~/ember-feed/config.json
read -rsp "MDBList API key (not shown as you type): " KEY; echo
[ -n "$KEY" ] || { echo "Nothing entered."; exit 1; }
MDBL_KEY="$KEY" python3 - "$CFG" <<'PY'
import json, os, sys
p = sys.argv[1]
c = json.load(open(p)) if os.path.exists(p) else {}
c["mdblist_key"] = os.environ["MDBL_KEY"].strip()
json.dump(c, open(p, "w"), indent=2)
os.chmod(p, 0o600)
PY
sudo systemctl restart ember-feed && echo "Saved. Rotten Tomatoes scores will fill in on details pages."
