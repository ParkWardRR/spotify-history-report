package spotify_report

// Track identity (ROADMAP Phase 1). Answers "is this the same recording?",
// which is a different question from "does this sound similar?".
//
// What is established, in order of strength:
//   1. the Spotify track URI from the export (exact);
//   2. otherwise only the title/artist text, recorded as `Metadata_Only`.
// Nothing here merges recordings on fuzzy evidence. Near-duplicates and version
// families are *proposed* for review; only a user override in
// `.shr/overrides.json` changes how plays are counted, and deleting that file
// reverts it. External ids (MusicBrainz, AcoustID) are Phase 1b.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

SHR_DIR_NAME            :: ".shr"
IDENTITIES_FILE         :: "identities.json"
OVERRIDES_FILE          :: "overrides.json"
IDENTITY_SCHEMA_VERSION :: 1
MAX_MERGE_CHAIN         :: 16

shr_dir :: proc(data_dir: string) -> string {
	p, _ := filepath.join({data_dir, SHR_DIR_NAME}, context.allocator)
	return p
}

// ── Types ────────────────────────────────────────────────────────────────────

Identity_Source :: enum {
	Spotify_Uri,   // keyed by the export's spotify_track_uri
	Metadata_Only, // no URI in the record; keyed by exact title + artist text
}

Track_Identity :: struct {
	id:        string, // the URI, or "meta:<artist> | <title>"
	uri:       string,
	mbid:      string, // reserved for Phase 1b
	title:     string, // the name most plays of this id carry
	artist:    string,
	album:     string,
	source:    Identity_Source,
	plays:     int,
	alt_names: int, // other (title, artist) spellings seen under this id
}

// Version qualifiers that mark a different recording or edit. Tracks differing
// in these are never proposed as duplicates (see MusicBrainz's AcoustID guide).
Version_Marker :: enum u8 {
	Live, Remaster, Instrumental, Karaoke, Acoustic, Demo, Edit, Remix, Mono, Stereo, Reprise,
}
Version_Markers :: bit_set[Version_Marker; u16]

// A "song" is what the report counts: plays sharing exact title + artist text.
Song :: struct {
	artist:  string,
	title:   string,
	plays:   int,
	uris:    int, // distinct URIs seen with this exact text
	markers: Version_Markers,
}

Candidate_Kind :: enum {
	Near_Duplicate, // same normalised title and artist, differing only in case/punctuation
	Version_Family, // same base title, different version markers: distinct on purpose
}

Candidate :: struct {
	kind:       Candidate_Kind,
	artist:     string, // artist text of the most-played member
	title:      string, // readable title of the most-played member, qualifiers removed
	base_title: string, // the same, normalised: the grouping key
	songs:      [dynamic]Song,
	plays:      int,
}

Identity_Summary :: struct {
	plays:                 int,
	plays_by_uri:          int,
	plays_metadata_only:   int,
	plays_by_mbid:         int, // Phase 1b
	plays_by_fingerprint:  int, // Phase 1b
	identities:            int,
	identities_by_uri:     int,
	identities_meta_only:  int,
	songs:                 int,
	songs_multi_uri:       int, // one song text under several URIs (counted together)
	uris_multi_name:       int, // one URI under several spellings (counted apart)
	near_duplicate_groups: int,
	version_families:      int,
	groups_suppressed:     int, // hidden by keep_separate overrides
	plays_remapped:        int, // plays whose song was changed by a merge override
	merges_applied:        int,
}

Identity_Table :: struct {
	identities: [dynamic]Track_Identity,
	songs:      [dynamic]Song,
	candidates: [dynamic]Candidate,
	summary:    Identity_Summary,
}

// ── Text normalisation ───────────────────────────────────────────────────────

// Lower-cases ASCII, drops apostrophes, turns & into "and", and collapses every
// other punctuation run into a single space. Non-ASCII bytes pass through
// untouched, so "Beyoncé" stays distinct from "Beyonce": folding accents would
// be a fuzzy merge.
normalize_text :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	pending_space := false

	put :: proc(b: ^strings.Builder, pending: ^bool, c: u8) {
		if pending^ && strings.builder_len(b^) > 0 do strings.write_byte(b, ' ')
		pending^ = false
		strings.write_byte(b, c)
	}

	i := 0
	for i < len(s) {
		c := s[i]
		// Curly apostrophes U+2018 / U+2019 are dropped like the ASCII one.
		if c == 0xE2 && i + 2 < len(s) && s[i+1] == 0x80 && (s[i+2] == 0x98 || s[i+2] == 0x99) {
			i += 3
			continue
		}
		switch {
		case c >= 'A' && c <= 'Z': put(&b, &pending_space, c + 32)
		case (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c >= 0x80: put(&b, &pending_space, c)
		case c == '\'':
		case c == '&':
			pending_space = true
			for ch in transmute([]u8)string("and") do put(&b, &pending_space, ch)
			pending_space = true
		case: pending_space = true
		}
		i += 1
	}
	return strings.to_string(b)
}

