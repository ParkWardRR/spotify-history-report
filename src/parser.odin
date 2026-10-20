package spotify_report

import "core:encoding/json"
import "core:os"
import "core:fmt"
import "core:strings"
import "core:path/filepath"
import "core:slice"
import "core:time"

Streaming_Record :: struct {
	ts:                                string,
	ms_played:                         i64,
	master_metadata_track_name:        Maybe(string),
	master_metadata_album_artist_name: Maybe(string),
	master_metadata_album_album_name:  Maybe(string),
	platform:                          Maybe(string),
	skipped:                           Maybe(bool),
	spotify_track_uri:                 Maybe(string),
	reason_start:                      Maybe(string),
	reason_end:                        Maybe(string),
	shuffle:                           Maybe(bool),
	offline:                           Maybe(bool),
	conn_country:                      Maybe(string),
}

// The export's `skipped` field is true, false, or null (current exports leave it
// null for most rows). Null is not the same as false, so it is kept apart.
Skip_Flag :: enum u8 {
	Unknown,
	No,
	Yes,
}

Play :: struct {
	year:     int,
	month:    int,
	day:      int,
	hour:     int,
	minute:   int,
	weekday:  int, // 0 = Monday … 6 = Sunday
	ordinal:  i64, // local calendar day number; consecutive days differ by 1
	unix:     i64, // UTC seconds, for gaps between plays
	ms:       i64,
	track:    string,
	artist:   string,
	album:    string,
	platform: string,
	skipped:  Skip_Flag, // as exported; Unknown when Spotify left it null
	ts_raw:   string,
	// Identity and context from the export (empty when absent).
	uri:          string, // spotify:track:<id>
	reason_start: string,
	reason_end:   string,
	conn_country: string,
	shuffle:      bool,
	offline:      bool,
	// Set by assign_sessions from the whole event stream; 0 = not assigned yet.
	session:        int,
	opens_session:  bool, // first qualifying play of its session
	closes_session: bool, // last qualifying play of its session
}

Stats :: struct {
	total_plays:      int,
	total_hours:      int,
	unique_artists:   int,
	unique_tracks:    int,
	date_range_start: string,
	date_range_end:   string,
	top_artists:      [dynamic]Artist_Stat,
	top_albums:       [dynamic]Album_Stat,
	hours_by_year:    [dynamic]Year_Hours,
	session_openers:  [dynamic]Opener_Stat,
	never_skipped:    [dynamic]Track_Stat,
	biggest_day:      Day_Stat,
	peak_hour:        int,
	peak_hour_val:    int,
	peak_day:         string,
	loyal_count:      int,
	n_years:          int,
	loyalists:        [dynamic]Artist_Stat,
	most_played_song: Track_Stat,
	earworms:           [dynamic]Earworm_Stat,
	earworm_total:      int,
	worst_earworm:      Earworm_Stat,
	longest_streak:     int,
	heatmap:            [dynamic]JSON_HM,
	explore_obsess:     [dynamic]JSON_Explore,
	skip_rate_first:    int, // explicit skips, % of rows with the flag; -1 = no flagged rows
	skip_rate_last:     int,
	short_rate_first:   int, // listens under 30 s, % of music rows
	short_rate_last:    int,
	skip_flag_coverage: int, // % of music rows whose `skipped` field was present
	skip_rate_first_yr: int,
	skip_rate_last_yr:  int,
	avg_len_first:      f64,
	avg_len_last:       f64,
	avg_len_first_yr:   int,
	avg_len_last_yr:    int,
	concentration_top10: f64,
	songs_for_half:     int,
	peak_day_hours:     int,
	platforms:          [dynamic]Platform_Stat,
	top_by_year:        [dynamic]Year_Top,
	avg_track_length:   [dynamic]Year_Avg_Len,
	// Genre data (populated when LLM or cache available)
	genre_area:         [dynamic]Genre_Quarter,
	genre_artists:      [dynamic]Genre_Artists, // biggest genres, each with its top artists
	genre_order:        [dynamic]string,
	genre_colors:       map[string]string,
	genre_classified:   int,
	genre_unclassified_pct: f64, // share of listening time with no genre annotation
	genre_source_pct:   [Annotation_Source]f64, // share of listening time decided by each source
	genre_user_targets: int,    // artists and tracks the user classified
	// Coverage: the span of local days the data covers, for completeness checks.
	first_ordinal:      i64,
	last_ordinal:       i64,
	last_year:          int,
	last_year_partial:  bool,
	timezone:           string, // description of how local time was derived
	scores:             Scores,
	identity:           Identity_Summary,
	identity_candidates: [dynamic]Candidate, // top review candidates, most-played first
	import_summary:     Import_Summary,
	largest_gap:        Gap_Stat,
}

