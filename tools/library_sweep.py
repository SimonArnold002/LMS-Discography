#!/usr/bin/env python3
"""Real-world sweep of the Discography plugin over the whole local library.

Drives the LIVE plugin over HTTP (jsonrpc) exactly the way Material does, one
artist at a time, and records what the user would actually see: which releases
resolved, which service matched which release, which owned albums never became
a tile, and -- when debug_log is on -- the plugin's own reasoning for each
decision.

Nothing here re-implements the matcher. Every verdict comes from the plugin's
own output, so a run measures the shipped code rather than a model of it.

Phases (each resumable; re-running skips artists already recorded):

    preflight   check server, mirror, player, and that the diagnostic prefs
                are actually in effect (they cannot be read off-LAN, so they
                are proven by observing behaviour instead)
    browse      per artist: fire the discography feed, parse it, reconcile
                against the owned albums, capture the debug-log slice
    search      per artist: type the name into the plugin's own search and
                check the artist comes back and same-name acts fold
    variants    for names carrying & + ! ' or accents: search the plain
                spelling too, testing the _norm fold and the local-leg recovery
    report      aggregate everything into markdown + CSV

Usage:
    python3 tools/library_sweep.py preflight
    python3 tools/library_sweep.py browse [--limit N] [--offset N]
    python3 tools/library_sweep.py search [--limit N]
    python3 tools/library_sweep.py variants
    python3 tools/library_sweep.py report
"""

import argparse
import gzip
import json
import os
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

HOST = os.environ.get("DSC_HOST", "plex:9000")
BASE = f"http://{HOST}"
OUT = os.environ.get("DSC_SWEEP_OUT", os.path.expanduser("~/Documents/GitHub/LMS-Discography/sweep"))

# A player MAC is required for menu-mode feed queries; discovered at runtime.
PLAYER = os.environ.get("DSC_PLAYER", "")

PERFORMANCE_ROLES = "ARTIST,ALBUMARTIST,BAND,TRACKARTIST"
SERVICES = ("Local", "Qobuz", "Tidal", "Deezer")

RENDER_TIMEOUT = 150
FEED_MAX_ITEMS = 800
PACE = float(os.environ.get("DSC_PACE", "0.15"))  # polite gap between artists

# A COLD artist renders BEFORE its streaming candidate pool exists. The plugin
# only awaits that warm when hide_unmatched is on (0.44.8), and the sweep must
# run with it off to see the misses at all -- so a single render measures the
# pool's warm-up, not the matcher. Measured on the live box:
#     13th Floor Elevators  first 2/42   second 12/42
#     Count Basie           first 25/112 second 33/112
# So each artist is rendered until the match count stops rising. The first
# render's figure is kept too: the gap between them IS the second-load contract
# as a user experiences it.
SETTLE = float(os.environ.get("DSC_SETTLE", "2.0"))
MAX_RENDERS = int(os.environ.get("DSC_MAX_RENDERS", "4"))

# Section headers the plugin emits. Keyed by the prefix of the rendered text.
SECTION_PREFIXES = [
    ("Albums", "ALBUMS"),
    ("EPs", "EPS"),
    ("Singles", "SINGLES"),
    ("Compilations", "COMPILATIONS"),
    ("Live albums", "LIVE"),
    ("Other releases", "OTHER"),
    ("Also in your library", "LIB_EXTRAS"),
    ("Appearances", "APPEARANCES"),
    ("Also on streaming", "STREAM_EXTRAS"),
    ("Other artists with this name", "SAME_NAME"),
    ("Similar artists", "SIMILAR"),
    ("Also a member of", "BANDS"),
    ("Biography", "BIO"),
    ("Options", "OPTIONS"),
]

ERROR_MARKERS = {
    "couldn't identify": "unresolved",
    "no releases found": "empty_spine",
}


# ---------------------------------------------------------------- transport


