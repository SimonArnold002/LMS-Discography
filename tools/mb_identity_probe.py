#!/usr/bin/env python3
"""Measure a local<->MusicBrainz IDENTITY INDEX before building one.

Resolves each library album's ARTIST identity from the ALBUM rather than the
artist name -- album titles are far more unique, so identity falls out of the
album match instead of being guessed from a name that several acts share. This
is the offline measurement behind the PLANNED index section in CLAUDE.md; it
writes nothing back to LMS or the plugin.

The escalating tiers (each runs ONLY if the previous missed, which is what makes
the aggressive ones safe -- see `rescue`):

    T1  exact      releasegroup:"TITLE" AND artist:"ARTIST"
    T2  cleaned    edition decoration stripped from the title
    TA  aliases    alias:"TITLE"      (MB files some groups under the original
                   language and carries other spellings as aliases)
    T3  loose      releasegroup:"TITLE" alone, artist chosen by name agreement
    T4  fuzzy      Lucene fuzzy per word -- catches tagging typos
    -- rescue pass, misses only --
    T5  prefix     strip an "Artist:" / "Surname:" prefix off the title
    T6  decor      strip disc / edition decoration aggressively
    T7  year       let the library YEAR break a self-titled tie

WHY THE ORDER MATTERS, and it is the whole safety argument: applied
indiscriminately the T5 prefix strip would damage working matches -- "Talking
Heads: 77" is a REAL album title and would become "77". Because T5 only ever
sees albums the earlier tiers MISSED, and that album resolves at T1, the strip
never gets the chance. Ordering is the safety mechanism, not the regex.

Usage:
    python3 tools/mb_identity_probe.py scan     [--limit N]
    python3 tools/mb_identity_probe.py rescue
    python3 tools/mb_identity_probe.py report

Environment:
    DSC_HOST       LMS host:port          (default plex:9000)
    DSC_MB         MusicBrainz ws/2 base  (default http://plex:5000/ws/2/)
    DSC_SWEEP_OUT  output directory       (default <repo>/sweep)

`scan` is resumable: re-running skips albums already recorded. Against a local
mirror the full pass is a few minutes; against the public API it is ~1 req/s,
so budget roughly an hour for a 3,000-album library and let it resume.
"""

import argparse
import collections
import csv
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
import urllib.parse

HOST = os.environ.get("DSC_HOST", "plex:9000")
MB = os.environ.get("DSC_MB", "http://plex:5000/ws/2/")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.environ.get("DSC_SWEEP_OUT", os.path.join(REPO, "sweep"))
ALBUMS = os.path.join(OUT, "identity_albums.json")
RESULTS = os.path.join(OUT, "identity.json")

VARIOUS = re.compile(r"^(various|va|soundtrack|original soundtrack|\[unknown\])", re.I)


# ---------------------------------------------------------------------------
# transport
# ---------------------------------------------------------------------------
def lms(params, timeout=180):
    body = json.dumps({"id": 1, "method": "slim.request", "params": ["", params]})
    r = subprocess.run(["curl", "-s", "-m", str(timeout), f"http://{HOST}/jsonrpc.js",
                        "--data-binary", "@-"],
                       input=body, capture_output=True, text=True)
    try:
        return json.loads(r.stdout).get("result", {})
    except Exception:
        return {}


def mbget(url, tries=2):
    for attempt in range(tries):
        r = subprocess.run(["curl", "-s", "-m", "30", url], capture_output=True, text=True)
        try:
            return json.loads(r.stdout)
        except Exception:
            if attempt == tries - 1:
                return {}
            time.sleep(0.5)
    return {}


def query(q, limit=12):
    d = mbget(f"{MB}release-group?query={urllib.parse.quote(q)}&fmt=json&limit={limit}")
    return d.get("release-groups") or []


