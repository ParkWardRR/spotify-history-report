package spotify_report

// Technical Log Information: the second export Spotify sends. It is a pile of
// event files (one per event type) with `timestamp_utc` and `message_*` fields.
// Three of them say something about *how* you listen rather than *what*:
//
//   AudioRouteSegmentEnd   where the sound went (speakers, Bluetooth, car, AirPlay)
//   AudioFileSelection     which stream bitrate was chosen
//   DaylistGenerated       the daylist titles Spotify made for you, and when
//
// Everything else in the package is ignored without being parsed. It covers
// the current account only and usually a shorter span than the streaming
// history, so the report states its own date range.

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

DAYPARTS :: [4]string{"morning", "afternoon", "evening", "night"}
WEEKDAYS_SUN :: [7]string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}
TECHLOG_TOP_TERMS  :: 20
TECHLOG_SAMPLE_TITLES :: 10

Count_Item :: struct {
	label: string,
	count: int,
}

// What has been read so far, before it is ranked into Tech_Stats.
Tech_Raw :: struct {
	routes:       map[string]int,
	bitrates:     map[string]int, // kbps label → selections
	terms:        map[string]int,
	titles:       [dynamic]Dated_Title,
	dayparts:     [4]int,
	weekdays:     [7]int,
	daylists:     int,
	route_total:  int,
	bitrate_total: int,
	first_utc:    string, // earliest timestamp_utc seen, ISO 8601 (sorts as text)
	last_utc:     string,
}

Dated_Title :: struct {
	utc:   string,
	title: string,
}

Tech_Stats :: struct {
	present:       bool,
	first_date:    string, // YYYY-MM-DD
	last_date:     string,
	route_total:   int,
	routes:        [dynamic]Count_Item,
	bitrate_total: int,
	bitrates:      [dynamic]Count_Item,
	daylists:      int,
	terms:         [dynamic]Count_Item,
	titles:        [dynamic]string, // newest first
	dayparts:      [4]int,
	weekdays:      [7]int, // Sunday first
}

// Cheap look at the start of a file: Technical Log records carry `message_` or
// `context_` keys, which streaming-history rows never do. This keeps a 100 MB
// package from being parsed as listening history.
looks_like_technical_log :: proc(data: []u8) -> bool {
	head := string(data[:min(len(data), 4096)])
	return strings.contains(head, "\"message_") || strings.contains(head, "\"context_application_version\"")
}

// Friendly name for Spotify's route type. Unknown types keep their own name:
// a label we invented would be a guess.
route_label :: proc(t: string) -> string {
	switch t {
	case "built_in-speakers", "Speaker", "BuiltInSpeaker": return "Built-in speakers"
	case "CarAudio":                                      return "Car"
	case "BluetoothA2DPOutput", "bluetooth-headphones", "BluetoothHFP", "BluetoothLE": return "Bluetooth"
	case "AirPlay":                                       return "AirPlay"
	case "wired-headphones", "Headphones", "HeadphonesOutput": return "Wired headphones"
	case "HDMI", "HDMIOutput":                            return "HDMI"
	case "USBAudio":                                      return "USB audio"
	}
	return t
}

// A field as text, whether the export wrote it as a string or a number.
// Absent, null and "None" (what a missing value is exported as) give "".
field_text :: proc(obj: json.Object, key: string) -> string {
	v, ok := obj[key]
	if !ok do return ""
	#partial switch x in v {
	case json.String:  return "" if x == "None" else string(x)
	case json.Integer: return fmt.tprintf("%d", x)
	case json.Float:   return fmt.tprintf("%d", i64(x))
	}
	return ""
}

// Terms come as a JSON array or as Python's repr of a list: "['a b', 'c']".
parse_term_list :: proc(obj: json.Object, key: string) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	v, ok := obj[key]
	if !ok do return out
	#partial switch x in v {
	case json.Array:
		for item in x do if s, is_s := item.(json.String); is_s do append(&out, string(s))
	case json.String:
		s := string(x)
		i := 0
		for i < len(s) {
			q := s[i]
			if q != '\'' && q != '"' { i += 1; continue }
			j := i + 1
			for j < len(s) && s[j] != q {
				if s[j] == '\\' do j += 1
				j += 1
			}
			if j > len(s) do break
			term := strings.trim_space(s[i + 1:min(j, len(s))])
			if len(term) > 0 do append(&out, term)
			i = j + 1
		}
	}
	return out
}

// Counts one more of `key`, keeping a copy of the key only the first time.
bump :: proc(m: ^map[string]int, key: string) {
	if key in m^ { m[key] += 1; return }
	m[strings.clone(key)] = 1
}

note_time :: proc(raw: ^Tech_Raw, utc: string) {
	if len(utc) < 10 do return
	// The text lives in the temporary parse tree, which does not outlive this
	// call, so what is kept must be a copy.
	if len(raw.first_utc) == 0 || utc < raw.first_utc {
		delete(raw.first_utc)
		raw.first_utc = strings.clone(utc)
	}
	if utc > raw.last_utc {
		delete(raw.last_utc)
		raw.last_utc = strings.clone(utc)
	}
}

