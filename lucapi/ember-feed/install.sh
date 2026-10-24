#!/usr/bin/env bash
# Installs ember-feed on lucapi. Run from this folder:  bash install.sh
set -euo pipefail

DEST=/home/luca/ember-feed
mkdir -p "$DEST"
cp feed.py ember-feed.service "$DEST"/
[ -f "$DEST/config.json" ] || cp config.example.json "$DEST/config.json"

python3 -m venv "$DEST/venv"
"$DEST/venv/bin/pip" install --quiet --upgrade pip
"$DEST/venv/bin/pip" install --quiet icalendar recurring-ical-events

PHOTOS=$(python3 -c "import json;print(json.load(open('$DEST/config.json'))['photos']['folder'])")
if [ -n "$PHOTOS" ]; then sudo mkdir -p "$PHOTOS" && sudo chown luca:luca "$PHOTOS"; fi

# Lets the service read docker container states (skip if you don't use docker).
if command -v docker >/dev/null && ! id -nG luca | grep -qw docker; then
  sudo usermod -aG docker luca
fi

sudo cp "$DEST/ember-feed.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ember-feed
sleep 2
systemctl --no-pager status ember-feed | head -5
echo
echo "Check it:  curl -s http://localhost:8090/status | python3 -m json.tool"
echo "Then edit $DEST/config.json (calendar URLs) and: sudo systemctl restart ember-feed"
