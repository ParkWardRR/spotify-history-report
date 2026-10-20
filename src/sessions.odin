package spotify_report

import "core:slice"

// A session is a run of listening with no idle gap longer than SESSION_GAP_SECONDS.
// It is decided on every music row in the export, short listens included: a few
// seconds of skipping between two songs is still listening, and dropping those
// rows first would split a session wherever the skipping happened.
//
// Spotify stamps a row with when the stream *ended*, so the idle time before a
// row is its estimated start (end − ms_played) minus the latest end seen so far.

Session_Event :: struct {
	end:  i64, // unix seconds, stream end
	ms:   i64,
	slot: int, // index into the plays slice, or -1 for a short listen that is not a play
}

// Assigns `session` (1-based), `opens_session` and `closes_session` on `plays`.
// An opener is the first *qualifying* play of a session; a session with none
// (all short listens) opens and closes nothing. `events` may be in any order.
assign_sessions :: proc(events: []Session_Event, plays: []Play) {
	if len(events) == 0 do return
	slice.stable_sort_by(events, proc(a, b: Session_Event) -> bool { return a.end < b.end })

	session := 0
	latest_end: i64
	first_slot, last_slot := -1, -1

	close :: proc(plays: []Play, first, last: int) {
		if first >= 0 do plays[first].opens_session = true
		if last >= 0 do plays[last].closes_session = true
	}

	for e, i in events {
		start := e.end - e.ms / 1000
		if i == 0 || start - latest_end > SESSION_GAP_SECONDS {
			if i > 0 do close(plays, first_slot, last_slot)
			session += 1
			first_slot, last_slot = -1, -1
			latest_end = e.end
		}
		latest_end = max(latest_end, e.end)
		if e.slot >= 0 {
			plays[e.slot].session = session
			if first_slot < 0 do first_slot = e.slot
			last_slot = e.slot
		}
	}
	close(plays, first_slot, last_slot)
}

// For plays that were not loaded through the importer (tests, callers with only
// qualifying plays): sessions from the plays alone.
ensure_sessions :: proc(plays: []Play) {
	if len(plays) == 0 || plays[0].session != 0 do return
	events := make([]Session_Event, len(plays), context.temp_allocator)
	for p, i in plays do events[i] = Session_Event{p.unix, p.ms, i}
	assign_sessions(events, plays)
}
