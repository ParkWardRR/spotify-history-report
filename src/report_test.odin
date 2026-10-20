package spotify_report

import "core:encoding/json"
import "core:strings"
import "core:testing"

// Every string in the report comes from the user's export or their own notes
// and must never be able to leave its JSON string or its <script> element.
HOSTILE :: "</script><script>alert(1)</script> \" \\ \n\t\r\x01\x1f <!-- &     é 音楽 🎧"

@(test)
test_report_json_is_valid_and_script_safe_for_hostile_metadata :: proc(t: ^testing.T) {
	s: Stats
	s.timezone = HOSTILE
	s.date_range_start = HOSTILE
	s.peak_day = HOSTILE
	s.most_played_song = Track_Stat{HOSTILE, HOSTILE, 3}
	s.worst_earworm = Earworm_Stat{HOSTILE, HOSTILE, 9, HOSTILE}
	s.biggest_day = Day_Stat{HOSTILE, 1, 1}
	append(&s.top_artists, Artist_Stat{HOSTILE, 1})
	append(&s.top_albums, Album_Stat{HOSTILE, HOSTILE, 1})
	append(&s.session_openers, Opener_Stat{HOSTILE, HOSTILE, 1})
	append(&s.never_skipped, Track_Stat{HOSTILE, HOSTILE, 15})
	append(&s.earworms, Earworm_Stat{HOSTILE, HOSTILE, 5, HOSTILE})
	append(&s.loyalists, Artist_Stat{HOSTILE, 1})
	append(&s.platforms, Platform_Stat{HOSTILE, 1})
	append(&s.genre_order, HOSTILE)
	s.genre_colors[HOSTILE] = HOSTILE
	append(&s.genre_area, Genre_Quarter{quarter = HOSTILE})
	s.import_summary.source = HOSTILE

	data := report_json(s)
	testing.expect(t, !strings.contains(data, "</"), "no closing tag may survive in the embedded data")
	testing.expect(t, !strings.contains(data, "<!--"), "no HTML comment opener")
	testing.expect(t, !strings.contains(data, " ") && !strings.contains(data, " "))

	v, err := json.parse(transmute([]u8)data)
	testing.expect_value(t, err, json.Error.None)
	obj, is_obj := v.(json.Object)
	testing.expect(t, is_obj)
	// The text survives the round trip byte for byte.
	tz, _ := obj["timezone"].(json.String)
	testing.expect_value(t, string(tz), HOSTILE)
	artists, _ := obj["top_artists"].(json.Array)
	testing.expect_value(t, len(artists), 1)
	first, _ := artists[0].(json.Object)
	name, _ := first["name"].(json.String)
	testing.expect_value(t, string(name), HOSTILE)
}

@(test)
test_json_html_safe_escapes_every_control_character :: proc(t: ^testing.T) {
	for i in 0 ..< 0x20 {
		in_ := string([]u8{'a', u8(i), 'b'})
		out := json_html_safe(in_)
		for c in transmute([]u8)out do if c < 0x20 do testing.fail_now(t, "raw control character in output")
		v, err := json.parse(transmute([]u8)strings.concatenate({`"`, out, `"`}, context.temp_allocator))
		testing.expect_value(t, err, json.Error.None)
		got, _ := v.(json.String)
		testing.expect_value(t, string(got), in_)
	}
}
