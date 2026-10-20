package spotify_report

// Dashboard tab contents. Each builder returns a block of text sized for the
// given content width; the viewport handles scrolling.

import "core:fmt"
import "core:strings"

build_tab :: proc(t: Tab, s: ^Stats, cw: int) -> string {
	switch t {
	case .Overview: return build_overview(s, cw)
	case .Artists:  return build_artists(s, cw)
	case .Library:  return build_library(s, cw)
	case .Habits:   return build_habits(s, cw)
	case .Rhythm:   return build_rhythm(s, cw)
	case .Genres:   return build_genres(s, cw)
	}
	return ""
}

// ── Shared pieces ────────────────────────────────────────────────────────────

section :: proc(title: string, cw: int, note := "") -> string {
	head := fgs(COL_ACCENT2, title, true)
	used := text_width(title)
	tail := ""
	if len(note) > 0 {
		tail = strings.concatenate({"  ", muted(note)}, context.temp_allocator)
		used += 2 + text_width(note)
	}
	return strings.concatenate({head, tail, " ", faint(repeat_str("─", max(0, cw - used - 1)))}, context.temp_allocator)
}

stat_card :: proc(label, value, sub: string, color: Nord, w: int) -> string {
	body := strings.join({muted(label), fgs(color, value, true), faint(sub)}, "\n", context.temp_allocator)
	return render(Style{border = .Rounded, border_fg = COL_FAINT, width = w - 2, pad = {0, 1, 0, 1}}, body)
}

card_grid :: proc(cards: []struct{ label, value, sub: string, color: Nord }, cw: int) -> string {
	cols := 4 if cw >= 84 else 2 if cw >= 44 else 1
	gap := 1
	card_w := (cw - gap * (cols - 1)) / cols
	rows := make([dynamic]string, context.temp_allocator)
	for start := 0; start < len(cards); start += cols {
		row := make([dynamic]string, context.temp_allocator)
		for c in cards[start:min(start + cols, len(cards))] {
			append(&row, stat_card(c.label, c.value, c.sub, c.color, card_w))
		}
		append(&rows, join_h(row[:], gap))
	}
	return join_v(rows[:])
}

kv_line :: proc(label, value: string, color: Nord = COL_TEXT) -> string {
	return strings.concatenate({faint("▸ "), muted(pad_right(label, 14)), fgs(color, value)}, context.temp_allocator)
}

rank_color :: proc(i: int) -> Nord {
	switch i {
	case 0: return NORD13
	case 1: return NORD4
	case 2: return NORD12
	}
	return COL_MUTED
}

Row3 :: struct {
	primary, secondary, value: string,
}

// Ranked list: "  1  Primary text   Secondary   value" — columns hug their content.
list_table :: proc(rows: []Row3, cw: int, value_color: Nord) -> string {
	vw, pw, sw := 0, 0, 0
	for r in rows {
		vw = max(vw, text_width(r.value))
		pw = max(pw, text_width(r.primary))
		sw = max(sw, text_width(r.secondary))
	}
	avail := cw - 4 - vw - 6
	pw = min(pw, avail * 6 / 10)
	sw = min(sw, avail - pw)
	out := make([dynamic]string, context.temp_allocator)
	for r, i in rows {
		line := strings.concatenate({
			fgs(rank_color(i), pad_left(fmt.tprintf("%d", i + 1), 2), i < 3), "  ",
			fgs(COL_BRIGHT, pad_right(r.primary, pw)), "   ",
			muted(pad_right(r.secondary, sw)), "   ",
			fgs(value_color, pad_left(r.value, vw), true),
		}, context.temp_allocator)
		append(&out, line)
	}
	return join_v(out[:])
}

