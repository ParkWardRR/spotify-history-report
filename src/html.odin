package spotify_report

import "core:os"
import "core:fmt"
import "core:strings"

TEMPLATE :: string(#load("../template/report.html"))
DATA_MARKER :: "/*DATA_PLACEHOLDER*/{}"

// Escapes `s` for use inside a JSON string that is embedded in an HTML
// <script>. Beyond JSON's own rules (quote, backslash, every control character)
// it also writes `<`, `>`, `&` and the line separators U+2028/2029 as \u escapes,
// so no imported text can close the script element or start a comment in it.
json_html_safe :: proc(s: string) -> string {
	b := strings.builder_make()
	for c in s {
		switch c {
		case '"':  strings.write_string(&b, "\\\"")
		case '\\': strings.write_string(&b, "\\\\")
		case '\n': strings.write_string(&b, "\\n")
		case '\r': strings.write_string(&b, "\\r")
		case '\t': strings.write_string(&b, "\\t")
		case 0 ..< 0x20, '<', '>', '&', 0x7f, 0x2028, 0x2029:
			strings.write_string(&b, fmt.tprintf("\\u%04x", int(c)))
		case: strings.write_rune(&b, c)
		}
	}
	return strings.to_string(b)
}

// The DATA blob embedded in the report, as JSON text.
report_json :: proc(s: Stats) -> string {
	j := strings.builder_make()

	w :: strings.write_string
	wf :: proc(b: ^strings.Builder, f: string, args: ..any) {
		strings.write_string(b, fmt.aprintf(f, ..args))
	}

	esc :: json_html_safe

	w(&j, "{")
	wf(&j, "\"total_plays\":%d,", s.total_plays)
	// NOTE: In format strings below, {{ and }} produce literal { and }
	// because Odin's fmt treats { as a format specifier opener.
	wf(&j, "\"total_hours\":%d,", s.total_hours)
	wf(&j, "\"unique_artists\":%d,", s.unique_artists)
	wf(&j, "\"unique_tracks\":%d,", s.unique_tracks)
	wf(&j, "\"n_years\":%d,", s.n_years)
	wf(&j, "\"date_range_start\":\"%s\",", esc(s.date_range_start))
	wf(&j, "\"date_range_end\":\"%s\",", esc(s.date_range_end))
	wf(&j, "\"longest_streak\":%d,", s.longest_streak)
	wf(&j, "\"peak_hour\":%d,", s.peak_hour)
	wf(&j, "\"peak_hour_val\":%d,", s.peak_hour_val)
	wf(&j, "\"peak_day\":\"%s\",", esc(s.peak_day))
	wf(&j, "\"loyal_count\":%d,", s.loyal_count)
	wf(&j, "\"peak_day_hours\":%d,", s.peak_day_hours)
	wf(&j, "\"genre_subtitle\":\"Quarterly share of listening time by genre.\",")
	wf(&j, "\"heatmap_title\":\"When I listen\",")
	wf(&j, "\"genre_classified\":%d,", s.genre_classified)
	wf(&j, "\"genre_unclassified_pct\":%.1f,", s.genre_unclassified_pct)
	wf(&j, "\"genre_user_targets\":%d,", s.genre_user_targets)
	w(&j, "\"genre_source_pct\":{")
	for src in Annotation_Source {
		if src != min(Annotation_Source) do w(&j, ",")
		wf(&j, "\"%s\":%.1f", source_name(src), s.genre_source_pct[src])
	}
	w(&j, "},")

	// Skip rate
	// Explicit skips are null for a year where Spotify left the flag out.
	pct_or_null :: proc(b: ^strings.Builder, key: string, v: int) {
		if v < 0 { strings.write_string(b, fmt.tprintf("\"%s\":null,", key)) } else { strings.write_string(b, fmt.tprintf("\"%s\":%d,", key, v)) }
	}
	pct_or_null(&j, "skip_rate_first", s.skip_rate_first)
	pct_or_null(&j, "skip_rate_last", s.skip_rate_last)
	wf(&j, "\"short_rate_first\":%d,", s.short_rate_first)
	wf(&j, "\"short_rate_last\":%d,", s.short_rate_last)
	wf(&j, "\"skip_flag_coverage\":%d,", s.skip_flag_coverage)
	wf(&j, "\"skip_rate_first_yr\":%d,", s.skip_rate_first_yr)
	wf(&j, "\"skip_rate_last_yr\":%d,", s.skip_rate_last_yr)

	// Avg track length
	wf(&j, "\"avg_len_first\":%.1f,", s.avg_len_first)
	wf(&j, "\"avg_len_last\":%.1f,", s.avg_len_last)
	wf(&j, "\"avg_len_first_yr\":%d,", s.avg_len_first_yr)
	wf(&j, "\"avg_len_last_yr\":%d,", s.avg_len_last_yr)

	// Concentration
	wf(&j, "\"concentration_top10\":%.1f,", s.concentration_top10)
	wf(&j, "\"songs_for_half\":%d,", s.songs_for_half)

	// Worst earworm
	wf(&j, "\"earworm_total\":%d,", s.earworm_total)
	if len(s.worst_earworm.track) > 0 {
		wf(&j, "\"worst_earworm\":{{\"track\":\"%s\",\"artist\":\"%s\",\"plays\":%d,\"period\":\"%s\"}},",
			esc(s.worst_earworm.track), esc(s.worst_earworm.artist), s.worst_earworm.plays, esc(s.worst_earworm.period))
	}

	if s.last_year_partial {
		wf(&j, "\"hours_subtitle\":\"%d is a partial year.\",", s.last_year)
	} else {
		w(&j, "\"hours_subtitle\":\"\",")
	}
	wf(&j, "\"timezone\":\"%s\",", esc(s.timezone))
	w(&j, "\"identity\":")
	summary_json(&j, s.identity)
	w(&j, ",")
	i := s.import_summary
	wf(&j, "\"largest_gap\":{{\"days\":%d,\"from\":\"%s\",\"to\":\"%s\"}},", s.largest_gap.days, esc(s.largest_gap.from), esc(s.largest_gap.to))
	wf(&j, "\"import\":{{\"source\":\"%s\",\"files_used\":%d,\"files_ignored\":%d,\"files_identical\":%d,\"records\":%d,\"non_music\":%d,\"malformed\":%d,\"overlap_dropped\":%d,\"music_events\":%d,\"short_listens\":%d,\"plays\":%d}},",
		esc(i.source), i.files_used, i.files_ignored, i.files_identical, i.records, i.non_music, i.malformed, i.overlap_dropped, i.music_events, i.short_listens, i.plays)

	// Listening-behaviour views, each with its own plain-English definition.
	score_list :: proc(j: ^strings.Builder, name, why: string, list: []Track_Score, esc: proc(string) -> string) {
		strings.write_string(j, fmt.aprintf("\"%s\":{{\"why\":\"%s\",\"items\":[", name, esc(why)))
		for t, i in list {
			if i > 0 do strings.write_string(j, ",")
			strings.write_string(j, fmt.aprintf(
				"{{\"track\":\"%s\",\"artist\":\"%s\",\"plays\":%d,\"months\":%d,\"recent\":%d,\"silent_days\":%d,\"activation\":%.2f,\"opener_rate\":%.3f,\"closer_rate\":%.3f}}",
				esc(t.track), esc(t.artist), t.plays, t.months_active, t.recent_plays, t.days_since_last,
				t.activation, t.opener_rate, t.closer_rate))
		}
		strings.write_string(j, "]}")
	}
	wf(&j, "\"scores\":{{\"ref_date\":\"%s\",\"decay\":%.2f,\"hot_days\":%d,", esc(s.scores.ref_date), s.scores.decay, HOT_WINDOW_DAYS)
	score_list(&j, "favourites", why_favourites(), s.scores.favourites[:], esc); w(&j, ",")
	score_list(&j, "obsessions", why_obsessions(), s.scores.obsessions[:], esc); w(&j, ",")
	score_list(&j, "rediscoveries", why_rediscoveries(), s.scores.rediscoveries[:], esc); w(&j, ",")
	score_list(&j, "warm", why_warm(), s.scores.warm[:], esc); w(&j, ",")
	score_list(&j, "openers", why_openers(), s.scores.openers[:], esc)
	w(&j, "},")

	// Most played song
	wf(&j, "\"most_played_song\":{{\"track\":\"%s\",\"artist\":\"%s\",\"plays\":%d}},",
		esc(s.most_played_song.track), esc(s.most_played_song.artist), s.most_played_song.plays)

	// Biggest day
	wf(&j, "\"biggest_day\":{{\"date\":\"%s\",\"plays\":%d,\"hours\":%.1f}},",
		esc(s.biggest_day.date), s.biggest_day.plays, s.biggest_day.hours)

	// Hours by year
	w(&j, "\"hours_by_year\":[")
	for &yh, i in s.hours_by_year {
		if i > 0 do w(&j, ",")
		wf(&j, "{{\"year\":%d,\"hours\":%.1f}}", yh.year, yh.hours)
	}
	w(&j, "],")

	// Top artists
	w(&j, "\"top_artists\":[")
	for &a, i in s.top_artists {
		if i > 0 do w(&j, ",")
		wf(&j, "{{\"name\":\"%s\",\"hours\":%.1f}}", esc(a.name), a.hours)
	}
	w(&j, "],")

	// Top albums
	w(&j, "\"top_albums\":[")
	for &a, i in s.top_albums {
		if i > 0 do w(&j, ",")
		wf(&j, "{{\"album\":\"%s\",\"artist\":\"%s\",\"hours\":%.1f}}", esc(a.album), esc(a.artist), a.hours)
	}
	w(&j, "],")

	// Session openers
	w(&j, "\"session_openers\":[")
	for &o, i in s.session_openers {
		if i > 0 do w(&j, ",")
		wf(&j, "{{\"track\":\"%s\",\"artist\":\"%s\",\"count\":%d}}", esc(o.track), esc(o.artist), o.count)
	}
	w(&j, "],")

	// Never skipped
	w(&j, "\"never_skipped\":[")
	for &ns, i in s.never_skipped {
		if i > 0 do w(&j, ",")
		wf(&j, "{{\"track\":\"%s\",\"artist\":\"%s\",\"plays\":%d}}", esc(ns.track), esc(ns.artist), ns.plays)
	}
	w(&j, "],")

	// Earworms
	w(&j, "\"earworms\":[")
	for &e, i in s.earworms {
		if i > 0 do w(&j, ",")
		wf(&j, "{{\"track\":\"%s\",\"artist\":\"%s\",\"plays\":%d,\"period\":\"%s\"}}", esc(e.track), esc(e.artist), e.plays, esc(e.period))
	}
	w(&j, "],")

	// Loyalists
	w(&j, "\"loyalists\":[")
	for &l, i in s.loyalists {
		if i > 0 do w(&j, ",")
		wf(&j, "{{\"name\":\"%s\",\"hours\":%.1f}}", esc(l.name), l.hours)
	}
	w(&j, "],")

	// Explore/obsess
	w(&j, "\"explore_obsess\":[")
	for &e, i in s.explore_obsess {
		if i > 0 do w(&j, ",")
		wf(&j, "{{\"year\":%d,\"new_pct\":%d,\"top10_pct\":%d,\"rest_pct\":%d,\"new_count\":%d,\"total_artists\":%d}}",
			e.year, e.new_pct, e.top10_pct, e.rest_pct, e.new_count, e.total_artists)
	}
	w(&j, "],")

	// Heatmap
	w(&j, "\"heatmap\":[")
	for &h, i in s.heatmap {
		if i > 0 do w(&j, ",")
		wf(&j, "{{\"day\":%d,\"hour\":%d,\"hours\":%.1f}}", h.day, h.hour, h.hours)
	}
	w(&j, "],")

	// Genre data
	w(&j, "\"genre_order\":[")
	for &g, i in s.genre_order {
		if i > 0 do w(&j, ",")
		wf(&j, "\"%s\"", esc(g))
	}
	w(&j, "],")

	w(&j, "\"genre_colors\":{")
	// In genre_order, not map order: map iteration varies between processes.
	gi := 0
	for g in s.genre_order {
		c, has := s.genre_colors[g]
		if !has do continue
		if gi > 0 do w(&j, ",")
		wf(&j, "\"%s\":\"%s\"", esc(g), esc(c))
		gi += 1
	}
	w(&j, "},")

	w(&j, "\"genre_area\":[")
	for &gq, qi in s.genre_area {
		if qi > 0 do w(&j, ",")
		wf(&j, "{{\"quarter\":\"%s\",\"partial\":%v", esc(gq.quarter), gq.partial)
		for &g in s.genre_order {
			v: f64 = 0
			if g in gq.values { v = gq.values[g] }
			wf(&j, ",\"%s\":%.1f", esc(g), v)
		}
		w(&j, "}")
	}
	w(&j, "],")

	// Avg track length per year
	w(&j, "\"avg_track_length\":[")
	for &a, i in s.avg_track_length {
		if i > 0 do w(&j, ",")
		wf(&j, "{{\"year\":%d,\"minutes\":%.1f}}", a.year, a.minutes)
	}
	w(&j, "],")

	// Platforms
	w(&j, "\"platforms\":[")
	for &p, i in s.platforms {
		if i > 0 do w(&j, ",")
		wf(&j, "{{\"name\":\"%s\",\"count\":%d}}", esc(p.name), p.count)
	}
	w(&j, "]")

	w(&j, "}")
	return strings.to_string(j)
}

NOINDEX_ANCHOR :: `<meta charset="utf-8">`
NOINDEX_REPLACEMENT :: `<meta charset="utf-8">` +
	"\n    <meta name=\"robots\" content=\"noindex, nofollow, noarchive\">" +
	"\n    <meta name=\"googlebot\" content=\"noindex, nofollow\">"

// render_report fills the template; with noindex it also adds the robots meta
// tags right after the charset declaration. The caller owns the result.
render_report :: proc(s: Stats, noindex: bool) -> (html: string, ok: bool) {
	data := report_json(s)
	defer delete(data)

	tmpl := TEMPLATE
	marker_pos := strings.index(tmpl, DATA_MARKER)
	if marker_pos < 0 do return "", false

	result := strings.builder_make()
	strings.write_string(&result, tmpl[:marker_pos])
	strings.write_string(&result, data)
	strings.write_string(&result, tmpl[marker_pos + len(DATA_MARKER):])
	html = strings.to_string(result)

	if noindex {
		if !strings.contains(html, NOINDEX_ANCHOR) {
			delete(html)
			return "", false
		}
		replaced, _ := strings.replace(html, NOINDEX_ANCHOR, NOINDEX_REPLACEMENT, 1)
		delete(html)
		html = replaced
	}
	return html, true
}

generate_report :: proc(s: Stats, output_path: string, noindex: bool = false) -> bool {
	html, ok := render_report(s, noindex)
	if !ok do return false
	defer delete(html)
	return os.write_entire_file(output_path, transmute([]u8)html) == nil
}
