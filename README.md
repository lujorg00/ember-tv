# Ember — a Google TV home screen with no ads

Ember replaces the Google TV home screen with your own:

- **Hero backdrop** for whatever's focused (title, year, rating, genres, synopsis)
- **Home page = your Omni addon's rows**: every catalogue in its manifest becomes a row
  ("Pick Up Where You Left Off" gets wide backdrop cards)
- **Back flips to the Apps page**: a grid of every app, most-used first (hold OK on an app to hide it),
  with a calendar ticker pill by the clock ("Next shift: …" then your other events), a small lucapi status
  in the bottom-right corner, and Elvis and Winnie's status in the bottom-left. Back again returns to your rows.
- **Screensaver** after 1 minute idle: your photos cycling, what's coming up in your calendars, and lucapi's service status
- **Clock and date**, warm amber "Ember" theme
- **The home and Apps pages follow the sun** (worked out on the TV for Salford, no internet needed):
  light mode by day with a bright sun and clouds drifting past; a wall lit by a fire just out of view in the
  evening, with the odd ember; deep blue at night with twinkling stars, shooting stars and the real moon phase.
  Through December, light snow falls over whichever scene is showing.
  The focused app's colour glows through all three. The animation pauses whenever an app is open.
- Picking a title opens it in **Stremio** (configurable)
- Rows are cached, so the home screen appears instantly and works offline;
  they refresh every 15 minutes

Ember is a home screen, not a player. Streams and playback still happen in Stremio.

---

## 1. Build it on GitHub (no Android Studio needed)

1. Create a new repo on github.com (public is easiest: see the note below).
2. Upload everything in this folder, including the hidden `.github` folder.
   On the web: **Add file → Upload files**, then drag the folder contents in.
3. Go to the **Actions** tab. The "Build Ember APK" run starts on its own and takes about 4 minutes.
4. When it's green, the APK is at:
   `https://github.com/<you>/<repo>/releases/latest/download/ember.apk`

Every later push (an edit on GitHub counts) builds a new version that installs over the old one.

**Public vs private:** the download link only works without signing in if the repo is public.
Nothing personal is in the code as long as you leave the addon URL as the placeholder and
set it on the TV instead (step 3). The signing key is in the repo, which is fine for a personal
sideloaded app.
If you keep the repo private, download `ember.apk` from the build's **Artifacts** section and
install it with adb (step 2, option B), or host the file on lucapi.

## 2. Install on the TV

**Option A, the Downloader app (no computer):**
1. On the TV, go to **Settings → System → About** and press **Android TV OS build** 7 times to turn on developer options.
2. Install **Downloader** (by AFTVnews) from the Play Store.
3. **Settings → Apps → Security & restrictions → Unknown sources →** allow Downloader.
4. In Downloader, enter the `releases/latest/download/ember.apk` URL and install it.

**Option B, adb from your PC:**
1. Turn on developer options (as above), then **Developer options → USB debugging / Network debugging**.
2. `adb connect <tv-ip>:5555`, then `adb install -r ember.apk`

## 3. Point it at your addon

The easy way is from your PC, which saves typing on the remote:

```
adb shell am start -n org.lucamedia.ember/.SettingsActivity --es addon "https://YOUR-ADDON/manifest.json"
```

Or open Ember, press Back for the Apps page, choose **⚙ Ember** at the end of the grid, and type the URL in.
Use **Test addon** to check it, then **Save & reload**.

To bake the URL into the build instead, edit `app/src/main/res/values/config.xml` before building.

## 3b. The lucapi feed (screensaver + projects strip)

`lucapi/ember-feed/` is a small service for the Pi. It gives Ember:

- **your calendars:** the next 7 days from your iCloud calendars, with recurring events and time changes handled
- **Pi status:** every service you've installed (it finds your own systemd services and docker containers by
  itself), plus temperature, disk and uptime
- **photos:** anything you drop in `/mnt/storage/ember-photos`, or Bing's daily photos if that folder is empty

**Install on lucapi** (from your PC):
```
scp -r lucapi/ember-feed luca@192.168.4.141:~/ember-feed-src
ssh luca@192.168.4.141 "cd ~/ember-feed-src && bash install.sh"
```
Then edit `~/ember-feed/config.json` on the Pi:
- **calendars:** your iCloud calendar links. Your wall dashboard already uses these, so you can copy them from its config.
  To make a new one: iPhone Calendar → (i) next to the calendar → **Public Calendar** → Share Link. Anyone with that link can read the calendar.
