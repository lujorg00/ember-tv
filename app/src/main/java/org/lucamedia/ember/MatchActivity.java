package org.lucamedia.ember;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * "What shall we watch?" on the TV: shows a QR code; everyone swipes on their phone; anything you all liked appears
 * here as a row. Select one to open it in Stremio.
 */
public class MatchActivity extends Activity {
    private static final int BG = 0xFF0E0B09, SURFACE = 0xFF1C1612, TEXT = 0xFFF3E7DA, MUTED = 0xFFA8968A, ACCENT = 0xFFF0A04B;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private Prefs prefs;
    private ImageLoader images;
    private float density;
    private String code;
    private TextView codeText, people, hint;
    private ImageView qr;
    private LinearLayout strip;
    private String shown = "";

    private final Runnable poll = new Runnable() {
        @Override
        public void run() {
            refresh();
            main.postDelayed(this, 2000);
        }
    };

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        prefs = new Prefs(this);
        images = ImageLoader.get(this);
        density = getResources().getDisplayMetrics().density;

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(BG);
        root.setPadding(dp(48), dp(36), dp(48), dp(24));

        TextView title = text(30, TEXT);
        title.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        title.setText("What shall we watch?");
        root.addView(title);
        TextView sub = text(14, MUTED);
        sub.setText("Everyone swipes on their phone. Anything you all like appears below.");
        root.addView(sub);

        LinearLayout top = new LinearLayout(this);
        top.setGravity(Gravity.CENTER_VERTICAL);
        top.setPadding(0, dp(22), 0, dp(18));
        root.addView(top);
        qr = new ImageView(this);
        qr.setBackgroundColor(0xFFFFFFFF);
        qr.setPadding(dp(6), dp(6), dp(6), dp(6));
        top.addView(qr, new LinearLayout.LayoutParams(dp(170), dp(170)));
        LinearLayout info = new LinearLayout(this);
        info.setOrientation(LinearLayout.VERTICAL);
        info.setPadding(dp(28), 0, 0, 0);
        top.addView(info);
        hint = text(15, TEXT);
        hint.setText("Scan with your phone's camera");
        info.addView(hint);
        codeText = text(46, ACCENT);
        codeText.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
        codeText.setLetterSpacing(0.3f);
        codeText.setText("…");
        info.addView(codeText);
        people = text(14, MUTED);
        people.setText("Waiting for people to join…");
        info.addView(people);

        TextView mt = text(17, TEXT);
        mt.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        mt.setText("Matches");
        root.addView(mt);
        HorizontalScrollView hs = new HorizontalScrollView(this);
        hs.setHorizontalScrollBarEnabled(false);
        hs.setClipToPadding(false);
        strip = new LinearLayout(this);
        strip.setPadding(0, dp(10), dp(48), dp(10));
        strip.setClipChildren(false);
        hs.addView(strip);
        root.addView(hs);
        TextView none = text(13, MUTED);
        none.setText("None yet. Needs at least two people.");
        strip.addView(none);

