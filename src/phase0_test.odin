package spotify_report

// Run from the repo root:
//   odin test src -define:ODIN_TEST_TRACK_MEMORY=false
// (the report code is a short-lived batch process and does not free its output,
// so the leak tracker is turned off.)

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// ── Helpers ──────────────────────────────────────────────────────────────────

utc_clock :: proc() -> Clock {
	return Clock{name = "UTC"}
}

mk_play :: proc(ts, track, artist: string, ms: i64 = 200000, skipped := false) -> Play {
	c := utc_clock()
	rec := Streaming_Record{
		ts = ts, ms_played = ms,
		master_metadata_track_name = track,
		master_metadata_album_artist_name = artist,
		skipped = skipped,
	}
	p, status := record_to_play(rec, &c)
	assert(status == .Ok, "fixture timestamp must parse")
	return p
}

resolver_for :: proc(artist, genre: string) -> Genre_Resolver {
	f := Annotation_File{schema_version = ANNOTATIONS_SCHEMA_VERSION}
	append(&f.annotations, Annotation{artist = artist, namespace = NS_GENRE, value = genre, source = "llm"})
	return build_genre_resolver(f, nil)
}

stats_for :: proc(plays: ..Play) -> Stats {
	list := make([dynamic]Play, context.temp_allocator)
	append(&list, ..plays)
	sort_plays(list[:])
	return compute_stats(list[:])
}

// ── Calendar ─────────────────────────────────────────────────────────────────

@(test)
test_weekdays_match_known_dates :: proc(t: ^testing.T) {
	c := utc_clock()
	// 0 = Monday … 6 = Sunday
	cases := [?]struct{ ts: string, want: int }{
		{"2020-01-01T12:00:00Z", 2}, // Wednesday
		{"2024-03-15T12:00:00Z", 4}, // Friday
		{"2021-01-03T12:00:00Z", 6}, // Sunday
		{"2000-02-29T12:00:00Z", 1}, // Tuesday
		{"2023-12-31T12:00:00Z", 6}, // Sunday
		{"2024-01-01T12:00:00Z", 0}, // Monday
	}
	for tc in cases {
		lt, ok := parse_ts(tc.ts, &c)
		testing.expect(t, ok, tc.ts)
		testing.expect_value(t, lt.weekday, tc.want)
	}
}

@(test)
test_ordinals_are_consecutive_across_boundaries :: proc(t: ^testing.T) {
	c := utc_clock()
	day :: proc(c: ^Clock, ts: string) -> i64 {
		lt, _ := parse_ts(ts, c)
		return lt.ordinal
	}
	// Year end: the old year*366+month*31+day scheme put Jan 1 *before* Dec 31.
	testing.expect_value(t, day(&c, "2021-01-01T12:00:00Z") - day(&c, "2020-12-31T12:00:00Z"), 1)
	// Month end: the old scheme saw Apr 30 → May 1 as two days apart.
	testing.expect_value(t, day(&c, "2020-05-01T12:00:00Z") - day(&c, "2020-04-30T12:00:00Z"), 1)
	// Leap years.
	testing.expect_value(t, day(&c, "2020-03-01T12:00:00Z") - day(&c, "2020-02-28T12:00:00Z"), 2)
	testing.expect_value(t, day(&c, "2021-03-01T12:00:00Z") - day(&c, "2021-02-28T12:00:00Z"), 1)
	testing.expect_value(t, day(&c, "1900-03-01T12:00:00Z") - day(&c, "1900-02-28T12:00:00Z"), 1) // not leap
	testing.expect_value(t, day(&c, "2000-03-01T12:00:00Z") - day(&c, "2000-02-28T12:00:00Z"), 2) // leap
}

@(test)
test_invalid_timestamps_are_rejected :: proc(t: ^testing.T) {
	c := utc_clock()
	bad := [?]string{
		"", "garbage", "2024-13-01T00:00:00Z", "2024-02-30T00:00:00Z", "2023-02-29T00:00:00Z",
		"2024-00-10T00:00:00Z", "2024-01-00T00:00:00Z", "2024-01-01T24:00:00Z", "2024-01-01T00:60:00Z",
		"2024-01-01T00:00:60Z", "20x4-01-01T00:00:00Z", "2024/01/01T00:00:00Z",
	}
	for ts in bad {
		_, ok := parse_ts(ts, &c)
		testing.expectf(t, !ok, "%q should not parse", ts)
	}
}

