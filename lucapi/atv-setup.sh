#!/usr/bin/env bash
# Sets up atvloadly on lucapi: the web page that installs Ember on the Apple TV and re-signs it every week
# (a free Apple ID's apps stop opening after 7 days unless they're refreshed).
# Run on the Pi:  bash ~/ember-feed-src/lucapi/atv-setup.sh      Then open http://192.168.4.141:5533
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "Installing Docker…"
  curl -fsSL https://get.docker.com | sudo sh
fi

# atvloadly finds and pairs with the Apple TV through the Pi's avahi (Bonjour) service
echo "Making sure avahi-daemon is installed and running…"
sudo apt-get -y -qq install avahi-daemon >/dev/null
sudo systemctl enable --now avahi-daemon >/dev/null 2>&1 || sudo systemctl restart avahi-daemon

mkdir -p "$HOME/atvloadly"   # its settings, the Apple ID sign-in and the installed apps live here
chmod 700 "$HOME/atvloadly"

echo "Starting atvloadly…"
sudo docker pull -q bitxeno/atvloadly:latest >/dev/null
sudo docker rm -f atvloadly >/dev/null 2>&1 || true
sudo docker run -d --name=atvloadly --restart=always --security-opt seccomp:unconfined \
  -p 5533:80 \
  -v "$HOME/atvloadly":/data \
  -v /var/run/dbus:/var/run/dbus \
  -v /var/run/avahi-daemon:/var/run/avahi-daemon \
  bitxeno/atvloadly:latest >/dev/null

sleep 3
if sudo docker ps --filter name=atvloadly --filter status=running -q | grep -q .; then
  echo "atvloadly is running: open http://192.168.4.141:5533 on your PC."
else
  echo "atvloadly didn't start. Its log:"; sudo docker logs --tail 30 atvloadly
fi
