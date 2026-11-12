#!/usr/bin/env bash
# The Ring camera by the cat flap, popping up on Ember TV and Apple TV when a cat reaches the flap.
#   ring-mqtt (Docker) logs into your Ring account and offers each camera's live view as a local stream, only while
#   something is watching it. go2rtc (Docker) turns that into HLS, which the Chromecast and Apple TV players can play.
#   ember-feed is told where it is, and pops it up when the cat tracker sees a cat at the flap.
# You log in to Ring yourself, on ring-mqtt's own page (http://192.168.4.141:55123) - nothing is typed into this script.
# Run: cd ~/ember-feed-src && git pull -q && bash lucapi/ring-setup.sh     (safe to run again)
set -euo pipefail
IP=$(hostname -I | awk '{print $1}')
CFG=~/ember-feed/config.json

command -v docker >/dev/null || { echo "Docker isn't installed. Install it with: curl -fsSL https://get.docker.com | sh"; exit 1; }
command -v mosquitto_sub >/dev/null || { echo "Installing mosquitto-clients..."; sudo apt-get install -y -qq mosquitto-clients >/dev/null; }
D="docker"; docker ps >/dev/null 2>&1 || D="sudo docker"

# the MQTT broker the cat tracker already uses
MQ=(-h localhost)
if ! timeout 5 mosquitto_sub "${MQ[@]}" -t '$SYS/broker/version' -C 1 >/dev/null 2>&1; then
  read -rp "Your MQTT (mosquitto) username: " MU
  read -rsp "Its password (not shown): " MP; echo
  MQ=(-h localhost -u "$MU" -P "$MP")
  timeout 5 mosquitto_sub "${MQ[@]}" -t '$SYS/broker/version' -C 1 >/dev/null || { echo "Couldn't log in to mosquitto."; exit 1; }
  MQURL="mqtt://$MU:$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$MP")@localhost:1883"
else
  MQURL="mqtt://localhost:1883"
fi

# 1. ring-mqtt
mkdir -p ~/ring-mqtt
MQURL="$MQURL" python3 - ~/ring-mqtt/config.json <<'PY'
import json, os, sys
p = sys.argv[1]
c = json.load(open(p)) if os.path.exists(p) else {}
c.update({"mqtt_url": os.environ["MQURL"], "enable_cameras": True, "enable_modes": False, "enable_panic": False,
          "ring_topic": "ring", "hass_topic": "homeassistant/status"})
c.setdefault("livestream_user", ""); c.setdefault("livestream_pass", ""); c.setdefault("disarm_code", "")
c.setdefault("location_ids", [])
json.dump(c, open(p, "w"), indent=2); os.chmod(p, 0o600)
PY
if ! $D ps --format '{{.Names}}' | grep -qx ring-mqtt; then
  $D rm -f ring-mqtt >/dev/null 2>&1 || true
  echo "Starting ring-mqtt (the first download takes a minute or two)..."
  $D run -d --name ring-mqtt --restart unless-stopped --network host -v ~/ring-mqtt:/data tsightler/ring-mqtt >/dev/null
fi
sleep 10
if curl -s -o /dev/null -m 3 "http://localhost:55123"; then
  echo
  echo "Log in to Ring: on your phone or PC, open  http://$IP:55123"
  echo "and sign in with your Ring email, password and the 2-step code. (It's only reachable on your home network.)"
  read -rp "Press Enter once it says you're logged in... "
  sleep 5
fi

# 2. which camera: ring-mqtt lists them on MQTT (ring/<location>/camera/<id>/...) with their names in the
#    Home Assistant discovery messages
echo "Looking for your Ring cameras (up to a minute)..."
TMP=$(mktemp)
timeout 60 mosquitto_sub "${MQ[@]}" -v -t 'ring/+/camera/+/#' -t 'homeassistant/#' > "$TMP" 2>/dev/null &
SUB=$!
sleep 3; $D restart ring-mqtt >/dev/null   # makes it announce everything again
for i in $(seq 1 57); do
  grep -q '^ring/[^/]*/camera/' "$TMP" && [ "$i" -gt 20 ] && break
  sleep 1
done
kill $SUB 2>/dev/null || true
CAMS=$(python3 - "$TMP" <<'PY'
import json, re, sys
ids, names = [], {}
for line in open(sys.argv[1], errors="ignore"):
    topic, _, payload = line.rstrip("\n").partition(" ")
    m = re.match(r"ring/[^/]+/camera/([^/]+)/", topic)
    if m and m.group(1) not in ids:
        ids.append(m.group(1))
    if topic.startswith("homeassistant/"):
        try:
            d = json.loads(payload).get("device") or {}
        except Exception:
            continue
        for i in (d.get("identifiers") or []):
            names.setdefault(str(i), d.get("name") or "")
for i in ids:
    print(i + "\t" + (names.get(i) or "Ring camera"))
PY
)
rm -f "$TMP"
[ -n "$CAMS" ] || { echo "No cameras found. Check the login page (http://$IP:55123) and: docker logs --tail 30 ring-mqtt"; exit 1; }
N=$(echo "$CAMS" | wc -l)
if [ "$N" -gt 1 ]; then
  echo "Your Ring cameras:"; echo "$CAMS" | awk -F'\t' '{print "  " NR ") " $2}'
  read -rp "Which one is by the cat flap? Number: " PICK
  CAM=$(echo "$CAMS" | sed -n "${PICK}p")
else
  CAM=$CAMS
fi
CAMID=$(echo "$CAM" | cut -f1); CAMNAME=$(echo "$CAM" | cut -f2)
echo "Using: $CAMNAME"

# 3. go2rtc: the live view as HLS, on port 1985 (ring-mqtt has 8554 and its own go2rtc)
mkdir -p ~/go2rtc
cat > ~/go2rtc/go2rtc.yaml <<EOF
api:
  listen: ":1985"
rtsp:
  listen: ":8556"
webrtc:
  listen: ":8557"
streams:
  catflap: rtsp://127.0.0.1:8554/${CAMID}_live#media=video
EOF
$D rm -f go2rtc >/dev/null 2>&1 || true
$D run -d --name go2rtc --restart unless-stopped --network host -v ~/go2rtc:/config alexxit/go2rtc >/dev/null

# 4. tell ember-feed
python3 - "$CFG" "http://$IP:1985/api/stream.m3u8?src=catflap" <<'PY'
import json, os, sys
p = sys.argv[1]
c = json.load(open(p)) if os.path.exists(p) else {}
r = c.setdefault("ring", {})
r["hls"] = sys.argv[2]
r.setdefault("flap_rooms", ["cat_flap"]); r.setdefault("secs", 45); r.setdefault("cooldown", 90)
json.dump(c, open(p, "w"), indent=2); os.chmod(p, 0o600)
PY
sudo systemctl restart ember-feed
sleep 4

# 5. check it: ask go2rtc for the stream (this starts a live view on the camera)
echo "Checking the camera stream (up to 30 s)..."
OK=""
for i in $(seq 1 15); do
  if curl -s -m 20 "http://localhost:1985/api/stream.m3u8?src=catflap" | grep -q '#EXT'; then OK=1; break; fi
  sleep 2
done
if [ -n "$OK" ]; then
  echo "Camera stream works."
else
  echo "The stream didn't start. Look at: docker logs --tail 30 ring-mqtt ; docker logs --tail 30 go2rtc"
fi
curl -s "http://localhost:8090/cam/test" >/dev/null && echo "Sent a test pop-up to Ember TV and Apple TV (it shows for 45 s)."
echo "From now on it pops up when a cat reaches the flap. Test again any time: curl -s localhost:8090/cam/test"
