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
import android.speech.RecognizerIntent;
import android.text.Editable;
import android.text.TextUtils;
import android.text.TextWatcher;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONObject;

import java.net.URLEncoder;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Search, like Stremio's: the same catalogue Stremio searches (Cinemeta), split into Series and Films.
 * Type with the remote or the keyboard's microphone; the mic button here uses Google's voice input if it's there.
 */
public class SearchActivity extends Activity {

    private static final String CINEMETA = "https://v3-cinemeta.strem.io/catalog/%s/top/search=%s.json";
    private static final int BG = 0xFF0E0B09, SURFACE = 0xFF1C1612, TEXT = 0xFFF3E7DA, MUTED = 0xFFA8968A, ACCENT = 0xFFF0A04B;
    private static final int VOICE = 41;

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private Prefs prefs;
    private ImageLoader images;
    private float density;
    private EditText field;
    private LinearLayout results;
    private TextView status;
    private String lastQuery = "";
    private int generation;

    private final Runnable runSearch = new Runnable() {
        @Override
        public void run() {
            search(field.getText().toString().trim());
        }
    };

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        prefs = new Prefs(this);
        images = ImageLoader.get(this);
        density = getResources().getDisplayMetrics().density;

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(BG);
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setPadding(dp(48), dp(32), 0, 0);
        root.addView(col, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        // The search pill, with a mic beside it.
        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        col.addView(bar);

        field = new EditText(this);
        field.setSingleLine(true);
        field.setHint("Search films and series");
        field.setHintTextColor(MUTED);
        field.setTextColor(TEXT);
        field.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18);
        field.setImeOptions(EditorInfo.IME_ACTION_SEARCH);
        field.setPadding(dp(20), dp(10), dp(20), dp(10));
        field.setBackground(pill(true));
        field.addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence s, int a, int c, int d) {
            }

            public void onTextChanged(CharSequence s, int a, int c, int d) {
            }

            public void afterTextChanged(Editable s) {
                main.removeCallbacks(runSearch);
                main.postDelayed(runSearch, 450); // wait until you pause typing
            }
        });
        field.setOnEditorActionListener(new TextView.OnEditorActionListener() {
            @Override
            public boolean onEditorAction(TextView v, int id, KeyEvent e) {
                main.removeCallbacks(runSearch);
                runSearch.run();
                hideKeyboard();
                focusFirstResult();
                return true;
            }
        });
        bar.addView(field, new LinearLayout.LayoutParams(dp(460), ViewGroup.LayoutParams.WRAP_CONTENT));

        final Intent voice = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(RecognizerIntent.EXTRA_PROMPT, "Say a film or series");
        if (voice.resolveActivity(getPackageManager()) != null) {
            TextView mic = new TextView(this);
            mic.setText("🎙  Speak");
            mic.setTextColor(TEXT);
            mic.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
            mic.setPadding(dp(16), dp(10), dp(16), dp(10));
            mic.setBackground(pill(false));
            mic.setFocusable(true);
            mic.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    try {
                        startActivityForResult(voice, VOICE);
                    } catch (ActivityNotFoundException e) {
                        Toast.makeText(SearchActivity.this, "Voice input isn't available", Toast.LENGTH_SHORT).show();
                    }
                }
            });
            LinearLayout.LayoutParams ml = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            ml.leftMargin = dp(12);
            bar.addView(mic, ml);
        }

        status = text(13, MUTED);
        status.setPadding(0, dp(14), 0, 0);
        col.addView(status);

        ScrollView scroll = new ScrollView(this);
        scroll.setVerticalScrollBarEnabled(false);
        results = new LinearLayout(this);
        results.setOrientation(LinearLayout.VERTICAL);
        results.setPadding(0, 0, 0, dp(48));
        scroll.addView(results);
        col.addView(scroll, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        setContentView(root);
        String q = getIntent().getStringExtra("query");
        if (q != null) field.setText(q);
        field.requestFocus();
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        super.onActivityResult(req, res, data);
        if (req == VOICE && res == RESULT_OK && data != null) {
            ArrayList<String> said = data.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS);
            if (said != null && !said.isEmpty()) {
                field.setText(said.get(0));
                field.setSelection(field.length());
                main.removeCallbacks(runSearch);
                runSearch.run();
            }
        }
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        worker.shutdownNow();
    }

    private void search(final String q) {
        if (q.equals(lastQuery)) return;
        lastQuery = q;
        final int gen = ++generation;
        if (q.length() < 2) {
            results.removeAllViews();
            status.setText("");
            return;
        }
        status.setText("Searching…");
        worker.execute(new Runnable() {
            @Override
            public void run() {
                final List<Meta> series = fetch("series", q), films = fetch("movie", q);
                main.post(new Runnable() {
                    @Override
                    public void run() {
                        if (gen != generation) return; // you've typed more since
                        show(series, films);
                    }
                });
            }
        });
    }

    private List<Meta> fetch(String type, String q) {
        List<Meta> out = new ArrayList<>();
        try {
            String url = String.format(CINEMETA, type, URLEncoder.encode(q, "UTF-8").replace("+", "%20"));
            JSONArray metas = new JSONObject(AddonClient.get(url)).optJSONArray("metas");
            for (int i = 0; metas != null && i < metas.length() && out.size() < 30; i++) {
                JSONObject o = metas.optJSONObject(i);
                if (o != null) out.add(Meta.from(o, type));
            }
        } catch (Exception ignored) {
            // shown as no results
        }
        return out;
    }

    private void show(List<Meta> series, List<Meta> films) {
        results.removeAllViews();
        if (series.isEmpty() && films.isEmpty()) {
            status.setText("Nothing found for “" + lastQuery + "”");
            return;
        }
        status.setText("");
        // Whichever has the better first match goes first.
        if (!series.isEmpty()) addRow("Series", series);
        if (!films.isEmpty()) addRow("Films", films);
    }

    private void addRow(String title, List<Meta> items) {
        TextView t = text(15, TEXT);
        t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        t.setPadding(0, dp(18), 0, dp(8));
        results.addView(t);
        t.setText(title);

        HorizontalScrollView hs = new HorizontalScrollView(this);
        hs.setHorizontalScrollBarEnabled(false);
        hs.setClipToPadding(false);
        LinearLayout strip = new LinearLayout(this);
        strip.setPadding(0, dp(8), dp(48), dp(8));
        strip.setClipChildren(false);
        strip.setClipToPadding(false);
        hs.addView(strip);
        results.addView(hs);

        for (final Meta m : items) {
            final FrameLayout card = new FrameLayout(this);
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
            images.into(img, m.poster, dp(100), dp(150));
            if (TextUtils.isEmpty(m.poster)) {
                TextView name = text(12, TEXT);
                name.setText(m.name);
                name.setGravity(Gravity.CENTER);
                name.setPadding(dp(6), 0, dp(6), 0);
                card.addView(name, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
            }
            card.setOnFocusChangeListener(new View.OnFocusChangeListener() {
                @Override
                public void onFocusChange(View v, boolean has) {
                    if (has) {
                        GradientDrawable ring = new GradientDrawable();
                        ring.setCornerRadius(dp(8));
                        ring.setStroke(dp(2), ACCENT);
                        v.setForeground(ring);
                        v.animate().scaleX(1.08f).scaleY(1.08f).setDuration(140).start();
                        status.setText(m.name + (m.subtitle().isEmpty() ? "" : "   ·   " + m.subtitle()));
                    } else {
                        v.setForeground(null);
                        v.animate().scaleX(1f).scaleY(1f).setDuration(140).start();
                    }
                }
            });
            card.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    open(m);
                }
            });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(dp(100), dp(150));
            lp.rightMargin = dp(14);
            strip.addView(card, lp);
        }
    }

    private void open(Meta m) {
        String uri = prefs.openUri().replace("{type}", m.type).replace("{id}", m.id);
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(uri)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        } catch (ActivityNotFoundException e) {
            Toast.makeText(this, "Nothing can open " + uri + ". Is Stremio installed?", Toast.LENGTH_LONG).show();
        }
    }

    private void focusFirstResult() {
        main.postDelayed(new Runnable() {
            @Override
            public void run() {
                View first = results.findFocus() == null ? firstCard() : null;
                if (first != null) first.requestFocus();
            }
        }, 900);
    }

    private View firstCard() {
        for (int i = 0; i < results.getChildCount(); i++) {
            View v = results.getChildAt(i);
            if (v instanceof HorizontalScrollView) {
                ViewGroup strip = (ViewGroup) ((HorizontalScrollView) v).getChildAt(0);
                if (strip.getChildCount() > 0) return strip.getChildAt(0);
            }
        }
        return null;
    }

    private void hideKeyboard() {
        InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
        if (imm != null) imm.hideSoftInputFromWindow(field.getWindowToken(), 0);
    }

    private GradientDrawable pill(boolean outlined) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(0xFF241912);
        d.setCornerRadius(dp(99));
        if (outlined) d.setStroke(dp(1), ACCENT);
        return d;
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
