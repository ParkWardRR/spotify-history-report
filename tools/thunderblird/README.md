# thunderblird

Go tool that classifies artists by querying the Last.fm `artist.getTopTags` API and mapping tags to the report's genre vocabulary.

## Genres

Output uses the same genre set as the Odin report:

> Hip-hop & Rap, Indie pop, Funk & Soul, Electronic, Rock, R&B, Jazz, Latin, Classical, Pop, Country, Metal, World, Other

## Usage

```
export LASTFM_API_KEY=your_key_here

go run . -data /path/to/spotify_cleaned
```

Or pass the key directly:

```
go run . -api-key YOUR_KEY -data /path/to/spotify_cleaned
```

## Flags

| Flag            | Default                   | Description                                       |
|-----------------|---------------------------|---------------------------------------------------|
| `-api-key`      | `$LASTFM_API_KEY`         | Last.fm API key                                   |
| `-data`         | `/tmp/spotify_cleaned`    | Directory with `Streaming_History_Audio_*.json`    |
| `-db`           | `artists.db`              | bbolt cache database                              |
| `-out`          | `genre_map.json`          | Output genre map (artist -> genre)                |
| `-annotations`  | `annotations.json`        | Output in `.shr/annotations.json` format          |
| `-workers`      | `4`                       | Concurrent Last.fm workers                        |
| `-refresh`      | `false`                   | Re-query all artists (ignore cache)               |

## Output

**genre_map.json** -- flat `{"Artist Name": "Genre"}` map for the Odin pipeline.

**annotations.json** -- structured annotations compatible with the `.shr/` schema:

```json
{
  "schema_version": 1,
  "annotations": [
    {
      "artist": "Name",
      "title": "",
      "namespace": "genre",
      "value": "Rock",
      "source": "lastfm",
      "model": "artist.getTopTags",
      "confidence": null,
      "observed": "2026-10-19"
    }
  ]
}
```

## Design

- Weighted tag voting: top Last.fm tags get higher weight, mapped to the report genre vocabulary
- bbolt persistent cache survives interrupted runs
- Overall rate limiter at ~3.5 req/sec to stay within Last.fm limits
- Per-worker retry on 429 responses
