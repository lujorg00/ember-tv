package org.lucamedia.ember;

import android.accessibilityservice.AccessibilityService;
import android.animation.ValueAnimator;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.media.AudioManager;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityEvent;
import android.widget.FrameLayout;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.text.SimpleDateFormat;
import java.util.Calendar;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Ember's layer over everything on screen (Stremio, YouTube, the screensaver):
 *  - the dimmer: a see-through black layer, cycled Off -> Dim -> Heavy by one remote button (the Netflix button,
 *    learnt in Ember settings). Automatic: Dim at 11:30pm, Heavy at midnight, lifted at 8am. Before an early shift
 *    (starting before 10am) each step comes an hour earlier, with a note saying when the shift is.
 *  - notes: small pills top-right - "You were at 10:50" when something you were part-way through starts playing,
 *    "Winnie came in" / "Elvis went out" from the cat flap, and calendar and reminder alerts (10 seconds each).
 */
public class DimService extends AccessibilityService {

    static final int[] LEVELS = {0, 50, 80};       // percent of black over the picture
    static final String[] NAMES = {"Dim off", "Dim", "Heavy dim"};
    private static final int DIM_AT = 23 * 60 + 30, HEAVY_AT = 24 * 60, LIFT_AT = 8 * 60;
    private static final int EARLY_SHIFT_BEFORE = 10 * 60; // a shift before 10am counts as early
    private static final int EARLY_BY = 60;                // and brings the dimming forward an hour
    private static final long CAT_POLL_MS = 20_000, NIGHT_POLL_MS = 15 * 60_000;
    private static final long RESUME_NOTE_MS = 30_000, CAT_NOTE_MS = 8_000, ALERT_NOTE_MS = 10_000;
    private static final long ALERT_POLL_MS = 5 * 60_000;

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService net = Executors.newSingleThreadExecutor();
    private Prefs prefs;
    private WindowManager wm;
    private PowerManager power;
    private AudioManager audio;
    private FrameLayout layer;
    private TextView label, note;
    private int shownAlpha; // 0..255 currently on screen
    private ValueAnimator fade;
    private long noteUntil;

    // the next shift, from lucapi (start time in millis, 0 = none)
    private volatile long shiftStart;
    private volatile String shiftTitle = "";
    private long nightFetchedAt;

    private final java.util.List<Object[]> notesWaiting = new java.util.ArrayList<>();
    private final java.util.List<Object[]> alertsDue = new java.util.ArrayList<>(); // {id, at millis, text}
    private long alertsFetchedAt;
    private final Map<String, Boolean> catsHome = new HashMap<>();
    private boolean catsKnown;

    private final Runnable clock = new Runnable() {
        @Override
        public void run() {
            if (System.currentTimeMillis() - nightFetchedAt > NIGHT_POLL_MS) fetchNight();
            if (power.isInteractive() && System.currentTimeMillis() - alertsFetchedAt > ALERT_POLL_MS) fetchAlerts();
            checkSchedule();
            showDueAlerts();
            main.postDelayed(this, 30_000);
        }
    };

    private final BroadcastReceiver screenOn = new BroadcastReceiver() {
        @Override
        public void onReceive(Context c, Intent i) {
            checkSchedule(); // the TV may have slept through a step
            fetchAlerts();
            main.removeCallbacks(catPoll);
            main.post(catPoll);
        }
    };

    @Override
    protected void onServiceConnected() {
        super.onServiceConnected();
        prefs = new Prefs(this);
        wm = (WindowManager) getSystemService(WINDOW_SERVICE);
        power = (PowerManager) getSystemService(POWER_SERVICE);
        audio = (AudioManager) getSystemService(AUDIO_SERVICE);
        registerReceiver(screenOn, new IntentFilter(Intent.ACTION_SCREEN_ON));
        prefs.raw().registerOnSharedPreferenceChangeListener(resumeWatch);
        apply(prefs.dimLevel(), false);
        main.post(clock);
        main.postDelayed(catPoll, 3000);
        if (!prefs.resumeNote().isEmpty()) main.post(resumeCheck);
    }

    @Override
    public void onDestroy() {
        main.removeCallbacksAndMessages(null);
        net.shutdownNow();
        try {
            unregisterReceiver(screenOn);
        } catch (Exception ignored) {
        }
        if (prefs != null) prefs.raw().unregisterOnSharedPreferenceChangeListener(resumeWatch);
        removeLayer();
        super.onDestroy();
    }

    // ---------------------------------------------------------------- the button

