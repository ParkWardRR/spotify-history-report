#!/usr/bin/env bash
# End-to-end check of a built binary against the fictional sample export.
#
#   scripts/smoke.sh ./spotify-history-report
#
# Every artist is pre-classified through a legacy genre cache, so no LLM key is
# needed and no request is ever made. It then checks the report that comes out.
set -euo pipefail
fail() { echo "smoke: FAIL: $*" >&2; exit 1; }

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

# No key on purpose: a fully annotated history must not need one.
run() { env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u OPENROUTER_API_KEY HOME="$WORK/home" "$BIN" "$WORK/data" --plain --timezone "$1" -o "$2" 2>&1; }

run America/Los_Angeles "$WORK/a.html" | sed 's/\x1b\[[0-9;]*m//g' | tee "$WORK/a.log"
run America/Los_Angeles "$WORK/b.html" >/dev/null
run Europe/Berlin "$WORK/c.html" >/dev/null

# A history with no genres and no key must still produce a report.
mkdir "$WORK/bare"
cp "$ROOT"/sample/Streaming_History_Audio_*.json "$WORK/bare/"
env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u OPENROUTER_API_KEY HOME="$WORK/home" "$BIN" "$WORK/bare" --plain -o "$WORK/bare.html" >"$WORK/bare.log" 2>&1 \
	|| { cat "$WORK/bare.log"; echo "smoke: FAIL: report without genres or a key" >&2; exit 1; }
grep -q "enrichment off" "$WORK/bare.log" || { echo "smoke: FAIL: enrichment-off not reported" >&2; exit 1; }
# A key in the environment is not consent: without --enrich nothing may be sent.
ANTHROPIC_API_KEY=sk-ant-invalid HOME="$WORK/home" "$BIN" "$WORK/bare" --plain -o "$WORK/bare2.html" >"$WORK/bare2.log" 2>&1
grep -q "enrichment off" "$WORK/bare2.log" \
	|| { echo "smoke: FAIL: a key alone enabled enrichment" >&2; exit 1; }

# The ZIP as Spotify sends it (deflate, nested folder, a PDF and macOS noise) must give the same report as the folder.
mkdir "$WORK/pkg" "$WORK/zipdir"
python3 -I - "$ROOT" "$WORK/zipdir/my_spotify_data.zip" <<'PY'
import glob, sys, zipfile
root, out = sys.argv[1:3]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted(glob.glob(f"{root}/sample/Streaming_History_Audio_*.json")):
        z.write(f, "Spotify Extended Streaming History/" + f.rsplit("/", 1)[1])
    z.writestr("Spotify Extended Streaming History/ReadMeFirst.pdf", b"%PDF-1.4 not json")
    z.writestr("Spotify Extended Streaming History/Playlist1.json", '{"playlists": []}')
    z.writestr("__MACOSX/Spotify Extended Streaming History/._Streaming_History_Audio_2020-2024.json", b"\0\0junk")
PY
env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u OPENROUTER_API_KEY HOME="$WORK/home" "$BIN" "$WORK/zipdir/my_spotify_data.zip" --plain --timezone America/Los_Angeles -o "$WORK/z.html" >"$WORK/z.log" 2>&1 \
	|| { cat "$WORK/z.log"; echo "smoke: FAIL: ZIP input" >&2; exit 1; }
grep -q "1 other JSON file ignored" "$WORK/z.log" || { cat "$WORK/z.log"; echo "smoke: FAIL: ZIP import notes missing" >&2; exit 1; }
[ ! -e "$WORK/zipdir/Spotify Extended Streaming History" ] || { echo "smoke: FAIL: ZIP was extracted to disk" >&2; exit 1; }
env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u OPENROUTER_API_KEY HOME="$WORK/home" "$BIN" "$WORK/bare" --plain --timezone America/Los_Angeles -o "$WORK/f.html" >/dev/null 2>&1
# Same data; only the import description (ZIP vs folder, ignored files) may differ.
python3 -I - "$WORK/z.html" "$WORK/f.html" <<'PY' || fail "ZIP and folder give different reports"
import json, re, sys
def data(p):
    d = json.loads(re.search(r"const DATA\s*=\s*(\{.*?\});\s*\n", open(p).read(), re.S).group(1))
    imp = d.pop("import")
    return d, imp
(a, ia), (b, ib) = data(sys.argv[1]), data(sys.argv[2])
assert a == b, "reports differ beyond the import summary"
assert ia["source"] == "ZIP" and ib["source"] == "folder", (ia["source"], ib["source"])
assert ia["files_ignored"] == 1 and ib["files_ignored"] == 0, (ia, ib)
PY