# ---------------------------------------------------------------------------
# normalisation (a deliberate approximation of Sources.pm::_norm -- close
# enough to MEASURE with; the plugin itself must always use the real thing)
# ---------------------------------------------------------------------------
LUCENE = re.compile(r'([+\-!(){}\[\]^"~*?:\\/]|&&|\|\|)')


def esc(s):
    return LUCENE.sub(r"\\\1", s)


def norm(s):
    s = unicodedata.normalize("NFD", (s or "").lower())
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = re.sub(r"[‐-―]", "-", s)
    s = re.sub(r"&", " and ", s)
    s = re.sub(r"'", "", s)
    s = re.sub(r"[^a-z0-9]+", " ", s).strip()
    return re.sub(r"^the ", "", s)


DECOR = re.compile(r"""\s*(\(|\[)[^)\]]*(deluxe|expanded|remaster|remastered|edition|
    anniversary|bonus|disc\s*\d|digital|version|mono|stereo|reissue|special|
    original\s+score|original\s+motion\s+picture|explicit|japan|import)[^)\]]*(\)|\])""",
                   re.I | re.X)


def clean(t):
    prev, s = None, t
    while prev != s:
        prev = s
        s = DECOR.sub("", s).strip()
    s = re.sub(r"\s*[:\-]\s*(deluxe|expanded|remastered).*$", "", s, flags=re.I).strip()
    return s or t


DECOR2 = re.compile(r"""(\s*\(disc\s*\d+[^)]*\)|\s*\[[^\]]*\]|
    \s*\((?:[^)]*(?:sacd|mix|bonus|deluxe|edition|version|remaster|expanded|
    outtakes|instrumentals|single|europe|japan|live\s+at[^)]*)[^)]*)\)|
    \s+deluxe$|\s+\(single\)$)""", re.I | re.X)


def strip_decor(t):
    prev, s = None, t
    while prev != s:
        prev = s
        s = DECOR2.sub("", s).strip()
    return s


def variants(name):
    """Spellings of the artist a tagger might have used as a title prefix."""
    n = name.strip()
    v = {n, re.sub(r"^the\s+", "", n, flags=re.I)}
    parts = [p for p in re.split(r"\s+", re.sub(r"^the\s+", "", n, flags=re.I)) if p]
    if len(parts) > 1:
        v.add(parts[-1])                       # surname: Springsteen, Reed, Drake
    if re.match(r"^st\.?\s", n, flags=re.I):
        v.add(re.sub(r"^st\.?\s", "Saint ", n, flags=re.I))
    if re.match(r"^saint\s", n, flags=re.I):
        v.add(re.sub(r"^saint\s", "St. ", n, flags=re.I))
    return {x for x in v if len(x) > 2}


def strip_prefix(artist, title):
    for cand in sorted(variants(artist), key=len, reverse=True):
        m = re.match(r"^\s*" + re.escape(cand) + r"\s*[:\-–]\s*(.+)$", title, flags=re.I)
        if m:
            rest = m.group(1).strip()
            # NEVER strip to nothing: a self-titled album must survive intact.
            if rest and norm(rest):
                return rest
    return None


# ---------------------------------------------------------------------------
# deciding a hit
# ---------------------------------------------------------------------------
def credits(rg):
    out = []
    for c in rg.get("artist-credit") or []:
        a = c.get("artist") or {}
        if a.get("id"):
            out.append((a["id"], a.get("name", "")))
    return out


