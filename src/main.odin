package spotify_report

import "core:fmt"
import "core:os"
import "core:strings"
import "core:slice"

main :: proc() {
	hide_cursor()
	defer show_cursor()

	clear_screen()
	draw_header()

	args := os.args

	// Check for --help or --setup first
	for a in args[1:] {
		if a == "--help" || a == "-h" {
			print_usage()
			return
		}
		if a == "--setup" {
			run_setup()
			return
		}
		if a == "--guide" {
			print_spotify_guide()
			return
		}
	}

	if len(args) < 2 {
		print_usage()
		return
	}

	data_dir := args[1]
	output_path := "spotify_report.html"

	// Parse flags
	cli_provider := ""
	cli_key := ""
	cli_model := ""

	i := 2
	for i < len(args) {
		a := args[i]
		switch {
		case a == "--output" || a == "-o":
			if i + 1 < len(args) { i += 1; output_path = args[i] }
		case a == "--openai-key":
			if i + 1 < len(args) { i += 1; cli_key = args[i]; cli_provider = "openai" }
		case a == "--anthropic-key":
			if i + 1 < len(args) { i += 1; cli_key = args[i]; cli_provider = "anthropic" }
		case a == "--openrouter-key":
			if i + 1 < len(args) { i += 1; cli_key = args[i]; cli_provider = "openrouter" }
		case a == "--model":
			if i + 1 < len(args) { i += 1; cli_model = args[i] }
		case !strings.has_prefix(a, "-"):
			output_path = a
		}
		i += 1
	}

	// Load config
	cfg := load_config()
	if len(cli_key) > 0 {
		switch cli_provider {
		case "openai":     cfg.openai_key = cli_key;     cfg.provider = "openai"
		case "anthropic":  cfg.anthropic_key = cli_key;  cfg.provider = "anthropic"
		case "openrouter": cfg.openrouter_key = cli_key; cfg.provider = "openrouter"
		}
	}
	if len(cli_model) > 0 {
		cfg.model = cli_model
	}

	provider, api_key, model := resolve_provider(cfg)

	// Find JSON files
	draw_section_header("Scanning")
	files := find_json_files(data_dir)
	if len(files) == 0 {
		f11 := fg(NORD11)
		defer delete(f11)
		fmt.printf("  %s✗ No Streaming_History_Audio_*.json found in %s%s\n", f11, data_dir, RESET)
		fmt.printf("\n  Run %s--guide%s to learn how to get your Spotify data export.\n\n", BOLD, RESET)
		return
	}
	f14 := fg(NORD14)
	defer delete(f14)
	fmt.printf("  %s%d%s files found\n", f14, len(files), RESET)

	// Load records
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

	slice.sort_by(all_plays[:], proc(a, b: Play) -> bool {
		return a.ts_raw < b.ts_raw
	})

	f8 := fg(NORD8)
	defer delete(f8)
	fmt.printf("  %s%d%s records, %s%d%s qualifying plays\n",
		f8, total_records, RESET,
		f14, len(all_plays), RESET)

	// Compute base stats
	draw_section_header("Computing")
	stats := compute_stats(all_plays[:])
	fmt.printf("  %sDone%s\n", f14, RESET)

	// Require an LLM provider
	if provider == .None {
		f11 := fg(NORD11)
		f3 := fg(NORD3)
		defer { delete(f11); delete(f3) }
		fmt.printf("\n  %s%s✗%s  No LLM API key found.\n", BOLD, f11, RESET)
		fmt.printf("  %sRun %s--setup%s%s to configure one, or pass %s--anthropic-key%s%s / %s--openai-key%s%s / %s--openrouter-key%s%s.\n",
			f3, BOLD, RESET, f3, BOLD, RESET, f3, BOLD, RESET, f3, BOLD, RESET, f3)
		fmt.printf("  %sYou can also set %sANTHROPIC_API_KEY%s%s, %sOPENAI_API_KEY%s%s, or %sOPENROUTER_API_KEY%s%s env vars.%s\n\n",
			f3, BOLD, RESET, f3, BOLD, RESET, f3, BOLD, RESET, f3, RESET)
		return
	}

	// Genre classification via LLM
	genre_map: map[string]string

	cached, has_cache := load_genre_cache(data_dir)
	if has_cache && len(cached) > 0 {
		genre_map = cached
		f7 := fg(NORD7)
		defer delete(f7)
		fmt.printf("\n  %s%s✓%s Loaded %s%d%s cached genre classifications\n",
			BOLD, f7, RESET, f7, len(genre_map), RESET)
	}

	artist_list: [dynamic]string
	defer delete(artist_list)
	for &a in stats.top_artists {
		append(&artist_list, a.name)
	}
	artist_set: map[string]bool
	defer delete(artist_set)
	for &a in stats.top_artists { artist_set[a.name] = true }
	for &p in all_plays {
		if p.artist not_in artist_set {
			artist_set[p.artist] = true
			append(&artist_list, p.artist)
		}
	}

	unclassified := 0
	for &a in artist_list {
		if a not_in genre_map do unclassified += 1
	}

	if unclassified > 0 {
		draw_section_header("Genre classification")
		f9 := fg(NORD9)
		defer delete(f9)
		fmt.printf("  %s%s%s → %s%d%s artists to classify via %s\n",
			f9, provider_name(provider), RESET,
			f14, unclassified, RESET,
			model)
		fmt.println()

		genre_map = classify_artists_llm(
			artist_list[:], provider, api_key, model, genre_map)

		save_genre_cache(data_dir, genre_map)
		fmt.printf("  %s✓%s Classified %s%d%s artists, cached to .genre_cache.json\n",
			f14, RESET, f14, len(genre_map), RESET)
	}

	compute_genre_stats(&stats, all_plays[:], genre_map)

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

	draw_stat_card("Genres mapped",  fmt.aprintf("%d artists (%.1f%% Other)", stats.genre_classified, stats.genre_other_pct), NORD7)

	// Top artists
	draw_section_header("Top artists")
	fmt.println()
	max_h: f64 = 0
	for &a in stats.top_artists {
		if a.hours > max_h do max_h = a.hours
	}
	nord_colors := [5]Nord{NORD8, NORD9, NORD7, NORD10, NORD15}
	for idx in 0..<min(10, len(stats.top_artists)) {
		draw_mini_bar(stats.top_artists[idx].name, stats.top_artists[idx].hours, max_h, nord_colors[idx % 5])
	}

	// Top albums
	draw_section_header("Top albums")
	fmt.println()
	for idx in 0..<min(5, len(stats.top_albums)) {
		a := stats.top_albums[idx]
		draw_list_item(idx + 1, a.album, a.artist, fmt.aprintf("%.1fh", a.hours), NORD7)
	}

	// Session openers
	if len(stats.session_openers) > 0 {
		draw_section_header("Session openers")
		fmt.println()
		for idx in 0..<min(5, len(stats.session_openers)) {
			s := stats.session_openers[idx]
			draw_list_item(idx + 1, s.track, s.artist, fmt.aprintf("%dx", s.count), NORD15)
		}
	}

	// Never skipped
	if len(stats.never_skipped) > 0 {
		draw_section_header("Never skipped")
		fmt.println()
		for idx in 0..<min(5, len(stats.never_skipped)) {
			s := stats.never_skipped[idx]
			draw_list_item(idx + 1, s.track, s.artist, fmt.aprintf("%d plays", s.plays), NORD14)
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

print_usage :: proc() {
	f4 := fg(NORD4)
	f8 := fg(NORD8)
	f3 := fg(NORD3)
	f9 := fg(NORD9)
	defer { delete(f4); delete(f8); delete(f3); delete(f9) }

	fmt.printf("  %sUsage:%s  spotify-history-report <data-dir> [options]\n\n", BOLD, RESET)

	fmt.printf("  %sArguments:%s\n", f9, RESET)
	fmt.printf("    %s<data-dir>%s              Directory with Streaming_History_Audio_*.json\n\n", f4, RESET)

	fmt.printf("  %sOptions:%s\n", f9, RESET)
	fmt.printf("    %s-o, --output <file>%s     Output HTML path %s(default: spotify_report.html)%s\n", f4, RESET, f3, RESET)
	fmt.printf("    %s--openai-key <key>%s      OpenAI API key for genre classification\n", f4, RESET)
	fmt.printf("    %s--anthropic-key <key>%s   Anthropic API key %s(Claude)%s\n", f4, RESET, f3, RESET)
	fmt.printf("    %s--openrouter-key <key>%s  OpenRouter API key %s(any model)%s\n", f4, RESET, f3, RESET)
	fmt.printf("    %s--model <model>%s         Override the LLM model\n", f4, RESET)
	fmt.printf("    %s--setup%s                 Interactive config setup %s(saves to ~/.config)%s\n", f4, RESET, f3, RESET)
	fmt.printf("    %s--guide%s                 How to get your Spotify data export\n\n", f4, RESET)

	fmt.printf("  %sEnvironment variables:%s\n", f9, RESET)
	fmt.printf("    %sOPENAI_API_KEY%s          OpenAI key %s(overrides config)%s\n", f4, RESET, f3, RESET)
	fmt.printf("    %sANTHROPIC_API_KEY%s       Anthropic key %s(overrides config)%s\n", f4, RESET, f3, RESET)
	fmt.printf("    %sOPENROUTER_API_KEY%s      OpenRouter key %s(overrides config)%s\n\n", f4, RESET, f3, RESET)

	fmt.printf("  %sExamples:%s\n", f9, RESET)
	fmt.printf("    %s$%s spotify-history-report ~/Downloads/spotify_data/\n", f3, RESET)
	fmt.printf("    %s$%s spotify-history-report ./data --anthropic-key sk-ant-... -o report.html\n", f3, RESET)
	fmt.printf("    %s$%s OPENAI_API_KEY=sk-... spotify-history-report ./data\n\n", f3, RESET)
}

print_spotify_guide :: proc() {
	f4 := fg(NORD4)
	f8 := fg(NORD8)
	f9 := fg(NORD9)
	f14 := fg(NORD14)
	f3 := fg(NORD3)
	f13 := fg(NORD13)
	defer { delete(f4); delete(f8); delete(f9); delete(f14); delete(f3); delete(f13) }

	draw_section_header("How to get your Spotify data")
	fmt.println()
	fmt.printf("  %s%s1.%s Open %shttps://www.spotify.com/account/privacy/%s\n", BOLD, f8, RESET, f4, RESET)
	fmt.printf("     %sLog in → scroll to \"Download your data\"%s\n\n", f3, RESET)

	fmt.printf("  %s%s2.%s Request your %s\"Extended streaming history\"%s\n", BOLD, f8, RESET, f14, RESET)
	fmt.printf("     %sNot the basic \"Account data\" — you need the Extended version.%s\n", f3, RESET)
	fmt.printf("     %sIt includes every stream with timestamps and durations.%s\n\n", f3, RESET)

	fmt.printf("  %s%s3.%s Wait for the email %s(usually 5-30 days)%s\n", BOLD, f8, RESET, f13, RESET)
	fmt.printf("     %sSpotify prepares the export and emails you a download link.%s\n\n", f3, RESET)

	fmt.printf("  %s%s4.%s Download and unzip\n", BOLD, f8, RESET)
	fmt.printf("     %sYou'll get files named %sStreaming_History_Audio_2019-2024.json%s%s etc.%s\n\n", f3, f4, RESET, f3, RESET)

	fmt.printf("  %s%s5.%s Point this tool at the folder\n", BOLD, f8, RESET)
	fmt.printf("     %s$%s spotify-history-report ~/Downloads/my_spotify_data/\n\n", f3, RESET)

	draw_separator()
	fmt.printf("\n  %sWhat's in the data?%s\n\n", f9, RESET)
	fmt.printf("  Each JSON file contains an array of streaming records:\n\n")
	fmt.printf("  %s{%s\n", f3, RESET)
	fmt.printf("    %s\"ts\"%s: \"2024-03-15T18:32:01Z\",\n", f8, RESET)
	fmt.printf("    %s\"ms_played\"%s: 234567,\n", f8, RESET)
	fmt.printf("    %s\"master_metadata_track_name\"%s: \"Song Title\",\n", f8, RESET)
	fmt.printf("    %s\"master_metadata_album_artist_name\"%s: \"Artist\",\n", f8, RESET)
	fmt.printf("    %s\"master_metadata_album_album_name\"%s: \"Album\",\n", f8, RESET)
	fmt.printf("    %s\"platform\"%s: \"OS X 15.2.0\",\n", f8, RESET)
	fmt.printf("    %s\"skipped\"%s: false\n", f8, RESET)
	fmt.printf("  %s}%s\n\n", f3, RESET)

	fmt.printf("  A play counts as \"qualifying\" if %sms_played >= 30,000%s (30 seconds)\n", f4, RESET)
	fmt.printf("  and both track name and artist name are present.\n\n")
}

run_setup :: proc() {
	f4 := fg(NORD4)
	f8 := fg(NORD8)
	f9 := fg(NORD9)
	f14 := fg(NORD14)
	f3 := fg(NORD3)
	f13 := fg(NORD13)
	defer { delete(f4); delete(f8); delete(f9); delete(f14); delete(f3); delete(f13) }

	show_cursor()

	cfg := load_config()

	draw_section_header("API key setup")
	fmt.println()
	fmt.printf("  The genre chart needs an LLM to classify your artists.\n")
	fmt.printf("  Pick a provider and paste your API key. It's saved to:\n")
	fmt.printf("  %s%s%s\n\n", f3, config_path(), RESET)

	fmt.printf("  %sProviders:%s\n", f9, RESET)
	fmt.printf("    %s1.%s %sAnthropic%s  %s(Claude — recommended)%s\n", f8, RESET, f4, RESET, f3, RESET)
	fmt.printf("       %shttps://console.anthropic.com/settings/keys%s\n", DIM, RESET)
	fmt.printf("    %s2.%s %sOpenAI%s     %s(GPT-4o-mini — cheap and fast)%s\n", f8, RESET, f4, RESET, f3, RESET)
	fmt.printf("       %shttps://platform.openai.com/api-keys%s\n", DIM, RESET)
	fmt.printf("    %s3.%s %sOpenRouter%s  %s(any model — one key, many providers)%s\n", f8, RESET, f4, RESET, f3, RESET)
	fmt.printf("       %shttps://openrouter.ai/keys%s\n\n", DIM, RESET)

	fmt.printf("  %sEnter provider (1/2/3): %s", f4, RESET)
	choice_buf: [16]u8
	n, _ := os.read(os.stdin, choice_buf[:])
	choice := strings.trim_space(string(choice_buf[:n]))

	provider_name_str := ""
	switch choice {
	case "1": cfg.provider = "anthropic";  provider_name_str = "Anthropic"
	case "2": cfg.provider = "openai";     provider_name_str = "OpenAI"
	case "3": cfg.provider = "openrouter"; provider_name_str = "OpenRouter"
	case:
		fmt.printf("  %sInvalid choice.%s\n\n", fg(NORD11), RESET)
		return
	}

	fmt.printf("  %sEnter %s API key: %s", f4, provider_name_str, RESET)
	key_buf: [256]u8
	kn, _ := os.read(os.stdin, key_buf[:])
	key := strings.trim_space(string(key_buf[:kn]))

	if len(key) < 5 {
		fmt.printf("  %sKey too short, aborting.%s\n\n", fg(NORD11), RESET)
		return
	}

	switch cfg.provider {
	case "anthropic":  cfg.anthropic_key = key
	case "openai":     cfg.openai_key = key
	case "openrouter": cfg.openrouter_key = key
	}

	fmt.printf("  %sModel override (Enter for default): %s", f4, RESET)
	model_buf: [128]u8
	mn, _ := os.read(os.stdin, model_buf[:])
	model_str := strings.trim_space(string(model_buf[:mn]))
	if len(model_str) > 0 {
		cfg.model = model_str
	}

	if save_config(cfg) {
		fmt.printf("\n  %s%s✓%s Config saved to %s%s%s\n\n", BOLD, f14, RESET, f3, config_path(), RESET)
		fmt.printf("  Now run: %sspotify-history-report <data-dir>%s\n\n", f4, RESET)
	} else {
		fmt.printf("\n  %s✗ Failed to save config%s\n\n", fg(NORD11), RESET)
	}

	hide_cursor()
}
