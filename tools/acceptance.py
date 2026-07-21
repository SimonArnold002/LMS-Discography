#!/usr/bin/env python3
"""Live acceptance probe for the Discography plugin.

WHY THIS EXISTS
---------------
Every regression in this plugin so far has had the same shape: a change is
verified against the thing it fixed, on a server whose caches are already WARM,
and the coupling to some other feature is never exercised. 0.44.3 version-scoped
the candidate pools (correct in isolation) and silently broke `hide_unmatched`,
because that pref reads the pool and treats "cold" as "unresolved".

So this probe tests behaviour the user can SEE, and — crucially — tests it COLD
as well as warm. A check that only passes on the second render is a regression,
not a pass.

USAGE
    python3 tools/acceptance.py [--host plex:9000] [--player <mac>]

Exit code 0 = all checks passed. Any failure prints the evidence.

Requires the plugin's own `clearcache` CLI, so it is safe to run repeatedly;
it only clears the artists it tests.
"""

import argparse
import json
import sys
import time
import urllib.request

FAILED = []
PASSED = []


def rpc(host, player, cmd, timeout=180):
    body = json.dumps({"id": 1, "method": "slim.request",
                       "params": [player or "", cmd]}).encode()
    req = urllib.request.Request("http://%s/jsonrpc.js" % host, data=body,
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=timeout)).get("result", {})


def rows(host, player, params, count=400):
    r = rpc(host, player, ["discography", "items", "0", str(count),
                           "menu:discography"] + params)
    return [i.get("text", "") for i in r.get("item_loop", [])]


def log_tail(host, lines=3000):
    """LMS's log.txt returns a ~155-line tail by DEFAULT — far too short.

    A single discography render writes ~100 `match` lines, so anything logged
    at the START of a build (cache keys, service fetches, the cold-pool await)
    is evicted before it can be read. That truncation produced a confidently
    WRONG diagnosis on 2026-07-19: "no fetch lines, therefore clearcache is
    broken" — from a window that could not have contained them. clearcache was
    fine. Always pass ?lines=.
    """
    u = "http://%s/log.txt?lines=%d" % (host, lines)
    return urllib.request.urlopen(u, timeout=40).read().decode("utf8", "replace")


def clear(host, artist, mbid=None):
    cmd = ["discography", "clearcache", "artist:" + artist]
    if mbid:
        cmd.append("mbid:" + mbid)
    rpc(host, None, cmd)


def check(name, ok, detail=""):
    (PASSED if ok else FAILED).append(name)
    print("  %-58s %s" % (name, "PASS" if ok else "FAIL"))
    if not ok and detail:
        for line in str(detail).splitlines():
            print("      " + line)


def release_rows(rs):
    """Rows that are a release tile: 'Title\\nYear · Type[ · Services]'."""
    out = []
    for r in rs:
        if "\n" not in r:
            continue
        second = r.split("\n")[1]
        if "·" in second or second.strip().isdigit():
            out.append(r)
    return out


def unmatched(rs):
    return [r for r in release_rows(rs)
            if not any(s in r for s in ("Qobuz", "Tidal", "Deezer", "Local"))]


# --------------------------------------------------------------------------
# The checks. Each one encodes a behaviour a USER reported, with the artist
# that exposed it — so a future change that reintroduces the bug fails here
# rather than in Simon's living room.
# --------------------------------------------------------------------------

SKA_MADNESS = "5f58803e-8c4c-478e-8b51-477f38483ede"
HUANG_BOOM = "13a1f939-9e60-495f-b5f5-71c4bb3438a7"


def test_hide_unmatched_cold(host, player):
    """hide_unmatched must hold on the FIRST render, not just once warm.

    Regression: 0.44.3's version-scoped pools made every artist cold after an
    update, and the `!resolved` exemption then ignored the pref entirely —
    93 releases shown, 85 of them unmatched, correcting only on a revisit.

    STRENGTHENED 2026-07-19. This check was previously annotated "weak: a PASS
    proves nothing", on the belief that `clearcache` could not empty the pool.
    That belief was WRONG, and instructive: it came from grepping LMS's log.txt,
    which returns only a ~155-line tail by default, while each render writes
    ~100 `match` lines — so the cache-key and service-fetch evidence was evicted
    before it could be read. With `?lines=3000` the log shows the clear working
    exactly as intended (`[HIT->gone]`), a genuinely cold read (`miss`), the
    await firing, and a real refetch. See log_tail().

    So this check is now meaningful: clearcache really does produce a cold pool,
    and with the 0.44.8 await in place a cold render must still honour the pref.
    """
    print("\n[hide_unmatched, COLD pool]")
    pref = rpc(host, None, ["pref", "plugin.discography:hide_unmatched", "?"]).get("_p2")
    if str(pref) != "1":
        print("  SKIPPED (hide_unmatched is off on this server)")
        return
    clear(host, "Madness", SKA_MADNESS)
    rs = rows(host, player, ["artist:Madness", "mbid:" + SKA_MADNESS])
    un = unmatched(rs)
    check("cold render hides unmatched releases", not un,
          "%d unmatched shown of %d releases; first 3:\n%s"
          % (len(un), len(release_rows(rs)),
             "\n".join(repr(u.replace("\n", " | ")) for u in un[:3])))


