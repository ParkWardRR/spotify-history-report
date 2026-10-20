package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	bolt "go.etcd.io/bbolt"
)

var apiKey string

var (
	bucketArtists = []byte("artists")
	bucketMeta    = []byte("meta")
)

type SpotifyRecord struct {
	Artist   string `json:"master_metadata_album_artist_name"`
	Track    string `json:"master_metadata_track_name"`
	Album    string `json:"master_metadata_album_album_name"`
	MsPlayed int64  `json:"ms_played"`
	TS       string `json:"ts"`
}

type ArtistEntry struct {
	Name      string   `json:"name"`
	Genre     string   `json:"genre"`
	Tags      []string `json:"tags"`
	Hours     float64  `json:"hours"`
	QueryTime int64    `json:"query_time"`
	Source    string   `json:"source"`
}

type LastFMResponse struct {
	TopTags struct {
		Tag []struct {
			Name  string `json:"name"`
			Count int    `json:"count"`
		} `json:"tag"`
	} `json:"toptags"`
	Error   int    `json:"error"`
	Message string `json:"message"`
}

// Annotation represents a single genre annotation in the .shr/annotations.json format.
type Annotation struct {
	Artist     string  `json:"artist"`
	Title      string  `json:"title"`
	Namespace  string  `json:"namespace"`
	Value      string  `json:"value"`
	Source     string  `json:"source"`
	Model      string  `json:"model"`
	Confidence *string `json:"confidence"`
	Observed   string  `json:"observed"`
}

// AnnotationsFile is the top-level structure for annotations.json output.
type AnnotationsFile struct {
	SchemaVersion int          `json:"schema_version"`
	Annotations   []Annotation `json:"annotations"`
}