normalize_artist :: proc(s: string, allocator := context.allocator) -> string {
	n := normalize_text(s, allocator)
	if strings.has_prefix(n, "the ") do return n[4:]
	return n
}

marker_of_word :: proc(w: string) -> (m: Version_Marker, ok: bool) {
	switch w {
	case "live":                                  return .Live, true
	case "remaster", "remastered", "remastering": return .Remaster, true
	case "instrumental":                          return .Instrumental, true
	case "karaoke":                               return .Karaoke, true
	case "acoustic":                              return .Acoustic, true
	case "demo":                                  return .Demo, true
	case "edit", "edited":                        return .Edit, true
	case "remix", "mix", "rmx":                   return .Remix, true
	case "mono":                                  return .Mono, true
	case "stereo":                                return .Stereo, true
	case "reprise":                               return .Reprise, true
	}
	return
}

// Markers named by any word of a parenthetical or " - " suffix.
segment_markers :: proc(seg: string) -> (out: Version_Markers) {
	start := -1
	for i in 0 ..= len(seg) {
		is_word := i < len(seg) && ((seg[i] >= 'a' && seg[i] <= 'z') || (seg[i] >= 'A' && seg[i] <= 'Z') || (seg[i] >= '0' && seg[i] <= '9'))
		if is_word {
			if start < 0 do start = i
		} else if start >= 0 {
			word := strings.to_lower(seg[start:i], context.temp_allocator)
			if m, ok := marker_of_word(word); ok do out += {m}
			start = -1
		}
	}
	return
}

// Splits a title into its base text and the version qualifiers it carries:
// "Song (Live at X) - Remastered 2011" → ("Song", {Live, Remaster}). Brackets
// without a qualifier, like "(feat. Y)", stay in the base. The returned base
// lives in the temp allocator.
split_title :: proc(title: string) -> (base: string, markers: Version_Markers) {
	kept := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(title) {
		c := title[i]
		if c == '(' || c == '[' {
			closer: u8 = ')' if c == '(' else ']'
			if j := strings.index_byte(title[i + 1:], closer); j >= 0 {
				if m := segment_markers(title[i + 1:i + 1 + j]); m != {} {
					markers += m
					i += j + 2
					continue
				}
			}
		}
		strings.write_byte(&kept, c)
		i += 1
	}
	s := strings.to_string(kept)
	if k := strings.index(s, " - "); k >= 0 {
		if m := segment_markers(s[k + 3:]); m != {} {
			markers += m
			s = s[:k]
		}
	}
	return strings.trim_space(s), markers
}

// ── Building the table ───────────────────────────────────────────────────────

identity_id :: proc(p: Play) -> string {
	if len(p.uri) > 0 do return p.uri
	return fmt.aprintf("meta:%s | %s", p.artist, p.track)
}

Id_Acc :: struct {
	uri:   string,
	album: string,
	plays: int,
	names: map[Track_Key]int,
}

