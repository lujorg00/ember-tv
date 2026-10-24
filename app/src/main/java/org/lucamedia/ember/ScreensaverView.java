package org.lucamedia.ember;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Handler;
import android.os.Looper;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.List;
import java.util.Locale;
import java.util.Random;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Ember's screensaver: your photos cycling full screen, with the clock, what's coming up in your
 * calendars, and the state of lucapi's services. Used by EmberDream (the real screensaver) and by
 * the preview in settings.
 */
final class ScreensaverView extends FrameLayout {

    private static final int BG = 0xFF0B0908;
    private static final int TEXT = 0xFFF3E7DA;
    private static final int SOFT = 0xFFE6D5C6;
    private static final int ACCENT = 0xFFF0A04B;
    private static final int UP = 0xFF8FD18B;
    private static final int DOWN = 0xFFFF7A6B;
    private static final long FEED_EVERY_MS = 5 * 60 * 1000L;
    private static final long SHIFT_EVERY_MS = 3 * 60 * 1000L;

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Random random = new Random();
    private final Prefs prefs;
    private final ImageLoader images;
    private final float density;
    private final int screenW;
    private final int screenH;

    private final ImageView[] photoViews = new ImageView[2];
    private int frontPhoto;
    private final LinearLayout overlay;
    private final TextView clock;
    private final TextView date;
    private final LinearLayout eventsBox;
    private final LinearLayout servicesBox;
    private final TextView health;
    private final TextView credit;
    private final TextView message;

    private List<String[]> photos = new ArrayList<>(); // {url, credit}
    private int photoIndex = -1;
    private long photoMs = 30_000;
    private boolean running;

    private final Runnable clockTick = new Runnable() {
        @Override
        public void run() {
            updateClock();
            main.postDelayed(this, 15_000);
        }
    };
    private final Runnable feedTick = new Runnable() {
        @Override
        public void run() {
            fetchFeed();
            main.postDelayed(this, FEED_EVERY_MS);
        }
    };
    private final Runnable photoTick = new Runnable() {
        @Override
        public void run() {
            nextPhoto();
            main.postDelayed(this, photoMs);
        }
    };
    private final Runnable shiftTick = new Runnable() {
        @Override
        public void run() {
            // Nudge the text around a little so nothing burns into the panel.
            overlay.animate().translationX(dp(random.nextInt(25) - 12)).translationY(dp(random.nextInt(17) - 8))
                    .setDuration(2000).start();
            main.postDelayed(this, SHIFT_EVERY_MS);
        }
    };

    ScreensaverView(Context ctx) {
        super(ctx);
        prefs = new Prefs(ctx);
        images = ImageLoader.get(ctx);
        density = ctx.getResources().getDisplayMetrics().density;
        screenW = ctx.getResources().getDisplayMetrics().widthPixels;
        screenH = ctx.getResources().getDisplayMetrics().heightPixels;
        setBackgroundColor(BG);

        // A warm gradient shows until the first photo arrives (or if there are none).
        View base = new View(ctx);
        base.setBackground(new GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM,
                new int[]{0xFF1B2833, 0xFF3E3A44, 0xFF8A5A3C, 0xFF2A1A12, BG}));
        addView(base, match());

        // Photos get their own layer so swapping them never covers the text.
        FrameLayout photoLayer = new FrameLayout(ctx);
        addView(photoLayer, match());
        for (int i = 0; i < 2; i++) {
            ImageView iv = new ImageView(ctx);
            iv.setScaleType(ImageView.ScaleType.CENTER_CROP);
            iv.setAlpha(0f);
            photoViews[i] = iv;
            photoLayer.addView(iv, match());
        }