var tagToGenre = map[string]string{
	// Hip-hop & Rap
	"hip-hop": "Hip-hop & Rap", "hip hop": "Hip-hop & Rap", "rap": "Hip-hop & Rap",
	"trap": "Hip-hop & Rap", "southern hip hop": "Hip-hop & Rap", "gangsta rap": "Hip-hop & Rap",
	"underground hip-hop": "Hip-hop & Rap", "east coast hip hop": "Hip-hop & Rap",
	"west coast hip hop": "Hip-hop & Rap", "dirty south": "Hip-hop & Rap",
	"crunk": "Hip-hop & Rap", "grime": "Hip-hop & Rap", "conscious hip hop": "Hip-hop & Rap",
	"abstract hip hop": "Hip-hop & Rap", "alternative hip hop": "Hip-hop & Rap",
	"cloud rap": "Hip-hop & Rap", "drill": "Hip-hop & Rap", "mumble rap": "Hip-hop & Rap",
	"boom bap": "Hip-hop & Rap", "horrorcore": "Hip-hop & Rap",

	// Indie pop
	"indie": "Indie pop", "indie pop": "Indie pop", "indie rock": "Indie pop",
	"indie folk": "Indie pop", "dream pop": "Indie pop", "shoegaze": "Indie pop",
	"chamber pop": "Indie pop", "art pop": "Indie pop", "baroque pop": "Indie pop",
	"twee pop": "Indie pop", "lo-fi": "Indie pop", "slowcore": "Indie pop",
	"folktronica": "Indie pop", "alternative": "Indie pop", "new wave": "Indie pop",
	"post-punk": "Indie pop", "singer-songwriter": "Indie pop",
	"noise pop": "Indie pop", "jangle pop": "Indie pop",
	"indietronica": "Indie pop", "math rock": "Indie pop",

	// Funk & Soul (funk, soul, disco, motown, reggae, ska, afrobeat, gospel, p-funk)
	"funk": "Funk & Soul", "soul": "Funk & Soul",
	"motown": "Funk & Soul", "rhythm and blues": "Funk & Soul",
	"reggae": "Funk & Soul", "dancehall": "Funk & Soul", "ska": "Funk & Soul",
	"afrobeat": "Funk & Soul", "afrobeats": "Funk & Soul",
	"gospel": "Funk & Soul", "disco": "Funk & Soul",
	"p-funk": "Funk & Soul", "deep funk": "Funk & Soul",

	// R&B
	"r&b": "R&B", "rnb": "R&B", "neo-soul": "R&B", "neo soul": "R&B",
	"contemporary r&b": "R&B", "quiet storm": "R&B", "new jack swing": "R&B",

	// Electronic
	"electronic": "Electronic", "edm": "Electronic", "house": "Electronic",
	"techno": "Electronic", "trance": "Electronic", "dubstep": "Electronic",
	"drum and bass": "Electronic", "ambient": "Electronic", "chillwave": "Electronic",
	"electronica": "Electronic", "synthpop": "Electronic", "synth-pop": "Electronic",
	"electro": "Electronic", "deep house": "Electronic", "tropical house": "Electronic",
	"progressive house": "Electronic", "future bass": "Electronic",
	"downtempo": "Electronic", "trip-hop": "Electronic", "idm": "Electronic",
	"chillout": "Electronic", "glitch": "Electronic", "minimal": "Electronic",
	"new age": "Electronic", "electro house": "Electronic", "big room": "Electronic",
	"future house": "Electronic", "bass music": "Electronic", "witch house": "Electronic",
	"vaporwave": "Electronic", "synthwave": "Electronic", "retrowave": "Electronic",
	"uk garage": "Electronic", "breakbeat": "Electronic",
	"progressive trance": "Electronic", "psytrance": "Electronic",
	"hardstyle": "Electronic", "gabber": "Electronic",
	"dub": "Electronic", "glitch hop": "Electronic",

	// Pop
	"pop": "Pop", "dance pop": "Pop", "electropop": "Pop", "teen pop": "Pop",
	"bubblegum pop": "Pop", "europop": "Pop", "k-pop": "Pop", "j-pop": "Pop",
	"latin pop": "Pop", "power pop": "Pop", "sunshine pop": "Pop",
	"sophisti-pop": "Pop", "synth pop": "Pop",
	"dance": "Pop", "boy band": "Pop",

	// Rock
	"rock": "Rock", "classic rock": "Rock", "hard rock": "Rock",
	"punk": "Rock", "punk rock": "Rock", "pop punk": "Rock", "emo": "Rock",
	"grunge": "Rock", "post-rock": "Rock", "progressive rock": "Rock",
	"psychedelic rock": "Rock", "garage rock": "Rock", "blues rock": "Rock",
	"southern rock": "Rock", "folk rock": "Rock", "soft rock": "Rock",
	"brit pop": "Rock", "britpop": "Rock",
	"alternative rock": "Rock", "stoner rock": "Rock", "post-hardcore": "Rock",
	"screamo": "Rock", "prog rock": "Rock",
	"psychedelic": "Rock", "space rock": "Rock", "krautrock": "Rock",
	"noise rock": "Rock", "surf rock": "Rock",

	// Metal
	"metal": "Metal", "heavy metal": "Metal", "metalcore": "Metal",
	"death metal": "Metal", "black metal": "Metal", "thrash metal": "Metal",
	"doom metal": "Metal", "power metal": "Metal", "progressive metal": "Metal",
	"nu metal": "Metal", "symphonic metal": "Metal", "folk metal": "Metal",
	"gothic metal": "Metal", "sludge metal": "Metal", "grindcore": "Metal",
	"deathcore": "Metal", "djent": "Metal",

	// Country
	"country": "Country", "country rock": "Country", "alt-country": "Country",
	"americana": "Country", "bluegrass": "Country", "country pop": "Country",
	"bro-country": "Country", "outlaw country": "Country",
	"honky tonk": "Country", "nashville sound": "Country",
	"red dirt": "Country", "texas country": "Country",

	// Latin
	"latin": "Latin", "reggaeton": "Latin", "salsa": "Latin", "bachata": "Latin",
	"cumbia": "Latin", "bossa nova": "Latin", "samba": "Latin", "merengue": "Latin",
	"latin jazz": "Latin", "latin alternative": "Latin", "tropical": "Latin",
	"corrido": "Latin", "norteno": "Latin", "tejano": "Latin",
	"mpb": "Latin", "fado": "Latin", "flamenco": "Latin",

	// World (Indian/Bollywood tags also map here)
	"world": "World", "bollywood": "World", "hindi": "World", "indian": "World",
	"filmi": "World", "hindustani": "World", "desi": "World",
	"punjabi": "World", "tamil": "World", "telugu": "World",
	"carnatic": "World", "bhangra": "World", "sufi": "World",
	"indian classical": "World", "ghazal": "World",
	"qawwali": "World", "kollywood": "World",
	"celtic": "World", "african": "World", "middle eastern": "World",
	"balkan": "World", "klezmer": "World",

	// Jazz
	"jazz": "Jazz", "smooth jazz": "Jazz",
	"bebop": "Jazz", "swing": "Jazz",
	"big band": "Jazz", "cool jazz": "Jazz",
	"free jazz": "Jazz", "fusion": "Jazz",
	"acid jazz": "Jazz", "vocal jazz": "Jazz",
	"blues": "Jazz", "easy listening": "Jazz",
	"lounge": "Jazz", "traditional": "Jazz",
	"bop": "Jazz", "post-bop": "Jazz",
	"hard bop": "Jazz", "contemporary jazz": "Jazz",
	"soundtrack": "Jazz", "film score": "Jazz", "score": "Jazz",
	"christmas": "Jazz", "holiday": "Jazz",

	// Classical
	"classical": "Classical", "opera": "Classical",
	"baroque": "Classical", "romantic": "Classical",
	"orchestral": "Classical", "symphony": "Classical",
	"chamber music": "Classical", "choral": "Classical",
	"minimalism": "Classical", "contemporary classical": "Classical",
	"neo-classical": "Classical", "modern classical": "Classical",

	// Comedy / spoken word → Other
	"comedy": "Other", "stand-up comedy": "Other", "parody": "Other",
	"spoken word": "Other", "humor": "Other",

	// Folk → Indie pop
	"folk": "Indie pop", "acoustic": "Indie pop",
	"freak folk": "Indie pop", "neofolk": "Indie pop",
	"anti-folk": "Indie pop", "psych-folk": "Indie pop",

	// Misc
	"experimental": "Other",
}