        setContentView(root);
        start();
    }

    private void start() {
        if (!prefs.feedConfigured()) {
            hint.setText("Set lucapi's address in Ember settings first.");
            return;
        }
        final String url = prefs.feedUrl() + "/match/new";
        worker.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    java.net.HttpURLConnection c = (java.net.HttpURLConnection) new java.net.URL(url).openConnection();
                    c.setRequestMethod("POST");
                    c.setDoOutput(true);
                    c.setConnectTimeout(8000);
                    c.setReadTimeout(30000);
                    c.setRequestProperty("Content-Type", "application/json");
                    c.getOutputStream().write("{}".getBytes());
                    java.io.InputStream in = c.getInputStream();
                    java.io.ByteArrayOutputStream bos = new java.io.ByteArrayOutputStream();
                    byte[] buf = new byte[8192];
                    int n;
                    while ((n = in.read(buf)) > 0) bos.write(buf, 0, n);
                    final String got = new JSONObject(bos.toString("UTF-8")).optString("code");
                    main.post(new Runnable() {
                        @Override
                        public void run() {
                            code = got;
                            codeText.setText(code);
                            String host = prefs.feedUrl().replaceFirst("^https?://", "");
                            hint.setText("Scan with your phone's camera, or go to  " + host + "/m/" + code);
                            images.into(qr, prefs.feedUrl() + "/match/" + code + "/qr.png", dp(170), dp(170));
                            main.post(poll);
                        }
                    });
                } catch (Exception e) {
                    main.post(new Runnable() {
                        @Override
                        public void run() {
                            hint.setText("Couldn't reach lucapi.");
                        }
                    });
                }
            }
        });
    }

    private void refresh() {
        if (code == null) return;
        final String url = prefs.feedUrl() + "/match/" + code;
        worker.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    final JSONObject st = new JSONObject(AddonClient.get(url));
                    main.post(new Runnable() {
                        @Override
                        public void run() {
                            show(st);
                        }
                    });
                } catch (Exception ignored) {
                    // try again in a moment
                }
            }
        });
    }

    private void show(JSONObject st) {
        JSONArray ps = st.optJSONArray("people");
        StringBuilder sb = new StringBuilder();
        for (int i = 0; ps != null && i < ps.length(); i++) {
            JSONObject p = ps.optJSONObject(i);
            if (sb.length() > 0) sb.append("     ");
            sb.append(p.optString("name")).append("  ").append(p.optInt("swiped")).append("/").append(st.optInt("deckSize"));
        }
        people.setText(sb.length() == 0 ? "Waiting for people to join…" : sb.toString());
        JSONArray ms = st.optJSONArray("matches");
        StringBuilder key = new StringBuilder();
        for (int i = 0; ms != null && i < ms.length(); i++) key.append(ms.optJSONObject(i).optString("id")).append(',');
        if (key.toString().equals(shown)) return;
        boolean grew = key.length() > shown.length();
        shown = key.toString();
        strip.removeAllViews();
        if (ms == null || ms.length() == 0) {
            TextView none = text(13, MUTED);
            none.setText("None yet.");
            strip.addView(none);
            return;
        }
        for (int i = 0; i < ms.length(); i++) {
            final Meta m = Meta.from(ms.optJSONObject(i), "movie");
            FrameLayout card = new FrameLayout(this);
            GradientDrawable bg = new GradientDrawable();
            bg.setColor(SURFACE);
            bg.setCornerRadius(dp(8));
            card.setBackground(bg);
            card.setClipToOutline(true);
            card.setFocusable(true);
            card.setClickable(true);
            ImageView img = new ImageView(this);
            img.setScaleType(ImageView.ScaleType.CENTER_CROP);
            card.addView(img, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
            images.into(img, m.poster, dp(110), dp(165));
            card.setOnFocusChangeListener(new View.OnFocusChangeListener() {
                @Override
                public void onFocusChange(View v, boolean has) {
                    GradientDrawable ring = new GradientDrawable();
                    ring.setCornerRadius(dp(8));
                    ring.setStroke(dp(2), ACCENT);
                    v.setForeground(has ? ring : null);
                    v.animate().scaleX(has ? 1.08f : 1f).scaleY(has ? 1.08f : 1f).setDuration(140).start();
                    if (has) hint.setText(m.name + "   \u00b7   " + m.subtitle());
                }
            });
            card.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    String uri = prefs.openUri().replace("{type}", m.type).replace("{id}", m.id);
                    try {
                        startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(uri)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                    } catch (ActivityNotFoundException e) {
                        Toast.makeText(MatchActivity.this, "Is Stremio installed?", Toast.LENGTH_LONG).show();
                    }
                }
            });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(dp(110), dp(165));
            lp.rightMargin = dp(14);
            strip.addView(card, lp);
        }
        if (grew) Toast.makeText(this, "It's a match!", Toast.LENGTH_SHORT).show();
        if (getCurrentFocus() == null) strip.getChildAt(0).requestFocus();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        main.removeCallbacksAndMessages(null);
        worker.shutdownNow();
    }

    private TextView text(float sp, int colour) {
        TextView t = new TextView(this);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(colour);
        return t;
    }

    private int dp(float v) {
        return Math.round(v * density);
    }
}
