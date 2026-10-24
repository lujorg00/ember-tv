package org.lucamedia.ember;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.DialogInterface;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Rect;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewParent;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Ember's home screen: a hero backdrop for whatever is focused, rows from your addon, and your apps. */
public class HomeActivity extends Activity {

    private static final long REFRESH_AFTER_MS = 15 * 60 * 1000L;
    private static final String TAG_SETTINGS = "tile:ember-settings";
    private static final String TAG_TV_SETTINGS = "tile:tv-settings";

    private static final int BG = 0xFF0E0B09;
    private static final int SURFACE = 0xFF1C1612;
    private static final int TEXT = 0xFFF3E7DA;
    private static final int MUTED = 0xFFA8968A;
    private static final int ACCENT = 0xFFF0A04B;

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();

    private Prefs prefs;
    private AddonClient addon;
    private ImageLoader images;
    private float density;
    private int screenW;
    private int screenH;

    private FadedImageView backdrop;
    private TextView heroTitle;
    private TextView heroSub;
    private TextView heroDesc;
    private TextView clock;
    private TextView greeting;
    private LinearLayout clockBox;
    private Glows glows;

    // Apps page look for the time of day (the rest of Ember keeps its own colours).
    private SunClock.Mode apMode;
    private AmbientView ambient;
    private AmbientView homeAmbient;
    private int apText, apMuted, apAccent, apSurface, apPill, apDown;
    private float apGlowStrength;
    private org.json.JSONObject lastStatus;

    private SunClock.Mode currentMode() {
        double lat = 53.48, lon = -2.29;
        try {
            lat = Double.parseDouble(getString(R.string.sun_latitude));
            lon = Double.parseDouble(getString(R.string.sun_longitude));
        } catch (Exception ignored) {
            // fall back to Salford
        }
        return SunClock.modeAt(Calendar.getInstance(), lat, lon);
    }

    private void applyApPalette(SunClock.Mode m) {
        apMode = m;
        switch (m) {
            case DAY: // warm paper, dark text
                apText = 0xFF2A1E14; apMuted = 0xFF6B5848; apAccent = 0xFFB5651D;
                apSurface = 0xFFDDD0BE; apPill = 0xFFE2D6C5; apDown = 0xFFB3261E; apGlowStrength = 0.5f;
                break;
            case EVENING: // firelit wall
                apText = 0xFFF3E7DA; apMuted = 0xFFC9B6A6; apAccent = 0xFFF0A04B;
                apSurface = 0xD91E120C; apPill = 0xCC2A1A12; apDown = 0xFFFF9A8E; apGlowStrength = 0.8f;
                break;
            default: // starry night
                apText = 0xFFF3E7DA; apMuted = 0xFFA8A4B8; apAccent = 0xFFF0A04B;
                apSurface = 0xFF1C1C26; apPill = 0xFF1E1E2A; apDown = 0xFFFF9A8E; apGlowStrength = 0.6f;
                break;
        }
    }

    /** The shared clock is dark on the daytime Apps page and light everywhere else. */
    private void styleClock() {
        boolean lightPage = onApps && apMode == SunClock.Mode.DAY;
        clock.setTextColor(lightPage ? apText : 0xFFF3E7DA);
        greeting.setTextColor(lightPage ? apMuted : 0xFFE6D5C6);
        float r = lightPage ? 0 : dp(6);
        clock.setShadowLayer(r, 0, 0, lightPage ? 0 : 0xAA000000);
        greeting.setShadowLayer(r, 0, 0, lightPage ? 0 : 0xAA000000);
    }

    private ScrollView rowScroll;
    private LinearLayout rowsBox;

    // Two pages: catalogues (home) and apps. Back flips between them.
    private FrameLayout cataloguePage;
    private FrameLayout appsPage;
    private ScrollView appsScroll;
    private LinearLayout appsGrid;
    private TextView appsFocusName;
    private boolean onApps;
    private String appFocusKey;

    private List<AddonClient.Row> rows = new ArrayList<>();
    private List<AppEntry> apps = new ArrayList<>();
    private String focusKey;
    private String addonError;
    private boolean fetching;
    private String pendingBackdrop;

    private final Runnable clockTick = new Runnable() {
        @Override
        public void run() {
            updateClock();
            main.postDelayed(this, 20_000);
        }
    };

    private final Runnable backdropLoader = new Runnable() {
        @Override
        public void run() {
            final String url = pendingBackdrop;
            if (url == null || url.isEmpty()) return;
            images.load(url, screenW / 2, screenH / 2, new ImageLoader.Callback() {
                @Override
                public void onLoaded(Bitmap bmp) {
                    if (!url.equals(pendingBackdrop)) return;
                    backdrop.setImageBitmap(bmp);
                    backdrop.setAlpha(0f);
                    backdrop.animate().alpha(0.85f).setDuration(450).start();
                }
            });
        }
    };

    // ---------------------------------------------------------------- lifecycle

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = new Prefs(this);
        addon = new AddonClient(this);
        images = ImageLoader.get(this);
        density = getResources().getDisplayMetrics().density;
        screenW = getResources().getDisplayMetrics().widthPixels;
        screenH = getResources().getDisplayMetrics().heightPixels;

