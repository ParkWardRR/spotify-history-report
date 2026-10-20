package spotify_report

import "core:fmt"
import "core:os"
import "core:testing"

// ── Helpers ──────────────────────────────────────────────────────────────────

// A fresh data directory per test; tests run in parallel.
temp_data_dir :: proc(name: string) -> string {
	base := os.temp_directory(context.temp_allocator) or_else "/tmp"
	dir := fmt.aprintf("%s/shr_test_%s", base, name)
	os.remove_all(dir)
	os.make_directory_all(dir)
	return dir
}

write_file :: proc(path, content: string) {
	_ = os.write_entire_file(path, transmute([]u8)content)
}

ann :: proc(artist, title, value, source, observed: string) -> Annotation {
	return Annotation{artist = artist, title = title, namespace = NS_GENRE, value = value, source = source, observed = observed}
}

store_of :: proc(items: ..Annotation) -> Annotation_File {
	f := Annotation_File{schema_version = ANNOTATIONS_SCHEMA_VERSION}
	append(&f.annotations, ..items)
	return f
}

genre_of :: proc(r: ^Genre_Resolver, track, artist: string) -> string {
	if p, ok := resolve_genre(r, track, artist); ok do return p.genre
	return "<unknown>"
}

// ── Validation ───────────────────────────────────────────────────────────────

@(test)
test_validate_annotation :: proc(t: ^testing.T) {
	testing.expect_value(t, validate_annotation("genre", "Rock"), "")
	testing.expect_value(t, validate_annotation("genre", "Other"), "") // a real label, unlike Unclassified
	testing.expect(t, len(validate_annotation("genre", "Hip hop")) > 0)      // not the vocabulary: "Hip-hop & Rap"
	testing.expect(t, len(validate_annotation("genre", "rock")) > 0)         // case matters
	testing.expect(t, len(validate_annotation("genre", UNCLASSIFIED)) > 0)   // unknown is absence, not a value
	testing.expect(t, len(validate_annotation("genre", "")) > 0)
	testing.expect_value(t, validate_annotation("mood", "warm and slow"), "")  // other namespaces are free text
	testing.expect(t, len(validate_annotation("nonsense", "x")) > 0)
}

@(test)
test_parse_annotations_rejects_bad_files :: proc(t: ^testing.T) {
	good := `{"schema_version":1,"annotations":[{"artist":"A","title":"","namespace":"genre","value":"Rock","source":"llm","model":"m","confidence":null,"observed":"2026-01-01"}]}`
	f, err := parse_annotations(transmute([]u8)good, "f")
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(f.annotations), 1)

	bad := [?]string{
		`{not json`,
		`{"schema_version":2,"annotations":[]}`,
		`{"schema_version":1,"annotations":[{"artist":"A","namespace":"genre","value":"Rock","source":"oracle"}]}`,
		`{"schema_version":1,"annotations":[{"artist":"A","namespace":"genre","value":"Hip hop","source":"llm"}]}`,
		`{"schema_version":1,"annotations":[{"artist":"","namespace":"genre","value":"Rock","source":"llm"}]}`,
		`{"schema_version":1,"annotations":[{"artist":"A","namespace":"bogus","value":"x","source":"llm"}]}`,
	}
	for src, i in bad {
		_, e := parse_annotations(transmute([]u8)src, "f")
		testing.expectf(t, len(e) > 0, "case %d should be rejected", i)
	}
}

// ── Loading, migration, safety ───────────────────────────────────────────────

