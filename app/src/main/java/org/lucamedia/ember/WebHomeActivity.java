package org.lucamedia.ember;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Drawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import android.util.Log;
import android.view.KeyEvent;
import android.view.View;
import android.view.WindowManager;
import android.view.inputmethod.InputMethodManager;
import android.webkit.ConsoleMessage;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * Ember TV's home: the same interface as Ember PC (bundled from ember-pc/ui), full screen, driven by the remote.
 * The page talks to Android through window.EmberTV: playing streams (PlayerActivity), the apps on the TV,
 * the on-screen keyboard and Ember's TV settings (dimmer, screensaver...).
 */
public class WebHomeActivity extends Activity {
    private static final String TAG = "EmberWeb";
    static final int REQ_PLAY = 7;

    private WebView web;
    private final Handler main = new Handler(Looper.getMainLooper());
    // Read by the page while a film plays (it checks every couple of seconds, as it does with mpv on the PC).
    private static volatile boolean playing = false;
    private static volatile int lastExit = 0;

    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        // no keep-screen-on here: on the home screen the Chromecast's own screensaver and sleep timer work as normal (only the player keeps it awake)
        web = new WebView(this);
        web.setBackgroundColor(Color.parseColor("#0E0B09"));
        web.setFocusable(true);
        web.setFocusableInTouchMode(true);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);          // Ember's settings live in localStorage, as on the PC
        s.setAllowFileAccess(true);
        s.setAllowFileAccessFromFileURLs(true);
        s.setAllowUniversalAccessFromFileURLs(true); // the page is a local file; lucapi and AIOStreams are on the network
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setUseWideViewPort(true);            // lay the page out at the width it asks for, then fit it to the TV
        s.setLoadWithOverviewMode(true);
        s.setTextZoom(100);
        s.setCacheMode(WebSettings.LOAD_DEFAULT);
        web.addJavascriptInterface(new Bridge(), "EmberTV");
        web.setWebViewClient(new WebViewClient());
        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onConsoleMessage(ConsoleMessage m) {
                Log.d(TAG, m.message() + " (" + m.sourceId() + ":" + m.lineNumber() + ")");
                return true;
            }
        });
        setContentView(web);
        web.loadUrl("file:///android_asset/index.html");
        web.requestFocus();
    }

    // Back: the page decides (close a panel, go back a page); on the first page it does nothing, as a home screen should.
    // Holding OK: Android sees the hold (the page doesn't reliably), so it's spotted here and passed on.
    private long okDownAt = 0;
    private boolean okHeld = false;

    @Override
    public boolean dispatchKeyEvent(KeyEvent e) {
        int k = e.getKeyCode();
        if (k == KeyEvent.KEYCODE_BACK) {
            if (e.getAction() == KeyEvent.ACTION_UP) web.evaluateJavascript("window.emberTvBack && emberTvBack()", null);
            return true;
        }
        if (k == KeyEvent.KEYCODE_DPAD_CENTER || k == KeyEvent.KEYCODE_ENTER || k == KeyEvent.KEYCODE_NUMPAD_ENTER) {
            if (e.getAction() == KeyEvent.ACTION_DOWN) {
                if (e.getRepeatCount() == 0) {
                    okDownAt = e.getEventTime();
                    okHeld = false;
                    return super.dispatchKeyEvent(e);
                }
                // still held: after 0.6 s it's a hold, once; the rest of the repeats are swallowed
                if (!okHeld && e.getEventTime() - okDownAt >= 600) {
                    okHeld = true;
                    web.evaluateJavascript("window.emberTvLongOk && emberTvLongOk()", null);
                }
                return true;
            }
            if (e.getAction() == KeyEvent.ACTION_UP && okHeld) {
                okHeld = false;
                web.evaluateJavascript("window.emberTvOkCancel && emberTvOkCancel()", null);
                return true; // a hold isn't also a press
            }
        }
        return super.dispatchKeyEvent(e);
    }

    @Override
    protected void onActivityResult(int req, int result, Intent data) {
        super.onActivityResult(req, result, data);
        if (req == REQ_PLAY) {
            lastExit = result == RESULT_CANCELED ? 0 : result;
            playing = false;
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        web.onResume();
        web.evaluateJavascript("window.emberTvResumed && emberTvResumed()", null);
    }

    @Override
    protected void onPause() {
        // keep the page running while the player is up, so it notices when you come back
        super.onPause();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        // Home pressed while Ember is already open: back to Ember's Home page
        web.evaluateJavascript("window.emberTvHome && emberTvHome()", null);
    }

    private static String drawableToDataUrl(Drawable d, int w, int h) {
        if (d == null) return "";
        try {
            Bitmap b;
            if (d instanceof BitmapDrawable && ((BitmapDrawable) d).getBitmap() != null) {
                b = Bitmap.createScaledBitmap(((BitmapDrawable) d).getBitmap(), w, h, true);
            } else {
                b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
                Canvas c = new Canvas(b);
                d.setBounds(0, 0, w, h);
                d.draw(c);
            }
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            b.compress(Bitmap.CompressFormat.PNG, 100, out);
            return "data:image/png;base64," + Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP);
        } catch (Exception ex) {
            return "";
        }
    }

    /** What the page can ask of Android. Everything here is called from the page's thread: hop to the UI thread. */
    final class Bridge {
        @JavascriptInterface
        public boolean isTv() { return true; }

        /** {url, start, opts, title, passthrough}: opts is the same comma list mpv gets on the PC. */
        @JavascriptInterface
        public String play(final String json) {
            try {
                final JSONObject a = new JSONObject(json);
                playing = true;
                lastExit = 0;
                main.post(() -> {
                    Intent i = new Intent(WebHomeActivity.this, PlayerActivity.class);
                    i.putExtra("url", a.optString("url"));
                    i.putExtra("start", a.optDouble("start", 0));
                    i.putExtra("opts", a.optString("opts"));
                    i.putExtra("title", a.optString("title"));
                    startActivityForResult(i, REQ_PLAY);
                });
                return "playing";
            } catch (Exception e) {
                playing = false;
                return "error: " + e.getMessage();
            }
        }

        @JavascriptInterface
        public boolean playing() { return playing; }

        @JavascriptInterface
        public int lastExit() { return lastExit; }

        /** The apps on the TV (most used first), with their banners, for Ember's Apps page. */
        @JavascriptInterface
        public String apps() {
            JSONArray out = new JSONArray();
            try {
                Prefs prefs = new Prefs(WebHomeActivity.this);
                List<AppEntry> list = AppEntry.load(WebHomeActivity.this, prefs);
                for (AppEntry e : list) {
                    JSONObject o = new JSONObject();
                    o.put("pkg", e.pkg);
                    o.put("label", e.label);
                    o.put("banner", e.banner != null ? drawableToDataUrl(e.banner, 320, 180) : "");
                    o.put("icon", e.banner == null ? drawableToDataUrl(e.icon, 128, 128) : "");
                    out.put(o);
                }
            } catch (Exception ex) {
                Log.w(TAG, "apps: " + ex);
            }
            return out.toString();
        }

        @JavascriptInterface
        public void launchApp(final String pkg) {
            main.post(() -> {
                try {
                    Intent i = getPackageManager().getLeanbackLaunchIntentForPackage(pkg);
                    if (i == null) i = getPackageManager().getLaunchIntentForPackage(pkg);
                    if (i != null) {
                        new Prefs(WebHomeActivity.this).recordLaunch(pkg);
                        startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                    }
                } catch (Exception ex) {
                    Log.w(TAG, "launch " + pkg + ": " + ex);
                }
            });
        }

        /** The Chromecast's own Settings, or the Play Store (neither is in the normal app list on Google TV). */
        @JavascriptInterface
        public void openSystem(final String what) {
            main.post(() -> {
                List<Intent> tries = new ArrayList<>();
                if ("store".equals(what)) {
                    tries.add(new Intent(Intent.ACTION_MAIN).setClassName("com.android.vending", "com.google.android.finsky.tvmainactivity.TvMainActivity"));
                    Intent lb = getPackageManager().getLeanbackLaunchIntentForPackage("com.android.vending");
                    if (lb != null) tries.add(lb);
                    Intent l = getPackageManager().getLaunchIntentForPackage("com.android.vending");
                    if (l != null) tries.add(l);
                    tries.add(new Intent(Intent.ACTION_VIEW, android.net.Uri.parse("market://search?q=apps")));
                } else {
                    tries.add(new Intent(android.provider.Settings.ACTION_SETTINGS));
                    tries.add(new Intent(Intent.ACTION_MAIN).setClassName("com.android.tv.settings", "com.android.tv.settings.MainSettings"));
                }
                for (Intent i : tries) {
                    try { startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); return; }
                    catch (Exception ex) { Log.w(TAG, "open " + what + ": " + ex); }
                }
            });
        }

        /** Sends a test calendar and cat notification; false if Ember's notification service (the dimmer) is off. */
        @JavascriptInterface
        public boolean testNotices() { return DimService.test(); }

        /** Ember's own TV settings: dimmer, screensaver, home-screen takeover. */
        @JavascriptInterface
        public void openTvSettings() {
            main.post(() -> startActivity(new Intent(WebHomeActivity.this, SettingsActivity.class)));
        }

        /** Bring up the on-screen keyboard for the box that has focus (search). */
        @JavascriptInterface
        public void showKeyboard() {
            main.post(() -> {
                web.requestFocus(View.FOCUS_DOWN);
                InputMethodManager imm = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
                if (imm != null) imm.showSoftInput(web, InputMethodManager.SHOW_IMPLICIT);
            });
        }

        @JavascriptInterface
        public void hideKeyboard() {
            main.post(() -> {
                InputMethodManager imm = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
                if (imm != null) imm.hideSoftInputFromWindow(web.getWindowToken(), 0);
            });
        }

        /** "Watch trailer": straight to that video in the TV's YouTube app. The TV app opens a video from a
         *  watch link sent to it directly (a vnd.youtube: link only opened its home screen); other apps are the fallback. */
        @JavascriptInterface
        public void openTrailer(final String id) {
            if (id == null || !id.matches("[A-Za-z0-9_-]{6,20}")) return;
            main.post(() -> {
                android.net.Uri watch = android.net.Uri.parse("https://www.youtube.com/watch?v=" + id);
                Intent[] tries = {
                        new Intent(Intent.ACTION_VIEW, watch).setPackage("com.google.android.youtube.tv"),
                        new Intent(Intent.ACTION_VIEW, android.net.Uri.parse("vnd.youtube:" + id)).setPackage("com.google.android.youtube.tv"),
                        new Intent(Intent.ACTION_VIEW, watch),
                };
                for (Intent i : tries) {
                    try {
                        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                        i.putExtra("force_fullscreen", true);
                        startActivity(i);
                        return;
                    } catch (Exception ex) {
                        Log.w(TAG, "trailer via " + i + ": " + ex);
                    }
                }
            });
        }

        @JavascriptInterface
        public String deviceName() { return "Ember TV"; }
    }
}
