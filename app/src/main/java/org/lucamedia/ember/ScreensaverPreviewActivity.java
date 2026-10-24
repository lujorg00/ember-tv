package org.lucamedia.ember;

import android.app.Activity;
import android.os.Bundle;
import android.view.KeyEvent;

/** Shows the screensaver on demand from Ember settings. Any button closes it. */
public class ScreensaverPreviewActivity extends Activity {

    private ScreensaverView view;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        view = new ScreensaverView(this);
        setContentView(view);
    }

    @Override
    protected void onResume() {
        super.onResume();
        view.start();
    }

    @Override
    protected void onPause() {
        super.onPause();
        view.stop();
        finish(); // the view's worker is shut down, so don't come back to a dead preview
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        finish();
        return true;
    }
}
