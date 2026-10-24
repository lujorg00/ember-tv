package org.lucamedia.ember;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Handler;
import android.os.Looper;
import android.util.LruCache;
import android.widget.ImageView;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Minimal image loader: memory + disk cache, downsampled decode, no external libraries. */
final class ImageLoader {

    interface Callback {
        void onLoaded(Bitmap bmp);
    }

    private static ImageLoader instance;

    static synchronized ImageLoader get(Context ctx) {
        if (instance == null) instance = new ImageLoader(ctx.getApplicationContext());
        return instance;
    }

    private final LruCache<String, Bitmap> memory;
    private final File diskDir;
    // Two low-priority threads: posters keep loading, but never at the expense of smooth scrolling.
    private final ExecutorService pool = Executors.newFixedThreadPool(2, new java.util.concurrent.ThreadFactory() {
        @Override
        public Thread newThread(final Runnable r) {
            Thread t = new Thread(new Runnable() {
                @Override
                public void run() {
                    android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND);
                    r.run();
                }
            }, "ember-images");
            t.setDaemon(true);
            return t;
        }
    });
    // The title backdrop gets its own lane so it never waits behind a queue of posters.
    private final ExecutorService heroLane = Executors.newSingleThreadExecutor();
    private volatile String heroWanted;
    private final Handler main = new Handler(Looper.getMainLooper());

    private ImageLoader(Context ctx) {
        int maxKb = (int) (Runtime.getRuntime().maxMemory() / 1024 / 5);
        memory = new LruCache<String, Bitmap>(maxKb) {
            @Override
            protected int sizeOf(String key, Bitmap value) {
                return value.getByteCount() / 1024;
            }
        };
        diskDir = new File(ctx.getCacheDir(), "img");
        //noinspection ResultOfMethodCallIgnored
        diskDir.mkdirs();
        pool.execute(new Runnable() {
            @Override
            public void run() {
                trimDisk(150L * 1024 * 1024);
            }
        });
    }

    /** Keeps the poster cache under a size cap by deleting the oldest files. */
    private void trimDisk(long maxBytes) {
        File[] files = diskDir.listFiles();
        if (files == null) return;
        long total = 0;
        for (File f : files) total += f.length();
        if (total <= maxBytes) return;
        java.util.Arrays.sort(files, new java.util.Comparator<File>() {
            @Override
            public int compare(File a, File b) {
                return Long.compare(a.lastModified(), b.lastModified());
            }
        });
        for (File f : files) {
            if (total <= maxBytes * 3 / 4) break;
            total -= f.length();
            //noinspection ResultOfMethodCallIgnored
            f.delete();
        }
    }

    /** Loads url into view, scaled to roughly maxW x maxH pixels. Ignores stale results. */
    void into(final ImageView view, final String url, final int maxW, final int maxH) {
        view.setTag(R.id.ember_image_url, url);
        if (url == null || url.isEmpty()) {
            view.setImageDrawable(null);
            return;
        }
        Bitmap hit = memory.get(key(url, maxW));
        if (hit != null) {
            view.setImageBitmap(hit);
            return;
        }
        view.setImageDrawable(null);
        load(url, maxW, maxH, new Callback() {
            @Override
            public void onLoaded(Bitmap bmp) {
                if (url.equals(view.getTag(R.id.ember_image_url))) view.setImageBitmap(bmp);
            }
        });
    }

    void load(final String url, final int maxW, final int maxH, final Callback cb) {
        final String k = key(url, maxW);
        Bitmap hit = memory.get(k);
        if (hit != null) {
            cb.onLoaded(hit);
            return;
        }
        pool.execute(new Runnable() {
            @Override
            public void run() {
                Bitmap got = fetch(url, maxW, maxH);
                if (got == null) {
                    try {
                        Thread.sleep(1500);
                    } catch (InterruptedException ignored) {
                    }
                    got = fetch(url, maxW, maxH); // one retry: the network on the TV can blip
                }
                if (got == null) return;
                final Bitmap bmp = got;
                memory.put(k, bmp);
                main.post(new Runnable() {
                    @Override
                    public void run() {
                        cb.onLoaded(bmp);
                    }
                });
            }
        });
    }

    /** Loads the big title backdrop: tries each URL in turn, and drops requests you've already scrolled past. */
    void loadHero(final String[] urls, final int maxW, final int maxH, final Callback cb) {
        final String want = urls.length > 0 ? urls[0] : null;
        heroWanted = want;
        if (want == null) return;
        for (String u : urls) {
            Bitmap hit = u == null ? null : memory.get(key(u, maxW));
            if (hit != null) {
                cb.onLoaded(hit);
                return;
            }
        }
        heroLane.execute(new Runnable() {
            @Override
            public void run() {
                for (String u : urls) {
                    if (!want.equals(heroWanted)) return; // you've moved on: skip it
                    if (u == null || u.isEmpty()) continue;
                    final Bitmap bmp = fetch(u, maxW, maxH);
                    if (bmp == null) continue;
                    memory.put(key(u, maxW), bmp);
                    main.post(new Runnable() {
                        @Override
                        public void run() {
                            if (want.equals(heroWanted)) cb.onLoaded(bmp);
                        }
                    });
                    return;
                }
            }
        });
    }

    private Bitmap fetch(String url, int maxW, int maxH) {
        File f = new File(diskDir, hash(url));
        try {
            byte[] data = null;
            if (f.exists() && f.length() > 0) data = readAll(new FileInputStream(f));
            Bitmap fromDisk = data == null ? null : decode(data, maxW, maxH);
            if (fromDisk != null) return fromDisk;
            //noinspection ResultOfMethodCallIgnored
            f.delete(); // missing or unreadable: download it again
            data = download(url);
            if (data == null) return null;
            Bitmap bmp = decode(data, maxW, maxH);
            if (bmp == null) {
                android.util.Log.w("EmberImg", "couldn't decode " + url);
                return null;
            }
            try (FileOutputStream fos = new FileOutputStream(f)) {
                fos.write(data);
            }
            return bmp;
        } catch (Throwable e) {
            android.util.Log.w("EmberImg", e.getClass().getSimpleName() + " " + url);
            return null;
        }
    }

    /** Follows up to 5 redirects by hand, because Android won't follow one that switches http/https. */
    private static byte[] download(String url) throws java.io.IOException {
        String u = url;
        for (int hop = 0; hop < 5; hop++) {
            HttpURLConnection c = (HttpURLConnection) new URL(u).openConnection();
            c.setConnectTimeout(8000);
            c.setReadTimeout(15000);
            c.setInstanceFollowRedirects(false);
            c.setRequestProperty("User-Agent", "Mozilla/5.0 (Linux; Android 12) Ember-TV/1.0");
            try {
                int code = c.getResponseCode();
                if (code >= 300 && code < 400) {
                    String next = c.getHeaderField("Location");
                    if (next == null) break;
                    u = new URL(new URL(u), next).toString();
                    continue;
                }
                if (code != 200) {
                    android.util.Log.w("EmberImg", "HTTP " + code + " " + u);
                    return null;
                }
                return readAll(c.getInputStream());
            } finally {
                c.disconnect();
            }
        }
        android.util.Log.w("EmberImg", "too many redirects " + url);
        return null;
    }

    private static Bitmap decode(byte[] data, int maxW, int maxH) {
        BitmapFactory.Options o = new BitmapFactory.Options();
        o.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(data, 0, data.length, o);
        if (o.outWidth <= 0 || o.outHeight <= 0) return null;
        int sample = 1;
        while (o.outWidth / (sample * 2) >= maxW && o.outHeight / (sample * 2) >= maxH) sample *= 2;
        BitmapFactory.Options d = new BitmapFactory.Options();
        d.inSampleSize = sample;
        d.inPreferredConfig = Bitmap.Config.RGB_565;
        return BitmapFactory.decodeByteArray(data, 0, data.length, d);
    }

    private static String key(String url, int w) {
        return w + "|" + url;
    }

    private static String hash(String s) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-1");
            byte[] b = md.digest(s.getBytes("UTF-8"));
            StringBuilder sb = new StringBuilder();
            for (byte x : b) sb.append(String.format("%02x", x));
            return sb.toString();
        } catch (Exception e) {
            return Integer.toHexString(s.hashCode());
        }
    }

    private static byte[] readAll(InputStream in) throws java.io.IOException {
        try (InputStream is = in) {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[16384];
            int n;
            while ((n = is.read(buf)) > 0) bos.write(buf, 0, n);
            return bos.toByteArray();
        }
    }
}
