// thunderblird classifies the artists in a Spotify export by their Last.fm top
// tags and writes the answers as `lastfm` annotations into the report's
// .shr/annotations.json, next to whatever is already there.
//
// It is optional and opt-in: the report works without it. The only data it
// sends is artist names (never plays, times or counts), and `-dry-run` shows
// exactly how many before anything leaves the machine.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	bolt "go.etcd.io/bbolt"
)

// apiBase is a variable so tests can point it at a local server.
var apiBase = "https://ws.audioscrobbler.com/2.0/"

var (
	bucketArtists = []byte("artists")

	errRateLimited = errors.New("rate limited")
	errNotFound    = errors.New("artist not found")
)

type spotifyRecord struct {
	Artist   string `json:"master_metadata_album_artist_name"`
	MsPlayed int64  `json:"ms_played"`
}

// cacheEntry is what a finished Last.fm lookup leaves in the bbolt cache. An
// empty Genre means "asked, and nothing the tag table understands came back":
// it is remembered so reruns don't ask again, but it is never written out as
// an annotation. Lookups that failed are not cached at all.
type cacheEntry struct {
	Name      string   `json:"name"`
	Genre     string   `json:"genre"`
	Tags      []string `json:"tags"`
	QueryTime int64    `json:"query_time"`
}

type lastfmResponse struct {
	TopTags struct {
		Tag []struct {
			Name  string `json:"name"`
			Count int    `json:"count"`
		} `json:"tag"`
	} `json:"toptags"`
	Error   int    `json:"error"`
	Message string `json:"message"`
}

