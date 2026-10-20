package spotify_report

// Listening-behaviour scores (ROADMAP Phase 3). Interpretable models over the
// play history only: no audio, no network, no ML runtime.
//
// The core is ACT-R base-level activation, the memory model used in
//   Reiter-Haas et al., "Predicting Music Relistening Behavior Using the ACT-R
//   Framework" (RecSys 2021): the chance you return to a track grows with how
//   often and how recently you played it,
//       B = ln( sum_j (now - t_j)^-d )
// with every past play j decaying as a power law. Rankings are invariant to the
// time unit, so days are used. "Now" is the last play in the export, not the
// wall clock, which keeps reports reproducible and meaningful for old exports.
//
// Favourites, obsessions and rediscoveries are separate views with separate
// definitions. They are not a partition: a favourite you are bingeing this
// week is both, and appears in both.

import "core:fmt"
import "core:math"
import "core:slice"

DEFAULT_DECAY       :: 0.5
LAG_FLOOR_DAYS      :: 1.0 / 24 // a replay within the hour counts as one hour ago, not infinitely recent
SECONDS_PER_DAY     :: 86400
SESSION_GAP_SECONDS :: 1800

// Thresholds behind each view. They are shown to the user next to the lists.
FAV_MIN_PLAYS       :: 10
FAV_MIN_MONTHS      :: 6
DORMANT_DAYS        :: 365
HOT_WINDOW_DAYS     :: 14
HOT_MIN_PLAYS       :: 5
REDISCOVER_MIN_PLAYS  :: 8
REDISCOVER_MIN_MONTHS :: 3
WARM_MIN_PLAYS      :: 3
AFFINITY_MIN_PLAYS  :: 8
AFFINITY_MIN_HITS   :: 3
SCORE_LIST_SIZE     :: 10

Track_Score :: struct {
	track:           string,
	artist:          string,
	plays:           int,
	months_active:   int, // distinct calendar months with at least one play
	activation:      f64, // at the end of the history
	past_strength:   f64, // activation on the day after its last play: how well known it was when it dropped out
	recent_plays:    int, // plays in the last HOT_WINDOW_DAYS
	days_since_last: int,
	openers:         int,
	closers:         int,
	opener_rate:     f64,
	closer_rate:     f64,
}

Scores :: struct {
	ref_unix:      i64,
	ref_date:      string, // local date of the last play
	decay:         f64,
	favourites:    [dynamic]Track_Score,
	obsessions:    [dynamic]Track_Score,
	rediscoveries: [dynamic]Track_Score,
	warm:          [dynamic]Track_Score,
	openers:       [dynamic]Track_Score,
	closers:       [dynamic]Track_Score,
}

// One-line plain-English definition of each view, used verbatim in the TUI,
// the HTML report and `--scores`.
why_favourites :: proc() -> string {
	return fmt.aprintf("%d+ plays across %d+ different months, and heard within the last %d days of your history.",
		FAV_MIN_PLAYS, FAV_MIN_MONTHS, DORMANT_DAYS)
}
why_obsessions :: proc() -> string {
	return fmt.aprintf("%d+ plays in the last %d days of your history.", HOT_MIN_PLAYS, HOT_WINDOW_DAYS)
}
why_rediscoveries :: proc() -> string {
	return fmt.aprintf("%d+ plays across %d+ months, but not heard for %d+ days. Ranked by how well you knew them when they dropped out.",
		REDISCOVER_MIN_PLAYS, REDISCOVER_MIN_MONTHS, DORMANT_DAYS)
}
why_warm :: proc() -> string {
	return "The tracks you are most likely to come back to, by a memory model where recent and frequent plays count most and fade with time. A prediction of what you would replay, not of what you like most."
}
why_openers :: proc() -> string {
	return fmt.aprintf("Share of a track's plays that began a session (%d+ plays, %d+ openings).", AFFINITY_MIN_PLAYS, AFFINITY_MIN_HITS)
}
why_closers :: proc() -> string {
	return fmt.aprintf("Share of a track's plays that ended a session (%d+ plays, %d+ endings).", AFFINITY_MIN_PLAYS, AFFINITY_MIN_HITS)
}

