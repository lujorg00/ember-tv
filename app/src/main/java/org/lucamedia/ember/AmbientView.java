package org.lucamedia.ember;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RadialGradient;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.Shader;
import android.os.SystemClock;
import android.view.View;

import java.util.Random;

/**
 * The Apps page's moving background, drawn by hand so it stays light on the Chromecast:
 *   DAY      warm paper under a pale sky, a bright sun top-right, soft clouds drifting across
 *   EVENING  a dark wall lit by a fire just out of view (bottom-left), flickering, with stray embers
 *   NIGHT    deep blue, twinkling stars, the odd shooting star, and tonight's real moon phase
 * Built for the Chromecast: nothing is painted pixel-by-pixel on the processor while it animates. Each
 * scene's still parts are pre-rendered once into small bitmaps; the moving parts (clouds, pools of
 * firelight, shadow) are small pre-made glow bitmaps the GPU just stretches and fades; and the crisp
 * details (stars, moon, embers, snow) are a few dozen dots. ~30fps, only while on screen, and it can
 * be switched to a still picture in Ember settings.
 */
final class AmbientView extends View {

    private static final long FRAME_MS = 33;
    private static final float SOFT_SCALE = 0.25f; // resolution of the pre-rendered still bases

    private SunClock.Mode mode = SunClock.Mode.NIGHT;
    private final Random rnd = new Random();
    private final float density;
    private final long start = SystemClock.uptimeMillis();
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
    private int w, h;
    private boolean animate = true;

    // Each mode's unchanging base, pre-rendered once at quarter resolution (uploaded to the GPU once).
    private Bitmap baseDay, baseEvening, baseNight;
    // Soft glow sprites for the firelight and shadow, made once; the GPU stretches them each frame.
    private Bitmap[] fireGlows;
    private Bitmap shadowGlow;
    private float[][] firePools; // {cx, cy, radius}
    private float[] shadowPool;  // {cx, cy, radius}
    private final RectF tmp = new RectF();
    private final RectF full = new RectF();

    // Day
    private Shader skyShader, sunShader;
    private Bitmap[] clouds;
    private float[][] cloudSpec; // {top fraction, width fraction, height fraction, seconds to cross, phase, alpha}

    // Evening
    private Shader[] fireShaders;
    private Shader shadowShader;
    private float[][] embers; // {startX, startY, lifeSec, phase, size}

    // Night
    private Shader moonlightShader;
    private float[][] stars; // {x, y, radius, speed, phase}
    private long nextMeteorAt;
    private float[] meteor; // {startX, startY, startTimeSec}
    private final Path moonPath = new Path();

    // December: light snow over whichever scene is showing.
    private float[][] flakes; // {x, startY, fallSpeed (px/s), size, swayPhase, isCrystal, spin}
    private Bitmap softFlake, crystal;

    AmbientView(Context ctx) {
        super(ctx);
        density = ctx.getResources().getDisplayMetrics().density;
        setWillNotDraw(false);
    }

    private float moonX = 0.40f, moonY = 0.075f;

    /** Where the moon sits, as fractions of the width and height. */
    void setMoonPosition(float fx, float fy) {
        moonX = fx;
        moonY = fy;
    }

    private long stillUntil;

    /** Freezes the animation for a moment (e.g. while the remote is being used), then carries on. */
    void holdStill(long ms) {
        stillUntil = SystemClock.uptimeMillis() + ms;
    }

    /** false = draw one still frame and stop (lighter on the Chromecast). */
    void setAnimate(boolean on) {
        animate = on;
        invalidate();
    }

    void setMode(SunClock.Mode m) {
        if (m == mode) return;
        mode = m;
        invalidate();
    }

    @Override
    protected void onSizeChanged(int nw, int nh, int ow, int oh) {
        w = nw;
        h = nh;
        if (w == 0 || h == 0) return;
        build();
    }

