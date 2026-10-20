package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

const (
	schemaVersion = 1
	sourceName    = "lastfm"
	modelName     = "artist.getTopTags"
)

// Annotation is one record of .shr/annotations.json (see ROADMAP Phase 2).
type Annotation struct {
	Artist     string   `json:"artist"`
	Title      string   `json:"title"`
	Namespace  string   `json:"namespace"`
	Value      string   `json:"value"`
	Source     string   `json:"source"`
	Model      string   `json:"model"`
	Confidence *float64 `json:"confidence"`
	Observed   string   `json:"observed"`
}

// mergeAnnotations folds this run's Last.fm answers into an existing store
// without touching anything else in it. It replaces only the artist-level genre
// records that Last.fm itself wrote for the artists in `universe` (so an artist
// that now has no mappable tag loses a stale answer), and leaves user, LLM and
// every other source, and any field it does not know about, exactly as found.
// `existing` may be nil (no store yet).
func mergeAnnotations(existing []byte, fresh []Annotation, universe map[string]bool) ([]byte, error) {
	top := map[string]json.RawMessage{}
	var kept []json.RawMessage
	if len(bytes.TrimSpace(existing)) > 0 {
		if err := json.Unmarshal(existing, &top); err != nil {
			return nil, fmt.Errorf("existing annotations are not valid JSON (%v); refusing to overwrite them", err)
		}
		if raw, ok := top["schema_version"]; ok {
			var v int
			if err := json.Unmarshal(raw, &v); err != nil || v != schemaVersion {
				return nil, fmt.Errorf("existing annotations have schema_version %s; this tool writes version %d", raw, schemaVersion)
			}
		}
		if raw, ok := top["annotations"]; ok {
			var all []json.RawMessage
			if err := json.Unmarshal(raw, &all); err != nil {
				return nil, fmt.Errorf("existing annotations: \"annotations\" is not a list (%v)", err)
			}
			for _, rec := range all {
				var a Annotation
				if err := json.Unmarshal(rec, &a); err != nil {
					return nil, fmt.Errorf("existing annotations contain an unreadable record (%v); refusing to overwrite them", err)
				}
				if a.Source == sourceName && a.Title == "" && a.Namespace == "genre" && universe[a.Artist] {
					continue
				}
				kept = append(kept, rec)
			}
		}
	}

	sort.Slice(fresh, func(i, j int) bool { return fresh[i].Artist < fresh[j].Artist })
	for _, a := range fresh {
		rec, err := json.Marshal(a)
		if err != nil {
			return nil, err
		}
		kept = append(kept, rec)
	}
	if kept == nil {
		kept = []json.RawMessage{}
	}

	annotations, err := json.Marshal(kept)
	if err != nil {
		return nil, err
	}
	top["annotations"] = annotations
	top["schema_version"] = json.RawMessage(fmt.Sprint(schemaVersion))
	return marshalIndented(top)
}

// marshalIndented writes object keys in a fixed order (schema_version first,
// annotations last) so diffs of the store stay small.
func marshalIndented(top map[string]json.RawMessage) ([]byte, error) {
	keys := make([]string, 0, len(top))
	for k := range top {
		if k != "schema_version" && k != "annotations" {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	order := append(append([]string{"schema_version"}, keys...), "annotations")
	var buf bytes.Buffer
	buf.WriteString("{\n")
	for i, k := range order {
		kb, _ := json.Marshal(k)
		var val bytes.Buffer
		if err := json.Indent(&val, top[k], "  ", "  "); err != nil {
			return nil, err
		}
		fmt.Fprintf(&buf, "  %s: %s", kb, val.String())
		if i < len(order)-1 {
			buf.WriteString(",")
		}
		buf.WriteString("\n")
	}
	buf.WriteString("}\n")
	return buf.Bytes(), nil
}

// writeFileAtomic writes next to the target and renames, so an interrupted run
// can never leave a half-written store behind.
func writeFileAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// loadExcluded reads exclude_artists from <data>/.shr/overrides.json, the same
// list the report applies, so those artists' names are never sent to Last.fm.
// A missing file means nothing is excluded; an unreadable one is an error,
// because silently ignoring it would send names the user asked to withhold.
func loadExcluded(dataDir string) (map[string]bool, error) {
	path := filepath.Join(dataDir, ".shr", "overrides.json")
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var ov struct {
		Exclude []string `json:"exclude_artists"`
	}
	if err := json.Unmarshal(data, &ov); err != nil {
		return nil, fmt.Errorf("%s: %v", path, err)
	}
	out := make(map[string]bool, len(ov.Exclude))
	for _, a := range ov.Exclude {
		out[a] = true
	}
	return out, nil
}