stacked_bar :: proc(parts: []f64, colors: []Nord, width: int, thin := false) -> string {
	total: f64
	for p in parts { total += p }
	if total <= 0 || width <= 0 do return ""
	sb := strings.builder_make(context.temp_allocator)
	used := 0
	acc: f64
	for p, i in parts {
		acc += p
		end := int(acc / total * f64(width) + 0.5)
		n := max(0, end - used)
		if i == len(parts) - 1 do n = width - used
		strings.write_string(&sb, fgs(colors[i % len(colors)], repeat_str("━" if thin else "█", n)))
		used += n
	}
	return strings.to_string(sb)
}

wrap_items :: proc(items: []string, cw: int, gap := 3) -> string {
	lines := make([dynamic]string, context.temp_allocator)
	cur := strings.builder_make(context.temp_allocator)
	cur_w := 0
	for it in items {
		iw := text_width(it)
		if cur_w > 0 && cur_w + gap + iw > cw {
			append(&lines, strings.clone(strings.to_string(cur), context.temp_allocator))
			strings.builder_reset(&cur)
			cur_w = 0
		}
		if cur_w > 0 {
			strings.write_string(&cur, spaces(gap))
			cur_w += gap
		}
		strings.write_string(&cur, it)
		cur_w += iw
	}
	if cur_w > 0 do append(&lines, strings.clone(strings.to_string(cur), context.temp_allocator))
	return strings.join(lines[:], "\n", context.temp_allocator)
}

// ── Overview ─────────────────────────────────────────────────────────────────

// "January 2018" -> "Jan 2018"
short_month_year :: proc(s: string) -> string {
	if i := strings.index_byte(s, ' '); i > 3 do return fmt.tprintf("%s%s", s[:3], s[i:])
	return s
}