def decide(rgs, artist, title, need_artist_agreement):
    """-> (verdict, mbid, name, detail).  verdict in UNIQUE/AMBIGUOUS/MISS."""
    if not rgs:
        return ("MISS", None, None, "no hits")
    an, tn = norm(artist), norm(title)
    top = rgs[0].get("score", 0)
    best = [r for r in rgs if r.get("score", 0) >= top and top > 0]
    # A 100-scored fuzzy hit on a DIFFERENT album must not carry the vote.
    best = [r for r in best if norm(r.get("title", "")) in (tn, norm(clean(title)))] or best
    if need_artist_agreement:
        keep = []
        for r in best:
            for cid, cname in credits(r):
                if norm(cname) == an or an in norm(cname) or norm(cname) in an:
                    keep.append((r, cid, cname))
                    break
        if not keep:
            return ("MISS", None, None, "hits but no artist agreement")
        ids = {c for _, c, _ in keep}
        if len(ids) == 1:
            r, cid, cname = keep[0]
            return ("UNIQUE", cid, cname, r.get("title", ""))
        return ("AMBIGUOUS", None, None,
                f"{len(ids)} artists: " + ", ".join(sorted({n for _, _, n in keep})[:4]))
    ids = {}
    for r in best:
        for cid, cname in credits(r):
            ids.setdefault(cid, (cname, r.get("title", "")))
    if not ids:
        return ("MISS", None, None, "no artist credit")
    if len(ids) == 1:
        cid, (cname, rt) = next(iter(ids.items()))
        return ("UNIQUE", cid, cname, rt)
    return ("AMBIGUOUS", None, None,
            f"{len(ids)} artists: " + ", ".join(sorted(n for n, _ in ids.values())[:4]))


def resolve(artist, title):
    """The main tiers. -> (tier, verdict, mbid, name, detail)."""
    a, t = esc(artist), esc(title)
    v = decide(query(f'releasegroup:"{t}" AND artist:"{a}"'), artist, title, False)
    if v[0] == "UNIQUE":
        return ("T1",) + v
    ct = clean(title)
    v2 = v
    if norm(ct) != norm(title):
        v2 = decide(query(f'releasegroup:"{esc(ct)}" AND artist:"{a}"'), artist, ct, False)
        if v2[0] == "UNIQUE":
            return ("T2",) + v2
    va = decide(query(f'alias:"{esc(ct)}" AND artist:"{a}"'), artist, ct, False)
    if va[0] == "UNIQUE":
        return ("TA",) + va
    v3 = decide(query(f'releasegroup:"{esc(ct)}"', limit=25), artist, ct, True)
    if v3[0] == "UNIQUE":
        return ("T3",) + v3
    words = re.findall(r"[A-Za-z0-9]{4,}", ct)[:6]
    if words:
        fq = " AND ".join(f"{esc(w)}~" for w in words)
        v4 = decide(query(f"releasegroup:({fq}) AND artist:\"{a}\"", limit=25), artist, ct, True)
        if v4[0] in ("UNIQUE", "AMBIGUOUS"):
            return ("T4",) + v4
    for cand in (v3, v2, v):
        if cand[0] == "AMBIGUOUS":
            return ("T3",) + cand
    return ("-",) + v


def year_pick(artist, title, year):
    """T7: an ambiguous self-titled album, decided by the library year."""
    hits = []
    for r in query(f'releasegroup:"{esc(title)}"', limit=25):
        if norm(r.get("title", "")) != norm(title):
            continue
        d = (r.get("first-release-date") or "")[:4]
        for c in r.get("artist-credit") or []:
            a = c.get("artist") or {}
            if not a.get("id"):
                continue
            if norm(a.get("name", "")) == norm(artist) and d and year \
                    and abs(int(d) - int(year)) <= 1:
                hits.append((a["id"], a.get("name"), r.get("title"), d))
    ids = {h[0] for h in hits}
    if len(ids) == 1:
        return ("UNIQUE", hits[0][0], hits[0][1], f"{hits[0][2]} ({hits[0][3]})")
    return ("MISS", None, None, f"{len(ids)} after year filter")


# ---------------------------------------------------------------------------
# phases
# ---------------------------------------------------------------------------
def load_albums():
    if os.path.exists(ALBUMS):
        return json.load(open(ALBUMS))
    d = lms(["albums", 0, 20000, "tags:lyaS"])
    al = d.get("albums_loop", [])
    if not al:
        sys.exit(f"no albums returned from {HOST} — is LMS reachable?")
    os.makedirs(OUT, exist_ok=True)
    json.dump(al, open(ALBUMS, "w"))
    print(f"cached {len(al)} albums -> {ALBUMS}")
    return al


