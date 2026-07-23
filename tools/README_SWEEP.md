# Full-library sweep — method notes

`library_sweep.py` drives the **live** plugin over HTTP, one artist at a time, exactly the
way Material does, and records what a user would actually see. `report_sweep.py` turns the
result into `sweep/REPORT.md` plus CSVs.

Nothing here re-implements the matcher. Every verdict is the plugin's own output, so a run
measures the shipped code rather than a model of it — which is the whole point, and the
reason it can find things the unit suites cannot (the 0.44.25 lesson: textual sync proves
the bytes agree, not that they behave).

## Running it

```bash
python3 tools/library_sweep.py preflight   # verifies config is actually in effect
python3 tools/library_sweep.py browse      # the core pass (~1h for 1100 album artists)
python3 tools/library_sweep.py search      # each artist's own name typed into the search
python3 tools/library_sweep.py variants    # plain spellings of decorated names
python3 tools/library_sweep.py report      # aggregate -> sweep/REPORT.md + CSVs
```

Every phase is **resumable** — re-running skips artists already recorded, so an interrupted
run just carries on. Raw feeds are archived under `sweep/raw/`, so the whole analysis can be
recomputed offline without touching the server again.

## Test configuration (required)

The sweep needs prefs that a normal install would not use. **Set them on the box** — LMS
refuses pref writes from off-LAN (a Tailscale client gets
*"Access to settings is restricted to the local network"*), so a Mac that is not on the home
network cannot do this itself:

```bash
curl -s http://plex:9000/jsonrpc.js -d '{"id":1,"method":"slim.request","params":["",["pref","plugin.discography:debug_log","1"]]}'
curl -s http://plex:9000/jsonrpc.js -d '{"id":1,"method":"slim.request","params":["",["pref","plugin.discography:hide_unmatched","0"]]}'
curl -s http://plex:9000/jsonrpc.js -d '{"id":1,"method":"slim.request","params":["",["pref","plugin.discography:show_streaming_extras","1"]]}'
curl -s http://plex:9000/jsonrpc.js -d '{"id":1,"method":"slim.request","params":["",["pref","plugin.discography:show_library_extras","1"]]}'
curl -s http://plex:9000/jsonrpc.js -d '{"id":1,"method":"slim.request","params":["",["pref","plugin.discography:show_types","ALBUMS,EPS,SINGLES,COMPILATIONS,LIVE,OTHER"]]}'
```

**Afterwards, put `debug_log` and `hide_unmatched` back** (fleet habit — debug logging is not
free, and every message string is built at the call site whether or not the pref is on):

```bash
curl -s http://plex:9000/jsonrpc.js -d '{"id":1,"method":"slim.request","params":["",["pref","plugin.discography:debug_log","0"]]}'
curl -s http://plex:9000/jsonrpc.js -d '{"id":1,"method":"slim.request","params":["",["pref","plugin.discography:hide_unmatched","1"]]}'
```

`preflight` does not trust these settings to have been applied — it cannot READ prefs off-LAN
either, so it **proves them by behaviour**: it browses a big-catalogue artist and checks that
sourceless rows actually render and that debug lines actually appear.

## Three traps this harness already fell into

Recorded so they are not re-derived.

### 1. A first visit understates matches — always render twice

With `hide_unmatched` off, `_discographyView` does **not** await the streaming warm; that
await only fires when the pref is ON and the pool is cold (0.44.8). The sweep must run with
it off to see misses at all — so a cold artist renders *before* its candidate pool exists.
Measured live:

```
13th Floor Elevators  first 2/42   second 12/42
Count Basie           first 25/112 second 33/112
Eve Adams             first 1/6    second 4/6
```

The harness therefore re-renders each artist until the match count stops rising, and keeps
the first render's figure separately as `warm_gain`. **A single-render sweep is invalid** and
would have reported a catastrophic, entirely fictional miss rate.

### 2. `log.txt` is HTML-wrapped and returns a short tail by default

Tags must be stripped, and the default window is ~155 lines while one render can write
several hundred. `LogCursor` requests a wide window, detects when the window has outrun the
cursor, and re-fetches wider rather than silently returning a short slice — the 0.44.9
misdiagnosis in tool form.

### 3. An unmatched row has three unrelated causes

Counting them together overstates the problem by roughly an order of magnitude.
`classify_releases` splits them:

- **`rival_loser`** — another release group by the same artist normalises to the same title
  and won the candidate under the 0.16.0 rival-owner rule. Unmatched *by design*, and hidden
  in normal use. A test artefact.
