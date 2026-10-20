package spotify_report

import "core:encoding/json"
import "core:fmt"
import "core:testing"

// ── Helpers ──────────────────────────────────────────────────────────────────

mk_uri_play :: proc(ts, track, artist, uri: string) -> Play {
	p := mk_play(ts, track, artist)
	p.uri = uri
	return p
}

// ── Normalisation and version markers ────────────────────────────────────────

@(test)
test_normalize_text :: proc(t: ^testing.T) {
	cases := [?][2]string{
		{"Don't Stop", "dont stop"},
		{"Don’t Stop", "dont stop"},
		{"Rock & Roll", "rock and roll"},
		{"  A--B  ", "a b"},
		{"Song!!!", "song"},
		{"Beyoncé", "beyoncé"}, // accents are not folded: that would be a fuzzy merge
		{"", ""},
	}
	for c in cases do testing.expect_value(t, normalize_text(c[0], context.temp_allocator), c[1])
	testing.expect_value(t, normalize_artist("The Beatles", context.temp_allocator), "beatles")
	testing.expect_value(t, normalize_artist("Theory of a Deadman", context.temp_allocator), "theory of a deadman")
}

@(test)
test_split_title_finds_version_qualifiers :: proc(t: ^testing.T) {
	cases := [?]struct{ title, base: string, markers: Version_Markers }{
		{"Song", "Song", {}},
		{"Song (Live at Wembley) - Remastered 2011", "Song", {.Live, .Remaster}},
		{"Song [Mono]", "Song", {.Mono}},
		{"Song - Radio Edit", "Song", {.Edit}},
		{"Song (Instrumental)", "Song", {.Instrumental}},
		{"Song (feat. Someone)", "Song (feat. Someone)", {}}, // a credit, not a version
		{"Live and Let Die", "Live and Let Die", {}},         // outside brackets: ordinary words
		{"Part - One", "Part - One", {}},
		{"Song (Live", "Song (Live", {}},                     // unbalanced: no crash
		{"Song (Extended Mix)", "Song", {.Remix}},
	}
	for c in cases {
		base, m := split_title(c.title)
		testing.expectf(t, base == c.base, "%q: base %q, want %q", c.title, base, c.base)
		testing.expectf(t, m == c.markers, "%q: markers %v, want %v", c.title, m, c.markers)
	}
}

// ── Resolution ───────────────────────────────────────────────────────────────

@(test)
test_plays_resolve_by_uri_or_stay_metadata_only :: proc(t: ^testing.T) {
	plays := [?]Play{
		mk_uri_play("2020-01-01T12:00:00Z", "A", "X", "spotify:track:1"),
		mk_uri_play("2020-01-02T12:00:00Z", "A", "X", "spotify:track:1"),
		mk_play("2020-01-03T12:00:00Z", "B", "X"),
		mk_play("2020-01-04T12:00:00Z", "B", "X"),
		mk_play("2020-01-05T12:00:00Z", "B", "Y"),
	}
	tbl := build_identity_table(plays[:])
	s := tbl.summary
	testing.expect_value(t, s.plays, 5)
	testing.expect_value(t, s.plays_by_uri, 2)
	testing.expect_value(t, s.plays_metadata_only, 3)
	testing.expect_value(t, s.identities, 3) // one URI + two text-only (B/X, B/Y)
	testing.expect_value(t, s.identities_by_uri, 1)
	testing.expect_value(t, s.identities_meta_only, 2)
	testing.expect_value(t, s.plays_by_mbid, 0)
	testing.expect_value(t, s.plays_by_uri + s.plays_metadata_only, s.plays) // every play is accounted for
}

@(test)
test_one_song_under_several_uris_and_one_uri_under_several_names :: proc(t: ^testing.T) {
	plays := [?]Play{
		mk_uri_play("2020-01-01T12:00:00Z", "Hit", "X", "spotify:track:album"),
		mk_uri_play("2020-01-02T12:00:00Z", "Hit", "X", "spotify:track:compilation"),
		mk_uri_play("2020-01-03T12:00:00Z", "Old Name", "Z", "spotify:track:renamed"),
		mk_uri_play("2020-01-04T12:00:00Z", "New Name", "Z", "spotify:track:renamed"),
		mk_uri_play("2020-01-05T12:00:00Z", "New Name", "Z", "spotify:track:renamed"),
	}
	tbl := build_identity_table(plays[:])
	testing.expect_value(t, tbl.summary.songs, 3) // Hit, Old Name, New Name
	testing.expect_value(t, tbl.summary.songs_multi_uri, 1)
	testing.expect_value(t, tbl.summary.uris_multi_name, 1)

	for id in tbl.identities {
		if id.uri == "spotify:track:renamed" {
			testing.expect_value(t, id.title, "New Name") // the spelling most plays carry
			testing.expect_value(t, id.alt_names, 1)
		}
	}
	// Same text under two URIs is counted as one song by the report.
	s := compute_stats(plays[:])
	testing.expect_value(t, s.unique_tracks, 3)
}