    @Override
    protected boolean onKeyEvent(KeyEvent e) {
        int code = e.getKeyCode();
        if (prefs.dimLearning()) {
            if (code == KeyEvent.KEYCODE_DPAD_CENTER || code == KeyEvent.KEYCODE_ENTER) return false;
            if (e.getAction() == KeyEvent.ACTION_DOWN) {
                prefs.setDimKey(code);
                prefs.setDimLearning(false);
                Log.i("EmberDim", "dimmer button set to " + KeyEvent.keyCodeToString(code));
                say("Dimmer button set");
            }
            return true;
        }
        if (code != prefs.dimKey() || prefs.dimKey() == 0) return false;
        if (e.getAction() == KeyEvent.ACTION_UP && e.getRepeatCount() == 0) {
            prefs.setDimAuto(false); // you've taken over for tonight
            apply((prefs.dimLevel() + 1) % LEVELS.length, true);
        }
        return true; // swallow it, so Netflix doesn't open
    }

    // ---------------------------------------------------------------- the schedule

    /**
     * Times are counted from noon, so one night runs noon -> noon: Dim, then Heavy, then lift at 8am. Each step happens
     * once a night and never brightens what you've set; at 8am an automatic dim lifts, one you set yourself stays.
     */
    private void checkSchedule() {
        Calendar now = Calendar.getInstance();
        int mins = now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE);
        int t = (mins - 12 * 60 + 1440) % 1440;           // minutes since noon
        Calendar noon = (Calendar) now.clone();             // the noon this night started at
        if (mins < 12 * 60) noon.add(Calendar.DAY_OF_YEAR, -1);
        noon.set(Calendar.HOUR_OF_DAY, 12);
        noon.set(Calendar.MINUTE, 0);
        noon.set(Calendar.SECOND, 0);
        noon.set(Calendar.MILLISECOND, 0);
        String night = noon.get(Calendar.YEAR) + "-" + noon.get(Calendar.DAY_OF_YEAR);

        boolean early = earlyShift(noon);
        int shift = early ? EARLY_BY : 0;
        int dimAt = DIM_AT - 12 * 60 - shift, heavyAt = HEAVY_AT - 12 * 60 - shift, liftAt = LIFT_AT + 12 * 60;

