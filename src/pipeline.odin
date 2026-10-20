package spotify_report

// The data pipeline (scan → load → compute → genres → report), decoupled from
// presentation: it only reports progress through `emit`. The TUI points emit at
// program_send from a worker thread; plain mode points it at a line printer.

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
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
	inputs:      []string, // a folder, a ZIP, or .json files
	data_dir:    string,   // where .shr/ lives; derived from the first input
	output_path: string,
	provider:    LLM_Provider,
	api_key:     string,
	model:       string,
	timezone:    string, // IANA name; empty means the default
	decay:       f64,    // memory decay for the behaviour scores; 0 means the default
	enrich:      bool,   // allow sending artist names to the LLM provider (off by default)
	noindex:     bool,   // inject robots noindex/nofollow meta tags into the report
}

emit: proc(msg: Msg) = proc(msg: Msg) {}

stage_msg :: proc(stage: Stage, state: Stage_State, detail: string, current := 0, total := 0) {
	emit(Stage_Msg{stage, state, current, total, detail})
}

// What the import found, shown to the user so a surprising report can be
// traced to its input.
Import_Summary :: struct {
	source:           string, // "folder", "ZIP" or "files"
	files_used:       int,    // streaming-history files that were read
	files_ignored:    int,    // other JSON in the package (playlists, searches, …)
	files_identical:  int,    // byte-for-byte copies of a file already read
	account_files:    int,    // one-year StreamingHistory*.json files (not supported)
	records:          int,    // rows in the used files
	non_music:        int,    // podcasts, audiobooks, video: no track or artist
	malformed:        int,    // rows whose timestamp could not be read
	overlap_dropped:  int,    // rows identical to one in a different file
	music_events:     int,    // rows with a track and artist, after the above
	short_listens:    int,    // music events under 30 s (not plays)
	plays:            int,    // qualifying plays (30 s or more)
	excluded:         int,    // music rows dropped by exclude_artists
	exclusions_unmatched: [dynamic]string, // exclude_artists names that matched no row
}

Load_Result :: struct {
	plays:   [dynamic]Play,
	tally:   Skip_Tally,
	summary: Import_Summary,
	err:     string, // set when the input is unusable
	hint:    string,
}

// Reads every history file into chronologically ordered plays, plus the skip
// tally covering the records that don't qualify. Files are recognised by what
// is in them, identical copies are read once, and a row that repeats one from a
// different file (overlapping exports) is dropped and counted. Repeats inside
// one file are kept: those can be real replays.
//
// Rows by an `exclude` artist are dropped here, before the tally, the sessions
// and the plays are built, so they leave no trace in any metric.
load_plays :: proc(entries: []Input_Entry, clock: ^Clock, progress: bool, exclude: []string = nil) -> (r: Load_Result, ok: bool) {
	exclude_hits: map[string]int // not temp: the pipeline frees temp between files
	defer delete(exclude_hits)
	for name in exclude do exclude_hits[name] = 0
	seen_files: map[u64]bool
	seen_rows: map[u64]int // row fingerprint → index of the file it first appeared in
	events: [dynamic]Session_Event // every music row, for sessions
	defer delete(events)
	defer { delete(seen_files); delete(seen_rows) }

	for e, fi in entries {
		data, rerr := read_input(e)
		if len(rerr) > 0 {
			r.err = fmt.aprintf("%s %s", e.name, rerr)
			r.hint = "Download the export again, or extract it and pass the folder."
			return r, false
		}
		fp := file_fingerprint(data)
		kind, records := classify_file(e.name, data)
		delete(data)

		switch kind {
		case .Other:
			r.summary.files_ignored += 1
			continue
		case .Account_History:
			r.summary.account_files += 1
			continue
		case .Damaged:
			r.err = fmt.aprintf("%s is not valid JSON", e.name)
			r.hint = "The file looks truncated. Download the export again."
			return r, false
		case .Streaming_History:
		}
		if fp in seen_files {
			r.summary.files_identical += 1
			delete(records)
			continue
		}
		seen_files[fp] = true
		r.summary.files_used += 1
		r.summary.records += len(records)

		for &rec in records {
			play, status := record_to_play(rec, clock)
			switch status {
			case .Not_A_Track:   r.summary.non_music += 1; continue
			case .Bad_Timestamp: r.summary.malformed += 1; continue
			case .Ok:
			}
			row := row_fingerprint(rec)
			if first, dup := seen_rows[row]; dup && first != fi {
				r.summary.overlap_dropped += 1
				continue
			}
			seen_rows[row] = fi
			if play.artist in exclude_hits {
				exclude_hits[play.artist] += 1
				r.summary.excluded += 1
				continue
			}
			r.summary.music_events += 1
			tally_record(&r.tally, play.year, play_key(play), play.skipped, play.ms)
			slot := -1
			if qualifies(play) {
				slot = len(r.plays)
				append(&r.plays, play)
			} else {
				r.summary.short_listens += 1
			}
			append(&events, Session_Event{play.unix, play.ms, slot})
		}
		delete(records)
		if progress do stage_msg(.Load, .Active, e.name, fi + 1, len(entries))
	}
	r.summary.plays = len(r.plays)
	for name in exclude { // listed order, so the report never depends on map order
		if exclude_hits[name] == 0 do append(&r.summary.exclusions_unmatched, name)
	}

	if r.summary.files_used == 0 {
		r.err, r.hint = no_history_message(entries, r.summary)
		return r, false
	}
	assign_sessions(events[:], r.plays[:]) // before sorting: slots index the load order
	if len(r.plays) == 0 {
		r.err = "No listening of 30 seconds or more in this export."
		r.hint = "Every music row ended before 30 seconds, so there is nothing to report on. Check that this is the complete Extended Streaming History."
		if r.summary.music_events == 0 do r.err, r.hint = "The streaming-history files contain no music listening.", "They only hold podcasts or other non-music rows, or no rows at all. Check that you downloaded the Extended Streaming History."
		if r.summary.excluded > 0 {
			r.err = "Nothing is left after exclude_artists."
			r.hint = fmt.aprintf("%s rows were removed by exclude_artists in .shr/overrides.json, and no other listening of 30 seconds or more remains. Check the names.", fmt_int(r.summary.excluded))
		}
		return r, false
	}
	sort_plays(r.plays[:])
	return r, true
}

