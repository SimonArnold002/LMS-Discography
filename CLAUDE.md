# Discography — LMS Plugin

## Project Overview
A plugin for Lyrion Music Server (LMS) that shows an artist's **full discography** — not just what's in the library. The discography spine comes from **MusicBrainz release-groups** (original/first release dates, primary types), artwork from the **Cover Art Archive**, and each release resolves to playable sources: the **local library** and/or the user's streaming services (**Qobuz / Tidal / Deezer** — deliberately no Bandcamp; Spotify maybe later). Entry point is a **"Full Discography"** custom action on the artist context menu in Material Skin. Targets LMS 9.x.

Long-term context: this is **Phase 1** of a bigger idea — an integrated Material artist view (bio header + library albums + full discography inline). Phase 1 deliberately needs **zero Material changes**; the integrated view would be a later local Material patch and, eventually, an upstream ask for a generic "artist-view section provider" hook.

**Maintain this file.** Update it with every code change: keep the File Structure annotations, mechanics notes, and the Development Log current as part of each build. Bug-fix detail goes in the Development Log; scope changes go in Phase-1 Scope.

## Phase-1 Scope (locked decisions)
- **Services: Qobuz / Tidal / Deezer only.** No Bandcamp (cookie-dependent search + event-loop-blocking parsing in its plugin — excluded on purpose). Spotify deferred (Spotty has no `getAPIHandler`; its adapter is real work, not a free port).
- **Spine = MusicBrainz release-groups** browsed by artist MBID (`release-group?artist=<mbid>&limit=100&offset=N`, serial pagination at MB's 1 req/s). `first-release-date` drives the date sort; primary type (Album/EP/Single/Compilation) + secondary types (Live/Remix — excluded by default) drive filtering. Art: CAA release-group front.
- **Artist MBID**: prefer the library's `contributor.musicbrainz_id`; fall back to MB name search (port of LBF `getArtistMbidByName`).
- **Resolver = trimmed port** of the LBF `_findPlayable` engine (the same port Pitchfork Reviews proved) — NOT a runtime dependency on LBF. New layer on top: `_resolveArtistBatch` — one artist-only search per service, matched against ALL release groups in a single pass (≈1 API call per service per artist, not per album). Known limit: service search caps ~50 albums; the v1.1 fix is the services' artist-discography endpoints.
- **Tiles**: render instantly from MB data; playable via **resolve-on-play**; Material **emblems** appear opportunistically from cache (`extid` prefixed `qobuz:`/`tidal:`/`deezer:`). Drill-in shows every version: Local (real `album_id`) + per-service matches + "View on MusicBrainz" weblink.
- **Settings live in the plugin** (not Material settings): default sort (newest/oldest), service priority (`svc_priority_*`, 0 = never, LBF convention), release types shown, hide-unmatched.
- **Cache keys**: `dsc:mbid:<norm-artist>` 30d · `dsc:rg:<mbid>:vN` 14d · `dsc:cand:vN:<svc>:<norm-artist>` 3d found / 1d empty / 1h error · `dsc:urls:` · `dsc:bio:` · `dsc:rev:`. There is **no match-result cache** — candidates are cached RAW and matching runs live per render, so a matcher change takes effect immediately and only needs `dsc:cand` bumped when the cached candidate SHAPE changes. No background warming while a library scan runs.

## Build Order / Status
1. ✅ **Skeleton + entry point** (v0.1.1, 2026-07-09) — plugin registers, custom action written, placeholder feed proves the `artist_id` handoff end-to-end. **VERIFIED on the server**: artist context menu → skeleton view with DB-resolved artist name ("13th Floor Elevators").
2. ✅ **MusicBrainz discography list** (v0.2.0, 2026-07-09) — release-group fetch + CAA art + sorted tile list + newest/oldest toggle + Refresh + plugin icon. Awaiting server test.
3. ✅ **Streaming sources** (v0.4.0–0.6.0, all VERIFIED on server 2026-07-09) — Sources.pm engine, playable tiles (preferred-service play w/ fallback), background warm, single-version detail (pref for all-services view), type-filter + hide-unmatched prefs, Material type icons on headers, match debug log. Local Material emblem patch prepared (test-artifacts/) — deploy pending Simon being home. Still open: full CAA-miss art fallback (current heuristic = service art on undated releases only).
4. ✅ **Local library matching** (v0.9.0, 2026-07-09) — Local pseudo-source (svc_priority_local, default 1 = first), one sync `albums` CLI query per build, owned releases show/count as matched, detail Local row plays the library tracklist. Awaiting server test. KNOWN LIMIT: tile-level play still uses the best STREAMING match (a Local match has no play URL string; needs a play/go split — research).
5. ✅ **Settings page** (v0.10.0, 2026-07-09) — all prefs in the LMS web UI. LL favurl handshake + Refresh actions were delivered earlier (0.4.x). Awaiting server test. (Resolve-all action: dropped — the background warm on view open made it redundant.)

## Server Details
- **LMS Server**: test/diagnose via `http://plex:9000` (hostname, not LAN IP — works on and off the network)
- **OS**: DietPi (Debian Bookworm); service `lyrionmusicserver`
- **Plugin location (manual install)**: `/var/lib/squeezeboxserver/Plugins/Discography/`
- **Log**: `/var/log/squeezeboxserver/server.log`
- **Workflow**: Simon runs all server commands himself (give bare commands); he installs the zip manually — build it and say it's ready. Debug via HTTP + pasted logs.

## Install Commands
```bash
sudo rm -rf /var/lib/squeezeboxserver/Plugins/Discography
sudo unzip Discography.zip -d /var/lib/squeezeboxserver/Plugins/
sudo chown -R squeezeboxserver:nogroup /var/lib/squeezeboxserver/Plugins/Discography
sudo systemctl restart lyrionmusicserver

# Check logs
grep -i "dsc" /var/log/squeezeboxserver/server.log | tail -20
```

Test the feed without Material (player MAC required):
```bash
curl -s http://plex:9000/jsonrpc.js -d '{"id":1,"method":"slim.request","params":["<PLAYER_MAC>",["discography","items",0,10,"artist_id:<ID>"]]}'
```

## File Structure
```
Discography/
├── Plugin.pm       # OPMLBased entry point (tag 'discography', is_app); prefs; canonical `dbg` (API/Browse/Sources delegate); Material custom-action merge-write/clear; Settings under WEBUI
├── Browse.pm       # topLevel ($VAR guard, %lastCtx stash+expand flags+visibility snapshot); grouped list (bio header, Options/type/library-extras sections, sort+Refresh); release detail (review w/ inline expand, version rows w/ Show-other-versions toggle, MB links); _proseRow avatar-column indent
├── API.pm          # Async MusicBrainz: artist MBID (library tag first, MB search score>=90), paginated release-group browse, url-rels links; CAA image URLs; caching
├── Sources.pm      # Source engine: Q/T/D adapters (artist-FIRST candidate fetch, per-adapter query_enc, shared _renderAlbums + _albumArray envelope unwrap), Local pseudo-source (sync albums query, db:album.id play), matcher (fleet-synced), matchesFor/peekPool+peekMatches/claimedLocalIds, LL favurl handshake
├── Settings.pm     # Web settings: source priorities (detection), view options (type checkboxes->CSV), release page, integration
├── install.xml     # <extension> + <optionsURL>; version lives here (no repo.xml yet — pre-release)
├── strings.txt     # PLUGIN_DISCOGRAPHY_* UI strings
└── HTML/EN/plugins/Discography/
    ├── settings.html                           # TT template (PFR's settings layout)
    └── html/images/                            # icon (vinyl _svg.png, #000 fill) + dsc-*_MTL_icon_* action/header placeholders + dsc_MTL_svg_* type-header names + dsc-blank.png (unused, kept)
```
Build the zip from the repo root: `zip -r -X Discography.zip Discography -x '*.DS_Store'`. **Bump the version in install.xml on every rebuild** (same version = LMS won't reinstall); when repo.xml exists, bump + recompute `<sha>` there too.

## Key Mechanics
- **Entry point — `lmsbrowse` custom action (stock Material, no patching).** Material's `customactions.js` supports an action type that navigates INTO a plugin browse feed with `$VAR` substitution (`doCustomAction` → `lmsbrowse`). We write one entry to the **`artist`** section:
  `{ title: "Full Discography", icon: "album", lmsbrowse: { command: ["discography","items"], params: ["artist_id:$ARTISTID","artist:$TITLE"] } }`
  `$ARTISTID` is filled from the item's `artist_id:N` id and is the reliable key; `$TITLE` (row title = artist name) is a fallback because artist rows don't carry `$ARTISTNAME`. **Unpopulated `$VARS` arrive as literal tokens** — `Browse::_cleanParam` drops anything starting with `$`.
- **Shared actions.json discipline.** `<prefsdir>/material-skin/actions.json` is shared with Material, Listen Later and user actions. We do an atomic **read-merge-write** (temp file + rename), stripping only OUR entries (`_isOurAction`: `lmsbrowse.command[0] eq 'discography'`) before appending the current one. Never reset a category we don't own; never leave an empty category behind (empty categories actively suppress in Material). The `material_action` pref (default on) gates the write; off = entry is cleaned out at postinit.
- **Material caches `customactions.json` at app start** — after (re)install, an open Material tab needs a **hard refresh** before the menu entry appears.
- **Params → feed**: XMLBrowser's `cliQuery` passes tagged request params to the top-level feed as `$args->{params}` (same path Material's own `browselibrary items … artist_id:` uses; LBF/PFR read it the same way).
- **Settings template vars → `beforeRender`, NOT `handler`.** `Slim::Web::Settings::handler` (verified against LMS source) does, in order: persist each `prefs()` pref from `$params->{pref_<name>}` → refresh `$params->{prefs}{<name>}` from the store → call `$class->beforeRender($params, $client)` → render. So anything the template derives from a pref must be built in `beforeRender`; built in `handler` before `SUPER::handler` it is read PRE-save and a save re-renders the old values (looks like a lost save) while the base's `prefs.*` rows on the same page show the new ones. Sanitising the incoming `$params->{pref_*}` still belongs in `handler`, before `SUPER::handler`. Fleet-wide rule — DSC/PFR/LBF all had this bug (fixed 2026-07-10).
- **Local syntax gate**: `perl -c` with stubbed Slim modules (stubs in the session scratchpad; recreate as needed — Log, Prefs, PluginManager, Strings, Plugin::OPMLBased, Schema, JSON::XS).

## Service Plugin APIs — VERIFIED SIGNATURES (2026-07-10, from upstream source)
Don't guess these; the adapters break silently when they drift. Sources fetched from GitHub
(the installed server copies are the same code):

| Call | Signature | Callback receives |
|---|---|---|
| Qobuz `search` | `($self,$cb,$query,$type,$args)` | whole result hash: `{artists}{items}`, `{albums}{items}` |
| Qobuz `getArtist` | `($self,$cb,$artistId)` | result hash w/ `{albums}{items}` (`artist/get`, `extra=albums`, capped at `QOBUZ_DEFAULT_LIMIT`=200) |
| Qobuz `_albumItem` | `($client,$album)` | — (album items normally carry a named `{artist}`; also `{artists}` w/ roles) |
| TIDAL `search` | `($self,$cb,{type,search,limit})` | plain ARRAY (`$result->{items}`) |
| TIDAL `artistAlbums` | `($self,$cb,$id,$type)` — `$type` defaults `'ALBUMS'`, also `EPSANDSINGLES`/`COMPILATIONS` | plain ARRAY |
| Deezer `search` | `($self,$cb,{search,type,strict,limit})` | plain ARRAY (unwraps `{data}`; `artist` type filtered on `nb_album`) |
| Deezer `artistAlbums` | `($self,$cb,$id)` | plain ARRAY (unwraps `{data}`); items have **NO** `artist` object |
| Deezer `_renderAlbum` | `($item,$addArtistToTitle,$artist)` | — (`$artist` backfills `favorites_title`; `line2` stays undef on artist-albums items — Browse overwrites `line2` with the service name anyway) |

Repos: `LMS-Community/plugin-Qobuz` (master, `API.pm` + `API/Common.pm` + `Plugin.pm`) ·
`michaelherger/lms-plugin-tidal` (`API/Async.pm`) · `philippe44/lms-deezer` (`API/Async.pm` + `Plugin.pm`).
**Only Qobuz returns an envelope**; Deezer and TIDAL unwrap `{data}` themselves.

## Reference Code (read before porting)
- **LBF** `ListenBrainzFreshReleases/Browse.pm` — resolver family to port: `_findPlayable` (artist-only search strategy + priority/parallel/timeout resolution), `_norm`, `_albumMatches`, `_searchQobuz`/`_searchTidal`/`_searchDeezer` (adapter registration gated on plugin capabilities), `_rebuildStreamItems`, `_attachFavUrl`. `API.pm` — `getArtistMbidByName` (MB artist search), MB/CAA constants + async HTTP patterns.
- **PFR** `PitchforkReviews/Browse.pm` — the proven shape of a trimmed resolver port (what to keep/drop).
- **Listen Later** `ListenLater/Plugin.pm` — the actions.json read-merge-write this plugin's version was ported from.
- **Material source** (unminified): `LMS-Listen-to-Later/test-artifacts/lms-material/` — `customactions.js` (lmsbrowse), `emblems.js` (`getEmblem(extid)`), `browse-resp.js` (artist-view grouping, for the later integrated phase).

## Shared Matching Engine — FLEET SYNC RULE (2026-07-10)

The artist/album/track matcher (`_norm`, `%FOLD`, `_artistMatch`, `_albumMatches`,
fallback helpers `_stripFmt`/`_asciiNorm`/`_punctNorm`/`_stripArtistPrefix`; LBF also
`_trackMatches`) is ONE engine with a copy in each of these four repos:

- `LMS-ListenBrainz-New-Releases/ListenBrainzFreshReleases/Browse.pm` (origin, canonical)
- `LMS-Pitchfork-Reviews/PitchforkReviews/Browse.pm`
- `LMS-Discography/Discography/Sources.pm`
- `LMS-Listen-to-Later/ListenLater/Sources.pm` (hash-pinned LENIENT variant — empty-artist
  saved-item replay must still match; do NOT blindly align it)

**THE RULE: a matching fix in ANY of these repos must be applied to ALL repos carrying the
affected sub, in the SAME work session.** Enforcement — this must exit 0 before any matcher
change is called done:

    python3 LMS-ListenBrainz-New-Releases/tools/matcher_sync_check.py

It diffs the comment-stripped CODE of every copy across all four repos. Deliberate variants
are sha1-pinned inside the script with a reason, and FAIL the check if they change without a
conscious re-pin (`--print-hashes` prints current hashes). After aligning: bump every touched
repo's plugin version AND its match/decision cache versions (LBF: `lbf:stream` + `lbf:track` +
`lbf:pl:resolved` — ALL layers; PFR: `pfr:stream`; DSC: `dsc:cand` only if the cached candidate
shape changed — matching runs live there; LL: none — matching is live), rebuild zips + repo.xml
sha. Never leave a matcher fix in one repo "to port later" — that is exactly how the 2026-07
drift happened (LBF missed the P!nk/EP/ascii rules for months).

