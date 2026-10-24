package org.lucamedia.ember;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.HashSet;
import java.util.Set;

/** Small wrapper around SharedPreferences for Ember's settings and usage stats. */
final class Prefs {
    private static final String FILE = "ember";
    private static final String K_ADDON = "addon_url";
    private static final String K_OPEN = "open_uri";
    private static final String K_FEED = "feed_url";
    private static final String K_HIDDEN = "hidden_apps";
    private static final String K_LAUNCH_PREFIX = "launch_";
    private static final String K_LAST_STOCK = "last_stock_window";

    private final Context ctx;
    private final SharedPreferences sp;

    Prefs(Context context) {
        ctx = context.getApplicationContext();
        sp = ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    String addonUrl() {
        return sp.getString(K_ADDON, ctx.getString(R.string.default_addon_url)).trim();
    }

    void setAddonUrl(String url) {
        sp.edit().putString(K_ADDON, url.trim()).apply();
    }

    boolean addonConfigured() {
        String u = addonUrl();
        return u.startsWith("http") && !u.contains("REPLACE-ME");
    }

    String openUri() {
        return sp.getString(K_OPEN, ctx.getString(R.string.default_open_uri)).trim();
    }

    void setOpenUri(String uri) {
        sp.edit().putString(K_OPEN, uri.trim()).apply();
    }

    /** Base URL of ember-feed on lucapi, e.g. http://192.168.4.141:8090 (empty = off). */
    String feedUrl() {
        String u = sp.getString(K_FEED, ctx.getString(R.string.default_feed_url)).trim();
        while (u.endsWith("/")) u = u.substring(0, u.length() - 1);
        return u;
    }

    void setFeedUrl(String url) {
        sp.edit().putString(K_FEED, url.trim()).apply();
    }

    boolean feedConfigured() {
        return feedUrl().startsWith("http");
    }

    /** Moving backgrounds on (default) or a still picture. */
    boolean motion() {
        return sp.getBoolean("motion", true);
    }

    void setMotion(boolean on) {
        sp.edit().putBoolean("motion", on).apply();
    }

    Set<String> hiddenApps() {
        return new HashSet<>(sp.getStringSet(K_HIDDEN, new HashSet<String>()));
    }

    void hideApp(String pkg) {
        Set<String> s = hiddenApps();
        s.add(pkg);
        sp.edit().putStringSet(K_HIDDEN, s).apply();
    }

    void clearHiddenApps() {
        sp.edit().remove(K_HIDDEN).apply();
    }

    int launchCount(String pkg) {
        return sp.getInt(K_LAUNCH_PREFIX + pkg, 0);
    }

    void recordLaunch(String pkg) {
        sp.edit().putInt(K_LAUNCH_PREFIX + pkg, launchCount(pkg) + 1).apply();
    }

    String lastStockWindow() {
        return sp.getString(K_LAST_STOCK, "none seen yet");
    }

    void setLastStockWindow(String s) {
        sp.edit().putString(K_LAST_STOCK, s).apply();
    }
}
