package spotify_report

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// ── Fixtures ─────────────────────────────────────────────────────────────────

REC_A :: `{"ts":"2023-05-01T10:00:00Z","ms_played":200000,"master_metadata_track_name":"Song A","master_metadata_album_artist_name":"Artist","master_metadata_album_album_name":"Album","spotify_track_uri":"spotify:track:aaa"}`
REC_B :: `{"ts":"2023-05-01T10:04:00Z","ms_played":10000,"master_metadata_track_name":"Song B","master_metadata_album_artist_name":"Artist","master_metadata_album_album_name":"Album","spotify_track_uri":"spotify:track:bbb"}`
REC_POD :: `{"ts":"2023-05-01T11:00:00Z","ms_played":900000,"master_metadata_track_name":null,"master_metadata_album_artist_name":null,"episode_name":"Ep"}`

fixture_dir :: proc(name: string) -> string {
	base := os.temp_directory(context.temp_allocator) or_else "/tmp"
	dir := fmt.aprintf("%s/shr_input_%s", base, name)
	rm_rf(dir)
	_ = os.make_directory_all(dir)
	return dir
}

write_fixture :: proc(dir, name, body: string) -> string {
	path := fmt.aprintf("%s/%s", dir, name)
	_ = os.write_entire_file(path, transmute([]u8)body)
	return path
}

// A minimal single-pass ZIP writer (stored entries), enough to exercise the reader.
make_zip :: proc(names: []string, bodies: []string) -> []u8 {
	out: [dynamic]u8
	cd: [dynamic]u8
	u16le :: proc(b: ^[dynamic]u8, v: u16) { append(b, u8(v), u8(v >> 8)) }
	u32le :: proc(b: ^[dynamic]u8, v: u32) { u16le(b, u16(v)); u16le(b, u16(v >> 16)) }
	for name, i in names {
		body := bodies[i]
		off := u32(len(out))
		u32le(&out, 0x04034b50); u16le(&out, 20); u16le(&out, 0); u16le(&out, 0); u16le(&out, 0); u16le(&out, 0)
		u32le(&out, 0); u32le(&out, u32(len(body))); u32le(&out, u32(len(body))); u16le(&out, u16(len(name))); u16le(&out, 0)
		append(&out, ..transmute([]u8)name); append(&out, ..transmute([]u8)body)

		u32le(&cd, 0x02014b50); u16le(&cd, 20); u16le(&cd, 20); u16le(&cd, 0); u16le(&cd, 0); u16le(&cd, 0); u16le(&cd, 0)
		u32le(&cd, 0); u32le(&cd, u32(len(body))); u32le(&cd, u32(len(body))); u16le(&cd, u16(len(name)))
		u16le(&cd, 0); u16le(&cd, 0); u16le(&cd, 0); u16le(&cd, 0); u32le(&cd, 0); u32le(&cd, off)
		append(&cd, ..transmute([]u8)name)
	}
	cd_off := u32(len(out))
	append(&out, ..cd[:])
	u32le(&out, 0x06054b50); u16le(&out, 0); u16le(&out, 0); u16le(&out, u16(len(names))); u16le(&out, u16(len(names)))
	u32le(&out, u32(len(cd))); u32le(&out, cd_off); u16le(&out, 0)
	return out[:]
}

load_all :: proc(inputs: []string) -> (Load_Result, bool) {
	scan := scan_inputs(inputs)
	if len(scan.err) > 0 do return Load_Result{err = scan.err, hint = scan.hint}, false
	c := make_clock("UTC")
	return load_plays(scan.entries[:], &c, false)
}

// ── Tests ────────────────────────────────────────────────────────────────────

@(test)
test_folder_finds_history_by_content_not_name :: proc(t: ^testing.T) {
	dir := fixture_dir("content")
	// Not named Streaming_History_Audio_*: it is still history. Playlists are not.
	write_fixture(dir, "my_export_part1.json", fmt.tprintf("[%s,%s,%s]", REC_A, REC_B, REC_POD))
	write_fixture(dir, "Playlist1.json", `{"playlists":[]}`)
	write_fixture(dir, "Userdata.json", `{"username":"x"}`)
	r, ok := load_all({dir})
	testing.expect(t, ok)
	s := r.summary
	testing.expect_value(t, s.files_used, 1)
	testing.expect_value(t, s.files_ignored, 2)
	testing.expect_value(t, s.records, 3)
	testing.expect_value(t, s.non_music, 1)
	testing.expect_value(t, s.music_events, 2)
	testing.expect_value(t, s.short_listens, 1)
	testing.expect_value(t, s.plays, 1)
}

@(test)
test_nested_folder_and_hidden_sidecar_are_handled :: proc(t: ^testing.T) {
	dir := fixture_dir("nested")
	sub := fmt.tprintf("%s/Spotify Extended Streaming History", dir)
	_ = os.make_directory_all(sub)
	_ = os.make_directory_all(fmt.tprintf("%s/.shr", dir))
	write_fixture(sub, "Streaming_History_Audio_2023.json", fmt.tprintf("[%s]", REC_A))
	write_fixture(dir, ".shr/identities.json", `[{"ts":"x"}]`) // our own cache must never be read as history
	r, ok := load_all({dir})
	testing.expect(t, ok)
	testing.expect_value(t, r.summary.files_used, 1)
	testing.expect_value(t, r.summary.plays, 1)
}

