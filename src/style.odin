package spotify_report

// Styling & layout, a small subset of charmbracelet/lipgloss:
// colors with profile fallback, Style.render, borders, padding,
// ANSI-aware width/truncate, and horizontal/vertical joins.
//
// Everything returned here is allocated with context.temp_allocator, so call
// sites never free; the Tea loop clears the temp arena once per frame.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

RESET :: "\x1b[0m"

Color_Profile :: enum {
	None,       // no color at all (pipes, NO_COLOR)
	ANSI,       // 16 colors: the Nord Terminal.app theme supplies the palette
	ANSI256,
	True_Color, // exact Nord RGB
}

color_profile: Color_Profile = .None

// SHR_COLOR=truecolor|256|ansi|none overrides detection.
detect_color_profile :: proc() {
	if v := os.get_env_alloc("SHR_COLOR", context.temp_allocator); len(v) > 0 {
		switch v {
		case "truecolor", "24bit": color_profile = .True_Color
		case "256":                color_profile = .ANSI256
		case "ansi", "16":         color_profile = .ANSI
		case:                      color_profile = .None
		}
		return
	}
	if len(os.get_env_alloc("NO_COLOR", context.temp_allocator)) > 0 || !is_tty(STDOUT_FD) {
		color_profile = .None
		return
	}
	ct := os.get_env_alloc("COLORTERM", context.temp_allocator)
	if ct == "truecolor" || ct == "24bit" {
		color_profile = .True_Color
		return
	}
	// Terminal.app, iTerm, etc.: stick to the 16-color slots so an installed
	// Nord theme (nordtheme/terminal-app) paints them.
	color_profile = .ANSI
}

// ── Colors ───────────────────────────────────────────────────────────────────

lerp_color :: proc(a, b: Nord, t: f64) -> Nord {
	t := clamp(t, 0, 1)
	mix :: proc(x, y: u8, t: f64) -> u8 { return u8(f64(x) + (f64(y) - f64(x)) * t + 0.5) }
	return Nord{mix(a.r, b.r, t), mix(a.g, b.g, t), mix(a.b, b.b, t), ANSI_NONE}
}

// Multi-stop gradient, t in [0,1].
ramp_color :: proc(stops: []Nord, t: f64) -> Nord {
	if len(stops) == 1 do return stops[0]
	t := clamp(t, 0, 1) * f64(len(stops) - 1)
	i := min(int(t), len(stops) - 2)
	return lerp_color(stops[i], stops[i + 1], t - f64(i))
}

// xterm-256 quantization (6x6x6 cube + grayscale ramp).
quantize_256 :: proc(c: Nord) -> int {
	cube :: proc(v: u8) -> int {
		if v < 48 do return 0
		if v < 115 do return 1
		return (int(v) - 35) / 40
	}
	steps := [6]int{0, 95, 135, 175, 215, 255}
	ri, gi, bi := cube(c.r), cube(c.g), cube(c.b)
	cube_idx := 16 + 36 * ri + 6 * gi + bi
	dist :: proc(a, b: [3]int) -> int {
		d := 0
		for i in 0 ..< 3 { d += (a[i] - b[i]) * (a[i] - b[i]) }
		return d
	}
	want := [3]int{int(c.r), int(c.g), int(c.b)}
	cube_d := dist(want, {steps[ri], steps[gi], steps[bi]})

	avg := (int(c.r) + int(c.g) + int(c.b)) / 3
	gi_idx := clamp((avg - 8 + 5) / 10, 0, 23)
	gv := 8 + gi_idx * 10
	gray_d := dist(want, {gv, gv, gv})
	if gray_d < cube_d do return 232 + gi_idx
	return cube_idx
}

// SGR parameter string for a color (without the leading 38/48 for ANSI slots).
color_sgr :: proc(c: Nord, background: bool) -> string {
	base := 48 if background else 38
	switch color_profile {
	case .None:
		return ""
	case .True_Color:
		return fmt.tprintf("%d;2;%d;%d;%d", base, c.r, c.g, c.b)
	case .ANSI256:
		if c.ansi == ANSI_DEFAULT do return "49" if background else "39"
		return fmt.tprintf("%d;5;%d", base, quantize_256(c))
	case .ANSI:
		if c.ansi == ANSI_DEFAULT do return "49" if background else "39"
		if c.ansi == ANSI_NONE do return fmt.tprintf("%d;5;%d", base, quantize_256(c))
		slot := int(c.ansi)
		if slot < 8 do return fmt.tprintf("%d", (40 if background else 30) + slot)
		return fmt.tprintf("%d", (100 if background else 90) + slot - 8)
	}
	return ""
}