@(test)
test_timezone_follows_dst :: proc(t: ^testing.T) {
	c := make_clock("America/Los_Angeles")
	if c.fallback {
		testing.fail_now(t, "tzdata not installed: America/Los_Angeles could not be loaded")
	}
	at :: proc(c: ^Clock, ts: string) -> Local_Time {
		lt, ok := parse_ts(ts, c)
		assert(ok)
		return lt
	}

	// Spring forward 2024-03-10: 02:00 PST becomes 03:00 PDT at 10:00Z.
	before := at(&c, "2024-03-10T09:59:59Z")
	after := at(&c, "2024-03-10T10:00:00Z")
	testing.expect_value(t, before.hour, 1)
	testing.expect_value(t, after.hour, 3)
	testing.expect_value(t, before.ordinal, after.ordinal)
	testing.expect_value(t, after.unix - before.unix, 1) // gaps use UTC, so DST can't distort them

	// Fall back 2024-11-03: 02:00 PDT becomes 01:00 PST at 09:00Z (hour 1 repeats).
	first := at(&c, "2024-11-03T08:59:59Z")
	second := at(&c, "2024-11-03T09:00:00Z")
	testing.expect_value(t, first.hour, 1)
	testing.expect_value(t, second.hour, 1)
	testing.expect_value(t, second.unix - first.unix, 1)

	// Winter (UTC-8) and summer (UTC-7) offsets, and the day rolling back.
	winter := at(&c, "2024-01-01T05:00:00Z")
	testing.expect_value(t, winter.year, 2023)
	testing.expect_value(t, winter.month, 12)
	testing.expect_value(t, winter.day, 31)
	testing.expect_value(t, winter.hour, 21)
	testing.expect_value(t, winter.weekday, 6) // Sunday
	summer := at(&c, "2024-07-01T06:30:00Z")
	testing.expect_value(t, summer.month, 6)
	testing.expect_value(t, summer.day, 30)
	testing.expect_value(t, summer.hour, 23)
}

@(test)
test_unknown_timezone_falls_back_to_fixed_offset :: proc(t: ^testing.T) {
	for name in ([?]string{"Not/AZone", "../../etc/passwd", "bad name", "/abs"}) {
		c := make_clock(name)
		testing.expectf(t, c.fallback, "%q should fall back", name)
		lt, ok := parse_ts("2024-01-01T05:00:00Z", &c)
		testing.expect(t, ok)
		testing.expect_value(t, lt.hour, 21) // UTC-8
		testing.expect_value(t, lt.day, 31)
	}
	utc := make_clock("UTC")
	testing.expect(t, !utc.fallback)
	lt, _ := parse_ts("2024-01-01T05:00:00Z", &utc)
	testing.expect_value(t, lt.hour, 5)
}

// ── Streaks, sessions, earworms ──────────────────────────────────────────────

@(test)
test_streak_counts_across_year_and_month_ends :: proc(t: ^testing.T) {
	s := stats_for(
		mk_play("2020-12-30T12:00:00Z", "A", "X"),
		mk_play("2020-12-31T12:00:00Z", "A", "X"),
		mk_play("2021-01-01T12:00:00Z", "A", "X"),
		mk_play("2021-01-03T12:00:00Z", "A", "X"), // gap on the 2nd
	)
	testing.expect_value(t, s.longest_streak, 3)

	s = stats_for(
		mk_play("2020-04-30T12:00:00Z", "A", "X"),
		mk_play("2020-05-01T12:00:00Z", "A", "X"),
		mk_play("2020-05-02T12:00:00Z", "A", "X"),
	)
	testing.expect_value(t, s.longest_streak, 3)
}

