#!/usr/bin/env bash
# The Tapo camera inside the cat flap, popping up on Ember TV and Apple TV when something moves at the flap.
#   go2rtc (Docker) keeps the one connection to the camera; ember-feed records the last minute into memory and watches
#   the box round the flap for movement, then pops up a replay from 3 s before, running on into live.
# You type the camera account (made in the Tapo app: camera > Settings > Advanced Settings > Camera Account) into this
# script; it's kept only on the Pi, in ~/go2rtc/go2rtc.yaml (readable by you alone).
# Run: cd ~/ember-feed-src && git pull -q && bash lucapi/tapo-setup.sh     (safe to run again)
set -euo pipefail
IP=$(hostname -I | awk '{print $1}')
CFG=~/ember-feed/config.json
cd ~/ember-feed-src

command -v docker >/dev/null || { echo "Docker isn't installed. Install it with: curl -fsSL https://get.docker.com | sh"; exit 1; }
command -v ffmpeg >/dev/null || { echo "Installing ffmpeg..."; sudo apt-get install -y -qq ffmpeg >/dev/null; }
D="docker"; docker ps >/dev/null 2>&1 || D="sudo docker"

# 1. where the camera is: anything on the home network answering on the RTSP port (554)
echo "Looking for the camera on your network..."
NET=$(echo "$IP" | cut -d. -f1-3)
FOUND=$(for i in $(seq 1 254); do
  ( [ "$NET.$i" != "$IP" ] && timeout 1 bash -c "</dev/tcp/$NET.$i/554" 2>/dev/null && echo "$NET.$i" ) &
done; wait)
FOUND=$(echo "$FOUND" | grep . | sort -t. -k4 -n || true)
if [ "$(echo "$FOUND" | grep -c . || true)" = 1 ]; then
  read -rp "Found a camera at $FOUND. Press Enter to use it, or type its address: " CAMIP
  CAMIP=${CAMIP:-$FOUND}
else
  [ -n "$FOUND" ] && echo "Cameras found at: $(echo $FOUND)"
  read -rp "The camera's IP address (Tapo app: camera > Settings > Device Info): " CAMIP
fi

# 2. the camera account
read -rp "Camera Account username: " CU
read -rsp "Camera Account password (not shown): " CP; echo
ENCU=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$CU")
ENCP=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$CP")
MAIN="rtsp://$ENCU:$ENCP@$CAMIP:554/stream1"
SUB="rtsp://$ENCU:$ENCP@$CAMIP:554/stream2"
echo "Checking the camera..."
INFO=$(ffprobe -v error -rtsp_transport tcp -timeout 10000000 -select_streams v:0 \
       -show_entries stream=codec_name,width,height -of csv=p=0 "$MAIN" 2>&1) || {
  echo "Couldn't open the camera's stream. Check the address and the Camera Account username and password."
  echo "(ffprobe said: $(echo "$INFO" | sed "s#$ENCP#****#g; s#$ENCU#****#g" | head -2))"; exit 1; }
echo "Camera works: $INFO"
case "$INFO" in h264*) ;; *) echo "Note: the camera sends ${INFO%%,*}, not H.264. The Apple TV may not play it; tell Claude.";; esac

# 3. go2rtc: one connection to the camera, shared (keeps the Ring's stream if it's there)
mkdir -p ~/go2rtc
MAIN="$MAIN" SUB="$SUB" python3 - ~/go2rtc/go2rtc.yaml <<'PY'
import os, sys
p = sys.argv[1]
old = open(p).read().splitlines() if os.path.exists(p) else []
after = old[old.index("streams:") + 1:] if "streams:" in old else []
keep = [l for l in after if l.startswith("  ") and not l.startswith("  tapo")]
out = ['api:', '  listen: ":1985"', 'rtsp:', '  listen: ":8556"', 'webrtc:', '  listen: ":8557"', 'streams:'] + keep + [
    f'  tapo: {os.environ["MAIN"]}#media=video', f'  tapo_sub: {os.environ["SUB"]}#media=video']
open(p, "w").write("\n".join(out) + "\n"); os.chmod(p, 0o600)
PY
$D rm -f go2rtc >/dev/null 2>&1 || true
$D run -d --name go2rtc --restart unless-stopped --network host -v ~/go2rtc:/config alexxit/go2rtc >/dev/null
sleep 4

# 4. tell ember-feed (and update it)
python3 - "$CFG" "$IP" <<'PY'
import json, os, sys
p, ip = sys.argv[1], sys.argv[2]
c = json.load(open(p)) if os.path.exists(p) else {}
t = c.setdefault("tapo", {})
t.update(main="rtsp://127.0.0.1:8556/tapo", sub="rtsp://127.0.0.1:8556/tapo_sub",
         live=f"http://{ip}:1985/api/stream.m3u8?src=tapo", base=f"http://{ip}:8090")
for k, v in {"zone": [0, 0, 1, 1], "sens": 0.04, "secs": 6, "hold": 6, "cooldown": 60, "pre": 3}.items():
    t.setdefault(k, v)
json.dump(c, open(p, "w"), indent=2); os.chmod(p, 0o600)
PY
cp lucapi/ember-feed/feed.py ~/ember-feed/feed.py
sudo systemctl restart ember-feed
echo "Starting the recorder and the motion watcher (15 s)..."
sleep 15

# 5. check it
M=$(curl -s -m 5 localhost:8090/cam/motion || echo '{}')
python3 - "$M" <<'PY'
import json, sys
m = json.loads(sys.argv[1] or "{}")
print("Recorder:", "running, %ss kept" % m.get("seconds_kept") if m.get("recording") else "NOT running yet")
print("Motion watcher:", "running (%s frames looked at)" % m.get("frames") if m.get("frames") else "NOT running yet")
PY
curl -s localhost:8090/cam/test >/dev/null && echo "Sent a test pop-up to Ember TV and Apple TV (it shows while there's movement)."
echo
echo "Last step: on your phone, open  http://$IP:8090/cam/view.jpg  (home Wi-Fi only)"
echo "and send Claude a screenshot, so the motion box can go round the flap. Until then the whole picture counts."
echo "If something isn't working: sudo journalctl -u ember-feed -n 40 --no-pager | grep tapo"
