#!/usr/bin/env python3
"""Leftover replay, step 5: tracklists for the shortlisted groups, from ListenBrainz.

The request the plugin would make: `/1/metadata/release_group/?release_group_mbids=
<csv>&inc=recording`, one group list per request (ListenBrainz has no mirror; this
is the public API, paced well inside its ~30 requests / 10 s).

Usage:  python3 tools/leftover/fetch_lb.py [holdout.json]
Output: sweep/leftover/lb.json   { rg-mbid: {release, tracks: [[name, ms], ...]} | null }
"""

import json
import os
import sys
import time
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DIR = os.path.join(REPO, "sweep", "leftover")
OUT = os.path.join(DIR, "lb.json")
URL = "https://api.listenbrainz.org/1/metadata/release_group/?release_group_mbids={}&inc=recording"
UA = "LMS-Discography-dev/0.56 ( https://github.com/SimonPArnold/LMS-Discography )"
BATCH = 25


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "leftovers.json"
    left = json.load(open(os.path.join(DIR, src)))
    want = sorted({c["mbid"] for x in left for c in x["cands"]})
    have = json.load(open(OUT)) if os.path.exists(OUT) else {}
    todo = [m for m in want if m not in have]
    print(f"{len(want)} groups, {len(todo)} to fetch")
    t0 = time.time()
    for i in range(0, len(todo), BATCH):
        batch = todo[i:i + BATCH]
        req = urllib.request.Request(URL.format(",".join(batch)), headers={"User-Agent": UA})
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    d = json.loads(r.read())
                break
            except Exception as e:
                print(f"  retry {attempt + 1}: {e}")
                time.sleep(5 * (attempt + 1))
        else:
            continue
        for m in batch:
            rec = (d.get(m) or {}).get("recording") or {}
            tracks = [[t.get("name", ""), t.get("length") or 0]
                      for med in rec.get("mediums") or [] for t in med.get("tracks") or []]
            have[m] = {"release": rec.get("release_mbid"), "tracks": tracks} if tracks else None
        time.sleep(0.5)
    json.dump(have, open(OUT, "w"))
    got = sum(1 for m in want if have.get(m))
    print(f"{got} of {len(want)} groups have a tracklist ({time.time() - t0:.0f} s) -> {OUT}")


if __name__ == "__main__":
    main()
