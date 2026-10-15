package spotify_report

import "core:fmt"
import "core:slice"
import "core:strings"

Track_Key :: struct {
	track:  string,
	artist: string,
}

compute_stats :: proc(plays: []Play) -> Stats {
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
		track_set[Track_Key{p.track, p.artist}] = true
	}
	stats.unique_artists = len(artist_set)
	stats.unique_tracks = len(track_set)

	// Date range
	if len(plays) > 0 {
		stats.date_range_start = format_month_year(plays[0].year, plays[0].month)
		stats.date_range_end = format_month_year(plays[len(plays) - 1].year, plays[len(plays) - 1].month)
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
			album_ms[Track_Key{p.album, p.artist}] += p.ms
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

	// Session openers (gap > 30 min)
	opener_count: map[Track_Key]int
	defer delete(opener_count)
	if len(plays) > 0 {
		opener_count[Track_Key{plays[0].track, plays[0].artist}] += 1
		for i in 1..<len(plays) {
			gap := estimate_gap_seconds(plays[i-1], plays[i])
			if gap > 1800 {
				opener_count[Track_Key{plays[i].track, plays[i].artist}] += 1
			}
		}
	}
	stats.session_openers = top_n_openers(opener_count, 10)

	// Never-skipped songs (15+ plays, 0 skips)
	track_total: map[Track_Key]int
	track_skips: map[Track_Key]int
	defer { delete(track_total); delete(track_skips) }
	for &p in plays {
		k := Track_Key{p.track, p.artist}
		track_total[k] += 1
		if p.skipped { track_skips[k] += 1 }
	}
	ns: [dynamic]Track_Stat
	defer delete(ns)
	for k, count in track_total {
		skip_count := track_skips[k] if k in track_skips else 0
		if count >= 15 && skip_count == 0 {
			append(&ns, Track_Stat{k.track, k.artist, count})
		}
	}
	slice.sort_by(ns[:], proc(a, b: Track_Stat) -> bool { return a.plays > b.plays })
	for i in 0..<min(10, len(ns)) {
		append(&stats.never_skipped, ns[i])
	}

	// Most played song
	track_play_count: map[Track_Key]int
	defer delete(track_play_count)
	for &p in plays { track_play_count[Track_Key{p.track, p.artist}] += 1 }
	best_track: Track_Key
	best_count := 0
	for k, c in track_play_count {
		if c > best_count { best_count = c; best_track = k }
	}
	stats.most_played_song = Track_Stat{best_track.track, best_track.artist, best_count}

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
		if c > best_day_plays { best_day_plays = c; best_day = d }
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
	slice.sort_by(stats.loyalists[:], proc(a, b: Artist_Stat) -> bool { return a.hours > b.hours })

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
		total_yr: i64 = 0
		new_ms: i64 = 0
		top10_ms: i64 = 0
		new_count := 0
		total_count := 0
		for a, ms in yam {
			total_yr += ms
			total_count += 1
			if a in artist_first_year && artist_first_year[a] == yr {
				new_ms += ms
				new_count += 1
			}
			for &t in top10_alltime {
				if a == t {
					top10_ms += ms
					break
				}
			}
		}
		new_pct := 0
		top10_pct := 0
		if total_yr > 0 {
			new_pct = int(f64(new_ms) / f64(total_yr) * 100)
			top10_pct = int(f64(top10_ms) / f64(total_yr) * 100)
		}
		rest_pct := 100 - new_pct - top10_pct
		if rest_pct < 0 do rest_pct = 0
		append(&stats.explore_obsess, JSON_Explore{yr, new_pct, top10_pct, rest_pct, new_count, total_count})
	}

	// Longest streak (consecutive days)
	day_set: map[i64]bool
	defer delete(day_set)
	for &p in plays {
		day_num := i64(p.year) * 366 + i64(p.month) * 31 + i64(p.day)
		day_set[day_num] = true
	}
	day_list: [dynamic]i64
	defer delete(day_list)
	for d in day_set { append(&day_list, d) }
	slice.sort(day_list[:])
	max_streak := 1
	cur_streak := 1
	for i in 1..<len(day_list) {
		if day_list[i] - day_list[i-1] == 1 {
			cur_streak += 1
		} else {
			if cur_streak > max_streak do max_streak = cur_streak
			cur_streak = 1
		}
	}
	if cur_streak > max_streak do max_streak = cur_streak
	stats.longest_streak = max_streak

	// Earworms: 7-day sliding window per track
	{
		track_plays_list: map[Track_Key][dynamic]int
		defer {
			for _, &v in track_plays_list { delete(v) }
			delete(track_plays_list)
		}
		track_plays_month: map[Track_Key][dynamic][2]int  // parallel arrays of {month, year}
		defer {
			for _, &v in track_plays_month { delete(v) }
			delete(track_plays_month)
		}

		for &p in plays {
			k := Track_Key{p.track, p.artist}
			day_num := p.year * 366 + p.month * 31 + p.day
			if k not_in track_plays_list {
				track_plays_list[k] = {}
				track_plays_month[k] = {}
			}
			append(&track_plays_list[k], day_num)
			append(&track_plays_month[k], [2]int{p.month, p.year})
		}

		earworm_list: [dynamic]Earworm_Stat
		defer delete(earworm_list)
		earworm_total_count := 0

		for k, &days in track_plays_list {
			if len(days) < 5 do continue
			slice.sort(days[:])
			months := track_plays_month[k]

			best_count := 0
			best_idx := 0

			// Sliding window: for each play, count how many plays fall within 7 days
			for i in 0..<len(days) {
				count := 0
				for j in i..<len(days) {
					if days[j] - days[i] < 7 {
						count += 1
					} else {
						break
					}
				}
				if count > best_count {
					best_count = count
					best_idx = i
				}
			}

			if best_count >= 5 {
				month_names := [13]string{"", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
				m := months[best_idx][0]
				y := months[best_idx][1]
				period := fmt.aprintf("%s %d", month_names[m], y)
				append(&earworm_list, Earworm_Stat{k.track, k.artist, best_count, period})
			}
			if best_count >= 15 {
				earworm_total_count += 1
			}
		}

		slice.sort_by(earworm_list[:], proc(a, b: Earworm_Stat) -> bool { return a.plays > b.plays })

		stats.earworm_total = earworm_total_count
		for i in 0..<min(20, len(earworm_list)) {
			append(&stats.earworms, earworm_list[i])
		}
		if len(earworm_list) > 0 {
			stats.worst_earworm = earworm_list[0]
		}
	}

	// Skip rate per year (first and last years)
	if len(years) > 0 {
		first_yr := years[0]
		last_yr := years[len(years) - 1]

		first_total := 0
		first_skipped := 0
		last_total := 0
		last_skipped := 0

		for &p in plays {
			if p.year == first_yr {
				first_total += 1
				if p.skipped do first_skipped += 1
			}
			if p.year == last_yr {
				last_total += 1
				if p.skipped do last_skipped += 1
			}
		}

		stats.skip_rate_first_yr = first_yr
		stats.skip_rate_last_yr = last_yr
		if first_total > 0 {
			stats.skip_rate_first = first_skipped * 100 / first_total
		}
		if last_total > 0 {
			stats.skip_rate_last = last_skipped * 100 / last_total
		}
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
		slice.sort_by(plat_list[:], proc(a, b: Platform_Stat) -> bool { return a.count > b.count })

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
		slice.sort_by(yr_artists[:], proc(a, b: Artist_Stat) -> bool { return a.hours > b.hours })

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

compute_genre_stats :: proc(stats: ^Stats, plays: []Play, genre_map: map[string]string) {
	if len(genre_map) == 0 do return

	// Genre order and colors
	for g in GENRE_ORDER_DEFAULT {
		append(&stats.genre_order, g)
	}
	for gc in GENRE_COLORS_DEFAULT {
		stats.genre_colors[gc[0]] = gc[1]
	}

	// Count classified
	classified := 0
	total_ms: i64 = 0
	other_ms: i64 = 0

	for &p in plays {
		total_ms += p.ms
		if p.artist in genre_map {
			classified += 1
		} else {
			other_ms += p.ms
		}
	}
	stats.genre_classified = classified
	stats.genre_other_pct = f64(other_ms) / f64(max(total_ms, 1)) * 100

	// Genre share by quarter (exclude last year if incomplete)
	quarter_genre_ms: map[string]map[string]i64
	defer {
		for _, &m in quarter_genre_ms { delete(m) }
		delete(quarter_genre_ms)
	}

	max_year := 0
	for &p in plays {
		if p.year > max_year do max_year = p.year
	}

	for &p in plays {
		if p.year >= max_year do continue  // skip incomplete year

		q := fmt.aprintf("%d-Q%d", p.year, (p.month - 1) / 3 + 1)
		genre := "Other"
		if p.artist in genre_map {
			genre = genre_map[p.artist]
		}

		if q not_in quarter_genre_ms {
			quarter_genre_ms[q] = {}
		}
		(&quarter_genre_ms[q])[genre] += p.ms
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
		gq.values = {}
		for g in GENRE_ORDER_DEFAULT {
			ms: i64 = 0
			if g in gm { ms = gm[g] }
			pct := f64(ms) / f64(max(total_q, 1)) * 100
			gq.values[g] = pct
		}
		append(&stats.genre_area, gq)
	}
}

estimate_gap_seconds :: proc(a, b: Play) -> i64 {
	da := i64(a.year) * 366 * 86400 + i64(a.month) * 31 * 86400 + i64(a.day) * 86400 + i64(a.hour) * 3600 + i64(a.minute) * 60
	db := i64(b.year) * 366 * 86400 + i64(b.month) * 31 * 86400 + i64(b.day) * 86400 + i64(b.hour) * 3600 + i64(b.minute) * 60
	diff := db - da
	if diff < 0 do diff = -diff
	return diff
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
	slice.sort_by(items[:], proc(a, b: Artist_Stat) -> bool { return a.hours > b.hours })
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
	slice.sort_by(items[:], proc(a, b: Album_Stat) -> bool { return a.hours > b.hours })
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
		if c > 0 { append(&items, Opener_Stat{k.track, k.artist, c}) }
	}
	slice.sort_by(items[:], proc(a, b: Opener_Stat) -> bool { return a.count > b.count })
	result: [dynamic]Opener_Stat
	for i in 0..<min(n, len(items)) {
		append(&result, items[i])
	}
	return result
}