// Identity of a row for overlap detection: when it ended, what it was and for
// how long. Two honest plays never share all of these.
row_fingerprint :: proc(rec: Streaming_Record) -> u64 {
	h := hash.fnv64a(transmute([]u8)rec.ts)
	h = hash.fnv64a(transmute([]u8)(rec.spotify_track_uri.? or_else (rec.master_metadata_track_name.? or_else "")), h)
	h = hash.fnv64a(transmute([]u8)(rec.master_metadata_album_artist_name.? or_else ""), h)
	ms := rec.ms_played
	return hash.fnv64a(mem.ptr_to_bytes(&ms), h)
}

// Explains why nothing usable was found, in terms of what the user can do.
no_history_message :: proc(entries: []Input_Entry, sum: Import_Summary) -> (err, hint: string) {
	if sum.account_files > 0 {
		return "This is your recent account history, not Extended Streaming History.",
			"The basic download only covers about the last year and has no track IDs. Request \"Extended streaming history\" at spotify.com/account/privacy (run --guide for steps), then use that ZIP."
	}
	for e in entries {
		base := e.name
		if strings.contains(base, "Streaming_History_") do return "The streaming-history files contain no listening records.",
			"They hold no rows at all. Download the Extended Streaming History again."
	}
	if len(entries) == 0 {
		return "No .json files found.", "Pass the ZIP Spotify emailed you, the folder you extracted it to, or the Streaming_History_Audio_*.json files. Run --guide for how to get it."
	}
	return "None of the JSON files is Spotify streaming history.",
		"Expected files named Streaming_History_Audio_*.json from the Extended Streaming History package. Run --guide for how to get it."
}

