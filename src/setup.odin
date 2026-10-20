package spotify_report

// `--setup`: a small Bubble Tea program — provider picker followed by masked
// key entry and an optional model override.

import "core:fmt"
import "core:strings"

Setup_Step :: enum {
	Provider,
	Key,
	Model,
	Done,
}

Provider_Option :: struct {
	id, name, blurb, url: string,
}

PROVIDER_OPTIONS := [?]Provider_Option{
	{"anthropic",  "Anthropic",  "Claude — recommended",              "console.anthropic.com/settings/keys"},
	{"openai",     "OpenAI",     "GPT-4o-mini — cheap and fast",      "platform.openai.com/api-keys"},
	{"openrouter", "OpenRouter", "any model — one key, many vendors", "openrouter.ai/keys"},
}

Setup :: struct {
	w, h:     int,
	step:     Setup_Step,
	sel:      int,
	key:      Text_Input,
	model:    Text_Input,
	cfg:      Config,
	err:      string,
	saved:    bool,
	frame:    int,
}

setup_existing_key :: proc(s: ^Setup) -> string {
	switch PROVIDER_OPTIONS[s.sel].id {
	case "anthropic":  return s.cfg.anthropic_key
	case "openai":     return s.cfg.openai_key
	case "openrouter": return s.cfg.openrouter_key
	}
	return ""
}

setup_update :: proc(m: rawptr, msg: Msg) -> (cmd: Cmd) {
	s := (^Setup)(m)

	#partial switch v in msg {
	case Window_Size_Msg:
		s.w, s.h = v.width, v.height
		return
	case Key_Msg:
		if s.step == .Done {
			return cmd_quit()
		}
		s.err = ""
		switch s.step {
		case .Provider:
			#partial switch v.key {
			case .Esc: return cmd_quit()
			case .Up:   s.sel = (s.sel + len(PROVIDER_OPTIONS) - 1) % len(PROVIDER_OPTIONS)
			case .Down: s.sel = (s.sel + 1) % len(PROVIDER_OPTIONS)
			case .Enter:
				s.step = .Key
				s.key.focused = true
			case .Rune:
				switch v.r {
				case 'k': s.sel = (s.sel + len(PROVIDER_OPTIONS) - 1) % len(PROVIDER_OPTIONS)
				case 'j': s.sel = (s.sel + 1) % len(PROVIDER_OPTIONS)
				case 'q': return cmd_quit()
				case '1'..='3':
					s.sel = int(v.r - '1')
					s.step = .Key
					s.key.focused = true
				}
			}
		case .Key:
			#partial switch v.key {
			case .Esc:
				s.step = .Provider
				s.key.focused = false
			case .Enter:
				if len(text_input_string(&s.key)) < 5 && len(setup_existing_key(s)) == 0 {
					s.err = "That key looks too short."
				} else {
					s.step = .Model
					s.key.focused = false
					s.model.focused = true
				}
			case:
				text_input_update(&s.key, msg)
			}
		case .Model:
			#partial switch v.key {
			case .Esc:
				s.step = .Key
				s.model.focused = false
				s.key.focused = true
			case .Enter:
				s.model.focused = false
				setup_save(s)
				if s.err == "" do s.step = .Done
			case:
				text_input_update(&s.model, msg)
			}
		case .Done:
		}
	case Paste_Msg:
		if s.step == .Key do text_input_update(&s.key, msg)
		if s.step == .Model do text_input_update(&s.model, msg)
	}
	return
}

setup_save :: proc(s: ^Setup) {
	opt := PROVIDER_OPTIONS[s.sel]
	s.cfg.provider = opt.id
	s.cfg.enrich = true // finishing setup after the disclosure below is the opt-in
	if k := text_input_string(&s.key); len(k) > 0 {
		k = strings.trim_space(k)
		switch opt.id {
		case "anthropic":  s.cfg.anthropic_key = strings.clone(k)
		case "openai":     s.cfg.openai_key = strings.clone(k)
		case "openrouter": s.cfg.openrouter_key = strings.clone(k)
		}
	}
	if m := strings.trim_space(text_input_string(&s.model)); len(m) > 0 {
		s.cfg.model = strings.clone(m)
	}
	if save_config(s.cfg) {
		s.saved = true
	} else {
		s.err = "Failed to write the config file."
	}
}

masked_key :: proc(k: string) -> string {
	if len(k) <= 8 do return "••••••••"
	return fmt.tprintf("%s••••%s", k[:3], k[len(k) - 4:])
}

