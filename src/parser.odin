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
}

Play :: struct {
	year:     int,
	month:    int,
	day:      int,
	hour:     int,
	minute:   int,
	weekday:  int,
	ms:       i64,
	track:    string,
	artist:   string,
	album:    string,
	platform: string,
	skipped:  bool,
	ts_raw:   string,
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
	skip_rate_first:    int,
	skip_rate_last:     int,
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
	genre_order:        [dynamic]string,
	genre_colors:       map[string]string,
	genre_classified:   int,
	genre_other_pct:    f64,
}

Genre_Quarter :: struct {
	quarter: string,
	values:  map[string]f64,
}

Artist_Stat :: struct {
	name:  string,
	hours: f64,
}

Album_Stat :: struct {
	album:  string,
	artist: string,
	hours:  f64,
}

Track_Stat :: struct {
	track:  string,
	artist: string,
	plays:  int,
}

Opener_Stat :: struct {
	track:  string,
	artist: string,
	count:  int,
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

parse_ts_fields :: proc(ts: string) -> (year, month, day, hour, minute, weekday: int) {
	if len(ts) < 19 do return

	y := parse_int(ts[0:4])
	m := parse_int(ts[5:7])
	d := parse_int(ts[8:10])
	h := parse_int(ts[11:13])
	mi := parse_int(ts[14:16])

	// Pacific time offset (-8h)
	h -= 8
	if h < 0 {
		h += 24
		d -= 1
		if d < 1 {
			m -= 1
			if m < 1 {
				m = 12
				y -= 1
			}
			d = days_in_month(y, m)
		}
	}

	year = y
	month = m
	day = d
	hour = h
	minute = mi

	// Zeller's formula for day of week (0=Sun, 1=Mon, ..., 6=Sat)
	zy := y
	zm := m
	if zm < 3 {
		zm += 12
		zy -= 1
	}
	q := d
	k := zy % 100
	j := zy / 100
	dow := (q + (13 * (zm + 1)) / 5 + k + k / 4 + j / 4 - 2 * j) % 7
	if dow < 0 do dow += 7
	// Convert from Zeller (0=Sun..6=Sat) to ISO (0=Mon..6=Sun)
	weekday = (dow + 6) % 7
	return
}

days_in_month :: proc(y, m: int) -> int {
	days := [13]int{0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
	if m == 2 && (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) do return 29
	return days[m]
}

find_json_files :: proc(dir: string) -> [dynamic]string {
	files: [dynamic]string

	dh, err := os.open(dir)
	if err != nil do return files
	defer os.close(dh)

	entries, read_err := os.read_dir(dh, -1, context.allocator)
	if read_err != nil do return files

	for entry in entries {
		if strings.has_prefix(entry.name, "Streaming_History_Audio_") && strings.has_suffix(entry.name, ".json") {
			p, _ := filepath.join({dir, entry.name}, context.allocator)
			append(&files, p)
		}
	}

	slice.sort_by(files[:], proc(a, b: string) -> bool {
		return a < b
	})

	return files
}

load_records :: proc(path: string) -> ([dynamic]Streaming_Record, bool) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil do return {}, false

	records: [dynamic]Streaming_Record
	json_err := json.unmarshal(data, &records)
	if json_err != nil do return {}, false
	delete(data)

	return records, true
}
