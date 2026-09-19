#!/usr/bin/env python3
"""SEARCH-PATH soak: every library artist reached the way a user types them.

WHY THIS EXISTS. The 2026-07-21/22 sweep drove the BROWSE path -- it entered
every artist by `artist_id`, which is the Artists row / Material custom action,
and which resolves identity from the library's own MusicBrainz tag. That is the
easy path, and it hid a whole class of defect: CLAUDE.md's "DSC two entry paths"
rule exists because a fix can land on one and not the other. Simon, 2026-07-31:
*"run via the search engine, and not using mbids to see what misses we get ...
another round of artists that might fail to match via search but matched via
rows."*

So each artist is measured TWICE and the two are compared:

    reference   discography items artist_id:<id> artist:<name>   (the row path)
    search      discography items search:<name>                  (typed)
                then DRILL the resulting row using the row's OWN go params,
                verbatim, exactly what Material would send on a tap.

NO MBID IS EVER INJECTED. The search command carries only the typed text, and
the drill carries only what the row itself offered -- which is the measurement:
`entry_keys` records whether a search row hands over an artist_id, an mbid, or
nothing but a name, and that is what decides whether the drilled page resolves
by identity or by spelling.

THE ORACLE IS THE PLUGIN'S OWN OUTPUT, never a name comparison. The last sweep
recorded three "search failures" that were CORRECT alias folds (British Sea
Power -> Sea Power), because it compared row names literally. Here a row counts
as the right artist when the page it opens resolves to the same MusicBrainz
artist as the reference render, whatever it is called; `name_folded` marks the
ones where the label legitimately differs.

TWO MEASUREMENT TRAPS THIS INHERITS FROM THE LAST SWEEP, both load-bearing:

  1. A FIRST RENDER UNDERSTATES MATCHES. With hide_unmatched OFF -- which this
     needs, or misses are invisible -- the view does not await the streaming
     warm (0.44.8), so a cold artist renders before its pool exists. Measured:
     13th Floor Elevators 2/42 then 12/42. Every render here therefore repeats
     until the matched count stops rising, and BOTH figures are kept.
  2. PER-ARTIST LOG SLICES CANNOT BE ATTRIBUTED IN PARALLEL. Workers interleave
     in one log, so `--log-slices` is refused unless --workers 1. The JSON the
     plugin returns is the evidence in parallel mode.

PARALLELISM IS PER PLAYER, not just per thread. `%lastCtx` is stashed per
player id (Browse.pm), so two workers sharing a player would overwrite each
other's stashed artist mid-run. Each worker therefore owns one player and
workers are capped at the number of connected players. Nothing here ever sends
play/add/insert -- it browses only, so a playing player is not disturbed.

    python3 tools/search_soak.py preflight
    python3 tools/search_soak.py run [--workers N] [--limit N] [--resume]
    python3 tools/search_soak.py report

Resumable: results append to sweep/search-soak/soak.jsonl keyed by artist_id,
and a re-run skips what is already recorded.
"""

import argparse
import json
import os
import queue
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import library_sweep as LS          # rpc / parsing / artist list, unchanged

OUT = os.path.join(LS.OUT, "search-soak")
JSONL = os.path.join(OUT, "soak.jsonl")

FEED_MAX = 800
SEARCH_MAX = 60
RENDER_TIMEOUT = 180
SETTLE = float(os.environ.get("DSC_SETTLE", "2.0"))
MAX_RENDERS = int(os.environ.get("DSC_MAX_RENDERS", "4"))

_lock = threading.Lock()


# ---------------------------------------------------------------- plumbing


def _feed(params, player):
    res = LS.rpc(params, timeout=RENDER_TIMEOUT, player=player)
    return res, LS.parse_feed(res)


def matched_count(feed):
    """Releases with at least one playable source, by the plugin's own line2."""
    return sum(1 for r in feed.get("releases", []) if r.get("sources"))


def render_settled(params, player):
    """Render until the matched count stops RISING (see trap 1).

    The comparison is against the PREVIOUS render, not the best so far: a
    'best' comparison stops the moment a render improves, which is exactly the
    case that needs another look (13th Floor Elevators went 2 -> 12 -> 12).
    """
    first = prev = None
    best_res, best = None, None
    renders = 0
    for _ in range(MAX_RENDERS):
        res, feed = _feed(params, player)
        renders += 1
        m = matched_count(feed)
        if first is None:
            first = m
        if best is None or m > matched_count(best):
            best_res, best = res, feed
        if prev is not None and m <= prev:
            break
        prev = m
        time.sleep(SETTLE)
    best["_first_matched"] = first
    best["_renders"] = renders
    return best_res, best


