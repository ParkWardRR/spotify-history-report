package spotify_report

import "core:os"
import "core:fmt"
import "core:strings"
import "core:encoding/json"
import "core:path/filepath"

Config :: struct {
	openai_key:     string,
	anthropic_key:  string,
	openrouter_key: string,
	provider:       string,
	model:          string,
	timezone:       string,
	enrich:         bool, // consent to send artist names to the provider; off unless set
}

LLM_Provider :: enum {
	None,
	OpenAI,
	Anthropic,
	OpenRouter,
}

config_dir :: proc() -> string {
	home := os.get_env_alloc("HOME", context.allocator)
	if len(home) == 0 do home = os.get_env_alloc("USERPROFILE", context.allocator)
	p, _ := filepath.join({home, ".config", "spotify-history-report"}, context.allocator)
	return p
}

config_path :: proc() -> string {
	dir := config_dir()
	p, _ := filepath.join({dir, "config.json"}, context.allocator)
	return p
}

genre_cache_path :: proc(data_dir: string) -> string {
	p, _ := filepath.join({data_dir, ".genre_cache.json"}, context.allocator)
	return p
}

load_config :: proc() -> Config {
	cfg: Config
	path := config_path()
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return cfg

	Raw_Config :: struct {
		openai_key:     string,
		anthropic_key:  string,
		openrouter_key: string,
		provider:       string,
		model:          string,
		timezone:       string,
		enrich:         bool,
	}
	raw: Raw_Config
	json_err := json.unmarshal(data, &raw)
	delete(data)
	if json_err != nil do return cfg

	cfg.openai_key = raw.openai_key
	cfg.anthropic_key = raw.anthropic_key
	cfg.openrouter_key = raw.openrouter_key
	cfg.provider = raw.provider
	cfg.model = raw.model
	cfg.timezone = raw.timezone
	cfg.enrich = raw.enrich
	return cfg
}

save_config :: proc(cfg: Config) -> bool {
	dir := config_dir()
	if err := os.make_directory_all(dir, {.Read_User, .Write_User, .Execute_User}); err != nil && err != .Exist do return false

	j := strings.builder_make()
	defer strings.builder_destroy(&j)

	strings.write_string(&j, "{\n")
	strings.write_string(&j, fmt.aprintf("  \"openai_key\": \"%s\",\n", json_escape(cfg.openai_key)))
	strings.write_string(&j, fmt.aprintf("  \"anthropic_key\": \"%s\",\n", json_escape(cfg.anthropic_key)))
	strings.write_string(&j, fmt.aprintf("  \"openrouter_key\": \"%s\",\n", json_escape(cfg.openrouter_key)))
	strings.write_string(&j, fmt.aprintf("  \"provider\": \"%s\",\n", json_escape(cfg.provider)))
	strings.write_string(&j, fmt.aprintf("  \"model\": \"%s\",\n", json_escape(cfg.model)))
	strings.write_string(&j, fmt.aprintf("  \"timezone\": \"%s\",\n", json_escape(cfg.timezone)))
	strings.write_string(&j, fmt.aprintf("  \"enrich\": %v\n", cfg.enrich))
	strings.write_string(&j, "}\n")

	path := config_path()
	// The file holds API keys: owner-only.
	return os.write_entire_file(path, transmute([]u8)strings.to_string(j), {.Read_User, .Write_User}) == nil
}

// Local-time zone for bucketing plays: --timezone, then the config file, then
// $TZ, then DEFAULT_TIMEZONE (what earlier versions hard-coded as UTC-8).
resolve_timezone :: proc(cli: string, cfg: Config) -> string {
	if len(cli) > 0 do return cli
	if len(cfg.timezone) > 0 do return cfg.timezone
	if tz := os.get_env_alloc("TZ", context.allocator); len(tz) > 0 do return tz
	return DEFAULT_TIMEZONE
}

resolve_provider :: proc(cfg: Config) -> (LLM_Provider, string, string) {
	// CLI env overrides, then config file
	oai := os.get_env_alloc("OPENAI_API_KEY", context.allocator)
	if len(oai) == 0 do oai = cfg.openai_key

	ant := os.get_env_alloc("ANTHROPIC_API_KEY", context.allocator)
	if len(ant) == 0 do ant = cfg.anthropic_key

	orr := os.get_env_alloc("OPENROUTER_API_KEY", context.allocator)
	if len(orr) == 0 do orr = cfg.openrouter_key

	prov := cfg.provider
	model := cfg.model

	// If provider set, use that
	switch prov {
	case "openai":
		if len(oai) > 0 {
			if len(model) == 0 do model = "gpt-4o-mini"
			return .OpenAI, oai, model
		}
	case "anthropic":
		if len(ant) > 0 {
			if len(model) == 0 do model = "claude-sonnet-4-20250514"
			return .Anthropic, ant, model
		}
	case "openrouter":
		if len(orr) > 0 {
			if len(model) == 0 do model = "anthropic/claude-sonnet-4-20250514"
			return .OpenRouter, orr, model
		}
	}

	// Auto-detect: prefer Anthropic > OpenAI > OpenRouter
	if len(ant) > 0 {
		if len(model) == 0 do model = "claude-sonnet-4-20250514"
		return .Anthropic, ant, model
	}
	if len(oai) > 0 {
		if len(model) == 0 do model = "gpt-4o-mini"
		return .OpenAI, oai, model
	}
	if len(orr) > 0 {
		if len(model) == 0 do model = "anthropic/claude-sonnet-4-20250514"
		return .OpenRouter, orr, model
	}

	return .None, "", ""
}

// Reads the legacy .genre_cache.json. Only the one-time import into
// .shr/annotations.json uses it; nothing writes this file any more.
load_genre_cache :: proc(data_dir: string) -> (map[string]string, bool) {
	path := genre_cache_path(data_dir)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return {}, false

	result: map[string]string
	json_err := json.unmarshal(data, &result)
	delete(data)
	if json_err != nil do return {}, false
	return result, true
}

json_escape :: proc(s: string) -> string {
	b := strings.builder_make()
	for c in s {
		switch c {
		case '"':  strings.write_string(&b, "\\\"")
		case '\\': strings.write_string(&b, "\\\\")
		case '\n': strings.write_string(&b, "\\n")
		case '\t': strings.write_string(&b, "\\t")
		case '\r': strings.write_string(&b, "\\r")
		case 0 ..< 0x20: strings.write_string(&b, fmt.tprintf("\\u%04x", int(c)))
		case:      strings.write_rune(&b, c)
		}
	}
	return strings.to_string(b)
}
