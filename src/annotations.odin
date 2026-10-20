package spotify_report

// Track annotations (ROADMAP Phase 2). Replaces the flat artist→genre map with
// records that say what was claimed, about what, by whom, and when:
//
//   artist  title   namespace  value        source  model   observed
//   "Daft"  ""      genre      Electronic   llm     claude  2026-10-19     (about the artist)
//   "Daft"  "Voyager" genre    Funk & Soul  user    ""      ""             (about one track)
//
// Rules this module enforces:
//   - "unknown" is the absence of an annotation, never the label "Other".
//     Other is a real answer the classifier may give; Unclassified is not.
//   - A value outside the namespace's vocabulary is rejected, not coerced.
//   - The user always wins, and a user decision is never overwritten by a
//     re-run of any other source.
//   - An unreadable annotations file is an error and is never overwritten.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

ANNOTATIONS_FILE           :: "annotations.json"
ANNOTATIONS_SCHEMA_VERSION :: 1
NS_GENRE                   :: "genre"
UNCLASSIFIED               :: "Unclassified"
UNCLASSIFIED_COLOR         :: "#e3e1dc"

KNOWN_NAMESPACES := [?]string{NS_GENRE, "subgenre", "mood", "instrumentation", "era", "language"}

// Lower value = higher priority when two sources disagree about the same
// target. User decisions come first. Among the rest the order is a fixed,
// documented policy, not a claim about accuracy: curated metadata, then a
// model that heard the audio, then a language model working from a name.
Annotation_Source :: enum {
	User,
	Musicbrainz,
	Sidecar,
	Lastfm,
	Llm,
}

source_name :: proc(s: Annotation_Source) -> string {
	switch s {
	case .User:        return "user"
	case .Musicbrainz: return "musicbrainz"
	case .Sidecar:     return "sidecar"
	case .Lastfm:      return "lastfm"
	case .Llm:         return "llm"
	}
	return "?"
}

parse_source :: proc(name: string) -> (s: Annotation_Source, ok: bool) {
	for v in Annotation_Source do if source_name(v) == name do return v, true
	return
}

// One record in `.shr/annotations.json`. An empty title means the annotation
// is about the whole artist.
Annotation :: struct {
	artist:     string,
	title:      string,
	namespace:  string,
	value:      string,
	source:     string,
	model:      string, // model id + revision for model-made annotations; empty if unknown
	confidence: Maybe(f64), // null where the source has no calibrated score
	observed:   string, // YYYY-MM-DD; empty if unknown
}

Annotation_File :: struct {
	schema_version: int,
	migrated_from:  string,
	annotations:    [dynamic]Annotation,
}

Annotations_Info :: struct {
	migrated: bool, // built from .genre_cache.json this run: the caller should save
	rejected: int,  // cached entries dropped because the label is not a known genre
	existed:  bool,
}

is_valid_genre :: proc(v: string) -> bool {
	for g in GENRE_ORDER_DEFAULT do if g == v do return true
	return false
}

valid_genre_list :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	for g, i in GENRE_ORDER_DEFAULT {
		if i > 0 do strings.write_string(&b, ", ")
		strings.write_string(&b, g)
	}
	return strings.to_string(b)
}

// Returns a problem description, or "" if (namespace, value) is acceptable.
validate_annotation :: proc(namespace, value: string) -> string {
	known := false
	for ns in KNOWN_NAMESPACES do if ns == namespace { known = true; break }
	if !known {
		return fmt.aprintf("unknown namespace \"%s\" (known: %s)", namespace, strings.join(KNOWN_NAMESPACES[:], ", ", context.temp_allocator))
	}
	if len(value) == 0 do return "empty value"
	if namespace == NS_GENRE && !is_valid_genre(value) {
		return fmt.aprintf("\"%s\" is not a known genre (valid: %s)", value, valid_genre_list())
	}
	return ""
}

today_string :: proc() -> string {
	dt, ok := time.time_to_datetime(time.now())
	if !ok do return ""
	return fmt.aprintf("%04d-%02d-%02d", dt.year, dt.month, dt.day)
}

// ── Loading, migrating, saving ───────────────────────────────────────────────

annotations_path :: proc(data_dir: string) -> string {
	p, _ := filepath.join({shr_dir(data_dir), ANNOTATIONS_FILE}, context.allocator)
	return p
}

