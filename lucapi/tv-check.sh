#!/usr/bin/env bash
# Is Ember TV's overlay (the dimmer, calendar pop-ups and the cats) running on the TV? Prints what it finds.
# Usage: bash tv-check.sh [TV_IP]
TV_IP="${1:-192.168.4.29}"
DEV=$(adb devices | awk -v ip="$TV_IP" 'index($1, ip":")==1 && $2=="device"{print $1; exit}')
if [ -z "$DEV" ]; then
  PORT=$(adb mdns services 2>/dev/null | awk -v ip="$TV_IP" '$2 ~ /_adb-tls-connect/ && index($3, ip":")==1 {split($3,a,":"); print a[2]; exit}')
  [ -z "$PORT" ] && command -v avahi-browse >/dev/null && PORT=$(timeout 8 avahi-browse -rpt _adb-tls-connect._tcp 2>/dev/null | awk -F';' -v ip="$TV_IP" '$1=="=" && $8==ip {print $9; exit}')
  [ -z "$PORT" ] && read -rp "Port shown on the TV's Wireless debugging screen: " PORT
  DEV="$TV_IP:$PORT"; adb connect "$DEV" >/dev/null; sleep 2
fi
[ "$(adb -s "$DEV" get-state 2>/dev/null)" = "device" ] || { echo "Couldn't reach the TV at $DEV"; exit 1; }
echo "Ember on the TV:   $(adb -s "$DEV" shell dumpsys package org.lucamedia.ember | awk -F= '/versionName/{print $2; exit}' | tr -d '\r')"
on=$(adb -s "$DEV" shell settings get secure enabled_accessibility_services | tr -d '\r')
case "$on" in *org.lucamedia.ember/.DimService*) echo "Overlay switched on: yes";; *) echo "Overlay switched on: NO";; esac
if adb -s "$DEV" shell dumpsys accessibility 2>/dev/null | grep -q "org.lucamedia.ember/.DimService"; then
  echo "Overlay running:     yes"; else echo "Overlay running:     NO (run tv-update.sh again to switch it off and on)"; fi
echo "Recent overlay messages:"
adb -s "$DEV" logcat -d -t 400 2>/dev/null | grep -i -E "EmberDim|DimService" | tail -8
