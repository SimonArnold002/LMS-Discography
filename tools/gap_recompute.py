#!/usr/bin/env python3
"""Recompute "owned albums that never became a tile" from the LIVE plugin.

The sweep's `lib_extras` column ages the moment the library is rescanned or a
matcher fix ships, so re-derive it before triaging rather than trusting a stale
CSV. This drives the real feed and reads the plugin's own *Also in your library*
section -- the safety-net rows -- so the answer is what a user sees today.

    python3 tools/gap_recompute.py            # every artist the sweep flagged
    python3 tools/gap_recompute.py --artists "Kraftwerk,Neko Case"
    python3 tools/gap_recompute.py --who "Jack,Muzz,Rico"   # what did it RESOLVE?

`--who` answers a different and often more useful question: it prints the first
few SPINE rows for each artist, which is how you tell a matcher miss (right
artist, titles just don't line up) from a resolver miss (the page is somebody
else's discography entirely -- Jack -> Jack Johnson, Muzz -> the d'n'b MUZZ).

Environment:
    DSC_HOST       LMS host:port     (default plex:9000)
    DSC_PLAYER     player MAC        (discovered if unset -- menu mode needs one)
    DSC_SWEEP_OUT  output directory  (default <repo>/sweep)
"""

import argparse
import csv
import json
import os
import subprocess
import sys

HOST = os.environ.get("DSC_HOST", "plex:9000")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.environ.get("DSC_SWEEP_OUT", os.path.join(REPO, "sweep"))
DEST = os.path.join(OUT, "gaps.json")


def rq(params, mac="", timeout=180):
    body = json.dumps({"id": 1, "method": "slim.request", "params": [mac, params]})
    r = subprocess.run(["curl", "-s", "-m", str(timeout), f"http://{HOST}/jsonrpc.js",
                        "--data-binary", "@-"],
                       input=body, capture_output=True, text=True)
    try:
        return json.loads(r.stdout).get("result", {})
    except Exception:
        return {}


def find_player():
    mac = os.environ.get("DSC_PLAYER")
    if mac:
        return mac
    d = rq(["players", 0, 20])
    for p in d.get("players_loop", []):
        if p.get("playerid"):
            return p["playerid"]
    sys.exit("no player found — the feed needs `menu:discography`, which needs a player MAC")


def artist_id(name):
    for x in rq(["artists", 0, 10, "search:" + name]).get("artists_loop", []):
        if x["artist"].lower() == name.lower():
            return x["id"]
    return None


def feed(name, mac):
    params = ["discography", "items", 0, 400, "artist:" + name, "menu:discography"]
    aid = artist_id(name)
    if aid:
        params.insert(4, f"artist_id:{aid}")
    return aid, rq(params, mac=mac)


def split_sections(d):
    """-> (spine rows, library-extra rows). Section headers are single-line."""
    sec, spine, lib = None, [], []
    for it in d.get("item_loop", []):
        t = (it.get("text") or "").split("\n")
        if len(t) == 1 and ("(" in t[0] or t[0] in ("Similar artists", "Biography")):
            sec = t[0]
            continue
        if len(t) > 1:
            (lib if (sec or "").startswith("Also in your library") else spine).append(
                (t[0], t[1].replace("\n", " ")))
    return spine, lib


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--artists", help="comma-separated names (default: sweep's flagged set)")
    ap.add_argument("--who", help="comma-separated names: show what the plugin RESOLVED")
    ap.add_argument("-o", "--out", default=DEST)
    args = ap.parse_args()
    mac = find_player()

    if args.who:
        for name in [a.strip() for a in args.who.split(",")]:
            aid, d = feed(name, mac)
            spine, lib = split_sections(d)
            print(f"=== {name}   (lms artist_id {aid})")
            for t, l2 in spine[:6]:
                print(f"    spine: {t}  |  {l2}")
            for t, l2 in lib:
                print(f"    LIB  : {t}  |  {l2}")
            print()
        return

    if args.artists:
        names = [a.strip() for a in args.artists.split(",")]
    else:
        csv_path = os.path.join(OUT, "artists.csv")
        if not os.path.exists(csv_path):
            sys.exit(f"{csv_path} not found — run library_sweep.py, or pass --artists")
        rows = list(csv.DictReader(open(csv_path)))
        names = [r["name"] for r in rows if int(r.get("lib_extras") or 0) > 0]
        print(f"{len(names)} artists flagged by the sweep")

    out = []
    for i, name in enumerate(names, 1):
        aid, d = feed(name, mac)
        _, lib = split_sections(d)
        albums = [t for t, _ in lib]
        out.append({"artist": name, "artist_id": aid, "now": len(albums), "albums": albums})
        print(f"{i:3}/{len(names)} {name[:30]:32} unattached={len(albums)}", flush=True)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    json.dump(out, open(args.out, "w"), indent=1)
    tot = sum(x["now"] for x in out)
    print(f"\n{tot} unattached albums across {sum(1 for x in out if x['now'])} artists -> {args.out}")
    print("next: python3 tools/spine_fetch.py --gaps " + args.out + " && perl tools/spine_match.pl")


if __name__ == "__main__":
    main()
