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
 *    "Winnie came in" / "Elvis went out" from the cat flap, and calendar and reminder alerts (10 seconds each,
 *    12h / 1h / 30 min before and getting more urgent; early shifts 9h before with when to be up).
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
    private TextView label, note, catNote;
    private long catUntil;
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
                        String wake = o.optString("wake", "");
                        got.add(new Object[]{o.optString("id"), parseIso(o.optString("at")), parseIso(o.optString("until")),
                                parseIso(o.optString("start")), o.optString("title"), o.optString("where"),
                                o.optString("kind"), o.optBoolean("shift"), o.optInt("level", 1),
                                wake.isEmpty() ? 0L : parseIso(wake)});
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
            if ((Long) a[1] > now || (Long) a[2] <= now || shown.contains(id)) continue;
            shown.add(id);
            changed = true;
            showNote(alertText(a, now), ALERT_NOTE_MS, (Integer) a[8]);
        }
        if (changed) prefs.setShownAlerts(shown);
    }

    /** Words for an alert, worked out when it's shown so the time left is right even if the TV was off. */
    private static String alertText(Object[] a, long now) {
        long start = (Long) a[3], wake = (Long) a[9];
        String title = (String) a[4], where = (String) a[5], kind = (String) a[6];
        boolean shift = (Boolean) a[7];
        int level = (Integer) a[8];
        String at = new SimpleDateFormat("HH:mm", Locale.UK).format(start);
        String place = where.isEmpty() ? "" : "  \u00b7  " + where;
        if (wake > 0) {
            String up = new SimpleDateFormat("HH:mm", Locale.UK).format(wake);
            return "Early shift: " + title + " at " + at + "  \u00b7  you need to be up at " + up + ", in " + span(wake - now);
        }
        String left = span(start - now);
        if ("rem".equals(kind)) {
            return level >= 3 ? "Reminder in " + left + ": " + title + "!" : "Reminder in " + left + ": " + title + " (" + at + ")";
        }
        String what = shift ? "Shift: " + title : title;
        switch (level) {
            case 1: return "In " + left + "  \u00b7  " + what + " at " + at + place;
            case 2: return "In " + left + ": " + what + " at " + at + place;
            default: return what + " starts in " + left + "!  " + at + place;
        }
    }

    /** 41 min, 1h 05m, 11h 40m */
    private static String span(long ms) {
        long mins = Math.max(1, Math.round(ms / 60_000.0));
        if (mins < 60) return mins + " min";
        return (mins / 60) + "h " + String.format(Locale.UK, "%02d", mins % 60) + "m";
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
        if (msg.length() > 0) showCatNote(msg.toString());
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
            long now = System.currentTimeMillis();
            if (prefs.dimLevel() == 0 && now >= noteUntil && now >= catUntil) removeLayer();
        }
    };

    private void scheduleDrop(long ms) {
        main.removeCallbacks(dropIfIdle);
        long now = System.currentTimeMillis();
        main.postDelayed(dropIfIdle, Math.max(ms, Math.max(noteUntil, catUntil) - now + 800));
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
    private void showNote(String s, long ms) {
        showNote(s, ms, 0);
    }

    /** level 0 = plain note, 1 = calm alert, 2 = firmer (amber), 3 = urgent (red, bigger, pulses). */
    private void showNote(String s, final long ms, final int level) {
        if (System.currentTimeMillis() < noteUntil) { // one at a time: wait for the current note to go
            notesWaiting.add(new Object[]{s, ms, level});
            if (level >= 3) { // urgent ones jump the queue
                notesWaiting.add(0, notesWaiting.remove(notesWaiting.size() - 1));
            }
            return;
        }
        ensureLayer();
        if (note == null) return;
        styleNote(note, level);
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
                            showNote((String) next[0], (Long) next[1], (Integer) next[2]);
                        } else {
                            scheduleDrop(300);
                        }
                    }
                }).start();
            }
        }).start();
        if (level >= 3) { // a few slow pulses so it can't be missed
            final TextView p = note;
            p.setScaleX(1f);
            p.setScaleY(1f);
            p.setPivotX(p.getWidth() > 0 ? p.getWidth() : 600);
            p.setPivotY(0);
            for (int i = 0; i < 3; i++) {
                main.postDelayed(new Runnable() {
                    @Override
                    public void run() {
                        p.animate().scaleX(1.06f).scaleY(1.06f).setDuration(350).withEndAction(new Runnable() {
                            @Override
                            public void run() {
                                p.animate().scaleX(1f).scaleY(1f).setDuration(350).start();
                            }
                        }).start();
                    }
                }, 400 + i * 1200L);
            }
        }
        noteUntil = System.currentTimeMillis() + ms + 700;
        scheduleDrop(ms + 900);
    }

    /** The cats get their own quiet corner, bottom-left, separate from alerts (no queue, smaller, softer). */
    private void showCatNote(String s) {
        ensureLayer();
        if (catNote == null) return;
        catNote.setText(s);
        catNote.animate().cancel();
        catNote.setAlpha(0f);
        final TextView c = catNote;
        c.animate().alpha(0.92f).setStartDelay(0).setDuration(400).withEndAction(new Runnable() {
            @Override
            public void run() {
                c.animate().alpha(0f).setStartDelay(CAT_NOTE_MS).setDuration(800).start();
            }
        }).start();
        catUntil = System.currentTimeMillis() + CAT_NOTE_MS + 1300;
        scheduleDrop(CAT_NOTE_MS + 1500);
    }

    private void styleNote(TextView t, int level) {
        float d = getResources().getDisplayMetrics().density;
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(99 * d);
        int textColour = 0xFFF3E7D8;
        float size = 15;
        switch (level) {
            case 2:   // firmer: warm amber edge, a bit bigger
                bg.setColor(0xF0261708);
                bg.setStroke(Math.round(2 * d), 0xFFE8A15A);
                textColour = 0xFFFFE2C2;
                size = 17;
                break;
            case 3:   // urgent: red, bigger, white text
                bg.setColor(0xF5B3261E);
                bg.setStroke(Math.round(2 * d), 0xFFFF8A80);
                textColour = 0xFFFFFFFF;
                size = 20;
                break;
            default:  // plain notes and the calm first alert
                bg.setColor(0xE01A1410);
        }
        t.setBackground(bg);
        t.setTextColor(textColour);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, size);
        int padH = Math.round((level >= 3 ? 24 : 18) * d), padV = Math.round((level >= 3 ? 12 : 8) * d);
        t.setPadding(padH, padV, padH, padV);
        t.setTypeface(Typeface.create("sans-serif-medium", level >= 2 ? Typeface.BOLD : Typeface.NORMAL));
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

        catNote = pill(d);
        catNote.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        catNote.setTextColor(0xFFE6D6C4);
        catNote.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
        catNote.setPadding(Math.round(14 * d), Math.round(6 * d), Math.round(14 * d), Math.round(6 * d));
        GradientDrawable cb = new GradientDrawable();
        cb.setColor(0xB31A1410);
        cb.setCornerRadius(99 * d);
        catNote.setBackground(cb);
        FrameLayout.LayoutParams cp = new FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT);
        cp.gravity = Gravity.BOTTOM | Gravity.START;
        cp.leftMargin = Math.round(40 * d);
        cp.bottomMargin = Math.round(32 * d);
        layer.addView(catNote, cp);

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
            catNote = null;
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
        catNote = null;
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