@(test)
test_legacy_genre_cache_is_migrated_once :: proc(t: ^testing.T) {
	dir := temp_data_dir("migrate")
	defer os.remove_all(dir)
	write_file(fmt.tprintf("%s/.genre_cache.json", dir), `{"A":"Rock","B":"Hip hop","C":"Other","D":"Jazz"}`)

	f, info, err := load_annotations(dir)
	testing.expect_value(t, err, "")
	testing.expect(t, info.migrated)
	testing.expect_value(t, info.rejected, 1)                  // "Hip hop" is not a genre: left unclassified, not coerced
	testing.expect_value(t, len(f.annotations), 3)
	testing.expect_value(t, f.migrated_from, ".genre_cache.json")
	for a in f.annotations {
		testing.expect_value(t, a.source, "llm")
		testing.expect_value(t, a.model, "")                    // model of an old cache is unknown
	}
	testing.expect(t, save_annotations(dir, f))

	// Afterwards the legacy cache is ignored, even if it changes.
	write_file(fmt.tprintf("%s/.genre_cache.json", dir), `{"A":"Metal","Z":"Pop"}`)
	f2, info2, err2 := load_annotations(dir)
	testing.expect_value(t, err2, "")
	testing.expect(t, !info2.migrated && info2.existed)
	testing.expect_value(t, len(f2.annotations), 3)
	r := build_genre_resolver(f2, nil)
	testing.expect_value(t, genre_of(&r, "x", "A"), "Rock")
	testing.expect_value(t, genre_of(&r, "x", "Z"), "<unknown>")
}

@(test)
test_unreadable_store_is_an_error_and_left_alone :: proc(t: ^testing.T) {
	dir := temp_data_dir("unreadable")
	defer os.remove_all(dir)
	os.make_directory_all(fmt.tprintf("%s/.shr", dir))
	path := fmt.tprintf("%s/.shr/annotations.json", dir)
	write_file(path, "{ this is not json")
	write_file(fmt.tprintf("%s/.genre_cache.json", dir), `{"A":"Rock"}`)

	_, _, err := load_annotations(dir)
	testing.expect(t, len(err) > 0)
	testing.expect(t, contains(err, "left untouched"))
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), "{ this is not json") // still there, and not replaced by a migration
}

@(test)
test_store_round_trips_deterministically :: proc(t: ^testing.T) {
	dir := temp_data_dir("roundtrip")
	defer os.remove_all(dir)
	a := ann("Zed \"Q\"", "", "Rock", "llm", "2026-01-02")
	a.confidence = 0.75
	a.model = "claude-x@1"
	f := store_of(a, ann("Abe", "Song\nTwo", "Jazz", "user", ""), ann("Abe", "", "Pop", "llm", "2026-01-01"))
	f.migrated_from = ".genre_cache.json"

	testing.expect(t, save_annotations(dir, f))
	g, _, err := load_annotations(dir)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(g.annotations), 3)
	testing.expect_value(t, g.migrated_from, ".genre_cache.json")

	// Same content in a different order writes the same bytes.
	f2 := store_of(f.annotations[2], f.annotations[0], f.annotations[1])
	f2.migrated_from = f.migrated_from
	testing.expect(t, annotations_json(f) == annotations_json(f2))

	// And what was written is what comes back, including the escaped characters and confidence.
	found := false
	for x in g.annotations do if x.artist == "Zed \"Q\"" {
		found = true
		c, has := x.confidence.?
		testing.expect(t, has && c == 0.75)
		testing.expect_value(t, x.model, "claude-x@1")
	}
	testing.expect(t, found)
	_, e := parse_annotations(transmute([]u8)annotations_json(store_of()), "empty")
	testing.expect_value(t, e, "") // an empty store is valid JSON too
}

// ── Precedence ───────────────────────────────────────────────────────────────

@(test)
test_track_level_beats_artist_level_for_non_user_sources :: proc(t: ^testing.T) {
	f := store_of(
		ann("A", "", "Rock", "llm", "2026-01-01"),
		ann("A", "Special", "Jazz", "llm", "2026-01-01"),
	)
	r := build_genre_resolver(f, nil)
	testing.expect_value(t, genre_of(&r, "Special", "A"), "Jazz")
	testing.expect_value(t, genre_of(&r, "Other Song", "A"), "Rock") // only that track is affected
	testing.expect_value(t, genre_of(&r, "x", "Nobody"), "<unknown>")
}

@(test)
test_same_source_latest_wins_and_better_source_beats_later_date :: proc(t: ^testing.T) {
	f := store_of(
		ann("A", "", "Rock", "llm", "2026-01-01"),
		ann("A", "", "Metal", "llm", "2026-06-01"),   // reclassified later: replaces
		ann("B", "", "Rock", "musicbrainz", "2020-01-01"),
		ann("B", "", "Pop", "llm", "2026-06-01"),     // newer, but a lower-priority source
		ann("C", "", "Rock", "llm", "2026-01-01"),
		ann("C", "", "Pop", "llm", "2026-01-01"),     // same date: later record wins
	)
	r := build_genre_resolver(f, nil)
	testing.expect_value(t, genre_of(&r, "x", "A"), "Metal")
	testing.expect_value(t, genre_of(&r, "x", "B"), "Rock")
	testing.expect_value(t, genre_of(&r, "x", "C"), "Pop")
}

