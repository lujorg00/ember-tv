package org.lucamedia.ember;

import android.content.Context;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * Reads a Stremio addon: its manifest lists catalogues, and each catalogue becomes a row.
 * The last good result is cached on disk so the home screen appears instantly, even offline.
 */
final class AddonClient {

    static final class Row {
        final String title;
        final List<Meta> items;

        Row(String title, List<Meta> items) {
            this.title = title;
            this.items = items;
        }

        /** Continue-watching style rows get wide backdrop cards instead of posters. */
        boolean wide() {
            String t = title.toLowerCase();
            return t.contains("pick up") || t.contains("continue") || t.contains("left off");
        }
    }

    private static final String CACHE = "catalogues.json";
    private final File cacheFile;

    AddonClient(Context ctx) {
        cacheFile = new File(ctx.getFilesDir(), CACHE);
    }

    long cacheAgeMs() {
        return cacheFile.exists() ? System.currentTimeMillis() - cacheFile.lastModified() : Long.MAX_VALUE;
    }

    /** Rows from the disk cache, or an empty list. Safe to call on any thread. */
    List<Row> cached() {
        try {
            if (!cacheFile.exists()) return new ArrayList<>();
            return parseRows(new JSONArray(readAll(new FileInputStream(cacheFile))));
        } catch (Exception e) {
            return new ArrayList<>();
        }
    }

    /** Fetches every catalogue live. Call off the main thread. Throws if the manifest can't be read. */
    List<Row> fetch(String manifestUrl) throws Exception {
        String base = baseOf(manifestUrl);
        JSONObject manifest = new JSONObject(get(base + "/manifest.json"));
        JSONArray catalogs = manifest.optJSONArray("catalogs");
        JSONArray out = new JSONArray();
        if (catalogs != null) {
            for (int i = 0; i < catalogs.length(); i++) {
                JSONObject c = catalogs.getJSONObject(i);
                if (needsInput(c)) continue; // e.g. search catalogues
                String type = c.optString("type");
                String id = c.optString("id");
                String name = c.optString("name", id);
                try {
                    JSONObject res = new JSONObject(get(base + "/catalog/" + type + "/" + id + ".json"));
                    JSONArray metas = res.optJSONArray("metas");
                    if (metas == null || metas.length() == 0) continue;
                    JSONObject row = new JSONObject();
                    row.put("title", name);
                    row.put("type", type);
                    row.put("metas", metas);
                    out.put(row);
                } catch (Exception ignored) {
                    // One broken catalogue shouldn't blank the whole home screen.
                }
            }
        }
        try (FileOutputStream fos = new FileOutputStream(cacheFile)) {
            fos.write(out.toString().getBytes(StandardCharsets.UTF_8));
        }
        return parseRows(out);
    }

    /** Returns the number of catalogues the manifest lists, for the settings "Test" button. */
    int test(String manifestUrl) throws Exception {
        JSONObject manifest = new JSONObject(get(baseOf(manifestUrl) + "/manifest.json"));
        JSONArray c = manifest.optJSONArray("catalogs");
        return c == null ? 0 : c.length();
    }

    private static boolean needsInput(JSONObject catalog) {
        JSONArray extra = catalog.optJSONArray("extra");
        if (extra != null) {
            for (int i = 0; i < extra.length(); i++) {
                JSONObject e = extra.optJSONObject(i);
                if (e != null && e.optBoolean("isRequired", false)) return true;
            }
        }
        JSONArray req = catalog.optJSONArray("extraRequired");
        return req != null && req.length() > 0;
    }

    private static List<Row> parseRows(JSONArray arr) {
        List<Row> rows = new ArrayList<>();
        for (int i = 0; i < arr.length(); i++) {
            JSONObject r = arr.optJSONObject(i);
            if (r == null) continue;
            String type = r.optString("type");
            JSONArray metas = r.optJSONArray("metas");
            List<Meta> items = new ArrayList<>();
            if (metas != null) {
                for (int j = 0; j < metas.length(); j++) {
                    JSONObject m = metas.optJSONObject(j);
                    if (m != null) items.add(Meta.from(m, type));
                }
            }
            if (!items.isEmpty()) rows.add(new Row(r.optString("title"), items));
        }
        return rows;
    }

    static String baseOf(String manifestUrl) {
        String u = manifestUrl.trim();
        if (u.startsWith("stremio://")) u = "https://" + u.substring("stremio://".length());
        if (u.endsWith("/manifest.json")) u = u.substring(0, u.length() - "/manifest.json".length());
        while (u.endsWith("/")) u = u.substring(0, u.length() - 1);
        return u;
    }

    static String get(String url) throws IOException {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(8000);
        c.setReadTimeout(15000);
        c.setRequestProperty("Accept", "application/json");
        c.setRequestProperty("User-Agent", "Ember-TV/1.0");
        try {
            int code = c.getResponseCode();
            if (code < 200 || code >= 300) throw new IOException("HTTP " + code + " for " + url);
            return readAll(c.getInputStream());
        } finally {
            c.disconnect();
        }
    }

    private static String readAll(InputStream in) throws IOException {
        try (InputStream is = in) {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[16384];
            int n;
            while ((n = is.read(buf)) > 0) bos.write(buf, 0, n);
            return new String(bos.toByteArray(), StandardCharsets.UTF_8);
        }
    }
}