- **Mark your shifts calendar** with `"shifts": true`. The Apps page pill then reads "Next shift: …" first,
  then rolls through your next few events from your other calendars (how many: `ticker_others`).
- **cats → url:** where Ember reads Elvis and Winnie's status from your cat tracker (see below).
- **services → names:** friendlier names (`"rotation": "Gym tracker"`). Use **hide** to leave something out.
- **photos → mix_bing:** `true` mixes Bing's photos in with yours.

Then run `sudo systemctl restart ember-feed`. Check it with `curl -s http://192.168.4.141:8090/screensaver`.

**Adding photos:** copy them in from your PC, for example
`scp ~/Pictures/tv/*.jpg luca@192.168.4.141:/mnt/storage/ember-photos/`.
Landscape photos at 1920px wide or more look best. New photos are picked up within 5 minutes.

The TV build points at `http://192.168.4.141:8090` by default. You can change it in Ember settings → **lucapi feed**,
or with `adb shell am start -n org.lucamedia.ember/.SettingsActivity --es feed "http://..."`.

**Cats:** ember-feed reads a JSON address from your cat tracker and shows it small in the bottom-left of the Apps page.
Each cat gets its own small block saying In or Out and for how long. ember-feed understands either a list or a
dict keyed by name, with fields like `home` / `state` ("home"/"out") and `since` (when that last changed, as an ISO time or epoch). If catwatch doesn't expose an address like that yet, a tiny endpoint needs adding to it.
Until `cats.url` is set, the cats line just stays hidden.

## 3c. Make Ember the screensaver, after 1 minute idle

Google TV's menus only offer Google's own Ambient mode, so set it from your PC once:
```
adb shell settings put secure screensaver_components org.lucamedia.ember/.EmberDream
adb shell settings put secure screensaver_enabled 1
adb shell settings put system screen_off_timeout 60000
```
`screen_off_timeout` is how long the TV waits before the screensaver starts, in milliseconds (60000 = 1 minute).
Video apps keep the TV awake while they're playing, so it won't start in the middle of a film.
To check how it looks without waiting, use Ember settings → **Preview screensaver**.

*Not yet verified on a real Chromecast:* some Google TV updates reset these settings or put Ambient mode back.
If the screensaver reverts to Google's, run the three commands again.
To go back to Google's: `adb shell settings delete secure screensaver_components`.

## 4. Make the Home button go to Ember

Google TV doesn't let other apps be the default home screen. Two ways round it:

**A — Accessibility override (recommended, reversible):**
Ember settings → **Open Accessibility settings** → **Ember home button** → On.
After that, whenever the Google TV home screen appears (Home button, waking the TV), Ember jumps in front.
You may see Google TV for a split second first.

*Caveat:* Google has broken this trick for Projectivy at least once with an update. If Home stops
going to Ember, check Ember settings → **Diagnostics**. It shows the last Google TV screen Ember saw,
which tells us what to match.

**B — Disable the stock launcher (harder, more permanent):**
```
adb shell pm disable-user --user 0 com.google.android.apps.tv.launcherx
```
Ember then becomes the real home app (pick it and choose "Always" if asked).
Undo with `adb shell pm enable com.google.android.apps.tv.launcherx`.
**Before you do this:** it can break things that rely on the stock launcher, such as Google TV setup,
some account and profile screens, and possibly the settings side panel. Some firmware updates also
re-enable it. Try option A first.

## Remote controls in Ember

| Button | What it does |
|---|---|
| D-pad / OK | Move, open |
| Hold OK on a title | Open / refresh all rows |
| Hold OK on an app | Open / hide / app info |
| Back | Flip between your rows and the Apps page |
| Home | Back to the top of your rows |

## Changing things

- Rows come straight from your addon, so add, rename or reorder catalogues there.
- Colours are at the top of `HomeActivity.java` (`BG`, `SURFACE`, `ACCENT`…).
- If titles should open somewhere other than Stremio, change "When you pick a title, open" in settings.
