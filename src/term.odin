package spotify_report

// Terminal layer: raw mode, size, and input decoding.
// Ported from the ideas in charmbracelet/bubbletea (tty.go, key.go, mouse.go).

import "core:c"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:unicode/utf8"

when ODIN_OS == .Darwin {
	TIOCGWINSZ :: 0x40087468
} else {
	TIOCGWINSZ :: 0x5413
}

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
}

Winsize :: struct {
	row, col, xpixel, ypixel: c.ushort,
}

STDIN_FD  :: posix.FD(0)
STDOUT_FD :: posix.FD(1)

is_tty :: proc(fd: posix.FD) -> bool {
	return bool(posix.isatty(fd))
}

term_size :: proc() -> (w, h: int) {
	ws: Winsize
	if ioctl(1, TIOCGWINSZ, &ws) == 0 && ws.col > 0 && ws.row > 0 {
		return int(ws.col), int(ws.row)
	}
	w, h = 80, 24
	if v := os.get_env_alloc("COLUMNS", context.temp_allocator); len(v) > 0 {
		if n := parse_int(v); n > 0 do w = n
	}
	if v := os.get_env_alloc("LINES", context.temp_allocator); len(v) > 0 {
		if n := parse_int(v); n > 0 do h = n
	}
	return
}

// ── Raw mode & screen modes ──────────────────────────────────────────────────

Terminal :: struct {
	saved:  posix.termios,
	active: bool,
}

term: Terminal

write_out :: proc(s: string) {
	if len(s) == 0 do return
	data := transmute([]u8)s
	for len(data) > 0 {
		n, err := os.write(os.stdout, data)
		if err != nil || n <= 0 do return
		data = data[n:]
	}
}

// Enter the full-screen TUI: raw mode, alt screen, hidden cursor,
// wheel mouse (SGR), bracketed paste.
term_enter :: proc() -> bool {
	if term.active do return true
	if posix.tcgetattr(STDIN_FD, &term.saved) != .OK do return false

	raw := term.saved
	raw.c_iflag -= {.BRKINT, .ICRNL, .INPCK, .ISTRIP, .IXON}
	raw.c_oflag -= {.OPOST}
	raw.c_lflag -= {.ECHO, .ICANON, .IEXTEN, .ISIG}
	raw.c_cc[.VMIN] = 1
	raw.c_cc[.VTIME] = 0
	if posix.tcsetattr(STDIN_FD, .TCSAFLUSH, &raw) != .OK do return false

	term.active = true
	write_out("\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1006h\x1b[?2004h\x1b[2J\x1b[H")

	posix.signal(.SIGTERM, term_signal_handler)
	posix.signal(.SIGHUP, term_signal_handler)
	return true
}

term_leave :: proc() {
	if !term.active do return
	term.active = false
	write_out("\x1b[?2004l\x1b[?1006l\x1b[?1000l\x1b[?25h\x1b[?1049l\x1b[0m")
	posix.tcsetattr(STDIN_FD, .TCSAFLUSH, &term.saved)
}

term_signal_handler :: proc "c" (sig: posix.Signal) {
	context = {}
	term_leave()
	posix._exit(1)
}

hide_cursor :: proc() { write_out("\x1b[?25l") }
show_cursor :: proc() { write_out("\x1b[?25h") }

// ── Input ────────────────────────────────────────────────────────────────────

Key :: enum {
	Rune,
	Enter,
	Tab,
	Shift_Tab,
	Backspace,
	Delete,
	Esc,
	Up,
	Down,
	Left,
	Right,
	Home,
	End,
	Page_Up,
	Page_Down,
	Insert,
}

Key_Msg :: struct {
	key:  Key,
	r:    rune, // for .Rune
	ctrl: bool,
	alt:  bool,
}

Mouse_Msg :: struct {
	x, y:   int,
	button: int, // 0 left, 1 middle, 2 right
	wheel:  int, // -1 up, +1 down
	press:  bool,
}

Paste_Msg :: struct {
	text: string,
}

Parse_Status :: enum {
	Ok,
	Skip,
	Need_More,
}

// Is there something to read on stdin within timeout_ms?
stdin_ready :: proc(timeout_ms: int) -> bool {
	fds := [1]posix.pollfd{{fd = STDIN_FD, events = {.IN}}}
	n := posix.poll(raw_data(fds[:]), 1, c.int(timeout_ms))
	return n > 0 && .IN in fds[0].revents
}

stdin_read :: proc(buf: ^[dynamic]u8) {
	tmp: [256]u8
	n, err := os.read(os.stdin, tmp[:])
	if err != nil || n <= 0 do return
	append(buf, ..tmp[:n])
}

