package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	bolt "go.etcd.io/bbolt"
)

func TestClassifyUnknownIsNotOther(t *testing.T) {
	if g, ok := classify([]string{"seen live", "favorites"}); ok || g != "" {
		t.Fatalf("tags the table doesn't know must be unknown, got %q ok=%v", g, ok)
	}
	if _, ok := classify(nil); ok {
		t.Fatal("no tags must be unknown")
	}
	if g, ok := classify([]string{"comedy"}); !ok || g != "Other" {
		t.Fatalf("a tag that really means Other stays Other, got %q ok=%v", g, ok)
	}
}

func TestClassifyWeighsPopularTagsAndIsDeterministic(t *testing.T) {
	// "rock" is first (weight 10); two later pop tags (8+7) beat it.
	g, _ := classify([]string{"rock", "seen live", "pop", "dance pop"})
	if g != "Pop" {
		t.Fatalf("got %q", g)
	}
	// An exact tie must not depend on map order: alphabetically first wins.
	for i := 0; i < 50; i++ {
		if g, _ := classify([]string{"jazz", "classical"}); g != "Classical" && g != "Jazz" {
			t.Fatal("unexpected")
		} else if g != "Jazz" { // jazz is first, so it has the higher weight
			t.Fatalf("got %q", g)
		}
		if g, _ := classify([]string{"rock", "pop", "rock", "pop"}); g != "Pop" && g != "Rock" {
			t.Fatal("unexpected")
		}
	}
	first, _ := classify([]string{"rock", "metal", "jazz", "pop", "world", "blues"})
	for i := 0; i < 50; i++ {
		if g, _ := classify([]string{"rock", "metal", "jazz", "pop", "world", "blues"}); g != first {
			t.Fatalf("classification changed between calls: %q vs %q", g, first)
		}
	}
}

func TestEveryTableGenreIsInTheReportVocabulary(t *testing.T) {
	valid := map[string]bool{}
	for _, g := range reportGenres {
		valid[g] = true
	}
	for tag, g := range tagToGenre {
		if !valid[g] {
			t.Errorf("tag %q maps to %q, which the report would reject", tag, g)
		}
	}
}

func rec(artist, genre, source string) Annotation {
	return Annotation{Artist: artist, Namespace: "genre", Value: genre, Source: source, Observed: "2026-01-01"}
}

func parse(t *testing.T, b []byte) (map[string]json.RawMessage, []Annotation) {
	t.Helper()
	top := map[string]json.RawMessage{}
	if err := json.Unmarshal(b, &top); err != nil {
		t.Fatalf("output is not valid JSON: %v\n%s", err, b)
	}
	var anns []Annotation
	if err := json.Unmarshal(top["annotations"], &anns); err != nil {
		t.Fatal(err)
	}
	return top, anns
}

func TestMergeKeepsEveryOtherSourceAndUnknownFields(t *testing.T) {
	existing := []byte(`{
  "schema_version": 1,
  "migrated_from": ".genre_cache.json",
  "annotations": [
    {"artist":"A","title":"","namespace":"genre","value":"Rock","source":"user","model":"","confidence":null,"observed":"2026-01-01"},
    {"artist":"A","title":"","namespace":"genre","value":"Jazz","source":"lastfm","model":"artist.getTopTags","confidence":null,"observed":"2025-01-01"},
    {"artist":"B","title":"","namespace":"genre","value":"Pop","source":"llm","model":"m","confidence":null,"observed":"2026-01-01","note":"kept"},
    {"artist":"C","title":"","namespace":"genre","value":"Metal","source":"lastfm","model":"artist.getTopTags","confidence":null,"observed":"2025-01-01"},
    {"artist":"A","title":"Song","namespace":"genre","value":"Funk & Soul","source":"lastfm","model":"","confidence":null,"observed":""}
  ]
}`)
	universe := map[string]bool{"A": true, "B": true} // C is not in this export
	out, err := mergeAnnotations(existing, []Annotation{rec("A", "Electronic", "lastfm")}, universe)
	if err != nil {
		t.Fatal(err)
	}
	top, anns := parse(t, out)
	if string(top["migrated_from"]) != `".genre_cache.json"` {
		t.Errorf("unknown top-level field lost: %s", out)
	}
	if !strings.Contains(string(out), `"note": "kept"`) {
		t.Errorf("unknown per-record field lost: %s", out)
	}
	var got []string
	for _, a := range anns {
		got = append(got, a.Artist+"/"+a.Title+"/"+a.Value+"/"+a.Source)
	}
	want := []string{"A//Rock/user", "B//Pop/llm", "C//Metal/lastfm", "A/Song/Funk & Soul/lastfm", "A//Electronic/lastfm"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("got  %v\nwant %v", got, want)
	}
}

func TestMergeDropsAStaleAnswerWhenNothingIsMappableNow(t *testing.T) {
	existing := []byte(`{"schema_version":1,"annotations":[{"artist":"A","title":"","namespace":"genre","value":"Jazz","source":"lastfm","model":"","confidence":null,"observed":""}]}`)
	out, err := mergeAnnotations(existing, nil, map[string]bool{"A": true})
	if err != nil {
		t.Fatal(err)
	}
	if _, anns := parse(t, out); len(anns) != 0 {
		t.Fatalf("stale lastfm answer should be gone: %+v", anns)
	}
	if !strings.Contains(string(out), `"annotations": []`) {
		t.Fatalf("an empty list must stay a list, not null: %s", out)
	}
}

