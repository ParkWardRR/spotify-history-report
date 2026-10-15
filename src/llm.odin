package spotify_report

import "core:os"
import "core:fmt"
import "core:strings"
import "core:encoding/json"
import "core:c/libc"

GENRE_LIST :: `Hip-hop & Rap, Indie pop, Funk & Soul, Electronic, Rock, R&B, Jazz, Latin, Classical, Pop, Country, Metal, World, Other`

BATCH_SIZE :: 150

classify_artists_llm :: proc(
	artists: []string,
	provider: LLM_Provider,
	api_key: string,
	model: string,
	existing: map[string]string,
) -> map[string]string {
	result: map[string]string
	// Copy existing
	for a, g in existing {
		result[a] = g
	}

	// Filter to unclassified
	unclassified: [dynamic]string
	defer delete(unclassified)
	for &a in artists {
		if a not_in result {
			append(&unclassified, a)
		}
	}

	if len(unclassified) == 0 do return result

	total_batches := (len(unclassified) + BATCH_SIZE - 1) / BATCH_SIZE

	for batch_idx in 0..<total_batches {
		start := batch_idx * BATCH_SIZE
		end := min(start + BATCH_SIZE, len(unclassified))
		batch := unclassified[start:end]

		draw_progress_bar("  Classifying...", batch_idx + 1, total_batches)

		batch_result := call_llm_genre(batch, provider, api_key, model)
		for a, g in batch_result {
			result[a] = g
		}
		delete(batch_result)
	}
	fmt.println()

	return result
}

call_llm_genre :: proc(artists: []string, provider: LLM_Provider, api_key: string, model: string) -> map[string]string {
	// Build artist list
	artist_list := strings.builder_make()
	defer strings.builder_destroy(&artist_list)
	for a, i in artists {
		if i > 0 do strings.write_string(&artist_list, "\n")
		strings.write_string(&artist_list, a)
	}

	prompt := fmt.aprintf(
		`Classify each music artist below into exactly one genre from this list:
%s

Return ONLY a JSON object mapping artist name to genre. No explanation, no markdown fences.
Example: {"Artist Name": "Rock", "Other Artist": "Electronic"}

Artists:
%s`, GENRE_LIST, strings.to_string(artist_list))

	response := ""
	switch provider {
	case .OpenAI:
		response = call_openai(api_key, model, prompt)
	case .Anthropic:
		response = call_anthropic(api_key, model, prompt)
	case .OpenRouter:
		response = call_openrouter(api_key, model, prompt)
	case .None:
		// no-op
	}

	return parse_genre_response(response)
}

call_openai :: proc(key: string, model: string, prompt: string) -> string {
	body := strings.builder_make()
	defer strings.builder_destroy(&body)
	strings.write_string(&body, "{\"model\":\"")
	strings.write_string(&body, model)
	strings.write_string(&body, "\",\"messages\":[{\"role\":\"user\",\"content\":\"")
	strings.write_string(&body, json_escape(prompt))
	strings.write_string(&body, "\"}],\"temperature\":0}")

	return curl_post(
		"https://api.openai.com/v1/chat/completions",
		fmt.aprintf("Authorization: Bearer %s", key),
		strings.to_string(body),
	)
}

call_anthropic :: proc(key: string, model: string, prompt: string) -> string {
	body := strings.builder_make()
	defer strings.builder_destroy(&body)
	strings.write_string(&body, "{\"model\":\"")
	strings.write_string(&body, model)
	strings.write_string(&body, "\",\"max_tokens\":4096,\"messages\":[{\"role\":\"user\",\"content\":\"")
	strings.write_string(&body, json_escape(prompt))
	strings.write_string(&body, "\"}]}")

	return curl_post_anthropic(key, strings.to_string(body))
}

call_openrouter :: proc(key: string, model: string, prompt: string) -> string {
	body := strings.builder_make()
	defer strings.builder_destroy(&body)
	strings.write_string(&body, "{\"model\":\"")
	strings.write_string(&body, model)
	strings.write_string(&body, "\",\"messages\":[{\"role\":\"user\",\"content\":\"")
	strings.write_string(&body, json_escape(prompt))
	strings.write_string(&body, "\"}],\"temperature\":0}")

	return curl_post(
		"https://openrouter.ai/api/v1/chat/completions",
		fmt.aprintf("Authorization: Bearer %s", key),
		strings.to_string(body),
	)
}

