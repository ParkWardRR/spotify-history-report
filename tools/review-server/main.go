package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
)

type Decision struct {
	Type   string   `json:"type"`
	Remove []string `json:"remove"`
	Keep   []string `json:"keep"`
}

func main() {
	port := flag.Int("port", 8234, "HTTP port")
	reviewDir := flag.String("dir", ".", "directory containing review HTML files")
	outDir := flag.String("out", ".", "directory for decision JSON output")
	flag.Parse()

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		files, _ := filepath.Glob(filepath.Join(*reviewDir, "review_*.html"))
		fmt.Fprintf(w, `<!DOCTYPE html><html><head><meta charset="utf-8"><title>Shared-Account Review</title>
<style>body{font-family:system-ui;background:#f5f5f3;display:flex;justify-content:center;align-items:center;min-height:100vh;gap:40px;flex-wrap:wrap;padding:40px}
a{display:block;padding:24px 48px;background:white;border-radius:12px;text-decoration:none;color:#0b0b0b;font-size:20px;font-weight:600;box-shadow:0 2px 8px rgba(0,0,0,0.08);transition:transform 0.1s}
a:hover{transform:scale(1.03)}
.sub{font-size:13px;color:#898781;margin-top:4px}
h1{width:100%%;text-align:center;font-size:24px;color:#0b0b0b}</style></head>
<body><h1>Shared-Account Artist Review</h1>`)
		for _, f := range files {
			name := filepath.Base(f)
			label := name[len("review_") : len(name)-len(".html")]
			fmt.Fprintf(w, `<a href="/%s">Review %s<div class="sub">%s</div></a>`, name, label, name)
		}
		fmt.Fprint(w, `</body></html>`)
	})

	http.HandleFunc("/review_", func(w http.ResponseWriter, r *http.Request) {
		name := filepath.Base(r.URL.Path)
		http.ServeFile(w, r, filepath.Join(*reviewDir, name))
	})

	http.HandleFunc("/api/save", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		var d Decision
		if err := json.NewDecoder(r.Body).Decode(&d); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		fname := filepath.Join(*outDir, fmt.Sprintf("%s_decisions.json", d.Type))
		data, _ := json.MarshalIndent(d, "", "  ")
		if err := os.WriteFile(fname, data, 0644); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		log.Printf("Saved %s: %d remove, %d keep → %s", d.Type, len(d.Remove), len(d.Keep), fname)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "saved", "file": fname})
	})

	http.HandleFunc("/api/export-overrides", func(w http.ResponseWriter, r *http.Request) {
		files, _ := filepath.Glob(filepath.Join(*outDir, "*_decisions.json"))
		var allRemove []string
		for _, f := range files {
			data, err := os.ReadFile(f)
			if err != nil {
				continue
			}
			var d Decision
			if err := json.Unmarshal(data, &d); err != nil {
				continue
			}
			allRemove = append(allRemove, d.Remove...)
		}

		overrides := map[string]interface{}{
			"version":         1,
			"exclude_artists": allRemove,
		}
		w.Header().Set("Content-Type", "application/json")
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		enc.Encode(overrides)
	})

	addr := fmt.Sprintf("127.0.0.1:%d", *port)
	log.Printf("Review server at http://%s", addr)
	log.Printf("  Review dir: %s", *reviewDir)
	log.Printf("  Output dir: %s", *outDir)
	log.Fatal(http.ListenAndServe(addr, nil))
}