// ── Activation ───────────────────────────────────────────────────────────────

// ACT-R base-level activation at `at` from the plays in `times` (ascending UTC
// seconds). Plays at or after `at` are ignored. With no earlier play it is
// effectively minus infinity.
activation_at :: proc(times: []i64, at: i64, d: f64) -> f64 {
	sum := 0.0
	for t in times {
		if t >= at do break
		lag := f64(at - t) / SECONDS_PER_DAY + LAG_FLOOR_DAYS
		sum += math.pow(lag, -d)
	}
	if sum <= 0 do return -1e9
	return math.ln(sum)
}

// ── Per-track histories ──────────────────────────────────────────────────────

Track_Hist :: struct {
	score:      Track_Score,
	times:      [dynamic]i64,
	last_month: int,
}

// One pass over chronologically sorted plays. Returns histories in order of
// first play, which is deterministic.
build_histories :: proc(plays: []Play) -> [dynamic]Track_Hist {
	ensure_sessions(plays)
	hists: [dynamic]Track_Hist
	index: map[Track_Key]int
	defer delete(index)

	for i in 0 ..< len(plays) {
		p := plays[i]
		k := play_key(p)
		hi, seen := index[k]
		if !seen {
			hi = len(hists)
			index[k] = hi
			append(&hists, Track_Hist{score = Track_Score{track = p.track, artist = p.artist}})
		}
		h := &hists[hi]
		h.score.plays += 1
		append(&h.times, p.unix)
		if m := p.year * 12 + p.month; m != h.last_month {
			h.score.months_active += 1
			h.last_month = m
		}
		if p.opens_session do h.score.openers += 1
		if p.closes_session do h.score.closers += 1
	}
	return hists
}

destroy_histories :: proc(h: ^[dynamic]Track_Hist) {
	for &x in h do delete(x.times)
	delete(h^)
}

// ── Computing the views ──────────────────────────────────────────────────────

before_by :: proc(a_v, b_v: f64, a, b: Track_Score) -> bool {
	if a_v != b_v do return a_v > b_v
	if a.artist != b.artist do return a.artist < b.artist
	return a.track < b.track
}

take :: proc(dst: ^[dynamic]Track_Score, src: []Track_Score) {
	for s in src[:min(SCORE_LIST_SIZE, len(src))] do append(dst, s)
}

