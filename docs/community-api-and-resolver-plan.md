
# Community API + one artist resolver — plan (2026-09-25)

**Status: PLAN. No code written.** Built from the code at the last dev push (`ba95148`, the 0.55.x tree) and
from measurements taken on 2026-09-25. It supersedes the "what the code does today" parts of
`docs/unified-artist-resolver-plan.md` (written against the 0.56.0 tree, since reverted) and the migration
sections of `docs/hosted-lms-community-api.md`. Line numbers below are for `ba95148`.

## 0. Rules this plan is held to

- **The public MusicBrainz API is what we work to.** Behaviour is identical on public and on a mirror; the
  only allowed difference is pacing. Simon's rig can stay on its mirror; no code path may depend on one.
  (CLAUDE.md, top section.)
- **Scope is canonical (official) releases.** Spine caps and bootleg handling are known limits, not findings.
- **No NEW requests to Herger.** The two already sent still stand and are expected: release-group aliases on
  each `/discography` entry (agreed) and release titles in the `withReleases` map (for edition titles). Until
  they ship we work around them (§3.3); nothing else is asked for.
- **Reuse existing mechanisms** (the Kraftwerk alias matching, the Madness candidate handling, the owned-album
  check) before adding a rule.
- **Every stage is measured on the PUBLIC API before it is called done.** The rig is switched for the check and
  switched back.

## 1. What the plan rests on (measured, 2026-09-25 unless dated)

| fact | evidence |
|---|---|
| Public MB is slow for us because of serial PAGES, not name lookups | The Beatles, cold, rig on public: release groups 6 pages (~6s), then the official/bootleg browse 34 pages (~37s); 15s deadline fired, page rendered at 23s unfiltered; the browse then FAILED with a 503 twice and cached nothing (one bad page discards the whole browse) |
| The community API answers the same in one call | `/artist/<name>/discography?mbid=<id>&withReleases=1`: The Beatles 1039 groups + 3268 releases with status in 0.08s (Cloudflare-cached; a first request was ~0.6s in July, not re-measured) |
| It only lists groups where the artist is FIRST in the credit | Willie Nelson: MB 489 groups, hosted 423; all 67 missing credit him second or later. Today they are in the MB list and show when matched: Willie's are unmatched (Qobuz files them under the first-named artist) and hidden, but Sonic Boom's page shows *Reset* (Simon, on the rig). Asking by the joint name finds nothing (an empty entry, id unknown to MB). Hence the list merges the community API with a MusicBrainz official-groups search (§2) |
| An id it does not know is silently answered by NAME | ledger §A3 `silently falls back to the NAME` (2026-09-24). Every reply's top-level `mbid` must equal the one sent |
| It cannot turn a NAME into the right artist | `/aliases` by name: 4 of 22 confidently wrong (2026-09-24); re-checked today: Rossini -> Rossini Quartet, The Las -> The Las Vegas Boneheads. One guess, no candidates, no score |
| Release-group aliases and release titles are NOT there yet | Kraftwerk `/discography`: no aliases field; `releases` map is `{release-id: status}` only |
| Batching MB name lookups works; batching release checks does not | One `artist:"A" OR artist:"B" ...` search matched 7 of 8 rows to the same act as per-name searches (the 8th found via alias, a gain). One release-group search for 6 artists: ELO took 94 of 100 results; Genesis and The Beatles did not appear |
| MAI's discography is Discogs, not the community API | MAI master `ArtistInfo::getDiscography` -> `Discogs::getDiscography` (api.discogs.com); its MusicBrainz version is commented out |

## 2. Every MusicBrainz call the plugin makes, and where it goes

