#!/usr/bin/env bash
# Updates ember-feed on lucapi to the newest version from GitHub and restarts it.
# Run on the Pi:  bash ~/ember-feed-src/lucapi/feed-update.sh
set -euo pipefail
cd "$HOME/ember-feed-src"
git pull -q
cp lucapi/ember-feed/feed.py "$HOME/ember-feed/feed.py"   # the service runs this copy, not the one in ember-feed-src
sudo systemctl restart ember-feed
sleep 3
if curl -fsS -m 5 http://localhost:8090/client/log >/dev/null; then
  echo "ember-feed updated and running ($(git log -1 --format='%h %cd' --date=format:'%d %b %H:%M'))."
else
  echo "ember-feed didn't come back. Its log:"; sudo journalctl -u ember-feed -n 30 --no-pager
fi
