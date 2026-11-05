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
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
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
    @Override
    public boolean dispatchKeyEvent(KeyEvent e) {
        if (e.getKeyCode() == KeyEvent.KEYCODE_BACK) {
            if (e.getAction() == KeyEvent.ACTION_UP) web.evaluateJavascript("window.emberTvBack && emberTvBack()", null);
            return true;
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

        @JavascriptInterface
        public String deviceName() { return "Ember TV"; }
    }
}
