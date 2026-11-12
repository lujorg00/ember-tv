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
import android.widget.LinearLayout;
import android.widget.TextView;

import androidx.media3.common.C;
import androidx.media3.common.text.Cue;
import androidx.media3.common.text.CueGroup;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.TrackSelectionParameters;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.ui.AspectRatioFrameLayout;
import androidx.media3.ui.DefaultTimeBar;
import androidx.media3.ui.TimeBar;
import androidx.media3.ui.PlayerView;
import androidx.media3.ui.CaptionStyleCompat;
import androidx.media3.ui.SubtitleView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Ember TV's player (Media3 / ExoPlayer). Does what ember.lua does in mpv on the PC:
 * starts at the saved point, reports where you are to lucapi (every 15 s, on pause and on stop), gives up on a
 * stream that won't start or keeps stalling so Ember can try the next best one, and offers "next episode".
 * Result codes (as mpv's exit codes on the PC): 0 normal, 2 couldn't play, 4 stalled, 5 next episode.
 */
public class PlayerActivity extends Activity {
    private static final String TAG = "EmberPlayer";
    /** Ember's player is open (the overlay doesn't offer to join a room this TV is already in). */
    static volatile boolean active = false;
    private static final int EXIT_ERROR = 2, EXIT_STALL = 4, EXIT_NEXT = 5;

    private ExoPlayer player;
    private PlayerView view;
    private TextView titleView, nextButton;
    // "Next episode" pop-up at the start of the credits: counts down, then plays it
    private LinearLayout upNext;
    private TextView upNextText, upNextPlay, upNextStay;
    private boolean upNextShown = false, creditsWanted = false;
    private int countdown = 0;
    private static final int COUNTDOWN_S = 15;
    private static final int ACCENT = Color.parseColor("#F0A04B"), INK = Color.parseColor("#1A0F08");
    private final Handler h = new Handler(Looper.getMainLooper());
    private final Map<String, String> o = new HashMap<>();
    private boolean started = false, done = false, hasNext = false;
    private long introUntil = 0;   // the title stays at the top for the first 13 s of a stream
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
        active = true;

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
        style(nextButton, true);
        nextButton.setOnClickListener(v -> { report("stopped", true); finishWith(EXIT_NEXT); });
        FrameLayout.LayoutParams nl = new FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.END);
        nl.setMargins(0, 0, dp(48), dp(120));
        root.addView(nextButton, nl);
        nextButton.setVisibility(View.GONE);

        // Up next: bottom right, over the credits
        upNext = new LinearLayout(this);
        upNext.setOrientation(LinearLayout.VERTICAL);
        upNext.setPadding(dp(20), dp(16), dp(20), dp(18));
        GradientDrawable ub = new GradientDrawable();
        ub.setColor(Color.argb(235, 20, 15, 11));
        ub.setCornerRadius(dp(14));
        ub.setStroke(dp(1), Color.argb(30, 255, 255, 255));
        upNext.setBackground(ub);
        upNextText = new TextView(this);
        upNextText.setTextColor(Color.WHITE);
        upNextText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 17);
        upNextText.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        upNext.addView(upNextText);
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        upNextPlay = pill("Play now");
        upNextStay = pill("Watch credits");
        LinearLayout.LayoutParams bl = new LinearLayout.LayoutParams(-2, -2);
        bl.setMargins(0, dp(12), dp(10), 0);
        row.addView(upNextPlay, bl);
        row.addView(upNextStay, new LinearLayout.LayoutParams(bl));
        upNext.addView(row);
        upNextPlay.setOnClickListener(v -> { report("stopped", true); finishWith(EXIT_NEXT); });
        upNextStay.setOnClickListener(v -> { creditsWanted = true; hideUpNext(); });
        FrameLayout.LayoutParams ul = new FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.END);
        ul.setMargins(0, 0, dp(48), dp(48));
        root.addView(upNext, ul);
        upNext.setVisibility(View.GONE);
        setContentView(root);

        view.setControllerVisibilityListener((PlayerView.ControllerVisibilityListener) visibility -> {
            if (visibility == View.VISIBLE) { titleView.animate().cancel(); titleView.setAlpha(1f); titleView.setVisibility(View.VISIBLE); }
            else if (System.currentTimeMillis() >= introUntil) titleView.setVisibility(View.GONE);
            nextButton.setVisibility(hasNext && !upNextShown ? visibility : View.GONE);
            // controls up: the timeline has the focus, so left/right skip straight away (10 s a press, faster held)
            // (a moment later: the player puts the focus on play/pause itself as the controls appear)
            if (visibility == View.VISIBLE && !upNextShown) h.postDelayed(this::focusTimeline, 150);
        });

        // the Chromecast's own decoders first; FFmpeg's for the audio it can't do (DTS, TrueHD...), so nothing is skipped
        DefaultRenderersFactory rf = new DefaultRenderersFactory(this).setEnableDecoderFallback(true)
                .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON);
        player = new ExoPlayer.Builder(this, rf).build();
        // the TV's refresh rate follows the film (24p stays 24p) when "Match content frame rate" is on in Google TV's settings
        player.setVideoChangeFrameRateStrategy(C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_OFF);
        // English audio and subtitles first, as on the PC; Dolby / DTS go untouched to the TV or soundbar when it can take them
        TrackSelectionParameters p = player.getTrackSelectionParameters().buildUpon()
                .setPreferredAudioLanguage("en").setPreferredTextLanguage("en").build();
        player.setTrackSelectionParameters(p);
        view.setPlayer(player);
        // the timeline: selectable with the remote, 10 s a press, in Ember's colour
        View tbv = view.findViewById(androidx.media3.ui.R.id.exo_progress);
        if (tbv instanceof TimeBar) ((TimeBar) tbv).setKeyTimeIncrement(10_000);
        if (tbv instanceof DefaultTimeBar) {
            ((DefaultTimeBar) tbv).setPlayedColor(ACCENT);
            ((DefaultTimeBar) tbv).setScrubberColor(ACCENT);
        }
        if (tbv != null) {
            tbv.setFocusable(true);
            tbv.setFocusableInTouchMode(false);
            if (tbv instanceof DefaultTimeBar) tbv.setOnFocusChangeListener((v, f) -> ((DefaultTimeBar) v).setScrubberColor(f ? Color.WHITE : ACCENT));
        }
        SubtitleView sv = view.getSubtitleView();
        if (sv != null) {
            // like Netflix: white text with a dark outline, no black box (the TV's own caption style has one),
            // and the stream's own boxes and colours ignored
            sv.setApplyEmbeddedStyles(false);
            sv.setApplyEmbeddedFontSizes(false);
            sv.setStyle(new CaptionStyleCompat(Color.WHITE, Color.TRANSPARENT, Color.TRANSPARENT,
                    CaptionStyleCompat.EDGE_TYPE_OUTLINE, 0xE6000000, subFont()));
            sv.setFractionalTextSize(SubtitleView.DEFAULT_TEXT_SIZE_FRACTION);
            sv.setBottomPaddingFraction(0.07f);
        }

        player.addListener(new Player.Listener() {
            // runs after the player view's own listener: the same lines again, ALL-CAPS ones in sentence case
            @Override
            public void onCues(CueGroup cues) {
                SubtitleView v = view.getSubtitleView();
                if (v == null) return;
                List<Cue> out = new ArrayList<>();
                for (Cue c : cues.cues) {
                    if (c.text == null) { out.add(c); continue; }
                    out.add(c.buildUpon().setText(Subs.sentenceCase(c.text.toString())).build());
                }
                v.setCues(out);
            }

            @Override
            public void onPlaybackStateChanged(int s) {
                if (s == Player.STATE_READY) {
                    if (!started) {
                        // when a stream begins: the title lingers, then fades away (unless the controls are up)
                        introUntil = System.currentTimeMillis() + 13_000;
                        titleView.setAlpha(1f);
                        titleView.setVisibility(View.VISIBLE);
                        h.postDelayed(() -> {
                            if (view.isControllerFullyVisible()) return;
                            titleView.animate().alpha(0f).setDuration(1200).withEndAction(() -> {
                                if (!view.isControllerFullyVisible()) titleView.setVisibility(View.GONE);
                                titleView.setAlpha(1f);
                            }).start();
                        }, 13_000);
                    }
                    started = true;
                    bufferingSince = 0;
                } else if (s == Player.STATE_BUFFERING && started) {
                    bufferingSince = System.currentTimeMillis();
                } else if (s == Player.STATE_ENDED) {
                    report("stopped", true);
                    finishWith(hasNext ? EXIT_NEXT : 0); // a series carries on with the next episode
                }
            }

            // Subtitles "None": the player only switches off subtitles that aren't in a preferred language,
            // and English is preferred, so English ones stayed on. Dropping the preference makes "None" mean none.
            @Override
            public void onTrackSelectionParametersChanged(TrackSelectionParameters p) {
                if (p.ignoredTextSelectionFlags != 0 && !p.preferredTextLanguages.isEmpty())
                    player.setTrackSelectionParameters(p.buildUpon().setPreferredTextLanguages().build());
            }

            @Override
            public void onVideoSizeChanged(androidx.media3.common.VideoSize size) { matchFrameRate(); }

            @Override
            public void onIsPlayingChanged(boolean isPlaying) {
                if (!isPlaying && started && !done) report("paused", false);
            }

            @Override
            public void onPlayWhenReadyChanged(boolean playWhenReady, int reason) {
                if (reason == Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST) tgSend(playWhenReady ? "play" : "pause");
            }

            @Override
            public void onPositionDiscontinuity(Player.PositionInfo a, Player.PositionInfo b, int reason) {
                if (reason == Player.DISCONTINUITY_REASON_SEEK) h.postDelayed(() -> tgSend("seek"), 300);
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
        if (!String.valueOf(o.get("ember-together")).isEmpty() && o.get("ember-together") != null) {
            tgRoom = "host".equals(o.get("ember-together")) ? null : o.get("ember-together");
            h.postDelayed(tgTick, 1000);
        }
        // not started after 25 s: let Ember try the next stream
        h.postDelayed(() -> { if (!started && !done) finishWith(EXIT_STALL); }, 25_000);
    }

    /** Asks Android to switch the TV to the film's frame rate, even if the switch isn't seamless (as Google TV's own apps do). */
    private void matchFrameRate() {
        if (android.os.Build.VERSION.SDK_INT < 31 || player == null) return;
        androidx.media3.common.Format f = player.getVideoFormat();
        View sv = view.getVideoSurfaceView();
        if (f == null || f.frameRate <= 0 || !(sv instanceof android.view.SurfaceView)) return;
        android.view.Surface s = ((android.view.SurfaceView) sv).getHolder().getSurface();
        if (s == null || !s.isValid()) return;
        try {
            s.setFrameRate(f.frameRate, android.view.Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE, android.view.Surface.CHANGE_FRAME_RATE_ALWAYS);
        } catch (Exception e) {
            Log.w(TAG, "frame rate: " + e);
        }
    }

    private long lastReport = 0;
    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            if (done) return;
            long now = System.currentTimeMillis();
            if (started && player.isPlaying() && now - lastReport > 15_000) report("playing", false);
            upNextTick();
            // stuck buffering for more than 12 s once it had started: this stream isn't keeping up
            if (bufferingSince > 0 && now - bufferingSince > 12_000) {
                report("stopped", false);
                finishWith(EXIT_STALL);
                return;
            }
            h.postDelayed(this, 1000);
        }
    };

    /** Where the credits roughly start. Streams don't say, so it's an estimate: the last 4% of the episode,
     *  at least 25 s and at most 100 s (about 50 s on a half-hour show, 100 s on an hour-long one). */
    private long creditsAt(long dur) {
        // guessing earlier cut the end off shows that run to the last seconds (Law & Order: SVU): the card now
        // appears for the last 20 s only, and the next episode starts when this one has actually finished
        return dur - 20_000;
    }

    private void upNextTick() {
        if (!hasNext || !started || player == null) return;
        long dur = player.getDuration(), pos = player.getCurrentPosition();
        if (dur == C.TIME_UNSET || dur < 5 * 60_000) return;
        boolean inCredits = pos >= creditsAt(dur);
        if (!inCredits) { // went back before the credits: start again
            if (upNextShown) hideUpNext();
            creditsWanted = false;
            return;
        }
        if (creditsWanted) return;
        if (!upNextShown) {
            upNextShown = true;
            countdown = COUNTDOWN_S;
            view.hideController();
            nextButton.setVisibility(View.GONE);
            upNext.setVisibility(View.VISIBLE);
            upNextPlay.requestFocus();
        }
        upNextText.setText("Next episode");
    }

    private View timeline() { return view.findViewById(androidx.media3.ui.R.id.exo_progress); }

    private void focusTimeline() {
        View tb = timeline();
        if (tb == null) return;
        tb.setEnabled(true);
        tb.setFocusable(true);
        tb.requestFocus();
    }

    private void hideUpNext() {
        upNextShown = false;
        upNext.setVisibility(View.GONE);
    }

    private Typeface subFont() {
        try { return Typeface.createFromAsset(getAssets(), "fonts/Selawik-Semibold.ttf"); }
        catch (Exception e) { return Typeface.create("sans-serif-medium", Typeface.NORMAL); }
    }

    /** A button that shows focus with a ring and a colour change, never by stretching. */
    private void style(TextView b, boolean primary) {
        b.setFocusable(true);
        b.setFocusableInTouchMode(false);
        final GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(dp(10));
        Runnable paint = () -> {
            boolean f = b.isFocused();
            if (primary) { bg.setColor(ACCENT); b.setTextColor(INK); }
            else { bg.setColor(f ? Color.WHITE : Color.argb(40, 255, 255, 255)); b.setTextColor(f ? INK : Color.WHITE); }
            bg.setStroke(dp(3), f ? Color.WHITE : Color.TRANSPARENT);
            b.setBackground(bg);
        };
        paint.run();
        b.setOnFocusChangeListener((v, f) -> paint.run());
    }

    private TextView pill(String text) {
        TextView b = new TextView(this);
        b.setText(text);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        b.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        b.setPadding(dp(18), dp(10), dp(18), dp(10));
        style(b, false);
        return b;
    }

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

    // ---------------------------------------------------------------- watch together
    // ember-together=host: start a room once the stream's playing; =CODE: join it. Pause / play / seek go to everyone
    // in the room through lucapi; the host says where it is every second, and anyone 2 s off jumps back in line.

    private String tgRoom;
    private boolean tgMade = false, tgBusy = false;
    private int tgSince = -2;   // -2: not said hello yet; -1: first look (don't replay what happened before)
    private long tgQuietUntil = 0, tgReadyAt = Long.MAX_VALUE;

    private JSONObject tgHttp(String path, JSONObject body) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(o.get("ember-feed") + path).openConnection();
        c.setConnectTimeout(3000);
        c.setReadTimeout(4000);
        if (body != null) {
            c.setRequestMethod("POST");
            c.setDoOutput(true);
            c.setRequestProperty("Content-Type", "application/json");
            try (OutputStream out = c.getOutputStream()) { out.write(body.toString().getBytes(StandardCharsets.UTF_8)); }
        }
        try (java.io.InputStream in = c.getInputStream()) {
            java.io.ByteArrayOutputStream b = new java.io.ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            for (int n; (n = in.read(buf)) > 0; ) b.write(buf, 0, n);
            return new JSONObject(b.toString("UTF-8"));
        } finally {
            c.disconnect();
        }
    }

    private JSONObject tgBody(String action) throws Exception {
        JSONObject b = new JSONObject();
        b.put("who", o.get("ember-who"));
        b.put("name", o.containsKey("ember-device") ? o.get("ember-device") : "Ember TV");
        b.put("action", action);
        b.put("pos", player == null ? 0 : player.getCurrentPosition() / 1000.0);
        return b;
    }

    private void tgSend(String action) {
        long now = System.currentTimeMillis();
        if (tgRoom == null || player == null || now < tgQuietUntil || now < tgReadyAt) return; // from the room, or start-up
        try {
            final JSONObject b = tgBody(action);
            final String room = tgRoom;
            new Thread(() -> { try { tgHttp("/together/" + room, b); } catch (Exception e) { Log.w(TAG, "together: " + e); } }).start();
        } catch (Exception ignored) { }
    }

    private void tgQuiet() { tgQuietUntil = System.currentTimeMillis() + 1500; }

    private void tgSay(String s) { android.widget.Toast.makeText(this, s, android.widget.Toast.LENGTH_SHORT).show(); }

    private void tgSeek(double secs) { tgQuiet(); player.seekTo(Math.max(0, (long) (secs * 1000))); }

    private final Runnable tgTick = new Runnable() {
        @Override
        public void run() {
            if (done || player == null) return;
            h.postDelayed(this, 1000);
            if (tgBusy) return;
            final double pos = player.getCurrentPosition() / 1000.0;
            final boolean paused = !player.getPlayWhenReady();
            if (tgRoom == null) {   // hosting: make the room once the stream's really playing
                if (tgMade || !started || pos < 1) return;
                tgMade = true;
                tgBusy = true;
                new Thread(() -> {
                    String code = null;
                    try {
                        JSONObject meta = new JSONObject();
                        meta.put("id", o.get("ember-imdb"));
                        meta.put("type", o.get("ember-type"));
                        meta.put("name", o.get("ember-show"));
                        if (o.get("ember-season") != null && !o.get("ember-season").isEmpty()) meta.put("season", Integer.parseInt(o.get("ember-season")));
                        if (o.get("ember-episode") != null && !o.get("ember-episode").isEmpty()) meta.put("episode", Integer.parseInt(o.get("ember-episode")));
                        JSONObject b = tgBody("start");
                        b.put("url", getIntent().getStringExtra("url"));
                        b.put("paused", paused);
                        b.put("meta", meta);
                        b.put("title", getIntent().getStringExtra("title"));
                        code = tgHttp("/together/start", b).optString("code", null);
                    } catch (Exception e) {
                        Log.w(TAG, "together start: " + e);
                    }
                    final String got = code;
                    h.post(() -> {
                        tgBusy = false;
                        if (got != null) { tgRoom = got; tgSay("Watching together: your other Ember devices are being asked to join"); }
                        else tgSay("Couldn't start watching together (lucapi didn't answer)");
                    });
                }).start();
                return;
            }
            final boolean hello = tgSince == -2;
            if (hello) tgSince = -1;
            final String room = tgRoom;
            final int since = Math.max(tgSince, 0);
            tgBusy = true;
            new Thread(() -> {
                JSONObject j = null;
                try {
                    if (hello) tgHttp("/together/" + room, tgBody("hello"));
                    j = tgHttp("/together/" + room + "?since=" + since + "&who=" + Uri.encode(o.get("ember-who")), null);
                } catch (Exception e) {
                    Log.w(TAG, "together: " + e);
                }
                final JSONObject r = j;
                h.post(() -> { tgBusy = false; if (hello) tgReadyAt = System.currentTimeMillis() + 3000; if (r != null) tgApply(r); });
            }).start();
        }
    };

    private void tgApply(JSONObject j) {
        if (done || player == null || j.optBoolean("gone")) return;
        int n = j.optInt("n");
        if (tgSince == -1) tgSince = n; // don't replay what happened before you joined
        else {
            tgSince = n;
            JSONArray evs = j.optJSONArray("events");
            for (int i = 0; evs != null && i < evs.length(); i++) {
                JSONObject ev = evs.optJSONObject(i);
                String a = ev.optString("action"), who = ev.optString("name");
                double p = ev.optDouble("pos", 0);
                boolean far = Math.abs(player.getCurrentPosition() / 1000.0 - p) > 2;
                tgQuiet();
                if ("pause".equals(a)) { if (far) tgSeek(p); player.setPlayWhenReady(false); tgSay("Paused by " + who); }
                else if ("play".equals(a)) { if (far) tgSeek(p); player.setPlayWhenReady(true); tgSay("Playing (" + who + ")"); }
                else if ("seek".equals(a)) { tgSeek(p); tgSay(who + " skipped"); }
                else if ("hello".equals(a)) tgSay(who + " joined");
                else if ("bye".equals(a)) tgSay(who + " left");
            }
        }
        long now = System.currentTimeMillis();
        boolean host = j.optBoolean("you_host");
        if (!host && now >= tgQuietUntil && started) {   // in step with the host
            boolean paused = j.optBoolean("paused");
            if (paused == player.getPlayWhenReady()) { tgQuiet(); player.setPlayWhenReady(!paused); }
            double expect = j.optDouble("expect", 0);
            if (Math.abs(player.getCurrentPosition() / 1000.0 - expect) > 2) tgSeek(expect + 0.3);
        }
        if (host && player.getPlayWhenReady()) tgSend("tick");
    }

    private void finishWith(int code) {
        if (done) return;
        if (tgRoom != null) {   // leaving the room
            try {
                final JSONObject b = tgBody("bye");
                final String room = tgRoom;
                new Thread(() -> { try { tgHttp("/together/" + room, b); } catch (Exception ignored) { } }).start();
            } catch (Exception ignored) { }
        }
        active = false;
        done = true;
        h.removeCallbacksAndMessages(null);
        setResult(code == 0 ? RESULT_CANCELED : code);
        finish();
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent e) {
        int k = e.getKeyCode();
        if (upNextShown) {
            boolean down = e.getAction() == KeyEvent.ACTION_DOWN;
            if (k == KeyEvent.KEYCODE_DPAD_LEFT || k == KeyEvent.KEYCODE_DPAD_RIGHT) {
                if (down) (k == KeyEvent.KEYCODE_DPAD_LEFT ? upNextPlay : upNextStay).requestFocus();
                return true;
            }
            if (k == KeyEvent.KEYCODE_DPAD_CENTER || k == KeyEvent.KEYCODE_ENTER || k == KeyEvent.KEYCODE_NUMPAD_ENTER) {
                if (!down) (upNextStay.isFocused() ? upNextStay : upNextPlay).performClick();
                return true;
            }
            if (k == KeyEvent.KEYCODE_BACK) { // Back: keep watching the credits
                if (!down) { creditsWanted = true; hideUpNext(); }
                return true;
            }
            if (k == KeyEvent.KEYCODE_DPAD_UP || k == KeyEvent.KEYCODE_DPAD_DOWN) return true;
        }
        // Controls up: the timeline is ours to drive. Left/right skip 10 s (30 s once held a while), OK plays/pauses,
        // down from the buttons above lands on it.
        View tl = timeline();
        if (view.isControllerFullyVisible() && tl != null) {
            boolean down = e.getAction() == KeyEvent.ACTION_DOWN;
            if (tl.isFocused()) {
                if (k == KeyEvent.KEYCODE_DPAD_LEFT || k == KeyEvent.KEYCODE_DPAD_RIGHT) {
                    if (down) {
                        long step = e.getRepeatCount() > 8 ? 30_000 : 10_000;
                        long to = player.getCurrentPosition() + (k == KeyEvent.KEYCODE_DPAD_RIGHT ? step : -step);
                        long dur = player.getDuration();
                        if (dur != C.TIME_UNSET && dur > 0) to = Math.min(to, dur - 1000);
                        player.seekTo(Math.max(0, to));
                        view.showController(); // keeps the controls up while skipping
                    }
                    return true;
                }
                if (k == KeyEvent.KEYCODE_DPAD_CENTER || k == KeyEvent.KEYCODE_ENTER || k == KeyEvent.KEYCODE_NUMPAD_ENTER) {
                    if (!down) { player.setPlayWhenReady(!player.getPlayWhenReady()); view.showController(); }
                    return true;
                }
            } else if (k == KeyEvent.KEYCODE_DPAD_DOWN && down) {
                View f = getCurrentFocus();
                int[] a = new int[2], b = new int[2];
                tl.getLocationOnScreen(b);
                if (f == null) { focusTimeline(); return true; }
                f.getLocationOnScreen(a);
                if (a[1] + f.getHeight() <= b[1] + 4) { focusTimeline(); view.showController(); return true; }
            }
        }
        if (k == KeyEvent.KEYCODE_BACK && e.getAction() == KeyEvent.ACTION_UP) {
            if (view.isControllerFullyVisible()) { view.hideController(); return true; }
            report("stopped", false);
            finishWith(0);
            return true;
        }
        if (k == KeyEvent.KEYCODE_BACK) return true;
        if (k == KeyEvent.KEYCODE_MEDIA_NEXT && hasNext && e.getAction() == KeyEvent.ACTION_UP) { report("stopped", true); finishWith(EXIT_NEXT); return true; }
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
        active = false;
        h.removeCallbacksAndMessages(null);
        if (player != null) {
            player.release();
            player = null;
        }
    }
}