@(test)
test_user_decisions_beat_everything_at_either_level :: proc(t: ^testing.T) {
	f := store_of(
		ann("A", "", "Rock", "llm", "2026-01-01"),
		ann("A", "Song", "Pop", "sidecar", "2026-06-01"),
		ann("B", "Song", "Pop", "musicbrainz", "2026-06-01"),
	)
	user := [?]User_Annotation{
		{artist = "A", value = "Jazz"},                     // artist-level user choice
		{artist = "B", title = "Song", value = "Metal"},    // track-level user choice
	}
	r := build_genre_resolver(f, user[:])
	// The artist-level user choice beats a model's track-level guess.
	testing.expect_value(t, genre_of(&r, "Song", "A"), "Jazz")
	testing.expect_value(t, genre_of(&r, "Song", "B"), "Metal")
	testing.expect_value(t, r.user_artists, 1)
	testing.expect_value(t, r.user_tracks, 1)
}

@(test)
test_user_decision_survives_reclassification :: proc(t: ^testing.T) {
	f := store_of(ann("A", "", "Rock", "llm", "2026-01-01"))
	user := [?]User_Annotation{{artist = "A", value = "Jazz"}}

	answers: map[string]string
	defer delete(answers)
	answers["A"] = "Pop" // a later LLM run disagrees
	added, _ := add_llm_annotations(&f, answers, {"A"}, "model-2", "2027-01-01")
	testing.expect_value(t, added, 1)

	r := build_genre_resolver(f, user[:])
	testing.expect_value(t, genre_of(&r, "x", "A"), "Jazz")
	// Remove the user's override and the newest model answer is what remains.
	r2 := build_genre_resolver(f, nil)
	testing.expect_value(t, genre_of(&r2, "x", "A"), "Pop")
}

@(test)
test_llm_answers_are_validated_not_coerced :: proc(t: ^testing.T) {
	f := store_of()
	answers: map[string]string
	defer delete(answers)
	answers["Good"] = "Jazz"
	answers["Misc"] = "Other"        // a legitimate answer
	answers["Typo"] = "Hip hop"      // not in the vocabulary
	answers["Stranger"] = "Rock"     // nobody asked about this artist
	added, rejected := add_llm_annotations(&f, answers, {"Good", "Misc", "Typo"}, "m", "2026-10-19")
	testing.expect_value(t, added, 2)
	testing.expect_value(t, rejected, 2)

	r := build_genre_resolver(f, nil)
	testing.expect_value(t, genre_of(&r, "x", "Good"), "Jazz")
	testing.expect_value(t, genre_of(&r, "x", "Misc"), "Other")
	testing.expect_value(t, genre_of(&r, "x", "Typo"), "<unknown>")      // unknown, NOT "Other"
	testing.expect_value(t, genre_of(&r, "x", "Stranger"), "<unknown>")
	testing.expect(t, !has_artist_genre(&r, "Typo")) // so it will be asked about again
	for a in f.annotations do testing.expect_value(t, a.model, "m")
}

// ── User annotations in overrides.json ───────────────────────────────────────

@(test)
test_user_annotations_parse_and_validate :: proc(t: ^testing.T) {
	ov, err := parse_ov(`{"annotations":[{"artist":"A","value":"Jazz"},{"artist":"B","title":"T","namespace":"mood","value":"calm"}]}`)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(ov.annotations), 2)
	testing.expect_value(t, ov.annotations[0].namespace, NS_GENRE) // defaulted

	cases := [?]string{
		`{"annotations":[{"artist":"A","value":"Hip hop"}]}`,    // not a genre
		`{"annotations":[{"value":"Jazz"}]}`,                    // no artist
		`{"annotations":[{"artist":"A"}]}`,                      // no value
		`{"annotations":[{"artist":"A","valeu":"Jazz"}]}`,       // typo'd key
		`{"annotations":[{"artist":"A","namespace":"x","value":"y"}]}`,
		`{"annotations":"nope"}`,
	}
	for src, i in cases {
		_, e := parse_ov(src)
		testing.expectf(t, len(e) > 0, "case %d should be rejected", i)
	}
}

