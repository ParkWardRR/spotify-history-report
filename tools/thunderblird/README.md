# thunderblird

Optional helper that classifies the artists in your Spotify export by their
[Last.fm](https://www.last.fm/api/show/artist.getTopTags) top tags and records
the answers as `lastfm` annotations in the report's `.shr/annotations.json`.

The report works without it. Run it once and the next report run picks the
answers up (precedence: `user` > `musicbrainz` > `sidecar` > `lastfm` > `llm`,
so your own corrections always win and Last.fm outranks an LLM guess).

## Privacy

It sends **artist names only** to `ws.audioscrobbler.com`: no plays, no times,
no counts. Artists listed in `exclude_artists` in `<data>/.shr/overrides.json`
are never sent. `-dry-run` prints how many names would be sent and stops
before any network use.

## Usage

```sh
export LASTFM_API_KEY=your_key_here          # https://www.last.fm/api/account/create

go run . -data ~/Downloads/my_spotify_data -dry-run   # how many names would leave?
go run . -data ~/Downloads/my_spotify_data
```

Then `./spotify-history-report ~/Downloads/my_spotify_data` as usual.

## Flags

| Flag            | Default                       | Description |
|-----------------|-------------------------------|-------------|
| `-data`         | *(required)*                  | Folder with `Streaming_History_Audio_*.json` |
| `-api-key`      | `$LASTFM_API_KEY`             | Last.fm API key (only needed when there is something to ask) |
| `-annotations`  | `<data>/.shr/annotations.json`| Store to merge into |
| `-db`           | `<data>/.shr/lastfm.db`       | bbolt cache, so an interrupted run resumes |
| `-out`          | *(off)*                       | Also write a flat `{artist: genre}` map (legacy; the report does not read it) |
| `-refresh`      | `false`                       | Ask about every artist again, ignoring the cache |
| `-dry-run`      | `false`                       | Report what would be sent, then stop |
| `-workers`      | `4`                           | Concurrent requests (overall rate is capped at ~3.5/s) |

## How it behaves

- **Merges, never replaces.** Only artist-level `genre` records that Last.fm
  itself wrote for artists in this export are replaced. User, LLM and every other
  source, plus any field this tool does not know about, are left exactly as
  found. An unreadable store, or one with a different `schema_version`, stops the
  run instead of being overwritten.
- **Unknown is not "Other".** If none of an artist's tags maps to a genre, or
  Last.fm does not know the artist, nothing is written and the artist stays
  *Unclassified* in the report. "Other" is written only when a tag really means
  it (comedy, spoken word, ...).
- **Failures are not answers.** Network errors and persistent rate limiting are
  skipped and not cached; the next run asks again. A request is retried once on
  a 429.
- **Deterministic.** Tags are voted by rank (the first tag weighs 10, down to 1);
  ties go to the alphabetically first genre, so a rerun never changes an answer.
- **The key stays out of logs.** Errors report the cause, not the request URL.

## Genres

Output uses the report's 14 labels: Hip-hop & Rap, Indie pop, Funk & Soul,
Electronic, Rock, R&B, Jazz, Latin, Classical, Pop, Country, Metal, World, Other.
A test fails if the tag table ever produces anything else.

## Development

```sh
go vet ./... && go test -race ./...
```
