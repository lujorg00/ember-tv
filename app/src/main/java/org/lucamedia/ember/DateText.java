package org.lucamedia.ember;

import android.text.SpannableStringBuilder;
import android.text.Spanned;
import android.text.style.RelativeSizeSpan;
import android.text.style.SuperscriptSpan;

import java.text.SimpleDateFormat;
import java.util.Calendar;
import java.util.Locale;

/** "Saturday 24th October", with the "th" small and raised. */
final class DateText {
    private DateText() {
    }

    static CharSequence of(Calendar c) {
        int day = c.get(Calendar.DAY_OF_MONTH);
        SpannableStringBuilder sb = new SpannableStringBuilder();
        sb.append(new SimpleDateFormat("EEEE", Locale.UK).format(c.getTime())).append(' ').append(String.valueOf(day));
        int start = sb.length();
        sb.append(suffix(day));
        sb.setSpan(new SuperscriptSpan(), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        sb.setSpan(new RelativeSizeSpan(0.62f), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        sb.append(' ').append(new SimpleDateFormat("MMMM", Locale.UK).format(c.getTime()));
        return sb;
    }

    static String suffix(int day) {
        if (day >= 11 && day <= 13) return "th";
        switch (day % 10) {
            case 1: return "st";
            case 2: return "nd";
            case 3: return "rd";
            default: return "th";
        }
    }
}
