package main

import (
	"sort"
	"strings"
)

// The Odin report's fixed genre vocabulary (src/stats.odin). Anything else is
// rejected by the report, so the table below must only produce these.
var reportGenres = []string{
	"Hip-hop & Rap", "Indie pop", "Funk & Soul", "Electronic", "Rock", "R&B", "Jazz",
	"Latin", "Classical", "Pop", "Country", "Metal", "World", "Other",
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

// classify turns an artist's top tags (most popular first) into one report
// genre by weighted vote. It returns ok=false when no tag maps to a genre: that
// is "unknown", which the report keeps distinct from the real label "Other".
// Ties go to the alphabetically first genre so a rerun never changes an answer.
func classify(tags []string) (genre string, ok bool) {
	votes := make(map[string]int)
	for i, tag := range tags {
		g, known := tagToGenre[strings.ToLower(strings.TrimSpace(tag))]
		if !known {
			continue
		}
		votes[g] += max(10-i, 1)
	}
	if len(votes) == 0 {
		return "", false
	}
	names := make([]string, 0, len(votes))
	for g := range votes {
		names = append(names, g)
	}
	sort.Strings(names)
	best := names[0]
	for _, g := range names[1:] {
		if votes[g] > votes[best] {
			best = g
		}
	}
	return best, true
}