compute_scores :: proc(plays: []Play, decay := DEFAULT_DECAY) -> Scores {
	s := Scores{decay = decay}
	if len(plays) == 0 do return s

	hists := build_histories(plays)
	defer destroy_histories(&hists)

	last := plays[0]
	for p in plays do if p.unix > last.unix do last = p
	s.ref_unix = last.unix
	s.ref_date = fmt.aprintf("%04d-%02d-%02d", last.year, last.month, last.day)
	at := s.ref_unix + 1 // strictly after every play

	for &h in hists {
		sc := &h.score
		sc.activation = activation_at(h.times[:], at, decay)
		last_t := h.times[len(h.times) - 1]
		sc.days_since_last = int((s.ref_unix - last_t) / SECONDS_PER_DAY)
		sc.past_strength = activation_at(h.times[:], last_t + SECONDS_PER_DAY, decay)
		for t in h.times do if s.ref_unix - t < HOT_WINDOW_DAYS * SECONDS_PER_DAY do sc.recent_plays += 1
		sc.opener_rate = f64(sc.openers) / f64(sc.plays)
		sc.closer_rate = f64(sc.closers) / f64(sc.plays)
	}

	pick :: proc(hists: []Track_Hist, keep: proc(s: Track_Score) -> bool, less: proc(a, b: Track_Score) -> bool, out: ^[dynamic]Track_Score) {
		tmp := make([dynamic]Track_Score, context.temp_allocator)
		for h in hists do if keep(h.score) do append(&tmp, h.score)
		slice.sort_by(tmp[:], less)
		take(out, tmp[:])
	}

	pick(hists[:],
		proc(s: Track_Score) -> bool { return s.plays >= FAV_MIN_PLAYS && s.months_active >= FAV_MIN_MONTHS && s.days_since_last <= DORMANT_DAYS },
		proc(a, b: Track_Score) -> bool {
			if a.months_active != b.months_active do return a.months_active > b.months_active
			return before_by(f64(a.plays), f64(b.plays), a, b)
		}, &s.favourites)
	pick(hists[:],
		proc(s: Track_Score) -> bool { return s.recent_plays >= HOT_MIN_PLAYS },
		proc(a, b: Track_Score) -> bool { return before_by(f64(a.recent_plays), f64(b.recent_plays), a, b) },
		&s.obsessions)
	pick(hists[:],
		proc(s: Track_Score) -> bool { return s.days_since_last >= DORMANT_DAYS && s.plays >= REDISCOVER_MIN_PLAYS && s.months_active >= REDISCOVER_MIN_MONTHS },
		proc(a, b: Track_Score) -> bool { return before_by(a.past_strength, b.past_strength, a, b) },
		&s.rediscoveries)
	pick(hists[:],
		proc(s: Track_Score) -> bool { return s.plays >= WARM_MIN_PLAYS },
		proc(a, b: Track_Score) -> bool { return before_by(a.activation, b.activation, a, b) },
		&s.warm)
	pick(hists[:],
		proc(s: Track_Score) -> bool { return s.plays >= AFFINITY_MIN_PLAYS && s.openers >= AFFINITY_MIN_HITS },
		proc(a, b: Track_Score) -> bool {
			if a.opener_rate != b.opener_rate do return a.opener_rate > b.opener_rate
			return before_by(f64(a.openers), f64(b.openers), a, b)
		}, &s.openers)
	pick(hists[:],
		proc(s: Track_Score) -> bool { return s.plays >= AFFINITY_MIN_PLAYS && s.closers >= AFFINITY_MIN_HITS },
		proc(a, b: Track_Score) -> bool {
			if a.closer_rate != b.closer_rate do return a.closer_rate > b.closer_rate
			return before_by(f64(a.closers), f64(b.closers), a, b)
		}, &s.closers)
	return s
}

// ── Held-out evaluation ──────────────────────────────────────────────────────
//
// Does the activation ranking actually predict replays better than the trivial
// rankings it is meant to improve on? For each fold, cut the history at T, rank
// the tracks heard before T, and check how many of the top K are replayed in
// the following horizon. Only relistens are scored: a ranker over known tracks
// cannot predict discoveries.

// Above this expected precision for a random ranking the test cannot separate
// the rankers, and the report says so instead of presenting a tie as a result.
EVAL_UNINFORMATIVE_CHANCE :: 0.8

Ranker_Result :: struct {
	name:      string,
	decay:     f64, // 0 for the baselines that don't use one
	precision: f64, // mean over folds of hits@K / K
	ndcg:      f64,
}

Evaluation :: struct {
	folds_requested: int,
	folds_used:      int,
	horizon_days:    int,
	k:               int,
	chance:          f64, // expected precision of a random ranking
	avg_candidates:  f64,
	avg_replayed:    f64,
	rows:            [dynamic]Ranker_Result,
}

Ranked :: struct {
	value: f64,
	key:   Track_Key,
	hit:   bool,
}

RANKER_NAMES := [?]string{"most recent", "most played", "activation d=0.3", "activation d=0.5", "activation d=0.8", "activation d=1.0"}
RANKER_DECAYS := [?]f64{0.3, 0.5, 0.8, 1.0}

MIN_DECAY :: 0.05
MAX_DECAY :: 2.0
DECAY_HINT_MARGIN :: 0.05 // another decay must win by 5 points of precision before we suggest it