// Builds the identity table, applying `.shr/overrides.json` when present.
// Returns a message in `err` if the overrides file can't be used.
resolve_identities :: proc(plays: []Play, ov: Overrides, tally: ^Skip_Tally = nil) -> (table: Identity_Table, err: string) {
	ov := ov
	table = build_identity_table(plays, &ov)
	// One URI is one track, whatever spellings it carries (see Track_Key).
	canonicalize_uri_names(plays, table, tally)
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
	stage_msg(.Scan, .Active, input_label(o.inputs))
	scan := scan_inputs(o.inputs)
	if len(scan.err) > 0 {
		fail(.Scan, scan.err, scan.hint)
		return
	}
	o := o
	o.data_dir = scan.sidecar_dir
	stage_msg(.Scan, .Done, fmt.aprintf("%d JSON file%s", len(scan.entries), "" if len(scan.entries) == 1 else "s"))

	// ── Load ──
	// Overrides are read first: exclude_artists decides which rows are loaded.
	ov, ov_err := load_overrides(o.data_dir)
	if len(ov_err) > 0 {
		fail(.Load, ov_err, "Fix or remove .shr/overrides.json in your data directory, then run again.")
		return
	}
	clock := make_clock(o.timezone)
	stage_msg(.Load, .Active, "", 0, len(scan.entries))
	loaded, ok := load_plays(scan.entries[:], &clock, true, ov.exclude_artists[:])
	if !ok {
		fail(.Load, loaded.err, loaded.hint)
		return
	}
	defer skip_tally_destroy(&loaded.tally)
	all_plays := loaded.plays
	tally := &loaded.tally // not a copy: overrides replace its maps in place
	loaded.summary.source = input_kind(o.inputs)
	load_detail := fmt.aprintf("%s plays from %s · %s", fmt_int(len(all_plays)), import_files_text(loaded.summary), clock_label(clock))
	if note := import_notes_text(loaded.summary); len(note) > 0 do load_detail = fmt.aprintf("%s · %s", load_detail, note)
	stage_msg(.Load, .Done, load_detail, len(scan.entries), len(scan.entries))

	// ── Identity ──
	stage_msg(.Identity, .Active, "")
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
	stats.import_summary = loaded.summary
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
	can_enrich := o.enrich && o.provider != .None
	if len(artist_list) > 0 && can_enrich {
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
	if len(artist_list) > added do detail = fmt.aprintf("%s · %s unclassified", detail, fmt_int(len(artist_list) - added))
	if can_enrich && added == 0 && len(artist_list) > 0 && len(llm_last_error) > 0 {
		detail = fmt.aprintf("%s · the provider said: %s", detail, llm_last_error)
	}
	if len(artist_list) > 0 && !can_enrich {
		// Never a failure: the core report needs no genres, and Unclassified is a result.
		detail = fmt.aprintf("%s · enrichment off, nothing sent anywhere", detail)
	}
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

// ── Describing the input ─────────────────────────────────────────────────────

input_label :: proc(inputs: []string) -> string {
	if len(inputs) == 1 do return inputs[0]
	return fmt.aprintf("%d inputs", len(inputs))
}

input_kind :: proc(inputs: []string) -> string {
	if len(inputs) > 1 do return "files"
	if len(inputs) == 1 {
		if os.is_dir(inputs[0]) do return "folder"
		if is_zip_path(inputs[0]) do return "ZIP"
	}
	return "file"
}

import_files_text :: proc(s: Import_Summary) -> string {
	return fmt.aprintf("%d file%s", s.files_used, "" if s.files_used == 1 else "s")
}

// The surprising parts of an import, each as a short clause; empty when none.
// What exclude_artists did, including names that matched nothing (usually a typo).
exclusion_note :: proc(s: Import_Summary) -> string {
	parts: [dynamic]string
	if s.excluded > 0 do append(&parts, fmt.aprintf("%s rows excluded by exclude_artists", fmt_int(s.excluded)))
	if len(s.exclusions_unmatched) > 0 {
		append(&parts, fmt.aprintf("exclude_artists matched nothing for %s", strings.join(s.exclusions_unmatched[:], ", ", context.temp_allocator)))
	}
	return strings.join(parts[:], " · ")
}

import_notes_text :: proc(s: Import_Summary) -> string {
	parts: [dynamic]string
	if note := exclusion_note(s); len(note) > 0 do append(&parts, note)
	if s.short_listens > 0 do append(&parts, fmt.aprintf("%s short listens", fmt_int(s.short_listens)))
	if s.non_music > 0 do append(&parts, fmt.aprintf("%s non-music rows skipped", fmt_int(s.non_music)))
	if s.overlap_dropped > 0 do append(&parts, fmt.aprintf("%s rows repeated across files dropped", fmt_int(s.overlap_dropped)))
	if s.files_identical > 0 do append(&parts, fmt.aprintf("%d identical file%s ignored", s.files_identical, "" if s.files_identical == 1 else "s"))
	if s.malformed > 0 do append(&parts, fmt.aprintf("%s rows with unreadable timestamps skipped", fmt_int(s.malformed)))
	if s.files_ignored > 0 do append(&parts, fmt.aprintf("%d other JSON file%s ignored", s.files_ignored, "" if s.files_ignored == 1 else "s"))
	return strings.join(parts[:], " · ")
}