## Development Log
### 0.10.4 (2026-07-10) — code review of 0.10.0–0.10.3: correctness + scale fixes
- **Settings page rendered STALE after a save.** `dsc_types` / `dsc_services` were computed from `$prefs` *before* `SUPER::handler` persists the POST, so a saved form came back showing pre-save values (untick Singles, Save, box still ticked — the save HAD applied; a reload showed it). Worse, the base class refreshes its own `prefs` template var post-save, so the Local priority row (reads `prefs.*`) disagreed with the streaming rows (read `dsc_services`). **Fix = the platform's own hook**: `Slim::Web::Settings::handler` persists the POST, refreshes `$paramRef->{prefs}`, and THEN calls `beforeRender($paramRef, $client)` (a documented no-op in the base) immediately before `filltemplatefile`. Both vars moved there. **RULE (fleet-wide): any Settings template variable derived from a pref MUST be built in `beforeRender`, never in `handler` before `SUPER::handler`.** Same bug found and fixed in PFR (0.7.4) and LBF (0.9.85) the same session — DSC's Settings.pm was ported from PFR's, so the defect came with the port.
- **Qobuz `_candArtist` could come out undef**, failing `_albumMatches`' mandatory artist gate for every candidate in a healthy pool. `_renderQobuzAlbums` fell back to the resolved name only when `{artist}` wasn't a hash, so a hash *without* a `name` yielded undef; it also never consulted `{artists}[0]`. Hardened via the shared ladder. **Honest reachability**: NOT proven live — Qobuz's own `_albumItem` does `$album->{artist}->{name} || ''`, and `artist/get` items normally carry a named `{artist}`. It IS reachable for Deezer, whose `_renderAlbum` autovivifies an empty `{artist}` as a side effect; `_renderAlbums` therefore computes `_candArtist` BEFORE calling the renderer.
- **`_albumArray` envelope guard** — I first read the dead `{data}` unwrap in the Deezer search leg as proof the API layer returns envelopes. **It doesn't.** Verified in the plugin sources: Deezer `Async.pm` `artistAlbums`/`search` both do `shift->{data}` then `$cb->($albums || [])`, and TIDAL's `artistAlbums` likewise passes a plain ARRAY — that unwrap could never fire. Only Qobuz hands back the whole result hash (`{albums}{items}`). `_albumArray` now centralises that one real reach and stays tolerant of an envelope if a plugin changes; it is hardening, NOT a bug fix, and the original `ref $albums eq 'ARRAY'` checks were correct.
- **The three `_render<Svc>Albums` loops collapsed into one `_renderAlbums($albums,$svc,$artistName,$render,$skip)`** (~66 lines -> ~25). The Qobuz bug above WAS that duplication drifting. Per-service quirks are now coderefs: Qobuz's streamable `$skip`, each plugin's own renderer.
- **Pool reads hoisted out of the per-release loop.** `peekMatches` did a `cache->get` + full `_reattach` shallow-copy of every cached item ONCE PER RELEASE GROUP; artist-first pools run to thousands, so a 50-release list did tens of thousands of hash copies synchronously on the event loop. New `Sources::peekPool($artist)` reads+reattaches once per build; `_buildList` passes it into `peekMatches` as an optional 5th arg. Safe because `matchesFor` copies matched items before decorating them.
- **`SVC_TIMEOUT` 8s -> 20s** — it was sized for one 50-item search, but the fetch is now artist-search THEN artist-albums (Tidal: 3 paginated bucket pulls). A timeout ALSO threw away a result that landed late; `$settle` now still caches a late non-empty result (only the `$cb` is spoken for), so completed work is never discarded into a 1h error pin.
- **`_dbg` was a third verbatim copy** (API + Browse + Sources). Canonical `Plugins::Discography::Plugin::dbg` now; the three modules are one-line delegators (PFR/LBF pattern).
- Docs: removed a false "DELIBERATE DIVERGENCE / port upstream" claim from `_albumMatches` and the 0.10.3 entry (the port had already landed; `matcher_sync_check.py` exits 0 with all three repos in sync), and corrected the Phase-1 cache-key list, which documented a `dsc:match:` / `dsc:svc:` cache that has never existed.
- **KNOWN, NOT FIXED**: `matchesFor` re-runs `_norm` on every candidate title+artist for every release group (~350k Unicode normalisations for a 50-release list against 7k pooled candidates). Fixing it means memoising or precomputing inside the fleet-pinned matcher subs, which must land in all four repos in one session — worth doing, but not as a drive-by.
- Gates: `perl -c` clean on all 5 modules; 23/23 behavioural assertions via the real module (`_albumArray` envelopes, Qobuz artist fallback, renderer error-vs-empty semantics, short-title matcher regression guards); `matcher_sync_check.py` exit 0.

