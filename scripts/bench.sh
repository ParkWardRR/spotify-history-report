#!/usr/bin/env bash
# Times the whole pipeline on synthetic histories of increasing size.
#
#   scripts/bench.sh ./spotify-history-report [sizes...]     (default: 100000 500000 2000000)
#
# The data is generated, not real: ~8 years of plays over a catalogue that grows
# with the history, a few percent short listens, a third of the `skipped` flags
# null. It measures this tool on this machine, nothing more.
set -euo pipefail

BIN="$(cd "$(dirname "${1:?usage: bench.sh <binary> [sizes...]}")" && pwd)/$(basename "$1")"
shift || true
SIZES=("${@:-100000 500000 2000000}")
[ $# -eq 0 ] && SIZES=(100000 500000 2000000)
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if /usr/bin/time -l true >/dev/null 2>&1; then
	timer() { /usr/bin/time -l "$@" 2>&1 >/dev/null | awk '/maximum resident/ {printf "%.0f", $1/1048576}'; }
else
	timer() { /usr/bin/time -v "$@" 2>&1 >/dev/null | awk -F': ' '/Maximum resident/ {printf "%.0f", $2/1024}'; }
fi

printf '%-12s %-10s %-10s %-10s\n' rows json_MB seconds peak_MB
for n in "${SIZES[@]}"; do
	dir="$WORK/$n"; mkdir -p "$dir"
	python3 -I - "$n" "$dir" <<'PY'
import json, random, sys
from datetime import datetime, timedelta, timezone
n, out = int(sys.argv[1]), sys.argv[2]
rnd = random.Random(7)
tracks = max(200, n // 40)
start = datetime(2018, 1, 1, tzinfo=timezone.utc)
span = 8 * 365 * 24 * 3600
rows, t = [], 0
per_file = 100_000
fno = 0
for i in range(n):
    t = (i * span) // n + rnd.randrange(0, 600)
    k = int(tracks * (rnd.random() ** 2.2))
    short = rnd.random() < 0.06
    flag = rnd.choice([True, False, None])
    rows.append({
        "ts": (start + timedelta(seconds=t)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ms_played": rnd.randrange(1000, 29000) if short else rnd.randrange(60000, 360000),
        "master_metadata_track_name": f"Track {k}",
        "master_metadata_album_artist_name": f"Artist {k // 9}",
        "master_metadata_album_album_name": f"Album {k // 12}",
        "spotify_track_uri": f"spotify:track:{k:022d}",
        "platform": "synthetic", "skipped": flag, "reason_end": "trackdone",
    })
    if len(rows) == per_file:
        json.dump(rows, open(f"{out}/Streaming_History_Audio_{fno:03d}.json", "w")); rows = []; fno += 1
if rows:
    json.dump(rows, open(f"{out}/Streaming_History_Audio_{fno:03d}.json", "w"))
PY
	mb=$(du -sm "$dir" | cut -f1)
	t0=$(python3 -c 'import time; print(time.time())')
	rss=$(timer env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u OPENROUTER_API_KEY HOME="$WORK/h" "$BIN" "$dir" --plain --timezone UTC -o "$WORK/out.html")
	t1=$(python3 -c 'import time; print(time.time())')
	printf '%-12s %-10s %-10.1f %-10s\n' "$n" "$mb" "$(python3 -c "print($t1-$t0)")" "$rss"
done
