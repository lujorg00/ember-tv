package org.lucamedia.ember;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.StateListDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.InputType;
import android.util.TypedValue;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

/**
 * Ember settings. Values can also be pushed from a computer with adb, which beats typing URLs on a remote:
 *   adb shell am start -n org.lucamedia.ember/.SettingsActivity --es addon "https://.../manifest.json"
 */
public class SettingsActivity extends Activity {

    private static final int BG = 0xFF0E0B09;
    private static final int SURFACE = 0xFF1C1612;
    private static final int TEXT = 0xFFF3E7DA;
    private static final int MUTED = 0xFFA8968A;
    private static final int ACCENT = 0xFFF0A04B;

    private final Handler main = new Handler(Looper.getMainLooper());
    private Prefs prefs;
    private float density;
    private EditText addonField;
    private EditText openField;
    private EditText feedField;
    private TextView status;
    private TextView overrideState;
    private Button hiddenButton;
    private Button dimButton;
    private final android.content.SharedPreferences.OnSharedPreferenceChangeListener dimWatch =
            new android.content.SharedPreferences.OnSharedPreferenceChangeListener() {
                @Override
                public void onSharedPreferenceChanged(android.content.SharedPreferences sp, String key) {
                    if (key != null && key.startsWith("dim_")) refreshDim();
                }
            };

    private void refreshDim() {
        if (dimButton == null) return;
        if (!accessibilityOn(DimService.class)) {
            dimButton.setText("Dimmer is switched off in Accessibility settings");
        } else if (prefs.dimLearning()) {
            dimButton.setText("Now press the button you want as the dimmer\u2026");
        } else if (prefs.dimKey() == 0) {
            dimButton.setText("Set dimmer button");
        } else {
            dimButton.setText("Dimmer button: " + android.view.KeyEvent.keyCodeToString(prefs.dimKey())
                    .replace("KEYCODE_", "").toLowerCase(java.util.Locale.UK) + "  (press to change)");
        }
    }

    private boolean accessibilityOn(Class<?> svc) {
        String enabled = Settings.Secure.getString(getContentResolver(), Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
        if (enabled == null) return false;
        android.content.ComponentName me = new android.content.ComponentName(this, svc);
        for (String s : enabled.split(":")) if (me.equals(android.content.ComponentName.unflattenFromString(s))) return true;
        return false;
    }
    private TextView diag;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = new Prefs(this);
        density = getResources().getDisplayMetrics().density;
        applyExtras(getIntent());
        setContentView(build());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        applyExtras(intent);
        addonField.setText(prefs.addonUrl());
        openField.setText(prefs.openUri());
        feedField.setText(prefs.feedUrl());
    }

    @Override
    protected void onPause() {
        super.onPause();
        prefs.raw().unregisterOnSharedPreferenceChangeListener(dimWatch);
        if (prefs.dimLearning()) prefs.setDimLearning(false); // don't leave it waiting for a button
    }

    @Override
    protected void onResume() {
        super.onResume();
        prefs.raw().registerOnSharedPreferenceChangeListener(dimWatch);
        refreshDim();
        refreshState();
    }

    private void applyExtras(Intent i) {
        if (i == null) return;
        String a = i.getStringExtra("addon");
        String o = i.getStringExtra("open");
        String st = i.getStringExtra("feed");
        if (a != null && !a.trim().isEmpty()) prefs.setAddonUrl(a);
        if (o != null && !o.trim().isEmpty()) prefs.setOpenUri(o);
        if (st != null) prefs.setFeedUrl(st);
        if (a != null || o != null || st != null) Toast.makeText(this, "Ember settings updated", Toast.LENGTH_SHORT).show();
    }