// Resolves every play to an identity and groups songs into review candidates.
// `ov` (optional) only affects which candidates are shown.
build_identity_table :: proc(plays: []Play, ov: ^Overrides = nil) -> Identity_Table {
	t: Identity_Table
	t.summary.plays = len(plays)

	accs: map[string]Id_Acc
	song_plays: map[Track_Key]int
	defer {
		for _, &a in accs do delete(a.names)
		delete(accs); delete(song_plays)
	}

	for &p in plays {
		id := identity_id(p)
		if id not_in accs do accs[id] = Id_Acc{uri = p.uri}
		a := &accs[id]
		a.plays += 1
		a.names[text_key(p)] += 1
		if len(a.album) == 0 do a.album = p.album
		song_plays[text_key(p)] += 1
		if len(p.uri) > 0 { t.summary.plays_by_uri += 1 } else { t.summary.plays_metadata_only += 1 }
	}

	song_uris: map[Track_Key]int
	defer delete(song_uris)

	for id, &a in accs {
		best: Track_Key
		best_n := 0
		for k, n in a.names {
			if n > best_n || (n == best_n && (k.artist < best.artist || (k.artist == best.artist && k.track < best.track))) {
				best, best_n = k, n
			}
		}
		src := Identity_Source.Spotify_Uri if len(a.uri) > 0 else Identity_Source.Metadata_Only
		append(&t.identities, Track_Identity{
			id = id, uri = a.uri, title = best.track, artist = best.artist, album = a.album,
			source = src, plays = a.plays, alt_names = len(a.names) - 1,
		})
		if src == .Spotify_Uri {
			t.summary.identities_by_uri += 1
			if len(a.names) > 1 do t.summary.uris_multi_name += 1
			for k in a.names do song_uris[k] += 1
		} else {
			t.summary.identities_meta_only += 1
		}
	}
	slice.sort_by(t.identities[:], proc(a, b: Track_Identity) -> bool { return a.id < b.id })
	t.summary.identities = len(t.identities)

	for k, n in song_plays {
		m := song_markers(k.track)
		append(&t.songs, Song{artist = k.artist, title = k.track, plays = n, uris = song_uris[k], markers = m})
		if song_uris[k] > 1 do t.summary.songs_multi_uri += 1
	}
	slice.sort_by(t.songs[:], song_before)
	t.summary.songs = len(t.songs)

	build_candidates(&t, ov)
	return t
}

song_markers :: proc(title: string) -> Version_Markers {
	_, m := split_title(title)
	return m
}

song_before :: proc(a, b: Song) -> bool {
	if a.artist != b.artist do return a.artist < b.artist
	return a.title < b.title
}

build_candidates :: proc(t: ^Identity_Table, ov: ^Overrides) {
	groups: map[string][dynamic]int // normalised artist + base title → song indexes
	defer {
		for _, &g in groups do delete(g)
		delete(groups)
	}
	bases := make([]string, len(t.songs), context.temp_allocator)
	fulls := make([]string, len(t.songs), context.temp_allocator) // normalised, qualifiers kept

	for s, i in t.songs {
		base_raw, _ := split_title(s.title)
		base := normalize_text(base_raw, context.temp_allocator)
		if len(base) == 0 do base = normalize_text(s.title, context.temp_allocator)
		bases[i] = base
		fulls[i] = normalize_text(s.title, context.temp_allocator)
		key := strings.concatenate({normalize_artist(s.artist, context.temp_allocator), "\x1f", base})
		if key not_in groups do groups[key] = {}
		append(&groups[key], i)
	}

	for _, members in groups {
		if len(members) < 2 do continue

		// Near duplicate iff two songs differ only in case/punctuation/spacing
		// (same normalised title, qualifiers included). Songs that merely share a
		// base title are versions: "Song (Live in Paris)" and "Song (Live in
		// Tokyo)" are different recordings and must not be proposed as one.
		kind := Candidate_Kind.Version_Family
		for a in 0 ..< len(members) {
			for b in a + 1 ..< len(members) {
				if fulls[members[a]] == fulls[members[b]] do kind = .Near_Duplicate
			}
		}

		c := Candidate{kind = kind, base_title = strings.clone(bases[members[0]])}
		for i in members {
			append(&c.songs, t.songs[i])
			c.plays += t.songs[i].plays
		}
		slice.sort_by(c.songs[:], proc(a, b: Song) -> bool {
			if a.plays != b.plays do return a.plays > b.plays
			return song_before(a, b)
		})
		c.artist = c.songs[0].artist
		shown, _ := split_title(c.songs[0].title)
		c.title = strings.clone(shown)

		if ov != nil && all_pairs_separated(c.songs[:], ov) {
			t.summary.groups_suppressed += 1
			continue
		}
		append(&t.candidates, c)
		if kind == .Near_Duplicate { t.summary.near_duplicate_groups += 1 } else { t.summary.version_families += 1 }
	}

	slice.sort_by(t.candidates[:], proc(a, b: Candidate) -> bool {
		if a.kind != b.kind do return a.kind < b.kind
		if a.plays != b.plays do return a.plays > b.plays
		if a.artist != b.artist do return a.artist < b.artist
		return a.base_title < b.base_title
	})
}

// ── Overrides ────────────────────────────────────────────────────────────────

// How a track is named in overrides.json: by URI, or by exact artist + title.
Override_Ref :: struct {
	uri:    string,
	artist: string,
	title:  string,
}

Merge_Override :: struct {
	from: Override_Ref,
	into: Override_Ref,
}

Separate_Override :: struct {
	a: Override_Ref,
	b: Override_Ref,
}

