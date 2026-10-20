package spotify_report

// The main Bubble Tea model: a progress screen while the pipeline runs on a
// worker thread, then a tabbed, scrollable dashboard.

import "core:fmt"
import "core:c/libc"
import "core:strings"
import "core:time"

App_Phase :: enum {
	Running,
	Dashboard,
	Failed,
}

Tab :: enum {
	Overview,
	Artists,
	Library,
	Habits,
	Rhythm,
	Genres,
}

TAB_TITLES := [Tab]string{
	.Overview = "Overview",
	.Artists  = "Artists",
	.Library  = "Library",
	.Habits   = "Habits",
	.Rhythm   = "Rhythm",
	.Genres   = "Genres",
}

TICK_FRAME :: 1
TICK_MS    :: 40

Stage_Row :: struct {
	state:   Stage_State,
	current: int,
	total:   int,
	detail:  string,
	shown:   f64, // animated progress, 0..1
}

App :: struct {
	w, h:        int,
	phase:       App_Phase,
	frame:       int,
	started:     time.Tick,
	rows:        [Stage]Stage_Row,
	opts:        Run_Opts,
	stats:       ^Stats,
	elapsed_ms:  int,
	err_title:   string,
	err_hint:    string,

	tab:         Tab,
	vps:         [Tab]Viewport,
	built_w:     [Tab]int, // content width each tab was built for (0 = stale)

	toast:       string,
	toast_until: int, // frame number
}

app_init :: proc(a: ^App, opts: Run_Opts) {
	a.opts = opts
	a.started = time.tick_now()
}

// ── Update ───────────────────────────────────────────────────────────────────

app_update :: proc(m: rawptr, msg: Msg) -> (cmd: Cmd) {
	a := (^App)(m)

	#partial switch v in msg {
	case Window_Size_Msg:
		a.w, a.h = v.width, v.height
		app_layout(a)

	case Tick_Msg:
		a.frame += 1
		for &r in a.rows {
			target := 0.0
			if r.total > 0 do target = f64(r.current) / f64(r.total)
			if r.state == .Done do target = 1
			r.shown += (target - r.shown) * 0.3
		}
		if a.phase == .Running || a.frame < a.toast_until {
			cmd = cmd_tick(TICK_MS, TICK_FRAME)
		}

	case Stage_Msg:
		r := &a.rows[v.stage]
		r.state = v.state
		r.current = v.current
		r.total = v.total
		r.detail = v.detail

	case Done_Msg:
		a.elapsed_ms = v.elapsed_ms
		if v.ok {
			a.phase = .Dashboard
			a.stats = v.stats
			app_layout(a)
		} else {
			a.phase = .Failed
			a.err_title = v.err_title
			a.err_hint = v.err_hint
		}

	case Key_Msg:
		return app_key(a, v)

	case Mouse_Msg:
		if a.phase == .Dashboard do viewport_update(&a.vps[a.tab], v)
	}
	return
}

app_key :: proc(a: ^App, k: Key_Msg) -> (cmd: Cmd) {
	if !k.ctrl && k.key == .Rune && (k.r == 'q' || k.r == 'Q') do return cmd_quit()
	if k.key == .Esc do return cmd_quit()
	if a.phase != .Dashboard do return

	tabs := len(Tab)
	switch {
	case k.key == .Tab || k.key == .Right || (k.key == .Rune && !k.ctrl && k.r == 'l'):
		a.tab = Tab((int(a.tab) + 1) % tabs)
		app_layout(a)
	case k.key == .Shift_Tab || k.key == .Left || (k.key == .Rune && !k.ctrl && k.r == 'h'):
		a.tab = Tab((int(a.tab) + tabs - 1) % tabs)
		app_layout(a)
	case k.key == .Rune && !k.ctrl && k.r >= '1' && k.r <= rune('0' + tabs):
		a.tab = Tab(int(k.r - '1'))
		app_layout(a)
	case k.key == .Rune && !k.ctrl && k.r == 'o':
		open_path(a.opts.output_path)
		a.toast = "Opened report in your browser"
		a.toast_until = a.frame + 50
		cmd = cmd_tick(TICK_MS, TICK_FRAME)
	case:
		viewport_update(&a.vps[a.tab], k)
	}
	return
}