@(test)
test_streak_edge_cases :: proc(t: ^testing.T) {
	testing.expect_value(t, compute_stats({}).longest_streak, 0)
	testing.expect_value(t, stats_for(mk_play("2020-06-01T12:00:00Z", "A", "X")).longest_streak, 1)
	// Several plays on one day are still one day.
	s := stats_for(
		mk_play("2020-06-01T10:00:00Z", "A", "X"),
		mk_play("2020-06-01T11:00:00Z", "B", "X"),
	)
	testing.expect_value(t, s.longest_streak, 1)
}

@(test)
test_sessions_split_on_gaps_not_on_calendar_boundaries :: proc(t: ^testing.T) {
	// 15 minutes apart across a month end and a year end: one session each.
	s := stats_for(
		mk_play("2020-04-30T23:50:00Z", "First", "X"),
		mk_play("2020-05-01T00:05:00Z", "Second", "X"),
		mk_play("2020-05-01T00:20:00Z", "Third", "X"),
	)
	testing.expect_value(t, len(s.session_openers), 1)
	testing.expect_value(t, s.session_openers[0].track, "First")

	s = stats_for(
		mk_play("2020-12-31T23:50:00Z", "First", "X"),
		mk_play("2021-01-01T00:05:00Z", "Second", "X"),
	)
	testing.expect_value(t, len(s.session_openers), 1)

	// More than 30 minutes apart starts a new session.
	s = stats_for(
		mk_play("2020-05-01T10:00:00Z", "First", "X"),
		mk_play("2020-05-01T10:31:00Z", "Second", "X"),
	)
	testing.expect_value(t, len(s.session_openers), 2)
}

@(test)
test_earworm_window_spans_year_end :: proc(t: ^testing.T) {
	s := stats_for(
		mk_play("2020-12-30T12:00:00Z", "Loop", "X"),
		mk_play("2020-12-31T12:00:00Z", "Loop", "X"),
		mk_play("2021-01-01T12:00:00Z", "Loop", "X"),
		mk_play("2021-01-02T12:00:00Z", "Loop", "X"),
		mk_play("2021-01-03T12:00:00Z", "Loop", "X"),
	)
	testing.expect_value(t, len(s.earworms), 1)
	testing.expect_value(t, s.earworms[0].plays, 5)
	testing.expect_value(t, s.earworms[0].period, "Dec 2020")
}

@(test)
test_earworm_window_is_seven_days :: proc(t: ^testing.T) {
	// Five plays over days 1,2,3,4,8: the 8th is outside a 7-day window from the 1st.
	s := stats_for(
		mk_play("2020-03-01T12:00:00Z", "Loop", "X"),
		mk_play("2020-03-02T12:00:00Z", "Loop", "X"),
		mk_play("2020-03-03T12:00:00Z", "Loop", "X"),
		mk_play("2020-03-04T12:00:00Z", "Loop", "X"),
		mk_play("2020-03-08T12:00:00Z", "Loop", "X"),
	)
	testing.expect_value(t, len(s.earworms), 0) // best window is 4 plays: below the 5 minimum
}

// ── Explore vs. obsess ───────────────────────────────────────────────────────

@(test)
test_explore_obsess_buckets_are_a_partition :: proc(t: ^testing.T) {
	plays := make([dynamic]Play, context.temp_allocator)
	// 2020: twelve established artists, descending hours.
	for i in 0..<12 {
		name := fmt.tprintf("artist%02d", i)
		append(&plays, mk_play("2020-06-01T12:00:00Z", "T", name, ms = i64(12 - i) * 600000))
	}
	// 2021: one artist that is new *and* an all-time top 10 by sheer volume, plus a small new one.
	append(&plays, mk_play("2021-06-01T12:00:00Z", "T", "newtop", ms = 90_000_000))
	append(&plays, mk_play("2021-06-02T12:00:00Z", "T", "newsmall", ms = 600000))
	append(&plays, mk_play("2021-06-03T12:00:00Z", "T", "artist11", ms = 600000))
	s := stats_for(..plays[:])

	var_2021: JSON_Explore
	for e in s.explore_obsess {
		testing.expect(t, e.new_pct >= 0 && e.top10_pct >= 0 && e.rest_pct >= 0)
		testing.expect_value(t, e.new_pct + e.top10_pct + e.rest_pct, 100)
		if e.year == 2021 do var_2021 = e
	}
	testing.expect_value(t, var_2021.year, 2021)
	testing.expect_value(t, var_2021.new_count, 2)       // both first heard in 2021
	testing.expect(t, var_2021.top10_pct > 90)           // the big new artist is top-10 only
	testing.expect(t, var_2021.new_pct < 5)              // so "new" is just newsmall's sliver
}