def rpc(params, timeout=30, player=""):
    """One slim.request. Returns the result dict, or raises."""
    body = json.dumps({"id": 1, "method": "slim.request", "params": [player, params]}).encode("utf-8")
    req = urllib.request.Request(f"{BASE}/jsonrpc.js", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as fh:
        return json.loads(fh.read().decode("utf-8", "replace")).get("result", {})


def http_text(path, timeout=60):
    req = urllib.request.Request(f"{BASE}{path}", headers={"Cache-Control": "no-cache"})
    with urllib.request.urlopen(req, timeout=timeout) as fh:
        return fh.read().decode("utf-8", "replace")


TAG_RE = re.compile(r"<[^>]*>")
LOGLINE_RE = re.compile(r"^\[\d\d-\d\d-\d\d \d\d:\d\d:\d\d\.\d+\]")


def log_lines(lines=1500):
    """The server log tail, HTML stripped, only real log records."""
    try:
        raw = http_text(f"/log.txt?lines={lines}&cb={int(time.time()*1000)}")
    except Exception:
        return []
    out = []
    for ln in raw.splitlines():
        ln = TAG_RE.sub("", ln).rstrip()
        if LOGLINE_RE.match(ln):
            out.append(ln)
    return out


class LogCursor:
    """Returns only the log lines written since the previous call.

    The log tail is a fixed window, so if the window no longer reaches back to
    the cursor the slice is marked truncated rather than silently short --
    a short window is exactly how the 0.44.9 misdiagnosis happened.
    """

    def __init__(self):
        self.last = None

    def slice(self, want=1500):
        lines = log_lines(want)
        if not lines:
            return [], False
        if self.last is None:
            self.last = lines[-1]
            return [], False
        truncated = self.last not in lines
        if truncated:
            lines2 = log_lines(6000)
            if lines2 and self.last in lines2:
                lines, truncated = lines2, False
        if not truncated:
            idx = lines.index(self.last)
            fresh = lines[idx + 1:]
        else:
            fresh = lines
        if lines:
            self.last = lines[-1]
        return fresh, truncated


# ---------------------------------------------------------------- library


def find_player():
    global PLAYER
    if PLAYER:
        return PLAYER
    res = rpc(["players", 0, 20])
    for p in res.get("players_loop", []):
        if p.get("connected"):
            PLAYER = p["playerid"]
            return PLAYER
    raise SystemExit("no connected player found; a player MAC is required for menu-mode queries")


def album_artists():
    res = rpc(["artists", 0, 1, "role_id:ALBUMARTIST"], timeout=60)
    total = int(res.get("count", 0))
    out, step = [], 500
    for off in range(0, total, step):
        res = rpc(["artists", off, step, "role_id:ALBUMARTIST"], timeout=120)
        for a in res.get("artists_loop", []):
            out.append({"id": int(a["id"]), "name": a.get("artist", "")})
    return out


def owned_albums(artist_id):
    """The albums the plugin itself would see for this artist (same roles)."""
    res = rpc(["albums", 0, 500, f"artist_id:{artist_id}",
               f"role_id:{PERFORMANCE_ROLES}", "tags:ly"], timeout=60)
    out = []
    for a in res.get("albums_loop", []):
        out.append({"id": int(a.get("id", 0)), "title": a.get("album", ""),
                    "year": a.get("year") or None})
    return out


# ---------------------------------------------------------------- parsing


def split_text(text):
    parts = (text or "").split("\n")
    return parts[0], (parts[1] if len(parts) > 1 else "")


def section_key(text):
    base = re.sub(r"\s*\(\d+\)\s*$", "", text or "").strip()
    for prefix, key in SECTION_PREFIXES:
        if base == prefix or base.startswith(prefix):
            return key
    return None


def section_count(text):
    m = re.search(r"\((\d+)\)\s*$", text or "")
    return int(m.group(1)) if m else None


def parse_line2(line2):
    """'2011 · Album · Local/Qobuz' -> (year, type, [sources])."""
    parts = [p.strip() for p in (line2 or "").split("·")]
    year = None
    rtype = None
    sources = []
    for p in parts:
        if not p:
            continue
        if re.fullmatch(r"\d{4}", p):
            year = int(p)
            continue
        bits = [b.strip() for b in p.split("/")]
        if bits and all(b in SERVICES for b in bits):
            sources = bits
        elif rtype is None:
            rtype = p
        elif p not in ("",):
            # release types can themselves contain ' / ' (e.g. "Single / Soundtrack")
            rtype = f"{rtype} · {p}" if rtype else p
    return year, rtype, sources


def parse_feed(result):
    """Turn a rendered discography feed into structured facts."""
    items = result.get("item_loop", []) or []
    out = {
        "item_count": int(result.get("count", len(items))),
        "artist_mbid": None,
        "error": None,
        "sections": {},
        "releases": [],
        "lib_extras": [],
        "appearances": [],
        "stream_extras": [],
        "same_name": [],
        "similar": [],
        "bands": [],
        "has_bio": False,
    }
    current = None
    for it in items:
        text = it.get("text", "") or ""
        line1, line2 = split_text(text)
        go = (it.get("actions") or {}).get("go") or {}
        gp = go.get("params") or {}

        if out["artist_mbid"] is None and gp.get("mbid"):
            out["artist_mbid"] = gp["mbid"]

        low = line1.lower()
        for marker, kind in ERROR_MARKERS.items():
            if marker in low:
                out["error"] = kind

        is_divider = it.get("style") == "itemNoAction" and it.get("type") == "text"
        if is_divider:
            key = section_key(line1)
            if key:
                current = key
                cnt = section_count(line1)
                if cnt is not None:
                    out["sections"][key] = cnt
                elif key not in out["sections"]:
                    out["sections"][key] = None
                if key == "BIO":
                    out["has_bio"] = True
                continue

        rg = gp.get("rg")
        item_id = gp.get("item") or it.get("id") or ""

        if rg:
            year, rtype, sources = parse_line2(line2)
            fav = ((it.get("presetParams") or {}).get("favorites_url") or "")
            out["releases"].append({
                "rg": rg, "title": line1, "year": year, "type": rtype,
                "sources": sources, "section": current,
                "favurl_scheme": fav.split("://")[0] if "://" in fav else None,
            })
            continue

        if isinstance(item_id, str) and item_id.startswith("lib:"):
            year, _t, sources = parse_line2(line2)
            rec = {"title": line1, "year": year, "album_id": item_id[4:]}
            (out["appearances"] if current == "APPEARANCES" else out["lib_extras"]).append(rec)
            continue

        if isinstance(item_id, str) and item_id.startswith("str:"):
            year, _t, _s = parse_line2(line2)
            out["stream_extras"].append({"title": line1, "year": year, "id": item_id})
            continue

        if current == "SIMILAR" and line1 and not is_divider:
            out["similar"].append(line1)
        elif current == "BANDS" and line1 and not is_divider:
            out["bands"].append(line1)
        elif current == "SAME_NAME" and line1 and not is_divider:
            out["same_name"].append({"name": line1, "note": line2})

    return out


# ------------------------------------------------------------ log mining

DBG = re.compile(r"dsc\[dbg\]:\s*(.*)$")
RE_TOPLEVEL = re.compile(r"topLevel: artist_id=(\S+) artist=(.*?) mbid=(\S+)")
RE_TAGMBID = re.compile(r"artist mbid from library tag: ([0-9a-f-]{36})")
RE_MATCH = re.compile(r"match '(.*)' \[(.*?)\]: (.*?) \| pool: (.*)$")
RE_DROPPED = re.compile(r"(\w+)/(\S+): dropped (\d+) album\(s\)")
RE_AMBIG = re.compile(r"(\w+): '(.*?)' is ambiguous")
RE_UNRESOLVED = re.compile(r"UNRESOLVED")
RE_CANDS = re.compile(r"candidates (\w+)[/:]'?(.*?)'?: (\d+)")
RE_ARTSEARCH = re.compile(r"artist search '(.*?)': (\d+) merged from (.*)$")


def mine_log(lines):
    """Pull the plugin's own reasoning out of a log slice."""
    facts = {
        "dbg_lines": 0,
        "mbid_from_tag": None,
        "pools": {},
        "no_match": [],
        "matched": 0,
        "dropped": {},
        "ambiguous": [],
        "unresolved_services": [],
        "candidates": {},
    }
    for ln in lines:
        m = DBG.search(ln)
        if not m:
            continue
        msg = m.group(1)
        facts["dbg_lines"] += 1

        t = RE_TAGMBID.search(msg)
        if t:
            facts["mbid_from_tag"] = t.group(1)

        mm = RE_MATCH.search(msg)
        if mm:
            title, _artist, verdict, pool = mm.groups()
            if verdict.strip() == "NO MATCH":
                if title not in facts["no_match"]:
                    facts["no_match"].append(title)
            else:
                facts["matched"] += 1
            for part in pool.split(","):
                bits = part.strip().split("=")
                if len(bits) == 2 and bits[1].strip().isdigit():
                    facts["pools"][bits[0].strip()] = int(bits[1])
            continue

        d = RE_DROPPED.search(msg)
        if d:
            svc, _eid, n = d.groups()
            facts["dropped"][svc] = facts["dropped"].get(svc, 0) + int(n)

        a = RE_AMBIG.search(msg)
        if a:
            entry = f"{a.group(1)}:{a.group(2)}"
            if entry not in facts["ambiguous"]:
                facts["ambiguous"].append(entry)
            if RE_UNRESOLVED.search(msg):
                if a.group(1) not in facts["unresolved_services"]:
                    facts["unresolved_services"].append(a.group(1))

        c = RE_CANDS.search(msg)
        if c:
            facts["candidates"][c.group(1)] = int(c.group(3))

    return facts


# ---------------------------------------------------------------- norming


def loose(name):
    """The harness's OWN loose comparison -- deliberately not the plugin's
    _norm. Used only to ask 'is this obviously the same name', never to judge
    whether the matcher was right."""
    s = unicodedata.normalize("NFD", name or "")
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = s.lower().replace("&", " and ").replace("+", " and ")
    s = re.sub(r"[^a-z0-9]+", " ", s)
    s = re.sub(r"^the\s+", "", s).strip()
    return re.sub(r"\s+", " ", s)


def variant_spellings(name):
    """Plain spellings a user might type for a decorated name."""
    out = set()
    ascii_fold = "".join(c for c in unicodedata.normalize("NFD", name)
                         if not unicodedata.combining(c))
    if ascii_fold != name and ascii_fold.isascii():
        out.add(ascii_fold)
    for src in list(out) + [name]:
        if "&" in src:
            out.add(src.replace("&", "and"))
            out.add(re.sub(r"\s*&\s*", " and ", src))
        if "+" in src:
            out.add(re.sub(r"\s*\+\s*", " and ", src))
        if "'" in src or "’" in src:
            out.add(src.replace("'", "").replace("’", ""))
        if "!" in src:
            out.add(src.replace("!", ""))
    out.discard(name)
    return sorted(x for x in out if x.strip())


# ---------------------------------------------------------------- storage


def outdir(*parts):
    p = os.path.join(OUT, *parts)
    os.makedirs(os.path.dirname(p) if os.path.splitext(p)[1] else p, exist_ok=True)
    return p


def jsonl_path(phase):
    os.makedirs(OUT, exist_ok=True)
    return os.path.join(OUT, f"{phase}.jsonl")


def done_keys(phase, key="artist_id"):
    """Artists already recorded SUCCESSFULLY.

    A record carrying `fatal` is deliberately NOT counted as done, so a
    transient failure -- a timeout because the run was paused mid-request, a
    service blip -- is retried on the next run instead of being skipped
    permanently. The report keeps the LAST record for an artist, so the retry
    supersedes the failure.
    """
    path = jsonl_path(phase)
    if not os.path.exists(path):
        return set()
    seen = set()
    with open(path, encoding="utf-8") as fh:
        for ln in fh:
            try:
                rec = json.loads(ln)
            except Exception:
                continue
            if rec.get("fatal"):
                continue
            seen.add(rec.get(key))
    return seen


def append(phase, rec):
    with open(jsonl_path(phase), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, ensure_ascii=False) + "\n")