def search_rows(query, player):
    """The search view's rows, each keeping its FULL go params so the drill can
    replay exactly what Material would send."""
    res = LS.rpc(["discography", "items", 0, SEARCH_MAX, f"search:{query}",
                  "menu:discography"], timeout=RENDER_TIMEOUT, player=player)
    rows, section = [], None
    for it in res.get("item_loop", []) or []:
        line1, line2 = LS.split_text(it.get("text", ""))
        if it.get("style") == "itemNoAction" and it.get("type") == "text":
            k = LS.section_key(line1)
            if k:
                section = k
            continue
        gp = ((it.get("actions") or {}).get("go") or {}).get("params") or {}
        if not (gp.get("artist") or gp.get("mbid") or gp.get("artist_id")):
            continue
        rows.append({
            "name": line1,
            "sources": [s.strip() for s in (line2 or "").split("·") if s.strip()],
            "params": {k: v for k, v in gp.items()
                       if k not in ("menu", "_index", "_quantity")},
            "section": section,
        })
    return res, rows


def drill(row, player):
    """Open the row with ITS OWN params -- no mbid of our invention."""
    params = ["discography", "items", 0, FEED_MAX]
    params += [f"{k}:{v}" for k, v in row["params"].items()]
    params += ["menu:discography"]
    return render_settled(params, player)


# ---------------------------------------------------------------- one artist


def measure(art, player):
    rec = {"artist_id": art["id"], "name": art["name"], "player": player}
    t0 = time.time()

    _, ref = render_settled(["discography", "items", 0, FEED_MAX,
                             f"artist_id:{art['id']}", f"artist:{art['name']}",
                             "menu:discography"], player)
    rec["ref"] = {
        "mbid": ref.get("artist_mbid"),
        "error": ref.get("error"),
        "releases": len(ref.get("releases", [])),
        "matched": matched_count(ref),
        "matched_first_render": ref.get("_first_matched"),
        "local": sum(1 for r in ref.get("releases", []) if "Local" in (r.get("sources") or [])),
        "lib_extras": len(ref.get("lib_extras", [])),
        "renders": ref.get("_renders"),
    }

    _, rows = search_rows(art["name"], player)
    want = LS.loose(art["name"])
    idx = next((i for i, r in enumerate(rows) if LS.loose(r["name"]) == want), None)
    rec["search"] = {"rows": len(rows), "self_rank": idx,
                     "row_names": [r["name"] for r in rows][:12]}

    pick = idx if idx is not None else (0 if rows else None)
    if pick is None:
        rec["search"]["picked"] = None
        rec["verdict"] = "no_rows"
        rec["elapsed"] = round(time.time() - t0, 2)
        return rec

    row = rows[pick]
    rec["search"].update({
        "picked": row["name"],
        "picked_index": pick,
        "picked_sources": row["sources"],
        "picked_has_local": "Local" in row["sources"],
        # THE POINT OF THE RUN: what identity does the row actually hand over?
        "entry_keys": sorted(row["params"].keys()),
        "name_folded": LS.loose(row["name"]) != want,
    })

    _, d = drill(row, player)
    rec["drill"] = {
        "mbid": d.get("artist_mbid"),
        "error": d.get("error"),
        "releases": len(d.get("releases", [])),
        "matched": matched_count(d),
        "matched_first_render": d.get("_first_matched"),
        "local": sum(1 for r in d.get("releases", []) if "Local" in (r.get("sources") or [])),
        "lib_extras": len(d.get("lib_extras", [])),
        "renders": d.get("_renders"),
    }

    rec["verdict"] = classify(rec)
    rec["elapsed"] = round(time.time() - t0, 2)
    return rec


def classify(rec):
    """Worst-first. Every verdict is a comparison against the artist's OWN
    reference render, so a thin discography is not mistaken for a defect."""
    s, d, r = rec["search"], rec.get("drill") or {}, rec["ref"]
    if not s.get("picked"):
        return "no_rows"
    if d.get("error"):
        return "drill_error"                       # "couldn't identify this artist"
    if r.get("mbid") and d.get("mbid") and r["mbid"] != d["mbid"]:
        return "wrong_artist"                      # search opened someone else
    if r["matched"] and not d.get("matched"):
        return "drill_empty"                       # rows path plays, search path does not
    if d.get("matched", 0) < r["matched"]:
        return "fewer_matches"
    if r["local"] and not d.get("local"):
        return "lost_local"                        # owned copy only found via the row
    if not s.get("picked_has_local") and (r["local"] or r["lib_extras"]):
        return "row_no_local"                      # owned artist, row does not say so
    if s.get("self_rank") is None:
        return "found_by_fold"                     # right artist under another name
    if s.get("self_rank"):
        return "ranked_low"
    return "ok"


# ---------------------------------------------------------------- phases