// ── Skips ────────────────────────────────────────────────────────────────────

@(test)
test_skip_rate_counts_short_plays :: proc(t: ^testing.T) {
	tally: Skip_Tally
	defer skip_tally_destroy(&tally)
	key := Track_Key{"A", "X"}
	tally_record(&tally, 2020, key, false)
	tally_record(&tally, 2020, key, false)
	tally_record(&tally, 2020, key, true)  // skipped flag
	tally_record(&tally, 2020, key, true)  // < 30s
	tally_record(&tally, 2021, key, false)

	list := [?]Play{mk_play("2020-01-01T12:00:00Z", "A", "X"), mk_play("2021-01-01T12:00:00Z", "A", "X")}
	s := compute_stats(list[:], &tally)
	testing.expect_value(t, s.skip_rate_first, 50)
	testing.expect_value(t, s.skip_rate_last, 0)
}

@(test)
test_is_skip_and_qualifies :: proc(t: ^testing.T) {
	testing.expect(t, is_skip(mk_play("2020-01-01T12:00:00Z", "A", "X", ms = 29999)))
	testing.expect(t, !is_skip(mk_play("2020-01-01T12:00:00Z", "A", "X", ms = 30000)))
	testing.expect(t, is_skip(mk_play("2020-01-01T12:00:00Z", "A", "X", ms = 200000, skipped = true)))
	testing.expect(t, !qualifies(mk_play("2020-01-01T12:00:00Z", "A", "X", ms = 29999)))
	testing.expect(t, qualifies(mk_play("2020-01-01T12:00:00Z", "A", "X", ms = 30000)))
}

@(test)
test_never_skipped_ignores_tracks_with_short_plays :: proc(t: ^testing.T) {
	plays := make([dynamic]Play, context.temp_allocator)
	for i in 0..<15 {
		append(&plays, mk_play(fmt.tprintf("2020-03-%02dT12:00:00Z", i + 1), "Song", "Art"))
	}
	without := compute_stats(plays[:])
	testing.expect_value(t, len(without.never_skipped), 1)

	tally: Skip_Tally
	defer skip_tally_destroy(&tally)
	tally_record(&tally, 2020, Track_Key{"Song", "Art"}, true) // a sub-30s play that was filtered out
	with_tally := compute_stats(plays[:], &tally)
	testing.expect_value(t, len(with_tally.never_skipped), 0)
}

// ── Determinism ──────────────────────────────────────────────────────────────

@(test)
test_ties_rank_the_same_regardless_of_encounter_order :: proc(t: ^testing.T) {
	a := stats_for(
		mk_play("2020-01-01T12:00:00Z", "TrackZ", "Zed"),
		mk_play("2020-01-02T12:00:00Z", "TrackA", "Abe"),
	)
	b := stats_for(
		mk_play("2020-01-01T12:00:00Z", "TrackA", "Abe"),
		mk_play("2020-01-02T12:00:00Z", "TrackZ", "Zed"),
	)
	for s in ([?]Stats{a, b}) {
		testing.expect_value(t, s.most_played_song.artist, "Abe")
		testing.expect_value(t, s.top_artists[0].name, "Abe")
		testing.expect_value(t, s.biggest_day.date, "2020-01-01")
	}
}

// ── Genre completeness ───────────────────────────────────────────────────────

