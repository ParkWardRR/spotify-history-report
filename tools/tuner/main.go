// tuner is a local slider UI for the `downweight` rules in .shr/overrides.json.
// It loads the same history files the report reads, previews what each rule
// does to the top artists and songs, and saves the rules back without touching
// the rest of the overrides file. The report applies them on its next run.
package main

import (
	"bytes"
	"embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"hash/fnv"
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
	topN      = 25
)

// Rule mirrors Downweight_Rule in src/identity.odin.
type Rule struct {
	Artist string  `json:"artist,omitempty"`
	Track  string  `json:"track,omitempty"`
	Remove float64 `json:"remove"`
}

type row struct {
	ts, artist, track string
	ms                int64
	apple             bool
	h                 uint64 // rowHash, computed once
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
			Platform *string `json:"platform"`
		}
		if json.Unmarshal(data, &recs) != nil {
			continue // not streaming history
		}
		for _, r := range recs {
			if r.Track == nil || r.Artist == nil || *r.Track == "" || *r.Artist == "" {
				continue
			}
			s.rows = append(s.rows, row{r.TS, *r.Artist, *r.Track, r.MS, r.Platform != nil && *r.Platform == "Apple Music",
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

// rowHash must match downweight_hash in src/pipeline.odin bit for bit.
func rowHash(ts, artist, track string, ms int64) uint64 {
	h := fnv.New64a()
	fmt.Fprintf(h, "%s\x1f%s\x1f%s\x1f%d", ts, artist, track, ms)
	return fmix64(h.Sum64())
}

// cutoffs mirrors downweight_cutoffs: each rule drops exactly
// round(remove × its plays), the plays with the lowest hashes. Short listens
// below the same cutoff are dropped too, as in the report.
type cutoff struct {
	hash uint64
	ties int // plays with exactly this hash that are dropped (exact duplicates)
}

func (s *store) cutoffs(rules []Rule) []cutoff {
	pools := make([][]uint64, len(rules))
	for _, r := range s.rows {
		if s.excluded[r.artist] || r.ms < minPlayMS {
			continue
		}
		if ri := ruleFor(rules, r.artist, r.track); ri >= 0 {
			pools[ri] = append(pools[ri], r.h)
		}
	}
	out := make([]cutoff, len(rules))
	for i, pool := range pools {
		k := min(int(math.Round(rules[i].Remove*float64(len(pool)))), len(pool))
		if k == 0 {
			continue
		}
		sort.Slice(pool, func(a, b int) bool { return pool[a] < pool[b] })
		last, below := pool[k-1], 0
		for below < k && pool[below] < last {
			below++
		}
		out[i] = cutoff{last, k - below}
	}
	return out
}

// ruleFor mirrors downweight_rule_for: a track rule beats an artist rule.
func ruleFor(rules []Rule, artist, track string) int {
	byArtist := -1
	for i, r := range rules {
		if r.Track != "" {
			if r.Track == track && (r.Artist == "" || r.Artist == artist) {
				return i
			}
		} else if r.Artist == artist && byArtist < 0 {
			byArtist = i
		}
	}
	return byArtist
}

func validate(rules []Rule) error {
	for i, r := range rules {
		r.Artist, r.Track = strings.TrimSpace(r.Artist), strings.TrimSpace(r.Track)
		if r.Artist == "" && r.Track == "" {
			return fmt.Errorf("rule %d needs an artist, a track or both", i+1)
		}
		if !(r.Remove > 0 && r.Remove <= 1) {
			return fmt.Errorf("rule %d: remove must be above 0 and at most 1", i+1)
		}
		rules[i] = r
	}
	return nil
}

// ── Preview ────────────────────────────────────────────────────────────────

type tally struct {
	plays int
	ms    int64
}

type ruleStat struct {
	Matched     int     `json:"matched"` // plays the rule applies to
	Dropped     int     `json:"dropped"`
	HoursBefore float64 `json:"hours_before"`
	HoursAfter  float64 `json:"hours_after"`
}

type ranked struct {
	Name        string  `json:"name"`
	Artist      string  `json:"artist,omitempty"`
	Plays       int     `json:"plays"`
	PlaysBefore int     `json:"plays_before"`
	Hours       float64 `json:"hours"`
	HoursBefore float64 `json:"hours_before"`
	Rank        int     `json:"rank"`
	RankBefore  int     `json:"rank_before"` // 0 = outside the list before
}

type preview struct {
	Rules       []ruleStat `json:"rules"`
	Plays       int        `json:"plays"`
	PlaysBefore int        `json:"plays_before"`
	Hours       float64    `json:"hours"`
	HoursBefore float64    `json:"hours_before"`
	Artists     []ranked   `json:"artists"`
	Tracks      []ranked   `json:"tracks"`
}

func hours(ms int64) float64 { return math.Round(float64(ms)/3.6e6*10) / 10 }

func (s *store) preview(rules []Rule) preview {
	stats := make([]tally, len(rules)*2) // [before, after] per rule
	dropped := make([]int, len(rules))
	before, after := map[string]*tally{}, map[string]*tally{}
	tBefore, tAfter := map[[2]string]*tally{}, map[[2]string]*tally{}
	var all, kept tally
	cut := s.cutoffs(rules)
	tiesTaken := make([]int, len(rules))
	add := func(m map[string]*tally, k string, ms int64) {
		if m[k] == nil {
			m[k] = &tally{}
		}
		m[k].plays++
		m[k].ms += ms
	}
	addT := func(m map[[2]string]*tally, k [2]string, ms int64) {
		if m[k] == nil {
			m[k] = &tally{}
		}
		m[k].plays++
		m[k].ms += ms
	}
	for _, r := range s.rows {
		if s.excluded[r.artist] || r.ms < minPlayMS {
			continue
		}
		key := [2]string{r.artist, r.track}
		all.plays++
		all.ms += r.ms
		add(before, r.artist, r.ms)
		addT(tBefore, key, r.ms)
		if ri := ruleFor(rules, r.artist, r.track); ri >= 0 {
			stats[ri*2].plays++
			stats[ri*2].ms += r.ms
			tie := r.h == cut[ri].hash && tiesTaken[ri] < cut[ri].ties
			if tie {
				tiesTaken[ri]++
			}
			if r.h < cut[ri].hash || tie {
				dropped[ri]++
				continue
			}
			stats[ri*2+1].plays++
			stats[ri*2+1].ms += r.ms
		}
		kept.plays++
		kept.ms += r.ms
		add(after, r.artist, r.ms)
		addT(tAfter, key, r.ms)
	}

	p := preview{Plays: kept.plays, PlaysBefore: all.plays, Hours: hours(kept.ms), HoursBefore: hours(all.ms)}
	for i := range rules {
		p.Rules = append(p.Rules, ruleStat{stats[i*2].plays, dropped[i], hours(stats[i*2].ms), hours(stats[i*2+1].ms)})
	}

	// Artists rank by hours, songs by plays, as in the report.
	rankArtists := func(m map[string]*tally) []string {
		names := make([]string, 0, len(m))
		for k := range m {
			names = append(names, k)
		}
		sort.Slice(names, func(i, j int) bool {
			if m[names[i]].ms != m[names[j]].ms {
				return m[names[i]].ms > m[names[j]].ms
			}
			return names[i] < names[j]
		})
		return names
	}
	rankTracks := func(m map[[2]string]*tally) [][2]string {
		keys := make([][2]string, 0, len(m))
		for k := range m {
			keys = append(keys, k)
		}
		sort.Slice(keys, func(i, j int) bool {
			if m[keys[i]].plays != m[keys[j]].plays {
				return m[keys[i]].plays > m[keys[j]].plays
			}
			return keys[i][0]+keys[i][1] < keys[j][0]+keys[j][1]
		})
		return keys
	}
	oldA := map[string]int{}
	for i, n := range rankArtists(before) {
		oldA[n] = i + 1
	}
	for i, n := range rankArtists(after) {
		if i >= topN {
			break
		}
		p.Artists = append(p.Artists, ranked{Name: n, Plays: after[n].plays, PlaysBefore: before[n].plays,
			Hours: hours(after[n].ms), HoursBefore: hours(before[n].ms), Rank: i + 1, RankBefore: oldA[n]})
	}
	oldT := map[[2]string]int{}
	for i, k := range rankTracks(tBefore) {
		oldT[k] = i + 1
	}
	for i, k := range rankTracks(tAfter) {
		if i >= topN {
			break
		}
		p.Tracks = append(p.Tracks, ranked{Name: k[1], Artist: k[0], Plays: tAfter[k].plays, PlaysBefore: tBefore[k].plays,
			Hours: hours(tAfter[k].ms), HoursBefore: hours(tBefore[k].ms), Rank: i + 1, RankBefore: oldT[k]})
	}
	return p
}

// candidates lists the biggest artists and songs, for the add-a-rule search.
func (s *store) candidates() (artists []ranked, tracks []ranked) {
	a, t := map[string]*tally{}, map[[2]string]*tally{}
	for _, r := range s.rows {
		if s.excluded[r.artist] || r.ms < minPlayMS {
			continue
		}
		if a[r.artist] == nil {
			a[r.artist] = &tally{}
		}
		a[r.artist].plays++
		a[r.artist].ms += r.ms
		k := [2]string{r.artist, r.track}
		if t[k] == nil {
			t[k] = &tally{}
		}
		t[k].plays++
		t[k].ms += r.ms
	}
	for n, v := range a {
		artists = append(artists, ranked{Name: n, Plays: v.plays, Hours: hours(v.ms)})
	}
	for k, v := range t {
		tracks = append(tracks, ranked{Name: k[1], Artist: k[0], Plays: v.plays, Hours: hours(v.ms)})
	}
	sort.Slice(artists, func(i, j int) bool { return artists[i].Hours > artists[j].Hours })
	sort.Slice(tracks, func(i, j int) bool { return tracks[i].Plays > tracks[j].Plays })
	if len(artists) > 600 {
		artists = artists[:600]
	}
	if len(tracks) > 1500 {
		tracks = tracks[:1500]
	}
	return
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
		artists, tracks := s.candidates()
		writeJSON(w, map[string]any{"rules": rules, "artists": artists, "tracks": tracks, "file": s.overrides})
	})
	mux.HandleFunc("POST /api/preview", func(w http.ResponseWriter, r *http.Request) {
		rules, ok := readRules(w, r)
		if !ok {
			return
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		writeJSON(w, s.preview(rules))
	})
	mux.HandleFunc("POST /api/save", func(w http.ResponseWriter, r *http.Request) {
		rules, ok := readRules(w, r)
		if !ok {
			return
		}
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

func readRules(w http.ResponseWriter, r *http.Request) ([]Rule, bool) {
	var body struct {
		Rules []Rule `json:"rules"`
	}
	dec := json.NewDecoder(io.LimitReader(r.Body, maxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		http.Error(w, "bad JSON: "+err.Error(), http.StatusBadRequest)
		return nil, false
	}
	if body.Rules == nil {
		body.Rules = []Rule{}
	}
	if err := validate(body.Rules); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return nil, false
	}
	return body.Rules, true
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

// fmix64 is MurmurHash3's finalizer. FNV alone leaves rows that differ only in
// a few characters (the same song on nearby days) clustered, which made small
// rules miss their share by several points.
func fmix64(h uint64) uint64 {
	h ^= h >> 33
	h *= 0xff51afd7ed558ccd
	h ^= h >> 33
	h *= 0xc4ceb9fe1a85ec53
	h ^= h >> 33
	return h
}
