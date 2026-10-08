#!/usr/bin/env python3
"""Leftover replay, step 2: MusicBrainz tags from the July sweep's debug logs.

The LMS CLI exposes neither an album's MUSICBRAINZ_ALBUMID nor a contributor's
MusicBrainz id (Sources::localAlbums reads them from Slim::Schema). The July
sweep (sweep/logs/<artist_id>.log.gz, 2026-07-21) logged both for 1,100 album
artists:
    artist mbid from library tag: <mbid>      (else: artist mbid cache hit '<name>': <mbid>)
    local albums for artist_id=<id>: <n> | <title> mbid=<release|NONE>; ...
Tags live in the files, so they survive a rescan; only LMS's ids change. Keyed
here by artist NAME and album TITLE. An album added after July has no entry and
is replayed as untagged (the report counts them).

Usage:  python3 tools/leftover/july_tags.py
Output: sweep/leftover/july_tags.json
"""

import gzip
import json
import os
import re

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LOGS = os.path.join(REPO, "sweep", "logs")
OUT = os.path.join(REPO, "sweep", "leftover", "july_tags.json")

RE_TOP = re.compile(r"topLevel: artist_id=(\S+) artist=(.*?) mbid=(\S+)")
RE_TAG = re.compile(r"artist mbid from library tag: ([0-9a-f-]{36})")
RE_HIT = re.compile(r"artist mbid cache hit '(.*)': ([0-9a-f-]{36})")
RE_LOC = re.compile(r"local albums for artist_id=\S+: \d+ \| (.*)$")
RE_ALB = re.compile(r"^(.*) mbid=([0-9a-f-]{36}|NONE)(?: \(credited to .*\))?$")


def main():
    out = {}
    for f in sorted(os.listdir(LOGS)):
        if not f.endswith(".log.gz"):
            continue
        name, amb, hit, albums = None, None, None, {}
        with gzip.open(os.path.join(LOGS, f), "rt", errors="replace") as fh:
            for line in fh:
                line = line.rstrip("\n")
                m = RE_TOP.search(line)
                if m and name is None:
                    name = m.group(2)
                m = RE_TAG.search(line)
                if m and amb is None:
                    amb = m.group(1)
                m = RE_HIT.search(line)
                if m and hit is None and name is not None and m.group(1) == name:
                    hit = m.group(2)
                m = RE_LOC.search(line)
                if m:
                    for part in m.group(1).split("; "):
                        a = RE_ALB.match(part)
                        if a:
                            albums[a.group(1)] = None if a.group(2) == "NONE" else a.group(2)
        if name:
            out[name] = {"artist_mbid": amb or hit, "by": "tag" if amb else ("name" if hit else None),
                         "albums": albums}
    tagged = sum(1 for v in out.values() if v["by"] == "tag")
    named = sum(1 for v in out.values() if v["by"] == "name")
    rel = sum(1 for v in out.values() for m in v["albums"].values() if m)
    print(f"{len(out)} artists ({tagged} by tag, {named} by name), {rel} album release tags")
    json.dump(out, open(OUT, "w"))
    print(f"-> {OUT}")


if __name__ == "__main__":
    main()
