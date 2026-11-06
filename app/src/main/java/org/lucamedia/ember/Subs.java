package org.lucamedia.ember;

/** Subtitles in ALL CAPS (common on TV captions) read far better in sentence case, as on Netflix. */
final class Subs {
    private Subs() {}

    static String sentenceCase(String s) {
        int letters = 0, upper = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (Character.isLetter(c)) { letters++; if (Character.isUpperCase(c)) upper++; }
        }
        if (letters < 4 || upper < letters * 0.8) return s;
        String low = s.toLowerCase();
        StringBuilder out = new StringBuilder(low.length());
        boolean capNext = true;
        for (int i = 0; i < low.length(); i++) {
            char c = low.charAt(i);
            if (capNext && Character.isLetter(c)) { out.append(Character.toUpperCase(c)); capNext = false; continue; }
            out.append(c);
            if (c == '.' || c == '!' || c == '?' || c == '\n') capNext = true;
            else if (capNext && (c == '[' || c == '(')) capNext = false;   // [door slams] stays lower case
        }
        // "i", "i'm", "i'll" on their own are always capitals
        return out.toString().replaceAll("(?<![\\p{L}'’])i(?=$|[^\\p{L}])", "I");
    }
}