evaluate_rankers :: proc(plays: []Play, folds := 6, horizon_days := 30, k := 20) -> Evaluation {
	ev := Evaluation{folds_requested = folds, horizon_days = horizon_days, k = k}
	for n, i in RANKER_NAMES {
		append(&ev.rows, Ranker_Result{name = n, decay = RANKER_DECAYS[i - 2] if i >= 2 else 0})
	}
	if len(plays) == 0 do return ev

	hists := build_histories(plays)
	defer destroy_histories(&hists)

	ref_end := plays[0].unix
	first := plays[0].unix
	for p in plays {
		ref_end = max(ref_end, p.unix)
		first = min(first, p.unix)
	}
	ref_end += 1
	horizon := i64(horizon_days) * SECONDS_PER_DAY

	ranked := make([dynamic]Ranked, context.temp_allocator)
	for f in 0 ..< folds {
		cut := ref_end - i64(f + 1) * horizon
		if cut - first < horizon do break // need at least one horizon of history to learn from

		candidates, replayed := 0, 0
		for &h in hists {
			before := count_before(h.times[:], cut)
			if before == 0 do continue
			candidates += 1
			if replayed_in(h.times[:], cut, cut + horizon) do replayed += 1
		}
		if candidates < k || replayed == 0 do continue

		ev.folds_used += 1
		ev.avg_candidates += f64(candidates)
		ev.avg_replayed += f64(replayed)
		ev.chance += f64(replayed) / f64(candidates)

		for r in 0 ..< len(RANKER_NAMES) {
			clear(&ranked)
			for &h in hists {
				n := count_before(h.times[:], cut)
				if n == 0 do continue
				v: f64
				switch r {
				case 0: v = f64(h.times[n - 1])
				case 1: v = f64(n)
				case:   v = activation_at(h.times[:n], cut, RANKER_DECAYS[r - 2])
				}
				append(&ranked, Ranked{v, Track_Key{h.score.track, h.score.artist}, replayed_in(h.times[:], cut, cut + horizon)})
			}
			slice.sort_by(ranked[:], proc(a, b: Ranked) -> bool {
				if a.value != b.value do return a.value > b.value
				if a.key.artist != b.key.artist do return a.key.artist < b.key.artist
				return a.key.track < b.key.track
			})
			hits := 0
			dcg := 0.0
			for i in 0 ..< k do if ranked[i].hit {
				hits += 1
				dcg += 1 / math.log2(f64(i + 2))
			}
			idcg := 0.0
			for i in 0 ..< min(k, replayed) do idcg += 1 / math.log2(f64(i + 2))
			ev.rows[r].precision += f64(hits) / f64(k)
			ev.rows[r].ndcg += dcg / idcg
		}
	}

	if ev.folds_used > 0 {
		n := f64(ev.folds_used)
		ev.chance /= n
		ev.avg_candidates /= n
		ev.avg_replayed /= n
		for &r in ev.rows {
			r.precision /= n
			r.ndcg /= n
		}
	}
	return ev
}

// A decay worth trying instead of `current`, if one of the evaluated decays
// beat it clearly on held-out replays. Never suggests anything from a test the
// report itself calls uninformative.
suggest_decay :: proc(ev: Evaluation, current: f64) -> (decay: f64, ok: bool) {
	if ev.folds_used == 0 || ev.chance >= EVAL_UNINFORMATIVE_CHANCE do return
	cur, best := -1.0, Ranker_Result{precision = -1}
	for r in ev.rows {
		if r.decay == 0 do continue
		if abs(r.decay - current) < 1e-9 do cur = r.precision
		if r.precision > best.precision do best = r // first wins ties: the slower decay
	}
	if cur < 0 || abs(best.decay - current) < 1e-9 do return
	if best.precision >= cur + DECAY_HINT_MARGIN do return best.decay, true
	return
}

// Number of entries in ascending `times` that are < t.
count_before :: proc(times: []i64, t: i64) -> int {
	lo, hi := 0, len(times)
	for lo < hi {
		mid := (lo + hi) / 2
		if times[mid] < t { lo = mid + 1 } else { hi = mid }
	}
	return lo
}

replayed_in :: proc(times: []i64, from, to: i64) -> bool {
	i := count_before(times, from)
	return i < len(times) && times[i] < to
}

// ── Text report (`--scores`) ─────────────────────────────────────────────────

