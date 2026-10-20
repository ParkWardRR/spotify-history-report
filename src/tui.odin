package spotify_report

// Static (non-interactive) screens: --help and --guide. Same styling system as
// the live TUI, printed once.

import "core:fmt"
import "core:strings"

heading :: proc(title: string) -> string {
	return fmt.tprintf("  %s", fgs(COL_ACCENT2, title, true))
}

// "  -o, --output <file>   Output HTML path (default: …)"
opt_line :: proc(flag, desc: string, note := "") -> string {
	line := fmt.tprintf("    %s %s", fgs(COL_TEXT, pad_right(flag, 24)), desc)
	if len(note) > 0 do line = fmt.tprintf("%s %s", line, muted(note))
	return line
}

print_block :: proc(lines: ..string) {
	fmt.println(strings.join(lines, "\n", context.temp_allocator))
	free_all(context.temp_allocator)
}

print_usage :: proc() {
	print_block(
		"",
		indent_block(logo_block(), 2),
		"",
		fmt.tprintf("  %s  spotify-history-report %s [options]", fgs(COL_BRIGHT, "Usage", true), fgs(COL_ACCENT, "<export>")),
		"",
		heading("Arguments"),
		opt_line("<export>", "Your Spotify ZIP, the extracted folder, or the .json files", "(several allowed)"),
		"",
		heading("Options"),
		opt_line("-o, --output <file>", "Output HTML path", "(default: spotify_report.html)"),
		opt_line("--enrich", "Send artist names to your LLM provider to fill in genres", "(off by default)"),
		opt_line("--openai-key <key>", "OpenAI API key for genre classification"),
		opt_line("--anthropic-key <key>", "Anthropic API key", "(Claude)"),
		opt_line("--openrouter-key <key>", "OpenRouter API key", "(any model)"),
		opt_line("--model <model>", "Override the LLM model"),
		opt_line("--timezone <name>", "IANA zone for local time (default: $TZ, else America/Los_Angeles)"),
		opt_line("--decay <d>", "Memory decay for the behaviour scores (default 0.5; try --scores first)"),
		opt_line("--scores", "Print favourites/obsessions/rediscoveries and test the model on your replays"),
		opt_line("--annotations", "Print genre coverage and the biggest unclassified artists, then exit"),
		opt_line("--identities", "Print the track-identity report (coverage, duplicates) and exit"),
		opt_line("--noindex", "Add robots noindex/nofollow meta tags to the report"),
		opt_line("--plain", "No TUI; print progress as plain lines"),
		opt_line("--setup", "Interactive config setup", "(saves to ~/.config)"),
		opt_line("--guide", "How to get your Spotify data export"),
		"",
		heading("Environment"),
		opt_line("ANTHROPIC_API_KEY", "Anthropic key", "(overrides config)"),
		opt_line("OPENAI_API_KEY", "OpenAI key", "(overrides config)"),
		opt_line("OPENROUTER_API_KEY", "OpenRouter key", "(overrides config)"),
		opt_line("SHR_COLOR", "truecolor | 256 | ansi | none", "(default: auto)"),
		"",
		heading("Examples"),
		fmt.tprintf("    %s spotify-history-report ~/Downloads/my_spotify_data.zip", muted("$")),
		fmt.tprintf("    %s spotify-history-report ./data --enrich --anthropic-key sk-ant-... -o report.html", muted("$")),
		fmt.tprintf("    %s OPENAI_API_KEY=sk-... spotify-history-report ./data --enrich", muted("$")),
		"",
	)
}

step_line :: proc(n: int, title: string) -> string {
	return fmt.tprintf("  %s %s", fgs(COL_ACCENT, fmt.tprintf("%d.", n), true), fgs(COL_BRIGHT, title, true))
}

print_spotify_guide :: proc() {
	code :: proc(k, v: string, last := false) -> string {
		return fmt.tprintf("    %s%s %s%s", fgs(COL_ACCENT, k), muted(":"), v, "" if last else muted(","))
	}
	print_block(
		"",
		indent_block(logo_block(), 2),
		"",
		heading("How to get your Spotify data"),
		"",
		step_line(1, "Open the privacy page"),
		fmt.tprintf("     %s", fgs(COL_ACCENT2, "https://www.spotify.com/account/privacy/")),
		fmt.tprintf("     %s", muted("Log in, then scroll to “Download your data”.")),
		"",
		step_line(2, "Request your “Extended streaming history”"),
		fmt.tprintf("     %s", muted("Not the basic “Account data” — you need the Extended version.")),
		fmt.tprintf("     %s", muted("It includes every stream with timestamps and durations.")),
		"",
		step_line(3, "Wait for the email"),
		fmt.tprintf("     %s %s", muted("Spotify prepares the export and emails a link"), fgs(COL_WARN, "(usually 5–30 days)")),
		"",
		step_line(4, "Download the ZIP"),
		fmt.tprintf("     %s %s", muted("It holds files like"), fgs(COL_TEXT, "Streaming_History_Audio_2019-2024.json")),
		fmt.tprintf("     %s", muted("No need to unzip it. The tool reads the ZIP in memory.")),
		"",
		step_line(5, "Point this tool at the ZIP (or the folder)"),
		fmt.tprintf("     %s spotify-history-report ~/Downloads/my_spotify_data.zip", muted("$")),
		"",
		faint(strings.concatenate({"  ", repeat_str("─", 64)}, context.temp_allocator)),
		"",
		heading("What's in the data?"),
		"",
		"  Each JSON file is an array of streaming records:",
		"",
		fmt.tprintf("    %s", muted("{")),
		code("\"ts\"", fgs(COL_OK, "\"2024-03-15T18:32:01Z\"")),
		code("\"ms_played\"", fgs(COL_WARN, "234567")),
		code("\"master_metadata_track_name\"", fgs(COL_OK, "\"Song Title\"")),
		code("\"master_metadata_album_artist_name\"", fgs(COL_OK, "\"Artist\"")),
		code("\"master_metadata_album_album_name\"", fgs(COL_OK, "\"Album\"")),
		code("\"platform\"", fgs(COL_OK, "\"OS X 15.2.0\"")),
		code("\"skipped\"", fgs(NORD15, "false"), true),
		fmt.tprintf("    %s", muted("}")),
		"",
		fmt.tprintf("  A play is “qualifying” if %s (30 s)", fgs(COL_TEXT, "ms_played >= 30,000")),
		"  and both track name and artist name are present.",
		"",
	)
}