fg_code :: proc(c: Nord) -> string {
	s := color_sgr(c, false)
	if len(s) == 0 do return ""
	return fmt.tprintf("\x1b[%sm", s)
}

bg_code :: proc(c: Nord) -> string {
	s := color_sgr(c, true)
	if len(s) == 0 do return ""
	return fmt.tprintf("\x1b[%sm", s)
}

// ── Style ────────────────────────────────────────────────────────────────────

Align :: enum {
	Left,
	Center,
	Right,
}

Border :: enum {
	None,
	Rounded,
	Normal,
	Thick,
}

Style :: struct {
	fg, bg:    Maybe(Nord),
	bold:      bool,
	dim:       bool,
	italic:    bool,
	underline: bool,
	reverse:   bool,
	pad:       [4]int, // top, right, bottom, left
	width:     int,    // exact inner width (incl. padding); 0 = fit content
	align:     Align,
	border:    Border,
	border_fg: Maybe(Nord),
}

Border_Chars :: struct {
	tl, tr, bl, br, h, v: string,
}

border_chars :: proc(b: Border) -> Border_Chars {
	switch b {
	case .Rounded: return {"╭", "╮", "╰", "╯", "─", "│"}
	case .Normal:  return {"┌", "┐", "└", "┘", "─", "│"}
	case .Thick:   return {"┏", "┓", "┗", "┛", "━", "┃"}
	case .None:    return {}
	}
	return {}
}

sgr_prefix :: proc(s: Style) -> string {
	if color_profile == .None do return ""
	b := strings.builder_make(context.temp_allocator)
	if s.bold      do strings.write_string(&b, "\x1b[1m")
	if s.dim       do strings.write_string(&b, "\x1b[2m")
	if s.italic    do strings.write_string(&b, "\x1b[3m")
	if s.underline do strings.write_string(&b, "\x1b[4m")
	if s.reverse   do strings.write_string(&b, "\x1b[7m")
	if c, ok := s.fg.?; ok do strings.write_string(&b, fg_code(c))
	if c, ok := s.bg.?; ok do strings.write_string(&b, bg_code(c))
	return strings.to_string(b)
}

// Paint each line of text with the style's SGR codes (self-contained lines).
paint :: proc(s: Style, text: string) -> string {
	pre := sgr_prefix(s)
	if len(pre) == 0 do return text
	if !strings.contains(text, "\n") {
		return strings.concatenate({pre, reapply(text, pre), RESET}, context.temp_allocator)
	}
	lines := strings.split(text, "\n", context.temp_allocator)
	for &l in lines {
		l = strings.concatenate({pre, reapply(l, pre), RESET}, context.temp_allocator)
	}
	return strings.join(lines, "\n", context.temp_allocator)
}

// If text already contains resets (nested styles), restore our style after them.
reapply :: proc(text, pre: string) -> string {
	if !strings.contains(text, RESET) do return text
	rep, _ := strings.replace_all(text, RESET, strings.concatenate({RESET, pre}, context.temp_allocator), context.temp_allocator)
	return rep
}

render :: proc(s: Style, text: string) -> string {
	lines := strings.split(text, "\n", context.temp_allocator)

	inner := 0
	for l in lines { inner = max(inner, text_width(l)) }
	inner += s.pad[1] + s.pad[3]
	if s.width > 0 do inner = s.width
	content_w := inner - s.pad[1] - s.pad[3]

	out := make([dynamic]string, 0, len(lines) + 4, context.temp_allocator)
	blank := strings.repeat(" ", inner, context.temp_allocator)
	for _ in 0 ..< s.pad[0] do append(&out, paint(s, blank))
	for l in lines {
		l := l
		if text_width(l) > content_w do l = truncate(l, content_w)
		aligned := align_text(l, content_w, s.align)
		row := strings.concatenate({
			strings.repeat(" ", s.pad[3], context.temp_allocator),
			aligned,
			strings.repeat(" ", s.pad[1], context.temp_allocator),
		}, context.temp_allocator)
		append(&out, paint(s, row))
	}
	for _ in 0 ..< s.pad[2] do append(&out, paint(s, blank))

	if s.border != .None {
		bc := border_chars(s.border)
		bs := Style{fg = s.border_fg}
		hline := strings.repeat(bc.h, inner, context.temp_allocator)
		side := paint(bs, bc.v)
		framed := make([dynamic]string, 0, len(out) + 2, context.temp_allocator)
		append(&framed, paint(bs, strings.concatenate({bc.tl, hline, bc.tr}, context.temp_allocator)))
		for l in out {
			append(&framed, strings.concatenate({side, l, side}, context.temp_allocator))
		}
		append(&framed, paint(bs, strings.concatenate({bc.bl, hline, bc.br}, context.temp_allocator)))
		return strings.join(framed[:], "\n", context.temp_allocator)
	}
	return strings.join(out[:], "\n", context.temp_allocator)
}