**Decision (Simon, 2026-09-25): the page's release list is the community API list MERGED with a MusicBrainz
official-groups search, both fetched in parallel and awaited, so the FIRST visit is complete.** The community API
lists only groups where the artist is named first; the search adds the rest (collaborations), and only official
ones. Measured (public MB, 2026-09-25): `release-group?query=arid:<mbid> AND status:official` = Radiohead 101
groups / **2** pages (the browse takes 6), Sonic Boom 28 / **1** page with *Reset* and 17 second-named groups, The
Beatles 330 / **4** pages and complete (today's browse stops at 600 of 1050). "Next visit" was ruled out (Simon).

| call (API.pm) | used for | goes to |
|---|---|---|
| `getReleaseGroups` :2090 (<= 6 pages, `inc=aliases`) | the discography list | **replaced on the render path** by community API `/discography` + the MB official search (1-4 pages), merged by release-group id. The browse itself runs in the BACKGROUND only for release-group aliases until Herger's agreed alias addition ships (§3.3) |
| `warmOfficial` :2711 (<= 40 pages) | official map `o`, release->group map `r`, edition titles `t` | **community API** for `o` and `r` (same `withReleases=1` call). A group only the MB search returned is official by construction. `t`: §3.3 |
| `warmLocalReleases` :2403 | owned release ids -> their group | **the permanent local store** (§3.5), then the community API `r`, then MusicBrainz for anything neither knows |
| `warmCandidateCounts` :1270 | "does this act have releases?" (search rows, collaborations, the resolver's zero-release check) | **community API** entry count first; only when it says 0, confirm with today's MusicBrainz count (one request), because an act credited only second counts 0 there |
| `warmArtistAliases` :1897 | artist aliases + MB canonical name | **community API** `/aliases?mbid=` (matched MB exactly 7 of 7, 2026-09-24) |
| `_artistMbidByName` :692, `getArtistCandidates` :1947 | name -> artist; same-name acts | **stays MusicBrainz** (§1: the community API cannot do it) |
| `warmBandMembers` :2614, `warmCollaborations` :2577 | "member of", collaboration links | **stays MusicBrainz** (`artist-rels`, no hosted route). Their release counts move |
| `getReleaseGroupUrls` :2838 | external links on a release page | **stays MusicBrainz** (hosted album links are keyed by title + a RELEASE id) |

After the move, a cold page's MusicBrainz requests on the render path are: the official search (1-4 pages), band
members, and a name lookup when the artist has no MusicBrainz tag or was opened by name. The community API call
runs alongside, un-throttled. The 40-page browse is gone.

## 3. Part A — the community API layer

### 3.1 One request helper (`API::_hostedGet`, new)
- Every call sends `X-LMS-Plugin-ID` (guarded `apiHeaders`, `docs/hosted-lms-community-api.md` §0), has a slot
  for a future token pref + `Authorization` header, and treats 401/403 as "unavailable", never a hard fail.
- One in flight, shared 429/503 backoff (the shape agreed in the ledger, `community API has NO hard limit`).
- **Every reply is checked:** top-level `mbid` must equal the one sent, else it is a MISS.
- A miss or an error falls back to today's MusicBrainz path for that artist (the existing code, unchanged), so a
  community API outage degrades to today's behaviour, never to an empty page.

### 3.2 The list (`API::getReleaseList`, new; replaces `getReleaseGroups` on the render path)
- In parallel: `GET /music/artist/<name>/discography?mbid=<id>&withReleases=1` (community API) and
  `release-group?query=arid:<id> AND status:official` (MusicBrainz, 100 per page, through `_netGet`'s 1/s queue).
- Merge by release-group id into the existing `{mbid, title, date, type, secondary}` shape, so `Browse` does not
  change. `peekOfficial` (`o`) and `peekReleaseMap` (`r`) filled from the community API's `releases` map (the
  existing `_isOfficial` :2330 rule); groups only the search returned are marked official.
- Awaited before the first render. Cost on a cold public-API page: about 1-2 s for a typical artist, 4-5 s for The
  Beatles (pages x 1.1 s), against 23 s with bootlegs showing today.
- A mirror whose search index is unbuilt answers the search with nothing: falls back to today's browse (the
  existing mirror safety net, `_mbSearchVerdict`).

### 3.3 What is still deferred until Herger's two pending additions ship
- **Release-group aliases** (the Kraftwerk fix): neither the search nor the community API carries them (0 of
  Kraftwerk's 60 official groups). The existing browse (`inc=aliases`) runs in the BACKGROUND, off the render
  path; on a first-ever visit a foreign-titled album matches one visit later. Removed when the alias addition ships.
- **Edition titles** (`peekEditions`): same, from the existing release browse, background only; it no longer
  decides the official/bootleg filter. Removed when the release-titles addition ships.

### 3.4 Second-named releases and collaborations (measured 2026-09-25) — present on the FIRST visit

| page | community API | MB official search | result |
|---|---|---|---|
| "Robert Plant & Alison Krauss" (MB duo artist 38eb4af8) | Raising Sand, Raise the Roof | same | same as today |
| "Panda Bear & Sonic Boom" (no MB artist; `_creditHead` opens Panda Bear) | Reset | Reset | same as today |
| **Sonic Boom** (second-named on Reset) | not listed | **Reset** | Reset shows, first visit |

A second-named BOOTLEG is not added (the search asks for official only), which is stricter than today. The
joint-credit fold (`Sources::_jointArtistIds` :412) is library-side and unchanged.

### 3.5 Caching: results, the ids that make a revisit cheap, and a PERMANENT local store (Simon, 2026-09-25)
Simon: *"as long as we cache the results and any ids that save us time when the cache expires and we need to
revisit. I am thinking local albums should cache permanently and just look for updates when opened."*

- **Results** keep today's lifetimes: the merged list and status 14 days, name -> artist 30 days, aliases 30 days.
- **When a result expires, render from the expired copy and refresh in the background** (stale-while-revalidate,
  LBF's feed pattern). A page seen once never waits on the network again; the expired copy is kept for a longer
  hard limit (proposed 90 days) purely as that fallback.
- **Ids kept so a refresh skips work:** (1) the artist's mbid (exists, `dsc:mbid`); (2) per MB artist, the SERVICE
  artist id each service resolved to (Qobuz/Tidal/Deezer/Spotify), so a pool refresh fetches that artist's
  albums by id and skips the artist search and the spine check that chose it; it is still re-checked if the fetch
  fails or returns nothing; (3) owned release -> group (below).
- **Local albums: a permanent store** (new), holding each owned album's match: release group, and how it was
  matched (MB release id, edition title, title). **Keyed by the release mbid when the album is tagged, otherwise by
  normalised artist + title**, never by LMS `album_id`, which a clear-and-rescan reassigns. On every page open the
  existing live `localAlbums` query (one local DB read, ~20 ms) lists what is owned now; only albums NOT in the
  store are matched and added, and albums no longer owned are simply not shown. No expiry.
- **It lives in Discography's own SQLite store, `DB.pm` (built in 0.56.0), not in `Slim::Utils::Cache`.** The
  fleet decision (LBF `docs/caching-rework.md` §2.1): anything that must survive needs a table, because the LMS
  cache is disposable and reads lifetimes over 30 days as a 1970 date. `DB.pm`'s `kv` table is emptied per
  build (CACHE_VERSION), its `mbid` and `artist` tables are not. The owned-album store below is a new table
  there, cleared only by Refresh / `clearcache` for that artist or a deliberate key-version bump (the fleet rule:
  a resolve fix needs a cache bump). *(Corrected 2026-09-25: this bullet first proposed a second LMS-cache
  namespace with a fixed version, contradicting that decision.)*
- **No MusicBrainz id in the file? Find it once, keep it** (Simon, 2026-09-25: *"when looked up and no mb it
  should be able to get the mbid and then cache that going forward"*). An untagged owned album that gets matched
  (by edition title, title, or a release lookup) has the release-group id it matched to written into the
  permanent store, so every later visit matches it by id like a tagged album and never by title again. The same
  for a library ARTIST with no MusicBrainz tag: the mbid the resolver chose is stored permanently against that
  library artist (keyed by normalised name, not contributor id, for the rescan reason above). A library tag, when
  present, always wins over a stored id.
- **Not in MusicBrainz = no match, but a "no match" is never stored as a fact** (Simon, 2026-09-25: *"if its not
  in MB then not much we can do other than offer no match, unless we find its matcher logic and not MB"*). An owned
  album that matches nothing shows as today ("Also in your library"); an artist MusicBrainz cannot identify shows
  "Couldn't identify" as today. The store records the MISS with its reason and the matcher version that produced
  it, never as a permanent answer: it is re-tried when the matcher version changes (so a matcher fix reaches every
  old miss without a manual refresh), on a manual refresh, when the album's fingerprint changes, AND on a visit
  once the miss is 7 days old (in the background). **Why the last one:** Simon adds albums he owns to MusicBrainz
  himself (2026-09-25: *"I would manually update MB for albums not in it that I own, so yes its not a permanent no
  match"*), so a "not in MusicBrainz" miss is expected to become a match. The public API sees an edit at once and
  the community API within a day; a manual Refresh picks it up immediately. (A local mirror only sees it after the
  mirror is updated; it does not replicate on its own.) The reason
  separates the two cases Simon named: **not in MusicBrainz** (one release search for the title + artist finds
  nothing) versus **our matcher** (MusicBrainz has a release by that title and artist, and it was not matched). The
  second is logged as a matcher gap with both titles, so it can be diffed and fixed rather than left as a silent
  no match. That check costs one MusicBrainz request per unmatched album, once, then it is stored.
- **Manual refresh, as today** (Simon: *"same as we do now"*). The artist page's Refresh row (`_refreshItem`) and
  the `["discography","clearcache","artist:<name>"|"mbid:<id>"]` command keep working and ALSO clear that
  artist's entries in the permanent store and the kept service artist ids, so a refresh re-resolves and re-matches
  everything from scratch. This is the escape hatch when anything cached is wrong or stale.
- **A visit updates anything that has changed** (Simon: *"it also needs to update if needs be when we visit and its
  different"*):
  - *Library side, every visit, free:* each stored album carries a fingerprint (its MusicBrainz release tag, title
    and track count). If the live `localAlbums` read shows a different fingerprint (retagged, re-ripped, edition
    swapped) or a new album, that album is re-matched on this visit and the store updated; a removed album drops
    out. A library artist whose MusicBrainz tag now differs from the stored mbid takes the tag.
  - *Remote side, every visit, cheap:* the community API list is re-asked on every visit (un-throttled, one call,
    usually a Cloudflare cache hit). If its set of release groups differs from the cached one, the MusicBrainz
    search is re-run too and the page renders the new list on THIS visit. Otherwise the cached MusicBrainz part is
    used until it expires, then refreshed in the background as above.
  - *Streaming side:* a kept service artist id that now returns nothing or fails its spine check is dropped and the
    service artist is searched for again on that visit.
- The dev rule "every build clears caches" still holds for everything else; the permanent store is the one stated
  exception, because it holds the user's own library matches, which do not go stale when the code changes. If a
  build changes HOW local albums are matched, that build bumps the store's format version.

## 4. Part B — remove the mirror-only behaviour

Five places skip work unless MB is a mirror. All five go; the work is made affordable instead of skipped.

| where (`ba95148`) | what public users miss today (verified live on the rig, 2026-09-25) | replaced by |
|---|---|---|
| `API::filterRowsWithContent` :1335 early return | dead-end rows shown ("Genesis Tajiri" -> "Couldn't identify"), alias rows not merged (Tommy Genesis), library not attached by tag | row check runs everywhere: names resolved with ONE batched MB search per result list (§1), release counts from the community API |
| `_artistMbidByName` alias pass :975, credit split :1055, zero-release check :1087 (speculative + public) | nothing yet (only reached via the row above); would PUT WRONG ANSWERS in the shared name cache (Hall And Oates / Shostakovich measured on public) | removed: a row lookup runs the same passes as a page lookup, so the shared `dsc:mbid` cache is never written with a lesser answer |
| `Browse.pm:3457` second service search under the canonical name | "British Sea Power" search: no Qobuz (verified live) | runs everywhere; one name lookup per new term, cached 30 days |

Mirror safety nets stay (a mirror that errors or has an unbuilt index falls back to public): they do not change
public behaviour.

## 5. Part C — one artist resolver

The design in `docs/unified-artist-resolver-plan.md` §1–§6 stands (ranked candidates with the measured
initialism lift; the owned-album check whenever there is more than one act; English label on MusicBrainz-only
rows; streaming asked canonical first; same material whichever name opened the page). It is **rebuilt on the
current code, with Parts A and B underneath it**, and the 0.57.0 build is NOT restored as a whole.

The 0.57.0 review (2026-09-25) found defects that the rebuild must not repeat. Each becomes a requirement with a
suite:

| 0.57.0 defect | requirement |
|---|---|
| Duplicate rows for an alias act on public ("Beatles" -> two "The Beatles") | fixed by Part B (rows resolve on public too) plus a join on the MB name / English name / inline aliases the ranked list already carries |
| MB aliases and the demoted browsed name sent to the services unconverted (Deezer takes bytes) | every name, not just the first, goes through the adapter's `query_enc` |
| Release page resolves without `ambiguous` and writes the shared pool | the release page asks EXACTLY what the list asks, `ambiguous` included, through one helper |
| Collaboration filter and same-name guard compare one name while the lookup uses another | both test the browsed name AND MB's names |
| Refresh cleared another act's caches via a name-only clear | every clear carries the mbid |
| "Also on streaming" credit gate ignores MB's other names | same `artistAlts` rule as the matcher |

Code from the 0.57.0 stash (`git stash list`: "0.56.0/0.57.0 working tree") may be reused sub by sub
(`rankArtistCandidates`, `_initials`, `searchArtistCandidates`, the suites `t_rankcands`, `t_ownedcheck`,
`t_mbcands`, `t_mbfirst`, `t_canonfirst`), each re-read against this plan before it goes in. Nothing is taken
unread.

## 6. Part D — the search list, MusicBrainz first (redo)

The ledger decision `THE SEARCH LIST IS MUSICBRAINZ-FIRST` stands (Simon: "searching MB first to get the
discography then streaming to make matches"); it is not in the code since the revert. Rebuilt on Parts B and C:
rows are the ranked MusicBrainz acts, service and library rows join them by resolved mbid (now available on
public too), owned acts first.

## 7. Order of work

Each stage: suites green before and after, mutation-checked, then a live check **on the public API**, results
shown to Simon before the next stage starts.

0. **Baseline on public.** The existing `sweep/baseline-0.55.0` was taken with the rig on its mirror. Re-take
   the search soak and probe with the rig on public, on the current build, so "gains not losses" is measured
   against what users get.
1. **Part A** (§3): helper, merged list (community API + MB official search), status/release maps, counts,
   aliases; background browses for the two deferred pieces; the caching of §3.5 incl. the permanent local store.
   Live, on public: The Beatles and Willie Nelson cold (first render complete and filtered, time it), Sonic Boom
   (*Reset* on the FIRST visit), Kraftwerk (alias matches after the background browse), an unknown/merged mbid
   (falls back to MB), a revisit after forcing expiry (renders at once), and the local store surviving a plugin
   upgrade AND a clear-and-rescan.
2. **Part B** (§4): row check everywhere, batched names, the three speculative gates, the canonical second pass.
   Live: Genesis (dead ends gone, Tommy Genesis merged), British Sea Power (Qobuz present), Hall and Oates and
   Shostakovich (search, then page: right act both times).
3. **Part C** (§5): resolver, owned-album check, English labels, canonical-first streaming, same-material diff.
   Live: the plan's list (ELO, PIL, NIN, OMD, KLF, Luna, James, Madness, Kenshi Yonezu, Кино, The Bees).
4. **Part D** (§6): MusicBrainz-first search list. Live: Hawkwind, ELO, Madness, Beatles.
5. Full soak on public against the stage-0 baseline; every loss explained or fixed. Then docs, then ask to build.

## 8. Cost on the public API (before -> after)

| action | today | after |
|---|---|---|
| cold page, big artist (The Beatles) | ~43 MB requests (1 name + 6 + 34 + members/collabs/owned), 23s to render, bootlegs unfiltered, can fail and repeat | 1 name + 4 search pages + band members (~6s), community API in parallel; complete, bootlegs filtered, first visit |
| cold page, normal artist | 1 + list pages + release pages (Radiohead: 6 + 12) | 1 + 1-2 search pages (Radiohead: 2) + community API |
| revisit after expiry | full cold cost again | renders from the expired copy at once, refreshes in the background |
| search list, 15 rows | 1 MB request (row check skipped) | 1 batched MB name search + community API counts (un-throttled) + 1 canonical lookup per new term |
| background, until Herger's two additions ship | none | today's group browse (aliases) + release browse (edition titles), off the render path |

## 9. Not in this plan

Classical composer/performer conflation (parked); prose bio (MAI); "Also a member of" beyond today's; any NEW
request to the community API's maintainer (the two pending ones stand).
