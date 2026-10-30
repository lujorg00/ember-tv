#!/usr/bin/env bash
# Installs the latest Ember on the TV (after tv-setup.sh has paired it once).
# Usage: bash tv-update.sh [TV_IP]
set -uo pipefail
TV_IP="${1:-192.168.4.29}"
DEV=$(adb devices | awk -v ip="$TV_IP" 'index($1, ip":")==1 && $2=="device"{print $1; exit}')
if [ -z "$DEV" ]; then
  read -rp "Port shown under 'IP address & port' on the TV's Wireless debugging screen: " PORT
  DEV="$TV_IP:$PORT"; adb connect "$DEV" >/dev/null; sleep 2
fi
[ "$(adb -s "$DEV" get-state 2>/dev/null)" = "device" ] || { echo "Couldn't reach the TV at $DEV"; exit 1; }
# Switches on Ember's dimmer (an accessibility service), keeping any others that are already on.
enable_dimmer() {
  local svc="org.lucamedia.ember/.DimService" cur
  cur=$(adb -s "$DEV" shell settings get secure enabled_accessibility_services | tr -d '\r')
  [ "$cur" = "null" ] && cur=""
  case ":$cur:" in *":$svc:"*) ;; *) cur="${cur:+$cur:}$svc";; esac
  adb -s "$DEV" shell settings put secure enabled_accessibility_services "$cur" && \
  adb -s "$DEV" shell settings put secure accessibility_enabled 1
}
curl -fsSL -o /tmp/ember.apk https://github.com/lujorg00/ember-tv/releases/latest/download/ember.apk && \
  adb -s "$DEV" install -r /tmp/ember.apk && \
  adb -s "$DEV" shell settings put secure screensaver_components org.lucamedia.ember/.EmberDream && \
  adb -s "$DEV" shell settings put secure screensaver_enabled 1 && \
  adb -s "$DEV" shell settings put secure screensaver_activate_on_sleep 1 && \
  enable_dimmer && \
  adb -s "$DEV" shell am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null && \
  echo "Ember updated: $(adb -s "$DEV" shell dumpsys package org.lucamedia.ember | grep -m1 versionName | tr -d ' \r')"