// Shorthand: foreground-only text.
fgs :: proc(c: Nord, text: string, bold := false) -> string {
	return paint(Style{fg = c, bold = bold}, text)
}

muted :: proc(text: string) -> string { return paint(Style{fg = COL_MUTED}, text) }
faint :: proc(text: string) -> string { return paint(Style{fg = COL_FAINT}, text) }
bold  :: proc(text: string) -> string { return paint(Style{bold = true, fg = COL_BRIGHT}, text) }

// ── Measuring ────────────────────────────────────────────────────────────────

rune_width :: proc(r: rune) -> int {
	switch {
	case r == 0:                                  return 0
	case r < 0x20 || (r >= 0x7f && r < 0xa0):     return 0
	case r >= 0x300 && r <= 0x36f:                return 0 // combining
	case r >= 0x200b && r <= 0x200f:              return 0
	case r >= 0xfe00 && r <= 0xfe0f:              return 0
	case r >= 0x1100 && r <= 0x115f:              return 2
	case r >= 0x2e80 && r <= 0xa4cf:              return 2
	case r >= 0xac00 && r <= 0xd7a3:              return 2
	case r >= 0xf900 && r <= 0xfaff:              return 2
	case r >= 0xfe30 && r <= 0xfe6f:              return 2
	case r >= 0xff00 && r <= 0xff60:              return 2
	case r >= 0xffe0 && r <= 0xffe6:              return 2
	case r >= 0x1f300 && r <= 0x1f64f:            return 2
	case r >= 0x1f900 && r <= 0x1f9ff:            return 2
	case r >= 0x20000 && r <= 0x3fffd:            return 2
	}
	return 1
}

// Display width of a string, ignoring ANSI escape sequences.
text_width :: proc(s: string) -> int {
	w := 0
	i := 0
	for i < len(s) {
		if s[i] == 0x1b {
			i = skip_escape(s, i)
			continue
		}
		r, size := utf8.decode_rune_in_string(s[i:])
		w += rune_width(r)
		i += size
	}
	return w
}

// Index just past the escape sequence starting at s[i] == ESC.
skip_escape :: proc(s: string, i: int) -> int {
	j := i + 1
	if j >= len(s) do return j
	if s[j] == '[' {
		j += 1
		for j < len(s) {
			c := s[j]
			j += 1
			if c >= 0x40 && c <= 0x7e do break
		}
		return j
	}
	return j + 1
}

// Cut to at most w display columns (ANSI-aware); appends "…" when cut.
truncate :: proc(s: string, w: int, tail := "…") -> string {
	if w <= 0 do return ""
	if text_width(s) <= w do return s
	limit := w - text_width(tail)
	if limit < 0 do limit = 0
	return cut_width(s, limit, tail)
}

cut_width :: proc(s: string, limit: int, tail: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	cur := 0
	i := 0
	saw_escape := false
	for i < len(s) {
		if s[i] == 0x1b {
			j := skip_escape(s, i)
			strings.write_string(&b, s[i:j])
			saw_escape = true
			i = j
			continue
		}
		r, size := utf8.decode_rune_in_string(s[i:])
		rw := rune_width(r)
		if cur + rw > limit do break
		strings.write_string(&b, s[i:i + size])
		cur += rw
		i += size
	}
	strings.write_string(&b, tail)
	if saw_escape do strings.write_string(&b, RESET)
	return strings.to_string(b)
}

// ── Layout ───────────────────────────────────────────────────────────────────

spaces :: proc(n: int) -> string {
	if n <= 0 do return ""
	return strings.repeat(" ", n, context.temp_allocator)
}

repeat_str :: proc(s: string, n: int) -> string {
	if n <= 0 do return ""
	return strings.repeat(s, n, context.temp_allocator)
}

align_text :: proc(s: string, w: int, a: Align) -> string {
	gap := w - text_width(s)
	if gap <= 0 do return s
	switch a {
	case .Left:   return strings.concatenate({s, spaces(gap)}, context.temp_allocator)
	case .Right:  return strings.concatenate({spaces(gap), s}, context.temp_allocator)
	case .Center: return strings.concatenate({spaces(gap / 2), s, spaces(gap - gap / 2)}, context.temp_allocator)
	}
	return s
}

pad_right :: proc(s: string, w: int) -> string { return align_text(truncate(s, w), w, .Left) }
pad_left  :: proc(s: string, w: int) -> string { return align_text(truncate(s, w), w, .Right) }

block_width :: proc(s: string) -> int {
	w := 0
	for l in strings.split(s, "\n", context.temp_allocator) { w = max(w, text_width(l)) }
	return w
}

