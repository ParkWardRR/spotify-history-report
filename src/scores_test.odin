package spotify_report

import "core:fmt"
import "core:math"
import "core:testing"
import "core:time"

REF :: i64(1_700_000_000) // the last play in these fixtures

play_at :: proc(unix: i64, track, artist: string) -> Play {
	dt, _ := time.time_to_datetime(time.unix(unix, 0))
	ts := fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second)
	return mk_play(ts, track, artist)
}

days_ago :: proc(d: int, extra_seconds := 0) -> i64 {
	return REF - i64(d) * SECONDS_PER_DAY + i64(extra_seconds)
}

sorted :: proc(plays: [dynamic]Play) -> [dynamic]Play {
	sort_plays(plays[:])
	return plays
}

names :: proc(list: [dynamic]Track_Score) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	for s in list do append(&out, s.track)
	return out
}

has :: proc(list: [dynamic]Track_Score, track: string) -> bool {
	for s in list do if s.track == track do return true
	return false
}

// ── Activation ───────────────────────────────────────────────────────────────

@(test)
test_activation_matches_the_formula :: proc(t: ^testing.T) {
	times := [?]i64{REF - SECONDS_PER_DAY}
	got := activation_at(times[:], REF, 0.5)
	want := -0.5 * math.ln(1 + LAG_FLOOR_DAYS)
	testing.expectf(t, abs(got - want) < 1e-9, "got %v want %v", got, want)

	two := [?]i64{REF - 10 * SECONDS_PER_DAY, REF - SECONDS_PER_DAY}
	want2 := math.ln(math.pow(10 + LAG_FLOOR_DAYS, -0.5) + math.pow(1 + LAG_FLOOR_DAYS, -0.5))
	testing.expectf(t, abs(activation_at(two[:], REF, 0.5) - want2) < 1e-9, "two plays")

	testing.expect(t, activation_at(nil, REF, 0.5) < -1e8) // never heard
	late := [?]i64{REF + 5}
	testing.expect(t, activation_at(late[:], REF, 0.5) < -1e8) // plays after `at` don't count
}

@(test)
test_activation_prefers_recent_and_frequent :: proc(t: ^testing.T) {
	recent := [?]i64{REF - SECONDS_PER_DAY}
	old := [?]i64{REF - 200 * SECONDS_PER_DAY}
	testing.expect(t, activation_at(recent[:], REF, 0.5) > activation_at(old[:], REF, 0.5))

	once := [?]i64{REF - 5 * SECONDS_PER_DAY}
	thrice := [?]i64{REF - 7 * SECONDS_PER_DAY, REF - 6 * SECONDS_PER_DAY, REF - 5 * SECONDS_PER_DAY}
	testing.expect(t, activation_at(thrice[:], REF, 0.5) > activation_at(once[:], REF, 0.5))

	// A replay seconds ago stays finite thanks to the lag floor.
	instant := [?]i64{REF - 1}
	v := activation_at(instant[:], REF, 0.5)
	testing.expect(t, v > -1e8 && v < 10)
}

@(test)
test_decay_changes_how_much_history_matters :: proc(t: ^testing.T) {
	// Many old plays versus one recent play: a faster decay favours the recent one.
	many_old := make([dynamic]i64, context.temp_allocator)
	for i in 0 ..< 50 do append(&many_old, REF - i64(300 + i) * SECONDS_PER_DAY)
	one_new := [?]i64{REF - 2 * SECONDS_PER_DAY}
	slow := activation_at(many_old[:], REF, 0.2) - activation_at(one_new[:], REF, 0.2)
	fast := activation_at(many_old[:], REF, 1.0) - activation_at(one_new[:], REF, 1.0)
	testing.expect(t, slow > fast)
	testing.expect(t, slow > 0) // at slow decay the weight of history wins
	testing.expect(t, fast < 0) // at fast decay the recent play wins
}

// ── Views ────────────────────────────────────────────────────────────────────