    private void build() {
        // Day: sky that fades into warm paper, and a bright sun in the top-right.
        skyShader = new LinearGradient(0, 0, 0, h,
                new int[]{0xFFB9D6EA, 0xFFD8E6EC, 0xFFF0EADF, 0xFFEADFCF},
                new float[]{0f, 0.34f, 0.66f, 1f}, Shader.TileMode.CLAMP);
        sunShader = new RadialGradient(w * 0.9f, -h * 0.1f, w * 0.42f,
                new int[]{0xFFFFFFFF, 0xF7FFFCE8, 0x99FFEAAF, 0x40FFDE96, 0x00FFDE96},
                new float[]{0f, 0.15f, 0.37f, 0.7f, 1f}, Shader.TileMode.CLAMP);
        clouds = new Bitmap[4];
        cloudSpec = new float[][]{
                {0.03f, 0.30f, 0.16f, 40f, 0.2f, 0.95f},
                {0.15f, 0.22f, 0.11f, 54f, 0.55f, 0.80f},
                {-0.03f, 0.36f, 0.15f, 48f, 0.75f, 0.90f},
                {0.25f, 0.20f, 0.07f, 66f, 0.40f, 0.60f}};
        for (int i = 0; i < clouds.length; i++) clouds[i] = makeCloud(i);

        // Evening: three pools of firelight from the bottom-left, toned down, fading fully to nothing (no edges).
        float cx = w * 0.05f, cy = h * 1.05f;
        fireShaders = new Shader[]{
                soft(cx, cy, w * 0.58f, Color.argb(74, 235, 110, 40)),
                soft(cx + w * 0.05f, cy - h * 0.04f, w * 0.38f, Color.argb(66, 255, 165, 70)),
                soft(cx + w * 0.10f, cy - h * 0.08f, w * 0.22f, Color.argb(58, 255, 205, 120))};
        shadowShader = soft(w * 0.8f, h * 0.55f, w * 0.22f, Color.argb(60, 0, 0, 0));
        embers = new float[5][];
        for (int i = 0; i < embers.length; i++) {
            embers[i] = new float[]{rnd.nextFloat() * w * 0.25f, h * (0.85f + rnd.nextFloat() * 0.15f),
                    7f + rnd.nextFloat() * 4f, rnd.nextFloat(), 1.2f + rnd.nextFloat() * 0.6f};
        }

        // Night: faint moonlight, stars, shooting stars.
        moonlightShader = soft(w * 0.85f, -h * 0.05f, w * 0.6f, Color.argb(61, 90, 105, 170));
        stars = new float[55][];
        for (int i = 0; i < stars.length; i++) {
            stars[i] = new float[]{rnd.nextFloat() * w, rnd.nextFloat() * h,
                    (rnd.nextFloat() < 0.15f ? 1.5f : 1f) * density, 0.9f + rnd.nextFloat() * 1.2f, rnd.nextFloat() * 6.28f};
        }
        nextMeteorAt = SystemClock.uptimeMillis() + 8000 + rnd.nextInt(20000);

        flakes = new float[30][];
        for (int i = 0; i < flakes.length; i++) {
            boolean near = rnd.nextFloat() < 0.2f;     // a few bigger, slightly quicker flakes in front give depth
            boolean isCrystal = rnd.nextFloat() < 0.3f; // some show the six-armed snowflake shape
            flakes[i] = new float[]{rnd.nextFloat() * w, rnd.nextFloat() * h,
                    (near ? 13f : 6f + rnd.nextFloat() * 5f) * density,
                    (isCrystal ? (near ? 8.25f : 5.25f) : (near ? 5.25f : 3f + rnd.nextFloat() * 1.5f)) * density,
                    rnd.nextFloat() * 6.28f, isCrystal ? 1f : 0f, (rnd.nextFloat() - 0.5f) * 30f};
        }
        softFlake = makeSoftFlake();
        crystal = makeCrystal();

        int lw = Math.max(1, Math.round(w * SOFT_SCALE)), lh = Math.max(1, Math.round(h * SOFT_SCALE));
        full.set(0, 0, w, h);
        firePools = new float[][]{{cx, cy, w * 0.58f}, {cx + w * 0.05f, cy - h * 0.04f, w * 0.38f}, {cx + w * 0.10f, cy - h * 0.08f, w * 0.22f}};
        fireGlows = new Bitmap[]{glow(Color.argb(74, 235, 110, 40)), glow(Color.argb(66, 255, 165, 70)), glow(Color.argb(58, 255, 205, 120))};
        shadowPool = new float[]{w * 0.8f, h * 0.55f, w * 0.22f};
        shadowGlow = glow(Color.argb(60, 0, 0, 0));
        baseDay = makeBase(lw, lh, 0xFFEADFCF, skyShader, sunShader);
        baseEvening = makeBase(lw, lh, 0xFF110A07);
        baseNight = makeBase(lw, lh, 0xFF0A0A10, moonlightShader);
    }