// Reads one Technical Log file. Files that are not one of the three event
// types (judged by their fields, not their names) are left alone. Returns
// whether the file contributed anything.
techlog_ingest :: proc(raw: ^Tech_Raw, data: []u8) -> bool {
	// Most of the package is other event types: don't parse what we won't read.
	head := string(data[:min(len(data), 8192)])
	interesting := strings.contains(head, "\"message_current_route_type\"") ||
		strings.contains(head, "\"message_bitrate\"") ||
		strings.contains(head, "\"message_playlist_title\"")
	if !interesting do return false

	val, err := json.parse(data, allocator = context.temp_allocator)
	if err != nil do return false
	arr, is_arr := val.(json.Array)
	if !is_arr || len(arr) == 0 do return false
	first, is_obj := arr[0].(json.Object)
	if !is_obj do return false

	_, has_route := first["message_current_route_type"]
	_, has_bitrate := first["message_bitrate"]
	_, has_strategy := first["message_strategy_name"]
	_, has_daylist := first["message_playlist_title"]
	_, has_daypart := first["message_daypart"]

	used := false
	switch {
	case has_route:
		for item in arr {
			obj, ok := item.(json.Object)
			if !ok do continue
			t := field_text(obj, "message_current_route_type")
			if len(t) == 0 do continue
			bump(&raw.routes, route_label(t))
			raw.route_total += 1
			note_time(raw, field_text(obj, "timestamp_utc"))
		}
		used = true
	case has_bitrate && has_strategy:
		for item in arr {
			obj, ok := item.(json.Object)
			if !ok do continue
			bps := field_text(obj, "message_bitrate")
			n: i64
			for c in bps { if c < '0' || c > '9' { n = 0; break }; n = n * 10 + i64(c - '0') }
			if n <= 0 do continue
			bump(&raw.bitrates, fmt.tprintf("%d kbps", n / 1000))
			raw.bitrate_total += 1
			note_time(raw, field_text(obj, "timestamp_utc"))
		}
		used = true
	case has_daylist && has_daypart:
		for item in arr {
			obj, ok := item.(json.Object)
			if !ok do continue
			raw.daylists += 1
			title := field_text(obj, "message_playlist_title")
			utc := field_text(obj, "timestamp_utc")
			if len(title) > 0 do append(&raw.titles, Dated_Title{strings.clone(utc), strings.clone(title)})
			for term in parse_term_list(obj, "message_title_terms") do bump(&raw.terms, strings.to_lower(term, context.temp_allocator))
			dp := field_text(obj, "message_daypart")
			for name, i in DAYPARTS do if name == strings.to_lower(dp, context.temp_allocator) do raw.dayparts[i] += 1
			dow := field_text(obj, "message_day_of_week")
			for name, i in WEEKDAYS_SUN do if name == dow do raw.weekdays[i] += 1
			note_time(raw, utc)
		}
		used = true
	}
	return used
}

// Ranks counts by size, then by name, so a rerun never reorders ties.
ranked :: proc(m: map[string]int, limit: int) -> [dynamic]Count_Item {
	items := make([dynamic]Count_Item, context.temp_allocator)
	for k, v in m do append(&items, Count_Item{k, v})
	slice.sort_by(items[:], proc(a, b: Count_Item) -> bool {
		if a.count != b.count do return a.count > b.count
		return a.label < b.label
	})
	out: [dynamic]Count_Item
	for i in 0 ..< min(limit, len(items)) do append(&out, items[i])
	return out
}

techlog_stats :: proc(raw: ^Tech_Raw) -> (t: Tech_Stats) {
	if raw.route_total + raw.bitrate_total + raw.daylists == 0 do return
	t.present = true
	if len(raw.first_utc) >= 10 do t.first_date = raw.first_utc[:10]
	if len(raw.last_utc) >= 10 do t.last_date = raw.last_utc[:10]
	t.route_total = raw.route_total
	t.routes = ranked(raw.routes, 12)
	t.bitrate_total = raw.bitrate_total
	t.bitrates = ranked(raw.bitrates, 12)
	t.daylists = raw.daylists
	t.terms = ranked(raw.terms, TECHLOG_TOP_TERMS)
	t.dayparts = raw.dayparts
	t.weekdays = raw.weekdays

	slice.sort_by(raw.titles[:], proc(a, b: Dated_Title) -> bool {
		if a.utc != b.utc do return a.utc > b.utc
		return a.title < b.title
	})
	seen := make(map[string]bool, context.temp_allocator)
	for d in raw.titles {
		if seen[d.title] do continue
		seen[d.title] = true
		append(&t.titles, d.title)
		if len(t.titles) >= TECHLOG_SAMPLE_TITLES do break
	}
	return
}
