package spotify_report

import "core:fmt"
import "core:os"
import "core:slice"

main :: proc() {
	hide_cursor()
	defer show_cursor()

	clear_screen()
	draw_header()

	args := os.args
	data_dir: string
	if len(args) < 2 {
		f4 := fg(NORD4)
		defer delete(f4)
		fmt.printf("  %sUsage:%s %sspotify-history-report%s <data-dir>\n\n", BOLD, RESET, f4, RESET)
		fmt.printf("  %sdata-dir%s   Directory with Streaming_History_Audio_*.json files\n\n", f4, RESET)
		return
	}
	data_dir = args[1]

	// Find JSON files
	draw_section_header("Scanning")
	files := find_json_files(data_dir)
	if len(files) == 0 {
		f11 := fg(NORD11)
		defer delete(f11)
		fmt.printf("  %s✗ No Streaming_History_Audio_*.json found in %s%s\n\n", f11, data_dir, RESET)
		return
	}
	f14 := fg(NORD14)
	defer delete(f14)
	fmt.printf("  %s%d%s files found\n", f14, len(files), RESET)

	// Load and parse records
	draw_section_header("Loading")
	all_plays: [dynamic]Play
	total_records := 0

	for path, fi in files {
		draw_progress_bar("Loading... ", fi + 1, len(files))

		records, ok := load_records(path)
		if !ok {
			f11 := fg(NORD11)
			defer delete(f11)
			fmt.printf("\n  %s✗ Failed to parse %s%s\n", f11, path, RESET)
			continue
		}

		total_records += len(records)

		for &rec in records {
			track := rec.master_metadata_track_name.? or_else ""
			artist := rec.master_metadata_album_artist_name.? or_else ""
			if rec.ms_played < 30000 || len(track) == 0 || len(artist) == 0 do continue

			year, month, day, hour, minute, weekday := parse_ts_fields(rec.ts)
			append(&all_plays, Play{
				year     = year,
				month    = month,
				day      = day,
				hour     = hour,
				minute   = minute,
				weekday  = weekday,
				ms       = rec.ms_played,
				track    = track,
				artist   = artist,
				album    = rec.master_metadata_album_album_name.? or_else "",
				platform = rec.platform.? or_else "",
				skipped  = rec.skipped.? or_else false,
				ts_raw   = rec.ts,
			})
		}
		delete(records)
	}
	fmt.println()

	// Sort by raw timestamp for session detection
	slice.sort_by(all_plays[:], proc(a, b: Play) -> bool {
		return a.ts_raw < b.ts_raw
	})

	f8 := fg(NORD8)
	defer delete(f8)
	fmt.printf("  %s%d%s records, %s%d%s qualifying plays\n",
		f8, total_records, RESET,
		f14, len(all_plays), RESET)

	// Compute stats
	draw_section_header("Computing")
	stats := compute_stats(all_plays[:])
	fmt.printf("  %sDone%s\n", f14, RESET)

	// Dashboard
	fmt.println()
	draw_separator()
	draw_section_header("Dashboard")
	fmt.println()

	draw_stat_card("Total plays",    fmt.aprintf("%d", stats.total_plays), NORD8)
	draw_stat_card("Total hours",    fmt.aprintf("%d", stats.total_hours), NORD8)
	draw_stat_card("Unique artists", fmt.aprintf("%d", stats.unique_artists), NORD9)
	draw_stat_card("Unique tracks",  fmt.aprintf("%d", stats.unique_tracks), NORD9)
	draw_stat_card("Loyal artists",  fmt.aprintf("%d (%d years)", stats.loyal_count, stats.n_years), NORD14)
	draw_stat_card("Peak hour",      fmt.aprintf("%d:00 (%dh total)", stats.peak_hour, stats.peak_hour_val), NORD13)
	draw_stat_card("Peak day",       stats.peak_day, NORD13)
	draw_stat_card("Most played",    fmt.aprintf("\"%s\" (%dx)", stats.most_played_song.track, stats.most_played_song.plays), NORD12)

	// Top artists
	draw_section_header("Top artists")
	fmt.println()
	max_h: f64 = 0
	for &a in stats.top_artists {
		if a.hours > max_h do max_h = a.hours
	}
	colors := [5]Nord{NORD8, NORD9, NORD7, NORD10, NORD15}
	for i in 0..<min(10, len(stats.top_artists)) {
		draw_mini_bar(stats.top_artists[i].name, stats.top_artists[i].hours, max_h, colors[i % 5])
	}

	// Top albums
	draw_section_header("Top albums")
	fmt.println()
	for i in 0..<min(5, len(stats.top_albums)) {
		a := stats.top_albums[i]
		draw_list_item(i + 1, a.album, a.artist, fmt.aprintf("%.1fh", a.hours), NORD7)
	}

	// Session openers
	if len(stats.session_openers) > 0 {
		draw_section_header("Session openers")
		fmt.println()
		for i in 0..<min(5, len(stats.session_openers)) {
			s := stats.session_openers[i]
			draw_list_item(i + 1, s.track, s.artist, fmt.aprintf("%dx", s.count), NORD15)
		}
	}

	// Never skipped
	if len(stats.never_skipped) > 0 {
		draw_section_header("Never skipped")
		fmt.println()
		for i in 0..<min(5, len(stats.never_skipped)) {
			s := stats.never_skipped[i]
			draw_list_item(i + 1, s.track, s.artist, fmt.aprintf("%d plays", s.plays), NORD14)
		}
	}

	// Hours by year
	draw_section_header("Hours by year")
	fmt.println()
	max_yh: f64 = 0
	for &yh in stats.hours_by_year {
		if yh.hours > max_yh do max_yh = yh.hours
	}
	for &yh in stats.hours_by_year {
		draw_mini_bar(fmt.aprintf("%d", yh.year), yh.hours, max_yh, NORD8)
	}

	draw_separator()

	// Generate HTML report
	output_path := "spotify_report.html"
	if len(args) >= 3 {
		output_path = args[2]
	}

	draw_section_header("Generating report")
	ok_report := generate_report(stats, output_path)
	if ok_report {
		draw_done(output_path)
	} else {
		f11 := fg(NORD11)
		defer delete(f11)
		fmt.printf("  %s✗ Failed to generate report%s\n\n", f11, RESET)
	}
}