# Hostile metadata must not escape the embedded data or the page.
mkdir "$WORK/evil"
python3 -I - "$ROOT" "$WORK/evil" <<'PY'
import glob, json, sys
root, out = sys.argv[1:3]
for f in glob.glob(f"{root}/sample/Streaming_History_Audio_*.json"):
    rows = json.load(open(f))
    for r in rows:
        if r.get("master_metadata_album_artist_name") == "Bronze Atlas":
            r["master_metadata_album_artist_name"] = "</script><img src=x onerror=alert(1)>\u2028\x01"
            r["master_metadata_track_name"] = "<b>\"quoted\"</b> & \\"
    json.dump(rows, open(out + "/Streaming_History_Audio_evil.json", "w"))
PY
env -u ANTHROPIC_API_KEY HOME="$WORK/home" "$BIN" "$WORK/evil" --plain --timezone UTC -o "$WORK/evil.html" >/dev/null 2>&1 || fail "report with hostile metadata"
python3 -I - "$WORK/evil.html" "$WORK/bare.html" <<'PY'
import json, re, sys
evil, ok = (open(p).read() for p in sys.argv[1:3])
assert evil.count("</script>") == ok.count("</script>"), "imported text closed a script element"
assert "<img src=x" not in evil, "markup from the export reached the page unescaped"
d = json.loads(re.search(r"const DATA\s*=\s*(\{.*?\});\s*\n", evil, re.S).group(1))
assert any("</script>" in a["name"] for a in d["top_artists"]), "hostile name lost"
PY

# A non-history input fails with a plain message and a non-zero exit.
echo '{"x":1}' > "$WORK/Other.json"
if "$BIN" "$WORK/Other.json" --plain -o "$WORK/no.html" >"$WORK/no.log" 2>&1; then echo "smoke: FAIL: non-history input accepted" >&2; exit 1; fi
grep -q "None of the JSON files" "$WORK/no.log" || { cat "$WORK/no.log"; echo "smoke: FAIL: no explanation for non-history input" >&2; exit 1; }


grep -q "Report ready" "$WORK/a.log" || fail "pipeline did not finish"
grep -q "America/Los_Angeles" "$WORK/a.log" || fail "timezone not reported"
cmp -s "$WORK/a.html" "$WORK/b.html" || fail "two runs of the same export differ"
cmp -s "$WORK/a.html" "$WORK/c.html" && fail "changing --timezone did not change the report"

[ -s "$WORK/data/.shr/identities.json" ] || fail "no .shr/identities.json written"
"$BIN" "$WORK/data" --identities > "$WORK/ids.txt" || fail "--identities failed"
grep -q "by Spotify URI" "$WORK/ids.txt" || fail "--identities printed no coverage"
[ -s "$WORK/data/.shr/annotations.json" ] || fail "legacy genre cache was not migrated to .shr/annotations.json"
grep -q "imported .genre_cache.json" "$WORK/a.log" || fail "migration not reported"
"$BIN" "$WORK/data" --annotations > "$WORK/ann.txt" || fail "--annotations failed"
grep -q "Genre coverage" "$WORK/ann.txt" || fail "--annotations printed no coverage"
"$BIN" "$WORK/data" --scores > "$WORK/scores.txt" || fail "--scores failed"
grep -q "Long-term favourites" "$WORK/scores.txt" || fail "--scores printed no views"
grep -q "Not informative here" "$WORK/scores.txt" || fail "--scores should flag the degenerate sample evaluation"
"$BIN" "$WORK/data" --scores --decay 9 >/dev/null 2>&1 && fail "--decay 9 should be rejected"

python3 -I - "$WORK/a.html" "$WORK/data/.shr/identities.json" <<'PY'
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
ids = json.load(open(sys.argv[2]))
assert ids["schema_version"] == 1 and ids["summary"]["plays_metadata_only"] == 0, ids["summary"]
assert d["identity"]["plays_by_uri"] == d["total_plays"], d["identity"]
sc = d["scores"]
assert sc["favourites"]["items"] and sc["warm"]["items"], "behaviour views are empty"
assert all(k in sc["favourites"] for k in ("why", "items")), sc["favourites"].keys()
assert d["genre_unclassified_pct"] == 0 and d["genre_source_pct"]["llm"] == 100.0, (d["genre_unclassified_pct"], d["genre_source_pct"])
assert "Unclassified" not in d["genre_order"], "no Unclassified series when everything is annotated"
print("smoke: ok")
PY