@(test)
test_identical_files_count_once_and_cross_file_overlap_is_dropped :: proc(t: ^testing.T) {
	dir := fixture_dir("dupes")
	write_fixture(dir, "a.json", fmt.tprintf("[%s,%s]", REC_A, REC_B))
	write_fixture(dir, "b.json", fmt.tprintf("[%s,%s]", REC_A, REC_B)) // same bytes
	write_fixture(dir, "c.json", fmt.tprintf("[%s]", REC_A))           // overlaps one row of a.json
	r, ok := load_all({dir})
	testing.expect(t, ok)
	testing.expect_value(t, r.summary.files_used, 2)
	testing.expect_value(t, r.summary.files_identical, 1)
	testing.expect_value(t, r.summary.overlap_dropped, 1)
	testing.expect_value(t, r.summary.plays, 1)
}

@(test)
test_repeat_inside_one_file_is_kept :: proc(t: ^testing.T) {
	// The same row twice in a single file may be a real replay: never silently removed.
	dir := fixture_dir("replay")
	write_fixture(dir, "a.json", fmt.tprintf("[%s,%s]", REC_A, REC_A))
	r, ok := load_all({dir})
	testing.expect(t, ok)
	testing.expect_value(t, r.summary.overlap_dropped, 0)
	testing.expect_value(t, r.summary.plays, 2)
}

@(test)
test_account_history_gets_a_clear_message :: proc(t: ^testing.T) {
	dir := fixture_dir("account")
	write_fixture(dir, "StreamingHistory0.json", `[{"endTime":"2023-05-01 10:00","artistName":"A","trackName":"T","msPlayed":200000}]`)
	r, ok := load_all({dir})
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(r.err, "not Extended Streaming History"), r.err)
}

@(test)
test_truncated_history_file_is_an_error_not_a_silent_skip :: proc(t: ^testing.T) {
	dir := fixture_dir("trunc")
	write_fixture(dir, "Streaming_History_Audio_2023.json", `[{"ts":"2023-05-01T10:00:00Z","ms_pla`)
	r, ok := load_all({dir})
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(r.err, "not valid JSON"), r.err)
}

@(test)
test_no_history_anywhere_explains_itself :: proc(t: ^testing.T) {
	dir := fixture_dir("none")
	write_fixture(dir, "Playlist1.json", `{"playlists":[]}`)
	r, ok := load_all({dir})
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(r.err, "None of the JSON files"), r.err)

	_, ok2 := load_all({"/nonexistent/path"})
	testing.expect(t, !ok2)
}

@(test)
test_loose_files_and_multiple_inputs :: proc(t: ^testing.T) {
	dir := fixture_dir("loose")
	f1 := write_fixture(dir, "one.json", fmt.tprintf("[%s]", REC_A))
	f2 := write_fixture(dir, "two.json", fmt.tprintf("[%s]", REC_B))
	r, ok := load_all({f1, f2})
	testing.expect(t, ok)
	testing.expect_value(t, r.summary.files_used, 2)
	testing.expect_value(t, r.summary.music_events, 2)
}

@(test)
test_zip_reads_json_entries_only :: proc(t: ^testing.T) {
	dir := fixture_dir("zip")
	z := make_zip(
		{"Spotify Extended Streaming History/Streaming_History_Audio_2023.json", "Spotify Extended Streaming History/ReadMe.pdf", "__MACOSX/._x.json", "Spotify Extended Streaming History/Playlist1.json"},
		{fmt.tprintf("[%s,%s]", REC_A, REC_B), "%PDF", "junk", `{"playlists":[]}`})
	path := fmt.tprintf("%s/my_spotify_data.zip", dir)
	_ = os.write_entire_file(path, z)
	r, ok := load_all({path})
	testing.expect(t, ok, r.err)
	testing.expect_value(t, r.summary.files_used, 1)
	testing.expect_value(t, r.summary.files_ignored, 1) // Playlist1.json; the PDF and resource fork are never opened
	testing.expect_value(t, r.summary.plays, 1)

	scan := scan_inputs({path})
	testing.expect_value(t, scan.sidecar_dir, dir) // state lives beside the ZIP, nothing is extracted
}

@(test)
test_zip_rejects_hostile_names_and_damage :: proc(t: ^testing.T) {
	testing.expect(t, !safe_zip_name("../../etc/passwd"))
	testing.expect(t, !safe_zip_name("/abs/x.json"))
	testing.expect(t, !safe_zip_name("a\\..\\b.json"))
	testing.expect(t, !safe_zip_name("C:/x.json"))
	testing.expect(t, safe_zip_name("Spotify Extended Streaming History/Streaming_History_Audio_1.json"))

	dir := fixture_dir("zipbad")
	// Hostile entry names are skipped, not followed.
	z := make_zip({"../evil.json"}, {fmt.tprintf("[%s]", REC_A)})
	path := fmt.tprintf("%s/hostile.zip", dir)
	_ = os.write_entire_file(path, z)
	r, ok := load_all({path})
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(r.err, "No .json files") || strings.contains(r.err, "None of"), r.err)

	// Truncated archive: a clear message.
	good := make_zip({"a.json"}, {fmt.tprintf("[%s]", REC_A)})
	cut := fmt.tprintf("%s/cut.zip", dir)
	_ = os.write_entire_file(cut, good[:len(good) - 30])
	r2, ok2 := load_all({cut})
	testing.expect(t, !ok2)
	testing.expect(t, strings.contains(r2.err, "ZIP"), r2.err)
}
