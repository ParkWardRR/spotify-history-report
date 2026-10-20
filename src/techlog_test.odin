package spotify_report

import "core:strings"
import "core:testing"

ROUTES_JSON :: `[
 {"timestamp_utc":"2026-08-01T10:00:00.000Z","message_current_route_type":"CarAudio","message_current_route_name":"CarPlay","message_reason":"x"},
 {"timestamp_utc":"2026-08-02T10:00:00.000Z","message_current_route_type":"BluetoothA2DPOutput","message_current_route_name":"Buds"},
 {"timestamp_utc":"2026-08-03T10:00:00.000Z","message_current_route_type":"bluetooth-headphones","message_current_route_name":"Buds"},
 {"timestamp_utc":"2026-08-04T10:00:00.000Z","message_current_route_type":"Odd-New-Type"},
 {"timestamp_utc":"2026-08-05T10:00:00.000Z","message_current_route_type":null}
]`

BITRATE_JSON :: `[
 {"timestamp_utc":"2026-08-01T10:00:00.000Z","message_bitrate":"320000","message_strategy_name":"cached file"},
 {"timestamp_utc":"2026-08-01T11:00:00.000Z","message_bitrate":320000,"message_strategy_name":"stream"},
 {"timestamp_utc":"2026-08-01T12:00:00.000Z","message_bitrate":"160000","message_strategy_name":"stream"},
 {"timestamp_utc":"2026-08-01T13:00:00.000Z","message_bitrate":"None","message_strategy_name":"stream"}
]`

DAYLIST_JSON :: `[
 {"timestamp_utc":"2026-07-26T21:54:06.304Z","message_playlist_title":"smooth groove indie soul sunday afternoon",
  "message_title_terms":"['smooth groove', 'indie soul']","message_daypart":"afternoon","message_day_of_week":"Sunday"},
 {"timestamp_utc":"2026-08-07T19:35:00.884Z","message_playlist_title":"smooth r&b velvety friday afternoon",
  "message_title_terms":["Smooth R&B","velvety"],"message_daypart":"Afternoon","message_day_of_week":"Friday"},
 {"timestamp_utc":"2026-08-08T04:00:00.000Z","message_playlist_title":"smooth groove late night",
  "message_title_terms":"['smooth groove', \"don't stop\"]","message_daypart":"night","message_day_of_week":"Saturday"}
]`

ingest_all :: proc() -> Tech_Raw {
	raw: Tech_Raw
	testing.expect_value(nil, true, true)
	techlog_ingest(&raw, transmute([]u8)string(ROUTES_JSON))
	techlog_ingest(&raw, transmute([]u8)string(BITRATE_JSON))
	techlog_ingest(&raw, transmute([]u8)string(DAYLIST_JSON))
	return raw
}

@(test)
test_techlog_routes_group_by_friendly_label :: proc(t: ^testing.T) {
	raw := ingest_all()
	s := techlog_stats(&raw)
	testing.expect(t, s.present)
	testing.expect_value(t, s.route_total, 4) // the null route type is not a segment
	testing.expect_value(t, s.routes[0].label, "Bluetooth") // two types, one label, 2 of 4
	testing.expect_value(t, s.routes[0].count, 2)
	found_odd := false
	for r in s.routes do if r.label == "Odd-New-Type" do found_odd = true
	testing.expect(t, found_odd) // an unknown type keeps its own name, never a guessed one
}

@(test)
test_techlog_bitrates_accept_strings_numbers_and_skip_none :: proc(t: ^testing.T) {
	raw := ingest_all()
	s := techlog_stats(&raw)
	testing.expect_value(t, s.bitrate_total, 3)
	testing.expect_value(t, s.bitrates[0].label, "320 kbps")
	testing.expect_value(t, s.bitrates[0].count, 2)
	testing.expect_value(t, s.bitrates[1].label, "160 kbps")
}

@(test)
test_techlog_daylists_terms_titles_and_times :: proc(t: ^testing.T) {
	raw := ingest_all()
	s := techlog_stats(&raw)
	testing.expect_value(t, s.daylists, 3)
	// "smooth groove" twice (python repr both times), lower-cased; ties by name.
	testing.expect_value(t, s.terms[0].label, "smooth groove")
	testing.expect_value(t, s.terms[0].count, 2)
	has_apostrophe := false
	for term in s.terms do if term.label == "don't stop" do has_apostrophe = true
	testing.expect(t, has_apostrophe)
	testing.expect_value(t, s.titles[0], "smooth groove late night") // newest first
	testing.expect_value(t, s.dayparts[1], 2) // afternoon, in either case
	testing.expect_value(t, s.dayparts[3], 1)
	testing.expect_value(t, s.weekdays[0], 1) // Sunday first
	testing.expect_value(t, s.weekdays[5], 1) // Friday
	testing.expect_value(t, s.first_date, "2026-07-26")
	testing.expect_value(t, s.last_date, "2026-08-08")
}

@(test)
test_techlog_ignores_other_event_files_and_garbage :: proc(t: ^testing.T) {
	raw: Tech_Raw
	testing.expect(t, !techlog_ingest(&raw, transmute([]u8)string(`[{"timestamp_utc":"2026-01-01T00:00:00Z","message_something_else":"x"}]`)))
	testing.expect(t, !techlog_ingest(&raw, transmute([]u8)string(`not json message_bitrate`)))
	testing.expect(t, !techlog_ingest(&raw, transmute([]u8)string(`[]`)))
	s := techlog_stats(&raw)
	testing.expect(t, !s.present) // nothing read means no section, not an empty one
}

@(test)
test_looks_like_technical_log_is_a_cheap_content_check :: proc(t: ^testing.T) {
	testing.expect(t, looks_like_technical_log(transmute([]u8)string(ROUTES_JSON)))
	testing.expect(t, !looks_like_technical_log(transmute([]u8)string(REC_A)))
	kind, _ := classify_file("whatever.json", transmute([]u8)string(ROUTES_JSON))
	testing.expect_value(t, kind, File_Kind.Technical_Log)
}

@(test)
test_report_carries_techlog_only_when_present :: proc(t: ^testing.T) {
	s := stats_for(mk_play("2024-03-01T12:00:00Z", "Song", "Artist"))
	plain, _ := render_report(s, false)
	testing.expect(t, !strings.contains(plain, `"techlog":`))

	raw := ingest_all()
	s.tech = techlog_stats(&raw)
	html, ok := render_report(s, false)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(html, `"techlog":{"first":"2026-07-26","last":"2026-08-08"`))
	testing.expect(t, strings.contains(html, `{"label":"Bluetooth","count":2}`))
}

// The parse tree lives in the temp allocator, which the pipeline frees between
// stages. Nothing kept in Tech_Raw may point into it.
@(test)
test_techlog_keeps_nothing_that_points_into_temp_memory :: proc(t: ^testing.T) {
	raw := ingest_all()
	free_all(context.temp_allocator)
	// Scribble over whatever the freed arena hands out next.
	junk := make([]u8, 1 << 16, context.temp_allocator)
	for i in 0 ..< len(junk) do junk[i] = 'Z'
	s := techlog_stats(&raw)
	free_all(context.temp_allocator)
	testing.expect_value(t, s.first_date, "2026-07-26")
	testing.expect_value(t, s.last_date, "2026-08-08")
	testing.expect_value(t, s.titles[0], "smooth groove late night")
	testing.expect_value(t, s.terms[0].label, "smooth groove")
	testing.expect_value(t, s.routes[0].label, "Bluetooth")
}
