package main

import (
	"math"
	"sort"
	"strconv"
)

const (
	listArtists = 300
	listTracks  = 300
	listAlbums  = 150
)

type tally struct {
	plays int
	ms    int64
}

func (t *tally) add(ms int64) { t.plays++; t.ms += ms }

// pair holds one thing's totals without rules (before) and with them (after).
type pair struct{ before, after tally }

type ruleStat struct {
	Matched     int     `json:"matched"` // plays the rule governs
	Dropped     int     `json:"dropped"`
	HoursBefore float64 `json:"hours_before"`
	HoursAfter  float64 `json:"hours_after"`
}

type ranked struct {
	Name        string  `json:"name"`
	Artist      string  `json:"artist,omitempty"`
	Plays       int     `json:"plays"`
	PlaysBefore int     `json:"plays_before"`
	Hours       float64 `json:"hours"`
	HoursBefore float64 `json:"hours_before"`
	Rank        int     `json:"rank"`
	RankBefore  int     `json:"rank_before"`
}

type yearRow struct {
	Year          int     `json:"year"`
	SpotifyBefore float64 `json:"spotify_before"`
	AppleBefore   float64 `json:"apple_before"`
	Spotify       float64 `json:"spotify"`
	Apple         float64 `json:"apple"`
}

type share struct {
	Before float64 `json:"before"`
	After  float64 `json:"after"`
}

type yearTotal struct {
	Year        int     `json:"year"`
	Hours       float64 `json:"hours"`
	HoursBefore float64 `json:"hours_before"`
}

type focusView struct {
	Artist string      `json:"artist"`
	Songs  []ranked    `json:"songs"`
	Years  []yearTotal `json:"years"`
}

type preview struct {
	Rules       []ruleStat `json:"rules"`
	Plays       int        `json:"plays"`
	PlaysBefore int        `json:"plays_before"`
	Hours       float64    `json:"hours"`
	HoursBefore float64    `json:"hours_before"`
	Artists     []ranked   `json:"artists"`
	Tracks      []ranked   `json:"tracks"`
	Albums      []ranked   `json:"albums"`
	Years       []yearRow  `json:"years"`
	Top1Share   share      `json:"top1_share"`  // % of hours on the #1 artist
	Top10Share  share      `json:"top10_share"` // % of hours on the top 10 artists
	Focus       *focusView `json:"focus,omitempty"`
}

func hours(ms int64) float64 { return math.Round(float64(ms)/3.6e6*10) / 10 }

func year(ts string) int {
	y, _ := strconv.Atoi(ts[:min(4, len(ts))])
	return y
}

