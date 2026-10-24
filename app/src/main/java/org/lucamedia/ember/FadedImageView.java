package org.lucamedia.ember;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.PorterDuff;
import android.graphics.PorterDuffXfermode;
import android.graphics.Shader;
import android.widget.ImageView;

/**
 * The title backdrop on the home page. It fades itself out towards its left and bottom edges,
 * so the day / evening / night scene behind shows through instead of a hard edge or a dark band.
 */
final class FadedImageView extends ImageView {

    private final Paint mask = new Paint(Paint.ANTI_ALIAS_FLAG);
    private Shader left, bottom;

    FadedImageView(Context ctx) {
        super(ctx);
        mask.setXfermode(new PorterDuffXfermode(PorterDuff.Mode.DST_IN));
    }

    @Override
    protected void onSizeChanged(int w, int h, int ow, int oh) {
        super.onSizeChanged(w, h, ow, oh);
        left = new LinearGradient(0, 0, w * 0.55f, 0, 0x00000000, 0xFF000000, Shader.TileMode.CLAMP);
        bottom = new LinearGradient(0, h * 0.45f, 0, h, 0xFF000000, 0x00000000, Shader.TileMode.CLAMP);
    }

    @Override
    protected void onDraw(Canvas c) {
        if (left == null || getDrawable() == null) {
            super.onDraw(c);
            return;
        }
        int save = c.saveLayer(0, 0, getWidth(), getHeight(), null);
        super.onDraw(c);
        mask.setShader(left);
        c.drawRect(0, 0, getWidth(), getHeight(), mask);
        mask.setShader(bottom);
        c.drawRect(0, 0, getWidth(), getHeight(), mask);
        c.restoreToCount(save);
    }
}