// A genre (or other namespace) decided by the user. An empty title annotates
// the whole artist; an empty namespace means genre.
User_Annotation :: struct {
	artist:    string,
	title:     string,
	namespace: string,
	value:     string,
}

Overrides :: struct {
	version:       int,
	merges:        [dynamic]Merge_Override,
	keep_separate: [dynamic]Separate_Override,
	annotations:   [dynamic]User_Annotation,
	// Every play by these artists is dropped before anything is computed (for a
	// shared account where some listening belongs to someone else). Exact,
	// case-sensitive names, like the rest of the overrides.
	exclude_artists: [dynamic]string,
}

// Reads `.shr/overrides.json`. A missing file is fine (nothing overridden); a
// malformed one is an error, because silently ignoring a user's decision is
// worse than stopping.
load_overrides :: proc(data_dir: string) -> (ov: Overrides, err: string) {
	path, _ := filepath.join({shr_dir(data_dir), OVERRIDES_FILE}, context.allocator)
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil do return {}, ""
	defer delete(data)
	return parse_overrides(data, path)
}

parse_overrides :: proc(data: []u8, label: string) -> (ov: Overrides, err: string) {
	val, perr := json.parse(data, allocator = context.temp_allocator)
	if perr != nil do return {}, fmt.aprintf("%s is not valid JSON (%v)", label, perr)

	if e := check_keys(val, {"version", "merges", "keep_separate", "annotations", "exclude_artists"}, label); len(e) > 0 do return {}, e
	root := val.(json.Object)

	check_list :: proc(root: json.Object, field: string, pair: [2]string, label: string) -> string {
		raw, present := root[field]
		if !present do return ""
		arr, is_arr := raw.(json.Array)
		if !is_arr do return fmt.aprintf("%s: \"%s\" must be a list", label, field)
		for item, i in arr {
			where_ := fmt.aprintf("%s: %s[%d]", label, field, i)
			if e := check_keys(item, {pair[0], pair[1]}, where_); len(e) > 0 do return e
			obj := item.(json.Object)
			for side in pair {
				ref, has := obj[side]
				if !has do return fmt.aprintf("%s: missing \"%s\"", where_, side)
				if e := check_keys(ref, {"uri", "artist", "title"}, fmt.aprintf("%s.%s", where_, side)); len(e) > 0 do return e
			}
		}
		return ""
	}
	if e := check_list(root, "merges", {"from", "into"}, label); len(e) > 0 do return {}, e
	if e := check_list(root, "keep_separate", {"a", "b"}, label); len(e) > 0 do return {}, e

	if raw, present := root["annotations"]; present {
		arr, is_arr := raw.(json.Array)
		if !is_arr do return {}, fmt.aprintf("%s: \"annotations\" must be a list", label)
		for item, i in arr {
			where_ := fmt.aprintf("%s: annotations[%d]", label, i)
			if e := check_keys(item, {"artist", "title", "namespace", "value"}, where_); len(e) > 0 do return {}, e
		}
	}

	if raw, present := root["exclude_artists"]; present {
		arr, is_arr := raw.(json.Array)
		if !is_arr do return {}, fmt.aprintf("%s: \"exclude_artists\" must be a list of artist names", label)
		for item, i in arr {
			name, is_str := item.(json.String)
			if !is_str || len(name) == 0 {
				return {}, fmt.aprintf("%s: exclude_artists[%d] must be a non-empty artist name", label, i)
			}
		}
	}

	if uerr := json.unmarshal(data, &ov); uerr != nil do return {}, fmt.aprintf("%s: %v", label, uerr)
	for &u, i in ov.annotations {
		where_ := fmt.aprintf("%s: annotations[%d]", label, i)
		if len(u.artist) == 0 do return {}, fmt.aprintf("%s: missing \"artist\"", where_)
		if len(u.namespace) == 0 do u.namespace = NS_GENRE
		if p := validate_annotation(u.namespace, u.value); len(p) > 0 do return {}, fmt.aprintf("%s: %s", where_, p)
	}
	if ov.version != 0 && ov.version != 1 {
		return {}, fmt.aprintf("%s: unsupported version %d (this build reads version 1)", label, ov.version)
	}
	return ov, ""
}

