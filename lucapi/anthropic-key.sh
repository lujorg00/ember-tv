#!/usr/bin/env bash
# Optional: lets Ember's search understand anything ("slow-burn Nordic crime shows", "films like Heat") by asking
# Claude (Anthropic's API, billed per use - a search costs a tiny fraction of a penny with the default model).
# Without a key, Ember still reads genres, decades, years and people itself.
# Make a key at https://console.anthropic.com (API keys), then run: bash lucapi/anthropic-key.sh
set -euo pipefail
CFG=~/ember-feed/config.json
read -rsp "Anthropic API key (not shown as you type; leave empty to remove it): " KEY; echo
ANTHROPIC_KEY="$KEY" python3 - "$CFG" <<'PY'
import json, os, sys
p = sys.argv[1]
c = json.load(open(p)) if os.path.exists(p) else {}
k = os.environ["ANTHROPIC_KEY"].strip()
if k:
    c["anthropic_key"] = k
else:
    c.pop("anthropic_key", None)
json.dump(c, open(p, "w"), indent=2)
os.chmod(p, 0o600)
print("Saved." if k else "Removed: search reads requests itself.")
PY
sudo systemctl restart ember-feed
