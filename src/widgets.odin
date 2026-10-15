package spotify_report

// Components in the spirit of charmbracelet/bubbles: spinner, progress,
// viewport, text input — plus a few chart primitives for the dashboard.

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

// ── Spinner ──────────────────────────────────────────────────────────────────

SPINNER_FRAMES := [?]string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

spinner_view :: proc(frame: int, color: Nord = COL_ACCENT) -> string {
	return fgs(color, SPINNER_FRAMES[frame % len(SPINNER_FRAMES)])
}

// ── Bars ─────────────────────────────────────────────────────────────────────

EIGHTHS := [?]string{" ", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█"}

// Horizontal bar with 1/8-cell precision. Returns exactly `width` columns.
// If `to` is set the bar is a gradient from `from` to `to`.
hbar :: proc(value, max_value: f64, width: int, from: Nord, to: Maybe(Nord) = nil, track := true) -> string {
	if width <= 0 do return ""
	frac := clamp(value / max(max_value, 1e-9), 0, 1)
	eighths := int(frac * f64(width) * 8 + 0.5)
	full := eighths / 8
	part := eighths % 8

	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< full {
		c := from
		if t, ok := to.?; ok do c = lerp_color(from, t, f64(i) / f64(max(width - 1, 1)))
		strings.write_string(&sb, fgs(c, "█"))
	}
	used := full
	if part > 0 && full < width {
		c := from
		if t, ok := to.?; ok do c = lerp_color(from, t, f64(full) / f64(max(width - 1, 1)))
		strings.write_string(&sb, fgs(c, EIGHTHS[part]))
		used += 1
	}
	if track && used < width {
		strings.write_string(&sb, faint(repeat_str("░", width - used)))
	} else if used < width {
		strings.write_string(&sb, spaces(width - used))
	}
	return strings.to_string(sb)
}

// Bubbles-style progress bar: gradient fill, percentage on the right.
progress_view :: proc(pct: f64, width: int, show_pct := true) -> string {
	pct_s := ""
	w := width
	if show_pct {
		pct_s = fmt.tprintf(" %s%%", pad_left(fmt.tprintf("%d", int(clamp(pct, 0, 1) * 100 + 0.5)), 3))
		w -= len(pct_s)
	}
	bar := hbar(pct, 1, w, NORD8, NORD14)
	return strings.concatenate({bar, muted(pct_s)}, context.temp_allocator)
}

SPARK_LEVELS := [?]string{"▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"}

sparkline :: proc(values: []f64, color: Nord) -> string {
	if len(values) == 0 do return ""
	hi: f64
	for v in values { hi = max(hi, v) }
	sb := strings.builder_make(context.temp_allocator)
	for v in values {
		idx := 0
		if hi > 0 do idx = clamp(int(v / hi * f64(len(SPARK_LEVELS) - 1) + 0.5), 0, len(SPARK_LEVELS) - 1)
		strings.write_string(&sb, SPARK_LEVELS[idx])
	}
	return fgs(color, strings.to_string(sb))
}

// Vertical column chart: one column per value, `height` rows, labels beneath.
column_chart :: proc(values: []f64, labels, sub_labels: []string, height, col_w, gap: int, from, to: Nord) -> string {
	if len(values) == 0 do return ""
	hi: f64
	for v in values { hi = max(hi, v) }
	rows := make([dynamic]string, 0, height + 2, context.temp_allocator)

	for r in 0 ..< height {
		level := height - r // 1..height, top row first
		sb := strings.builder_make(context.temp_allocator)
		for v, i in values {
			// Height of this column in eighths.
			total := int(v / max(hi, 1e-9) * f64(height) * 8 + 0.5)
			cell_eighths := clamp(total - (level - 1) * 8, 0, 8)
			col := lerp_color(from, to, f64(i) / f64(max(len(values) - 1, 1)))
			glyph := " "
			switch cell_eighths {
			case 0: glyph = " "
			case 1: glyph = "▁"
			case 2: glyph = "▂"
			case 3: glyph = "▃"
			case 4: glyph = "▄"
			case 5: glyph = "▅"
			case 6: glyph = "▆"
			case 7: glyph = "▇"
			case 8: glyph = "█"
			}
			cell := spaces(col_w) if cell_eighths == 0 else repeat_str(glyph, col_w)
			strings.write_string(&sb, fgs(col, cell))
			strings.write_string(&sb, spaces(gap))
		}
		append(&rows, strings.to_string(sb))
	}
	for set, si in ([2][]string{labels, sub_labels}) {
		if len(set) == 0 do continue
		sb := strings.builder_make(context.temp_allocator)
		for l in set {
			cell := align_text(truncate(l, col_w + gap, ""), col_w, .Center)
			strings.write_string(&sb, fgs(COL_TEXT if si == 0 else COL_MUTED, cell))
			strings.write_string(&sb, spaces(gap))
		}
		append(&rows, strings.to_string(sb))
	}
	return strings.join(rows[:], "\n", context.temp_allocator)
}

// ── Viewport ─────────────────────────────────────────────────────────────────

Viewport :: struct {
	lines: [dynamic]string,
	y:     int,
	w, h:  int,
}

viewport_set_content :: proc(vp: ^Viewport, content: string) {
	for l in vp.lines { delete(l) }
	clear(&vp.lines)
	for l in strings.split(content, "\n", context.temp_allocator) {
		append(&vp.lines, strings.clone(l))
	}
	viewport_clamp(vp)
}

viewport_max_y :: proc(vp: ^Viewport) -> int {
	return max(0, len(vp.lines) - vp.h)
}

viewport_clamp :: proc(vp: ^Viewport) {
	vp.y = clamp(vp.y, 0, viewport_max_y(vp))
}

viewport_scroll :: proc(vp: ^Viewport, delta: int) {
	vp.y += delta
	viewport_clamp(vp)
}

viewport_percent :: proc(vp: ^Viewport) -> int {
	m := viewport_max_y(vp)
	if m == 0 do return 100
	return vp.y * 100 / m
}

// Key handling shared by scrollable views. Returns true if consumed.
viewport_update :: proc(vp: ^Viewport, msg: Msg) -> bool {
	#partial switch m in msg {
	case Key_Msg:
		if m.ctrl {
			switch m.r {
			case 'd': viewport_scroll(vp, vp.h / 2); return true
			case 'u': viewport_scroll(vp, -(vp.h / 2)); return true
			case 'f': viewport_scroll(vp, vp.h); return true
			case 'b': viewport_scroll(vp, -vp.h); return true
			}
			return false
		}
		#partial switch m.key {
		case .Up:        viewport_scroll(vp, -1); return true
		case .Down:      viewport_scroll(vp, 1); return true
		case .Page_Up:   viewport_scroll(vp, -vp.h); return true
		case .Page_Down: viewport_scroll(vp, vp.h); return true
		case .Home:      vp.y = 0; return true
		case .End:       vp.y = viewport_max_y(vp); return true
		case .Rune:
			switch m.r {
			case 'k': viewport_scroll(vp, -1); return true
			case 'j': viewport_scroll(vp, 1); return true
			case 'g': vp.y = 0; return true
			case 'G': vp.y = viewport_max_y(vp); return true
			case ' ': viewport_scroll(vp, vp.h); return true
			}
		}
	case Mouse_Msg:
		if m.wheel != 0 {
			viewport_scroll(vp, m.wheel * 3)
			return true
		}
	}
	return false
}