def test_dead_end_rows(host, player):
    """Search must not offer rows whose page is empty.

    'Beats of Genesis' -> "No releases found"; 'Genesis Tajiri' -> cannot be
    identified. Both must be absent. 'Genesis Brass' and 'Genesis Piano
    Project' are REAL artists with releases and must survive — they are the
    false-positive guard, and two earlier filter designs failed exactly here.
    """
    print("\n[search rows lead somewhere]")
    clear(host, "Genesis")
    rs = rows(host, player, ["search:Genesis"], count=60)
    names = [r.split("\n")[0] for r in rs]
    for dead in ("Beats of Genesis", "Genesis Tajiri"):
        check("dead end hidden: %s" % dead, dead not in names)
    for live in ("Genesis Brass", "Genesis Piano Project"):
        check("real artist kept: %s" % live, live in names,
              "present rows: %s" % ", ".join(names[:12]))


def test_same_name_section_cold(host, player):
    """The disambiguation section must not list acts with zero releases.

    Regression: the filter peeked a count warmed in the BACKGROUND, so the
    first search listed everything (a cold 'Bush' search offered the 'techno'
    act, which has 0 release groups) and a later search silently removed them.
    """
    print("\n[same-name section, COLD]")
    clear(host, "Bush")
    rs = rows(host, player, ["search:Bush"], count=60)
    idx = next((i for i, t in enumerate(rs) if "Other artists" in t), None)
    if idx is None:
        check("Bush disambiguation section present", False, "no section rendered")
        return
    section = rs[idx + 1:]
    check("no zero-release act listed (Bush/techno)",
          not any(s.split("\n")[-1].strip() == "techno" for s in section),
          "section rows:\n" + "\n".join(repr(s.replace("\n", " | ")) for s in section))


def test_secondary_act_bio(host, player):
    """A secondary same-name act must not show the prominent act's biography.

    Regression: the guard PEEKED the candidate cache and a miss answered "not
    shared", so the first visit rendered Pete Kember's biography on the Andrew
    Huang / Rob Scallon group's page. Cold render is the whole point.
    """
    print("\n[secondary act biography, COLD]")
    clear(host, "Sonic Boom", HUANG_BOOM)
    rs = rows(host, player, ["artist:Sonic Boom", "mbid:" + HUANG_BOOM], count=12)
    leaked = [r for r in rs if "Kember" in r or "Spacemen" in r]
    check("no prominent-act bio on secondary page", not leaked,
          "\n".join(repr(r[:120]) for r in leaked))


def test_alias_folding(host, player):
    """Service entities that are the SAME MusicBrainz artist collapse to one row.

    Qobuz lists "Eurythmics" and "The Eurythmics" as separate artists; both
    build their page from MBID b4d32cff-..., because MB records the second as
    an ALIAS of the first (alias field, score 100). Two rows to an identical
    page is a duplicate, and the second is the worse doorway — the library
    lookup is by NAME, so "The Eurythmics" matched none of the user's albums.

    The CONTROL matters as much as the fold: name-similarity folding was
    rejected precisely because "Iron Maiden" and "The Iron Maidens" are one
    edit apart and genuinely different bands. They resolve to different MBIDs,
    so they must SURVIVE as separate rows. If this ever fails, the merge has
    drifted back to string inference.
    """
    print("\n[same-MB-artist rows folded]")
    clear(host, "Eurythmics")
    rs = rows(host, player, ["search:Eurythmics"], count=60)
    names = [r.split("\n")[0] for r in rs]
    check("duplicate alias row folded (The Eurythmics)",
          "The Eurythmics" not in names, "rows: %s" % ", ".join(names[:8]))
    check("surviving row keeps every source",
          any(n == "Eurythmics" for n in names)
          and any("Local" in r and "Qobuz" in r for r in rs if r.startswith("Eurythmics")),
          "rows: %s" % " / ".join(repr(r.replace("\n", " | ")) for r in rs[:4]))

    # CONTROL: two DIFFERENT artists that fuzzy resolution once conflated must
    # stay separate. MB's Lucene returns artist:"Bush" -> KATE BUSH at score
    # 100, and 0.44.11 folded on resolved-MBID alone and merged them, deleting
    # a real result. Neither name is an alias of the other, so the alias gate
    # must keep both rows.
    #
    # (This replaces an earlier "The Iron Maidens" control, which was WRONG:
    # it asserted that row must survive an Iron Maiden search, but that band's
    # page is legitimately "No releases found" — none of its 5 MB release
    # groups match anything on this server — so the dead-end filter is right to
    # hide it. A control must not contradict a rule the plugin deliberately
    # implements.)
    clear(host, "Bush")
    rs2 = rows(host, player, ["search:Bush"], count=60)
    n2 = [r.split("\n")[0] for r in rs2]
    check("CONTROL: 'Bush' kept as its own row", "Bush" in n2,
          "rows: %s" % ", ".join(n2[:10]))
    check("CONTROL: 'Kate Bush' NOT folded into Bush", "Kate Bush" in n2,
          "rows: %s" % ", ".join(n2[:10]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="plex:9000")
    ap.add_argument("--player", default=None,
                    help="player MAC; required for menu-mode renders")
    args = ap.parse_args()

    player = args.player
    if not player:
        pl = rpc(args.host, None, ["players", "0", "5"]).get("players_loop", [])
        if not pl:
            print("no players found; pass --player <mac>")
            return 2
        player = pl[0]["playerid"]
    print("host=%s player=%s" % (args.host, player))

    started = time.time()
    for fn in (test_hide_unmatched_cold, test_dead_end_rows,
               test_same_name_section_cold, test_secondary_act_bio,
               test_alias_folding):
        try:
            fn(args.host, player)
        except Exception as e:
            check(fn.__name__ + " (raised)", False, repr(e))

    print("\n%d passed, %d failed in %.0fs" % (len(PASSED), len(FAILED),
                                               time.time() - started))
    if FAILED:
        print("FAILED: " + ", ".join(FAILED))
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
