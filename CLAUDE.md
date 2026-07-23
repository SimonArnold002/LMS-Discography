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
- **Cache keys**: `dsc:mbid:<norm-artist>` 30d · `dsc:rg:<mbid>:vN` 14d · `dsc:cand:vN:<svc>:<norm-artist>` 3d found / 1d empty / 1h error · `dsc:urls:` · `dsc:bio:` · `dsc:rev:` · `dsc:mbmirror:v1` 1d (auto-detected same-host MB mirror base; URL=found, `''`=probed-none) · `dsc:asearch:2:<lc query>` 10min (merged artist-search results — written ONLY when every source settled OK, so a service timeout can't pin a degraded list; see 0.42.2). There is **no match-result cache** — candidates are cached RAW and matching runs live per render, so a matcher change takes effect immediately and only needs `dsc:cand` bumped when the cached candidate SHAPE changes. No background warming while a library scan runs.

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
├── Browse.pm       # topLevel ($VAR guard, %lastCtx stash+expand flags+page counts+visibility snapshot); app-root view (_rootView: _coverCollageRow responsive random-album-cover banner, About prose, search section, "Works best with" live plugin-status badge rows w/ badgeSrc imageproxy normaliser); global artist search (_searchRow type=search item in the app root + Options section, go action overridden w/ search:__TAGGEDINPUT__ fixedParams -> topLevel search-param dispatch GATED on item_id being absent, so a positional walk still reaches the row's own coderef; _artistSearchView w/ 10-min merged cache, only written when every source settled OK, _searchResultRow name-drills); grouped list (bio header, Options/type/library-extras sections, sort+Refresh, _pageSection 30-at-a-time Show more/less, "Also a member of" band links + "Similar artists" name-drill links w/ MAI artist-photo thumbnails, both second-load); release detail (review w/ inline expand, version rows w/ Show-other-versions toggle, MB links); _proseRow avatar-column indent
├── API.pm          # Async MusicBrainz (base = mb_base_url pref, mirror-aware _mbBase/_mbGap): artist MBID (library tag first, MB search score>=90), paginated release-group browse, url-rels links; peekOfficial/warmOfficial/clearOfficial + _isOfficial (bootleg filter: artist-wide status pass -> {rg=>official?} + {release=>rg} maps, fail-open); peekLocalReleaseMap/warmLocalReleases (targeted release->rg for library albums); peekBands/warmBandMembers (member-of-band); CAA image URLs; caching
├── Sources.pm      # Source engine: Q/T/D adapters (artist-FIRST candidate fetch, per-adapter query_enc, shared _renderAlbums + _albumArray envelope unwrap), Local pseudo-source (sync albums query, db:album.id play), matcher (fleet-synced), matchesFor/peekPool+peekMatches/claimedLocalIds, LL favurl handshake; global artist search (searchArtists parallel per-service artist-type legs + Local CLI leg, cb(\%bySvc, \%failed) — the 2nd arg names services that ERRORED/TIMED OUT, since a failure settles as an empty list and callers must not persist an incomplete set; mergeArtistHits pure norm-keyed dedupe/rank + relevance gate vs the typed query); serviceStatus takes an OPTIONAL pre-built adapters list (omitted = probe); randomAlbumCovers (app-root banner, sort:random — measured ~20ms/2900 albums, cheap)
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
- **KNOWN, NOT PLUGIN-FIXABLE — the search row renders inline OR as a click-to-popup depending on the VIEW SIZE, not on anything the plugin sends (assessed 2026-07-23; Simon: "leave it alone").** Field: the `_searchRow` looks inline (an always-visible text box, the "home-page look") on some artists and as a clickable row that opens a text-entry popup on others (Stan Getz, British Sea Power — the look Simon prefers). Traced through Material source: a `type:'search'` item renders inline via a `<text-field>` in the normal list template (browse-page.js:406), BUT once a view exceeds `LMS_MAX_NON_SCROLLER_ITEMS` (~100 rows) Material switches to its virtual scroller (`useRecyclerForLists`, browse-page.js:674) where the row becomes a plain clickable row whose tap fires `promptForText` (browse-functions.js:1047-1055) — the popup. Same trigger for grid mode (`grid.use`). Big discographies (all type sections + extras + band/similar links) tip past 100 and get the popup; smaller ones stay inline; the home page is always small -> always inline. The item the plugin emits is BYTE-IDENTICAL in every view; there is **no per-item override** for the inline-vs-popup choice, so it cannot be forced from the plugin either way (a big artist ALWAYS exceeds 100 -> scroller). **The only fix is a ~2-line Material change** (exclude a marked search item from the inline-field branch at browse-page.js:406 + add `|| item.<flag>` at browse-functions.js:1048) — a local-patch/upstream-ask candidate, NOT built (Simon declined; would also need verifying a plugin-set marker survives XMLBrowser->Material). Do NOT re-investigate as a plugin bug.
- **KNOWN LIMIT — no entry on SEARCH results or an artist page entered FROM search (assessed 2026-07-15, NOT plugin-fixable).** Material expands custom actions from ONE view-level property (`view.itemCustomActions`, browse-functions.js:676): the artists browse sets it (`getCustomActions("artist")`, browse-resp.js:1106), but the search page is fully client-built and emits a synthetic resp with NO `itemCustomActions` (search-field.js:228 — it can't set one, the view mixes artist/album/track categories); and the drilled artist page's toolbar "…" is built (line 547) from the PREVIOUS view's value — leftover "artist" actions when coming from the Artists list (works), `undefined` when coming from search (nothing). Same class as LL's home-shelf leftover-state saga. **Upstream ask (small, general, can't regress):** in `browseActions`' CUSTOM_ACTIONS expansion, fall back to a per-item `getCustomActions(<category-for-stdItem>)` when the view property is undefined. Add to the Material asks list alongside custom-action visibility/placement.
- **Params → feed**: XMLBrowser's `cliQuery` passes tagged request params to the top-level feed as `$args->{params}` (same path Material's own `browselibrary items … artist_id:` uses; LBF/PFR read it the same way).
- **Settings template vars → `beforeRender`, NOT `handler`.** `Slim::Web::Settings::handler` (verified against LMS source) does, in order: persist each `prefs()` pref from `$params->{pref_<name>}` → refresh `$params->{prefs}{<name>}` from the store → call `$class->beforeRender($params, $client)` → render. So anything the template derives from a pref must be built in `beforeRender`; built in `handler` before `SUPER::handler` it is read PRE-save and a save re-renders the old values (looks like a lost save) while the base's `prefs.*` rows on the same page show the new ones. Sanitising the incoming `$params->{pref_*}` still belongs in `handler`, before `SUPER::handler`. Fleet-wide rule — DSC/PFR/LBF all had this bug (fixed 2026-07-10).
- **Local syntax gate**: `perl -c` with stubbed Slim modules (stubs in the session scratchpad; recreate as needed — Log, Prefs, PluginManager, Strings, Plugin::OPMLBased, Schema, JSON::XS).

## Stale-view bug + param-addressed navigation plan (diagnosed 2026-07-15)

**FIELD BUG (Simon, Marc Almond): navigate to another artist, go BACK to the previous artist's
still-rendered view, tap an album → empty page / play dead, until a Refresh.** Root cause chain,
all verified in LMS 9.0 XMLBrowser source:
1. XMLBrowser's per-session browse-tree cache (`xmlbrowser_<sid>`, item_ids prefixed with an
   8-hex sid) is **disabled for feeds containing coderef urls** (XMLBrowser.pm:346 "Don't cache
   if list has coderefs") — this whole plugin family is coderef-based, so every click re-runs
   the top feed and walks a freshly-built tree by POSITIONAL `item_id`.
2. The rebuild resolves the artist from the per-player `%lastCtx` stash = the LAST artist entered
   WITH params. Entering artist B re-stashes; Material's back button shows artist A's CLIENT-cached
   rows; the next tap walks B's tree server-side → wrong/absent nodes. (LMS restart clears the
   in-memory ctx → same symptom without visiting anyone.) Refresh / re-entry re-stashes → "fixes" it.
3. Siblings (PFR page-state, LBF paging) carry milder versions but their top levels are GLOBAL —
   DSC's per-artist top level is why it bites here.

**THE FIX (planned, staged): self-identifying clicks via XMLBrowser `itemActions` / feed-level
`actions`** (verified in source, lines 1274–1345 + `_makeAction`/`findAction`): a row can carry its
OWN go/play command with `fixedParams` (+ `variables`/`commonVariables` mapping item fields, e.g.
`[ item => 'id' ]`) — the click then sends explicit params (`rg:<rg-mbid>` + artist identity)
instead of a positional item_id, and the server renders that node DIRECTLY — no ctx, no walk.
Param-addressed navigation is how LMS's native menus work; LL already uses the `info` flavour.
- **Stage 1 — SHIPPED in 0.34.0** (fixes the field case): release TILES get `itemActions.items`
  (go → `rg:` + artist params; topLevel dispatches `rg:` to the release detail, re-stashing ctx);
  DETAIL rows carry per-row `id`s + their own `itemActions` (per-item, NOT feed-level — item-level
  actions ride `$item->{nextWindow}` for the refresh toggles) so version rows / toggles / headers /
  Refresh are param-addressed too; tile + version-row PLAY moves to an explicit
  `['discography','playcmd',…]` CLI dispatch (itemActions.play/add/insert) since XMLBrowser's
  default play action is also positional (`item_id`); band/similar rows get `itemActions.items`
  with their existing mbid/name entry params (the direct-mbid path already handles them).
- **Stage 2 — SHIPPED in 0.35.0**: the LIST view's controls. `item:` WITHOUT `rg:` dispatches via
  `_listItemDispatch` (private `_discographyView` render → invoke the row's coderef — same collector
  as `_rgView`). Row ids: `bio:more/less`, `act:refresh`, `page:<KEY>:<target>`, `sect:<KEY>`
  headers, `lib:<album_id>` extras tiles (their play/add/insert carry the whitelisted
  `db:album.id=N` url straight to playcmd's direct mode). The SORT toggle instead rides an explicit
  `sort:newest|oldest` param (fresh entry, drill-in UX kept); `_identParams` folds a valid sort into
  every action's params so a sorted view's toggles re-issue the sorted command and the order sticks.
- `%lastCtx` stays (walk-stability for legacy paths + non-Material skins); the itemActions override
  only changes what MATERIAL sends on tap. nextWindow (refresh toggles) rides `_makeAction`'s
  nextWindow passthrough (from `$item->{nextWindow}`).
- **KNOWN LIMIT — header taps (assessed 2026-07-15, Simon: "leave as is").** On Material >= 6.4.3 our
  `header-basic` dividers are NON-clickable BY DESIGN (browse-resp.js:271 wipes `actions` at parse) —
  "tap a header -> that section only" is not a supported plugin-feed interaction. Worse, the wipe
  leaves `addAction` ('go', forced by XMLBrowser on EVERY non-playable non-text item — line 1230
  branch + 1251; NOT suppressible server-side), so Material's dead-click guard
  (browse-functions.js:1059 `!actions && !addAction`) never fires and a header tap falls through to a
  paramless fallback -> lands on the plugin default page (a Material BUG — upstream one-liner: wipe
  `addAction` with `actions`). The headers DO carry param-addressed `sect:` go actions server-side
  (verified live), so if this is ever revisited: emit type `header` instead (actions survive, More
  chevron renders, tap = our section view) — the historic blockers were the positional dead drill
  (fixed by 0.35.0 param-addressing) and LL 0.1.29's "actionable header renders as a grid card on
  >= 6.4.3" (UNVERIFIED on 6.4.4 — check by eye before shipping). Declined for now.

## NOTE (Simon, 2026-07-19): the streaming spine may be the way OUT of the same-name hole

Recorded at Simon's request while fixing the "Also on streaming" junk: *"Make a note of this as
it may well be our only way out of this hole."*

Everything in 0.43.x-0.44.x fights the same fight — MusicBrainz is the identity spine, the
services have their OWN artist entities, and the two are joined only by NAME plus catalogue
corroboration. Every edge case so far is a seam in that join: same-name acts, diacritic variants
(Maedness), alias-only streaming names (Tony Madness), an artist whose service entity holds a
different selection, releases the services carry and MB does not.

The alternative, worth weighing properly when this settles: **let a resolved SERVICE artist be a
spine in its own right**, with MB as an enricher rather than the gate. The pieces already exist —
`_resolveArtist` identifies the right service entity, "Also on streaming" already renders
unclaimed candidates as first-class rows. What is missing is navigation keying for releases with
no rg-mbid (see the PLANNED section below, which scoped exactly this for MB-ABSENT artists) and a
decision about what the release DETAIL page shows without an MB release group.

Not a small change, and not one to start mid-firefight — but the accumulating edge cases are all
symptoms of the same architectural choice, and that is worth saying out loud.

## TRIAGED — the sweep's "66 owned albums not attached to a tile" (2026-07-22)

Recomputed LIVE against 0.47.4 (all 57 artists re-browsed, contributor ids re-derived — the library
had been rescanned since the sweep): **63 albums across 54 artists** now, and the sweep's headline
figure hid six unrelated causes. **NONE of them loses music**: every one of these albums is visible
and playable in *Also in your library* — the safety net doing exactly its job. The defect, where
there is one, is that the owned copy is not MERGED with its MusicBrainz release group.

| Cause | Share | Example | Verdict |
|---|---|---|---|
| **Classical** (composer/performer entities) | **17 albums, 15 artists** | New York Philharmonic *The Complete Mahler Symphonies*; *Masters of Music: Berlioz* | **PARKED** with the classical cluster |
| **Hidden by the type filter** (Remix / DJ-mix secondary) | 3+ confirmed | alt-j *Reduxer*, Jazzanova *Remixed*, Soft Cell *Non-Stop Ecstatic Dancing* | **BY DESIGN.** The RG matches; `%HIDE_SECONDARY` hides it, so the owned copy has no tile to attach to |
| **MB credits a BAND the artist is in** | sampled | Neko Case *Furnace Room Lullaby* -> MB credits **"Neko Case & Her Boyfriends"** | **BY DESIGN, and fully reachable** — see the correction below |
| **MB uses the ORIGINAL-LANGUAGE title** | 5 albums | Kraftwerk *Radio-Activity* -> MB **"Radio‐Aktivität"** | **WRONG VERDICT — corrected below. Fixable with one query parameter.** |
| **Spelling variant** | sampled | Pet Shop Boys *Behavior* (US) -> MB **"Behaviour"** (UK) | Real matcher gap |
| **Library title is SHORTER than MB's** | sampled | Orange Juice *Very Best Of* -> MB **"The Very Best of Orange Juice"**; House of Love *House Of Love* -> MB **"The House of Love"** | Real matcher gap — the prefix rule only tolerates EXTRA text on the candidate, and 0.11.1's self-titled EXACT rule blocks the "The"-less spelling |

**CORRECTION, after Simon pointed out the tagging (2026-07-22).** I first wrote that the Neko Case
albums are "not in this mbid's spine and never will be", which reads as unreachable. **They are
reachable, by the design 0.25.0 chose deliberately, and it was verified live end to end:**
- the library tags them `ALBUMARTIST = Neko Case & Her Boyfriends` with **`TRACKARTIST = Neko Case`**,
  which is a PERFORMANCE role — so LMS and `localAlbums` rightly show them under her;
- MusicBrainz models the same thing: `member of band -> Neko Case & Her Boyfriends` (forward);
- her page therefore lists that band under **"Also a member of"**, and browsing it renders
  **Furnace Room Lullaby (2000) · Local/Tidal** and **The Virginian (1997) · Local** as proper matched
  tiles — while the same albums ALSO appear under *Also in your library* on her own page.

0.25.0's rule is that a person's page shows their SOLO-credited releases plus links to their bands,
rather than folding a band's catalogue into the person. This case is that rule working. **Do not
"fix" it by merging band release groups into the person's spine** — that is the design Simon
explicitly rejected, and it would put records the artist made under another name on the wrong page.

**CORRECTION #2, after Simon challenged the Kraftwerk row (2026-07-22).** Simon: *"The Kraftwerk
issue needs looking at more as it resolves cleanly in MB using english as do all their titles."*
**He was right and my verdict was wrong.** MusicBrainz DOES carry the English titles — as release-
group **ALIASES**, which `getReleaseGroups` (`API.pm:1543`) has never asked for:

```
Radio‐Aktivität     alias -> Radio-Activity          Computerwelt   alias -> Computer World
Die Mensch·Maschine alias -> The Man·Machine         Electric Cafe  alias -> Techno Pop
```

It was never a translation-source problem; the data was one query parameter away (`&inc=aliases`).
Cost: **no extra requests**, +20% payload (28.4KB -> 34.2KB per 100-RG page), no measurable time
change; only 5.0% of release groups (530 of 10,565 across the 54 gap artists) carry an alias at all.
Two more gaps fall to the same fix, and one is otherwise unreachable by ANY normalisation rule:

- **Prince** *Sign 'O' the Times* — MB titles it **`Sign “☮︎” the Times`**, with the peace symbol.
- **Big Star** *Third/Sister Lovers* — the release group is titled `3rd`, alias `Third`.

**Alias support is DSC-side** (the MB fetch layer + the two `_albumMatches` call sites, via the
existing `$opt` hash — no signature change), so it is NOT blocked behind the fleet `_norm` port.
This drops the "real matcher gap" count from 11+ to **11 exactly** (listed below). The same alias
field also feeds tier TA of the identity index — see the PLANNED index section.

**THE 11 REAL MATCHER GAPS** (fleet job — they live in `_albumMatches`, synced across DSC/LBF/PFR/LL,
so they belong with the outstanding `_norm`/`%FOLD` port debt from 0.44.26):

| Artist | Owned | MB spine title | Failing rule |
|---|---|---|---|
| Pet Shop Boys | Behavior | Behaviour | US/UK spelling |
| Orange Juice | Very Best Of | The Very Best of Orange Juice | library title shorter |
| The Orb | Adventures Beyond The Ultraworld | The Orb's Adventures Beyond the Ultraworld | library title shorter |
| The Orchids | Who Needs Tomorrow | Who Needs Tomorrow... A 30 Year Retrospective | library title shorter |
| James | Be Opened By The Wonderful | Be Opened by the Wonderful: 40 Years Orchestrated | library title shorter |
| The Sleepy Jackson | Personality (One Was A Spider…) | Personality: One Was a Spider, One Was a Bird | `_norm` strips the bracket -> shorter |
| Cliff Martinez | Drive [Original Score] | Drive: Original Motion Picture Soundtrack | bracket stripped -> shorter |
| The House of Love | House Of Love | The House of Love | self-titled EXACT rule + missing "The" |
| The Psychedelic Furs | Psychedelic Furs [Expanded] | The Psychedelic Furs | same |
| The Waterboys | The Best of the Waterboys: 1981-1990 | The Best of The Waterboys: '81–'90 | year formatting |
| Elvis Presley | The Complete '68 Comeback Special: 40th Anniv. | Memories: The '68 Comeback Special | different compilation title |

**Six of the eleven are ONE rule**: the prefix rule tolerates extra text on the CANDIDATE only, never
on the MB side. That single line is the highest-value item in the list.

**RESOLVER, NOT MATCHER — a separate class found in the same triage (6 albums, 4 artists).**
`Jack`, `Roswell`, `Muzz`, `Rico` browse to the WRONG same-name MB artist. Diagnosed in full, and
the browse-time fix was **measured and REJECTED** (up to 13 extra MB round-trips for ~3 albums);
the batch answer is the PLANNED identity index below. `Rico` loses nothing either way — the library
carries BOTH `Rico` and `Rico Rodriguez`, and the album attaches correctly under the latter.

**METHOD NOTE — the numbers are mechanism-verified, not guessed.** Each sampled title was run through
the REAL `_albumMatches` against that artist's REAL MusicBrainz spine (fetched from the mirror), so
"no match" is the shipped matcher's own verdict rather than an inference. Two harness bugs were caught
doing it, both of which produced confident nonsense first time round:
- the argument order (`artistNorm, albumNorm, candArtist, candTitle, albumRaw` — the SPINE title is
  the pre-normalised second arg) was wrong, and every case reported NO MATCH including albums that
  plainly do match;
- an mbid was hand-retyped from a truncated 8-char display and 404'd. **Never reconstruct an mbid from
  a shortened one.**

**IF THIS IS EVER FIXED, IT IS A FLEET JOB.** The two real matcher gaps (spelling variant, shorter
library title) live in `_albumMatches`, which is fleet-synced across DSC/LBF/PFR/LL — so they belong
in the same session as the outstanding `_norm`/`%FOLD` port debt from 0.44.26, not as a DSC-only
patch. Estimated value is low: roughly a dozen albums that are already visible and playable.

## PARKED — CLASSICAL NEEDS A DIFFERENT SPINE (Simon, 2026-07-22): evaluate Open Opus or similar

Simon, after a session of chasing classical bugs one at a time: *"I think we should perhaps look at
a different approach for classical composers/music in general looking at OpenOpus or similar as they
are designed for classical music. MusicBrainz isn't really good for it due to how it mixes up
composers/performers often into titles etc."*

**Parked deliberately. Do NOT keep patching the same-name/resolver machinery for classical cases** —
this session proved the ceiling, and the evidence below is why. Every fix landed correctly and the
pages are still wrong in ways the architecture cannot express.

### WHAT WAS MEASURED (2026-07-22, live, mirror + all three services)

- **The model does not fit.** The plugin joins ONE MusicBrainz artist to ONE service artist by name
  plus catalogue corroboration. Classical has a composer AND performers, and the services file the
  record under the PERFORMER while MusicBrainz files the work under the COMPOSER. Neither is wrong;
  they are answering different questions.
- **Qobuz drops 190 of ~200 albums on a composer's own artist page** because the credit is the
  performer: `Qobuz/229370: dropped 190 album(s) credited to other artist ids | Rossini: Il barbiere
  di Siviglia [credit Teresa Berganza id 27149]; Rossini: Overtures [credit Antonio Pappano id
  35163]`. `_filterForeignArtist` is behaving exactly as designed.
- **Composer metadata cannot rescue it.** Qobuz is the ONLY service carrying composer data at all
  (`API/Common.pm` `composer`/`composerId`; Tidal and Deezer have zero references) — and the Qobuz
  plugin's `_precacheAlbum` **DELETES the `composer` field** before we ever see it. It also has no
  composer SEARCH endpoint. The only surviving lever is the album `artists[]` array with its `roles`,
  which is kept — whether it carries the composer is UNVERIFIED and needs a one-line debug build.
- **Wrong-artist and wrong-music are different questions, and the spine score cannot separate them.**
  Rossini adopted a modern rapper (fixed in 0.47.2). Shostakovich adopted **Maxim Shostakovich** (his
  son) on Qobuz and the **Shostakovich Quartet** on Deezer — but those ARE Shostakovich recordings,
  so "correcting" them could make the page worse. A composer's discography is not a list of his
  releases; it is a list of other people's recordings of his works.
- **Latin script is not guaranteed.** Shostakovich's MB canonical name is `Дмитрий Дмитриевич
  Шостакович`, so the canonical-name retry that fixed Rossini is a name no streaming service knows.
- **The library agrees with the services, not with us.** Simon's five Vivaldi albums are credited to
  Various Composers / Various Artists / Ensemble Explorations / Vienna Philharmonic / Capella
  Istropolitana. `albums artist_id:53262` = 5, `role_id:ARTIST,ALBUMARTIST,BAND,TRACKARTIST` = **0**,
  `role_id:COMPOSER` = **5**. So 0.19.0's performance-role filter (the Bob Dylan fix) hides all of
  them — working as designed, and the design is the problem.

### WHAT A CLASSICAL SOURCE WOULD HAVE TO GIVE US (verify before committing to one)
Open Opus (`openopus.org`) is the named candidate; the questions are the same for any alternative,
and NONE of this has been checked yet:
1. composer -> **WORKS** (not releases), with a stable id per work;
2. a way to get from a work to actual recordings, or at least to searchable performer/work strings;
3. licensing and rate limits acceptable for a plugin (the LBF/DSC fleet rule: no key the user must
   supply if avoidable);
4. coverage beyond the canon — the tail is where every music-metadata source falls over;
5. how to DETECT that an artist is a composer at all, cheaply, so the classical path is entered only
   when it applies (MB `type=Person` + disambiguation "composer" is a start; the local library's
   COMPOSER role is another).

### THE SHAPE THIS PROBABLY TAKES
A **works spine** rather than a release spine, for composers only: the page becomes works, each
resolving to available recordings — which is what a classical listener actually wants, and is close
to the "streaming spine" idea already recorded above (MusicBrainz as enricher, not gate). It is a
distinct rendering mode, not a tweak to the resolver.

### FIXES ALREADY SHIPPED THAT SHOULD SURVIVE ANY REWRITE
0.47.1 (zero-release artists are not answers — that was a general resolver bug found via
Shostakovich), 0.47.2 (one coincidental title is not corroboration), and both were verified on
non-classical controls. They are not classical-specific and are worth keeping.

### KNOWN, DIAGNOSED, NOT FIXED (parked with the above)
**The shared-name guard misfires on a short library spelling.** Browsing `Vivaldi` suppresses the
bio, the library albums AND similar artists, while `Antonio Vivaldi` shows all three — same mbid.
Cause: `getArtistCandidates('Vivaldi')` returns only artists named EXACTLY "Vivaldi" (a Hungarian
band, a '70s prog group); our resolved artist is not among them, so `_sharesDecision`'s "we ARE the
prominent act" escape misses and `lc($top->{name}) eq lc($name)` fires. The guard's premise is that
OUR artist shares the name — here it was reached by fuzzy match and carries a different canonical
name. **Fix shape (two coupled parts, ~an hour):** `_sharesDecision` returns 0 when the resolved
artist's canonical name folds differently from the browsed string, AND the name-keyed bio/similar
lookups use the canonical name — part one alone would let the Hungarian band's biography through.
The Madness control survives by construction (the rapper's canonical name IS "Madness"). **This one
is NOT classical-specific** — any artist whose library spelling is a bare surname other MB acts
carry exactly will hit it — so it is worth doing on its own merits when classical is unparked.

## PLANNED — LOCAL<->MUSICBRAINZ IDENTITY INDEX (Simon's proposal, MEASURED 2026-07-22, NOT built)

Simon: *"The plugin has its own scanner to scan a user's library ... and matches to MB from an
artist/album level. This would then disambiguate any local files... We then maintain our own DB of
matches and use these as points of entry to MB when pulling discographies rather than the search.
This is how Roon kind of works and how Plex matches as well."* **Agreed to build AFTER the current
search + matching cycle is finished.** Everything below was measured offline against the live
library and the mirror; nothing was written back to LMS or the plugin.

### THE IDEA, AND WHY IT BEATS BROWSE-TIME RESOLUTION

Today identity is decided per-browse from the artist NAME (`_artistMbidByName` -> MB search -> top
hit). The index decides it ONCE, offline, from the user's ALBUMS — which are far more unique than
artist names — and stores the answer as the entry point into MB.

The asymmetry is the whole argument: **offline, search depth is free**. An earlier proposal in the
same session (score candidates against the library AT BROWSE TIME) was measured and REJECTED because
reaching the right artist cost up to 13 extra MB round-trips (~14s on the public API) for ~3 albums.
Batch that same work and the cost disappears — and cases that were unreachable become trivial:

- `Jack` — the Welsh band is rank **32** on `artist:"Jack"` (mirror AND public agree; MB's *website*
  shows it at ~20 only because the site sends a BARE query, and a bare query makes the top hit
  "Captain Jack" — so switching query shape is a REGRESSION, not a fix). Unreachable by artist
  search. Resolves **first hit, one request** from `releasegroup:"Pioneer Soundtracks"`.
- `Roswell` — MB has FIVE artists literally named Roswell, none Simon's; his is an alias for
  **Roswell Road**. No name search can ever find it; the album finds it immediately.
- `Muzz` (six exact-name entities, MB scores the wrong one 100), `Rico` (exact-name preference beat
  a correctly-ranked #1) — same shape.

### MEASURED (2,910 albums, mirror, ~4 min; ~3,700 queries = ~60 min on the public API at 1 req/s)

115 Various-Artists albums skipped -> 2,795 eligible. Tiers escalate, each running only if the
previous missed:

| Tier | Query / rule | Cumulative |
|---|---|---|
| T1 | `releasegroup:"TITLE" AND artist:"ARTIST"` | 88.5% |
| T2 | edition decoration stripped | 92.2% |
| TA | **release-group ALIASES** (`alias:"TITLE"`) | 92.5% |
| T3 | album alone, artist agreed by name | 95.3% |
| T4 | **Lucene fuzzy per word** (Simon's spelling-error ask) | 96.5% |
| T5 | strip `Artist:` / `Surname:` prefix | +18 |
| T6 | strip disc / edition decoration (aggressive) | +15 |
| T7 | library **YEAR** breaks a self-titled tie | +4 |

**Final coverage 97.8%. Manual queue 61 albums (2.1%), of which 24 are classical — so ~37 real.**

T4 earns its place twice: it caught a deliberately planted typo (`Remain in Ligth` -> *Remain in
Light*) AND closed *Pet Shop Boys — Behavior -> Behaviour*, one of the 11 known matcher gaps.
T7 is cheap and settles what names cannot: *Placebo (1995)*, *Lamb (1996)*, *The Specials — In the
Studio (1984)*.

### THREE SAFETY RULES — ALL THREE ARE LOAD-BEARING, EACH PROVEN BY A COUNTEREXAMPLE

**1. NAME GATE (mandatory).** Require the MB artist's name to agree with the library artist's name
(token-subset either direction). Without it the index resolved 1,044 artists and DISAGREED with
today's resolution 13 times — of which **three were regressions**, because classical albums credit
the COMPOSER on the release group and the album vote drags the artist there:

```
Leonard Bernstein          -> Игорь Фёдорович Стравинский   WRONG (today is right)
Chicago Symphony Orchestra -> Пётр Ильич Чайковский         WRONG (today is right)
caroline (London band)     -> Caroline Lind                 WRONG (today is right)
```

The gate drops only 34 of 2,697 albums and leaves **7 disagreements, every one verified an
improvement** — including three orchestras that resolve to COMPOSERS today:

```
Jack     ff6e677f (Jack Johnson) -> c8fc9d07  Jack, Welsh band
Roswell  332cd868 (psytrance)    -> c1ac5a41  Roswell Road
Muzz     6cfdec30 (d'n'b MUZZ)   -> 893e0bd0  Muzz, NYC trio
Rico     93df7c51                -> 48910ede  Rico Rodriguez
Boston Symphony Orchestra  (was Gustav Holst)  -> 6ed6a493
London Symphony Orchestra  (was Edward Elgar)  -> 38712b4c
Royal Scottish National Orchestra               -> c6c4103b
```

**2. STRICT PLURALITY per artist, no ties.** A margin of >=2 is TOO strict (it covers only 565 of
1,044 artists — most artists own one or two albums). A strict plurality plus the name gate is the
right setting.

**3. STORE ARTIST IDENTITY ONLY — never album->release-group without EXACT title agreement.**
**179 of 2,697 (6.6%) got the artist right and the release group WRONG**: *The Man Machine* ->
*The Man-Machine Recreated*, *Sign 'O' the Times* -> *Sign o' the Times Live!*, *Drive [Original
Score]* -> *I Drive (Waveshaper remix)*. A stored RG mbid feeds `_mbidMatch`, which is Tier 0 and
trusted ABSOLUTELY — a wrong one would MANUFACTURE incorrect tiles, i.e. actively worse than today.
Safe subset for album-level storage: 2,518 (93.4%).

### ORDERING IS THE SAFETY MECHANISM, NOT THE REGEX

Simon asked for title parsing that still protects albums named after the band. The measurement gives
the definitive answer: **T5/T6 must run ONLY after the earlier tiers miss.** Applied
indiscriminately, the prefix strip would damage two WORKING matches —

```
Talking Heads  "Talking Heads: 77"            -> "77"
Stevie Wonder  "Wonder: Original Musiquarium" -> "Original Musiquarium"
```

— and ***Talking Heads: 77* is a genuine album title.** No pattern is clever enough to tell it from
`Bark Psychosis: Hex`; a pattern that tried would break something else. Because the tier only fires
on a miss, and *Talking Heads: 77* resolves at T1, the strip never gets the chance. Verified
alongside: **142 self-titled albums in the library, NONE altered** (no separator to match) and **0
titles stripped to empty** (the rule requires a surviving remainder).

### DESIGN CONSTRAINTS TO SETTLE BEFORE CODE

- **It must NOT live in the version-scoped Cache namespace.** We deliberately wipe that on every dev
  build (see the dev-builds-clear-caches discipline). A 60-minute scan behind a store that a version
  bump destroys is a trap we have already built for ourselves once. It needs its own persistent
  store, explicitly exempt.
- **VERIFY the key before committing to it.** `persist.db` survives rescans but is keyed on track
  URL, while `album_id` is an auto-increment row in `library.db` — a CLEAR-and-rescan very likely
  reassigns it, orphaning the index exactly when a user does what support articles tell them to.
  Safer: key on normalised artist+album (or first track URL), keep `album_id` as a fast-path hint.
- **Record provenance + confidence per row** (tag / album-query / fuzzy / user override) so a later
  pass can re-resolve the weak ones WITHOUT touching user corrections. A stored wrong match is
  stickier than a computed one: today a bad resolution silently improves as MB improves.
- **Correction UI + unmatched list**, as Simon scoped. 61 rows is a realistic queue.
- The MB-tag fast path ALREADY EXISTS and needs nothing new: `Sources.pm` reads
  `Slim::Schema::Album->musicbrainz_id` (:316) and resolves a Contributor by `musicbrainz_id` (:362).
  Simon's library is not Picard-tagged, so Tier 0 currently has nothing to feed it — the index IS
  that missing feed.

### WHAT IT DOES **NOT** FIX

Classical stays parked. The index rescues ORCHESTRA identity (3 above) but not the
composer/performer split, which is upstream of identity — see the PARKED classical section. 24 of
the 61 unresolved are classical.

### KNOWN CHEAP GAINS LEFT ON THE TABLE (~4-5 more albums)

- **Normalise hyphens in the prefix compare.** *Gil Scott‐Heron* carries U+2010 while the title says
  `Scott-Heron:`, so they don't match. Same root cause as `The B‐52s` and the Kraftwerk titles.
- **Chain T5 -> T6.** *Mayfield: Superfly: The Original Motion Picture Soundtrack* needs the prefix
  strip AND the decoration strip; neither alone is enough.

### SIMON'S OWN TAGGING, SURFACED BY THE MEASUREMENT (fixable in tags OR in the scanner)

21 albums carry an artist/surname prefix (*Springsteen:*, *Reed:*, *Drake:*, *Amos:*, *Hersh:*,
*Hopkins:*, *Earle:*, *Weeks:*, *MacColl:*, *Saint Vincent:* under a `St.`<->`Saint` fold); 21 carry
leftover bracketed editions; 5 carry unicode punctuation (`The B‐52s` is U+2010, not a hyphen).

## PLANNED — streaming-spine fallback for artists absent from MusicBrainz (scoped 2026-07-17, NOT built)

Some real artists aren't in MB at all; today they dead-end at "Couldn't identify this artist"
(+ Retry). Agreed scope with Simon (build later, after the search feature settles):

- **Trigger**: only on a DEFINITIVE resolution miss (the cached `''` sentinel path after the
  0.32.0 alias stage) — never on transient MB/HTTP errors. The Retry-MB row stays at the top of
  the fallback view so a transient miss can still heal into the real MB spine.
- **Spine = the candidate pool itself.** `getCandidates` AWAITED (not just warmed) — each
  service's artist-first album list already carries `_year`, art, play urls. Dedupe across
  services by `_norm(title)` buckets → one tile per album, per-service versions beneath (same
  view shape as now, streaming-sourced). Local albums merge via the existing title matcher
  (`matchesFor` without rg/relMap/rivals — Tier 2 is title-based).
- **Sections**: first cut = ONE flat list sorted by year. Service type data is patchy (Deezer
  `record_type`, Tidal only via its fetch buckets which we merge UNTAGGED — tagging them is a
  candidate shape change = `CAND_CACHE_V` bump; Qobuz unreliable). Typed sections are a later
  refinement.
- **The real cost is navigation keying**: the 0.34/0.35 param-addressed nav (`rg:` uuid params,
  `playcmd`, ctx, detail-row ids) is rg-mbid-keyed throughout. The fallback needs a parallel
  synthetic key (e.g. `st:<norm-title>` — validate charset for param transport), a detail view
  without the MB rows (no CAA, no MB weblink, no review-by-rg cache key — keep Qobuz `_desc`),
  and no bands section (MB-keyed); MAI bio + similar artists can stay (name-keyed).
- Estimate: multi-day. Search (0.37.0) was ~a day; this is distinctly bigger.

## PLANNED — MusicBrainz access performance (MEASURED 2026-07-21, NOT built)

Simon: *"it's feeling sluggish."* Measured before proposing anything, live against the box
(LMS `plex:9000`, mirror `plex:5000`) with `debug_log` on. **Priority order agreed: public API
first** — a mirror user's cold path is seconds, a public-API user's is tens of seconds.

**THE MATCHER IS NOT THE PROBLEM. Warm renders are already fast** — Radiohead (582 release
groups) **0.22s**, Jamie Cullum **0.05s**, repeatable. 0.29.0's first-token index is doing its
job and the ~600 `matchesFor` calls cost ~30ms. Do not go looking there again.

**The cost is entirely the COLD path.** Jamie Cullum, first visit, **2.32s** on the mirror,
from the log timeline:

| stage | cost | notes |
|---|---|---|
| RG spine (1 page) | 80ms | |
| targeted local release→RG lookups (2) | 150ms | |
| `warmBandMembers` | 240ms | |
| **`_warmArtistExtras` (MAI → Last.fm)** | **1,130ms** | **49% of the render, and NOT a MusicBrainz call** |
| `warmOfficial` (2 pages) | 715ms | |
| streaming pool resolution | ~1.7s | parallel, awaited (`hide_unmatched` + cold pool) |

Radiohead with MB caches warm but a cold pool: 1.30s, essentially all of it the awaited
streaming resolution.

### Findings, in the order they should be fixed

1. **`autodetectMirror` CAN NEVER SUCCEED — the probe MBID is not a real MBID.**
   `MB_PROBE_MBID` = `a74b1b7f-06a0-4672-a641-eb3353aa608d` **404s on the mirror AND on
   musicbrainz.org** (verified both). Radiohead is `a74b1b7f-71a5-4011-9441-d0b5e4122711` —
   confirmed by the library tag in the same log (`artist mbid from library tag:
   a74b1b7f-71a5-…`). So every install with a blank `mb_base_url` and a same-host mirror runs
   the WHOLE plugin against the public API at 1 req/s, and re-probes daily forever. This is
   very likely the biggest field cause of "sluggish", and it is a one-constant fix. **Fix the
   constant and add a live probe assertion**, or the next typo is invisible the same way.
   (0.30.0/0.30.1 already record that this feature shipped twice without ever firing.)
2. **A 1.1s NON-MusicBrainz call sits inside the serial MB chain.** The chain
   `warmLocalReleases → warmBandMembers → _warmArtistExtras → warmOfficial` is serial to
   respect MB's 1 req/s etiquette — but `_warmArtistExtras` is MAI/Last.fm, so it is paying an
   etiquette tax it does not owe, and it gated 49% of the cold render. Run it in PARALLEL with
   the MB chain under its own `$render` flag (exactly how the bio already works — and note the
   0.7.0 compose-order trap: assign `$render` before the fetch). It stays AWAITED (0.31.0's
   first-render decision holds); it just stops queueing behind MusicBrainz.
3. **`warmLocalReleases` fires its requests back-to-back with NO gap.** The header comment says
   "serially (1.1s gap)" and the code has no timer — `$done` calls `$next` directly. Invisible
   on a mirror (and correct there), but on the public API N owned albums = N unspaced requests
   → 503s; failures are deliberately not cached, so it repeats on EVERY visit. Fix: route
   through `mbGap` like every other loop (0 on a mirror), and CAP the per-visit batch so a user
   who owns 30 albums by one artist does not add 33s to the chain — the rest resolve next visit,
   which is the plugin's established second-load contract.
4. **`getArtistCandidates` is fetched TWICE per cold artist.** `$warm` and
   `sharesNameWithProminentAsync` both call it before either caches. Proven, not inferred: the
   sub only logs inside its HTTP callback, and the line appears twice ~4ms apart (Radiohead
   10.6165/10.6183; Cullum 00.4670/00.4715). Add an in-flight dedupe keyed by name (the pattern
   `warmOfficial`/`warmBandMembers`/`warmLocalReleases` already use). Saves one MB request per
   cold artist — 1.1s on the public API.
5. **`warmOfficial` is the dominant MB cost AND it gates the first render.** Radiohead 1140
   releases = 12 pages; The Beatles 3258 = 33 pages. On the public API that is 13s / 36s at
   1.1s spacing, so the 15s `official_wait` deadline ALWAYS fires for a big artist: the user
   waits 15 seconds **and still gets the bootlegs**, while the pass keeps hammering MB for
   another 20s. Two levers:
   - **`release?artist=X&status=official` IS accepted** (verified on mirror and public — unlike
     the release-group browse, see the dead ends below). Radiohead 1140→492 (12→**5** pages,
     −58%); Beatles 3258→2207 (33→**23**, −32%) — bootleg-heavy artists win big, reissue-heavy
     ones less. The semantics inverse cleanly: a group present in the official-only browse has
     an official release (SHOW); a spine group absent from it is bootleg-only (HIDE).
     **COST, measured, not assumed:** groups whose releases are ALL status-less currently
     fail-open to shown and would flip to hidden — **5 of Radiohead's 582** (101 have an
     official release, 476 are bootleg-only). Mitigation that is right anyway: **never hide a
     release group the user owns locally.** Also note `warmLocalReleases` already covers the
     release→RG map for owned albums, so losing non-official releases from `peekReleaseMap`
     costs nothing that matters.
   - **`official_wait` should default to 0 when throttled.** Waiting 15s to still show bootlegs
     is the worst of both outcomes; on a mirror the pass finishes inside the wait anyway.
6. **Version-scoped pool keys make EVERY artist cold after EVERY install** (0.44.3,
   `dsc:cand:4:<version>:…`). With `hide_unmatched` on that is the 1.2–2s awaited streaming
   resolution per artist, per build — which is precisely why the plugin feels slowest during a
   dev cycle. The diagnosis value is real; consider gating the version component on `debug_log`
   so field installs keep their pools across an update.
7. **Debug logging is not free.** `debug_log` was ON on the server during this measurement, and
   Radiohead writes ~600 `match` lines plus the long "dropped N album(s)" lines per render.
   `Plugin::dbg` only picks the LEVEL — every message string is built at the call site whether
   or not the pref is on. Turn it off after diagnosis (fleet habit), and consider guarding the
   per-RG match line behind the pref.

### Dead ends — verified 2026-07-21, do NOT re-derive
- `release-group?artist=X&status=official` → *"status is not a valid parameter unless releases
  are requested"* (mirror AND public). The spine cannot carry officialness.
- `release-group?artist=X&inc=releases[&status=official]` → *"releases is not a valid inc
  parameter for the release-group resource"*. So the separate release browse is the only route.
- MB's page limit is 100; there is no way to slim a ws/2 payload, so pages are the only lever.

### Public-API request budget per COLD artist (the number to optimise)
RG spine (1–6) + artist candidates (**2 today**, 1 after fix #4) + aliases (1 if ambiguous) +
local releases (1 per owned album) + band members (1) + officialness (2–33). Jamie Cullum ≈ 9
requests ≈ 10s; Radiohead ≈ 21 ≈ 23s. Fixes #2/#4/#5 take Radiohead to roughly 13 requests with
the 1.1s Last.fm leg off the chain entirely. The parked LMS-community hosted API (see the fleet
memory note) is the structural answer beyond that — it is un-throttled — but it is blocked on
the dev adding type/secondaryTypes/date to `/discography`.

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

**DSC-ONLY, NOT part of the shared engine (do NOT port; does NOT trip the sync check):**
- **Local-candidate gate substitution (0.24.0).** `matchesFor` + `claimedLocalIds` gate a
  `$a->{local}` candidate on the BROWSED artist instead of its `_candArtist`, because DSC's
  `localAlbums` join already proves the artist performs on the album (co-credit / band-fronted
  owned albums whose collapsed ALBUMARTIST is a different act). This is a change to the DSC CALL
  SITES, not to `_albumMatches`/`_artistMatch` (those stay byte-identical, so `matcher_sync_check.py`
  still exits 0). LBF/PFR/LL have no Local pseudo-source and no such join guarantee — the shared
  subs' mandatory artist gate is correct there. Sibling of LBF's release-type filter, which is
  likewise deliberately LBF-only and outside the shared engine.

## Development Log
### 0.50.5 (2026-07-23) — a short NON-ASCII token is a whole word, not a stopword (the hieroglyph/zalgo album)
- **Simon: a 2026 album with a hieroglyph/zalgo title resolves to DEEZER, not his local copy — "it works
  searching via lms own search and finds my local instance ... The plugin finds it in Deezer not my local
  copy", while browsing the LMS Artists row works fine.** Diagnosed LIVE over HTTP (jsonrpc against
  `plex:9000`), and it is a Local-resolution miss, nothing to do with the album matcher:
  - The library holds album **29030** under artist **88810**, whose name is
    `⣎⡇ꉺლ༽இ•̛)ྀ◞ ༎ຶ ༽ৣৢ؞ৢ؞ؖ ꉺლ` (braille + Yi + Georgian + combining marks).
  - `artists search:<full name>` returns **0** in LMS ITSELF (even with no role filter) — the whole string
    is unmatchable. But `artists search:ꉺლ` (the 2-char Yi+Georgian token, U+A27A U+10DA) returns **88810**.
    So LMS can find the artist, but only by that one short token.
  - `_localArtistRows`' ladder: the exact spelling misses; the ASCII fold strips every non-ASCII char to
    nearly nothing and misses; the **term probe** is the only route left — and it drops any token under
    `PUNCT_PROBE_MIN_LEN` (4), a floor meant to skip ASCII stopwords ("the"/"of"). `ꉺლ` is 2 chars, so it was
    never tried → `_localArtistRows` returned `[]`.
  - Consequence: the search Local leg found nothing (row got no Local source), AND `localAlbums`' name
    fallback found nothing on drill-in — so the album resolved to Deezer. The Artists ROW works because it
    passes `artist_id:88810` directly, bypassing name resolution entirely (`getArtistMbid` reads the library
    tag first).
- **FIX (one line): the length floor is lifted for NON-ASCII tokens** — `grep { length >= PUNCT_PROBE_MIN_LEN
  || /[^\x00-\x7f]/ }`. A short non-ASCII token is a whole word in a dense script (CJK/Yi/Georgian/Tamil…),
  never a stopword, and is often the only handle LMS indexes for a name it can't match whole. This fixes BOTH
  entry paths that go through `_localArtistRows` (the search Local leg and `localAlbums`' name fallback), so
  the row gains its Local source and the drill-in — carrying `artist_id:88810` — resolves via the reliable
  library-tag path, identical to the Artists row. Also helps short CJK/Korean/etc. artist names generally,
  where the same floor silently excluded them from the probe. **`$` short ASCII tokens still skipped** (the
  floor is only lifted for non-ASCII), so "the"/"of" are unaffected — a control asserts it.
- **NOT a matcher change.** `_localArtistRows` is DSC-only call-site logic (sibling of 0.24.0);
  `matcher_sync_check.py` reports only the deliberate 0.44.26 `_norm`/`%FOLD` drift, and `_albumMatches`/
  `_artistMatch` stay IN SYNC. No candidate-shape change; CACHE_VERSION 0.50.5 clears the namespace regardless.
- **`tools/t_local.pl` 18 → 22**, fixtures = the field artist's real token (octets per the shape convention):
  the 2-char non-ASCII token is probed and locates the artist, it was tried AFTER the exact spelling, and a
  short ASCII token is STILL not admitted (the change is surgical). **Verified RED** against the pre-fix floor
  (the primary assertion fails) and 22/22 after.
- **PROCESS NOTE (self-inflicted, recorded so it isn't repeated): a scripted `perl -0pi` patch corrupted
  Sources.pm** — a `$_` in the replacement string interpolated the whole file into itself — and a reflexive
  `git checkout -- Sources.pm` then reverted the file to the last COMMIT (v0.44.25), discarding all the
  uncommitted 0.44.26→0.50.4 work on disk. Recovered the intact 0.50.4 `Sources.pm` from `Discography.zip`
  (the build artifact) and re-applied the fix with the Edit tool. **Two rules, both already in this repo's
  history and both ignored here: never script-patch a .pm (use the Edit tool — 0.44.6/0.48.6), and NEVER
  `git checkout` an uncommitted working file.**
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION 0.50.5 == install.xml + PROBE_MBID OK; **all 25 suites green**.
- **LIVE VERIFY AFTER INSTALL:** search the hieroglyph artist/album — the row must now carry **Local** and the
  album must show/play the owned copy (album 29030) rather than resolving to Deezer only; the log should read
  `Local lookup '<name>': matched 1 via term probe 'ꉺლ'`. Control: an ordinary artist unchanged.

### 0.50.4 (2026-07-23) — same-name act artwork: use LMS's OWN artist icon (0.50.3 used the album COVER — wrong)
- **Simon, on 0.50.3: *"totally wrong, you've used cover art not artist art."*** He was right. 0.50.3
  substituted the act's album COVER for the thumbnail; he wants the ARTIST art (the folder artist-image
  MAI ingests on rescan), and worse, 0.50.3 REPLACED the correct MAI artist-art on the acts that HAD
  it. Two mistakes in one.
- **DIAGNOSED PROPERLY THIS TIME (live HTTP, byte-compared):** `imageproxy/mai/artist/<id>` is
  byte-IDENTICAL to what LMS's own artist menu shows (`contributor/<hash>/image`) for the two Bees that
  have folder art (88656 -> 40622B, 83895 -> 73342B, same md5s) — so MAI is CORRECT there. It only goes
  wrong for the third act (86742, *Pushin' Too Hard*), which has **no artist art in LMS at all** (menu
  icon = None): there MAI INVENTS an online photo of the prominent UK band. So the real defect is
  narrow — MAI's online fallback for an art-less same-name act — and 0.50.3 broke the good cases.
- **FIX — `Sources::_artistMenuIcons($name)`** does ONE `browselibrary mode:artists` query (empty
  client, like every CLI query here) and returns each same-name artist's LMS icon: a
  `contributor/<hash>/image` URL when LMS holds art, `''` when it knows the act but has none.
  `splitOwnedByIdentity` stamps each split row with `_img` (LMS's icon) when present, or `_noart` when
  LMS has none; `_searchResultRow` uses `_img`, else a neutral person icon for `_noart`, else the MAI
  proxy as before. So each act shows EXACTLY what LMS shows — correct folder art for the two that have
  it, a neutral icon for the art-less one instead of MAI's wrong online guess.
- **Add folder artist-art + rescan and the third act fills in automatically** — the fix defers to LMS's
  own resolution, which is the mechanism Simon described.
- **`tools/t_bees.pl` (22):** the two acts with art get their OWN LMS icon; the art-less act gets the
  neutral icon (NOT MAI) — the stub gives two contributors a menu icon and one none.
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION 0.50.4 == install.xml + PROBE_MBID OK; all 25 suites
  green. No matcher sub touched.
- **LIVE VERIFY AFTER INSTALL:** search **The Bees** -> the two acts with folder art show their own
  correct artist images (matching LMS's artist list), the *Pushin' Too Hard* act shows a neutral icon
  rather than the UK band. Control: Radiohead unchanged (MAI photo).

### 0.50.3 (2026-07-23, SUPERSEDED by 0.50.4) — a same-name owned act gets its OWN artwork, not MAI's photo of the prominent one
- **WRONG APPROACH, replaced within the hour.** Used the act's album COVER as the thumbnail; Simon
  wanted ARTIST art, and this also clobbered the correct MAI artist-art on acts that already had it.
  See 0.50.4 for the diagnosis and the fix. Original note follows for the record.
- **Simon, on the split "The Bees": *"the artwork for the one from the bootleg is showing from the UK
  band; I search LMS it uses the artwork I have for the correct band"*, then the key: *"when you have
  artwork saved in with the album, LMS/MAI picks this up when you do a full rescan ... if it's inside
  the folder structure."*** So the artwork he has is FOLDER ART on the album, and MAI ingests it.
- **DIAGNOSED LIVE (HTTP image fetches + LMS's own artist menu):**
  - `_artistImg` uses `imageproxy/mai/artist/<id>/image.png`, but MAI resolves that by NAME/online, so
    it hands each same-name "The Bees" a different ONLINE photo — the prominent UK band, or a
    silhouette — never the user's local art. Measured: the three ids returned 40 KB / 73 KB / 585 KB
    online images.
  - `contributor/<numeric-id>/image` is a red herring: it returned the SAME 21,953-byte silhouette for
    all three Bees AND for Radiohead — LMS's default placeholder, not per-artist art.
  - LMS's OWN artist menu (`browselibrary mode:artists`) draws each Bees from a DIFFERENT
    `contributor/<hash>/image` — and that hash is an ALBUM COVERID. So LMS represents the artist by one
    of their album covers, i.e. the local folder art. Confirmed each act owns a real, distinct cover:
    88656 -> Nuggets, 83895 -> Every Step's a Yes (UK), 86742 -> Pushin' Too Hard.
- **FIX — `Sources::_artistCover($id)`** returns one of the act's OWN album covers (`/music/<coverid>/
  cover`, PERFORMANCE-role, the local folder art), and `splitOwnedByIdentity` stamps each split row's
  `_img` with it. `_searchResultRow` prefers `$hit->{_img}` over `_artistImg`. So each same-name owned
  act shows its own distinct, correct, LOCAL thumbnail instead of MAI's online photo of whichever act
  is most prominent.
- **SCOPED to split rows only.** A normal (unique-name) owned artist keeps the MAI artist photo
  (0.48.3) — nicer than an album cover for a well-known act, and MAI resolves it correctly when the
  name is unambiguous. The album-cover substitution is exactly for the same-name case MAI cannot tell
  apart — the same problem 0.43.1 met with the person icon, now improved to real per-act art. Cost is
  one `albums` query per split identity, only when an act actually splits.
- **`tools/t_bees.pl` (now 21 assertions):** the three split rows each carry their OWN album-cover
  `_img` (distinct coverids), not one shared photo — the stub returns a different artwork_track_id per
  contributor so a regression to a shared image fails the assertion.
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION 0.50.3 == install.xml + PROBE_MBID OK; all 25 suites
  green. No matcher sub touched.
- **LIVE VERIFY AFTER INSTALL:** search **The Bees** -> the three rows show three DIFFERENT covers
  (Nuggets / Every Step's a Yes / Pushin' Too Hard), matching what LMS's own artist list shows, instead
  of all three wearing the UK band's photo. Control: a unique-name owned artist (Radiohead) still shows
  its MAI band photo.

### 0.50.2 (2026-07-23) — track-linking: a release owned only as a COMPILATION TRACK becomes playable
- **Simon, on the garage "The Bees" single: *"can it not link to the version in the compilation, it's
  odd having it orphaned like that and you can't play the track directly at all."*** Right — the
  spine single *"Voices Green and Purple / Trip to New Orleans"* rendered as an unplayable orphan
  while the track he owns (on the *Nuggets* comp) sat separately under Appearances. The plugin matched
  the spine at ALBUM granularity only; a track owned on a VA compilation attached to nothing. This is
  the track-level matching CLAUDE.md 0.28.0 explicitly deferred.
- **FIX — `Sources::localTracks` + `_trackLinksRelease` + a track-link pass in `matchesFor`.** For a
  release that matched NOTHING else (an orphaned, otherwise-unplayable spine release), an owned track
  whose title links to the release title adds a **Local section that plays the track directly**
  (`db:track.id`). Title matching is **A/B-side aware in both directions** (a 45 is titled "A / B"
  while the comp holds "A"; splits on a SPACED " / " so "AC/DC" stays whole), with a >=4-char guard;
  the real safety is that only THIS artist's own tracks are ever considered (id-keyed, so a match is
  always this artist's song). **Runs ONLY on an unmatched release** — a streaming/album match is never
  overridden.
- **The compilation stays under Appearances** (Simon's call): track-linking claims a TRACK, not the
  comp ALBUM, so *Nuggets* remains an orphan album -> Appearances, and its track ALSO becomes the
  playable source for the spine single. The track shows in both places, deliberately.
- **LAZY, so it costs nothing for an artist owned as albums.** `localTracks` is threaded as a
  memoised coderef (`$opt->{localTracks}`); `matchesFor` calls it only when it reaches an unmatched
  release, so a fully-matched artist (Radiohead) never runs the extra `titles` query. Same shared-name
  suppression as `$local` (id-keyed is exact; only a name-resolved shared-name entry is suppressed).
  Both call sites wired — `_buildList` (tiles) and `_releaseDetail` (drill-in), so they agree. The
  detail row shows `Local \x{b7} from <comp>`.
- **Also fixes "shows but isn't playable":** the orphaned spine single now carries a Local section, so
  it renders as a playable tile (and survives `hide_unmatched`). The bootleg-only Bee (77854) is
  unaffected — its spine RGs are bootleg-hidden, so there is no visible tile to attach to; its comp
  stays reachable via Appearances (0.50.1).
- **`tools/t_tracklink.pl` (new, 22 assertions):** `_trackLinksRelease` (exact, both A/B directions,
  the unrelated-title and short-title guards, inline-slash not split) driven directly; the `matchesFor`
  pass through the REAL sub (orphan gains one Local track section playing `db:track.id`; a
  streaming-matched release gets NO bolt-on; no-link stays unmatched; the lazy pool fetched ONLY for an
  unmatched release; MAX_PER_SVC cap); and `localTracks`' fetch shape (db:track.id play, `_track` flag,
  comp name, artwork, one id-keyed query).
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION 0.50.2 == install.xml + PROBE_MBID OK; **all 25 suites
  green**. No matcher sub touched — `_trackLinksRelease`/`localTracks`/the `matchesFor` pass are
  DSC-only call-site logic (sibling of 0.24.0); `matcher_sync_check.py` reports only the deliberate
  0.44.26 `_norm`/`%FOLD` drift.
- **LIVE VERIFY AFTER INSTALL:** search **The Bees** -> the garage act's single *"Voices Green and
  Purple…"* must now be **playable** (plays the Nuggets track; drill shows `Local \x{b7} from Nuggets…`),
  and *Nuggets* still appears under Appearances. Control: **Radiohead** unchanged and runs NO extra
  `titles` query (every release matches, so the lazy pool is never fetched).

### 0.50.1 (2026-07-23) — the same-name guard was suppressing ID-KEYED owned albums (0.50.0's Bees still empty)
- **Simon, installing 0.50.0: the split works (three "The Bees" rows) but two of them are wrong — one
  reads "No releases found" and should show the compilation track he owns, the other "shows but isn't
  playable".** Diagnosed LIVE over HTTP (debug_log on, jsonrpc drills + log.txt):
  - **77854** (bootleg-only spine, dd11eecd) -> `count: 1` "No releases found";
  - **79768** (garage, 0790a093) -> the MB single "Voices Green and Purple" with NO source (unplayable);
  - **75007** (UK, 276cfa71) -> full 47-item page, fine.
  Both broken acts are owned ONLY as a **track on a VA compilation** (77854 -> *Pushin' Too Hard*
  25851; 79768 -> *Nuggets* 26105) — Simon's own read: *"as the acts don't own the albums and they
  are from compilations ... they should show up as appearances."* Right on both counts.
- **THE ALBUM WAS THERE — the guard threw it away.** Measured: `albums artist_id:77854 role_id:
  PERFORMANCE_ROLES` returns the comp (The Bees is TRACKARTIST on it). The log named the culprit:
  `'The Bees' shares its name with a more prominent act - suppressing name-keyed library/bio/similar`
  -> `$local = []`. The 0.43.4 suppression exists because `localAlbums` COULD be name-keyed and drag
  the prominent act's catalogue onto a secondary act — but **its comment's premise is false whenever
  an `artist_id` is present**: `localAlbums($artist_id, ...)` is ID-keyed (Sources.pm:380), exact to
  THAT contributor, so it cannot return the wrong act. Only the NAME fallback (no artist_id) is the
  case 0.43.4 guards. Every search-drilled secondary act carries a real contributor id, so the guard
  was zeroing a lookup that was already safe — and with `$local` empty, 0.50.0's Gap B fall-through
  never fired and the page short-circuited to "No releases found".
- **FIX (one condition): suppress `$local` only when there is NO artist_id** —
  `($opts->{shared_name} && !$opts->{artist_id}) ? [] : localAlbums(...)`. The bio and
  similar-artists sections stay suppressed via `$opts->{shared_name}` (those ARE name-keyed —
  MAI/Last.fm — and would show the prominent act). Now 77854 falls through to **Appearances:
  *Pushin' Too Hard*** (playable `db:album.id`), and 79768 shows its MB single AND **Appearances:
  *Nuggets***. Helps every same-name act entered by id, not just the Bees.
- **DEPENDS on `show_library_extras`** (default on): the Appearances section is gated on it, so if it
  is off the owned comp still will not render. Left as-is — it is the correct pref for this section.
- **The bare unplayable MB single on 79768 is separate and expected:** it is a real spine release the
  user does not own as a single (only as a comp track), shown because the streaming pool is empty and
  the `!resolved` exemption keeps it visible; `hide_unmatched` is the lever for that, not this fix.
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION 0.50.1 == install.xml + PROBE_MBID OK; all 24 suites
  green (t_bees unchanged — this is a `_discographyView` call-site condition, exercised live). No
  matcher sub touched.
- **LIVE VERIFY AFTER INSTALL:** search **The Bees** -> the bootleg-only act must show **Appearances:
  Pushin' Too Hard** (playable) instead of "No releases found", and the garage act must show
  **Appearances: Nuggets** (playable) beneath its single. Control: the UK band unchanged.

### 0.50.0 (2026-07-23) — search shows every owned same-name act; an owned empty-spine act isn't "No releases found"
- **Simon owns THREE distinct acts called "The Bees"** (UK band, US garage band, a third with a
  bootleg-only spine) as three separate library contributors, each with its own MB tag. LMS's own
  library search lists all three; search listed ONE and it drilled into the wrong band. His rule,
  verbatim: **"it should fold them if the same artist but if legitimate different acts it should not."**
- **CAUSE.** `mergeArtistHits` buckets by `_norm(name)` and keeps only the FIRST same-name contributor
  id (Sources.pm:1348), so distinct owned acts collapsed into one row and the other two were
  unreachable. The discriminator for fold-vs-separate is the **MusicBrainz tag**: same tag = one act,
  different tags = different acts.
- **FIX 1 — `Sources::splitOwnedByIdentity` (new), a DB-aware post-merge pass** wired into
  `Browse::_withMbCandidates` AFTER `attachLibraryArtists`, BEFORE `rankArtistHits`. For each OWNED row
  it re-derives the discarded same-name contributors (`_localArtistRows`, the ids the pure merge threw
  away), groups them by identity (`_contribMbid` = the `Contributor->musicbrainz_id` read
  getArtistMbid trusts first; untagged = keyed by contributor id so two untagged same-name
  contributors are NOT blind-folded), and:
  - one identity -> the row is left intact, only **stamped with `_ident_mbid`**;
  - several identities -> **one Local row per act**, deterministic order by contributor id
    (item_id-walk stable), each carrying its own `artist_id` so it drills into the RIGHT band by tag.
- **WHY IT'S A SEPARATE PASS, not in the merge:** `mergeArtistHits` is PURE (no DB) — that is what
  lets t_fold/t_fuzzy/t_rank/t_joint run headless and what its 10-minute cache stores. Identity needs
  the library, so it lives in the DB-aware layer, run on the CACHED path too (like the attach), judged
  against the library as it is NOW. The cache holds the pre-split rows, same shape as before — **no
  `dsc:asearch` shape bump** (CACHE_VERSION 0.50.0 clears the namespace regardless).
- **STREAMING SOURCES DELIBERATELY NOT ATTRIBUTED.** A service "The Bees" carries no MBID, so knowing
  which owned act it belongs to means the per-row spine scoring the search path refuses to pay
  (0.44.7 / 0.46.6). Each split row shows **Local only**; the correct streaming catalogue is recovered
  on DRILL-IN, where `_resolveArtist` scores it against that identity's spine. The single-identity
  common case keeps every streaming source untouched. **The planned library identity index is what
  makes attributing them cheap+safe later** (verified mbid instead of the tag-read, plus offline-warmed
  per-identity pools) — recorded with Simon as the supersede path; nothing built here is wasted.
- **FIX 2 — "Other artists with this name" is now UNOWNED-only.** `_withMbCandidates` drops any MB
  candidate whose mbid is in the owned set (`%ownedMbid` from the rows' `_ident_mbid`) — exact, not the
  old name heuristic — so Simon's three Bees are owned rows and none reappears in the section. The
  0.43.2 prominent-act `$covered`/shift is TIGHTENED to fire only for an UNOWNED merged row: an owned
  row drills by artist_id to its own (already-excluded) identity, so counting it would wrongly drop a
  legitimate unowned act.
- **FIX 3 (Gap B) — an act you OWN is never "No releases found".** The bootleg-only Bee (dd11eecd, two
  release groups, both bootleg) rendered an empty spine and short-circuited to NO_RESULTS, hiding the
  comp Simon owns. `_buildList`'s early return now also falls through when `@$local` is non-empty —
  rendering bio / "Also in your library" / "Appearances" / band links — reusing the exact fall-through
  0.49.0 added for local_only. The `markArtistEmpty` guard already required `!@$local`, so this changes
  only what is RENDERED, never what is remembered. Helps the browse path too.
- **`tools/t_bees.pl` (new, 20 assertions)** driven through the REAL `splitOwnedByIdentity` with a
  stubbed LMS (contributor->mbid + album counts): the three-way split with distinct ids/mbids and
  Local-only sources; **same-tag contributors FOLD** (one row, streaming kept); **untagged same-name
  contributors stay separate** (can't prove one act); the normal single-identity artist untouched but
  stamped; non-owned rows never probed; no input mutation; bounded probe cost. The tagged-fold +
  untagged-separate pair is what proves the identity discriminator is actually read.
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION 0.50.0 == install.xml + PROBE_MBID OK; **all 24 suites
  green**. No matcher sub touched — `splitOwnedByIdentity`/`_contribMbid` are DSC-only call-site logic
  (sibling of 0.24.0 / 0.44.24); `matcher_sync_check.py` reports only the deliberate 0.44.26
  `_norm`/`%FOLD` drift.
- **LIVE VERIFY AFTER INSTALL:** search **The Bees** — expect THREE "The Bees" rows (each Local), each
  opening its OWN discography (the UK band, the garage band, and the bootleg-only one now showing its
  owned material instead of "No releases found"); "Other artists with this name" must NOT repeat any
  of the three. Controls: **Radiohead** unchanged (one row, all sources); an artist you own nothing by
  unchanged.

### 0.49.2 (2026-07-23) — the search re-queries services in a spelling they MATCH (The La's / Qobuz)
- **Simon, after 0.49.1: "still exactly the same when searching The Las, no Qobuz."** The 0.49.1
  resolver fix was correct but only HALF the chain. Diagnosed LIVE end to end over HTTP (debug_log on,
  jsonrpc searches, `log.txt` reads):
  - `held, trying alias` fired and resolved "The Las" -> **The La's** (ff3e88b3) — 0.49.1 works.
  - MB's canonical name is **"The La’s" with a CURLY apostrophe** (U+2019).
  - **Qobuz's artist search returns the band only for the STRAIGHT apostrophe** — measured on the box:
    `Qobuz/'The La's'` -> "The La's" (#1), `Qobuz/'The La’s'` (curly) -> 15 rows of unrelated junk.
  - The 0.45.2 second pass (re-search services under the canonical name) **never ran**: its guard was
    `_norm($canon) eq _norm($q)`, and `_norm` folds EVERY apostrophe to nothing (verified:
    `_norm("The Las") = _norm("The La's") = _norm("The La’s") = "the las"`), so the guard concluded
    "canonical == typed" and skipped. **The guard used the matcher's fold to decide something the
    SERVICES care about — exact punctuation.**
- **FIX (two coupled parts):**
  - `_svcQueryName` — folds typographic marks to ASCII (curly/prime quotes -> `'`/`"`, en/em/figure
    dashes + minus -> `-`, ellipsis, nbsp) and keeps letters, spacing and CASE. The services get
    searched under this, so Qobuz is queried as "The La's" (straight) and returns the band.
  - the second-pass gate becomes `lc(_svcQueryName($canon)) ne lc($q)` — a comparison that PRESERVES
    the punctuation `_norm` throws away. It is **strictly WIDER than the old `_norm` gate** (`_norm`
    folds more, so `_norm`-equal implies `_svcQueryName`-equal), so it can only ADD second passes,
    never drop one that worked (British Sea Power -> Sea Power still re-searches; Radiohead still
    doesn't). Asserted as an invariant in the test.
- **Why searching under the curly canonical wasn't enough** (an earlier instinct, killed by the live
  measurement): Qobuz needs the STRAIGHT form, so the fold to ASCII is the load-bearing half, not just
  the gate.
- **`tools/t_svcname.pl` (new, 18 assertions):** `_svcQueryName` mark-folding (incl. accents LEFT
  ALONE — services keep them — and a slash untouched), the exact gate decision for the apostrophe-less
  / straight / curly / rename / identical / case-only cases, and the wider-gate invariant (new runs
  whenever old did) over a fixture set.
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION 0.49.2 == install.xml + PROBE_MBID OK; **all 23 suites
  green**. No matcher sub touched — `_svcQueryName` is DSC-only Browse logic; `matcher_sync_check.py`
  unchanged (deliberate 0.44.26 `_norm`/`%FOLD` drift only).
- **LIVE VERIFY AFTER INSTALL:** search **The Las** — the "The La's" row must now read
  **Local · Qobuz · Tidal · Deezer**, and the log should show `MB canonical 'The La’s' (service
  spelling 'The La's') differs ... searching services under it too` followed by
  `artist-search Qobuz/'The La's': ... The La's`. Controls: **The La's** (straight) unchanged;
  **Radiohead** issues no second pass.

### 0.49.1 (2026-07-23) — the artist-field pass HOLDS a "+2" top hit so the alias pass can run (The La's)
- **Simon (long-standing, 0.48.5 "STILL OPEN"): The La's never showed Qobuz.** `_artistMbidByName`'s
  quoted **artist** pass accepted MB's top hit on score alone (the `>=90` gate is a near no-op since
  Lucene normalises the best match to 100), so a wrong artist was adopted and the alias pass — which
  finds the right one — never ran.
- **MEASURED FIRST (live musicbrainz.org, 2026-07-23), because the CLAUDE.md fix shape was too glib:**
  ```
  artist:"The Las" -> 100 The Las Vegas Boneheads   (The La's NOT in results; Lucene [the][la][s])
  alias:"The Las"  -> 100 The La's                  <- the artist actually meant, already trusted
  artist:"Beatles" -> 100 The Beatles               (+1: must stay accepted, NOT held)
  artist:"La's"    -> 100 Yo La Tengo / alias:"La's" -> 100 Various Artists (special entity)
  ```
  The naive "apply `_closeEnough` to the quoted pass" would REGRESS `Beatles`->`The Beatles`
  (`_closeEnough` is a typo gate: "beatles" is 7 chars, under `FUZZY_MIN_LEN`, and edit-sim 0.64).
- **THE REAL SIGNAL: token count.** Legit fallbacks add ONE token — an article/honorific ("The"
  Beatles, "Ms." Lauryn Hill) or the query being the longer side (British Sea Power -> Sea Power).
  A wrong longer-named act adds TWO+ ("The Las" -> "The Las **Vegas Boneheads**"). New `_plausibleName`
  = token-subset either way AND `abs(token-count diff) <= 1`.
- **THE FIX IS A HOLD, NOT A REJECT — so it cannot regress.** On the **artist field, quoted, non-exact**
  only, a non-plausible top hit is parked in the SAME last-resort slot the zero-release hit uses
  (0.47.1) and the alias/loose passes run. `alias:"The Las"` returns The La's at 100, accepted there
  (the alias field is trusted by design, 0.32.0). If nothing does better, the held hit is stored —
  byte-identical to the old behaviour. The alias and loose passes are UNCHANGED (never gated by
  `_plausibleName`: an alias match's whole point is a differing name).
- **PLUS a special-entity guard:** MB's reserved meta-artists (Various Artists, [unknown], [no artist],
  [anonymous], [traditional]) are dropped from the results, so a degenerate query (`La's`, whose alias
  field leads with Various Artists at 100) can never adopt one — it falls back to the held hit instead.
- **A `perl`-invisible bug caught by the test's own numbers:** `my $n = () = split ' ', $str` returned
  **1**, not the token count (measured: `chain=1` while `scalar split` and an array both give 4), so
  every name read as plausible and the hold never fired. Switched to `my @t = split; abs(@a-@b)`.
- **`tools/t_thelas.pl` (new, 12 assertions)**, fixtures = the verbatim measured MB rows. **Designed to
  FAIL on the pre-fix code** ("The Las" -> Boneheads) and covers: the fix + that the alias pass ran;
  the +1 controls accepted with NO alias pass (surgical, not a blanket hold); exact = one query only;
  the special-entity guard; and a +2 hit whose alias finds nothing falling back to the held hit
  (no-regression proof).
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION 0.49.1 == install.xml + PROBE_MBID OK; **all 21 suites
  green** (t_zerorg's sibling hold-and-continue intact). No shared matcher sub touched — `_plausibleName`
  is API-local and CALLS `_artistMatch` (reported IN SYNC); `matcher_sync_check.py` shows only the
  deliberate 0.44.26 `_norm`/`%FOLD` drift.
- **LIVE VERIFY AFTER INSTALL:** browse/search a "The Las" (apostrophe-less) spelling — it must open
  The La's with Qobuz present, and the log should read `artist-field top hit '...Boneheads' adds a
  whole name - held, trying alias`. Controls: **Radiohead**, **The Beatles**, **Bush** (-> the band,
  not Kate Bush) unchanged.

### 0.49.0 (2026-07-23) — "Show only what you own": a local-only view toggle
- **Simon: a way, in the discography view's Options, to show purely what the user OWNS.** Confirmed
  scope: a **view toggle** (not a saved pref), keeping the **bio and the band/similar links** (owned
  or navigation), filtering everything else to owned.
- **Mechanics = the sort toggle's, exactly** — a FRESH drill-in entry carrying an explicit
  `local_only` param, threaded through `_identParams` alongside `sort`, so a filtered view's own rows
  (sort, paging, drill) re-issue the command with `local_only=1` still set and the filter sticks.
  NOT stashed in ctx: it rides the rows' param-addressed itemActions (Material), same best-effort
  legacy-walk limitation `sort` has. `topLevel` parses `local_only` (`'1'` -> 1) into `$opts`.
- **The filter lives entirely in `_buildList`** (no matcher touched, no candidate-shape change):
  - a spine release shows iff it has a **Local** section, and only its Local section(s) render — the
    spine, dates, artwork and Album/EP/Single grouping stay; streaming version rows drop. Local
    membership is the sync `localAlbums` query, stable per visit, so it is snapshot-safe.
  - **"Also on streaming"** (the unclaimed-streaming net) is suppressed — an unowned record has no
    place in a "what you own" view.
  - **"Also in your library" / "Appearances"** (owned, off-spine) are kept as-is (gated on their own
    `show_library_extras` pref); **bio** and the **"Also a member of" / "Similar artists"** links are
    kept.
  - it is a FILTERED view, so it neither **markArtistEmpty** nor **clearArtistEmpty** (an empty
    on-spine result is not a catalogue verdict), and an empty on-spine result FALLS THROUGH to render
    bio + library-extras + nav rather than short-circuiting to NO_RESULTS.
- **The Options toggle** (`_localOnlyToggleItem`, label = the ACTION: "Show only what you own" /
  "Show all sources") is offered whenever the user owns anything by the artist OR the filter is
  already on (always an escape hatch). Reuses the shipped `library_music` glyph (no new asset, 0.25.0
  precedent). The release DETAIL page is deliberately left UNFILTERED — drilling a release still
  shows every version, so a local-only browse can still reach streaming for one album.
- Gates: `zsh tools/syntax_check.sh` 5/5 + CACHE_VERSION 0.49.0 == install.xml + PROBE_MBID OK. New
  `t_localonly.pl` (8 assertions, driven through the REAL `_identParams` / `_localOnlyToggleItem` /
  `_sortToggleItem`): local_only is emitted only when on, the toggle flips label + fixedParams +
  passthrough in both directions, and a sort inside a local-only view keeps `local_only=1`. No
  matcher sub touched — `matcher_sync_check.py` reports only the deliberate 0.44.26 `_norm`/`%FOLD`
  drift.
- **LIVE VERIFY AFTER INSTALL:** open an artist you partly own -> Options now has **"Show only what
  you own"**; tap it -> only owned releases remain (Local rows), "Also on streaming" gone, bio +
  "Also in your library" + band/similar still present, and the row now reads **"Show all sources"**;
  sort/page while filtered -> stays filtered; tapping a remaining tile -> detail still lists every
  version. Control: an artist you own nothing by -> no toggle offered.

### 0.48.8 (2026-07-23) — an owned collaboration shows Local on its search row
- **Simon, with a screenshot of the search grid: the "Robert Plant & Alison Krauss" row read just
  "Qobuz"** — *"I am not talking badge, I am talking text here."* The line2 SOURCE text, not the
  emblem. He owns Raising Sand, but the row showed no Local.
- **CAUSE.** The row's sources come from `mergeArtistHits` (only Qobuz's artist search returned that
  entity for the query), and the Local attach that would add ownership — `attachLibraryArtists`
  (0.48.1) — probes the library for a contributor of the row's EXACT name. There is none: the album
  is tagged under the two MEMBER contributors, not one of the duo's name. So the exact probe missed,
  exactly as it does for the discography page before 0.48.6 taught `localAlbums` the joint
  intersection — and that same intersection was never wired into the search-row attach.
- **FIX.** When the exact probe finds nothing AND the row name is a joint credit, ask
  `localAlbums(undef, name)` — which already does the member-intersection (0.48.6) — and if it
  returns any owned album, add the **Local source**. Deliberately **no artist_id**: there is no
  single contributor to navigate to, and the row already drills to the duo correctly by name/mbid;
  attaching a member's id would send it to that member's page (or, in Simon's mistagged library, only
  coincidentally to the duo). Gated on the name being a joint credit, so ordinary rows cost nothing.
- **RANKING FOLLOWS.** 0.48.4 keyed "owned" on `artist_id`, but an owned collaboration is Local with
  no id, so it would not have trumped. The ownership predicate is now `artist_id OR a Local source`
  — correct in general (a Local row is owned however it got the badge) and normally a no-op, since a
  Local row usually carries the id.
- **`tools/t_joint.pl` 27 -> 33**: the owned duo row gains Local and no id, an UNOWNED collaboration
  gains nothing (the badge must be true), a plain unowned row is untouched, and the owned-no-id row
  still ranks first. **Verified by MUTATION** — forcing the joint branch off turns the "gains Local"
  assertion red while every negative control stays green.
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION + PROBE_MBID OK; **424 assertions green** across 20
  suites. No matcher sub touched (deliberate 0.44.26 `_norm`/`%FOLD` drift only).
- **STILL NOT Local on the row: Tidal/Deezer.** Those services' artist search simply did not return
  the duo entity for the typed query, so the row genuinely has only Qobuz among the streaming
  sources. Closing that means a per-row service search under the duo's own name — the expensive
  per-row round-trips the design rejects — so it is left. The emblem-badge cosmetic (0.48.7) and the
  library mistag (contributor carries the duo's mbid) are also still open, both Simon's call.
- **LIVE VERIFY AFTER INSTALL:** search **Alison Krauss** — the "Robert Plant & Alison Krauss" row
  must now read **Local · Qobuz**, and the log should show `'Robert Plant & Alison Krauss' is an
  OWNED collaboration ... added Local`. Control: an artist you do NOT own must not gain a false
  Local.

### 0.48.7 (2026-07-23) — a real MB duo is not folded into one of its members
- **Simon: *"if I search for Robert Plant I get no Robert Plant & Alison Krauss at all; if I search
  Alison Krauss I do."*** A regression from the 0.48.5 joint-credit fold, and the asymmetry is the
  tell. Diagnosed live end to end:
  ```
  artist mbid cache hit 'Robert Plant': bd53f9a7   (solo)
  search row keep 'Robert Plant & Alison Krauss': mbid=38eb4af8   (the duo, a REAL MB artist)
  artist mbid from library tag: 38eb4af8
  search rows: folded 'Robert Plant & Alison Krauss' into 'Robert Plant' (joint credit, 38eb4af8)
  ```
- **THE CHAIN.** The user's library tags BOTH member contributors (Robert Plant 65658, Alison Krauss
  65659) with the DUO's mbid 38eb4af8 — LMS derived it from *Raising Sand*, whose albumartist MB id
  is the duo. So in a "Robert Plant" search the Robert Plant row, carrying that library artist_id,
  resolves **via the tag** to 38eb4af8 and lands in the duo's fold group; the duo's credit-head is
  "Robert Plant", 0.48.5's fold matched it, and the duo was merged INTO the member row and vanished.
  In an "Alison Krauss" search the same group forms, but the duo's head "Robert Plant" ≠ "Alison
  Krauss" and its canonical name ≠ "Alison Krauss", so nothing folds and the duo survives — the exact
  asymmetry reported.
- **THE FOLD WAS FOR THE OPPOSITE CASE.** 0.48.5 exists for a credit MusicBrainz has NO artist for
  (Nick Cave & Warren Ellis, count=0), which only reaches an mbid by splitting to the head act — so
  the group's mbid is the head's and its canonical name is the head's ("Nick Cave"). A credit MB
  models as its OWN artist (Robert Plant & Alison Krauss, count=1) has a group whose canonical name
  IS the whole credit. That is the clean discriminator, and it needs no extra request — the fold
  already holds the canonical name.
- **FIX (one line of intent): `$splitsTo` refuses to treat a name as a foldable credit when that
  name IS the group's canonical artist** (`_norm($from) eq $canonNorm`). So a credit with its own MB
  page keeps its own row; a credit that only reached the group by head-split still folds. Nick Cave &
  Warren Ellis is untouched (its group's canonical name is "Nick Cave", not the joint string).
- **`tools/t_fold.pl` 36 -> 39**: the duo is NOT folded into a member, it keeps its row, and the
  outcome is independent of which row survives the merge. **Verified by MUTATION** — removing the
  guard turns exactly those 3 red while the Nick Cave fold and every 0.44.13 control stay green.
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION + PROBE_MBID OK; **418 assertions green** across 20
  suites. No matcher sub touched — the deliberate 0.44.26 `_norm`/`%FOLD` drift only.
- **TWO THINGS SURFACED, NEITHER FIXED HERE (both need Simon's call):**
  - **The emblem badge.** On the duo page *Raising Sand* renders `text` "…· Local/Qobuz/Tidal" with
    the library cover as artwork, but Material's single corner emblem comes from the tile's
    `favorites_url` scheme, which is `qobuz://` (Local has no `service://` scheme to make a badge
    from). So the badge reads Qobuz on an owned row — the 0.4.2 single-badge limitation, cosmetic,
    the row plays Local. Options if it bothers: suppress the favurl (loses the streaming badge AND
    the Listen-Later handshake) or leave it.
  - **The library tag itself.** Because contributor 65658 (Robert Plant) is tagged with the duo's
    mbid, browsing "Robert Plant" by that artist_id resolves to the duo — solo Robert Plant is only
    reached by NAME (bd53f9a7). Pre-existing, a metadata artefact, not touched: distrusting a library
    MB tag is a much bigger decision than this fix.
- **LIVE VERIFY AFTER INSTALL:** search **Robert Plant** — "Robert Plant & Alison Krauss" must now
  appear as its own row; search **Alison Krauss** — unchanged. Control: search **Nick Cave** — solo
  Nick Cave present and "Nick Cave & Warren Ellis" still folded into it (0.48.5), and **Lou Reed**
  still one row.

### 0.48.6 (2026-07-22) — a collaboration finds the user's own copy, whichever way it is modelled
- **Simon: *"can't find my album of Robert Plant & Alison Krauss, I see Qobuz only."*** Measured live:
  ```
  album 19127 'Raising Sand'   artist (display string) -> "Robert Plant"
  artist_id 56743 Robert Plant   -> 19127 Raising Sand
  artist_id 56744 Alison Krauss  -> 19127 Raising Sand
  ```
- **A WRONG DIAGNOSIS OF MINE, CORRECTED BY SIMON, and the correction produced a better fix.** I read
  that display string as LMS collapsing a multi-value ALBUMARTIST to the first name. He put it
  straight: *"it lives under both artists, LMS will use both or more artists when it's separated by
  `;` — that is correct metadata tagging convention."* Right: only the `albums` query's single
  DISPLAY string collapses, the contributor JOIN carries both. The real gap is that MusicBrainz
  models the duo as a **THIRD artist** (38eb4af8) his library correctly has no contributor for, so
  the page asked for a name nobody holds. My first fix (fall back to the credit HEAD) would have
  worked by accident and dragged Robert Plant's solo catalogue onto the duo's page.
- **THEN THE WIDER POINT, also his: *"some users might tag it as Robert Plant & Alison Krauss, same
  as they might for Panda Bear and Sonic Boom ... MB isn't itself consistent with doing this, some
  are new artists entirely."*** Two independent inconsistencies, so four cells, and only the diagonal
  worked. Verified live that MB really is inconsistent — this is not a hypothetical:
  ```
  artist:"Robert Plant & Alison Krauss" -> count=1  (a real Group)
  artist:"Nick Cave & Warren Ellis"     -> count=0
  artist:"Panda Bear & Sonic Boom"      -> count=0
  ```
  | | library: separate contributors | library: one joint contributor |
  |---|---|---|
  | **MB HAS a joint artist** | duo page finds NOTHING — the field report | works (name matches) |
  | **MB has NO joint artist** | works (0.47.0 -> head act, who is a contributor) | album INVISIBLE — head act has no contributor |
- **FIX — one symmetric rule: a joint credit is the SET of its parts, on whichever side it appears.**
  - browsed name joint, library has the members -> **INTERSECT** their album sets. The intersection
    IS the duo's catalogue by construction, so no solo record can leak in and *Also in your library*
    stays honest. Asserted with a solo album on each side.
  - browsed name single, a library contributor is joint AND NAMES IT as a part -> that contributor
    counts too. Part EQUALITY, never substring, so "Nick Cave" cannot adopt "Nick Cavendish &
    Friends" — the guard that keeps this from becoming the name-similarity folding withdrawn in
    0.44.13.
- **ONE definition of "joint credit", shared both ways.** The splitter moved to
  `Sources::_creditParts` and `API::_creditHead` now delegates to it, so the MusicBrainz side (the
  resolver + the 0.48.5 search-row fold) and the library side cannot drift the moment either learns
  a new separator.
- **DELIBERATE ASYMMETRY, stated because it breaks the "only on a miss" pattern:** the intersection
  runs only when the duo's own name finds no contributor, but the joint-contributor pickup runs
  ALWAYS. A user owning both a plain "Nick Cave" contributor and a "Nick Cave & Warren Ellis" one
  must get both albums, and miss-gating it would silently drop the collaboration from the page it
  belongs on. Asserted in both directions.
- **A BUG IN MY OWN FIRST CUT, caught by an existing suite:** `_creditParts` refused a split when ANY
  part was under 3 characters, but `_creditHead` had only ever checked the HEAD — so "Stan Getz / A /
  B" stopped resolving and `t_credit.pl` went red. The length rule is gone: each caller already
  applies something far stronger (the resolver needs its head to resolve on MB; the library lookup
  needs EVERY part to resolve to a real contributor by exact normalised name). "A" is refused because
  no contributor is called "A", not because it is one letter.
- **`tools/t_joint.pl` (new, 27 assertions)**, fixtures = Simon's real ids and album. **Verified by
  MUTATION on both halves separately** — killing the intersection turns 2 red, killing the
  joint-contributor pickup turns 5 red — and the CONTROLS pass in every state: a plain artist is
  unaffected and still costs exactly ONE album query, entry by `artist_id` never runs a name lookup,
  and an unknown artist still returns nothing.
  - **A mutation that silently did not apply**, again (0.47.3's lesson): the scripted `perl -0pi`
    regex matched 0 times and the suite's clean run "proved" nothing. Redone with the Edit tool and a
    `grep -c` confirmation before trusting the result.
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION + PROBE_MBID OK; **415 assertions green** across 20
  suites. No matcher sub touched — `matcher_sync_check.py` reports the deliberate 0.44.26
  `_norm`/`%FOLD` drift only. `localAlbums` is DSC-only (no sibling repo has a Local pseudo-source).
- **LIVE VERIFY AFTER INSTALL:** open **Robert Plant & Alison Krauss** — *Raising Sand* must show
  **Local** alongside Qobuz, and the log should read `localAlbums: name 'Robert Plant & Alison
  Krauss' -> artist_id 56743+56744 (joint credit, intersected)`. Controls: **Radiohead** and any
  artist entered from the Artists row must be unchanged, and the duo's page must NOT list any solo
  Robert Plant or Alison Krauss record.

### 0.48.5 (2026-07-22) — the search-row half of the joint-credit fix, and a verdict that can be wrong
- **Simon, and he was right twice: *"Nick Cave & Warren Ellis is the same as Panda Bear & Sonic Boom,
  Robert Plant & Diana Krall — why is it being treated differently as we sorted our conjoined artists
  some time ago"*, then *"looking like this never got implemented into search and is just row
  based."*** 0.47.0 taught the RESOLVER about joint credits and that half does run in search — it is
  what resolved these rows. The search-ROW layer never learned.
- **WHY MUSICBRAINZ MAKES THEM LOOK DIFFERENT — measured, because the answer is not in our code:**
  ```
  artist:"Robert Plant & Alison Krauss"  -> count=1   Group  38eb4af8   <- a real MB artist
  artist:"Nick Cave & Warren Ellis"      -> count=0
  artist:"Panda Bear & Sonic Boom"       -> count=0
  ```
  MB carries some collaborations as their own entity and files others under the individuals with a
  joint artist CREDIT. Plant & Krauss resolves to its own artist; the other two fall to 0.47.0's
  credit-head split and open the head act's page — correctly, and Nick Cave's page really does hold
  CARNAGE, Seven Psalms and the soundtracks. So they ARE handled identically; MB differs.
- **THE DEFECT IS THE FALLOUT.** The fold gate merged two rows only when MB records one name as an
  ALIAS of the other — and a joint credit is not an alias, it is not an MB anything. So every split
  row stayed a duplicate pointing at the same page. One log window, all real:
  ```
  NOT folding 'Neil Young & The Chrome Hearts'  into 'Neil Young'   - same MBID 75167b8b
  NOT folding 'Lou Reed and Kris Kristofferson' into 'Lou Reed'     - same MBID 9d1ebcfe
  NOT folding 'Lou Reed & John Cale'            into 'Lou Reed'     - same MBID 9d1ebcfe
  NOT folding 'Nick Cave & Warren Ellis'        into 'Nick Cave'    - same MBID 4aae17a7
  ```
  And because BOTH the empty verdict and the candidate pool are keyed by mbid alone, those duplicates
  then collide.
- **FIX 1 — a joint credit is fold evidence, alongside an MB alias.** `_creditHead` is pure and
  cache-only, so this costs no request. **NOT string inference** — the bar 0.44.13 set after the
  "Kate Bush folded into Bush" withdrawal: the rows have already resolved to the SAME MBID and
  `_creditHead` is the very function that put them there, so we are agreeing with a mapping we made
  deliberately, not guessing from a name. The head must match the OTHER row or MB's canonical name,
  so "Belle and Sebastian" -> "Belle" folds into nothing.
- **FIX 2 — the verdict is falsifiable.** Field: *"a first search for Nick Cave gave 4 hits, one was
  just Nick Cave which had albums in it ... now it's hidden the solo Nick Cave and it shouldn't
  have."* The log said `search row DROP 'Nick Cave': proven empty on a previous render` — and
  rendering that mbid live returns **75 items: Albums (9), Singles (5), Compilations (1)**. The
  verdict was simply WRONG, and 0.46.6 gave it no way to be proven wrong: it could only be SET, never
  unset, short of the 7-day TTL or a Refresh **on a page the search no longer shows you**. Any render
  that finds content now clears it. *A judgement that only ever accumulates is not a cache, it is a
  ratchet.*
- **FIX 3 — close the write path, not just mop up after it.** `_browsedAsSelf`: a render may record a
  verdict only if it browsed the artist under MB's canonical name or one of its recorded aliases. A
  joint-credit page was built from a pool searched under a name that is not the artist's — a fair
  render of a DIFFERENT question — and the verdict speaks for the mbid, so it would condemn the head
  act's own row. A rename (British Sea Power -> Sea Power) is an alias and still qualifies. **Fails
  safe by design:** an unknown canonical name declines to record, because a missing verdict costs one
  thin search row while a wrong one hides a real artist for a week.
- **`tools/t_fold.pl` 21 -> 36** (the fold, every `_creditHead` separator, and the 0.44.13 control
  that same-mbid rows with neither an alias nor a split STILL stay apart) and **`tools/t_verdict.pl`
  (new, 18)** for the write guard. **Verified by MUTATION** — stubbing the split test out turns 7
  fold assertions red while every control stays green.
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION + PROBE_MBID OK; **388 assertions green** across 19
  suites. No matcher sub touched — `matcher_sync_check.py` reports the deliberate 0.44.26
  `_norm`/`%FOLD` drift only.
- **STILL OPEN, deliberately not in this build** (the resolver spine, needs measuring):
  `_artistMbidByName`'s quoted pass accepts MB's top hit on SCORE alone, and Lucene normalises its
  best match to 100 — so the gate is a near no-op. Measured consequences: `artist:"The Las"` returns
  **The Las Vegas Boneheads** at 100 (The La's is not in the four results at all — Lucene tokenises
  it `[the][la][s]`), and `artist:"La's"` returns **Yo La Tengo** at 100. That wrong canonical name
  then drives 0.45.2's second pass to search the services for the WRONG artist, which is why Qobuz
  never appears on Simon's The La's row — *"the supposed Qobuz fix ... doesn't work, only the accurate
  spelling The La's works"*. It also confers 0.46.4 "exactness" on the wrong row, which is what put
  Boneheads at #0. **Fix shape:** apply 0.44.28's name-closeness gate to the QUOTED pass too. Also
  unexplained and worth a look: a row named `Robert Plant` resolved to `38eb4af8`, the DUO's mbid.
- **LIVE VERIFY AFTER INSTALL:** search **`Nick Cave`** — the solo artist must be back, and the log
  should read `folded 'Nick Cave & Warren Ellis' into 'Nick Cave' (joint credit, ...)` instead of
  `NOT folding`. Search **`Lou Reed`** and **`Neil Young`** — one row each, not three. Control:
  **`bush`** must still list Kate Bush and Bush as SEPARATE rows (the 0.44.13 protection).

### 0.48.4 (2026-07-22) — a LIBRARY artist outranks one you don't own
- **Simon: *"when searching, a Local artist will show ahead of any matches that there is no local
  artist even if it doesn't make the top hit, local should always be trumps."*** Verified live
  before touching anything, and he was right — **ownership was not a ranking key at all.** The order
  was `exact name -> number of sources -> first-seen`; Local is merely first in the SCAN order, so
  it won nothing but genuine ties. Two distinct failure shapes, both measured on the running server:
  ```
  typed 'bush'      0  Bush                     Qobuz·Tidal·Deezer   <- NOT owned, wins on exact
                    1  Kate Bush                Local·Qobuz·Deezer
                    2  Bush Tetras              Local·Qobuz·Deezer
  typed 'The Las'   0  The Las Vegas Boneheads  Qobuz·Tidal·Deezer
                    6  The Last                 Local   <- owned, buried by breadth
                    7  The Last Word            Local   <- owned, buried by breadth
  ```
  The second is the one that hurt: owning an artist NO service carries is precisely when the library
  row is the only useful answer, and breadth guaranteed it lost to anything on three services.
- **FIX — `Sources::rankArtistHits`, one comparator: `owned -> exact -> breadth -> first-seen`.**
  `artist_id` IS the ownership test and can be nothing else: `_artistHits` builds every streaming hit
  as `{ name => ... }` with no id, so an id on a merged row came from the Local leg or from
  `attachLibraryArtists`. Verified in the source before relying on it.
- **APPLIED TWICE, and that is the load-bearing part.** The merge knows what the LOCAL LEG found;
  `attachLibraryArtists` (0.48.1) rescues rows the Local leg cannot spell-match — **"The La's" is the
  entire reason that sub exists** — and it runs AFTER the merge, in `_withMbCandidates`. Ranking only
  in the merge would have missed exactly the rows 0.48.1 was written for; ranking only after it would
  let `SEARCH_MERGED_MAX` truncate an owned row before it could be promoted (asserted: 35 two-service
  rows push a Local-only row past the 30-cap under the old rule). `_seq` is preserved rather than
  re-based, so the second pass cannot re-shuffle the tiebreak — one deterministic order per library
  state, which is what the item_id walk depends on.
- **WHY OWNERSHIP OUTRANKS EXACTNESS — Simon's call, made on his own data after seeing both orderings
  side by side, and I had recommended the OTHER one first.** "Exact" is not purely what the user
  typed: 0.46.4 also accepts MusicBrainz's canonical name for whatever the query resolved to. Measured
  live: **MB resolves the query `La's` to *Yo La Tengo***, and MB resolving `Young` to Neil Young /
  `Cave` to Nick Cave & the Bad Seeds is why those owned artists already ranked first — by accident,
  not by rule. Putting ownership under that key subordinates the one thing the user can verify to an
  MB inference. **The cheaper option (`exact -> owned -> breadth`) was rejected because it does not
  fix the motivating case at all**: its top three for `La's` are byte-identical to today, with
  `The La's` still third behind a French rapper, because `_norm("The La's")` is `the las` and the
  typed `La's` is `las`.
- **ACCEPTED COST, stated in the code so nobody "fixes" it later:** typing a name that exactly matches
  an artist you do NOT own now returns owned near-misses above it — `bush` gives Kate Bush and Bush
  Tetras before Bush. Asserted as intended behaviour, not tolerated as a side effect.
- **NOT FIXED, and it is the real cause of the worst ordering seen:** MB resolving `La's` to Yo La
  Tengo. Yo La Tengo sits at #0 under *every* ordering tried, including the old one — that is a
  resolution defect, not a ranking one, and is deliberately left alone here.
- **`dsc:asearch` 10 -> 11**: the cached rows now CARRY `_seq`/`_exact` for the post-attach re-rank,
  and a v10 entry has neither — every row would re-rank as non-exact, i.e. a WORSE order than before,
  for exactly the ten-minute window someone tests this in. (CACHE_VERSION 0.48.4 clears the namespace
  regardless; this is belt and braces.)
- **`tools/t_rank.pl` (new, 19 assertions).** Fixtures are the live hits from the two field searches.
  **Verified 4 RED against the pre-change module** (written and run BEFORE the fix), then green;
  **and verified by MUTATION** — stubbing the ownership key out turns 6 assertions red while every
  CONTROL stays green, which is what proves the change is surgical: nothing owned in the results
  returns the byte-identical old order, the 0.37.1 junk gate still refuses Led Zeppelin/Pink Floyd for
  "The Beatles", exactness still orders inside each block, and re-ranking is idempotent.
- **NOT a matcher change.** `rankArtistHits`/`mergeArtistHits` are DSC-only call-site logic (the
  0.44.24 precedent), so this adds NOTHING to the fleet port debt — do not port to LBF/PFR/LL.
  `matcher_sync_check.py` reports `_norm`/`%FOLD` only, the deliberate pre-existing 0.44.26 drift.
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION + PROBE_MBID OK; **355 assertions green** across 18
  suites (every prior suite unchanged).
- **LIVE VERIFY AFTER INSTALL:** search **`The Las`** — "The La's" must be the FIRST row, with *The
  Last* and *The Last Word* above The Las Vegas Boneheads. Search **`bush`** — Kate Bush and Bush
  Tetras must now come before Bush (the deliberate trade). Control: **`Radiohead`**, **`Police`** and
  **`Beatles`** unchanged, and "The Beatles" must still not list Led Zeppelin.

### 0.48.3 (2026-07-22) — artist artwork keyed by CONTRIBUTOR ID, the way LMS does it
- Simon: *"when I play these albums or browse the artists I get the correct artwork ... from MAI"* —
  while the plugin's own row showed the silhouette. **That observation is what found the real fix**,
  and it killed the transliteration plan I was about to build.
- **LMS keys artist artwork by CONTRIBUTOR, not by name.** Its own artist browse emits
  `contributor/475bed14/image` — the SAME image for `The La's` and `The La’s`. The plugin was asking
  the MAI proxy by NAME, which cannot resolve typographic punctuation. **56 of Simon's 4,288 library
  artists carry some** (`Alison’s Halo`, `Booker T. & the MG’s`, `The Chi‐Lites`, `The dB’s`,
  `The Del‐Vetts`, `Blow–Up`…), and every one of them showed the placeholder. Measured live:
  ```
  name 'The La’s'    ->   5,071 bytes (silhouette)   id 57545 -> 418,519
  name 'The Go‐Go’s' ->   5,071 bytes                id       -> 411,927
  name 'The dB’s'    ->   5,071 bytes                id       ->  41,154
  name 'Radiohead'   -> 214,785 bytes                id       -> 214,785  (identical)
  name 'Nonexistent Band Xyzzy' -> 5,071 bytes  <- the placeholder, byte-identical
  ```
- **FIX:** `_artistImg($name, $artistId)` uses `imageproxy/mai/artist/<id>/image.png` whenever a
  numeric contributor id is known, else the name route exactly as before. Wired at the two sites that
  have an id — search result rows and MB candidate rows (a real `artist_id` now outranks the 0.43.0
  "unique spelling" test, since it is exact). *Similar artists* and *band links* keep the name route:
  they are usually not library artists, and the band row resolves its contributor id LAZILY on click
  by design (0.26.1) — not worth changing for this.
- **WHY NOT TRANSLITERATION** (the plan before Simon's remark): mapping `’`->`'` and U+2010->`-` in
  the URL would have fixed the symptom for library artists while leaving the plugin keyed differently
  from the rest of LMS. The id route is what LMS, Material and MAI all already agree on.
- **HONEST TRADE, measured:** the id route can return a SMALLER image (`The B-52s` 234KB by id vs
  1.97MB by name; `The Chi‐Lites` 14KB vs 43KB) because it serves the artwork MAI already holds for
  that contributor. That is the same picture the rest of his LMS shows, which is the point — but it
  is a change, not a pure win.
- Defensive: a non-numeric or empty id falls back to the NAME rather than emitting
  `imageproxy/mai/artist//image.png`; an id with no name is still enough to build a URL; the MAI
  enabled-check still comes first. New `tools/t_artimg.pl` (14 assertions). All 17 suites green.

### 0.48.2 (2026-07-22) — fixes the artwork regression 0.48.1 introduced
- Simon, same day: *"it's missing qobuz and doesn't have artwork"* / *"my local album has artist
  artwork"*. **The artwork half was mine.** 0.48.1 adopted the LIBRARY's spelling unconditionally
  (0.46.5's rule), and his library spells it **"The La’s" with a CURLY apostrophe**. Measured on the
  live image proxy, the same method 0.46.5 used:
  ```
  "The La's" (ASCII, what the row already had) -> 2,317,943 bytes, a photo
  "The La’s" (curly, the library's spelling)   ->     5,071 bytes, the silhouette
  "Nonexistent Band Xyzzy"                     ->     5,071 bytes, byte-identical
  ```
  0.46.5's measurement was the same failure the other way round (MB's U+2010 "The B‐52s" -> 5,071;
  library ASCII -> 1,966,381). **So the rule is not "the library's spelling wins" — it is "the
  spelling that RESOLVES wins", which in 0.46.5's case merely happened to be the library's.**
- **FIX (1) — `_typoMarks`.** The library name is adopted only when it carries no MORE typographic
  punctuation than the row already has (curly quotes, U+2010-2015 dashes, prime, ellipsis).
  **Diacritics are deliberately NOT in that class** — "Björk" and "Sigur Rós" are correct spellings
  every name-keyed lookup resolves. Both 0.46.5's case and this one now come out right under one rule.
  The `artist_id` is still the library's; only the LABEL is kept.
- **FIX (2) — pick the contributor that actually HAS the albums.** Duplicate contributors differing
  only by apostrophe style are real in Simon's library, and measured live:
  `58667 "The La's" (ASCII) -> 0 albums`, `57545 "The La’s" (curly) -> 5 albums`. Attaching the empty
  one opens a blank page. One extra `albums` query, and only when the library returns >1 match.
- **A TEST THAT ASSERTED FICTION, caught by running it.** I added "an ACCENTED library name still
  wins" and it failed — because `_normKey` `utf8::encode`s before folding and `_norm`'s diacritic
  stripping is gated on `utf8::is_utf8`, so it is SKIPPED for encoded input: **`_normKey('Bjork') ne
  _normKey('Björk')`**. A service row carrying the stripped spelling will NOT attach to an accented
  library artist. PRE-EXISTING, shared with the search Local leg and `localAlbums`, so deliberately
  NOT changed here — but now asserted as a KNOWN LIMITATION so nobody re-derives it.
  - A second fixture bug in the same suite: the stub did not model LMS folding accents in its index
    (`artists search:Bjork` really does find "Björk"), which is why the ASCII-fold ladder step exists.
- **NOT MINE, and not Deezer: the missing QOBUZ.** Measured BEFORE 0.48.1 shipped — searching
  "The Las" already returned `Tidal · Deezer` only. Typing "The La's" DOES return Qobuz, so it is
  Qobuz's own artist search not matching the plain spelling. Untouched here, still open.
- `tools/t_lone.pl` now 30 assertions. All 16 suites green; `syntax_check.sh` OK.

### 0.48.1 (2026-07-22) — a LONE search row can now attach to the user's library
- Simon: searching **"The Las"** rendered *The La's* with only Tidal/Deezer, although he owns it —
  *"I don't fully understand what's different here as opposed to another artist with ' in the name
  which we have working."* Measured, and the answer is that it is **not an apostrophe problem**.
- **THREE independent safety nets exist, and this is the one name that slips past ALL of them:**
  1. **the Local leg** — `artists search:The Las` returns *The Last / The Last Word / The Last Dinner
     Party*: real bands, WRONG ones. `_localArtistRows` returns at the first **non-empty** step, so a
     wrong answer actively BLOCKS the fallbacks. ("Las" is a prefix of "Last"; "OJays" is a prefix of
     nothing, which is exactly why The O'Jays never lands here.)
  2. **the term probes** — skipped: every word is under `PUNCT_PROBE_MIN_LEN` (4). "The" (3) and
     "Las" (3). Rag'n'Bone Man survives only because "Bone" happens to be 4 letters.
  3. **`filterRowsWithContent`'s MB canonical/alias attach** — runs ONLY for **duplicated** mbid
     groups. Every service spells this one identically, so it is a lone row. The O'Jays is rescued
     there purely because the services disagreed (straight vs curly apostrophe) — luck, not design,
     and the same is true of The Go-Go's.
  So it is a **SHORT-NAME problem**: two words both under the probe floor, where the plain spelling
  collides with other real artists and every service agrees on the spelling.
- **FIX — `Sources::attachLibraryArtists`,** called from `Browse::_withMbCandidates`. For a merged row
  with no `artist_id`, probe the library with **the row's own name** (already a service-canonical
  spelling the library CAN match) and attach on an exact `_normKey` match: Local source, the library
  `artist_id`, and the library's spelling. **Costs NO MusicBrainz request** — which is the cost
  `API.pm:1066` was avoiding — and it works on PUBLIC installs, where `filterRowsWithContent` bails
  out at `mbGap(1.1)` and none of net 3 exists at all. Simon: *"fix for all then, not just my install."*
- **Placement is deliberate.** In `_withMbCandidates`, not beside the merge: both the cached and the
  fresh path funnel through it, so a row served from the 10-minute search cache is judged against the
  library **as it is now**. It also runs AHEAD of `filterRowsWithContent`, whose alias attach is
  guarded on `!$artist_id` — so this makes that path do **less** work, not more.
- **`mergeArtistHits` stays pure** (no DB access) so `t_fold.pl`/`t_fuzzy.pl` keep running headless,
  and **`_localArtistRows` keeps its default behaviour** — it is shared with `localAlbums` on the
  BROWSE path, so its "stop at first non-empty" rule was left alone rather than fixed globally.
- **COST, measured not assumed.** The first cut made **30** CLI queries for a 10-row search: the
  shared ladder runs a spelling try plus 2 term probes per row. The probes exist to rescue a MANGLED
  USER-TYPED string; this caller already holds a canonical name, so they cannot add a hit the ladder
  would miss. New `$opt->{no_probe}` (default unchanged) skips them → **10 queries**, capped at
  `LIB_PROBE_MAX => 10` rows.
- **THE GATE IS THE WHOLE SAFETY, and the first test of it was worthless.** `_normKey` folds
  "The Las" and "The La's" to the SAME key, so only an exact `_normKey` match stops a wrong attach.
  A mutation run with the gate deleted left the suite at **20/20 green** — the negative assertions
  let the row match ITSELF, so removing the gate changed nothing about them. Rewritten around a row
  spelled *"The Las"*, whose ladder returns wrong-but-non-empty hits: mutated it now fails 3
  assertions, restored it passes. **A negative test that cannot fail is not a test.**
- New `tools/t_lone.pl` (24 assertions, LMS's real token-splitting index as the fixture, both of
  Simon's duplicate contributor spellings included). All 16 suites green; `syntax_check.sh` OK.
- Side effects, all intended: more rows gain a Local badge; those rows adopt the LIBRARY's spelling
  (0.46.5's rule — it is what `_artistImg`, `localAlbums` and the matcher's artist gate all resolve,
  so this also fixes artist ARTWORK on such rows); drill-in switches to the library-tag path.

### 0.48.0 (2026-07-22) — MusicBrainz release-group ALIASES (Simon was right about Kraftwerk) — LIVE-VERIFIED
- Simon: *"The Kraftwerk issue needs looking at more as it resolves cleanly in MB using english as do
  all their titles."* **He was right and the previous triage verdict ("needs a translation source,
  not a matcher tweak") was WRONG.** MB titles a release group in its ORIGINAL language and files
  other spellings as **aliases** — and `getReleaseGroups` had never asked for them.
- **The whole fix is one query parameter plus somewhere to put the answer.** `API.pm` now fetches
  `&inc=aliases` and stores `aliases => [...]` per entry (deduped, the title itself dropped, key
  omitted entirely when empty). **MEASURED cost: NO extra requests** — same call — and +20% payload
  on a 100-RG page (28.4KB -> 34.2KB); only ~5% of release groups (530 of 10,565 across the 54 gap
  artists) carry an alias at all. `RG_CACHE_V` v1 -> **v2** so no v1 spine can be served as v2.
- **What it closes** (all live-verified against the mirror): Kraftwerk *Radio-Activity* ->
  `Radio‐Aktivität`, *Computer World* -> `Computerwelt`, *The Man Machine* -> `Die Mensch·Maschine`;
  Big Star *Third/Sister Lovers* -> release group `3rd`; and **Prince *Sign 'O' the Times*, whose MB
  title is literally `Sign “☮︎” the Times`** — unreachable by ANY normalisation rule, ever.
- **THE INDEX HOLE, which is the part that would have made this silently do nothing.** `peekPool`
  narrows streaming candidates to buckets sharing a FIRST TOKEN with the release-group title, and an
  alias routinely starts with a different word (`computerwelt` vs `computer world`). Without folding
  the aliases' `_titleKeys` into `@lkeys`, the narrowed subset cannot contain the very candidate the
  alias exists to reach. Asserted through the indexed path, not just the full scan.
- **AN ALIAS DOES NOT GET THE FULL RULE SET — `_aliasMatches`, and this was caught by the test, not
  by reasoning.** The prefix rule reads "<album> <extra>" as an edition suffix, which is right for
  "(Deluxe)" and wrong for a different record starting with the same words: via the alias
  "The Man·Machine", `Die Mensch·Maschine` claimed the remix tribute album **"The Man-Machine
  Recreated"**. An alias must now be the WHOLE normalised title, with one deliberate exception — a
  `/` or `:` immediately after it marks an ALTERNATE TITLE rather than an edition, which is what
  keeps Big Star's `3rd`/"Third" -> *Third/Sister Lovers* working. Same discipline as 0.11.1's
  self-titled exact rule, and for the same reason: a weaker claim gets a stricter test.
  - **Verified by MUTATION:** deleting the shape gate turns the "Recreated" assertion RED.
- **DSC-ONLY, so it is NOT blocked behind the fleet `_norm` port.** `_aliasMatches` is new call-site
  logic; `_albumMatches` itself is untouched and `matcher_sync_check.py` still reports it **IN SYNC**
  across DSC/LBF/PFR (the `%FOLD` DRIFT it reports is the deliberate pre-existing one from 0.44.26).
  Do NOT port `_aliasMatches` to LBF/PFR/LL.
- Both consumers covered: `matchesFor` (aliases arrive via the existing `$opt`, no signature change)
  and `claimedLocalIds` (reads `$rg->{aliases}` directly) — otherwise an owned copy under the English
  title would leak into *Also in your library* while its own tile sat directly above it. Both Browse
  call sites pass them; `$rg` comes straight from `getReleaseGroups` on both paths.
- New `tools/t_alias.pl` (24 assertions, real MB fixtures including the U+2010 hyphen, the U+00B7
  middle dot and the peace symbol). All 15 suites green; `syntax_check.sh` OK.

### 0.47.4 (2026-07-22) — the cold render stops queueing behind work it does not owe
- Both halves come straight from the **measured** 2026-07-21 cold-path table (Jamie Cullum, 2.32s).
- **(1) THE MAI/LAST.FM LEG WAS 1,130ms — 49% OF THE RENDER — AND IT IS NOT MUSICBRAINZ.** The chain
  `warmLocalReleases -> warmBandMembers -> _warmArtistExtras -> warmOfficial` is serial to respect
  MusicBrainz's 1 req/s etiquette, but the extras leg is MAI/Last.fm and owed no such gap. It now runs
  **in parallel**, under its own `$extDone` render flag. **Still AWAITED** — 0.31.0's decision holds,
  because a section appearing on a later rebuild shifts every item_id below it. It simply stops
  waiting for MusicBrainz first.
- **(2) `getArtistCandidates` WAS FETCHED TWICE PER COLD ARTIST.** The bio's shared-name guard and the
  candidate warm both call it before either caches. It now dedupes in flight — one fetch per name
  however many callers arrive.
  - **It QUEUES rather than answering empty**, unlike the house in-flight pattern (`warmOfficial`,
    `warmBandMembers`), whose late callers get nothing because their result is optional. Here the
    result DECIDES something: an empty list tells `sharesNameWithProminentAsync` there is no same-name
    act, which is the 0.44.5 biography leak exactly.
  - **Every waiter is settled on the FAILURE path too.** The bio leg gates the render, so a queue
    drained only on success would hang the page rather than degrade it. Asserted.
- **THE TWO ARE COUPLED, AND NEITHER IS SAFE ALONE — this is the part worth remembering.** Moving the
  extras leg earlier means its shared-name guard no longer runs after the bio path has warmed the
  same-name set: it runs against a **COLD** cache, and a cold sync peek answers "not shared". That
  would warm and cache the PROMINENT act's similar artists under a secondary act's mbid — 0.44.5,
  re-created by a change that never went near it. So the guard became ASYNC, which would have added a
  request back... except the dedupe makes it free. A speed-up that quietly reintroduces a fixed bug is
  worse than no speed-up.
  - **Verified by MUTATION, not by reasoning:** reverting only the guard to its sync form (leaving the
    parallel move in place) turns the cold-cache assertion RED.
- **Three settle paths audited, because a new render flag is a new way to hang forever:** the
  `official_wait` deadline now clears `$extDone` as well (inside the serial chain a hung MAI was
  already capped by that timer — gating a new flag without extending it would have made a hung MAI
  hang the page indefinitely); the `official_wait = 0` opt-out settles it immediately (opt-out must
  never reintroduce a wait); and the release-group `onError` path settles it, the same lesson as
  0.44.18's `$poolDone`.
- **`tools/t_perf.pl` (new, 20 assertions)** with a deliberately DEFERRED HTTP stub, so "in flight" is
  a real state rather than a simulated one. **Verified 1 RED pre-fix** (the double fetch) plus the
  mutation check above. Covers the queued caller getting the REAL list, the marker being released
  (a stuck one would wedge a name forever), different names not sharing a queue, failure settling
  everyone, and the cold-guard trap in both directions.
- **A HARNESS BUG OF MINE, caught because the failure looked too much like the bug:** the HTTP-error
  assertions went red pre-fix, which I nearly recorded as a second defect. The cause was my `flush()`
  draining ONE snapshot of deferred callbacks — a mirror error legitimately retries against the public
  API, queueing another. It now drains repeatedly. **A harness that under-drains an async queue looks
  exactly like a hung callback in the code.**
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION + PROBE_MBID OK; **268 assertions green** across 14
  suites. No matcher sub touched.
- **LIVE VERIFY AFTER INSTALL:** browse a COLD artist (clearcache first) and compare `render=` against
  the same artist on 0.47.3 — expect roughly a second off. The **Similar artists** section must still
  be present on that FIRST render (it is still awaited); if it only appears on re-entry, the parallel
  leg is settling too late and the flag needs re-checking. Control: a secondary same-name act
  (the horrorcore Madness, mbid 5d500d2e) must still show NO similar-artists section at all.

### 0.47.3 (2026-07-22) — the mirror auto-detect probe asked for an artist that does not exist
- **A ONE-CHARACTER-CLASS BUG THAT DISABLED A WHOLE FEATURE, TWICE.** `MB_PROBE_MBID` shipped as
  `a74b1b7f-06a0-4672-a641-eb3353aa608d` — a mangled copy of Radiohead's id sharing only the first
  block. Re-verified live before touching anything:
  ```
  a74b1b7f-06a0-4672-a641-eb3353aa608d -> 404   (mirror AND musicbrainz.org)
  a74b1b7f-71a5-4011-9441-d0b5e4122711 -> 200   Radiohead
  ```
  `autodetectMirror` validates a candidate by fetching that artist and comparing the name, so the
  probe could never validate, no mirror was ever adopted, and **every install with a blank
  `mb_base_url` and a same-host mirror ran the whole plugin against the public API at 1 req/s** —
  re-probing daily, forever. The feature shipped in 0.30.0 and was "fixed" again in 0.30.1 without
  ever once firing. (Simon's own box is unaffected: his base is set by hand.)
- **WHY IT SURVIVED TWO RELEASES, and the reason the fix is not just the constant: the failure is
  INVISIBLE BY CONSTRUCTION.** A 404 on the probe artist is indistinguishable from "nothing is
  running on :5000" — the correct, expected, silent outcome for most users. No runtime log, no unit
  test and no amount of code reading can tell the two apart. Only MusicBrainz can.
- **So `tools/syntax_check.sh` now ASKS IT:** it fetches `MB_PROBE_MBID` from musicbrainz.org and
  fails the gate unless the artist really is `MB_PROBE_NAME`. **Verified in both directions** — the
  gate exits 1 with the old constant and 0 with the new one. Skipped cleanly when offline, so the
  check stays usable without a network.
- `tools/t_mirror.pl` 14 -> 23: the probe carries the constant, a validating responder is adopted and
  cached, a responder that answers with something ELSE is rejected after trying both same-host
  candidates (the guard that stops an AirPlay or Flask service on :5000 being taken for a mirror), no
  responder caches probed-none, a manually-set base is never probed over, and a cached verdict is not
  re-probed. **Verified by MUTATION** — breaking the name comparison in `autodetectMirror` turns the
  adoption assertion red.
- **AND THAT MUTATION CHECK IS THE REASON THIS ENTRY MATTERS BEYOND THE BUG.** It came back GREEN
  first time, against deliberately broken code, because my new assertion read
  `ok(($CACHE{...} // '') =~ m{...}, 'name')` — a bare match in an argument list returns the EMPTY
  LIST on failure, shifting the test NAME into the condition slot so a FAILING assertion prints as a
  pass. **Fifth sighting in this repo** (0.43.5, 0.44.24, 0.46.4, 0.47.2, here), and the first one
  that was caught by mutation rather than luck.
  - **Fixed structurally, not locally: every `ok()` in all 13 suites now DIES when called without a
    test name.** A missing name is the exact fingerprint of the trap, so it can no longer be scored
    as a pass anywhere. Proven to fire on a deliberate `ok($s =~ /nomatch/, '...')`.
  - **Rule worth keeping fleet-wide: never put a bare `=~`, `grep` or `map` in an argument list.**
- **A claim of mine, withdrawn:** I first justified a "the probe mbid is well-formed" assertion as a
  cheap backstop. The BROKEN constant was itself well-formed, so it would not have caught anything;
  the comment now says so rather than implying cover that does not exist.
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION OK + **PROBE_MBID OK**; **248 assertions green** across
  13 suites. No matcher sub touched.
- **NO LIVE VERIFY POSSIBLE ON SIMON'S BOX** — auto-detect only runs when `mb_base_url` is BLANK, and
  his is set. Verified instead by direct HTTP against both hosts plus the mutation-checked unit
  coverage. Anyone testing it for real must clear the pref first.

### 0.47.2 (2026-07-22) — ONE coincidental title is not corroboration (the Rossini rapper)
- **FIELD: browsing "Rossini" rendered three albums plus 42 rows of a MODERN RAPPER** — *Oxytocin II*,
  *ZINALE*, *Alté girl/Son of Orpheus*, 2023-2026. The spine guard from 0.43.1 **did arm**, and lost
  on a single accidental title:
  ```
  Tidal:  'Rossini' is ambiguous - 3637384=1, 51024775=0, 58712447=0, 57520369=0 spine titles
  Deezer: 'Rossini' is ambiguous - 1155894=1, 274461941=0, 106057932=0, 15290083=0 spine titles
  ```
  Against a spine of several HUNDRED release groups one hit is noise — but it beat zero, and
  `unless ($scored[0]{score})` treats any non-zero as settled.
- **A BETTER ANSWER PROVABLY EXISTED, measured on the same mbid in the same session:** browsing MB's
  own canonical name scores the RIGHT Tidal artist **3**, and the page changes completely.
  | query | Tidal score | page |
  |---|---|---|
  | `Rossini` | 3637384 = **1** | Albums (3), 42 unclaimed pop rows |
  | `Gioachino Rossini` | 3901472 = **3** | Albums (19), Compilations (1), Live (5) |
- **THE SECOND HALF, and it is the wider hole — an UNVERIFIED pick.** Shostakovich on Qobuz and Deezer
  logged **no `is ambiguous` line at all**: no service artist is named exactly "Shostakovich", so
  `_sameName` is empty, `$verify` never arms, and `_pickArtist`'s fallback — `_artistMatch`, a token
  SUBSET test — adopted **Maxim Shostakovich** (his son) and the **Shostakovich Quartet** with nothing
  checked whatsoever. Scoring that pick costs NOTHING, because its albums are fetched either way.
- **FIX: a weakly corroborated pick is HELD, not settled on.** Below `SPINE_STRONG` (2) the resolver
  buys ONE more name — the canonical name Browse already puts at the front of the alias list (0.45.0,
  supplied regardless of ambiguity) — and keeps whichever corroborates more. **If nothing does better
  the held pick is returned unchanged**, which is the entire safety argument: an artist whose service
  titles merely spell differently from MusicBrainz's still resolves exactly as today. That is the
  case the verify path was deliberately not made the default for, and it stays intact.
- **THE COST IS ON THE BROKEN PATH ONLY.** A strong pick returns immediately — no extra search, no
  extra album fetch (asserted: `Gioachino Rossini` fetches exactly one catalogue and searches no
  further names). A weak one costs at most one extra search+fetch per service, capped by
  `WEAK_RETRY_MAX`; a total MISS still walks the full `ALIAS_MAX` list, as it always has.
- **0.43.1's RULE IS UNTOUCHED AND ASSERTED:** an ambiguous name where nothing corroborates is still
  **UNRESOLVED**, never a silent adoption of the prominent act — the held-pick fallback must not
  resurrect that, and a test pins it.
- **HONEST LIMIT, measured rather than hoped for: this does NOT fix Shostakovich.** His MB canonical
  name is **Cyrillic** (`Дмитрий Дмитриевич Шостакович`), so the one retry name is one no streaming
  service can match, and the fallback correctly returns the pick he has today. Fixing that needs MB's
  Latin ALIASES, which are fetched only for an ambiguous name — a separate, wider change. Recorded
  because a fix log that implies more coverage than it has is how the next session wastes a day.
  Note too that his "wrong" Qobuz pick is not junk the way Rossini's rapper is: they ARE Shostakovich
  recordings, credited to a conductor. For a COMPOSER, wrong-artist and wrong-music are different
  questions, and the spine score cannot tell them apart.
- **`tools/t_weak.pl` (new, 14 assertions)**, fixture in the shape the field produced (including the
  one coincidental title that did the damage). **Verified 4 RED against the pre-fix module and 14/14
  after** — and the ten passing in BOTH states are the guards: the strong pick costing nothing, the
  fallback returning the uncorroborated pick, a fruitless retry leaving it alone, no-spine meaning no
  opinion, and the 0.43.1 UNRESOLVED rule.
- **THE LIST-CONTEXT `ok()` TRAP BIT AGAIN — fourth time in this repo, in my own new test.**
  `ok($titles =~ /Cenerentola/, 'name')` reported **ok with a blank name** while actually failing: a
  failing match returns the EMPTY LIST, so the test NAME shifts into the condition slot. It was
  visible only as a stray "uninitialized value" warning. `scalar()` restored, with the reason in-code.
  Worth a fleet habit: never put a bare `=~` in an argument list.
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION OK; **239 assertions green** across 13 suites.
  `matcher_sync_check.py` reports `_norm`/`%FOLD` only (the deliberate 0.44.26 divergence);
  `_resolveArtist`/`_resolveOne`/`_spineScore` are DSC-only call-site logic, so no fleet port debt.
- **LIVE VERIFY AFTER INSTALL:** open **Rossini** — Albums should jump from 3, the "Also on streaming"
  rows must stop being a rapper's singles, and the log should read `corroborates only 1 spine title(s)
  - holding it and looking further` then a retry under `Gioachino Rossini`. Controls: **Radiohead**,
  **Vivaldi** and **Sibelius** unchanged, and **Shostakovich** must still show Albums (40).

### 0.47.1 (2026-07-22) — a MusicBrainz artist with NO RELEASES is not an answer (the classical blackout)
- **FIELD (classical cluster, from the sweep's service-blackout list): browsing "Shostakovich" rendered
  "No releases found"** while Tidal had **111 real candidates** waiting. Measured on the mirror, and
  the whole defect is four lines:
  ```
  artist:"Shostakovich" -> 100 Shostakovich Trio            (Group, 0 release groups)  <- taken
                            99 The Shostakovich String Quartet
  alias:"Shostakovich"  -> 100 Дмитрий Дмитриевич Шостакович (Person)                  <- the composer
  ```
  **The composer's MB canonical name is CYRILLIC**, so the `artist:` field can NEVER find him — only
  the alias pass can. But the alias pass runs on FAILURE, and the artist pass "succeeded" by taking a
  group that shares his surname and has catalogued nothing. Same shape as 0.43.7 (a lone same-name hit
  trusted unchecked) and 0.44.28: **a confident-looking first hit stopping a better pass.**
- **The test already existed one path over.** `filterRowsWithContent` has dropped zero-release artists
  since 0.44.7 (`1 MB artist(s) dropped as having no releases`); the BROWSE resolver never applied it.
- **FIX: a zero-release winner is HELD, not accepted.** `_artistMbidByName` counts its release groups
  and, on zero, parks the mbid in `$zeroMbid` and falls through to the alias / unquoted / credit-split
  passes. **If none of them does better the held hit is stored anyway** — so every artist that resolves
  today still resolves to the same mbid, and the worst case is byte-identical to the old behaviour.
  That fallback is the whole safety argument; without it this would trade one dead page for another.
- **THE COST IS TARGETED, and measured by test rather than asserted:** the count runs ONLY when the
  winner's `_norm` name is not what was searched for. "Radiohead" issues **zero** release-group
  requests; "Shostakovich" -> "Shostakovich Trio" is exactly the shape that goes wrong. Throttle rule
  matches the alias and credit-split passes — a SPECULATIVE lookup adds nothing against the public API.
- **It reuses `warmCandidateCounts` / `dsc:rgcount`, so on the common path it is not an extra request
  at all** — the dead-end row filter needed that same count a moment later and now reads it from cache.
- **HONEST COST, and it weakens a 0.46.6 claim:** that entry said the empty-artist verdict costs "no
  extra request, ever". It now costs one, in one case — a row whose verdict is already recorded still
  pays the resolver's identity count before the verdict can be read (the verdict is mbid-keyed, so
  resolution has to happen first). One local request on a mirror, which is the only place that filter
  ever runs. `tools/t_fold.pl`'s assertion was rewritten to say what is now true instead of quietly
  passing — a cost assertion that no longer matches the code is how the next diagnosis goes wrong.
- **`tools/t_zerorg.pl` (new, 18 assertions)**, fixture = the mirror's real answers including the
  Cyrillic canonical name. **Verified 8 RED against the pre-fix module and 18/18 after** — and the ten
  that pass in BOTH states are the ones that matter: the exact-name artist costing nothing, the
  fallback returning the release-less hit when there is no alternative, a FAILED count not being read
  as a zero, and the speculative/public-API path adding no requests.
- **A FIXTURE BUG OF MINE, caught by the suite and worth recording:** `t_canon.pl` started failing its
  "capture is free" request count. The cause was the STUB, not the code — its responder answered every
  URL with an artist list, so the new count read as zero and the resolver (correctly) went looking for
  a better artist. Sea Power has 52 release groups; the fixture now says so. **A stub that answers a
  question it was never taught indicts the code instead of itself** — the third fixture bug in this
  repo with that shape (0.44.19's unflagged byte, 0.43.3's decoded string).
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION OK; **225 assertions green** across 12 suites.
  `matcher_sync_check.py` reports `_norm`/`%FOLD` only — the deliberate DSC divergence from 0.44.26,
  untouched here. No matcher sub changed; `_artistMbidByName` is DSC-only resolver logic.
- **LIVE VERIFY AFTER INSTALL:** open **Shostakovich** — it must show a real discography instead of
  "No releases found", with `has NO release groups - held as a fallback, looking further` in the log.
  Controls: **Vivaldi** (47 albums) and **Sibelius** (16) unchanged; **Radiohead** unchanged and
  costing no extra MB request.

### 0.47.0 (2026-07-22) — a JOINT CREDIT is not an artist name (the sweep's "compound name" cluster)
- **The sweep filed these as SERVICE BLACKOUTS; they are not.** Measured live: an album whose
  ALBUMARTIST is a joint credit dead-ends on **"Couldn't identify this artist on MusicBrainz"** —
  the whole page, not one service. The harness only saw "a service matched 0" and drew the wrong
  label.
  ```
  artist:'Stan Getz / João Gilberto feat. Antônio Carlos Jobim' -> count=2 (error + Retry)
  artist:'Charlie Parker & Dizzy Gillespie'                     -> count=2 (error + Retry)
  ```
  MusicBrainz has no ARTIST with those names: it models them as an artist CREDIT of two artists on
  the release, so every resolver pass was asking for something that cannot exist. The library, by
  contrast, keeps the joint string as ONE contributor (`Stan Getz / João Gilberto feat. Antônio
  Carlos Jobim` is contributor 57045 — there is no plain "Stan Getz" row at all).
- **SCOPE, MEASURED, and it is what shaped the fix.** Of 1107 album artists, **49 look like joint
  credits — and 36 of those are real band names that resolve fine** (Belle and Sebastian, Nick Cave
  & the Bad Seeds, Booker T. & the MG's, Echo and the Bunnymen). **13 fail** on MusicBrainz; run
  through the plugin's REAL chain, its existing alias/unquoted passes already rescue **2** of them.
  The remaining **11** are what this recovers.
- **A FIX I NEARLY BUILT AND DID NOT NEED.** Probing the mirror directly, "Antony and the Johnsons"
  and "Echo and the Bunnymen" both failed and an `&`/`and` variant pass fixed them — so I started
  designing one. Running the same names through the PLUGIN showed both already resolve (35 and 75
  rows). The variant pass would have been dead code. **Measure through the real chain, not through
  the dependency it calls** — the mirror is not the resolver.
- **FIX: after every existing pass has definitively missed, split the credit and resolve the FIRST
  act named.** `_creditHead` splits on the first ` / `, ` & `, ` + `, ` feat. `, ` with `, ` and `,
  ` vs ` (spaces required, so "AC/DC" is untouched; a head under 3 characters is refused). The
  result caches under the JOINT name, so it costs one extra lookup per such artist per 30 days.
- **THE MISS-GUARD IS THE ENTIRE DESIGN.** "Belle and Sebastian" never reaches this code because it
  resolves — the splitter only ever sees a name nothing else could identify. Same shape as 0.32.0's
  alias retry and 0.44.28's unquoted pass: it can rescue a failure, never change a resolution that
  works. Without that guard this would be the worst kind of change, since the cost of being wrong is
  a confidently WRONG discography instead of an honest miss.
- **Two consequences verified BEFORE building, not assumed:**
  - the matcher still works — `_artistMatch` is a token-subset test and the joint credit is the
    LARGER set, so `{stan,getz}` ⊆ `{stan,getz,joão,gilberto,feat,antônio,carlos,jobim}`;
  - the services get asked under a searchable name — 0.45.0 already puts MB's canonical name at the
    front of the alias list when it differs, so `getCandidates` searches "Stan Getz" rather than the
    joint string no service could match.
- **`tools/t_credit.pl` (new, 16 assertions)**, split deliberately into two halves: the credits that
  must resolve, and the BAND NAMES that must never be split (with an explicit check that "Belle"
  alone is never asked for). **Verified 4 RED against the pre-fix module and 16/16 after** — and the
  band-name half passes in BOTH states, which is what proves the guard rather than the feature.
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION OK; **207 assertions green** across 11 suites.
- **LIVE VERIFY AFTER INSTALL:** open **Charlie Parker & Dizzy Gillespie** and **Stan Getz / João
  Gilberto feat. Antônio Carlos Jobim** — each must open the first-named artist's discography with
  the owned album showing under Local, instead of "Couldn't identify". Control: **Belle and
  Sebastian** and **Nick Cave & the Bad Seeds** must be unchanged.

### 0.46.8 (2026-07-22) — same-title rivalry: the ALBUM outranks the single (the sweep's ABBA lead)
- **The strongest single lead from the full-library sweep, now closed.** Reproduced live before
  changing anything: ABBA have NINE studio albums and the page showed **six**.
  ```
  Albums (6)   Voyage · The Visitors · Voulez‐vous · The Album · Arrival · ABBA
  MISSING      Ring Ring · Waterloo · Super Trouper
  Singles (10) ... Super Trouper (1980) · Waterloo (1974) · Ring Ring (1973) ...
  ```
  The three missing albums are EXACTLY the three whose title is also a single. No exceptions, which
  is what made the cause findable.
- **CAUSE — the tie-break was deciding on date PRECISION, not chronology.** `_rivalsByTitle` sorted
  rivals by `comp`, then **`date cmp`** — a string compare. From the mirror:
  ```
  Waterloo       Album 1974-03-04   vs  Single 1974-03
  Super Trouper  Album 1980-11-03   vs  Single 1980-11
  Ring Ring      Album 1973-03-26   vs  Single 1973-02-14
  ```
  A partial date is a PREFIX of the fuller one, so `"1980-11"` sorts before `"1980-11-03"`. The
  single therefore came first for all three (genuinely earlier only for Ring Ring), `_rivalOwner`
  gave it the streaming candidate, and `hide_unmatched` removed the album.
- **FIX 1 — primary type ranks ahead of date: Album, then EP, then Single** (still behind `comp`, so
  0.16.0's White-Album rule is untouched). A service release titled "Super Trouper" by ABBA is the
  album; 1970s vinyl singles rarely exist as separate streaming releases at all. An UNTYPED group
  sorts WITH Album, not last — demoting it would recreate this bug wherever MB has typed loosely.
  - **KNOWN COST, accepted:** where a service carries both, both candidates now land on the album
    (its detail lists two versions) and the single row hides. One-candidate-per-rival assignment
    needs a global pass across every release group — far more than this defect warrants.
  - **Candidate TYPE was considered and rejected as the signal:** Deezer exposes `record_type`,
    TIDAL only implies it through fetch buckets we merge untagged, Qobuz is unreliable — patchy
    coverage, plus a candidate-shape change and a `CAND_CACHE_V` bump, against a two-line ordering
    fix.
- **FIX 2 — a group the user's TYPE FILTER hides can no longer own a candidate.** This is the second
  half of the same sweep finding (*"the matcher runs over release groups that are never rendered —
  202 match calls for 75 rendered releases"*). The rival list already excluded bootlegs and
  Remix/DJ-mix for exactly this reason; `show_types` had been missed, so with Singles hidden the
  single still claimed the album's candidate and **neither** row appeared. Both call sites pass the
  filter — the detail page too, or a drill-in would compute a different owner than the tile that
  opened it (the 0.18.0 class of bug).
- **`tools/t_rivals.pl` (new, 15 assertions)**, fixtures = the real MB records off the mirror.
  **Verified 11 RED against the pre-fix module and 15/15 after**, and the four that pass in BOTH
  states are the invariants: a compilation still winning on its own year (0.16.0), bootlegs and
  Remix groups still excluded, and rival order independent of MB's input order (item_id walks
  depend on that determinism).
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION OK; **191 assertions green**. No matcher sub touched —
  `_rivalsByTitle`/`_rivalOwner` are DSC-only call-site logic.
- **LIVE VERIFY AFTER INSTALL:** open ABBA — **Albums (9)**, with Ring Ring, Waterloo and Super
  Trouper back and matched; the same three should now be the ones missing from Singles. Control:
  The Beatles' four same-titled compilations must still resolve to ONE White Album tile.

### 0.46.7 (2026-07-22) — clearcache reports the mbid it RESOLVED (and clears the pool it names)
- Spotted while verifying 0.46.6 live: `["discography","clearcache","artist:Luke Bushell"]` replied
  `"mbid":""` while the log line said
  `clearArtistCache name='Luke Bushell' mbid='cbf5bb9c-…' -> mbid,bio,candnames,rg,official,bands,rgcount,empty`.
  The reply echoed the mbid **passed in**, not the one used.
- **NOT only cosmetic, which is why it was worth a build.** `_cliClearCache` then passed that same
  empty `$mbid` to `clearCandidates`, and candidate pools are **mbid-scoped** (0.43.2) — so a
  clear-by-name cleared the name-keyed pool and left the mbid-keyed one intact. That is precisely
  the pool someone running clearcache is trying to shift, and the handler's own comment already said
  so. Recovering the mbid fixes the reply AND closes that hole.
- **`clearArtistCache` returns the resolved mbid in LIST context** (`wantarray ? (\@cleared, $mbid)
  : \@cleared`). The caller cannot derive it: it is recovered inside from the name cache, and
  clearing that cache is the first thing the sub does. Scalar context is unchanged, so Browse's
  Refresh row and every other caller are untouched.
- **A reply that contradicts the log is how a later diagnosis goes wrong** — the same class as
  0.45.0's "cached 1d" message and 0.44.9's truncated log window, both of which cost real time.
- `tools/t_fold.pl` 17 -> 21: clearing by name reports the resolved mbid, says it cleared the
  `empty` verdict, the verdict is genuinely gone, and SCALAR context still returns just the list.
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION OK; **176 assertions green**.

### 0.46.6 (2026-07-22) — dead-end search rows: PROVE it once, then remember
- **Simon: *"I thought we had put in place a way to stop displaying artists when searching that
  return no content. I am still finding these popping up."*** The filter (0.44.7) works — it just
  answers a DIFFERENT question: *"does MusicBrainz list releases for this artist?"*, never *"is any
  of it playable HERE?"*. The gap was documented in 0.43.5 and this is it in the field.
- **FOUND A LIVE EXAMPLE rather than reasoning from the code.** Drilling every row of two searches:
  ```
  search "bush"    -> 15 rows, 14 open real discographies, 1 dead: Luke Bushell
  search "madness" -> 18 rows, all fine (same-name rows drilled BY MBID, not by name —
                      drilling by name sends every same-name row to the same artist)
  ```
  and the log gives the reason exactly: `match 'Wondering' [Luke Bushell]: NO MATCH | pool:
  Deezer=1, Qobuz=1, Tidal=1` — 8 release groups in MB (so the count filter rightly keeps him),
  every service holds an artist entity of that name (so he is a legitimate search hit), and nothing
  corroborates. **Both innocent explanations were checked and ruled out:** the type filters are not
  hiding it (Albums/EPs/Singles/Compilations/Live all render on a normal artist), and the same-name
  section rows all open real pages.
- **WHY NOT JUST RESOLVE AT SEARCH TIME:** that is ~6 service requests per row on a 15-row search.
  Measured on the box: a cold search is **1.94s** and a warm one **0.04s** — this would add seconds
  to every search to remove the occasional row.
- **THE FIX: the artist page has already answered the question the expensive way, so record the
  verdict.** A render that ends with nothing to show writes `dsc:empty:1:<mbid>` (7d), and
  `filterRowsWithContent` drops rows for it — checked BEFORE the release-count fetch, since it is a
  cache read AND a stronger answer. **No extra request, ever.** Cost is one cache read per row
  against a 43ms warm search; it can only remove work later.
- **FOUR GUARDS, because wrongly hiding a real artist is far worse than showing a thin one:**
  1. the pool must have **RESOLVED** — cold or errored means "not asked yet", not "nothing there"
     (0.43.9's distinction; 0.44.5's lesson that a cold cache must never answer "no");
  2. MB must list releases AND the user's own type filters must leave at least one on the table —
     an empty page because Singles are hidden is a PREFERENCE, not an absent artist (0.43.9: check
     the user's view filters before diagnosing a match failure);
  3. never for an artist the user OWNS;
  4. TTL'd at 7 days — a judgement about a CATALOGUE, which changes when a service adds the artist,
     unlike the 30d name/alias entries — and cleared by Refresh / `clearcache`, so "look again"
     genuinely looks again.
- **A HALF OF MY OWN PROPOSAL, DROPPED after thinking about the cost:** I had also suggested
  evaluating already-cached pools at search time. Matching needs the full release-group LIST, but
  the row filter only ever fetches a COUNT (`limit=1`, one request) — so for an artist whose list is
  cold that is up to 6 MB requests per row, exactly the cost being refused. And when the list IS
  warm the page has already rendered, so the recorded verdict covers it. Cost, no coverage.
- **Ordering note kept in-code:** the empty return short-circuits BEFORE the "Also on streaming" and
  library-extras sections are built, so the verdict matches exactly what the user sees. If that
  early return ever changes, the condition must move with it.
- **`tools/t_fold.pl` 10 -> 17**: the verdict is honoured, it outranks (and skips) the count fetch,
  a LIBRARY row is exempt, `markArtistEmpty`/`peekArtistEmpty` round-trip, Refresh clears it, and a
  control proves the same row is KEPT with no verdict recorded.
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION OK; **172 assertions green**. No matcher sub touched.
- **LIVE VERIFY AFTER INSTALL:** search "bush" (Luke Bushell should still appear — nothing is known
  yet), open him -> "No releases found", then search "bush" again: the row must be GONE, with
  `search row DROP 'Luke Bushell': proven empty on a previous render` in the log. Then tap Refresh
  on his page and confirm the row comes back — the verdict must be undoable.

### 0.46.5 (2026-07-22) — the LIBRARY's spelling outranks MusicBrainz's canonical one
- **Simon: *"still missing the artist artwork for The b52s, also missing for Pink Floyd oddly."*** Two
  different causes; this entry is the one that was ours.
- **MB's canonical name is a spelling NOTHING ELSE IN THE CHAIN CAN RESOLVE.** For this band it is
  `The B‐52s` with a **U+2010 HYPHEN**. Measured on the live LMS image proxy, same session:
  ```
  "The B-52s"  (library, ASCII)  -> 1,966,381 bytes   a real photo
  "The B‐52s"  (MB canonical)    ->     5,071 bytes   the silhouette placeholder
  ```
  Artwork is only the visible half — `_artistImg`, `localAlbums`' name fallback and the matcher's
  artist gate are ALL name-keyed, so relabelling a row to a spelling only MusicBrainz uses degrades
  every one of them.
- **FIX: when a folded row already carries a library `artist_id`, keep the LIBRARY's spelling.** It
  is what the user sees everywhere else in LMS and the one spelling known to resolve. MB canonical
  remains right for a row the library does NOT know — which is the case 0.44.20 was written for
  (`Layo and bushwacka` vs `Layo & Bushwacka!` depending on what was typed), and that is asserted
  here so this fix cannot quietly disable it.
- **Why `b52s` already had artwork and `b-52s` did not:** for `b52s` the 0.46.2 attach re-labelled the
  row back to the library name after the canonical relabel; for `b-52s` the row ALREADY had an
  `artist_id`, so the attach never ran and the canonical name stood. Same defect, visible only on
  one of the two routes — the argument for testing the fold directly rather than through a query.
- **`tools/t_fold.pl` (new, 10 assertions)** — the first test to drive `filterRowsWithContent`
  END TO END (stubbed HTTP by URL: artist search, release-group count, alias fetch). Three field
  bugs in a row have now lived in this block, and every one of them presented as "wrong text in a
  row" while actually breaking MATCHING. **Verified 2 RED against the pre-fix module and 10/10
  after**, with the 0.44.20 canonical case green in BOTH states — which is what proves the change is
  surgical rather than merely a preference flip. Also covers the lone-row case, a dead-end row still
  being dropped (0.44.7) and a library row surviving when MB knows nothing.
- **NOT ours, and TRACED TO SOURCE — the Pink Floyd photo. DEEZER's image is a placeholder.**
  MAI asks `api.lms-community.org/music/artist/<name>/picture`, which answers with a Deezer CDN URL;
  fetching that URL directly (browser UA — a bare curl gets 0 bytes) returns **exactly the 32,022-byte
  grey silhouette LMS serves**, md5 `cf0b6a5247e606f67470140451774cb5`, for BOTH `Pink Floyd`
  (artist 6d6d4e14…) and `B52's` (artist 8101b740…). Nothing local is involved and nothing is
  mis-keyed: MAI faithfully serves the picture it is given, and the entity that picture belongs to
  has no photo.
  - **A HYPOTHESIS OF MINE THAT WAS WRONG, recorded because a wrong lead in this log is worse than
    no lead:** I first read this as a generic `artist.jpg` being picked up as real local artwork
    (MAI's `_artworkUrl` does try local first, and `defaultArtistPhoto()` does prefer a user file).
    Fetching the CDN URL disproved it. The tell was already in the data and I had missed it — an
    UNKNOWN artist returns MAI's bundled 5,071-byte PNG, not the 32,022-byte JPEG, so the JPEG was
    never a fallback at all.
  - The case split (`pink floyd` returning a real 136 KB photo) is MAI's own cache: `API.pm` keys it
    on the full escaped URL — case-SENSITIVE — with a **1-year TTL**, so the lowercase entry still
    holds a good URL cached before Deezer's entity lost its picture. Not a lookup rule, and not
    something to build on.
  - **User-side fix that needs no debug logging:** drop an artist image in the artist-image folder
    (or the album folder) — MAI checks local artwork BEFORE the API, so it wins. Upstream, the
    picture for that Deezer entity is the thing that is wrong.
  - **This is exactly why 0.46.5 matters for the B-52s:** the API returns the placeholder entity for
    `B52's` but a REAL 1.9 MB photo for `The B-52s`, the library's spelling — so keeping that
    spelling is what gets the picture.
- **Deliberately NOT done: lowercasing the proxy name.** It "fixes" Pink Floyd by accident and
  changes which image The B-52s gets (1.9 MB -> a different 148 KB one) — trading a known-good result
  for a coin toss on an MAI cache quirk.
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION OK; **165 assertions green** (t_norm 51, t_fuzzy 26,
  t_local 18, t_loose 15, t_mbname 15, t_mirror 14, t_canon 12, t_fold 10, t_resolve 4). No cache-key
  bump needed — the merged list is cached PRE-fold and the fold runs live; CACHE_VERSION 0.46.5
  clears the namespace regardless.

### 0.46.4 (2026-07-22) — judge a canonical-pass hit against the CANONICAL name
- **Simon: *"search for b52s is missing Deezer, it works for all 3 services when its the b-52s."*** With
  0.46.3 installed the page itself was fixed (log: `relabelled 'B52's' to MB canonical 'The B‐52s'`
  then `attached library artist 62125 ... via MB alias 'The B‐52s'`); this is the remaining source
  label.
- **DEEZER WAS NEVER MISSING — its hits were thrown away by the relevance gate.** The log says
  `artist search 'b52s': 2 merged from Deezer=2,Local=1,Qobuz=24,Tidal=30`. 0.45.2 fetches a second
  round under MusicBrainz's canonical name, but `mergeArtistHits` then judged those hits against the
  string the USER typed:
  ```
  _norm("The B-52's") = 'the b 52s'   vs typed 'b52s'
    substring no · token-subset no · fuzzy no (4-char query, FUZZY_MIN_LEN is 8)
  ```
  **Qobuz and Tidal survived on a coincidence, not a difference** — their result lists happened to
  also contain "B52's", which folds exactly onto the typed query. Deezer only ever returned
  "The B-52's" and "B-52", so it had nothing to get in with.
- **FIX: the gate accepts hits relevant to the typed query OR to any name the caller ALSO searched
  under** (`mergeArtistHits`' new optional 4th arg; Browse passes MB's canonical name, and ONLY when
  the second pass actually ran). **This cannot admit an unrelated artist:** the extra query is MB's
  own name for the artist the typed query already resolved to, and every admitted row still faces
  the dead-end filter. The same test governs the `_exact` ranking flag, so a row named exactly as MB
  names the artist ranks with the typed-exact ones.
- **THE NEGATIVES ARE THE POINT, and this fixture proves it:** Tidal's answer to the canonical name
  is mostly free association — Talking Heads, DEVO, The Go-Go's, Missing Persons — i.e. exactly the
  junk 0.37.1's gate exists to reject, now arriving through a new door. All still rejected, as are
  **Kate Pierson** (a band MEMBER — a real artist, and not this one) and the near misses "B-52" and
  "The B-69s".
- **`tools/t_fuzzy.pl` 19 -> 26**, fixture verbatim from the `artist-search` log lines. Includes the
  PRE-FIX assertion (judged against "b52s" alone, the canonical hit is discarded — so the test
  demonstrates the mechanism rather than only the fix), that the surviving row lists BOTH services,
  and that omitting the extra query leaves the whole result list byte-identical.
- **A test bug of my own, caught and recorded because it is the THIRD time in this repo:**
  `ok(<expr> && @$old, 'name')` flattens the array into `ok`'s argument list and the test NAME
  becomes a hashref — the 0.43.5 list-context trap. `scalar()` restored, with the reason in-code.
- `dsc:asearch` **9 -> 10**: the cached merged list is precisely what this changes, and the 10-minute
  window is exactly when the fix gets tested. CACHE_VERSION 0.46.4 clears the namespace anyway.
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION OK; **155 assertions green**. `matcher_sync_check.py`
  reports drift on `_norm`/`%FOLD` ONLY — the pre-existing deliberate DSC divergence from 0.44.26,
  untouched here; every other shared sub IN SYNC. `mergeArtistHits` is DSC-only call-site logic (the
  0.44.24 precedent), so this adds nothing to the fleet port debt.
- **LIVE VERIFY AFTER INSTALL:** search `b52s` — the row must read **Local · Qobuz · Tidal · Deezer**,
  the same as `b-52s`.

### 0.46.3 (2026-07-22) — the empty "b52s" page: a missing canonical name, and a NAME as artist identity
- **Simon: *"a search for b52s returns an empty artist for Qobuz and Tidal"* / *"none of the searches
  seem consistent."*** Both reproduced live, and they are the same defect.
- **THE CHAIN, measured end to end** (`artist:"B52's"` vs `artist:"The B-52s"` on the live box):
  ```
  click row "B52's"     -> count 1   "No releases found"     <- the report
  click row "The B-52s" -> count 59  full discography        <- control
  ```
  Both resolve to the SAME mbid (127f591a) and BOTH read the same warm pools
  (`peekPool ... qobuz/tidal/deezer: HIT`). The difference is the NAME, because the browsed name is
  the artist identity the matcher gates on — and `_norm` turns a hyphen into a SPACE:
  ```
  _norm("B52's")      = 'b52s'        ONE token
  _norm("The B-52s")  = 'the b 52s'   library, MB and every service candidate
  ```
  `_artistMatch` is a token-subset test, so `{b52s}` is a subset of nothing, EVERY candidate was
  rejected, `hide_unmatched` hid all 80 release groups, and the page read "No releases found".
  Measured through the real subs, not reasoned: `_albumMatches` returns **0** for
  (`b52s`, Cosmic Thing, "The B-52s") and **1** for the control.
- **WHY THE ROW WORE A SERVICE SPELLING — the safety nets were both disabled by a missing cache
  value.** The fold's relabel-to-canonical (0.44.20) and the library attach (0.46.2) BOTH start at
  `peekArtistName($mbid)`, and for this artist it returned **undef while the alias list from the
  same response was intact**. Proven twice over, independently: the attach tried exactly ELEVEN
  names (the mirror's alias list, verbatim — canonical absent), and 0.45.2's second pass logged no
  `MB canonical name is ...` line for a query it demonstrably differs from.
- **The cause of the missing entry is NOT established, and the fix does not depend on a guess.** An
  ASCII canonical name written by the same sub reads back fine (verified live: *"relabelled 'British
  Sea Power' to MB canonical 'Sea Power'"*, on the cached path too). Rather than theorise, the code
  stops depending on that value surviving:
  1. **`warmArtistAliases` no longer early-returns on a cached alias list ALONE** — a list with no
     name is exactly the broken state, so it refetches to recover it.
  2. **The name is remembered in-process (`%mbNameMem`) as well as cached**, so a cache that keeps
     losing it costs ONE request per artist per plugin run, not one per render. `%nameRefetched`
     bounds it belt-and-braces.
  3. **A missing canonical name now LOGS** (`search rows: NO MB canonical name for <mbid>`). It had
     been a silent no-op, which is why a page could be empty with nothing in the log saying why —
     the same "mechanism correct but unreachable" pattern as 0.44.20 and 0.45.1.
- **A MEASUREMENT WORTH KEEPING: the library holds TWO contributors for this band** — 62125
  `The B-52s` (ALBUMARTIST on 3 albums) and 62136 `The B-52's` (a non-performance credit on one).
  0.44.18's `PERFORMANCE_ROLES` filter correctly returns only 62125, which is why `search:The B-52's`
  finds nothing role-filtered while `search:B-52s` finds the artist. **Not a bug — do not "fix" it.**
- **`tools/t_mbname.pl` (new, 15 assertions)**, fixture = the mirror's REAL record (canonical
  `The B‐52s` with U+2010, all eleven aliases). **Verified 4 RED against the pre-fix module and
  15/15 after**, and the four that fail are exactly the ones describing the bug: the refetch, the
  name being available after it, the bound on a cache that keeps losing it, and the memo answering.
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION OK; **148 assertions green** (t_norm 51, t_fuzzy 19,
  t_local 18, t_loose 15, t_mbname 15, t_mirror 14, t_canon 12, t_resolve 4). No matcher sub touched
  (`matcher_sync_check.py` unaffected); CACHE_VERSION 0.46.3 clears every namespace.
- **LIVE VERIFY AFTER INSTALL:** search `b52s`, `b-52s`, `b-52's` — each must return ONE row that
  opens a real discography (not "No releases found"), and the log must show either a `relabelled ...
  to MB canonical` or an `attached library artist ...` line rather than the new NO-canonical-name
  warning.

### 0.46.0 (2026-07-22) — ONE Local artist lookup for BOTH entry paths (the accented-name hole)
- **Simon asked for the audit that found this:** *"can we do a check now to see if we have applied
  changes to only one path ... the non ASCII latin character being an example as I thought we had
  fixed those but cropped up in this large sort test."* He was right on both counts.
- **AUDIT RESULT — measured live on 0.45.1, not inferred:**
  | Entry path | Björk | Röyksopp | The B‐52's | Sigur Rós |
  |---|---|---|---|---|
  | Browse by `artist_id` (Artists row) | 2 | 1 | 4 | 5 |
  | **Browse by NAME** (search drill, similar-artist, band link) | **0** | **0** | **0** | 5 |
  | **Search row sources** | no Local | no Local | no Local | Local |
  LMS itself finds all four either way (`artists search:` returns them), so the library was never
  the problem — and clicking the Artists row always worked, which is why this survived so long.
- **WHICH FIXES WERE ONE-PATH-ONLY:** the `&`/`and` retry (0.44.23) and the punctuation probe
  (0.44.26) were built into `searchArtists`' Local leg and **`localAlbums`' name fallback never got
  them**. So the "you do not own this artist" bug those releases fixed for SEARCH was still live on
  every by-name browse.
- **THE DEFECT: nothing ever tried the ASCII-FOLDED spelling.** LMS's index folds accents (verified
  live: `search:Bjork` returns Björk), but a **single-word** accented name has no second term for
  the 0.44.26 term probe to use, so there was no route back. Sigur Rós worked purely by luck — its
  longest term, "Sigur", is already ASCII.
- **FIX: `_localArtistRows`, one ladder used by BOTH call sites**, cheapest first, each step only on
  a total miss: as typed -> `&`/`and` variant -> **ASCII-folded spelling (new)** -> most-selective
  term probes. Recovery rows are norm-verified by the caller, so widening the net cannot adopt a
  wrong artist. This is the 0.44.18 lesson applied again: *"the defect was not the missing filter,
  it was the same policy spelled in two places that could drift"* — it had drifted again.
- **`localAlbums`' name fallback was also SILENT** — no debug line at all, which is why the sweep
  could see the symptom but no trace explained it. Both call sites now log.
- **A WRONG DIAGNOSIS OF MINE, CAUGHT BY ITS OWN CONTROL, and recorded because it matters:** I
  expected a SECOND defect — `_norm` folding on octets while the name arrives as characters (the
  0.43.3 `_nameKey` trap) — and wrote a control asserting the two disagree. **The control failed
  against correct code: they already agree**, because 0.44.26's `%FOLD` extension handles both
  shapes. `_normKey` therefore stays as explicit defensive intent, NOT as a fix, and the code
  comment says so. A wrong diagnosis left in the tests would send the next investigation somewhere
  there is no bug.
- **`tools/t_local.pl` (new, 14 assertions)**, driven through the REAL `_localArtistRows` with a
  stubbed LMS that records every query: the field case (Björk recovered via the fold), that the
  exact spelling is tried FIRST and wins alone when it works, the `&`/`and` recovery, the term probe
  running LAST, a genuine miss staying a miss, and the encoding control above.
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION OK; **129 assertions green** (t_norm 51, t_fuzzy 19,
  t_resolve 4, t_loose 15, t_mirror 14, t_canon 12, t_local 14).
- **LIVE VERIFY AFTER INSTALL:** browse **Björk / Röyksopp / The B‐52's BY NAME** (via search, or a
  similar-artist link) -> each must now show Local albums, matching what the Artists row gives; and
  searching those names must show **Local** among the row's sources.

### 0.45.2 (2026-07-22) — the SEARCH path gets the canonical-name fix too (it is a separate path)
- **Simon: *"still not resolving Qobuz ... When entering British Sea Power in to search, we need to
  ensure all fixes we do for matching are done across matching from the rows in Artists and via our
  search. It works fine from the row."*** Exactly right, and it names a structural rule this repo
  needed written down.
- **THERE ARE TWO INDEPENDENT MATCHING PATHS, and 0.45.0 only fixed one:**
  - **Artists row / browse** -> `_discographyView` -> `Sources::getCandidates` -> `_resolveArtist`
    (builds the candidate POOL and per-release matches). **Fixed in 0.45.0.**
  - **Plugin search** -> `_artistSearchView` -> `Sources::searchArtists` -> `mergeArtistHits`
    (builds the search ROW and its source labels). **Never touched** — it does not call
    `getCandidates` at all.
  Measured: `search "British Sea Power" -> 'Sea Power' [Local,Tidal,Deezer]` vs
  `search "Sea Power" -> [Local,Qobuz,Tidal,Deezer]`. Qobuz's artist-SEARCH leg returns nothing for
  the old name.
- **FIX: `_artistSearchView` resolves the TYPED query to an MB artist, and if MB's canonical name
  differs, runs the service legs again under it and unions the two result sets before ranking.**
  `mergeArtistHits` buckets by `_norm`, so a duplicate hit collapses into the same row rather than
  doubling it — this can only ever ADD services to a row. Bounded to ONE extra round, only when the
  name actually differs (the rename/alias case alone).
- **Ordering is right here, unlike the browse path:** `getArtistMbid` COMPLETES before
  `peekArtistName` is read, so the canonical name is guaranteed present rather than depending on a
  warm that runs later.
- **THROTTLE-GATED**, matching `filterRowsWithContent` (API.pm:808): one MB lookup per NEW search
  term is milliseconds on a mirror but 1.1s of etiquette delay on the public API, on every search a
  user types. Extra MB work runs only where MB is un-throttled — the plugin's established policy.
- A failure in EITHER pass marks the set incomplete, so 0.42.2's "never cache a degraded result"
  rule still holds. `dsc:asearch` **7 -> 8**, or the pre-fix merged rows would be served from the
  10-minute cache — which is precisely the window the fix gets tested in.
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION OK; 115 assertions green. **Live verify after
  install:** search "British Sea Power" -> the row must read **Local · Qobuz · Tidal · Deezer**, and
  "Sea Power" must return the same single row.

### 0.45.1 (2026-07-22) — every build now CLEARS ITS OWN CACHES + the "unparseable" mislabel
- **Simon: *"on all new builds whilst still in dev we clear the cache as its caught us out too many
  times now."*** He is right, and it was the direct cause of 0.45.0 looking broken. The canonical-name
  capture lives in `_artistMbidByName`, which **short-circuits on a cached `dsc:mbid` (30d)** — so for
  every artist visited before the upgrade the resolver never ran and the fix could not fire. It
  worked only for British Sea Power, because I had manually `clearcache`d that one artist while
  investigating. Same family as 0.44.3 (pools surviving a resolver change) and 0.44.20 (`dsc:alias`
  v1 keeping the canonical name from ever being fetched).
- **THE PLATFORM ALREADY DOES THIS — no key-by-key bumping needed.** Verified in LMS 9.1
  `Slim/Utils/Cache.pm`: `new($namespace, $version)` ends with *"empty existing cache if version
  number is different"* -> `$self->clear()`. All three modules now construct
  `Slim::Utils::Cache->new(CACHE_NS, CACHE_VERSION)` with `CACHE_NS => 'discography'`, so **bumping
  the plugin version wipes every Discography cache automatically**. Key enumeration was never
  possible (there is no delete-by-prefix), which is why this had been solved one key at a time.
- **`CACHE_VERSION` must be identical in all three modules**: `Cache::new` returns the EXISTING
  instance for a namespace and ignores later args, so whichever module loads first decides the
  version — a mismatch would silently leave stale caches behind, i.e. rebuild the exact bug this
  prevents. `tools/syntax_check.sh` now asserts the three agree AND match `install.xml`; **verified
  it FAILS on an induced mismatch**, not just passes when correct.
- **One-time effect:** the plugin moves out of LMS's shared `cache` namespace, so pre-0.45.1 `dsc:`
  entries are orphaned and expire on their own TTLs. That is itself the full purge we wanted.
- **`unparseable MB response` mislabel FIXED** (the one Simon asked after). `$@` is a GLOBAL and was
  re-read ~80 lines below the `eval` that set it, past `_mbSearchVerdict` (whose `_mbSearchProve` is
  itself an `eval`), `_dbg`, `_norm` and `_closeEnough`. Now captured into `$parseErr` AT the eval,
  and the message carries the real error text and the response length. **Proven not to be a real
  parse failure:** the exact URL this builds for "British Sea Power" returns valid JSON with
  `count=0` on BOTH mirror and public MB — correct, since MB knows that name only as an alias.
- **STILL OPEN — the SEARCH row understates its sources** (Simon: *"i am using search"*, and that is
  why we saw different things). Measured: `search "British Sea Power" -> row 'Sea Power'
  [Local,Tidal,Deezer]` vs `search "Sea Power" -> [Local,Qobuz,Tidal,Deezer]`. Qobuz's artist-SEARCH
  leg returns nothing for the old name. 0.45.0 fixed `getCandidates` (browse); `searchArtists` /
  `mergeArtistHits` is a SEPARATE path and was not touched. **The drill-in is correct** — all four
  entry paths (current id, stale id, name-only, by-mbid) render Qobuz 22/24 — so this is a LABEL
  defect, not a resolution one. Fix shape: after the fold resolves the MB artist, re-run the
  artist-search leg under MB's canonical name for services absent from the row, bounded to the top
  row so a search does not pay N rows x 3 services.
- **VERIFIED 0.45.0 DOES WORK on the browse path**, against the live box, all four entry shapes:
  `{Local:9, Qobuz:22, Tidal:22, Deezer:21}` where the sweep recorded `Qobuz: 0`.
- **A process note worth keeping: the library had been RESCANNED since the sweep**, moving British
  Sea Power from contributor id 45251 to 54133. I probed a hardcoded id I had not re-derived and got
  a different artist entirely (`Local: 0`), which briefly looked like a regression. **Re-derive ids
  after any rescan; never carry one across sessions.**
- Gates: `syntax_check.sh` 5/5 + CACHE_VERSION OK; 115 assertions green (t_norm 51, t_fuzzy 19,
  t_resolve 4, t_loose 15, t_mirror 14, t_canon 12).

### 0.45.0 (2026-07-22) — ask the services for MB's CANONICAL name (the renamed-artist hole)
- **Found by the full-library sweep, and Simon named the cause before I did** (*"its the arists
  original name, now changed to just Sea Power so its an alias. Services perhaps now all changed
  to show sea power."*). Measured live, cleared cache, reproducible:
  ```
  search "British Sea Power" (old) -> Qobuz ERROR / absent
  search "Sea Power"         (new) -> Qobuz PRESENT
  candidates Tidal/'British Sea Power':  32   e.g. Sea Power - Everything Was Forever
  candidates Deezer/'British Sea Power': 26   e.g. Sea Power - Disco Elysium
  candidates Qobuz/'British Sea Power':  <no pool>
  ```
  Tidal/Deezer absorb the old name and return the renamed catalogue — which still MATCHES because
  `_artistMatch` is a token-subset test and `{sea,power}` ⊆ `{british,sea,power}`. Qobuz does not,
  so the artist's entire Qobuz catalogue was missing (24/52 matched, 12 albums owned).
- **The plugin already held the answer and discarded it.** It resolved the MBID *through the alias
  field*, so MB's canonical name was in the response it had just paid for. Same
  "it was already in the response" pattern as 0.44.20.
- **THREE EDITS, all verified before writing a line (Simon: *"yes always check and verify before
  changing code"*):**
  1. `_artistMbidByName` caches the winner's `$a->{name}` under `_mbNameKey`. **Zero extra requests.**
  2. `warmBandMembers` does the same — **verified live** that `artist/<mbid>?inc=artist-rels`
     returns `name: 'Sea Power'`. This is the only FREE source for a **tag-resolved** artist, which
     never runs an MB search. `dsc:bands` **v1 -> v2**, because that sub early-returns on a cached
     band list and a v1 entry would keep the name from EVER being fetched — the 0.44.20
     "mechanism correct but unreachable" trap.
  3. Browse's `getCandidates` call site puts the canonical name at the FRONT of the alias list when
     it folds differently from the browsed name. **Purely additive**: `_resolveArtist` consults
     these only after the browsed name has already failed to corroborate, so nothing that resolves
     today can change. Reuses 0.43.6's retry rather than adding a mechanism — `$search` was already
     wired for all three adapters; the only missing ingredient was a non-empty `$aliases`.
- **Also fixed, two diagnostics that actively mislead** (both cost real time during the sweep):
  - `candidates <svc>: 'error (handler/timeout/renderer)'` is printed whenever the leg settles
    **undef** — which an UNRESOLVED artist does too (the `$spine && %$spine` branch). Proven from
    the ABBA trace: `Deezer: ... UNRESOLVED` immediately followed by that "error" line. Now reads
    *"no pool (artist unresolved, or handler/timeout/renderer error)"* — it must not claim a cause
    it cannot know.
  - The resolver logged `NO MATCH (...; cached 1d)` while `MBID_EMPTY_TTL` has been **3600 (1h)**
    since 0.23.1. Now derived from the constant, so it cannot rot again.
- **`ALIAS_TTL` hoisted** to the top constant block: it is now used by the resolver, which compiles
  BEFORE the alias section, and a `use constant` must be declared textually before first use.
  Caught by `tools/syntax_check.sh` — the gate paying for itself again.
- **A bug in my own first cut, caught before it compiled:** the capture referenced `$a`, but
  `my $a` lives INSIDE the candidate block and `$a` outside it is **sort's global** — silently
  undef, no strict error. Exactly the 0.44.18 shadowing trap. Fixed with a properly scoped
  `$canonName`.
- **`tools/t_canon.pl` (new, 12 assertions)** — the fixture is the REAL field case. Verified **3 RED
  against the pre-change code and 12/12 after**, so it tests the bug and not just the fix. Covers
  the alias path, that capture adds no request, that an ordinary artist's canonical name folds
  EQUAL (so nothing is added), and that a miss / sub-threshold hit caches no name — a name
  belonging to nobody would be worse than none.
- Gates: `syntax_check.sh` 5/5 OK; **115 assertions green** (t_norm 51, t_fuzzy 19, t_resolve 4,
  t_loose 15, t_mirror 14, t_canon 12). `matcher_sync_check.py` drift is `_norm`/`%FOLD` ONLY —
  the deliberate DSC-only divergence from 0.44.26, pre-existing and untouched here; every other
  shared sub reports IN SYNC.
- **LIVE VERIFY AFTER INSTALL:** browse **British Sea Power** -> Qobuz must now appear among the
  sources (it matched 0 of 52 before); control on **Pretenders** and **Radiohead** -> unchanged.
  Note the canonical name arrives from the RESOLVER immediately for a name-resolved artist, but on
  the SECOND load for a tag-resolved one (warmBandMembers sits later in the MB chain) — the same
  contract bands and emblems already have.

### (2026-07-21/22, tooling — no version bump) — FULL-LIBRARY SWEEP: 1104 artists driven through the live plugin
New `tools/library_sweep.py` + `tools/report_sweep.py` + `tools/README_SWEEP.md`. Drives the LIVE
plugin over `plex:9000` one artist at a time and records what a user would see. Nothing
re-implements the matcher — every verdict is the plugin's own output, which is why it found
things the unit suites cannot (the 0.44.25 lesson: textual sync proves the bytes agree, not
that they behave). Resumable; raw feeds + per-artist debug slices archived gzipped under
`sweep/`, so the analysis recomputes offline without re-running.

**Run:** 1104 album artists browsed + searched, 71 variant probes, ~3.5h. Config for the run:
`debug_log=1 hide_unmatched=0 show_streaming_extras=1 show_library_extras=1 show_types=all`.

**THREE METHOD TRAPS, each of which would have produced a confidently wrong report:**
1. **A first visit UNDERSTATES matches, badly.** With `hide_unmatched` off — which the sweep
   needs to see misses at all — `_discographyView` does NOT await the streaming warm (that
   await only fires when the pref is ON, 0.44.8). So a cold artist renders before its pool
   exists. Measured: 13th Floor Elevators first 2/42 vs second 12/42; Count Basie 25/112 vs
   33/112. **130 of 1104 artists were affected, hiding 905 releases**; worst was The Rolling
   Stones at +59. The harness now re-renders until the count stops rising (974 artists needed
   2 renders, 129 needed 3, 1 needed 4). The first run was scrapped 111 artists in.
2. **An unmatched row has three unrelated causes** and lumping them overstates the problem
   ~10x: `rival_loser` 738 (by design, 0.16.0, hidden in normal use), `no_pool` 59, `genuine`
   20341. Even "genuine" is NOT a defect count — it bundles releases the services genuinely do
   not sell with real misses, and the feed cannot tell them apart.
3. **Owned-album "failures" are mostly by design**: of 857 owned albums not attached to a tile,
   **790 are Appearances** (VA comps, guest spots — never expected to be tiles) and only **66
   are real** *Also in your library* gaps.

**HEADLINE (the honest numbers):**
| Measure | Value |
|---|---|
| Artists that failed outright | **0** of 1104 |
| Not identified on MusicBrainz | **2** (Debussy String Quartet, HouseCurve) |
| Real local-match gap | **66 of 3760 owned albums (1.8%)**, 57 artists |
| Search: artist not returned by own name | **0** (see correction below) |
| Search: artist returned but not first | **0** |
| Service coverage | Qobuz 42.7% · Tidal 42.9% · Deezer 42.5% · Local 6.6% |
| Service blackouts (one service 0, another >=3) | Qobuz 21 · Deezer 18 · Tidal 13 |
| Median render | 4.5s · slowest 22.2s (Tchaikovsky) |

**FINDINGS WORTH FIXING (diagnosed, NOT yet fixed):**
- **`API.pm:505` logs "cached 1d" but `MBID_EMPTY_TTL` is 3600 (1h).** The message predates
  0.23.1, which shortened exactly that TTL. A diagnostic that lies about cache lifetime is how
  the next investigation goes wrong — 0.23.1 was itself entirely about a poisoned miss-cache.
- **A legitimate empty MB result can be reported as "unparseable MB response".** `$@` is tested
  at API.pm:461 several statements after the `eval` at :384 that set it, with `_mbSearchVerdict`
  (which calls `_mbSearchProve`, itself an `eval`) in between. Capture the parse failure in a
  lexical AT the eval instead of re-reading `$@` later. Verified the responses themselves are
  fine: the exact URLs the plugin builds return valid JSON (`count=0`) on BOTH mirror and public,
  and 12 parallel requests all succeed — so the encoding is correct and the label is wrong.
- **The Local leg contributes nothing for some accented / non-ASCII-punctuation names.**
  `artist search 'Röyksopp': 6 merged from Deezer=3,Local=0,Qobuz=9,Tidal=15` while LMS's own
  `artists search:Röyksopp` returns the artist. Same for Björk, ROSALÍA, The B‐52's, The Go‐Go's,
  The La's, Yo‐Yo Ma (7 artists) — several of which carry U+2010 HYPHEN / U+2019 APOSTROPHE in
  the library name where the service spelling uses ASCII. NB **Lauryn Hill is NOT a bug**: it
  folds correctly into "Ms. Lauryn Hill" WITH Local.
- **ABBA: the studio album loses its candidate to a single.** `Super Trouper` (1980, ALBUMS)
  renders unmatched while `Super Trouper` (SINGLES) takes the candidate — the 0.16.0 rival-owner
  order putting a single ahead of the album. Also 3 `Ring Ring` verdicts in the log where the
  winner is not in the feed at all: the matcher runs over release groups that are never rendered
  (202 match calls for 75 rendered releases), so an invisible RG can claim a candidate the
  visible album then never gets. **This is the strongest single lead in the sweep.**
- **Variant/fold**: 71 probes, 1 lost entirely (`Pyotr Il'yich Tchaikovsky` -> `Pyotr Ilyich
  Tchaikovsky`), 5 lost their Local source on the plain spelling (The B‐52's, The Go‐Go's,
  The La's, The O'Jays, Rag'n'Bone Man) — the apostrophe cases 0.44.26 addressed, still live
  on the SEARCH path.
- **Performance**: the slowest renders are classical/orchestral (Tchaikovsky 22.2s for only 30
  releases) and correlate with DEBUG VOLUME (1233 debug lines) more than catalogue size — worth
  re-measuring with `debug_log` off before drawing conclusions (0.44.x finding #7).

**CORRECTION — the 3 "search failures" were ALL CORRECT ALIAS FOLDS, not defects** (Simon, on
British Sea Power: *"this one should not fail, its the arists original name, now changed to just
Sea Power so its an alias"* — he was right). Verified live: each returns ONE row under MB's
canonical name **carrying the Local source**, which is 0.44.20 relabelling working exactly as
designed:
`British Sea Power -> Sea Power [Local,Tidal,Deezer]` · `Vienna Philharmonic Orchestra ->
Wiener Philharmoniker [Local,Deezer]` · `Lauryn Hill -> Ms. Lauryn Hill [Local,Qobuz,Tidal,Deezer]`.
The harness compared row names LITERALLY, so a correct fold read as a miss. **True search failure
rate is 0 of 1104.** Lesson for any future sweep: a name-equality oracle cannot judge a feature
whose whole purpose is to return a DIFFERENT name.

**THE REAL BUG BEHIND THAT ARTIST — services are never asked under MB's canonical name.**
Measured live, same session, cleared cache, reproducible:
```
search "British Sea Power" (old name) -> Qobuz ERROR / absent
search "Sea Power"          (new name) -> Qobuz PRESENT
candidates Tidal/'British Sea Power':  32  e.g. Sea Power - Everything Was Forever
candidates Deezer/'British Sea Power': 26  e.g. Sea Power - Disco Elysium
candidates Qobuz/'British Sea Power':  error (handler/timeout/renderer)
```
Tidal/Deezer absorb the old name themselves and return the renamed catalogue (which still matches,
because `_artistMatch` is a token-subset test and `{sea,power}` ⊆ `{british,sea,power}`). Qobuz
does not. **The plugin already HOLDS the answer**: it resolved the MBID through the alias field
(`'British Sea Power' (alias) => 8830afec`), and 0.44.20 caches MB's canonical name under
`dsc:mbname`. It simply never uses that name to query the services. 0.43.6's alias retry cannot
help here: aliases are fetched only for AMBIGUOUS names, and this one logs `0 same-name`, so the
retry never arms. **Proposed fix (NOT built, needs Simon's OK): when MB's canonical name differs
from the browsed name, search the services under the canonical name too.** Cheap — the name is
already cached, no extra MB request.

**SERVICE BLACKOUTS — 42 artists (3.8%)** where one service matched nothing while another matched
>=3. Characterised, not just counted; three dominant shapes:
- **compound / collaboration names** — Charlie Parker & Dizzy Gillespie, Stan Getz / João Gilberto,
  Django Reinhardt & Jean Sablon, Ian Dury & The Blockheads, Booker T. & the MG's
- **classical composer/orchestra entities** — Rossini, Berlioz, Saint-Saëns, Israel Philharmonic,
  Columbia Symphony, Orchestre National de Lille (the service entity is the performer, MB's is the
  composer)
- **non-ASCII spellings** — Sinéad O'Connor (Qobuz dark), The Dø (Tidal dark)
Plus the rename case above. Errored candidate legs across the run: Deezer 35, Qobuz 30, Tidal 20.

**HARNESS BLIND SPOTS (do not read these as zeros):** the log miner only counts a service as
UNRESOLVED when the word appears on the *ambiguous* line, so section G reports 0 where ABBA
demonstrably has an unresolved Deezer; and the same-name section is a SEARCH-view feature, so
browse-phase `same_name=0` is expected, not evidence of absence.

### 0.44.28 (2026-07-21) — stop asking MusicBrainz a question that cannot match
Simon: *"If I search Janes Addiction in MB it finds it straight away top hit, I dont understand your last comment."* **He was right and I was wrong** — I had called this unfixable in 0.44.27's notes without testing the obvious alternative.

- **THE RESTRICTION WAS OURS, NOT MUSICBRAINZ'S.** The plugin sends an exact Lucene PHRASE. Measured against the mirror:
  ```
  artist:"janes addiction"   -> count 0       an exact phrase cannot match
  janes addiction            -> count 239     "Jane's Addiction", which
  artist:janes addiction     -> count 208     tokenises [jane][s][addiction]
  ```
  Jane's Addiction is the **top hit at score 100** in both unquoted forms — exactly what musicbrainz.org's own search box does.
- **FIX: the quoted query stays PRIMARY; an unquoted pass runs only after the quoted artist AND alias passes have both found nothing.** So it can only rescue a definite miss — no name that resolves today can change. Suppressed under `$speculative`, like the alias pass, or the dead-end row filter pays it on every row it exists to drop.
- **THE HAZARD, and why this is not just "drop the quotes":** Lucene normalises the best match to 100, so **the `>= 90` score gate is nearly a NO-OP on a loose query** — any unquoted search returning rows offers a >=90 top hit. Ungated, a nonsense query would adopt whatever came back and show the wrong discography, which is strictly WORSE than the honest miss it replaces. So the loose winner must also BE the artist asked for: either the 0.44.14 exact-name preference matched, or `_closeEnough` accepts it (the same tested typo gate the search rows use).
- **Verified end-to-end against the live mirror**, running the real three-step chain:
  ```
  Jane's Addiction         -> Jane’s Addiction        [artist quoted]    unchanged
  Janes Addiction          -> Jane’s Addiction        [alias quoted]     MB carries the alias
  sigor ros                -> Sigur Rós               [artist unquoted]  rescued
  flornce and the machine  -> Florence + the Machine  [artist unquoted]  rescued
  Bush                     -> Bush                    [artist quoted]    0.44.14 trap survives
  Beatles                  -> The Beatles             [artist quoted]    unchanged
  sogor / blue addiction   -> NO MATCH                                   correctly refused
  ```
  The two rescued names are **real queries from Simon's log** that each cost a wasted public round trip and resolved to nothing.
- **`getArtistCandidates` gets the same quoted-then-unquoted rule but NO closeness gate** — its `_nameKey eq $want` filter already demands the candidate's name normalise equal to the query, which is stricter than anything the loose top-hit gate can apply.
- **Cache reasoning:** `dsc:acand` 6 → **7**, because an empty same-name set cached under the quoted-only regime would pin the fix out for **14 days**. `dsc:mbid` is deliberately NOT bumped: its negative entries expire in 1h (self-healing), while bumping `MBID_CACHE_V` would discard every 30-day POSITIVE mbid and force a full re-resolve — punishing precisely the public-API users this costs most.
- **`tools/t_loose.pl` (new, 15 assertions)** — fixtures are real measured MB top hits, not invented. Covers the fix, the typo rescues, the hazard (`blue addiction`/`addiction`/`machine`/`the` must all be refused), the Kate Bush trap in BOTH directions, and the short-name guard that stops `abba`/`muse` being fuzzed.
- **A `perl -c`-invisible bug caught in passing:** replacing the `$query` string with a `$mkQ` builder left the URL line still referencing `$query`. `use strict` does not catch it (both are lexicals in scope) — a grep for the old name did.

### 0.44.27 (2026-07-21) — a healthy mirror stops paying for musicbrainz.org
Simon, reading the 0.44.26 diagnosis: *"Why is this using throttled we are using local MB instance?"* — and he was right to ask.

- **The mirror WAS being used, and is healthy** (verified live: Solr `count:3063`, `Jane's Addiction` at score 100, browses fine). The public traffic came from the **mirror → public retry** firing on legitimately-empty searches.
- **ROOT CAUSE — the heuristic could not tell two different zeros apart.** The retry (0.44.x, field 2026-07-10) treats a zero-result mirror search as a probable unbuilt Solr index. That failure mode is real. But zero is ALSO the correct answer to a query matching nothing, and the plugin sends an **exact Lucene phrase**:
  ```
  artist:"janes addiction"   -> count 0    "Jane's Addiction" tokenises as
  artist:"jane's addiction"  -> count 1    [jane][s][addiction], so the phrase
  artist:"sigur ros"         -> count 1    cannot match. Solr folds accents but
  artist:"florence and the machine" -> 0   NOT the apostrophe — same root cause
                                           as the reported bug, one layer out.
  ```
  So **every legitimately-empty lookup silently cost an internet round trip**: 6 in a single log window (`florence and the machine` ×2, `flornce and the machine`, `janes addiction`, `sigor ros`, `sogor`) — and note **three are plain typos**, which take the same expensive route.
- **FIX: one non-empty mirror result PROVES the Solr index is built.** From then on a 0 is a real 0 and the public retry is skipped. No probe request, no config, self-healing. Keyed BY BASE (repointing re-proves rather than inheriting a clean bill of health) and TTL'd at 7d (a mirror that later breaks is retested). A genuinely unbuilt mirror never sets the flag, so the original protection is untouched.
- **Both call sites now share `_mbSearchVerdict($arts, $mirror, $isFb)`** rather than repeating the condition — they cannot drift, and the decision is testable without HTTP. The **error** branches (mirror unreachable) are deliberately NOT gated: a dead mirror still needs the public fallback.
- **CORRECTION to my own 0.44.26 note:** I described this as our 1.1s courtesy throttle. It is not. `_mbGap` only spaces *paginated* fetches and reads the CONFIGURED base — the mirror — so it returns 0 and the fallback request is not rate-limited by us at all. The ~2.2s observed is plain internet latency to musicbrainz.org versus milliseconds locally. Real waste, wrong mechanism.
- **`tools/t_mirror.pl` (new, 14 assertions)** — stubbed cache/prefs, no HTTP. Covers the unproven case still retrying (the protection), proving via a normal lookup, the fix itself, base-keying, and two traps worth naming: an **empty result must never prove the index** (it would set the flag on exactly the case it gates) and an **unparseable response is not a proven zero**.

### 0.44.26 (2026-07-21) — an apostrophe ELIDES, and every accented letter reaches the key as ASCII
Field report: "Janes Addiction" found nothing local, for a band that is in the library as "Jane's Addiction".

- **TWO defects, one symptom, and fixing either alone leaves the bug standing.**
  1. **`_norm` SPACED the apostrophe** instead of eliding it, keying `"Jane's Addiction"` as `jane s addiction` against `janes addiction`. `_artistMatch` is an exact-token SUBSET test, so the token `janes` matched nothing. Same for O'Connor/OConnor, D'Angelo, The B-52's.
     - **SCOPE, corrected by Simon from the field and then verified — the STREAMING rows were fine; only Local failed.** I first wrote that this broke matching against every source. It does not, and the log says so plainly: `artist search 'janes addiction': 2 merged from Deezer=2,Local=0,Qobuz=2,Tidal=15`. Replaying `mergeArtistHits`' relevance gate against the SHIPPED `_norm` shows why: substring `n`, token subset `n`, **fuzzy `Y`** — the streaming rows were rescued solely by `_closeEnough`, i.e. 0.44.24's typo tolerance absorbing the one-character `jane s` / `janes` difference. Local had nothing to rescue because the DB returned zero rows. **The lesson: 0.44.24 was already masking this defect on three of four sources**, which is exactly why it presented as a library-only bug.
  2. **The Local leg queries LMS directly with the user's raw text**, so `_norm` never reaches it — and `_norm` cannot match a row the database never returned. Fixing the fold alone would still have shown no Local source.
- **Measured LMS's search semantics rather than assuming them** (live, `artists search:`): terms are **ANDed** and each matches at a **TOKEN START** (`Jane Addiction` hits, `ane` does not), and the index **TOKENISES on the apostrophe** (`search:Connor` returns "Sinead O'Connor"; `search:s Addiction` returns "Jane's Addiction"). Eliding is therefore the choice that agrees with LMS's own index. The recovery probes with the most selective TERM alone and lets `_norm` filter the rows — the DB widens the net, the normaliser closes it. Bounded at `PUNCT_PROBE_MAX` (2) extra sync queries, **only on a total miss**; a correctly typed query pays nothing.
- **GUARDED THE GUARD, and it mattered:** `'n'` contracting "and" joins two WORDS rather than sitting inside one, so a blind elide would have keyed `Rock'n'Roll` as `rocknroll` while `Rock 'n' Roll` stayed `rock n roll`. All three spellings agreed BEFORE this change; one line spacing that form first keeps the agreement. Locked in by test.
- **ACCENTS — "any accented characters need to pass" (Simon).** The two `_norm` failures visible in the working output were a **test-fixture artefact**, not a defect: a bare `"Sigur R\x{f3}s"` literal is unflagged latin-1, which is not how a name ever arrives. Proved by re-testing in both real shapes (UTF-8 octets from the LMS DB, flagged strings from JSON) — all pass. Verified live that LMS's own index folds accents too (`search:Bjork` → Björk, `search:Beyonce` → Beyoncé), so the Local leg needs nothing extra. `Motörhead` returning 0 for BOTH spellings was the control: not in the library.
- **But the sweep found a real gap next door.** NFD strips COMBINING MARKS, which is why every true accent already folded with no table at all. It cannot decompose a letter whose mark is part of the glyph — a **stroke** (ø đ ł ŧ ƀ), a **hook** (ɓ ɗ ƙ) or a **ligature** (æ œ ĳ ǉ) — and those reached the key non-ASCII, i.e. unfindable typed plain. Sweeping U+00C0–U+024F: **130 letters survived non-ASCII before, 26 after** extending `%FOLD` from 10 to ~90 entries. The 26 left are click consonants, glottal stops and tone letters with no sensible ASCII base — deliberately unmapped, because guessing a base is worse than not folding.
- **Cache bumps:** `dsc:acand` 5 → **6** (keyed BY `_norm`, so a mark-bearing name's key now collides with what v5 stored for the mark-less spelling — the exact reason as the v2 → v3 bump) and `dsc:asearch` 6 → **7**. `dsc:cand` is version-scoped and self-invalidates. `dsc:alias`/`dsc:mbname` are mbid-keyed raw MB data and are untouched.
- **Verification:** 74 standalone assertions (t_norm 25 → **51**, t_fuzzy 19, t_resolve 4) + `syntax_check` 5/5. Old-vs-new `_norm` diffed over a 42-name corpus: **exactly 6 changed, every one an apostrophe case**, with `rock'n'roll`, `$uicideboy$`, `!!!`, `P!nk` and the over-merge guards all unmoved — the `%FOLD` extension is purely additive. The Local recovery was then simulated against the **live library**: "Janes Addiction" → probe `Addiction` → recovered; "Sinead OConnor" → probe `OConnor` (0) → `Sinead` → recovered "Sinéad O’Connor".
- **KNOWN LIMIT:** a single-word name whose only mark is internal ("D'Angelo" typed "Dangelo") has no second term to probe with, so the Local row is not recovered. `_norm` still matches it on the streaming side.
- **DSC-ONLY DRIFT, deliberately** (`_norm` + `%FOLD` are fleet-synced): held here pending field proof, same as 0.44.19–0.44.24 were. `matcher_sync_check.py` reports drift BY DESIGN until ported.

### 0.44.25 (2026-07-21) — FLEET PORT, and the port found a bug 0.44.24 shipped
- **The `_norm` changes are now in all four sync repos** (DSC / LBF / PFR / SH — LBF 0.9.120, PFR 0.7.8, SH 0.12.1); **`matcher_sync_check.py` exits 0**. LL is untouched: the script pins its `_norm` as the legacy ASCII variant, which carries none of these substitutions.
- **THE PORT CAUGHT A REAL BUG IN 0.44.24, and the sync check could never have found it.** Extracting all four copies and running them side by side over 21 names showed:
  ```
  '$uicideboy$'  ->  suicideboy      (0.44.24)   vs   suicideboys  (correct)
  ```
  0.44.19 scoped the boundary rule to `$` and `@` as well as `!`, but a TRAILING `$` is genuinely the letter *s* — `$uicideboy$` is Suicideboy**s**, a case PFR's own `_norm` comment names as supported. **`$` and `@` are now unconditional again; only `!` is boundary-scoped**, because `!` is the one with a real decorative use ("Wham!", "Panic!", "Godspeed You!") while the other two are effectively always letters.
  - **The sync check compares TEXT, so it would have reported four identical copies of the bug.** Textual sync proves the bytes agree, not that they behave. A behavioural harness across the repos is the thing that catches a fleet-wide wrong answer, and it is worth keeping that distinction in mind whenever the check goes green.
- **Aligned to the both-sides rule `s/(?<=\w)!(?=\w)/i/g`** — which is what Search Hub's CLAUDE.md had specified as the intended fleet implementation all along. Better than 0.44.19's lookahead-only form for a LEADING mark: "!Attention" now yields `attention` rather than `iattention`.
- **Two deliberate deviations from that documented sketch, both recorded in SH's CLAUDE.md:**
  1. `$`/`@` stay unconditional (the regression above).
  2. **`!!!` keeps `iii` and does NOT fall back to `punctNorm`.** The sketch accepted that fallback; the matcher cannot live with it, because `_artistMatch` returns 0 when either side is empty, so an emptied name rejects every candidate — this same bug in a new costume.
- **`dsc:acand:4` -> `5`, `dsc:asearch:5` -> `6`.** Most keys are unchanged (only names containing `$`, `@` or a leading `!` move), so this is deliberately cautious rather than forced: a moved key can land on an entry a DIFFERENT artist wrote under the old rule, and one MB request per name per fortnight is a cheap premium against serving the wrong candidate set.
- **`tools/t_norm.pl` -> 25 assertions**, adding `$uicideboy$` -> `suicideboys` and `WOR$T` -> `worst` so this regression cannot return.
- Gates: `zsh tools/syntax_check.sh` 5/5 OK; `t_norm.pl` 25/25; `t_fuzzy.pl` 19/19; `t_resolve.pl` 4/4; SH `check.sh` 61/61; cross-repo harness **21 identical, 0 divergent**; `matcher_sync_check.py` **exit 0**.

### 0.44.24 (2026-07-21) — typo tolerance: stop throwing away the correction the services already made
- **Simon typed "Layo & Bushwaka" — one letter out — and got NOTHING.** The damning part is in the log: Qobuz, Tidal AND Deezer had ALL returned "Layo & Bushwacka!" for that misspelling. **17 hits went in, 1 came out**, and that one was a vague "Layo" with 0 release groups which the dead-end filter then correctly dropped. The search was strictly WORSE than the services it queries. Simon: "from a user perspective this is broken" — he was right, and it took several exchanges before I stopped defending the gate and measured it.
- **`_closeEnough`: a normalised edit-similarity fallback**, tried ONLY after the three existing tests (exact key / substring / token-subset) have all failed. **Purely additive — it cannot reject anything that passes today.**
- **THRESHOLDS MEASURED AGAINST THE REAL LOGGED HITS, not invented.** Recomputed with the CURRENT `_norm` (my first pass used a Python approximation of the OLD one, before the `!` and `&` changes — worth stating, because the numbers moved):
  - lowest wanted-KEEP **0.944** (`layo and bushwaka` -> `layo and bushwacka`)
  - highest wanted-DROP **0.545** (`the beatles` -> `beatless` / `the monkees`)
  - `FUZZY_MIN_SIM = 0.85` sits far clear of the junk in both directions.
- **THE LENGTH FLOOR (`FUZZY_MIN_LEN = 8`) IS LOAD BEARING, not decoration.** On short names one edit is a DIFFERENT WORD: "eagles"/"beagles" scores **0.857** and "slayer"/"player" **0.833** — both ABOVE the ratio threshold, and only the floor excludes them. Accepted cost: a real short typo like "nirvna" is not caught. No result beats a confidently wrong one.
- **NOT the entity folding declined on 2026-07-17, and the distinction is the whole point.** That decision rejected MERGING two service entities on string similarity ("Beatles" + "The Beatles") because a name cannot prove two entities are one act. Nothing here merges anything — bucketing is still EXACT `_norm` equality. This only decides whether a hit the service returned is relevant to what the USER TYPED: a query/result question, not an identity claim, and every admitted row still faces the dead-end filter.
- **NOT fleet drift.** `mergeArtistHits`, `_closeEnough` and `_editDistance` are DSC-only call-site logic (sibling of the 0.24.0 Local-gate exception); no shared matcher sub was touched, so this adds nothing to the `_norm` port debt.
- **`tools/t_fuzzy.pl` (new, 19 assertions) — the fixture is REAL**, every candidate list copied verbatim from the `artist-search` log lines, junk included. Inventing plausible hits would prove nothing about the junk we must exclude. **Verified 4 RED without the gate line and 19/19 with it**, and every NEGATIVE assertion passes in BOTH states — which is what proves the rule admits typos without loosening the 0.37.1 junk filter (Led Zeppelin / Pink Floyd / The Monkees for "The Beatles" all still rejected).
- **A test bug caught, and recorded because the distinction is genuinely useful:** my "Beagles must not be admitted for Eagles" assertion failed against CORRECT code. `beagles` CONTAINS `eagles`, so the 0.37.1 SUBSTRING rule takes it — the documented prefix-superset behaviour ("Beatless" for "beatles"), nothing to do with fuzzy matching, which declines the pair on the length floor. Both facts are now asserted explicitly.
- **I reproduced the 0.44.18 `sort`-shadowing bug in my own validation harness** (`sub lev { my ($a,$b) = @_; ... sort { $a <=> $b } ... }`), which produced negative similarities and a "NOT SEPARABLE" verdict. Caught because the numbers were absurd. `_editDistance` takes `$s1/$s2` and computes its minimum explicitly, with the reason in-code.
- `dsc:asearch:4` -> **5**: the gate decides what goes in that cached merged list, so entries written before this change hold pre-fuzzy results.
- Gates: `zsh tools/syntax_check.sh` 5/5 OK; `t_norm.pl` 23/23; `t_resolve.pl` 4/4; `t_fuzzy.pl` 19/19.
- **Live verify after install:** search "Layo & Bushwaka" (one letter out) -> the band; "Led Zepplin" -> Led Zeppelin; and "The Beatles" must STILL not list Led Zeppelin or The Monkees.

### 0.44.23 (2026-07-21) — "&" and "+" are spoken "and" (and LMS's own search is asked both ways)
- **Closes the gap 0.44.22 deliberately left:** searching with "and" silently LOST the Local source. `Simon and Garfunkel` showed `Qobuz · Tidal · Deezer` while `Simon & Garfunkel` showed `Local · …` — the user owns the albums and is not told.
- **TWO fixes, because there are two independent failures.** Worth stating plainly: `_norm` alone does NOT fix the Local row, and I checked before assuming it would.
  1. **`_norm`: `&` and `+` -> "and".** The same rule as every substitution above it — a symbol folded to the word it stands for, exactly like `$ -> s` and `! -> i`. Without it "&" merely became a space, so `simon garfunkel` and `simon and garfunkel` keyed differently and the SAME act arriving from two services became TWO rows, merging only if MB happened to record the variant as an alias. Field: Deezer says "Layo and bushwacka!" where Tidal says "Layo & Bushwacka". `+` is included because services use it identically — MB's own alias list for that duo carries "Layo + Bushwacka!".
  2. **The LOCAL leg asks LMS both ways.** `_norm` could never have fixed this: that leg queries the LMS database DIRECTLY with the raw typed text, so our fold never reaches it. **Verified live before writing the code:** `artists search:Simon and Garfunkel` -> **0**, `search:Simon & Garfunkel` -> **1**. It now retries the other spelling when the first finds nothing — one extra sync DB query, only on a miss, only on a query the user typed.
- **Caches bumped to `dsc:acand:4` / `dsc:asearch:4`.** `_norm` feeds both keys, and — as with the 0.44.19 bump — the new key for an "&" name is the OLD key of the "and" spelling, so a stale entry would be served for a query it was never computed for.
- **`t_norm.pl` grown to 23 assertions, and the OVER-MERGE guards matter as much as the fixes:** `Simon & Garfunkel` != `Garfunkel & Oates`, and `Layo & Bushwacka!` != `Bushwacka!` (the solo project must stay its own act — it is a real separate MB artist with 56 release groups). Verified to go **10 RED** against the pre-change module and 23/23 after.
- Gates: `zsh tools/syntax_check.sh` 5/5 OK; `t_norm.pl` 23/23; `t_resolve.pl` 4/4. Still DSC-ONLY drift on `_norm` (see 0.44.19) — now two behaviour changes to port when the fleet catches up.
- **Live verify after install:** `Simon and Garfunkel` must show **Local** among its sources, and must return the SAME single row as `Simon & Garfunkel`.

### 0.44.22 (2026-07-21) — reach an artist MB only knows by ALIAS, and stop service annotations killing the query
- **Field (Simon): "Hall and Oates" returned NOTHING.** Not an `and`/`&` problem — MB handles that itself (`artist:"Daryl Hall and John Oates"` scores **100**). We never asked it properly. All five service rows were dropped:
  | service row | `artist:` | `alias:` | cause |
  |---|---|---|---|
  | `Daryl Hall and John Oates (Hall and Oates)` | NONE | — | the PARENTHETICAL |
  | `Darryl Hall and John Oates` (service typo) | NONE | **100** | alias retry suppressed |
  | `Hall And Oates` | empty MB stub, rgcount=0 | **100** | resolves, so no retry |
  | `Hall&Oates` | NONE | NONE | genuinely unresolvable |
- **(A) Speculative mode now gets the ALIAS FIELD when un-throttled.** 0.44.15 suppressed it for bulk row guesses, but the measured cost that justified that was **61 requests to musicbrainz.org** — the PUBLIC-API cascade (mirror miss -> public retry -> alias -> another public retry), not the alias field itself. Against a mirror it is one more query worth milliseconds, and `filterRowsWithContent` — the ONLY speculative caller — already refuses to run when `mbGap` is non-zero, so it can never fire against the public API however it is reached. Gated `!$speculative || !_mbGap(1.1)` rather than on the caller, so the guarantee holds structurally. **MB's alias index even absorbs the service's own typo:** `alias:"Darryl Hall and John Oates"` (double-r) returns the band at 100.
- **(B) Service ANNOTATIONS are stripped from the MB query.** Catalogues append a parenthetical the artist is not called — "Daryl Hall and John Oates (Hall and Oates)", "Anthrax (US)", "!!! (Chk Chk Chk)" — while MusicBrainz keeps that out of the name entirely (it has a separate disambiguation field).
  - **UNCONDITIONAL, and that is safe because the unstripped query is ALREADY broken:** parentheses are Lucene syntax and survive our percent-encoding, so MB returns ZERO even inside a quoted phrase. Verified on two unrelated names — `artist:"(Sandy) Alex G"` and the Hall & Oates row both return nothing. There is no working resolution to regress, only a failing one to rescue.
  - **Query only** — the cache key keeps the caller's spelling, so each service spelling caches its own entry pointing at the same mbid. The `>= 90` gate and exact-name preference still apply, and `_norm` strips brackets too, so the preference compares like for like (asserted: `_norm(original)` == `_norm(stripped)` for both cases).
- **Together they compound into the right answer:** two rows now resolve to the real band, which means they FOLD (same mbid + real alias) and 0.44.20 labels the survivor **"Daryl Hall & John Oates"**.
- **`and` vs `&` — the answer to Simon's actual question: it was never the issue.** MB folds it natively. Measured spread before touching anything: "Simon and Garfunkel" and "Above and Beyond" already worked; "Hall and Oates" failed for the unrelated reasons above. **STILL OPEN (deliberately):** searching with "and" loses the LOCAL row, because LMS's own `artists search:` does not fold `&`/`and` — you can own the albums and not be told. That needs `_norm` mapping `&` <-> `and` (more drift on the already-drifted sub) and is NOT in this build.
- Gates: `zsh tools/syntax_check.sh` 5/5 OK; `t_norm.pl` 15/15; `t_resolve.pl` 4/4.
- **Live verify after install:** search "Hall and Oates" -> expect ONE row reading "Daryl Hall & John Oates" that opens a real discography.

### 0.44.21 (2026-07-21) — DIAGNOSTIC build: name the albums the foreign-artist filter drops, list small pools in full
- **Field (Simon): Layo & Bushwacka's page is "missing a lot" of releases.** Measured — MB has 5 plain Albums and the page shows 2: **Low Life** (1999), **All Night Long** (2003), **Feels Closer** (2006) and **The Raw Road** (2009) are all `NO MATCH` against a pool of `Deezer=7, Qobuz=11, Tidal=12`.
- **PRIME SUSPECT, not yet proven: the 0.44.2 same-name rule eating the duo's own records.** `Tidal/3566402: dropped 8 album(s)` — 40% of what TIDAL returned. `_filterForeignArtist` forgives a differing artist id only when the credit CONTAINS the artist and is not merely EQUAL to it, because an exactly-equal credit under another id is the Madness case (a DIFFERENT act sharing the name). But a service routinely files ONE act under SEVERAL ids, and for a duo that is likely — those albums are credited "Layo & Bushwacka", exactly equal, so the Madness defence drops them.
- **NOT SHIPPING A FIX ON A HUNCH.** Two hypotheses produce the identical screen and the log cannot currently separate them: (a) the album was FETCHED and dropped by the filter, or (b) it is IN the pool and failing `_albumMatches` on the title (a service edition suffix). This build adds the evidence for both, and nothing else.
  - **Dropped albums are now NAMED** — title + credit + artist id, capped at 8. A count cannot answer "was this record ever returned?", which is the only question that matters here. Exactly the 0.44.17 lesson (artist-search name list) applied to the filter.
  - **A pool of <= `POOL_LOG_MAX` (25) is logged IN FULL** rather than three examples, so "is it in the pool?" is answerable directly. Big pools stay sampled — one render already writes ~100 match lines and `log.txt` tails.
- **`_filterForeignArtist` refactored to a single-pass PARTITION** so the dropped set is the exact complement of the kept set by construction. The first cut derived it by matching ref addresses, which is precisely how a diagnostic drifts away from the decision it claims to explain. **Behaviour proven unchanged: 6/6 assertions** through the real sub (foreign id dropped, no-artist-id kept, TIDAL id-space disengage, collaboration kept, same-name-different-id dropped, `artists[]` credit array).
- Gates: `zsh tools/syntax_check.sh` 5/5 OK; `t_norm.pl` 15/15; `t_resolve.pl` 4/4; filter suite 6/6.
- **NEXT:** install, open Layo & Bushwacka, then `curl 'http://plex:9000/log.txt?lines=3000' | grep -iE "dropped|ALL:"`. If the four albums appear in the dropped list, the fix is to recognise a service's SECOND id for the same act (candidate signal: the id also appears on albums the MB spine corroborates). If they are in the pool, it is a title-matching problem and a different fix entirely.

### 0.44.20 (2026-07-21) — a folded search row is labelled with MusicBrainz's CANONICAL name
- **Simon: "if a user uses and instead of & it shows Layo and Bushwacka ... A search in MB using either gets Layo & Bushwacka as top hit. Its also another alias."** Correct on every point, and measured before changing anything: MB resolves `artist:"Layo and Bushwacka"` to b7ba42de at **score 100**, and its alias list carries both `Layo And Bushwacka` and `Layo and Bushwacka!`.
- **The fold was WORKING — the LABEL was the bug.** The search returned ONE correctly merged row (`Deezer · Qobuz · Tidal`); it just wore Deezer's lowercase spelling. The survivor is picked by merge rank, which depends on the QUERY, so the same band was labelled differently depending on what was typed. Both spellings appear in the log, in both directions:
  `folded 'Layo and bushwacka!' into 'Layo & Bushwacka!'` and, on another query, **the exact reverse**.
- **Fix: after folding, relabel the survivor with MB's canonical name.** A folded row has already been PROVEN to be that MB artist (grouped by resolved mbid, gated on a real alias), so no inference is involved — and neither service spelling is authoritative while MB's is. The row now reads the same however it was reached.
- **FREE: the canonical name was already in the response we fetch.** `warmArtistAliases` uses `$d->{name}` to keep the canonical spelling OUT of the alias list, then threw it away; it is now cached alongside (`dsc:mbname:1:<mbid>`, new `peekArtistName`). No extra request.
- **ORDERING IS LOAD BEARING — a bug I wrote and caught before it shipped.** My first cut relabelled BEFORE the alias gate. Because `warmArtistAliases` deliberately omits the canonical name from the alias list, renaming the survivor to canonical can make `$alias{$b}` FALSE and block the very fold it is tidying up (rows "Canon" + "Some Alias" would stop merging). Moved strictly after the fold loop, gated on something having actually folded, with the reason recorded in-code so it is not "simplified" back.
- **`dsc:alias:1` -> `2`, and this one is not optional:** `warmArtistAliases` early-returns on a cached alias list, so a v1 entry would keep the canonical name from EVER being fetched and the relabel would silently never fire — the exact "mechanism correct but unreachable" pattern this log keeps recording. Bumping repopulates both from one request.
- **KNOWN LIMIT (deliberate):** only FOLDED groups are relabelled, because only they fetch aliases. A lone row keeps its service spelling rather than pay an MB request per search row — the cost this design has always avoided.
- Gates: `zsh tools/syntax_check.sh` 5/5 OK; `tools/t_norm.pl` 15/15; `tools/t_resolve.pl` 4/4. Live re-verify after install: search "Layo and Bushwacka" and "Layo & Bushwacka" — BOTH must return a single row reading **Layo & Bushwacka!**.

### 0.44.19 (2026-07-21) — a DECORATIVE "!" is punctuation, not the letter i (DSC-ONLY, deliberate fleet drift)
- **Simon, and he was right while I kept looking elsewhere: "I cant search for Panic at the disco without having ! in the name ... The search is now too restrictive to 100% accurate spelling including special characters. From a user perspective this is broken."** Then, decisively: **"No releases found on searching for it which is not true as there is an album in Tidal."**
- **ONE root cause behind every symptom he reported, and the third one is serious.** `_norm` folded EVERY `!` to `i`, so a name spelled WITH the mark did not match the same name spelled WITHOUT it:
  1. **Search needed the exact punctuation** — `panici at the disco` defeats the relevance gate's substring and token tests.
  2. **The same-name fold picked a different survivor per query** — the two spellings keyed differently. Proven in the log: `folded 'Layo & Bushwacka!' into 'Layo & Bushwacka'` on one query and **the exact reverse** on another.
  3. **THE BIG ONE — "No releases found" on a real artist.** `_albumMatches`' artist gate is MANDATORY. Browsing "Layo & Bushwacka" (no mark) normalises to `layo bushwacka` while every streaming candidate is credited "Layo & Bushwacka!" -> `layo bushwackai`, so **EVERY candidate was rejected**, nothing matched, and `hide_unmatched` hid the lot. Measured live: the SAME artist renders 23 items entered as "Layo & Bushwacka!" and an EMPTY PAGE as "Layo & Bushwacka" — `topLevel` log shows **both names resolving to the same mbid b7ba42de**, so it was never resolution, never the type filter (MB has 5 plain Albums), never the spine.
- **THE RULE: substitute only when a word character FOLLOWS the mark.** That is exactly what separates a letter from decoration — "P!nk"/"Ke$ha" carry the mark INSIDE the word, while a trailing or free-standing mark is punctuation and falls through to the existing `[^\p{Alnum}]` rule. Applied to `!`, `$` and `@` (the leetspeak class); the currency signs are left alone as a different class.
- **GUARD THE GUARD:** a name made entirely of these marks (**"!!!"**, a real band) keeps the OLD unconditional fold. Stripping would leave `''`, and `_artistMatch` **returns 0 if either side is empty** (Sources.pm:1737) — i.e. the same bug in a new costume, rejecting every candidate. Verified: `!!!` still normalises to `iii`.
- **Caches bumped for a COLLISION, not merely a change:** `dsc:acand:2` -> **3** and `dsc:asearch:2` -> **3**. The new key for a mark-bearing name is now the OLD key of the mark-less spelling, so a stale entry would be served for a query it was never computed for — and it holds a NARROWER set, computed when the two were considered different names. Identical reasoning to the 0.43.3 v1->v2 bump. Candidate pools need no manual bump (0.44.3 version-scoping does it).
- **DSC-ONLY, DELIBERATE DRIFT — Simon: "only disc for now we need to make sure it all works properly before patching all others."** `_norm` is fleet-synced, so **`matcher_sync_check.py` now reports drift on `_norm` BY DESIGN** until this is ported to LBF/PFR/LL/Search Hub (the line is at LBF Browse.pm:5436, PFR Browse.pm:1201, SearchHub Text.pm:56; LL's lenient variant did not match the grep — check it rather than assume). **Verified the drift is exactly one sub:** a diff of every non-comment change shows the three substitution lines inside `_norm` and nothing else — `_artistMatch`/`_albumMatches`/`_stripFmt`/`_asciiNorm`/`_punctNorm` are byte-identical, so the port is one isolated block.
- **`tools/t_norm.pl` (new), and it EARNS its place: 5 RED before the change, 15/15 green after.** The controls pass in BOTH directions, which is what proves the change is surgical rather than merely permissive — P!nk/Ke$ha/M@ss still fold, and Bush vs Kate Bush, Iron Maiden vs The Iron Maidens, Beatles vs Beatless all stay distinct.
- **A fixture bug in my own test, caught by the 0.43.3 note and worth repeating:** the accent assertion failed against CORRECT code because `"Sigur R" . chr(0xF3) . "s"` is a single UNFLAGGED byte — not valid UTF-8 and not what any real caller passes. Confirmed by running the same fixture against the PRE-change code, which produced the identical mojibake. Now asserted in both real shapes (utf8-upgraded string as MB JSON gives, and encoded octets as a CLI param gives) plus their agreement.
- **STILL NOT FIXED, and deliberately separate: genuine TYPOS.** "Bushwaka" (missing c) is not a punctuation variant and `_norm` will never fix it. Measured from the live log, the services' own search CORRECTS such typos — Qobuz/Tidal/Deezer all returned "Layo & Bushwacka!" for the misspelling — and **our relevance gate then threw all 17 hits away**, keeping only a vague "Layo" (0 release groups) which the dead-end filter then dropped. A normalised edit-similarity fallback was validated against the REAL logged hits and separates cleanly (keep: Panic! At The Disco 0.947, Layo & Bushwacka 0.929, Layo and bushwacka! 0.684 / drop: The Monkees 0.545, Bushwacka! 0.462, Panicland 0.389, Fall Out Boy 0.222, Pink Floyd 0.000) — threshold ~0.62 with a >=6-char query guard, purely additive so the 0.37.1 free-association junk (Led Zeppelin for "The Beatles") still cannot get in. NOT built pending this fix proving out in the field.
- Gates: `zsh tools/syntax_check.sh` 5/5 OK; `tools/t_norm.pl` 15/15 (5 red pre-change); `tools/t_resolve.pl` 4/4.

### 0.44.18 (2026-07-19) — code review of the 0.43.x-0.44.17 block: three correctness bugs + the search/page role split
Review pass over the whole uncommitted 0.43-0.44.17 diff (~1720 lines across API/Browse/Sources). Four fixes, each verified before and after.

- **THE BIG ONE — `_resolveOne`'s spine sort never sorted.** The scoring loop was `for my $a (@same)`, and **a lexical `$a` in scope MASKS sort's own `$a`**, so `sort { $b->{score} <=> $a->{score} }` read `score` off the service-artist hashref (always undef) instead of the element being compared. That is not a comparator: the top-scoring candidate need not end up first. So the WRONG service artist was adopted, and when the misordered head happened to score 0 the whole thing reported UNRESOLVED even though a candidate corroborated — i.e. the exact "his own albums are missing" symptom the entire 0.43.x/0.44.x same-name effort exists to fix. Loop variable renamed to `$cand`.
  - **Proven by a harness that FAILS on the old code and PASSES on the new** (`tools/t_resolve.pl`, driven through the REAL `_resolveOne`): three same-name artists scoring 0/2/1 against the spine — pre-fix picks the score-1 artist and returns 1 album, post-fix picks the score-2 artist and returns its 3. A test that only passes on the fixed code proves nothing about the bug; this one was run both ways.
  - **SILENT BY CONSTRUCTION, which is why it survived review and every gate:** `perl -c` cannot see it, and Sources.pm has no `use warnings`, so the "Use of uninitialized value in numeric comparison" that would have exposed it never fires. **Worth remembering fleet-wide: `my $a`/`my $b` anywhere in a scope containing a `sort` block is a silent corruptor.** A sweep of all five modules found this was the only instance.
- **A MusicBrainz error left the page hanging forever.** 0.44.8 added `$poolDone` to `$render`'s gate but set it only inside the release-group `onDone`; the `onError` path set `$rgsErr`/`$offDone` and not `$poolDone`, so `$render` returned early on every call and **the OPML callback was never fired at all** — a spinner that never resolves, where the error row used to be. Now settled in `onError` too. There is nothing to await on that path anyway: no release groups means no spine, so the streaming warm the flag waits for is never started.
- **The candidate-pool write key and read keys had diverged AGAIN** (third time — cf. 0.43.1 and 0.43.9). `getCandidates` derived the key's mbid as `($spine && %$spine) ? $opt->{mbid} : undef` — vestigial from 0.43.1, when only ambiguous lookups were mbid-scoped — while BOTH readers pass the mbid unconditionally. So an **empty spine wrote a name-keyed pool nothing ever read back**. Two live consequences: an artist with no MB release groups could never warm (with `hide_unmatched` on, the cold-pool await re-resolved every service on EVERY visit); and `_releaseDetail`, whose spine comes from the cache-ONLY `peekReleaseGroups`, resolved against the name-keyed pool on any cache miss — the prominent same-name act's catalogue, disagreeing with the tile that opened it, which is precisely what that block's comment claims to prevent. Now `$opt->{mbid}` unconditionally, so both sides derive the key identically. Both callers already pass it, so nothing regresses. **The 0.43.2 RULE keeps earning its place — and note it failed here not because a reader was missed but because the WRITER gated the scope on something the readers could not see.**
- **Search offered "Local" rows the page then showed nothing for** (field, Simon: "several artists that claim are local but show no entries" — John Bush / Steven Bush / David Bush). 0.19.0 restricted the library ALBUM query to performance roles (`ARTIST,ALBUMARTIST,BAND,TRACKARTIST`) so writer-only credits stopped polluting the page — **but the artist SEARCH's Local leg was never brought along.** Verified in LMS 9.0 `Queries.pm`: `artistsQuery` DOES accept `role_id` (:990, same comma form as `albums`), and without it falls back to `activeContributorRoles`/`defaultContributorRoles` (:1047-1063), **which include COMPOSER**. So a composer-only contributor was returned as a Local search row, was then EXEMPT from the dead-end filter (library rows are never filtered, 0.44.7), and opened a page whose `localAlbums` filtered it straight back out.
  - **Fixed as ONE constant, `PERFORMANCE_ROLES`, used by both call sites** rather than a second literal. The defect was not the missing filter, it was the same policy spelled in two places that could drift — fixing it as a second literal would have rebuilt the bug. If composer support is ever built, both sites widen together.
  - **KNOWN CONSEQUENCE, flagged to Simon before shipping:** composer-only contributors now disappear from search entirely. Right for the Bush case; but a classical album tagged ALBUMARTIST=orchestra with the composer as COMPOSER only means that composer is no longer a Local search row. Consistent (their page was empty anyway), and it is the hole composer support would fill.
  - The other two `artists search:` call sites (`localAlbums`' name fallback, `_bandContributorId`) were CHECKED AND DELIBERATELY LEFT: both resolve a name to a contributor id that is then fed to an album query which already filters, and LMS keeps one contributor row per name (roles live in `contributor_track`), so there is no wrong-duplicate risk — a composer-only id just yields an empty list one query later. Same outcome, no change warranted.
- **No manual cache bump needed, and that is 0.44.3 paying off:** the pool key already carries the plugin version, so bumping install.xml to 0.44.18 self-invalidates every candidate pool — which the `_resolveOne` fix requires, since pools cached under the old build hold the WRONG service artist's catalogue. The 10-minute `dsc:asearch:2` entries hold pre-filter composer rows and simply expire.
- Gates: `zsh tools/syntax_check.sh` 5/5 OK; `tools/t_resolve.pl` 3/3 green post-fix and demonstrably RED pre-fix. `matcher_sync_check.py` NOT run and NOT required — no shared matcher sub was touched (`_resolveOne` is DSC-only call-site logic, sibling of the 0.24.0 Local-gate exception).
- **STILL OPEN, not fixed here:** "Layo & Bushwaka!" (MB) vs "Layo & Bushwaka" (Tidal) do not fold. `_norm` substitutes `!` -> `i` (deliberate: P!nk -> pink, Ke$ha -> kesha), so the two spellings key differently — `layo bushwakai` vs `layo bushwaka`. **This is the DEFERRED half of the known `!` hole:** Search Hub 0.2.1 patched its own relevance gate for a user TYPING the name without the "!", and its comment explicitly scoped the fleet `_norm` change out ("the matcher has the same exposure whenever two sources spell the punctuation differently; tracked as a separate, deliberate fleet change"). Layo is that exposure, in the field. NB the fold path is keyed on resolved MBID and the alias gate normalises MB's alias to the same string, so on paper it should still fold — **do not patch this blind**; get the `search rows: NOT folding ...` / `aliases <mbid>:` log line first, since this repo has a track record of mechanisms that were correct but unreachable.

### 0.44.17 (2026-07-19) — the Iron Maidens "bug" was a WRONG TEST; control replaced
- **Simon: "the iron maidens when I searched showed no content, so shouldn't these have been filtered out like we setup earlier?"** Exactly right, and it closes the question. `artist:The Iron Maidens` renders **"No releases found"**: MB lists 5 release groups for the band, but none match anything on this server, so with `hide_unmatched` on the page is empty. A dead end — and hiding it from search results is the CORRECT behaviour we deliberately built.
- **THE TEST WAS THE DEFECT.** The Iron Maidens control asserted that row must SURVIVE an "Iron Maiden" search, which directly contradicts the dead-end filter's own rule. It failed three builds running and each time I hunted a different subsystem (folding, then resolution, then the merge relevance gate / SEARCH_MAX cap). A control that contradicts a deliberate rule will fail forever and send every investigation somewhere new.
- **Replaced with a control that is REAL and verified:** `Bush` and `Kate Bush` must remain separate rows. MB's Lucene returns artist:"Bush" -> Kate Bush at score 100, and 0.44.11's MBID-only fold merged them and deleted a genuine result. Neither is an alias of the other, so the alias gate keeps both. Confirmed live: both rows present. **11/11 pass.**
- **Per-row DROP/keep reasons are now logged** (`search row DROP 'X': no MB artist` / `rgcount=0`) and the artist-search line lists the NAMES each service returned, not just a count. Both stay: the whole investigation stalled on not being able to see which stage removed a row, and a count can never answer "was this artist ever returned?".
- **Still genuinely unknown, and deliberately NOT chased further:** why "The Iron Maidens" never reached the row filter at all (no per-row line), when Tidal's own results contain it — likely the per-service `SEARCH_MAX => 15` cap or the merge relevance gate. It no longer affects correctness (the row must be hidden either way), but if a legitimately non-empty artist ever goes missing from a search, START HERE: the 0.44.17 artist-search name list will show whether the service returned it.

### 0.44.15 (2026-07-19) — resolver picks the artist you ASKED for; speculative lookups stop hammering MusicBrainz
- **Simon: "i see Kate Bush under Bush and none of thier albums at all."** `_artistMbidByName` took MB's top hit whenever it scored >=90 — checking the SCORE but never the NAME. MB's Lucene returns `artist:"Bush"` -> **Kate Bush at 100**, with the English rock band named exactly "Bush" second at 95. So Bush drilled into Kate Bush's MBID and matched none of his albums, because the streaming pool was the band's.
- **EXACT-NAME PREFERENCE (0.44.14):** fetch 8 candidates (was 1) and prefer one whose name equals the query after `_norm`. Falls back to the old top-hit rule otherwise, which is what keeps `Beatles` -> The Beatles working (nothing is named exactly "Beatles"). This is the resolver fault that ALSO produced 0.44.11's "Kate Bush folded into Bush" — fixed at source rather than worked around.
- **`dsc:mbid` KEY VERSIONED to v2.** This changes what resolution MEANS, and a v1 entry holds a confidently wrong artist for 30 days.
- **Simon: "the delay here for resolving is painful took far too long to return."** Measured, and the wall clock was the least of it: ONE "Sonic Boom" search fired **61 requests at musicbrainz.org** plus 56 alias retries. The dead-end row filter resolves EVERY row, and the junk rows it exists to drop are exactly the ones that miss and take the most expensive path: mirror miss -> public-API retry -> alias field -> another public retry.
- **SPECULATIVE MODE:** `getArtistMbid(speculative => 1)` suppresses the public-API fallback and the alias retry. Those exist for a real case (a mirror whose search index is unbuilt returns 0 for everything) but must never fire for BULK guesses about names we were merely handed. Cost per row is now one mirror query. Beyond speed, the old behaviour risked getting the user's IP rate-limited by MusicBrainz.
- A speculative miss is "no answer", and `filterRowsWithContent` keeps failing OPEN elsewhere (an undef release-group count keeps the row) so a failed lookup never reads as "this artist has nothing".

### 0.44.13 (2026-07-19) — folding is gated on a REAL MusicBrainz alias (0.44.11 pulled, 0.44.12 disabled)
- **Simon: "it should only be doing this if the artist has an alias in MB to fold it."** Correct, and it is the rule that makes this safe. 0.44.11 folded on "both rows resolved to the same MBID" and was pulled within the hour.
- **WHY 0.44.11 WAS DANGEROUS:** `_artistMbidByName` is FUZZY. MB's Lucene scoring returns `artist:"Bush"` -> **Kate Bush**, score 100, and the `>=90` gate checks only the SCORE, never whether the name matches. So the merge folded **"Kate Bush" into "Bush"** and destroyed a real search result. This is a PRE-EXISTING resolver fault that folding merely acted on — the dead-end filter and any name-entered page inherit it too (see Open Questions).
- **CAUGHT BY THE CONTROL, not by review.** The Iron Maidens check added to tools/acceptance.py in the same build failed immediately. The control was added on the reasoning that name-similarity folding had been rejected for exactly that pair — and it earned its place within minutes.
- **The rule now:** fold only when MB records one row's name as an ALIAS of the other's artist. An alias is asserted editorial data, not a similarity score. Verified against the mirror:
  - `The Eurythmics` IS an alias of Eurythmics -> fold
  - `Genesis Mohanraj` IS an alias of Tommy Genesis -> fold (her legal name is Genesis Yasmine Mohanraj; that earlier fold was CORRECT)
  - `Bush` is NOT an alias of Kate Bush -> stay separate
- Tested in BOTH directions, because `warmArtistAliases` omits the canonical name — a row carrying the canonical name would otherwise never match while the survivor holds the alias. Survivor prefers a row with a library `artist_id` (that id is what matches the user's own albums); sources are unioned.
- **Process note:** a scripted patch to this function produced broken Perl, and `tools/syntax_check.sh` caught it before the build — the function was then rewritten wholesale rather than patched further. That tool has now paid for itself twice in one day.

### 0.44.11 (2026-07-19) — WITHDRAWN same day: folded on resolved MBID alone; merged "Kate Bush" into "Bush". Superseded by 0.44.13.
- **Simon: "Eurythmics and the alias The Eurythmics are both an entity in Qobuz I thought we had sorted this to fold into one? As the catalogue appears to be the same here."** Correct, and this is the case `mergeArtistHits`' comment explicitly held open.
- **NOT the string-similarity folding that was rejected.** We assert nothing about the names. MusicBrainz resolves "The Eurythmics" through its **alias field** to b4d32cff-f19e-455f-86c4-f347d824ca61 at score 100 — MB editors recorded that alias. Rows merge ONLY when they resolve to the same MBID, which is exactly when they would have built the identical page. Verified live: both rows rendered the same 18 releases in the same order.
- **The duplicate was also the WORSE doorway:** the library lookup is by NAME, so "The Eurythmics" matched none of Simon's own albums (21 releases with Local matches vs 18 without).
- **Merge policy:** union the `sources` labels so the survivor still advertises every service, and adopt the duplicate's `artist_id` if the survivor lacks one — that id is what makes the user's own albums match. Library rows now resolve too (they are still never FILTERED) so their artist_id can reach the survivor.
- **CONTROL, kept in the probe:** "Iron Maiden" / "The Iron Maidens" resolve to DIFFERENT MBIDs and must stay separate — that pair is why name-based folding was rejected in the first place. If that check ever fails, the merge has drifted back to string inference.
- Inherits the throttle gate: folding rides on the MBID resolution in `filterRowsWithContent`, so it happens where MB is un-throttled and is skipped on the public API.

### 0.44.10 (2026-07-19) — "unmatched" meant two opposite things; settings reworded
- **The confusion was real and the plugin caused it.** Simon, with `hide_unmatched` ticked, reasonably asked why a section full of unmatched albums was still showing — and then whether the checkbox was wired backwards. It is not (proved live: ticked = 60 releases / 0 unplayable, unticked = 93 / 39). The two settings simply used "matched" on OPPOSITE axes:
  - `hide_unmatched` — a MusicBrainz release with NO PLAYABLE SOURCE. Hide what you cannot play.
  - "Also on streaming" / "Also in your library" — the mirror image: something PLAYABLE with no MusicBrainz release.
  A row in those sections is unmatched to MUSICBRAINZ, not unmatched to a source, which is exactly why the hide pref does not touch it. Read together, the two labels flatly contradicted each other and no user could tell which direction each meant.
- **Strings only, no logic change.** "Hide unmatched releases" -> **"Hide releases you can't play"**, with the description stating the direction explicitly and noting the two extras sections are unaffected. Both extras descriptions now say their rows ARE playable and therefore out of scope for that setting.
- **String KEYS deliberately unchanged** (`PLUGIN_DISCOGRAPHY_HIDE_UNMATCHED`), so settings.html and every code reference keep working — a rename here would buy nothing and risk a missed reference.
- Lesson worth keeping: this cost more of Simon's time than several of the actual bugs. A correct implementation described in words that contradict a neighbouring setting IS a defect.

### 0.44.9 (2026-07-19) — clearcache was NEVER broken; the log window was. Cache-key diagnostics kept
- **THE BUG DID NOT EXIST.** 0.44.8's entry and a whole diagnosis cycle rested on "clearcache reports success but the pool survives". It does not. With `log.txt?lines=3000` the evidence is unambiguous: `clearCandidates: dsc:cand:4:0.44.9:qobuz:mb:5f58803e… [HIT->gone]`, then `peekPool read …deezer:mb:5f58803e…: miss`, then `pool is cold - awaiting streaming resolution before render`, then `candidates Qobuz/'Madness': 139`. Identical keys, real clear, real cold read, real refetch.
- **ROOT CAUSE OF THE MISDIAGNOSIS: `log.txt` returns only a ~155-LINE TAIL by default**, and a single discography render writes ~100 `match` lines. Everything logged at the START of a build — cache keys, service fetches, the cold-pool await — was evicted before it could be read. The conclusion "no fetch lines, therefore the clear failed" was drawn from a window that could not physically have contained them. **ALWAYS append `?lines=3000`** (see `log_tail()` in tools/acceptance.py).
- **This one flaw explains a cluster of today's errors**, all previously attributed to different causes: the "cold" tests that silently ran warm, the acceptance probe's false pass, the wrongly-annotated weak check, and an hour spent hunting a read/write key divergence that was never there. When a check depends on reading logs, the READING is part of the check.
- **0.44.8's `hide_unmatched` race fix is VERIFIED** for the first time, by that same log: cold pool -> await -> resolve -> render, pref honoured. It shipped unverified; it works.
- **Diagnostics KEPT, not reverted.** `clearCandidates` logs every key with `[HIT|miss -> gone|STILL-PRESENT]`, and `peekPool` logs each read key with HIT/miss. A clear that cannot be observed is a clear that cannot be trusted, and the pair diffs the two sides instantly. `STILL-PRESENT` would indicate an LMS cache-layer fault — a different bug from a key mismatch.
- **`tools/acceptance.py` corrected**: the hide_unmatched check is no longer annotated "weak, a PASS proves nothing" — that annotation was itself a product of the truncated log. 7/7 pass.

### 0.44.8 (2026-07-19) — hide_unmatched race fixed; row checks parallelised; VERIFICATION TOOLING ADDED
- **Simon: "can we ensure what your doing is the correct way, you seem to break one thing on each update."** Fair, and the audit is in this entry. The pattern: a change is verified against the thing it FIXED, on a WARM server, and the coupling to other features is never exercised. 0.44.3's version-scoped pools were right in isolation and silently broke `hide_unmatched`, which depends on pools being warm.
- **`hide_unmatched` was bypassed by a RACE, not a cache state.** The visibility rule exempts unmatched releases when `!$peek->{resolved}` — correct for "we asked and the services do not have this artist", wrong for "we have not asked yet". `peekPool` reported both as `resolved => 0`. Version-scoped pool keys made EVERY artist cold after an update, so the first view of any artist ignored the pref (Madness: 93 releases, 85 unmatched) and the second view corrected it — the show-then-vanish behaviour Simon had already ruled out.
- **Fix:** `peekPool` now reports `cold` (no service has ANY cached entry) separately from unresolved, and `_discographyView` AWAITS the streaming warm when `hide_unmatched` is on and the pool is cold. Bounded by `POOL_WAIT_MAX` (20s) purely as a safety net against a service handler that never calls back — a hung page would be worse than the bug. With the pref off, nothing waits.
- **Row checks now run in PARALLEL** (`filterRowsWithContent`). It only ever runs un-throttled, so serialising ~2 requests per row — 30 sequential round trips for a 15-row search — was pointless; that was the slowness Simon reported on his own mirror. Order is preserved by writing into a per-row slot rather than pushing on completion.
- **`tools/syntax_check.sh` (new).** `perl -c` never ran on this repo from the Mac (no Slim::*), so checks had degenerated into eyeballing brace counts — which is not a check: a crude counter called Sources.pm "+3 unbalanced" when it was syntactically perfect. This generates Slim stubs and compiles all five modules. Run before every build.
- **`tools/acceptance.py` (new).** Live probe of user-visible behaviour, tested COLD as well as warm, with each check naming the artist that exposed the bug and the regression it guards.
- **HONESTY NOTE ON THE PROBE:** its `hide_unmatched` check is WEAK and says so in the file. `clearcache` empties the pool but not the upstream service caches, so the pool rebuilds inside the same request and the page renders correctly — it PASSED against a build that had visibly failed minutes earlier. A FAIL is meaningful; a PASS proves nothing. That is precisely why the fix above removes the race rather than testing for it. The other three checks (dead-end rows with the Genesis Brass / Genesis Piano Project false-positive guards, zero-release acts in the same-name section, secondary-act biography) do exercise genuinely cold paths, since `clearcache` clears what they read.

### 0.44.7 (2026-07-19) — search rows that lead nowhere are hidden (throttle-gated)
- **Simon: "What has MB got to do with if the artist in the view has no entries inside. It either has contents or it doesnt and its hidden from view if it doesn't."** The answer is that a Discography page's contents ARE the MB discography, so "has contents" and "MB knows it" are the same question — but the challenge was right that the previous filter only covered the same-name SECTION, not the main search list.
- **Measured first (server, not theory).** Of four suspect rows in a "Genesis" search: `Beats of Genesis` -> "No releases found"; `Genesis Tajiri` -> "Couldn't identify this artist on MusicBrainz"; but `Genesis Brass` (34 rows) and `Genesis Piano Project` (19 rows) are REAL artists with releases. So a blanket "looks obscure" rule would have deleted genuine results.
- **Two cheaper oracles were measured FALSE — do not re-propose:**
  1. *The service's own release count.* Deezer reports `releases=1` for real artists and junk alike.
  2. *The single MB search already run for the query.* It returned 100 artists for "Genesis" and still omitted `Genesis P-Orridge` and `Genesis Piano Project`, both of which have real pages. Filtering on it would hide two genuine artists to remove four dead ends — the same false-positive shape as the rejected conflation heuristic in 0.44.4.
- **So `API::filterRowsWithContent` performs the page's own test:** resolve name -> MBID, count release groups, drop the row when it resolves to nothing or to zero releases. Both halves already cache (`dsc:mbid`, `dsc:rgcount`).
- **THROTTLE-GATED (`mbGap`).** One resolve + one count per row is milliseconds against a mirror but 15-30s for a first search of a new name on the public API. The filter therefore runs only where MB is un-throttled; elsewhere every row is kept exactly as before. Deterministic per install, so no show-then-vanish either way.
- **LIBRARY ROWS ARE NEVER FILTERED** (`artist_id` present). An artist in the user's own collection that MB does not list would otherwise vanish from search — hiding music they own is far worse than a thin page. Likewise an undef count (failed fetch) keeps the row.
- **Bug caught pre-ship:** `getArtistMbid`'s name parameter is `artist`, not `name`. The first draft passed `name =>`, which resolves nothing and would have hidden EVERY row.

### 0.44.6 (2026-07-19) — checkboxes were invisible in Material (bare `<input>` inside `WRAPPER setting`)
- **Simon: "I dont see an option in settings to turn it off/on" ... "It is not viewable".** Server-side everything checked out — the field is in the rendered HTML, registered in `Settings::prefs`, and `checked`. It is MATERIAL that does not draw it.
- **The screenshot was the evidence.** In "Discography view", *Default sort* and *Release types* render; the four settings after them leave BLANK SPACE. The difference is not the pref, the section, or the description: the two that render wrap their controls in `<label>` with text, the four that vanish are bare `<input type="checkbox">` inside `[% WRAPPER setting %]`.
- **All 7 checkboxes on the page are now wrapped** in `<label>…PLUGIN_DISCOGRAPHY_ENABLED</label>`, matching the *Release types* markup that demonstrably renders. Harmless in the classic skin (which drew the bare ones fine), and it gives every checkbox a clickable label.
- **NOT yet confirmed as the cause** — this is a cheap, low-risk change that matches the one structural difference visible in the evidence, made after three theories died today. If checkboxes are still missing after installing, the cause is elsewhere (Material's iframe CSS was the next suspect; its assets are not served from the paths guessed here, so reading them needs the Material source rather than HTTP).
- **POSSIBLY FLEET-WIDE.** LMS-Listen-to-Later, LMS-Pitchfork-Reviews and LMS-Album-Booklet all use the same bare-checkbox-inside-`WRAPPER setting` pattern, so their toggles may be equally invisible in Material. Do not change them until this build confirms the fix — then it is the same mechanical edit in each repo. Material's own settings pages are Vue (`v-checkbox`), so the plugin-iframe path is a different code path from anything Material renders natively.

### 0.44.5 (2026-07-19) — the peek-guard class of bug: cold caches were answering "no"
- **ONE root cause behind two separate reports.** Both `sharesNameWithProminent` and the empty-candidate filter decided from a PEEK, and both treat "not cached" as "don't act". So each was correct on a warm cache and wrong on the visit that actually matters — the first one. This is the third time this session a mechanism was right but unreachable (cf. the split cache key and the alias retry); the pattern is a test that exercises the mechanism while the entry condition never holds.
- **Biography leak (Simon: "still seeing the real Sonic Booms bio on the group Sonic boom with Andew Haung").** `sharesNameWithProminent` peeks `dsc:acand`, and a miss returns 0 = "does not share a name", so the guard opened and MAI's name-keyed biography rendered the PROMINENT act's life story under the other artist's name. New `sharesNameWithProminentAsync` FETCHES the same-name set (cached thereafter); the sync form stays for callers that cannot wait, now documented as fail-open. The page already blocks on MB and `$render` is flag-gated, so this is free in wall-clock terms.
- **Empty same-name rows (Simon: "is it not possible at this level to not show any artist that has nothing in its drill down?").** The filter existed and was right; `warmCandidateCounts` just ran in the BACKGROUND, so the first search rendered every candidate and a later one silently removed the empties. Proven on an unwarmed name: a first search for "Bush" listed the "techno" act (0 release groups in MB). It now AWAITS the counts.
- **Correctness over latency, chosen deliberately.** Simon: "I dont want users getting confused by stuff showing then disappearing" and "the hit on resolution and being correct is more important." Cost is one MB browse per uncounted candidate at the 1 req/s etiquette — milliseconds on a mirror, a few seconds on the public API for a first search, then cached for `RGCOUNT_TTL`. The planned hosted LMS-community API removes the throttle. A rejected middle option (short timeout, then show everything) was exactly the show-then-vanish behaviour he ruled out; an HTTP FAILURE still leaves the count undef and the artist SHOWN, since a failed fetch must never read as "has no releases".
- **`clearcache` now clears `dsc:acand` and `dsc:rgcount` too.** It previously cleared neither, so a wrong disambiguation list could not be shifted at all — and it made a "cold" reproduction of the bio guard silently run warm, which is why an early attempt at reproducing that leak came back negative. Counts are cleared BEFORE the candidate list that indexes them.

### 0.44.4 (2026-07-19) — "Also on streaming" is UNVERIFIABLE: pref defaults OFF, section relabelled
- **Simon: "not sure the dedupe is working still seeing all that pollution."** The dedupe was fine. Dedupe collapses copies of the SAME album across services; it was never going to remove a DIFFERENT act's album. The pool arrived wrong.
- **Root cause, measured on the live server (Search Hub's `album-artist-ids` diagnostic):** Qobuz files at least five different "Madness" acts under ONE artist entity, id 85999. 139 albums, 90 of them not the ska band's, every one credited "Madness". Both existing defences are structurally incapable here: `_filterForeignArtist` compares artist IDs (the intruders share the id) and the credit gate compares NAMES (they share the name).
- **Not the same fault as Sonic Boom**, despite looking identical on screen: `Qobuz/932593: dropped 31` — that entity DOES credit appears-on records to other ids, which is how the Experimental Audio Research pollution was caught and why it stays fixed. Only the Madness-shaped entity is unseparable.
- **THREE filter designs were prototyped and killed by measurement before any shipped** — recorded so they are not re-proposed:
  1. *Drop unclaimed albums whose title matches a rival same-name MB artist's release group.* **Circular and near-useless:** 0 of 30 polluting rows matched any of the 19 rival titles. This section shows exactly the records MB does NOT list, so MB cannot identify the intruders — they are streaming-only acts it has never heard of. That is WHY they land here.
  2. *Suppress when the service entity shows zero artist-id diversity.* **Built on a misread log line.** The `album-artist-ids` histogram is computed AFTER filtering, so it always shows one id for the kept set and can never show diversity. Madness's real figure was on the line above: `dropped 19`. The condition would never have fired on the case it was designed for, and the only artist it DID fire on was Genesis (40 clean albums, 0 appears-on) — a silent false positive.
  3. *Gate on the name being shared by several MB acts.* **Gates nothing:** every artist measured has >=2 same-name MB artists (Panda Bear 2, Genesis 17, Air 21). Drop-ratios don't separate either — Madness 12%, Bush 8%, Yes 13%.
- **Conclusion: the unclaimed streaming pool cannot be validated with any signal available to us.** So the honest change, not a fourth filter: `show_streaming_extras` now defaults to **0**, the section reads **"Also on streaming (unverified)"**, and the settings text names the failure mode explicitly. The net stays available for the case that motivated it (the US rapper's nine Deezer albums that MB does not list) with the user opting in knowing what it is.
- **Deezer needs no id filter — earlier concern retracted.** `Deezer album-artist-ids: (none)=17` is not a filter failing open: `/artist/N/albums` is id-scoped AT THE ENDPOINT, so there is no artist object because there is nothing to disambiguate. Confirmed by three Deezer ids returning three different catalogues for Sonic Boom (17/18/3). Qobuz's artist endpoint differs only because it folds in appears-on credits.
- **The durable fix remains the streaming-spine architecture** (resolve identity from the service's own catalogue structure instead of asking MB to arbitrate records it has never heard of). This entry is the evidence for why it is worth doing.

### 0.44.3 (2026-07-19) — candidate pools are keyed by PLUGIN VERSION (self-invalidating on every install)
- **Simon: "can we not automatically clear the cache pool on updates whilst we develop?"** Yes, and it removes a recurring diagnosis trap rather than just a chore.
- **The candidate pool is the one cache whose contents depend on our LOGIC, not on remote data** — which service artist was picked, what the foreign-artist filter dropped, whether the alias retry ran. A resolver change can therefore leave a pool that is stale in a way no TTL describes, and it persists for `CAND_FOUND_TTL` (3 days). Twice this week that made a WORKING fix look broken (Sonic Boom came right only after a manual `clearcache`; the same trap cost several rounds on Madness).
- **`_candKey` now includes the plugin version**, so a new build simply cannot read an old build's pools. Cost is one refetch per artist actually VISITED after an update — on demand, not a mass rebuild. Old keys are never read again and expire on their own. The manual `CAND_CACHE_V` constant stays for deliberate shape changes.
- **Not applied to the MB caches** (`dsc:rg`, `dsc:mbid`, `dsc:acand`, `dsc:alias`, `dsc:rgcount`): those hold REMOTE data that our code changes do not invalidate, and version-scoping them would re-fetch MusicBrainz on every install for no benefit.
- **Same change in Search Hub 0.12.0** (`sh:leg` + `sh:artitles` keyed on its existing `BUILD` constant) for the same reason.

### 0.44.2 (2026-07-19) — "Also on streaming": same-name albums back in, and one row per album
- **Field (Simon): Sonic Boom's whole discography now resolves (7 albums + EP + compilation across all three services, pools 37/22/17 where Qobuz had been 2) — but "Also on streaming (54)" listed another artist's records and duplicated every album per service.**
- **0.44.1's collaboration softening had reopened the same-name hole.** Forgiving ANY differing artist id whose credit matched the name let a DIFFERENT act with the SAME name straight back in ("Bajo Tu Voz", "El Mssiah" by another Sonic Boom). **The forgiveness is now narrow:** a genuine collaboration reads as the artist PLUS someone else ("Panda Bear & Sonic Boom") — strictly MORE tokens than the name — so a differing id is forgiven only when the credit CONTAINS the artist and is not merely EQUAL to it. An exactly equal credit under a different id is the Madness case and is dropped.
- **Deduped across services**, as a matched release already is: one row per album naming every service that carries it, keyed on title+year so genuinely different records sharing a title stay apart. The first occurrence wins the row and the loop runs in source-priority order, so the preferred service supplies the node that plays.
- **Two operational notes from the field session, both of which made a working fix look broken:** the pool warm is a SECOND-LOAD (the render never waits for it), so the first open after installing still shows the old result; and a stale pool persists for up to `CAND_FOUND_TTL` (3 days), so an artist visited before the fix needs `["discography","clearcache","artist:<name>","mbid:<mbid>"]` or a Refresh to re-resolve.
- Gates: `perl -c` clean; **7 filter assertions** (adds same-name-different-id dropped while the collaboration survives) + 8 alias + 2 unresolved + 3 present + 6 fold + 6 shared-name + 10 spine + 10 same-name = **52 green**; `matcher_sync_check.py` exit 0.

### 0.44.1 (2026-07-19) — "Also on streaming": wrong links, other artists' records, and ambiguity that was never detected
- **Three field reports (Simon), three separate causes, all measured before fixing:**
- **(1) Rows opened the WRONG album** — "Help Me Please (Hi-Res) · Qobuz" opened Experimental Audio Research's "Phenomena 256". My 0.44.0 rows carried **no `id` and no `itemActions`**, so a click sent a POSITIONAL item_id, the feed was rebuilt and the index landed on whatever now sat there. Every other actionable row in this plugin has been param-addressed since 0.34/0.35; these were the exception. Now `id => 'str:<svc>:<albumid>'` + `_listItemActions`.
- **(2) The section listed other artists' records** (Sonic Boom's showed Experimental Audio Research releases — a band he is a MEMBER of). A MATCHED release is verified by the MB spine; an UNCLAIMED one has nothing vouching for it, so it now must at least be CREDITED to this artist (`_artistMatch` token-subset, so "Panda Bear & Sonic Boom" still counts as his).
- **(3) THE BIG ONE — ambiguity was only ever detected after a plugin SEARCH.** `$ambig` came from `peekArtistCandidates`, a cache the plugin's own search populates; an artist entered from the **Material context menu — the primary entry point** — was therefore never known to be ambiguous, so strict verification and the alias retry never ran. Live proof on Sonic Boom (FOUR MB artists of that name): `pool: Deezer=0, Local=3, Qobuz=2, Tidal=0` with **no `ambiguous` line at all** — Qobuz had resolved to an entity holding two albums and nothing checked it, which is why his own albums were missing while the Panda Bear collaborations (matched from Local) showed. Now FETCHED via `getArtistCandidates` (cached 14d = one MB request per artist per fortnight).
- **`_filterForeignArtist` softened — collaborations are not foreign.** 0.44.0 dropped any album whose artist id differed from the requested one, which would discard "Panda Bear & Sonic Boom" (credited to the collab entity) even though the MB spine LISTS it — a matching regression. A differing id is now forgiven when the credit still names the artist; only credits that do not (his other band's records) are dropped.
- Gates: `perl -c` clean on API/Sources/Browse; **6 filter assertions incl. the new collaboration case** + 8 alias + 2 unresolved + 3 present + 6 fold + 6 shared-name + 10 spine + 10 same-name = **51 green**; `matcher_sync_check.py` exit 0.
- **Recorded at Simon's request:** the streaming-spine alternative, as the possible way out of this whole class of problem — see the NOTE section above the PLANNED fallback.

### 0.44.0 (2026-07-19) — streaming safety net: releases the MB spine doesn't list + foreign-artist filter
- **Simon: "I know there is more by this artist in Tidal and Qobuz that's not in MB. Ideally we don't want to throw these away."** Measured: MB has ONE release group for the US rapper (Manuel Gomez) while **Deezer carries TEN albums** under his alias entity (id 9205778). The spine is MusicBrainz, so nine playable records were invisible.
- **"Also on streaming" section** — the exact twin of "Also in your library", and for the same reason: MB is the spine, and anything PLAYABLE the spine does not list must not silently vanish. Rows are the pool candidates no release group claimed, grouped in source-priority order, year-sorted, paged (`STREAM` key). They are the service plugins' OWN rendered nodes, so they browse and play natively — no MB detail page, same as a library-extras tile. New pref `show_streaming_extras` (default 1) + Settings checkbox.
- **Claimed ids are collected DURING the existing release loop** rather than recomputed — matching every candidate against every release group is exactly the work that loop already does.
- **`_filterForeignArtist` ported from Search Hub 0.11.0, and it is load-bearing for the above:** Qobuz's `getArtist(85999)` returns 139 albums by 85999 **plus ~20 by eighteen OTHER artist ids** (appears-on entries its own app hides). Unfiltered, those would have filled the new section with other artists' records. Applied inside the album FETCH so it cleans scoring as well as rendering — a foreign album must not contribute to a candidate's spine score either. **SELF-GUARDING:** TIDAL's album payloads use a different id space from its artist ids (we ask for 9130 and no album reports 9130), so the filter only engages once the requested id actually appears in the response — a naive version would delete TIDAL's entire discography.
- **Aliases now shown on the same-name rows** (`aka Tony Madness`): it is the name the artist's records are actually sold under, so it is often the most recognisable thing on the row — and it explains why a row named "Madness" leads to a catalogue filed elsewhere.
- **Recall limit, measured and NOT fixed:** a service search for "madness" (limit 25) does **not** return "Tony Madness" — 8 fans against the ska band's 260,000, so he falls outside the relevance cap. He is reachable only via the MB same-name row + the alias retry, never as a search result in his own right. Raising the limit moves the cliff rather than removing it (the 0.10.2 search-cap lottery).
- Gates: `perl -c` clean on API/Sources/Browse; **5 new filter assertions** (foreign id dropped, credit-less kept, TIDAL id-space disengage, Deezer no-op, `artists[]` credit array, no-id no-op) + 8 alias + 2 unresolved + 3 present + 6 fold + 6 shared-name + 10 spine + 10 same-name = **50 green**; `matcher_sync_check.py` exit 0 (`_filterForeignArtist` is adapter logic, not a matcher sub — the sibling of the 0.24.0 Local-gate exception).
- Settings template edited by hand after a scripted block-copy duplicated a chunk of it — restored from git and re-inserted precisely. **Verify a templated file by eye (or a tag balance check) after any scripted edit.**

### 0.43.9 (2026-07-19) — "unresolved" finally MEANS unresolved; clearcache clears the mbid-scoped pool
- **Simon: "could it be because I don't have singles enabled?" — YES, and that was the whole of the empty page.** The US rapper's ONLY release group is `Classy` (2018), **primary-type Single**, and his `show_types` is `ALBUMS,COMPILATIONS`. The page was correctly empty by his own filter; nothing to do with aliases or resolution. Measured, not guessed: MB says Single, the pref says Albums+Compilations. **Check the user's own view filters before diagnosing a matching failure** — three builds chased a filter.
- With singles enabled the release renders and the resolver runs — which exposed two REAL bugs behind it:
  1. **`clearcache` never cleared the mbid-scoped pool.** 0.43.2 scoped candidate pools by mbid and updated Browse's callers, but `Plugin.pm`'s CLI still called `clearCandidates($artist)` with no mbid — so the one command whose entire job is shifting a stale pool left the ambiguous artist's pool in place. Same class as the 0.43.1 read/write key split: a scope added to a key must reach EVERY caller.
  2. **`unresolved` was never actually recorded, so 0.43.1's headline behaviour did not exist.** The claim was "no corroboration => unresolved, so hide_unmatched leaves the release visible". In fact the error path cached an empty list with no marker, and `peekPool` sets `resolved` from the mere PRESENCE of a cache entry — so an unresolved service counted as "streaming was checked" and the release was hidden anyway. `_cacheCands` now stores an `unresolved => 1` marker and `peekPool` does not count those as resolved. **I asserted this behaviour in the 0.43.1 log without ever verifying it.**
- Gates: `perl -c` clean; **2 new assertions** (unresolved pool -> resolved 0; checked-but-empty pool -> resolved 1) + 8 alias + 3 present + 6 fold + 6 shared-name + 10 spine + 10 same-name = **45 green**; `matcher_sync_check.py` exit 0.
- **Third false-passing fixture this session, same lesson:** without stubbing `orderedAdapters`, the pool loop never runs under the harness and BOTH cache cases return `resolved => 0` — the unresolved assertion "passed" while testing nothing. Stub the collaborator that makes the loop execute, or the test proves only that the code compiled.

### 0.43.7 (2026-07-19) — the alias retry never fired: a lone same-name hit was trusted unchecked
- **Field: 0.43.6 installed, alias FETCHED (`aliases b933968d...: Tony Madness`) but no retry and still "No releases found".** The US rapper has 1 release group (*Classy*, 2018), so a spine existed. Cause: **Qobuz returns exactly ONE artist called "Madness"**, so `_resolveOne` took its `@same < 2` shortcut, adopted the ska band WITHOUT scoring it against the spine, and reported SUCCESS — so the wrapper's alias retry, which only runs when nothing resolved, was never reached. The alias machinery was correct and unreachable.
- **Fix — `$strict`:** when the NAME is known to be shared by several MB artists, a lone same-name hit on a service proves nothing (it is most likely the prominent act) and is now scored against the spine like any other candidate; failing that, it reports unresolved and the alias retry runs. Threaded as `getCandidates`' `{ambiguous}` from Browse, which already knows the same-name set size.
- **Deliberately NOT the default.** For an unambiguous artist a single name match IS the right answer, and demanding catalogue corroboration would reject legitimate artists whose service titles are spelled differently from MusicBrainz's. Asserted both ways: not-strict trusts the lone hit, strict scores it and falls through to the alias.
- Gates: 8 alias assertions (incl. both sides of `$strict`) + 3 present + 6 fold + 6 shared-name + 10 spine + 10 same-name = **43 green**; `perl -c` clean; `matcher_sync_check.py` exit 0.

### 0.43.6 (2026-07-19) — resolve a service artist under MusicBrainz ALIASES ("Tony Madness")
- **Field (Simon): MB's "Madness" (US rapper Manuel Gomez, member of Critical Madness) has all his streaming releases under his alias TONY MADNESS, not "Madness".** Verified against MB before writing anything: `artist/b933968d?inc=aliases` returns exactly one alias, **"Tony Madness"** (type "Artist name"). So the spine resolver searched the services for "Madness", found the ska band, scored zero against this artist's release groups and correctly settled UNRESOLVED. The artist was never absent — we were asking under the wrong name.
- **Sibling of the 0.32.0 alias fix, in the opposite direction:** that one searched MB by ALIAS when the name found nothing; this searches the SERVICES by MB's aliases when the name finds nothing that corroborates.
- **`API::warmArtistAliases`/`peekArtistAliases`** (`dsc:alias:1:<mbid>`, 30d; the primary name filtered out, dupes dropped). **HTTP errors are NOT cached** — an alias list is an enabler, and pinning an empty one for a month would silently disable the retry with no symptom.
- **`Sources::_resolveArtist` split into a wrapper + `_resolveOne`** so the alias retry can reuse the scoring without recursing into itself: try the searched name, then up to `ALIAS_MAX` (3) aliases, each a fresh service artist search scored against the same spine. Each adapter now exposes a `$search->($name,$cb)` closure alongside its existing `$fetch`. **Retries happen ONLY on the failure path** — a name that corroborates costs nothing extra (asserted: zero additional artist searches).
- **Aliases are fetched only for an AMBIGUOUS name** (`peekArtistCandidates` > 1 and an mbid in hand), where a failed resolution is expected and the retry is what rescues it. An ordinary artist resolves under its own name and must not pay an MB request per browse.
- Self-passing closure for the alias walk, not a captured lexical — the 0.30.1 reference-cycle leak fix.
- Gates: `perl -c` clean on API/Sources/Browse; **6 new assertions** driven through the REAL `_resolveArtist` with the field shape (resolves under the alias; still fails correctly without aliases; tries aliases in order; the cap is honoured; the name path is unaffected; NO extra search when the name works) + 3 present + 6 fold + 6 shared-name + 10 spine + 10 same-name = **41 green**; `matcher_sync_check.py` exit 0.

### 0.43.5 (2026-07-19) — distinct spellings promoted + artist photos + dead-end acts dropped
- **Simon, three things: (1) "the German rapper can move up with the other releases as being with umlauts it's significantly different", (2) "can we not find an artist image for them", (3) "all the others have no releases at all that has been matched. It seems wrong to display them at all".**
- **(1) Distinct spellings are no longer treated as ambiguous.** Candidates whose name STRING differs from the query ("Maedness") now render in the MAIN result list; only same-spelling acts go under "Other artists with this name". The section exists to separate things a user cannot tell apart by name — a differently spelled artist is simply another result.
- **(2) Photos, where they can be RIGHT.** `_artistImg` is name-keyed, so a unique spelling resolves to the correct artist and gets a real MAI photo; same-spelling acts keep the person icon, because a name-keyed lookup would hand every one of them the PROMINENT act's picture (the 0.43.0 bug). **A genuine per-act photo for same-spelling artists is not available cheaply** — MB carries no images and the MAI/Last.fm route has only the name; the nearest option is a release-group cover via CAA, one MB lookup per candidate. Not done.
- **(3) Zero-release candidates dropped.** `API::warmCandidateCounts` + `peekReleaseGroupCount` (`dsc:rgcount:1:<mbid>`, 14d): an artist MB has catalogued no releases for can only ever render an empty page ("John Olson", "features on a Robert de Boron track"). **It is a WARM, not an inline filter, and that is a real limitation, not a design flourish:** one MB browse per candidate, which a local mirror answers in milliseconds but the public API rate-limits to 1 req/s — eight candidates would block a search for eight seconds. So the filter applies to whatever is already counted (the plugin's established second-load contract), and **an UNCOUNTED candidate is never treated as zero** — a cold cache shows everything rather than hiding real artists. On Simon's mirror this is effectively immediate; on the public API the dead rows go on the next search for that name. An HTTP error caches nothing, so a blip cannot pin "0" for a fortnight.
- **What this does NOT do:** it drops acts with no MB RELEASES, not acts with no STREAMING MATCH. Telling the latter apart needs the full per-candidate service resolution (an artist search plus album fetches per service, per candidate) at search time — far too costly for a result list. So an act with releases that no service carries still appears, and correctly so: it exists, it just isn't playable.
- Gates: `perl -c` clean on API/Sources/Browse; **3 new assertions** (unique spelling -> real photo, shared spelling -> person icon, zero-release dropped while UNCOUNTED is kept) + 6 fold + 6 shared-name + 10 spine + 10 same-name = **35 green**; `matcher_sync_check.py` exit 0.
- **Two fixture bugs caught in this session's own tests, both of which had a test passing for the wrong reason:** `ok($x =~ /re/, 'name')` puts the match in LIST context — an empty list on failure shifts the NAME into the condition slot and the assertion "passes"; wrap in `scalar()`. And `_artistImg` returns the person icon when MAI is absent, which the stub reports, so the photo assertion was quietly testing the fallback until `isEnabled` was stubbed true.

### 0.43.4 (2026-07-19) — a same-name act no longer borrows the prominent act's library, bio and similar artists
- **Field (Simon): "the main discography folds into the other artists called Madness — N.B. it's not doing it for the German rapper."** Exactly right, and the exception is the diagnosis: the horrorcore Madness's page showed *Open Corpse* (correct, its own) followed by **the ska band's** "Also in your library (3)", "Appearances (4)" and "Similar artists (The Specials, The Selecter…)", while **Maedness** was clean. Those three lookups are keyed by the NAME STRING — `localAlbums` (name -> artist_id), the MAI biography, and Last.fm similar artists — so an act spelled *identically* inherits the prominent act's data, and a differently spelled one does not. This is the known limit recorded in 0.43.2, now closed.
- **`API::sharesNameWithProminent($name,$mbid)`** (+ sync `peekArtistCandidates`): true only when the cached same-name set has >1 entry, this mbid is NOT the top-scored one, AND the top candidate's name is the SAME STRING. The string test is the whole point — it is why Maedness keeps its own (correct) name-keyed results while a second "Madness" gets none. **Fails OPEN**: an unfetched candidate set never suppresses anything.
- **Suppressed for a shared-name act:** the library albums (`$local = []` — no signal exists to split two acts sharing a name, and asserting the user owns records this artist never made is worse than showing nothing), the biography, and the similar-artists section. **The similar-artists WARM is gated too, not just the render:** its cache is mbid-keyed but its FETCH is by name, so warming a shared-name act writes the prominent act's peers under this artist's key, where a later render would trust them.
- Gates: `perl -c` clean on API/Sources/Browse; **6 new assertions** (secondary same-string flagged, prominent act never flagged, MAEDNESS explicitly NOT flagged, no-mbid entry unaffected, fail-open on an unfetched set, single candidate not ambiguous) + 6 fold + 10 spine + 10 same-name = **32 green**; `matcher_sync_check.py` exit 0.
- **Verified in menu mode before changing anything** that the disambiguation labels DO render (`Madness || Horrorcore rapper, member of Bedlam · Person`) — a plain jsonrpc dump omits `line2` entirely (legacy `loop_loop` format without `menu:`), which briefly looked like a labelling bug. Measure the way Material actually asks.

### 0.43.3 (2026-07-19) — same-name set is FOLD-matched (the missing "Maedness") + no duplicate prominent act
- **Field (Simon): an act called Madness that Search Hub lists, and which is MB's SECOND hit, was missing from the disambiguation section - "it has umlauts over the a so isn't showing".** Confirmed live: `artist:"Madness"` returns **Maedness** (German rapper Marco Doell, umlaut a, score 77) second, and `getArtistCandidates` filtered on `lc($name) eq $want`, so a genuinely different act sharing the spoken name was invisible - while Search Hub, which folds, listed it.
- **Fix - `API::_nameKey`**, used for both the filter and the cache key. **TWO things are required and either alone is useless**, both verified by measurement before writing the code: the matcher's fold (umlaut-a -> a) AND **UTF-8 OCTETS** - `_norm`'s fold table matches on octets, while MB's JSON decodes to CHARACTER strings, so `_norm` on the decoded name leaves the umlaut unfolded (`_norm(chars)='m?dness'` vs `_norm(octets)='madness'`). Cache key `dsc:acand:1` -> **`2`**: v1 entries hold a NARROWER set and must not be served.
- **Widens `getArtistCandidates` for ALL callers, including the wrong-tag `_disambiguateByLibrary` path** whose 0.32.0 note recorded lc equality. Deliberate and safe: which candidate wins there is decided by LIBRARY corroboration, never by the name, so admitting a diacritic variant adds a candidate to TEST rather than changing how one is CHOSEN.
- **Field: the ska band appeared TWICE - once in the streaming rows, once under "Other artists with this name".** `getArtistCandidates` sorts by MB score and the top hit is exactly what name resolution picks, so the rows above already drill into it. Now dropped from the section **when a result row for that exact name exists above**; with no such row (an artist absent from every service and the library) the whole set stays, or the prominent act would be unreachable.
- **Test-harness lesson worth keeping:** the first fold test FAILED against correct code because the fixture was wrong - a bare `"\x{e4}"` literal is a single UNFLAGGED 0xE4 byte (invalid UTF-8), not what `from_json` returns. `utf8::upgrade` reproduces a decoded string properly. A fixture that misrepresents the input shape indicts the code instead of itself.
- Gates: `perl -c` clean on API/Sources/Browse; **6 fold assertions** (fold-equality, both encodings agreeing, distinct names staying distinct) + 10 spine + 10 same-name row = 26 green; `matcher_sync_check.py` exit 0 (`_nameKey` is a new API-local helper CALLING `_norm`, not a copy of it).

### 0.43.2 (2026-07-18) — read/write cache-key parity + the duplicated prominent act
- **Field: 0.43.1's resolver "did nothing" — and it WAS installed** (Simon corrected me; I had wrongly read the absence of debug lines as proof the build wasn't there, when it was proof the code path was never REACHED). **The read key and the write key had diverged:** `getCandidates` wrote the pool under `dsc:cand:...:mb:<mbid>` while `peekPool` still read `_candKey($svc,$artist)` — name-keyed — so the render never saw what the warm fetched and kept matching against the stale prominent-act pool. `peekPool`/`peekMatches` now take the mbid and derive the key with the same `_candKey` call; `clearCandidates` clears both scopes. **RULE: a cache whose key gains a scope must have EVERY reader updated in the same change — a split read/write key fails silently and is indistinguishable from the fix not being installed.** Regression test asserts read-key == write-key.
- **Pools are now keyed by MB artist rather than name for every artist** — a ONE-TIME refetch on first open after install (effectively a cache-version bump; candidate SHAPE unchanged).
- **Field: the ska band appeared TWICE — once in the streaming rows, once under "Other artists with this name".** `getArtistCandidates` sorts by MB score and the top hit is exactly what name resolution picks, so the rows above already drill into it. It is now dropped from the section **when a result row for that exact name exists above**; with no such row (an artist absent from every service and the library) the whole set stays, or the prominent act would be unreachable.
- **VERIFIED LIVE after install** (the horrorcore Madness, mbid 5d500d2e): page renders `Albums (1) / Open Corpse` matched on Qobuz — `pool: Deezer=0, Local=7, Qobuz=1, Tidal=0` where Qobuz was 158 before; `Tidal: 'Madness' is ambiguous - 9130=0, 4107463=0, 17139839=0, 82480915=0 spine titles -> UNRESOLVED`, same for Deezer's four. Four same-name candidates probed per service, none corroborating on Tidal/Deezer (this act genuinely isn't on them) and correctly settling unresolved instead of adopting the ska band's catalogue.
- **KNOWN, NOT FIXED (visible on that same page): `localAlbums`, the BIO and SIMILAR ARTISTS are still name-keyed**, so the rapper's page lists the ska band's 3 owned albums under "Also in your library", 4 "Appearances", and The Specials/The Selecter as similar artists. The library one is the most misleading — it asserts the user owns records this artist did not make. Same fix shape (scope by mbid / suppress when the entry is a secondary same-name act); deliberately deferred rather than bundled half-done.
- Gates: `perl -c` clean on API/Sources/Browse; 10 spine assertions + 10 same-name row assertions green; `matcher_sync_check.py` exit 0.

### 0.43.1 (2026-07-18) — same-name acts: resolve the SERVICE artist against the MB spine (0.43.0's empty pages)
- **Field (Simon): the new same-name rows all showed the SAME wrong artist photo, and every one of them drilled into an empty page — "which isn't correct as they do have material in services".** Diagnosed live, and the matcher was NOT at fault:
  ```
  topLevel: artist=Madness mbid=5d500d2e-...          (the horrorcore rapper)
  match 'Open Corpse' [Madness]: NO MATCH | pool: Qobuz=158, Tidal=131, Local=7
  ```
  The MB spine was RIGHT (the rapper's one release group, *Open Corpse* — MB has 1 RG for him, 107 for the ska band). The candidate pool was the SKA BAND's, because `getCandidates` is keyed by artist NAME and `_pickArtist` returns the first exact-name hit — a coin toss when eight artists share the name. Nothing matched, `hide_unmatched` hid it, page read "No releases found". **Only the spine was identity-keyed; candidates, local albums, bio and photo all still resolved by NAME**, so a secondary act inherited the prominent act's everything.
- **Fix — `Sources::_resolveArtist`**: when a service returns MORE THAN ONE artist of the searched name AND a spine is supplied, fetch each same-name candidate's catalogue (capped `SPINE_ARTISTS` 4) and pick the one whose titles corroborate the MB release groups we already hold. MB is an authoritative title list for that mbid, so this is a real identity test rather than another name comparison. `Browse::_spineTitles($rgs)` builds the reference (matcher `_norm`, so it compares like-for-like with candidate titles).
- **Self-limiting by construction:** `_resolveArtist` gates on `@same < 2`, so an unambiguous artist takes the byte-identical old path (`_pickArtist` → fetch), and the spine can therefore be passed unconditionally. `_candKey` gains an OPTIONAL `$mbid`: pools are now scoped to the MusicBrainz artist rather than the name, so two acts called Madness cannot share one. **This re-keys every artist's pool — a ONE-TIME refetch on first open after install** (effectively a cache-version bump; the candidate SHAPE is unchanged). `clearCandidates` clears both scopes so Refresh can't leave a stale pool behind.
- **NO CORROBORATION = UNRESOLVED, not "no match"** (Simon's call): settling `undef` caches the short error TTL and leaves `peekMatches`' `resolved` false, so `hide_unmatched` does NOT hide the releases — the real discography shows unplayable instead of an empty page. The album-search fallback is SUPPRESSED in spine mode: searching by name returns the prominent act's records, which under the wrong artist's page is worse than nothing.
- **The warm moved** from before the release-group fetch to inside its callback (it needs the spine); unambiguous artists are unaffected in timing terms since the RG list is cached 14d. The DETAIL page passes the same spine via the new sync `API::peekReleaseGroups` — without it drill-in could resolve a different service artist than the tile did (the 0.18.0 class of bug).
- **Artist photo:** the same-name rows no longer use `_artistImg` — that proxy is keyed by NAME, so every act sharing it got the SAME (prominent) photo. A confidently wrong picture on every row of a list whose purpose is telling acts apart is worse than none; they use the person icon.
- **KNOWN, NOT FIXED:** the BIO and the LOCAL album list are still name-keyed, so a secondary act still shows the prominent act's biography and can match against the wrong library albums. Same fix shape (scope by mbid / suppress when ambiguous); deferred deliberately rather than bundled half-done.
- **BUG IN 0.43.1's OWN FIRST CUT, caught in the field the same session: the read key and the write key diverged.** `getCandidates` wrote the pool under `dsc:cand:...:mb:<mbid>` while `peekPool` still read `_candKey($svc,$artist)` — name-keyed — so the render never saw what the warm fetched and kept matching against the stale prominent-act pool. The fix appeared to do nothing (Simon: "it is installed", and it was). **`peekPool`/`peekMatches` now take the mbid and derive the key with the same `_candKey` call**, and a regression test asserts read-key == write-key. RULE: a cache whose key gains a scope must have EVERY reader updated in the same change — a split read/write key fails silently and looks exactly like the fix not working.
- Gates: `perl -c` clean on API/Sources/Browse; **10 new assertions driven through the REAL `_resolveArtist`** with the field data (rapper spine → rapper's service id, ska spine → ska band, winner's albums reused not refetched, no-corroboration → unresolved, single-candidate and no-spine paths byte-identical to before, cache keys separate the acts while leaving ordinary artists' keys untouched) + the 7 same-name row assertions still green; `matcher_sync_check.py` **exit 0** (no shared sub touched — `_resolveArtist`/`_sameName`/`_spineScore` are new DSC-only call-site logic, the sibling of the 0.24.0 Local-gate exception). No `CAND_CACHE_V` bump — the candidate SHAPE is unchanged and the new keys are self-populating.
- **Live verify after install:** search "Madness" → tap the horrorcore rapper → expect *Open Corpse* with a Qobuz/Tidal match (log: `Qobuz: 'Madness' is ambiguous - <id>=N, <id>=M spine titles`), NOT "No releases found"; tap the ska band → its 107-release discography unchanged.

### 0.43.0 (2026-07-18) — same-name artists: MusicBrainz disambiguation section in search
- **Field (Simon): several different acts share one name, and only ONE was reachable.** Searching "Madness" found the ska band on every service; MB's **seven other** artists of that name (horrorcore rapper, US funk rock group, Indiana black metal, …) did not appear in Discography's search at all, and every entry route — the plugin's own name search, or Search Hub handing off by name — resolved to the same prominent act. Wrong discography, no way to correct it.
- **Why the services can't fix it:** their search returns whichever same-named acts they carry, under one indistinguishable string. Verified live on Deezer's public API: **eight** artists literally named "Madness" (the band = id 1825, 84 albums / 260489 fans; the rest 0-34 fans). No string operation separates them. **MusicBrainz models them as separate artists WITH disambiguation comments** — verified live: `artist:"Madness"` returns the ska band at score 100 ("English pop/ska band", GB, Group) and the others at 68-70, each with its own comment. That comment is the only thing that makes a list of identical names usable.
- **`API::getArtistCandidates` now returns `disambiguation` / `country` / `type`** — MB has always sent them; the sub kept only `{mbid,name,score}`, which is enough to pick a winner and useless for showing the alternatives. **Now cached** (`dsc:acand:1:<lc name>`, 14d, empty results cached too, HTTP failures not) — it moved from the rare wrong-tag path to every artist search, so one request per name and nothing on a repeat.
- **`Browse::_withMbCandidates`** appends an **"Other artists with this name"** section to the search results (both the cached and the fresh path finish through it), shown **only when MB has >1 artist by that name** — a single candidate is the act the streaming rows already lead to, so it would just be a duplicate row. **`_mbCandidateRow`** enters by **`mbid` fixedParams**, which `_discographyView` takes as a resolved identity and browses directly (uuid-gated, line 730) — entering by NAME would resolve straight back to the prominent act and defeat the whole section. Label = disambiguation · type · country, with a `SAME_NAME_NOINFO` fallback so a comment-less candidate is never a blank line2.
- New strings `PLUGIN_DISCOGRAPHY_SAME_NAME` / `_SAME_NAME_NOINFO`; reuses the shipped person `_MTL_` icon (no new asset).
- **Consumer note (Search Hub 0.11.2):** its artist rows hand off to Discography BY NAME, so only the leading act can be handed off — secondary same-name acts keep Search Hub's own view. Handing SH the mbid per act (resolved by matching each act's catalogue against these candidates — the same overlap test) is the follow-up that closes that loop.
- Gates: `perl -c` clean on API/Sources/Browse (stub harness rebuilt — it is wiped on each day rollover; `Slim::Utils::Log` needs `logger` EXPORTED, plus `Slim::Schema`, `SimpleAsyncHTTP` and `JSON::XS::VersionOneAndTwo` stubs); **7 behavioural assertions driven through the REAL `_mbCandidateRow` with MB's verbatim Madness candidate set** (enters by mbid not name, comment/type/country labelling, three acts → three DISTINCT entry mbids, comment-less fallback). No matcher change — `matcher_sync_check.py` N/A. No candidate-cache bump (`dsc:cand` shape unchanged); the new `dsc:acand:` key is self-populating.
- **Live verify after install:** search "Madness" → streaming rows, then the section with the ska band + rapper + funk group, each labelled; tapping the rapper must open ITS discography, not the ska band's.

### 0.42.2 (2026-07-18) — code review of 0.37.0-0.42.1: search-walk hijack + degraded-result caching
Review pass over the whole uncommitted 0.37-0.42 block (search feature + app-root redesign). Two real bugs, both verified before fixing; one flagged finding measured and WITHDRAWN.
- **BUG (confirmed by live reproduction): a positional walk carrying `item_id` + `search:` was hijacked by the param-addressed search dispatch.** 0.37.1's dispatch ran before any item_id check, so the results were returned as the TOP feed and XMLBrowser then descended the item_id path INTO them (`_cliQuery_done` splits item_id and indexes `$feed->{items}` positionally). **Live proof on the box:** root-view `item_id:5` + `search:The Beatles` rendered title **"The Beatles Tribute Band"** — exactly result index 5 — instead of the result list. Side effect: `_artistSearch` + the row's `passthrough` were unreachable dead code despite the comment claiming they served legacy walks.
  - **Fix:** dispatch gated on `item_id` being absent (`$walking`), which also replaces the duplicated item_id test in the ctx-restore branch. The legacy path is RESTORED, not merely disabled — Control/XMLBrowser.pm:493 hands the text to the row's coderef as `$args->{search}` again.
  - **Verified safe for Material** before changing anything: the served item JSON for the search row carries `go.params = {search: __TAGGEDINPUT__, menu: 1}` — **no item_id** — and Material's `item_loop` branch (browse-resp.js:278) types the row from the server's own go-params. The item_id-adding construction at browse-resp.js:2319 is the `loop_loop` legacy branch, which `menu:` mode has bypassed since 0.2.2.
- **BUG: a service timeout/error pinned a silently-degraded result list for the full 10-min `SEARCH_TTL`.** `searchArtists`' `$settle` collapsed error/timeout into an empty list — indistinguishable from "this service has no such artist" — and `_artistSearchView` cached unconditionally. One slow Qobuz call meant every retry inside the window was served the short list from cache without re-searching.
  - **Fix:** `searchArtists`' callback gained a **second arg `\%failed`** (`{ svc => 1 }` per errored/timed-out service; `$settle` already knew, it just discarded it). `_artistSearchView` skips the cache write when `%failed` is non-empty — the user still SEES what came back, it just isn't remembered, so retrying re-searches. Contract documented on the sub.
- **WITHDRAWN (my own finding, disproved by measurement):** I flagged `randomAlbumCovers`' `albums sort:random` as an expensive full-table sort blocking the event loop on every root render. **Measured against the live 2900-album library: 41-68ms round trip vs 41-48ms for the IDENTICAL query without `sort:random`, over a 23ms baseline** — i.e. `sort:random` costs nothing measurable and the whole query is ~20ms, in line with `localAlbums`, which the fleet already accepts as a sync query. No change made. (Lesson, same class as the 0.31.1 WebFetch one: measure before asserting a perf claim.)
- **Cleanups:** `_searchResultRow`'s conditional `line2` and its comment still described the 0.39.0 app-root spotlight, removed in 0.40.0 — search results are now the only caller and `mergeArtistHits` always records >=1 source per bucket, so the conditional was dead; collapsed to an unconditional `line2`. `_rootView` probed `adapters()` **three** times per render (via `_searchRow`->`orderedSources`, `serviceStatus()`, and the icon map) — `serviceStatus` now takes an OPTIONAL pre-built adapters list (omitted = probe as before, so Settings.pm is untouched) and the root view passes one hoisted call. Perf gain is negligible; the point is removing the duplicated capability probe.
- Gates: `perl -c` clean on all 5 modules (stub harness rebuilt — it is wiped on each day rollover); **new t_0422.pl 35 green** (the field walk-hijack case + the restored legacy walk end-to-end, cache-skip on failure incl. the retry-heals-and-then-caches sequence, cache-hit short-circuit, undef-failed-map defensive path, searchArtists' failure contract, serviceStatus both call shapes, line2, and a mergeArtistHits relevance-gate regression); `matcher_sync_check.py` exit 0 (no shared sub touched). No cache-version bump — `dsc:asearch:2` entries stay valid, the fix only changes WHEN one is written.
- Live re-verify after install: `["discography","items",0,30,"item_id:5","search:The Beatles","menu:discography"]` must NOT return "The Beatles Tribute Band" (pre-fix it did); the paramless `search:` form must still return ~16 gated rows with The Beatles first.

### 0.42.1 (2026-07-18) — fix: missing MAI & Material badge icons (0.42.0 regression)
- **Field (Simon): MAI and Material Skin badges showed no icon.** Two causes, both found live: (1) `_pluginDataFor('icon')` is NOT always a relative path — MAI returns a **full remote URL** (`https://www.herger.net/slim-plugins/icons/mai.svg`), which 0.42.0's blind `/`-prefix turned into `src='/https://…'` (broken); (2) **Material Skin exposes no plugin icon** (`_pluginIcon` undef) so its badge was a bare spacer. (The Discography context menu itself was fine — served correctly in `customactions.json`; Simon confirmed he'd looked in the wrong place.)
- **Fix — `badgeSrc` normaliser**: remote `http(s)://` icons route through LMS **imageproxy** (`/imageproxy/<uri-escaped>/image_96x96_f.png` — server-cached, same-origin; verified live 200 image/svg+xml); relative paths get a single leading `/`; already-absolute paths pass through unchanged. Material Skin badge hardcoded to its served asset `/material/html/images/icon.png` (verified live 200). Streaming badges (Qobuz/Tidal/Deezer) were already relative → unaffected, still fine.
- Scratchpad stub harness (wiped on the day rollover) rebuilt minimally; `perl -c` clean both modules; **new t_badge.pl 11 green** (every badgeSrc branch: relative-anchor, absolute-passthrough, remote→imageproxy, absent→spacer+cross, enabled→tick, all-dead-rows). Live re-verify after install: MAI row → imageproxy src, Material row → skin icon, both ticked.

### 0.42.0 (2026-07-17) — "Works best with" redesigned: badge rows w/ tick/cross + About↔Search gap
- **Simon: add the streaming service badges to each service row, linespace them (felt crowded), tick instead of "detected"; plus a line space between the About section and search.** Status rows became dead v-html TEXT rows (the proven banner/prose route — plain list rows give no spacing/badge control): each lays out the plugin's OWN icon as a 42px badge (root-absolute `/plugins/.../icon.png` via `Sources::_pluginIcon`; MAI/Material get theirs the same way when enabled), bold name + green tick `&#10003;` (installed) or muted cross `&#10007;` + "not installed" on the role line, `margin:10px` vertical breathing room. Badge geometry mimics a native icon row (16px indent + 42px badge + 14px gap = text at the 72px avatar column). A NOT-installed plugin has no local logo to serve — spacer div keeps alignment (deliberate: no bundled brand images). Ticks/crosses are HTML entities per the no-non-ASCII-literals rule; `SVC_DETECTED` string now unused here but KEPT (Settings.pm still uses it).
- **About↔Search gap**: `_proseRow` gained an optional extra-style arg; `ABOUT_2` row carries `padding-bottom:24px` — gap lives INSIDE the row, item count/shape untouched (walk stability).
- Gates: `perl -c` clean; view suite **33** (5 ROLE_ rows, dead rows, cross-when-absent, no-img spacer, tick-when-enabled via isEnabled flip, ABOUT_2 padding) + routing 20 + merge 32 = **85 green**. No matcher change; no cache bump.

### 0.41.1 (2026-07-17) — banner: BANNER_MAX 12 -> 20 (Simon: "go higher on the album count")
- 20 x 132px (tile+gap) fills up to ~2600px ultrawide; anything narrower still clips to what fits. Test expectations updated; 80 green.

### 0.41.0 (2026-07-17) — banner cover-count scales with the display (responsive one-row clip)
- **Simon: can the amount of artwork scale with the window? Material has PWA layouts per device.** Directly no — one server-rendered feed serves every client and Material's breakpoints never reach plugin rows. **Route: send MORE tiles than any screen needs and let pure CSS decide what shows.** `BANNER_MAX` 12 tiles at a FIXED `BANNER_TILE_PX` 120px; container `flex-wrap:wrap` + `max-height:120px` + `overflow:hidden` + `justify-content:center` — what doesn't fit the width wraps to a second row that the clip hides, so the visible strip is exactly the complete tiles that fit: phone ~3, tablet ~5-6, desktop ~9+, self-adjusting on resize/rotation. Hidden tiles cost only local LMS-resized thumbnail fetches. (`RANDOM_COUNT` retired.)
- Gates: `perl -c` clean; view suite 28 (12 imgs, responsive-clip styles asserted) — **80 green** total. No matcher change; no cache bump.

### 0.40.1 (2026-07-17) — banner: random ALBUM COVERS replace artist photos (the blank-tile fix)
- **Field (Simon, 0.40.0 confirmed rendering — the v-html `<img>` route WORKS in Material): one banner tile was blank (an artist MAI has no photo for), switch to random album covers.** New **`Sources::randomAlbumCovers($n)`** replaces `randomArtists`: one `albums sort:random tags:j` CLI query (server-side random, verified live — fresh order per call, no Perl shuffle), keeps only albums WITH `artwork_track_id` (pool 3x the ask), returns root-absolute `/music/<coverid>/cover_300x300_f.jpg` URLs — **a blank tile is now impossible**, and the MAI gate is gone (covers need no MAI). `_artistCollageRow` -> **`_coverCollageRow`**: same centred flex strip, `border-radius:8px` (square covers, not the artist-circle idiom). Suppressed only when the library has no artwork at all.
- Gates: `perl -c` clean both modules; view suite reworked for covers (count/filter/URL shape, dead-row, 4 imgs, artless-library suppression; the re-roll is the server's own sort:random — verified live, not mock-testable) — **79 green** total (view 27 + routing 20 + merge 32). No matcher change; no cache bump.

### 0.40.0 (2026-07-17) — root banner: decorative browser-composed artist-photo collage (replaces the 0.39.0 spotlight rows)
- **Simon on the 0.39.0 spotlight: small list rows are "not much use"; can't force tiles (correct — grid is whole-view and ANY text row kills it, the About prose is staying); wants the random artists "combined as a png or jpeg… decorative only", not clickable.** Server-side composition is off the table (fleet rule: no GD/Imager). **Route taken: ONE non-clickable text row whose v-html is a centred flex strip of `<img>` tags — the BROWSER composes the collage.** Circular (border-radius:50%, Material's artist idiom), `width:21%;max-width:150px`, flex-wrap for narrow screens; srcs are ROOT-ABSOLUTE `/imageproxy/mai/artist/<uri-escaped name>/image_300x300_f.png` (root-absolute because Material's page lives at /material/ — a relative src would resolve wrong; the MAI proxy serves its silhouette on a miss, never a broken img). Fresh `randomArtists` roll per render.
- **`_artistCollageRow`** returns undef (row skipped) when MAI is disabled (four silhouettes duller than nothing) or the library is empty. The 0.39.0 spotlight section + `RANDOM_HDR` string removed; `Sources::randomArtists` stays (now feeds the banner); `_searchResultRow`'s conditional line2 kept (search results still use it). Root order: banner → About → Find an artist → Works best with.
- **UNVERIFIED-UNTIL-INSTALL: Material rendering `<img>` inside a text row's v-html.** The prose `<div>` styling is verified live (0.9.5), raw img tags are the same v-html path but have never been tried — if Material sanitises them, the banner shows nothing/garbage: check by eye first thing. (If it fails, fallback candidate: a plugin-registered HTTP handler that 302s to a random artist's proxy image — single image, still no server-side composition.)
- Gates: `perl -c` clean; view suite **29** (banner leads at 12 rows w/ library+MAI; suppressed w/o MAI — About leads; dead text row, 4 imgs, escaped root-absolute srcs; re-roll proven) + routing 20 + merge 32 = **81 green**. No matcher change; no cache bump.

### 0.39.0 (2026-07-17) — root page: random-artist spotlight on top, search moved below About
- **Simon: "move search below About Discography and add some artwork from random artists at top, randomised each time it's opened."** New root order: **From your library** (spotlight) → About → Find an artist → Works best with.
- **`Sources::randomArtists($n)`** — one sync `artists` CLI query over a capped pool (`RANDOM_POOL_MAX` 2000; the artists query has no sort:random — albums does, artists doesn't), Perl-shuffled per call (re-rolls every open), "Various Artists"/junk filtered, returns `[{name, artist_id}]`.
- **Spotlight section** (`RANDOM_COUNT` 4 rows, `RANDOM_HDR` "From your library", library_music MTL header icon): rows are `_searchResultRow`s — MAI artist photos (the Similar-artists imagery), param-addressed drill straight into each artist's discography (so it's a discovery shelf, not decoration). `_searchResultRow`'s line2 became conditional (sources present = search result; absent = spotlight row, no line2). Empty library / failed query -> section skipped.
- **Walk-safety note:** the re-roll makes the root non-deterministic across renders; Material taps are immune (param-addressed itemActions), a legacy positional walk may land on a different random row — accepted, same class as the 0.37.2 classic-skin corner (documented in-code).
- Gates: `perl -c` clean both modules; view suite grew to **27** (randomArtists count/VA-junk filter/ids kept; root 16 rows w/ library, spotlight leads, row shape link/no-line2/param-addressed, re-roll proven across renders; About-leads + search-below-About when library empty) — **79 green** total w/ routing 20 + merge 32. No matcher change; no cache bump.

### 0.38.1 (2026-07-17) — root-page copy tweaks (Simon's wording)
- `SEARCH_HDR` "Find any artist" -> **"Find an artist"**; `ABOUT_1` replaced with Simon's text (typos corrected: that's/Deluxe/comma fixes): full discography from MusicBrainz, plays from library or chosen streaming services if available, artwork/dates/reviews/bios, releases grouped so you can pick the version (Deluxe, Remastered), currently supports Qobuz, Tidal & Deezer. Strings-only — no code change, no test impact (`&` is safe: prose rows pass through `_escHtml`).

### 0.38.0 (2026-07-17) — app-root page redesigned: sectioned, on-brand, search made prominent
- **Simon: "the plugin's main page is a tad dull — add a brief description, what plugins get the most out of it, and make the search more noticeable. Break things up with headers like we do and keep on brand."** New `Browse::_rootView` replaces the two bare hint rows, built in the artist view's own visual language (`_sectionHeader` dividers — real headers under Material `features:hi`, text dividers elsewhere; `_proseRow` 72px indent; shipped MTL/_svg icons only):
  - **"Find any artist"** (search MTL icon) — the search row under its own header, now with a dynamic line2 naming what it searches (`orderedSources()` names in priority order: "Local · Qobuz · Tidal · Deezer" — same names the result rows use; disabled sources drop out).
  - **"About Discography"** (plugin vinyl _svg icon) — two prose rows: what the plugin does (`ABOUT_1`) and the two entry points (`ABOUT_2`).
  - **"Works best with"** (tune MTL icon) — LIVE plugin-status rows: Qobuz/Tidal/Deezer via `serviceStatus()` (service's own icon when installed, dsc-blank fallback), MAI and Material Skin via `PluginManager->isEnabled`, each `type => 'text'` + image (XMLBrowser styles text rows itemNoAction → dead status readouts) with line2 "role · detected/not installed" (roles: `ROLE_STREAM`/`ROLE_MAI`/`ROLE_MATERIAL`; status reuses `SVC_DETECTED`/`SVC_NOT_DETECTED`).
- Strings: `APPS_HINT`/`APPS_HINT2` retired (verified unreferenced); new `SEARCH_HDR`, `ABOUT_HDR`, `ABOUT_1`, `ABOUT_2`, `PLUGINS_HDR`, `ROLE_*`. No new images.
- Root view stays fully deterministic (pure prefs + plugin detection — walk-safe for legacy positional clicks); Material taps unaffected (search is param-addressed, status rows are dead).
- Gates: `perl -c` clean; suites updated for the new shape — view 19 + routing 20 + merge 32 = **71 green** (root sections/row count, search-row line2 sources, five status rows, all routing shapes unchanged). No matcher change; no cache bump. Live check of headers on the real Material client (does the Apps-menu entry carry `features:hi`?) pending install — text dividers are the graceful fallback if not.

### 0.37.2 (2026-07-17) — fix: app stuck on the last artist view, root/search view unreachable
- **Field (Simon): after a search + drill, backing out and re-entering Discography re-opened the LAST view — no way back to the main app view.** Cause: topLevel treated EVERY paramless request as a walk re-entry and restored `%lastCtx`, so the Apps-menu entry (paramless by construction) always resurrected the stashed artist. Tolerable when the root was just a hint page; a trap now the root carries the search.
- **Fix: the stash is restored ONLY for positional WALK requests — gated on `item_id` presence in `$params`.** Verified in LMS 9.0 source (Control/XMLBrowser.pm:148): the top-level coderef call gets `params => $request->getParamsCopy()`, so a walk's `item_id` is visible to the feed while a genuine app-root entry (Apps menu / Material re-fetching the root) has none → falls through to the root (search + hints) view. Ctx itself is untouched: deeper clicks still re-run the feed with item_id and rebuild the identical stashed view (walk determinism unchanged), and every Material tap is param-addressed anyway (0.34/0.35/0.37.1).
- **KNOWN (accepted): classic-web-skin corner** — with an artist stashed, the classic skin's app root now shows the root view but its positional clicks resolve against the stashed artist tree (mismatch). Material — the deployment target, all param-addressed — is unaffected; pre-0.37.2 the same skin had the inverse quirk (root stuck on the artist). Fleet precedent: Material-first, legacy best-effort.
- Gates: `perl -c` clean; view suite now **17** (root-entry-despite-stash renders the root view; paramless+item_id still restores ctx — async artist build under stubs is itself the proof) + merge 32 = **49 green**; sync check exit 0 (no matcher change); no cache bump (pure view routing).

### (2026-07-17, no version) — DECLINED: search-time entity folding of duplicate service artists
- **Field: Qobuz carries BOTH "Beatles" and "The Beatles" (same releases); also "Chocolate Watchband" / "The Chocolate Watch Band" / a TYPO'd "The Chocoloate Watch Band" — asked to fold into one search row.** An article + spacing + one-internal-edit fold was designed and part-built, then **REVERTED on Simon's call: "we should not be trying to rectify streaming service errors" — keep them separate.** The principle he set for any future revisit: **string similarity alone must never merge — a merge would have to be DISCOGRAPHY-VERIFIED** (corroborate that the entities' release lists actually overlap, the 0.28.x library-disambiguation philosophy), because one-edit-apart names are routinely genuinely distinct acts ("Beatles"/"Beatless", "Iron Maiden"/"The Iron Maidens"). Not built — a discography check per search hit costs a per-candidate album fetch at search time; revisit only if the duplicates prove annoying enough to pay that. Decision + rationale also in the `mergeArtistHits` header comment (comment-only diff vs the shipped 0.37.1 zip — code identical, zip NOT rebuilt). Cross-service dedupe of IDENTICAL normalised names stays (that's the same name, not an error correction).

### 0.37.1 (2026-07-17) — search fixes: relevance gate (the Beatles-junk report) + param-addressed submission (stale-walk break)
- **Field (Simon: "this is not returning what I asked for" / "search The Beatles and look"). Reproduced live over HTTP — TWO defects:**
  1. **Junk results.** The right row came FIRST (The Beatles, Local · Qobuz · Tidal · Deezer), but 34 rows of service relevance-tail followed: Qobuz tribute/cover acts ("The Beatles Revival Band", "Beatless") and — worst — **Tidal's artist search returns RELATED artists** (Led Zeppelin, Pink Floyd, The Monkees, Paul McCartney… no textual relation to the query at all). 0.37.0 trusted service relevance; wrong.
  2. **Stale-walk break.** With an artist ctx stashed, the positional `item_id:0 + search:` submission walked the ARTIST view and landed on the Biography row → "Empty" (verified live: stash Radiohead, submit search → title "Biography", 1 empty item). That's the mainline "search again after viewing a result" flow, not a corner.
- **Fix 1 — relevance gate in `mergeArtistHits`** (pure, gate documented in-code): a hit survives only if exact-key equal, OR the normalised query is a SUBSTRING of the normalised name (partial typing: "beatl" → The Beatles; NB this admits prefix-supersets like "Beatless" for query "beatles" — same behaviour as LMS's own token-prefix library search), OR `_artistMatch` token-subset either way ("Beatles" ↔ "The Beatles", tribute acts CONTAINING the phrase). Led Zeppelin-class free association drops; punct-only queries admit exact only. Result list capped `SEARCH_MERGED_MAX` 30. Calls the shared `_artistMatch`, does NOT modify it — sync check exit 0.
- **Fix 2 — param-addressed submission.** The search row's `go` action is now OVERRIDDEN via `itemActions` with `fixedParams { search => '__TAGGEDINPUT__', features }` — verified in source both sides: XMLBrowser's search branch builds its positional action first but the itemActions pass runs AFTER and replaces `go` while keeping `input` (Control/XMLBrowser.pm:1188 vs :1274); Material types a row as a search input purely from go-params carrying `__TAGGEDINPUT__` under `search` (browse-resp.js:279) and substitutes the term into those params on submit (browse-functions.js:2885). So the submitted command is `search:<text>` + features, NO item_id; new **topLevel search dispatch** (BEFORE ctx stash/restore, raw param not `_cleanParam` — typed text may start with '$') renders `_artistSearchView` directly. Ctx-independent, walk-free, ctx untouched. Handler refactor: `_artistSearch` (url coderef, legacy classic-web-skin walks) delegates to `_artistSearchView`; literal-`__TAGGEDINPUT__`/blank queries return empty without searching.
- **Cache: `dsc:asearch:` 1 → 2** (fleet bump rule — 0.37.0's cached UNGATED merged lists are disk-persisted and would otherwise serve for up to 10 min post-install).
- Gates: `perl -c` clean both modules; **48 assertions** (32 merge incl. the live Beatles fixture verbatim — 7 related-artist names dropped, contains/superset/subset kept, partial typing, cap, punct-exact-only; 16 view incl. THE FIELD CASE: stash artist → param submission → results render, ctx preserved after, placeholder guard, cached re-query, legacy coderef path); `matcher_sync_check.py` exit 0. Live re-verify after install: fire `["discography","items",0,30,"search:The Beatles","menu:discography"]` (no item_id) — expect ~6 gated rows, The Beatles first.

### 0.37.0 (2026-07-17) — global artist search from the plugin view
- **Simon: the plugin view only pointed at the artist context menu — add a global search so any artist can be reached by typing.** New standard XMLBrowser **`type => 'search'` row** ("Search for an artist") in BOTH the Apps hint view (first row; hints reworded below it) AND the artist list view's Options section — needed because after any artist browse the app re-opens on that artist (the `%lastCtx` model), which would strand the Apps-view search. Submission mechanics verified in LMS 9.0 `Control/XMLBrowser.pm`: the client re-sends the command with `item_id` + `search:<text>`, the walk descends to the row and calls its url coderef with `$args->{search}` (line 493) — walk-safe because the paramless re-fetch rebuilds the identical view from ctx (the same determinism every other row relies on).
- **`Sources::searchArtists($client,$query,$cb)`** — one artist-TYPE search per enabled service in parallel (new standalone `_artistsQobuz/_artistsTidal/_artistsDeezer` + shared `_artistHits` shape guard/cap; the exact `search` calls the artist-first candidate fetch opens with, `query_enc` chars/bytes discipline preserved) + a sync Local leg (the same `artists search:` CLI query as `localAlbums`' name fallback, hits keep their contributor id). `SEARCH_TIMEOUT` 10s watchdog per service, settle-once, error/timeout settles as an empty list; results NOT cached at this layer (user-initiated, one request per service).
- **`Sources::mergeArtistHits($query,$bySvc,$order)`** — pure merge/dedupe/rank: bucket key = matcher `_norm` (fallback `_punctNorm` for names `_norm` empties, e.g. "( )"), so cross-service spelling variants collapse while genuinely distinct names ("Laetitia Sadier" vs "Laetitia Sadier Source Ensemble" — Simon's example) stay separate rows. Display name + `artist_id` from the FIRST source to introduce a bucket (order = Local, then adapter priority). Rank: exact-normalised query match first, then breadth (more sources = more likely the meant act), then first-seen relevance. Internal sort keys stripped from the result.
- **Browse:** `_artistSearch` handler caches the MERGED list 10 min (`dsc:asearch:1:<lc query>`, `SEARCH_TTL`) purely for item_id-walk determinism on legacy re-walks (Material taps use the rows' param-addressed itemActions and never re-walk); empty/whitespace query → empty; no hits → `SEARCH_NONE` text row. `_searchResultRow` = the `_similarLinkRow` drill by name **plus `artist_id`** when Local knows the artist (library-tag resolution path applies), MAI `_artistImg` thumbnail, line2 = source names ("Local · Qobuz · Deezer" — Simon's call). New strings `PLUGIN_DISCOGRAPHY_SEARCH`/`SEARCH_NONE`; APPS_HINT wording updated; new placeholder icon `dsc-find_MTL_icon_search.png` (Material maps the name to its own search glyph).
- **No topLevel changes** — the search text rides the standard walk, artist identity params are untouched, and result-row taps are fresh param-addressed top entries.
- Gates: `perl -c` clean (Browse + Sources, session stublib); **33 new assertions** (20 merge: dedupe/exact-vs-breadth/relevance tiebreak/diacritic collapse/punct-fallback/junk+cap guards; 13 view: hint-row placement, blank-query guard, row shapes incl. fixedParams + passthrough, cached re-walk skips re-search, no-results row); `matcher_sync_check.py` exit 0 (no shared sub touched); no candidate-cache bump (new `dsc:asearch:` key is self-populating). Live end-to-end (Material search input → results → drill) pending install.
- **Also this session: scoped the no-MusicBrainz streaming-spine fallback** (see the PLANNED section above) — deliberately not built.

### 0.36.0 (2026-07-15) — fix: Stage-2 list toggles broke bio/paging on the primary (mbid-less) entry; code-review cleanups
- **Bug (code review, CONFIRMED live on the box before fixing): on the normal artist entry (custom action sends `artist_id`/`$TITLE`, NO mbid), the bio "Read more" / section "Show more" toggles did nothing.** 0.35.0's `_identParams` folded the RESOLVED artist mbid into every list-view `itemActions`, but the Material entry/refresh command carries no mbid — so topLevel's `$same` identity check (`artist_id`+`artist`+`mbid`) mismatched on the toggle dispatch AND on the subsequent refresh, wiping the very expand/`page` ctx flag the toggle had just set (the 0.8.1 bug, re-introduced by Stage 2). Detail toggles were unaffected (their `rg` actions carry the resolved mbid on BOTH entry and refresh, so `$same` holds); paging INSIDE a sort-toggled view also happened to work (the sort toggle injects the mbid into that view's own entry command) — which is why the breakage was inconsistent.
  - **Live proof (Marc Almond, artist_id 46825):** fire `item:bio:more`+`mbid:<resolved>` (sets the flag → returns "Empty"), then re-issue the mbid-less entry command (the parent refresh) → bio came back COLLAPSED. Control: re-issue WITH the mbid → EXPANDED. B vs control differ only by the mbid, isolating the cause.
  - **Fix:** `_buildList` now keeps the resolved mbid on `$opts->{mbid}` (detail actions need it) AND stashes the ENTRY mbid separately as `$opts->{entry_mbid}`. `_identParams` (LIST-view identity) emits the ENTRY mbid — present only for a band-link entry, which carries it end-to-end; a person/name entry emits none, matching the mbid-less refresh command so `$same` holds. `_rgIdent` (DETAIL actions) adds the resolved mbid explicitly, so `_rgView` can still fetch the RG list. Band-by-mbid views unchanged (entry==resolved). No `%lastCtx`/`$same` logic changed — only what the actions emit.
- **Code-review cleanups (same pass):** the triplicated "render feed privately → find row by `id` → run its coderef (else empty)" collector is now one pair of helpers — **`_findRow`** + **`_runRow`** — used by `_listItemDispatch`, `_rgView`'s item branch, and (`_findRow` only) `playCommand`. `playCommand`'s direct-url branch now REJECTS a present-but-non-whitelisted `url` explicitly (a `$log->warn` + `setStatusDone`) instead of falling through to the misleading "missing rg" path — a lib: tile carries a url and no rg, so once a url is present that is the only path it can take.
- **Deliberately NOT changed (efficiency finding, reviewed with Simon):** every list-control tap does a full private `_discographyView` rebuild to locate its row. That rebuild IS the durability mechanism (the pre-Stage-2 cheap ctx-walk is exactly what caused the empty-page-on-back-nav bug), so it stays — the rebuild cost is the accepted price of correct back-navigation.
- Gates: `perl -c` clean (Browse + Plugin w/ WEBUI stub); Stage-1 suite still 19/19; **14 new assertions** (person list actions omit mbid; band list actions carry it; detail actions keep the resolved mbid; sort-toggle flip; lib play url; invalid-sort omission). No matcher change (sync N/A); no cache bump. Live re-verify of the Read-more round-trip pending install.

### 0.35.0 (2026-07-15) — param-addressed navigation, Stage 2 (list-view controls)
- **Completes the stale-view fix for the LIST view's own controls** (Stage 1 = tiles/detail/play in 0.34.0). Every actionable list row is now self-identifying via `itemActions` + a row `id`, dispatched by the new `item:`-without-`rg:` branch in topLevel → **`_listItemDispatch`** (private `_discographyView` render → find row by id → invoke its coderef; same collector pattern as `_rgView`, zero logic duplication; unknown id → empty + the row's nextWindow refresh re-renders clean).
- **Row ids:** bio `bio:more`/`bio:less`; Refresh `act:refresh`; paging `page:<KEY>:<target>` (`_pageSection`/`_pageRow` gained an `$opts` arg; absolute targets kept); section headers `sect:<KEY>` (type groups by group key + `sect:BIO`/`OPT`/`EXTRAS`/`APPEAR`/`BANDS`/`SIMILAR`; `_sectionHeader` gained an optional `$act` arg, applied only when headers are real). Detail's review header got its Stage-1 id (`hdr:review`).
- **Sort toggle = a fresh entry with an explicit `sort:newest|oldest` param** (not an item dispatch): keeps the drill-in UX, and `_identParams` (refactored out of `_rgIdent`) folds a VALID sort into every action's params — so inside a sorted view, toggles/paging re-issue the sorted command on refresh and the order sticks end-to-end. topLevel validates + threads `sort` into `$opts` (falls back to the pref).
- **Library-extras tiles** (`lib:<album_id>`): go dispatches to their tracklist coderef; play/add/insert carry the tile's core-resolved `db:album.id=N` play string to **playcmd's new direct-url mode** (whitelisted `^db:album\.id=\d+$` — no resolution step, no rg needed).
- Gates: `perl -c` clean; 18/18 new Stage-2 assertions (ident sort validation, list-action shapes, lib play url, page-row ids, header act gating, sort-toggle flip) + Stage-1 suite still 19/19. Live verify pending install. No matcher change; no cache bump.

### 0.34.0 (2026-07-15) — param-addressed navigation, Stage 1 (the stale-view fix)
- **Field bug (Marc Almond): browse another artist, go BACK to the previous artist's view, tap an album → empty page / play dead until a Refresh.** Full diagnosis in "Stale-view bug + param-addressed navigation plan" above (one-artist `%lastCtx` + positional item_ids; XMLBrowser's session cache is disabled for coderef feeds). Stage 1 makes every tap that mattered SELF-IDENTIFYING via XMLBrowser `itemActions` (explicit `fixedParams`, no positional walk):
- **Tiles** (`_releaseItem`): `itemActions.items` carries `rg:<rg-mbid>` + full artist identity (built by `_rgIdent`/`_rgItemActions`); matched tiles also get `play`/`add`/`insert` → the new `['discography','playcmd']` dispatch. **topLevel** gained `rg:`/`item:` params: `rg:` routes to **`_rgView`**, which re-stashes ctx (params carry the identity), resolves the RG from the cached list and renders `_releaseDetail` directly — durable across any navigation order, restarts, other artists.
- **Detail rows** (`_releaseDetail`): every actionable row gets an `id` (`v:<Svc>:<n>` version rows, `ver:show/hide` + `rev:more/less` toggles, `hdr:<Svc>` service headers, `act:refresh`) + per-item `itemActions` addressing `rg + item`. An `item:` request renders the detail PRIVATELY in `_rgView` and invokes the matched row's own url coderef — toggles/version drills reuse their existing logic, zero duplication. Item-level (not feed-level) actions deliberately: `_makeAction` takes `nextWindow` from the ITEM, so the refresh toggles keep working; a toggle's refresh re-issues the view's command (with `rg` + identity) → `$same` artist → ctx flags preserved → the flip renders.
- **`playcmd`** (`Browse::playCommand`, registered in Plugin.pm `[1,0,1]`): resolves via the SAME cache-backed `_releaseDetail` build (collector callback), picks the `item:`-named row or the kept preferred-source play row, executes `['playlist', play|add|insert, $url]` (all three verified as core commands on the live server). Async CLI (setStatusProcessing/Done).
- **Band + similar rows**: `itemActions.items` = fresh top-level entry by band mbid / artist name — durable, and retires the 0.26.1 known limit (top toggles landing on the person) for taps that come through the action.
- The url coderefs + `%lastCtx` stay untouched (legacy walk path, non-Material skins, walk-stability). Stage 2 (list-view sort/Refresh/paging toggles) deferred — only tappable while the view is current.
- Gates: `perl -c` clean (Browse), Plugin.pm loads clean (WEBUI stubbed), 19/19 assertions on `_rgItemActions` (command/param shapes, playable vs go-only, item ids on go+play, sparse-opts omission). Live end-to-end (Material tap → rg dispatch; back-nav after another artist; tile play) pending install. No matcher change; no cache bump.

### 0.33.0 (2026-07-15) — artist thumbnails load IN-VIEW (MAI image proxy replaces the photo pre-fetch)
- **Field (Simon): "not all artist artwork loads nicely — a user should not have to exit view and back to see them."** The 0.31.x design pre-fetched each photo server-side (fire-and-forget after render, cached) so cold rows rendered the person icon until re-entry — the second-load contract is wrong for images.
- **Fix: rows now point at MAI's own artist image proxy** — `imageproxy/mai/artist/<uri-escaped NAME>/image.png`. Verified in MAI source (ArtistInfo.pm): the handler accepts a NAME or contributor id (`_getArtistFromArtistId` falls through non-numeric as the name; MAI's own related-artists menus build name-based URLs, line 960), resolves local artwork → Discogs/Last.fm → MAI's **default artist silhouette** (never a broken image), and the browser's `<img>` fetches each thumbnail asynchronously through the LMS proxy — photos pop in IN-VIEW, exactly like Material's native artist lists. New `Browse::_artistImg($name)` (person icon fallback when MAI is disabled) feeds `_bandLinkRow` + `_similarLinkRow`.
- **Deleted the whole photo-warm machinery** (0.31.0/0.31.1): `_warmArtistPhoto`, `_peekArtistPhoto`, `_photoKey`, `%photoInFlight`, `PHOTO_*` TTLs — `_warmArtistExtras` reduces to the awaited similar-LIST warm only (that list is data, still cached `dsc:similar:v1` and warmed in the MB chain before `$offDone`, so the section itself is normally in the FIRST render). Orphaned `dsc:artphoto:v2` cache keys just expire (nothing reads them).
- Gate: `perl -c` clean. No matcher change; no cache bump (similar-list key unchanged). MAI's proxy does its own caching server-side.

### 0.32.0 (2026-07-15) — resolve alias-only artist names (The Oh Sees -> Osees)
- **Field (Simon): "The Oh Sees" (a Similar-artists link under Ty Segall) fails to resolve on MB.** Root cause verified live against BOTH public MB and the mirror: our fielded query `artist:"The Oh Sees"` returns **0 results** — the `artist:` search field matches the artist NAME only, and "The Oh Sees" exists solely as an ALIAS of **Osees** (`194272cc-…`). `alias:"The Oh Sees"` scores 100 on public AND on the mirror. Any alias-only name (Last.fm similar-artist lists are full of era names like this) was invisible to `_artistMbidByName`.
- **Fix: a second, alias-field search stage.** `_artistMbidByName`'s `$run` gained a `$field` arg (query built per-field by `$mkQuery`); when the `artist` field yields nothing acceptable (0 results after the mirror→public fallback, or top-hit score <90), it retries ONCE with `alias:"name"` — same quoted-phrase escaping, same score gate, same mirror→public-on-0-results behaviour within the stage. Runs ONLY where we'd otherwise cache a miss, so no working resolution can change. Worst case for a truly unknown name = one extra request on a 1h-cached miss path.
- Flow for The Oh Sees on Simon's box: artist(mirror) 0 → artist(public) 0 → alias(public) → Osees. (A mirror low-score result routes alias through the mirror instead.) Poisoned `dsc:mbid:the oh sees` miss self-heals in 1h, or tap the Retry row / `clearcache`.
- **PORTED to LBF 0.9.96 the same session** (`getArtistMbidByName`, identical two-stage change; the resolver is NOT part of the pinned matcher fleet-sync, so no sync-check impact). NOT ported to `getArtistCandidates` (disambiguation keeps lc-name equality — alias artists can't corroborate by name; separate question, not this bug). Gate: `perl -c` clean on API.pm; no cache-version bump (resolution path only).

### 0.31.1 (2026-07-15) — fix: 0.31.0 thumbnails never appeared (wrong field off MAI's photo callback)
- **Field (Simon): only person icons, no photo thumbnails.** Root cause found in the REAL MAI source (fetched raw, not summarised): `getArtistPhotos` calls back with **OPML rows** — the photo URL is each row's `image =>` field (`name` is the credit; the not-found row has no image) — while 0.31.0 read `$p->{url}` (a field those items never carry, from a paraphrased WebFetch of the INTERNAL `_getArtistPhotos` shape). So every lookup "found nothing" and pinned a 1-day negative. Fix: read `image`; **photo cache key `dsc:artphoto:v1` → v2** so the poisoned negatives are bypassed immediately on install. `getRelatedArtists`' shape re-verified against source while at it — as coded (items w/ `name`, error rows `type=>'text'`), so the Similar Artists LIST was unaffected.
- **Lesson (repeat of the fleet rule): don't trust a summarised WebFetch for a callback signature — read the quoted source.** Gate: `perl -c` clean.

### 0.31.0 (2026-07-15) — "Similar artists" section + artist-photo thumbnails on it AND "Also a member of"
- **Simon: add a "Similar artists" section at the bottom (like MAI does), links drilling into each artist's discography exactly as "Also a member of" does; and try artist-image thumbnails on both sections.** New LAST section `PLUGIN_DISCOGRAPHY_SIMILAR_ARTISTS` in `_buildList`, after "Also a member of".
- **Data = MAI `getRelatedArtists`** via the guarded direct-function pattern (same as the bio) — Last.fm under MAI's own key; returns artist NAMES only (no mbid/image). `_warmSimilarArtists` caches the name list under `dsc:similar:v1:<mbid>` (30d found / 1d empty, capped `SIMILAR_MAX=25`, MAI error rows `type=text` skipped, MAI relevance order kept). `_peekSimilar` is the sync cache read used at render.
- **Each similar row is `_similarLinkRow` — the SAME drill-in as `_bandLinkRow`, entered by NAME** (Last.fm gives no mbid): `_discographyView({ artist => $name, ... })` → the paramless person path (`_resolveArtistMbid`→`getArtistMbid`) resolves it exactly like a top-level entry, so browse/sort/Refresh/drill-into-a-release all work and an owned similar artist matches locally via `localAlbums`' name fallback. Behaviour is identical to a band link; only the entry key differs (name vs mbid).
- **Artist thumbnails (BOTH sections) = MAI `getArtistPhotos({artist=>name})`** → first non-empty photo URL, cached `dsc:artphoto:v1:<lc-name>` (30d found / 1d empty), keyed by name so a band that is also "similar" is fetched once. `_peekArtistPhoto` feeds both `_bandLinkRow` and `_similarLinkRow`'s `image` (`// person icon` fallback). **NOT circular** — Material only rounds items it classifies as artists (`stdItem == STD_ITEM_ONLINE_ARTIST`), reachable only via `metadata.type=='artist'` (XMLBrowser forwards NO `metadata` field — verified in 9.0 AND 9.1 source) or an `<svc>://artist:<id>` favurl (only forwarded for playable rows, not `type=>'link'` drills, and needs a real streaming id). With **no Material patches** (Simon's constraint), a drill row can't be told to round — the thumbnails render square. `image` IS forwarded (as the row icon), so the photos display fine.
- **Warming = second-load, exactly like bands/emblems.** New `_warmArtistExtras($client,$mbid,$artist,$cb)` slots into the serial chain right after `warmBandMembers` (both wait sites): it AWAITS the similar-LIST warm (so the section can appear on the same second-load flip as "Also a member of"), then fire-and-forgets the photos for bands + similar artists (cache-guarded, in-flight-deduped). Photos land later → both sections show the person icon on the cold render and the real thumbnail on re-entry. The similar section sits LAST, so a cold→warm flip only adds trailing rows (walk-stable); a photo swap changes only a row's image, never item counts/order.
- **Not part of the shared matcher** (no `_norm`/`_albumMatches` touched) — `matcher_sync_check.py` N/A; no candidate-cache bump (new keys are self-populating). Gate: `perl -c` clean on Browse.pm (session stublib). New string `PLUGIN_DISCOGRAPHY_SIMILAR_ARTISTS`; section/rows reuse the shipped `dsc-bio_MTL_icon_person.png` (no new asset). Live end-to-end (section render + name-drill + thumbnails on re-entry) pending install.

### 0.30.1 (2026-07-12) — make 0.30.0's auto-detect actually fire + free the resolver closure (ported from LBF 0.9.95)
- **Bug found in LBF 0.9.95, same defect here: 0.30.0's auto-detect never ran.** The pref shipped defaulting to the public URL (`mb_base_url => 'https://musicbrainz.org/ws/2/'`) AND Settings.pm reset a blank field back to that URL on save — so the base was never blank, and `autodetectMirror` (which only probes when the base is blank) could never fire on any install. Fixes, matching LBF 0.9.95: **Plugin.pm** default → **`''`** (blank); **Settings.pm** keeps a blank field blank (dropped the `length $u ? $u : 'public'`); **settings.html** gained `placeholder="https://musicbrainz.org/ws/2/"` so the empty box still shows the default. Existing installs that saved the public URL should clear the field once to enable auto-detect. `_mbBase` already falls back to public on blank, so behaviour is unchanged when no mirror is found.
- **Memory leak in the artist-name→MBID resolver (also fixed in LBF 0.9.95).** `_artistMbidByName` and `getArtistCandidates` used a self-capturing `my $run; $run = sub {…$run…}` closure — a reference cycle Perl never reclaims, leaking a little memory on every name-resolved artist (the common no-library-tag path) and every wrong-tag disambiguation. Rewritten to **pass the sub to itself** (`my $run = sub { my ($self,…)=@_; … $self->($self,…) }; $run->($run,…)`), so the CV is freed once the in-flight callbacks finish. `autodetectMirror`'s once-per-startup `$try` closure is left as-is (matches LBF; a one-off, not a per-request leak).
- Gates: `perl -c` clean on API.pm + Settings.pm; Plugin.pm loads clean (WEBUI stubbed). No matcher change (sync N/A); no cache bump. Same `dsc:mbmirror:v1` key.

### 0.30.0 (2026-07-12) — auto-detect a same-host MB mirror + de-personalise the settings text
- **Simon: "auto-detect mode on local network for easier usage" + remove my local endpoint from the plugin text/tooltip.** The tooltip and all code comments referenced Simon's personal host `http://plex:5000/` — replaced fleet-wide (DSC + LBF) with a neutral `http://your-server:5000/ws/2/`, and the DSC tooltip was rewritten to match LBF's clearer wording (states the public default, blank behaviour, scheme note).
- **`API::autodetectMirror($cb)` (NEW)** — zero-config same-host mirror discovery. Runs ONLY when `mb_base_url` is blank: probes a FIXED same-host list (`http://localhost:5000/ws/2/`, `http://127.0.0.1:5000/ws/2/`) and, for the first that answers, **validates it is really MusicBrainz** by fetching a known artist MBID (Radiohead `a74b1b7f…`) and checking `name eq 'Radiohead'` — so another `:5000` service (macOS AirPlay, a Flask app) can't be mistaken for a mirror. The discovered base is cached under `dsc:mbmirror:v1` (a URL = found, `''` = probed-none), TTL **1 day** (re-probes daily). Fired async from `postinitPlugin`.
- **`_mbBase` now consults `dsc:mbmirror:v1` when the pref is blank** (manual URL still wins and skips the probe entirely). `_mbThrottled` is unchanged, so a discovered localhost mirror is correctly treated as un-throttled + eligible for the empty-search→public fallback, exactly like a manually-set mirror. **The LAN is never scanned** — localhost only; a mirror on another host is still typed in by hand. This covers the common musicbrainz-docker-alongside-LMS case (incl. Simon's own `plex` box, where LMS and the mirror share a host) with no config.
- **Settings.pm gained LBF's bare-host scheme guard** — a scheme-less entry like `your-server:5000/ws/2` now gets `http://` prepended on save instead of silently failing every MB lookup (makes the new "a bare host is assumed to be http://" tooltip line truthful). DSC previously stored it verbatim; LBF already had this.
- Gates: `perl -c` clean on API.pm + Settings.pm; DSC Plugin.pm loads clean (WEBUI stubbed). No matcher change (sync N/A); no candidate-cache bump (resolution path only). New cache key `dsc:mbmirror:v1` is self-populating. Ported identically to LBF 0.9.94 the same session (both route every MB call through `_mbBase`; PFR/LL don't use a MB base).

### 0.29.0 (2026-07-12) — perf (worst case): candidate first-token INDEX cuts the R x C matcher storm
- **The deferred worst-case win (Simon: tune for the public, not just his library).** `matchesFor` runs per release group and tested EVERY streaming candidate against it — R x C `_albumMatches` calls (a big artist: hundreds of RGs x a ~200 pool). 0.26.2 hoisted the per-RG invariants; this cuts the call COUNT itself.
- **`Sources::_titleKeys($norm,$artistNorm)`** (NEW, DSC-only — NOT a shared matcher sub): the first-token index keys of a normalised title in the three forms that a match can hinge on — the norm itself (exact / trailing-extra prefix / `_stripFmt`, which only trims a trailing ep/lp so the front is kept), `_asciiNorm(norm)` (accented first token), and artist-prefix-stripped. Every `_albumMatches` positive path leaves the two titles sharing a first token in >=1 form, so it's a proper SUPERSET filter — it only decides which candidates reach the unchanged `_albumMatches`, never the result.
- **`peekPool`** builds a per-streaming-service index `{ key => [cands] }` once per render (returned as `index`); **`matchesFor`** (given `$opt->{index}`) narrows a streaming service to the union of buckets for the RG's lookup keys instead of scanning the whole pool. **LOCAL pools always full-scan** — they're small AND match by release MBID (`_mbidMatch`), not just title, so the title index would miss them. A short (<2 char) album norm matches via the raw-punctuation branch (no first token) -> full-scan too.
- **Proven a SUPERSET, not a behaviour change:** an index-vs-full-scan equivalence harness over the real `matchesFor` returns byte-identical sections for every path (exact, trailing-extra prefix, `(Deluxe)` bracket, EP `_stripFmt`, artist-prefix, self-titled, wrong-artist rejection) AND a randomized 120-RG x 300-candidate sweep = ALL IDENTICAL. Speedup on that sweep: **218ms -> 10.5ms (~21x, 95% less)**. `matcher_sync_check.py` exit 0 (shared subs untouched); `perl -c` clean; no cache bump.
- **Residual (acknowledged):** the key is the first token, and `_norm` keeps a leading "the", so an artist whose titles mostly start with "The" clusters under one bucket (index -> full-scan for those). Bounded by the artist's own catalog; never worse than before. A stopword-aware key breaks the single-token-RG superset, so it's deliberately not done.

### 0.28.1 (2026-07-12) — disambiguation: WEIGHT the evidence (stop silly self-titled / generic matches)
- **Simon: add weighting so a coincidental match can't drive a wrong same-name adoption.** 0.28.0 counted RAW title matches, so a SELF-TITLED owned album ("The Bees") — which every same-name candidate also has — matched them all and could hand a wrong one the tie-break; a lone generic comp title ("Greatest Hits") was likewise thin evidence.
- **`_matchWeight($title,$artist)`**: self-titled (title norm == artist norm) → **0.5** (universal, the key fix — worthless for same-name disambiguation), generic compilation title (`%GENERIC_TITLE`: Greatest Hits/Best Of/Live/Collection/Anthology/… stored `_norm`'d) → **0.5**, distinctive → **1.0**. `_disambiguateByLibrary` now sums weights per candidate and adopts only when the best `>= DISAMBIG_MIN_WEIGHT` (1.0); ties still break toward the higher search score; tag kept otherwise.
- Balance held deliberately: ONE distinctive album still heals a wrong tag (weight 1.0), but a single self-titled/generic collision does not (0.5) — so we don't over-strict into failing thin-but-correct cases. Two generics accumulate to 1.0 (adopt).
- Verified via the REAL matcher (mocked network), 7/7: 3-distinctive adopt · 1-distinctive adopt · self-titled-only KEEP TAG · generic-only KEEP TAG · generic+distinctive adopt · two-generics adopt · right-band-beats-1-collision. `perl -c` clean. No matcher/cache change.
- Generic set is English-biased (acknowledged) — that's where most MB/streaming titles land; self-titled handling is language-neutral. Per-title MB-rarity weighting was considered and rejected (extra API calls on a wrong-tag-only path).

### 0.28.0 (2026-07-11) — disambiguate same-name artists by the LIBRARY (check every candidate, keep the best)
- **Simon's refinement of 0.27.0:** don't stop at the top name-search hit — the right "The Bees" isn't necessarily the highest-scored one, and files often have no MBIDs (his were wrong, not absent). Check EACH same-name candidate and pick the one whose discography actually matches the library.
- **`API::getArtistCandidates($name, cb)`** — the same-name set `[{mbid,name,score}]` (search `limit=15`, kept where lc-name == searched name, score-sorted), same mirror->public fallback as `_artistMbidByName`; not cached (rare wrong-tag path only). **`API::mbGap($default)`** exposes the throttle-aware gap (0 on a mirror).
- **`Browse::_disambiguateByLibrary`** (replaces 0.27.0's top-hit-only corroboration): fetch each candidate's release groups (serial, spaced by `mbGap` for MB's 1 req/s on public, 0 on a mirror; bounded to `DISAMBIG_MAX=8`; RG lists cached 14d so repeats are free) and count OWNED albums matched via `claimedLocalIds` (title match — no MBIDs needed). Adopt the candidate with the MOST matches; strictly-greater comparison breaks ties toward the higher search score. Keeps the original tag mbid if NOTHING matches (an obscure same-name contributor is never mis-attributed).
- Trigger unchanged: only when a library-TAG mbid returns zero release-groups (the wrong/merged-tag signal). Name-searched mbids and tag mbids with a real discography are untouched.
- Verified through the REAL matcher with a mocked network: UK owner (4 owned) -> picks 276cfa71; garage owner (comp only) -> keeps the tag (no false page); **UK owner vs a coincidental single-title collision on another same-name artist -> still picks the 3-match band** (proves best-not-first). `perl -c` clean on API.pm + Browse.pm. No matcher change; no cache bump.
- **KNOWN/scope:** corroboration is ALBUM-title only. An artist the user owns solely as loose compilation TRACKS (no album) won't corroborate — track-title matching would need per-RG recording fetches (heavy); deferred.

### 0.27.0 (2026-07-11) — heal a WRONG library artist-tag (corroborated name-search fallback)
- **Bug (field, The Bees): "No releases found" (resolution SUCCEEDED, spine empty).** Deep dive over HTTP + the mirror + a debug_log run (log fetched via `http://plex:9000/log.txt`, not just pasted): `artist mbid from library tag: dd11eecd-…` — Simon's UK "The Bees" albums carry a US GARAGE band's artist MBID (score-85 same-name entity, **0 release-groups**), while the real band `276cfa71` (18 RGs; "A Band of Bees" is just its alias) is what a name search finds. `getArtistMbid` trusts the file tag first (exact identity, normally right), so a mis-tagged/merged same-name artist resolves fine yet browses empty. Streaming candidates (Qobuz 24/Deezer 21/Tidal 41) + 5 local albums were all CORRECT — they just had no MB tiles to attach to.
- **Fix: `Browse::_resolveArtistMbid` — when a TAG mbid has zero release-groups, name-search for an alternative and adopt it ONLY if the artist's OWNED albums corroborate it.** `getArtistMbid`'s onDone now passes `$fromTag` (1=library tag, 0=name search). `_discographyView` routes non-band entries through `_resolveArtistMbid`: name-searched mbids are trusted as-is; a tag mbid with 0 RGs triggers a name search, and the alternative is adopted only if `claimedLocalIds($altRgs, name, localAlbums, {})` finds an owned album matching one of its release-groups. So UK Bees (owns Free The Bees/Octopus/… → 4 match `276cfa71`) adopts the real band; the US-garage contributor (owns only a Nuggets comp → 0 match) keeps its tag and shows no FALSE page (no mis-attribution to the prominent same-name act). General: heals any wrong/merged artist tag, safely.
- All `getReleaseGroups` calls are cached (14d), so the resolver's RG check warms the cache the main chain reuses (no extra network on the common tag-good path; a cold tag-good artist pays one serialized RG fetch before bio — acceptable, once per 14d).
- Verified through the REAL subs: `claimedLocalIds` corroborates UK Bees (4 owned match) and rejects the garage-comp case (0 match); `perl -c` clean on API.pm + Browse.pm. No matcher change (sync N/A); no cache bump. Live end-to-end pending install.
- **debug_log turned back OFF on the server after the diagnosis.**

### 0.26.2 (2026-07-11) — perf: hoist per-render matcher invariants out of the release-group loop
- **Review pass (Simon asked for perf).** Hot path = `_buildList` render, which runs on EVERY view (first load, sort toggle, paging, Refresh), calling `peekMatches`->`matchesFor` once per release group. Benchmarked the matcher core: a 120-RG × 660-candidate render is ~880ms of pure CPU (worst case, all misses -> every fallback norm fires); memoizing `_norm` recovers only ~31% (the fold isn't the sole cost). Live warm renders on Simon's actual (smaller) artists: ~70ms over ~104ms network/LMS baseline — fine in practice; no huge artists (Beatles/Dylan) in his library.
- **Fix (safe, behaviour-preserving): compute per-list invariants ONCE, not per RG.** `matchesFor`/`peekMatches` gained a trailing `$opt` hashref; `_buildList` now precomputes the artist norm and the source order (`orderedSources()` reads prefs + builds + sorts an array on every call) once for the whole list and threads them in, and computes each RG title's norm ONCE — reused for BOTH the rivals lookup and the matcher (was normed 2-3× per RG). Standalone callers (detail page, unit tests) pass no `$opt` and compute as before.
- Proven identical: an opt-vs-no-opt parity harness over the real `matchesFor` (co-credit Local match, streaming match, wrong-artist rejection, no-match) returns byte-identical section results in every case. No matcher sub touched — `matchesFor`/`peekMatches` are DSC-only call sites, sync check N/A; no cache bump.
- **NOT done (deferred, not worth it for Simon's library):** (a) fleet-wide `_norm` memoization (~31%, but touches 4 repos); (b) a candidate bucket-index to cut the R×C `_albumMatches` storm to R×small (big win only on 100+ RG artists — a correct first-token/asciiNorm/artist-prefix superset index; DSC-local). Both are the levers if a very large artist ever renders slowly; the current hoist is proportionate to the actual data.
- `perl -c` clean (Sources + Browse).

### 0.26.1 (2026-07-11) — fix: "Also a member of" links didn't change the page
- **Bug (field, Simon): tapping a band link did nothing.** 0.25.0's `_bandLinkRow` used "re-stash `%lastCtx` to the band + `nextWindow => 'refresh'`". Confirmed from the live item JSON: the row's `go` action is `cmd:[discography,items] params:{item_id:17} nextWindow:refresh`. So the tap ran the coderef (set ctx=band, returned empty) but the refresh re-issued the PERSON's TOP command WITH its artist params (the 0.8.1 behaviour — a top refresh carries the entry params), which hit topLevel's fresh-entry branch and CLOBBERED the band stash before it was read → bounced straight back to the person. The "set ctx + refresh" trick fundamentally can't do cross-artist nav.
- **Fix: make the band link a plain DRILL-IN that renders the band's discography inline.** `_bandLinkRow` now carries the band identity in `passthrough` and its `url` coderef calls `_discographyView` with the band's `{mbid, artist, artist_id}` (entered by mbid via the direct-mbid path) — no `nextWindow`, no stash. Tapping drills into the band as a nested sub-feed; each deeper click re-walks THROUGH this coderef (deterministic), so band→release-detail navigation stays consistent (same walk-stability the whole plugin relies on; the "Also a member of" section is LAST + deterministic, so item_id 17 is stable).
- **KNOWN LIMIT (documented in code):** toggles that refresh the TOP view (bio "Read more", section paging "Show more") land on the PERSON in a nested band view, because a top refresh re-sends the person's params. Browse / sort / Refresh / drill-into-a-release all work. A band as a true top-level view (all toggles working) needs a fresh top command carrying the band's params, which a feed item can't emit from within — future work (would want the same `lmsbrowse`-style entry the custom action uses).
- `perl -c` clean. topLevel's `mbid` param handling (0.25.0) stays — harmless for the person entry, and the direct-mbid path in `_discographyView` is what the drill-in uses.

### 0.26.0 (2026-07-11) — refresh cached MB data: HTTP `clearcache` command + comprehensive Refresh
- **Field (Simon): "no way to refresh the mb data cached" — Alison Krauss stayed unresolvable.** Confirmed live: the INSTALLED build still renders the bare "Couldn't identify" with NO Retry row (it predates 0.23.1), so the `dsc:mbid:` miss (cached 1 day while the mirror's search index was unbuilt) can't be busted from the UI at all, and the normal Refresh only cleared release-groups + bootleg map — never the mbid, bands, bio, or candidates. There was genuinely no way out but waiting the TTL.
- **`API::clearArtistCache(name=>, mbid=>)`** — the one "re-pull from MusicBrainz" primitive: clears resolution (`dsc:mbid:` incl. the '' miss), bio (`dsc:bio:1:`), and — recovering the mbid from a cached HIT when only a name is given — release groups (`dsc:rg:`), bootleg map (`dsc:rgo:`), band members (`dsc:bands:`). Streaming candidates are Sources' (`clearCandidates`), called alongside. Returns the list of classes touched.
- **HTTP-triggerable `["discography","clearcache", ...]`** (new CLI dispatch in Plugin.pm) — the field escape hatch, no Material UI needed: `artist:<name>`, or `artist_id:<n>` (resolves the name via Contributor), or `mbid:<artist-mbid>` (also clears the mbid-keyed caches). This is the mechanism the mirror-index gotcha needed — a poisoned cache can now be cleared with a curl (and remotely, over http://plex:9000, during diagnosis).
- **View Refresh is now comprehensive** — `_refreshItem` carries the artist name in its passthrough and calls `clearArtistCache` + `clearCandidates`, so the button re-pulls EVERYTHING (person view re-resolves by name; a band view keeps its stashed mbid and re-pulls by mbid). The 0.23.1 error-page Retry still busts the mbid miss for the unresolvable case (it's the only thing shown then).
- Gates: `perl -c`/load clean on all modules (Plugin.pm loaded with `main::WEBUI` stubbed); `clearArtistCache` driven through a stateful cache stub — all five keys removed with the mbid recovered from the cached name. No matcher change; no cache-version bump (this clears caches, doesn't reshape them).
- **Simon's unblock:** install 0.26.0, then either tap "Retry MusicBrainz lookup" on Alison Krauss OR run `["discography","clearcache","artist:Alison Krauss"]` (I can run it for you over HTTP once installed). The mirror resolves her at score 100, so she loads immediately after.

### 0.25.0 (2026-07-11) — "Also a member of": link OUT to the artist's bands instead of folding them into the solo spine
- **Simon's design call:** browsing a person should show ONLY their solo-credited releases (which is already what `release-group?artist=<personMbid>` returns — bands are separate MB artists), plus a links section to the OTHER bands/projects they're in. Don't fake-merge a band's catalogue into the person's spine.
- **New bottom section "Also a member of"** (`PLUGIN_DISCOGRAPHY_ALSO_MEMBER_OF`) in `_buildList`, from `API::peekBands($mbid)` (MB "member of band", already warmed in the serial MB chain by `warmBandMembers`; deduped by id). Each band is a `_bandLinkRow` — a link that opens THAT band's discography. Shown regardless of `show_library_extras` (navigation, not library). Cache-cold on first render → appears on re-entry (bootleg/emblem second-load contract); it's the LAST section, so a cold→warm flip only adds trailing rows (walk-stable — nothing above shifts). Verified on the mirror: Neil Hannon → The Divine Comedy / Duckworth Lewis Method / Cake Sale; Luke Haines → The Auteurs / Black Box Recorder / Baader Meinhof / …; Alison Krauss → Alison Krauss & Union Station / Robert Plant & Alison Krauss (so Raising Sand is reachable) / The Red Hots.
- **Enter another artist's discography by mbid.** `_bandLinkRow` mirrors `_refreshItem`: it re-stashes `%lastCtx` to the band (artist_id resolved lazily via `Sources::_bandContributorId`, mbid, name — idempotent, same one-artist-per-player model as a fresh entry) and returns `nextWindow => 'refresh'`, so topLevel re-enters PARAMLESS, restores the band context, and renders the band's discography IN PLACE at the top level (not nested — a nested sub-feed would fight the single-context stash when the band's OWN top-level toggles refresh "the top"). `topLevel` now reads/stashes/restores an `mbid` param (added to the `$same` identity check); `_discographyView` refactored so the post-resolution body is a `$withMbid` closure driven EITHER by a direct `$opts->{mbid}` (uuid-gated) OR by `getArtistMbid` — the band path skips resolution entirely (the person path is unchanged).
- **Band albums REMOVED from the solo "Appearances" section** (0.20.0's `Sources::bandAlbums` injection): per the decision they now live behind the band link. `bandAlbums` is left in Sources.pm (dead but valid; `_bandContributorId` still used by the link). "Appearances" is now purely the artist's own library orphans + VA comps/soundtracks they perform on.
- Icon: reuses the shipped person `_MTL_` icon for the header + rows (a dedicated group icon is a cheap follow-up). No matcher change (sync N/A), no cache bump.
- Gates: `perl -c` clean on all three modules (real sibling modules via the scratchpad symlink dir); member-of-band data confirmed live on the mirror for the three field artists + dedup verified (`warmBandMembers` `$seen{$id}++`). Live end-to-end (section render + band navigation) pending install.
- **KNOWN/scope:** the section is only as good as MB's "member of band" relations (present for all three field artists on the mirror; a one-person project occasionally isn't modelled as a band). The band view shows the band's FULL discography (spine + streaming + that band's library albums) — that's the point.

### 0.24.0 (2026-07-11) — co-credit / band-fronted owned albums match (trust the Local join, not the collapsed album-artist)
- **Bug (field, Simon — validated live before fixing): a co-credited owned album never matches its tile.** `localAlbums` fetches by `artist_id:N role_id:ARTIST,ALBUMARTIST,BAND,TRACKARTIST`, so the DB join ALREADY proves the browsed artist performs on the album — but the `albums` CLI query collapses a multi-value ALBUMARTIST to ONE display string (Raising Sand's `ALBUMARTIST=Robert Plant; Alison Krauss` came back as just "Robert Plant"), and `Sources.pm:205` fed that single string into `_albumMatches`' MANDATORY artist gate as `_candArtist`. Result: browsing Alison Krauss, `_artistMatch("alison krauss","robert plant")=0` → the owned album is dropped. Proven against the REAL module (`_albumMatches(...)=0`; control with browsed artist =1).
- **Fix: gate LOCAL candidates on the BROWSED artist, not `_candArtist`.** In `matchesFor` and `claimedLocalIds`, a `$a->{local}` candidate now passes `$artist` (the browsed name) as the gate artist to `_albumMatches` — the title must still match, but the redundant artist re-check (already established by the join) can't veto a co-credit. **`_candArtist` is deliberately LEFT AS the true collapsed album-artist** because Browse's 0.21.0 "Also in your library" vs "Appearances" split (`Browse.pm:745`, reads `_candArtist`) needs it to tell an own-record from a guest/VA appearance. Streaming candidates are UNCHANGED — they still gate on `_candArtist` (their pool can contain wrong artists; the join guarantee doesn't apply).
- **NOT a shared-matcher change:** `_albumMatches`/`_artistMatch` themselves are byte-identical — only the DSC-only CALL SITES (`matchesFor`, `claimedLocalIds`) changed. `matcher_sync_check.py` exits 0; no fleet port, no cache bump (matching runs live; candidate shape unchanged).
- **Honest scope:** this fixes the MATCH gate. For the four field artists specifically, most of their owned records sit under a DIFFERENT MusicBrainz artist (Auteurs/Divine Comedy = band; Plant+Krauss = collab) that isn't in the browsed person's release-group SPINE, so those still won't become tiles — they surface via the extras "Appearances" section, and band-fronted ones via the 0.20.0 band-member path. This fix bites whenever the browsed artist's OWN spine contains an album the user owns under a co-credit album-artist (and stops such an album double-listing in the library-extras net).
- Gates: `perl -c` clean; driven through the REAL `matchesFor`/`claimedLocalIds` — co-credited Local album now MATCHES + is CLAIMED, streaming wrong-artist still REJECTED (gate intact); `matcher_sync_check.py` exit 0.

### 0.23.1 (2026-07-11) — bust the poisoned MBID miss-cache (fixed mirror still looked broken)
- **Field (Simon): mirror search index rebuilt & verified working (`?query=` Radiohead 7 / Alison Krauss 3 / Neil Hannon 1, all score 100), but the plugin STILL showed "Couldn't identify this artist" for the same four.** Diagnosed live: it's the `dsc:mbid:<name>` **empty "not found" sentinel**, cached for 1 DAY during the dead-search window, being served before any HTTP call — so neither the fixed mirror NOR 0.23.0's public fallback ever gets a chance to fire (the fallback is inside the live search; a cache hit short-circuits it). Version-independent: any *live* lookup now resolves; the cached miss is the sole blocker, and there was no UI path to clear it (the per-artist Refresh lives INSIDE a resolved view; the "not found" error page had no action).
- **Fix 1 — miss TTL 1 day -> 1 hour (`MBID_EMPTY_TTL`).** A "not found" is far more often a transient infra blip (mirror index still building returns 0 for everyone; a timeout) than a genuinely unknown artist. 1h still avoids hammering a real miss but self-heals fast. (Found-hit TTL unchanged at 30d.)
- **Fix 2 — Retry row on the "not found" view.** New `API::clearArtistMbid($name)` removes the `dsc:mbid:` key (found or miss), keyed exactly like `_artistMbidByName` (utf8-encoded lc name). The error view now appends a `PLUGIN_DISCOGRAPHY_RETRY_LOOKUP` row (`nextWindow => 'refresh'`) whose url sub clears the miss and returns empty; the refresh re-enters `topLevel` (artist context is stashed BEFORE resolution, so paramless re-entry restores it), re-runs `getArtistMbid` with the cache clear -> live search -> resolves. Same mechanism as the existing Refresh, so walk-stability/idempotence hold (the clear is safe to re-run). Only added when `$artist` is non-empty.
- **Simon's immediate unblock (no waiting):** install 0.23.1, open one of the four, tap **Retry MusicBrainz lookup** -> it resolves. (Or just wait ~1h for the shortened TTL and re-enter.)
- Gates: `perl -c` clean on API.pm + Browse.pm (real sibling modules loaded via a scratchpad Plugins/Discography symlink dir + Slim stubs). No matcher change (fleet sync N/A); no candidate-cache bump. New string `PLUGIN_DISCOGRAPHY_RETRY_LOOKUP`; reuses `MENU_REFRESH` icon.

### 0.23.0 (2026-07-10) — mirror search fallback: resolve by name via public MB when the mirror's Solr is empty
- **Bug (field, Simon): "Discography fails to get matches" for Alison Krauss, Neil Hannon, Luke Haines, Françoise Hardy** (The Bees was a red herring — id 39433 works; id 44182 is a genuinely DIFFERENT 1960s US garage band, correctly split). **Diagnosed live over HTTP, and it was NOT contributor tags or matching:** the live feed returned *"Couldn't identify this artist on MusicBrainz"* for all four, i.e. `getArtistMbid` -> undef at RUNTIME, while a direct query to musicbrainz.org scored 100 for every one (accents included). Root cause: `mb_base_url` points at Simon's musicbrainz-docker mirror (`http://plex:5000/ws/2`), and **the mirror's Solr SEARCH index was never built** — `?query=` returns `count:0` for EVERYTHING (Radiohead/Beatles/Dylan all 0) while entity BROWSES (`release-group?artist=<mbid>`, Postgres) work fine (Alison Krauss's browse returns 27 RGs). So artists with a valid library MB tag resolved via the tag->browse path and worked; the four that lack a tag fell to NAME SEARCH -> dead Solr -> undef. The whole "fails for some artists" pattern = "does the library contributor carry a valid MB artist MBID?".
- **Fix (plugin resilience): `_artistMbidByName` retries the public API ONCE when the configured base is a mirror and its search yields zero results (or is unreachable).** `$mirror = !_mbThrottled()` gates it; `$isFallback` prevents a loop; the public-resolved MBID is universal so release-group BROWSES still hit the (fast, unthrottled) mirror. A mirror that returns real search results, a low-score hit (index works), or the public API itself, are all unaffected — only the empty-mirror-search / mirror-search-error paths fall back. Miss/`found` caching + the daily/30d TTLs are unchanged (moved into a shared `$store` closure). No cache bump (resolution, not candidate shape); `perl -c` clean with the session stubs.
- **Fix (mirror, the actual cause): `setup-musicbrainz-mirror.sh` now builds the search index.** New `--search-index fetch|build|skip` (default **fetch** = load prebuilt Solr dumps, ~60 GB, `search fetch-backup-archives`+`load-backup-archives`; `build` = `indexer python -m sir reindex`, ~4h). Runs as step 7.5 after the stack is up; the misleading "the import builds the search indexes" warning is corrected (it does NOT); the health check now also verifies `?query=Radiohead` returns >0 and prints the rebuild command if not; skip-import and closing notes document the two-step (import THEN index). `bash -n` clean.
- **Simon's fix RIGHT NOW (no reinstall needed):** on the mirror host, `cd /opt/musicbrainz-docker && sudo docker compose exec search fetch-backup-archives && sudo docker compose exec search load-backup-archives`, then re-check `curl -s 'http://plex:5000/ws/2/artist?query=artist%3A%22Radiohead%22&fmt=json&limit=1'`. The 0.23.0 plugin build is belt-and-suspenders for future empty-search states.
- **STILL OPEN (secondary, deferred):** once search works these four resolve, but their OWNED music sits under a different album-artist (Raising Sand=Robert Plant+Alison Krauss co-credit; Auteurs/Divine Comedy=band; Eurythmics=guest), and `Sources.pm:205` feeds only the single collapsed `albums`-query `artist` string into the matcher's mandatory artist gate — so a co-credited owned album is dropped even though the DB join already proved the credit. Fix when it bites: for Local candidates trust the join (set `_candArtist` to the browsed artist, or skip the gate for `_svc eq 'Local'`). Band-fronting (Divine Comedy/Auteurs) is the 0.20.0 band-member path's job — verify it fires for these once resolution is unblocked.

### 0.22.0 (2026-07-10) — tile art: prefer the matched source cover over CAA
- **Bug (field): blank tiles.** The Cover Art Archive 404s even on dated releases (verified live: Marc Almond "Against Nature", "The Dancing Marquis" — both MATCHED, so a streaming cover exists, but CAA-less -> no thumbnail). Old `_releaseItem` used the source cover ONLY for UNDATED releases (a heuristic that assumed CAA gaps were confined to the obscure tail); every dated CAA gap showed blank.
- **Fix (Simon's call — "less trawling, quicker to populate"): source-cover PRIMARY, CAA fallback.** A matched section always carries art — Local file art or the service's CDN cover, already in the candidate cache (no extra fetch, faster load than CAA's redirect-to-archive.org). So `$image = $cover` whenever a match has one; the CAA url stays only for a tile with no match yet (pre-warm) or an unmatched release shown with `hide_unmatched` off. `$cover` is still the first non-empty cover in source-priority order (Local first), so an owned album shows its library art and a streaming-only match shows the service cover.
- **Timing (as designed):** covers ride the streaming candidate warm (fired on view open), so a CAA-less tile is blank on the very FIRST cold render and gains art on the next render — same warm pattern as the service tags/emblems. Not instant, but reliable once warm; CAA was instant-but-often-404.
- Gates: `perl -c` clean; existing suites green (self 22, page 25, rival 28, play 11, band 8, appear 6). Behaviour verified by live diagnosis before the change (CAA HEAD 200 vs 404 across a real feed, matched tiles carrying favurls); post-install live re-check pending.

### 0.21.0 (2026-07-10) — split the library tail into "Also in your library" + "Appearances"
- Simon: the band albums AND the VA-comp/soundtrack items (Dylan's Big Lebowski, High Fidelity, Jingle Jangle Morning) should sit under a distinct **Appearances** header, not "Also in your library".
- **Split signal = the album ARTIST** (verified live: Dylan's own albums read `Bob Dylan`; the soundtracks read `Various Composers`/`Various Artists`). `_buildList` classifies each unclaimed library album with the matcher's own `_artistMatch(browsedArtist, albumArtist)`:
  - matches (their own record MB's spine missed) -> **"Also in your library"**;
  - doesn't match (VA comp / someone else's album they perform on) -> **"Appearances"**.
  Every band album (`_band`) goes to Appearances unconditionally. Empty/unknown album-artist fails safe to "Also in your library" (never demote an unknown).
- Both sections now come from ONE helper `_extraSection` (year sort, `_pageSection` paging with distinct keys `EXTRAS`/`APPEAR`, walk-stable header). Appearances uses the `MTL_icon_person` divider icon.
- New string `PLUGIN_DISCOGRAPHY_APPEARANCES`. No new asset (reuses the shipped person `_MTL_` icon).
- Gates: `perl -c` clean; 6/6 classification assertions (own exact + collab-superset; Various Composers/Various Artists + band-name -> appearance; empty album-artist -> own). Full suite green (self 22, page 25, boot 18, await 13, mbid 11, rival 28, local 10, play 11, band 8).

### 0.20.0 (2026-07-10) — band-member albums (Soft Cell under Marc Almond)
- **Follow-up to 0.19.0's known limit.** 0.19.0's performance-role filter correctly dropped write-only chaff but also dropped band albums a member is tagged COMPOSER-only on (Soft Cell's "Non-Stop Erotic Cabaret" under Marc Almond). The library can't tell those apart; **MusicBrainz can**, via the artist's "member of band" relationships.
- **`API::warmBandMembers($mbid,$cb)`** — one cached call, `artist/<mbid>?inc=artist-rels`, keeps `type=='member of band'` + `direction=='forward'` (the artist is a member of the target group; backward would be the group listing members), dedups by id → `dsc:bands:v1:<mbid>` 14d as `[{mbid,name}]`. Verified against MB: Marc Almond → Soft Cell, Marc and the Mambas, The Flesh Volcano, The Immaculate Consumptive. `peekBands` is the sync cache read (undef=unwarmed, `[]`=warmed-no-bands).
- **`Sources::bandAlbums($bands,$exclude)`** — for each band resolve a library Contributor id (`_bandContributorId`: MB id via `Contributor.musicbrainz_id` first, else normalised-name match with the same anti-fuzzy discipline as `localAlbums`), then reuse `localAlbums` (so the same PERFORMANCE-role filter applies — but the band IS the album artist, so its records come through clean). `$exclude` skips the artist's own albums so a split isn't double-listed.
- **Browse:** `warmBandMembers` is chained in the serial MB pass (local-release lookups → band members → bootleg — one chain, 1 req/s preserved), so the band list is cached before `$offDone` and ready first render (deadline permitting; else re-entry). The "Also in your library" section now fires when there are band albums even if the artist owns none of their own, and a band tile's line2 names the band (`1981 · Soft Cell`) vs the plain `· Local`.
- Scope: LIBRARY albums by the band (what Simon asked). NOT the band's full MB discography or streaming matches — that's a bigger future step if wanted.
- Gates: `perl -c` clean; 8/8 new assertions (peekBands undef-vs-empty-vs-warmed; the member-of-band relation filter: backward + wrong-type + duplicate-id all excluded, id lowercased). All prior suites (self 22, page 25, boot 18, await 13, mbid 11, rival 28, local 10, play 11) green.
- Rolls up 0.18.0 (Qobuz `.qbz`, drill-in parity, mb_base_url) + 0.19.0 (role filter) — 0.20.0 is the install.

### 0.19.0 (2026-07-10) — library section: PERFORMANCE roles only (drop writer-only chaff)
- **Bug (field, Bob Dylan): "Also in your library" full of albums Dylan only WROTE a track on** — Richard Hawley's "Now Then", George Harrison's "All Things Must Pass", Ladysmith Black Mambazo, Jenny Lewis, Fun Boy Three. The MB spine (Albums/Compilations sections) was CLEAN — it's the library query. `Sources::localAlbums` ran `albums artist_id:N` with no role filter, and LMS's default spans ALL contributor roles (`contributorRoles()` incl. COMPOSER/CONDUCTOR), so every album carrying one Dylan-written cover was dragged in.
- **Fix: `role_id:ARTIST,ALBUMARTIST,BAND,TRACKARTIST`** on the query — the artist must PERFORM (solo, primary, band member, or guest), not merely have written a song that appears. Live-verified over HTTP: Dylan 30 → 8 (all real albums + the soundtracks he performs on kept; every writer-only album gone). Matches Simon's rule exactly ("compilations they appear on as the artist is fine; writer-only is not").
- **KNOWN LIMIT, discussed with Simon and accepted as the first cut:** a band album whose member is tagged ONLY as COMPOSER also drops. Marc Almond is COMPOSER-only on Soft Cell's "Non-Stop Erotic Cabaret" in Simon's library — **identical in the data to a write-only cover credit** (both COMPOSER, on an album whose ALBUMARTIST is someone else). No library signal separates them: the track-fraction idea fails because that album tags Almond on just 2/18 tracks (deluxe padding), overlapping Dylan's genuine chaff (Music From Big Pink 3/17). Proper "show my band's albums under me" needs a MusicBrainz **member-of-band** relationship lookup — a future feature, noted in the code.
- Affects BOTH uses of `localAlbums`: the match pool (a performer's own albums still match their MB release-groups — Blood on the Tracks etc. unaffected, it's ALBUMARTIST=Dylan) and the extras safety net (where the chaff lived). No behavioural test added — it's a CLI-query param verified live, not matcher logic.
- Rolls up the still-unverified 0.18.0 fixes (Qobuz `.qbz` play, drill-in MBID/rival parity, `mb_base_url` mirror) — install 0.19.0 to get the lot.

### 0.18.0 (2026-07-10) — Qobuz play fix (.qbz) + drill-in agrees with the tile + MB-mirror pref
- **Bug (field, Simon): Qobuz albums "not playing", a raw id ("kv6tfmvmgn0wb") shown as the Now-Playing title.** Root cause found live over HTTP: the tile/row play used the stripped ListenLater favurl `qobuz://album:<id>`, and **Qobuz's ProtocolHandler explodes an album ONLY when the url ends `.qbz`** (`explodePlaylist`, regex `qobuz://(playlist|album)?:?([0-9a-z]+)\.qbz`). Without it, LMS enqueues one bogus track literally titled `album:<id>`. Verified: `qobuz://album:0060254767034` → 1 junk track; `qobuz://album:0060254767034.qbz` → the 17-track album. Tidal (`tidal://album:<id>`) and Deezer (`deezer://album:<id>`) DO resolve the plain form — so this was Qobuz-only.
- **Fix: `Browse::_playUrl($item)`** returns a genuinely playable url per source — Local `db:album.id=N` (its own play string), **Qobuz `qobuz://album:<id>.qbz`**, Tidal/Deezer the plain `<svc>://album:<id>`, unknown → stripped favurl. Used for the tile `play` AND the kept (preferred) detail row's play string. The favurl itself is UNCHANGED (still `<svc>://album:<id>` — that's the correct LL/Favorites/emblem handshake); only the PLAY string differs. Detail rows also still play via their native url coderef (verified: item play enqueues the real tracklist), so this is belt-and-suspenders for tile-play-via-feed-expansion.
- **Bug (field, Simon): drilling into the White Album showed Qobuz as primary and no Local (Esher) row; couldn't play the local copy.** The detail page (`_releaseDetail`) rebuilt matches with a bare `matchesFor($bySvc,$artist,$title,$local)` — NO `$rgMbid`/`$relMap`/`$rivals` — so tier-0 identity (0.15.0, the only way Esher matches "The Beatles") and the same-title rival rule (0.16.0) were BOTH off on drill-in, disagreeing with the tile. **Fix:** the tile now carries the artist MBID (`$opts->{mbid}`, injected in `_buildList`), and `_releaseDetail` rebuilds the SAME `relMap` (artist map + `peekLocalReleaseMap` for the owned albums) and `rivals` (from the cached RG list + `peekOfficial`), passing all three to `matchesFor`. Falls back to plain title matching on a stale pre-mbid passthrough. So drill-in now matches the tile: Local first (svc_priority_local=1), Esher shown and playable, compilations show no streaming.
- **Feature (parallel work, now versioned): `mb_base_url` pref — point the plugin at a local MusicBrainz mirror.** `API::_mbBase` reads the pref (default = public API), `_mbThrottled`/`_mbGap` drop the 1 req/s courtesy delay for any non-musicbrainz.org host (a mirror is our own hardware). All MB calls (`artist`, `release-group`, `release`, url-rels) go through `_mbBase()`. CAA stays on the public host (musicbrainz-docker doesn't mirror it). Settings.pm + settings.html expose it; blank resets to public. **Big win for The Beatles: the 33-page bootleg/release pass runs back-to-back instead of at 1/s, so the first-render deadline stops mattering** — worth pointing `mb_base_url` at a docker mirror if the wait ever bites.
- Verified LIVE over HTTP on 0.17.0 before the fix (the diagnosis): Qobuz item play works via the coderef (17 tracks); the raw favurl play produces the junk 1-track item; Tidal/Deezer favurls play fine; `.qbz` fixes Qobuz. Post-fix code gated: `perl -c` clean on all modules; 11/11 `_playUrl` assertions (per-service formats, Local/explicit-play precedence, guards, unknown-svc fallback, coderef-play ignored); mbid (11) await (13) boot (18) matcher (22) paging (25) rival (28) local (10) suites green.
- **debug_log turned back OFF on the server** after the diagnosis.

### 0.17.0 (2026-07-10) — library albums match on the FIRST render (targeted release lookups)
- **Diagnosis (live, HTTP): Simon's "The Beatles and Esher Demos" orphaned into "Also in your library" on FIRST entry only.** The debug build (0.16.1) proved the data pipeline is correct — the album carries release mbid `318462e7`, the map resolves it to `055be730` (White Album), and with the map warm there are ZERO orphans. The cause was pure timing: the release map only exists once the artist-wide bootleg browse completes (33 pages / ~36s for The Beatles), which blows the 15s render deadline (0.14.0). So on a huge artist the first render had no map, exact-MBID matching couldn't fire, and the title matcher (rightly, per 0.11.1) refused "The Beatles and Esher Demos".
- **Fix: resolve the LIBRARY's own release MBIDs directly, ahead of the big browse.** The user owns a handful of albums, so `API::warmLocalReleases` does one `release/<mbid>?inc=release-groups` per owned album (cached per release 14d, `dsc:rel2rg:v1:<mbid>`), a few requests that finish well inside the deadline. `_buildList`'s `$relMap` is now the artist-wide map (when warm) MERGED with this targeted map (`peekLocalReleaseMap`), so a library album's identity match is ready first render even while the full bootleg pass is still running in the background.
- **One serial MB chain, ordering deliberate:** targeted library lookups FIRST (few, fix the visible orphan, finish inside the deadline), THEN the full bootleg browse. Never parallel — two chains break MB's 1 req/s etiquette. Render gates on the bootleg leg's `$offDone` (set by completion or the deadline); the local map is populated before that leg starts, so it's always ready when the render fires (unless the user owns >~13 untagged-by-the-big-map albums, whose lookups themselves exceed the deadline — rare, self-heals on re-entry).
- Only release MBIDs the artist-wide map hasn't ALREADY resolved are looked up (`grep { !$known->{$_} }`), and `warmLocalReleases` further skips per-release-cached ones — so a revisit (either cache warm) costs zero requests and renders instantly. A 404 (the tag was a release-GROUP mbid, which `_mbidMatch` matches directly) caches '' so it isn't retried; HTTP errors cache nothing.
- `$local` is now fetched ONCE in `_discographyView` (needs the mbids for the lookups) and passed into `_buildList` (was a second sync DB query); `_buildList` still self-fetches on a direct call.
- Field diagnostics kept from 0.16.1: `local albums for artist_id=N: … mbid=…` and `library-extras (orphans): relMap=N releases | …`. **debug_log is currently ON on Simon's server** (turn off when done: `["pref","plugin.discography:debug_log","0"]`).
- Gates: `perl -c` clean on all three modules; 10/10 new assertions on `warmLocalReleases`/`peekLocalReleaseMap` (sync cb on empty/undef/all-cached, empty-vs-404 exclusion, the cold-artist-map + local-map merge). mbid (11), await (13), bootleg (18), matcher (22), paging (25), rival (28) suites green.

### 0.16.0 (2026-07-10) — same-title release-groups: one candidate, one owner
- **Bug (field): four tiles under Compilations, all showing the White Album on all three services.** The Beatles have four OFFICIAL release-groups whose titles normalise to the artist name — the 1968 album plus compilations from 1967, 1983, 1988. Each exact-matches the streaming album titled "The Beatles" (0.11.1's self-titled rule is exact, and they ARE exactly equal), so all four claimed the same candidate. Not bootlegs; the 0.13.0 filter correctly keeps them.
- **Fix: a candidate belongs to exactly ONE release-group.** `Browse::_rivalsByTitle` buckets release-groups by the matcher's `_norm`ed title; `Sources::_rivalOwner` picks the owner and `matchesFor` drops the candidate for every other rival.
- **The rule is deliberately NOT nearest-year.** Streaming catalogues date a remaster by its REISSUE year, so a 2009 White Album remaster is nearer 1988 than 1968 and nearest-year would hand it to the compilation — worse than the bug. Instead: an EXACT year equality wins (a service listing the 1988 compilation as 1988 gets it right), otherwise the first rival in a fixed order wins.
- **That order is the subtle part: real album before compilation, THEN earliest date.** Date alone is wrong here — the 1967 compilation PREDATES the 1968 album, so "earliest wins" would have handed the White Album's candidate to a compilation. mbid is the final tiebreak so ordering never depends on hash iteration (item_id walk stability).
- Rivals exclude what can't be rendered — bootlegs (0.13.0 map) and Remix/DJ-mix secondaries — so a hidden group can't win a candidate the visible album would then never show. Fails open: unwarmed bootleg map = everything is a rival, and the album still wins undated candidates.
- **Tier-0 MBID identity (0.15.0) is never second-guessed by the rival rule** — an MBID says which group a release IS.
- Candidates now carry `_year`, read off the RAW service album in `_decorate` (the plugins' rendered items drop it). Field names verified in each plugin's source, ORIGINAL date preferred: Qobuz `release_date_original` -> `release_date_stream`, TIDAL `releaseDate`, Deezer `release_date`. **CAND_CACHE_V 3 -> 4** (cached candidate shape changed — the fleet's bump rule).
- Gates: `perl -c` clean; 28/28 new assertions driving the REAL Beatles release-group set (album beats the earlier 1967 comp; 1968/undated/2009-remaster all land on the White Album; 1988 lands on the 1988 comp; every year yields exactly ONE owner; bootleg excluded from rivals; `_candYear` field precedence incl. remaster stream date, empty and ref values). mbid (11), await (13), bootleg (18), matcher (22), paging (25) suites green.

### 0.15.0 (2026-07-10) — Tier 0: exact local matching by MusicBrainz release id
- **Bug (field): Simon's White Album sat in "Also in your library" instead of matching its tile.** His copy is titled `The Beatles and Esher Demos` (the 2018 box, MB release `318462e7`). Against release-group `The Beatles` the title matcher has nothing to work with — and 0.11.1's self-titled EXACT rule (rightly) refuses the prefix match. Verified against MB: that release's release-group IS `055be730`, the White Album.
- **Answer to "are we not using local MBIDs?": we weren't. Now we are, for free.** `Slim::Schema::Album` carries `musicbrainz_id` (the `albums` CLI query exposes NO MusicBrainz tag — verified in LMS 9.0 `Queries.pm`), and it holds a **release** mbid. The bootleg browse (`release?artist=…&inc=release-groups`) already returns every release's group, so the same cached pass now also yields `{ release-mbid => release-group-mbid }` (`API::peekReleaseMap`). Zero extra requests. Cache key `dsc:rgo:v2` -> **v3** (shape change: `{ o => official-map, r => release-map }`).
- **`Sources::_mbidMatch` is TIER 0** — tried before `_albumMatches` in both `matchesFor` and `claimedLocalIds`, so identity beats every string rule and the album stops leaking into the extras section. Accepts a direct release-GROUP mbid too (some taggers write that). Fails closed to the title matcher on: untagged album, unwarmed map, release absent from the map, streaming candidate (no `_mbid`). It can never create a cross-group false match.
- Note the ordering dependency: the release map only exists once the bootleg pass has completed for the artist (0.14.0 awaits it on first render), so MBID matching and bootleg filtering light up together.
- Gates: `perl -c` clean; 11/11 new assertions on `_mbidMatch` (incl. the real Esher/White Album MBIDs, cross-group controls, all four fall-through paths, and an explicit check that the title matcher alone still rejects Esher while tier-0 accepts it); t_await extended to 13 for the new cache shape + `peekReleaseMap`; bootleg (18), matcher (22), paging (25) suites green.
- **KNOWN, NOT FIXED — the four "The Beatles" compilations.** (FIXED in 0.16.0 by the rival-owner rule.)

### 0.14.0 (2026-07-10) — bootleg filter applies on the FIRST render (awaited, with a deadline)
- **Simon, correctly: "having to go in, see bad albums, back out and in again is poor design."** 0.13.0's warm was fire-and-forget, so the first entry into an artist always rendered unfiltered.
- **Why it couldn't just filter early:** a release-group is a bootleg only when NONE of its releases is official, so a PARTIAL map can never prove bootleg-ness — an unseen official release on a later page would redeem it. Hence nothing is cached until the pass completes, and there is no "filter with what we have so far". The choice is genuinely *wait* or *show them*.
- **Fix: await it, bounded.** `warmOfficial($mbid, $cb)` now fires `$cb` exactly once when the map is usable or provably won't be (cache hit, pass complete, HTTP failure, or another chain already in flight). `_discographyView` gates `$render` on a third leg `$offDone`, and arms a `Slim::Utils::Timers` deadline: whichever of (map ready | deadline) lands first sets `$offDone` and renders; the winner kills the loser's timer. On deadline, the pass CONTINUES in the background and lands in the cache for the next entry — i.e. 0.13.0's behaviour becomes the fallback, not the norm.
- **Cost is one MB request per 100 releases.** A normal artist = ONE request, so the wait is imperceptible and the first render is already clean. The Beatles (3,254 releases) = 33 requests; they hit the deadline. Pref `official_wait` (default 15s, `0` = never wait) tunes it.
- **Deliberately NOT parallel with the release-group fetch.** Two concurrent MB chains would put us at ~2 req/s, over MusicBrainz's 1 req/s etiquette, risking 503s. The pass starts after the RG pages finish. (RG list is cached 14d, so repeat visits pay only the officialness pass — and that's cached 14d too.)
- **In-flight callers do NOT attach to a running chain** — they cb immediately and render unfiltered. Attaching would let one player's view hang on another's 33-second pass.
- `onError` on the RG fetch now also sets `$offDone` (the error page must not wait on a map it will never use).
- Gates: `perl -c` clean; 10/10 new assertions on the real `warmOfficial`/`peekOfficial`/`clearOfficial` contract (cb fires exactly once on: no-mbid, cache hit, mid-pass second caller; cb optional; map membership + both fail-open reads; clear drops the map). 0.13.0 bootleg (18) + 0.11.1 matcher (22) + 0.11.0 paging (25) suites still green.

### 0.13.0 (2026-07-10) — ALL bootlegs filtered (artist-wide release browse); 0.12.0's targeted lookup replaced
- **0.12.0 didn't work.** Two bootleg tiles survived: (1) `The Beatles (White Album)` (2000, `d2f8e542`) — 0.12.0's collision key deliberately KEPT bracketed text, so it never collided with `The Beatles`, was never looked up, and rendered as a second White Album. Wrong trade: a false collision costs one cached lookup (the group returns official and shows), a missed collision leaks a bootleg. (2) `The Beatles` (1994, `71aa4dac`) DID collide and was queued — but the collision set was 70 release-groups at MB's 1 req/s ≈ 77s of background work, so it hadn't been reached yet.
- **Root realisation: targeted was both slower AND incomplete.** It cost 96 requests for The Beatles (once the key was fixed to the matcher's `_norm`) and, by construction, could never catch a bootleg whose title collides with nothing.
- **Fix = one artist-wide pass, cheaper than the targeted one.** `release?artist=<arid>&inc=release-groups` returns every release's `status` NEXT TO its release-group id. `API::warmOfficial($artistMbid)` paginates it (100/page, 1.1s gap, REL_MAX_PAGES 40), accumulates `{ rg-mbid => official? }` (a group is official if ANY release is), and caches the whole map as `dsc:rgo:v2:<artist-mbid>` for 14d. The Beatles: **33 requests, 1028 release-groups classified, 678 bootleg-only.** Most artists: one request. `Browse::_buildList` reads the map with `peekOfficial` — pure cache, sync, safe in the render path. `_collisionKey`/`_collisionTitles` deleted.
- Note the map covers ALL 1028 release-groups even though the spine browse caps at 600 (RG_MAX_PAGES 6) — officialness is complete regardless of the spine's truncation.
- **FAIL-OPEN preserved and widened:** map not yet warmed → shows; release-group absent from a warmed map (beyond REL_MAX_PAGES) → shows; releases with NO status → official (MB leaves status unset on obscure releases; the real White Album has 2 status-less releases among its 25). Nothing is cached until the pass COMPLETES, so a partial or failed run never hides anything. In-flight guard: one chain per artist, not one per rebuild.
- Bootleg visibility still lives in the SAME per-visit snapshot as `hide_unmatched` (0.6.0 walk-stability rule). **Refresh now also clears the bootleg map** (`clearOfficial`) — it's the user's "re-check MusicBrainz" button.
- **Still second-load, by design:** the warm fires AFTER the first render (33s for The Beatles), so bootlegs vanish on the next entry into the artist — same contract as the streaming candidate warm.
- Gates: `perl -c` clean; 18/18 assertions on the classifier + map accumulation + all three fail-open paths (incl. order-independence of `||=`, and the 2000 bootleg 0.12.0 leaked); **end-to-end against live MB** — the real 33-page browse classifies 1968 White Album SHOWN, 1994 bootleg HIDDEN, 2000 "(White Album)" bootleg HIDDEN, 1988 compilation SHOWN. 0.11.1 matcher (22) + 0.11.0 paging (25) suites still green.

### 0.12.0 (2026-07-10) — bootleg release-groups hidden (targeted officialness lookup)
- **Bug (field, The Beatles):** after 0.11.1 fixed the matching, three tiles titled "The Beatles" remained (1968, 1994, …). They are NOT reissues — MB already groups reissues as *releases* inside one release-group (the White Album RG holds 25). They are **separate bootleg release-groups**: MB has **14** RGs titled exactly "The Beatles", and **7 have no official release at all**. The 1994 one (`71aa4dac`) is `primary-type=Album`, no secondary types, one release, status **Bootleg** — identical to a real album on every field the RG *browse* returns.
- **The only signal is release `status`, and MB won't give it cheaply.** `status` is rejected on the release-group browse ("not a valid parameter unless releases are requested"); `inc=releases` is rejected there too ("not a valid inc parameter for the release-group resource"). It works ONLY on the per-RG *lookup*, at 1 req/s — 600 RGs = 10 minutes for The Beatles. Wholesale filtering via the release browse (`release?artist=…&status=official`) would be 23 pages / ~25s before first render (2,207 official releases). Both rejected.
- **Fix = targeted.** `Browse::_collisionTitles` finds titles claimed by 2+ RGs of this artist; ONLY those get `API::warmOfficial` (serial, 1.1s gap, background, fired AFTER the render, cached `dsc:rgo:v1:<mbid>` 30d, in-flight guard so rebuilds don't stack chains). A unique title has nothing to be confused with. Weezer's five self-titled albums collide, get looked up, are all official, all survive — which is exactly why officialness and not title-merging is the right tool.
- **`_isOfficial` fails open in three places** (unresolved, no releases, no status set): 1 unless EVERY release carries an explicit non-official status. MB leaves `status` unset on plenty of obscure releases — the real White Album has 2 status-less releases among its 25 — and hiding a real album is far worse than showing a bootleg. Same reason unresolved/HTTP-failed lookups render.
- **Bootleg visibility lives in the SAME per-visit snapshot as `hide_unmatched`**, so a background resolve landing mid-visit can't shift item_ids under a click (the 0.6.0 walk-stability rule).
- `_collisionKey` is lc + whitespace only — deliberately NOT `Sources::_norm`, which strips bracketed text and would collide "The Beatles" with "The Beatles (Deluxe)".
- Track-count/ordering matching (Simon's suggestion) was considered and **not** used as the primary signal: a bootleg of the White Album can carry the same track count and ordering, and it needs `inc=media` on the same expensive per-RG lookup. Officialness separates bootlegs; it also correctly *keeps* same-title-different-album cases. Track count stays a candidate tiebreaker for the residual below.
- **RESIDUAL:** the surviving compilations titled "The Beatles" (1967/1983/1988) are real and still show, in the Compilations section. Distinguishing *those* from the Album-section White Album is a display question, not a data one.
- Gates: `perl -c` clean on both modules; 19/19 new assertions against the real subs (classifier over the REAL status mixes MB returns for those 14 RGs, incl. mixed/status-less/promo-only and the fail-open cases; collision detection incl. the bracketed-variant and Weezer controls); 0.11.1 matcher (22) + 0.11.0 paging (25) suites still green.

### 0.11.1 (2026-07-10) — matcher: self-titled releases swallowed the discography
- **Bug (field, The Beatles):** several "The Beatles" tiles all resolved to the White Album, and Simon's own copies of the Red (`1962–1966`) and Blue (`1967–1970`) albums were nowhere in the view. Root cause: `_albumMatches`' trailing-extra prefix rule (`index($t, "$albumNorm ") == 0`) reads `"<album> <extra>"` as the same album with an edition suffix. When the album title IS the artist name, `albumNorm` = `"the beatles"` matches EVERY candidate titled `"The Beatles …"` — the Red album, the Blue album, `Anthology 1`, `Ballads`. Worse via `claimedLocalIds`: the self-titled release-group CLAIMED his local Red/Blue albums, so they were suppressed from the "Also in your library" safety net too — the one thing that section exists to prevent.
- **Fix:** when `$albumNorm eq $artistNorm` (and the artist is non-empty), match on EXACT normalised title only — no prefix rule, no `_stripFmt`/`_asciiNorm`/`_stripArtistPrefix` fallbacks. `_norm` already strips bracketed decoration, so `The Beatles (White Album)` / `(Remastered)` / `[Deluxe Edition]` still match. The empty-artist path is untouched (matters for LL's saved-item replay variant).
- **Deliberate behaviour change:** an unbracketed suffix on a self-titled album no longer matches (`Weezer` vs `Weezer Blue Album`). That string is indistinguishable from `Metallica` vs `Metallica Through the Never`, and the false positives are far more damaging than the miss.
- **RESIDUAL, not fixable on title alone:** MusicBrainz has FOUR release-groups titled `The Beatles` (the 1968 album + three compilations, 1967/1983/1988). A candidate titled "The Beatles" legitimately matches all four, so duplicate-looking tiles remain. Disambiguating needs the release year (LL's `_bestByYear` tier is the model) and streaming reissue dates make a naive year gate lossy — separate job.
- **FLEET PORT PENDING** (Simon testing DSC first): `matcher_sync_check.py` currently reports DRIFT on `_albumMatches` DSC-vs-LBF/PFR, deliberately. LL carries the same defect in its lenient variant (`$ct =~ /^\Q$albumNorm\E\s/`). Port to LBF + PFR + LL, re-pin LL's variant hash, bump versions and the `lbf:stream`/`lbf:track`/`lbf:pl:resolved` + `pfr:stream` caches, then re-run until exit 0.
- No DSC cache bump: candidates are cached raw and matching runs live, so the fix applies on the next render.
- Gates: `perl -c` clean; 22/22 matcher assertions against the real module (Red/Blue/Anthology no longer swallowed, White Album still matches its decorated listings, Red/Blue still match artist-prefixed listings, empty-artist path unchanged, wrong-artist control, 0.9.1 + 0.10.3 rules intact); paging tests still green.

### 0.11.0 (2026-07-10) — paged sections ("Show more", 30 at a time)
- Long sections (Singles reaches the hundreds) now render **PAGE_SIZE = 30 tiles**, followed by a **"Show more (N)"** row that grows the section by another 30, and — once expanded — a **"Show less"** row that collapses back to 30. Per section, independent (`SINGLES` paging doesn't touch `EPS`); the extras section pages under key `EXTRAS`. Headers keep naming the **true total** (`Singles (87)` over 30 rows), so a capped section reads as paging, not as a lost release.
- **Same mechanism as the bio "Read more"** — a ctx flag + `nextWindow => 'refresh'` — with a COUNT instead of a boolean (`$lastCtx{cid}{page}{<groupKey>}`). The reveal mechanism was never hide-vs-reveal-all; only the flag's type constrained it.
- **`page` added to the same-artist preserve list in `topLevel`.** The paging rows refresh the TOP view, whose re-fetch carries the artist params and lands in the fresh-entry branch — without this it wipes the counter the row just set (the exact 0.8.1 bio bug). The visibility snapshot still resets, as before.
- **Paging rows carry an ABSOLUTE target, never `+= PAGE_SIZE`** (`_pageRow($client,$key,$target,...)`). Deeper clicks re-execute the whole item_id path, so a relative bump could advance more than once; absolute targets keep the plugin-wide idempotence rule intact regardless. `_pageSection` also clamps a stored page to the current total — a Refresh or type-filter change that shrinks a section must not slice past the end.
- Collapsing deletes the ctx key rather than storing the default, so an unpaged section leaves no residue.
- Side benefit: retires the 0.8.1 known risk — typical views now stay under Material's `LMS_MAX_NON_SCROLLER_ITEMS` (100), above which the fixed-row RecycleScroller clips tall text rows (the expanded bio).
- No matcher change (fleet sync check not applicable) and no cache bump — paging is pure view state.
- New string `PLUGIN_DISCOGRAPHY_SHOW_MORE`; new placeholder icon `dsc-pg_MTL_icon_unfold_less.png` (Material maps it to its own `unfold_less`); `unfold_more` reused from the versions toggle.
- Gates: `perl -c` clean; 25/25 behavioural assertions against the real module (cap/no-cap, remainder counts, page-2 row pair, double-click idempotence, collapse, section independence, shrunk-list clamp with no undef tiles).

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