@(test)
test_complete_final_year_is_kept :: proc(t: ^testing.T) {
	genres := resolver_for("X", "Rock")
	defer genre_resolver_destroy(&genres)
	list := [?]Play{
		mk_play("2020-01-01T12:00:00Z", "A", "X"),
		mk_play("2020-07-01T12:00:00Z", "A", "X"),
		mk_play("2020-12-31T12:00:00Z", "A", "X"),
	}
	s := compute_stats(list[:])
	testing.expect(t, !s.last_year_partial)
	compute_genre_stats(&s, list[:], &genres)
	testing.expect_value(t, len(s.genre_area), 3) // Q1, Q3, Q4 have plays; the final year is not dropped
	testing.expect_value(t, s.genre_area[len(s.genre_area) - 1].quarter, "2020-Q4")
	for q in s.genre_area do testing.expectf(t, !q.partial, "%s should be complete", q.quarter)
}

@(test)
test_partial_quarters_are_flagged_not_dropped :: proc(t: ^testing.T) {
	genres := resolver_for("X", "Rock")
	defer genre_resolver_destroy(&genres)
	list := [?]Play{
		mk_play("2020-02-10T12:00:00Z", "A", "X"), // history starts mid-Q1
		mk_play("2020-06-15T12:00:00Z", "A", "X"),
		mk_play("2021-02-10T12:00:00Z", "A", "X"), // and ends mid-Q1
	}
	s := compute_stats(list[:])
	compute_genre_stats(&s, list[:], &genres)
	testing.expect(t, s.last_year_partial)
	partial: map[string]bool
	defer delete(partial)
	for q in s.genre_area do partial[q.quarter] = q.partial
	testing.expect_value(t, partial["2020-Q1"], true)  // starts 10 Feb
	testing.expect_value(t, partial["2020-Q2"], false)
	testing.expect_value(t, partial["2021-Q1"], true)  // ends 10 Feb
}

@(test)
test_quarter_partial_boundaries :: proc(t: ^testing.T) {
	first := date_ordinal(2020, 1, 1)
	last := date_ordinal(2020, 12, 31)
	testing.expect(t, !quarter_partial("2020-Q1", first, last))
	testing.expect(t, !quarter_partial("2020-Q4", first, last))
	testing.expect(t, quarter_partial("2020-Q4", first, date_ordinal(2020, 12, 30)))
	testing.expect(t, quarter_partial("2020-Q1", date_ordinal(2020, 1, 2), last))
}

// ── Parsing ──────────────────────────────────────────────────────────────────

@(test)
test_parser_handles_podcast_nulls_unknown_fields_and_uri :: proc(t: ^testing.T) {
	src := `[
	  {"ts":"2024-03-15T18:32:01Z","ms_played":1000,"master_metadata_track_name":null,
	   "master_metadata_album_artist_name":null,"episode_name":"Pod","spotify_episode_uri":"spotify:episode:x","ip_addr":"1.2.3.4"},
	  {"ts":"2024-03-15T18:40:00Z","ms_played":234567,"master_metadata_track_name":"Song",
	   "master_metadata_album_artist_name":"Art","master_metadata_album_album_name":"Alb",
	   "spotify_track_uri":"spotify:track:abc","reason_start":"trackdone","reason_end":"fwdbtn",
	   "shuffle":true,"offline":false,"conn_country":"US","skipped":null,"platform":"iOS"},
	  {"ts":"2024-03-15T18:41:00Z","ms_played":5,"master_metadata_track_name":"S","master_metadata_album_artist_name":"A"}
	]`
	records: [dynamic]Streaming_Record
	defer delete(records)
	testing.expect(t, json.unmarshal(transmute([]u8)src, &records) == nil)
	testing.expect_value(t, len(records), 3)

	c := utc_clock()
	_, status := record_to_play(records[0], &c)
	testing.expect_value(t, status, Record_Status.Not_A_Track)

	p, st := record_to_play(records[1], &c)
	testing.expect_value(t, st, Record_Status.Ok)
	testing.expect_value(t, p.uri, "spotify:track:abc")
	testing.expect_value(t, p.reason_end, "fwdbtn")
	testing.expect_value(t, p.conn_country, "US")
	testing.expect_value(t, p.shuffle, true)
	testing.expect_value(t, p.offline, false)
	testing.expect_value(t, p.skipped, false)
	testing.expect_value(t, p.album, "Alb")

	// Only the required fields present: optional ones default cleanly.
	m, st2 := record_to_play(records[2], &c)
	testing.expect_value(t, st2, Record_Status.Ok)
	testing.expect_value(t, m.uri, "")
	testing.expect_value(t, m.album, "")
	testing.expect(t, !qualifies(m))
}