### 0.10.3 (2026-07-10) — matcher: all-punctuation / single-char titles ("( )", "X")
- `_norm` strips parenthetical content, so Sigur Rós's "( )" normalised to '' and died at the <2-char gate (same for any single-char title like "X" — length 1). New branch in `_albumMatches`: when `length $albumNorm < 2`, compare `_punctNorm` (lowercase, whitespace stripped, punctuation KEPT: "( )" == "()") of the RAW titles — exact equality ONLY (a prefix rule would let "x" swallow "xx") and the artist gate is mandatory. `_albumMatches` gained a 5th arg (raw MB title) — both call sites (matchesFor, claimedLocalIds) pass it. No cache bump (candidates cached raw; matching runs live). Verified via the real module: 9/9 incl. must-not-match controls (live edition, "(bonus)", wrong artist, x-vs-xx). Ported to LBF + PFR the same session per the fleet rule — `matcher_sync_check.py` reports `_albumMatches`/`_punctNorm` IN SYNC across DSC/LBF/PFR, so this is NOT a divergence (an earlier draft of this entry wrongly called it one).

### 0.10.2 (2026-07-10) — artist-first candidate fetch (search-cap lottery fix)
- **Bug (field, on 0.10.1): Qobuz pool healthy (193) but Valtari + Með suð í eyrum... still unmatched.** Root cause: album-search-by-artist-name is a relevance LOTTERY — Qobuz catalog/search caps at QOBUZ_DEFAULT_LIMIT=200 and those albums ranked outside the top 200 for query "sigur rós" (193 = 200 minus streamable/render drops). Our Tidal/Deezer searches were capped at 50 — same exposure, just lucky.
- **Fix: every adapter now resolves the ARTIST on the service first** (artist-type search → `_pickArtist`: normalised exact name wins, else first `_artistMatch` token-subset hit) **then pulls that artist's own album list** — complete by construction: Qobuz `getArtist` (artist/get extra=albums), Tidal `artistAlbums` × 3 filter buckets ALBUMS/EPSANDSINGLES/COMPILATIONS merged id-deduped (TIDAL splits discographies across filters; MAX_LIMIT 5000), Deezer `artistAlbums` (single list, MAX_LIMIT 2000; payload has NO artist object — resolved name passed as `_renderAlbum`'s 3rd arg like the plugin's own getArtistAlbums does). Old album search kept as fallback when no artist resolves (stylised names, absent artists). Raw-empty artist-albums settles as ERROR (1h retry) not a 1d empty pin. Render loops factored into `_render<Svc>Albums` shared by both paths. CAND_CACHE_V 2->3.
- `( )` (Sigur Rós 2002) still can't match: all-punctuation title normalises to empty — matcher's <2-char gate. Known, separate.