    private View build() {
        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(BG);
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setPadding(dp(64), dp(36), dp(64), dp(48));
        scroll.addView(col);

        col.addView(text("Ember settings", 28, TEXT, true));

        col.addView(section("Your addon"));
        col.addView(text("Manifest URL of your Omni / Stremio addon. Every catalogue it lists becomes a home row.", 13, MUTED, false));
        addonField = field(prefs.addonUrl());
        col.addView(addonField);

        col.addView(section("When you pick a title, open"));
        col.addView(text("{type} and {id} are filled in. The default opens the title in Stremio.", 13, MUTED, false));
        openField = field(prefs.openUri());
        col.addView(openField);

        col.addView(section("lucapi feed"));
        col.addView(text("Address of ember-feed on lucapi, e.g. http://192.168.4.141:8090. Powers the screensaver (calendar, Pi status, photos) and the projects strip on the Apps page.", 13, MUTED, false));
        feedField = field(prefs.feedUrl());
        col.addView(feedField);

        LinearLayout buttons = new LinearLayout(this);
        buttons.setOrientation(LinearLayout.HORIZONTAL);
        buttons.addView(button("Save & reload", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                save();
            }
        }));
        buttons.addView(button("Test addon", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                test();
            }
        }));
        col.addView(buttons);

        status = text("", 13, ACCENT, false);
        col.addView(status);

        col.addView(section("Screensaver"));
        col.addView(text("Your photos, calendar and lucapi status when the TV is idle. To make it the TV's screensaver (and start after 1 minute), run the commands in the README from your PC.", 13, MUTED, false));
        col.addView(button("Preview screensaver", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                prefs.setFeedUrl(feedField.getText().toString());
                startActivity(new Intent(SettingsActivity.this, ScreensaverPreviewActivity.class));
            }
        }));

        col.addView(section("Moving backgrounds"));
        col.addView(text("The clouds, firelight, stars and snow. Switch off for a still picture if the Chromecast feels slow.", 13, MUTED, false));
        final Button motionButton = button(prefs.motion() ? "On" : "Off", null);
        motionButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                prefs.setMotion(!prefs.motion());
                motionButton.setText(prefs.motion() ? "On" : "Off");
            }
        });
        col.addView(motionButton);

        col.addView(section("Dimmer"));
        col.addView(text("One remote button dims the whole picture: Off, Dim (50%), Heavy (80%). It goes to Dim by itself at 11:30pm, Heavy at midnight, and lifts at 8am. Press Set, then press the button you want (the Netflix button).", 13, MUTED, false));
        dimButton = button("", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                prefs.setDimLearning(true);
                refreshDim();
            }
        });
        col.addView(dimButton);
        refreshDim();

        col.addView(section("Home button"));
        col.addView(text("Google TV doesn't let other apps be the home screen. Switch on \"Ember home button\" under Accessibility and Ember will replace the Google TV home screen whenever it appears.", 13, MUTED, false));
        overrideState = text("", 14, TEXT, true);
        col.addView(overrideState);
        col.addView(button("Open Accessibility settings", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                try {
                    startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS));
                } catch (ActivityNotFoundException e) {
                    startActivity(new Intent(Settings.ACTION_SETTINGS));
                }
            }
        }));

        col.addView(section("Hidden apps"));
        hiddenButton = button("", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                prefs.clearHiddenApps();
                refreshState();
                Toast.makeText(SettingsActivity.this, "All apps are back on the home screen", Toast.LENGTH_SHORT).show();
            }
        });
        col.addView(hiddenButton);

        col.addView(section("Diagnostics"));
        diag = text("", 12, MUTED, false);
        col.addView(diag);
        return scroll;
    }

    private void refreshState() {
        boolean on = HomeOverrideService.isEnabled(this);
        overrideState.setText(on ? "●  On — Home goes to Ember" : "○  Off — Home goes to Google TV");
        overrideState.setTextColor(on ? ACCENT : MUTED);
        int hidden = prefs.hiddenApps().size();
        hiddenButton.setText(hidden == 0 ? "No hidden apps" : "Show " + hidden + " hidden app" + (hidden == 1 ? "" : "s"));
        hiddenButton.setEnabled(hidden > 0);
        diag.setText("Last Google TV screen seen: " + prefs.lastStockWindow());
    }

    private void save() {
        prefs.setAddonUrl(addonField.getText().toString());
        prefs.setOpenUri(openField.getText().toString());
        prefs.setFeedUrl(feedField.getText().toString());
        // Force a refetch next time home opens.
        new java.io.File(getFilesDir(), "catalogues.json").setLastModified(0);
        status.setText("Saved. Going home to reload…");
        main.postDelayed(new Runnable() {
            @Override
            public void run() {
                Intent i = new Intent(SettingsActivity.this, HomeActivity.class);
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
                startActivity(i);
                finish();
            }
        }, 600);
    }

    private void test() {
        final String url = addonField.getText().toString();
        status.setText("Testing…");
        new Thread(new Runnable() {
            @Override
            public void run() {
                String msg;
                try {
                    int n = new AddonClient(SettingsActivity.this).test(url);
                    msg = "✓  Addon reachable — " + n + " catalogue" + (n == 1 ? "" : "s") + " listed";
                } catch (Exception e) {
                    msg = "✗  " + (e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage());
                }
                final String m = msg;
                main.post(new Runnable() {
                    @Override
                    public void run() {
                        status.setText(m);
                    }
                });
            }
        }).start();
    }

    // ---------------------------------------------------------------- helpers

    private TextView section(String s) {
        TextView t = text(s, 16, ACCENT, true);
        t.setPadding(0, dp(24), 0, dp(4));
        return t;
    }

    private TextView text(String s, float sp, int color, boolean medium) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(color);
        t.setTypeface(Typeface.create(medium ? "sans-serif-medium" : "sans-serif", Typeface.NORMAL));
        t.setPadding(0, dp(2), 0, dp(2));
        return t;
    }

    private EditText field(String value) {
        EditText e = new EditText(this);
        e.setText(value);
        e.setSingleLine(true);
        e.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        e.setTextColor(TEXT);
        e.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        e.setPadding(dp(12), dp(10), dp(12), dp(10));
        e.setBackground(focusBg());
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(6);
        e.setLayoutParams(lp);
        return e;
    }

    private Button button(String label, View.OnClickListener l) {
        Button b = new Button(this);
        b.setText(label);
        b.setAllCaps(false);
        b.setTextColor(TEXT);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        b.setBackground(focusBg());
        b.setPadding(dp(18), dp(8), dp(18), dp(8));
        b.setOnClickListener(l);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(12);
        lp.rightMargin = dp(12);
        b.setLayoutParams(lp);
        return b;
    }

    private StateListDrawable focusBg() {
        GradientDrawable normal = new GradientDrawable();
        normal.setColor(SURFACE);
        normal.setCornerRadius(dp(8));
        GradientDrawable focused = new GradientDrawable();
        focused.setColor(SURFACE);
        focused.setCornerRadius(dp(8));
        focused.setStroke(dp(2), ACCENT);
        StateListDrawable s = new StateListDrawable();
        s.addState(new int[]{android.R.attr.state_focused}, focused);
        s.addState(new int[]{}, normal);
        return s;
    }

    private int dp(float v) {
        return Math.round(v * density);
    }
}
