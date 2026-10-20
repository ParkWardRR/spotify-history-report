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

Each call writes `<type>_decisions.json` to the output directory.

### `GET /api/export-overrides`

Aggregates all `*_decisions.json` files in the output directory and returns a combined overrides object:

```json
{
  "version": 1,
  "exclude_artists": ["Artist A", "Artist B"]
}
```

Pipe the output to `.shr/overrides.json` to feed it back into report generation with `exclude_artists` filtering.