build_overview :: proc(s: ^Stats, cw: int) -> string {
	out := make([dynamic]string, context.temp_allocator)

	days := f64(s.total_hours) / 24
	cards := []struct{ label, value, sub: string, color: Nord }{
		{"Total plays",     fmt_int(s.total_plays),     fmt.tprintf("%s – %s", short_month_year(s.date_range_start), short_month_year(s.date_range_end)), NORD8},
		{"Hours listened",  fmt_int(s.total_hours),     fmt.tprintf("≈ %.0f days nonstop", days), NORD8},
		{"Unique artists",  fmt_int(s.unique_artists),  fmt.tprintf("top 10 = %.0f%% of time", s.concentration_top10), NORD9},
		{"Unique tracks",   fmt_int(s.unique_tracks),   fmt.tprintf("half of plays in %s", fmt_int(s.songs_for_half)), NORD9},
		{"Longest streak",  fmt.tprintf("%d days", s.longest_streak), "consecutive days", NORD14},
		{"Peak hour",       fmt.tprintf("%02d:00", s.peak_hour), fmt.tprintf("%dh total", s.peak_hour_val), NORD13},
		{"Peak day",        s.peak_day, fmt.tprintf("%dh total", s.peak_day_hours), NORD13},
		{"Loyal artists",   fmt_int(s.loyal_count), fmt.tprintf("heard in all %d years", s.n_years), NORD15},
	}
	append(&out, section("At a glance", cw), card_grid(cards, cw), "")

	// Highlights
	append(&out, section("Highlights", cw))
	ms := s.most_played_song
	append(&out, kv_line("Most played", fmt.tprintf("“%s” — %s · %s plays", ms.track, ms.artist, fmt_int(ms.plays)), NORD12))
	if s.worst_earworm.plays > 0 {
		e := s.worst_earworm
		append(&out, kv_line("Worst earworm", fmt.tprintf("“%s” — %s · %d plays in 7 days", e.track, e.artist, e.plays), NORD11))
	}
	bd := s.biggest_day
	if bd.plays > 0 {
		append(&out, kv_line("Biggest day", fmt.tprintf("%s · %d plays · %.1fh", bd.date, bd.plays, bd.hours), NORD13))
	}
	if s.skip_rate_first_yr > 0 {
		append(&out, kv_line("Skip rate", fmt.tprintf("%d%% (%d) → %d%% (%d)", s.skip_rate_first, s.skip_rate_first_yr, s.skip_rate_last, s.skip_rate_last_yr), NORD14))
	}
	if s.avg_len_first_yr > 0 {
		append(&out, kv_line("Track length", fmt.tprintf("%.1f min (%d) → %.1f min (%d)", s.avg_len_first, s.avg_len_first_yr, s.avg_len_last, s.avg_len_last_yr), NORD7))
	}
	append(&out, "")

	// Hours by year
	n := len(s.hours_by_year)
	if n > 0 {
		append(&out, section("Hours by year", cw))
		values := make([]f64, n, context.temp_allocator)
		labels := make([]string, n, context.temp_allocator)
		subs := make([]string, n, context.temp_allocator)
		for yh, i in s.hours_by_year {
			values[i] = yh.hours
			labels[i] = fmt.tprintf("%d", yh.year)
			subs[i] = fmt.tprintf("%.0fh", yh.hours)
		}
		col_w := clamp(cw / n * 2 / 3, 5, 11)
		gap := clamp(cw / n - col_w, 1, 4)
		if n * (col_w + gap) <= cw {
			append(&out, column_chart(values, labels, subs, 7, col_w, gap, NORD10, NORD8))
		} else {
			hi: f64
			for v in values { hi = max(hi, v) }
			for v, i in values {
				append(&out, strings.concatenate({
					muted(labels[i]), " ", hbar(v, hi, cw - 12, NORD10, NORD8, thin = true), " ", fgs(COL_TEXT, pad_left(subs[i], 5)),
				}, context.temp_allocator))
			}
		}
		append(&out, "")
	}

	// Top 5 artists
	if len(s.top_artists) > 0 {
		append(&out, section("Top artists", cw))
		hi := s.top_artists[0].hours
		nw := clamp(cw / 3, 12, 26)
		bw := max(8, cw - nw - 12)
		for a, i in s.top_artists[:min(5, len(s.top_artists))] {
			append(&out, strings.concatenate({
				fgs(rank_color(i), pad_left(fmt.tprintf("%d", i + 1), 2), i < 3), "  ",
				fgs(COL_BRIGHT, pad_right(a.name, nw)), " ",
				hbar(a.hours, hi, bw, NORD10, NORD8, thin = true), " ",
				fgs(COL_TEXT, pad_left(fmt.tprintf("%.0fh", a.hours), 5)),
			}, context.temp_allocator))
		}
		append(&out, "")
	}

	// Platforms
	if len(s.platforms) > 0 {
		append(&out, section("Where you listen", cw))
		total: f64
		for p in s.platforms { total += f64(p.count) }
		parts := make([]f64, len(s.platforms), context.temp_allocator)
		names := make([]string, len(s.platforms), context.temp_allocator)
		shares := make([]f64, len(s.platforms), context.temp_allocator)
		for p, i in s.platforms {
			parts[i] = f64(p.count)
			names[i] = p.name
			shares[i] = f64(p.count) / total * 100
		}
		append(&out, stacked_bar(parts, SERIES_COLORS[:], cw))
		append(&out, wrap_items(legend_items(names, shares, SERIES_COLORS[:]), cw))
	}
	return join_v(out[:])
}

legend_items :: proc(names: []string, shares: []f64, colors: []Nord) -> []string {
	items := make([]string, len(names), context.temp_allocator)
	for n, i in names {
		items[i] = strings.concatenate({
			fgs(colors[i % len(colors)], "■"), " ", fgs(COL_TEXT, n), " ",
			muted(fmt.tprintf("%.0f%%", shares[i])),
		}, context.temp_allocator)
	}
	return items
}

// ── Artists ──────────────────────────────────────────────────────────────────