def players(args):
    res = LS.rpc(["players", 0, 99], timeout=30)
    macs = [p["playerid"] for p in res.get("players_loop", []) if p.get("connected")]
    if args.player:
        macs = [m for m in macs if m in args.player] or args.player
    return macs


def read_pref(name):
    try:
        res = LS.rpc(["pref", f"plugin.discography:{name}", "?"], timeout=20)
        return res.get("_p2")
    except Exception as exc:
        return f"?({type(exc).__name__})"


# hide_unmatched ON hides exactly what this run is looking for: a release the
# search path failed to resolve simply does not render, so every artist scores
# a perfect matched==releases and the sweep measures nothing. Checked, not
# assumed -- the last sweep was scrapped 111 artists in over a config trap.
REQUIRED = {"hide_unmatched": "0", "show_library_extras": "1"}

# AN UNTICKED CHECKBOX DOES NOT READ BACK AS "0" (field, 2026-07-31). Simon
# unticked "Hide releases you can't play" in the settings page and the pref
# read came back **None** -- the form stores an empty value, not a zero -- so a
# string compare against "0" called a correctly-configured server wrong. The
# plugin itself never cared: `$prefs->get('hide_unmatched')` is a plain truth
# test (Browse.pm:1590), and empty is false. So compare TRUTH, not spelling.
OFF = {None, "", "0", "off", "false", "no"}


def pref_is(name, want):
    got = read_pref(name)
    return ("0" if (got in OFF or str(got).strip() in OFF) else "1") == want, got


def check_prefs():
    bad = {}
    for k, want in REQUIRED.items():
        ok, got = pref_is(k, want)
        if not ok:
            bad[k] = (got, want)
    return bad


def phase_preflight(args):
    macs = players(args)
    print(f"server   {LS.BASE}")
    print(f"players  {len(macs)}: {', '.join(macs)}")
    arts = LS.album_artists()
    print(f"artists  {len(arts)} album artists")
    for k in ("hide_unmatched", "show_library_extras", "show_types",
              "show_streaming_extras", "debug_log"):
        got = read_pref(k)
        shown = "(empty)" if got in (None, "") else got
        off = " -> off" if got in OFF else ""
        print(f"pref     {k:22s} = {shown}{off}")
    bad = check_prefs()
    if bad:
        print("\nWRONG FOR THIS RUN -- misses would be invisible:")
        for k, (got, want) in bad.items():
            print(f"  {k} is {got}, needs {want}:")
            print(f"    curl -s {LS.BASE}/jsonrpc.js -d '{{\"id\":1,\"method\":"
                  f"\"slim.request\",\"params\":[\"\",[\"pref\","
                  f"\"plugin.discography:{k}\",\"{want}\"]]}}'")
    print("\n         debug_log is only useful with --workers 1 (see trap 2).")
    # Prove the feed answers on one artist rather than trusting the prefs read,
    # which cannot be done off-LAN.
    a = arts[0]
    _, ref = render_settled(["discography", "items", 0, 50,
                             f"artist_id:{a['id']}", f"artist:{a['name']}",
                             "menu:discography"], macs[0])
    rel, mat = len(ref.get("releases", [])), matched_count(ref)
    print(f"probe    {a['name']}: {rel} releases, {mat} matched, "
          f"mbid={ref.get('artist_mbid')}")
    # THE BEHAVIOURAL CHECK, and it outranks the pref read above. An unticked
    # checkbox stores an empty value rather than a zero, so the only evidence
    # that misses are visible is a render where some release has NO source.
    # rel == mat on an artist with a real discography means they are hidden.
    if rel and rel == mat:
        print("         ^ every release matched: unmatched are probably HIDDEN. "
              "Check the probe artist has real misses before trusting a run.")
    elif rel:
        print(f"         ^ {rel - mat} unmatched release(s) rendered - misses ARE visible")
    return 0


def done_ids():
    if not os.path.exists(JSONL):
        return set()
    out = set()
    with open(JSONL, encoding="utf-8") as fh:
        for ln in fh:
            try:
                out.add(int(json.loads(ln)["artist_id"]))
            except Exception:
                pass
    return out