    /** A small soft round glow (fades fully to transparent) the GPU can stretch to any size cheaply. */
    private static Bitmap glow(int c) {
        Bitmap b = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888);
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.DITHER_FLAG);
        p.setShader(soft(48, 48, 48, c));
        new Canvas(b).drawRect(0, 0, 96, 96, p);
        return b;
    }

    private Bitmap makeBase(int lw, int lh, int colour, Shader... layers) {
        Bitmap b = Bitmap.createBitmap(lw, lh, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(b);
        c.scale(SOFT_SCALE, SOFT_SCALE);
        c.drawColor(colour);
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.DITHER_FLAG);
        for (Shader sh : layers) {
            p.setShader(sh);
            c.drawRect(0, 0, w, h, p);
        }
        return b;
    }

    /** A fluffy, soft-edged flake: white fading out to nothing. */
    private static Bitmap makeSoftFlake() {
        Bitmap b = Bitmap.createBitmap(32, 32, Bitmap.Config.ARGB_8888);
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        p.setShader(new RadialGradient(16, 16, 16, new int[]{0xFFFFFFFF, 0xCCFFFFFF, 0x33FFFFFF, 0x00FFFFFF},
                new float[]{0f, 0.35f, 0.7f, 1f}, Shader.TileMode.CLAMP));
        new Canvas(b).drawCircle(16, 16, 16, p);
        return b;
    }

    /** A delicate six-armed snowflake with small side branches. */
    private static Bitmap makeCrystal() {
        Bitmap b = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(b);
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        p.setColor(Color.WHITE);
        p.setStrokeWidth(2.4f);
        p.setStrokeCap(Paint.Cap.ROUND);
        c.translate(32, 32);
        for (int i = 0; i < 6; i++) {
            c.drawLine(0, 0, 0, -28, p);
            c.drawLine(0, -12, -7, -19, p);
            c.drawLine(0, -12, 7, -19, p);
            c.drawLine(0, -20, -5, -25, p);
            c.drawLine(0, -20, 5, -25, p);
            c.rotate(60);
        }
        p.setStyle(Paint.Style.FILL);
        c.drawCircle(0, 0, 3, p);
        return b;
    }

    private static boolean isDecember() {
        return java.util.Calendar.getInstance().get(java.util.Calendar.MONTH) == java.util.Calendar.DECEMBER;
    }

    private android.graphics.ColorFilter snowFilter;
    private int snowTint;
    private final RectF snowDst = new RectF();

    /** Light snowfall: slow, soft flakes and a few small crystals drifting and turning, tinted to suit the scene. */
    private void drawSnow(Canvas c, float t) {
        int tint;
        int alpha;
        switch (mode) {
            case DAY: tint = 0xFF8D9DB0; alpha = 150; break;     // soft blue-grey so it shows on the light page
            case EVENING: tint = 0xFFFFE6CC; alpha = 120; break; // warmed by the firelight
            default: tint = 0xFFF2F4FF; alpha = 170; break;      // crisp white at night
        }
        paint.setShader(null);
        if (snowFilter == null || snowTint != tint) {
            snowTint = tint;
            snowFilter = new android.graphics.PorterDuffColorFilter(tint, android.graphics.PorterDuff.Mode.SRC_IN);
        }
        paint.setColorFilter(snowFilter);
        paint.setAlpha(alpha);
        RectF dst = snowDst;
        for (float[] f : flakes) {
            float y = (f[1] + t * f[2]) % (h + 30 * density) - 15 * density;
            float x = f[0] + (float) Math.sin(t * 0.45f + f[4]) * 18 * density + t * 2 * density;
            x = ((x % w) + w) % w;
            float r = f[3];
            dst.set(x - r, y - r, x + r, y + r);
            if (f[5] > 0) {
                c.save();
                c.rotate(t * f[6] + f[4] * 57f, x, y); // crystals turn slowly as they fall
                c.drawBitmap(crystal, null, dst, paint);
                c.restore();
            } else {
                c.drawBitmap(softFlake, null, dst, paint);
            }
        }
        paint.setColorFilter(null);
        paint.setColor(Color.WHITE);
        paint.setAlpha(255);
    }

    /** A radial glow that fades smoothly to fully transparent, so it never shows a circle edge. */
    private static Shader soft(float x, float y, float r, int c) {
        int mid = Color.argb(Color.alpha(c) * 45 / 100, Color.red(c), Color.green(c), Color.blue(c));
        int low = Color.argb(Color.alpha(c) * 12 / 100, Color.red(c), Color.green(c), Color.blue(c));
        return new RadialGradient(x, y, r, new int[]{c, mid, low, c & 0x00FFFFFF},
                new float[]{0f, 0.35f, 0.7f, 1f}, Shader.TileMode.CLAMP);
    }

    /** Draws a few white puffs on a tiny bitmap; scaling it up later blurs it into a soft cloud. */
    private Bitmap makeCloud(int seed) {
        Random r = new Random(seed * 7919L + 13);
        Bitmap b = Bitmap.createBitmap(48, 20, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(b);
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        p.setColor(Color.WHITE);
        int puffs = 3 + r.nextInt(2);
        for (int i = 0; i < puffs; i++) {
            float cx = 10 + i * (28f / puffs) + r.nextFloat() * 6;
            float cy = 11 + r.nextFloat() * 3;
            float rx = 7 + r.nextFloat() * 5, ry = 4 + r.nextFloat() * 3;
            p.setAlpha(200 + r.nextInt(55));
            c.drawOval(new RectF(cx - rx, cy - ry, cx + rx, cy + ry), p);
        }
        return b;
    }

    @Override
    protected void onDraw(Canvas c) {
        if (w == 0 || h == 0 || baseDay == null) return;
        long nowMs = SystemClock.uptimeMillis();
        boolean holding = nowMs < stillUntil && lastT >= 0;
        float t = holding ? lastT : (nowMs - start) / 1000f;
        lastT = t;
        paint.setShader(null);
        paint.setColorFilter(null);
        paint.setAlpha(255);

        Bitmap base = mode == SunClock.Mode.DAY ? baseDay : mode == SunClock.Mode.EVENING ? baseEvening : baseNight;
        c.drawBitmap(base, null, full, paint); // static: the GPU keeps it, no re-upload
        if (mode == SunClock.Mode.DAY) drawClouds(c, t);
        else if (mode == SunClock.Mode.EVENING) drawFirelight(c, t);
        paint.setAlpha(255);
        drawCrisp(c, t);

        // Only keep animating while visible: never while an app is open over Ember. While the remote is
        // being used, hold the frame and check back when the hold ends.
        if (animate && isShown() && windowVisible) postInvalidateDelayed(holding ? stillUntil - nowMs : FRAME_MS);
    }

    private float lastT = -1;

    private void drawCrisp(Canvas c, float t) {
        if (mode == SunClock.Mode.EVENING) drawEmbers(c, t);
        else if (mode == SunClock.Mode.NIGHT) drawSky(c, t);
        if (isDecember()) drawSnow(c, t);
    }

    private boolean windowVisible = true;

    @Override
    protected void onWindowVisibilityChanged(int visibility) {
        super.onWindowVisibilityChanged(visibility);
        windowVisible = visibility == VISIBLE;
        if (windowVisible) invalidate();
    }

    @Override
    protected void onVisibilityChanged(View changedView, int visibility) {
        super.onVisibilityChanged(changedView, visibility);
        if (visibility == VISIBLE) invalidate(); // restart the loop when the Apps page comes back
    }

    private final Rect cloudSrc = new Rect(0, 0, 48, 20);
    private final RectF cloudDst = new RectF();

    private void drawClouds(Canvas c, float t) {
        paint.setShader(null);
        Rect src = cloudSrc;
        RectF dst = cloudDst;
        for (int i = 0; i < clouds.length; i++) {
            float[] s = cloudSpec[i];
            float cw = s[1] * w, ch = s[2] * h * 1.6f;
            float travel = w + cw * 2;
            float x = ((t / s[3] + s[4]) % 1f) * travel - cw;
            float y = s[0] * h - ch * 0.15f;
            dst.set(x, y, x + cw, y + ch);
            paint.setAlpha((int) (s[5] * 255));
            c.drawBitmap(clouds[i], src, dst, paint);
        }
        paint.setAlpha(255);
    }

    private void drawFirelight(Canvas c, float t) {
        // Each pool flickers on its own rhythm, which is what makes firelight feel alive.
        float[][] beat = {{2.7f, 6.3f, 11f}, {4.1f, 8.9f, 13.7f}, {6.6f, 12.4f, 17.3f}};
        for (int i = 0; i < firePools.length; i++) {
            float f = 0.75f + 0.15f * (float) Math.sin(t * beat[i][0] + i)
                    + 0.08f * (float) Math.sin(t * beat[i][1] + i * 2) + 0.05f * (float) Math.sin(t * beat[i][2] + i * 3);
            float dx = (float) Math.sin(t * 0.9f + i) * 10 * density, dy = (float) Math.cos(t * 1.3f + i) * 6 * density;
            float[] pl = firePools[i];
            tmp.set(pl[0] + dx - pl[2], pl[1] + dy - pl[2], pl[0] + dx + pl[2], pl[1] + dy + pl[2]);
            paint.setAlpha((int) (Math.max(0f, Math.min(1f, f)) * 255));
            c.drawBitmap(fireGlows[i], null, tmp, paint);
        }
        float sx = (float) Math.sin(t * 1.4f) * 14 * density;
        tmp.set(shadowPool[0] + sx - shadowPool[2], shadowPool[1] - shadowPool[2], shadowPool[0] + sx + shadowPool[2], shadowPool[1] + shadowPool[2]);
        paint.setAlpha(255);
        c.drawBitmap(shadowGlow, null, tmp, paint);
    }

    private void drawEmbers(Canvas c, float t) {
        // Stray embers drifting up and across from the fire's side, cooling from yellow to red.
        for (float[] e : embers) {
            float life = ((t / e[2]) + e[3]) % 1f;
            float x = e[0] + life * 90 * density + (float) Math.sin(life * 9 + e[3] * 6) * 6 * density;
            float y = e[1] - life * 150 * density;
            int col = life < 0.35f ? blend(0xFFFFE08A, 0xFFFFB040, life / 0.35f)
                    : life < 0.7f ? blend(0xFFFFB040, 0xFFFF6A20, (life - 0.35f) / 0.35f)
                    : blend(0xFFFF6A20, 0xFFA02A10, (life - 0.7f) / 0.3f);
            float a = life < 0.1f ? life / 0.1f : 1f - Math.max(0f, (life - 0.6f) / 0.4f);
            float r = e[4] * density * (1f - life * 0.5f);
            paint.setColor(col);
            paint.setAlpha((int) (a * 70));
            c.drawCircle(x, y, r * 3.2f, paint);
            paint.setAlpha((int) (a * 255));
            c.drawCircle(x, y, r, paint);
        }
        paint.setColor(Color.WHITE);
    }

    private void drawSky(Canvas c, float t) {
        paint.setShader(null);
        paint.setColor(0xFFE8ECFF);
        for (float[] s : stars) {
            float tw = 0.25f + 0.75f * (0.5f + 0.5f * (float) Math.sin(t * s[3] + s[4]));
            paint.setAlpha((int) (tw * 255));
            c.drawCircle(s[0], s[1], s[2], paint);
        }

        drawMoon(c, w * moonX, h * moonY, 8 * density);

        // A shooting star every 20 to 60 seconds.
        long now = SystemClock.uptimeMillis();
        if (meteor == null && now >= nextMeteorAt) {
            meteor = new float[]{w * (0.45f + rnd.nextFloat() * 0.5f), h * rnd.nextFloat() * 0.3f, t};
            nextMeteorAt = now + 20000 + rnd.nextInt(40000);
        }
        if (meteor != null) {
            float p = (t - meteor[2]) / 0.9f;
            if (p >= 1f) {
                meteor = null;
            } else {
                float len = 70 * density;
                float dist = p * 190 * density;
                float ang = (float) Math.toRadians(152);
                float hx = meteor[0] + (float) Math.cos(ang) * dist, hy = meteor[1] + (float) Math.sin(ang) * dist;
                float tx = hx - (float) Math.cos(ang) * len, ty = hy - (float) Math.sin(ang) * len;
                float a = p < 0.15f ? p / 0.15f : 1f - (p - 0.15f) / 0.85f;
                paint.setShader(new LinearGradient(tx, ty, hx, hy, 0x00FFFFFF, Color.argb((int) (a * 255), 255, 255, 255), Shader.TileMode.CLAMP));
                paint.setStrokeWidth(1.5f * density);
                paint.setStrokeCap(Paint.Cap.ROUND);
                c.drawLine(tx, ty, hx, hy, paint);
                paint.setShader(null);
            }
        }
        paint.setColor(Color.WHITE);
        paint.setAlpha(255);
    }

    /** Draws the moon as it actually looks tonight (waxing lit on the right, waning on the left, as seen from the UK). */
    private void drawMoon(Canvas c, float cx, float cy, float r) {
        double age = SunClock.moonAgeDays(System.currentTimeMillis());
        double phase = age / 29.530588853; // 0 new, 0.5 full
        paint.setColor(0x26E9E6DA);
        c.drawCircle(cx, cy, r, paint); // the faint unlit disc
        if (phase < 0.02 || phase > 0.98) return; // new moon: just the faint disc
        float k = (float) Math.cos(phase * 2 * Math.PI); // 1 new, -1 full
        boolean waxing = phase < 0.5;
        moonPath.reset();
        RectF disc = new RectF(cx - r, cy - r, cx + r, cy + r);
        // Lit limb: the right half when waxing, left half when waning.
        moonPath.arcTo(disc, -90, waxing ? 180 : -180);
        // Terminator: half an ellipse whose width depends on the phase.
        float tw = Math.abs(k) * r;
        RectF term = new RectF(cx - tw, cy - r, cx + tw, cy + r);
        boolean bulgesOut = k < 0; // gibbous: terminator bulges into the dark side
        // Crescent: terminator curves towards the lit side; gibbous: towards the dark side.
        float sweep = (waxing ^ bulgesOut) ? -180 : 180;
        moonPath.arcTo(term, 90, sweep);
        moonPath.close();
        paint.setColor(0xFFE9E6DA);
        c.drawPath(moonPath, paint);
    }

    private static int blend(int a, int b, float f) {
        f = Math.max(0f, Math.min(1f, f));
        return Color.argb(255,
                (int) (Color.red(a) + (Color.red(b) - Color.red(a)) * f),
                (int) (Color.green(a) + (Color.green(b) - Color.green(a)) * f),
                (int) (Color.blue(a) + (Color.blue(b) - Color.blue(a)) * f));
    }
}
