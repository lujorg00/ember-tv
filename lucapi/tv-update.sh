#!/usr/bin/env bash
# Installs the latest Ember on the TV (after tv-setup.sh has paired it once).
# Usage: bash tv-update.sh [TV_IP]
set -uo pipefail
TV_IP="${1:-192.168.4.29}"
DEV=$(adb devices | awk -v ip="$TV_IP" 'index($1, ip":")==1 && $2=="device"{print $1; exit}')
# The TV's debugging port changes now and then. It announces it on the network, so look it up first
# (adb's own lookup, then the Pi's avahi); only ask if neither finds it.
find_port() {
  adb mdns services 2>/dev/null | awk -v ip="$TV_IP" '$2 ~ /_adb-tls-connect/ && index($3, ip":")==1 {split($3,a,":"); print a[2]; exit}'
  command -v avahi-browse >/dev/null || sudo apt-get -y -qq install avahi-utils >/dev/null 2>&1
  command -v avahi-browse >/dev/null && timeout 8 avahi-browse -rpt _adb-tls-connect._tcp 2>/dev/null \
    | awk -F';' -v ip="$TV_IP" '$1=="=" && $8==ip {print $9; exit}'
}
if [ -z "$DEV" ]; then
  PORT=$(find_port | head -1)
  if [ -n "$PORT" ]; then
    echo "Found the TV at $TV_IP:$PORT"
  else
    echo "Couldn't find the TV's debugging port by itself (is Wireless debugging still on?)."
    read -rp "Port shown under 'IP address & port' on the TV's Wireless debugging screen: " PORT
  fi
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
