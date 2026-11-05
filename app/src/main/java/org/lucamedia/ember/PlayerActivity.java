package org.lucamedia.ember;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;

import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.TrackSelectionParameters;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.ui.AspectRatioFrameLayout;
import androidx.media3.ui.PlayerView;
import androidx.media3.ui.SubtitleView;

import org.json.JSONObject;

import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

/**
 * Ember TV's player (Media3 / ExoPlayer). Does what ember.lua does in mpv on the PC:
 * starts at the saved point, reports where you are to lucapi (every 15 s, on pause and on stop), gives up on a
 * stream that won't start or keeps stalling so Ember can try the next best one, and offers "next episode".
 * Result codes (as mpv's exit codes on the PC): 0 normal, 2 couldn't play, 4 stalled, 5 next episode.
 */
public class PlayerActivity extends Activity {
    private static final String TAG = "EmberPlayer";
    private static final int EXIT_ERROR = 2, EXIT_STALL = 4, EXIT_NEXT = 5;

    private ExoPlayer player;
    private PlayerView view;
    private TextView titleView, nextButton;
    private final Handler h = new Handler(Looper.getMainLooper());
    private final Map<String, String> o = new HashMap<>();
    private boolean started = false, done = false, hasNext = false;
    private long bufferingSince = 0;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        String url = getIntent().getStringExtra("url");
        double start = getIntent().getDoubleExtra("start", 0);
        String title = getIntent().getStringExtra("title");
        for (String kv : String.valueOf(getIntent().getStringExtra("opts")).split(",")) {
            int i = kv.indexOf('=');
            if (i > 0) o.put(kv.substring(0, i).trim(), kv.substring(i + 1).trim());
        }
        hasNext = "yes".equals(o.get("ember_osc-next"));

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        view = new PlayerView(this);
        view.setKeepScreenOn(true);
        view.setShowBuffering(PlayerView.SHOW_BUFFERING_ALWAYS);
        view.setResizeMode(AspectRatioFrameLayout.RESIZE_MODE_FIT);
        view.setControllerShowTimeoutMs(3500);
        view.setShowSubtitleButton(true);
        view.setShowNextButton(false);
        view.setShowPreviousButton(false);
        root.addView(view, new FrameLayout.LayoutParams(-1, -1));

