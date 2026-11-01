// tuner is a local slider UI for the `downweight` rules in .shr/overrides.json.
// It loads the same history files the report reads, previews what the rules do
// to the top artists, songs, albums and years, and saves them back without
// touching the rest of the overrides file. The report applies them next run.
package main

import (
	"bytes"
	"embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed index.html
var assets embed.FS

const (
	minPlayMS = 30_000 // the report's threshold for a play
	maxBody   = 1 << 20
)

type row struct {
	ts, artist, track, album string
	ms                       int64
	apple                    bool
	h                        uint64 // rowHash, computed once
}

type store struct {
	mu        sync.Mutex
	dataDir   string
	rows      []row
	excluded  map[string]bool
	overrides string // path to .shr/overrides.json
}

func main() {
	dir := flag.String("data", ".", "folder with the history JSON files (and .shr/)")
	port := flag.Int("port", 8235, "HTTP port, bound to 127.0.0.1")
	flag.Parse()

	s, err := load(*dir)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("loaded %d music rows from %s", len(s.rows), *dir)
	addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(*port))
	log.Printf("open http://%s/", addr)
	srv := &http.Server{Addr: addr, Handler: s.routes(), ReadHeaderTimeout: 10 * time.Second}
	log.Fatal(srv.ListenAndServe())
}

func load(dir string) (*store, error) {
	s := &store{dataDir: dir, excluded: map[string]bool{}, overrides: filepath.Join(dir, ".shr", "overrides.json")}
	files, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return nil, err
	}
	sort.Strings(files)
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		var recs []struct {
			TS       string  `json:"ts"`
			MS       int64   `json:"ms_played"`
			Track    *string `json:"master_metadata_track_name"`
			Artist   *string `json:"master_metadata_album_artist_name"`
			Album    *string `json:"master_metadata_album_album_name"`
			Platform *string `json:"platform"`
		}
		if json.Unmarshal(data, &recs) != nil {
			continue // not streaming history
		}
		for _, r := range recs {
			if r.Track == nil || r.Artist == nil || *r.Track == "" || *r.Artist == "" {
				continue
			}
			album := ""
			if r.Album != nil {
				album = *r.Album
			}
			s.rows = append(s.rows, row{r.TS, *r.Artist, *r.Track, album, r.MS, r.Platform != nil && *r.Platform == "Apple Music",
				rowHash(r.TS, *r.Artist, *r.Track, r.MS)})
		}
	}
	if len(s.rows) == 0 {
		return nil, fmt.Errorf("no streaming-history rows in %s", dir)
	}
	ov, err := readOverrides(s.overrides)
	if err != nil {
		return nil, err
	}
	if raw, ok := ov.get("exclude_artists"); ok {
		var names []string
		if err := json.Unmarshal(raw, &names); err != nil {
			return nil, fmt.Errorf("%s: exclude_artists: %w", s.overrides, err)
		}
		for _, n := range names {
			s.excluded[n] = true
		}
	}
	return s, nil
}

// ── overrides.json, keeping every other key and its formatting ─────────────

type orderedDoc struct {
	keys []string
	vals map[string]json.RawMessage
}

func (d *orderedDoc) get(k string) (json.RawMessage, bool) {
	v, ok := d.vals[k]
	return v, ok
}

func readOverrides(path string) (*orderedDoc, error) {
	d := &orderedDoc{vals: map[string]json.RawMessage{}}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return d, nil
	}
	if err != nil {
		return nil, err
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	if tok, err := dec.Token(); err != nil || tok != json.Delim('{') {
		return nil, fmt.Errorf("%s: expected a JSON object", path)
	}
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		key := tok.(string)
		var raw json.RawMessage
		if err := dec.Decode(&raw); err != nil {
			return nil, fmt.Errorf("%s: %s: %w", path, key, err)
		}
		if _, dup := d.vals[key]; !dup {
			d.keys = append(d.keys, key)
		}
		d.vals[key] = raw
	}
	return d, nil
}

func (d *orderedDoc) set(k string, v json.RawMessage) {
	if _, ok := d.vals[k]; !ok {
		d.keys = append(d.keys, k)
	}
	d.vals[k] = v
}

func (d *orderedDoc) del(k string) {
	if _, ok := d.vals[k]; !ok {
		return
	}
	delete(d.vals, k)
	for i, key := range d.keys {
		if key == k {
			d.keys = append(d.keys[:i], d.keys[i+1:]...)
			break
		}
	}
}