@(test)
test_record_with_bad_timestamp_is_reported :: proc(t: ^testing.T) {
	c := utc_clock()
	rec := Streaming_Record{ts = "yesterday", ms_played = 100000,
		master_metadata_track_name = "S", master_metadata_album_artist_name = "A"}
	_, status := record_to_play(rec, &c)
	testing.expect_value(t, status, Record_Status.Bad_Timestamp)
}

@(test)
test_load_records_rejects_missing_empty_and_malformed :: proc(t: ^testing.T) {
	_, ok := load_records("/nonexistent/nowhere.json")
	testing.expect(t, !ok)

	dir := os.temp_directory(context.temp_allocator) or_else "/tmp"
	empty := fmt.tprintf("%s/shr_test_empty.json", dir)
	bad := fmt.tprintf("%s/shr_test_bad.json", dir)
	_ = os.write_entire_file(empty, transmute([]u8)string("[]"))
	_ = os.write_entire_file(bad, transmute([]u8)string("[{\"ts\":"))
	defer { os.remove(empty); os.remove(bad) }

	recs, ok2 := load_records(empty)
	testing.expect(t, ok2)
	testing.expect_value(t, len(recs), 0)
	_, ok3 := load_records(bad)
	testing.expect(t, !ok3)
}

// ── End to end on the sample export ──────────────────────────────────────────

SAMPLE_DIR :: #directory + "../sample"

load_sample :: proc(c: ^Clock) -> (plays: [dynamic]Play, tally: Skip_Tally, bad: int) {
	files := find_json_files(SAMPLE_DIR)
	for path in files {
		records, ok := load_records(path)
		assert(ok)
		for &rec in records {
			p, status := record_to_play(rec, c)
			#partial switch status {
			case .Bad_Timestamp: bad += 1
			case .Ok:
				tally_record(&tally, p.year, play_key(p), is_skip(p))
				if qualifies(p) do append(&plays, p)
			}
		}
	}
	sort_plays(plays[:])
	return
}

@(test)
test_sample_report_is_reproducible_and_sane :: proc(t: ^testing.T) {
	c := make_clock("UTC")
	plays1, tally1, bad := load_sample(&c)
	plays2, tally2, _ := load_sample(&c)
	defer { delete(plays1); delete(plays2); skip_tally_destroy(&tally1); skip_tally_destroy(&tally2) }

	testing.expect_value(t, bad, 0)
	testing.expect(t, len(plays1) > 1000)
	for p in plays1 do if len(p.uri) == 0 || !strings.has_prefix(p.uri, "spotify:track:") {
		testing.fail_now(t, "every sample play should carry its spotify_track_uri")
	}

	s1 := compute_stats(plays1[:], &tally1)
	s2 := compute_stats(plays2[:], &tally2)
	s1.timezone, s2.timezone = "UTC", "UTC"
	j1, j2 := report_json(s1), report_json(s2)
	testing.expect(t, j1 == j2, "two runs over the same export must produce identical JSON")

	// Sanity: hours-by-year sums to the total (within per-year rounding), the
	// streak fits in the date span, and shares partition each year.
	sum := 0.0
	for yh in s1.hours_by_year do sum += yh.hours
	testing.expect(t, abs(sum - f64(s1.total_hours)) < f64(len(s1.hours_by_year)) + 1)
	testing.expect(t, i64(s1.longest_streak) <= s1.last_ordinal - s1.first_ordinal + 1)
	for e in s1.explore_obsess {
		testing.expect_value(t, e.new_pct + e.top10_pct + e.rest_pct, 100)
	}
}