        // the title, top left, while the controls are showing (like the PC player)
        titleView = new TextView(this);
        titleView.setText(title == null ? "" : title.replace("  ·  ", "  ·  "));
        titleView.setTextColor(Color.WHITE);
        titleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        titleView.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        titleView.setShadowLayer(12, 0, 2, Color.BLACK);
        FrameLayout.LayoutParams tl = new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.START);
        tl.setMargins(dp(48), dp(32), dp(48), 0);
        root.addView(titleView, tl);

        // "Next episode", bottom right above the controls, for series
        nextButton = new TextView(this);
        nextButton.setText("Next episode  ›");
        nextButton.setTextColor(Color.parseColor("#1A0F08"));
        nextButton.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        nextButton.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        nextButton.setPadding(dp(18), dp(10), dp(18), dp(10));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(Color.parseColor("#F0A04B"));
        bg.setCornerRadius(dp(10));
        nextButton.setBackground(bg);
        nextButton.setFocusable(true);
        nextButton.setOnClickListener(v -> finishWith(EXIT_NEXT));
        nextButton.setOnFocusChangeListener((v, f) -> v.setScaleX(f ? 1.08f : 1f));
        FrameLayout.LayoutParams nl = new FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.END);
        nl.setMargins(0, 0, dp(48), dp(120));
        root.addView(nextButton, nl);
        nextButton.setVisibility(View.GONE);
        setContentView(root);

        view.setControllerVisibilityListener((PlayerView.ControllerVisibilityListener) visibility -> {
            titleView.setVisibility(visibility);
            nextButton.setVisibility(hasNext ? visibility : View.GONE);
        });

        player = new ExoPlayer.Builder(this, new DefaultRenderersFactory(this).setEnableDecoderFallback(true)).build();
        // English audio and subtitles first, as on the PC; Dolby / DTS go untouched to the TV or soundbar when it can take them
        TrackSelectionParameters p = player.getTrackSelectionParameters().buildUpon()
                .setPreferredAudioLanguage("en").setPreferredTextLanguage("en").build();
        player.setTrackSelectionParameters(p);
        view.setPlayer(player);
        SubtitleView sv = view.getSubtitleView();
        if (sv != null) sv.setFractionalTextSize(SubtitleView.DEFAULT_TEXT_SIZE_FRACTION * 0.9f);

        player.addListener(new Player.Listener() {
            @Override
            public void onPlaybackStateChanged(int s) {
                if (s == Player.STATE_READY) {
                    started = true;
                    bufferingSince = 0;
                } else if (s == Player.STATE_BUFFERING && started) {
                    bufferingSince = System.currentTimeMillis();
                } else if (s == Player.STATE_ENDED) {
                    report("stopped", true);
                    finishWith(0);
                }
            }

            @Override
            public void onIsPlayingChanged(boolean isPlaying) {
                if (!isPlaying && started && !done) report("paused", false);
            }

            @Override
            public void onPlayerError(PlaybackException e) {
                Log.w(TAG, "playback error: " + e.getErrorCodeName() + " " + e.getMessage());
                if (started && player.getCurrentPosition() > 60_000) report("stopped", false);
                finishWith(started ? EXIT_STALL : EXIT_ERROR);
            }
        });

        player.setMediaItem(MediaItem.fromUri(Uri.parse(url)));
        player.prepare();
        if (start > 0) player.seekTo((long) (start * 1000));
        player.setPlayWhenReady(true);

        h.postDelayed(tick, 1000);
        // not started after 25 s: let Ember try the next stream
        h.postDelayed(() -> { if (!started && !done) finishWith(EXIT_STALL); }, 25_000);
    }

    private long lastReport = 0;
    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            if (done) return;
            long now = System.currentTimeMillis();
            if (started && player.isPlaying() && now - lastReport > 15_000) report("playing", false);
            // stuck buffering for more than 12 s once it had started: this stream isn't keeping up
            if (bufferingSince > 0 && now - bufferingSince > 12_000) {
                report("stopped", false);
                finishWith(EXIT_STALL);
                return;
            }
            h.postDelayed(this, 1000);
        }
    };

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }

    /** Where you are, to lucapi (the same report ember.lua sends from the PC). */
    private void report(String state, boolean finished) {
        final String feed = o.get("ember-feed"), imdb = o.get("ember-imdb");
        if (feed == null || feed.isEmpty() || imdb == null || imdb.isEmpty() || player == null) return;
        long pos = Math.max(0, player.getCurrentPosition()), dur = player.getDuration();
        if (!started || pos < 1000) return;
        lastReport = System.currentTimeMillis();
        try {
            final JSONObject b = new JSONObject();
            b.put("imdb", imdb);
            b.put("type", "series".equals(o.get("ember-type")) ? "series" : "movie");
            if (o.get("ember-season") != null && !o.get("ember-season").isEmpty()) b.put("season", Integer.parseInt(o.get("ember-season")));
            if (o.get("ember-episode") != null && !o.get("ember-episode").isEmpty()) b.put("episode", Integer.parseInt(o.get("ember-episode")));
            b.put("position", pos / 1000.0);
            if (dur != C.TIME_UNSET && dur > 0) b.put("duration", dur / 1000.0);
            b.put("device", o.containsKey("ember-device") ? o.get("ember-device") : "Ember TV");
            b.put("state", state);
            b.put("finished", finished);
            new Thread(() -> {
                try {
                    HttpURLConnection c = (HttpURLConnection) new URL(feed + "/progress/report").openConnection();
                    c.setRequestMethod("POST");
                    c.setConnectTimeout(5000);
                    c.setReadTimeout(6000);
                    c.setDoOutput(true);
                    c.setRequestProperty("Content-Type", "application/json");
                    try (OutputStream out = c.getOutputStream()) { out.write(b.toString().getBytes(StandardCharsets.UTF_8)); }
                    Log.d(TAG, state + " at " + (pos / 1000) + "s -> " + c.getResponseCode());
                    c.disconnect();
                } catch (Exception e) {
                    Log.w(TAG, "report failed: " + e);
                }
            }).start();
        } catch (Exception e) {
            Log.w(TAG, "report: " + e);
        }
    }

    private void finishWith(int code) {
        if (done) return;
        done = true;
        h.removeCallbacksAndMessages(null);
        setResult(code == 0 ? RESULT_CANCELED : code);
        finish();
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent e) {
        int k = e.getKeyCode();
        if (k == KeyEvent.KEYCODE_BACK && e.getAction() == KeyEvent.ACTION_UP) {
            if (view.isControllerFullyVisible()) { view.hideController(); return true; }
            report("stopped", false);
            finishWith(0);
            return true;
        }
        if (k == KeyEvent.KEYCODE_BACK) return true;
        if (k == KeyEvent.KEYCODE_MEDIA_NEXT && hasNext && e.getAction() == KeyEvent.ACTION_UP) { finishWith(EXIT_NEXT); return true; }
        // the remote's own play/pause and fast-forward/rewind work as they do in other TV apps
        if (e.getAction() == KeyEvent.ACTION_DOWN && !view.isControllerFullyVisible()
                && (k == KeyEvent.KEYCODE_DPAD_LEFT || k == KeyEvent.KEYCODE_DPAD_RIGHT)) {
            player.seekTo(Math.max(0, player.getCurrentPosition() + (k == KeyEvent.KEYCODE_DPAD_RIGHT ? 10_000 : -10_000)));
            view.showController();
            return true;
        }
        return view.dispatchKeyEvent(e) || super.dispatchKeyEvent(e);
    }

    @Override
    protected void onStop() {
        super.onStop();
        if (!done) {
            report("stopped", false);
            finishWith(0);
        }
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        h.removeCallbacksAndMessages(null);
        if (player != null) {
            player.release();
            player = null;
        }
    }
}