// ── Genre statistics ─────────────────────────────────────────────────────────

@(test)
test_unknown_is_its_own_series_and_not_other :: proc(t: ^testing.T) {
	f := store_of(
		ann("A", "", "Rock", "llm", "2026-01-01"),
		ann("C", "", "Other", "llm", "2026-01-01"),
	)
	user := [?]User_Annotation{{artist = "A", title = "T2", value = "Jazz"}}
	r := build_genre_resolver(f, user[:])
	defer genre_resolver_destroy(&r)

	list := [?]Play{
		mk_play("2020-02-01T12:00:00Z", "T1", "A"), // Rock (artist-level)
		mk_play("2020-02-02T12:00:00Z", "T2", "A"), // Jazz (user, this track only)
		mk_play("2020-02-03T12:00:00Z", "T3", "B"), // nobody has classified B
		mk_play("2020-02-04T12:00:00Z", "T4", "C"), // Other: a real label
	}
	s := compute_stats(list[:])
	compute_genre_stats(&s, list[:], &r)

	testing.expect_value(t, s.genre_order[len(s.genre_order) - 1], UNCLASSIFIED)
	testing.expect(t, abs(s.genre_unclassified_pct - 25) < 1e-6)
	testing.expect_value(t, s.genre_classified, 3)
	testing.expect_value(t, s.genre_user_targets, 1)
	testing.expect(t, abs(s.genre_source_pct[.User] - 25) < 1e-6)
	testing.expect(t, abs(s.genre_source_pct[.Llm] - 50) < 1e-6)

	testing.expect_value(t, len(s.genre_area), 1)
	q := s.genre_area[0]
	testing.expect(t, abs(q.values["Rock"] - 25) < 1e-6)
	testing.expect(t, abs(q.values["Jazz"] - 25) < 1e-6)
	testing.expect(t, abs(q.values["Other"] - 25) < 1e-6)
	testing.expect(t, abs(q.values[UNCLASSIFIED] - 25) < 1e-6)
	sum := 0.0
	for g in s.genre_order do sum += q.values[g]
	testing.expect(t, abs(sum - 100) < 1e-6) // every bit of listening is in exactly one series
}

@(test)
test_no_unclassified_series_when_everything_is_annotated :: proc(t: ^testing.T) {
	r := resolver_for("A", "Rock")
	defer genre_resolver_destroy(&r)
	list := [?]Play{mk_play("2020-02-01T12:00:00Z", "T", "A")}
	s := compute_stats(list[:])
	compute_genre_stats(&s, list[:], &r)
	for g in s.genre_order do testing.expect(t, g != UNCLASSIFIED)
	testing.expect_value(t, s.genre_unclassified_pct, 0.0)
}

@(test)
test_report_lists_the_biggest_gaps :: proc(t: ^testing.T) {
	f := store_of(ann("A", "", "Rock", "llm", "2026-01-01"))
	r := build_genre_resolver(f, nil)
	defer genre_resolver_destroy(&r)
	list := [?]Play{
		mk_play("2020-02-01T12:00:00Z", "T", "A", ms = 100000),
		mk_play("2020-02-02T12:00:00Z", "T", "Small", ms = 100000),
		mk_play("2020-02-03T12:00:00Z", "T", "Big", ms = 900000),
	}
	text := annotations_report_text(f, {}, &r, list[:], 0)
	testing.expect(t, contains(text, "Biggest unclassified"))
	testing.expect(t, contains(text, "overrides.json"))
	big, small := index_of(text, "Big"), index_of(text, "Small")
	testing.expect(t, big >= 0 && small >= 0 && big < small) // ranked by listening time
}

index_of :: proc(s, sub: string) -> int {
	for i in 0 ..= len(s) - len(sub) do if s[i:i + len(sub)] == sub do return i
	return -1
}
