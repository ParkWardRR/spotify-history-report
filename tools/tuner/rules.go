package main

import (
	"fmt"
	"hash/fnv"
	"math"
	"sort"
	"strings"
)

// Rule mirrors Downweight_Rule in src/identity.odin. Every field that is set
// must match; From/To are an inclusive window of YYYY, YYYY-MM or YYYY-MM-DD
// against the export's UTC timestamp.
type Rule struct {
	Artist string  `json:"artist,omitempty"`
	Track  string  `json:"track,omitempty"`
	Album  string  `json:"album,omitempty"`
	From   string  `json:"from,omitempty"`
	To     string  `json:"to,omitempty"`
	Remove float64 `json:"remove"`
}

// rowHash must match downweight_hash in src/pipeline.odin bit for bit.
func rowHash(ts, artist, track string, ms int64) uint64 {
	h := fnv.New64a()
	fmt.Fprintf(h, "%s\x1f%s\x1f%s\x1f%d", ts, artist, track, ms)
	return fmix64(h.Sum64())
}

// fmix64 is MurmurHash3's finalizer. FNV alone leaves rows that differ only in
// a few characters (the same song on nearby days) clustered.
func fmix64(h uint64) uint64 {
	h ^= h >> 33
	h *= 0xff51afd7ed558ccd
	h ^= h >> 33
	h *= 0xc4ceb9fe1a85ec53
	h ^= h >> 33
	return h
}

func (r Rule) matches(x *row) bool {
	if r.Artist != "" && r.Artist != x.artist {
		return false
	}
	if r.Track != "" && r.Track != x.track {
		return false
	}
	if r.Album != "" && r.Album != x.album {
		return false
	}
	if r.From != "" && x.ts < r.From {
		return false
	}
	if r.To != "" && x.ts[:min(len(r.To), len(x.ts))] > r.To {
		return false
	}
	return true
}

// score mirrors downweight_rule_for: track, then album, then artist, then a
// window; ties go to the rule listed first.
func (r Rule) score() int {
	s := 0
	if r.Track != "" {
		s += 8
	}
	if r.Album != "" {
		s += 4
	}
	if r.Artist != "" {
		s += 2
	}
	if r.From != "" || r.To != "" {
		s++
	}
	return s
}

// ruleFor is the plain mirror of downweight_rule_for, kept for tests; the
// preview uses the indexed matcher, which must agree with it.
func ruleFor(rules []Rule, x *row) int {
	best, bestScore := -1, -1
	for i, r := range rules {
		if r.matches(x) && r.score() > bestScore {
			best, bestScore = i, r.score()
		}
	}
	return best
}

// matcher finds a row's rule by looking only at the rules that name its
// artist, track or album (plus window-only rules), so hundreds of rules stay
// fast over two hundred thousand rows.
type matcher struct {
	rules                    []Rule
	byArtist, byTrack, byAlb map[string][]int
	generic                  []int
}

func newMatcher(rules []Rule) *matcher {
	m := &matcher{rules: rules, byArtist: map[string][]int{}, byTrack: map[string][]int{}, byAlb: map[string][]int{}}
	for i, r := range rules {
		switch {
		case r.Track != "":
			m.byTrack[r.Track] = append(m.byTrack[r.Track], i)
		case r.Album != "":
			m.byAlb[r.Album] = append(m.byAlb[r.Album], i)
		case r.Artist != "":
			m.byArtist[r.Artist] = append(m.byArtist[r.Artist], i)
		default:
			m.generic = append(m.generic, i)
		}
	}
	return m
}

func (m *matcher) find(x *row) int {
	best, bestScore := -1, -1
	try := func(ids []int) {
		for _, i := range ids {
			r := m.rules[i]
			if s := r.score(); (s > bestScore || (s == bestScore && i < best)) && r.matches(x) {
				best, bestScore = i, s
			}
		}
	}
	try(m.byTrack[x.track])
	if x.album != "" {
		try(m.byAlb[x.album])
	}
	try(m.byArtist[x.artist])
	try(m.generic)
	return best
}

type cutoff struct {
	hash uint64
	ties int // plays with exactly this hash that are dropped (exact duplicates)
}

// cutoffs mirrors downweight_cutoffs: each rule drops exactly
// round(remove × its plays), the plays with the lowest hashes. Short listens
// below the same cutoff are dropped too, as in the report.
func cutoffs(rows []row, excluded map[string]bool, m *matcher) []cutoff {
	pools := make([][]uint64, len(m.rules))
	for i := range rows {
		x := &rows[i]
		if excluded[x.artist] || x.ms < minPlayMS {
			continue
		}
		if ri := m.find(x); ri >= 0 {
			pools[ri] = append(pools[ri], x.h)
		}
	}
	out := make([]cutoff, len(m.rules))
	for i, pool := range pools {
		k := min(int(math.Round(m.rules[i].Remove*float64(len(pool)))), len(pool))
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

func isDatePrefix(s string) bool {
	if len(s) != 4 && len(s) != 7 && len(s) != 10 {
		return false
	}
	for i, c := range s {
		if i == 4 || i == 7 {
			if c != '-' {
				return false
			}
		} else if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// validate applies the report's checks (parse_overrides), so a saved file
// never stops the next run.
func validate(rules []Rule) error {
	for i := range rules {
		r := &rules[i]
		r.Artist, r.Track, r.Album = strings.TrimSpace(r.Artist), strings.TrimSpace(r.Track), strings.TrimSpace(r.Album)
		r.From, r.To = strings.TrimSpace(r.From), strings.TrimSpace(r.To)
		if r.Artist == "" && r.Track == "" && r.Album == "" && r.From == "" && r.To == "" {
			return fmt.Errorf("rule %d needs an artist, song, album or date window", i+1)
		}
		for _, d := range []string{r.From, r.To} {
			if d != "" && !isDatePrefix(d) {
				return fmt.Errorf("rule %d: dates must be YYYY, YYYY-MM or YYYY-MM-DD", i+1)
			}
		}
		if r.From != "" && r.To != "" {
			n := min(len(r.From), len(r.To))
			if r.From[:n] > r.To[:n] {
				return fmt.Errorf("rule %d: from is after to", i+1)
			}
		}
		if !(r.Remove > 0 && r.Remove <= 1) {
			return fmt.Errorf("rule %d: remove must be above 0 and at most 1", i+1)
		}
	}
	return nil
}