// Render the visible window, with a scrollbar column on the right when the
// content overflows. Output is exactly vp.h lines of vp.w columns.
viewport_view :: proc(vp: ^Viewport) -> string {
	out := make([dynamic]string, 0, vp.h, context.temp_allocator)
	overflow := len(vp.lines) > vp.h
	body_w := vp.w - 1 if overflow else vp.w

	thumb_h, thumb_y := 0, 0
	if overflow {
		thumb_h = max(1, vp.h * vp.h / len(vp.lines))
		thumb_y = vp.y * (vp.h - thumb_h) / max(viewport_max_y(vp), 1)
	}

	for r in 0 ..< vp.h {
		line := ""
		if vp.y + r < len(vp.lines) do line = vp.lines[vp.y + r]
		row := align_text(truncate(line, body_w, ""), body_w, .Left)
		if overflow {
			bar := faint("│")
			if r >= thumb_y && r < thumb_y + thumb_h do bar = fgs(COL_ACCENT2, "┃")
			row = strings.concatenate({row, bar}, context.temp_allocator)
		}
		append(&out, row)
	}
	return strings.join(out[:], "\n", context.temp_allocator)
}

// ── Text input ───────────────────────────────────────────────────────────────

Text_Input :: struct {
	value:       [dynamic]rune,
	pos:         int,
	mask:        bool,
	placeholder: string,
	width:       int,
	focused:     bool,
}