func TestMergeIntoNothingCreatesAStoreAndIsStable(t *testing.T) {
	fresh := []Annotation{rec("B", "Pop", "lastfm"), rec("A", "Rock", "lastfm")}
	out, err := mergeAnnotations(nil, fresh, map[string]bool{"A": true, "B": true})
	if err != nil {
		t.Fatal(err)
	}
	top, anns := parse(t, out)
	if string(top["schema_version"]) != "1" || len(anns) != 2 || anns[0].Artist != "A" {
		t.Fatalf("unexpected store: %s", out)
	}
	if !strings.Contains(string(out), `"confidence": null`) {
		t.Fatalf("confidence must be null, not a made-up number: %s", out)
	}
	again, err := mergeAnnotations(out, fresh, map[string]bool{"A": true, "B": true})
	if err != nil || string(again) != string(out) {
		t.Fatalf("merging the same answers twice must change nothing (err=%v)\n%s\n---\n%s", err, out, again)
	}
}

func TestMergeRefusesToOverwriteWhatItCannotRead(t *testing.T) {
	for name, existing := range map[string]string{
		"not json":      `{oops`,
		"future schema": `{"schema_version":2,"annotations":[]}`,
		"annotations":   `{"schema_version":1,"annotations":"x"}`,
		"bad record":    `{"schema_version":1,"annotations":[7]}`,
	} {
		if _, err := mergeAnnotations([]byte(existing), nil, nil); err == nil {
			t.Errorf("%s: expected a refusal", name)
		}
	}
}

func TestExcludedArtistsAreNeverRead(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".shr"), 0o755)
	os.WriteFile(filepath.Join(dir, ".shr", "overrides.json"), []byte(`{"version":1,"exclude_artists":["Other Listener"]}`), 0o644)
	os.WriteFile(filepath.Join(dir, "Streaming_History_Audio_2023.json"), []byte(`[
	 {"master_metadata_album_artist_name":"Me","ms_played":3600000},
	 {"master_metadata_album_artist_name":"Other Listener","ms_played":3600000},
	 {"master_metadata_album_artist_name":"Short","ms_played":1000}]`), 0o644)
	ex, err := loadExcluded(dir)
	if err != nil {
		t.Fatal(err)
	}
	hours, files, records, err := readArtists(dir, ex)
	if err != nil || files != 1 || records != 3 {
		t.Fatalf("files=%d records=%d err=%v", files, records, err)
	}
	if len(hours) != 1 || hours["Me"] != 1 {
		t.Fatalf("only Me (1h) should be sent, got %v", hours)
	}

	if ex, err := loadExcluded(t.TempDir()); err != nil || ex != nil {
		t.Fatalf("no overrides file means nothing excluded, got %v %v", ex, err)
	}
	os.WriteFile(filepath.Join(dir, ".shr", "overrides.json"), []byte(`{broken`), 0o644)
	if _, err := loadExcluded(dir); err == nil {
		t.Fatal("an unreadable overrides file must stop the run, not send everyone")
	}
}

func TestLookupCachesDefiniteAnswersOnlyAndNeverLeaksTheKey(t *testing.T) {
	var mu sync.Mutex
	calls := map[string]int{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a := r.URL.Query().Get("artist")
		mu.Lock()
		calls[a]++
		n := calls[a]
		mu.Unlock()
		if r.URL.Query().Get("api_key") != "SECRET" {
			t.Errorf("api key missing from request")
		}
		switch a {
		case "Rocker":
			io.WriteString(w, `{"toptags":{"tag":[{"name":"rock","count":100},{"name":"seen live","count":50}]}}`)
		case "Mystery":
			io.WriteString(w, `{"toptags":{"tag":[{"name":"seen live","count":9}]}}`)
		case "Ghost":
			io.WriteString(w, `{"error":6,"message":"The artist you supplied could not be found"}`)
		case "Flaky":
			if n == 1 {
				w.WriteHeader(http.StatusTooManyRequests)
				return
			}
			io.WriteString(w, `{"toptags":{"tag":[{"name":"jazz","count":10}]}}`)
		case "Broken":
			io.WriteString(w, `{"error":8,"message":"Operation failed - Most likely the backend service failed"}`)
		}
	}))
	defer srv.Close()

	apiBase, requestGap, retryAfter = srv.URL+"/", time.Millisecond, time.Millisecond
	db, err := bolt.Open(filepath.Join(t.TempDir(), "c.db"), 0o644, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.Update(func(tx *bolt.Tx) error { _, err := tx.CreateBucketIfNotExists(bucketArtists); return err })

	lookup(db, "SECRET", []string{"Rocker", "Mystery", "Ghost", "Flaky", "Broken"}, 2)

	got := map[string]cacheEntry{}
	db.View(func(tx *bolt.Tx) error {
		return tx.Bucket(bucketArtists).ForEach(func(k, v []byte) error {
			var e cacheEntry
			json.Unmarshal(v, &e)
			got[string(k)] = e
			return nil
		})
	})
	want := map[string]string{"Rocker": "Rock", "Mystery": "", "Ghost": "", "Flaky": "Jazz"}
	for a, g := range want {
		e, ok := got[a]
		if !ok || e.Genre != g {
			t.Errorf("%s: cached %+v (present=%v), want genre %q", a, e, ok, g)
		}
	}
	if _, ok := got["Broken"]; ok {
		t.Error("a failed lookup must not be cached: it would be remembered as an answer")
	}
	if calls["Flaky"] != 2 {
		t.Errorf("a rate-limited request should be retried once, got %d calls", calls["Flaky"])
	}
}

func TestTransportErrorsDoNotContainTheKey(t *testing.T) {
	apiBase = "http://127.0.0.1:1/" // nothing listens here
	_, err := queryLastFM(&http.Client{Timeout: time.Second}, "SECRET", "x")
	if err == nil {
		t.Fatal("expected a connection error")
	}
	if strings.Contains(err.Error(), "SECRET") {
		t.Fatalf("error leaks the API key: %v", err)
	}
}
