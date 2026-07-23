#!/usr/bin/env python3
"""Analysis for library_sweep.py -- turns the raw JSONL into a report.

Every finding here is bucketed by the DEFECT CLASS it points at, not just
counted, because the point of the sweep is to decide what to fix next. Each
bucket names real artists and releases so a claim can be re-checked live
against the box rather than taken on trust.
"""

import csv
import gzip
import json
import os
import statistics
import sys

SERVICES = ("Local", "Qobuz", "Tidal", "Deezer")
STREAMING = ("Qobuz", "Tidal", "Deezer")


def load(out, phase):
    path = os.path.join(out, f"{phase}.jsonl")
    if not os.path.exists(path):
        return []
    # A resumed run can record an artist twice (a retried failure). Keep the
    # LAST record, so a successful retry supersedes the earlier failure.
    latest = {}
    order = []
    with open(path, encoding="utf-8") as fh:
        for ln in fh:
            try:
                r = json.loads(ln)
            except Exception:
                continue
            key = r.get("key", r.get("artist_id"))
            if key not in latest:
                order.append(key)
            latest[key] = r
    return [latest[k] for k in order]


def classify_releases(out):
    """Re-read the saved raw feeds and classify every UNMATCHED release.

    A raw unmatched count is misleading and would overstate the problem badly.
    Three quite different things render identically as a sourceless row:

      rival_loser  another release group by the same artist normalises to the
                   SAME title and DID match. The 0.16.0 rival-owner rule gives
                   a candidate to exactly one group, so the loser is unmatched
                   BY DESIGN. With hide_unmatched on -- every real user's
                   config -- it is hidden, so this is a test artefact, not a
                   defect.
      no_pool      every streaming service returned an empty candidate pool for
                   this artist. Nothing could have matched; the failure is
                   artist resolution, one level up from the matcher.
      genuine      the pools were healthy and the title still did not match.
                   THIS is the matcher's real miss rate.
    """
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import library_sweep as ls

    raw_dir = os.path.join(out, "raw", "browse")
    if not os.path.isdir(raw_dir):
        return [], {}

    by_artist = {r["artist_id"]: r for r in load(out, "browse")}
    rows = []
    for fn in sorted(os.listdir(raw_dir)):
        if not fn.endswith(".json.gz"):
            continue
        aid = int(fn.split(".")[0])
        try:
            with gzip.open(os.path.join(raw_dir, fn), "rt", encoding="utf-8") as fh:
                feed = ls.parse_feed(json.load(fh))
        except Exception as exc:
            # Never swallow this silently: a blanket skip once hid a NameError
            # here and the whole classification came back empty but "successful".
            print(f"  ! could not classify {fn}: {type(exc).__name__}: {exc}", file=sys.stderr)
            continue
        rec = by_artist.get(aid, {})
        pools = (rec.get("log") or {}).get("pools", {}) or {}
        streaming_pool = sum(pools.get(s, 0) for s in ("Qobuz", "Tidal", "Deezer"))

        matched_titles = {ls.loose(r["title"]) for r in feed["releases"] if r["sources"]}
        for r in feed["releases"]:
            if r["sources"]:
                continue
            key = ls.loose(r["title"])
            if key in matched_titles:
                kind = "rival_loser"
            elif streaming_pool == 0:
                kind = "no_pool"
            else:
                kind = "genuine"
            rows.append({
                "artist_id": aid,
                "artist": rec.get("name", ""),
                "title": r["title"],
                "year": r["year"],
                "type": r["type"],
                "section": r["section"],
                "kind": kind,
                "streaming_pool": streaming_pool,
            })
    tally = {}
    for r in rows:
        tally[r["kind"]] = tally.get(r["kind"], 0) + 1
    return rows, tally


def write_csv(out, name, fieldnames, rows):
    path = os.path.join(out, name)
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=fieldnames, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow(r)
    return path


def pct(n, d):
    return f"{(100.0 * n / d):.1f}%" if d else "n/a"


def table(rows, headers):
    if not rows:
        return "_none_\n"
    out = ["| " + " | ".join(headers) + " |",
           "|" + "|".join("---" for _ in headers) + "|"]
    for r in rows:
        out.append("| " + " | ".join(str(c) for c in r) + " |")
    return "\n".join(out) + "\n"