open_path :: proc(path: string) {
	opener := "open" if ODIN_OS == .Darwin else "xdg-open"
	quoted, _ := strings.replace_all(path, "'", "'\\''", context.temp_allocator)
	cmd := fmt.ctprintf("%s '%s' >/dev/null 2>&1 &", opener, quoted)
	libc.system(cmd)
}

// Size the active tab's viewport and (re)build its content if the width changed.
app_layout :: proc(a: ^App) {
	if a.phase != .Dashboard || a.stats == nil do return
	// Only the active tab is built eagerly; the rest when first selected.
	vp := &a.vps[a.tab]
	vp.w = a.w
	vp.h = max(3, a.h - 4)
	cw := content_width(a.w)
	if a.built_w[a.tab] != cw {
		body := build_tab(a.tab, a.stats, cw)
		viewport_set_content(vp, indent_block(body, 2))
		a.built_w[a.tab] = cw
	}
	viewport_clamp(vp)
}

content_width :: proc(w: int) -> int {
	return max(30, w - 5) // 2 margin each side + scrollbar
}

// ── View ─────────────────────────────────────────────────────────────────────

app_view :: proc(m: rawptr, w, h: int) -> string {
	a := (^App)(m)
	switch a.phase {
	case .Running, .Failed: return view_progress(a, w, h)
	case .Dashboard:        return view_dashboard(a, w, h)
	}
	return ""
}

logo_block :: proc() -> string {
	art := [3]string{"▗▄▄▄▖", "▐   ▌", "▝▀▀▀▘"}
	right := [3]string{
		fgs(COL_BRIGHT, "spotify-history-report", true),
		muted("Turn your Spotify export into a beautiful report"),
		faint("local · private · one binary"),
	}
	rows: [3]string
	for i in 0 ..< 3 {
		rows[i] = strings.concatenate({fgs(COL_ACCENT, art[i], true), "  ", right[i]}, context.temp_allocator)
	}
	return join_v(rows[:])
}

stage_line :: proc(a: ^App, st: Stage, inner: int) -> string {
	r := a.rows[st]
	title := STAGE_TITLES[st]
	icon, title_s: string
	switch r.state {
	case .Pending:
		icon = faint("○")
		title_s = faint(pad_right(title, 8))
	case .Active:
		icon = spinner_view(a.frame)
		title_s = fgs(COL_BRIGHT, pad_right(title, 8), true)
	case .Done:
		icon = fgs(COL_OK, "✓", true)
		title_s = fgs(COL_TEXT, pad_right(title, 8))
	case .Failed:
		icon = fgs(COL_ERR, "✗", true)
		title_s = fgs(COL_ERR, pad_right(title, 8), true)
	}

	avail := inner - 2 - 8 - 2
	rest := ""
	switch r.state {
	case .Pending:
	case .Active:
		if r.total > 0 {
			bar_w := clamp(avail / 3, 10, 24)
			count := fmt.tprintf(" %d/%d ", r.current, r.total)
			rest = strings.concatenate({
				progress_view(r.shown, bar_w), muted(count),
				muted(truncate(r.detail, max(0, avail - bar_w - 5 - len(count)))),
			}, context.temp_allocator)
		} else {
			rest = muted(truncate(r.detail, avail))
		}
	case .Done:
		rest = muted(truncate(r.detail, avail))
	case .Failed:
		rest = fgs(COL_ERR, truncate(r.detail, avail))
	}
	return strings.concatenate({icon, " ", title_s, "  ", rest}, context.temp_allocator)
}

view_progress :: proc(a: ^App, w, h: int) -> string {
	pw := clamp(w - 4, 36, 78)
	inner := pw - 4

	lines: [len(Stage)]string
	for st in Stage { lines[int(st)] = stage_line(a, st, inner) }
	card := panel(a.phase == .Failed ? "Stopped" : "Working", join_v(lines[:]), pw,
		COL_ERR if a.phase == .Failed else COL_FAINT,
		COL_ERR if a.phase == .Failed else COL_ACCENT)

	parts := make([dynamic]string, context.temp_allocator)
	append(&parts, logo_block(), "", card)

	if a.phase == .Failed {
		body := strings.concatenate({
			fgs(COL_ERR, wrap_text(a.err_title, pw - 6), true), "\n\n",
			muted(wrap_text(a.err_hint, pw - 6)),
		}, context.temp_allocator)
		append(&parts, "", panel("What happened", body, pw, COL_ERR, COL_ERR))
	} else {
		secs := f64(time.duration_milliseconds(time.tick_since(a.started))) / 1000
		append(&parts, "", muted(fmt.tprintf("  elapsed %.1fs", secs)))
	}
	append(&parts, "", help_view([]Help_Item{{"q", "quit"}}))

	block := join_v(parts[:])
	block = center_block(block, w)
	top := max(0, (h - block_height(block)) / 3)
	return strings.concatenate({repeat_str("\n", top), block}, context.temp_allocator)
}