        applyApPalette(currentMode());
        setContentView(buildLayout());
        showWelcomeHero();

        worker.execute(new Runnable() {
            @Override
            public void run() {
                final List<AddonClient.Row> cached = addon.cached();
                final List<AppEntry> loadedApps = AppEntry.load(HomeActivity.this, prefs);
                main.post(new Runnable() {
                    @Override
                    public void run() {
                        rows = cached;
                        apps = loadedApps;
                        renderApps();
                        render();
                    }
                });
            }
        });
    }

    @Override
    protected void onResume() {
        super.onResume();
        main.post(clockTick);
        main.post(statusTick);
        main.postDelayed(tickerTick, TICKER_EVERY_MS);
        reloadApps();
        if (addon.cacheAgeMs() > REFRESH_AFTER_MS) refreshCatalogues();
    }

    @Override
    protected void onPause() {
        super.onPause();
        main.removeCallbacks(clockTick);
        main.removeCallbacks(statusTick);
        main.removeCallbacks(tickerTick);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        // Home pressed: always land on the catalogues, at the top.
        if (rows.isEmpty()) {
            showApps();
        } else {
            showCatalogues();
            goToTop();
        }
    }

    @Override
    public void onBackPressed() {
        // A launcher has nowhere to go back to, so Back flips between catalogues and apps.
        if (onApps && !rows.isEmpty()) showCatalogues();
        else showApps();
    }

    private void showApps() {
        boolean was = onApps;
        onApps = true;
        styleClock();
        swapPages(cataloguePage, appsPage, was);
        View target = appFocusKey == null ? null : appsGrid.findViewWithTag(appFocusKey);
        if (target == null && appsGrid.getChildCount() > 0) target = ((ViewGroup) appsGrid.getChildAt(0)).getChildAt(0);
        if (target != null) target.requestFocus();
    }

    private void showCatalogues() {
        boolean was = !onApps;
        onApps = false;
        styleClock();
        swapPages(appsPage, cataloguePage, was);
        View target = focusKey == null ? null : rowsBox.findViewWithTag(focusKey);
        if (target == null) target = firstCard();
        if (target != null) target.requestFocus();
    }

    private void swapPages(final View out, View in, boolean alreadyShowing) {
        if (alreadyShowing) return;
        in.setVisibility(View.VISIBLE);
        in.setAlpha(0f);
        in.animate().alpha(1f).setDuration(220).start();
        out.animate().alpha(0f).setDuration(180).withEndAction(new Runnable() {
            @Override
            public void run() {
                out.setVisibility(View.GONE);
            }
        }).start();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        worker.shutdownNow();
    }

    // ---------------------------------------------------------------- data

    private void reloadApps() {
        worker.execute(new Runnable() {
            @Override
            public void run() {
                final List<AppEntry> loaded = AppEntry.load(HomeActivity.this, prefs);
                main.post(new Runnable() {
                    @Override
                    public void run() {
                        if (sameApps(loaded, apps)) return;
                        apps = loaded;
                        renderApps();
                    }
                });
            }
        });
    }

    private static boolean sameApps(List<AppEntry> a, List<AppEntry> b) {
        if (a.size() != b.size()) return false;
        for (int i = 0; i < a.size(); i++) if (!a.get(i).pkg.equals(b.get(i).pkg)) return false;
        return true;
    }

    void refreshCatalogues() {
        if (fetching) return;
        if (!prefs.addonConfigured()) {
            addonError = null;
            return;
        }
        fetching = true;
        final String url = prefs.addonUrl();
        worker.execute(new Runnable() {
            @Override
            public void run() {
                List<AddonClient.Row> fresh = null;
                String err = null;
                try {
                    fresh = addon.fetch(url);
                } catch (Exception e) {
                    err = e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage();
                }
                final List<AddonClient.Row> result = fresh;
                final String error = err;
                main.post(new Runnable() {
                    @Override
                    public void run() {
                        fetching = false;
                        addonError = error;
                        if (result != null) {
                            rows = result;
                            render();
                        } else if (rows.isEmpty()) {
                            showWelcomeHero();
                        }
                    }
                });
            }
        });
    }

    // ---------------------------------------------------------------- layout

    private View buildLayout() {
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(BG);
        cataloguePage = new FrameLayout(this);
        root.addView(cataloguePage, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        // The day / evening / night scene fills the page; the title's backdrop fades into it.
        homeAmbient = new AmbientView(this);
        homeAmbient.setMode(apMode);
        homeAmbient.setAnimate(prefs.motion());
        homeAmbient.setMoonPosition(0.07f, 0.065f); // top-left, clear of the title and the clock
        cataloguePage.addView(homeAmbient, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        backdrop = new FadedImageView(this);
        backdrop.setScaleType(ImageView.ScaleType.CENTER_CROP);
        backdrop.setAlpha(0.85f);
        FrameLayout.LayoutParams bdLp = new FrameLayout.LayoutParams((int) (screenW * 0.72f), (int) (screenH * 0.72f));
        bdLp.gravity = Gravity.TOP | Gravity.END;
        cataloguePage.addView(backdrop, bdLp);

        // Hero text, top-left.
        LinearLayout hero = new LinearLayout(this);
        hero.setOrientation(LinearLayout.VERTICAL);
        FrameLayout.LayoutParams heroLp = new FrameLayout.LayoutParams((int) (screenW * 0.5f), ViewGroup.LayoutParams.WRAP_CONTENT);
        heroLp.leftMargin = dp(48);
        heroLp.topMargin = dp(70);
        cataloguePage.addView(hero, heroLp);

        heroTitle = text(34, apText, Typeface.create("sans-serif-medium", Typeface.NORMAL));
        heroTitle.setMaxLines(2);
        heroTitle.setEllipsize(TextUtils.TruncateAt.END);
        hero.addView(heroTitle);

        heroSub = text(14, apAccent, Typeface.create("sans-serif-medium", Typeface.NORMAL));
        heroSub.setPadding(0, dp(6), 0, dp(10));
        heroSub.setSingleLine(true);
        hero.addView(heroSub);

        heroDesc = text(14, apMuted, Typeface.create("sans-serif", Typeface.NORMAL));
        heroDesc.setMaxLines(3);
        heroDesc.setEllipsize(TextUtils.TruncateAt.END);
        heroDesc.setLineSpacing(0, 1.2f);
        hero.addView(heroDesc);

        // Rows, bottom part of the screen.
        rowScroll = new ScrollView(this) {
            @Override
            protected int computeScrollDeltaToGetChildRectOnScreen(Rect rect) {
                return 0; // We scroll the focused row to the top ourselves.
            }
        };
        rowScroll.setVerticalScrollBarEnabled(false);
        rowScroll.setOverScrollMode(View.OVER_SCROLL_NEVER);
        rowScroll.setClipChildren(false);
        rowScroll.setClipToPadding(false);
        FrameLayout.LayoutParams rsLp = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
        rsLp.topMargin = (int) (screenH * 0.46f);
        cataloguePage.addView(rowScroll, rsLp);

        rowsBox = new LinearLayout(this);
        rowsBox.setOrientation(LinearLayout.VERTICAL);
        rowsBox.setClipChildren(false);
        rowsBox.setClipToPadding(false);
        rowsBox.setPadding(0, 0, 0, screenH); // lets the last row scroll up to the top slot
        rowScroll.addView(rowsBox, new ScrollView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        // Hint so it's obvious where the apps went.
        TextView hint = text(13, apMuted, Typeface.create("sans-serif-medium", Typeface.NORMAL));
        hint.setText("\u2190  Back for apps");
        FrameLayout.LayoutParams hLp = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        hLp.gravity = Gravity.BOTTOM | Gravity.START;
        hLp.leftMargin = dp(48);
        hLp.bottomMargin = dp(18);
        cataloguePage.addView(hint, hLp);

        appsPage = buildAppsPage();
        appsPage.setVisibility(View.GONE);
        root.addView(appsPage, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        // Clock, top-right.
        clockBox = new LinearLayout(this);
        clockBox.setOrientation(LinearLayout.VERTICAL);
        clockBox.setGravity(Gravity.END);
        FrameLayout.LayoutParams cLp = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        cLp.gravity = Gravity.TOP | Gravity.END;
        cLp.rightMargin = dp(48);
        cLp.topMargin = dp(24);
        root.addView(clockBox, cLp);

        clock = text(30, TEXT, Typeface.create("sans-serif-light", Typeface.NORMAL));
        clock.setShadowLayer(dp(6), 0, 0, 0xAA000000);
        clockBox.addView(clock);
        greeting = text(13, MUTED, Typeface.create("sans-serif", Typeface.NORMAL));
        greeting.setShadowLayer(dp(6), 0, 0, 0xAA000000);
        clockBox.addView(greeting);

        styleClock();
        updateClock();
        return root;
    }

    /** Rebuilds the catalogue rows, keeping focus on the same item where possible. */
    private void render() {
        String keep = focusKey;
        rowsBox.removeAllViews();
        for (int i = 0; i < rows.size(); i++) addMetaRow(i, rows.get(i));

        if (rows.isEmpty()) {
            // Nothing to browse yet: the apps page is the useful one.
            showWelcomeHero();
            updateAppsStatus();
            if (!onApps) showApps();
            return;
        }
        updateAppsStatus();
        if (onApps) return; // don't yank focus off the apps page
        View target = keep == null ? null : rowsBox.findViewWithTag(keep);
        if (target == null) target = firstCard();
        if (target != null) {
            final View t = target;
            t.post(new Runnable() {
                @Override
                public void run() {
                    t.requestFocus();
                }
            });
        }
    }

    private void addMetaRow(int rowIndex, AddonClient.Row row) {
        LinearLayout strip = addRow(row.title);
        boolean wide = row.wide();
        int w = wide ? dp(192) : dp(100);
        int h = wide ? dp(108) : dp(150);
        for (final Meta m : row.items) {
            FrameLayout card = card(w, h);
            card.setTag("meta:" + rowIndex + ":" + m.id);

            ImageView img = new ImageView(this);
            img.setScaleType(ImageView.ScaleType.CENTER_CROP);
            card.addView(img, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
            images.into(img, wide ? m.background : m.poster, w, h);

            if (wide) {
                View shade = new View(this);
                shade.setBackground(new GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM,
                        new int[]{0x00000000, 0xCC000000}));
                card.addView(shade, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
                TextView label = text(12, TEXT, Typeface.create("sans-serif-medium", Typeface.NORMAL));
                label.setSingleLine(true);
                label.setEllipsize(TextUtils.TruncateAt.END);
                label.setText(m.name);
                label.setPadding(dp(8), 0, dp(8), dp(6));
                FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                lp.gravity = Gravity.BOTTOM;
                card.addView(label, lp);
            }

            card.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    openTitle(m);
                }
            });
            card.setOnLongClickListener(new View.OnLongClickListener() {
                @Override
                public boolean onLongClick(View v) {
                    titleMenu(m);
                    return true;
                }
            });
            card.setOnFocusChangeListener(new View.OnFocusChangeListener() {
                @Override
                public void onFocusChange(View v, boolean has) {
                    focusAnim(v, has);
                    if (has) showMetaHero(m);
                }
            });
            strip.addView(card, cardLp(w, h));
        }
    }

    private static final int APP_COLUMNS = 5;
    private static final long STATUS_EVERY_MS = 2 * 60 * 1000L;
    private static final long TICKER_EVERY_MS = 4500;
    private TextView appsStatus;

    // Apps page extras from lucapi: calendar ticker pill (by the clock), lucapi line (bottom-right), cats (bottom-left).
    private FrameLayout tickerPill;
    private TextView tickerText;
    private final List<CharSequence> tickerItems = new ArrayList<>();
    private int tickerIndex;
    private LinearLayout lucapiLine;
    private View lucapiDot;
    private TextView lucapiText;
    private LinearLayout catsLine;

    private final Runnable statusTick = new Runnable() {
        @Override
        public void run() {
            refreshStatus();
            main.postDelayed(this, STATUS_EVERY_MS);
        }
    };

    private final Runnable tickerTick = new Runnable() {
        @Override
        public void run() {
            if (tickerItems.size() > 1) rollTicker();
            main.postDelayed(this, tickerDwellMs());
        }
    };

    /** How long the current item stays: longer if it's too wide for the pill and has to slide across. */
    private long tickerDwellMs() {
        if (tickerItems.isEmpty() || tickerText.getWidth() == 0) return TICKER_EVERY_MS;
        float textW = tickerText.getPaint().measureText(tickerItems.get(tickerIndex).toString());
        float overflow = textW - tickerText.getWidth();
        if (overflow <= 0) return TICKER_EVERY_MS;
        // Android's marquee moves at roughly 30dp a second; allow one full pass plus a pause.
        return TICKER_EVERY_MS + (long) ((overflow + tickerText.getWidth()) / (30 * density) * 1000);
    }

    /** Fetches the ticker, lucapi status and cats from the feed (if set). */
    private void refreshStatus() {
        if (!prefs.feedConfigured()) {
            tickerPill.setVisibility(View.GONE);
            lucapiLine.setVisibility(View.GONE);
            catsLine.setVisibility(View.GONE);
            return;
        }
        final String url = prefs.feedUrl() + "/status";
        worker.execute(new Runnable() {
            @Override
            public void run() {
                org.json.JSONObject o = null;
                try {
                    o = new org.json.JSONObject(AddonClient.get(url));
                } catch (Exception ignored) {
                    // Keep showing the last good status if lucapi blips.
                }
                final org.json.JSONObject result = o;
                main.post(new Runnable() {
                    @Override
                    public void run() {
                        if (result != null) renderStatus(result);
                    }
                });
            }
        });
    }

    private void renderStatus(org.json.JSONObject o) {
        lastStatus = o;
        // Calendar ticker: "Next shift: ..." then your other upcoming events, rolling.
        tickerItems.clear();
        org.json.JSONArray t = o.optJSONArray("ticker");
        for (int i = 0; t != null && i < t.length(); i++) {
            org.json.JSONObject item = t.optJSONObject(i);
            if (item == null) continue;
            String prefix = item.optString("prefix");
            android.text.SpannableStringBuilder sb = new android.text.SpannableStringBuilder();
            if (!prefix.isEmpty()) {
                sb.append(prefix).append(' ');
                sb.setSpan(new android.text.style.ForegroundColorSpan(apAccent), 0, prefix.length(),
                        android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            }
            sb.append(item.optString("text"));
            tickerItems.add(sb);
        }
        tickerPill.setVisibility(tickerItems.isEmpty() ? View.GONE : View.VISIBLE);
        if (!tickerItems.isEmpty()) {
            if (tickerIndex >= tickerItems.size()) tickerIndex = 0;
            tickerText.setText(tickerItems.get(tickerIndex));
            placeTickerByClock();
        }

        // lucapi: one small line in the bottom-right corner.
        org.json.JSONObject l = o.optJSONObject("lucapi");
        if (l != null) {
            boolean ok = l.optBoolean("ok", true);
            lucapiText.setText(l.optString("text"));
            lucapiText.setTextColor(ok ? apMuted : apDown);
            ((GradientDrawable) lucapiDot.getBackground()).setColor(ok ? 0xFF8FD18B : 0xFFFF7A6B);
            lucapiLine.setVisibility(View.VISIBLE);
        } else {
            lucapiLine.setVisibility(View.GONE);
        }

        // Cats: a small block each, bottom-left: name, then "In · 2h" / "Out · 40m".
        catsLine.removeAllViews();
        org.json.JSONArray cats = o.optJSONArray("cats");
        for (int i = 0; cats != null && i < cats.length(); i++) {
            org.json.JSONObject c = cats.optJSONObject(i);
            if (c == null) continue;
            boolean in = c.optBoolean("home");
            LinearLayout block = new LinearLayout(this);
            block.setOrientation(LinearLayout.VERTICAL);
            block.setPadding(dp(9), dp(5), dp(10), dp(6));
            GradientDrawable bb = new GradientDrawable();
            bb.setColor(apSurface);
            bb.setCornerRadius(dp(8));
            block.setBackground(bb);
            TextView name = text(11, apText, Typeface.create("sans-serif-medium", Typeface.NORMAL));
            name.setText(c.optString("name"));
            block.addView(name);
            TextView state = text(10, in ? apAccent : apMuted, Typeface.create("sans-serif", Typeface.NORMAL));
            state.setText(c.optString("detail"));
            block.addView(state);
            LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            if (i > 0) blp.leftMargin = dp(8);
            catsLine.addView(block, blp);
        }
        catsLine.setVisibility(catsLine.getChildCount() == 0 ? View.GONE : View.VISIBLE);
    }

    /** Keeps the ticker pill just to the left of the clock, whatever the clock's width. */
    private void placeTickerByClock() {
        clockBox.post(new Runnable() {
            @Override
            public void run() {
                FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) tickerPill.getLayoutParams();
                int want = clockBox.getWidth() + dp(48) + dp(14);
                if (lp.rightMargin != want) {
                    lp.rightMargin = want;
                    tickerPill.setLayoutParams(lp);
                }
            }
        });
    }

    private void rollTicker() {
        final int h = tickerText.getHeight() > 0 ? tickerText.getHeight() : dp(16);
        tickerText.animate().translationY(-h).alpha(0f).setDuration(260).withEndAction(new Runnable() {
            @Override
            public void run() {
                if (tickerItems.isEmpty()) return;
                tickerIndex = (tickerIndex + 1) % tickerItems.size();
                tickerText.setText(tickerItems.get(tickerIndex));
                tickerText.setSelected(false);
                tickerText.setSelected(true); // restart the slide for the new item
                tickerText.setTranslationY(h);
                tickerText.animate().translationY(0).alpha(1f).setDuration(260).start();
            }
        }).start();
    }

    /** The apps page: big name of the focused app, then a grid of every app. */
    private FrameLayout buildAppsPage() {
        FrameLayout page = new FrameLayout(this);

        // Background: day / evening / night scene following the real sun, under a glow in the focused app's colour.
        ambient = new AmbientView(this);
        ambient.setMode(apMode);
        ambient.setAnimate(prefs.motion());
        page.addView(ambient, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        View appLayer = new View(this);
        page.addView(appLayer, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        glows = new Glows(appLayer, screenW);
        glows.setStrength(apGlowStrength);

        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        column.setClipChildren(false);
        page.addView(column, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        LinearLayout head = new LinearLayout(this);
        head.setOrientation(LinearLayout.VERTICAL);
        head.setPadding(dp(48), dp(36), dp(48), 0);
        column.addView(head);

        TextView label = text(13, apAccent, Typeface.create("sans-serif-medium", Typeface.NORMAL));
        label.setText("APPS");
        label.setLetterSpacing(0.2f);
        head.addView(label);

        appsFocusName = text(34, apText, Typeface.create("sans-serif-medium", Typeface.NORMAL));
        appsFocusName.setSingleLine(true);
        appsFocusName.setMaxWidth((int) (screenW * 0.32f));
        appsFocusName.setEllipsize(TextUtils.TruncateAt.END);
        appsFocusName.setPadding(0, dp(4), 0, 0);
        head.addView(appsFocusName);

        appsStatus = text(13, apMuted, Typeface.create("sans-serif", Typeface.NORMAL));
        appsStatus.setPadding(0, dp(6), 0, 0);
        head.addView(appsStatus);


        appsScroll = new ScrollView(this);
        appsScroll.setVerticalScrollBarEnabled(false);
        appsScroll.setOverScrollMode(View.OVER_SCROLL_NEVER);
        appsScroll.setClipChildren(false);
        appsScroll.setClipToPadding(false);
        column.addView(appsScroll, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        appsGrid = new LinearLayout(this);
        appsGrid.setOrientation(LinearLayout.VERTICAL);
        appsGrid.setClipChildren(false);
        appsGrid.setClipToPadding(false);
        appsGrid.setPadding(dp(48), dp(22), dp(48), dp(60));
        appsScroll.addView(appsGrid, new ScrollView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        // Calendar ticker pill, sitting just left of the clock (placed once the clock is measured).
        tickerPill = new FrameLayout(this);
        tickerPill.setPadding(dp(12), dp(5), dp(12), dp(5));
        GradientDrawable pillBg = new GradientDrawable();
        pillBg.setColor(apPill);
        pillBg.setCornerRadius(dp(999));
        tickerPill.setBackground(pillBg);
        tickerPill.setClipChildren(true);
        tickerPill.setVisibility(View.GONE);
        tickerText = text(12, apText, Typeface.create("sans-serif", Typeface.NORMAL));
        tickerText.setSingleLine(true);
        // Items that fit sit still; one that's too long slides sideways while it's showing.
        tickerText.setEllipsize(TextUtils.TruncateAt.MARQUEE);
        tickerText.setMarqueeRepeatLimit(1);
        tickerText.setHorizontallyScrolling(true);
        tickerText.setSelected(true);
        tickerPill.addView(tickerText, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        FrameLayout.LayoutParams tpLp = new FrameLayout.LayoutParams(dp(230), ViewGroup.LayoutParams.WRAP_CONTENT);
        tpLp.gravity = Gravity.TOP | Gravity.END;
        tpLp.topMargin = dp(30);
        tpLp.rightMargin = dp(320);
        page.addView(tickerPill, tpLp);

        // lucapi: small, bottom-right corner.
        lucapiLine = new LinearLayout(this);
        lucapiLine.setOrientation(LinearLayout.HORIZONTAL);
        lucapiLine.setGravity(Gravity.CENTER_VERTICAL);
        lucapiLine.setVisibility(View.GONE);
        lucapiDot = new View(this);
        GradientDrawable ld = new GradientDrawable();
        ld.setShape(GradientDrawable.OVAL);
        ld.setColor(0xFF8FD18B);
        lucapiDot.setBackground(ld);
        LinearLayout.LayoutParams ldLp = new LinearLayout.LayoutParams(dp(5), dp(5));
        ldLp.rightMargin = dp(5);
        lucapiLine.addView(lucapiDot, ldLp);
        lucapiText = text(9, apMuted, Typeface.create("sans-serif", Typeface.NORMAL));
        lucapiText.setSingleLine(true);
        lucapiText.setEllipsize(TextUtils.TruncateAt.END);
        lucapiText.setMaxWidth((int) (screenW * 0.35f));
        lucapiLine.addView(lucapiText);
        FrameLayout.LayoutParams llLp = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        llLp.gravity = Gravity.BOTTOM | Gravity.END;
        llLp.rightMargin = dp(48);
        llLp.bottomMargin = dp(18);
        page.addView(lucapiLine, llLp);

        // Cats: small, bottom-left.
        catsLine = new LinearLayout(this);
        catsLine.setOrientation(LinearLayout.HORIZONTAL);
        catsLine.setVisibility(View.GONE);
        FrameLayout.LayoutParams caLp = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        caLp.gravity = Gravity.BOTTOM | Gravity.START;
        caLp.leftMargin = dp(48);
        caLp.bottomMargin = dp(18);
        page.addView(catsLine, caLp);

        return page;
    }

    private void updateAppsStatus() {
        if (appsStatus == null) return;
        if (!prefs.addonConfigured()) {
            appsStatus.setText("Add your addon in \u2699 Ember (end of the grid) to get your rows.");
        } else if (rows.isEmpty() && addonError != null) {
            appsStatus.setText("Couldn't reach your addon: " + addonError);
        } else if (rows.isEmpty()) {
            appsStatus.setText("Loading your rows\u2026");
        } else {
            appsStatus.setText("\u2190  Back for your rows");
        }
    }

    /** Rebuilds the apps grid, keeping focus where it was. */
    private void renderApps() {
        String keep = appFocusKey;
        appsGrid.removeAllViews();
        int w = (screenW - dp(96) - dp(16) * (APP_COLUMNS - 1)) / APP_COLUMNS;
        int h = w * 9 / 16;

        List<View> tiles = new ArrayList<>();
        for (final AppEntry app : apps) {
            FrameLayout card = card(w, h);
            ((GradientDrawable) card.getBackground()).setColor(apSurface);
            card.setTag("app:" + app.pkg);
            if (app.banner != null) {
                ImageView img = new ImageView(this);
                img.setScaleType(ImageView.ScaleType.CENTER_CROP);
                img.setImageDrawable(app.banner);
                card.addView(img, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
            } else {
                card.addView(iconTile(app.icon, app.label));
            }
            card.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    launchApp(app);
                }
            });
            card.setOnLongClickListener(new View.OnLongClickListener() {
                @Override
                public boolean onLongClick(View v) {
                    appMenu(app);
                    return true;
                }
            });
            card.setOnFocusChangeListener(new View.OnFocusChangeListener() {
                @Override
                public void onFocusChange(View v, boolean has) {
                    focusAnim(v, has);
                    if (has) {
                        appFocusKey = String.valueOf(v.getTag());
                        appsFocusName.setText(app.label);
                        glows.focusApp(app.pkg, app.banner != null ? app.banner : app.icon);
                    }
                }
            });
            tiles.add(card);
        }
        tiles.add(actionTile(TAG_SETTINGS, "\u2699  Ember", "Ember settings", new Runnable() {
            @Override
            public void run() {
                startActivity(new Intent(HomeActivity.this, SettingsActivity.class));
            }
        }));
        tiles.add(actionTile(TAG_TV_SETTINGS, "\u2699  TV", "TV settings", new Runnable() {
            @Override
            public void run() {
                safeStart(new Intent(Settings.ACTION_SETTINGS));
            }
        }));

        LinearLayout line = null;
        for (int i = 0; i < tiles.size(); i++) {
            if (i % APP_COLUMNS == 0) {
                line = new LinearLayout(this);
                line.setOrientation(LinearLayout.HORIZONTAL);
                line.setClipChildren(false);
                LinearLayout.LayoutParams lineLp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                lineLp.bottomMargin = dp(18);
                appsGrid.addView(line, lineLp);
            }
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(w, h);
            if (i % APP_COLUMNS != APP_COLUMNS - 1) lp.rightMargin = dp(16);
            line.addView(tiles.get(i), lp);
        }

        if (onApps) {
            View target = keep == null ? null : appsGrid.findViewWithTag(keep);
            if (target == null && !tiles.isEmpty()) target = tiles.get(0);
            if (target != null) target.requestFocus();
        }
    }

    /** Adds a titled horizontal row and returns the strip that holds its cards. */
    private LinearLayout addRow(String title) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.VERTICAL);
        row.setClipChildren(false);
        row.setClipToPadding(false);

        TextView t = text(15, apText, Typeface.create("sans-serif-medium", Typeface.NORMAL));
        t.setText(title);
        t.setPadding(dp(48), dp(6), 0, dp(8));
        row.addView(t);

        HorizontalScrollView hs = new HorizontalScrollView(this);
        hs.setHorizontalScrollBarEnabled(false);
        hs.setOverScrollMode(View.OVER_SCROLL_NEVER);
        hs.setClipChildren(false);
        hs.setClipToPadding(false);
        hs.setFadingEdgeLength(dp(24));
        hs.setHorizontalFadingEdgeEnabled(true);

        LinearLayout strip = new LinearLayout(this);
        strip.setOrientation(LinearLayout.HORIZONTAL);
        strip.setClipChildren(false);
        strip.setClipToPadding(false);
        strip.setPadding(dp(48), dp(8), dp(48), dp(14));
        hs.addView(strip);
        row.addView(hs);

        rowsBox.addView(row);
        return strip;
    }

    private FrameLayout card(int w, int h) {
        FrameLayout card = new FrameLayout(this);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(SURFACE);
        bg.setCornerRadius(dp(8));
        card.setBackground(bg);
        card.setClipToOutline(true);
        card.setFocusable(true);
        card.setFocusableInTouchMode(false);
        card.setClickable(true);
        return card;
    }

    private LinearLayout.LayoutParams cardLp(int w, int h) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(w, h);
        lp.rightMargin = dp(14);
        return lp;
    }

    private View iconTile(Drawable icon, String label) {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setGravity(Gravity.CENTER);
        ImageView iv = new ImageView(this);
        iv.setImageDrawable(icon);
        box.addView(iv, new LinearLayout.LayoutParams(dp(40), dp(40)));
        TextView t = text(12, apText, Typeface.create("sans-serif-medium", Typeface.NORMAL));
        t.setText(label);
        t.setSingleLine(true);
        t.setEllipsize(TextUtils.TruncateAt.END);
        t.setPadding(dp(8), dp(6), dp(8), 0);
        box.addView(t);
        return box;
    }

    private View actionTile(String tag, String label, final String name, final Runnable action) {
        FrameLayout card = card(0, 0);
        ((GradientDrawable) card.getBackground()).setColor(apSurface);
        card.setTag(tag);
        TextView t = text(16, apAccent, Typeface.create("sans-serif-medium", Typeface.NORMAL));
        t.setText(label);
        t.setGravity(Gravity.CENTER);
        card.addView(t, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        card.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                action.run();
            }
        });
        card.setOnFocusChangeListener(new View.OnFocusChangeListener() {
            @Override
            public void onFocusChange(View v, boolean has) {
                focusAnim(v, has);
                if (has) {
                    appFocusKey = String.valueOf(v.getTag());
                    appsFocusName.setText(name);
                    glows.focusApp(String.valueOf(v.getTag()), null);
                }
            }
        });
        return card;
    }

    private boolean isOnAppsPage(View v) {
        for (android.view.ViewParent p = v.getParent(); p instanceof View; p = p.getParent()) {
            if (p == appsPage) return true;
        }
        return false;
    }

    private void focusAnim(View v, boolean has) {
        if (has) {
            String tag = String.valueOf(v.getTag());
            if (tag.startsWith("meta:")) focusKey = tag;
            GradientDrawable ring = new GradientDrawable();
            ring.setColor(Color.TRANSPARENT);
            ring.setCornerRadius(dp(8));
            ring.setStroke(dp(2), apAccent);
            v.setForeground(ring);
            v.animate().scaleX(1.08f).scaleY(1.08f).translationZ(dp(8)).setDuration(140).start();
            scrollRowToTop(v);
        } else {
            v.setForeground(null);
            v.animate().scaleX(1f).scaleY(1f).translationZ(0).setDuration(140).start();
        }
    }

    /** Keeps the focused row in the top slot, Google TV style. */
    private void scrollRowToTop(View card) {
        ViewParent p = card.getParent();
        View rowView = null;
        while (p instanceof View) {
            View pv = (View) p;
            if (pv.getParent() == rowsBox) {
                rowView = pv;
                break;
            }
            p = pv.getParent();
        }
        if (rowView != null) rowScroll.smoothScrollTo(0, rowView.getTop());
    }

    private View firstCard() {
        if (rowsBox.getChildCount() == 0) return null;
        ViewGroup row = (ViewGroup) rowsBox.getChildAt(0);
        ViewGroup hs = (ViewGroup) row.getChildAt(1);
        ViewGroup strip = (ViewGroup) hs.getChildAt(0);
        return strip.getChildCount() > 0 ? strip.getChildAt(0) : null;
    }

    private void goToTop() {
        if (rowScroll == null) return;
        rowScroll.smoothScrollTo(0, 0);
        View first = firstCard();
        if (first != null) {
            ViewParent hs = first.getParent().getParent();
            if (hs instanceof HorizontalScrollView) ((HorizontalScrollView) hs).smoothScrollTo(0, 0);
            first.requestFocus();
        }
    }

    // ---------------------------------------------------------------- hero

    private void showMetaHero(Meta m) {
        heroTitle.setText(m.name);
        heroSub.setText(m.subtitle());
        heroDesc.setText(m.description);
        pendingBackdrop = m.background;
        main.removeCallbacks(backdropLoader);
        main.postDelayed(backdropLoader, 250); // don't thrash while scrolling fast
    }

    private void showPlainHero(String title, String sub, String desc) {
        heroTitle.setText(title);
        heroSub.setText(sub);
        heroDesc.setText(desc);
    }

    private void showWelcomeHero() {
        if (!prefs.addonConfigured()) {
            showPlainHero("Welcome to Ember", "No ads. Just your stuff.",
                    "Add your Omni addon's manifest URL in Ember settings (end of the Apps row) and your rows will appear here.");
        } else if (addonError != null) {
            showPlainHero("Couldn't reach your addon", "Showing apps only",
                    addonError + "\nCheck lucapi is up, or fix the URL in Ember settings.");
        } else if (fetching || rows.isEmpty()) {
            showPlainHero("Loading your rows…", prefs.addonUrl(), "");
        }
    }

    private void updateClock() {
        if (appsPage != null && clock != null && currentMode() != apMode) {
            // Day, evening or night has changed: fade out and come back in the new look.
            final View root = findViewById(android.R.id.content);
            root.animate().alpha(0f).setDuration(400).withEndAction(new Runnable() {
                @Override
                public void run() {
                    recreate();
                }
            }).start();
            return;
        }
        Calendar c = Calendar.getInstance();
        clock.setText(new SimpleDateFormat("HH:mm", Locale.UK).format(c.getTime()));
        greeting.setText(DateText.of(c));
    }

    // ---------------------------------------------------------------- actions

    private void openTitle(Meta m) {
        String uri = prefs.openUri().replace("{type}", m.type).replace("{id}", m.id);
        Intent i = new Intent(Intent.ACTION_VIEW, Uri.parse(uri));
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            startActivity(i);
        } catch (ActivityNotFoundException e) {
            Toast.makeText(this, "Nothing can open " + uri + ". Is Stremio installed?", Toast.LENGTH_LONG).show();
        }
    }

    private void titleMenu(final Meta m) {
        new AlertDialog.Builder(this)
                .setTitle(m.name)
                .setItems(new CharSequence[]{"Open", "Refresh all rows now"}, new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int which) {
                        if (which == 0) openTitle(m);
                        else refreshCatalogues();
                    }
                })
                .show();
    }

    private void launchApp(AppEntry app) {
        Intent i = app.launchIntent(this);
        if (i == null) {
            Toast.makeText(this, "Couldn't open " + app.label, Toast.LENGTH_SHORT).show();
            return;
        }
        prefs.recordLaunch(app.pkg);
        safeStart(i);
    }

    private void appMenu(final AppEntry app) {
        new AlertDialog.Builder(this)
                .setTitle(app.label)
                .setItems(new CharSequence[]{"Open", "Hide from home", "App info"}, new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int which) {
                        if (which == 0) {
                            launchApp(app);
                        } else if (which == 1) {
                            prefs.hideApp(app.pkg);
                            focusKey = null;
                            reloadApps();
                        } else {
                            safeStart(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.parse("package:" + app.pkg)));
                        }
                    }
                })
                .show();
    }

    private void safeStart(Intent i) {
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            startActivity(i);
        } catch (ActivityNotFoundException e) {
            Toast.makeText(this, "That isn't available on this device", Toast.LENGTH_SHORT).show();
        }
    }

    // ---------------------------------------------------------------- helpers

    private TextView text(float sp, int color, Typeface tf) {
        TextView t = new TextView(this);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(color);
        t.setTypeface(tf);
        t.setBackground(new ColorDrawable(Color.TRANSPARENT));
        return t;
    }

    private int dp(float v) {
        return Math.round(v * density);
    }
}