func queryLastFM(client *http.Client, apiKey, artist string) ([]string, error) {
	u := apiBase + "?method=artist.getTopTags&format=json" +
		"&artist=" + url.QueryEscape(artist) + "&api_key=" + url.QueryEscape(apiKey)
	resp, err := client.Get(u)
	if err != nil {
		// net/http errors embed the full URL, API key included. Keep the cause only.
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusTooManyRequests {
		return nil, errRateLimited
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	var lfm lastfmResponse
	if err := json.Unmarshal(body, &lfm); err != nil {
		return nil, fmt.Errorf("unreadable response (HTTP %d)", resp.StatusCode)
	}
	switch lfm.Error {
	case 0:
	case 6: // "The artist you supplied could not be found"
		return nil, errNotFound
	case 29: // rate limit exceeded
		return nil, errRateLimited
	default:
		return nil, fmt.Errorf("lastfm error %d: %s", lfm.Error, lfm.Message)
	}
	var tags []string
	for _, t := range lfm.TopTags.Tag {
		if t.Count > 0 {
			tags = append(tags, t.Name)
		}
	}
	return tags, nil
}

// readArtists returns the hours listened per artist (plays of 30 s or more, the
// report's own definition), skipping every excluded artist.
func readArtists(dataDir string, excluded map[string]bool) (hours map[string]float64, files, records int, err error) {
	paths, _ := filepath.Glob(filepath.Join(dataDir, "Streaming_History_Audio_*.json"))
	sort.Strings(paths)
	hours = map[string]float64{}
	for _, p := range paths {
		data, rerr := os.ReadFile(p)
		if rerr != nil {
			return nil, 0, 0, rerr
		}
		var recs []spotifyRecord
		if jerr := json.Unmarshal(data, &recs); jerr != nil {
			return nil, 0, 0, fmt.Errorf("%s: %v", p, jerr)
		}
		records += len(recs)
		for _, r := range recs {
			if r.Artist != "" && r.MsPlayed >= 30000 && !excluded[r.Artist] {
				hours[r.Artist] += float64(r.MsPlayed) / 3600000
			}
		}
	}
	return hours, len(paths), records, nil
}

func main() {
	dataDir := flag.String("data", "", "folder with the export's Streaming_History_Audio_*.json (required)")
	dbPath := flag.String("db", "", "bbolt cache (default: <data>/.shr/lastfm.db)")
	annotPath := flag.String("annotations", "", "annotations store to merge into (default: <data>/.shr/annotations.json)")
	outPath := flag.String("out", "", "also write a flat {artist: genre} map here (legacy; the report does not read it)")
	refresh := flag.Bool("refresh", false, "ask Last.fm about every artist again, ignoring the cache")
	dryRun := flag.Bool("dry-run", false, "say how many artist names would be sent, then stop without any network use")
	workers := flag.Int("workers", 4, "concurrent Last.fm requests")
	apiKeyFlag := flag.String("api-key", "", "Last.fm API key (or set LASTFM_API_KEY)")
	flag.Parse()

	if *dataDir == "" {
		log.Fatal("-data is required: the folder holding Streaming_History_Audio_*.json")
	}
	if *dbPath == "" {
		*dbPath = filepath.Join(*dataDir, ".shr", "lastfm.db")
	}
	if *annotPath == "" {
		*annotPath = filepath.Join(*dataDir, ".shr", "annotations.json")
	}

	excluded, err := loadExcluded(*dataDir)
	if err != nil {
		log.Fatalf("overrides: %v", err)
	}
	hours, nfiles, nrecords, err := readArtists(*dataDir, excluded)
	if err != nil {
		log.Fatalf("read export: %v", err)
	}
	if nfiles == 0 {
		log.Fatalf("no Streaming_History_Audio_*.json in %s", *dataDir)
	}
	artists := make([]string, 0, len(hours))
	universe := make(map[string]bool, len(hours))
	for a := range hours {
		artists = append(artists, a)
		universe[a] = true
	}
	sort.Slice(artists, func(i, j int) bool {
		if hours[artists[i]] != hours[artists[j]] {
			return hours[artists[i]] > hours[artists[j]]
		}
		return artists[i] < artists[j]
	})
	log.Printf("Read %d records from %d files: %d artists (%d excluded by overrides.json)",
		nrecords, nfiles, len(artists), len(excluded))

	if err := os.MkdirAll(filepath.Dir(*dbPath), 0o755); err != nil {
		log.Fatalf("cache dir: %v", err)
	}
	db, err := bolt.Open(*dbPath, 0o644, &bolt.Options{Timeout: time.Second})
	if err != nil {
		log.Fatalf("open cache: %v", err)
	}
	defer db.Close()
	if err := db.Update(func(tx *bolt.Tx) error {
		_, err := tx.CreateBucketIfNotExists(bucketArtists)
		return err
	}); err != nil {
		log.Fatalf("cache: %v", err)
	}

	var need []string
	cached := 0
	db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket(bucketArtists)
		for _, a := range artists {
			if *refresh || b.Get([]byte(a)) == nil {
				need = append(need, a)
			} else {
				cached++
			}
		}
		return nil
	})
	log.Printf("Cache: %d artists known, %d to ask Last.fm about", cached, len(need))

	if *dryRun {
		log.Printf("Dry run: would send %d artist names to ws.audioscrobbler.com and nothing else. Nothing was sent.", len(need))
		return
	}

	if len(need) > 0 {
		apiKey := *apiKeyFlag
		if apiKey == "" {
			apiKey = os.Getenv("LASTFM_API_KEY")
		}
		if apiKey == "" {
			log.Fatal("a Last.fm API key is needed to ask about new artists: pass -api-key or set LASTFM_API_KEY")
		}
		lookup(db, apiKey, need, max(*workers, 1))
	}

	// Collect every cached answer for this export's artists.
	now := time.Now().Format("2006-01-02")
	var fresh []Annotation
	flat := map[string]string{}
	db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket(bucketArtists)
		for _, a := range artists {
			v := b.Get([]byte(a))
			if v == nil {
				continue
			}
			var e cacheEntry
			if json.Unmarshal(v, &e) != nil || e.Genre == "" {
				continue
			}
			observed := now
			if e.QueryTime > 0 {
				observed = time.Unix(e.QueryTime, 0).Format("2006-01-02")
			}
			fresh = append(fresh, Annotation{
				Artist: a, Namespace: "genre", Value: e.Genre,
				Source: sourceName, Model: modelName, Observed: observed,
			})
			flat[a] = e.Genre
		}
		return nil
	})

	existing, rerr := os.ReadFile(*annotPath)
	if rerr != nil && !os.IsNotExist(rerr) {
		log.Fatalf("read %s: %v", *annotPath, rerr)
	}
	merged, err := mergeAnnotations(existing, fresh, universe)
	if err != nil {
		log.Fatalf("%s: %v", *annotPath, err)
	}
	if err := writeFileAtomic(*annotPath, merged); err != nil {
		log.Fatalf("write %s: %v", *annotPath, err)
	}
	if *outPath != "" {
		data, _ := json.MarshalIndent(flat, "", "  ")
		if err := writeFileAtomic(*outPath, data); err != nil {
			log.Fatalf("write %s: %v", *outPath, err)
		}
	}

	genreHours := map[string]float64{}
	var total float64
	for _, a := range artists {
		total += hours[a]
		if g, ok := flat[a]; ok {
			genreHours[g] += hours[a]
		}
	}
	var covered float64
	names := make([]string, 0, len(genreHours))
	for g, h := range genreHours {
		covered += h
		names = append(names, g)
	}
	sort.Slice(names, func(i, j int) bool {
		if genreHours[names[i]] != genreHours[names[j]] {
			return genreHours[names[i]] > genreHours[names[j]]
		}
		return names[i] < names[j]
	})
	log.Printf("=== Genre breakdown (by hours listened) ===")
	for _, g := range names {
		log.Printf("  %-16s %7.0fh  %5.1f%%", g, genreHours[g], genreHours[g]/total*100)
	}
	log.Printf("  %-16s %7.0fh  %5.1f%%  (the rest stays Unclassified, not Other)", "classified", covered, covered/total*100)
	log.Printf("Wrote %d lastfm annotations into %s (other sources left untouched)", len(fresh), *annotPath)
}