// Rejects objects with keys outside `allowed`, so a typo such as "merge" can't
// be silently ignored.
check_keys :: proc(v: json.Value, allowed: []string, where_: string) -> string {
	obj, ok := v.(json.Object)
	if !ok do return fmt.aprintf("%s: expected an object", where_)
	for key in obj {
		found := false
		for a in allowed do if a == key { found = true; break }
		if !found do return fmt.aprintf("%s: unknown key \"%s\" (expected: %s)", where_, key, strings.join(allowed, ", ", context.temp_allocator))
	}
	return ""
}

// What the identity layer knows about the export, for resolving merge references.
Identity_Index :: struct {
	by_uri:  map[string]Track_Key, // uri → its identity (primary title and artist, uri)
	by_text: map[Track_Key]Track_Key, // exact (title, artist) → its most-played identity
}

identity_index_destroy :: proc(ix: ^Identity_Index) {
	delete(ix.by_uri); delete(ix.by_text)
}

build_identity_index :: proc(table: Identity_Table) -> (ix: Identity_Index) {
	best_plays: map[Track_Key]int
	defer delete(best_plays)
	for id in table.identities {
		key := Track_Key{id.title, id.artist, id.uri}
		if id.source == .Spotify_Uri do ix.by_uri[id.uri] = key
		text := Track_Key{id.title, id.artist, ""}
		// The most-played identity speaks for the text; ties go to the lower id so
		// the choice never depends on iteration order.
		if cur, has := ix.by_text[text]; !has || id.plays > best_plays[text] || (id.plays == best_plays[text] && key.uri < cur.uri) {
			ix.by_text[text] = key
			best_plays[text] = id.plays
		}
	}
	return
}

// A reference resolved to an identity. A text reference means every URI that
// carries that exact title and artist, and stands for the most-played of them;
// text that isn't in the export names a new, URI-less identity.
resolve_ref :: proc(r: Override_Ref, ix: Identity_Index) -> (k: Track_Key, ok: bool) {
	if len(r.artist) > 0 && len(r.title) > 0 {
		text := Track_Key{r.title, r.artist, ""}
		if known, has := ix.by_text[text]; has do return known, true
		return text, true
	}
	if len(r.uri) > 0 {
		k, ok = ix.by_uri[r.uri]
		return
	}
	return
}

ref_form_ok :: proc(r: Override_Ref) -> bool {
	has_text := len(r.artist) > 0 || len(r.title) > 0
	if len(r.uri) > 0 do return !has_text
	return len(r.artist) > 0 && len(r.title) > 0
}

all_pairs_separated :: proc(songs: []Song, ov: ^Overrides) -> bool {
	for a in 0 ..< len(songs) {
		for b in a + 1 ..< len(songs) {
			found := false
			for sep in ov.keep_separate {
				ka := Track_Key{sep.a.title, sep.a.artist, ""}
				kb := Track_Key{sep.b.title, sep.b.artist, ""}
				x := Track_Key{songs[a].title, songs[a].artist, ""}
				y := Track_Key{songs[b].title, songs[b].artist, ""}
				if (ka == x && kb == y) || (ka == y && kb == x) { found = true; break }
			}
			if !found do return false
		}
	}
	return true
}

// Gives every play the title and artist its URI carries most often, so one
// URI is always one track however Spotify's metadata drifted. The skip tally is
// keyed the same way and follows. Returns how many plays were renamed.
canonicalize_uri_names :: proc(plays: []Play, table: Identity_Table, tally: ^Skip_Tally = nil) -> (renamed: int) {
	ix := build_identity_index(table)
	defer identity_index_destroy(&ix)
	for &p in plays {
		if len(p.uri) == 0 do continue
		if k, ok := ix.by_uri[p.uri]; ok && (k.track != p.track || k.artist != p.artist) {
			p.track, p.artist = k.track, k.artist
			renamed += 1
		}
	}
	if tally != nil do remap_tally(tally, proc(k: Track_Key, ctx: rawptr) -> Track_Key {
		ix := (^Identity_Index)(ctx)
		if len(k.uri) > 0 { if c, ok := ix.by_uri[k.uri]; ok do return c }
		return k
	}, &ix)
	return
}

remap_tally :: proc(tally: ^Skip_Tally, f: proc(k: Track_Key, ctx: rawptr) -> Track_Key, ctx: rawptr) {
	remapped: map[Track_Key]int
	for k, n in tally.track_skips do remapped[f(k, ctx)] += n
	delete(tally.track_skips)
	tally.track_skips = remapped
}

Merge_Plan :: struct {
	ix:         Identity_Index,
	uri_remap:  map[string]Track_Key,
	text_remap: map[Track_Key]Track_Key, // exact (title, artist, "") → identity
}