def save_raw(kind, key, obj):
    d = os.path.join(OUT, "raw", kind)
    os.makedirs(d, exist_ok=True)
    with gzip.open(os.path.join(d, f"{key}.json.gz"), "wt", encoding="utf-8") as fh:
        json.dump(obj, fh, ensure_ascii=False)


def save_log(key, lines):
    if not lines:
        return
    d = os.path.join(OUT, "logs")
    os.makedirs(d, exist_ok=True)
    with gzip.open(os.path.join(d, f"{key}.log.gz"), "wt", encoding="utf-8") as fh:
        fh.write("\n".join(lines))


# ---------------------------------------------------------------- phases


def phase_preflight(_args):
    print(f"server   : {BASE}")
    st = rpc(["serverstatus", 0, 0], timeout=30)
    print(f"           LMS {st.get('version')}")
    mac = find_player()
    print(f"player   : {mac}")

    total = rpc(["artists", 0, 1, "role_id:ALBUMARTIST"])["count"]
    print(f"artists  : {total} album artists")

    # mirror
    try:
        q = urllib.parse.quote('artist:"Radiohead"')
        raw = urllib.request.urlopen(
            f"http://{HOST.split(':')[0]}:5000/ws/2/artist?query={q}&fmt=json&limit=1", timeout=15
        ).read().decode()
        print(f"mirror   : OK, search count={json.loads(raw).get('count')}")
    except Exception as exc:
        print(f"mirror   : UNREACHABLE ({exc}) -- the plugin may be using the public API")

    # Prefs cannot be READ off-LAN, so prove them by behaviour.
    cur = LogCursor()
    cur.slice(400)
    probe_id, probe_name = _probe_artist()
    res = rpc(["discography", "items", 0, FEED_MAX_ITEMS, f"artist_id:{probe_id}",
               f"artist:{probe_name}", "menu:discography"],
              timeout=RENDER_TIMEOUT, player=mac)
    time.sleep(1.5)
    fresh, _tr = cur.slice(3000)
    facts = mine_log(fresh)
    feed = parse_feed(res)

    unmatched = [r for r in feed["releases"] if not r["sources"]]
    print()
    print(f"probe    : {probe_name} -- {len(feed['releases'])} releases, "
          f"{len(unmatched)} with no source")
    print(f"debug_log: {'ON' if facts['dbg_lines'] else 'OFF'} "
          f"({facts['dbg_lines']} dsc lines captured)")
    print(f"hide_unmatched: {'OFF (good)' if unmatched else 'likely ON -- misses will be hidden'}")
    print(f"streaming extras section: "
          f"{'present' if feed['sections'].get('STREAM_EXTRAS') is not None else 'absent'}")
    types = [k for k in ("ALBUMS", "EPS", "SINGLES", "COMPILATIONS", "LIVE", "OTHER")
             if k in feed["sections"]]
    print(f"type sections rendered: {', '.join(types) or 'none'}")
    print()
    if not facts["dbg_lines"] or not unmatched:
        print("NOT READY -- set the diagnostic prefs on the box first (see README_SWEEP.md)")
        return 1
    print("READY")
    return 0


