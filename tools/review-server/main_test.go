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

func setup(t *testing.T) (h http.Handler, reviews, out string) {
	t.Helper()
	reviews, out = t.TempDir(), filepath.Join(t.TempDir(), "decisions")
	os.WriteFile(filepath.Join(reviews, "review_genre_outliers.html"), []byte("<h1>outliers</h1>"), 0o644)
	os.WriteFile(filepath.Join(reviews, "secret.html"), []byte("nope"), 0o644)
	return newHandler(reviews, out), reviews, out
}

func do(h http.Handler, method, path, body string, hdr map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.Host = "127.0.0.1:8234"
	if method == http.MethodPost {
		req.Header.Set("Content-Type", "application/json")
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestIndexListsReviewPagesAndEscapesNames(t *testing.T) {
	h, reviews, _ := setup(t)
	os.WriteFile(filepath.Join(reviews, "review_a&b.html"), []byte("x"), 0o644)
	rec := do(h, "GET", "/", "", nil)
	body := rec.Body.String()
	if rec.Code != 200 || !strings.Contains(body, `href="/review_genre_outliers.html"`) {
		t.Fatalf("%d %s", rec.Code, body)
	}
	if strings.Contains(body, "secret.html") {
		t.Fatal("only review_*.html belong in the index")
	}
	if strings.Contains(body, "a&b") && !strings.Contains(body, "a&amp;b") {
		t.Fatalf("names must be HTML-escaped: %s", body)
	}
}

func TestReviewPagesAreServedAndNothingElse(t *testing.T) {
	h, _, _ := setup(t)
	if rec := do(h, "GET", "/review_genre_outliers.html", "", nil); rec.Code != 200 || !strings.Contains(rec.Body.String(), "outliers") {
		t.Fatalf("page not served: %d %q", rec.Code, rec.Body.String())
	}
	for _, p := range []string{"/secret.html", "/review_x.txt", "/review_..%2f..%2fetc%2fpasswd", "/nope"} {
		if rec := do(h, "GET", p, "", nil); rec.Code != 404 {
			t.Errorf("%s: want 404, got %d", p, rec.Code)
		}
	}
}

func TestSaveAndExportRoundTrip(t *testing.T) {
	h, _, out := setup(t)
	rec := do(h, "POST", "/api/save", `{"type":"genre_outliers","remove":["B"," A ","B",""],"keep":["C"]}`, nil)
	if rec.Code != 200 {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	if rec := do(h, "POST", "/api/save", `{"type":"kids","remove":["D","A"],"keep":[]}`, nil); rec.Code != 200 {
		t.Fatal(rec.Body)
	}
	if _, err := os.Stat(filepath.Join(out, "genre_outliers_decisions.json")); err != nil {
		t.Fatal(err)
	}
	rec = do(h, "GET", "/api/export-overrides", "", nil)
	var got struct {
		Version int      `json:"version"`
		Exclude []string `json:"exclude_artists"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.Version != 1 || strings.Join(got.Exclude, ",") != "A,B,D" {
		t.Fatalf("want sorted unique A,B,D, got %+v", got)
	}
}

func TestExportWithNoDecisionsIsAnEmptyListNotNull(t *testing.T) {
	h, _, _ := setup(t)
	body := do(h, "GET", "/api/export-overrides", "", nil).Body.String()
	if !strings.Contains(body, `"exclude_artists": []`) {
		t.Fatalf("the report rejects null here: %s", body)
	}
}

func TestSaveRejectsBadInput(t *testing.T) {
	h, _, out := setup(t)
	cases := map[string]string{
		"traversal":   `{"type":"../../evil","remove":["A"]}`,
		"slash":       `{"type":"a/b","remove":[]}`,
		"empty type":  `{"type":"","remove":[]}`,
		"conflict":    `{"type":"x","remove":["A"],"keep":["A"]}`,
		"unknown key": `{"type":"x","remove":[],"extra":1}`,
		"not json":    `{`,
		"too big":     `{"type":"x","remove":["` + strings.Repeat("a", maxBody) + `"]}`,
	}
	for name, body := range cases {
		if rec := do(h, "POST", "/api/save", body, nil); rec.Code != 400 && rec.Code != 413 {
			t.Errorf("%s: want 400, got %d", name, rec.Code)
		}
	}
	if entries, _ := os.ReadDir(filepath.Dir(out)); len(entries) > 0 {
		for _, e := range entries {
			if strings.Contains(e.Name(), "evil") {
				t.Fatalf("a traversal wrote %s", e.Name())
			}
		}
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(filepath.Dir(out)), "evil_decisions.json")); err == nil {
		t.Fatal("path traversal succeeded")
	}
}

func TestGuardRefusesForeignOriginsAndHosts(t *testing.T) {
	h, _, _ := setup(t)
	body := `{"type":"x","remove":["A"],"keep":[]}`
	if rec := do(h, "POST", "/api/save", body, map[string]string{"Origin": "https://evil.example"}); rec.Code != 403 {
		t.Errorf("cross-site POST: want 403, got %d", rec.Code)
	}
	if rec := do(h, "POST", "/api/save", body, map[string]string{"Origin": "http://127.0.0.1:8234"}); rec.Code != 200 {
		t.Errorf("same-origin POST: want 200, got %d", rec.Code)
	}
	if rec := do(h, "POST", "/api/save", body, map[string]string{"Content-Type": "text/plain"}); rec.Code != 415 {
		t.Errorf("simple-request content type: want 415, got %d", rec.Code)
	}
	req := httptest.NewRequest("GET", "/", nil)
	req.Host = "attacker.example:8234" // DNS rebinding
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != 403 {
		t.Errorf("rebinding host: want 403, got %d", rec.Code)
	}
}