@(test)
test_identity_primary_name_ties_break_alphabetically :: proc(t: ^testing.T) {
	a := [?]Play{
		mk_uri_play("2020-01-01T12:00:00Z", "Zed", "X", "spotify:track:1"),
		mk_uri_play("2020-01-02T12:00:00Z", "Abe", "X", "spotify:track:1"),
	}
	b := [?]Play{a[1], a[0]}
	for plays in ([?][]Play{a[:], b[:]}) {
		tbl := build_identity_table(plays)
		testing.expect_value(t, tbl.identities[0].title, "Abe")
	}
}

// ── Candidates ───────────────────────────────────────────────────────────────

@(test)
test_near_duplicates_and_versions_are_proposed_not_merged :: proc(t: ^testing.T) {
	plays := [?]Play{
		mk_uri_play("2020-01-01T12:00:00Z", "Don't Stop", "Band", "spotify:track:1"),
		mk_uri_play("2020-01-02T12:00:00Z", "Dont Stop", "Band", "spotify:track:2"),   // punctuation only
		mk_uri_play("2020-01-03T12:00:00Z", "Anthem", "Band", "spotify:track:3"),
		mk_uri_play("2020-01-04T12:00:00Z", "Anthem (Live in Paris)", "Band", "spotify:track:4"),
		mk_uri_play("2020-01-05T12:00:00Z", "Anthem (Live in Tokyo)", "Band", "spotify:track:5"),
		mk_uri_play("2020-01-06T12:00:00Z", "Lonely", "Band", "spotify:track:6"),
		mk_uri_play("2020-01-07T12:00:00Z", "Lonely", "Other Band", "spotify:track:7"), // different artist
	}
	tbl := build_identity_table(plays[:])
	testing.expect_value(t, tbl.summary.near_duplicate_groups, 1)
	testing.expect_value(t, tbl.summary.version_families, 1)

	for c in tbl.candidates {
		switch c.kind {
		case .Near_Duplicate:
			testing.expect_value(t, len(c.songs), 2)
			testing.expect_value(t, c.base_title, "dont stop")
		case .Version_Family:
			testing.expect_value(t, len(c.songs), 3) // studio + two distinct live recordings
		}
	}
	// Proposed, never merged: counts are untouched.
	testing.expect_value(t, compute_stats(plays[:]).unique_tracks, 7)
}

@(test)
test_the_prefix_and_case_do_not_hide_duplicates :: proc(t: ^testing.T) {
	plays := [?]Play{
		mk_uri_play("2020-01-01T12:00:00Z", "Song", "The Band", "spotify:track:1"),
		mk_uri_play("2020-01-02T12:00:00Z", "SONG", "Band", "spotify:track:2"),
	}
	tbl := build_identity_table(plays[:])
	testing.expect_value(t, tbl.summary.near_duplicate_groups, 1)
}

// ── Overrides ────────────────────────────────────────────────────────────────

parse_ov :: proc(src: string) -> (Overrides, string) {
	return parse_overrides(transmute([]u8)src, "overrides.json")
}