merge_plan_destroy :: proc(m: ^Merge_Plan) {
	identity_index_destroy(&m.ix); delete(m.uri_remap); delete(m.text_remap)
}

// Follows merges from `k` to where it ends up. `ok` is false after MAX_MERGE_CHAIN
// hops, which means the merges loop.
follow_merges :: proc(m: ^Merge_Plan, k: Track_Key) -> (cur: Track_Key, ok: bool) {
	cur = k
	if len(cur.uri) > 0 { if c, has := m.ix.by_uri[cur.uri]; has do cur = c }
	for _ in 0 ..< MAX_MERGE_CHAIN {
		if len(cur.uri) > 0 {
			if next, has := m.uri_remap[cur.uri]; has && next != cur { cur = next; continue }
		}
		if next, has := m.text_remap[Track_Key{cur.track, cur.artist, ""}]; has && next != cur { cur = next; continue }
		return cur, true
	}
	return cur, false
}

// Applies merge overrides by rewriting the identity (title, artist, URI) of the
// affected plays. A reference by URI is exactly that URI. A reference by text
// is every URI carrying that title and artist; as a target it stands for the
// most-played of them and pulls the others in. Returns how many plays changed.
// Reversible by deleting the override: the export is never modified and the
// rewrite happens on every run.
apply_overrides :: proc(plays: []Play, ov: Overrides, table: Identity_Table, tally: ^Skip_Tally = nil) -> (changed: int, err: string) {
	if len(ov.merges) == 0 do return

	plan := Merge_Plan{ix = build_identity_index(table)}
	defer merge_plan_destroy(&plan)

	for m, i in ov.merges {
		if !ref_form_ok(m.from) do return 0, fmt.aprintf("merges[%d].from: give either \"uri\" or both \"artist\" and \"title\"", i)
		if !ref_form_ok(m.into) do return 0, fmt.aprintf("merges[%d].into: give either \"uri\" or both \"artist\" and \"title\"", i)
		target, ok := resolve_ref(m.into, plan.ix)
		if !ok do return 0, fmt.aprintf("merges[%d].into: %s is not in this export", i, m.into.uri)

		if len(m.from.uri) > 0 {
			if m.from.uri not_in plan.ix.by_uri do return 0, fmt.aprintf("merges[%d].from: %s is not in this export", i, m.from.uri)
			plan.uri_remap[m.from.uri] = target
		} else {
			from := Track_Key{m.from.title, m.from.artist, ""}
			if from == (Track_Key{target.track, target.artist, ""}) do return 0, fmt.aprintf("merges[%d]: merges a track into itself", i)
			plan.text_remap[from] = target
		}
		// Naming the target by text means all of its URIs, so they join the primary.
		if len(m.into.uri) == 0 {
			text := Track_Key{m.into.title, m.into.artist, ""}
			if _, taken := plan.text_remap[text]; !taken do plan.text_remap[text] = target
		}
	}

	for uri, k in plan.uri_remap {
		if _, ok := follow_merges(&plan, plan.ix.by_uri[uri]); !ok do return 0, fmt.aprintf("merge cycle involving %s", uri)
		_ = k
	}
	for from in plan.text_remap {
		start := plan.ix.by_text[from] or_else from
		if _, ok := follow_merges(&plan, start); !ok do return 0, fmt.aprintf("merge cycle involving %q by %q", from.track, from.artist)
	}

	for &p in plays {
		before := play_key(p)
		target, _ := follow_merges(&plan, before)
		if target != before {
			p.track, p.artist, p.uri = target.track, target.artist, target.uri
			changed += 1
		}
	}

	// The skip tally is keyed like the plays, so it follows the same merges.
	if tally != nil do remap_tally(tally, proc(k: Track_Key, ctx: rawptr) -> Track_Key {
		target, _ := follow_merges((^Merge_Plan)(ctx), k)
		return target
	}, &plan)
	return
}

// ── Persistence and reporting ────────────────────────────────────────────────

IDENTITIES_LIST_CAP :: 100_000

