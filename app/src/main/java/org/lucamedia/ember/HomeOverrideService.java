package org.lucamedia.ember;

import android.accessibilityservice.AccessibilityService;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.os.SystemClock;
import android.provider.Settings;
import android.text.TextUtils;
import android.view.accessibility.AccessibilityEvent;

import java.util.HashSet;
import java.util.Set;

/**
 * Google TV won't let a third-party app be the default home screen, so this does what Projectivy does:
 * when the stock launcher's home activity comes to the front (Home button, waking the TV), Ember is
 * brought to the front instead. Only the stock launcher's actual home activity is matched, so its
 * side panels (notifications, quick settings) still work.
 */
public class HomeOverrideService extends AccessibilityService {

    /** Known stock launchers: Google TV, older Android TV, and the original Leanback launcher. */
    private static final String[] STOCK = {
            "com.google.android.apps.tv.launcherx",
            "com.google.android.tvlauncher",
            "com.google.android.leanbacklauncher",
    };

    private final Set<String> stockHomeClasses = new HashSet<>();
    private long lastSwap;
    private Prefs prefs;

    @Override
    protected void onServiceConnected() {
        super.onServiceConnected();
        prefs = new Prefs(this);
        stockHomeClasses.clear();
        PackageManager pm = getPackageManager();
        Intent home = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME);
        for (ResolveInfo ri : pm.queryIntentActivities(home, 0)) {
            String p = ri.activityInfo.packageName;
            if (p.equals(getPackageName())) continue;
            stockHomeClasses.add(ri.activityInfo.name);
            // Launchers often register HOME on an activity-alias; the event reports the real class.
            if (ri.activityInfo.targetActivity != null) stockHomeClasses.add(ri.activityInfo.targetActivity);
        }
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        if (event == null || event.getEventType() != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return;
        CharSequence pkgCs = event.getPackageName();
        CharSequence clsCs = event.getClassName();
        if (pkgCs == null || clsCs == null) return;
        String pkg = pkgCs.toString();
        String cls = clsCs.toString();
        if (!isStock(pkg)) return;

        prefs.setLastStockWindow(pkg + "/" + cls);
        boolean isHome = stockHomeClasses.contains(cls)
                || cls.endsWith(".HomeActivity") || cls.endsWith(".MainActivity");
        if (!isHome) return; // a panel or dialog, not the home screen

        long now = SystemClock.elapsedRealtime();
        if (now - lastSwap < 700) return;
        lastSwap = now;

        Intent i = new Intent(this, HomeActivity.class);
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
        startActivity(i);
    }

    private static boolean isStock(String pkg) {
        for (String s : STOCK) if (s.equals(pkg)) return true;
        return false;
    }

    @Override
    public void onInterrupt() {
        // Nothing to clean up.
    }

    /** True if the user has switched this service on in Accessibility settings. */
    static boolean isEnabled(Context ctx) {
        String enabled = Settings.Secure.getString(ctx.getContentResolver(),
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
        if (TextUtils.isEmpty(enabled)) return false;
        ComponentName me = new ComponentName(ctx, HomeOverrideService.class);
        for (String s : enabled.split(":")) {
            ComponentName c = ComponentName.unflattenFromString(s);
            if (me.equals(c)) return true;
        }
        return false;
    }
}
