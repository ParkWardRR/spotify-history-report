package spotify_report

import "core:fmt"
import "core:os"
import "core:strings"
import "core:thread"

main :: proc() {
	detect_color_profile()

	args := os.args
	force_plain := false

	for a in args[1:] {
		switch a {
		case "--help", "-h":
			print_usage()
			return
		case "--setup":
			if !run_setup() do os.exit(1)
			return
		case "--guide":
			print_spotify_guide()
			return
		case "--plain":
			force_plain = true
		}
	}

	if len(args) < 2 {
		print_usage()
		return
	}

	opts := Run_Opts{data_dir = args[1], output_path = "spotify_report.html"}

	// Parse flags
	cli_provider := ""
	cli_key := ""
	cli_model := ""

	i := 2
	for i < len(args) {
		a := args[i]
		switch {
		case a == "--output" || a == "-o":
			if i + 1 < len(args) { i += 1; opts.output_path = args[i] }
		case a == "--openai-key":
			if i + 1 < len(args) { i += 1; cli_key = args[i]; cli_provider = "openai" }
		case a == "--anthropic-key":
			if i + 1 < len(args) { i += 1; cli_key = args[i]; cli_provider = "anthropic" }
		case a == "--openrouter-key":
			if i + 1 < len(args) { i += 1; cli_key = args[i]; cli_provider = "openrouter" }
		case a == "--model":
			if i + 1 < len(args) { i += 1; cli_model = args[i] }
		case !strings.has_prefix(a, "-"):
			opts.output_path = a
		}
		i += 1
	}

	// Load config
	cfg := load_config()
	if len(cli_key) > 0 {
		switch cli_provider {
		case "openai":     cfg.openai_key = cli_key;     cfg.provider = "openai"
		case "anthropic":  cfg.anthropic_key = cli_key;  cfg.provider = "anthropic"
		case "openrouter": cfg.openrouter_key = cli_key; cfg.provider = "openrouter"
		}
	}
	if len(cli_model) > 0 {
		cfg.model = cli_model
	}
	opts.provider, opts.api_key, opts.model = resolve_provider(cfg)

	interactive := is_tty(STDIN_FD) && is_tty(STDOUT_FD) && !force_plain
	if interactive && run_tui(opts) do return

	run_plain(opts)
}

// Full-screen Bubble Tea mode. Returns false if the terminal can't be put in
// raw mode, so the caller can fall back to plain output.
run_tui :: proc(opts: Run_Opts) -> bool {
	app: App
	app_init(&app, opts)

	prog := Program{model = &app, update = app_update, view = app_view}
	the_program = &prog
	emit = proc(m: Msg) { program_send(the_program, m) }

	if !term_enter() do return false
	term_leave() // program_run enters on its own; this was only a capability probe

	run_opts := new(Run_Opts)
	run_opts^ = opts
	thread.create_and_start_with_data(run_opts, pipeline_thread_proc)

	program_send(&prog, Tick_Msg{TICK_FRAME})
	if !program_run(&prog) do return false

	// Leave a compact record on the normal screen, like `tea.Println` on exit.
	switch app.phase {
	case .Dashboard:
		fmt.println()
		fmt.println(summary_text(app.stats, opts.output_path, app.elapsed_ms))
		fmt.println()
	case .Failed:
		fmt.println()
		fmt.printf("  %s %s\n", fgs(COL_ERR, "✗", true), fgs(COL_ERR, app.err_title, true))
		tw, _ := term_size()
		fmt.println(indent_block(muted(wrap_text(app.err_hint, min(tw - 6, 90))), 4))
		fmt.println()
	case .Running:
	}
	return true
}

run_plain :: proc(opts: Run_Opts) {
	emit = plain_emit
	fmt.println()
	fmt.printf("  %s %s\n\n", fgs(COL_ACCENT, "▗▄▖", true), fgs(COL_BRIGHT, "spotify-history-report", true))
	run_pipeline(opts)
	fmt.println()
	if plain_failed do os.exit(1)
}
