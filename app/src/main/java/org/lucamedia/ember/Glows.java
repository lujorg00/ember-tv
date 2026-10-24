package org.lucamedia.ember;

import android.animation.ValueAnimator;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.view.View;

import java.util.HashMap;
import java.util.Map;

/**
 * A soft glow on the Apps page that takes on the focused app's colour (the moving day / evening /
 * night scene behind it is AmbientView).
 */
final class Glows {

    private final GradientDrawable appGlow;
    private float strength = 1f;
    private final Map<String, Integer> appColours = new HashMap<>();
    private int appColour = 0x00000000;
    private ValueAnimator appAnim;

    Glows(View appLayer, int screenW) {
        appGlow = radial(0.18f, 0.6f, screenW * 0.5f);
        appLayer.setBackground(appGlow);
    }

    /** How strongly the app colour shows: softer on the light daytime page and at night. */
    void setStrength(float s) {
        strength = s;
    }

    private static GradientDrawable radial(float cx, float cy, float radius) {
        GradientDrawable d = new GradientDrawable();
        d.setGradientType(GradientDrawable.RADIAL_GRADIENT);
        d.setGradientCenter(cx, cy);
        d.setGradientRadius(radius);
        d.setColors(new int[]{0x00000000, 0x00000000});
        return d;
    }

    /** Fades the left glow to the colour of the app's banner or icon. */
    void focusApp(String key, Drawable art) {
        Integer c = appColours.get(key);
        if (c == null) {
            c = glowColour(art);
            appColours.put(key, c);
        }
        c = Color.argb((int) (Color.alpha(c) * strength), Color.red(c), Color.green(c), Color.blue(c));
        appAnim = fade(appAnim, appColour, c, appGlow, 600);
        appColour = c;
    }

    private static ValueAnimator fade(ValueAnimator running, int from, int to, final GradientDrawable d, long ms) {
        if (running != null) running.cancel();
        ValueAnimator a = ValueAnimator.ofArgb(from, to);
        a.setDuration(ms);
        a.addUpdateListener(new ValueAnimator.AnimatorUpdateListener() {
            @Override
            public void onAnimationUpdate(ValueAnimator va) {
                int c = (int) va.getAnimatedValue();
                d.setColors(new int[]{c, c & 0x00FFFFFF});
            }
        });
        a.start();
        return a;
    }

    /** Average colour of the artwork, pushed to a rich, mid-bright tone so it glows rather than greys. */
    private static int glowColour(Drawable art) {
        if (art == null) return 0x40F0A04B;
        try {
            Bitmap b = Bitmap.createBitmap(16, 9, Bitmap.Config.ARGB_8888);
            Canvas cv = new Canvas(b);
            Drawable d = art.getConstantState() != null ? art.getConstantState().newDrawable().mutate() : art;
            d.setBounds(0, 0, 16, 9);
            d.draw(cv);
            long r = 0, g = 0, bl = 0, n = 0;
            for (int y = 0; y < 9; y++) {
                for (int x = 0; x < 16; x++) {
                    int p = b.getPixel(x, y);
                    if (Color.alpha(p) < 128) continue;
                    float[] hsv = new float[3];
                    Color.colorToHSV(p, hsv);
                    int w = hsv[1] > 0.25f && hsv[2] > 0.2f ? 4 : 1; // favour the colourful pixels
                    r += Color.red(p) * w;
                    g += Color.green(p) * w;
                    bl += Color.blue(p) * w;
                    n += w;
                }
            }
            b.recycle();
            if (n == 0) return 0x40F0A04B;
            float[] hsv = new float[3];
            Color.RGBToHSV((int) (r / n), (int) (g / n), (int) (bl / n), hsv);
            if (hsv[1] < 0.15f) return 0x30C9B6A6; // black/white/grey artwork: a quiet neutral glow
            hsv[1] = Math.max(hsv[1], 0.6f);
            hsv[2] = 0.75f;
            return Color.HSVToColor(0x66, hsv);
        } catch (Exception e) {
            return 0x40F0A04B;
        }
    }
}