// Decode one message from the front of buf. `flush` means no more bytes are
// coming, so a lone ESC is the Esc key and truncated sequences are dropped.
parse_input :: proc(buf: []u8, flush: bool) -> (msg: Msg, n: int, status: Parse_Status) {
	if len(buf) == 0 do return nil, 0, .Need_More
	b := buf[0]

	if b == 0x1b {
		if len(buf) == 1 {
			if flush do return Key_Msg{key = .Esc}, 1, .Ok
			return nil, 0, .Need_More
		}
		switch buf[1] {
		case '[':
			return parse_csi(buf, flush)
		case 'O':
			if len(buf) < 3 {
				if flush do return nil, len(buf), .Skip
				return nil, 0, .Need_More
			}
			k: Key
			switch buf[2] {
			case 'A': k = .Up
			case 'B': k = .Down
			case 'C': k = .Right
			case 'D': k = .Left
			case 'H': k = .Home
			case 'F': k = .End
			case: return nil, 3, .Skip
			}
			return Key_Msg{key = k}, 3, .Ok
		case:
			// Alt+<key>
			inner, used, st := parse_input(buf[1:], flush)
			if st == .Need_More do return nil, 0, .Need_More
			if st == .Skip do return nil, 1 + used, .Skip
			if km, ok := inner.(Key_Msg); ok {
				km.alt = true
				return km, 1 + used, .Ok
			}
			return nil, 1 + used, .Skip
		}
	}

	switch b {
	case 0x0d, 0x0a: return Key_Msg{key = .Enter}, 1, .Ok
	case 0x09:       return Key_Msg{key = .Tab}, 1, .Ok
	case 0x7f, 0x08: return Key_Msg{key = .Backspace}, 1, .Ok
	case 0x00:       return nil, 1, .Skip
	case 0x01..=0x1a:
		return Key_Msg{key = .Rune, r = rune('a' + b - 1), ctrl = true}, 1, .Ok
	case 0x1c..=0x1f:
		return nil, 1, .Skip
	}

	r, size := utf8.decode_rune(buf)
	if r == utf8.RUNE_ERROR && size <= 1 {
		if !flush && len(buf) < 4 && b >= 0xC0 do return nil, 0, .Need_More
		return nil, 1, .Skip
	}
	return Key_Msg{key = .Rune, r = r}, size, .Ok
}

parse_csi :: proc(buf: []u8, flush: bool) -> (msg: Msg, n: int, status: Parse_Status) {
	// buf = ESC [ params... final
	end := -1
	for i in 2 ..< len(buf) {
		if buf[i] >= 0x40 && buf[i] <= 0x7e {
			end = i
			break
		}
		if i > 40 do return nil, i + 1, .Skip
	}
	if end < 0 {
		if flush do return nil, len(buf), .Skip
		return nil, 0, .Need_More
	}
	params := string(buf[2:end])
	final := buf[end]
	total := end + 1

	switch final {
	case 'A': return Key_Msg{key = .Up}, total, .Ok
	case 'B': return Key_Msg{key = .Down}, total, .Ok
	case 'C': return Key_Msg{key = .Right}, total, .Ok
	case 'D': return Key_Msg{key = .Left}, total, .Ok
	case 'H': return Key_Msg{key = .Home}, total, .Ok
	case 'F': return Key_Msg{key = .End}, total, .Ok
	case 'Z': return Key_Msg{key = .Shift_Tab}, total, .Ok
	case '~':
		code := parse_int(params)
		switch code {
		case 1, 7: return Key_Msg{key = .Home}, total, .Ok
		case 4, 8: return Key_Msg{key = .End}, total, .Ok
		case 2:    return Key_Msg{key = .Insert}, total, .Ok
		case 3:    return Key_Msg{key = .Delete}, total, .Ok
		case 5:    return Key_Msg{key = .Page_Up}, total, .Ok
		case 6:    return Key_Msg{key = .Page_Down}, total, .Ok
		case 200:
			// Bracketed paste: everything up to ESC[201~
			rest := buf[total:]
			marker := "\x1b[201~"
			idx := strings.index(string(rest), marker)
			if idx < 0 {
				if flush do return nil, len(buf), .Skip
				return nil, 0, .Need_More
			}
			text := strings.clone(string(rest[:idx]))
			return Paste_Msg{text = text}, total + idx + len(marker), .Ok
		}
		return nil, total, .Skip
	case 'M', 'm':
		// SGR mouse: ESC [ < b ; x ; y (M|m)
		if len(params) > 0 && params[0] == '<' {
			parts := strings.split(params[1:], ";", context.temp_allocator)
			if len(parts) == 3 {
				code := parse_int(parts[0])
				m := Mouse_Msg{x = parse_int(parts[1]) - 1, y = parse_int(parts[2]) - 1, press = final == 'M'}
				if code & 64 != 0 {
					m.wheel = -1 if code & 1 == 0 else 1
				} else {
					m.button = code & 3
				}
				return m, total, .Ok
			}
		}
		return nil, total, .Skip
	}
	return nil, total, .Skip
}
