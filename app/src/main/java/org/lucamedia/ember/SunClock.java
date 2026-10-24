package org.lucamedia.ember;

import java.util.Calendar;
import java.util.TimeZone;

/**
 * Sunrise, sunset and moon phase worked out on the device (no internet), for Ember's
 * day / evening / night looks on the Apps page.
 */
final class SunClock {

    enum Mode { DAY, EVENING, NIGHT }

    /** Evening starts this long before sunset... */
    static final int EVENING_BEFORE_SUNSET_MIN = 75;
    /** ...and night this long after it. Day starts this long after sunrise. */
    static final int NIGHT_AFTER_SUNSET_MIN = 45;
    static final int DAY_AFTER_SUNRISE_MIN = 20;

    private SunClock() {
    }

    static Mode modeAt(Calendar now, double lat, double lon) {
        int m = now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE);
        double[] rs = riseSetLocalMinutes(now, lat, lon);
        if (Double.isNaN(rs[0]) || Double.isNaN(rs[1])) {
            // Polar edge cases don't happen in Salford, but fall back to the clock just in case.
            return m >= 7 * 60 && m < 17 * 60 ? Mode.DAY : m < 21 * 60 && m >= 17 * 60 ? Mode.EVENING : Mode.NIGHT;
        }
        double rise = rs[0], set = rs[1];
        if (m >= rise + DAY_AFTER_SUNRISE_MIN && m < set - EVENING_BEFORE_SUNSET_MIN) return Mode.DAY;
        if (m >= set - EVENING_BEFORE_SUNSET_MIN && m < set + NIGHT_AFTER_SUNSET_MIN) return Mode.EVENING;
        return Mode.NIGHT;
    }

    /** {sunrise, sunset} in local minutes after midnight for the given day. */
    static double[] riseSetLocalMinutes(Calendar day, double lat, double lon) {
        int n = day.get(Calendar.DAY_OF_YEAR);
        TimeZone tz = day.getTimeZone();
        double offsetMin = tz.getOffset(day.getTimeInMillis()) / 60000.0;
        double rise = utcHours(n, lat, lon, true);
        double set = utcHours(n, lat, lon, false);
        return new double[]{
                Double.isNaN(rise) ? Double.NaN : norm(rise * 60 + offsetMin, 1440),
                Double.isNaN(set) ? Double.NaN : norm(set * 60 + offsetMin, 1440)};
    }

    /** Standard sunrise equation (as used by NOAA's almanac); accurate to a minute or two. */
    private static double utcHours(int n, double lat, double lng, boolean rising) {
        double zenith = 90.833;
        double lngHour = lng / 15.0;
        double t = n + ((rising ? 6 : 18) - lngHour) / 24.0;
        double mAnom = 0.9856 * t - 3.289;
        double l = norm(mAnom + 1.916 * sin(mAnom) + 0.020 * sin(2 * mAnom) + 282.634, 360);
        double ra = norm(Math.toDegrees(Math.atan(0.91764 * Math.tan(Math.toRadians(l)))), 360);
        ra = (ra + (Math.floor(l / 90) * 90 - Math.floor(ra / 90) * 90)) / 15.0;
        double sinDec = 0.39782 * sin(l);
        double cosDec = Math.cos(Math.asin(sinDec));
        double cosH = (Math.cos(Math.toRadians(zenith)) - sinDec * sin(lat)) / (cosDec * Math.cos(Math.toRadians(lat)));
        if (cosH > 1 || cosH < -1) return Double.NaN;
        double h = rising ? 360 - Math.toDegrees(Math.acos(cosH)) : Math.toDegrees(Math.acos(cosH));
        h /= 15.0;
        double tLocal = h + ra - 0.06571 * t - 6.622;
        return norm(tLocal - lngHour, 24);
    }

    /** Moon age in days since new moon (0 to ~29.53). */
    static double moonAgeDays(long nowMillis) {
        final double synodic = 29.530588853;
        final long knownNewMoon = 947182440000L; // 6 Jan 2000 18:14 UTC
        double days = (nowMillis - knownNewMoon) / 86400000.0;
        return norm(days, synodic);
    }

    private static double sin(double deg) {
        return Math.sin(Math.toRadians(deg));
    }

    private static double norm(double v, double range) {
        v = v % range;
        return v < 0 ? v + range : v;
    }
}