@(test)
test_overrides_parse_and_reject_mistakes :: proc(t: ^testing.T) {
	ov, err := parse_ov(`{"version":1,"merges":[{"from":{"artist":"B","title":"Dont"},"into":{"artist":"B","title":"Don't"}}],
		"keep_separate":[{"a":{"artist":"B","title":"X"},"b":{"artist":"B","title":"Y"}}]}`)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(ov.merges), 1)
	testing.expect_value(t, len(ov.keep_separate), 1)
	testing.expect_value(t, ov.merges[0].into.title, "Don't")

	_, err = parse_ov(`{"merge":[]}`) // typo for "merges"
	testing.expect(t, len(err) > 0 && contains(err, "unknown key"))
	_, err = parse_ov(`{"merges":[{"from":{"artist":"B","tittle":"x"},"into":{"artist":"B","title":"y"}}]}`)
	testing.expect(t, len(err) > 0 && contains(err, "tittle"))
	_, err = parse_ov(`{"merges":[{"from":{"uri":"u"}}]}`)
	testing.expect(t, len(err) > 0 && contains(err, "missing"))
	_, err = parse_ov(`{"version":2}`)
	testing.expect(t, len(err) > 0 && contains(err, "version"))
	_, err = parse_ov(`{not json`)
	testing.expect(t, len(err) > 0)
	_, err = parse_ov(`{"merges":"x"}`)
	testing.expect(t, len(err) > 0 && contains(err, "list"))
}

contains :: proc(s, sub: string) -> bool {
	for i in 0 ..= len(s) - len(sub) do if s[i:i + len(sub)] == sub do return true
	return false
}

@(test)
test_merge_override_rewrites_plays_and_is_reversible :: proc(t: ^testing.T) {
	make_plays :: proc() -> [3]Play {
		return {
			mk_uri_play("2020-01-01T12:00:00Z", "Don't Stop", "Band", "spotify:track:1"),
			mk_uri_play("2020-01-02T12:00:00Z", "Dont Stop", "Band", "spotify:track:2"),
			mk_uri_play("2020-01-03T12:00:00Z", "Dont Stop", "Band", "spotify:track:2"),
		}
	}
	plays := make_plays()
	ov, err := parse_ov(`{"merges":[{"from":{"artist":"Band","title":"Dont Stop"},"into":{"artist":"Band","title":"Don't Stop"}}]}`)
	testing.expect_value(t, err, "")

	tbl := build_identity_table(plays[:], &ov)
	changed, aerr := apply_overrides(plays[:], ov, tbl)
	testing.expect_value(t, aerr, "")
	testing.expect_value(t, changed, 2)
	testing.expect_value(t, compute_stats(plays[:]).unique_tracks, 1)
	testing.expect_value(t, build_identity_table(plays[:], &ov).summary.near_duplicate_groups, 0) // resolved

	// Reversible: without the override the same input is untouched.
	fresh := make_plays()
	testing.expect_value(t, compute_stats(fresh[:]).unique_tracks, 2)
}

@(test)
test_merge_by_uri_and_chains :: proc(t: ^testing.T) {
	plays := [?]Play{
		mk_uri_play("2020-01-01T12:00:00Z", "A", "X", "spotify:track:a"),
		mk_uri_play("2020-01-02T12:00:00Z", "B", "X", "spotify:track:b"),
		mk_uri_play("2020-01-03T12:00:00Z", "C", "X", "spotify:track:c"),
	}
	// uri b → text of a; then (X, A) → (X, C): a chain landing on C.
	ov, err := parse_ov(`{"merges":[
		{"from":{"uri":"spotify:track:b"},"into":{"uri":"spotify:track:a"}},
		{"from":{"artist":"X","title":"A"},"into":{"artist":"X","title":"C"}}]}`)
	testing.expect_value(t, err, "")
	tbl := build_identity_table(plays[:], &ov)
	_, aerr := apply_overrides(plays[:], ov, tbl)
	testing.expect_value(t, aerr, "")
	for p in plays do testing.expect_value(t, p.track, "C")
}

@(test)
test_bad_merges_are_rejected :: proc(t: ^testing.T) {
	plays := [?]Play{mk_uri_play("2020-01-01T12:00:00Z", "A", "X", "spotify:track:a")}
	tbl := build_identity_table(plays[:])
	cases := [?]string{
		`{"merges":[{"from":{"artist":"X","title":"A"},"into":{"artist":"X","title":"A"}}]}`,                     // into itself
		`{"merges":[{"from":{"uri":"spotify:track:zzz"},"into":{"artist":"X","title":"A"}}]}`,                    // unknown uri
		`{"merges":[{"from":{"artist":"X","title":"A"},"into":{"uri":"spotify:track:zzz"}}]}`,                    // unknown into
		`{"merges":[{"from":{"uri":"spotify:track:a","artist":"X"},"into":{"artist":"X","title":"B"}}]}`,         // both forms
		`{"merges":[{"from":{"artist":"X"},"into":{"artist":"X","title":"B"}}]}`,                                 // half a ref
		`{"merges":[{"from":{"artist":"X","title":"A"},"into":{"artist":"X","title":"B"}},
		            {"from":{"artist":"X","title":"B"},"into":{"artist":"X","title":"A"}}]}`,                     // cycle
	}
	for src, i in cases {
		ov, perr := parse_ov(src)
		testing.expectf(t, perr == "", "case %d should parse: %s", i, perr)
		_, aerr := apply_overrides(plays[:], ov, tbl)
		testing.expectf(t, len(aerr) > 0, "case %d should be rejected", i)
	}
}

