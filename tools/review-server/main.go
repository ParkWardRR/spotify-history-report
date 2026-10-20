// review-server is a small local web server for reviewing which artists on a
// shared Spotify account belong to another listener. It serves self-contained
// review pages, records keep/remove decisions, and exports them as the
// `exclude_artists` list that `.shr/overrides.json` understands.
//
// It listens on the loopback interface only and refuses requests that did not
// come from its own pages (see guard), because anything a web page can reach
// on localhost, any web page can reach.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"html"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

const maxBody = 1 << 20 // a decision is a list of names; 1 MiB is far more than enough

var (
	reviewFile = regexp.MustCompile(`^review_[A-Za-z0-9._-]+\.html$`)
	// A decision's type becomes part of a file name, so it is a short slug.
	typeSlug = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
)

// Decision is one saved review: artists to drop from the report and artists
// confirmed as the account owner's.
type Decision struct {
	Type   string   `json:"type"`
	Remove []string `json:"remove"`
	Keep   []string `json:"keep"`
}

type server struct {
	reviewDir string
	outDir    string
}

// newHandler builds the routes. It is separate from main so tests can drive it.
func newHandler(reviewDir, outDir string) http.Handler {
	s := &server{reviewDir: reviewDir, outDir: outDir}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", s.index)
	mux.HandleFunc("GET /{name}", s.page)
	mux.HandleFunc("POST /api/save", s.save)
	mux.HandleFunc("GET /api/export-overrides", s.export)
	return s.guard(mux)
}

// guard rejects requests whose Host is not this server's own loopback address
// (DNS rebinding) and state-changing requests that a page on another origin
// sent (cross-site request forgery).
func (s *server) guard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.Host)
		if err != nil {
			host = r.Host
		}
		if host != "127.0.0.1" && host != "localhost" && host != "[::1]" && host != "::1" {
			http.Error(w, "unexpected Host", http.StatusForbidden)
			return
		}
		if r.Method == http.MethodPost {
			if o := r.Header.Get("Origin"); o != "" {
				u, err := url.Parse(o)
				if err != nil || u.Host != r.Host {
					http.Error(w, "cross-origin request refused", http.StatusForbidden)
					return
				}
			}
			if ct := r.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
				http.Error(w, "Content-Type must be application/json", http.StatusUnsupportedMediaType)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

func (s *server) index(w http.ResponseWriter, r *http.Request) {
	files, _ := filepath.Glob(filepath.Join(s.reviewDir, "review_*.html"))
	sort.Strings(files)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, `<!DOCTYPE html><html><head><meta charset="utf-8"><title>Shared-Account Review</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>body{font-family:system-ui;background:#f5f5f3;display:flex;justify-content:center;align-items:center;min-height:100vh;gap:40px;flex-wrap:wrap;padding:40px}
a{display:block;padding:24px 48px;background:white;border-radius:12px;text-decoration:none;color:#0b0b0b;font-size:20px;font-weight:600;box-shadow:0 2px 8px rgba(0,0,0,0.08);transition:transform 0.1s}
a:hover{transform:scale(1.03)}
.sub{font-size:13px;color:#898781;margin-top:4px}
h1{width:100%;text-align:center;font-size:24px;color:#0b0b0b}</style></head>
<body><h1>Shared-Account Artist Review</h1>`)
	for _, f := range files {
		name := filepath.Base(f)
		if !reviewFile.MatchString(name) {
			continue
		}
		label := strings.TrimSuffix(strings.TrimPrefix(name, "review_"), ".html")
		fmt.Fprintf(w, `<a href="/%s">Review %s<div class="sub">%s</div></a>`,
			url.PathEscape(name), html.EscapeString(label), html.EscapeString(name))
	}
	fmt.Fprint(w, `</body></html>`)
}

func (s *server) page(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !reviewFile.MatchString(name) {
		http.NotFound(w, r)
		return
	}
	http.ServeFile(w, r, filepath.Join(s.reviewDir, name))
}

// clean trims names, drops empties and duplicates, and keeps the order given.
func clean(names []string) []string {
	out := []string{}
	seen := map[string]bool{}
	for _, n := range names {
		n = strings.TrimSpace(n)
		if n != "" && !seen[n] {
			seen[n] = true
			out = append(out, n)
		}
	}
	return out
}

func (s *server) save(w http.ResponseWriter, r *http.Request) {
	var d Decision
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&d); err != nil {
		http.Error(w, "invalid decision: "+err.Error(), http.StatusBadRequest)
		return
	}
	if !typeSlug.MatchString(d.Type) {
		http.Error(w, `"type" must be 1-64 letters, digits, "_" or "-"`, http.StatusBadRequest)
		return
	}
	d.Remove, d.Keep = clean(d.Remove), clean(d.Keep)
	kept := map[string]bool{}
	for _, k := range d.Keep {
		kept[k] = true
	}
	for _, rm := range d.Remove {
		if kept[rm] {
			http.Error(w, fmt.Sprintf("%q is in both remove and keep", rm), http.StatusBadRequest)
			return
		}
	}

	data, _ := json.MarshalIndent(d, "", "  ")
	if err := os.MkdirAll(s.outDir, 0o755); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	fname := filepath.Join(s.outDir, d.Type+"_decisions.json")
	tmp := fname + ".tmp"
	err := os.WriteFile(tmp, data, 0o644)
	if err == nil {
		err = os.Rename(tmp, fname)
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	log.Printf("Saved %s: %d remove, %d keep -> %s", d.Type, len(d.Remove), len(d.Keep), fname)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "saved", "file": fname})
}

// export merges every saved decision into an overrides fragment. The list is
// always a JSON array (never null), sorted and without duplicates, so the same
// decisions always give the same bytes and the report accepts the result.
func (s *server) export(w http.ResponseWriter, r *http.Request) {
	files, _ := filepath.Glob(filepath.Join(s.outDir, "*_decisions.json"))
	sort.Strings(files)
	var all []string
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			log.Printf("export: skipping %s: %v", f, err)
			continue
		}
		var d Decision
		if err := json.Unmarshal(data, &d); err != nil {
			log.Printf("export: skipping %s: %v", f, err)
			continue
		}
		all = append(all, d.Remove...)
	}
	exclude := clean(all)
	sort.Strings(exclude)

	w.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	enc.Encode(map[string]any{"version": 1, "exclude_artists": exclude})
}

func main() {
	port := flag.Int("port", 8234, "HTTP port (loopback only)")
	reviewDir := flag.String("dir", ".", "directory containing review_*.html files")
	outDir := flag.String("out", ".", "directory for decision JSON output")
	flag.Parse()

	addr := fmt.Sprintf("127.0.0.1:%d", *port)
	srv := &http.Server{
		Addr:              addr,
		Handler:           newHandler(*reviewDir, *outDir),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
	}
	log.Printf("Review server at http://%s", addr)
	log.Printf("  Review dir: %s", *reviewDir)
	log.Printf("  Output dir: %s", *outDir)
	log.Fatal(srv.ListenAndServe())
}
