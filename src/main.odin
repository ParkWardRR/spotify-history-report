package spotify_report

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:thread"

main :: proc() {
	detect_color_profile()

	args := os.args
	force_plain := false
	identities_only := false
	scores_only := false
	annotations_only := false
	enrich_flag := false

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
		case "--identities":
			identities_only = true
		case "--scores":
			scores_only = true
		case "--annotations":
			annotations_only = true
		case "--enrich":
			enrich_flag = true
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
	cli_timezone := ""
	cli_decay := 0.0
	decay_bad := false

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
		case a == "--decay":
			if i + 1 < len(args) {
				i += 1
				d, ok := strconv.parse_f64(args[i])
				if ok && d >= MIN_DECAY && d <= MAX_DECAY { cli_decay = d } else { decay_bad = true }
			}
		case a == "--timezone" || a == "--tz":
			if i + 1 < len(args) { i += 1; cli_timezone = args[i] }
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
	opts.timezone = resolve_timezone(cli_timezone, cfg)
	opts.decay = cli_decay
	opts.enrich = enrich_flag || cfg.enrich
	if decay_bad {
		fmt.eprintfln("--decay needs a number between %.2f and %.1f", MIN_DECAY, MAX_DECAY)
		os.exit(2)
	}

	if annotations_only {
		if !run_annotations(opts) do os.exit(1)
		return
	}
	if scores_only {
		if !run_scores(opts) do os.exit(1)
		return
	}
	if identities_only {
		if !run_identities(opts) do os.exit(1)
		return
	}

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

// `--identities`: no LLM, no report; just resolve identities and print them.
run_identities :: proc(opts: Run_Opts) -> bool {
	files := find_json_files(opts.data_dir)
	if len(files) == 0 {
		fmt.eprintfln("No Streaming_History_Audio_*.json found in %s", opts.data_dir)
		return false
	}
	clock := make_clock(opts.timezone)
	loaded, ok := load_plays(files[:], &clock, false)
	if !ok {
		fmt.eprintfln("Failed to parse %s", loaded.failed_path)
		return false
	}
	ov, ov_err := load_overrides(opts.data_dir)
	if len(ov_err) > 0 {
		fmt.eprintfln("%s", ov_err)
		return false
	}
	table, err := resolve_identities(loaded.plays[:], ov, &loaded.tally)
	if len(err) > 0 {
		fmt.eprintfln("overrides.json: %s", err)
		return false
	}
	if !save_identities(opts.data_dir, table) {
		fmt.eprintfln("note: could not write %s/%s", SHR_DIR_NAME, IDENTITIES_FILE)
	}
	fmt.print(identity_report_text(table))
	return true
}

// `--annotations`: genre coverage and the biggest gaps. No LLM; it imports a
// legacy .genre_cache.json the first time so the numbers match a normal run.
run_annotations :: proc(opts: Run_Opts) -> bool {
	files := find_json_files(opts.data_dir)
	if len(files) == 0 {
		fmt.eprintfln("No Streaming_History_Audio_*.json found in %s", opts.data_dir)
		return false
	}
	clock := make_clock(opts.timezone)
	loaded, ok := load_plays(files[:], &clock, false)
	if !ok {
		fmt.eprintfln("Failed to parse %s", loaded.failed_path)
		return false
	}
	ov, ov_err := load_overrides(opts.data_dir)
	if len(ov_err) > 0 {
		fmt.eprintfln("%s", ov_err)
		return false
	}
	if _, err := resolve_identities(loaded.plays[:], ov, &loaded.tally); len(err) > 0 {
		fmt.eprintfln("overrides.json: %s", err)
		return false
	}
	store, info, err := load_annotations(opts.data_dir)
	if len(err) > 0 {
		fmt.eprintfln("%s", err)
		return false
	}
	if info.migrated && !save_annotations(opts.data_dir, store) {
		fmt.eprintfln("note: could not write %s/%s", SHR_DIR_NAME, ANNOTATIONS_FILE)
	}
	resolver := build_genre_resolver(store, ov.annotations[:])
	fmt.print(annotations_report_text(store, info, &resolver, loaded.plays[:], len(ov.annotations)))
	return true
}

// `--scores`: print the behaviour views and test the memory model against
// simple baselines on this listener's own history.
run_scores :: proc(opts: Run_Opts) -> bool {
	files := find_json_files(opts.data_dir)
	if len(files) == 0 {
		fmt.eprintfln("No Streaming_History_Audio_*.json found in %s", opts.data_dir)
		return false
	}
	clock := make_clock(opts.timezone)
	loaded, ok := load_plays(files[:], &clock, false)
	if !ok {
		fmt.eprintfln("Failed to parse %s", loaded.failed_path)
		return false
	}
	// Overrides apply here too, so the scores match the report.
	ov, ov_err := load_overrides(opts.data_dir)
	if len(ov_err) > 0 {
		fmt.eprintfln("%s", ov_err)
		return false
	}
	if _, err := resolve_identities(loaded.plays[:], ov, &loaded.tally); len(err) > 0 {
		fmt.eprintfln("overrides.json: %s", err)
		return false
	}
	fmt.print(scores_report_text(compute_scores(loaded.plays[:], opts.decay if opts.decay > 0 else DEFAULT_DECAY), evaluate_rankers(loaded.plays[:])))
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