// Reads `.shr/annotations.json`. When it does not exist yet, builds a store from
// a legacy `.genre_cache.json` (marked as LLM output of unknown model) so no
// earlier classification is lost; the caller saves it. A file that exists but
// cannot be read is an error: it is never replaced.
load_annotations :: proc(data_dir: string) -> (f: Annotation_File, info: Annotations_Info, err: string) {
	path := annotations_path(data_dir)
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err == nil {
		defer delete(data)
		info.existed = true
		f, err = parse_annotations(data, path)
		return
	}

	f.schema_version = ANNOTATIONS_SCHEMA_VERSION
	legacy, has := load_genre_cache(data_dir)
	if !has || len(legacy) == 0 do return
	defer delete(legacy)

	f.migrated_from = ".genre_cache.json"
	info.migrated = true
	artists := make([dynamic]string, context.temp_allocator)
	for a in legacy do append(&artists, a)
	slice.sort(artists[:])
	for a in artists {
		if len(a) == 0 || !is_valid_genre(legacy[a]) {
			info.rejected += 1
			continue
		}
		append(&f.annotations, Annotation{artist = a, namespace = NS_GENRE, value = legacy[a], source = source_name(.Llm)})
	}
	return
}

parse_annotations :: proc(data: []u8, label: string) -> (f: Annotation_File, err: string) {
	if uerr := json.unmarshal(data, &f); uerr != nil {
		return {}, fmt.aprintf("%s could not be read (%v). It was left untouched; fix or move it aside to continue.", label, uerr)
	}
	if f.schema_version != ANNOTATIONS_SCHEMA_VERSION {
		return {}, fmt.aprintf("%s has schema_version %d; this build reads version %d.", label, f.schema_version, ANNOTATIONS_SCHEMA_VERSION)
	}
	for a, i in f.annotations {
		where_ := fmt.aprintf("%s: annotations[%d]", label, i)
		if len(a.artist) == 0 do return {}, fmt.aprintf("%s: missing artist", where_)
		if _, ok := parse_source(a.source); !ok {
			return {}, fmt.aprintf("%s: unknown source \"%s\" (known: user, musicbrainz, sidecar, lastfm, llm)", where_, a.source)
		}
		if p := validate_annotation(a.namespace, a.value); len(p) > 0 do return {}, fmt.aprintf("%s: %s", where_, p)
	}
	return
}

annotation_before :: proc(a, b: Annotation) -> bool {
	if a.artist != b.artist do return a.artist < b.artist
	if a.title != b.title do return a.title < b.title
	if a.namespace != b.namespace do return a.namespace < b.namespace
	if a.source != b.source do return a.source < b.source
	if a.observed != b.observed do return a.observed < b.observed
	return a.value < b.value
}

annotations_json :: proc(f: Annotation_File) -> string {
	sorted := make([dynamic]Annotation, context.temp_allocator)
	append(&sorted, ..f.annotations[:])
	slice.stable_sort_by(sorted[:], annotation_before)

	b := strings.builder_make()
	q :: proc(b: ^strings.Builder, s: string) {
		strings.write_byte(b, '"'); strings.write_string(b, json_escape(s)); strings.write_byte(b, '"')
	}
	strings.write_string(&b, fmt.tprintf("{{\n  \"schema_version\": %d,\n", f.schema_version))
	if len(f.migrated_from) > 0 {
		strings.write_string(&b, "  \"migrated_from\": "); q(&b, f.migrated_from); strings.write_string(&b, ",\n")
	}
	strings.write_string(&b, "  \"annotations\": [")
	for a, i in sorted {
		strings.write_string(&b, "\n    " if i == 0 else ",\n    ")
		strings.write_string(&b, "{\"artist\": "); q(&b, a.artist)
		strings.write_string(&b, ", \"title\": "); q(&b, a.title)
		strings.write_string(&b, ", \"namespace\": "); q(&b, a.namespace)
		strings.write_string(&b, ", \"value\": "); q(&b, a.value)
		strings.write_string(&b, ", \"source\": "); q(&b, a.source)
		strings.write_string(&b, ", \"model\": "); q(&b, a.model)
		strings.write_string(&b, ", \"confidence\": ")
		if c, ok := a.confidence.?; ok { strings.write_string(&b, fmt.tprintf("%g", c)) } else { strings.write_string(&b, "null") }
		strings.write_string(&b, ", \"observed\": "); q(&b, a.observed)
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "\n  ]\n}\n" if len(sorted) > 0 else "]\n}\n")
	return strings.to_string(b)
}