        View shadeLeft = new View(ctx);
        shadeLeft.setBackground(new GradientDrawable(GradientDrawable.Orientation.LEFT_RIGHT,
                new int[]{0xB30B0908, 0x330B0908, 0x000B0908}));
        addView(shadeLeft, new LayoutParams((int) (screenW * 0.55f), ViewGroup.LayoutParams.MATCH_PARENT));
        View shadeBottom = new View(ctx);
        shadeBottom.setBackground(new GradientDrawable(GradientDrawable.Orientation.BOTTOM_TOP,
                new int[]{0xCC0B0908, 0x000B0908}));
        LayoutParams sbLp = new LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (int) (screenH * 0.35f));
        sbLp.gravity = Gravity.BOTTOM;
        addView(shadeBottom, sbLp);
        View shadeTop = new View(ctx);
        shadeTop.setBackground(new GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM,
                new int[]{0x990B0908, 0x000B0908}));
        addView(shadeTop, new LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (int) (screenH * 0.3f)));

        // Everything that moves for burn-in protection lives in one overlay.
        overlay = new LinearLayout(ctx);
        overlay.setOrientation(LinearLayout.VERTICAL);
        FrameLayout content = new FrameLayout(ctx);
        overlay.addView(content, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        addView(overlay, match());

        // Clock, top-right.
        LinearLayout clockBox = new LinearLayout(ctx);
        clockBox.setOrientation(LinearLayout.VERTICAL);
        clockBox.setGravity(Gravity.END);
        LayoutParams cLp = wrap();
        cLp.gravity = Gravity.TOP | Gravity.END;
        cLp.topMargin = dp(28);
        cLp.rightMargin = dp(44);
        content.addView(clockBox, cLp);
        clock = text(72, TEXT, "sans-serif-thin");
        clockBox.addView(clock);
        date = text(16, SOFT, "sans-serif");
        clockBox.addView(date);

        // Calendar, top-left.
        eventsBox = new LinearLayout(ctx);
        eventsBox.setOrientation(LinearLayout.VERTICAL);
        LayoutParams eLp = new LayoutParams((int) (screenW * 0.42f), ViewGroup.LayoutParams.WRAP_CONTENT);
        eLp.topMargin = dp(36);
        eLp.leftMargin = dp(44);
        content.addView(eventsBox, eLp);

        // Services, bottom-left.
        LinearLayout bottom = new LinearLayout(ctx);
        bottom.setOrientation(LinearLayout.VERTICAL);
        LayoutParams bLp = new LayoutParams((int) (screenW * 0.7f), ViewGroup.LayoutParams.WRAP_CONTENT);
        bLp.gravity = Gravity.BOTTOM | Gravity.START;
        bLp.leftMargin = dp(44);
        bLp.bottomMargin = dp(30);
        content.addView(bottom, bLp);

        LinearLayout piHead = new LinearLayout(ctx);
        piHead.setOrientation(LinearLayout.HORIZONTAL);
        piHead.setGravity(Gravity.CENTER_VERTICAL);
        TextView piLabel = text(12, SOFT, "sans-serif-medium");
        piLabel.setText("LUCAPI");
        piLabel.setLetterSpacing(0.2f);
        piHead.addView(piLabel);
        health = text(13, SOFT, "sans-serif");
        health.setPadding(dp(12), 0, 0, 0);
        piHead.addView(health);
        bottom.addView(piHead);

        servicesBox = new LinearLayout(ctx);
        servicesBox.setOrientation(LinearLayout.VERTICAL);
        servicesBox.setPadding(0, dp(6), 0, 0);
        bottom.addView(servicesBox);

        credit = text(11, SOFT, "sans-serif");
        credit.setAlpha(0.7f);
        credit.setMaxLines(1);
        credit.setEllipsize(TextUtils.TruncateAt.END);
        credit.setGravity(Gravity.END);
        LayoutParams crLp = new LayoutParams((int) (screenW * 0.35f), ViewGroup.LayoutParams.WRAP_CONTENT);
        crLp.gravity = Gravity.BOTTOM | Gravity.END;
        crLp.rightMargin = dp(44);
        crLp.bottomMargin = dp(30);
        content.addView(credit, crLp);

        message = text(15, SOFT, "sans-serif");
        LayoutParams mLp = wrap();
        mLp.gravity = Gravity.CENTER;
        content.addView(message, mLp);

        updateClock();
        if (!prefs.feedConfigured()) {
            message.setText("Set your lucapi feed address in Ember settings to see your calendar, Pi status and photos.");
        }
    }

    void start() {
        if (running) return;
        running = true;
        main.post(clockTick);
        main.post(feedTick);
        main.postDelayed(shiftTick, SHIFT_EVERY_MS);
    }

    void stop() {
        running = false;
        main.removeCallbacks(clockTick);
        main.removeCallbacks(feedTick);
        main.removeCallbacks(photoTick);
        main.removeCallbacks(shiftTick);
        worker.shutdownNow();
    }

    // ---------------------------------------------------------------- feed

    private void fetchFeed() {
        if (!prefs.feedConfigured()) return;
        final String url = prefs.feedUrl() + "/screensaver";
        worker.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    final JSONObject o = new JSONObject(AddonClient.get(url));
                    main.post(new Runnable() {
                        @Override
                        public void run() {
                            if (running) apply(o);
                        }
                    });
                } catch (final Exception e) {
                    main.post(new Runnable() {
                        @Override
                        public void run() {
                            if (running && eventsBox.getChildCount() == 0) {
                                message.setText("Can't reach lucapi right now (" + e.getClass().getSimpleName() + ")");
                            }
                        }
                    });
                }
            }
        });
    }

    private void apply(JSONObject o) {
        message.setText("");
        renderEvents(o.optJSONArray("events"));
        renderServices(o.optJSONArray("services"), o.optJSONObject("health"));

        photoMs = Math.max(8, o.optInt("secondsPerPhoto", 30)) * 1000L;
        List<String[]> fresh = new ArrayList<>();
        JSONArray ph = o.optJSONArray("photos");
        for (int i = 0; ph != null && i < ph.length(); i++) {
            JSONObject p = ph.optJSONObject(i);
            if (p != null && !p.optString("url").isEmpty()) fresh.add(new String[]{p.optString("url"), p.optString("credit")});
        }
        boolean first = photos.isEmpty();
        photos = fresh;
        if (first && !photos.isEmpty()) {
            main.removeCallbacks(photoTick);
            main.post(photoTick);
        }
    }

    private void renderEvents(JSONArray events) {
        eventsBox.removeAllViews();
        TextView head = text(12, SOFT, "sans-serif-medium");
        head.setText("COMING UP");
        head.setLetterSpacing(0.2f);
        head.setPadding(0, 0, 0, dp(8));
        eventsBox.addView(head);

        if (events == null || events.length() == 0) {
            TextView none = text(18, TEXT, "sans-serif");
            none.setText("Nothing in the next week");
            eventsBox.addView(none);
            return;
        }
        String lastDay = null;
        int shown = 0;
        for (int i = 0; i < events.length() && shown < 7; i++) {
            JSONObject e = events.optJSONObject(i);
            if (e == null) continue;
            String day = e.optString("day");
            if (!day.equals(lastDay)) {
                TextView d = text(13, ACCENT, "sans-serif-medium");
                d.setText(day.toUpperCase(Locale.UK));
                d.setLetterSpacing(0.12f);
                d.setPadding(0, lastDay == null ? 0 : dp(10), 0, dp(3));
                eventsBox.addView(d);
                lastDay = day;
            }
            LinearLayout row = new LinearLayout(getContext());
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(0, dp(2), 0, dp(2));

            View dot = new View(getContext());
            GradientDrawable dd = new GradientDrawable();
            dd.setShape(GradientDrawable.OVAL);
            dd.setColor(parseColour(e.optString("colour"), ACCENT));
            dot.setBackground(dd);
            LinearLayout.LayoutParams dotLp = new LinearLayout.LayoutParams(dp(7), dp(7));
            dotLp.rightMargin = dp(10);
            row.addView(dot, dotLp);

            TextView t = text(17, SOFT, "sans-serif");
            t.setText(e.optString("time"));
            row.addView(t, new LinearLayout.LayoutParams(dp(70), ViewGroup.LayoutParams.WRAP_CONTENT));

            TextView title = text(18, TEXT, "sans-serif-medium");
            title.setText(e.optString("title"));
            title.setSingleLine(true);
            title.setEllipsize(TextUtils.TruncateAt.END);
            row.addView(title, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
            eventsBox.addView(row);
            shown++;
        }
    }

    private void renderServices(JSONArray services, JSONObject h) {
        servicesBox.removeAllViews();
        StringBuilder hs = new StringBuilder();
        if (h != null) {
            if (h.has("tempC")) hs.append(h.optInt("tempC")).append("°C");
            if (h.has("diskPct")) hs.append(hs.length() > 0 ? "  ·  " : "").append("disk ").append(h.optInt("diskPct")).append('%');
            if (h.has("uptime")) hs.append(hs.length() > 0 ? "  ·  " : "").append("up ").append(h.optString("uptime"));
        }
        health.setText(hs.toString());

        if (services == null || services.length() == 0) return;
        // Wrap the chips onto lines of four so a long list stays tidy.
        LinearLayout line = null;
        for (int i = 0; i < services.length(); i++) {
            JSONObject s = services.optJSONObject(i);
            if (s == null) continue;
            if (i % 4 == 0) {
                line = new LinearLayout(getContext());
                line.setOrientation(LinearLayout.HORIZONTAL);
                line.setPadding(0, dp(3), 0, dp(3));
                servicesBox.addView(line);
            }
            boolean up = s.optBoolean("up");
            LinearLayout chip = new LinearLayout(getContext());
            chip.setOrientation(LinearLayout.HORIZONTAL);
            chip.setGravity(Gravity.CENTER_VERTICAL);
            chip.setPadding(dp(10), dp(5), dp(12), dp(5));
            GradientDrawable cb = new GradientDrawable();
            cb.setColor(up ? 0x660B0908 : 0x99401410);
            cb.setCornerRadius(dp(14));
            chip.setBackground(cb);

            View dot = new View(getContext());
            GradientDrawable dd = new GradientDrawable();
            dd.setShape(GradientDrawable.OVAL);
            dd.setColor(up ? UP : DOWN);
            dot.setBackground(dd);
            LinearLayout.LayoutParams dotLp = new LinearLayout.LayoutParams(dp(8), dp(8));
            dotLp.rightMargin = dp(8);
            chip.addView(dot, dotLp);

            TextView name = text(14, up ? TEXT : DOWN, "sans-serif-medium");
            name.setText(up ? s.optString("name") : s.optString("name") + " \u2014 " + s.optString("state", "down"));
            chip.addView(name);

            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            lp.rightMargin = dp(8);
            line.addView(chip, lp);
        }
    }

    // ---------------------------------------------------------------- photos

    private void nextPhoto() {
        if (photos.isEmpty()) return;
        photoIndex = (photoIndex + 1) % photos.size();
        final String[] p = photos.get(photoIndex);
        images.load(p[0], screenW, screenH, new ImageLoader.Callback() {
            @Override
            public void onLoaded(Bitmap bmp) {
                if (!running) return;
                showPhoto(bmp, p[1]);
            }
        });
    }

    private void showPhoto(Bitmap bmp, String photoCredit) {
        final ImageView back = photoViews[1 - frontPhoto];
        final ImageView front = photoViews[frontPhoto];
        back.setImageBitmap(bmp);
        back.setAlpha(0f);
        back.setScaleX(1f);
        back.setScaleY(1f);
        back.bringToFront(); // within the photo layer only
        back.animate().alpha(1f).setDuration(1500).start();
        // Slow drift so a still photo doesn't sit dead on screen.
        back.animate().scaleX(1.07f).scaleY(1.07f).setDuration(photoMs + 2000).start();
        front.animate().alpha(0f).setDuration(1500).start();
        frontPhoto = 1 - frontPhoto;
        credit.setText(photoCredit == null ? "" : photoCredit);
    }

    // ---------------------------------------------------------------- helpers

    private void updateClock() {
        Calendar c = Calendar.getInstance();
        clock.setText(new SimpleDateFormat("HH:mm", Locale.UK).format(c.getTime()));
        date.setText(DateText.of(c));
    }

    private static int parseColour(String s, int fallback) {
        try {
            return android.graphics.Color.parseColor(s);
        } catch (Exception e) {
            return fallback;
        }
    }

    private TextView text(float sp, int color, String family) {
        TextView t = new TextView(getContext());
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(color);
        t.setTypeface(Typeface.create(family, Typeface.NORMAL));
        t.setShadowLayer(dp(8), 0, dp(1), 0xB3000000);
        return t;
    }

    private LayoutParams match() {
        return new LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
    }

    private LayoutParams wrap() {
        return new LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
    }

    private int dp(float v) {
        return Math.round(v * density);
    }
}
