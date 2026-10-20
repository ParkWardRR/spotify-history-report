package spotify_report

// The data pipeline (scan → load → compute → genres → report), decoupled from
// presentation: it only reports progress through `emit`. The TUI points emit at
// program_send from a worker thread; plain mode points it at a line printer.

import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

Stage :: enum {
	Scan,
	Load,
	Compute,
	Genres,
	Report,
}

STAGE_TITLES := [Stage]string{
	.Scan    = "Scan",
	.Load    = "Load",
	.Compute = "Compute",
	.Genres  = "Genres",
	.Report  = "Report",
}

Stage_State :: enum {
	Pending,
	Active,
	Done,
	Failed,
}

Stage_Msg :: struct {
	stage:   Stage,
	state:   Stage_State,
	current: int,
	total:   int,
	detail:  string,
}

Done_Msg :: struct {
	ok:         bool,
	stats:      ^Stats,
	path:       string,
	err_title:  string,
	err_hint:   string,
	elapsed_ms: int,
}

Run_Opts :: struct {
	data_dir:    string,
	output_path: string,
	provider:    LLM_Provider,
	api_key:     string,
	model:       string,
	timezone:    string, // IANA name; empty means the default
}

emit: proc(msg: Msg) = proc(msg: Msg) {}

stage_msg :: proc(stage: Stage, state: Stage_State, detail: string, current := 0, total := 0) {
	emit(Stage_Msg{stage, state, current, total, detail})
}

pipeline_thread_proc :: proc(data: rawptr) {
	opts := (^Run_Opts)(data)^
	run_pipeline(opts)
}

run_pipeline :: proc(o: Run_Opts) {
	t0 := time.tick_now()

	fail :: proc(stage: Stage, title, hint: string) {
		stage_msg(stage, .Failed, title)
		emit(Done_Msg{ok = false, err_title = title, err_hint = hint})
	}

	// ── Scan ──
	stage_msg(.Scan, .Active, o.data_dir)
	files := find_json_files(o.data_dir)
	if len(files) == 0 {
		fail(.Scan,
			fmt.aprintf("No Streaming_History_Audio_*.json found in %s", o.data_dir),
			"Run with --guide to learn how to get your Spotify data export.")
		return
	}
	stage_msg(.Scan, .Done, fmt.aprintf("%d file%s", len(files), "" if len(files) == 1 else "s"))

	// Fail fast before the slow part: genre classification needs an LLM.
	if o.provider == .None {
		fail(.Genres, "No LLM API key found",
			"Run --setup to configure one, pass --anthropic-key / --openai-key / --openrouter-key, or set ANTHROPIC_API_KEY / OPENAI_API_KEY / OPENROUTER_API_KEY.")
		return
	}

	// ── Load ──
	clock := make_clock(o.timezone)
	all_plays: [dynamic]Play
	tally: Skip_Tally
	defer skip_tally_destroy(&tally)
	total_records := 0
	bad_timestamps := 0
	stage_msg(.Load, .Active, "", 0, len(files))
	for path, fi in files {
		records, ok := load_records(path)
		if !ok {
			fail(.Load, fmt.aprintf("Failed to parse %s", path), "The file is not valid Streaming_History JSON.")
			return
		}
		total_records += len(records)

		for &rec in records {
			play, status := record_to_play(rec, &clock)
			switch status {
			case .Not_A_Track:   continue
			case .Bad_Timestamp: bad_timestamps += 1; continue
			case .Ok:
			}
			tally_record(&tally, play.year, play_key(play), is_skip(play))
			if qualifies(play) do append(&all_plays, play)
		}
		delete(records)
		stage_msg(.Load, .Active, filepath.base(path), fi + 1, len(files))
	}
	sort_plays(all_plays[:])
	load_detail := fmt.aprintf("%s records · %s qualifying plays · %s",
		fmt_int(total_records), fmt_int(len(all_plays)), clock_label(clock))
	if bad_timestamps > 0 {
		load_detail = fmt.aprintf("%s · %s unreadable timestamps skipped", load_detail, fmt_int(bad_timestamps))
	}
	stage_msg(.Load, .Done, load_detail, len(files), len(files))

	// ── Compute ──
	stage_msg(.Compute, .Active, "")
	stats := new(Stats)
	stats^ = compute_stats(all_plays[:], &tally)
	stats.timezone = clock_label(clock)
	stage_msg(.Compute, .Done, fmt.aprintf("%s artists · %s tracks",
		fmt_int(stats.unique_artists), fmt_int(stats.unique_tracks)))

	// ── Genres ──
	genre_map: map[string]string
	cached, has_cache := load_genre_cache(o.data_dir)
	if has_cache && len(cached) > 0 do genre_map = cached

	artist_list: [dynamic]string
	artist_set: map[string]bool
	for &a in stats.top_artists {
		append(&artist_list, a.name)
		artist_set[a.name] = true
	}
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
		stage_msg(.Genres, .Active,
			fmt.aprintf("%s · %s", provider_name(o.provider), o.model),
			0, (unclassified + BATCH_SIZE - 1) / BATCH_SIZE)
		genre_map = classify_artists_llm(artist_list[:], o.provider, o.api_key, o.model, genre_map)
		save_genre_cache(o.data_dir, genre_map)
		stage_msg(.Genres, .Done, fmt.aprintf("%s artists classified via %s",
			fmt_int(unclassified), provider_name(o.provider)))
	} else {
		stage_msg(.Genres, .Done, fmt.aprintf("%s artists (cached)", fmt_int(len(genre_map))))
	}
	compute_genre_stats(stats, all_plays[:], genre_map)

	// ── Report ──
	stage_msg(.Report, .Active, o.output_path)
	if !generate_report(stats^, o.output_path) {
		fail(.Report, fmt.aprintf("Failed to write %s", o.output_path), "Check that the output directory exists and is writable.")
		return
	}
	stage_msg(.Report, .Done, o.output_path)

	emit(Done_Msg{
		ok = true,
		stats = stats,
		path = o.output_path,
		elapsed_ms = int(time.duration_milliseconds(time.tick_since(t0))),
	})
}

// ── Plain (non-TUI) progress ─────────────────────────────────────────────────

plain_failed := false

plain_emit :: proc(msg: Msg) {
	#partial switch m in msg {
	case Done_Msg:
		if m.ok {
			fmt.println()
			fmt.println(summary_text(m.stats, m.path, m.elapsed_ms))
		} else {
			plain_failed = true
			fmt.printf("\n    %s\n", muted(m.err_hint))
		}
	case Stage_Msg:
		switch m.state {
		case .Pending, .Active:
			// In plain mode only report batch progress for long LLM runs.
			if m.stage == .Genres && m.total > 0 {
				fmt.printf("  %s %s\n", muted("…"), muted(fmt.tprintf("Genres  batch %d/%d", m.current, m.total)))
			}
		case .Done:
			fmt.printf("  %s %s  %s\n", fgs(COL_OK, "✓", true), pad_right(STAGE_TITLES[m.stage], 8), muted(m.detail))
		case .Failed:
			fmt.printf("  %s %s  %s\n", fgs(COL_ERR, "✗", true), pad_right(STAGE_TITLES[m.stage], 8), fgs(COL_ERR, m.detail))
		}
		free_all(context.temp_allocator)
	}
}