// Writes the store atomically (temp file, then rename), so an interrupted run
// cannot leave a half-written file in place of a good one.
save_annotations :: proc(data_dir: string, f: Annotation_File) -> bool {
	dir := shr_dir(data_dir)
	if err := os.make_directory_all(dir, {.Read_User, .Write_User, .Execute_User}); err != nil && err != .Exist do return false
	path := annotations_path(data_dir)
	tmp := strings.concatenate({path, ".tmp"})
	defer delete(tmp)
	data := annotations_json(f)
	defer delete(data)
	if os.write_entire_file(tmp, transmute([]u8)data) != nil do return false
	return os.rename(tmp, path) == nil
}

// Appends the classifier's answers for the artists that were asked about. A
// label outside the vocabulary, or an artist nobody asked about, is counted and
// ignored: the artist stays unclassified rather than being filed under "Other".
add_llm_annotations :: proc(f: ^Annotation_File, answers: map[string]string, asked: []string, model, today: string) -> (added, rejected: int) {
	was_asked: map[string]bool
	defer delete(was_asked)
	for a in asked do was_asked[a] = true

	names := make([dynamic]string, context.temp_allocator)
	for a in answers do append(&names, a)
	slice.sort(names[:])
	for a in names {
		genre := answers[a]
		if !was_asked[a] || !is_valid_genre(genre) {
			rejected += 1
			continue
		}
		append(&f.annotations, Annotation{
			artist = a, namespace = NS_GENRE, value = genre,
			source = source_name(.Llm), model = model, observed = today,
		})
		added += 1
	}
	return
}

// ── Resolving a play's genre ─────────────────────────────────────────────────

Genre_Pick :: struct {
	genre:  string,
	source: Annotation_Source,
}

// Per-target winners of all genre annotations. A track-level pick is more
// specific than an artist-level one, but a user's decision beats any other
// source whichever level it is made at.
Genre_Resolver :: struct {
	by_track:        map[Track_Key]Genre_Pick,
	by_artist:       map[string]Genre_Pick,
	user_artists:    int,
	user_tracks:     int,
}

// True if `a` should replace `b` as the annotation for the same target:
// a better source wins; the same source is won by the most recent observation,
// and a later record in the file breaks a tie.
pick_replaces :: proc(new_pick: Genre_Pick, new_observed: string, old: Genre_Pick, old_observed: string) -> bool {
	if new_pick.source != old.source do return new_pick.source < old.source
	return new_observed >= old_observed
}

build_genre_resolver :: proc(f: Annotation_File, user: []User_Annotation) -> Genre_Resolver {
	r: Genre_Resolver
	observed_track: map[Track_Key]string
	observed_artist: map[string]string
	defer { delete(observed_track); delete(observed_artist) }

	consider :: proc(r: ^Genre_Resolver, ot: ^map[Track_Key]string, oa: ^map[string]string, artist, title, value, observed: string, src: Annotation_Source) {
		pick := Genre_Pick{value, src}
		if len(title) > 0 {
			k := Track_Key{title, artist, ""}
			if old, has := r.by_track[k]; !has || pick_replaces(pick, observed, old, ot^[k]) {
				r.by_track[k] = pick
				ot^[k] = observed
			}
		} else {
			if old, has := r.by_artist[artist]; !has || pick_replaces(pick, observed, old, oa^[artist]) {
				r.by_artist[artist] = pick
				oa^[artist] = observed
			}
		}
	}

	for a in f.annotations {
		if a.namespace != NS_GENRE do continue
		src, _ := parse_source(a.source)
		consider(&r, &observed_track, &observed_artist, a.artist, a.title, a.value, a.observed, src)
	}
	for u in user {
		if len(u.namespace) > 0 && u.namespace != NS_GENRE do continue
		consider(&r, &observed_track, &observed_artist, u.artist, u.title, u.value, "~", .User) // "~" sorts after any date
	}
	for _, p in r.by_artist do if p.source == .User do r.user_artists += 1
	for _, p in r.by_track do if p.source == .User do r.user_tracks += 1
	return r
}

genre_resolver_destroy :: proc(r: ^Genre_Resolver) {
	delete(r.by_track); delete(r.by_artist)
}

resolve_genre :: proc(r: ^Genre_Resolver, track, artist: string) -> (pick: Genre_Pick, ok: bool) {
	t, has_t := r.by_track[Track_Key{track, artist, ""}]
	a, has_a := r.by_artist[artist]
	switch {
	case has_t && t.source == .User: return t, true
	case has_a && a.source == .User: return a, true
	case has_t:                      return t, true
	case has_a:                      return a, true
	}
	return
}

