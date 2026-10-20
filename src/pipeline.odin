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
	Identity,
	Compute,
	Genres,
	Report,
}

STAGE_TITLES := [Stage]string{
	.Scan     = "Scan",
	.Load     = "Load",
	.Identity = "Identity",
	.Compute  = "Compute",
	.Genres   = "Genres",
	.Report   = "Report",
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
	decay:       f64,    // memory decay for the behaviour scores; 0 means the default
	noindex:     bool,   // inject robots noindex/nofollow meta tags into the report
}

emit: proc(msg: Msg) = proc(msg: Msg) {}

stage_msg :: proc(stage: Stage, state: Stage_State, detail: string, current := 0, total := 0) {
	emit(Stage_Msg{stage, state, current, total, detail})
}

Load_Result :: struct {
	plays:          [dynamic]Play,
	tally:          Skip_Tally,
	total_records:  int,
	bad_timestamps: int,
	failed_path:    string, // set when a file could not be parsed
}

// Reads every export file into chronologically ordered plays, plus the skip
// tally covering the records that don't qualify.
load_plays :: proc(files: []string, clock: ^Clock, progress: bool) -> (r: Load_Result, ok: bool) {
	for path, fi in files {
		records, loaded := load_records(path)
		if !loaded {
			r.failed_path = path
			return r, false
		}
		r.total_records += len(records)

		for &rec in records {
			play, status := record_to_play(rec, clock)
			switch status {
			case .Not_A_Track:   continue
			case .Bad_Timestamp: r.bad_timestamps += 1; continue
			case .Ok:
			}
			tally_record(&r.tally, play.year, play_key(play), is_skip(play))
			if qualifies(play) do append(&r.plays, play)
		}
		delete(records)
		if progress do stage_msg(.Load, .Active, filepath.base(path), fi + 1, len(files))
	}
	sort_plays(r.plays[:])
	return r, true
}