def _probe_artist():
    """Pick a BIG-catalogue artist for the hide_unmatched probe.

    The probe asks 'does any release render with no source at all'. On a small
    artist the answer can legitimately be no, which would read as 'the pref is
    off' when it is on -- so the probe has to run against an artist whose
    MusicBrainz catalogue is far larger than any service carries.
    """
    prefer = ["Bob Dylan", "The Beatles", "Neil Young", "David Bowie", "Prince",
              "Elvis Costello", "Marc Almond", "Pretenders", "Radiohead"]
    everyone = album_artists()
    by_name = {a["name"]: a for a in everyone}
    for name in prefer:
        if name in by_name:
            return by_name[name]["id"], name
    # fall back to whoever owns the most albums -- the best proxy for a big catalogue
    best = max(everyone, key=lambda a: len(owned_albums(a["id"])) if a["id"] % 97 == 0 else 0)
    return best["id"], best["name"]


def phase_browse(args):
    mac = find_player()
    artists = album_artists()
    if args.offset:
        artists = artists[args.offset:]
    if args.limit:
        artists = artists[:args.limit]
    seen = done_keys("browse")
    todo = [a for a in artists if a["id"] not in seen]
    print(f"browse: {len(todo)} artists to do ({len(seen)} already recorded)")

    cur = LogCursor()
    cur.slice(400)
    t_start = time.time()
    for n, art in enumerate(todo, 1):
        rec = {"artist_id": art["id"], "name": art["name"], "ts": time.time()}
        t0 = time.time()
        try:
            feed = None
            first_matched = None
            renders = 0
            for attempt in range(MAX_RENDERS):
                res = rpc(["discography", "items", 0, FEED_MAX_ITEMS,
                           f"artist_id:{art['id']}", f"artist:{art['name']}",
                           "menu:discography"], timeout=RENDER_TIMEOUT, player=mac)
                renders += 1
                nxt = parse_feed(res)
                matched = sum(1 for r in nxt["releases"] if r["sources"])
                if attempt == 0:
                    rec["first_elapsed"] = round(time.time() - t0, 3)
                    first_matched = matched
                prev = sum(1 for r in feed["releases"] if r["sources"]) if feed else -1
                feed = nxt
                if matched <= prev:      # pool has stopped growing
                    break
                if attempt < MAX_RENDERS - 1:
                    time.sleep(SETTLE)
            rec["elapsed"] = round(time.time() - t0, 3)
            rec["renders"] = renders
            rec["matched_first_render"] = first_matched
            save_raw("browse", str(art["id"]), res)
        except Exception as exc:
            rec["elapsed"] = round(time.time() - t0, 3)
            rec["fatal"] = f"{type(exc).__name__}: {exc}"
            append("browse", rec)
            print(f"[{n}/{len(todo)}] {art['name']}: FATAL {rec['fatal']}")
            continue

        fresh, truncated = cur.slice(2500)
        save_log(str(art["id"]), fresh)
        facts = mine_log(fresh)
        rec["log_truncated"] = truncated

        owned = owned_albums(art["id"])
        orphan_titles = {loose(x["title"]) for x in feed["lib_extras"]}
        orphan_titles |= {loose(x["title"]) for x in feed["appearances"]}
        unclaimed = [o for o in owned if loose(o["title"]) in orphan_titles]

        rels = feed["releases"]
        by_service = {s: sum(1 for r in rels if s in r["sources"]) for s in SERVICES}
        rec.update({
            "mbid": feed["artist_mbid"],
            "error": feed["error"],
            "sections": feed["sections"],
            "release_total": len(rels),
            "release_matched": sum(1 for r in rels if r["sources"]),
            "release_unmatched": sum(1 for r in rels if not r["sources"]),
            "warm_gain": (sum(1 for r in rels if r["sources"]) - (first_matched or 0)),
            "by_service": by_service,
            "owned": len(owned),
            "owned_unclaimed": len(unclaimed),
            "lib_extras": len(feed["lib_extras"]),
            "appearances": len(feed["appearances"]),
            "stream_extras": len(feed["stream_extras"]),
            "same_name": len(feed["same_name"]),
            "similar": len(feed["similar"]),
            "bands": len(feed["bands"]),
            "has_bio": feed["has_bio"],
            "log": facts,
            "unmatched_titles": [r["title"] for r in rels if not r["sources"]][:60],
            "unclaimed_titles": [o["title"] for o in unclaimed][:40],
        })
        append("browse", rec)

        rate = (time.time() - t_start) / n
        eta = int(rate * (len(todo) - n))
        flag = ""
        if rec["error"]:
            flag = f"  !! {rec['error']}"
        elif rec["release_total"] and not rec["release_matched"]:
            flag = "  !! zero matches"
        elif rec["owned_unclaimed"]:
            flag = f"  !! {rec['owned_unclaimed']} owned unclaimed"
        print(f"[{n}/{len(todo)}] {art['name'][:38]:38s} "
              f"{rec['release_total']:4d} rel  {rec['release_matched']:4d} matched  "
              f"{rec['elapsed']:5.1f}s  eta {eta//60}m{flag}")
        time.sleep(PACE)
    return 0


