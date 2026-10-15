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
	return cfg
}

save_config :: proc(cfg: Config) -> bool {
	dir := config_dir()
	os.make_directory(dir)

	j := strings.builder_make()
	defer strings.builder_destroy(&j)

	strings.write_string(&j, "{\n")
	strings.write_string(&j, fmt.aprintf("  \"openai_key\": \"%s\",\n", json_escape(cfg.openai_key)))
	strings.write_string(&j, fmt.aprintf("  \"anthropic_key\": \"%s\",\n", json_escape(cfg.anthropic_key)))
	strings.write_string(&j, fmt.aprintf("  \"openrouter_key\": \"%s\",\n", json_escape(cfg.openrouter_key)))
	strings.write_string(&j, fmt.aprintf("  \"provider\": \"%s\",\n", json_escape(cfg.provider)))
	strings.write_string(&j, fmt.aprintf("  \"model\": \"%s\"\n", json_escape(cfg.model)))
	strings.write_string(&j, "}\n")

	path := config_path()
	_ = os.write_entire_file(path, transmute([]u8)strings.to_string(j))
	return true
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

// Load cached genre map from data directory
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

// Save genre map cache
save_genre_cache :: proc(data_dir: string, genres: map[string]string) {
	j := strings.builder_make()
	defer strings.builder_destroy(&j)

	strings.write_string(&j, "{\n")
	i := 0
	total := len(genres)
	for artist, genre in genres {
		comma := "," if i < total - 1 else ""
		esc_a := json_escape(artist)
		esc_g := json_escape(genre)
		strings.write_string(&j, fmt.aprintf("  \"%s\": \"%s\"%s\n", esc_a, esc_g, comma))
		i += 1
	}
	strings.write_string(&j, "}\n")

	path := genre_cache_path(data_dir)
	_ = os.write_entire_file(path, transmute([]u8)strings.to_string(j))
}

json_escape :: proc(s: string) -> string {
	b := strings.builder_make()
	for c in s {
		switch c {
		case '"':  strings.write_string(&b, "\\\"")
		case '\\': strings.write_string(&b, "\\\\")
		case '\n': strings.write_string(&b, "\\n")
		case '\t': strings.write_string(&b, "\\t")
		case:      strings.write_rune(&b, c)
		}
	}
	return strings.to_string(b)
}