// Builds the identity table, applying `.shr/overrides.json` when present.
// Returns a message in `err` if the overrides file can't be used.
resolve_identities :: proc(plays: []Play, ov: Overrides, tally: ^Skip_Tally = nil) -> (table: Identity_Table, err: string) {
	ov := ov
	table = build_identity_table(plays, &ov)
	if len(ov.merges) == 0 do return

	changed, apply_err := apply_overrides(plays, ov, table, tally)
	if len(apply_err) > 0 do return {}, fmt.aprintf("overrides.json: %s", apply_err)
	table = build_identity_table(plays, &ov) // names changed, so rebuild
	table.summary.merges_applied = len(ov.merges)
	table.summary.plays_remapped = changed
	return
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

	// ── Load ──
	clock := make_clock(o.timezone)
	stage_msg(.Load, .Active, "", 0, len(files))
	loaded, ok := load_plays(files[:], &clock, true)
	if !ok {
		fail(.Load, fmt.aprintf("Failed to parse %s", loaded.failed_path), "The file is not valid Streaming_History JSON.")
		return
	}
	defer skip_tally_destroy(&loaded.tally)
	all_plays := loaded.plays
	tally := &loaded.tally // not a copy: overrides replace its maps in place
	load_detail := fmt.aprintf("%s records · %s qualifying plays · %s",
		fmt_int(loaded.total_records), fmt_int(len(all_plays)), clock_label(clock))
	if loaded.bad_timestamps > 0 {
		load_detail = fmt.aprintf("%s · %s unreadable timestamps skipped", load_detail, fmt_int(loaded.bad_timestamps))
	}
	stage_msg(.Load, .Done, load_detail, len(files), len(files))

	// ── Identity ──
	stage_msg(.Identity, .Active, "")
	ov, ov_err := load_overrides(o.data_dir)
	if len(ov_err) > 0 {
		fail(.Identity, ov_err, "Fix or remove .shr/overrides.json in your data directory, then run again.")
		return
	}
	table, id_err := resolve_identities(all_plays[:], ov, tally)
	if len(id_err) > 0 {
		fail(.Identity, fmt.aprintf("overrides.json: %s", id_err), "Fix or remove .shr/overrides.json in your data directory, then run again.")
		return
	}
	saved := save_identities(o.data_dir, table)
	id_detail := fmt.aprintf("%s of plays matched to a Spotify URI · %s songs",
		fmt.aprintf("%.0f%%", pct(table.summary.plays_by_uri, table.summary.plays)), fmt_int(table.summary.songs))
	if table.summary.near_duplicate_groups > 0 {
		id_detail = fmt.aprintf("%s · %d to review", id_detail, table.summary.near_duplicate_groups)
	}
	if !saved do id_detail = fmt.aprintf("%s · cache not saved", id_detail)
	stage_msg(.Identity, .Done, id_detail)

	// ── Compute ──
	stage_msg(.Compute, .Active, "")
	stats := new(Stats)
	stats^ = compute_stats(all_plays[:], tally)
	stats.timezone = clock_label(clock)
	stats.scores = compute_scores(all_plays[:], o.decay if o.decay > 0 else DEFAULT_DECAY)
	stats.identity = table.summary
	for c, i in table.candidates {
		if i >= 10 do break
		append(&stats.identity_candidates, c)
	}
	stage_msg(.Compute, .Done, fmt.aprintf("%s artists · %s tracks",
		fmt_int(stats.unique_artists), fmt_int(stats.unique_tracks)))

	// ── Genres ──
	store, store_info, store_err := load_annotations(o.data_dir)
	if len(store_err) > 0 {
		fail(.Genres, store_err, "Nothing was changed. Repair .shr/annotations.json, or move it aside to rebuild from .genre_cache.json.")
		return
	}
	resolver := build_genre_resolver(store, ov.annotations[:])

	// Artists nobody has classified yet, most-listened first.
	artist_list: [dynamic]string
	seen: map[string]bool
	for &a in stats.top_artists {
		seen[a.name] = true
		if !has_artist_genre(&resolver, a.name) do append(&artist_list, a.name)
	}
	for &p in all_plays {
		if p.artist in seen do continue
		seen[p.artist] = true
		if !has_artist_genre(&resolver, p.artist) do append(&artist_list, p.artist)
	}

	existing := len(resolver.by_artist)
	added := 0
	dirty := store_info.migrated // a legacy cache was imported and should be saved
	if len(artist_list) > 0 {
		if o.provider == .None {
			fail(.Genres, fmt.aprintf("%s artists have no genre and no LLM API key is set", fmt_int(len(artist_list))),
				"Run --setup to configure a key, pass --anthropic-key / --openai-key / --openrouter-key, or set ANTHROPIC_API_KEY / OPENAI_API_KEY / OPENROUTER_API_KEY. Or classify them yourself in .shr/overrides.json (run --annotations to see which).")
			return
		}
		stage_msg(.Genres, .Active,
			fmt.aprintf("%s · %s", provider_name(o.provider), o.model),
			0, (len(artist_list) + BATCH_SIZE - 1) / BATCH_SIZE)
		answers := classify_artists_llm(artist_list[:], o.provider, o.api_key, o.model, nil)
		added, _ = add_llm_annotations(&store, answers, artist_list[:], o.model, today_string())
		dirty = true
		genre_resolver_destroy(&resolver)
		resolver = build_genre_resolver(store, ov.annotations[:])
	}
	saved_store := true
	if dirty do saved_store = save_annotations(o.data_dir, store)

	detail := fmt.aprintf("%s artists annotated", fmt_int(len(resolver.by_artist)))
	if existing > 0 && added == 0 do detail = fmt.aprintf("%s artists annotated (stored)", fmt_int(existing))
	if added > 0 do detail = fmt.aprintf("%s from storage · %s new via %s", fmt_int(existing), fmt_int(added), provider_name(o.provider))
	if len(artist_list) > added do detail = fmt.aprintf("%s · %d still unclassified", detail, len(artist_list) - added)
	if store_info.migrated && len(store.migrated_from) > 0 do detail = fmt.aprintf("%s · imported %s", detail, store.migrated_from)
	if resolver.user_artists + resolver.user_tracks > 0 {
		detail = fmt.aprintf("%s · %d of yours", detail, resolver.user_artists + resolver.user_tracks)
	}
	if !saved_store do detail = fmt.aprintf("%s · not saved", detail)
	stage_msg(.Genres, .Done, detail)
	compute_genre_stats(stats, all_plays[:], &resolver)

	// ── Report ──
	stage_msg(.Report, .Active, o.output_path)
	if !generate_report(stats^, o.output_path, o.noindex) {
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