@(test)
test_merge_remaps_the_skip_tally :: proc(t: ^testing.T) {
	plays := make([dynamic]Play, context.temp_allocator)
	for i in 0 ..< 15 {
		append(&plays, mk_uri_play(fmt.tprintf("2020-03-%02dT12:00:00Z", i + 1), "Dont Stop", "Band", "spotify:track:2"))
	}
	tally: Skip_Tally
	defer skip_tally_destroy(&tally)
	tally_record(&tally, 2020, Track_Key{"Dont Stop", "Band"}, .No, 5000) // a filtered short play of the old spelling

	ov, _ := parse_ov(`{"merges":[{"from":{"artist":"Band","title":"Dont Stop"},"into":{"artist":"Band","title":"Don't Stop"}}]}`)
	tbl := build_identity_table(plays[:], &ov)
	_, err := apply_overrides(plays[:], ov, tbl, &tally)
	testing.expect_value(t, err, "")
	testing.expect_value(t, tally.track_skips[Track_Key{"Don't Stop", "Band"}], 1) // followed the rename
	testing.expect_value(t, len(compute_stats(plays[:], &tally).never_skipped), 0)
}

@(test)
test_keep_separate_hides_a_candidate :: proc(t: ^testing.T) {
	plays := [?]Play{
		mk_uri_play("2020-01-01T12:00:00Z", "Don't Stop", "Band", "spotify:track:1"),
		mk_uri_play("2020-01-02T12:00:00Z", "Dont Stop", "Band", "spotify:track:2"),
	}
	ov, err := parse_ov(`{"keep_separate":[{"a":{"artist":"Band","title":"Dont Stop"},"b":{"artist":"Band","title":"Don't Stop"}}]}`)
	testing.expect_value(t, err, "")
	tbl := build_identity_table(plays[:], &ov)
	testing.expect_value(t, tbl.summary.near_duplicate_groups, 0)
	testing.expect_value(t, tbl.summary.groups_suppressed, 1)
	testing.expect_value(t, compute_stats(plays[:]).unique_tracks, 2) // and nothing was merged
}

// ── Persistence ──────────────────────────────────────────────────────────────

@(test)
test_identities_json_is_valid_and_reproducible :: proc(t: ^testing.T) {
	plays := [?]Play{
		mk_uri_play("2020-01-01T12:00:00Z", "Quote \" and \\ and \x01 control", "Band", "spotify:track:1"),
		mk_uri_play("2020-01-02T12:00:00Z", "Don't Stop", "Band", "spotify:track:2"),
		mk_uri_play("2020-01-03T12:00:00Z", "Dont Stop", "Band", "spotify:track:3"),
		mk_play("2020-01-04T12:00:00Z", "No Uri", "Band"),
	}
	j1 := identities_json(build_identity_table(plays[:]))
	j2 := identities_json(build_identity_table(plays[:]))
	testing.expect(t, j1 == j2)

	val, err := json.parse(transmute([]u8)j1, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	root := val.(json.Object)
	testing.expect_value(t, int(root["schema_version"].(json.Float)), IDENTITY_SCHEMA_VERSION)
	testing.expect_value(t, len(root["identities"].(json.Array)), 4)
	testing.expect_value(t, len(root["candidates"].(json.Array)), 1)
}

@(test)
test_sample_resolves_every_play_by_uri :: proc(t: ^testing.T) {
	c := make_clock("UTC")
	plays, tally, _ := load_sample(&c)
	defer { delete(plays); skip_tally_destroy(&tally) }
	tbl := build_identity_table(plays[:])
	testing.expect_value(t, tbl.summary.plays_metadata_only, 0)
	testing.expect_value(t, tbl.summary.plays_by_uri, len(plays))
	testing.expect_value(t, tbl.summary.songs, 36)
	testing.expect_value(t, len(tbl.candidates), 0)
}
