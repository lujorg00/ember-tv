package org.lucamedia.ember;

import android.accessibilityservice.AccessibilityService;
import android.animation.ValueAnimator;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityEvent;
import android.widget.FrameLayout;
import android.widget.TextView;

import java.util.Calendar;

/**
 * The dimmer: a see-through black layer over everything on screen (Stremio, YouTube, the screensaver),
 * switched by one remote button (the Netflix button, learnt in Ember settings). Presses cycle
 * Off -> Dim -> Heavy -> Off. Every night at midnight it goes to Heavy by itself and lifts again at 8am,
 * unless you've changed it with the button in the meantime.
 */
public class DimService extends AccessibilityService {

    static final int[] LEVELS = {0, 50, 80};       // percent of black over the picture
    static final String[] NAMES = {"Dim off", "Dim", "Heavy dim"};
    private static final int AUTO_LEVEL = 2;       // midnight: heavy
    private static final int AUTO_START_HOUR = 0, AUTO_END_HOUR = 8;

    private final Handler main = new Handler(Looper.getMainLooper());
    private Prefs prefs;
    private WindowManager wm;
    private FrameLayout layer;
    private TextView label;
    private int shownAlpha; // 0..255 currently on screen
    private ValueAnimator fade;

    private final Runnable clock = new Runnable() {
        @Override
        public void run() {
            checkSchedule();
            main.postDelayed(this, 30_000);
        }
    };

    private final BroadcastReceiver screenOn = new BroadcastReceiver() {
        @Override
        public void onReceive(Context c, Intent i) {
            checkSchedule(); // the TV may have slept through midnight or 8am
        }
    };

    @Override
    protected void onServiceConnected() {
        super.onServiceConnected();
        prefs = new Prefs(this);
        wm = (WindowManager) getSystemService(WINDOW_SERVICE);
        registerReceiver(screenOn, new IntentFilter(Intent.ACTION_SCREEN_ON));
        apply(prefs.dimLevel(), false);
        main.post(clock);
    }

    @Override
    public void onDestroy() {
        main.removeCallbacksAndMessages(null);
        try {
            unregisterReceiver(screenOn);
        } catch (Exception ignored) {
        }
        removeLayer();
        super.onDestroy();
    }

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

    /** Midnight to 8am: heavy dim, once per night. At 8am an automatic dim lifts; one you set yourself stays. */
    private void checkSchedule() {
        Calendar c = Calendar.getInstance();
        int hour = c.get(Calendar.HOUR_OF_DAY);
        String night = c.get(Calendar.YEAR) + "-" + c.get(Calendar.DAY_OF_YEAR);
        if (hour >= AUTO_START_HOUR && hour < AUTO_END_HOUR) {
            if (!night.equals(prefs.dimAutoNight())) {
                prefs.setDimAutoNight(night);
                prefs.setDimAuto(true);
                if (prefs.dimLevel() < AUTO_LEVEL) apply(AUTO_LEVEL, true);
            }
        } else if (prefs.dimAuto()) {
            prefs.setDimAuto(false);
            apply(0, false);
        }
    }

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
        main.removeCallbacks(dropIfOff);
        main.postDelayed(dropIfOff, 1800);
    }

    /** When the dimmer is off, take the layer away completely so it costs nothing. */
    private final Runnable dropIfOff = new Runnable() {
        @Override
        public void run() {
            if (prefs.dimLevel() == 0) removeLayer();
        }
    };

    private void say(String s) {
        ensureLayer();
        if (label == null) return;
        label.setText(s);
        label.animate().cancel();
        label.setAlpha(1f);
        label.animate().alpha(0f).setStartDelay(1100).setDuration(500).start();
        main.removeCallbacks(dropIfOff);
        main.postDelayed(dropIfOff, 1800);
    }

    private void ensureLayer() {
        if (layer != null) return;
        layer = new FrameLayout(this);
        layer.setBackgroundColor(Color.argb(shownAlpha, 0, 0, 0));
        float d = getResources().getDisplayMetrics().density;
        label = new TextView(this);
        label.setTextColor(0xFFF3E7D8);
        label.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        label.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        label.setPadding(Math.round(18 * d), Math.round(8 * d), Math.round(18 * d), Math.round(8 * d));
        GradientDrawable pill = new GradientDrawable();
        pill.setColor(0xCC1A1410);
        pill.setCornerRadius(99 * d);
        label.setBackground(pill);
        label.setAlpha(0f);
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT);
        lp.gravity = Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL;
        lp.bottomMargin = Math.round(48 * d);
        layer.addView(label, lp);
        WindowManager.LayoutParams wp = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        try {
            wm.addView(layer, wp);
        } catch (Exception e) {
            Log.w("EmberDim", "couldn't add the dim layer: " + e);
            layer = null;
            label = null;
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
        shownAlpha = 0;
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        // Only here for the remote button and the overlay.
    }

    @Override
    public void onInterrupt() {
    }
}