func (d *orderedDoc) bytes() []byte {
	var b bytes.Buffer
	b.WriteString("{\n")
	for i, k := range d.keys {
		kb, _ := json.Marshal(k)
		fmt.Fprintf(&b, "  %s: %s", kb, d.vals[k])
		if i < len(d.keys)-1 {
			b.WriteByte(',')
		}
		b.WriteByte('\n')
	}
	b.WriteString("}\n")
	return b.Bytes()
}

// rulesJSON writes one rule per line so the file stays easy to read and diff.
func rulesJSON(rules []Rule) json.RawMessage {
	var b bytes.Buffer
	b.WriteString("[\n")
	for i, r := range rules {
		r.Remove = math.Round(r.Remove*10000) / 10000
		line, _ := json.Marshal(r)
		b.WriteString("    ")
		b.Write(line)
		if i < len(rules)-1 {
			b.WriteByte(',')
		}
		b.WriteByte('\n')
	}
	b.WriteString("  ]")
	return b.Bytes()
}

func (s *store) loadRules() ([]Rule, error) {
	d, err := readOverrides(s.overrides)
	if err != nil {
		return nil, err
	}
	rules := []Rule{}
	if raw, ok := d.get("downweight"); ok {
		if err := json.Unmarshal(raw, &rules); err != nil {
			return nil, fmt.Errorf("downweight: %w", err)
		}
	}
	return rules, nil
}

func (s *store) saveRules(rules []Rule) error {
	d, err := readOverrides(s.overrides)
	if err != nil {
		return err
	}
	if len(rules) == 0 {
		d.del("downweight")
	} else {
		d.set("downweight", rulesJSON(rules))
	}
	if _, ok := d.get("version"); !ok {
		d.keys = append([]string{"version"}, d.keys...)
		d.vals["version"] = json.RawMessage("1")
	}
	out := d.bytes()
	if !json.Valid(out) {
		return errors.New("refusing to write invalid JSON")
	}
	if err := os.MkdirAll(filepath.Dir(s.overrides), 0o755); err != nil {
		return err
	}
	tmp := s.overrides + ".tmp"
	if err := os.WriteFile(tmp, out, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, s.overrides)
}

// ── HTTP ───────────────────────────────────────────────────────────────────

func (s *store) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		page, _ := assets.ReadFile("index.html")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(page)
	})
	mux.HandleFunc("GET /api/state", func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		rules, err := s.loadRules()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		p := s.preview(nil, "")
		writeJSON(w, map[string]any{"rules": rules, "file": s.overrides, "artists": p.Artists, "tracks": p.Tracks, "albums": p.Albums})
	})
	mux.HandleFunc("POST /api/preview", func(w http.ResponseWriter, r *http.Request) {
		body, ok := readBody(w, r)
		if !ok {
			return
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		writeJSON(w, s.preview(body.Rules, body.Focus))
	})
	mux.HandleFunc("POST /api/save", func(w http.ResponseWriter, r *http.Request) {
		body, ok := readBody(w, r)
		if !ok {
			return
		}
		rules := body.Rules
		s.mu.Lock()
		defer s.mu.Unlock()
		if err := s.saveRules(rules); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		writeJSON(w, map[string]any{"status": "saved", "file": s.overrides, "rules": len(rules)})
	})
	return guard(mux)
}

type request struct {
	Rules []Rule `json:"rules"`
	Focus string `json:"focus,omitempty"` // an artist to break down by song and year
}

func readBody(w http.ResponseWriter, r *http.Request) (request, bool) {
	var body request
	dec := json.NewDecoder(io.LimitReader(r.Body, maxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		http.Error(w, "bad JSON: "+err.Error(), http.StatusBadRequest)
		return body, false
	}
	if body.Rules == nil {
		body.Rules = []Rule{}
	}
	if err := validate(body.Rules); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return body, false
	}
	return body, true
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

// guard is the same localhost-only protection as tools/review-server: other
// sites can reach 127.0.0.1 from a browser, so check Host, Origin and type.
func guard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !localHost(r.Host) {
			http.Error(w, "forbidden host", http.StatusForbidden)
			return
		}
		if r.Method == http.MethodPost {
			if o := r.Header.Get("Origin"); o != "" {
				u, err := url.Parse(o)
				if err != nil || !localHost(u.Host) {
					http.Error(w, "forbidden origin", http.StatusForbidden)
					return
				}
			}
			if !strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
				http.Error(w, "expected application/json", http.StatusUnsupportedMediaType)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

func localHost(hostport string) bool {
	host := hostport
	if h, _, err := net.SplitHostPort(hostport); err == nil {
		host = h
	}
	return host == "127.0.0.1" || host == "localhost" || host == "::1"
}
