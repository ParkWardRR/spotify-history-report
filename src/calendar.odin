package spotify_report

// Calendar and timezone arithmetic. Every date-derived value in the report
// (streaks, 7-day windows, weekday/hour buckets) comes from here, so it is
// built on the stdlib's proleptic Gregorian ordinals rather than ad-hoc math.

import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

DEFAULT_TIMEZONE :: "America/Los_Angeles"
FALLBACK_OFFSET_SECONDS :: -8 * 3600 // used only when no zoneinfo is available

// How timestamps are turned into local time. `region == nil` means a fixed
// offset: exact UTC when `fallback` is false, otherwise the -8h stand-in used
// because the requested zone could not be loaded.
Clock :: struct {
	name:      string, // IANA name that was requested
	region:    ^datetime.TZ_Region,
	offset_s:  i64,
	fallback:  bool,
}

// A UTC timestamp resolved to local time. `ordinal` numbers consecutive
// calendar days; `unix` is UTC seconds and is what gaps between plays use, so
// DST changes never distort them.
Local_Time :: struct {
	year:    int,
	month:   int,
	day:     int,
	hour:    int,
	minute:  int,
	weekday: int, // 0 = Monday … 6 = Sunday
	ordinal: i64,
	unix:    i64,
}

valid_tz_name :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > 64 || strings.contains(name, "..") do return false
	for c in name {
		switch c {
		case 'a'..='z', 'A'..='Z', '0'..='9', '/', '_', '+', '-':
		case: return false
		}
	}
	return name[0] != '/'
}

make_clock :: proc(name: string) -> Clock {
	n := name if len(name) > 0 else DEFAULT_TIMEZONE
	if !valid_tz_name(n) do return Clock{name = n, offset_s = FALLBACK_OFFSET_SECONDS, fallback = true}
	region, ok := timezone.region_load(n)
	if !ok do return Clock{name = n, offset_s = FALLBACK_OFFSET_SECONDS, fallback = true}
	return Clock{name = n, region = region}
}

// Human-readable description for report footers and plain-mode output.
clock_label :: proc(c: Clock) -> string {
	if c.fallback do return "fixed UTC-8 (zoneinfo unavailable)"
	return c.name
}

// UTC offset in effect at `unix`. core:time/timezone looks up the record
// *before* a transition when the instant equals the transition second, so the
// exact second a DST change takes effect would get the old offset. Probing one
// second later gives the right answer for `unix` in every case, since no two
// transitions are a second apart.
region_offset :: proc(region: ^datetime.TZ_Region, unix: i64) -> (offset: i64, ok: bool) {
	probe := unix + 1
	utc_dt, dt_ok := time.time_to_datetime(time.unix(probe, 0))
	if !dt_ok do return
	local_dt := timezone.datetime_to_tz(utc_dt, region) or_return
	local_t, t_ok := time.datetime_to_time(local_dt)
	if !t_ok do return
	return time.to_unix_seconds(local_t) - probe, true
}

// ISO 8601 UTC timestamps as found in the export: 2024-03-15T18:32:01Z.
parse_ts :: proc(ts: string, c: ^Clock) -> (lt: Local_Time, ok: bool) {
	if len(ts) < 19 || ts[4] != '-' || ts[7] != '-' || (ts[10] != 'T' && ts[10] != ' ') || ts[13] != ':' || ts[16] != ':' {
		return
	}
	digits := [?][2]int{{0, 4}, {5, 7}, {8, 10}, {11, 13}, {14, 16}, {17, 19}}
	vals: [6]int
	for d, i in digits {
		for ch in ts[d[0]:d[1]] {
			if ch < '0' || ch > '9' do return
		}
		vals[i] = parse_int(ts[d[0]:d[1]])
	}

	utc := datetime.DateTime{
		date = {i64(vals[0]), i8(vals[1]), i8(vals[2])},
		time = {i8(vals[3]), i8(vals[4]), i8(vals[5]), 0},
	}
	if vals[1] < 1 || vals[1] > 12 || vals[2] < 1 || vals[3] > 23 || vals[4] > 59 || vals[5] > 59 do return
	if datetime.validate(utc.date) != .None do return

	t, t_ok := time.datetime_to_time(utc)
	if !t_ok do return
	lt.unix = time.to_unix_seconds(t)

	offset := c.offset_s
	if c.region != nil {
		offset, ok = region_offset(c.region, lt.unix)
		if !ok do return
	}
	local, local_ok := time.time_to_datetime(time.unix(lt.unix + offset, 0))
	if !local_ok do return

	lt.year   = int(local.year)
	lt.month  = int(local.month)
	lt.day    = int(local.day)
	lt.hour   = int(local.hour)
	lt.minute = int(local.minute)

	ord, err := datetime.components_to_ordinal(local.year, local.month, local.day)
	if err != .None do return
	lt.ordinal = i64(ord)
	// day_of_week is Sunday-first; the report is Monday-first.
	lt.weekday = (int(datetime.day_of_week(ord)) + 6) % 7
	ok = true
	return
}

days_in_month :: proc(y, m: int) -> int {
	days := [13]int{0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
	if m == 2 && (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) do return 29
	return days[m]
}

// Ordinal of a civil date, for comparing against Play.ordinal.
date_ordinal :: proc(y, m, d: int) -> i64 {
	ord, _ := datetime.components_to_ordinal(y, m, d)
	return i64(ord)
}