// lookup asks Last.fm about each artist, ~3.5 requests a second overall, and
// caches every definite answer as it arrives so an interrupted run resumes.
// Transient failures (network, rate limits that persist) are retried once and
// then skipped without caching, so a later run asks again.
var (
	requestGap = 280 * time.Millisecond // ~3.5 requests a second overall
	retryAfter = 2 * time.Second
)

func lookup(db *bolt.DB, apiKey string, need []string, workers int) {
	client := &http.Client{Timeout: 10 * time.Second}
	var answered, failed atomic.Int64
	total := len(need)

	jobs := make(chan string, workers)
	results := make(chan cacheEntry, workers*2)

	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for artist := range jobs {
				tags, err := queryLastFM(client, apiKey, artist)
				if errors.Is(err, errRateLimited) {
					time.Sleep(retryAfter)
					tags, err = queryLastFM(client, apiKey, artist)
				}
				switch {
				case err == nil || errors.Is(err, errNotFound):
					e := cacheEntry{Name: artist, Tags: tags, QueryTime: time.Now().Unix()}
					e.Genre, _ = classify(tags)
					answered.Add(1)
					results <- e
				default:
					failed.Add(1)
					log.Printf("  skipped %q: %v", artist, err)
				}
			}
		}()
	}

	done := make(chan struct{})
	go func() {
		defer close(done)
		var batch []cacheEntry
		flush := func() {
			if len(batch) == 0 {
				return
			}
			err := db.Update(func(tx *bolt.Tx) error {
				b := tx.Bucket(bucketArtists)
				for _, e := range batch {
					data, _ := json.Marshal(e)
					if err := b.Put([]byte(e.Name), data); err != nil {
						return err
					}
				}
				return nil
			})
			if err != nil {
				log.Printf("  cache write failed: %v", err)
			}
			batch = batch[:0]
		}
		tick := time.NewTicker(2 * time.Second)
		defer tick.Stop()
		for {
			select {
			case e, ok := <-results:
				if !ok {
					flush()
					return
				}
				batch = append(batch, e)
				if n := answered.Load() + failed.Load(); n%100 == 0 {
					log.Printf("  %d/%d asked (%d skipped)", n, total, failed.Load())
				}
			case <-tick.C:
				flush()
			}
		}
	}()

	limiter := time.NewTicker(requestGap)
	defer limiter.Stop()
	for _, a := range need {
		<-limiter.C
		jobs <- a
	}
	close(jobs)
	wg.Wait()
	close(results)
	<-done
	log.Printf("Asked about %d artists: %d answered, %d skipped (they will be retried next run)", total, answered.Load(), failed.Load())
}
