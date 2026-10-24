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
    private final ExecutorService pool = Executors.newFixedThreadPool(4);
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
                final Bitmap bmp = fetch(url, maxW, maxH);
                if (bmp == null) return;
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

    private Bitmap fetch(String url, int maxW, int maxH) {
        try {
            File f = new File(diskDir, hash(url));
            byte[] data;
            if (f.exists() && f.length() > 0) {
                data = readAll(new FileInputStream(f));
            } else {
                HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
                c.setConnectTimeout(8000);
                c.setReadTimeout(15000);
                c.setInstanceFollowRedirects(true);
                c.setRequestProperty("User-Agent", "Ember-TV/1.0");
                try {
                    if (c.getResponseCode() != 200) return null;
                    data = readAll(c.getInputStream());
                } finally {
                    c.disconnect();
                }
                try (FileOutputStream fos = new FileOutputStream(f)) {
                    fos.write(data);
                }
            }
            BitmapFactory.Options o = new BitmapFactory.Options();
            o.inJustDecodeBounds = true;
            BitmapFactory.decodeByteArray(data, 0, data.length, o);
            int sample = 1;
            while (o.outWidth / (sample * 2) >= maxW && o.outHeight / (sample * 2) >= maxH) sample *= 2;
            BitmapFactory.Options d = new BitmapFactory.Options();
            d.inSampleSize = sample;
            d.inPreferredConfig = Bitmap.Config.RGB_565;
            return BitmapFactory.decodeByteArray(data, 0, data.length, d);
        } catch (Exception e) {
            return null;
        }
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
