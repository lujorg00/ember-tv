package org.lucamedia.ember;

import android.service.dreams.DreamService;

/** The screensaver Google TV runs when the TV has been idle. */
public class EmberDream extends DreamService {

    private ScreensaverView view;

    @Override
    public void onAttachedToWindow() {
        super.onAttachedToWindow();
        setInteractive(false); // any button wakes the TV back up
        setFullscreen(true);
        setScreenBright(true);
        view = new ScreensaverView(this);
        setContentView(view);
    }

    @Override
    public void onDreamingStarted() {
        super.onDreamingStarted();
        if (view != null) view.start();
    }

    @Override
    public void onDreamingStopped() {
        super.onDreamingStopped();
        if (view != null) view.stop();
    }

    @Override
    public void onDetachedFromWindow() {
        if (view != null) view.stop();
        super.onDetachedFromWindow();
    }
}