build_artists :: proc(s: ^Stats, cw: int) -> string {
	out := make([dynamic]string, context.temp_allocator)

	if len(s.top_artists) > 0 {
		append(&out, section("Top artists", cw, "by listening time"))
		hi := s.top_artists[0].hours
		nw := clamp(cw * 3 / 10, 14, 30)
		bw := max(8, cw - nw - 13)
		for a, i in s.top_artists {
			append(&out, strings.concatenate({
				fgs(rank_color(i), pad_left(fmt.tprintf("%d", i + 1), 2), i < 3), "  ",
				fgs(COL_BRIGHT, pad_right(a.name, nw)), " ",
				hbar(a.hours, hi, bw, NORD10, NORD8, thin = true), " ",
				fgs(COL_TEXT, pad_left(fmt.tprintf("%.0fh", a.hours), 5)),
			}, context.temp_allocator))
		}
		append(&out, "")
	}

	if len(s.loyalists) > 0 {
		append(&out, section("The lifers", cw, fmt.tprintf("listened to in every one of %d years", s.n_years)))
		names := make([dynamic]string, context.temp_allocator)
		for a in s.loyalists[:min(18, len(s.loyalists))] {
			append(&names, strings.concatenate({fgs(COL_BRIGHT, a.name), " ", muted(fmt.tprintf("%.0fh", a.hours))}, context.temp_allocator))
		}
		append(&out, wrap_items(names[:], cw, 4), "")
	}

	if len(s.top_by_year) > 0 {
		append(&out, section("Top artists by year", cw))
		for yt in s.top_by_year {
			list := make([dynamic]string, context.temp_allocator)
			for a, i in yt.artists[:min(5, len(yt.artists))] {
				append(&list, fgs(COL_BRIGHT if i == 0 else COL_TEXT, a.name, i == 0))
			}
			joined := strings.join(list[:], faint(" · "), context.temp_allocator)
			append(&out, strings.concatenate({fgs(COL_ACCENT, fmt.tprintf("%d", yt.year), true), "  ", truncate(joined, cw - 6)}, context.temp_allocator))
		}
	}
	return join_v(out[:])
}

// ── Library ──────────────────────────────────────────────────────────────────

build_library :: proc(s: ^Stats, cw: int) -> string {
	out := make([dynamic]string, context.temp_allocator)

	if len(s.top_albums) > 0 {
		rows := make([dynamic]Row3, context.temp_allocator)
		for a in s.top_albums { append(&rows, Row3{a.album, a.artist, fmt.tprintf("%.1fh", a.hours)}) }
		append(&out, section("Top albums", cw), list_table(rows[:], cw, NORD7), "")
	}
	if len(s.earworms) > 0 {
		rows := make([dynamic]Row3, context.temp_allocator)
		for e in s.earworms[:min(10, len(s.earworms))] {
			append(&rows, Row3{e.track, fmt.tprintf("%s · %s", e.artist, e.period), fmt.tprintf("%d plays", e.plays)})
		}
		append(&out, section("Earworms", cw, "most plays in any 7-day window"), list_table(rows[:], cw, NORD11), "")
	}
	if len(s.session_openers) > 0 {
		rows := make([dynamic]Row3, context.temp_allocator)
		for o in s.session_openers { append(&rows, Row3{o.track, o.artist, fmt.tprintf("%dx", o.count)}) }
		append(&out, section("Session openers", cw, "what you reach for first"), list_table(rows[:], cw, NORD15), "")
	}
	if len(s.never_skipped) > 0 {
		rows := make([dynamic]Row3, context.temp_allocator)
		for t in s.never_skipped { append(&rows, Row3{t.track, t.artist, fmt.tprintf("%d plays", t.plays)}) }
		append(&out, section("Never skipped", cw, "15+ plays, zero skips"), list_table(rows[:], cw, NORD14), "")
	}

	// Track identity: how sure we are which recording each play was.
	id := s.identity
	if id.plays > 0 {
		append(&out, section("Track identity", cw, "run with --identities for the full review list"))
		append(&out, kv_line("matched by URI", fmt.tprintf("%.1f%% of plays", pct(id.plays_by_uri, id.plays)), COL_OK))
		if id.plays_metadata_only > 0 {
			append(&out, kv_line("text only", fmt.tprintf("%s plays, unresolved", fmt_int(id.plays_metadata_only)), COL_WARN))
		}
		append(&out, kv_line("songs", fmt.tprintf("%s (exact title + artist)", fmt_int(id.songs))))
		if id.songs_multi_uri > 0 {
			append(&out, kv_line("multi-release", fmt.tprintf("%s songs span several URIs, counted together", fmt_int(id.songs_multi_uri))))
		}
		if id.near_duplicate_groups > 0 || id.version_families > 0 {
			append(&out, kv_line("to review", fmt.tprintf("%d near-duplicates · %d version families (never merged automatically)",
				id.near_duplicate_groups, id.version_families), COL_WARN))
		}
		if len(s.identity_candidates) > 0 {
			rows := make([dynamic]Row3, context.temp_allocator)
			for c in s.identity_candidates[:min(5, len(s.identity_candidates))] {
				kind := "near-duplicate" if c.kind == .Near_Duplicate else "versions"
				append(&rows, Row3{c.title, fmt.tprintf("%s · %s", c.artist, kind), fmt.tprintf("%d variants", len(c.songs))})
			}
			append(&out, "", list_table(rows[:], cw, NORD13))
		}
	}
	return join_v(out[:])
}