def append(rec):
    with _lock:
        os.makedirs(OUT, exist_ok=True)
        with open(JSONL, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")


def phase_run(args):
    if args.log_slices and args.workers != 1:
        print("--log-slices needs --workers 1 (log lines cannot be attributed "
              "to an artist while workers interleave)", file=sys.stderr)
        return 2

    bad = check_prefs()
    if bad and not args.force:
        for k, (got, want) in bad.items():
            print(f"pref {k} is {got}, needs {want} - run 'preflight' for the "
                  f"command, or --force to measure anyway", file=sys.stderr)
        return 2

    macs = players(args)
    if not macs:
        print("no connected players", file=sys.stderr)
        return 2
    workers = min(args.workers, len(macs))
    if workers < args.workers:
        print(f"capped to {workers} worker(s): one player each, {len(macs)} available")

    arts = LS.album_artists()
    if args.only:
        want = [o.lower() for o in args.only]
        arts = [a for a in arts if any(o in a["name"].lower() for o in want)]
    if args.limit:
        arts = arts[:args.limit]
    if args.resume:
        seen = done_ids()
        arts = [a for a in arts if a["id"] not in seen]
        print(f"resuming: {len(arts)} left")

    pool = queue.Queue()
    for m in macs[:workers]:
        pool.put(m)

    t_start = time.time()
    counts = {}
    done = 0

    def task(a):
        mac = pool.get()
        try:
            return measure(a, mac)
        except Exception as exc:
            return {"artist_id": a["id"], "name": a["name"],
                    "verdict": "fatal", "error": f"{type(exc).__name__}: {exc}"}
        finally:
            pool.put(mac)

    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(task, a): a for a in arts}
        for fut in as_completed(futs):
            rec = fut.result()
            append(rec)
            done += 1
            v = rec.get("verdict", "?")
            counts[v] = counts.get(v, 0) + 1
            rate = (time.time() - t_start) / done
            eta = int(rate * (len(arts) - done))
            flag = "" if v == "ok" else f"  !! {v}"
            print(f"[{done}/{len(arts)}] {rec['name'][:38]:38s} "
                  f"{rec.get('elapsed', 0):5.1f}s  eta {eta//60}m{flag}")

    print("\n" + "  ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    return 0


def phase_report(_args):
    if not os.path.exists(JSONL):
        print("nothing recorded yet", file=sys.stderr)
        return 2
    recs = [json.loads(l) for l in open(JSONL, encoding="utf-8")]
    by = {}
    for r in recs:
        by.setdefault(r.get("verdict", "?"), []).append(r)

    order = ["fatal", "no_rows", "drill_error", "wrong_artist", "drill_empty",
             "fewer_matches", "lost_local", "row_no_local", "ranked_low",
             "found_by_fold", "ok"]
    print(f"{len(recs)} artists\n")
    for k in order + [k for k in by if k not in order]:
        if by.get(k):
            print(f"  {k:15s} {len(by[k]):5d}")

    # What identity did the search rows actually hand over? This is the answer
    # to "not using mbids" -- a row with only a name resolves by spelling.
    keys = {}
    for r in recs:
        k = ",".join((r.get("search") or {}).get("entry_keys") or []) or "(none)"
        keys[k] = keys.get(k, 0) + 1
    print("\nsearch row entry params:")
    for k, v in sorted(keys.items(), key=lambda x: -x[1]):
        print(f"  {k or '(none)':30s} {v:5d}")

    csv_path = os.path.join(OUT, "search_misses.csv")
    import csv as _csv
    with open(csv_path, "w", newline="", encoding="utf-8") as fh:
        w = _csv.writer(fh)
        w.writerow(["verdict", "artist", "artist_id", "ref_mbid", "drill_mbid",
                    "ref_matched", "drill_matched", "ref_local", "drill_local",
                    "row_picked", "row_rank", "row_sources", "entry_keys",
                    "search_rows", "row_names"])
        for r in recs:
            if r.get("verdict") in ("ok", "found_by_fold"):
                continue
            s, d, ref = r.get("search") or {}, r.get("drill") or {}, r.get("ref") or {}
            w.writerow([r.get("verdict"), r.get("name"), r.get("artist_id"),
                        ref.get("mbid"), d.get("mbid"),
                        ref.get("matched"), d.get("matched"),
                        ref.get("local"), d.get("local"),
                        s.get("picked"), s.get("self_rank"),
                        "/".join(s.get("picked_sources") or []),
                        ",".join(s.get("entry_keys") or []),
                        s.get("rows"), " | ".join((s.get("row_names") or [])[:8])])
    print(f"\nwrote {csv_path}")
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="phase", required=True)
    for name, fn in (("preflight", phase_preflight), ("run", phase_run),
                     ("report", phase_report)):
        p = sub.add_parser(name)
        p.set_defaults(fn=fn)
        p.add_argument("--player", action="append", default=[])
        if name == "run":
            p.add_argument("--workers", type=int, default=4)
            p.add_argument("--limit", type=int, default=0)
            p.add_argument("--resume", action="store_true")
            # Spot-check a named artist (substring, repeatable) without a
            # whole-library run -- how a reported case gets reproduced.
            p.add_argument("--only", action="append", default=[])
            p.add_argument("--log-slices", action="store_true")
            p.add_argument("--force", action="store_true")
    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