scores_report_text :: proc(s: Scores, ev: Evaluation) -> string {
	out := make([dynamic]string, context.temp_allocator)
	add :: proc(out: ^[dynamic]string, parts: ..any) { append(out, fmt.tprint(..parts, sep = "")) }

	add(&out, "Listening scores   (as of ", s.ref_date, ", memory decay d=", fmt.tprintf("%.1f", s.decay), ")")

	section :: proc(out: ^[dynamic]string, title, why: string, items: []Track_Score, detail: proc(t: Track_Score) -> string) {
		append(out, "")
		append(out, title)
		append(out, fmt.tprintf("  %s", why))
		if len(items) == 0 {
			append(out, "  (none)")
			return
		}
		for t, i in items do append(out, fmt.tprintf("  %s %s — %s   %s", pad_left(fmt.tprintf("%d.", i + 1), 3), t.track, t.artist, detail(t)))
	}

	section(&out, "Long-term favourites", why_favourites(), s.favourites[:],
		proc(t: Track_Score) -> string { return fmt.tprintf("%d plays, %d months", t.plays, t.months_active) })
	section(&out, "Current obsessions", why_obsessions(), s.obsessions[:],
		proc(t: Track_Score) -> string { return fmt.tprintf("%d plays in %d days", t.recent_plays, HOT_WINDOW_DAYS) })
	section(&out, "Rediscoveries", why_rediscoveries(), s.rediscoveries[:],
		proc(t: Track_Score) -> string { return fmt.tprintf("%d plays, silent %d days", t.plays, t.days_since_last) })
	section(&out, "Likely to come back to", why_warm(), s.warm[:],
		proc(t: Track_Score) -> string { return fmt.tprintf("activation %.2f", t.activation) })
	section(&out, "Reach-for-first", why_openers(), s.openers[:],
		proc(t: Track_Score) -> string { return fmt.tprintf("%.0f%% of %d plays", t.opener_rate * 100, t.plays) })
	section(&out, "Last song of the night", why_closers(), s.closers[:],
		proc(t: Track_Score) -> string { return fmt.tprintf("%.0f%% of %d plays", t.closer_rate * 100, t.plays) })

	add(&out, "")
	add(&out, "Does the memory model beat simple rankings on your history?")
	if ev.folds_used == 0 {
		add(&out, "  Not enough history to evaluate (needs several ", fmt.tprintf("%d", ev.horizon_days), "-day windows and ", fmt.tprintf("%d", ev.k), "+ known tracks).")
		return join_lines(out[:])
	}
	add(&out, fmt.tprintf("  Each of %d past windows (%d days): rank the tracks you already knew, check the top %d against what you replayed.",
		ev.folds_used, ev.horizon_days, ev.k))
	add(&out, fmt.tprintf("  On average %.0f known tracks, %.0f of them replayed.", ev.avg_candidates, ev.avg_replayed))
	add(&out, "")
	row :: proc(name, p, n: string) -> string {
		return fmt.tprintf("  %s %s %s", pad_right(name, 18), pad_left(p, 14), pad_left(n, 9))
	}
	add(&out, row("ranking", fmt.tprintf("precision@%d", ev.k), fmt.tprintf("NDCG@%d", ev.k)))
	add(&out, row("chance", fmt.tprintf("%.1f%%", ev.chance * 100), "—"))
	for r in ev.rows do add(&out, row(r.name, fmt.tprintf("%.1f%%", r.precision * 100), fmt.tprintf("%.3f", r.ndcg)))
	add(&out, "")
	if ev.chance >= EVAL_UNINFORMATIVE_CHANCE {
		add(&out, fmt.tprintf("  Not informative here: %.0f%% of the tracks you already knew were replayed in a typical window, so even a random", ev.chance * 100))
		add(&out, "  ranking scores that high and the rankings cannot be told apart. This test needs a history where much of your library goes unplayed for weeks.")
	} else {
		add(&out, "  Higher is better. Which ranking wins depends on your listening, so judge by this table, not by the model's reputation.")
		if d, ok := suggest_decay(ev, s.decay); ok {
			add(&out, fmt.tprintf("  On your history d=%.1f predicted replays better than the d=%.1f in use. Try: --decay %.1f", d, s.decay, d))
		}
	}
	return join_lines(out[:])
}

join_lines :: proc(lines: []string) -> string {
	n := 0
	for l in lines do n += len(l) + 1
	buf := make([dynamic]u8, 0, n)
	for l in lines {
		append(&buf, ..transmute([]u8)l)
		append(&buf, '\n')
	}
	return string(buf[:])
}