identities_json :: proc(t: Identity_Table) -> string {
	b := strings.builder_make()
	w :: strings.write_string
	str :: proc(b: ^strings.Builder, s: string) {
		strings.write_byte(b, '"'); strings.write_string(b, json_escape(s)); strings.write_byte(b, '"')
	}
	num :: proc(b: ^strings.Builder, n: int) { strings.write_string(b, fmt.tprintf("%d", n)) }

	w(&b, "{\"schema_version\":"); num(&b, IDENTITY_SCHEMA_VERSION)
	w(&b, ",\"tool\":\"spotify-history-report\",\"summary\":")
	summary_json(&b, t.summary)

	w(&b, ",\"identities\":[")
	for id, i in t.identities {
		if i >= IDENTITIES_LIST_CAP do break
		if i > 0 do w(&b, ",")
		w(&b, "{\"id\":"); str(&b, id.id)
		w(&b, ",\"uri\":"); if len(id.uri) > 0 { str(&b, id.uri) } else { w(&b, "null") }
		w(&b, ",\"mbid\":"); if len(id.mbid) > 0 { str(&b, id.mbid) } else { w(&b, "null") }
		w(&b, ",\"title\":"); str(&b, id.title)
		w(&b, ",\"artist\":"); str(&b, id.artist)
		w(&b, ",\"album\":"); str(&b, id.album)
		w(&b, ",\"source\":"); str(&b, "spotify_uri" if id.source == .Spotify_Uri else "metadata_only")
		w(&b, ",\"plays\":"); num(&b, id.plays)
		w(&b, ",\"alt_names\":"); num(&b, id.alt_names)
		w(&b, "}")
	}
	w(&b, "],\"candidates\":[")
	for c, i in t.candidates {
		if i > 0 do w(&b, ",")
		w(&b, "{\"kind\":"); str(&b, "near_duplicate" if c.kind == .Near_Duplicate else "version_family")
		w(&b, ",\"artist\":"); str(&b, c.artist)
		w(&b, ",\"title\":"); str(&b, c.title)
		w(&b, ",\"base_title\":"); str(&b, c.base_title)
		w(&b, ",\"plays\":"); num(&b, c.plays)
		w(&b, ",\"songs\":[")
		for s, j in c.songs {
			if j > 0 do w(&b, ",")
			w(&b, "{\"artist\":"); str(&b, s.artist)
			w(&b, ",\"title\":"); str(&b, s.title)
			w(&b, ",\"plays\":"); num(&b, s.plays)
			w(&b, ",\"uris\":"); num(&b, s.uris)
			w(&b, "}")
		}
		w(&b, "]}")
	}
	w(&b, "]}")
	return strings.to_string(b)
}

summary_json :: proc(b: ^strings.Builder, s: Identity_Summary) {
	strings.write_string(b, fmt.tprintf(
		"%s\"plays\":%d,\"plays_by_uri\":%d,\"plays_metadata_only\":%d,\"plays_by_mbid\":%d,\"plays_by_fingerprint\":%d,\"identities\":%d,\"songs\":%d,\"songs_multi_uri\":%d,\"uris_multi_name\":%d,\"near_duplicate_groups\":%d,\"version_families\":%d,\"groups_suppressed\":%d,\"plays_remapped\":%d,\"merges_applied\":%d%s",
		"{", s.plays, s.plays_by_uri, s.plays_metadata_only, s.plays_by_mbid, s.plays_by_fingerprint,
		s.identities, s.songs, s.songs_multi_uri, s.uris_multi_name, s.near_duplicate_groups,
		s.version_families, s.groups_suppressed, s.plays_remapped, s.merges_applied, "}"))
}

// Best-effort write of the derived identity table. Never fatal: it is a cache.
save_identities :: proc(data_dir: string, t: Identity_Table) -> bool {
	dir := shr_dir(data_dir)
	if err := os.make_directory_all(dir, {.Read_User, .Write_User, .Execute_User}); err != nil && err != .Exist do return false
	path, _ := filepath.join({dir, IDENTITIES_FILE}, context.allocator)
	data := identities_json(t)
	defer delete(data)
	return os.write_entire_file(path, transmute([]u8)data) == nil
}

pct :: proc(n, of: int) -> f64 {
	return f64(n) * 100 / f64(max(of, 1))
}

