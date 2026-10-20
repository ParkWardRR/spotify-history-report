package spotify_report

import "core:fmt"
import "core:slice"
import "core:strings"

// What a statistic counts as "one track". With a Spotify URI that is the URI's
// identity: two URIs are two tracks even when their titles match (an album cut
// and a compilation cut, a live take, a remaster), and `merges` in
// .shr/overrides.json is how the user says otherwise. Plays that carry the same
// URI always carry the same title and artist (see `canonicalize_uri_names`), so
// renamed catalogue entries never split. Without a URI the key is the exact
// title and artist text and `uri` is empty. Album keys reuse the type as
// (album, artist, "").
Track_Key :: struct {
	track:  string,
	artist: string,
	uri:    string,
}

// The one place a play is mapped to a track key.
play_key :: proc(p: Play) -> Track_Key {
	return Track_Key{p.track, p.artist, p.uri}
}

// A play's exact title and artist text, ignoring its URI: what the identity
// review calls a "song".
text_key :: proc(p: Play) -> Track_Key {
	return Track_Key{p.track, p.artist, ""}
}

// Skipping is tracked over every record with a track and artist, including the
// sub-30-second ones the pipeline drops from `plays`. Two separate things are
// counted: rows Spotify flagged `skipped: true`, and short listens (under 30 s).
// Rows whose flag is null are counted as unflagged, never as "not skipped", so
// the explicit-skip rate is taken over flagged rows only. Filled while loading.
Skip_Tally :: struct {
	year_total:    map[int]int, // music rows
	year_flagged:  map[int]int, // rows whose `skipped` field was present
	year_explicit: map[int]int, // flagged rows with skipped = true
	year_short:    map[int]int, // rows under MIN_PLAY_MS
	track_skips:   map[Track_Key]int, // rows that are either, for never-skipped
}

tally_record :: proc(t: ^Skip_Tally, year: int, key: Track_Key, flag: Skip_Flag, ms: i64) {
	t.year_total[year] += 1
	if flag != .Unknown do t.year_flagged[year] += 1
	explicit := flag == .Yes
	short := ms < MIN_PLAY_MS
	if explicit do t.year_explicit[year] += 1
	if short do t.year_short[year] += 1
	if explicit || short do t.track_skips[key] += 1
}

skip_tally_destroy :: proc(t: ^Skip_Tally) {
	delete(t.year_total); delete(t.year_flagged); delete(t.year_explicit); delete(t.year_short); delete(t.track_skips)
}

EARWORM_DAYS :: 7

// The most plays that fit in a window of `days` calendar days starting at one of
// the plays, and where the first such window starts. `ords` are day numbers in
// ascending order. A window starting at ords[i] covers ords[i] ..< ords[i]+days.
// Both ends only move forward, so this is linear instead of rescanning from
// every play.
densest_window :: proc(ords: []i64, days: i64) -> (best_count, best_idx: int) {
	j := 0
	for i in 0 ..< len(ords) {
		if j < i do j = i
		for j < len(ords) && ords[j] - ords[i] < days do j += 1
		if j - i > best_count {
			best_count = j - i
			best_idx = i
		}
	}
	return
}

// True if `a` ranks before `b`: higher count first, then artist and track name
// ascending, so equal counts order the same way on every run (map iteration
// order is unspecified).
ranks_before :: proc(a_n: int, a_k: Track_Key, b_n: int, b_k: Track_Key) -> bool {
	if a_n != b_n do return a_n > b_n
	if a_k.artist != b_k.artist do return a_k.artist < b_k.artist
	if a_k.track != b_k.track do return a_k.track < b_k.track
	return a_k.uri < b_k.uri
}

