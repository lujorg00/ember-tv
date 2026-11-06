#!/usr/bin/env bash
# Ember TV setup: run on lucapi. Talks to the Chromecast over Wi-Fi (adb wireless debugging) and:
#   1. backs up the TV's app list and settings
#   2. installs the latest Ember from GitHub
#   3. disables Google TV's launcher, recommendations, ambient mode and other bloat (nothing is uninstalled)
#   4. makes Ember the home app and the screensaver (starting after 1 minute)
# Everything is undone by the restore script it writes into the backup folder.
#
# Usage:  bash tv-setup.sh [TV_IP]        (defaults to 192.168.4.29)
set -uo pipefail

TV_IP="${1:-192.168.4.29}"
APK_URL="https://github.com/lujorg00/ember-tv/releases/latest/download/ember.apk"
EMBER="org.lucamedia.ember"
BACKUP="$HOME/tv-backup/$(date +%Y%m%d-%H%M%S)"

# Bloat to disable on Chromecast with Google TV. Only ones actually installed are touched.
BLOAT=(
  com.google.android.apps.tv.launcherx            # Google TV home screen (ads, recommendations) -> replaced by Ember
  com.google.android.tungsten.setupwraith         # setup app; otherwise takes over as home when the launcher is off
  com.google.android.tvrecommendations            # recommendation feeds for the home screen
  com.google.android.leanbacklauncher.recommendations
  com.google.android.apps.tv.dreamx               # Ambient mode -> replaced by Ember's screensaver
  com.google.android.backdrop                     # older Ambient mode photos
  com.google.android.videos                       # Google TV / Play Movies store
  com.google.android.play.games                   # Play Games
  com.google.android.tvtutorials                  # tips and tutorials
  com.google.android.feedback                     # feedback reporter
  com.android.printspooler                        # printing
)
# Kept on purpose: Play Store, Google Play services, casting (mediashell), Assistant/voice search (katniss),
# TV settings, remote/Bluetooth services, and every app you installed.

say() { printf '\n\033[1;33m%s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m%s\033[0m\n' "$*"; exit 1; }

# --- adb -------------------------------------------------------------------------------
if ! command -v adb >/dev/null; then
  say "Installing adb on the Pi..."
  sudo apt-get update -qq && (sudo apt-get install -y -qq adb || sudo apt-get install -y -qq android-tools-adb) || die "Couldn't install adb"
fi

# --- connect ---------------------------------------------------------------------------
echo "adb version: $(adb version | head -1)"
say "On the TV: Settings > System > Developer options > Wireless debugging > Pair device with pairing code"
echo "Leave that pairing box open on the TV the whole time - closing it cancels the code."
paired=no
for attempt in 1 2 3; do
  read -rp "Type the IP address and port shown in the pairing box (e.g. ${TV_IP}:37123), or 'skip' if already paired: " PAIR
  [ "$PAIR" = "skip" ] && { paired=yes; break; }
  [ -n "$PAIR" ] || continue
  read -rp "Type the 6-digit code shown in the pairing box: " CODE
  OUT=$(adb pair "$PAIR" "$CODE" 2>&1); echo "$OUT"
  if echo "$OUT" | grep -qi "successfully paired"; then paired=yes; break; fi
  echo "That didn't pair. If the box on the TV closed, open 'Pair device with pairing code' again: it gives a new port and code."
done
[ "$paired" = yes ] || die "Pairing failed three times. Send Claude the messages above."

say "Now back out to the main Wireless debugging screen: it shows 'IP address & port' (a different port)."
read -rp "Type just that port number: " PORT
DEV="${TV_IP}:${PORT}"
adb connect "$DEV" >/dev/null
sleep 2
[ "$(adb -s "$DEV" get-state 2>/dev/null)" = "device" ] || die "Couldn't connect to $DEV"
A() { adb -s "$DEV" shell "$@"; }
MODEL=$(A getprop ro.product.model | tr -d '\r')
SDK=$(A getprop ro.build.version.sdk | tr -d '\r')
say "Connected to: $MODEL (Android API $SDK)"