def main(out):
    browse = load(out, "browse")
    search = load(out, "search")
    variants = load(out, "variants")
    if not browse and not search:
        print("nothing recorded yet -- run the browse phase first")
        return 1

    md = ["# Discography — full-library sweep", ""]
    md.append(f"Source data: `{out}` — "
              f"{len(browse)} artists browsed, {len(search)} searched, "
              f"{len(variants)} variant probes.\n")

    ok = [r for r in browse if not r.get("fatal")]
    fatal = [r for r in browse if r.get("fatal")]

    # ---------------------------------------------------------- headline
    rel_total = sum(r.get("release_total", 0) for r in ok)
    rel_matched = sum(r.get("release_matched", 0) for r in ok)
    owned_total = sum(r.get("owned", 0) for r in ok)
    owned_unclaimed = sum(r.get("owned_unclaimed", 0) for r in ok)
    elapsed = [r["elapsed"] for r in ok if r.get("elapsed")]

    md.append("## Headline\n")
    md.append(table([
        ["Artists browsed", len(ok)],
        ["Artists that failed outright", len(fatal)],
        ["Release groups rendered", rel_total],
        ["Release groups with >=1 playable source", f"{rel_matched} ({pct(rel_matched, rel_total)})"],
        ["Release groups with NO source", f"{rel_total - rel_matched} "
                                          f"({pct(rel_total - rel_matched, rel_total)})"],
        ["Owned albums seen", owned_total],
        ["Owned albums not attached to a tile", f"{owned_unclaimed} "
                                                f"({pct(owned_unclaimed, owned_total)}) "
                                                f"— mostly by design, see section D"],
        ["Median render", f"{statistics.median(elapsed):.2f}s" if elapsed else "n/a"],
        ["Slowest render", f"{max(elapsed):.1f}s" if elapsed else "n/a"],
    ], ["Measure", "Value"]))

    # ------------------------------------------- A: artist identification
    unresolved = [r for r in ok if r.get("error") == "unresolved"]
    empty_spine = [r for r in ok if r.get("error") == "empty_spine"]
    no_mbid = [r for r in ok if not r.get("mbid") and not r.get("error")]

    md.append("\n## A. Artist identification\n")
    md.append(f"- **Not identified on MusicBrainz:** {len(unresolved)} "
              f"({pct(len(unresolved), len(ok))})\n")
    md.append(f"- **Identified but empty page:** {len(empty_spine)}\n")
    md.append(f"- **No MBID visible in the feed (no tiles to carry one):** {len(no_mbid)}\n\n")
    md.append(table([[r["name"], r.get("owned", 0)] for r in
                     sorted(unresolved, key=lambda x: -x.get("owned", 0))[:40]],
                    ["Unidentified artist", "Albums you own"]))
    md.append("\n")
    md.append(table([[r["name"], r.get("owned", 0)] for r in
                     sorted(empty_spine, key=lambda x: -x.get("owned", 0))[:30]],
                    ["Empty discography", "Albums you own"]))

    # ------------------------------- B: whole-service resolution failures
    svc_totals = {s: sum(r.get("by_service", {}).get(s, 0) for r in ok) for s in SERVICES}
    md.append("\n## B. Service coverage\n")
    md.append(table([[s, svc_totals[s], pct(svc_totals[s], rel_total)] for s in SERVICES],
                    ["Source", "Releases matched", "Of all releases"]))

    blackouts = {s: [] for s in STREAMING}
    for r in ok:
        bs = r.get("by_service", {})
        if r.get("release_total", 0) < 4:
            continue
        best = max((bs.get(s, 0) for s in STREAMING), default=0)
        for s in STREAMING:
            if bs.get(s, 0) == 0 and best >= 3:
                blackouts[s].append(r)

    md.append("\n### Service blackouts\n")
    md.append("An artist where one streaming service matched **nothing** while another matched "
              "at least three releases. This is an artist-entity resolution failure on that "
              "service, not a title-matching failure — the whole catalogue is missing.\n\n")
    md.append(table([[s, len(blackouts[s]), pct(len(blackouts[s]), len(ok))] for s in STREAMING],
                    ["Service", "Blackout artists", "Of artists browsed"]))
    for s in STREAMING:
        rows = sorted(blackouts[s], key=lambda x: -x.get("release_total", 0))[:20]
        if rows:
            md.append(f"\n**{s} blackouts (worst 20 by catalogue size)**\n\n")
            md.append(table([[r["name"], r.get("release_total", 0),
                              "/".join(f"{o}:{r.get('by_service', {}).get(o, 0)}"
                                       for o in STREAMING if o != s),
                              ", ".join(r.get("log", {}).get("unresolved_services", []) or ["-"])]
                             for r in rows],
                            ["Artist", "Releases", "Other services", "Logged UNRESOLVED"]))

    # ------------------------------------------- C: per-release matching
    zero = [r for r in ok if r.get("release_total", 0) >= 3 and r.get("release_matched", 0) == 0]
    md.append("\n## C. Release matching\n")
    md.append(f"- **Artists where nothing at all matched** (>=3 releases): {len(zero)}\n\n")
    md.append(table([[r["name"], r.get("release_total", 0), r.get("owned", 0),
                      ", ".join(f"{k}={v}" for k, v in
                                sorted(r.get("log", {}).get("pools", {}).items()))]
                     for r in sorted(zero, key=lambda x: -x.get("release_total", 0))[:30]],
                    ["Artist", "Releases", "Owned", "Candidate pools (from log)"]))

    miss_rows, miss_tally = classify_releases(out)
    if miss_rows:
        tot_miss = len(miss_rows)
        md.append("\n### What the unmatched releases actually are\n")
        md.append("A sourceless row has three quite different causes, and lumping them "
                  "together would overstate the problem. Only the last is a matcher miss.\n\n")
        md.append(table([
            ["rival_loser", miss_tally.get("rival_loser", 0),
             pct(miss_tally.get("rival_loser", 0), tot_miss),
             "By design (0.16.0) — hidden in normal use"],
            ["no_pool", miss_tally.get("no_pool", 0),
             pct(miss_tally.get("no_pool", 0), tot_miss),
             "Artist never resolved on any service"],
            ["genuine", miss_tally.get("genuine", 0),
             pct(miss_tally.get("genuine", 0), tot_miss),
             "Healthy pool, title still missed"],
        ], ["Class", "Releases", "Share of misses", "Meaning"]))
        genuine_rate = pct(miss_tally.get("genuine", 0), rel_total)
        md.append(f"\n**Unmatched with a healthy pool: {genuine_rate} of all release groups** "
                  f"({miss_tally.get('genuine', 0)} of {rel_total}).\n")
        md.append("\n> **Read this bucket carefully.** It bundles two things the feed cannot "
                  "tell apart: releases the services genuinely do not sell (MusicBrainz "
                  "catalogues promos, regional editions and one-off singles that no streaming "
                  "service carries), and releases the matcher failed to match. A high number "
                  "here is therefore expected and is **not** by itself a defect count. The "
                  "actionable subset is the studio-album section, below — a missing *album* by "
                  "an artist whose pool is healthy is the shape a real matcher bug takes.\n")

        by_section = {}
        for r in miss_rows:
            if r["kind"] != "genuine":
                continue
            key = r["section"] or "?"
            by_section[key] = by_section.get(key, 0) + 1
        order = ["ALBUMS", "EPS", "SINGLES", "COMPILATIONS", "LIVE", "OTHER"]
        md.append("\n**Genuine misses by section**\n\n")
        md.append(table([[k, by_section.get(k, 0)] for k in order if by_section.get(k)]
                        + [[k, v] for k, v in sorted(by_section.items()) if k not in order],
                        ["Section", "Unmatched with healthy pool"]))

        alb = [r for r in miss_rows if r["kind"] == "genuine" and r["section"] == "ALBUMS"]
        worst_alb = {}
        for r in alb:
            worst_alb[r["artist"]] = worst_alb.get(r["artist"], 0) + 1
        md.append(f"\n**Studio albums unmatched despite a healthy pool — {len(alb)} in total.** "
                  f"This is the list worth walking by hand.\n\n")
        md.append(table([[r["artist"], r["title"], r["year"] or "", r["streaming_pool"]]
                         for r in sorted(alb, key=lambda x: (x["artist"], x["year"] or 0))][:60],
                        ["Artist", "Album", "Year", "Pool size"]))
        write_csv(out, "unmatched_albums_healthy_pool.csv",
                  ["artist", "artist_id", "title", "year", "section", "streaming_pool"], alb)
        write_csv(out, "unmatched_classified.csv",
                  ["artist", "artist_id", "title", "year", "type", "section", "kind",
                   "streaming_pool"], miss_rows)

        worst = {}
        for r in miss_rows:
            if r["kind"] == "genuine":
                worst[r["artist"]] = worst.get(r["artist"], 0) + 1
        md.append("\n**Artists with the most genuine title misses**\n\n")
        md.append(table(sorted(worst.items(), key=lambda kv: -kv[1])[:25],
                        ["Artist", "Genuine misses"]))

    partial = []
    for r in ok:
        if not r.get("release_total"):
            continue
        miss = r.get("release_unmatched", 0)
        if miss:
            partial.append((miss / r["release_total"], miss, r))
    partial.sort(key=lambda x: (-x[0], -x[1]))
    md.append("\n### Worst per-artist miss rates (>=6 releases)\n\n")
    md.append(table([[r["name"], f"{ratio*100:.0f}%", miss, r.get("release_total", 0)]
                     for ratio, miss, r in partial if r.get("release_total", 0) >= 6][:30],
                    ["Artist", "Missed", "Unmatched", "Releases"]))

    # ---------------------------------------------- D: local library gaps
    lib_extras_total = sum(r.get("lib_extras", 0) for r in ok)
    appearances_total = sum(r.get("appearances", 0) for r in ok)
    gap_artists = [r for r in ok if r.get("lib_extras", 0)]

    md.append("\n## D. Local library matching\n")
    md.append("An owned album that never became a tile lands in one of two sections, and "
              "only one of them is a defect:\n\n")
    md.append(table([
        ["*Also in your library*", lib_extras_total,
         "**The real gap.** Your own record by this artist that the MusicBrainz spine "
         "did not claim — a missing release group or a title the matcher missed."],
        ["*Appearances*", appearances_total,
         "By design. Various-artists compilations and guest spots, which are not this "
         "artist's own release groups and are not expected to become tiles."],
    ], ["Section", "Albums", "Meaning"]))
    md.append(f"\n**Real local-match gap: {lib_extras_total} of {owned_total} owned albums "
              f"({pct(lib_extras_total, owned_total)}), across {len(gap_artists)} artists.**\n\n")
    md.append(table([[r["name"], r["lib_extras"], r.get("owned", 0),
                      "; ".join(r.get("unclaimed_titles", [])[:3])]
                     for r in sorted(gap_artists, key=lambda x: -x["lib_extras"])[:40]],
                    ["Artist", "Unclaimed own records", "Owned", "Examples"]))

    # ------------------------------------------------------- E: search
    if search:
        sok = [r for r in search if not r.get("fatal")]
        notfound = [r for r in sok if r.get("self_hit_index") is None]
        ranked = [r for r in sok if (r.get("self_hit_index") or 0) > 0]
        nolocal = [r for r in sok if r.get("self_hit_index") is not None
                   and not r.get("self_hit_local")]
        md.append("\n## E. Search\n")
        md.append("Typing each artist's own name into the plugin's search and asking whether "
                  "they come back, come back **first**, and come back carrying their **Local** "
                  "source (a missing Local source means the user is not told they own the music).\n\n")
        md.append(table([
            ["Names searched", len(sok)],
            ["Artist not returned at all", f"{len(notfound)} ({pct(len(notfound), len(sok))})"],
            ["Artist returned but not first", f"{len(ranked)} ({pct(len(ranked), len(sok))})"],
            ["Returned without a Local source", f"{len(nolocal)} ({pct(len(nolocal), len(sok))})"],
        ], ["Measure", "Value"]))
        md.append("\n**Not returned by their own name**\n\n")
        md.append(table([[r["name"], r.get("rows", 0), "; ".join(r.get("row_names", [])[:3])]
                         for r in notfound[:40]],
                        ["Artist", "Rows returned", "What came back instead"]))
        md.append("\n**Returned without a Local source**\n\n")
        md.append(table([[r["name"], r.get("self_hit_exact_name"),
                          "/".join(r.get("self_hit_sources") or [])]
                         for r in nolocal[:30]],
                        ["Artist", "Row label", "Sources shown"]))

    # ----------------------------------------------------- F: variants
    if variants:
        vok = [r for r in variants if not r.get("fatal")]
        vlost = [r for r in vok if r.get("self_hit_index") is None]
        vnolocal = [r for r in vok if r.get("self_hit_index") is not None
                    and not r.get("self_hit_local")]
        md.append("\n## F. Punctuation, accents and the `and`/`&` fold\n")
        md.append("Searching a **plain spelling** of a decorated name — accents stripped, "
                  "`&` written `and`, apostrophes and `!` dropped — which is what a user "
                  "actually types.\n\n")
        md.append(table([
            ["Variant spellings probed", len(vok)],
            ["Artist lost entirely", f"{len(vlost)} ({pct(len(vlost), len(vok))})"],
            ["Found but Local source lost", f"{len(vnolocal)} ({pct(len(vnolocal), len(vok))})"],
        ], ["Measure", "Value"]))
        md.append("\n**Lost entirely on the plain spelling**\n\n")
        md.append(table([[r["name"], r["query"], r.get("rows", 0)] for r in vlost[:40]],
                        ["Artist", "Typed as", "Rows returned"]))
        md.append("\n**Local source lost on the plain spelling**\n\n")
        md.append(table([[r["name"], r["query"]] for r in vnolocal[:30]],
                        ["Artist", "Typed as"]))

    # ------------------------------------------------- G: ambiguity / logs
    ambig = [r for r in ok if r.get("same_name")]
    unres_svc = [r for r in ok if r.get("log", {}).get("unresolved_services")]
    dropped = [r for r in ok if r.get("log", {}).get("dropped")]
    md.append("\n## G. Same-name acts and foreign-artist drops\n")
    md.append(f"- Artists rendering an *Other artists with this name* section: **{len(ambig)}**\n")
    md.append(f"- Artists where a service settled UNRESOLVED against the spine: **{len(unres_svc)}**\n")
    md.append(f"- Artists where the foreign-artist filter dropped albums: **{len(dropped)}**\n\n")
    md.append(table([[r["name"], r.get("same_name", 0), r.get("release_total", 0),
                      r.get("release_matched", 0),
                      ", ".join(r.get("log", {}).get("unresolved_services", []) or ["-"])]
                     for r in sorted(ambig, key=lambda x: -x.get("same_name", 0))[:30]],
                    ["Artist", "Same-name rows", "Releases", "Matched", "Unresolved services"]))
    md.append("\n**Heaviest foreign-artist drops** (albums removed from the candidate pool)\n\n")
    drows = []
    for r in dropped:
        d = r["log"]["dropped"]
        drows.append((sum(d.values()), r["name"], d, r.get("release_matched", 0),
                      r.get("release_total", 0)))
    drows.sort(reverse=True)
    md.append(table([[name, tot, ", ".join(f"{k}={v}" for k, v in sorted(d.items())),
                      f"{m}/{t}"] for tot, name, d, m, t in drows[:25]],
                    ["Artist", "Dropped", "By service", "Matched"]))

    # ----------------------------------------------------- H: performance
    slow = sorted((r for r in ok if r.get("elapsed")), key=lambda x: -x["elapsed"])[:20]
    md.append("\n## H. Performance\n")
    md.append(table([[r["name"], f"{r['elapsed']:.1f}s", r.get("release_total", 0),
                      r.get("log", {}).get("dbg_lines", 0)]
                     for r in slow],
                    ["Artist", "Render", "Releases", "Debug lines"]))

    truncated = [r for r in ok if r.get("log_truncated")]
    if truncated:
        md.append(f"\n> **Caveat:** the log window was outrun for {len(truncated)} artists, "
                  f"so their per-release reasoning is incomplete. Counts from the feed itself "
                  f"are unaffected.\n")

    # ------------------------------------------------------------ CSVs
    write_csv(out, "artists.csv",
              ["artist_id", "name", "mbid", "error", "release_total", "release_matched",
               "release_unmatched", "owned", "owned_unclaimed", "lib_extras", "appearances",
               "stream_extras", "same_name", "elapsed"],
              [dict(r, **{f"svc_{k}": v for k, v in r.get("by_service", {}).items()})
               for r in ok])

    unmatched_rows = []
    for r in ok:
        for t in r.get("unmatched_titles", []):
            unmatched_rows.append({"artist": r["name"], "artist_id": r["artist_id"], "title": t})
    write_csv(out, "unmatched_releases.csv", ["artist", "artist_id", "title"], unmatched_rows)

    unclaimed_rows = []
    for r in ok:
        for t in r.get("unclaimed_titles", []):
            unclaimed_rows.append({"artist": r["name"], "artist_id": r["artist_id"], "album": t})
    write_csv(out, "unclaimed_local_albums.csv", ["artist", "artist_id", "album"], unclaimed_rows)

    if search:
        write_csv(out, "search.csv",
                  ["artist_id", "name", "rows", "self_hit_index", "self_hit_exact_name",
                   "self_hit_local"], [r for r in search if not r.get("fatal")])
    if variants:
        write_csv(out, "variants.csv",
                  ["artist_id", "name", "query", "rows", "self_hit_index", "self_hit_local"],
                  [r for r in variants if not r.get("fatal")])

    path = os.path.join(out, "REPORT.md")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(md))
    print(f"wrote {path}")
    print(f"wrote CSVs in {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "sweep"))