### 0.10.1 (2026-07-10) — per-service query encoding (Sigur Rós fix) + MB-resolution debug logging
- **Bug (field, Sigur Rós): accented artists got junk/empty Qobuz+Tidal candidate pools while Deezer worked.** Root cause: getCandidates octet-encoded the search query for ALL adapters, but the service plugins' own URL layers differ — Qobuz escapes query params with `uri_escape_utf8` (plugin-Qobuz API.pm) and Tidal transliterates them with `Text::Unidecode` (lms-plugin-tidal API/Async.pm): both expect CHARACTER strings, so octets double-encoded ("Sigur Rós" searched as "Sigur RÃ³s" -> Qobuz 92 junk candidates, Tidal 0). Deezer's `complex_to_query` percent-encodes bytes, so octets were right there. Fix: adapters carry `query_enc => 'chars'|'bytes'`; getCandidates builds both spellings (`utf8::decode` fails safe on non-UTF-8) and passes each adapter its own. CAND_CACHE_V 1->2 flushes poisoned pools.
- **LBF and PFR had the SAME bug** (identical `$queryEnc` octets into the same adapters) — **backported the same session** (LBF 0.9.82, PFR 0.7.2); both now carry `query_enc`/`qChars`/`qBytes`. Likely retro-fixed part of LBF's "accents" known-gap class.
- Diagnosis was pure HTTP: debug_log pref on via jsonrpc, feed run, `server.log` fetched over HTTP — the `pool:` counts split matcher-rejection (healthy pool) from search failure (empty pool) exactly as designed. New: candidate debug line now samples the first 3 "artist - title" entries (wrong-artist pools are otherwise indistinguishable from matcher rejections), and API.pm MB artist/RG resolution failures now log through the same debug_log-elevated `_dbg` (score-gate misses say WHY + that the miss sentinel lasts 1d; HTTP errors say retry works). Field report "failed MB artist match" for Better Oblivion Community Center was unreproducible minutes later (resolves fine, score 100) — with the new logging a recurrence will say which path failed.