        if (t >= heavyAt && t < liftAt) {
            if (step("heavy:" + night, 2) && early) shiftNote();
        } else if (t >= dimAt && t < liftAt) {
            if (step("dim:" + night, 1) && early) shiftNote();
        } else if (prefs.dimAuto()) {
            prefs.setDimAuto(false);
            apply(0, false);
        }
    }

    /** True if the next shift starts between midnight and 10am after this night's noon. */
    private boolean earlyShift(Calendar noon) {
        if (shiftStart == 0) return false;
        long midnight = noon.getTimeInMillis() + 12 * 3600_000L;
        return shiftStart >= midnight && shiftStart < midnight + EARLY_SHIFT_BEFORE * 60_000L;
    }

    private boolean step(String id, int level) {
        if (id.equals(prefs.dimAutoNight())) return false; // already done
        prefs.setDimAutoNight(id);
        prefs.setDimAuto(true);
        if (prefs.dimLevel() < level) apply(level, true);
        return true;
    }

    private void shiftNote() {
        long left = shiftStart - System.currentTimeMillis();
        if (left <= 0) return;
        String at = new SimpleDateFormat("HH:mm", Locale.UK).format(shiftStart);
        long h = left / 3600_000L, m = (left / 60_000L) % 60;
        showNote("Early shift: " + shiftTitle + " at " + at + "  ·  " + h + "h " + m + "m to go", 15_000);
    }

    private void fetchNight() {
        nightFetchedAt = System.currentTimeMillis();
        final String url = feed("/night");
        if (url == null) return;
        net.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    JSONObject s = new JSONObject(AddonClient.get(url)).optJSONObject("shift");
                    if (s == null) {
                        shiftStart = 0;
                        return;
                    }
                    shiftTitle = s.optString("title", "shift");
                    shiftStart = parseIso(s.optString("start"));
                } catch (Exception e) {
                    Log.w("EmberDim", "couldn't read the next shift: " + e);
                }
            }
        });
    }

    private static long parseIso(String iso) throws java.text.ParseException {
        // "2026-10-30T07:00:00+00:00" -> drop the colon in the offset for SimpleDateFormat
        String s = iso.replaceAll("\\.\\d+", "").replaceAll("Z$", "+0000").replaceAll("([+-]\\d\\d):(\\d\\d)$", "$1$2");
        return new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssZ", Locale.UK).parse(s).getTime();
    }

    // ---------------------------------------------------------------- "you were at 10:50"

    /** Ember sets a resume note when it opens something you were part-way through; it shows once playback starts. */
    private final SharedPreferences.OnSharedPreferenceChangeListener resumeWatch =
            new SharedPreferences.OnSharedPreferenceChangeListener() {
                @Override
                public void onSharedPreferenceChanged(SharedPreferences sp, String key) {
                    if ("resume_note".equals(key) && !prefs.resumeNote().isEmpty()) {
                        main.removeCallbacks(resumeCheck);
                        main.postDelayed(resumeCheck, 2000);
                    }
                }
            };

    private final Runnable resumeCheck = new Runnable() {
        @Override
        public void run() {
            String text = prefs.resumeNote();
            if (text.isEmpty()) return;
            if (System.currentTimeMillis() > prefs.resumeNoteUntil()) {
                prefs.setResumeNote("", 0); // you didn't play it in time
                return;
            }
            if (audio.isMusicActive()) {   // something has started playing
                prefs.setResumeNote("", 0);
                showNote(text, RESUME_NOTE_MS);
                return;
            }
            main.postDelayed(this, 1000);
        }
    };

    // ---------------------------------------------------------------- the cat flap

    private final Runnable catPoll = new Runnable() {
        @Override
        public void run() {
            main.removeCallbacks(this);
            if (power.isInteractive()) {
                final String url = feed("/cats");
                if (url != null) {
                    net.execute(new Runnable() {
                        @Override
                        public void run() {
                            try {
                                final JSONArray cats = new JSONObject(AddonClient.get(url)).optJSONArray("cats");
                                main.post(new Runnable() {
                                    @Override
                                    public void run() {
                                        catsChanged(cats);
                                    }
                                });
                            } catch (Exception ignored) {
                                // lucapi blipped; try again next time
                            }
                        }
                    });
                }
                main.postDelayed(this, CAT_POLL_MS);
            }
            // While the screen is off we stop; turning it on starts us again.
        }
    };

    // ---------------------------------------------------------------- calendar and reminder pop-ups

    private void fetchAlerts() {
        alertsFetchedAt = System.currentTimeMillis();
        final String url = feed("/alerts");
        if (url == null) return;
        net.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    JSONArray a = new JSONObject(AddonClient.get(url)).optJSONArray("alerts");
                    final java.util.List<Object[]> got = new java.util.ArrayList<>();
                    for (int i = 0; a != null && i < a.length(); i++) {
                        JSONObject o = a.optJSONObject(i);
                        if (o == null) continue;
                        got.add(new Object[]{o.optString("id"), parseIso(o.optString("at")), o.optString("text")});
                    }
                    main.post(new Runnable() {
                        @Override
                        public void run() {
                            alertsDue.clear();
                            alertsDue.addAll(got);
                            showDueAlerts();
                        }
                    });
                } catch (Exception e) {
                    Log.w("EmberDim", "couldn't read alerts: " + e);
                }
            }
        });
    }

    /** Shows any alert whose time has come and that hasn't been shown yet (remembered across restarts). */
    private void showDueAlerts() {
        if (!power.isInteractive()) return;
        long now = System.currentTimeMillis();
        java.util.Set<String> shown = prefs.shownAlerts();
        boolean changed = false;
        for (Object[] a : alertsDue) {
            String id = (String) a[0];
            if ((Long) a[1] > now || shown.contains(id)) continue;
            shown.add(id);
            changed = true;
            showNote((String) a[2], ALERT_NOTE_MS);
        }
        if (changed) prefs.setShownAlerts(shown);
    }

    private void catsChanged(JSONArray cats) {
        if (cats == null) return;
        StringBuilder msg = new StringBuilder();
        for (int i = 0; i < cats.length(); i++) {
            JSONObject c = cats.optJSONObject(i);
            if (c == null || "Unknown".equals(c.optString("detail"))) continue;
            String name = c.optString("name");
            boolean home = c.optBoolean("home");
            Boolean before = catsHome.put(name, home);
            if (catsKnown && before != null && before != home) {
                if (msg.length() > 0) msg.append("  ·  ");
                msg.append(name).append(home ? " came in" : " went out");
            }
        }
        catsKnown = true;
        if (msg.length() > 0) showNote(msg.toString(), CAT_NOTE_MS);
    }

    private String feed(String path) {
        return prefs.feedConfigured() ? prefs.feedUrl() + path : null;
    }

    // ---------------------------------------------------------------- the layer

    private void apply(int level, boolean announce) {
        prefs.setDimLevel(level);
        int target = Math.round(LEVELS[level] * 255 / 100f);
        if (target > 0 || announce) ensureLayer();
        if (layer == null) return;
        if (fade != null) fade.cancel();
        fade = ValueAnimator.ofInt(shownAlpha, target);
        fade.setDuration(300);
        fade.addUpdateListener(new ValueAnimator.AnimatorUpdateListener() {
            @Override
            public void onAnimationUpdate(ValueAnimator a) {
                shownAlpha = (Integer) a.getAnimatedValue();
                if (layer != null) layer.setBackgroundColor(Color.argb(shownAlpha, 0, 0, 0));
            }
        });
        fade.start();
        if (announce) say(level == 0 ? NAMES[0] : NAMES[level] + "  " + LEVELS[level] + "%");
        scheduleDrop(1800);
    }

    /** When nothing is dimmed or showing, take the layer away completely so it costs nothing. */
    private final Runnable dropIfIdle = new Runnable() {
        @Override
        public void run() {
            if (prefs.dimLevel() == 0 && System.currentTimeMillis() >= noteUntil) removeLayer();
        }
    };

    private void scheduleDrop(long ms) {
        main.removeCallbacks(dropIfIdle);
        main.postDelayed(dropIfIdle, Math.max(ms, noteUntil - System.currentTimeMillis() + 800));
    }

    /** The dimmer's own short message, bottom centre. */
    private void say(String s) {
        ensureLayer();
        if (label == null) return;
        label.setText(s);
        label.animate().cancel();
        label.setAlpha(1f);
        label.animate().alpha(0f).setStartDelay(1100).setDuration(500).start();
        scheduleDrop(1800);
    }

    /** A note, top-right, for a while. */
    private void showNote(String s, final long ms) {
        if (System.currentTimeMillis() < noteUntil) { // one at a time: wait for the current note to go
            notesWaiting.add(new Object[]{s, ms});
            return;
        }
        ensureLayer();
        if (note == null) return;
        note.setText(s);
        note.animate().cancel();
        note.setAlpha(0f);
        final TextView n = note;
        n.animate().alpha(1f).setStartDelay(0).setDuration(300).withEndAction(new Runnable() {
            @Override
            public void run() {
                n.animate().alpha(0f).setStartDelay(ms).setDuration(600).withEndAction(new Runnable() {
                    @Override
                    public void run() {
                        noteUntil = 0;
                        if (!notesWaiting.isEmpty()) {
                            Object[] next = notesWaiting.remove(0);
                            showNote((String) next[0], (Long) next[1]);
                        } else {
                            scheduleDrop(300);
                        }
                    }
                }).start();
            }
        }).start();
        noteUntil = System.currentTimeMillis() + ms + 700;
        scheduleDrop(ms + 900);
    }

    private TextView pill(float d) {
        TextView t = new TextView(this);
        t.setTextColor(0xFFF3E7D8);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        t.setPadding(Math.round(18 * d), Math.round(8 * d), Math.round(18 * d), Math.round(8 * d));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(0xE01A1410);
        bg.setCornerRadius(99 * d);
        t.setBackground(bg);
        t.setAlpha(0f);
        return t;
    }

    private void ensureLayer() {
        if (layer != null) return;
        layer = new FrameLayout(this);
        layer.setBackgroundColor(Color.argb(shownAlpha, 0, 0, 0));
        float d = getResources().getDisplayMetrics().density;

        label = pill(d);
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT);
        lp.gravity = Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL;
        lp.bottomMargin = Math.round(48 * d);
        layer.addView(label, lp);

        note = pill(d);
        FrameLayout.LayoutParams np = new FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT);
        np.gravity = Gravity.TOP | Gravity.END;
        np.topMargin = Math.round(32 * d);
        np.rightMargin = Math.round(40 * d);
        layer.addView(note, np);

        WindowManager.LayoutParams wp = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        try {
            wm.addView(layer, wp);
        } catch (Exception e) {
            Log.w("EmberDim", "couldn't add the layer: " + e);
            layer = null;
            label = null;
            note = null;
        }
    }

    private void removeLayer() {
        if (layer == null) return;
        try {
            wm.removeView(layer);
        } catch (Exception ignored) {
        }
        layer = null;
        label = null;
        note = null;
        shownAlpha = 0;
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        // Only here for the remote button and the layer.
    }

    @Override
    public void onInterrupt() {
    }
}
