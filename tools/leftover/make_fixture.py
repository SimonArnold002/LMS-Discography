#!/usr/bin/env python3
"""Leftover replay, step 7: the parity fixture for tools/t_trackmatch.pl.

The plugin's track match (Sources::trackShortlist / trackEvidence / trackPick)
must reach the SAME verdict as the replay's rule v3 (tools/leftover/score.pl) on
the real cases it was measured on. This writes them, self-contained:
  - every owned album in "Also in your library" with a candidate (Simon's library
    + the tester's synthetic McCoy Tyner), and
  - every HOLDOUT case (real group hidden) that rule v1 or v3 matched, or sent to
    the manual list - the cases the rule exists to get right.
Each case: the owned title, artist, tracks [title, seconds], and up to 5
candidates { mbid, title (the title variant the replay judged it by), tracks
[name, seconds] or null }, with the replay's verdict (match mbid / manual / none).

Usage:  python3 tools/leftover/make_fixture.py
Output: tools/fixtures/trackmatch_replay.json
"""

import json
import os

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DIR = os.path.join(REPO, "sweep", "leftover")
OUT = os.path.join(REPO, "tools", "fixtures", "trackmatch_replay.json")


def load(name):
    return json.load(open(os.path.join(DIR, name)))


def expected(row):
    passing = sorted((c for c in row["scored"] if c.get("agree")), key=lambda c: -c["score"])
    if row["verdict"] == "MATCH":
        return {"verdict": "match", "mbid": passing[0]["mbid"]}
    return {"verdict": "manual" if passing else "none"}


def case(row, lib_tracks, lb, kind):
    return {
        "kind": kind,
        "artist": row["artist"],
        "title": row["title"],
        "own": [[t["title"], t["dur"]] for t in lib_tracks.get(str(row["album_id"]), [])],
        "cands": [{
            "mbid": c["mbid"],
            "title": c["variant"],
            "tracks": ([[n, (ms or 0) / 1000] for n, ms in lb[c["mbid"]]["tracks"]]
                       if lb.get(c["mbid"]) else None),
        } for c in row["scored"]],
        "expect": expected(row),
        **({"real": row["real"]} if row.get("real") else {}),
    }


def main():
    lib = load("library.json")["tracks"]
    syn = load("synthetic.json")
    lib.update(syn["tracks"])
    lb = load("lb.json")
    out = []
    for r in load("scored.json"):
        if r["scored"]:
            out.append(case(r, lib, lb, "synthetic" if r.get("synthetic") else "leftover"))
    v1 = {(r["artist"], r["album_id"]): r for r in load("scored-holdout-v1.json")}
    for r in load("scored-holdout.json"):
        r1 = v1.get((r["artist"], r["album_id"]))
        if r["verdict"] != "none" or (r1 and r1["verdict"] != "none"):
            out.append(case(r, lib, lb, "holdout"))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump(out, open(OUT, "w"), ensure_ascii=False, separators=(",", ":"))
    by = {}
    for c in out:
        by.setdefault((c["kind"], c["expect"]["verdict"]), 0)
        by[(c["kind"], c["expect"]["verdict"])] += 1
    print(f"{len(out)} cases -> {OUT} ({os.path.getsize(OUT) // 1024} KB)")
    for k in sorted(by):
        print(f"  {k[0]:9} {k[1]:6} {by[k]}")


if __name__ == "__main__":
    main()
