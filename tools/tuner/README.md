# tuner

Local slider UI for the `downweight` rules in `.shr/overrides.json`. Every top artist, song, album and year has its own slider; the whole library re-ranks live as you drag. **Save** writes the rules back, and the next report run applies them.

```
go build .
./tuner -data ~/Downloads/my_spotify_data
# open http://127.0.0.1:8235/
```

| Flag    | Default | Description                                         |
|---------|---------|-----------------------------------------------------|
| `-data` | `.`     | Folder with the history JSON files and `.shr/`      |
| `-port` | `8235`  | HTTP listen port (bound to 127.0.0.1)               |

## What it does

| Area | What you get |
|---|---|
| Header | Plays, hours, the #1 artist's share and the top 10's share of all listening, each with its value before any rules. Undo/redo (⌘Z / ⇧⌘Z), Revert, Save (⌘S). |
| Artists / Songs / Albums tabs | Top 300 by hours (songs by plays). Each row: rank and rank change, a slider for its own rule, what it inherits from a broader rule, and the value now vs before. Filter by name, show 50/100/300, or only rows with rules. Dragging a slider to 0 removes the rule. |
| Artist drill-down | Click an artist: hours per year (click a year to add a rule for just that year) and every song with its own slider. |
| Years tab | Hours per year split Spotify / Apple Music, outlined at the before-rules height, and a slider per year (a window-only rule, so it covers what no artist, song or album rule covers). |
| Rules list | Every rule with its exact effect (*drops 3,018 of 10,061 plays · 551 → 386 h*), its share, an optional date window, and a warning when it matches nothing. Add any artist, song or album from the search box. |
| Bulk tools | **Cap artists** at N hours, **cap songs** at N plays, or **compress the head**: shrink the gap between the top N artists and the rest while keeping their order. Each one writes ordinary rules you can then adjust; applying one twice gives the same rules. |

The preview drops exactly the plays the report drops: the same hash (FNV-1a 64 + MurmurHash3 finalizer over `ts␟artist␟track␟ms`), the same exact cutoff, the same most-specific-rule matching. Matching tests on both sides pin this. Songs are counted by exact artist and title, so a song the report splits into versions (single vs album) can show a higher count here than in the report.

## Saving

Only the `downweight` key is rewritten; every other key, its order and its formatting stay as they were (one rule per line, so diffs stay small). Saving with no rules removes the key. Writes are atomic, and the rules are checked against the report's own validation first, so a saved file never stops a run.

## Safety

Same as `tools/review-server`: bound to `127.0.0.1`, refuses foreign `Host` headers (DNS rebinding), cross-site `Origin`s and non-JSON `POST`s, limits bodies to 1 MiB, and rejects unknown fields, bad dates and out-of-range shares. No login; do not expose it.