// ── Habits ───────────────────────────────────────────────────────────────────

habit_section :: proc(out: ^[dynamic]string, title, why: string, items: []Track_Score, color: Nord, detail: proc(t: Track_Score) -> string, cw: int) {
	append(out, section(title, cw))
	append(out, muted(wrap_text(why, cw)))
	if len(items) == 0 {
		append(out, faint("  nothing in your history meets this definition"), "")
		return
	}
	rows := make([dynamic]Row3, context.temp_allocator)
	for t in items do append(&rows, Row3{t.track, t.artist, detail(t)})
	append(out, list_table(rows[:], cw, color), "")
}

build_habits :: proc(s: ^Stats, cw: int) -> string {
	out := make([dynamic]string, context.temp_allocator)
	sc := &s.scores
	if len(sc.ref_date) == 0 do return muted("No listening data.")

	append(&out, muted(wrap_text(fmt.tprintf("As of %s, the last day in your data. These views overlap on purpose: a favourite you are bingeing this week is both.", sc.ref_date), cw)), "")
	habit_section(&out, "Long-term favourites", why_favourites(), sc.favourites[:], NORD14,
		proc(t: Track_Score) -> string { return fmt.tprintf("%d plays · %d months", t.plays, t.months_active) }, cw)
	habit_section(&out, "Current obsessions", why_obsessions(), sc.obsessions[:], NORD11,
		proc(t: Track_Score) -> string { return fmt.tprintf("%d plays in %d days", t.recent_plays, HOT_WINDOW_DAYS) }, cw)
	habit_section(&out, "Rediscoveries", why_rediscoveries(), sc.rediscoveries[:], NORD15,
		proc(t: Track_Score) -> string { return fmt.tprintf("%d plays · silent %d mo", t.plays, t.days_since_last * 10 / 304) }, cw)
	habit_section(&out, "Likely to come back to", why_warm(), sc.warm[:], NORD13,
		proc(t: Track_Score) -> string { return fmt.tprintf("%d plays", t.plays) }, cw)
	habit_section(&out, "Reach-for-first", why_openers(), sc.openers[:], NORD7,
		proc(t: Track_Score) -> string { return fmt.tprintf("%.0f%% of %d plays", t.opener_rate * 100, t.plays) }, cw)
	habit_section(&out, "Last song of the night", why_closers(), sc.closers[:], NORD9,
		proc(t: Track_Score) -> string { return fmt.tprintf("%.0f%% of %d plays", t.closer_rate * 100, t.plays) }, cw)
	append(&out, muted("Run with --scores to test how well this model predicts your own replays."))
	return join_v(out[:])
}