has_artist_genre :: proc(r: ^Genre_Resolver, artist: string) -> bool {
	return artist in r.by_artist
}

// ── Report (`--annotations`) ─────────────────────────────────────────────────

annotations_report_text :: proc(f: Annotation_File, info: Annotations_Info, r: ^Genre_Resolver, plays: []Play, user_count: int) -> string {
	out := make([dynamic]string, context.temp_allocator)
	add :: proc(out: ^[dynamic]string, s: string) { append(out, s) }

	by_source: [Annotation_Source]int
	by_ns: map[string]int
	defer delete(by_ns)
	for a in f.annotations {
		src, _ := parse_source(a.source)
		by_source[src] += 1
		by_ns[a.namespace] += 1
	}

	add(&out, "Annotations")
	add(&out, fmt.tprintf("  stored       %s in .shr/%s", fmt_int(len(f.annotations)), ANNOTATIONS_FILE))
	parts := make([dynamic]string, context.temp_allocator)
	for s in Annotation_Source do if by_source[s] > 0 do append(&parts, fmt.tprintf("%s %s", source_name(s), fmt_int(by_source[s])))
	if len(parts) > 0 do add(&out, fmt.tprintf("  by source    %s", strings.join(parts[:], ", ", context.temp_allocator)))
	if user_count > 0 do add(&out, fmt.tprintf("  your overrides.json adds %d more (they always win)", user_count))
	if len(f.migrated_from) > 0 {
		add(&out, fmt.tprintf("  imported from %s (model unknown)", f.migrated_from))
	}
	if info.rejected > 0 {
		add(&out, fmt.tprintf("  %d cached labels were not valid genres and were left unclassified", info.rejected))
	}

	// Coverage by listening time.
	total_ms, unknown_ms: i64
	src_ms: [Annotation_Source]i64
	unknown_by_artist: map[string]i64
	defer delete(unknown_by_artist)
	for &p in plays {
		total_ms += p.ms
		if pick, ok := resolve_genre(r, p.track, p.artist); ok {
			src_ms[pick.source] += p.ms
		} else {
			unknown_ms += p.ms
			unknown_by_artist[p.artist] += p.ms
		}
	}
	add(&out, "")
	add(&out, "Genre coverage (by listening time)")
	add(&out, fmt.tprintf("  annotated    %.1f%%", 100 - pct_ms(unknown_ms, total_ms)))
	add(&out, fmt.tprintf("  unclassified %.1f%%   (kept separate from \"Other\", which is a real genre label)", pct_ms(unknown_ms, total_ms)))
	parts = make([dynamic]string, context.temp_allocator)
	for s in Annotation_Source do if src_ms[s] > 0 do append(&parts, fmt.tprintf("%s %.1f%%", source_name(s), pct_ms(src_ms[s], total_ms)))
	if len(parts) > 0 do add(&out, fmt.tprintf("  decided by   %s", strings.join(parts[:], ", ", context.temp_allocator)))

	if len(unknown_by_artist) > 0 {
		Row :: struct { artist: string, ms: i64 }
		rows := make([dynamic]Row, context.temp_allocator)
		for a, ms in unknown_by_artist do append(&rows, Row{a, ms})
		slice.sort_by(rows[:], proc(a, b: Row) -> bool {
			if a.ms != b.ms do return a.ms > b.ms
			return a.artist < b.artist
		})
		add(&out, "")
		add(&out, "Biggest unclassified artists")
		for row, i in rows {
			if i >= 15 do break
			add(&out, fmt.tprintf("  %s %s   %.1fh", pad_left(fmt.tprintf("%d.", i + 1), 3), row.artist, f64(row.ms) / 3_600_000))
		}
		add(&out, "")
		add(&out, "To classify one yourself, add it to .shr/overrides.json (your decision always wins):")
		add(&out, "  { \"annotations\": [ { \"artist\": \"Name\", \"value\": \"Jazz\" } ] }")
		add(&out, fmt.tprintf("  (add \"title\" to annotate a single track; valid genres: %s)", valid_genre_list()))
	}
	return join_lines(out[:])
}

pct_ms :: proc(part, whole: i64) -> f64 {
	return f64(part) * 100 / f64(max(whole, 1))
}
