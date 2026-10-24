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

    static Meta from(JSONObject o, String fallbackType) {
        String id = o.optString("id", "");
        String type = o.optString("type", fallbackType);
        String poster = o.optString("poster", "");
        if (poster.isEmpty() && id.startsWith("tt")) {
            poster = "https://images.metahub.space/poster/medium/" + id + "/img";
        }
        String bg = o.optString("background", "");
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
        return new Meta(id, type, o.optString("name", ""), poster, bg,
                o.optString("description", ""), o.optString("releaseInfo", ""),
                o.optString("imdbRating", ""), genres);
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