text_input_set :: proc(ti: ^Text_Input, s: string) {
	clear(&ti.value)
	for r in s { append(&ti.value, r) }
	ti.pos = len(ti.value)
}

text_input_string :: proc(ti: ^Text_Input) -> string {
	return utf8.runes_to_string(ti.value[:], context.temp_allocator)
}

text_input_insert :: proc(ti: ^Text_Input, r: rune) {
	inject_at(&ti.value, ti.pos, r)
	ti.pos += 1
}

text_input_update :: proc(ti: ^Text_Input, msg: Msg) {
	if !ti.focused do return
	#partial switch m in msg {
	case Paste_Msg:
		for r in m.text {
			if r >= ' ' do text_input_insert(ti, r) // drops newlines
		}
	case Key_Msg:
		if m.ctrl {
			switch m.r {
			case 'a': ti.pos = 0
			case 'e': ti.pos = len(ti.value)
			case 'u': remove_range(&ti.value, 0, ti.pos); ti.pos = 0
			case 'k': resize(&ti.value, ti.pos)
			case 'w':
				i := ti.pos
				for i > 0 && ti.value[i - 1] == ' ' do i -= 1
				for i > 0 && ti.value[i - 1] != ' ' do i -= 1
				remove_range(&ti.value, i, ti.pos)
				ti.pos = i
			}
			return
		}
		#partial switch m.key {
		case .Rune:      if m.r >= ' ' && !m.alt do text_input_insert(ti, m.r)
		case .Left:      ti.pos = max(0, ti.pos - 1)
		case .Right:     ti.pos = min(len(ti.value), ti.pos + 1)
		case .Home:      ti.pos = 0
		case .End:       ti.pos = len(ti.value)
		case .Backspace: if ti.pos > 0 { ordered_remove(&ti.value, ti.pos - 1); ti.pos -= 1 }
		case .Delete:    if ti.pos < len(ti.value) do ordered_remove(&ti.value, ti.pos)
		}
	}
}

// Renders with a virtual (reverse-video) cursor, as Bubble Tea's textinput does.
text_input_view :: proc(ti: ^Text_Input) -> string {
	sb := strings.builder_make(context.temp_allocator)
	if len(ti.value) == 0 {
		ph := ti.placeholder
		if ti.focused {
			first, size := ' ', 1
			if len(ph) > 0 do first, size = utf8.decode_rune_in_string(ph)
			strings.write_string(&sb, paint(Style{reverse = true}, utf8.runes_to_string([]rune{first}, context.temp_allocator)))
			if len(ph) > 0 do strings.write_string(&sb, muted(ph[size:]))
		} else {
			strings.write_string(&sb, muted(ph))
		}
		return strings.to_string(sb)
	}

	// Show the tail that fits in `width`.
	vis := ti.width if ti.width > 0 else len(ti.value) + 1
	start := 0
	if ti.pos >= vis do start = ti.pos - vis + 1
	end := min(len(ti.value), start + vis)
	for i in start ..< end {
		r := ti.value[i]
		if ti.mask do r = '•'
		cell := utf8.runes_to_string([]rune{r}, context.temp_allocator)
		if ti.focused && i == ti.pos {
			strings.write_string(&sb, paint(Style{reverse = true}, cell))
		} else {
			strings.write_string(&sb, fgs(COL_TEXT, cell))
		}
	}
	if ti.focused && ti.pos >= end {
		strings.write_string(&sb, paint(Style{reverse = true}, " "))
	}
	return strings.to_string(sb)
}

// ── Help bar ─────────────────────────────────────────────────────────────────

Help_Item :: struct {
	key, desc: string,
}

help_view :: proc(items: []Help_Item) -> string {
	parts := make([dynamic]string, 0, len(items), context.temp_allocator)
	for it in items {
		append(&parts, strings.concatenate({fgs(COL_TEXT, it.key, true), " ", muted(it.desc)}, context.temp_allocator))
	}
	return strings.join(parts[:], faint("  ·  "), context.temp_allocator)
}
