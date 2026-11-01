package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The Odin report pins the same three hashes (src/input_test.odin); if these
// drift the preview no longer matches what the report drops.
func TestHashMatchesTheReport(t *testing.T) {
	cases := []struct {
		ts, artist, track string
		ms                int64
		want              uint64
	}{
		{"2018-07-01T12:00:00Z", "Tyga", "Taste (feat. Offset)", 187000, 12424613125852909923},
		{"2019-01-02T03:04:05Z", "Kanye West", "Stronger", 311000, 17775851159619508905},
		{"2012-02-03T04:05:06Z", "JAY-Z", "Gotta Have It", 140000, 1095902694580450456},
	}
	for _, c := range cases {
		if got := rowHash(c.ts, c.artist, c.track, c.ms); got != c.want {
			t.Errorf("rowHash(%s, %s) = %d, want %d", c.artist, c.track, got, c.want)
		}
	}
}

func TestTrackRuleBeatsArtistRule(t *testing.T) {
	rules := []Rule{{Artist: "A", Remove: 0.3}, {Artist: "A", Track: "Hit", Remove: 0.5}, {Track: "Any", Remove: 1}}
	if got := ruleFor(rules, "A", "Hit"); got != 1 {
		t.Errorf("A/Hit -> %d, want 1", got)
	}
	if got := ruleFor(rules, "A", "Other"); got != 0 {
		t.Errorf("A/Other -> %d, want 0", got)
	}
	if got := ruleFor(rules, "B", "Any"); got != 2 {
		t.Errorf("B/Any -> %d, want 2", got)
	}
	if got := ruleFor(rules, "B", "Hit"); got != -1 {
		t.Errorf("B/Hit -> %d, want -1", got)
	}
}

func fixture(t *testing.T) *store {
	t.Helper()
	dir := t.TempDir()
	var recs []map[string]any
	for i := 0; i < 2000; i++ {
		artist, track := "Big", "Hit"
		if i%2 == 1 {
			track = "Deep Cut"
		}
		if i >= 1800 {
			artist, track = "Gone", "Song"
		}
		recs = append(recs, map[string]any{"ts": "2023-05-01T10:00:00Z", "ms_played": 200000 + i,
			"master_metadata_track_name": track, "master_metadata_album_artist_name": artist})
	}
	data, _ := json.Marshal(recs)
	os.WriteFile(filepath.Join(dir, "Streaming_History_Audio_2023.json"), data, 0o644)
	os.MkdirAll(filepath.Join(dir, ".shr"), 0o755)
	os.WriteFile(filepath.Join(dir, ".shr", "overrides.json"), []byte(`{
  "annotations": [
    {"artist": "Big", "value": "Pop"}
  ],
  "exclude_artists": ["Gone"]
}
`), 0o644)
	s, err := load(dir)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestPreviewDropsTheShareAndSkipsExcluded(t *testing.T) {
	s := fixture(t)
	p := s.preview([]Rule{{Artist: "Big", Remove: 0.3}})
	if p.PlaysBefore != 1800 {
		t.Fatalf("plays before = %d, want 1800 (Gone is excluded)", p.PlaysBefore)
	}
	d := p.Rules[0].Dropped
	if d != 540 {
		t.Errorf("dropped %d of 1800, want exactly 540", d)
	}
	if p.Plays != 1800-d || p.Rules[0].Matched != 1800 {
		t.Errorf("plays %d matched %d", p.Plays, p.Rules[0].Matched)
	}
	again := s.preview([]Rule{{Artist: "Big", Remove: 0.3}})
	if again.Rules[0].Dropped != d {
		t.Error("the same rule dropped different rows")
	}
}

func TestSaveKeepsTheRestOfTheFile(t *testing.T) {
	s := fixture(t)
	if err := s.saveRules([]Rule{{Artist: "Big", Remove: 0.3}, {Artist: "Big", Track: "Hit", Remove: 1.0 / 3}}); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(s.overrides)
	want := `{
  "version": 1,
  "annotations": [
    {"artist": "Big", "value": "Pop"}
  ],
  "exclude_artists": ["Gone"],
  "downweight": [
    {"artist":"Big","remove":0.3},
    {"artist":"Big","track":"Hit","remove":0.3333}
  ]
}
`
	if string(got) != want {
		t.Errorf("file:\n%s\nwant:\n%s", got, want)
	}
	rules, err := s.loadRules()
	if err != nil || len(rules) != 2 || rules[1].Track != "Hit" {
		t.Errorf("reload: %v %v", rules, err)
	}
	// Saving no rules removes the key instead of leaving an empty list.
	s.saveRules(nil)
	got, _ = os.ReadFile(s.overrides)
	if strings.Contains(string(got), "downweight") || !strings.Contains(string(got), `"exclude_artists": ["Gone"]`) {
		t.Errorf("after clearing:\n%s", got)
	}
}

func TestGuardAndValidation(t *testing.T) {
	h := fixture(t).routes()
	do := func(method, host, origin, ctype, body string) int {
		r := httptest.NewRequest(method, "http://"+host+"/api/preview", strings.NewReader(body))
		r.Host = host
		if origin != "" {
			r.Header.Set("Origin", origin)
		}
		if ctype != "" {
			r.Header.Set("Content-Type", ctype)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w.Code
	}
	ok := `{"rules":[{"artist":"Big","remove":0.3}]}`
	cases := []struct {
		name                      string
		host, origin, ctype, body string
		want                      int
	}{
		{"local", "127.0.0.1:8235", "http://127.0.0.1:8235", "application/json", ok, http.StatusOK},
		{"rebinding", "evil.example:8235", "", "application/json", ok, http.StatusForbidden},
		{"cross-site", "127.0.0.1:8235", "https://evil.example", "application/json", ok, http.StatusForbidden},
		{"form post", "localhost:8235", "", "text/plain", ok, http.StatusUnsupportedMediaType},
		{"percent not share", "localhost:8235", "", "application/json", `{"rules":[{"artist":"Big","remove":30}]}`, http.StatusBadRequest},
		{"no name", "localhost:8235", "", "application/json", `{"rules":[{"remove":0.3}]}`, http.StatusBadRequest},
		{"unknown field", "localhost:8235", "", "application/json", `{"rules":[{"artist":"Big","share":0.3}]}`, http.StatusBadRequest},
	}
	for _, c := range cases {
		if got := do(http.MethodPost, c.host, c.origin, c.ctype, c.body); got != c.want {
			t.Errorf("%s: %d, want %d", c.name, got, c.want)
		}
	}
}

func TestExactDuplicatesStillDropTheExactShare(t *testing.T) {
	s := &store{excluded: map[string]bool{}}
	for i := 0; i < 10; i++ { // one Apple Music daily count of 10, expanded
		s.rows = append(s.rows, row{ts: "2018-03-04T09:00:00Z", artist: "A", track: "T", ms: 200000, h: rowHash("2018-03-04T09:00:00Z", "A", "T", 200000)})
	}
	if got := s.preview([]Rule{{Artist: "A", Remove: 0.3}}).Rules[0].Dropped; got != 3 {
		t.Errorf("dropped %d of 10 identical rows, want 3", got)
	}
	if got := s.preview([]Rule{{Artist: "A", Remove: 1}}).Rules[0].Dropped; got != 10 {
		t.Errorf("remove 1 dropped %d of 10, want 10", got)
	}
}
