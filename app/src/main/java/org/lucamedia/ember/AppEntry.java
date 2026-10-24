package org.lucamedia.ember;

import android.content.Context;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.drawable.Drawable;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** An installed app shown in the Apps row. */
final class AppEntry {
    final String pkg;
    final String label;
    final Drawable banner; // TV banner (16:9), may be null
    final Drawable icon;

    private AppEntry(String pkg, String label, Drawable banner, Drawable icon) {
        this.pkg = pkg;
        this.label = label;
        this.banner = banner;
        this.icon = icon;
    }

    /** All launchable apps except hidden ones and Ember itself, most-used first. Call off the main thread. */
    static List<AppEntry> load(Context ctx, final Prefs prefs) {
        PackageManager pm = ctx.getPackageManager();
        Set<String> hidden = prefs.hiddenApps();
        Map<String, ResolveInfo> byPkg = new LinkedHashMap<>();

        for (String category : new String[]{Intent.CATEGORY_LEANBACK_LAUNCHER, Intent.CATEGORY_LAUNCHER}) {
            Intent i = new Intent(Intent.ACTION_MAIN).addCategory(category);
            for (ResolveInfo ri : pm.queryIntentActivities(i, 0)) {
                String p = ri.activityInfo.packageName;
                if (p.equals(ctx.getPackageName()) || hidden.contains(p) || byPkg.containsKey(p)) continue;
                byPkg.put(p, ri);
            }
        }

        List<AppEntry> out = new ArrayList<>();
        for (ResolveInfo ri : byPkg.values()) {
            ActivityInfo ai = ri.activityInfo;
            Drawable banner = ai.loadBanner(pm);
            if (banner == null) banner = ai.applicationInfo.loadBanner(pm);
            out.add(new AppEntry(ai.packageName, String.valueOf(ri.loadLabel(pm)), banner, ri.loadIcon(pm)));
        }

        Collections.sort(out, new Comparator<AppEntry>() {
            @Override
            public int compare(AppEntry a, AppEntry b) {
                int c = Integer.compare(prefs.launchCount(b.pkg), prefs.launchCount(a.pkg));
                return c != 0 ? c : a.label.compareToIgnoreCase(b.label);
            }
        });
        return out;
    }

    Intent launchIntent(Context ctx) {
        PackageManager pm = ctx.getPackageManager();
        Intent i = pm.getLeanbackLaunchIntentForPackage(pkg);
        if (i == null) i = pm.getLaunchIntentForPackage(pkg);
        if (i != null) i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        return i;
    }
}
