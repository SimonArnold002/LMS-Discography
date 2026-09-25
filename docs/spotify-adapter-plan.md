# Spotify (via Spotty) for Discography — build plan

**Status: BUILT, 2026-09-25 (§4.1–§4.8, D1 = PFR's adapter fields, D3 = 5). 0.55.0 committed and installed, 0.55.1 built + committed (not installed); the §6 failure half is VERIFIED LIVE (dead token -> pool unresolved, every release still shown with hide_unmatched on); matching and playback are not live-tested.** Originally Written from code, not from a live Spotify
account: Simon no longer subscribes. Every claim below was checked against Discography's source,
against Spotty 4.62.2's source (`michaelherger/Spotty-Plugin` master), and against the Spotify
work already done in LBF, PFR and LL. Where a line number is given it was read on 2026-09-25 and
will drift; the sub name is the stable reference.

**Reviewed against Discography's code 2026-09-25: the plan holds up.** Every Discography-side
claim in §3–§4.8 was checked in the source; the outcomes and the two decisions it produced are
in §8. The Spotty-side claims in §2 were not re-checked (no Spotty source in the workspace).

**Read first, in this order:**
1. This file.
2. LBF `docs/streaming-adapter-spec.md` §4–§7 (the fleet adapter contract; §6 is the rate-limit
   rules).
3. LBF `docs/spotify-rate-limits.md` (the full back-off working and the live evidence).
4. PFR `CLAUDE.md` Status 0.9.35 → 0.9.39, and ledger B `_searchSpotify` entries.
5. LL `CLAUDE.md` §B `A SPOTIFY ROW'S STORED ALBUM TITLE CAN NEVER MATCH`.

---

## 1. Why this is not a port of LBF's or PFR's adapter

LBF and PFR search **one album at a time** (`search type=album`, match locally, done).
Discography is **artist-first**: resolve the artist on each service, pull that artist's whole
album list, then match every MusicBrainz release group against that pool
(`Sources::getCandidates` → `_resolveArtist` → `$fetch`). So Discography needs Spotty's
**artist search** and **artist albums** calls, which neither sibling uses. The shape to copy is
Discography's own `_searchTidal` / `_searchDeezer`; the rate-limit and failure rules come from
LBF/PFR/LL.

## 2. Spotty's API, as Discography will call it (verified in Spotty's source)

| Need | Spotty call | Verified facts that matter |
|---|---|---|
| Handler | `Plugins::Spotty::Plugin->getAPIHandler($client)` (Plugin.pm:317) | CLASS method. Returns undef with **no `$client`**, and undef with no credentials at all. |
| Artist search | `$api->search($cb, {query, type=>'artist', limit})` (API.pm:229) | Key `query`, singular `type`. **Default limit is 200 = 4 requests**; always pass ≤50. Results are normalised artists `{id, name, uri, image, …}`. |
| Artist → albums | `$api->artistAlbums($cb, {uri=>"spotify:artist:$id", limit, offset, include})` (API.pm:441) | `include` defaults to `album,single,appears_on,compilation`. Limit is capped at 200 with Spotty's shared client id and **10,000** with the user's own. The Pipeline fetches page 1, then **every remaining page in parallel**. A 429 part-way drops pages silently → a **shortened** list. |
| Album search (fallback) | `$api->search($cb, {query, type=>'album', limit=>50})` | One request at limit 50 (PR #17 review). |
| Renderer | `Plugins::Spotty::OPML::_albumItem($client, $album)` (OPML.pm:1230) | `url => \&OPML::album` (coderef), `passthrough => [{uri}]`, `favorites_url => spotify:album:<id>`, `name` = "Album (Year) BY Artists" (year only with LMS `showYear`), `line1` = album name, `line2` = artists. **`image` falls back to `plugins/Spotty/html/images/album.png`** (OPML.pm:26) when the album has no art. |
| Rebuild on cache read | `\&Plugins::Spotty::OPML::album` | `($client, $cb, $params, $args)`, uri from passthrough. Same as LBF/PFR. |
| Play string | `spotify://album:<id>` | ProtocolHandler `explodePlaylist` → `tracksFromURI` (`:album:`) → `album()`. |
| Refusal signal | `Plugins::Spotty::API->hasError429` (API.pm:1466) | Set by a 429, cleared by the next successful response. **A 502, a token failure or a timeout never sets it.** |

**Album objects after `normalize` (API/Cache.pm):** the title is `name` (no `title`); `artist` is a
**string** (first artist's name) and `artists` is the list of `{id, name, uri}`; raw `type` is
**deleted**; `album_type` (`album` / `single` / `compilation` — **no EP class**), `total_tracks`,
`release_date`, `id`, `uri`, `image` survive. **No duration.**

**How Spotty fails (all four look like success):**
- 429 → Spotty sets `spotty_rate_limit_exceeded` for Retry-After and refuses every later call
  server-wide, **synchronously** (`getToken` does `return $cb->(-429)`).
- Any error → `_gotError` hands the extractor `{name => <error text>, type => 'text'}`, which
  extracts to **an empty list**. `undef` never reaches the caller.
- **Measured on the rig 2026-09-25:** Spotty reinstalled with the old (lapsed) account's
  credentials still cached. The menu shows, `getAPIHandler` returns a handler, and every token
  refresh fails (`accounts.spotify.com/api/token` → 400). Every search answers "Empty". This
  **dead-token state** is what a lapsed subscriber gets, and nothing reports it.

## 3. What Discography already does (do not rebuild it)

- **Unresolved vs "has nothing".** In `getCandidates`, `$settle->(undef)` caches the pool as
  UNRESOLVED for `CAND_ERR_TTL` (1h); `$settle->([])` caches it as empty for `CAND_EMPTY_TTL` (1d);
  a non-empty pool is cached for `CAND_FOUND_TTL` (3d). `peekPool` sets `resolved` only from a pool
  that is not unresolved, and `_discographyView` hides an unmatched release only when
  `hide_unmatched` is on **and** some pool is resolved (Browse `$visible`). So every Spotify
  failure must answer **`undef`** and nothing new is needed beyond that.
- **Resolved artist + empty album list → `undef`** in every service's search code.
- **Late results are kept:** a fetch that lands after the watchdog still caches a found pool.
- **Artist search is cached only when complete:** a service answering `undef` is marked failed and
  the merged list is not cached (Browse `$runMerge`, `SEARCH_TTL`).
- **Helpers that already understand Spotty's shape:** `_spineScore` reads `title // name`;
  `_albumArtistName` accepts a string `artist`.
- **The candidate cache key includes the plugin version** (`_candKey`), so a build re-keys every
  pool. No `CAND_CACHE_V` bump is needed.
- **No background pump reaches the services.** The `warm*` routines in `API.pm` are MusicBrainz
  ones. Services are reached only by: an artist or detail page (`getCandidates`), artist search
  (`searchArtists`), and the artist-photo tier (`artistImage`). Discography's ledger A2
  `A CROSS-PLUGIN shared rate limiter` records the same fact.
- **Artist photos come from MAI first** (Browse, the artist-artwork resolver): MAI local files,
  then MAI online, then the user's services only as a gap-filler for MAI's stale Deezer snapshot,
  then the person icon. **Album covers come with each release** (the renderer's `image`).

## 4. The build

### 4.1 Adapter entry — `Sources::adapters`

```perl
push @adapters, {
    name => 'Spotify', icon => _pluginIcon('Plugins::Spotty::Plugin'),
    run  => \&_searchSpotify, artists => \&_artistsSpotify, query_enc => 'chars',
    rebuild       => \&Plugins::Spotty::OPML::album,   # decision D1
    native_favurl => 1,                                # decision D1
    artist_image  => 0,                                # §4.6
} if Plugins::Spotty::Plugin->can('getAPIHandler')
  && Plugins::Spotty::OPML->can('_albumItem')
  && Plugins::Spotty::OPML->can('album');
```

- `query_enc => 'chars'`: Spotty escapes with `uri_escape_utf8` (LBF PR #17 review).
- Probe only the three Spotty functions actually called (spec R8). No `trackList`: Discography has
  no track leg.

### 4.2 The reshaping step

Every Spotify album hash goes through one helper **on a copy** before anything else sees it:

- `title` ← `name`. `_decorate` reads `title` for `_candTitle`; without this every title is blank
  and nothing matches. `peekPool` also builds its first-token title index from `_candTitle`, so
  without it Spotify albums would not even reach the matcher.
- `artist` ← `artists[0]` (the `{id, name}` hash). Without it `_albumArtistId` finds no id,
  `_filterForeignArtist` switches itself off, and the album-search fallback's rows fail the
  matcher's artist gate (`_renderAlbums` only reads a HASH `artist`).
  Known and accepted (Simon, 2026-09-25): a collaboration credited [A, B] can miss on B's own page.
  Not fixed here: services are not consistent about collaboration credits. See the ledger entry
  `A COLLABORATION CAN MISS ON THE SECOND-NAMED`.
- `image` stays untouched on the raw hash; see §4.5 for the cover.

The renderer (`_albumItem`) reads only `name`, `artists`, `release_date`, `image`, `uri`, so the
added keys cannot change what it renders.

### 4.3 The Spotify search code

Same structure as `_searchTidal`:

- **Artist search:** `search({query, type=>'artist', limit=>25})` → `_resolveArtist`.
- **Album list (`$fetch`):** page it **ourselves, one request at a time**:
  `artistAlbums({uri=>"spotify:artist:$id", limit=>50, offset=>$o, include=>'album,single,compilation'})`,
  stop on a page shorter than 50 or after **4 pages (200 albums)**. At limit 50 the Pipeline sends
  one request per call, so there is no parallel paging and a failure part-way is visible.
  `appears_on` is left out: it is other artists' records. `_filterForeignArtist` stays as a second
  guard.
- **Alias retry search (`$search`):** as the artist search.
- **Album-search fallback:** `search({query, type=>'album', limit=>50})`.
- **Artist hits for artist search (`_artistsSpotify`):** `search({query, type=>'artist', limit=>SEARCH_MAX})`
  → `_artistHits`.
- Renderer calls wrapped in `eval` (as `_renderAlbums` already does).

### 4.4 Answer rules (the lessons from LBF, PFR and the rig)

| Situation | Answer | Source of the rule |
|---|---|---|
| No handler (no client, signed out, helper not up yet) | `undef` | PFR: a service that cannot answer must not produce a confirmed miss. In Discography a confirmed miss becomes a `hide_unmatched` hide. **Not LBF's `hasCredentials → []`**, and never call `hasCredentials` (it rescans cache folders on every call while empty). |
| **Zero raw results** from any Spotify search (artist, albums page 1, album search, artist hits) | `undef` | LBF `_emptyResultIsError`. Catches 502s, dead tokens and 429s, which `hasError429` alone misses (PFR measured 184 502s in a minute). PFR declined this rule only because its warm would re-search an absent album hourly for ever; Discography has no warm and only re-asks when someone opens that artist. |
| Empty answer while `_spottyRateLimited()` | `undef` + stamp `$SPOTIFY_REFUSED_AT` | LBF/PFR. The stamp is the clock in §4.7. |
| A page after the first comes back empty while rate-limited | the whole album list → `undef` | New for Discography: never cache a shortened pool as found for 3 days. |
| Every renderer call died | `undef` | Already `_renderAlbums`' rule. |
| Results present | a real answer, whatever the flag says | LBF/PFR: only an empty list is doubted. |

**What this costs a lapsed or signed-out Spotify-only user:** the Spotify pool stays unresolved,
so releases stay visible (unmatched), and each artist-page open re-asks Spotify once an hour.
That's the correct outcome: nothing is hidden on a failure nobody confirmed.

### 4.5 Decoration and sizing — `_decorate`, `_candSize`

- **Cover:** set `_cover` only when the renderer's `image` is an `http(s)` url. Spotty puts its own
  `album.png` placeholder in `image` for an album without art, and tiles prefer `_cover` over Cover
  Art Archive art (Browse `_releaseItem`), so a placeholder would replace real CAA art. Do this in
  the Spotify code, not in the shared `_decorate`.
- **Size — BUILT DIFFERENTLY (2026-09-25):** `_candSize` is NOT changed. `_spotifyAlbum` writes Spotify's size onto its copy in the fields `_candSize` already reads (`album_type` album/compilation -> `record_type => 'album'`; `single` -> `tracks_count` from `total_tracks`), so the shared sub, and the other three services, are untouched. Pinned in `t_spotify.pl` §10, not `t_size.pl`. The original plan follows.
  Today `_candSize` reads neither `total_tracks` nor `album_type`, so every Spotify copy
  is **unknown**. Unknown passes the "an album is not a single" gate but **fails the album-only
  edition gate** (`matchesFor` `$titleHit`, the `@eds` loop). Change `_candSize`:
  - `album_type` `album` or `compilation` → `album` (reliable on Spotify; needed because there is no
    duration, so the 30-minute rule cannot promote a 5–6 track LP);
  - otherwise `total_tracks` through `_sizeFromCounts` (1–3 single, 4–6 EP), because Spotify files
    EPs under `single` (LBF PR #17 finding 2; LL's `singleIsWrong` takes the same view).
  - No other service carries either field, so no other copy's size changes. Pin in `t_size.pl`.
- `_candYear` already reads `release_date`. No change.

### 4.6 Artist photos — `Sources::artistImage`

Spotify is **left out** of the photo walk: `artist_image => 0` on the entry, checked in the
`orderedAdapters()` loop. Reasons, all checked:
- MAI is the photo source; services only fill MAI's gaps (§3).
- `_svcArtistImage` has no Spotify branch, so Spotify could never supply a photo, but an exact
  Spotify artist with no photo would set `$sawExact` and **veto** a loose photo from another
  service.
- The walk runs with no client (`Browse` calls `artistImage(undef, …)`), and Spotty's
  `getAPIHandler` returns undef without one. This is the case Discography's A3 row `getSomeUserId`
  says to re-raise: Qobuz/Tidal/Deezer handle a missing client; Spotty does not.
- It is the one path that can fire many Spotify searches at once (one per cold thumbnail).

MAI is a requirement of the plugin (ledger `MAI OFF IS NOT A SUPPORTED STATE`), so the
"MAI off, Spotify the only service" case needs no handling.

### 4.7 Rate management

What LBF/PFR built, and what applies here:

- **Refusal tagged on the answer, own 30s clock** (`$SPOTIFY_REFUSED_AT`, `SPOTIFY_BACKOFF_WINDOW`,
  `_spottyRateLimited`, `_spotifyBackingOff`), copied from PFR's shapes. `can`- and eval-guarded.
- **No second back-off.** Spotty owns the wait.
- **Nothing is slowed.** Both ledgers: pace the warm only, never a view. Discography has no warm,
  and the one bursty path (photos) is excluded. The clock is kept so a later pump can read it
  (spec §6: "nothing inherits the back-off").
- **Immediate refusals:** checked every Discography loop that reaches Spotify. None treats an
  immediate answer as a cache hit. The immediate recursions are bounded: `_resolveArtist`'s alias
  step (≤ `ALIAS_MAX` 3) and `getCandidates`' pending counter.
- **Cost of one artist page, worst case:** 1 artist search; up to `SPINE_ARTISTS` (4) candidate
  artists fetched at once for an ambiguous name, each up to 4 pages one at a time; up to 3 alias
  searches; 1 album search. About 20 requests, only for an ambiguous name; an ordinary artist is 2–5.
  Spotty caches each GET for an hour; Discography caches the pool for 3 days.
- **Timing:** services run in parallel under `SVC_TIMEOUT` (20s) each, and the first render waits up
  to `POOL_WAIT_MAX` (20s) for a cold pool. One-at-a-time paging fits; a late result is still cached.
- **The quota is shared:** Spotty's default client id is one Spotify app for every install
  (`iconCode`), counted over a rolling 30s window.

### 4.8 Other sites

| Site | Change |
|---|---|
| `Sources::%REATTACH` / `_reattach` | Spotify → `\&Plugins::Spotty::OPML::album` (or read the entry's `rebuild`, D1). |
| `Sources::matchesFor` → `_attachFavUrl` | Skip for Spotify (`native_favurl`). Spotty's `album()` takes the id with a greedy `/album:(.*)/`, so `?cover=` would break a saved favourite (LBF/PFR, settled in both ledgers). |
| `Sources::serviceStatus` `@known` | Add `[ 'spotify', 'Spotify' ]`. Drives the settings page and the "Works best with" strip (both loop over it). |
| `Browse::_playUrl` | `spotify://album:<id>`. NB `_playUrl` returns the node's own `play` first: if Spotty's `_albumItem` sets one, this change is not needed. Check it in the §5 fake before building. |
| `Browse::%EMBLEM` | Add `spotify` (key present in Material's `misc/emblems.json`, checked 2026-09-25). Badge extid becomes `spotify:album:<id>`. NB `_extid` keeps a node's own `extid`: check whether `_albumItem` sets one. |
| `Plugin.pm` pref defaults | `svc_priority_spotify => 5` (last, as LBF). |
| `Settings.pm` | Both service lists (the `prefs` list and the priority sanitiser loop). |
| Row labels | **Leave Spotty's `name` as it is.** Versions are deduplicated on the raw `name|line2` and Spotty's `line2` is the artist. CORRECTED 2026-09-25: with LMS `showYear` off, same-titled editions already share `name|line2` and show as one row; keeping `name` matters only with `showYear` on, where its " (YYYY)" keeps different years apart (`t_spotify.pl` §8). |

### 4.9 Listen to Later (nothing owed; recorded so it is not reported)

- A Discography Spotify tile's favourites url is Spotty's own `spotify:album:<id>`, so no `?cover=`
  or `&a=` reaches LL. LL normalises the bare URI (`Sources::normaliseFavurl`), fills in the artist
  from one Spotty album call (retried once, refusing Spotty's error hash), and matches Played by
  release id (`Played::_spotifyAlbumRecord`).
- **The title changes.** With no `&al=`, LL treats the title as a row label and replaces
  Discography's clean MusicBrainz title with Spotify's album name (LL `Plugin.pm` `_titleFromLabel`).
  Qobuz/Tidal/Deezer adds from Discography keep the MB title. This follows LL's rule "show what it
  matched to" (Simon, 2026-09-16).

### 4.10 Docs to update in the same session

- DONE 2026-09-25: `CLAUDE.md`'s "Spotty has no `getAPIHandler`" (Phase-1 Scope) and line 4
  ("Spotify maybe later") now point at this plan.
- DONE 2026-09-25 (after 0.55.0): `CLAUDE.md` "Service Plugin APIs — VERIFIED SIGNATURES" has the
  Spotty rows (`getAPIHandler`, `search`, `artistAlbums`, `OPML::_albumItem`) and Spotty's repo.
- DONE: Ledger A3 "Spotty's getAPIHandler REQUIRES a client", beside the `getSomeUserId` row.
- DONE: Ledger A2, four entries: `SPOTIFY: AN EMPTY ANSWER IS NEVER A VERDICT` (the `hide_unmatched` /
  zero-raw-results reasoning), `SPOTIFY: A FAILED LATER PAGE`, `SPOTIFY IS NOT IN THE ARTIST-PHOTO WALK`,
  `SPOTIFY ROWS KEEP SPOTTY'S OWN` (favurl, row name, the placeholder-cover rule).
- DONE: the home-page About text (`PLUGIN_DISCOGRAPHY_ABOUT_1`) lists Spotify; the stale lines in
  `CLAUDE.md` (line 4, Phase-1 Scope) say it is built.

## 5. Tests

New `tools/t_spotify.pl`, starting from PFR's `tools/t_spotify.pl` fake Spotty (its shapes come
from Spotty's source), extended with `artistAlbums` and artist search. The fake must:
- return **normalised** shapes: `name` not `title`, string `artist`, no `type`, `album_type`,
  `total_tracks`, no duration, `image` possibly empty;
- **refuse immediately** in the same call stack, like `getToken`'s `$cb->(-429)`;
- return a 502 / dead token as Spotty's error hash, i.e. an empty list with `hasError429` unset.

Assertions (each anti-tested with a deliberately broken copy, via a `DSC_SOURCES=`-style override):
1. Reshaping: title, artist id; `_filterForeignArtist` active for Spotify.
2. Zero raw results → `undef` in all four searches; a genuine hit list is an answer.
3. Rate-limited empty → `undef` + stamp; results present with the flag set → answer.
4. Paging: one request per page, stops at a short page and at 4 pages, `include` without
   `appears_on`, a refused page 2 → the whole list `undef`.
5. No handler → `undef`.
6. **End to end with `hide_unmatched`:** a Spotify-only user in the dead-token state keeps every
   release visible.
7. Placeholder `image` never becomes `_cover`.
8. `_candSize`: `album_type` album → album; single + 5 tracks → ep; single + 2 → single; other
   services unchanged (extend `t_size.pl`).
9. Favourites url left as Spotify's own; `_playUrl`; `_extid` (extend `t_extid.pl`); reattach.
10. `artistImage` never calls Spotify (extend `t_artimg.pl`).
11. Deliberate changes to existing suites: `t_worksbest.pl` five tiles → six; `t_settings.pl`
    priority list.

Harness traps both siblings hit:
- A value lifted from source into `use constant` resolves at compile time, while still undef.
- `our` must be declared above its first use (PFR 0.9.37: nine suites failed to load).
- Never `ok($src =~ /re/)` in list context; bind the match first.
- A fake timer must hand back its first argument the way LMS does.
- A sub-extractor that dies gives exit 255 with no FAIL line, which reads like a pass. **Check
  every suite's exit code**, not its last line.

## 6. Live checking

- **On the rig now (dead-token state):** Spotify at priority 1, others 0 → an artist page must
  show every release (unmatched), log the Spotify pool as unresolved, and not cache the artist
  search. This proves the failure half. **PASSED 2026-09-25** (0.55.0, Radiohead, hide_unmatched ON; evidence in CLAUDE.md dev log 0.55.0).
- **If a free Spotify account can sign into Spotty** (untested: Spotify's search API is not
  Premium-only, but how Spotty handles a free login is unknown), matching can be tested on the rig;
  only playback needs Premium.
- **For a tester with Spotify:** LBF `docs/streaming-adapter-spec.md` §10, plus: other priorities 0
  to test Spotify-only (PFR's method); re-open a page to prove the rebuild; watch for Spotty's
  `error429` lines and our refusal line (LBF `docs/spotify-rate-limits.md` §7).

## 7. Open decisions (Simon)

- **D1 — adapter fields vs maps.** Recommended: PFR's way. `rebuild` and `native_favurl` on all four
  entries, `_reattach` reads `rebuild`, `%REATTACH` goes. Alternative: add Spotify to the existing
  map and a `native_favurl` check, touching less working code for the other three services.
- **D2 — the fleet adapter spec.** It covers LBF/PFR/LL, not Discography, and still lacks PFR's
  `empty_unverified` / `pace_warm`. Adding Discography means editing LBF's copy and re-copying it to
  PFR and LL (checksums must match). Now, or after the build.
  **DECIDED (Simon, 2026-09-25): keep Discography SEPARATE from LBF's spec.** Discography's adapter
  contract lives in its own `CLAUDE.md` (the Service Plugin APIs section and §A2) and this plan;
  LBF's `docs/streaming-adapter-spec.md` is not edited and not re-copied.
- **D3 — default priority** `svc_priority_spotify => 5` (last). Recommended, as LBF.

## 8. Review against the code (2026-09-25)

**Checked and confirmed in Discography's source:**
- `getCandidates` caches an unresolved service for `CAND_ERR_TTL` (1h) with the `unresolved`
  marker; `peekPool` counts a pool as resolved only without it; a late result after
  `SVC_TIMEOUT` (20s) is still cached as found.
- All three existing adapters answer `undef` for a resolved artist with an empty album list.
- `_candKey` carries the plugin version, so no `CAND_CACHE_V` bump is needed.
- `_albumArtistId` / `_renderAlbums` need a HASH `artist`; Spotty's string `artist` short-circuits
  the `artists[0]` fallback, so the §4.2 reshaping is required.
- `_candSize` reads neither `album_type` nor `total_tracks`; an unknown size fails the album-only
  edition gate in `matchesFor`'s `$titleHit`.
- `artistImage` runs with no client and an exact entity without a photo sets `$sawExact` and
  vetoes every looser photo.
- `_attachFavUrl` is the one favurl writer; versions dedupe on `name|line2`; `%REATTACH`,
  `serviceStatus` `@known`, both Settings service lists and the priority defaults (Local 1 …
  Deezer 4) are as §4.8 says.
- PFR's `tools/t_spotify.pl`, `$SPOTIFY_REFUSED_AT`, `_spottyRateLimited` and
  `_spotifyBackingOff` exist to copy from.

**Decisions (Simon, both logged in the ledger):**
- A collaboration Spotify credits as several artists ([Panda Bear, Sonic Boom]) can miss on the
  second-named artist's own page (`artists[0]` + `_filterForeignArtist`). Accepted, not fixed:
  services are not consistent about collaboration credits, and the joint-credit and first-artist
  routes reach it (checked in the Spotify app). Ledger: `A COLLABORATION CAN MISS ON THE SECOND-NAMED`.
- MAI is a requirement, so MAI-off cases are out of scope. Ledger: `MAI OFF IS NOT A SUPPORTED STATE`.

**Carried into the build:** the `_playUrl` / `_extid` checks in §4.8.