@(test)
test_views_are_distinct_and_follow_their_definitions :: proc(t: ^testing.T) {
	plays := make([dynamic]Play, context.temp_allocator)
	// Fav: 12 plays, one every 40 days, ending now: sustained and still in rotation.
	for i in 0 ..< 12 do append(&plays, play_at(days_ago(40 * i), "Fav", "A"))
	// Hot: six plays within the last few hours of the history.
	for h in 1 ..= 6 do append(&plays, play_at(REF - i64(h) * 3600 - 7, "Hot", "B"))
	// Dormant: ten plays 20 days apart, ending 720 days ago.
	for i in 0 ..< 10 do append(&plays, play_at(days_ago(720 + 20 * i), "Dormant", "C"))
	// Earworm that faded: nine plays in one week 800 days ago. Not a favourite.
	for i in 0 ..< 9 do append(&plays, play_at(days_ago(800, i * 3 * 3600), "OldEarworm", "D"))
	// Burst: plenty of plays and still recent, but all within about two months.
	for i in 0 ..< 12 do append(&plays, play_at(days_ago(30 + i), "Burst", "G"))
	// One-off.
	append(&plays, play_at(days_ago(100), "OneOff", "E"))

	s := compute_scores(sorted(plays)[:])

	testing.expect(t, has(s.favourites, "Fav"))
	testing.expect(t, !has(s.favourites, "Hot"))        // one month only
	testing.expect(t, !has(s.favourites, "Dormant"))    // silent for two years
	testing.expect(t, !has(s.favourites, "OldEarworm"))
	testing.expect(t, !has(s.favourites, "Burst"))     // many plays but not sustained over months

	testing.expect_value(t, len(s.obsessions), 1)
	testing.expect(t, has(s.obsessions, "Hot"))
	testing.expect(t, !has(s.obsessions, "Fav"))        // only one play this fortnight

	testing.expect_value(t, len(s.rediscoveries), 1)
	testing.expect(t, has(s.rediscoveries, "Dormant"))
	testing.expect(t, !has(s.rediscoveries, "OldEarworm")) // a one-week burst isn't a favourite

	testing.expect(t, !has(s.warm, "OneOff"))           // fewer than WARM_MIN_PLAYS
	testing.expect(t, has(s.warm, "Hot"))
	testing.expect_value(t, s.warm[0].track, "Hot")     // recent AND frequent tops the memory ranking
}

@(test)
test_a_track_can_be_both_favourite_and_obsession :: proc(t: ^testing.T) {
	plays := make([dynamic]Play, context.temp_allocator)
	for i in 0 ..< 12 do append(&plays, play_at(days_ago(40 * i + 20), "Both", "A"))
	for h in 0 ..< 6 do append(&plays, play_at(REF - i64(h) * 600, "Both", "A"))
	s := compute_scores(sorted(plays)[:])
	testing.expect(t, has(s.favourites, "Both"))
	testing.expect(t, has(s.obsessions, "Both"))
}

@(test)
test_scores_are_measured_from_the_last_play_not_the_wall_clock :: proc(t: ^testing.T) {
	plays := make([dynamic]Play, context.temp_allocator)
	for h in 0 ..< 6 do append(&plays, play_at(REF - i64(h) * 600, "Hot", "A"))
	s := compute_scores(sorted(plays)[:])
	testing.expect_value(t, s.ref_unix, REF)
	testing.expect_value(t, len(s.obsessions), 1) // "recent" is relative to the export, however old it is
}

@(test)
test_session_openers_and_closers :: proc(t: ^testing.T) {
	plays := make([dynamic]Play, context.temp_allocator)
	for day in 0 ..< 8 {
		base := days_ago(day)
		append(&plays, play_at(base, "Start", "A"))
		append(&plays, play_at(base + 300, "Middle", "A"))
		append(&plays, play_at(base + 600, "End", "A"))
	}
	s := compute_scores(sorted(plays)[:])
	testing.expect_value(t, len(s.openers), 1)
	testing.expect_value(t, s.openers[0].track, "Start")
	testing.expect_value(t, s.openers[0].opener_rate, 1.0)
	testing.expect_value(t, len(s.closers), 1)
	testing.expect_value(t, s.closers[0].track, "End")
	testing.expect_value(t, s.closers[0].closer_rate, 1.0)
}

@(test)
test_scores_are_deterministic_and_handle_empty_input :: proc(t: ^testing.T) {
	testing.expect_value(t, len(compute_scores({}).warm), 0)

	plays := make([dynamic]Play, context.temp_allocator)
	for n in ([?]string{"Z", "Y", "X"}) { // identical scores: ties must break by name
		for i in 0 ..< 4 do append(&plays, play_at(days_ago(10 + i, int(n[0])), n, "A"))
	}
	a := compute_scores(sorted(plays)[:])
	b := compute_scores(sorted(plays)[:])
	testing.expect_value(t, len(a.warm), len(b.warm))
	for i in 0 ..< len(a.warm) do testing.expect_value(t, a.warm[i].track, b.warm[i].track)
}

// ── Held-out evaluation ──────────────────────────────────────────────────────

CUT :: REF + 1 - 30 * SECONDS_PER_DAY // what a single 30-day fold cuts at

find_row :: proc(ev: Evaluation, name: string) -> Ranker_Result {
	for r in ev.rows do if r.name == name do return r
	return {}
}

@(test)
test_recency_wins_when_old_favourites_were_dropped :: proc(t: ^testing.T) {
	plays := make([dynamic]Play, context.temp_allocator)
	for f in 0 ..< 5 { // played heavily long ago, never again
		for j in 0 ..< 100 do append(&plays, play_at(days_ago(340 + j, f * 60), fmt.tprintf("Old%d", f), "F"))
	}
	for r in 0 ..< 5 { // played lightly just before the cut, and replayed after it
		for d in ([?]int{45, 40, 35}) do append(&plays, play_at(days_ago(d, r * 60), fmt.tprintf("New%d", r), "R"))
		append(&plays, play_at(days_ago(5, r * 60), fmt.tprintf("New%d", r), "R"))
	}
	append(&plays, play_at(REF, "New0", "R"))

	ev := evaluate_rankers(sorted(plays)[:], folds = 1, horizon_days = 30, k = 5)
	testing.expect_value(t, ev.folds_used, 1)
	testing.expect_value(t, find_row(ev, "most recent").precision, 1.0)
	testing.expect_value(t, find_row(ev, "most played").precision, 0.0)
	testing.expectf(t, abs(ev.chance - 0.5) < 1e-9, "chance %v", ev.chance)
}