def _search(query, mac):
    res = rpc(["discography", "items", 0, 60, f"search:{query}", "menu:discography"],
              timeout=RENDER_TIMEOUT, player=mac)
    items = res.get("item_loop", []) or []
    rows, current = [], None
    for it in items:
        line1, line2 = split_text(it.get("text", ""))
        if it.get("style") == "itemNoAction" and it.get("type") == "text":
            k = section_key(line1)
            if k:
                current = k
            continue
        go = (it.get("actions") or {}).get("go") or {}
        gp = go.get("params") or {}
        if not (gp.get("artist") or gp.get("mbid")):
            continue
        rows.append({
            "name": line1,
            "sources": [s.strip() for s in (line2 or "").split("·") if s.strip()],
            "mbid": gp.get("mbid"),
            "artist_id": gp.get("artist_id"),
            "section": current,
        })
    return res, rows


def phase_search(args):
    mac = find_player()
    artists = album_artists()
    if args.limit:
        artists = artists[:args.limit]
    seen = done_keys("search")
    todo = [a for a in artists if a["id"] not in seen]
    print(f"search: {len(todo)} artists to do ({len(seen)} already recorded)")

    t_start = time.time()
    for n, art in enumerate(todo, 1):
        rec = {"artist_id": art["id"], "name": art["name"], "query": art["name"]}
        t0 = time.time()
        try:
            res, rows = _search(art["name"], mac)
            save_raw("search", str(art["id"]), res)
        except Exception as exc:
            rec["fatal"] = f"{type(exc).__name__}: {exc}"
            append("search", rec)
            print(f"[{n}/{len(todo)}] {art['name']}: FATAL {rec['fatal']}")
            continue
        rec["elapsed"] = round(time.time() - t0, 3)

        want = loose(art["name"])
        hit = next((i for i, r in enumerate(rows) if loose(r["name"]) == want), None)
        rec.update({
            "rows": len(rows),
            "self_hit_index": hit,
            "self_hit_exact_name": rows[hit]["name"] if hit is not None else None,
            "self_hit_local": ("Local" in rows[hit]["sources"]) if hit is not None else None,
            "self_hit_sources": rows[hit]["sources"] if hit is not None else None,
            "same_name_rows": sum(1 for r in rows if r["section"] == "SAME_NAME"),
            "row_names": [r["name"] for r in rows][:25],
        })
        append("search", rec)

        rate = (time.time() - t_start) / n
        eta = int(rate * (len(todo) - n))
        flag = ""
        if hit is None:
            flag = "  !! NOT FOUND"
        elif hit > 0:
            flag = f"  !! rank {hit + 1}"
        elif not rec["self_hit_local"]:
            flag = "  !! no Local source"
        print(f"[{n}/{len(todo)}] {art['name'][:38]:38s} {rec['rows']:3d} rows  "
              f"{rec['elapsed']:5.1f}s  eta {eta//60}m{flag}")
        time.sleep(PACE)
    return 0


