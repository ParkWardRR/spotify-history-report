package spotify_report

import "core:fmt"
import "core:strings"

ESC :: "\x1b"

fg :: proc(c: Nord) -> string {
	return fmt.aprintf("%s[38;2;%d;%d;%dm", ESC, c.r, c.g, c.b)
}

bg :: proc(c: Nord) -> string {
	return fmt.aprintf("%s[48;2;%d;%d;%dm", ESC, c.r, c.g, c.b)
}

RESET :: "\x1b[0m"
BOLD  :: "\x1b[1m"
DIM   :: "\x1b[2m"

clear_screen :: proc() {
	fmt.printf("%s[2J%s[H", ESC, ESC)
}

hide_cursor :: proc() {
	fmt.printf("%s[?25l", ESC)
}

show_cursor :: proc() {
	fmt.printf("%s[?25h", ESC)
}

draw_header :: proc() {
	f8 := fg(NORD8)
	f4 := fg(NORD4)
	f3 := fg(NORD3)
	defer { delete(f8); delete(f4); delete(f3) }

	fmt.println()
	fmt.printf("  %s%s▗▄▄▄▖%s\n", BOLD, f8, RESET)
	fmt.printf("  %s%s▐   ▌%s  %s%sspotify-history-report%s\n", BOLD, f8, RESET, BOLD, f4, RESET)
	fmt.printf("  %s%s▝▀▀▀▘%s  %s%sGenerate listening infographics from GDPR data%s\n", BOLD, f8, RESET, DIM, f3, RESET)
	fmt.println()
}

draw_separator :: proc() {
	f2 := fg(NORD3)
	defer delete(f2)
	line := strings.repeat("─", 68)
	defer delete(line)
	fmt.printf("  %s%s%s\n", f2, line, RESET)
}

draw_stat_card :: proc(label: string, value: string, color: Nord) {
	fc := fg(color)
	f3 := fg(NORD3)
	defer { delete(fc); delete(f3) }
	fmt.printf("  %s%s│%s %s%-24s%s %s%s%s%s\n", DIM, f3, RESET, DIM, label, RESET, BOLD, fc, value, RESET)
}

draw_progress_bar :: proc(label: string, current, total: int) {
	f8 := fg(NORD8)
	f4 := fg(NORD4)
	defer { delete(f8); delete(f4) }

	width := 40
	pct := f64(current) / f64(max(total, 1))
	filled := int(pct * f64(width))

	bar := strings.builder_make()
	defer strings.builder_destroy(&bar)
	for i in 0..<width {
		if i < filled {
			strings.write_string(&bar, "█")
		} else {
			strings.write_string(&bar, "░")
		}
	}

	fmt.printf("\r  %s%s%s %s%s%s %3d%%  ",
		DIM, label, RESET,
		f8, strings.to_string(bar), RESET,
		int(pct * 100))
}

draw_section_header :: proc(title: string) {
	f9 := fg(NORD9)
	defer delete(f9)
	fmt.printf("\n  %s%s%s ─%s\n", BOLD, f9, title, RESET)
}

draw_list_item :: proc(rank: int, primary: string, secondary: string, meta: string, color: Nord) {
	fc := fg(color)
	f3 := fg(NORD3)
	defer { delete(fc); delete(f3) }
	fmt.printf("  %s%s%2d.%s %s%s%s%s  %s%s%s\n",
		DIM, f3, rank, RESET,
		BOLD, fc, primary, RESET,
		DIM, meta, RESET)
	if len(secondary) > 0 {
		fmt.printf("      %s%s%s\n", DIM, secondary, RESET)
	}
}

draw_mini_bar :: proc(label: string, value: f64, max_value: f64, color: Nord) {
	fc := fg(color)
	f4 := fg(NORD4)
	defer { delete(fc); delete(f4) }

	width := 30
	filled := int((value / max(max_value, 0.01)) * f64(width))
	filled = min(filled, width)

	bar := strings.builder_make()
	defer strings.builder_destroy(&bar)
	for _ in 0..<filled {
		strings.write_string(&bar, "▓")
	}
	for _ in 0..<(width - filled) {
		strings.write_string(&bar, " ")
	}

	fmt.printf("  %s%-14s%s %s%s%s %.1f h\n",
		f4, label, RESET,
		fc, strings.to_string(bar), RESET,
		value)
}

draw_done :: proc(path: string) {
	f14 := fg(NORD14)
	f4 := fg(NORD4)
	defer { delete(f14); delete(f4) }
	fmt.printf("\n  %s%s✓%s %sReport written to:%s\n", BOLD, f14, RESET, f4, RESET)
	fmt.printf("    %s%s%s\n\n", DIM, path, RESET)
}
