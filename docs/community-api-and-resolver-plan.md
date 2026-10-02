
# Community API + one artist resolver — plan (2026-09-25)

**Status 2026-10-01: Part B BUILT; Part A in part; Part C APPROVED (Simon: "yes lets move forward"), C3 + C5 BUILT
as 0.56.17 and CHECKED LIVE; its one open case (a non-Latin name opened cold) fixed in 0.56.18 (checked live; its 王菲 regression fixed in 0.56.19, checked live; the "Faye Wong" page's gap fixed in 0.56.20, checked live), C4 DECLINED in the ledger, C2 BUILT as 0.56.21 (measured
beyond Simon's library first, below) and CHECKED LIVE, C1 next; Part D not started.** Everything through
0.56.16 is committed and pushed to `dev` (718c24b); 0.56.21 is installed on the rig and checked live; 0.56.25 (outside the plan: a shared name's biography by mbid; home page: banner, Find an artist, Discography) is built, not installed; 0.56.17-0.56.25 not committed.
- **Part C** (§5) was rewritten on 2026-10-01 from today's code and today's measurements: what is already done, what
  is left (C1 initials, C2 an owned artist with no MusicBrainz tag, C3 the same releases whichever name opened the
  page, C4 §A7 #4 decided, C5 two smaller gaps), and the live list. Approved the same day; built in §5.4's order.
- **Part B** (§4) came in as the efficiency plan's stage 3 (`docs/mb-efficiency-and-community-api-analysis.md`
  §A12-§A14; 0.56.3-0.56.6, checked live). Every gate is gone. The row check is not §4's one batched
  name search, which was measured unsound (analysis §E). It is the typed query's own reply, then one combined search
  trusted only when complete, then the community API by name for the rest.
- **Part A** (§3): the community API gives release counts and judges the search's leftover results. Its helper is
  `_netGet`'s `hosted` bucket with `_hostedHeaders`, not a `_hostedGet`. The page's list came from the community
  API and ListenBrainz by another route (analysis §A16 route A, 0.56.7-0.56.8). The caching (§3.5) is not started.
- **Part D** (§6) is not started; 0.56.10's search layout (Top Result, then Artists with the same-name acts first)
  covers part of it. Rewrite it against that layout after Part C.

*Was: PLAN. No code written.* Built from the code at the last dev push (`ba95148`, the 0.55.x tree) and
from measurements taken on 2026-09-25. It supersedes the "what the code does today" parts of
`docs/unified-artist-resolver-plan.md` (written against the 0.56.0 tree, since reverted) and the migration
sections of `docs/hosted-lms-community-api.md`. Line numbers below are for `ba95148`, and so are the timings
and request counts it calls "today" (The Beatles 23 s, ~43 requests); 0.56.2's live figures are in
`docs/mb-efficiency-and-community-api-analysis.md` §F.2 (The Beatles: 14 requests, bootlegs hidden on the first
visit).

> **Corrected 2026-09-29** (`docs/mb-efficiency-and-community-api-analysis.md` §A11). The MusicBrainz half of
> §2's merge, a paged `arid:<id> AND status:official` search, LOSES groups: The Beatles' 330 came back as 257
> distinct over 4 pages. And demoting the alias browse to the background (§3.3) saved nothing, because the
> browse is the spine. So the release-group browse stays on the render path as the spine and the alias
> source. Stage 2 of the efficiency plan (2026-09-29, analysis §F.2, `CLAUDE.md` dev log) builds the bootleg map
> from the search asked BY ID for the page's groups, and gives an artist under 25 groups its spine from the
> artist read. §2, §3.2, §3.3, §7 and §8 carry the corrections. What this means for Part A is decided at
> Part A, not here (analysis §F.4).

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
**Wrong, 2026-09-29: 330 was the COUNT. The 4 pages hold 257 distinct groups, 73 of them twice; Radiohead's 2
pages were complete by chance.** Paging the search cannot be the MusicBrainz half of this merge (analysis §A11).
The decision itself (first visit complete, second-credited groups included) stands. On next visit, Simon
2026-09-29: *"if we need next visit to get what we need lets look to use it but implement as efficiently as
possible"*; stage 2 uses it only for owned-album lookups the bootleg check cannot answer, and for a failed check.

| call (API.pm) | used for | goes to |
|---|---|---|
| `getReleaseGroups` :2090 (<= 6 pages, `inc=aliases`) | the discography list | **replaced on the render path** by community API `/discography` + the MB official search (1-4 pages), merged by release-group id. The browse itself runs in the BACKGROUND only for release-group aliases until Herger's agreed alias addition ships (§3.3). **Corrected 2026-09-29: stays on the render path.** It is MusicBrainz's only complete list of the artist's groups, second-credited ones included, and its aliases come free. Stage 2: an artist under 25 groups takes it from the artist read instead |
| `warmOfficial` :2711 (<= 40 pages) | official map `o`, release->group map `r`, edition titles `t` | **community API** for `o` and `r` (same `withReleases=1` call). A group only the MB search returned is official by construction. `t`: §3.3. **Stage 2 (2026-09-29): the page's groups BY ID, `release-group?query=rgid:A OR …`, 100 per request (at most 6), for `o`, `r` and `t`; the release browse is gone.** The community API map would stand in for the first-credited groups' requests |
| `warmLocalReleases` :2403 | owned release ids -> their group | **the permanent local store** (§3.5), then the community API `r`, then MusicBrainz for anything neither knows. **Stage 2 (2026-09-29): after the render, only for owned releases the by-id check did not place** |
| `warmCandidateCounts` :1270 | "does this act have releases?" (search rows, collaborations, the resolver's zero-release check) | **community API** entry count first; only when it says 0, confirm with today's MusicBrainz count (one request), because an act credited only second counts 0 there |
| `warmArtistAliases` :1897 | artist aliases + MB canonical name | **community API** `/aliases?mbid=` (matched MB exactly 7 of 7, 2026-09-24) |
| `_artistMbidByName` :692, `getArtistCandidates` :1947 | name -> artist; same-name acts | **stays MusicBrainz** (§1: the community API cannot do it) |
| `warmBandMembers` :2614, `warmCollaborations` :2577 | "member of", collaboration links | **stays MusicBrainz** (`artist-rels`, no hosted route). Their release counts move |
| `getReleaseGroupUrls` :2838 | external links on a release page | **stays MusicBrainz** (hosted album links are keyed by title + a RELEASE id) |

After the move, a cold page's MusicBrainz requests on the render path are: the official search (1-4 pages), band
members, and a name lookup when the artist has no MusicBrainz tag or was opened by name. The community API call
runs alongside, at its own rate (one request at a time, no fixed gap). The 40-page browse is gone. *(Corrected 2026-09-29: the paged search is out. After
stage 2 the render path is: the name lookup, the artist read, the browse (none under 25 groups), and at most 6
by-id requests. The 40-page browse is gone as of stage 2.)*

## 3. Part A — the community API layer

### 3.1 One request helper (`API::_hostedGet`, new)
- Every call sends `X-LMS-Plugin-ID` (guarded `apiHeaders`, `docs/hosted-lms-community-api.md` §0), has a slot
  for a future token pref + `Authorization` header, and treats 401/403 as "unavailable", never a hard fail.
- One in flight, shared 429/503 backoff (the shape agreed in the ledger, `community API has NO hard limit`).
  *Clarified 2026-09-30 (Simon):* "no hard limit" means none PUBLISHED; the fleet sets its own from how MAI uses
  the service (one request at a time, a shared 429 deadline 5-30 s), and the backoff is needed: the service answers
  429 even at that pace after a burst (ledger A3 `COMMUNITY API DOES REFUSE`). Discography's rule, including the
  mandatory plugin-id header and a refused count falling to MusicBrainz: ledger A2 `THE COMMUNITY API IS ONE
  REQUEST AT A TIME, MAI'S RATE`.
- **Every reply is checked:** top-level `mbid` must equal the one sent, else it is a MISS.
- A miss or an error falls back to today's MusicBrainz path for that artist (the existing code, unchanged), so a
  community API outage degrades to today's behaviour, never to an empty page.

### 3.2 The list (`API::getReleaseList`, new; replaces `getReleaseGroups` on the render path)
- In parallel: `GET /music/artist/<name>/discography?mbid=<id>&withReleases=1` (community API) and
  `release-group?query=arid:<id> AND status:official` (MusicBrainz, 100 per page, through `_netGet`'s 1/s queue).
  **Corrected 2026-09-29: not the paged search, which loses groups (analysis §A11).** The MusicBrainz half is
  what stage 2 already runs: the browse (or, under 25 groups, the artist read) and the by-id check for groups
  the community API does not list.
- Merge by release-group id into the existing `{mbid, title, date, type, secondary}` shape, so `Browse` does not
  change. `peekOfficial` (`o`) and `peekReleaseMap` (`r`) filled from the community API's `releases` map (the
  existing `_isOfficial` :2330 rule); groups only the search returned are marked official.
- Awaited before the first render. Cost on a cold public-API page: about 1-2 s for a typical artist, 4-5 s for The
  Beatles (pages x 1.1 s), against 23 s with bootlegs showing today.
- *(A bullet on falling back for a mirror with an unbuilt search index was here. Dropped 2026-09-29: no user
  runs a mirror, so nothing is built for one.)*

### 3.3 What is still deferred until Herger's two pending additions ship
- **Release-group aliases** (the Kraftwerk fix): neither the search nor the community API carries them (0 of
  Kraftwerk's 60 official groups). The existing browse (`inc=aliases`) runs in the BACKGROUND, off the render
  path; on a first-ever visit a foreign-titled album matches one visit later. Removed when the alias addition ships.
  **Corrected 2026-09-29:** the browse stays on the render path as the spine, so the aliases are there on the
  first visit at no cost; nothing runs in the background. The alias addition lets the browse go only with
  another source for second-credited groups (analysis §F.4).
- **Edition titles** (`peekEditions`): same, from the existing release browse, background only; it no longer
  decides the official/bootleg filter. Removed when the release-titles addition ships.
  **Corrected 2026-09-29:** from the by-id check (stage 2), which carries every release's title. The release
  browse is gone.

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
  - *Remote side, every visit, cheap:* the community API list is re-asked on every visit (one call, no fixed gap,
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

*Built 2026-09-30 (stage 3, 0.56.3; checked live on 0.56.4), with the row check described in the status note at the
top. A row lookup runs every pass a page lookup runs; `speculative` keeps only its mirror-retry role.*

## 5. Part C — one artist resolver (REWRITTEN 2026-10-01 against 0.56.16; APPROVED 2026-10-01; C3 + C5 built as 0.56.17)

The 2026-09-25 text of this section planned against code that has since changed (0.56.3-0.56.16) and is in git
history. Everything below was read in today's code or measured today: on the rig (0.56.16, public MusicBrainz,
debug log on for three page opens, then restored to WARN; scratchpad `partc_*.out`) and on the public MusicBrainz and ListenBrainz
APIs (scratchpad `initials_measure.out`, `partc_albumlookup.out`). Design detail and the September measurements
are in `docs/unified-artist-resolver-plan.md`; where the two differ, this section wins.

### 5.1 Already done — no work

| September item | where it landed | checked today |
|---|---|---|
| Streaming searched under MusicBrainz's canonical name first | 0.56.13 `Browse::_poolQuery` (a non-Latin canonical name keeps the Latin browsed name first) | British Sea Power and Sea Power pages are identical (Albums 11, Live 1, Appearances 1) |
| Same-name acts listed and told apart | 0.56.10 (first under Artists), 0.56.12 (MusicBrainz description on matched rows) | Madness, The Bees, Luna, Tennis |
| The owned act first | 0.48.4 "Local trumps" | Luna, James, Tennis, Bob, Madness, The Bees: the user's act is the Top Result |
| Rows resolve on the public API | Part B (stage 3) | — |
| Refresh clears by mbid | 0.56.15 | — |

Luna, James and Tennis were September's regressions of the reverted MusicBrainz-first build, not of the code that
shipped; they pass today and become Part D's guard list.

### 5.2 What is left

**C1. Initials ("ELO" is Electric Light Orchestra).** `_artistMbidByName` prefers an act literally named what was
asked for (0.44.14), so an abbreviation opens an obscure act of that name. Today:
- Search "ELO" (25 rows), "PIL" (26), "EBTG" (1): the user OWNS Electric Light Orchestra, Public Image Ltd and
  Everything but the Girl, and none of them is in the list. "NIN": Nine Inch Nails is row 11 (Qobuz · Tidal).
- Page opened by the name: "ELO" shows one album by another act called ELO under Electric Light Orchestra's
  biography and similar artists (both fetched by name); "PIL" shows a Danish Pil's two albums under PiL's biography;
  "NIN", "EBTG" and "BTO" say "No releases found".

**Fix:** September's rule, from the stash (`_initials`, `_rankCandidates`): one combined query
`artist:"X" OR alias:"X"` (limit 25); an act matched only by an alias whose own name's initials spell the query
wins when that query scores it above every act named the query. Re-measured on public MusicBrainz today:

| query | lifted to | its score vs the best act named the query |
|---|---|---|
| ELO | Electric Light Orchestra | 100 vs 72 |
| PIL | Public Image Ltd | 89 vs 82 |
| NIN | Nine Inch Nails | 100 vs 72 |
| EBTG | Everything but the Girl | 100 vs 98 |
| BTO | Bachman–Turner Overdrive (84) over Brynjar Takle Ohr (74): when two lift, the higher score wins | no act named BTO |

Unchanged, correctly: ABC (an act named ABC scores 100), TLC (100), HAIM (93), KLF (The KLF's initials are "tk"),
Bob (B.o.B is single letters). REM is not lifted either: R.E.M. is single letters, excluded by design so that "Bob"
never opens B.o.B (measured in September); the search already shows the owned R.E.M. first today.

- **Where:** `_artistMbidByName`, after the name search, so every name lookup (a search's typed query, a page
  entered by name, the row check's fallback) agrees. The lifted act's name is kept as its canonical name, as for
  any winner.
- **The search follows without more code:** `_artistSearchView` already searches the services again under
  MusicBrainz's name when it differs from what was typed (0.45.2), and `attachLibraryArtists` then gives that row
  the user's library id by name. So "ELO" should show Electric Light Orchestra, Local, as the Top Result. To be
  confirmed live, not assumed.
- **The shared-name guard must count a lifted act as the name's main one.** `API::_sharesDecision` calls a page a
  lesser act whenever its id is not the top of the same-name set (the acts literally named "ELO"); for such a page
  it hides the biography, similar artists and, with no library id, the user's own albums (0.43.4). Unchanged, a page
  opened as "ELO" would show Electric Light Orchestra's releases with none of those.
- **Cost:** one extra MusicBrainz request, only for a SHORT name (2-5 letters once spaces and dots are dropped),
  only when it is resolved by name (a tagged library artist never is), cached 14 days. About a second added to the
  first search or name-entered page of such a name on the public API.
- **Before it ships:** replay the rule over the library's album artists through the real code. September's
  "changes none of the 1,117" was measured on the mirror with the stashed code.

**C2. An owned artist whose files carry no MusicBrainz artist tag.** BUILT as 0.56.21 with the revised rules below
(CLAUDE.md A2 `AN UNTAGGED LIBRARY ARTIST IS NAMED BY ITS ALBUMS`); the built code replayed on both populations:
library 887 -> 903 right, outside sample 86 -> 417, none made wrong. With no tag, the page resolves by name and
takes the best-scoring act of that name. July's four (2026-07-22 triage, "RESOLVER, NOT MATCHER") still fail today:

| library artist | the page shows today | the user's albums | the album lookup today (one request, first hit, score 100) |
|---|---|---|---|
| Jack (153744) | Jack Johnson: his biography, 9 albums | The Jazz Age, Pioneer Soundtracks, under "Also in your library" | Jack, Welsh band |
| Roswell (155151) | another Roswell's one album | Come Home, Remedy: not on the page at all | Roswell Road, UK acoustic/folk duo (both titles) |
| Muzz (154491) | the producer Muzz's biography and album | Muzz, under "Also in your library" | Muzz, NYC indie rock trio |
| Rico (155050) | another Rico's 5 albums | That Man Is Forward, under "Also in your library" | Rico Rodriguez, Jamaican trombonist |

- **Why not September's owned-album check** (weigh each same-name act's album list against the owned albums): it
  cannot reach two of the four. The Welsh Jack is 32nd on `artist:"Jack"`, outside the 15 the same-name set reads;
  Roswell Road is not NAMED Roswell (it is an alias). It also cost up to 8 requests (ListenBrainz would answer all
  of them in one: `metadata/artist/?artist_mbids=A,B,C,D&inc=release_group`, measured today, 0.33 s for four acts;
  noted for later, not needed here).
- **Fix: the album lookup** (July's tier T1, `tools/mb_identity_probe.py`): `release-group?query=releasegroup:"<an
  owned title>" AND artist:"<library name>"`, then the artist credited on the top hit. Rules, each from July's
  measurement:
  1. only for a library artist with no tag; a tag still wins, and the 0.27.0 check for a tag with no releases is
     unchanged;
  2. the act found must agree with the library name (token subset either way: Roswell / Roswell Road, Rico / Rico
     Rodriguez). Without this gate, classical albums credited to the composer moved orchestras onto composers;
  3. the title asked for is an album credited to this artist (not a compilation they appear on), preferring a
     distinctive title over a self-titled or generic one (`_matchWeight`'s classes);
  4. a miss, an error or a failed name check keeps today's answer;
  5. the answer is kept per library CONTRIBUTOR (its id and name together, so an id reused after a clear-and-rescan
     cannot inherit it), never under the name: a Qobuz row called "Jack" must not start opening the Welsh band.
- **Where:** `Browse::_resolveArtistMbid` (pages entered with a library id), and the search's row check for an
  untagged library row (background work since 0.56.9). That also gives such a row its MusicBrainz description,
  which 0.56.12 withholds from untagged owned rows.
- **Biography:** once the page is the Welsh Jack, the existing shared-name guard (C1's) hides the biography and
  similar artists rather than showing Jack Johnson's (read in `_sharesDecision`: the act is not the name's top one).
- **Cost:** one MusicBrainz request on the first visit to an untagged owned artist, kept 30 days. Tagged artists pay
  nothing.
- **Not the identity index:** no library scan, and no album-to-release-group storing (July's rule 3); only the
  artist.
- **MEASURED 2026-10-02 beyond July's four (Simon: *"needs to work for others ... needs to disambiguate
  properly"*; mirror, as a correctness test, Simon's call).** Today's REAL resolver (0.56.20 `getArtistMbid` by name,
  tag ignored; scratch harness on Sept's `mbdrive.pl` stubs) against the lookup rules, two populations:
  - *The library as if untagged* (1,119 album artists; answer key = the tag July's sweep logged, 914 scorable): by
    name 883 right. The rule as first written above (one title, first hit) 897; the revised rules below 897, with
    15 fixed (Bob, caroline, Palace, Discovery, Weekend, Pacific, Heartworms ... all the user's lesser same-name act)
    and 0 broken. The one "broken" row is Rico, whose contributor carries ANOTHER Rico's tag (the Opgezwolle MC);
    the lookup's Rico Rodriguez is right. The untagged 200: only Jack, Muzz, Roswell change, each to the right act.
  - *An outside sample* (not from the library): 154 common band words and first names, up to 3 same-name acts each
    with an official studio album, a pretend untagged library of 1-3 of its albums (title 2 given "(Remastered)"):
    436 cases. By name 85 right; the rule as first written 322; the revised rules **415, 0 broken**, about 2.5
    requests per artist. The 21 left keep today's answer: 15 a lone self-titled album that several same-name acts
    hold (refused, not guessed), 6 titles the index does not find (Japanese, German).
  - What the measurement changed (each a counterexample): **up to 3 titles** (one title: 322 vs 415); **exact-title
    hits only, and a title two same-named acts hold counts for neither** (generic and self-titled titles);
    **a self-titled title counts when ONE act holds it** (Muzz's only album is "Muzz"; `_matchWeight`'s 0.5 floor
    alone would refuse it); **an act NAMED as the library beats one whose name only contains it** (Nat King Cole:
    "The Best of the Nat King Cole Trio" outvoted "The Collection" until this rule); **stop after the first title when
    it agrees with the name's answer** (same results, 1,092 vs 1,285 requests on the sample).
  - Seen, not yet in the rules: the name check should ignore spacing ("Chocolate Watch Band" / MusicBrainz's
    "Watchband" was refused); a leading "The" in the query blocks "The Go-Go's" (MusicBrainz: "Go-Go's"); a renamed
    act (Kingfisher -> Racing Mount Pleasant) and "2nd"/"Second" stay as today. July's `VARIOUS` regex (`^va`) skips
    any name starting "Va" ("Valley"): never port it.
  - Optional later: the library YEAR breaks a self-titled tie (July's T7) would reach most of the 15 refused.
  - Scratch (session scratchpad): `c2lib.py`, `c2byname.pl`, `c2lookup.py`, `c2score.py`, `c2outside.py`, outputs
    `c2score_v.out`, `c2out_score.out`.

**C3. The same releases whichever name opened the page.** BUILT in 0.56.17 (CLAUDE.md A2 `THE SAME RELEASES
WHICHEVER NAME OPENED THE PAGE`); checked live 2026-10-01, with one case open (a non-Latin name opened cold builds
its pool under that name and never tries the Latin alias), built as 0.56.18: MusicBrainz's primary English alias is
searched first (CLAUDE.md A2 `A NON-LATIN NAME IS SEARCHED IN ENGLISH FIRST`). As built, a copy credited under another of the artist's names is
judged as that name's own page would judge it, title rules included, not only let through the artist test (Tommy
Genesis's self-titled album: her canonical page wants the exact title), and a copy credited under the page's own name
exactly as before. Library copies, the candidate index and the biography stay on the page's name (no field case).
Measured today: "Kenshi Yonezu" shows 24 releases,
"米津玄師" (MusicBrainz's own name for him) says "No releases found". Same mbid (09d4a85c), same pool (Qobuz 73,
Tidal 43); all 39 release groups NO MATCH, because the page tests each candidate's artist against the name it was
opened under (`_buildList` `$artistNorm`) and the services credit "Kenshi Yonezu".
- **Reachable today:** Tidal's search row "米津玄師" (it appears for both spellings) opens that page.
- **And it hides search rows for 7 days:** that render recorded the act as having no releases ("empty artist
  recorded ... search rows for it will be hidden for 7d"), which drops every search row that resolves to it,
  "Kenshi Yonezu" included. Set by today's measurement, cleared by re-opening the "Kenshi Yonezu" page ("empty
  verdict CLEARED ... found 24 release(s)"). Same class as the open Genesis Mohanraj case in CLAUDE.md A2 `STAGE 1
  CHANGED SIX BEHAVIOURS ON PURPOSE` #1 (her 3 releases were rejected on the name); this fix closes that one too.
- **Fix:** the page's artist test accepts MusicBrainz's canonical name and MusicBrainz's aliases for the page's
  mbid, beside the name it was opened under. Both are already cached by the artist read every page makes, so no
  request. Callers: the release matching and owned-album claims in `_buildList`, the "Also on streaming" credit
  test, and the release page (`_releaseDetail`), so a release page agrees with its tile. Call-site logic, like
  0.24.0: the shared matcher subs are untouched, so no fleet port.
- Biography and similar artists by MusicBrainz's name instead of the browsed one: not changed unless the live check
  shows them differing between the two names.

**C4. §A7 #4 (the combined name query) — not taken as an efficiency change.** DONE 2026-10-01: the ledger entry
is now `A7 #4 IS DECLINED`. Replacing `_artistMbidByName`'s
`artist:` and `alias:` passes with the one combined query re-orders the acts named the query: HAIM would open Haïm
(measured on the public API 2026-09-29). The combined query is asked only by C1, only for short names, and never
reorders the name tier. On approval, the ledger entry `A7 #4 IS HELD FOR THE RESOLVER` becomes DECLINED with this
reason.

**C5. Two smaller gaps found reading the code (no live failure seen).** BUILT in 0.56.17 with C3 (`Browse::_poolOpts`;
`Sources::getCandidates` converts every name it is given):
- The release page asks for its streaming matches without the artist page's shared-name flag and MusicBrainz
  aliases (`_releaseDetail` against `_discographyView`'s `$go`). Writer: a release page opened after the 3-day pool
  has expired, for a name several acts share; it then picks the service artist without the strict check and writes
  the pool both pages read. One helper builds the options for both pages.
- Names tried after the first (the browsed name, aliases) reach a service's artist search without that service's
  text conversion (`query_enc`). Writer: Deezer, which takes bytes, with a non-ASCII alias. Not testable on the rig
  (no Deezer account); suite only.

### 5.3 Dropped from September's Part C
- **English labels on MusicBrainz-only rows** (Kenshi Yonezu for 米津玄師): today's search lists only acts named as
  typed, so a label in another script can only appear once alias-matched acts are listed. Moved to Part D.
- **The owned-album check that weighs every same-name act:** replaced by C2's album lookup (above, why).

### 5.4 Order and checks
C3 with C5 first (smallest; stops a wrong 7-day verdict), then C2, then C1 (with its library replay). Each step:
suites before and after, mutation-checked, `MBID_CACHE_V` bumped for C1 (a 30-day `dsc:mbid` entry holds today's
answer for "ELO"; the fleet rule for a resolve fix; C2 keeps its answers per contributor, not in that cache), then
the live check on the rig, results shown to Simon before the next step. Code from the 0.57.0 stash (`git stash list`) is reused sub by sub only after re-reading it.

Live list:
- **Changed:** ELO, PIL, NIN, EBTG, BTO (the band is in the search, the Top Result and Local where owned; the page
  is the band's, with its own biography); Jack, Roswell, Muzz, Rico (the page is the user's act, its albums on their tiles);
  米津玄師 = Kenshi Yonezu (the same releases, no "empty" verdict).
- **Unchanged:** ABC, TLC, HAIM, KLF, Bob, REM, Madness, The Bees, Luna, James, Tennis, British Sea Power / Sea
  Power, Radiohead (tagged: no extra request).

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
   aliases; background browses for the two deferred pieces *(corrected 2026-09-29: none, §3.3)*; the caching of
   §3.5 incl. the permanent local store.
   Live, on public: The Beatles and Willie Nelson cold (first render complete and filtered, time it), Sonic Boom
   (*Reset* on the FIRST visit), Kraftwerk (alias matches after the background browse), an unknown/merged mbid
   (falls back to MB), a revisit after forcing expiry (renders at once), and the local store surviving a plugin
   upgrade AND a clear-and-rescan.
2. **Part B** (§4): row check everywhere, batched names, the three speculative gates, the canonical second pass.
   Live: Genesis (dead ends gone, Tommy Genesis merged), British Sea Power (Qobuz present), Hall and Oates and
   Shostakovich (search, then page: right act both times).
   **BUILT as stage 3/3b (0.56.3-0.56.6).** The live checks are analysis §A12.9 and the dev log's 0.56.5 and 0.56.6
   entries (Genesis, British Sea Power, Hall and Oates right).
3. **Part C** (§5, rewritten and approved 2026-10-01): C3 + C5 (built as 0.56.17), then C2, then C1. Live: the list in §5.4. (Canonical-first
   streaming was built in 0.56.13; English labels moved to Part D; OMD dropped from the list, Simon 2026-10-01:
   it already works.)
4. **Part D** (§6): MusicBrainz-first search list. Live: Hawkwind, ELO, Madness, Beatles.
5. Full soak on public against the stage-0 baseline; every loss explained or fixed. Then docs, then ask to build.

## 8. Cost on the public API (before -> after)

| action | today | after |
|---|---|---|
| cold page, big artist (The Beatles) | ~43 MB requests (1 name + 6 + 34 + members/collabs/owned), 23s to render, bootlegs unfiltered, can fail and repeat | 1 name + 4 search pages + band members (~6s), community API in parallel; complete, bootlegs filtered, first visit |
| cold page, normal artist | 1 + list pages + release pages (Radiohead: 6 + 12) | 1 + 1-2 search pages (Radiohead: 2) + community API |
| revisit after expiry | full cold cost again | renders from the expired copy at once, refreshes in the background |
| search list, 15 rows | 1 MB request (row check skipped) | 1 batched MB name search + community API counts (one at a time, no fixed gap) + 1 canonical lookup per new term |
| background, until Herger's two additions ship | none | today's group browse (aliases) + release browse (edition titles), off the render path |

*Corrected 2026-09-29 (analysis §A11):* the first two rows assumed the paged search. Measured for stage 2 (one
name search, tagged owned albums): The Beatles **43 → 14** (name, artist read, 6 browse pages, 6 by id), Radiohead
21 → 14, a normal artist under 25 groups 5 → 3. The last row is void: nothing runs in the background, the browse
stays the spine, and edition titles come from the by-id check.

## 9. Not in this plan

Classical composer/performer conflation (parked); prose bio (MAI); "Also a member of" beyond today's; any NEW
request to the community API's maintainer (the two pending ones stand).
