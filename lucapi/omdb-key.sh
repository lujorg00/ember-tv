#!/usr/bin/env bash
# Adds a free OMDb key to ember-feed, for the IMDb, Rotten Tomatoes and Metacritic scores on details pages.
# Get one at https://www.omdbapi.com/apikey.aspx (free, 1,000 a day), then run: bash lucapi/omdb-key.sh
set -euo pipefail
CFG=~/ember-feed/config.json
read -rsp "OMDb key, or the whole link from their email (not shown as you type): " KEY; echo
[ -n "$KEY" ] || { echo "Nothing entered."; exit 1; }
OMDB_KEY="$KEY" python3 - "$CFG" <<'PY'
import json, os, sys
p = sys.argv[1]
c = json.load(open(p)) if os.path.exists(p) else {}
import re
k = os.environ["OMDB_KEY"].strip()
m = re.search(r"apikey=([A-Za-z0-9]+)", k)   # the whole link from OMDb's email works too
c["omdb_key"] = m.group(1) if m else k
json.dump(c, open(p, "w"), indent=2)
os.chmod(p, 0o600)
PY
sudo systemctl restart ember-feed && echo "Saved. Scores will show on details pages."