// Plain-text coverage report for `--identities`.
identity_report_text :: proc(t: Identity_Table, max_groups := 25) -> string {
	b := strings.builder_make()
	s := t.summary
	w :: strings.write_string
	line :: proc(b: ^strings.Builder, args: ..any) { strings.write_string(b, fmt.tprintln(..args, sep = "")) }

	line(&b, "Track identity")
	line(&b, "  plays            ", fmt_int(s.plays))
	line(&b, "    by Spotify URI ", fmt_int(s.plays_by_uri), fmt.tprintf("  (%.1f%%)", pct(s.plays_by_uri, s.plays)))
	line(&b, "    by MusicBrainz ", fmt_int(s.plays_by_mbid), "  (not yet looked up)")
	line(&b, "    by fingerprint ", fmt_int(s.plays_by_fingerprint), "  (needs local audio)")
	line(&b, "    metadata only  ", fmt_int(s.plays_metadata_only), fmt.tprintf("  (%.1f%%, unresolved)", pct(s.plays_metadata_only, s.plays)))
	line(&b, "  identities       ", fmt_int(s.identities), "  (", fmt_int(s.identities_by_uri), " URI, ", fmt_int(s.identities_meta_only), " metadata-only)")
	line(&b, "  songs            ", fmt_int(s.songs), "  (exact title + artist)")
	line(&b, "  The report counts each URI as its own track.")
	if s.songs_multi_uri > 0 {
		line(&b, "  ", fmt_int(s.songs_multi_uri), " songs appear under several URIs and are counted apart (listed below)")
	}
	if s.uris_multi_name > 0 {
		line(&b, "  ", fmt_int(s.uris_multi_name), " URIs carry several spellings; each is counted as one track under its most-played spelling")
	}
	if s.merges_applied > 0 {
		line(&b, "  overrides        ", fmt_int(s.merges_applied), " merges rewrote ", fmt_int(s.plays_remapped), " plays")
	}
	line(&b, "")

	multi_uri_section(&b, t, max_groups)

	if len(t.candidates) == 0 {
		line(&b, "No duplicate or version candidates.")
		return strings.to_string(b)
	}
	line(&b, "Review candidates (never merged automatically)")
	line(&b, "  ", fmt_int(s.near_duplicate_groups), " near-duplicate groups, ", fmt_int(s.version_families), " version families")
	if s.groups_suppressed > 0 {
		line(&b, "  ", fmt_int(s.groups_suppressed), " more hidden by keep_separate overrides")
	}
	for c, i in t.candidates {
		if i >= max_groups {
			line(&b, "  … and ", fmt_int(len(t.candidates) - max_groups), " more (see .shr/identities.json)")
			break
		}
		label := "near-duplicate" if c.kind == .Near_Duplicate else "versions"
		line(&b, "")
		line(&b, "  [", label, "] ", c.artist, " — ", c.title, "  (", fmt_int(c.plays), " plays)")
		for song in c.songs {
			line(&b, "      ", fmt_int(song.plays), "×  ", song.title)
		}
	}
	return strings.to_string(b)
}

// The same title and artist under several URIs. They are counted apart, so this
// is the list to check when a favourite looks under-counted; one override line
// per pair joins them.
multi_uri_section :: proc(b: ^strings.Builder, t: Identity_Table, max_groups: int) {
	Group :: struct { title, artist: string, ids: [dynamic]Track_Identity, plays: int }
	groups: map[Track_Key]Group
	defer { for _, &g in groups do delete(g.ids); delete(groups) }
	for id in t.identities {
		if id.source != .Spotify_Uri do continue
		k := Track_Key{id.title, id.artist, ""}
		g := groups[k]
		g.title, g.artist = id.title, id.artist
		append(&g.ids, id)
		g.plays += id.plays
		groups[k] = g
	}
	list: [dynamic]Group
	defer delete(list)
	for _, g in groups do if len(g.ids) > 1 do append(&list, g)
	if len(list) == 0 do return
	slice.sort_by(list[:], proc(a, b: Group) -> bool {
		if a.plays != b.plays do return a.plays > b.plays
		if a.artist != b.artist do return a.artist < b.artist
		return a.title < b.title
	})

	line :: proc(b: ^strings.Builder, args: ..any) { strings.write_string(b, fmt.tprintln(..args, sep = "")) }
	line(b, "Same title under several URIs (counted apart; join with a merge if they are one recording)")
	for g, i in list {
		if i >= max_groups {
			line(b, "  … and ", fmt_int(len(list) - max_groups), " more")
			break
		}
		slice.sort_by(g.ids[:], proc(a, b: Track_Identity) -> bool {
			if a.plays != b.plays do return a.plays > b.plays
			return a.uri < b.uri
		})
		line(b, "  ", g.artist, " — ", g.title, "  (", fmt_int(g.plays), " plays, ", fmt_int(len(g.ids)), " URIs)")
		for id, j in g.ids {
			line(b, "      ", fmt_int(id.plays), "×  ", id.uri, "  ", id.album)
			if j > 0 {
				line(b, "         {\"from\": {\"uri\": \"", id.uri, "\"}, \"into\": {\"uri\": \"", g.ids[0].uri, "\"}}")
			}
		}
	}
	line(b, "")
}