compute_stats :: proc(plays: []Play, tally: ^Skip_Tally = nil) -> Stats {
	stats: Stats
	stats.total_plays = len(plays)

	total: i64 = 0
	for &p in plays { total += p.ms }
	stats.total_hours = int(total / 3600000)

	// Unique artists and tracks
	artist_set: map[string]bool
	track_set: map[Track_Key]bool
	defer { delete(artist_set); delete(track_set) }

	for &p in plays {
		artist_set[p.artist] = true
		track_set[play_key(p)] = true
	}
	stats.unique_artists = len(artist_set)
	stats.unique_tracks = len(track_set)

	// Date range and coverage. Plays arrive sorted, but coverage is derived from
	// min/max so completeness never depends on that.
	if len(plays) > 0 {
		first, last := 0, 0
		for i in 1..<len(plays) {
			if plays[i].unix < plays[first].unix do first = i
			if plays[i].unix > plays[last].unix do last = i
		}
		stats.date_range_start = format_month_year(plays[first].year, plays[first].month)
		stats.date_range_end = format_month_year(plays[last].year, plays[last].month)
		stats.first_ordinal = plays[first].ordinal
		stats.last_ordinal = plays[last].ordinal
		stats.last_year = plays[last].year
		stats.last_year_partial = plays[last].ordinal < date_ordinal(plays[last].year, 12, 31)
	}

	// Artist hours
	artist_ms: map[string]i64
	defer delete(artist_ms)
	for &p in plays { artist_ms[p.artist] += p.ms }
	stats.top_artists = top_n_artists(artist_ms, 25)

	// Top albums
	album_ms: map[Track_Key]i64
	defer delete(album_ms)
	for &p in plays {
		if len(p.album) > 0 {
			album_ms[Track_Key{p.album, p.artist, ""}] += p.ms
		}
	}
	stats.top_albums = top_n_albums(album_ms, 15)

	// Hours by year
	year_ms: map[int]i64
	defer delete(year_ms)
	for &p in plays { year_ms[p.year] += p.ms }
	years := sorted_map_keys(year_ms)
	defer delete(years)
	for y in years {
		if y in year_ms {
			append(&stats.hours_by_year, Year_Hours{y, f64(year_ms[y]) / 3600000})
		}
	}

	// Session openers: the first play of each session (see sessions.odin).
	opener_count: map[Track_Key]int
	defer delete(opener_count)
	ensure_sessions(plays)
	for &p in plays {
		if p.opens_session do opener_count[play_key(p)] += 1
	}
	stats.session_openers = top_n_openers(opener_count, 10)

	// Never-skipped songs (15+ plays, 0 skips)
	// A skip also covers the sub-30s plays, which only the tally still knows about.
	track_total: map[Track_Key]int
	track_skips: map[Track_Key]int
	defer { delete(track_total); delete(track_skips) }
	for &p in plays {
		k := play_key(p)
		track_total[k] += 1
		if explicit_skip(p) || short_listen(p) { track_skips[k] += 1 }
	}
	ns: [dynamic]Track_Stat
	defer delete(ns)
	for k, count in track_total {
		skip_count := track_skips[k]
		if tally != nil do skip_count += tally.track_skips[k]
		if count >= 15 && skip_count == 0 {
			append(&ns, Track_Stat{k.track, k.artist, count, k.uri})
		}
	}
	slice.sort_by(ns[:], proc(a, b: Track_Stat) -> bool {
		return ranks_before(a.plays, Track_Key{a.track, a.artist, a.uri}, b.plays, Track_Key{b.track, b.artist, b.uri})
	})
	for i in 0..<min(10, len(ns)) {
		append(&stats.never_skipped, ns[i])
	}

	// Most played song
	track_play_count: map[Track_Key]int
	defer delete(track_play_count)
	for &p in plays { track_play_count[play_key(p)] += 1 }
	best_track: Track_Key
	best_count := 0
	for k, c in track_play_count {
		if best_count == 0 || ranks_before(c, k, best_count, best_track) {
			best_count = c; best_track = k
		}
	}
	stats.most_played_song = Track_Stat{best_track.track, best_track.artist, best_count, best_track.uri}

	// Biggest listening day
	day_plays: map[string]int
	day_ms_total: map[string]i64
	defer { delete(day_plays); delete(day_ms_total) }
	for &p in plays {
		d := fmt.aprintf("%04d-%02d-%02d", p.year, p.month, p.day)
		day_plays[d] += 1
		day_ms_total[d] += p.ms
	}
	best_day: string
	best_day_plays := 0
	for d, c in day_plays {
		if c > best_day_plays || (c == best_day_plays && d < best_day) { best_day_plays = c; best_day = d }
	}
	bd_ms: i64 = 0
	if best_day in day_ms_total { bd_ms = day_ms_total[best_day] }
	stats.biggest_day = Day_Stat{best_day, best_day_plays, f64(bd_ms) / 3600000}

	// Peak hour
	hour_ms: map[int]i64
	defer delete(hour_ms)
	for &p in plays { hour_ms[p.hour] += p.ms }
	peak_h := 0
	peak_v: i64 = 0
	for h in 0..<24 {
		v: i64 = 0
		if h in hour_ms { v = hour_ms[h] }
		if v > peak_v { peak_v = v; peak_h = h }
	}
	stats.peak_hour = peak_h
	stats.peak_hour_val = int(peak_v / 3600000)

	// Peak day of week
	dow_ms: map[int]i64
	defer delete(dow_ms)
	for &p in plays { dow_ms[p.weekday] += p.ms }
	dow_names := [7]string{"Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"}
	peak_d := 0
	peak_dv: i64 = 0
	for d in 0..<7 {
		v: i64 = 0
		if d in dow_ms { v = dow_ms[d] }
		if v > peak_dv { peak_dv = v; peak_d = d }
	}
	stats.peak_day = dow_names[peak_d]

	// Loyal artists (listened every year)
	artist_year_set: map[string]map[int]bool
	defer {
		for _, &s in artist_year_set { delete(s) }
		delete(artist_year_set)
	}
	all_years: map[int]bool
	defer delete(all_years)
	for &p in plays {
		all_years[p.year] = true
		if p.artist not_in artist_year_set {
			artist_year_set[p.artist] = {}
		}
		(&artist_year_set[p.artist])[p.year] = true
	}
	n_years := len(all_years)
	stats.n_years = n_years
	for a, ys in artist_year_set {
		if len(ys) == n_years {
			stats.loyal_count += 1
			ms_val: i64 = 0
			if a in artist_ms { ms_val = artist_ms[a] }
			append(&stats.loyalists, Artist_Stat{a, f64(ms_val) / 3600000})
		}
	}
	slice.sort_by(stats.loyalists[:], artist_before)

	// Heatmap: day of week x hour
	hm_ms: map[[2]int]i64
	defer delete(hm_ms)
	for &p in plays {
		hm_ms[{p.weekday, p.hour}] += p.ms
	}
	for d in 0..<7 {
		for h in 0..<24 {
			v: i64 = 0
			key := [2]int{d, h}
			if key in hm_ms { v = hm_ms[key] }
			append(&stats.heatmap, JSON_HM{d, h, f64(v) / 3600000})
		}
	}

	// Explore vs obsess
	artist_first_year: map[string]int
	defer delete(artist_first_year)
	for &p in plays {
		if p.artist not_in artist_first_year {
			artist_first_year[p.artist] = p.year
		} else if p.year < artist_first_year[p.artist] {
			artist_first_year[p.artist] = p.year
		}
	}
	year_artist_ms: map[int]map[string]i64
	defer {
		for _, &m in year_artist_ms { delete(m) }
		delete(year_artist_ms)
	}
	for &p in plays {
		if p.year not_in year_artist_ms {
			year_artist_ms[p.year] = {}
		}
		(&year_artist_ms[p.year])[p.artist] += p.ms
	}
	top10_alltime: [dynamic]string
	defer delete(top10_alltime)
	for i in 0..<min(10, len(stats.top_artists)) {
		append(&top10_alltime, stats.top_artists[i].name)
	}
	yr_keys := sorted_map_keys(year_artist_ms)
	defer delete(yr_keys)
	for yr in yr_keys {
		if yr not_in year_artist_ms do continue
		yam := year_artist_ms[yr]
		// The three shares partition the year's listening: an artist that is both
		// new this year and an all-time top-10 counts as top-10 only.
		// `new_count` still counts every artist first heard this year.
		total_yr: i64 = 0
		new_ms: i64 = 0
		top10_ms: i64 = 0
		new_count := 0
		total_count := 0
		for a, ms in yam {
			total_yr += ms
			total_count += 1
			is_new := a in artist_first_year && artist_first_year[a] == yr
			if is_new do new_count += 1

			is_top10 := false
			for &t in top10_alltime {
				if a == t {
					is_top10 = true
					break
				}
			}
			if is_top10 {
				top10_ms += ms
			} else if is_new {
				new_ms += ms
			}
		}
		new_pct := 0
		top10_pct := 0
		if total_yr > 0 {
			new_pct = int(f64(new_ms) / f64(total_yr) * 100)
			top10_pct = int(f64(top10_ms) / f64(total_yr) * 100)
		}
		rest_pct := 100 - new_pct - top10_pct // ≥ 0: the buckets are disjoint
		append(&stats.explore_obsess, JSON_Explore{yr, new_pct, top10_pct, rest_pct, new_count, total_count})
	}

	// Longest streak (consecutive days)
	day_set: map[i64]bool
	defer delete(day_set)
	for &p in plays {
		day_set[p.ordinal] = true
	}
	day_list: [dynamic]i64
	defer delete(day_list)
	for d in day_set { append(&day_list, d) }
	slice.sort(day_list[:])
	max_streak := 0
	cur_streak := 0
	for d, i in day_list {
		if i > 0 && d - day_list[i-1] == 1 {
			cur_streak += 1
		} else {
			cur_streak = 1
		}
		max_streak = max(max_streak, cur_streak)
	}
	stats.longest_streak = max_streak

	// Earworms: 7-day sliding window per track
	{
		Day_Play :: struct {
			ordinal: i64,
			year:    int,
			month:   int,
		}
		track_days: map[Track_Key][dynamic]Day_Play
		defer {
			for _, &v in track_days { delete(v) }
			delete(track_days)
		}
		for &p in plays {
			k := play_key(p)
			if k not_in track_days do track_days[k] = {}
			append(&track_days[k], Day_Play{p.ordinal, p.year, p.month})
		}

		earworm_list: [dynamic]Earworm_Stat
		defer delete(earworm_list)
		earworm_total_count := 0

		for k, &days in track_days {
			if len(days) < 5 do continue
			slice.stable_sort_by(days[:], proc(a, b: Day_Play) -> bool { return a.ordinal < b.ordinal })

			ords := make([]i64, len(days), context.temp_allocator)
			for d, i in days do ords[i] = d.ordinal
			best_count, best_idx := densest_window(ords, EARWORM_DAYS)

			if best_count >= 5 {
				month_names := [13]string{"", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
				period := fmt.aprintf("%s %d", month_names[days[best_idx].month], days[best_idx].year)
				append(&earworm_list, Earworm_Stat{k.track, k.artist, best_count, period, k.uri})
			}
			if best_count >= 15 {
				earworm_total_count += 1
			}
		}

		slice.sort_by(earworm_list[:], proc(a, b: Earworm_Stat) -> bool {
			return ranks_before(a.plays, Track_Key{a.track, a.artist, a.uri}, b.plays, Track_Key{b.track, b.artist, b.uri})
		})

		stats.earworm_total = earworm_total_count
		for i in 0..<min(20, len(earworm_list)) {
			append(&stats.earworms, earworm_list[i])
		}
		if len(earworm_list) > 0 {
			stats.worst_earworm = earworm_list[0]
		}
	}

	// Skip rates for the first and last year. Explicit skips are a share of the
	// rows that carry the flag (-1 when none do); short listens are a share of all
	// music rows. With no tally the qualifying plays stand in (so no short ones).
	if len(years) > 0 {
		first_yr := years[0]
		last_yr := years[len(years) - 1]

		Rates :: struct { explicit_pct, short_pct, flagged, total: int }
		rates :: proc(plays: []Play, tally: ^Skip_Tally, yr: int) -> (r: Rates) {
			explicit := 0
			if tally != nil {
				r.total, r.flagged, explicit = tally.year_total[yr], tally.year_flagged[yr], tally.year_explicit[yr]
				if r.total > 0 do r.short_pct = tally.year_short[yr] * 100 / r.total
			} else {
				for &p in plays {
					if p.year != yr do continue
					r.total += 1
					if p.skipped != .Unknown do r.flagged += 1
					if explicit_skip(p) do explicit += 1
				}
			}
			r.explicit_pct = explicit * 100 / r.flagged if r.flagged > 0 else -1
			return
		}

		stats.skip_rate_first_yr = first_yr
		stats.skip_rate_last_yr = last_yr
		f, l := rates(plays, tally, first_yr), rates(plays, tally, last_yr)
		stats.skip_rate_first, stats.skip_rate_last = f.explicit_pct, l.explicit_pct
		stats.short_rate_first, stats.short_rate_last = f.short_pct, l.short_pct

		total_rows, flagged_rows := 0, 0
		for y in years {
			r := rates(plays, tally, y)
			total_rows += r.total
			flagged_rows += r.flagged
		}
		stats.skip_flag_coverage = flagged_rows * 100 / total_rows if total_rows > 0 else 0
	}

	// Average track length per year
	{
		year_ms_sum: map[int]i64
		year_count: map[int]int
		defer { delete(year_ms_sum); delete(year_count) }

		for &p in plays {
			year_ms_sum[p.year] += p.ms
			year_count[p.year] += 1
		}

		for y in years {
			ms_sum: i64 = 0
			cnt := 0
			if y in year_ms_sum { ms_sum = year_ms_sum[y] }
			if y in year_count { cnt = year_count[y] }
			minutes: f64 = 0
			if cnt > 0 {
				minutes = f64(ms_sum) / f64(cnt) / 60000
			}
			append(&stats.avg_track_length, Year_Avg_Len{y, minutes})
		}

		if len(years) > 0 {
			first_yr := years[0]
			last_yr := years[len(years) - 1]
			stats.avg_len_first_yr = first_yr
			stats.avg_len_last_yr = last_yr
			for &atl in stats.avg_track_length {
				if atl.year == first_yr do stats.avg_len_first = atl.minutes
				if atl.year == last_yr  do stats.avg_len_last = atl.minutes
			}
		}
	}

	// Concentration: top 10 artists as % of total time
	{
		total_all_ms: i64 = 0
		for _, ms in artist_ms { total_all_ms += ms }

		// Sort artist_ms by value descending
		artist_ms_sorted: [dynamic]i64
		defer delete(artist_ms_sorted)
		for _, ms in artist_ms {
			append(&artist_ms_sorted, ms)
		}
		slice.sort_by(artist_ms_sorted[:], proc(a, b: i64) -> bool { return a > b })

		top10_ms: i64 = 0
		for i in 0..<min(10, len(artist_ms_sorted)) {
			top10_ms += artist_ms_sorted[i]
		}
		if total_all_ms > 0 {
			stats.concentration_top10 = f64(top10_ms) / f64(total_all_ms) * 100
		}
	}

	// Songs for half: how many tracks account for 50% of total plays
	{
		track_counts: [dynamic]int
		defer delete(track_counts)
		for _, c in track_play_count {
			append(&track_counts, c)
		}
		slice.sort_by(track_counts[:], proc(a, b: int) -> bool { return a > b })

		total_all := len(plays)
		half := total_all / 2
		running := 0
		count := 0
		for c in track_counts {
			running += c
			count += 1
			if running >= half do break
		}
		stats.songs_for_half = count
	}

	// Peak day hours
	{
		peak_dow_ms: i64 = 0
		if peak_d in dow_ms { peak_dow_ms = dow_ms[peak_d] }
		stats.peak_day_hours = int(peak_dow_ms / 3600000)
	}

	// Platforms
	{
		platform_counts: map[string]int
		defer delete(platform_counts)

		classify_platform :: proc(raw: string) -> string {
			if strings.contains(raw, "iPhone") || strings.contains(raw, "iOS") {
				return "iPhone"
			} else if strings.contains(raw, "OS X") || strings.contains(raw, "Mac") || strings.contains(raw, "macOS") {
				return "Mac"
			} else if strings.contains(raw, "Windows") {
				return "Windows"
			} else if strings.contains(raw, "Android") {
				return "Android"
			} else if len(raw) == 0 {
				return "Unknown"
			}
			return "Other"
		}

		for &p in plays {
			name := classify_platform(p.platform)
			platform_counts[name] += 1
		}

		plat_list: [dynamic]Platform_Stat
		defer delete(plat_list)
		for name, count in platform_counts {
			append(&plat_list, Platform_Stat{name, count})
		}
		slice.sort_by(plat_list[:], proc(a, b: Platform_Stat) -> bool {
			if a.count != b.count do return a.count > b.count
			return a.name < b.name
		})

		for &ps in plat_list {
			append(&stats.platforms, ps)
		}
	}

	// Top artists by year (top 5 per year)
	for y in years {
		if y not_in year_artist_ms do continue
		yam := year_artist_ms[y]

		yr_artists: [dynamic]Artist_Stat
		defer delete(yr_artists)
		for a, ms in yam {
			append(&yr_artists, Artist_Stat{a, f64(ms) / 3600000})
		}
		slice.sort_by(yr_artists[:], artist_before)

		yt: Year_Top
		yt.year = y
		for i in 0..<min(5, len(yr_artists)) {
			append(&yt.artists, yr_artists[i])
		}
		append(&stats.top_by_year, yt)
	}

	return stats
}

GENRE_ORDER_DEFAULT :: [?]string{
	"Hip-hop & Rap", "Indie pop", "Funk & Soul", "Electronic",
	"Rock", "R&B", "Jazz", "Latin", "Classical", "Pop",
	"Country", "Metal", "World", "Other",
}

GENRE_COLORS_DEFAULT :: [?][2]string{
	{"Hip-hop & Rap",  "#2a78d6"},
	{"Indie pop",      "#eb6834"},
	{"Funk & Soul",    "#1baf7a"},
	{"Electronic",     "#eda100"},
	{"Rock",           "#e87ba4"},
	{"R&B",            "#008300"},
	{"Jazz",           "#4a3aa7"},
	{"Latin",          "#e34948"},
	{"Classical",      "#5E81AC"},
	{"Pop",            "#D08770"},
	{"Country",        "#B48EAD"},
	{"Metal",          "#BF616A"},
	{"World",          "#A3BE8C"},
	{"Other",          "#b8b7b2"},
}

compute_genre_stats :: proc(stats: ^Stats, plays: []Play, r: ^Genre_Resolver) {
	if len(r.by_artist) == 0 && len(r.by_track) == 0 do return

	for g in GENRE_ORDER_DEFAULT {
		append(&stats.genre_order, g)
	}
	for gc in GENRE_COLORS_DEFAULT {
		stats.genre_colors[gc[0]] = gc[1]
	}

	// Resolve each play once; remember how much listening has no annotation.
	total_ms, unknown_ms: i64
	source_ms: [Annotation_Source]i64
	picks := make([]string, len(plays), context.temp_allocator)
	for &p, i in plays {
		total_ms += p.ms
		if pick, ok := resolve_genre(r, p.track, p.artist); ok {
			picks[i] = pick.genre
			source_ms[pick.source] += p.ms
			stats.genre_classified += 1
		} else {
			picks[i] = UNCLASSIFIED
			unknown_ms += p.ms
		}
	}
	stats.genre_unclassified_pct = f64(unknown_ms) / f64(max(total_ms, 1)) * 100
	for s in Annotation_Source do stats.genre_source_pct[s] = f64(source_ms[s]) / f64(max(total_ms, 1)) * 100
	stats.genre_user_targets = r.user_artists + r.user_tracks

	// "Unclassified" is a series of its own, and only when there is something in it.
	if unknown_ms > 0 {
		append(&stats.genre_order, UNCLASSIFIED)
		stats.genre_colors[UNCLASSIFIED] = UNCLASSIFIED_COLOR
	}

	// Genre share by quarter. A quarter is partial when the data does not span
	// all of it (typically the current quarter, or the one the history starts in);
	// partial quarters are kept and flagged rather than dropped.
	quarter_genre_ms: map[string]map[string]i64
	defer {
		for _, &m in quarter_genre_ms { delete(m) }
		delete(quarter_genre_ms)
	}

	for &p, i in plays {
		q := quarter_label(p.year, p.month)
		if q not_in quarter_genre_ms {
			quarter_genre_ms[q] = {}
		}
		(&quarter_genre_ms[q])[picks[i]] += p.ms
	}

	// Sort quarters
	q_keys: [dynamic]string
	defer delete(q_keys)
	for q in quarter_genre_ms {
		append(&q_keys, q)
	}
	slice.sort_by(q_keys[:], proc(a, b: string) -> bool { return a < b })

	for q in q_keys {
		gm := quarter_genre_ms[q]
		total_q: i64 = 0
		for _, ms in gm { total_q += ms }

		gq: Genre_Quarter
		gq.quarter = q
		gq.partial = quarter_partial(q, stats.first_ordinal, stats.last_ordinal)
		gq.values = {}
		for g in stats.genre_order {
			ms: i64 = 0
			if g in gm { ms = gm[g] }
			gq.values[g] = f64(ms) / f64(max(total_q, 1)) * 100
		}
		append(&stats.genre_area, gq)
	}
}

quarter_label :: proc(year, month: int) -> string {
	return fmt.aprintf("%d-Q%d", year, (month - 1) / 3 + 1)
}

// Whether the data, spanning [first, last] local days, fails to cover every
// day of the quarter named by a "YYYY-Qn" label.
quarter_partial :: proc(label: string, first, last: i64) -> bool {
	if len(label) < 7 do return true
	year := parse_int(label[0:4])
	q := int(label[6] - '0')
	m0 := (q - 1) * 3 + 1
	start := date_ordinal(year, m0, 1)
	end := date_ordinal(year, m0 + 2, days_in_month(year, m0 + 2))
	return first > start || last < end
}

// Hours descending, then name ascending.
artist_before :: proc(a, b: Artist_Stat) -> bool {
	if a.hours != b.hours do return a.hours > b.hours
	return a.name < b.name
}

format_month_year :: proc(y, m: int) -> string {
	months := [13]string{"", "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}
	return fmt.aprintf("%s %d", months[m], y)
}

sorted_map_keys :: proc(m: map[int]$V) -> [dynamic]int {
	keys: [dynamic]int
	for k in m { append(&keys, k) }
	slice.sort(keys[:])
	return keys
}

top_n_artists :: proc(m: map[string]i64, n: int) -> [dynamic]Artist_Stat {
	items: [dynamic]Artist_Stat
	defer delete(items)
	for name, ms in m {
		append(&items, Artist_Stat{name, f64(ms) / 3600000})
	}
	slice.sort_by(items[:], artist_before)
	result: [dynamic]Artist_Stat
	for i in 0..<min(n, len(items)) {
		append(&result, items[i])
	}
	return result
}

top_n_albums :: proc(m: map[Track_Key]i64, n: int) -> [dynamic]Album_Stat {
	items: [dynamic]Album_Stat
	defer delete(items)
	for k, ms in m {
		append(&items, Album_Stat{k.track, k.artist, f64(ms) / 3600000})
	}
	slice.sort_by(items[:], proc(a, b: Album_Stat) -> bool {
		if a.hours != b.hours do return a.hours > b.hours
		if a.artist != b.artist do return a.artist < b.artist
		return a.album < b.album
	})
	result: [dynamic]Album_Stat
	for i in 0..<min(n, len(items)) {
		append(&result, items[i])
	}
	return result
}

top_n_openers :: proc(m: map[Track_Key]int, n: int) -> [dynamic]Opener_Stat {
	items: [dynamic]Opener_Stat
	defer delete(items)
	for k, c in m {
		if c > 0 { append(&items, Opener_Stat{k.track, k.artist, c, k.uri}) }
	}
	slice.sort_by(items[:], proc(a, b: Opener_Stat) -> bool {
		return ranks_before(a.count, Track_Key{a.track, a.artist, a.uri}, b.count, Track_Key{b.track, b.artist, b.uri})
	})
	result: [dynamic]Opener_Stat
	for i in 0..<min(n, len(items)) {
		append(&result, items[i])
	}
	return result
}