view_dashboard :: proc(a: ^App, w, h: int) -> string {
	s := a.stats

	// Header
	badge := render(Style{fg = COL_ON_ACCENT, bg = COL_ACCENT, bold = true, pad = {0, 1, 0, 1}}, "♪ spotify-history-report")
	range := muted(fmt.tprintf("%s – %s", s.date_range_start, s.date_range_end))
	left := strings.concatenate({" ", badge, "  ", range}, context.temp_allocator)
	right := muted(truncate(fmt.tprintf("report → %s ", a.opts.output_path), max(10, w - text_width(left) - 2)))
	header := left
	if gap := w - text_width(left) - text_width(right); gap >= 1 {
		header = strings.concatenate({left, spaces(gap), right}, context.temp_allocator)
	}

	// Tabs + rule (the active tab's span is drawn heavy in the accent color)
	tabs_sb := strings.builder_make(context.temp_allocator)
	rule_sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&tabs_sb, " ")
	strings.write_string(&rule_sb, faint("─"))
	for t in Tab {
		label := fmt.tprintf(" %d %s ", int(t) + 1, TAB_TITLES[t])
		lw := text_width(label)
		if t == a.tab {
			strings.write_string(&tabs_sb, fgs(COL_ACCENT, label, true))
			strings.write_string(&rule_sb, fgs(COL_ACCENT, repeat_str("━", lw)))
		} else {
			strings.write_string(&tabs_sb, muted(label))
			strings.write_string(&rule_sb, faint(repeat_str("─", lw)))
		}
	}
	strings.write_string(&rule_sb, faint(repeat_str("─", max(0, w - text_width(strings.to_string(rule_sb))))))

	body := viewport_view(&a.vps[a.tab])

	// Status bar
	vp := &a.vps[a.tab]
	mode := render(Style{fg = COL_ON_ACCENT, bg = COL_ACCENT2, bold = true, pad = {0, 1, 0, 1}}, strings.to_upper(TAB_TITLES[a.tab], context.temp_allocator))
	help := help_view([]Help_Item{{"tab", "switch"}, {"↑↓", "scroll"}, {"o", "open report"}, {"q", "quit"}})
	if w < 72 do help = help_view([]Help_Item{{"tab", "switch"}, {"o", "open"}, {"q", "quit"}})
	status_right := fmt.tprintf("%s%% ", pad_left(fmt.tprintf("%d", viewport_percent(vp)), 3))
	if a.frame < a.toast_until do status_right = fmt.tprintf("%s  %s ", a.toast, status_right)
	status_left := strings.concatenate({mode, " ", help}, context.temp_allocator)
	fill := spaces(max(0, w - text_width(status_left) - text_width(status_right)))
	status := paint(Style{bg = COL_SURFACE}, strings.concatenate({status_left, fill, muted(status_right)}, context.temp_allocator))

	return join_v({header, strings.to_string(tabs_sb), strings.to_string(rule_sb), body, status})
}

// ── Exit summary ─────────────────────────────────────────────────────────────

// Printed to the normal screen after the TUI exits (and in plain mode).
summary_text :: proc(s: ^Stats, path: string, elapsed_ms: int) -> string {
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, fmt.tprintf("  %s %s", fgs(COL_OK, "✓", true), fgs(COL_BRIGHT, "Report ready", true)))
	append(&lines, fmt.tprintf("    %s  %s", muted(pad_right("file", 8)), fgs(COL_ACCENT, path)))
	append(&lines, fmt.tprintf("    %s  %s plays · %s hours · %s artists",
		muted(pad_right("library", 8)), fgs(COL_TEXT, fmt_int(s.total_plays)),
		fgs(COL_TEXT, fmt_int(s.total_hours)), fgs(COL_TEXT, fmt_int(s.unique_artists))))
	if elapsed_ms > 0 {
		append(&lines, fmt.tprintf("    %s  %.1fs", muted(pad_right("took", 8)), f64(elapsed_ms) / 1000))
	}
	return strings.join(lines[:], "\n", context.temp_allocator)
}
