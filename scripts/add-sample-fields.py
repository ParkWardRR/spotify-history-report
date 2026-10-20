#!/usr/bin/env python3
"""Give the fictional sample export the identity/context fields newer Spotify
exports carry (spotify_track_uri, reason_*, shuffle, offline, conn_country),
derived deterministically from each record so the output is reproducible.

    python3 -I scripts/add-sample-fields.py sample/Streaming_History_Audio_2020-2024.json

The URIs are fabricated: base62 of a hash of "artist|track", never real ids.
"""
import hashlib, json, sys

B62 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

def fake_id(artist: str, track: str) -> str:
    n = int.from_bytes(hashlib.sha256(f"{artist}|{track}".encode()).digest()[:16], "big")
    out = ""
    while len(out) < 22:
        n, r = divmod(n, 62)
        out += B62[r]
    return out

def pick(seed: str, options):
    h = int.from_bytes(hashlib.sha256(seed.encode()).digest()[:4], "big")
    return options[h % len(options)]

def main(path: str) -> None:
    with open(path) as f:
        records = json.load(f)
    for r in records:
        track = r.get("master_metadata_track_name")
        artist = r.get("master_metadata_album_artist_name")
        seed = f'{r["ts"]}|{artist}|{track}'
        r["conn_country"] = "US"
        r["spotify_track_uri"] = f"spotify:track:{fake_id(artist, track)}" if track and artist else None
        r["reason_start"] = pick(seed + "s", ["trackdone", "clickrow", "fwdbtn", "appload"])
        r["reason_end"] = "fwdbtn" if r.get("skipped") else pick(seed + "e", ["trackdone", "endplay"])
        r["shuffle"] = pick(seed + "h", [True, False])
        r["offline"] = False
    with open(path, "w") as f:
        json.dump(records, f, ensure_ascii=False)  # one line, as in the original

if __name__ == "__main__":
    main(sys.argv[1])