- **`no_pool`** — every streaming service returned an empty pool. The failure is artist
  resolution, one level above the matcher.
- **`genuine`** — healthy pool, title still missed. **This bucket is still not a defect
  count**: it bundles releases the services genuinely do not sell (MusicBrainz catalogues
  promos, regional editions and one-off singles no service carries) with real matcher
  misses, and the feed cannot tell them apart. The actionable subset is
  `unmatched_albums_healthy_pool.csv` — a missing *studio album* by an artist whose pool is
  healthy is the shape a real bug takes.

Likewise for owned albums: *Appearances* (various-artists compilations, guest spots) are
**not** expected to become tiles, so only the *Also in your library* count is a real
local-match gap.

## Output

| File | What it holds |
|---|---|
| `sweep/REPORT.md` | the readable report, bucketed by defect class |
| `sweep/artists.csv` | one row per artist, all counters |
| `sweep/unmatched_classified.csv` | every unmatched release with its cause |
| `sweep/unmatched_albums_healthy_pool.csv` | **the list worth walking by hand** |
| `sweep/unclaimed_local_albums.csv` | owned albums that never became a tile |
| `sweep/search.csv`, `sweep/variants.csv` | search + fold results |
| `sweep/raw/`, `sweep/logs/` | raw feeds and per-artist debug slices (gzipped) |

---

# Triage + identity tooling

Four tools that grew out of the 2026-07-22 triage session. The sweep tells you *how many*
albums went unmatched; these tell you *why*, using the shipped matcher rather than a model
of it. All take `DSC_HOST` (default `plex:9000`), `DSC_MB` (default
`http://plex:5000/ws/2/`) and `DSC_SWEEP_OUT` (default `sweep/`).

## The triage chain

```bash
python3 tools/gap_recompute.py                      # live: owned albums with no tile
python3 tools/spine_fetch.py --gaps sweep/gaps.json # each artist's real MB spine + aliases
perl    tools/spine_match.pl                        # the REAL matcher's verdict per album
```

`gap_recompute.py` re-derives the *Also in your library* rows from the live feed, because the
sweep's `lib_extras` column ages the moment the library is rescanned or a matcher fix ships.

`spine_match.pl` loads `Sources.pm` itself, so every verdict is the plugin's own, and it
separates four outcomes that are easy to conflate:

| Verdict | Meaning |
|---|---|
| `MATCH` | claimed, and the tile is visible |
| `HIDDEN` | claimed, but `%HIDE_SECONDARY` (Remix / DJ-mix) hides the tile — **not** a bug |
| `ALIAS` | claimed only via an MB release-group alias (0.48.0) |
| `NOMATCH` | the shipped matcher rejects every release group in the spine |

**`gap_recompute.py --who "Jack,Muzz,Rico"`** answers the other question: it prints the first
few *spine* rows, which is how you tell a **matcher** miss (right artist, titles don't line
up) from a **resolver** miss (the page is somebody else's discography entirely).

## The identity probe

`mb_identity_probe.py` measures the PLANNED local↔MusicBrainz identity index (see CLAUDE.md)
before anyone builds it. It resolves each album's *artist* identity from the **album** rather
than the artist name, in escalating tiers:

```bash
python3 tools/mb_identity_probe.py scan     # resumable; minutes on a mirror, ~1h public
python3 tools/mb_identity_probe.py rescue   # salvage tiers, misses only
python3 tools/mb_identity_probe.py report   # coverage, name gate, disagreements, queue
```

Measured 2026-07-22 on a 2,910-album library: **97.8%** resolved, manual queue **61 albums**.

Three results from that run are the reason the tool exists, and re-running it should
reproduce them:

- **The name gate is mandatory.** Without it the album vote drags a classical artist to the
  *composer* — Chicago Symphony Orchestra → Tchaikovsky, Leonard Bernstein → Stravinsky —
  breaking three pages that work today. `report` prints every disagreement so each one gets
  looked at rather than trusted.
- **Never store album→release-group without exact title agreement.** 6.6% resolved the artist
  correctly and the release group *wrongly* (*The Man Machine* → *The Man-Machine Recreated*).
  A stored RG mbid feeds `_mbidMatch`, which is Tier 0 and trusted absolutely.
- **Tier ORDER is the safety mechanism, not the regexes.** The T5 prefix strip would turn the
  real album title *Talking Heads: 77* into *77* — but only ever runs on albums the earlier
  tiers missed, and that one resolves at T1. Do not "simplify" it into a title cleanup pass.
