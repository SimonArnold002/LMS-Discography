#!/usr/bin/env python3
"""Leftover replay, step 1: the CURRENT library, read the way localAlbums reads it.

For every album artist: the albums LMS lists under the artist's own id with the
performance roles (Sources::PERFORMANCE_ROLES), and which of them are CREDITED to
the artist (role ALBUMARTIST,BAND - the 0.56.43 `_otherArtist` test). Then every
track with its album id, number, disc and duration, for the track comparison.

The CLI exposes no MusicBrainz id (album or contributor); step 2
(july_tags.py) takes the tags from the July sweep's debug logs instead.

Usage:  python3 tools/leftover/fetch_library.py
Output: sweep/leftover/library.json
"""

import json
import os
import urllib.request
from concurrent.futures import ThreadPoolExecutor

LMS = os.environ.get("DSC_LMS", "http://plex:9000/jsonrpc.js")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(REPO, "sweep", "leftover", "library.json")
ROLES = "ARTIST,ALBUMARTIST,BAND,TRACKARTIST"


def q(params):
    body = json.dumps({"id": 1, "method": "slim.request", "params": ["", params]}).encode()
    req = urllib.request.Request(LMS, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())["result"]


def artist_albums(a):
    rows = q(["albums", 0, 500, f"artist_id:{a['id']}", f"role_id:{ROLES}", "tags:ljyaWS"]).get("albums_loop", [])
    cred = q(["albums", 0, 500, f"artist_id:{a['id']}", "role_id:ALBUMARTIST,BAND", "tags:l"]).get("albums_loop", [])
    credited = {x["id"] for x in cred if x.get("id")}
    albums = []
    for e in rows:
        if not e.get("id") or e.get("album") is None:
            continue
        ids = str(e.get("artist_id", "")).split(",")
        albums.append({
            "id": e["id"],
            "title": e["album"],
            "artist": e.get("artist") or a["artist"],
            "year": e.get("year") or 0,
            "release_type": e.get("release_type"),
            "other": not (e["id"] in credited or str(a["id"]) in ids),
        })
    return {"id": a["id"], "name": a["artist"], "albums": albums}


def main():
    arts = q(["artists", 0, 10000, "role_id:ALBUMARTIST"]).get("artists_loop", [])
    print(f"{len(arts)} album artists")
    with ThreadPoolExecutor(6) as ex:
        artists = list(ex.map(artist_albums, arts))

    tracks = {}
    off, step = 0, 5000
    while True:
        r = q(["titles", off, step, "tags:edti"])
        loop = r.get("titles_loop", [])
        for t in loop:
            aid = str(t.get("album_id", ""))
            if not aid:
                continue
            tracks.setdefault(aid, []).append({
                "title": t.get("title", ""),
                "dur": float(t.get("duration") or 0),
                "disc": int(t.get("disc") or 1),
                "num": int(str(t.get("tracknum") or 0).split("/")[0] or 0),
            })
        off += step
        if off >= r.get("count", 0) or not loop:
            break
    for v in tracks.values():
        v.sort(key=lambda t: (t["disc"], t["num"]))

    n_alb = sum(len(a["albums"]) for a in artists)
    print(f"{n_alb} artist-album rows, {sum(len(v) for v in tracks.values())} tracks on {len(tracks)} albums")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump({"artists": artists, "tracks": tracks}, open(OUT, "w"))
    print(f"-> {OUT}")


if __name__ == "__main__":
    main()
