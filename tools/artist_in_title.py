#!/usr/bin/env python3
"""Albums whose TITLE carries the artist's own name — recomputed live.

Simon asked for the list the 2026-07-21/22 sweep surfaced as "21 albums carry
an artist/surname prefix" (CLAUDE.md, "SIMON'S OWN TAGGING"). That measurement
was a by-product of the identity-index run and kept no file, so this recomputes
it against the LIVE library over HTTP, using the sweep's own rule — variants()
and strip_prefix() are lifted verbatim from tools/mb_identity_probe.py, so the
answer is the same one the tier-5 measurement gave, not a fresh approximation.

TWO CLASSES, and only the first is a tagging artefact:

  prefix     "Springsteen: The Ghost of Tom Joad" — the artist's name (or
             surname) prepended with a separator. This is what the sweep
             flagged: MB titles the release group without it, so the match
             depends on the T5 strip firing.
  elsewhere  "The Freewheelin' Bob Dylan" — the name inside a title that is
             genuinely called that. Recorded for completeness and NOT a defect;
             a handful are on the known-matcher-gap list instead.

TWO THINGS THE ROW-LEVEL NOTES CALL OUT, both learned the hard way:
  * "Talking Heads: 77" is a REAL album title. The strip must never run
     indiscriminately — it survives only because T5 fires after the earlier
     tiers miss, and this one resolves at T1.
  * Gil Scott-Heron's tag carries U+2010 in the ARTIST while the title uses an
     ASCII hyphen, so the prefix compare misses a case that plainly is one.
     Normalising dashes on both sides is the "known cheap gain" in CLAUDE.md;
     it is done here (dash_variant=1 marks those rows) so the list is honest,
     and it is what the plugin-side fix would have to do too.

CLASSICAL is excluded by ARTIST (orchestras, ensembles, Various), per Simon's
"ignoring classical here as thats very common". Composers reached by their own
name still slip through the artist filter, so those rows are marked
likely_classical=1 rather than silently dropped.

    python3 tools/artist_in_title.py [--server http://plex:9000] [-o FILE]
"""
import argparse, csv, json, re, sys, unicodedata, urllib.request

CLASSICAL_ARTIST = re.compile(
    r"various|orchestra|philharmon|symphon|ensemble|quartet|quintet|trio\b|choir|"
    r"consort|academy|sinfoni|camerata|players|collegium|capella|cappella|"
    r"chamber|baroque|opera|concerto|philharmonia", re.I)

# Composers who reach the list under their own name — the artist filter above
# cannot catch these, so they are flagged instead of dropped.
COMPOSER = re.compile(
    r"saint-sa|mendelssohn|rossini|berlioz|sibelius|tchaikovsky|bernstein|"
    r"morricone|mahler|beethoven|mozart|vivaldi|shostakovich|stravinsky", re.I)

DASHES = dict.fromkeys(map(ord, "‐‑‒–—―−"), "-")

# Rows where the TAGGED form is MusicBrainz's real title, so stripping the
# prefix would be wrong. Only entries MEASURED against MB belong here — the
# 2026-07-22 identity run resolved "Talking Heads: 77" at tier 1, which is
# exactly why the T5 strip must run only after the earlier tiers miss. Every
# other row is UNVERIFIED: the column is blank, not "no".
REAL_TITLE = {31001: "yes (measured 2026-07-22, resolves at T1)"}


def norm(s):
    s = unicodedata.normalize("NFD", s or "")
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.sub(r"[^0-9a-z]+", " ", s.lower()).strip()


def variants(name):
    """Spellings of the artist a tagger might have used as a title prefix."""
    n = (name or "").strip()
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
                return cand, rest
    return None


def albums(server):
    req = urllib.request.Request(
        server.rstrip("/") + "/jsonrpc.js",
        data=json.dumps({"id": 1, "method": "slim.request",
                         "params": ["", ["albums", 0, 20000, "tags:la"]]}).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.load(r)["result"].get("albums_loop", [])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", default="http://plex:9000")
    # The 'elsewhere' class is titles that genuinely contain the name, so it is
    # off by default: what is actionable is the PREFIX class, where MB titles
    # the release group without the prefix and `title_without_prefix` is the
    # real title. --all restores the full list.
    ap.add_argument("--all", action="store_true")
    # tools/, not sweep/ — sweep/ is gitignored (it holds the raw archives), so
    # a file written there would never reach the repo.
    ap.add_argument("-o", "--out", default="tools/artist_in_title.csv")
    a = ap.parse_args()

    rows, skipped = [], 0
    for al in albums(a.server):
        artist, title = al.get("artist") or "", al.get("album") or ""
        if not artist or not title or CLASSICAL_ARTIST.search(artist):
            skipped += 1
            continue
        if norm(title) == norm(artist):        # self-titled is not a defect
            continue

        hit = strip_prefix(artist, title)
        dash = 0
        if not hit:
            # Same compare with every dash folded to ASCII, on BOTH sides.
            h2 = strip_prefix(artist.translate(DASHES), title.translate(DASHES))
            if h2:
                hit, dash = h2, 1
        if hit:
            rows.append(dict(cls="prefix", artist=artist, album=title,
                             album_id=al.get("id"), matched=hit[0], stripped=hit[1],
                             dash_variant=dash,
                             likely_classical=1 if COMPOSER.search(artist) else 0))
            continue

        nt = norm(title)
        for v in sorted(variants(artist), key=len, reverse=True):
            nv = norm(v)
            if len(nv) > 3 and re.search(r"\b" + re.escape(nv) + r"\b", nt):
                rows.append(dict(cls="elsewhere", artist=artist, album=title,
                                 album_id=al.get("id"), matched=v, stripped="",
                                 dash_variant=0,
                                 likely_classical=1 if COMPOSER.search(artist) else 0))
                break

    if not a.all:
        rows = [r for r in rows if r["cls"] == "prefix"]
    rows.sort(key=lambda r: (r["cls"] != "prefix", r["artist"].lower(), r["album"].lower()))
    with open(a.out, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["class", "artist", "album_as_tagged", "album_id",
                    "matched_spelling", "title_without_prefix",
                    "dash_variant", "likely_classical", "tagged_form_is_real_title"])
        for r in rows:
            w.writerow([r["cls"], r["artist"], r["album"], r["album_id"],
                        r["matched"], r["stripped"], r["dash_variant"],
                        r["likely_classical"], REAL_TITLE.get(r["album_id"], "")])

    n = sum(1 for r in rows if r["cls"] == "prefix")
    print(f"{a.out}: {len(rows)} rows ({n} prefix, {len(rows)-n} elsewhere); "
          f"{skipped} classical/incomplete rows skipped by artist")


if __name__ == "__main__":
    sys.exit(main())
