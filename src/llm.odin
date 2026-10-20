package spotify_report

import "core:os"
import "core:fmt"
import "core:strings"
import "core:encoding/json"
import "core:c/libc"

GENRE_LIST :: `Hip-hop & Rap, Indie pop, Funk & Soul, Electronic, Rock, R&B, Jazz, Latin, Classical, Pop, Country, Metal, World, Other`

BATCH_SIZE :: 150

// The provider's own message for the last request that returned no answer (an
// invalid model id, a bad key, a rate limit), so a failed enrichment says why
// instead of looking like "nothing to classify". Never contains the key: it is
// the provider's response text, not our request.
llm_last_error: string

// Pulls the provider's error text out of a response that carries no answer.
note_llm_failure :: proc(resp: string) {
	msg := extract_json_string(resp, "\"message\"")
	if len(msg) == 0 do msg = "no answer in the response"
	llm_last_error = msg
}

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

		batch_result := call_llm_genre(batch, provider, api_key, model)
		for a, g in batch_result {
			result[a] = g
		}
		delete(batch_result)
		stage_msg(.Genres, .Active, fmt.aprintf("%s · %s", provider_name(provider), model), batch_idx + 1, total_batches)
	}

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
	case .OpenAI:     response = call_openai(api_key, model, prompt)
	case .Anthropic:  response = call_anthropic(api_key, model, prompt)
	case .OpenRouter: response = call_openrouter(api_key, model, prompt)
	case .None: // unreachable
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
	if err != nil {
		llm_last_error = "no response (is curl installed and the network reachable?)"
		return ""
	}
	defer delete(data)

	// Extract content from OpenAI-style response
	resp_str := string(data)
	content := extract_openai_content(resp_str)
	if len(content) == 0 do note_llm_failure(resp_str)
	return content
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
	if err != nil {
		llm_last_error = "no response (is curl installed and the network reachable?)"
		return ""
	}
	defer delete(data)

	content := extract_anthropic_content(string(data))
	if len(content) == 0 do note_llm_failure(string(data))
	return content
}

extract_openai_content :: proc(resp: string) -> string {
	return extract_json_string(resp, "\"content\"")
}

extract_anthropic_content :: proc(resp: string) -> string {
	return extract_json_string(resp, "\"text\"")
}

extract_json_string :: proc(resp: string, key: string) -> string {
	for marker in ([2]string{fmt.aprintf("%s:\"", key), fmt.aprintf("%s: \"", key)}) {
		idx := strings.index(resp, marker)
		if idx < 0 do continue

		start := idx + len(marker)
		end := start
		for end < len(resp) {
			if resp[end] == '\\' { end += 2; continue }
			if resp[end] == '"' do break
			end += 1
		}
		if end > len(resp) do end = len(resp)

		raw := resp[start:end]
		b := strings.builder_make()
		i := 0
		for i < len(raw) {
			if i + 1 < len(raw) && raw[i] == '\\' {
				switch raw[i+1] {
				case 'n':  strings.write_rune(&b, '\n')
				case 't':  strings.write_rune(&b, '\t')
				case '"':  strings.write_rune(&b, '"')
				case '\\': strings.write_rune(&b, '\\')
				case:      strings.write_byte(&b, raw[i+1])
				}
				i += 2
			} else {
				strings.write_byte(&b, raw[i])
				i += 1
			}
		}
		return strings.to_string(b)
	}
	return ""
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