block_height :: proc(s: string) -> int {
	return strings.count(s, "\n") + 1
}

// Place blocks side by side, top-aligned, separated by `gap` columns.
join_h :: proc(blocks: []string, gap := 0) -> string {
	n := len(blocks)
	if n == 0 do return ""
	cols := make([][]string, n, context.temp_allocator)
	widths := make([]int, n, context.temp_allocator)
	height := 0
	for b, i in blocks {
		cols[i] = strings.split(b, "\n", context.temp_allocator)
		widths[i] = block_width(b)
		height = max(height, len(cols[i]))
	}
	rows := make([]string, height, context.temp_allocator)
	for y in 0 ..< height {
		sb := strings.builder_make(context.temp_allocator)
		for i in 0 ..< n {
			cell := cols[i][y] if y < len(cols[i]) else ""
			strings.write_string(&sb, cell)
			if i < n - 1 {
				strings.write_string(&sb, spaces(widths[i] - text_width(cell) + gap))
			}
		}
		rows[y] = strings.to_string(sb)
	}
	return strings.join(rows, "\n", context.temp_allocator)
}

join_v :: proc(blocks: []string, sep := "\n") -> string {
	return strings.join(blocks, sep, context.temp_allocator)
}

// Center every line of block within width w.
center_block :: proc(block: string, w: int) -> string {
	bw := block_width(block)
	left := max(0, (w - bw) / 2)
	lines := strings.split(block, "\n", context.temp_allocator)
	for &l in lines { l = strings.concatenate({spaces(left), l}, context.temp_allocator) }
	return strings.join(lines, "\n", context.temp_allocator)
}

// Rounded panel with the title set into the top border:  ╭─ Title ─────╮
panel :: proc(title: string, body: string, width: int, color: Nord = COL_FAINT, title_color: Nord = COL_ACCENT) -> string {
	inner := width - 2
	bs := Style{fg = color}
	lines := strings.split(body, "\n", context.temp_allocator)
	out := make([dynamic]string, 0, len(lines) + 2, context.temp_allocator)

	head: string
	if len(title) > 0 {
		t := truncate(title, inner - 4)
		fill := inner - 3 - text_width(t) // "─ " + t + " "
		head = strings.concatenate({paint(bs, "╭─"), " ", fgs(title_color, t, true), " ", paint(bs, repeat_str("─", fill)), paint(bs, "╮")}, context.temp_allocator)
	} else {
		head = paint(bs, strings.concatenate({"╭", repeat_str("─", inner), "╮"}, context.temp_allocator))
	}
	append(&out, head)
	side := paint(bs, "│")
	for l in lines {
		append(&out, strings.concatenate({side, " ", align_text(truncate(l, inner - 2), inner - 2, .Left), " ", side}, context.temp_allocator))
	}
	append(&out, paint(bs, strings.concatenate({"╰", repeat_str("─", inner), "╯"}, context.temp_allocator)))
	return strings.join(out[:], "\n", context.temp_allocator)
}

// ── Formatting helpers ───────────────────────────────────────────────────────

// 1234567 -> "1,234,567"
fmt_int :: proc(n: int) -> string {
	s := fmt.tprintf("%d", abs(n))
	if len(s) <= 3 do return fmt.tprintf("%s%s", "-" if n < 0 else "", s)
	b := strings.builder_make(context.temp_allocator)
	if n < 0 do strings.write_byte(&b, '-')
	for i in 0 ..< len(s) {
		if i > 0 && (len(s) - i) % 3 == 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

// Greedy word wrap to w display columns.
wrap_text :: proc(s: string, w: int) -> string {
	words := strings.fields(s, context.temp_allocator)
	lines := make([dynamic]string, context.temp_allocator)
	cur := strings.builder_make(context.temp_allocator)
	cur_w := 0
	for word in words {
		ww := text_width(word)
		if cur_w > 0 && cur_w + 1 + ww > w {
			append(&lines, strings.clone(strings.to_string(cur), context.temp_allocator))
			strings.builder_reset(&cur)
			cur_w = 0
		}
		if cur_w > 0 {
			strings.write_byte(&cur, ' ')
			cur_w += 1
		}
		strings.write_string(&cur, word)
		cur_w += ww
	}
	if cur_w > 0 do append(&lines, strings.clone(strings.to_string(cur), context.temp_allocator))
	return strings.join(lines[:], "\n", context.temp_allocator)
}

indent_block :: proc(block: string, n: int) -> string {
	pad := spaces(n)
	lines := strings.split(block, "\n", context.temp_allocator)
	for &l in lines { l = strings.concatenate({pad, l}, context.temp_allocator) }
	return strings.join(lines, "\n", context.temp_allocator)
}