curl_post :: proc(url: string, auth_header: string, body: string) -> string {
	// Write body to temp file
	body_path := "/tmp/shr_req.json"
	resp_path := "/tmp/shr_resp.json"
	_ = os.write_entire_file(body_path, transmute([]u8)body)

	cmd := fmt.aprintf(
		"curl -s -X POST '%s' -H 'Content-Type: application/json' -H '%s' -d @'%s' -o '%s' 2>/dev/null",
		url, auth_header, body_path, resp_path)
	defer delete(cmd)

	cmd_cstr := strings.clone_to_cstring(cmd)
	defer delete(cmd_cstr)
	libc.system(cmd_cstr)

	data, err := os.read_entire_file(resp_path, context.allocator)
	if err != nil do return ""
	defer delete(data)

	// Extract content from OpenAI-style response
	resp_str := string(data)
	return extract_openai_content(resp_str)
}

curl_post_anthropic :: proc(key: string, body: string) -> string {
	body_path := "/tmp/shr_req.json"
	resp_path := "/tmp/shr_resp.json"
	_ = os.write_entire_file(body_path, transmute([]u8)body)

	cmd := fmt.aprintf(
		"curl -s -X POST 'https://api.anthropic.com/v1/messages' -H 'Content-Type: application/json' -H 'x-api-key: %s' -H 'anthropic-version: 2023-06-01' -d @'%s' -o '%s' 2>/dev/null",
		key, body_path, resp_path)
	defer delete(cmd)

	cmd_cstr := strings.clone_to_cstring(cmd)
	defer delete(cmd_cstr)
	libc.system(cmd_cstr)

	data, err := os.read_entire_file(resp_path, context.allocator)
	if err != nil do return ""
	defer delete(data)

	return extract_anthropic_content(string(data))
}

// Extract "content" from OpenAI / OpenRouter chat completion response
extract_openai_content :: proc(resp: string) -> string {
	// Look for "content":" and extract the value
	marker := "\"content\":\""
	idx := strings.index(resp, marker)
	if idx < 0 {
		// Try content with space
		marker = "\"content\": \""
		idx = strings.index(resp, marker)
		if idx < 0 do return ""
	}
	start := idx + len(marker)
	// Find matching close quote (handle escaped quotes)
	depth := 0
	end := start
	for end < len(resp) {
		if resp[end] == '\\' {
			end += 2
			continue
		}
		if resp[end] == '"' && depth == 0 {
			break
		}
		end += 1
	}
	if end > len(resp) do end = len(resp)

	raw := resp[start:end]
	// Unescape
	b := strings.builder_make()
	i := 0
	for i < len(raw) {
		if i + 1 < len(raw) && raw[i] == '\\' {
			switch raw[i+1] {
			case 'n': strings.write_rune(&b, '\n')
			case 't': strings.write_rune(&b, '\t')
			case '"': strings.write_rune(&b, '"')
			case '\\': strings.write_rune(&b, '\\')
			case: strings.write_byte(&b, raw[i+1])
			}
			i += 2
		} else {
			strings.write_byte(&b, raw[i])
			i += 1
		}
	}
	return strings.to_string(b)
}

// Extract text from Anthropic messages response
extract_anthropic_content :: proc(resp: string) -> string {
	// Anthropic: {"content":[{"type":"text","text":"..."}]}
	marker := "\"text\":\""
	idx := strings.index(resp, marker)
	if idx < 0 {
		marker = "\"text\": \""
		idx = strings.index(resp, marker)
		if idx < 0 do return ""
	}
	start := idx + len(marker)
	end := start
	for end < len(resp) {
		if resp[end] == '\\' {
			end += 2
			continue
		}
		if resp[end] == '"' {
			break
		}
		end += 1
	}
	if end > len(resp) do end = len(resp)

	raw := resp[start:end]
	b := strings.builder_make()
	i := 0
	for i < len(raw) {
		if i + 1 < len(raw) && raw[i] == '\\' {
			switch raw[i+1] {
			case 'n': strings.write_rune(&b, '\n')
			case 't': strings.write_rune(&b, '\t')
			case '"': strings.write_rune(&b, '"')
			case '\\': strings.write_rune(&b, '\\')
			case: strings.write_byte(&b, raw[i+1])
			}
			i += 2
		} else {
			strings.write_byte(&b, raw[i])
			i += 1
		}
	}
	return strings.to_string(b)
}

// Parse the LLM response (JSON object of artist -> genre)
parse_genre_response :: proc(content: string) -> map[string]string {
	result: map[string]string

	// Find the JSON object in the response
	json_start := strings.index(content, "{")
	json_end := strings.last_index(content, "}")
	if json_start < 0 || json_end < 0 || json_end <= json_start do return result

	json_str := content[json_start:json_end + 1]

	parsed: map[string]string
	err := json.unmarshal(transmute([]u8)json_str, &parsed)
	if err != nil do return result

	for k, v in parsed {
		result[k] = v
	}
	return result
}

provider_name :: proc(p: LLM_Provider) -> string {
	switch p {
	case .OpenAI:     return "OpenAI"
	case .Anthropic:  return "Anthropic"
	case .OpenRouter: return "OpenRouter"
	case .None:       return "None"
	}
	return "Unknown"
}