func (s *store) preview(rules []Rule, focus string) preview {
	m := newMatcher(rules)
	cut := cutoffs(s.rows, s.excluded, m)
	stats := make([]pair, len(rules))
	dropped := make([]int, len(rules))
	ties := make([]int, len(rules))
	artists := map[string]*pair{}
	tracks := map[[2]string]*pair{}
	albums := map[[2]string]*pair{}
	years := map[int]*[2]pair{} // [spotify, apple]
	focusSongs := map[string]*pair{}
	focusYears := map[int]*pair{}
	var all pair

	get := func(mp map[string]*pair, k string) *pair {
		if mp[k] == nil {
			mp[k] = &pair{}
		}
		return mp[k]
	}
	get2 := func(mp map[[2]string]*pair, k [2]string) *pair {
		if mp[k] == nil {
			mp[k] = &pair{}
		}
		return mp[k]
	}
	getY := func(mp map[int]*pair, k int) *pair {
		if mp[k] == nil {
			mp[k] = &pair{}
		}
		return mp[k]
	}

	for i := range s.rows {
		x := &s.rows[i]
		if s.excluded[x.artist] || x.ms < minPlayMS {
			continue
		}
		y := year(x.ts)
		if years[y] == nil {
			years[y] = &[2]pair{}
		}
		plat := &years[y][0]
		if x.apple {
			plat = &years[y][1]
		}
		targets := []*pair{&all, get(artists, x.artist), get2(tracks, [2]string{x.artist, x.track}), plat}
		if x.album != "" {
			targets = append(targets, get2(albums, [2]string{x.artist, x.album}))
		}
		if x.artist == focus {
			targets = append(targets, get(focusSongs, x.track), getY(focusYears, y))
		}
		for _, t := range targets {
			t.before.add(x.ms)
		}
		if ri := m.find(x); ri >= 0 {
			stats[ri].before.add(x.ms)
			tie := x.h == cut[ri].hash && ties[ri] < cut[ri].ties
			if tie {
				ties[ri]++
			}
			if x.h < cut[ri].hash || tie {
				dropped[ri]++
				continue
			}
			stats[ri].after.add(x.ms)
		}
		for _, t := range targets {
			t.after.add(x.ms)
		}
	}

	p := preview{Plays: all.after.plays, PlaysBefore: all.before.plays, Hours: hours(all.after.ms), HoursBefore: hours(all.before.ms)}
	for i := range rules {
		p.Rules = append(p.Rules, ruleStat{stats[i].before.plays, dropped[i], hours(stats[i].before.ms), hours(stats[i].after.ms)})
	}
	// Artists and albums rank by hours, songs by plays, as in the report.
	p.Artists = rank(artists, listArtists, byHours, func(k string) (string, string) { return k, "" })
	p.Tracks = rank(tracks, listTracks, byPlays, func(k [2]string) (string, string) { return k[1], k[0] })
	p.Albums = rank(albums, listAlbums, byHours, func(k [2]string) (string, string) { return k[1], k[0] })

	ys := make([]int, 0, len(years))
	for y := range years {
		ys = append(ys, y)
	}
	sort.Ints(ys)
	for _, y := range ys {
		v := years[y]
		p.Years = append(p.Years, yearRow{y, hours(v[0].before.ms), hours(v[1].before.ms), hours(v[0].after.ms), hours(v[1].after.ms)})
	}
	p.Top1Share, p.Top10Share = concentration(artists, all, 1), concentration(artists, all, 10)

	if focus != "" {
		f := &focusView{Artist: focus, Songs: rank(focusSongs, 1000, byPlays, func(k string) (string, string) { return k, focus })}
		for _, y := range ys {
			yt := yearTotal{Year: y}
			if v := focusYears[y]; v != nil {
				yt.Hours, yt.HoursBefore = hours(v.after.ms), hours(v.before.ms)
			}
			f.Years = append(f.Years, yt)
		}
		p.Focus = f
	}
	return p
}

func byHours(t tally) int64 { return t.ms }
func byPlays(t tally) int64 { return int64(t.plays) }

// rank lists the top n by the after totals, with each one's rank before.
func rank[K comparable](mp map[K]*pair, n int, metric func(tally) int64, name func(K) (string, string)) []ranked {
	keys := make([]K, 0, len(mp))
	for k := range mp {
		keys = append(keys, k)
	}
	order := func(side func(*pair) tally) []K {
		ks := append([]K(nil), keys...)
		sort.Slice(ks, func(i, j int) bool {
			a, b := metric(side(mp[ks[i]])), metric(side(mp[ks[j]]))
			if a != b {
				return a > b
			}
			ni, ai := name(ks[i])
			nj, aj := name(ks[j])
			return ni+"\x00"+ai < nj+"\x00"+aj
		})
		return ks
	}
	before := map[K]int{}
	for i, k := range order(func(p *pair) tally { return p.before }) {
		before[k] = i + 1
	}
	var out []ranked
	for i, k := range order(func(p *pair) tally { return p.after }) {
		if i >= n {
			break
		}
		v := mp[k]
		if v.after.plays == 0 && v.before.plays == 0 {
			continue
		}
		nm, ar := name(k)
		out = append(out, ranked{Name: nm, Artist: ar, Plays: v.after.plays, PlaysBefore: v.before.plays,
			Hours: hours(v.after.ms), HoursBefore: hours(v.before.ms), Rank: i + 1, RankBefore: before[k]})
	}
	return out
}

// concentration is the share of listening time on the top n artists.
func concentration(artists map[string]*pair, all pair, n int) share {
	top := func(side func(*pair) int64, total int64) float64 {
		vals := make([]int64, 0, len(artists))
		for _, v := range artists {
			vals = append(vals, side(v))
		}
		sort.Slice(vals, func(i, j int) bool { return vals[i] > vals[j] })
		var sum int64
		for i := 0; i < n && i < len(vals); i++ {
			sum += vals[i]
		}
		if total == 0 {
			return 0
		}
		return math.Round(float64(sum)/float64(total)*1000) / 10
	}
	return share{
		Before: top(func(p *pair) int64 { return p.before.ms }, all.before.ms),
		After:  top(func(p *pair) int64 { return p.after.ms }, all.after.ms),
	}
}
