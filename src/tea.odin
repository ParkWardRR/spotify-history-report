package spotify_report

// A port of the core of charmbracelet/bubbletea to Odin: the Elm architecture
// (Model / Update / View), a message queue that background threads can Send
// into, timer commands (Tick), and a line-diffing renderer.
//
// A "model" is any struct; the program talks to it through two procs:
//
//   update :: proc(model: rawptr, msg: Msg) -> Cmd
//   view   :: proc(model: rawptr, width, height: int) -> string
//
// Msg is a closed union (Odin has no interfaces); app messages are added to it
// in pipeline.odin.

import "core:strings"
import "core:sync"
import "core:time"

Msg :: union {
	Key_Msg,
	Mouse_Msg,
	Paste_Msg,
	Window_Size_Msg,
	Tick_Msg,
	Stage_Msg,
	Done_Msg,
}

Window_Size_Msg :: struct {
	width, height: int,
}

Tick_Msg :: struct {
	tag: int,
}

// What update asks the runtime to do next. Bubble Tea's Cmd is a func that
// returns a Msg; ours is a small description of the two things we need.
Cmd :: struct {
	quit:     bool,
	tick_ms:  int, // >0: deliver Tick_Msg{tick_tag} after this many ms
	tick_tag: int,
}

cmd_quit :: proc() -> Cmd { return Cmd{quit = true} }
cmd_tick :: proc(ms, tag: int) -> Cmd { return Cmd{tick_ms = ms, tick_tag = tag} }

Timer :: struct {
	due: time.Tick,
	tag: int,
}

Program :: struct {
	model:  rawptr,
	update: proc(model: rawptr, msg: Msg) -> Cmd,
	view:   proc(model: rawptr, width, height: int) -> string,

	width, height: int,
	quit:          bool,

	// External messages (from worker threads) — guarded by mu.
	mu:    sync.Mutex,
	queue: [dynamic]Msg,

	timers: [dynamic]Timer,
	input:  [dynamic]u8,

	// Renderer state: the lines currently on screen.
	prev: [dynamic]string,
}

// Global handle so worker threads can reach the running program (p.Send).
the_program: ^Program

// Thread-safe.
program_send :: proc(p: ^Program, msg: Msg) {
	if p == nil do return
	sync.mutex_lock(&p.mu)
	append(&p.queue, msg)
	sync.mutex_unlock(&p.mu)
}

program_run :: proc(p: ^Program) -> bool {
	if !term_enter() do return false
	defer term_leave()

	p.width, p.height = term_size()
	dispatch(p, Window_Size_Msg{p.width, p.height})
	flush_frame(p)

	for !p.quit {
		// How long may we sleep? Until the next timer, capped for responsiveness
		// to worker-thread messages and resizes.
		timeout := 16
		now := time.tick_now()
		for t in p.timers {
			d := int(time.duration_milliseconds(time.tick_diff(now, t.due)))
			timeout = clamp(min(timeout, d), 0, 16)
		}

		if stdin_ready(timeout) {
			stdin_read(&p.input)
			drain_input(p, false)
		} else if len(p.input) > 0 {
			drain_input(p, true) // lone ESC => Esc key
		}

		// Worker messages.
		sync.mutex_lock(&p.mu)
		pending := p.queue
		p.queue = make([dynamic]Msg)
		sync.mutex_unlock(&p.mu)
		for m in pending { dispatch(p, m) }
		delete(pending)

		// Timers.
		now = time.tick_now()
		i := 0
		for i < len(p.timers) {
			if time.tick_diff(p.timers[i].due, now) >= 0 {
				tag := p.timers[i].tag
				ordered_remove(&p.timers, i)
				dispatch(p, Tick_Msg{tag})
			} else {
				i += 1
			}
		}

		// Resize (poll instead of SIGWINCH; ioctl is cheap).
		if w, h := term_size(); w != p.width || h != p.height {
			p.width, p.height = w, h
			clear(&p.prev)
			write_out("\x1b[2J")
			dispatch(p, Window_Size_Msg{w, h})
		}

		flush_frame(p)
		free_all(context.temp_allocator)
	}
	return true
}

drain_input :: proc(p: ^Program, flush: bool) {
	for len(p.input) > 0 && !p.quit {
		msg, n, status := parse_input(p.input[:], flush)
		switch status {
		case .Need_More:
			return
		case .Skip:
			remove_range(&p.input, 0, n)
		case .Ok:
			remove_range(&p.input, 0, n)
			dispatch(p, msg)
		}
	}
}

dispatch :: proc(p: ^Program, msg: Msg) {
	// Ctrl+C always quits, like Bubble Tea's default.
	if k, ok := msg.(Key_Msg); ok && k.ctrl && k.r == 'c' {
		p.quit = true
		return
	}
	cmd := p.update(p.model, msg)
	if cmd.quit do p.quit = true
	if cmd.tick_ms > 0 {
		append(&p.timers, Timer{
			due = time.tick_add(time.tick_now(), time.Duration(cmd.tick_ms) * time.Millisecond),
			tag = cmd.tick_tag,
		})
	}
}

// ── Renderer ─────────────────────────────────────────────────────────────────
// Like Bubble Tea's standard renderer: split the view into lines and only
// rewrite the lines that changed since the last frame, in one write, wrapped
// in synchronized-output markers so the terminal swaps frames atomically.

flush_frame :: proc(p: ^Program) {
	if p.width <= 0 || p.height <= 0 do return
	view := p.view(p.model, p.width, p.height)
	lines := strings.split(view, "\n", context.temp_allocator)
	if len(lines) > p.height do lines = lines[:p.height]

	sb := strings.builder_make(context.temp_allocator)
	changed := false
	for line, i in lines {
		line := line
		if text_width(line) > p.width do line = truncate(line, p.width, "")
		if i < len(p.prev) && p.prev[i] == line do continue
		if !changed {
			strings.write_string(&sb, "\x1b[?2026h")
			changed = true
		}
		write_row(&sb, i, line)
	}
	// Rows that existed before but are gone now.
	for i in len(lines) ..< len(p.prev) {
		if !changed {
			strings.write_string(&sb, "\x1b[?2026h")
			changed = true
		}
		write_row(&sb, i, "")
	}
	if !changed do return
	strings.write_string(&sb, "\x1b[?2026l")
	write_out(strings.to_string(sb))

	for l in p.prev { delete(l) }
	clear(&p.prev)
	for l in lines {
		line := l
		if text_width(line) > p.width do line = truncate(line, p.width, "")
		append(&p.prev, strings.clone(line))
	}
}

write_row :: proc(sb: ^strings.Builder, row: int, line: string) {
	strings.write_string(sb, "\x1b[")
	strings.write_int(sb, row + 1)
	strings.write_string(sb, ";1H")
	strings.write_string(sb, line)
	strings.write_string(sb, RESET)
	strings.write_string(sb, "\x1b[K")
}
