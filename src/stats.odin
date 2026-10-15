package spotify_report

import "core:fmt"
import "core:slice"

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
	dow_names := [7]string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}
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

	return stats
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