func classify(tags []string) string {
	votes := make(map[string]int)
	for i, tag := range tags {
		t := strings.ToLower(strings.TrimSpace(tag))
		if genre, ok := tagToGenre[t]; ok {
			weight := 10 - i
			if weight < 1 {
				weight = 1
			}
			votes[genre] += weight
		}
	}
	if len(votes) == 0 {
		return "Other"
	}
	best := ""
	bestScore := 0
	for g, s := range votes {
		if s > bestScore {
			bestScore = s
			best = g
		}
	}
	return best
}

func queryLastFM(client *http.Client, artist string) ([]string, error) {
	u := fmt.Sprintf("https://ws.audioscrobbler.com/2.0/?method=artist.getTopTags&artist=%s&api_key=%s&format=json",
		url.QueryEscape(artist), apiKey)

	resp, err := client.Get(u)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == 429 {
		return nil, fmt.Errorf("rate limited")
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	var lfm LastFMResponse
	if err := json.Unmarshal(body, &lfm); err != nil {
		return nil, err
	}

	if lfm.Error != 0 {
		return nil, fmt.Errorf("lastfm: %s", lfm.Message)
	}

	var tags []string
	for _, t := range lfm.TopTags.Tag {
		if t.Count > 0 {
			tags = append(tags, t.Name)
		}
	}
	return tags, nil
}

func main() {
	dataDir := flag.String("data", "/tmp/spotify_cleaned", "directory with Streaming_History_Audio_*.json files")
	dbPath := flag.String("db", "artists.db", "bbolt database path")
	outPath := flag.String("out", "genre_map.json", "output genre map JSON")
	annotPath := flag.String("annotations", "", "output annotations JSON (default: annotations.json next to -out)")
	refresh := flag.Bool("refresh", false, "re-query all artists from Last.fm (ignores cache)")
	workers := flag.Int("workers", 4, "concurrent Last.fm API workers")
	apiKeyFlag := flag.String("api-key", "", "Last.fm API key (or set LASTFM_API_KEY env)")
	flag.Parse()

	apiKey = *apiKeyFlag
	if apiKey == "" {
		apiKey = os.Getenv("LASTFM_API_KEY")
	}
	if apiKey == "" {
		log.Fatal("Last.fm API key required: pass -api-key or set LASTFM_API_KEY")
	}

	// Default annotations path: sibling of -out
	if *annotPath == "" {
		dir := filepath.Dir(*outPath)
		*annotPath = filepath.Join(dir, "annotations.json")
	}

	// Load streaming history
	files, _ := filepath.Glob(filepath.Join(*dataDir, "Streaming_History_Audio_*.json"))
	sort.Strings(files)

	artistHours := make(map[string]float64)
	var totalRecords int
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			log.Fatalf("read %s: %v", f, err)
		}
		var records []SpotifyRecord
		if err := json.Unmarshal(data, &records); err != nil {
			log.Fatalf("parse %s: %v", f, err)
		}
		totalRecords += len(records)
		for _, r := range records {
			if r.Artist != "" && r.MsPlayed >= 30000 {
				artistHours[r.Artist] += float64(r.MsPlayed) / 3600000
			}
		}
	}

	artists := make([]string, 0, len(artistHours))
	for a := range artistHours {
		artists = append(artists, a)
	}
	sort.Slice(artists, func(i, j int) bool {
		return artistHours[artists[i]] > artistHours[artists[j]]
	})

	log.Printf("Loaded %d records, %d unique artists from %d files", totalRecords, len(artists), len(files))

	// Open bbolt
	db, err := bolt.Open(*dbPath, 0644, &bolt.Options{Timeout: 1 * time.Second})
	if err != nil {
		log.Fatalf("open db: %v", err)
	}
	defer db.Close()

	db.Update(func(tx *bolt.Tx) error {
		tx.CreateBucketIfNotExists(bucketArtists)
		tx.CreateBucketIfNotExists(bucketMeta)
		return nil
	})

	// Find which artists need querying
	var needQuery []string
	cached := 0
	db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket(bucketArtists)
		for _, a := range artists {
			if *refresh {
				needQuery = append(needQuery, a)
				continue
			}
			v := b.Get([]byte(a))
			if v == nil {
				needQuery = append(needQuery, a)
			} else {
				cached++
			}
		}
		return nil
	})

	log.Printf("Cache: %d artists, need to query: %d", cached, len(needQuery))

	if len(needQuery) > 0 {
		client := &http.Client{Timeout: 10 * time.Second}
		var queried atomic.Int64
		var failed atomic.Int64
		total := len(needQuery)

		type result struct {
			artist string
			entry  ArtistEntry
		}

		ch := make(chan string, *workers*2)
		results := make(chan result, *workers*2)

		var wg sync.WaitGroup
		for w := 0; w < *workers; w++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for artist := range ch {
					tags, err := queryLastFM(client, artist)
					if err != nil {
						if strings.Contains(err.Error(), "rate limited") {
							time.Sleep(2 * time.Second)
							tags, err = queryLastFM(client, artist)
						}
						if err != nil {
							failed.Add(1)
							results <- result{artist, ArtistEntry{
								Name:      artist,
								Genre:     "Other",
								Hours:     artistHours[artist],
								QueryTime: time.Now().Unix(),
								Source:    "lastfm-error",
							}}
							continue
						}
					}

					tagNames := make([]string, 0, len(tags))
					tagNames = append(tagNames, tags...)

					genre := classify(tagNames)
					queried.Add(1)
					results <- result{artist, ArtistEntry{
						Name:      artist,
						Genre:     genre,
						Tags:      tagNames,
						Hours:     artistHours[artist],
						QueryTime: time.Now().Unix(),
						Source:    "lastfm",
					}}

					time.Sleep(260 * time.Millisecond) // ~3.8 req/sec per worker, but workers share this
				}
			}()
		}

		// Collector goroutine: batch-write to bbolt
		done := make(chan struct{})
		go func() {
			batch := make([]result, 0, 100)
			flush := func() {
				if len(batch) == 0 {
					return
				}
				db.Update(func(tx *bolt.Tx) error {
					b := tx.Bucket(bucketArtists)
					for _, r := range batch {
						data, _ := json.Marshal(r.entry)
						b.Put([]byte(r.artist), data)
					}
					return nil
				})
				batch = batch[:0]
			}

			ticker := time.NewTicker(2 * time.Second)
			defer ticker.Stop()

			for {
				select {
				case r, ok := <-results:
					if !ok {
						flush()
						close(done)
						return
					}
					batch = append(batch, r)
					q := queried.Load()
					f := failed.Load()
					if (q+f)%100 == 0 {
						log.Printf("  %d/%d queried (%d failed)", q+f, total, f)
						flush()
					}
				case <-ticker.C:
					flush()
				}
			}
		}()

		// Feed artists to workers with overall rate limiting
		limiter := time.NewTicker(280 * time.Millisecond) // ~3.5 req/sec overall
		for _, a := range needQuery {
			<-limiter.C
			ch <- a
		}
		limiter.Stop()
		close(ch)
		wg.Wait()
		close(results)
		<-done

		log.Printf("Done: %d queried, %d failed", queried.Load(), failed.Load())
	}

	// Read all entries and build genre map
	genreMap := make(map[string]string)
	var totalH, otherH float64
	genreHours := make(map[string]float64)

	today := time.Now().Format("2006-01-02")
	var annotations []Annotation

	db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket(bucketArtists)
		b.ForEach(func(k, v []byte) error {
			var e ArtistEntry
			json.Unmarshal(v, &e)
			name := string(k)
			h := artistHours[name]
			if h == 0 {
				h = e.Hours
			}
			genreMap[name] = e.Genre
			genreHours[e.Genre] += h
			totalH += h
			if e.Genre == "Other" {
				otherH += h
			}
			annotations = append(annotations, Annotation{
				Artist:     name,
				Title:      "",
				Namespace:  "genre",
				Value:      e.Genre,
				Source:     "lastfm",
				Model:      "artist.getTopTags",
				Confidence: nil,
				Observed:   today,
			})
			return nil
		})
		return nil
	})

	// Also add artists that might not be in DB yet
	for _, a := range artists {
		if _, ok := genreMap[a]; !ok {
			genreMap[a] = "Other"
			otherH += artistHours[a]
			genreHours["Other"] += artistHours[a]
			totalH += artistHours[a]
			annotations = append(annotations, Annotation{
				Artist:     a,
				Title:      "",
				Namespace:  "genre",
				Value:      "Other",
				Source:     "lastfm",
				Model:      "artist.getTopTags",
				Confidence: nil,
				Observed:   today,
			})
		}
	}

	// Sort annotations by artist name for stable output
	sort.Slice(annotations, func(i, j int) bool {
		return annotations[i].Artist < annotations[j].Artist
	})

	// Write genre map
	data, _ := json.MarshalIndent(genreMap, "", "  ")
	os.WriteFile(*outPath, data, 0644)

	// Write annotations
	af := AnnotationsFile{
		SchemaVersion: 1,
		Annotations:   annotations,
	}
	aData, _ := json.MarshalIndent(af, "", "  ")
	os.WriteFile(*annotPath, aData, 0644)

	// Stats
	log.Printf("\n=== Genre breakdown ===")
	type gstat struct {
		genre string
		hours float64
	}
	var stats []gstat
	for g, h := range genreHours {
		stats = append(stats, gstat{g, h})
	}
	sort.Slice(stats, func(i, j int) bool { return stats[i].hours > stats[j].hours })
	for _, s := range stats {
		log.Printf("  %-20s %7.0fh  %5.1f%%", s.genre, s.hours, s.hours/totalH*100)
	}
	log.Printf("  %-20s %7.0fh  %5.1f%%", "TOTAL", totalH, 100.0)
	log.Printf("\nGenre map:    %d artists -> %s", len(genreMap), *outPath)
	log.Printf("Annotations:  %d entries -> %s", len(annotations), *annotPath)
	log.Printf("DB:           %s", *dbPath)
}
