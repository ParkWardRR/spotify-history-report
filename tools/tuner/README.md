# tuner

Local slider UI for the `downweight` rules in `.shr/overrides.json`. Drag a slider and the top 25 artists and songs re-rank live; **Save** writes the rules back, and the next report run applies them.

```
go build .
./tuner -data ~/Downloads/my_spotify_data
# open http://127.0.0.1:8235/
```

| Flag    | Default | Description                                         |
|---------|---------|-----------------------------------------------------|
| `-data` | `.`     | Folder with the history JSON files and `.shr/`      |
| `-port` | `8235`  | HTTP listen port (bound to 127.0.0.1)               |

## What it shows

- One card per rule: a slider (share of plays removed) and the result, e.g. *drops 3,018 of 10,061 plays · 551 → 386 h*. A rule that matches nothing says so.
- Add a rule by picking an artist or a song from the search box. A song rule beats its artist's rule for that song.
- Top artists by hours and top songs by plays after the rules, with the rank change and the old value.

The preview drops exactly the plays the report drops: the same hash (FNV-1a 64 + MurmurHash3 finalizer over `ts␟artist␟track␟ms`) and the same exact cutoff, pinned by matching tests on both sides. It counts songs by exact artist and title, so a song the report splits into versions (single vs album) can show a higher count here than in the report.

## Saving

Only the `downweight` key is rewritten; every other key, its order and its formatting stay as they were (one rule per line, so diffs stay small). Saving with no rules removes the key. Writes are atomic.

## Safety

Same as `tools/review-server`: bound to `127.0.0.1`, refuses foreign `Host` headers (DNS rebinding), cross-site `Origin`s and non-JSON `POST`s, limits bodies to 1 MiB, and rejects unknown fields and out-of-range shares. No login; do not expose it.
