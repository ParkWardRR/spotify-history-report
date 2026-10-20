package spotify_report

import "core:testing"

// A row as the importer sees it: when it ended, how long it played.
ev :: proc(end: i64, ms: i64, slot: int) -> Session_Event { return Session_Event{end, ms, slot} }

blank_plays :: proc(n: int) -> []Play { return make([]Play, n, context.temp_allocator) }

@(test)
test_short_listens_do_not_split_a_session :: proc(t: ^testing.T) {
	// A ends 10:00; a 10 s skip ends 10:20; C (200 s) ends 10:50, so it started 10:46:40.
	// End to end A→C is 50 minutes, but the only real idle time is 26:40 on the 20 minute side.
	plays := blank_plays(2)
	events := []Session_Event{ev(36000, 200_000, 0), ev(37200, 10_000, -1), ev(39000, 200_000, 1)}
	assign_sessions(events, plays)
	testing.expect_value(t, plays[0].session, 1)
	testing.expect_value(t, plays[1].session, 1)
	testing.expect(t, plays[0].opens_session && !plays[1].opens_session)
	testing.expect(t, !plays[0].closes_session && plays[1].closes_session)
}

@(test)
test_idle_gap_is_measured_from_the_estimated_start :: proc(t: ^testing.T) {
	// B is a 20 minute track ending 35 minutes after A ended: by end times that is a
	// new session, but B started 15 minutes after A, so it is the same one.
	plays := blank_plays(2)
	assign_sessions([]Session_Event{ev(0, 100_000, 0), ev(2100, 1_200_000, 1)}, plays)
	testing.expect_value(t, plays[0].session, plays[1].session)

	// A genuine pause (45 minutes of nothing) still splits.
	plays2 := blank_plays(2)
	assign_sessions([]Session_Event{ev(0, 100_000, 0), ev(2900, 200_000, 1)}, plays2)
	testing.expect(t, plays2[0].session != plays2[1].session)
	testing.expect(t, plays2[1].opens_session && plays2[0].closes_session)
}

@(test)
test_session_of_only_short_listens_opens_nothing :: proc(t: ^testing.T) {
	plays := blank_plays(2)
	assign_sessions([]Session_Event{ev(0, 100_000, 0), ev(10_000, 5_000, -1), ev(10_020, 5_000, -1), ev(30_000, 100_000, 1)}, plays)
	testing.expect(t, plays[0].opens_session && plays[1].opens_session) // each is alone in its own session
	n := 0
	for p in plays do if p.opens_session do n += 1
	testing.expect_value(t, n, 2)
}

@(test)
test_unordered_events_and_overlaps_are_handled :: proc(t: ^testing.T) {
	// Two devices playing at once: the later row overlaps the earlier one.
	plays := blank_plays(3)
	assign_sessions([]Session_Event{ev(1000, 600_000, 1), ev(500, 400_000, 0), ev(1100, 100_000, 2)}, plays)
	testing.expect_value(t, plays[0].session, 1)
	testing.expect_value(t, plays[1].session, 1)
	testing.expect_value(t, plays[2].session, 1)
}

@(test)
test_openers_come_from_the_whole_stream :: proc(t: ^testing.T) {
	// X then a 12 s skip then Y: Y is NOT an opener; X is the only one. Under the old
	// rule (qualifying plays only, end-to-end gaps) Y would have opened a session.
	c := utc_clock()
	rec :: proc(ts, track: string, ms: i64) -> Streaming_Record {
		return Streaming_Record{ts = ts, ms_played = ms, master_metadata_track_name = track, master_metadata_album_artist_name = "Art"}
	}
	recs := []Streaming_Record{
		rec("2023-05-01T10:00:00Z", "X", 200_000),
		rec("2023-05-01T10:20:00Z", "skipped", 12_000),
		rec("2023-05-01T10:50:00Z", "Y", 200_000),
	}
	plays: [dynamic]Play
	events: [dynamic]Session_Event
	defer { delete(plays); delete(events) }
	for r in recs {
		p, _ := record_to_play(r, &c)
		slot := -1
		if qualifies(p) { slot = len(plays); append(&plays, p) }
		append(&events, Session_Event{p.unix, p.ms, slot})
	}
	assign_sessions(events[:], plays[:])
	s := compute_stats(plays[:])
	testing.expect_value(t, len(s.session_openers), 1)
	testing.expect_value(t, s.session_openers[0].track, "X")
}

@(test)
test_densest_window_matches_the_obvious_scan :: proc(t: ^testing.T) {
	naive :: proc(ords: []i64, days: i64) -> (best, idx: int) {
		for i in 0 ..< len(ords) {
			count := 0
			for j in i ..< len(ords) {
				if ords[j] - ords[i] < days { count += 1 } else { break }
			}
			if count > best { best = count; idx = i }
		}
		return
	}
	// A small deterministic generator; repeated days and long gaps both occur.
	state: u64 = 12345
	for round in 0 ..< 200 {
		n := 1 + round % 60
		ords := make([]i64, n, context.temp_allocator)
		day: i64 = 700_000
		for i in 0 ..< n {
			state = state * 6364136223846793005 + 1442695040888963407
			day += i64((state >> 33) % 5) if round % 3 != 0 else i64((state >> 33) % 12)
			ords[i] = day
		}
		wb, wi := densest_window(ords, 7)
		nb, ni := naive(ords, 7)
		testing.expect_value(t, wb, nb)
		testing.expect_value(t, wi, ni)
	}
	b, _ := densest_window(nil, 7)
	testing.expect_value(t, b, 0)
}

@(test)
test_largest_gap_names_the_quiet_stretch :: proc(t: ^testing.T) {
	s := stats_for(
		mk_play("2022-01-01T12:00:00Z", "A", "X"),
		mk_play("2022-01-03T12:00:00Z", "A", "X"),   // 1 empty day before
		mk_play("2022-03-05T12:00:00Z", "A", "X"),   // 60 empty days before (Jan 4 .. Mar 4)
		mk_play("2022-03-06T12:00:00Z", "A", "X"),
	)
	testing.expect_value(t, s.largest_gap.days, 60)
	testing.expect_value(t, s.largest_gap.from, "2022-01-03")
	testing.expect_value(t, s.largest_gap.to, "2022-03-05")
}