# --- backup ----------------------------------------------------------------------------
mkdir -p "$BACKUP"
A pm list packages -e | tr -d '\r' | sort > "$BACKUP/enabled-packages.txt"
A pm list packages -d | tr -d '\r' | sort > "$BACKUP/disabled-packages.txt"
for k in screensaver_components screensaver_enabled screensaver_activate_on_sleep; do
  echo "secure $k=$(A settings get secure $k | tr -d '\r')" >> "$BACKUP/settings.txt"
done
echo "system screen_off_timeout=$(A settings get system screen_off_timeout | tr -d '\r')" >> "$BACKUP/settings.txt"
echo "Backup saved in $BACKUP"

# --- install Ember first, so the TV is never left without a home screen ---------------
say "Downloading and installing the latest Ember..."
curl -fsSL -o "$BACKUP/ember.apk" "$APK_URL" || die "Couldn't download Ember"
adb -s "$DEV" install -r "$BACKUP/ember.apk" || die "Couldn't install Ember"
A pm path "$EMBER" >/dev/null || die "Ember isn't installed; stopping before anything is disabled"

# --- disable bloat (one command per package; chained pm calls can stop silently) -------
say "Disabling Google TV bloat..."
: > "$BACKUP/disabled-by-ember.txt"
for pkg in "${BLOAT[@]}"; do
  if grep -qx "package:$pkg" "$BACKUP/enabled-packages.txt"; then
    if A pm disable-user --user 0 "$pkg" 2>&1 | grep -q "disabled"; then
      echo "  off  $pkg"; echo "$pkg" >> "$BACKUP/disabled-by-ember.txt"
    else
      echo "  !!   couldn't disable $pkg (left as is)"
    fi
  fi
done

# --- Ember as home and screensaver -----------------------------------------------------
say "Making Ember the home app and the screensaver..."
A cmd package set-home-activity "$EMBER/.HomeActivity" >/dev/null 2>&1 || true
A settings put secure screensaver_components "$EMBER/.EmberDream"
A settings put secure screensaver_enabled 1
A settings put secure screensaver_activate_on_sleep 1   # start the screensaver when the TV goes idle
A settings put system screen_off_timeout 60000

# --- restore script --------------------------------------------------------------------
cat > "$BACKUP/restore.sh" <<EOF
#!/usr/bin/env bash
# Undoes tv-setup.sh from $(date). Usage: bash restore.sh TV_IP:PORT
DEV="\${1:?give the TV address, e.g. ${TV_IP}:PORT from the Wireless debugging screen}"
adb connect "\$DEV" >/dev/null; sleep 2
while read -r p; do [ -n "\$p" ] && adb -s "\$DEV" shell pm enable "\$p" && echo "on  \$p"; done < "$BACKUP/disabled-by-ember.txt"
adb -s "\$DEV" shell cmd package set-home-activity com.google.android.apps.tv.launcherx/com.google.android.apps.tv.launcherx.home.HomeActivity >/dev/null 2>&1
echo "Restored. Press Home on the remote (or restart the TV)."
EOF
# put the original settings back (or remove ones that didn't exist before)
while IFS='=' read -r key val; do
  ns="${key%% *}"; k="${key#* }"
  if [ "$val" = "null" ] || [ -z "$val" ]; then
    echo "adb -s \"\$DEV\" shell settings delete $ns $k"
  else
    echo "adb -s \"\$DEV\" shell settings put $ns $k \"$val\""
  fi
done < "$BACKUP/settings.txt" > "$BACKUP/.restore-settings"
sed -i "/^echo \"Restored/e cat $BACKUP/.restore-settings" "$BACKUP/restore.sh"
rm -f "$BACKUP/.restore-settings"
chmod +x "$BACKUP/restore.sh"

# --- go -------------------------------------------------------------------------------
A am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1
say "Done. Press Home on the remote: it should go straight to Ember."
echo "To undo everything:  bash $BACKUP/restore.sh ${TV_IP}:PORT"