@(test)
test_frequency_wins_when_recent_tracks_are_one_offs :: proc(t: ^testing.T) {
	plays := make([dynamic]Play, context.temp_allocator)
	for f in 0 ..< 5 { // steady favourites, replayed after the cut
		for j in 0 ..< 60 do append(&plays, play_at(days_ago(31 + 5 * j, f * 60), fmt.tprintf("Fav%d", f), "F"))
		append(&plays, play_at(days_ago(3, f * 60), fmt.tprintf("Fav%d", f), "F"))
	}
	for n in 1 ..= 30 { // heard once just before the cut, never again
		append(&plays, play_at(days_ago(30) - i64(n) * 3600, fmt.tprintf("Noise%02d", n), "N"))
	}
	append(&plays, play_at(REF, "Fav0", "F"))

	ev := evaluate_rankers(sorted(plays)[:], folds = 1, horizon_days = 30, k = 5)
	testing.expect_value(t, ev.folds_used, 1)
	testing.expect_value(t, find_row(ev, "most played").precision, 1.0)
	testing.expect_value(t, find_row(ev, "most recent").precision, 0.0)
	// Whatever the activation rankers do, their numbers must be valid.
	for r in ev.rows {
		testing.expectf(t, r.precision >= 0 && r.precision <= 1 && r.ndcg >= 0 && r.ndcg <= 1.0000001, "%s: %v %v", r.name, r.precision, r.ndcg)
	}
}

@(test)
test_evaluation_declines_when_history_is_too_short :: proc(t: ^testing.T) {
	plays := make([dynamic]Play, context.temp_allocator)
	for i in 0 ..< 30 do append(&plays, play_at(days_ago(i), fmt.tprintf("T%d", i % 3), "A"))
	ev := evaluate_rankers(sorted(plays)[:], folds = 6, horizon_days = 30, k = 5)
	testing.expect_value(t, ev.folds_used, 0)
	testing.expect_value(t, len(evaluate_rankers({}).rows), len(RANKER_NAMES))
	// And the report says so instead of printing zeros as if they were results.
	text := scores_report_text(compute_scores(sorted(plays)[:]), ev)
	testing.expect(t, contains(text, "Not enough history"))
}

@(test)
test_sample_scores_are_sane :: proc(t: ^testing.T) {
	c := make_clock("UTC")
	plays, tally, _ := load_sample(&c)
	defer { delete(plays); skip_tally_destroy(&tally) }
	s := compute_scores(plays[:])
	testing.expect(t, len(s.warm) > 0)
	for i in 1 ..< len(s.warm) {
		testing.expect(t, s.warm[i - 1].activation >= s.warm[i].activation) // ranked best first
	}
	ev := evaluate_rankers(plays[:])
	testing.expect(t, ev.folds_used > 0)
	testing.expect(t, ev.chance > 0 && ev.chance <= 1)
}

@(test)
test_decay_hint_needs_a_clear_win_on_an_informative_test :: proc(t: ^testing.T) {
	make_ev :: proc(chance: f64, p: [4]f64) -> Evaluation {
		ev := Evaluation{folds_used = 6, chance = chance}
		append(&ev.rows, Ranker_Result{name = "most recent", precision = 0.9})
		for d, i in RANKER_DECAYS do append(&ev.rows, Ranker_Result{name = "act", decay = d, precision = p[i]})
		return ev
	}
	d, ok := suggest_decay(make_ev(0.2, {0.30, 0.40, 0.55, 0.50}), 0.5)
	testing.expect(t, ok)
	testing.expect_value(t, d, 0.8)

	_, ok = suggest_decay(make_ev(0.2, {0.30, 0.40, 0.43, 0.42}), 0.5) // within the margin
	testing.expect(t, !ok)
	_, ok = suggest_decay(make_ev(0.95, {0.30, 0.40, 0.90, 0.50}), 0.5) // uninformative test
	testing.expect(t, !ok)
	_, ok = suggest_decay(make_ev(0.2, {0.30, 0.60, 0.55, 0.50}), 0.5) // already the best
	testing.expect(t, !ok)
	_, ok = suggest_decay(make_ev(0.2, {0.30, 0.40, 0.55, 0.50}), 0.6) // current not among those tested
	testing.expect(t, !ok)
	_, ok = suggest_decay(Evaluation{}, 0.5)
	testing.expect(t, !ok)
}
