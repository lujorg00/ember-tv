#!/usr/bin/env bash
# YouTube inside Ember (Apple TV): yt-dlp on the Pi does the YouTube side, signed in as you so the recommendations,
# subscriptions and Watch later are yours. Your sign-in is a cookies file you copy to the Pi yourself (below); it's
# kept only on the Pi (~/ember-feed/yt-cookies.txt, readable by you alone). Nothing is typed into this script.
# Run: cd ~/ember-feed-src && git pull -q && bash lucapi/youtube-setup.sh     (safe to run again)
set -euo pipefail
IP=$(hostname -I | awk '{print $1}')
cd ~/ember-feed-src
mkdir -p ~/.local/bin

# 1. yt-dlp: the newest build (YouTube changes often; the nightly build keeps up best), updated every night
echo "Getting the newest yt-dlp..."
case "$(uname -m)" in aarch64|arm64) F=yt-dlp_linux_aarch64;; armv7l) F=yt-dlp_linux_armv7l;; *) F=yt-dlp_linux;; esac
curl -fsSL -o ~/.local/bin/yt-dlp.new "https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download/$F"
chmod +x ~/.local/bin/yt-dlp.new && mv ~/.local/bin/yt-dlp.new ~/.local/bin/yt-dlp
echo "yt-dlp $(~/.local/bin/yt-dlp --version)"
( crontab -l 2>/dev/null | grep -v 'yt-dlp -U' ; echo "17 4 * * * $HOME/.local/bin/yt-dlp -U --update-to nightly >/dev/null 2>&1" ) | crontab -

# 2. deno: YouTube's player code has to be run to unlock the streams; yt-dlp uses deno for it
if [ ! -x ~/.deno/bin/deno ]; then
  echo "Installing deno (for yt-dlp)..."
  command -v unzip >/dev/null || sudo apt-get install -y -qq unzip >/dev/null
  curl -fsSL https://deno.land/install.sh | sh -s -- -y >/dev/null
fi
echo "deno $(~/.deno/bin/deno --version | head -1 | awk '{print $2}')"

# 3. update ember-feed
cp lucapi/ember-feed/feed.py ~/ember-feed/feed.py
sudo systemctl restart ember-feed

# 4. your YouTube sign-in
C=~/ember-feed/yt-cookies.txt
if [ ! -s "$C" ]; then
  cat <<TXT

Now your YouTube sign-in. On your PC, in Chrome:
  1. Install the extension "Get cookies.txt LOCALLY" (Chrome Web Store). In its details, turn on "Allow in Incognito".
  2. Open an Incognito window (Ctrl+Shift+N), go to youtube.com and sign in.
  3. In that same tab go to  https://www.youtube.com/robots.txt
  4. Click the extension, then "Export" (it saves www.youtube.com_cookies.txt to Downloads).
  5. Close the Incognito window straight away (that keeps the sign-in from being changed under the Pi).
  6. In PowerShell on the PC:
       scp \$HOME\\Downloads\\www.youtube.com_cookies.txt luca@$IP:ember-feed/yt-cookies.txt

TXT
  read -rp "Press Enter once it's copied... "
fi
[ -s "$C" ] || { echo "No ~/ember-feed/yt-cookies.txt yet. Copy it, then run this again."; exit 1; }
chmod 600 "$C"
grep -q "youtube.com" "$C" || { echo "That file doesn't look like YouTube cookies. Export again (step 4) and copy it over."; exit 1; }

echo "Checking your recommendations (up to a minute)..."
sleep 3
N=$(curl -s -m 120 localhost:8090/yt/feed/home | python3 -c 'import json,sys; j=json.load(sys.stdin); print(len(j.get("items",[])), j.get("error",""))')
case "$N" in
  0*) echo "Didn't get your recommendations: ${N#0 }"; echo "Export the cookies again (steps 2-6) and run this again."; exit 1;;
  *)  echo "Signed in: ${N%% *} recommended videos.";;
esac
S=$(curl -s -m 120 localhost:8090/yt/feed/subs | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("items",[])))')
echo "Subscriptions feed: $S videos."
echo "Done. YouTube is on Ember for Apple TV (the YouTube tab)."