def phase_scan(args):
    albums = load_albums()
    done = {}
    if os.path.exists(RESULTS):
        done = {str(x["id"]): x for x in json.load(open(RESULTS))}
        print(f"resuming: {len(done)} already recorded")
    res = list(done.values())
    todo = [a for a in albums if str(a["id"]) not in done]
    if args.limit:
        todo = todo[:args.limit]
    for i, al in enumerate(todo, 1):
        artist, title = al.get("artist") or "", al.get("album") or ""
        if not artist or not title:
            continue
        if VARIOUS.match(artist.strip()):
            res.append({"id": al["id"], "artist": artist, "album": title, "tier": "VA",
                        "verdict": "SKIP", "mbid": None, "name": None,
                        "detail": "various artists", "artist_id": al.get("artist_id"),
                        "year": al.get("year")})
            continue
        tier, verdict, mbid, name, detail = resolve(artist, title)
        res.append({"id": al["id"], "artist": artist, "album": title, "tier": tier,
                    "verdict": verdict, "mbid": mbid, "name": name, "detail": detail,
                    "artist_id": al.get("artist_id"), "year": al.get("year")})
        if i % 50 == 0:
            json.dump(res, open(RESULTS, "w"))
            print(f"{i}/{len(todo)}  {verdict:9} {tier:3} {artist[:22]:24} {title[:30]}",
                  flush=True)
    json.dump(res, open(RESULTS, "w"))
    print(f"scan done: {len(res)} albums -> {RESULTS}")


def phase_rescue(args):
    if not os.path.exists(RESULTS):
        sys.exit("run `scan` first")
    res = json.load(open(RESULTS))
    todo = [x for x in res if x["verdict"] in ("MISS", "AMBIGUOUS")]
    print(f"rescuing {len(todo)} unresolved albums")
    fixed = 0
    for x in todo:
        artist, title = x["artist"], x["album"]
        got = None
        sp = strip_prefix(artist, title)
        if sp:
            v = decide(query(f'releasegroup:"{esc(sp)}" AND artist:"{esc(artist)}"'),
                       artist, sp, False)
            if v[0] != "UNIQUE":
                v = decide(query(f'releasegroup:"{esc(sp)}"', limit=25), artist, sp, True)
            if v[0] == "UNIQUE":
                got = ("T5", sp) + v
        if not got:
            sd = strip_decor(title)
            if norm(sd) != norm(title) and norm(sd):
                v = decide(query(f'releasegroup:"{esc(sd)}" AND artist:"{esc(artist)}"'),
                           artist, sd, False)
                if v[0] != "UNIQUE":
                    v = decide(query(f'releasegroup:"{esc(sd)}"', limit=25), artist, sd, True)
                if v[0] == "UNIQUE":
                    got = ("T6", sd) + v
        if not got and x["verdict"] == "AMBIGUOUS":
            v = year_pick(artist, title, x.get("year"))
            if v[0] == "UNIQUE":
                got = ("T7", title) + v
        if got:
            x.update({"tier": got[0], "verdict": got[2], "mbid": got[3], "name": got[4],
                      "detail": got[5], "used": got[1]})
            fixed += 1
            print(f"  {got[0]}  {artist[:22]:24} {title[:36]:38} -> {got[4]}", flush=True)
    json.dump(res, open(RESULTS, "w"))
    print(f"\nrescued {fixed} of {len(todo)}")


def name_ok(lib, mb):
    """THE NAME GATE. Without it the album vote drags a classical artist to the
    COMPOSER (Chicago Symphony Orchestra -> Tchaikovsky) and breaks pages that
    work today. Token-subset either direction."""
    a, b = norm(lib), norm(mb)
    if not a or not b:
        return False
    if a == b:
        return True
    ta, tb = set(a.split()), set(b.split())
    return ta <= tb or tb <= ta


