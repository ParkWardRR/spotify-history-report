#!/usr/bin/env bash
# End-to-end check of a built binary against the fictional sample export.
#
#   scripts/smoke.sh ./spotify-history-report
#
# The pipeline requires an LLM key, so this uses a throwaway key together with a
# pre-filled genre cache: every artist is already classified, so no request is
# ever made. It then checks the report that comes out.
set -euo pipefail

BIN="$(cd "$(dirname "${1:?usage: smoke.sh <binary>}")" && pwd)/$(basename "$1")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir "$WORK/data"
cp "$ROOT"/sample/Streaming_History_Audio_*.json "$WORK/data/"
python3 -I - "$WORK/data" <<'PY'
import glob, json, sys
d = sys.argv[1]
artists = set()
for f in glob.glob(f"{d}/Streaming_History_Audio_*.json"):
    artists |= {r["master_metadata_album_artist_name"] for r in json.load(open(f))
                if r.get("master_metadata_album_artist_name")}
json.dump({a: "Rock" for a in sorted(artists)}, open(f"{d}/.genre_cache.json", "w"))
PY

run() { ANTHROPIC_API_KEY=smoke "$BIN" "$WORK/data" --plain --timezone "$1" -o "$2" 2>&1; }

run America/Los_Angeles "$WORK/a.html" | sed 's/\x1b\[[0-9;]*m//g' | tee "$WORK/a.log"
run America/Los_Angeles "$WORK/b.html" >/dev/null
run Europe/Berlin "$WORK/c.html" >/dev/null

fail() { echo "smoke: FAIL: $*" >&2; exit 1; }

grep -q "Report ready" "$WORK/a.log" || fail "pipeline did not finish"
grep -q "America/Los_Angeles" "$WORK/a.log" || fail "timezone not reported"
cmp -s "$WORK/a.html" "$WORK/b.html" || fail "two runs of the same export differ"
cmp -s "$WORK/a.html" "$WORK/c.html" && fail "changing --timezone did not change the report"

python3 -I - "$WORK/a.html" <<'PY'
import json, re, sys
html = open(sys.argv[1]).read()
m = re.search(r"const DATA\s*=\s*(\{.*?\});\s*\n", html, re.S)
assert m, "no DATA blob in report"
d = json.loads(m.group(1))
assert d["total_plays"] > 1000, d["total_plays"]
assert d["timezone"] == "America/Los_Angeles", d["timezone"]
for e in d["explore_obsess"]:
    assert e["new_pct"] + e["top10_pct"] + e["rest_pct"] == 100, e
assert any(q["partial"] for q in d["genre_area"]) or not d["hours_subtitle"], "partial year not flagged"
print("smoke: ok")
PY
