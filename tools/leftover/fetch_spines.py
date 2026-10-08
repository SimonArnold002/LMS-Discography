#!/usr/bin/env python3
"""Leftover replay, step 3: each artist's MusicBrainz groups, from the MIRROR.

The mirror is a test accelerator only (no rate limit); the requests are the ones
the plugin makes on the public API:
  - the release-group browse with aliases (API::getReleaseGroups, 6 pages max),
  - the bootleg check BY ID (API::_officialById: `release-group?query=rgid:A OR ...`,
    100 to a request), which lists every group's releases: officialness, the
    release -> group map that places an id-tagged copy, and the official edition
    titles (Browse::_editionTitles).

The artist is the July sweep's (tag, else the name it resolved); an artist new
since July is looked up by exact name.

Usage:  python3 tools/leftover/fetch_spines.py
Output: sweep/leftover/spines.json   (resumable: artists already fetched are kept)
"""

import json
import os
import subprocess
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

MB = os.environ.get("DSC_MB", "http://plex:5000/ws/2/")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DIR = os.path.join(REPO, "sweep", "leftover")
OUT = os.path.join(DIR, "spines.json")
MAX_RG = 600


def get(url):
    r = subprocess.run(["curl", "-s", "-m", "60", url], capture_output=True, text=True)
    try:
        return json.loads(r.stdout)
    except Exception:
        return {}


def by_name(name):
    q = urllib.parse.quote(f'artist:"{name}"')
    for a in get(f"{MB}artist?query={q}&fmt=json&limit=5").get("artists") or []:
        if a.get("name", "").lower() == name.lower() and int(a.get("score", 0)) >= 90:
            return a["id"]
    return None


def spine(mbid):
    rgs, off = [], 0
    while True:
        p = get(f"{MB}release-group?artist={mbid}&limit=100&offset={off}&fmt=json&inc=aliases")
        got = p.get("release-groups") or []
        for x in got:
            rgs.append({
                "mbid": x["id"],
                "title": x["title"],
                "type": x.get("primary-type") or "",
                "secondary": x.get("secondary-types") or [],
                "date": x.get("first-release-date") or "",
                "aliases": [a["name"] for a in (x.get("aliases") or []) if a.get("name")],
            })
        off += 100
        if off >= p.get("release-group-count", 0) or not got or off >= MAX_RG:
            break
    official, rel, ed = {}, {}, {}
    ids = [g["mbid"] for g in rgs]
    for i in range(0, len(ids), 100):
        batch = ids[i:i + 100]
        q = " OR ".join(f"rgid:{x}" for x in batch)
        safe = "".join(c if c.isalnum() or c == "-" else "%%%02X" % ord(c) for c in q)
        d = get(f"{MB}release-group?query={safe}&limit={len(batch)}&fmt=json")
        for g in d.get("release-groups") or []:
            gid = g.get("id", "").lower()
            rels = g.get("releases") or []
            if not rels:
                continue
            anyoff = False
            for r in rels:
                st = r.get("status")
                o = st is None or st.lower() == "official"
                anyoff = anyoff or o
                if r.get("id"):
                    rel[r["id"].lower()] = gid
                if o and r.get("title"):
                    ed.setdefault(gid, set()).add(r["title"])
            if anyoff:
                official[gid] = 1
            elif g.get("count") is None or g["count"] <= len(rels):
                official.setdefault(gid, 0)
    return {"rgs": rgs, "official": official, "rel": rel,
            "editions": {k: sorted(v) for k, v in ed.items()}}


def main():
    lib = json.load(open(os.path.join(DIR, "library.json")))
    tags = json.load(open(os.path.join(DIR, "july_tags.json")))
    have = json.load(open(OUT)) if os.path.exists(OUT) else {}
    who = {}
    for a in lib["artists"]:
        t = tags.get(a["name"])
        who[a["name"]] = (t or {}).get("artist_mbid")
    new = [n for n, m in who.items() if not m]
    with ThreadPoolExecutor(4) as ex:
        for n, m in zip(new, ex.map(by_name, new)):
            who[n] = m
    print(f"{len(who)} artists, {sum(1 for m in who.values() if m)} with an mbid "
          f"({len(new)} looked up by name now)")
    todo = sorted({m for m in who.values() if m and m not in have})
    print(f"{len(todo)} spines to fetch")
    done = 0
    with ThreadPoolExecutor(4) as ex:
        for m, s in zip(todo, ex.map(spine, todo)):
            have[m] = s
            done += 1
            if done % 50 == 0:
                print(f"  {done}/{len(todo)}", flush=True)
                json.dump(have, open(OUT, "w"))
    json.dump({**have, "_who": who}, open(OUT, "w"))
    print(f"-> {OUT}")


if __name__ == "__main__":
    main()