// ── Rhythm ───────────────────────────────────────────────────────────────────

DAY_NAMES := [7]string{"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}

build_rhythm :: proc(s: ^Stats, cw: int) -> string {
	out := make([dynamic]string, context.temp_allocator)

	// Heatmap: weekday × hour
	if len(s.heatmap) == 168 {
		cell_w := 2 if cw >= 24 * 2 + 6 else 1
		append(&out, section("When you listen", cw, "hours per weekday × hour"))
		hi: f64
		for h in s.heatmap { hi = max(hi, h.hours) }

		if cell_w == 2 {
			hdr := strings.builder_make(context.temp_allocator)
			strings.write_string(&hdr, spaces(4))
			for h in 0 ..< 24 {
				label := fmt.tprintf("%d", h) if h % 3 == 0 else ""
				strings.write_string(&hdr, muted(pad_right(label, 2)))
			}
			append(&out, strings.to_string(hdr))
		}

		ramp := [?]Nord{NORD2, NORD10, NORD8, NORD13}
		for d in 0 ..< 7 {
			sb := strings.builder_make(context.temp_allocator)
			strings.write_string(&sb, muted(pad_right(DAY_NAMES[d], 4)))
			for h in 0 ..< 24 {
				v := s.heatmap[d * 24 + h].hours / max(hi, 1e-9)
				c := ramp_color(ramp[:], v)
				strings.write_string(&sb, paint(Style{bg = c}, spaces(cell_w)))
			}
			append(&out, strings.to_string(sb))
		}
		swatches := strings.builder_make(context.temp_allocator)
		for i in 0 ..< 8 {
			strings.write_string(&swatches, paint(Style{bg = ramp_color(ramp[:], f64(i) / 7)}, "  "))
		}
		append(&out, "", strings.concatenate({spaces(4), muted("less "), strings.to_string(swatches), muted(" more")}, context.temp_allocator), "")
	}

	// By year: hours + average track length
	if len(s.hours_by_year) > 0 {
		append(&out, section("Year by year", cw))
		hi: f64
		for yh in s.hours_by_year { hi = max(hi, yh.hours) }
		bw := max(8, cw - 5 - 8 - 12)
		for yh, i in s.hours_by_year {
			avg := ""
			for al in s.avg_track_length {
				if al.year == yh.year { avg = fmt.tprintf("%.1f min/track", al.minutes) }
			}
			append(&out, strings.concatenate({
				fgs(COL_ACCENT, fmt.tprintf("%d", yh.year), true), " ",
				hbar(yh.hours, hi, bw, NORD10, NORD8, thin = true), " ",
				fgs(COL_TEXT, pad_left(fmt.tprintf("%.0fh", yh.hours), 5)), "  ",
				muted(avg),
			}, context.temp_allocator))
			_ = i
		}
		append(&out, "")
	}

	// Explore vs obsess
	if len(s.explore_obsess) > 0 {
		append(&out, section("Explore vs. obsess", cw, "share of each year's listening"))
		colors := [?]Nord{NORD14, NORD8, NORD3}
		bw := max(10, cw - 6 - 24)
		for e in s.explore_obsess {
			bar := stacked_bar({f64(e.new_pct), f64(e.top10_pct), f64(e.rest_pct)}, colors[:], bw, thin = true)
			append(&out, strings.concatenate({
				fgs(COL_ACCENT, fmt.tprintf("%d", e.year), true), " ", bar, "  ",
				muted(fmt.tprintf("%d new artists", e.new_count)),
			}, context.temp_allocator))
		}
		append(&out, strings.concatenate({
			spaces(5),
			fgs(NORD14, "■"), muted(" new artists   "),
			fgs(NORD8, "■"), muted(" all-time top 10   "),
			fgs(NORD3, "■"), muted(" the rest"),
		}, context.temp_allocator))
	}
	return join_v(out[:])
}

// ── Genres ───────────────────────────────────────────────────────────────────

Genre_Share :: struct {
	name:   string,
	share:  f64,
	series: [dynamic]f64,
}

genre_color :: proc(name: string, order_idx: int) -> Nord {
	if name == "Other" || name == UNCLASSIFIED do return COL_MUTED
	return SERIES_COLORS[order_idx % len(SERIES_COLORS)]
}

// Average a series down to n buckets.
downsample :: proc(values: []f64, n: int) -> []f64 {
	if len(values) <= n do return values
	out := make([]f64, n, context.temp_allocator)
	for i in 0 ..< n {
		lo := i * len(values) / n
		hi := max(lo + 1, (i + 1) * len(values) / n)
		sum: f64
		for v in values[lo:hi] { sum += v }
		out[i] = sum / f64(hi - lo)
	}
	return out
}

build_genres :: proc(s: ^Stats, cw: int) -> string {
	out := make([dynamic]string, context.temp_allocator)
	if len(s.genre_area) == 0 {
		return muted("No genre data.")
	}

	shares := make([dynamic]Genre_Share, context.temp_allocator)
	for g in s.genre_order {
		gs := Genre_Share{name = g}
		gs.series = make([dynamic]f64, context.temp_allocator)
		for q in s.genre_area {
			v := q.values[g] or_else 0
			append(&gs.series, v)
			gs.share += v
		}
		gs.share /= f64(len(s.genre_area))
		append(&shares, gs)
	}
	order_idx := make(map[string]int, context.temp_allocator)
	for g, i in s.genre_order { order_idx[g] = i }

	// Sort by share, desc (insertion sort; ≤ 14 items)
	for i in 1 ..< len(shares) {
		j := i
		for j > 0 && shares[j - 1].share < shares[j].share {
			shares[j - 1], shares[j] = shares[j], shares[j - 1]
			j -= 1
		}
	}

	parts := make([dynamic]f64, context.temp_allocator)
	colors := make([dynamic]Nord, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	pcts := make([dynamic]f64, context.temp_allocator)
	for g in shares {
		if g.share < 0.5 do continue
		append(&parts, g.share)
		append(&colors, genre_color(g.name, order_idx[g.name]))
		append(&names, g.name)
		append(&pcts, g.share)
	}

	first_q := s.genre_area[0].quarter
	last := s.genre_area[len(s.genre_area) - 1]
	last_q := fmt.tprintf("%s (partial)", last.quarter) if last.partial else last.quarter
	append(&out, section("Genre mix", cw, fmt.tprintf("%s → %s", first_q, last_q)))
	append(&out, stacked_bar(parts[:], colors[:], cw))
	append(&out, wrap_items(legend_items(names[:], pcts[:], colors[:]), cw), "")

	append(&out, section("Evolution", cw, "share of listening per quarter"))
	nw := 15
	spark_w := clamp(cw - nw - 12, 8, 32)
	hi: f64
	for g in shares { hi = max(hi, g.share) }
	for g in shares {
		if g.share < 0.5 do continue
		c := genre_color(g.name, order_idx[g.name])
		spark := sparkline(downsample(g.series[:], spark_w), c)
		append(&out, strings.concatenate({
			fgs(c, "■"), " ", fgs(COL_BRIGHT, pad_right(g.name, nw)), " ",
			spark, spaces(spark_w - min(spark_w, len(g.series))), "  ",
			fgs(COL_TEXT, pad_left(fmt.tprintf("%.1f%%", g.share), 6)),
		}, context.temp_allocator))
	}
	note := fmt.tprintf("%.1f%% of listening annotated", 100 - s.genre_unclassified_pct)
	if s.genre_unclassified_pct > 0 {
		note = fmt.tprintf("%s · %.1f%% unclassified (not the same as Other)", note, s.genre_unclassified_pct)
	}
	if s.genre_user_targets > 0 {
		note = fmt.tprintf("%s · %d set by you", note, s.genre_user_targets)
	}
	append(&out, "", muted(note))
	return join_v(out[:])
}