setup_view :: proc(m: rawptr, w, h: int) -> string {
	s := (^Setup)(m)
	pw := clamp(w - 4, 40, 74)
	rows := make([dynamic]string, context.temp_allocator)
	opt := PROVIDER_OPTIONS[s.sel]

	// Provider
	if s.step == .Provider {
		append(&rows, fgs(COL_BRIGHT, "Choose a provider", true), "")
		for o, i in PROVIDER_OPTIONS {
			cursor := fgs(COL_ACCENT, "❯", true) if i == s.sel else " "
			name := fgs(COL_ACCENT if i == s.sel else COL_TEXT, pad_right(o.name, 11), i == s.sel)
			append(&rows, strings.concatenate({cursor, " ", faint(fmt.tprintf("%d", i + 1)), " ", name, muted(o.blurb)}, context.temp_allocator))
		}
	} else {
		append(&rows, strings.concatenate({fgs(COL_OK, "✓", true), " ", muted(pad_right("Provider", 9)), fgs(COL_BRIGHT, opt.name)}, context.temp_allocator))
	}
	append(&rows, "")

	// Key
	s.key.mask = true
	s.key.width = max(10, pw - 18)
	s.key.placeholder = "paste your API key"
	if existing := setup_existing_key(s); len(existing) > 0 && s.step == .Key {
		s.key.placeholder = fmt.tprintf("Enter to keep %s", masked_key(existing))
	}
	switch s.step {
	case .Provider:
		append(&rows, strings.concatenate({faint("○"), " ", faint(pad_right("API key", 9))}, context.temp_allocator))
	case .Key:
		append(&rows, strings.concatenate({fgs(COL_ACCENT, "❯", true), " ", fgs(COL_BRIGHT, pad_right("API key", 9), true), text_input_view(&s.key)}, context.temp_allocator))
		append(&rows, strings.concatenate({"  ", spaces(9), faint("get one at "), fgs(COL_ACCENT2, opt.url)}, context.temp_allocator))
	case .Model, .Done:
		shown := masked_key(text_input_string(&s.key)) if len(text_input_string(&s.key)) > 0 else "kept existing"
		append(&rows, strings.concatenate({fgs(COL_OK, "✓", true), " ", muted(pad_right("API key", 9)), fgs(COL_TEXT, shown)}, context.temp_allocator))
	}
	append(&rows, "")

	// Model
	s.model.width = max(10, pw - 18)
	s.model.placeholder = "default model for provider"
	switch s.step {
	case .Provider, .Key:
		append(&rows, strings.concatenate({faint("○"), " ", faint(pad_right("Model", 9))}, context.temp_allocator))
	case .Model:
		append(&rows, strings.concatenate({fgs(COL_ACCENT, "❯", true), " ", fgs(COL_BRIGHT, pad_right("Model", 9), true), text_input_view(&s.model)}, context.temp_allocator))
		append(&rows, strings.concatenate({"  ", spaces(9), faint("optional — press Enter for the default")}, context.temp_allocator))
	case .Done:
		mv := text_input_string(&s.model)
		append(&rows, strings.concatenate({fgs(COL_OK, "✓", true), " ", muted(pad_right("Model", 9)), fgs(COL_TEXT, mv if len(mv) > 0 else "default")}, context.temp_allocator))
	}

	if len(s.err) > 0 {
		append(&rows, "", fgs(COL_ERR, strings.concatenate({"✗ ", s.err}, context.temp_allocator), true))
	}
	if s.step == .Done {
		append(&rows, "", fgs(COL_OK, "Saved.", true), muted(truncate(config_path(), pw - 6)))
	}

	help: string
	switch s.step {
	case .Provider: help = help_view([]Help_Item{{"↑↓", "select"}, {"enter", "confirm"}, {"q", "cancel"}})
	case .Key:      help = help_view([]Help_Item{{"enter", "next"}, {"esc", "back"}, {"ctrl+u", "clear"}})
	case .Model:    help = help_view([]Help_Item{{"enter", "save"}, {"esc", "back"}})
	case .Done:     help = help_view([]Help_Item{{"any key", "exit"}})
	}

	card := panel("API key setup", join_v(rows[:]), pw)
	intro := muted(wrap_text("Genre enrichment is optional. Saving a key turns it on: your artist names (nothing else) are sent to the provider you pick. Reports work without it, and --enrich is how you switch it on per run otherwise. The key is saved locally to ~/.config/spotify-history-report/config.json.", pw))
	block := center_block(join_v({logo_block(), "", intro, "", card, "", help}), w)
	top := max(0, (h - block_height(block)) / 4)
	return strings.concatenate({repeat_str("\n", top), block}, context.temp_allocator)
}

run_setup :: proc() -> bool {
	if !is_tty(STDIN_FD) || !is_tty(STDOUT_FD) {
		fmt.eprintln("--setup needs an interactive terminal.")
		return false
	}
	s := Setup{cfg = load_config()}
	// Preselect the configured provider.
	for o, i in PROVIDER_OPTIONS {
		if o.id == s.cfg.provider do s.sel = i
	}
	text_input_set(&s.model, s.cfg.model)

	p := Program{model = &s, update = setup_update, view = setup_view}
	if !program_run(&p) do return false

	if s.saved {
		fmt.println(strings.concatenate({"  ", fgs(COL_OK, "✓", true), " Config saved to ", fgs(COL_ACCENT, config_path())}, context.temp_allocator))
		fmt.println(strings.concatenate({"  ", muted("Now run: "), fgs(COL_TEXT, "spotify-history-report <data-dir>")}, context.temp_allocator))
	}
	return true
}
