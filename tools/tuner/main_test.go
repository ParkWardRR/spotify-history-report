package main

import (
	"encoding/json"
	"math/rand/v2"
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

// Same table as test_downweight_most_specific_rule_wins in src/input_test.odin.
func TestMostSpecificRuleWins(t *testing.T) {
	x := &row{artist: "A", track: "Hit", album: "LP", ts: "2018-07-01T12:00:00Z"}
	rules := []Rule{
		{Artist: "A", Remove: 0.1},
		{Artist: "A", From: "2018", To: "2018", Remove: 0.2},
		{Album: "LP", Remove: 0.3},
		{Artist: "A", Track: "Hit", Remove: 0.4},
		{Artist: "A", Track: "Hit", From: "2019", Remove: 0.5},
	}
	check := func(name string, rs []Rule, x *row, want int) {
		t.Helper()
		if got := ruleFor(rs, x); got != want {
			t.Errorf("%s: ruleFor = %d, want %d", name, got, want)
		}
		if got := newMatcher(rs).find(x); got != want {
			t.Errorf("%s: matcher = %d, want %d", name, got, want)
		}
	}
	check("all", rules, x, 3)
	check("no track rule", rules[:3], x, 2)
	check("window beats plain artist", rules[:2], x, 1)
	before := *x
	before.ts = "2017-12-31T23:59:59Z"
	check("before the window", rules[:2], &before, 0)
	end := *x
	end.ts = "2018-12-31T23:59:59Z"
	check("to 2018 covers December", rules[:2], &end, 1)
	check("to 2018-06 ends before July", []Rule{{Artist: "A", To: "2018-06", Remove: 1}}, x, -1)
	check("to 2018-07 covers July", []Rule{{Artist: "A", To: "2018-07", Remove: 1}}, x, 0)
	check("tie goes to the first", []Rule{{Artist: "A", Remove: 0.1}, {Artist: "A", Remove: 0.2}}, x, 0)
	check("song by any artist", []Rule{{Track: "Hit", Remove: 0.1}, {Artist: "A", Remove: 0.2}}, x, 0)
}

// The indexed matcher must pick exactly what the plain scan picks.
func TestMatcherAgreesWithPlainScan(t *testing.T) {
	rng := rand.New(rand.NewPCG(1, 2))
	pick := func(opts ...string) string { return opts[rng.IntN(len(opts))] }
	for trial := 0; trial < 300; trial++ {
		var rules []Rule
		for i := 0; i < 1+rng.IntN(12); i++ {
			r := Rule{Artist: pick("", "A", "B"), Track: pick("", "", "Hit", "Other"), Album: pick("", "", "", "LP"),
				From: pick("", "", "2017", "2018-07"), To: pick("", "", "2018", "2019-01"), Remove: 0.5}
			if r == (Rule{Remove: 0.5}) {
				r.Artist = "A"
			}
			rules = append(rules, r)
		}
		m := newMatcher(rules)
		for _, x := range []row{
			{artist: "A", track: "Hit", album: "LP", ts: "2018-07-01T00:00:00Z"},
			{artist: "B", track: "Other", ts: "2016-01-01T00:00:00Z"},
			{artist: "A", track: "Other", album: "LP", ts: "2019-01-31T00:00:00Z"},
		} {
			if a, b := ruleFor(rules, &x), m.find(&x); a != b {
				t.Fatalf("rules %+v row %+v: plain %d, matcher %d", rules, x, a, b)
			}
		}
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
	p := s.preview([]Rule{{Artist: "Big", Remove: 0.3}}, "")
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
	again := s.preview([]Rule{{Artist: "Big", Remove: 0.3}}, "")
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
		{"bad date", "localhost:8235", "", "application/json", `{"rules":[{"artist":"Big","from":"18","remove":0.3}]}`, http.StatusBadRequest},
		{"from after to", "localhost:8235", "", "application/json", `{"rules":[{"artist":"Big","from":"2019","to":"2018","remove":0.3}]}`, http.StatusBadRequest},
		{"window only", "localhost:8235", "", "application/json", `{"rules":[{"from":"2018","to":"2018","remove":0.3}]}`, http.StatusOK},
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
	if got := s.preview([]Rule{{Artist: "A", Remove: 0.3}}, "").Rules[0].Dropped; got != 3 {
		t.Errorf("dropped %d of 10 identical rows, want 3", got)
	}
	if got := s.preview([]Rule{{Artist: "A", Remove: 1}}, "").Rules[0].Dropped; got != 10 {
		t.Errorf("remove 1 dropped %d of 10, want 10", got)
	}
}

func TestFocusAndYears(t *testing.T) {
	s := fixture(t)
	p := s.preview([]Rule{{Artist: "Big", Track: "Hit", Remove: 1}}, "Big")
	if p.Focus == nil || len(p.Focus.Songs) != 2 {
		t.Fatalf("focus: %+v", p.Focus)
	}
	for _, song := range p.Focus.Songs {
		if song.Name == "Hit" && (song.Plays != 0 || song.PlaysBefore != 900) {
			t.Errorf("Hit: %+v", song)
		}
	}
	if len(p.Years) != 1 || p.Years[0].Year != 2023 || p.Years[0].SpotifyBefore <= p.Years[0].Spotify {
		t.Errorf("years: %+v", p.Years)
	}
	if p.Top1Share.Before != 100 {
		t.Errorf("one artist left holds %v%% of the time, want 100", p.Top1Share.Before)
	}
}