def phase_variants(args):
    mac = find_player()
    artists = album_artists()
    pairs = []
    for a in artists:
        for v in variant_spellings(a["name"]):
            pairs.append((a, v))
    if args.limit:
        pairs = pairs[:args.limit]
    seen = done_keys("variants", key="key")
    todo = [(a, v) for a, v in pairs if f"{a['id']}|{v}" not in seen]
    print(f"variants: {len(todo)} probes to do ({len(seen)} already recorded)")

    for n, (art, variant) in enumerate(todo, 1):
        rec = {"key": f"{art['id']}|{variant}", "artist_id": art["id"],
               "name": art["name"], "query": variant}
        try:
            res, rows = _search(variant, mac)
        except Exception as exc:
            rec["fatal"] = f"{type(exc).__name__}: {exc}"
            append("variants", rec)
            continue
        want = loose(art["name"])
        hit = next((i for i, r in enumerate(rows) if loose(r["name"]) == want), None)
        rec.update({
            "rows": len(rows),
            "self_hit_index": hit,
            "self_hit_local": ("Local" in rows[hit]["sources"]) if hit is not None else None,
            "row_names": [r["name"] for r in rows][:15],
        })
        append("variants", rec)
        flag = "  !! NOT FOUND" if hit is None else (
            "  !! no Local" if not rec["self_hit_local"] else "")
        print(f"[{n}/{len(todo)}] {art['name'][:28]:28s} -> {variant[:28]:28s} "
              f"{rec['rows']:3d} rows{flag}")
        time.sleep(PACE)
    return 0


# ---------------------------------------------------------------- report


def load(phase):
    path = jsonl_path(phase)
    if not os.path.exists(path):
        return []
    out = []
    with open(path, encoding="utf-8") as fh:
        for ln in fh:
            try:
                out.append(json.loads(ln))
            except Exception:
                continue
    return out


def phase_report(_args):
    import report_sweep  # noqa: F401  (sibling module, generated alongside)
    return report_sweep.main(OUT)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("phase", choices=["preflight", "browse", "search", "variants", "report"])
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--offset", type=int, default=0)
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    fn = {"preflight": phase_preflight, "browse": phase_browse, "search": phase_search,
          "variants": phase_variants, "report": phase_report}[args.phase]
    return fn(args) or 0


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    sys.exit(main())