def phase_report(args):
    if not os.path.exists(RESULTS):
        sys.exit("run `scan` first")
    r = json.load(open(RESULTS))
    tot = len(r)
    print(f"ALBUMS: {tot}")
    for k, v in collections.Counter(x["verdict"] for x in r).most_common():
        print(f"  {k:10} {v:5}  {100*v/tot:5.1f}%")
    elig = [x for x in r if x["verdict"] != "SKIP"]
    u = [x for x in elig if x["verdict"] == "UNIQUE"]
    t = collections.Counter(x["tier"] for x in u)
    print(f"\nof {len(elig)} non-Various-Artists albums:")
    cum = 0
    for k in ("T1", "T2", "TA", "T3", "T4", "T5", "T6", "T7"):
        if t[k]:
            cum += t[k]
            print(f"  {k}  {t[k]:5}  cumulative {cum:5} ({100*cum/len(elig):5.1f}%)")
    strict = [x for x in u if norm(x["detail"]) == norm(x["album"])]
    print(f"\nARTIST identity resolved : {len(u):5} ({100*len(u)/len(elig):.1f}%)")
    print(f"  release group ALSO agrees exactly: {len(strict)} ({100*len(strict)/max(len(u),1):.1f}%)")
    print(f"  UNSAFE to store as album->RG     : {len(u)-len(strict)}"
          "   <- store artist identity only")

    gated = [x for x in u if name_ok(x["artist"], x["name"])]
    print(f"\nNAME GATE: {len(gated)} survive, {len(u)-len(gated)} dropped")
    sweep_csv = os.path.join(OUT, "artists.csv")
    if os.path.exists(sweep_csv):
        sweep = {x["name"]: (x["mbid"] or "").lower() for x in csv.DictReader(open(sweep_csv))}
        votes = collections.defaultdict(collections.Counter)
        for x in gated:
            votes[x["artist"]][x["mbid"]] += 1
        agree, diffs = 0, []
        for a, c in votes.items():
            (win, n), *rest = c.most_common()
            if rest and n == rest[0][1]:
                continue                       # strict plurality: no ties
            cur = sweep.get(a)
            if not cur:
                continue
            if cur == win:
                agree += 1
            else:
                diffs.append((a, n, sum(c.values()), cur[:8], win[:8]))
        print(f"  agrees with the plugin's current resolution: {agree}")
        print(f"  DISAGREES (check each by hand)             : {len(diffs)}")
        for a, n, tv, cur, win in sorted(diffs, key=lambda x: -x[1]):
            print(f"     {a[:32]:34} {n}/{tv}  {cur} -> {win}")
    else:
        print(f"  (no {sweep_csv} — run library_sweep.py report to compare against the plugin)")

    man = [x for x in elig if x["verdict"] in ("MISS", "AMBIGUOUS")]
    print(f"\nMANUAL QUEUE: {len(man)} albums ({100*len(man)/tot:.1f}% of the library)")
    for x in man[:40]:
        print(f"   {x['verdict']:9} {x['artist'][:24]:26} {x['album'][:44]:46} {x['detail'][:30]}")
    if len(man) > 40:
        print(f"   ... and {len(man)-40} more (see {RESULTS})")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="phase", required=True)
    s = sub.add_parser("scan", help="resolve every library album (resumable)")
    s.add_argument("--limit", type=int, help="stop after N albums this run")
    s.set_defaults(func=phase_scan)
    s = sub.add_parser("rescue", help="salvage tiers over the misses only")
    s.set_defaults(func=phase_rescue)
    s = sub.add_parser("report", help="coverage, name gate, disagreements, manual queue")
    s.set_defaults(func=phase_report)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
