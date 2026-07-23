#!/usr/bin/env python3
"""Fetch each artist's REAL MusicBrainz spine (release groups + aliases).

Feeds `tools/spine_match.pl`, which runs owned/candidate titles through the
plugin's OWN matcher against these spines -- so "no match" is the shipped
matcher's verdict rather than an inference about it.

Input is either the gap file written by `tools/gap_recompute.py`, or a plain
list of "Artist :: Album" lines, or artist names one per line (spine only).

Usage:
    python3 tools/spine_fetch.py --gaps sweep/gaps.json
    python3 tools/spine_fetch.py --artists "Kraftwerk,Pet Shop Boys"
    python3 tools/spine_fetch.py --pairs cases.txt          # "Artist :: Album"

Environment:
    DSC_MB         MusicBrainz ws/2 base  (default http://plex:5000/ws/2/)
    DSC_SWEEP_OUT  output directory       (default <repo>/sweep)

NOTE the artist here is resolved by a plain score-ranked MB search, which is
NOT what the plugin does (it prefers an exact name). Where they differ the
canonical name is printed, so a wrong entity is visible rather than silent --
and `tools/gap_recompute.py --who` shows what the plugin actually resolved.
"""

import argparse
import json
import os
import subprocess
import sys
import urllib.parse

MB = os.environ.get("DSC_MB", "http://plex:5000/ws/2/")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.environ.get("DSC_SWEEP_OUT", os.path.join(REPO, "sweep"))
DEST = os.path.join(OUT, "spines.json")

MAX_RG = 600          # 6 pages, the same ceiling API.pm uses (RG_MAX_PAGES)


def get(url):
    r = subprocess.run(["curl", "-s", "-m", "40", url], capture_output=True, text=True)
    try:
        return json.loads(r.stdout)
    except Exception:
        return {}


def spine_for(artist):
    q = urllib.parse.quote(f'artist:"{artist}"')
    d = get(f"{MB}artist?query={q}&fmt=json&limit=3")
    arts = d.get("artists") or []
    if not arts:
        return {"mbid": None, "name": None, "rgs": []}
    mbid, canon = arts[0]["id"], arts[0]["name"]
    rgs, off = [], 0
    while True:
        # inc=aliases matters: MB files some groups under the original-language
        # title and carries other spellings as aliases (0.48.0).
        p = get(f"{MB}release-group?artist={mbid}&limit=100&offset={off}"
                f"&fmt=json&inc=aliases")
        got = p.get("release-groups") or []
        rgs += [{"title": x["title"],
                 "mbid": x.get("id"),
                 "type": x.get("primary-type"),
                 "sec": x.get("secondary-types") or [],
                 "date": (x.get("first-release-date") or "")[:4],
                 "al": [a["name"] for a in (x.get("aliases") or [])]} for x in got]
        off += 100
        if off >= p.get("release-group-count", 0) or not got or off >= MAX_RG:
            break
    return {"mbid": mbid, "name": canon, "rgs": rgs}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--gaps", help="gaps.json from gap_recompute.py")
    g.add_argument("--artists", help="comma-separated artist names")
    g.add_argument("--pairs", help="file of 'Artist :: Album' lines")
    ap.add_argument("-o", "--out", default=DEST)
    args = ap.parse_args()

    cases = {}
    if args.gaps:
        for x in json.load(open(args.gaps)):
            if x.get("albums"):
                cases[x["artist"]] = x["albums"]
    elif args.artists:
        for a in args.artists.split(","):
            cases[a.strip()] = []
    else:
        for line in open(args.pairs):
            if "::" not in line:
                continue
            a, alb = (p.strip() for p in line.split("::", 1))
            cases.setdefault(a, []).append(alb)

    if not cases:
        sys.exit("nothing to fetch")
    out = {}
    for i, (artist, albums) in enumerate(sorted(cases.items()), 1):
        s = spine_for(artist)
        s["albums"] = albums
        out[artist] = s
        flag = "" if (s["name"] or "").lower() == artist.lower() else f"   (MB name: {s['name']})"
        print(f"{i:3}/{len(cases)} {artist[:28]:30} rgs={len(s['rgs']):4}{flag}", flush=True)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    json.dump(out, open(args.out, "w"))
    print(f"\n-> {args.out}")


if __name__ == "__main__":
    main()
