package org.lucamedia.ember;

import org.json.JSONObject;

import java.util.Calendar;
import java.util.Locale;

/** Turns ember-feed's /weather into short lines for the clock and the screensaver. */
final class Weather {
    private Weather() {
    }

    /** "11° Light rain", or "" if there's no weather yet. */
    static String brief(JSONObject w) {
        if (w == null || !w.has("tempC")) return "";
        String t = w.optString("text", "");
        return w.optInt("tempC") + "°" + (t.isEmpty() ? "" : " " + t);
    }

    /** "11° Light rain · High 13° · Sunrise 07:42 · Sunset 16:40" (sun times work even without weather). */
    static String full(JSONObject w, android.content.Context ctx) {
        StringBuilder sb = new StringBuilder(brief(w));
        if (w != null && w.has("highC")) sb.append(" · High ").append(w.optInt("highC")).append('°');
        if (w != null && !w.isNull("rainChance") && w.optInt("rainChance", 0) >= 30) {
            sb.append(" · ").append(w.optInt("rainChance")).append("% rain");
        }
        String rise = w == null ? "" : w.optString("sunrise", "");
        String set = w == null ? "" : w.optString("sunset", "");
        if (rise.isEmpty() || set.isEmpty()) {
            double lat = Double.parseDouble(ctx.getString(R.string.sun_latitude));
            double lon = Double.parseDouble(ctx.getString(R.string.sun_longitude));
            double[] rs = SunClock.riseSetLocalMinutes(Calendar.getInstance(), lat, lon);
            rise = hm(rs[0]);
            set = hm(rs[1]);
        }
        if (sb.length() > 0) sb.append(" · ");
        sb.append("Sunrise ").append(rise).append(" · Sunset ").append(set);
        return sb.toString();
    }

    private static String hm(double mins) {
        int m = (int) Math.round(mins);
        return String.format(Locale.UK, "%02d:%02d", (m / 60) % 24, m % 60);
    }

}
