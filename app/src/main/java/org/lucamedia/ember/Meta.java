package org.lucamedia.ember;

import org.json.JSONArray;
import org.json.JSONObject;

/** One title from a Stremio catalogue. */
final class Meta {
    final String id;
    final String type;
    final String name;
    final String poster;
    final String background;
    final String description;
    final String releaseInfo;
    final String rating;
    final String genres;

    private Meta(String id, String type, String name, String poster, String background,
                 String description, String releaseInfo, String rating, String genres) {
        this.id = id;
        this.type = type;
        this.name = name;
        this.poster = poster;
        this.background = background;
        this.description = description;
        this.releaseInfo = releaseInfo;
        this.rating = rating;
        this.genres = genres;
    }

    /** Like optString, but a JSON null counts as missing (Android's optString turns it into the text "null"). */
    static String str(JSONObject o, String k, String fallback) {
        if (o.isNull(k)) return fallback;
        String v = o.optString(k, fallback).trim();
        return v.isEmpty() || v.equals("null") ? fallback : v;
    }

    /** An image address, or "" if the addon gave none (or something that isn't a web link). */
    private static String img(JSONObject o, String k) {
        String v = str(o, k, "");
        if (v.startsWith("//")) v = "https:" + v;
        return v.startsWith("http") ? v : "";
    }

    static Meta from(JSONObject o, String fallbackType) {
        String id = str(o, "id", "");
        String type = str(o, "type", fallbackType);
        String poster = img(o, "poster");
        if (poster.isEmpty() && id.startsWith("tt")) {
            poster = "https://images.metahub.space/poster/medium/" + id + "/img";
        }
        String bg = img(o, "background");
        if (bg.isEmpty() && id.startsWith("tt")) {
            bg = "https://images.metahub.space/background/medium/" + id + "/img";
        }
        if (bg.isEmpty()) bg = poster;

        String genres = "";
        JSONArray g = o.optJSONArray("genres");
        if (g != null) {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < g.length() && i < 3; i++) {
                if (sb.length() > 0) sb.append(", ");
                sb.append(g.optString(i));
            }
            genres = sb.toString();
        }
        return new Meta(id, type, str(o, "name", ""), poster, bg,
                str(o, "description", ""), str(o, "releaseInfo", ""),
                str(o, "imdbRating", ""), genres);
    }

    /** "2025 · ★ 7.8 · Drama, Thriller" */
    String subtitle() {
        StringBuilder sb = new StringBuilder();
        if (!releaseInfo.isEmpty()) sb.append(releaseInfo);
        if (!rating.isEmpty()) {
            if (sb.length() > 0) sb.append("  ·  ");
            sb.append("★ ").append(rating);
        }
        if (!genres.isEmpty()) {
            if (sb.length() > 0) sb.append("  ·  ");
            sb.append(genres);
        }
        if (sb.length() == 0) sb.append("series".equals(type) ? "Series" : "Film");
        return sb.toString();
    }
}