### 0.10.0 (2026-07-09) — step 5: settings page (scope complete)
- **Settings.pm** (PFR's template): sections Playback sources (Local row always present + serviceStatus-driven streaming rows w/ detected/not-installed, priorities 0-9 sanitised, absent-field-keeps-current), Discography view (sort radio, release-type CHECKBOXES -> show_types CSV via a `dsc_types_form` marker field distinguishing none-ticked from partial POST, hide_unmatched, show_bio w/ grid-tradeoff note, show_library_extras), Release page (show_all_versions), Integration (material_action w/ restart+refresh note, debug_log).
- install.xml gains `<optionsURL>`; Plugin.pm requires Settings under main::WEBUI. @TYPE_KEYS mirrors Browse's @GROUP_ORDER — keep in sync.
- ORIGINAL 5-STEP SCOPE COMPLETE.

### 0.9.6 (2026-07-09) — "Show other versions" inline toggle on the detail page
- Single-version detail gains a "Show other versions" row (only when >1 version exists) — the refresh-toggle pattern (ctx `{ver}{rg-mbid}`, preserved across same-artist fresh entries like bio/rev): expands IN PLACE to the full per-service layout (headers + all rows), "Hide other versions" collapses. `show_all_versions` pref = permanently expanded (no toggle rows).
- Play-string discipline holds in both states ($keptPlay spans the branches): exactly ONE play-string row per detail feed, so tile play stays single-version.

### 0.9.5 (2026-07-09) — prose rows aligned to the avatar column
- Simon's screenshot: prose (meta/review/bio) rendered flush to the viewport edge (Material's `browse-text` CSS is padding:0) while icon rows start at the avatar column. Fix: text rows render via **v-html**, so the indent lives INSIDE the content — `_proseRow` wraps HTML-escaped text in `<div style='margin-left:72px'>` (72px = Material's list avatar slot; a constant, adjust if it looks off on some skin/scale). Applied to: bio summary+paragraphs, review summary+paragraphs, no-match note, and the detail META row (now bold-title + sub line HTML; its image DROPPED — the view header already shows the artwork, and text+image would clamp per 0.7.2).
- Escaping matters: review/bio text passes through `_escHtml` before wrapping (titles can contain &/</>).

### 0.9.4 (2026-07-09) — local-first tile play (db: URLs) + multi-enqueue fix
- **READ THE LMS 9.0 SOURCE** (XMLBrowser.pm + Commands.pm, fetched from GitHub) — two findings that rewrite our play understanding:
  1. **Tile `play` attr is IGNORED for non-audio items.** XMLBrowser's play on a playlist-type item expands its url feed and collects, ONE level deep, every child that is type-audio-with-url OR has a `play` string, then loadtracks the lot. Our tile play "worked" in 0.5.0 only because the single-version detail feed happened to expose exactly one play-string row. COROLLARY BUG (fixed here): all-versions mode would have enqueued EVERY service's copy — now only the FIRST (preferred) version row keeps its `play` string; stripped rows still play via their own url tracklist feeds.
  2. **`db:` URLs are core-playable**: `playlist play db:album.id=N` -> Commands.pm `_playlistXtracksCommand_parseDbItem` -> generic branch `Slim::Schema->search($class, {$key=>$value})` -> album's tracks (the exact album-Favorites replay path).
- **Local candidates now carry `play => 'db:album.id=<id>'`** -> the Local detail row is a play-string row -> with Local first in priority, tile play genuinely plays the LIBRARY copy. "Also in your library" tiles get it too. Tile favurl (LL/badge) stays streaming-only (no local scheme).
- Tile playUrl now comes from the first section of ANY source (was: first streaming).

### 0.9.3 (2026-07-09) — section headers for bio / options / review
- New `_sectionHeader` helper (walk-stable divider: emitted iff its rows exist; url->own kids for older Material). List view: **Biography** header (MTL_icon_person) above the bio rows, **Options** header (MTL_icon_tune) above sort+refresh. Detail view: **Review** header (rate_review icon) above the review block (summary or expanded). Release-type and per-service headers unchanged.

### 0.9.2 (2026-07-09) — "Also in your library" safety net
- New END section: library albums under the artist that NO release group claimed (MB gaps, odd editions, matcher misses — nothing owned can silently vanish). `Sources::claimedLocalIds` = pure-CPU matcher pass over ALL non-hidden-secondary RGs — deliberately INCLUDING type-filtered ones, so hiding e.g. Singles doesn't resurface a matched single as "unmatched". Pref `show_library_extras` (default 1).
- These tiles ARE the playable node (their url feed is the album tracklist — playlist type, so tile play works FULLY for these, unlike matched tiles' streaming-only play); no MB detail page to drill to (tap = tracklist). Year sorted per the toggle; header icon = Material `library_music`.
- localAlbums candidates now carry `_year`.

### 0.9.1 (2026-07-09) — matcher: artist-name-prefixed titles
- Real case (Simon's library): MB release-group "Write About Love" vs library/release title "Belle and Sebastian Write About Love (Bonus Track Version)" — the artist name PREFIXES the title on one side, and the matcher's prefix rule only tolerates trailing extra text. New gated fallback in `_albumMatches`: strip a leading "<artistNorm> " from BOTH sides, re-compare (>=3 char remainder; artist check still applies). Verified through the real matcher incl. a must-not-match control. Also fixes the same album's STREAMING match (services sell it under the long title).
- **DELIBERATE DIVERGENCE from the "verbatim" LBF/PFR matcher** — 4th known gap class (after accents / shorter-file-title / punctuation); candidate to port back upstream to LBF+PFR.
- No cache bump needed: candidates are cached RAW and matching runs live per render — matcher changes apply immediately (nice property of the candidate-cache architecture).

### 0.9.0 (2026-07-09) — step 4: local library matching
- **Local pseudo-source** in Sources.pm: `localAlbums($artistId,$artist)` — one SYNC `albums` CLI query per artist (`artist_id` first; name fallback via norm-verified `artists search:`), NOT cached (library is live, a rescan must show immediately). Candidates decorated identically to streaming ones (`_candTitle/_candArtist/_albumid/_cover`), so the verbatim matcher handles them. Row playback = `_localAlbumTracks` feed (`titles album_id:N sort:tracknum` -> audio items), so play/add work on the whole album.
- **`orderedSources`** = Local (svc_priority_local pref, default 1 = FIRST) + streaming adapters, priority-sorted; `matchesFor(..., $local)` merges local into the pool; NO favurl on Local rows (no service scheme). Streaming defaults re-numbered 2/3/4 (existing installs keep stored values — collision harmless, sort is stable with Local listed first).
- **Visibility semantics**: `peekMatches` now returns `{sections, resolved}` — `resolved` = streaming candidates were CACHED. A local match shows a release but deliberately does NOT set resolved: owning some albums must not hide the unowned rest before streaming was actually checked. `_buildList` does ONE localAlbums call per build and feeds every release's peek.
- **Tile play limitation**: tiles still play the best STREAMING match (first non-Local section) — a Local match has no play URL string, and a coderef can't ride the tile's `play`. Local playback = detail row. Candidate future fix: research XMLBrowser's play-path for url-coderef playlist items or a `db:album.title=...` favorites-style play URL.
- Match debug now shows Local in sections + pool.

### 0.8.2 (2026-07-09) — show_bio pref (bio vs grid-capable tiles)
- CONFIRMED: text + grid is impossible in one stock-Material view — text ITEMS disable grid (browse-resp.js:810) and even `window.textarea` is converted to an item AND sets canUseGrid=false (browse-resp.js:950-959). The only prose-over-grid layout is the LIBRARY artist view header (page chrome, not items) → more ammunition for the upstream "artist-view section provider" ask.
- New pref `show_bio` (default 1): on = bio rows (list layout); off = no text rows from us, tiles eligible for Material's grid toggle. Bio fetch skipped entirely when off.

### 0.8.1 (2026-07-09) — fix: bio "Read more" never expanded
- The bio toggle refreshes the TOP view; that re-fetch carries the artist params -> topLevel's FRESH-ENTRY branch replaced the whole per-player ctx, wiping the expand flag the toggle had just set -> re-render came back collapsed. (Review toggles on the DETAIL page worked because detail refreshes are paramless -> ctx preserved.) Fix: fresh entry preserves `{bio}`/`{rev}` expand flags when the artist is UNCHANGED; the visibility snapshot still resets (the refreshed render is a complete consistent tree, so that's safe).
- RULE for refresh-toggle state: any nextWindow=>'refresh' toggle whose view re-fetch carries the ENTRY params must have its state survive the fresh-entry ctx reset.
- Noted for later: lists >100 items render in Material's fixed-row RecycleScroller (`LMS_MAX_NON_SCROLLER_ITEMS`), which CLIPS tall text rows — inline bio expansion in a >100-row list (big artist, all types shown) will truncate. If that bites, options: shorter bio preview + drill (LBF's original choice) or chunked rows. Current albums-only lists are well under.

### 0.8.0 (2026-07-09) — artist bio atop the list + renamed to "Discography"
- **Artist bio** at the very top of the list view (above the action rows — the phase-2 artist-view vision, list-native): summary + the same refresh-toggle inline expand as reviews ("Read more"/"Show less", ctx flag `{bio}{lc artist}`). Source: MAI `ArtistInfo->getBiography` via LBF's direct-function pattern, artist MBID passed; cache `dsc:bio:1:<lc artist>` 30d/'' 1d. NO Last.fm fallback (needs LBF's key infra). **Bio is AWAITED in `_discographyView`** (parallel with release groups, single `$render` gate, assigned before fetches — compose-order trap): a bio popping in on a rebuild would shift every item_id below it. NB: no timeout on the MAI call (MAI has its own internal timeouts; LBF does the same).
- **Custom action renamed "Full Discography" → "Discography"** (can't promise completeness with streaming-gated matching). actions.json changes → needs install + restart + fresh Material client for the new label.

### 0.7.4 (2026-07-09) — inline review expand (refresh-toggle pattern)
- Material has NO inline expander for browse rows (its `v-list-group` accordion is context-menu-only; list rows are fixed models in a virtual scroller) — so "Read full review" is now a **refresh toggle**: flips `$lastCtx{cid}{rev}{<rg-mbid>}` and returns `nextWindow=>'refresh'`; the re-fetched detail view renders the full text INLINE (paragraph rows) with everything below pushed down; "Show less" flips back. Walk-safe because the flag only changes via the toggle rows and each flip immediately re-renders the view whose shape it changes. NEW UI PATTERN for the fleet: server-side expand/collapse via nextWindow refresh.
- Expansion state is per player per release, in-memory (resets on restart — fine, it's view state).

### 0.7.3 (2026-07-09) — REVERT 0.7.2's row-alignment images (broke the detail view)
- 0.7.2 gave EVERY detail row an image (1x1 transparent spacer on prose, MTL icons on links) to align text with the header thumbnail column. **Two Material behaviours make this unworkable** (confirmed by Simon's screenshot: detail page rendered as a GRID of cards, spacer as an empty tile):
  1. `browse-resp.js:800`: a `type=>'text'` item WITH an image is mutated to type "other" → loses the unclamped full-wrap prose rendering.
  2. Grid eligibility: once NO row is imageless, Material can promote the page to grid — an imageless row is what PINS a page to list layout (the LBF grid lesson, in reverse).
- RULE: **detail-page prose rows must stay imageless** — flush-left prose + icon-indented link rows is the fleet-standard look (LBF does the same deliberately). Kept: MTL icons on link rows (rate_review / launch), which render correctly.

### 0.7.1 (2026-07-09) — full-review formatting
- Full-review view: one text row per PARAGRAPH — split on blank lines (`\n{2,}`) ONLY, single newlines inside a paragraph collapsed to spaces so rows wrap cleanly. Material renders text rows unclamped/fully-wrapped and row spacing provides the paragraph gaps — LBF's full-bio recipe (its comment is the authority: "Material renders text rows in full, so the preview must be pre-trimmed"). 0.7.0's split also broke on single `\n` — would have shredded paragraphs into fragment rows.

### 0.7.0 (2026-07-09) — detail page: album review + external links
- **Review summary** under the detail header, cut at ~380 chars on a word boundary, with a "Read full review" drill (full text as paragraph rows, text carried in passthrough). Sources in order: (1) **MAI albumreview** via the direct-function pattern LBF uses for bios — `Plugins::MusicArtistInfo::AlbumInfo->can('getAlbumReview')`, called `($client, $cb, {}, {artist, album})`, review text expected in items' `name`; ALL guarded (missing MAI / signature change degrades silently). **UNVERIFIED against MAI source — first server test tells; debug_log shows which source fired.** (2) **Qobuz editorial description** — `_desc` captured in `Sources::_decorate` from the raw search album, rides the candidate cache. Review cached per RG: `dsc:rev:1:<mbid>` 30d, '' = confirmed-none 1d.
- **External links**: `API::getReleaseGroupUrls` — MB `release-group/<mbid>?inc=url-rels`, curated whitelist in display order (AllMusic, Discogs, Wikipedia, Review, Official site; one row per type), cached `dsc:urls:1:<mbid>` 30/7d. Rendered after the MB weblink row.
- **Compose-order trap fixed in review**: `$compose` must be assigned BEFORE the fetch calls — with all caches warm the entire callback chain runs synchronously and an unassigned coderef would crash. Two-leg completion guard (urls | candidates→review), each leg checks the other.
- NO_MATCH row logic now counts only VERSION rows (review rows don't suppress it).

### 0.6.0 (2026-07-09) — type filters, hide-unmatched, Material type icons, single-version detail, match debug log
- **New prefs**: `show_types` (CSV of group keys, default all: ALBUMS,EPS,SINGLES,COMPILATIONS,LIVE,OTHER), `hide_unmatched` (default 1), `show_all_versions` (default 0 = detail shows ONE row, the preferred service's best version; 1 = per-service header sections). All remotely settable via `["pref","plugin.discography:<name>","<v>"]`.
- **LIVE is now its own section** (secondary "Live" — was silently hidden pre-0.6). %HIDE_SECONDARY is Remix/DJ-mix only. Group precedence: Compilation > Live > primary type.
- **Header icons = Material's own release-type svgs** via the `MTL_svg_<name>` image-name convention (release-album/release-ep/release-single/album-multi/release-live/release — all verified present in Material's images/); placeholder pngs shipped so non-Material skins don't 404.
- **hide_unmatched is SNAPSHOT-STABLE**: visibility per release is frozen in the per-player ctx on first build of a visit (fresh entry or Refresh resets it — both re-enter topLevel WITH params, replacing the ctx). Without this, the background warm could flip a tile to hidden between render and click and every item_id below it would shift → wrong-release clicks. Unresolved (peek undef) NEVER hides — only a resolved no-match.
- **Match debug log**: `_dbg` in Sources.pm — `matchesFor` logs per release: matched services+counts or NO MATCH, plus each service's candidate-pool size (miss with healthy pool = matcher gap, debug with LBF match_check; empty pool = service search returned nothing). `debug_log` pref ON = ERROR-level (visible at default WARN), OFF = INFO. peek path logs too — expect ~1 line per visible tile per rebuild while ON.
- peekMatches result now computed once in _buildList and passed into _releaseItem (was peeked twice per tile).

### 0.5.0 (2026-07-09) — playable tiles + background warm
- **VERIFIED LIVE (jsonrpc, warm cache)**: XMLBrowser forwards `favorites_url`→`presetParams` ONLY for playable item types — identical favurl dropped on a `type=>'link'` tile, forwarded on `type=>'playlist'` rows. So matched tiles are now **type 'playlist'**: tap still drills to the detail page (go action), play/add play the whole tile.
- **Play target** = preferred service's match (first section of `peekMatches` — orderedAdapters is svc_priority-sorted, so no-match fallback to the next service is automatic): native `play` string if the renderer set one, else the favurl stripped of our private `?cover=/&a=` params (`<svc>://album:<id>` is exactly what LMS Favorites replays, so protocol handlers accept it). Unmatched/unresolved tiles stay 'link' (item COUNT unchanged — walk-stable).
- **Background warm**: `_discographyView` fires `getCandidates` async after MBID resolve (client-gated — no player context would cache empties) — first list render may be untagged, but any navigation re-renders playable/tagged, no drill needed.
- **Service text tag restored** in tile line2 (fallback while the emblem patch is unverified; remove once badges confirmed — patched Material shows both).
- Settings page still step 5; priorities are settable remotely via CLI: `["pref","plugin.discography:svc_priority_<svc>","<n>"]` (0 = never use). Defaults qobuz=1 tidal=2 deezer=3.
- Also verified live in this session: full 0.4.x detail flow on the server — Night Reign matched on ALL THREE services, header-basic dividers rendered, favurls correct per service.

### 0.4.2 (2026-07-09) — real service emblems via a local Material patch
- **test-artifacts/material-emblem-patch.md + material-deferred.min.js**: the server's stock bundle (Material w/ merged PR #1235) + ONE inserted statement at the top of `browseHandleListResponse` — items with a service-scheme `presetParams.favorites_url` get `item.emblem = getEmblem(scheme)`. Verified prerequisites: browse templates render `item.emblem` for ALL items (grid+list), `getEmblem` is global (emblems.js is a separate script tag), emblems.json has qobuz/tidal/deezer, anchor `function browseHandleListResponse(a,b,c,e,d,g){` unique in the bundle. Patch re-generation snippet:
  `python3 -c "src=open('live.min.js').read(); a='function browseHandleListResponse(a,b,c,e,d,g){'; ..."` — see the md file; **re-apply after every Material update** (fetch the live bundle from http://plex:9000/material/html/js/material-deferred.min.js first — the anchor's arg names may change with a new minify).
- **Tiles now carry `favorites_url`** of the top-priority cached match (peek): with the patch that draws ONE corner badge per tile (top service wins — the emblem system is single-badge), and it makes tiles addable to Listen Later. The text service tag ("· Qobuz/Tidal") is REMOVED from line2 — unpatched Material now shows no per-tile service indicator (deliberate: Simon runs the patch).
- Detail version rows already carried favurls → they get badges from the patch with no plugin change.
- OPEN QUESTION to verify on server: does XMLBrowser forward `favorites_url`→`presetParams` for plain `type=>'link'` OPML items (tiles)? Verified for the native service rows; if tiles don't get presetParams, favurl may need `type=>'playlist'`-style handling or an isaudio hint — check the tile JSON via jsonrpc after install.

### 0.4.1 (2026-07-09) — detail page: per-service Material headers
- Detail page now groups version rows under a header divider per service ("Qobuz (2)" etc.), same divider mechanics as the list (type per client, walk-stable tree, url->own rows on older Material). Headers carry NO image (LBF detail-page convention; service icons are plain .png which dividers never render anyway). Rows keep native album art; line2 = service name.
- **Service-badge investigation (Simon's ask: the Now Playing logo badges)**: TWO separate badge systems in Material, NEITHER reaches plugin-feed rows: (1) Now Playing = `getTrackSource(playerStatus.current)` — playing track's URL scheme -> logo, NP screen only; (2) browse rows = `extid` -> `getEmblem()`, applied ONLY in library response branches (albums/titles loops). Plugin-feed (item_loop) parse never sets `emblem`, and XMLBrowser doesn't forward `extid` for OPML items — BUT it DOES forward `favorites_url` into `presetParams`, which the item_loop parser already reads. So a ~3-line LOCAL Material patch (browse-resp.js item_loop branch: `emblem = getEmblem(scheme)` when `presetParams.favorites_url` matches `^[a-z0-9]+://`) gives app-feed rows real emblems — zero plugin-side change needed (our rows already carry the favurl scheme), benefits LBF/PFR/LL too. browse-resp.js lives in `material-deferred.min.js` — the same bundle the LTL patch workflow already targets (built copy present in LL test-artifacts/lms-material-test.zip). Candidate for the upstream ask list alongside custom-action visibility. NOT yet done — needs to know which Material build Simon currently runs (stock repo vs dev build with PR #1235).

### 0.4.0 (2026-07-09) — step 3: streaming sources (Sources.pm)
- **Sources.pm** (new): PFR's trimmed LBF engine, restructured for discography scale. KEY DIFFERENCES vs PFR: (1) candidates cached at ARTIST level (`dsc:cand:1:<svc>:<norm-artist>`, 3d found / 1d empty / 1h error) — one search per service serves every release group; per-release matching is a local filter, no API call; (2) ALL matching services kept (PFR stops at first-priority winner) — priority only orders sections. Adapters Qobuz/Tidal/Deezer, capability-gated, per-service 8s watchdog, parallel, `$cb` fires once after all settle. Coderef url stripped on cache write, reattached per service on read (disabled service -> its cached items drop). Matcher verbatim from PFR/LBF (_norm/_albumMatches/_artistMatch/_stripFmt/_asciiNorm) — keep in sync.
- **Detail page** now async: MB meta header → per-service version rows (native nodes from the service plugins' own renderers: url coderef + passthrough, so play/add/insert work natively; service LOGO as thumbnail + svc name in line2 — `extid` emblems verified LIBRARY-ONLY in browse-resp.js, item_loop branch has no emblem handling) → "Refresh streaming matches" (nextWindow refresh, clears the artist's candidate caches) → MB weblink. Each row carries the ListenLater favurl handshake (`<svc>://album:<id>?cover=&a=`). Resolve is cache-backed = idempotent under item_id re-walks.
- **Tiles**: `peekMatches` (cache-only, sync, no client needed) appends matched service names to line2 ("2021 · Album · Qobuz/Tidal") and — for UNDATED releases only (the CAA-gap tail) — swaps in service artwork. Tiles stay type 'link' (drill to detail); direct tile play deferred: making a tile type 'playlist' would make TAP open the tracklist instead of our detail page.
- `matchesFor` copies items before decorating (never mutate the shared cache entry); per-service dedupe + cap 4.

### 0.3.0 (2026-07-09) — grouped list: Material header dividers by release type
- List is now sectioned **Albums / EPs / Singles / Compilations / Other releases** (fixed order, count in each header, date sort per toggle WITHIN each group, undated last per group). Grouping: secondary "Compilation" wins over primary type; Broadcast/Other/untyped -> Other.
- Header mechanic ported from LBF: `_headerType()` = 'header-basic' on Material >= 6.4.3 else 'header' (which gets a FORCED drill action -> headers carry a url to their own section's tiles); non-header clients get a text divider. **The divider row is emitted for every client — only its `type` differs — so the tree shape/item_id indexing is identical however the feed is rebuilt** (the %lastCtx re-walk depends on this).
- Header image = DiscographyIcon_svg.png (dividers only render `_svg.png`/`_MTL_*` icons — plain .png is ignored; also keeps Material's grid toggle enabled since image-less items disable it page-wide).
- `features:hi` added to the custom action's lmsbrowse params: Material appends it on drill commands itself (browseBuildCommand) but NOT on the custom-action entry fetch — without it the top view got text dividers while drill rebuilds got real headers. `features` is stashed in %lastCtx with the artist context.
- Deploy note: actions.json changed AGAIN -> install + restart + **fresh Material client** (new incognito window; a stale tab keeps the old action).

### 0.2.2 (2026-07-09) — fix: the OTHER half of the dead clicks — missing `menu` param
- 0.2.1's stash didn't help the real UI because Material sends the lmsbrowse command VERBATIM — and ours had no `menu` param. Without one, XMLBrowser answers in the legacy `loop_loop` format: items with NO actions/params, so Material renders the list but every click builds an empty command → blank page. (My earlier live repro "worked" because I'd added `menu:discography` by hand — simulate what the client REALLY sends, verbatim, before trusting a repro.)
- Fix: `menu:discography` appended to the custom action's lmsbrowse params → SlimBrowse `item_loop` responses with per-item `go` actions. BOTH fixes are needed: menu mode for clickable items, the 0.2.1 stash because drill-backs still omit the artist params.
- Deploy note: the action definition lives in actions.json (rewritten at postinit) and Material caches customactions.json at app start → this fix needs install + restart + **hard refresh of Material**.

### 0.2.1 (2026-07-09) — fix: every click in the list was dead
- **Symptom**: release tiles did nothing; sort toggle and Refresh opened a blank page.
- **Root cause (reproduced live via jsonrpc)**: Material browses app feeds in SlimBrowse/menu mode; a click sends back ONLY `item_id:<path>` + `menu:discography` — the lmsbrowse entry params (artist_id/artist) are NOT echoed, and with `cachetime=>0` there's no server-side session tree. XMLBrowser re-runs the TOP feed paramless on every drill → our topLevel served the Apps-hint page → the item_id walk hit a dead text row.
- **Fix 1 — `%lastCtx` stash**: topLevel stashes {artist_id, artist} per player id on a param-carrying entry; a paramless re-entry rebuilds the identical view from the stash (deterministic order, API-cache-fast), so item_id walks resolve. KNOWN LIMIT: one artist per player — navigating back into artist A's stale view after opening artist B walks B's tree.
- **Fix 2 — Refresh is `nextWindow=>'refresh'`** (LBF pattern), not a drill-in: clear rg cache, return empty items, client re-fetches the parent (which still has the artist params). The drill-in version was also a trap: later clicks re-walk through the Refresh node and would have re-cleared the cache on every navigation.
- Sort toggle stays a drill-in (it must show different content); its subtree is re-walked cheaply from cache. DESIGN RULE going forward: every url-sub item must be idempotent + side-effect-free, because XMLBrowser re-executes the whole item_id path on each deeper click; anything with side effects must use nextWindow refresh instead.

### 0.2.0 (2026-07-09) — step 2: MusicBrainz discography list
- **API.pm** (new): `getArtistMbid` (library `contributor.musicbrainz_id` first — exact identity; else MB name search port, score>=90 gate, '' = cached not-found sentinel); `getReleaseGroups` (paginated `release-group?artist=<mbid>`, 100/page serial with 1.1s gap, 6-page cap with truncation warn, lean `{mbid,title,date,type,secondary[]}` entries, `dsc:rg:v1:<mbid>` 14d cache, force bypass); `caaImage` (CAA release-group front-250/500 plain URL, 404 = default art); memoised MB-etiquette USER_AGENT.
- **Browse.pm**: real list view — sort toggle + Refresh action rows at top (re-enter `_discographyView` via passthrough; Refresh clears the rg cache first), tiles (title / "year · type" line2 via `\x{00B7}` escape / CAA image), ISO-date sort with undated LAST in both directions, secondary-type filter (`%HIDE_SECONDARY`: Live, Remix, DJ-mix; Compilation deliberately KEPT and displayed as the type label). Detail page: artwork, full date + type, "View on MusicBrainz" release-group weblink, step-3 placeholder line. `cachetime => 0` on the feed so toggles re-run (the data layer caches instead).
- **Non-ASCII in output**: use `\x{..}` escapes (LBF does exactly this) — the 0.1.1 rule refined: literals are the problem, escapes are the fleet-sanctioned way.
- **Icon added** (also the suspected Apps-tile fix): vinyl-disc SVG in #000 + qlmanage-rasterised PNGs; `<icon>` now in install.xml. Re-check the Apps menu on this install.
- **MB response shape verified live** (13th Floor Elevators, 52 RGs): `release-groups`/`release-group-count`/`first-release-date` (empty string when unknown)/`primary-type`/`secondary-types` all as coded.
- Strings moved to `cstring` tokens (PLUGIN_DISCOGRAPHY_*).

### 0.1.1 (2026-07-09) — fix: mojibake in skeleton title
- The em dash in Browse.pm's title literal rendered as "â…" — **fleet convention: NO non-ASCII in user-facing string literals** (no plugin uses `use utf8`, so source-literal multi-byte chars double-encode on output; comments are fine, JSON-decoded API data is fine). Replaced with ASCII hyphen; added a comment marking the rule.
- Step 1 verified end-to-end on the server: context menu → skeleton view, artist name resolved from `artist_id` via Slim::Schema.
- Open: no Apps-menu tile observed (context menu + feed work regardless). Suspect the missing `<icon>` in install.xml vs LBF/PFR which both list; add a real icon in step 2 and re-check. Apps entry is a testing convenience only.

### 0.1.0 (2026-07-09) — step 1: skeleton + entry point
- New plugin: `Plugins::Discography`, tag `discography`, prefs `plugin.discography`, log category `plugin.discography` (prefix `dsc:`, WARN default, `debug_log` pref for opt-in detail).
- Registered as an OPMLBased app; Apps-menu entry shows a "use the artist context menu" pointer.
- Material custom action write/clear implemented (see Key Mechanics); prefs seeded: `material_action`, `sort_order` (newest), `svc_priority_qobuz/tidal/deezer` (1/2/3), `debug_log`.
- `Browse::topLevel` placeholder: resolves artist name from `artist_id` via `Slim::Schema` Contributor, renders "Skeleton OK" text rows.
- Open question to confirm on first install: does the action appear on BOTH artist list rows and the artist page's toolbar "…" menu, and what does `$TITLE` carry on the latter? (Feed already guards; answer shapes nothing structural.)
