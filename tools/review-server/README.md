# review-server

Go HTTP server for reviewing artists flagged as belonging to another listener on a shared Spotify account. Serves self-contained review HTML pages, collects keep/remove decisions, and exports an `exclude_artists` list compatible with `.shr/overrides.json`.

## Usage

```
go build .
./review-server -dir ./reviews -out ./decisions -port 8234
```

### Flags

| Flag    | Default | Description                              |
|---------|---------|------------------------------------------|
| `-port` | `8234`  | HTTP listen port (bound to 127.0.0.1)    |
| `-dir`  | `.`     | Directory containing `review_*.html` files |
| `-out`  | `.`     | Directory for saved decision JSON files   |

## Safety

It binds to `127.0.0.1` only. Because any web page can send requests to localhost, it also:

- refuses requests whose `Host` is not `127.0.0.1` / `localhost` (DNS rebinding);
- refuses `POST`s whose `Origin` is another site, and any `POST` that is not `application/json`;
- accepts a decision `type` only as a short slug (`A-Za-z0-9_-`, 1-64 characters) because it becomes a file name;
- limits request bodies to 1 MiB and writes decisions atomically.

There is no login. Do not put it behind a reverse proxy or bind it to a network address.

## Review HTML files

Place self-contained HTML files named `review_<label>.html` in the review directory. Each file should contain artist data and a toggle UI that POSTs decisions back to the server. The index page automatically lists all `review_*.html` files found in `-dir`.

## API

### `POST /api/save`

Save keep/remove decisions for a review category.

**Request body:**

```json
{
  "type": "genre_outliers",
  "remove": ["Artist A", "Artist B"],
  "keep": ["Artist C"]
}
```

**Response:**

```json
{
  "status": "saved",
  "file": "./decisions/genre_outliers_decisions.json"
}
```

Each call writes `<type>_decisions.json` to the output directory. Names are trimmed and de-duplicated; a name in both `remove` and `keep` is a `400`.

### `GET /api/export-overrides`

Aggregates all `*_decisions.json` files in the output directory and returns a combined overrides object:

```json
{
  "version": 1,
  "exclude_artists": ["Artist A", "Artist B"]
}
```

The list is sorted, has no duplicates and is `[]` (never `null`) when nothing was removed, so the same decisions always give the same bytes. Save the output as `.shr/overrides.json` in your data folder (merge by hand if you already have merges or annotations there) and the next report run drops those artists:

```sh
curl -s localhost:8234/api/export-overrides > ~/Downloads/my_spotify_data/.shr/overrides.json
```

## Development

```sh
go vet ./... && go test -race ./...
```