Gap_Stat :: struct {
	days: int,    // whole days with no plays between `from` and `to`
	from: string, // last day with plays before the gap
	to:   string, // first day with plays after it
}

Genre_Quarter :: struct {
	quarter: string,
	partial: bool, // the data does not cover the whole quarter
	values:  map[string]f64,
}

Artist_Stat :: struct {
	name:  string,
	hours: f64,
}

// The artists that carry one genre, ranked by listening time within it.
// `hours` is the genre's total over the whole library, not just these artists.
Genre_Artists :: struct {
	genre:   string,
	hours:   f64,
	artists: [dynamic]Artist_Stat,
}

GENRE_ARTISTS_GENRES  :: 6  // how many genres get a list
GENRE_ARTISTS_PER_GENRE :: 15

Album_Stat :: struct {
	album:  string,
	artist: string,
	hours:  f64,
}

Track_Stat :: struct {
	track:  string,
	artist: string,
	plays:  int,
	uri:    string, // only to order two tracks that share a title and artist
}

Opener_Stat :: struct {
	track:  string,
	artist: string,
	count:  int,
	uri:    string,
}

Day_Stat :: struct {
	date:  string,
	plays: int,
	hours: f64,
}

Earworm_Stat :: struct {
	track:   string,
	artist:  string,
	plays:   int,
	period:  string,
	uri:     string,
}

JSON_HM :: struct {
	day:   int,
	hour:  int,
	hours: f64,
}

JSON_Explore :: struct {
	year:          int,
	new_pct:       int,
	top10_pct:     int,
	rest_pct:      int,
	new_count:     int,
	total_artists: int,
}

Year_Hours :: struct {
	year:  int,
	hours: f64,
}

Platform_Stat :: struct {
	name:  string,
	count: int,
}

Year_Top :: struct {
	year:    int,
	artists: [dynamic]Artist_Stat,
}

Year_Avg_Len :: struct {
	year:    int,
	minutes: f64,
}

parse_int :: proc(s: string) -> int {
	result := 0
	for c in s {
		if c >= '0' && c <= '9' {
			result = result * 10 + int(c - '0')
		}
	}
	return result
}

MIN_PLAY_MS :: 30000

Record_Status :: enum {
	Ok,
	Not_A_Track,   // podcast/audiobook/unknown row: no track or artist name
	Bad_Timestamp, // `ts` is not a valid ISO 8601 UTC timestamp
}

// Converts one export row. The returned Play is populated whenever the status
// is .Ok, including for plays shorter than MIN_PLAY_MS; the caller decides
// whether a short play qualifies (see `qualifies`) and feeds the skip tally.
record_to_play :: proc(rec: Streaming_Record, c: ^Clock) -> (p: Play, status: Record_Status) {
	track := rec.master_metadata_track_name.? or_else ""
	artist := rec.master_metadata_album_artist_name.? or_else ""
	if len(track) == 0 || len(artist) == 0 do return {}, .Not_A_Track

	lt, ok := parse_ts(rec.ts, c)
	if !ok do return {}, .Bad_Timestamp

	return Play{
		year         = lt.year,
		month        = lt.month,
		day          = lt.day,
		hour         = lt.hour,
		minute       = lt.minute,
		weekday      = lt.weekday,
		ordinal      = lt.ordinal,
		unix         = lt.unix,
		ms           = rec.ms_played,
		track        = track,
		artist       = artist,
		album        = rec.master_metadata_album_album_name.? or_else "",
		platform     = rec.platform.? or_else "",
		skipped      = skip_flag(rec.skipped),
		ts_raw       = rec.ts,
		uri          = rec.spotify_track_uri.? or_else "",
		reason_start = rec.reason_start.? or_else "",
		reason_end   = rec.reason_end.? or_else "",
		conn_country = rec.conn_country.? or_else "",
		shuffle      = rec.shuffle.? or_else false,
		offline      = rec.offline.? or_else false,
	}, .Ok
}

qualifies :: proc(p: Play) -> bool {
	return p.ms >= MIN_PLAY_MS
}

skip_flag :: proc(v: Maybe(bool)) -> Skip_Flag {
	if b, ok := v.?; ok do return .Yes if b else .No
	return .Unknown
}

// Two different observations, reported separately and never added together:
// Spotify flagging the row as skipped, and the play ending before MIN_PLAY_MS.
explicit_skip :: proc(p: Play) -> bool { return p.skipped == .Yes }
short_listen :: proc(p: Play) -> bool { return p.ms < MIN_PLAY_MS }

// Chronological order; ties keep file order so output is reproducible.
sort_plays :: proc(plays: []Play) {
	slice.stable_sort_by(plays, proc(a, b: Play) -> bool { return a.unix < b.unix })
}
