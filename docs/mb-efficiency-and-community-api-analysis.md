# MusicBrainz call efficiency, public/mirror parity, and the Community API — full analysis

> **STATUS 2026-10-01 — WHERE THE PLAN STANDS. The dated notes after this one are history.**
> - **Stages 1 and 2** (§F.1-2): committed on `dev`, unpushed.
> - **Stage 3** (§F.3, §A12), the public-API gates removed: built as 0.56.3, fixed as 0.56.4 and checked live
>   (§A12.9).
> - **Stage 3b** (§A13), the search's leftover results asked of the community API, and what the search proves handed
>   to the page: 0.56.5, checked live (the 16 searches' MusicBrainz requests 319 -> 51 on a first search).
> - **0.56.6** (§A14), more of those answers proven in the same requests: checked live.
> - 0.56.3-0.56.6 are installed on the rig; committed with 0.56.7-0.56.8 (below).
> - **2026-10-01: §A16 route A, BUILT as 0.56.7, INSTALLED and CHECKED LIVE:** the artist page draws from
>   ListenBrainz's list and the community's verdicts, MusicBrainz completing it in the background for the next
>   visit. Big pages 6.8-16 s -> 2.4-3.2 s; 22 albums over 7 artists a visit late (edition titles). The check found
>   that a Refresh hid the groups past the 600 cap for 14 days: **fixed as 0.56.8 (built, not installed, live check
>   owed)**, which also removes the 1,500-group ceiling (the Stones and Springsteen took the 15 s path), leaves out
>   the community's merged-away ids (Nirvana showed 3 such tiles) and bounds the bootleg check before the draw at
>   two requests (the composers). Then D2 for the search.
> - **2026-10-01, 0.56.7 and 0.56.8 INSTALLED and CHECKED LIVE, committed on `dev` with 0.56.3-0.56.6 (6f699ba,
>   unpushed).** Composer pages emptied on 0.56.8: PARKED with classical (Simon).
> - **2026-10-01, D2 DECIDED and BUILT as 0.56.9 (not installed):** the search does not wait for its row check
>   (Simon: *"this in reality should be the quickest part ... just hide them on 2nd search"*). Measured: Qobuz and the
>   library answer in 0.7-0.9 s, the check took a first search to 6-13 s. Rows are decided from what earlier checks
>   kept; the rest are shown and checked after the reply, as background work, and hidden on the next search. The
>   same-name section's counts likewise (D3's waiting is gone with it). Ledger A2 `THE SEARCH DOES NOT WAIT FOR ITS
>   ROW CHECK`; dev log 0.56.9.
> - **Open:** D3's remaining idea (MusicBrainz taking a waiting count when free) is moot for the search now that
>   nothing there waits on a count. §A7 #4, held for the resolver (Part C of
>   `docs/community-api-and-resolver-plan.md`); Parts C and D of that plan, not started. §F.4 (the community API for
>   the page's spine and status map) was built by §A16's route A (0.56.7).
> - **Not taken:** §A12.10, no MusicBrainz at search (Simon: "a step backwards"); §A13 was built instead.
> - **Also open, outside this plan:** finding 7 of the stage-1 review, DB.pm `get()`'s fall-through from the mbid
>   table to kv (recommended KEEP, undecided; CLAUDE.md dev log, stage 1).

> **Status 2026-09-30 (afternoon, history) — stage 3 steps 1-3 BUILT in the working tree (Simon: "proceed with your revised
> plan"), uncommitted, NOT built as a zip, NOT checked live.** Step 4, the check on the rig on the public API, is
> next and needs a build. Removing the gates as they stood made a multi-row first search three to six times slower
> on the public API; §A12.6's four steps keep the behaviour identical everywhere for less. Step 1 was gated on the
> order test and changed as a result (§A12.8: one request at 15 for page AND search, identical on all 1,117
> library artists).
> §A12.7 (same day): the community API can take the counts only, not the name lookups. Its rate is the fleet's own,
> set from how MAI uses it (one request at a time, a 5-30 s backoff after a 429), and it answers 429 even at that
> pace after a burst, so a search must not wait out the backoff (ledger A2 `THE COMMUNITY API IS ONE REQUEST AT A
> TIME, MAI'S RATE`).
> **Reviewed inline the same day** (CLAUDE.md dev log, stage 3, "Review"): no correctness defect; the typed query's
> lookup now runs alongside the service search, and a count is asked once per search; D3 (below, §A12.6) is open for
> step 4; the merge's artist read is accepted (§F step 3); the five behaviour changes are kept (ledger A2 `STAGE 3
> CHANGED FIVE BEHAVIOURS ON PURPOSE`).

**Date:** 2026-09-26 · **Code read:** the working tree at `0.56.0` (uncommitted, on `dev`)
**Everything below was measured live today** against `https://musicbrainz.org/ws/2/` and
`https://api.lms-community.org`. No number here is an estimate unless it says so.

> **Status 2026-09-29 — stage 1 (§F) is in the code, not built.** §A7 #1–#3 are implemented and committed on
> `dev`: aliases and band members from one `artist/<id>?inc=aliases+artist-rels` read, owned albums in
> `reid:` batches of 50, and one `inc=artist-rels+release-groups` lookup per collaboration candidate
> (`CLAUDE.md` dev log, "MusicBrainz efficiency stage 1"). Its code review (2026-09-29) fixed four
> findings: Refresh now clears a composer-only id's owned releases, a last batch of one id is a lookup not a
> search, two stale comments, and DB.pm's orphan cleanup follows its column list; 47 suites, 1,449 assertions,
> 0 failures. **Built as 0.56.1 and VERIFIED LIVE on the mirror and the public API (2026-09-29)**, see §A10.
> **§A7 #4 is HELD for the resolver work** (Part C of `docs/community-api-and-resolver-plan.md`): the combined
> query changes which artist a name resolves to. Measured: HAIM would open Haïm (§A7). Stages 3–4 not started.
>
> **Stage 2 re-measured and re-designed, 2026-09-29 (§A11).** The route in §A1–§A5 was wrong twice.
> Paging the release-group search by artist LOSES groups, and demoting the alias browse to the background would
> have made foreign-titled albums match a visit late for no saving. Stage 2 is now the bootleg check BY ID
> (§F.2): the page's groups are asked for by id, 100 per request, and the release-group browse stays the spine
> and alias source. An artist with fewer than 25 groups gets its spine from the artist read the page already
> makes. §0, §A1–§A6, §A9, §C5, §D and §E carry the corrections. **Built as 0.56.2 and VERIFIED LIVE on the
> public API 2026-09-29 (all four checks pass); committed on dev.**

---

## 0. Summary in ten lines

1. There is a MusicBrainz route we have never used: the **release-group SEARCH**. It returns,
   per group, the type, the date **and the group's full release list with each release's id,
   title and status**. *(Corrected 2026-09-29, §A11: paged by artist, `arid:<mbid>`, it LOSES
   groups. Asked by id, `rgid:A OR rgid:B …`, 100 per request, it is exact.)*
2. Asked by id for the page's groups, it does the job of the up-to-40-page release browse: the
   bootleg map, the release→group map and the edition titles. *(Corrected 2026-09-29: it does
   NOT replace the release-group browse. It cannot list groups it is not given, and it carries no
   group aliases. The browse stays the spine; under 25 groups the artist read carries it.)*
3. Spine + bootleg filter: The Beatles **40 → 12 requests**, Radiohead 18 → 12, Kraftwerk 8 → 4,
   an artist under 25 groups 2 → 1. *(Corrected 2026-09-29: the paged figures, 40 → 6, assumed a
   complete paged search. Whole cold page: §A11.)*
4. *(Withdrawn 2026-09-29.)* It was said to remove the 600-group spine cap. It does not: the ids
   come from the browse, which keeps the cap (a known limit, not a defect).
5. Four smaller savings on top: one artist call instead of two, one batched lookup instead of N,
   one collaboration call instead of two, one name query instead of up to three. *(2026-09-29: the
   first three are built; the fourth is held for the resolver, §A7.)*
6. MusicBrainz refuses search results past 500. *(Corrected 2026-09-29: that limits only a PAGED
   search. A by-id query is one page of at most 100, so stage 2 never reaches it, Elvis and Miles
   Davis included.)*
7. **Five places still behave differently on the public API than on a mirror.** All five *skip*
   work rather than pace it. Section B lists them and what each costs a public user. *(2026-09-30: all
   five removed in stage 3, 0.56.3, checked live on 0.56.4; §B.)*
8. The two search types (a row from **Artists** vs a row from **our search**) are identical on a
   mirror and **not** identical on the public API — one of the five gates is the cause. *(Identical
   everywhere since 0.56.3.)*
9. The Community API can replace the spine in one call (no fixed gap; one request at a time), but it **cannot** replace
   name→artist, band members, collaborations, release links, or groups where the artist is not
   the first credit. Section C is the full map with the MusicBrainz source for each.
10. The two requests already sent to Herger still stand. Request 2 (release titles) is no longer
    needed to save MusicBrainz calls — the search gives us those titles — but it is still needed
    for the hosted route to stand on its own. Section D.

**Tests: 45 suites, 1,356 assertions, all green. `syntax_check.sh` clean.** Section G.

**Relation to what is already written down.** Section B is not a new discovery: the two main
gates are already logged as OPEN in `CLAUDE.md`'s top section ("Known violations, OPEN, found
2026-09-25") and the three speculative ones in `docs/community-api-and-resolver-plan.md` §4.
This report confirms them against the current tree and adds what each costs. The spine page caps
are recorded as a **known limit, not a finding** (same plan, §0); A5 notes only that the new
route happens to remove one. **A1 is new**: the release-group search is not in the 2026-07-21
"Dead ends" list, which concluded that "the separate release browse is the only route" — a
conclusion reached from the *browse* forms alone, and superseded here.

---

## A. Making the public API cheaper

### A1. The big one — one search replaces both heavy browses

**What we do today, per cold artist page:**

| call | route | pages |
|---|---|---|
| `getReleaseGroups` | `release-group?artist=<mbid>&inc=aliases` | 1–6 (hard cap 6 = 600 groups) |
| `warmOfficial` | `release?artist=<mbid>&inc=release-groups` | 1–40 |

**What the search gives instead**, in one route:

```
release-group?query=arid:<mbid>&limit=100&offset=<n>&fmt=json
```

Measured shape of each entry (The Beatles, today):

| field | present | feeds |
|---|---|---|
| `id`, `title` | yes | the spine |
| `primary-type`, `secondary-types` | yes | `_groupOf` / sections |
| `first-release-date` | yes | year label + chronological sort |
| `releases[]` → `id`, `title`, `status` | **yes** | `peekOfficial` (`o`), `peekReleaseMap` (`r`), `peekEditions` (`t`) |
| `artist-credit[].artist.aliases` | yes | the artist alias list, free |
| release-group `aliases` | **no** | — see A2 |

**Proof the release list is complete and unfiltered.** I ran the same artist with and without
`AND status:official` and compared the `releases` sub-list of every group present in both: **0 of
33 differed**, and both carried `Bootleg`, `Promotion` and null statuses. Per group, `count`
equalled the length of `releases` in every case, including a group with **151** releases (Dark
Side of the Moon). So the sub-list is not capped and not filtered by the query.

**Proof the coverage matches the browse.** `arid:` returns exactly the same set as
`release-group?artist=`: The Beatles 1050 = 1050, Willie Nelson 489 = 489, Kraftwerk 167 = 167.
Second-credited groups are included.

> **Wrong, 2026-09-29 (§A11).** Those are the COUNTS. Paged 100 at a time, the pages overlap:
> Kraftwerk's 2 pages hold 162 distinct groups of 167, the same five lost on 3 runs of 3, five others
> returned twice. So the search cannot build the spine or its bootleg map by paging. Asked for the page's
> groups by id (`rgid:A OR rgid:B …`, one page per 100 ids) it returned every group asked for, for four
> artists, with complete release lists. That is how stage 2 uses it.

*(A paragraph on guarding a mirror whose search index is unbuilt was here. Dropped 2026-09-29: no user
runs a mirror, so nothing is built for one.)*

### A2. The one thing the search does not carry

Release-group **aliases** are absent from search results (checked every group on a full page: 0
carried one). They are only on the browse, where `inc=aliases` is free.

They matter for **8% of groups** (13 of Kraftwerk's 167), and they are exactly the cases we care
about: *Radio‐Aktivität* → "Radio-Activity", *Computerwelt* → "Computer World", *Electric Cafe* →
"Techno Pop".

**So:** run the search on the render path, and keep the existing `inc=aliases` browse in the
**background** off the render path, until Herger's agreed alias field ships. A foreign-titled
album matches one visit later instead of never.

> **Withdrawn 2026-09-29 (§A11).** "Only on the browse" was wrong: the artist lookup
> (`artist/<id>?inc=aliases+release-groups`) carries them for an artist with fewer than 25 groups, and the
> release browse carries them too, once per release. The recommendation was wrong as well. The browse is the
> spine and stays on the render path, so its aliases cost nothing; demoting it would have made every
> foreign-titled album match a visit late to save nothing. Aliases can leave MusicBrainz only when the
> community API carries them (request 1, agreed, not there on 2026-09-29) AND second-credited groups have
> another source (§F.4).

### A3. The 500-result cap (the limit that decides the design)

> **Superseded 2026-09-29 (§A11).** The cap limits a PAGED search, and paging loses groups anyway. The
> by-id query stage 2 uses is one page of at most 100, so it never reaches 500. Kept for the record.

MusicBrainz refuses a search past 500 results:

```
offset=400&limit=100  ->  200 OK
offset=450&limit=100  ->  400 "Must retrieve at most 500 search results, not 550."
```

The **browse** has no such cap. So the rule has to be:

```
1. GET release-group?query=arid:<id>&limit=100&offset=0
   -> read `count`
2. count <= 500 : page that same query to the end. Complete, exact, nothing lost.
                  (page 1 is already in hand, so cost = ceil(count/100))
3. count >  500 : run  arid:<id> AND status:official        (pages)
                + run  arid:<id> AND -status:[* TO *]       (1 page, usually)
                 -> if EITHER exceeds 500, fall back to today's two browses
```

Why the second query exists: `_isOfficial` treats a **missing** status as official, so a group
whose releases all have no status is shown today. `status:official` alone would hide it.
`-status:[* TO *]` finds exactly those (The Beatles: 28 of them, e.g. "Beatles No. 5").
`(status:official OR -status:[* TO *])` as one query returns **0** — a bare negative clause inside
an OR does not work in Lucene. It has to be two queries.

**One residual difference, measured, not guessed.** A group with a mix of *null* and *Bootleg*
releases and no Official one is shown today and would be hidden by the pair. Kraftwerk has
exactly **two**: "Tribal Gathering" and "Die Broadcast Sammlung" — both bootleg broadcasts. So the
loss is real but it is noise. It only applies to artists over the 500 cap; under it, step 2 is
exact.

### A4. Per-artist cost, measured today

| artist | groups | releases | search: all / official / null-status |
|---|---|---|---|
| Sonic Boom | 29 | 44 | 29 / 28 / 0 |
| Jamie Cullum | 35 | 146 | 35 / 28 / 1 |
| Kraftwerk | 167 | 553 | 167 / 60 / 1 |
| Frank Zappa | 417 | 1011 | 417 / 222 / 1 |
| Radiohead | 585 | 1149 | 585 / 101 / 5 |
| Miles Davis | 799 | 1972 | 799 / 665 / 52 |
| The Beatles | 1050 | 3302 | 1050 / 330 / 28 |
| Elvis Presley | 1343 | 2096 | 1343 / 1129 / 73 |

**Requests for the spine + bootleg filter:**

> **The "with the search" column is superseded (2026-09-29):** it assumed a complete paged search.
> The by-id costs are in §A11. The "today" column still holds (§A10 re-measured Kraftwerk's 8 live).

| artist | today | with the search | at 1.1s spacing |
|---|---|---|---|
| Sonic Boom | 2 | **1** | 2.2s → 1.1s |
| Jamie Cullum | 3 | **1** | 3.3s → 1.1s |
| Kraftwerk | 8 | **2** | 8.8s → 2.2s |
| Frank Zappa | 16 | **5** | 17.6s → 5.5s |
| Radiohead | 18 | **4** | 19.8s → 4.4s |
| The Beatles | 40 | **6** | 44s → 6.6s |
| Miles Davis | 26 | 26 (over the cap) | unchanged |
| Elvis Presley | 27 | 27 (over the cap) | unchanged |

Splitting an over-cap artist by primary type does **not** rescue it: Elvis official Albums alone =
900, Miles official Albums = 535. Both still over. Measured, so don't re-try it.

### A5. It also removes a spine cap (a known limit, not a defect)

> **Wrong, 2026-09-29.** The by-id search needs the group ids, which come from the browse, and the browse
> keeps its 600-group cap. Nothing in stage 2 changes the cap.

The page caps are logged as a known limit, not a finding. Noting it only because this route
happens to remove one for free. `RG_MAX_PAGES = 6` caps the spine at 600 groups; The Beatles
have 1050, so **450 groups are never fetched**. The search route returns the official set
complete (330 + 28), so the page becomes *more* complete while costing less.

### A6. Bytes go up, requests go down — and that is the right trade

| page | size | JSON::XS parse |
|---|---|---|
| search page, 100 groups with releases | 954 KB | **4.7 ms** |
| today's release browse page, 100 releases | 97 KB | 0.5 ms |
| Community API, whole Beatles discography | 383 KB | 1.8 ms |

The Beatles move ~3.6 MB either way. What changes is 40 round trips → 6. Parsing is not a
concern: LMS ships `JSON::XS`, and the biggest page costs under 5 ms.

*(2026-09-29: the by-id query has the same shape as the search page above: 100 Kraftwerk groups came to
190 KB, and 100 Beatles groups are ~950 KB. So the Beatles' bytes are unchanged and the round trips go
from 34 to 6, not to 6 overall; §A11.)*

### A7. Four smaller savings

| # | today | change | saves |
|---|---|---|---|
| 1 | `warmArtistAliases` = `artist/<id>?inc=aliases`, `warmBandMembers` = `artist/<id>?inc=artist-rels` — two calls to the same resource | `artist/<id>?inc=aliases+artist-rels` — **verified 200, 19,956 B, both `aliases` and `relations` present** | 1 request per cold page where the name is ambiguous |
| 2 | `warmLocalReleases` = one `release/<id>?inc=release-groups` per owned tagged album, serial | one batched `release?query=reid:A OR reid:B OR …` — **verified: 50 ids in one request, 50/50 resolved, 62 KB, `release-group` present on every hit** | N → ceil(N/50). A library with 20 owned albums by one artist: 20 requests → 1 |
| 3 | `_vetCollabs` = `artist/<id>?inc=artist-rels` **plus** `release-group?artist=<id>&limit=1` per candidate | `artist/<id>?inc=artist-rels+release-groups` — **verified 200, returns both relations and up to 25 groups**, which answers "has any releases?" | up to 8 requests per artist |
| 4 | `_artistMbidByName` cascade: `artist:"X"` → `alias:"X"` → unquoted → credit head | one combined `artist:"X" OR alias:"X"` | 1–2 requests on every name that needs the alias or unquoted pass |

Evidence for #4, measured today:

| query | top hits |
|---|---|
| `artist:"Hall And Oates"` | HmfO: A Hall and Oates Tribute (100) — **wrong** |
| `alias:"Hall And Oates"` | Daryl Hall & John Oates (100) |
| `artist:"Hall And Oates" OR alias:"Hall And Oates"` | **Daryl Hall & John Oates (100)**, tribute acts 74/66 |
| `artist:"janes addiction"` | 0 results |
| `artist:"janes addiction" OR alias:"janes addiction"` | **Jane's Addiction (100), count 1** — the unquoted pass is not needed either |
| `artist:"Radiohead" OR alias:"Radiohead"` | Radiohead (100) — unchanged |
| `artist:"Bush" OR alias:"Bush"` | Kate Bush (100), Bush (98) — same hazard as today, and the existing exact-name preference already handles it |

This one changes scoring, so it needs the exact-name preference and the ≥90 gate re-pinned in
`t_thelas` / `t_fuzzy` before it goes in.

**Status 2026-09-29.** #1–#3 are implemented (committed on `dev`, not built). **#4 is HELD for the resolver
work**, because re-scoring changes the ANSWER, not only the scores. Measured on the public API, the mirror
identical:

| query | top hits |
|---|---|
| `artist:"HAIM"` (today) | **HAIM** (US pop-rock trio) 100, Haim Saban 89, Emmanuelle Haïm 83, Haïm 78 |
| `artist:"HAIM" OR alias:"HAIM"` (#4) | Haim Saban 100, **Haïm** (Raï pop act) 93, Este Haim 87, Danielle Haim 84, HAIM 84 |

The exact-name preference takes the first name-equal hit scoring ≥ 90, so with #4 "HAIM" opens Haïm's page,
and the answer is cached for 30 days. The resolver plan keeps `_artistMbidByName` exactly as today
(`docs/unified-artist-resolver-plan.md` §2.2), and its one new rule was measured at 0 changes over the
1,117 library artists. #4 therefore moves into its Part C (`docs/community-api-and-resolver-plan.md`), to be
measured there against the same artists. Its saving is small either way: 1–2 requests, only for a name the
name field cannot answer, once per 30 days.

### A8. What cannot be batched — measured, do not re-derive

- **Release-group counts for several artists in one query.** `arid:A OR arid:B OR …` with 8
  artists, `limit=100`: only **3 of 8** appeared in the returned page (Kraftwerk, Sonic Boom,
  Jamie Cullum — the small ones). The Beatles, Radiohead, Zappa, Willie Nelson and Miles Davis
  were all scored out. A presence test on a batched query is unsound.
- **Several artist names in one query.** `artist:"A" OR artist:"B" …` with 8 names: 159 hits, 100
  returned, "Genesis" flooded the list, and British Sea Power, Hall and Oates and Shostakovich
  never appeared. Name lookups stay one per name.

### A9. New cold-page budget, public API, The Beatles

> **Superseded 2026-09-29 by §A11's table** (the "after" column assumed the paged search).

| stage | today | after |
|---|---|---|
| same-name candidates | 1 | 1 |
| spine + bootleg filter | 40 | **6** |
| owned-album release lookups (say 8 tagged albums) | 8 | **1** |
| band members + aliases (ambiguous name; 1 → 1 otherwise) | 2 | **1** |
| **render path total** | **51 (~56s)** | **9 (~10s)** |
| collaborations, after render | up to 16 | up to 8 |

The `official_wait` deadline is 15s. Today it **always** fires for a big artist, so the user waits
15 seconds *and still sees bootlegs*. At 10s the page renders filtered and complete instead.

### A10. Stage 1 measured live (0.56.1, 2026-09-29, public API)

`mb_base_url` = `https://musicbrainz.org/ws/2/`; every request 1.1 s apart; URLs read from LMS's own
`network.asynchttp` log at DEBUG (the plugin does not log its URLs). Both artists cleared cold first.

| cold page | requests, in order | total | before stage 1 | render |
|---|---|---|---|---|
| Kraftwerk (6 owned) | name search ×2, release-group browse ×2, **`reid:` ×1**, **artist read ×1**, release browse ×6 | 12 | 17 | 12.4 s, bootleg map complete |
| Brian Eno (2 owned) | name search ×2, release-group browse ×2, **`reid:` ×1**, **artist read ×1**, release browse ×6; then **vetting ×3** | 12 + 3 | 13 + 6 | 12.5 s |

"Before" is the same page's count with the pre-stage-1 code: one lookup per owned album, and two requests
per vetted collaboration. Neither name is ambiguous, so the artist read was one request before too (the
alias half was not fetched). The spine + bootleg filter is 2 + 6 = **8 for Kraftwerk, exactly §A4's figure**,
so §A4's baseline for stage 2 still holds. Same answers as the mirror: Fripp & Eno and Harmonia 76 kept,
N.M.L. dropped; Kraftwerk 169 groups, 106 bootleg-only.

**Found in the live run: the name is searched TWICE on every cold name-entered page.**
`_artistMbidByName` sends `artist?query=artist:"X"&limit=8`, and `getArtistCandidates` sends the SAME quoted
query with `limit=15` 1.1 s later (both runs above, and every earlier cold page). One `limit=15` answer could
serve both, saving one request (1.1 s on the render path) per cold page, if the first 8 hits of the
`limit=15` reply are always the `limit=8` reply, which is what the exact-name pick reads. **Measure that
across the 1,117 library artists before building it** (the §A7 #4 lesson: a change that re-orders the hits
changes the answer). The resolver plan (`docs/unified-artist-resolver-plan.md` §1) already makes the link path
read `getArtistCandidates` as its name tier, so this saving can come with that work rather than on its own.

### A11. Stage 2 re-measured (2026-09-29, public API): paging loses groups, asking by id does not

Measured on `https://musicbrainz.org/ws/2/`, one request at a time, 1.15 s apart, and compared **by group
id**, not by count (§A1's mistake). The scripts are not kept; the results are.

**1. Paging the search loses groups.**

| query | `count` | pages | distinct groups returned |
|---|---|---|---|
| `arid:<Kraftwerk>` | 167 | 2 | **162**, on 3 runs of 3: the same 5 lost each run, 5 others returned twice |
| `arid:<The Beatles> AND status:official` (the resolver plan's route) | 330 | 4 | **257**: 73 returned twice |
| `arid:<Radiohead> AND status:official` | 101 | 2 | 101 |

Each of Kraftwerk's lost groups matches on its own (`arid:X AND rgid:Y` counts 1), so the index has them and the
paging drops them. Every hit scores 100, so nothing keeps the order stable from one page to the next.

**2. Asked by id, it is exact.** `release-group?query=rgid:A OR rgid:B …&limit=<n>` for the groups on today's
page (the browse, at most 600), 100 ids per request, against today's release browse over the same groups:

| artist | page groups | requests by id (release browse today) | returned | bootleg map | release map | edition titles |
|---|---|---|---|---|---|---|
| Jamie Cullum | 35 | 1 (2) | 35 of 35 | 1 differs | 146 (145 today) | same |
| Kraftwerk | 167 | 2 (6) | 167 of 167 | same | 550 = 550 | same |
| Radiohead | 585 | 6 (12) | 585 of 585 | same | 1149 (1148) | 1 extra |
| The Beatles | 600 of 1050 | 6 (34) | 600 of 600 | 2 differ, both skipped (below) | 2789 (2787), 2 disagree | 2 extra |

Every group's release list was complete (`count` = releases listed), up to Dark Side of the Moon's 151
(Nevermind 98, Abbey Road 73 too). What each difference is:

- **Jamie Cullum, "Jamie Cullum, Volume One": shown today, hidden by id.** Its only release is a Promotion
  credited to Various Artists. The artist's release browse never sees it, so today the group fails open; the
  group's own release list shows it has no official release. The new answer is the right one.
- **The Beatles, "Last Night in Hamburg" and "Beatles in Tokyo":** the search lists them with NO releases.
  Today they are absent from the map and shown. Stage 2 skips a group with no releases listed, so they stay
  shown: no difference once built.
- **The Beatles, 2 releases:** the search still files them under "Strawberry Fields Forever / Penny Lane"; the
  database has moved them to "Strawberry Fields Forever". Index lag, healed by MusicBrainz's own indexing. An
  owned copy tagged with one of those two releases would sit on the older single's tile until then.
- **The extra edition titles** (Radiohead 1, The Beatles 2) are each the group's own title, which
  `Browse::_editionTitles` drops. No effect.
- **The extra release in the release map** (Jamie Cullum's promo; one for Radiohead): a release credited to
  another artist. The map now holds every release of every page group.

100 ids make a 5,160-character URL with `-` left raw (5,960 encoded), HTTP 200 both ways, ~190 KB for 100
Kraftwerk groups.

**3. Where release-group aliases can come from** (Kraftwerk's Radio‐Aktivität, alias "Radio-Activity"):

| route | group aliases? | cost |
|---|---|---|
| the release-group browse, `inc=aliases` (today's spine) | yes | free: the spine request itself |
| the search, by artist or by id, with or without `inc=aliases` | **no**, the artist's aliases only | — |
| the artist lookup, `inc=release-groups+aliases` | yes, for the groups it lists (at most 25) | free: the artist read the page already makes |
| the release browse, `inc=release-groups+aliases` | yes, repeated once per release | ~3x the release browse's pages |
| one `release-group/<id>?inc=aliases` per group | yes | 13 requests for Kraftwerk, 45 for Radiohead |
| the search field `alias:*` | counts the aliased groups (13), returns no text | — |
| the community API `/discography` | **no**: request 1, agreed, not there on 2026-09-29 | — |

**4. The artist read carries a small artist's whole spine.** `artist/<id>?inc=aliases+artist-rels+release-groups`
lists up to 25 groups with their aliases, and no count. For library artists under 25 groups the list was the
browse's exactly: the same groups with the same title, type, secondary types, date and aliases (10 of 10), in the
same ORDER once sorted by group id (9 of 9; unsorted 0 of 8, because the lookup orders by type then date and a
one-page browse by group id). At exactly 25 it may be cut short (Califone has 25; Kings of Convenience 26, Orange
Juice 36 and The xx 47 also list 25), so the browse runs. The extra list costs bytes only: Radiohead 19,956 →
29,704 B, Bonny Light Horseman 2,028 → 4,473 B.

**5. A cold page in requests.** One name search per page; the double name search of §A10 adds 1 to both
columns. "Today" assumes the artist has tagged owned albums (one `reid:` search); without them it is 1 less.

| artist | today (0.56.1) | stage 2 | what goes from the render path |
|---|---|---|---|
| under 25 groups (Bonny Light Horseman, 9) | 5: name, browse 1, `reid:` 1, artist read, release browse 1 | **3**: name, artist read, by id 1 | the browse (the read carries it), the release browse, the `reid:` search |
| Jamie Cullum (35) | 6: name, browse 1, `reid:`, read, release browse 2 | **4**: name, read, browse 1, by id 1 | the release browse, the `reid:` search |
| Kraftwerk (167) | 11: name, browse 2, `reid:`, read, release browse 6 | **6**: name, read, browse 2, by id 2 | the same |
| Radiohead (585) | 21: name, browse 6, `reid:`, read, release browse 12 | **14**: name, read, browse 6, by id 6 | the same |
| The Beatles (600 of 1050) | 43: name, browse 6, `reid:`, read, release browse 34 | **14**: name, read, browse 6, by id 6 | the same |

The bootleg check is at most 6 requests, about 7 s on the public API, inside the 15 s `official_wait` for every
artist. Today The Beatles' 34 pages cannot finish in time, so their first page shows bootlegs.

The `reid:` search leaves the render path because the by-id check maps every release of every page group, owned
ones included. `warmLocalReleases` still runs AFTER the render, for owned albums the check did not place
(normally none) or for all of them when the check failed, and the next visit uses its answers (Simon,
2026-09-29: *"if we need next visit to get what we need lets look to use it but implement as efficiently as
possible"*).

**6. What does not change:** the bootleg rule (a group is official if any release is; a status-less release is
official; a group never classified is shown), the per-visit snapshot, the `official_wait` deadline, the one serial
MusicBrainz queue, the browse for artists with 25 or more groups, and its 600-group cap.

### A12. Stage 3 measured (2026-09-30, public API): the gates cannot simply be removed; how to pay for it

**Status: BUILT** (steps 1-3 as 0.56.3; step 4 is the live check on 0.56.4, §9). The cost of the rows no shared
search answers then moved to the community API (§A13, 0.56.5). *Was: PROPOSAL, not decided, nothing built.*
Measured because §F.3's premise ("only once 1 and 2 have made the
work affordable") was never checked for the search list. Stages 1 and 2 removed requests from the artist PAGE and
none from the search.

**Method.** A scratch harness loaded the plugin's REAL `API.pm` and `Sources.pm` with LMS stubbed, and sent every
request to the public API through the plugin's own queue (`_netGet`: one in flight, 1.1 s after the previous send)
with the plugin's User-Agent. "Gates removed" was done in the harness only: `mbGap` patched to 0 and the
`speculative` flag dropped, so the row check ran every pass a page lookup runs. The scripts are not kept; the
results are. Samples:
- 28 real searches from the September soak (`sweep/baseline-0.55.0`, library artists' own names), stratified by
  result size (6 with 1 row, 7 with 2-5, 7 with 6-10, 8 with 11+): 149 distinct row names. The soak kept the rows
  that survived its filter, so row counts are a floor.
- 7 generic searches (Genesis, Madness, Bush, Air, The Bees, Hall and Oates, British Sea Power). Rows from
  Deezer's public artist search, passed through the plugin's own `mergeArtistHits`. Qobuz and Tidal need the rig,
  which was not reachable.
- 102 names (90 random library artists and 12 field names), each asked at limit 8, 15, 100, then 8 again.
- 204 community-API requests for the rows' and the same-name acts' mbids, one in flight, `X-LMS-Plugin-ID` sent.

**1. Removing the gates as they stand**, first search, median (worst in brackets):

| rows | today, public API | gates removed as they stand |
|---|---|---|
| 1 | 2 requests, 2.2 s (3.3) | 3 requests, 3.3 s (4.4) |
| 2-5 | 2, 2.2 s (3.3) | 6, 6.6 s (11.1) |
| 6-10 | 6, 6.6 s (13.3) | 19, 21.1 s (26.7) |
| 11+ | 4, 5.0 s (10.1) | 26, 28.3 s (33.2) |

A repeat search costs nothing (names are cached 30 days, counts 14).

**2. What that cost is made of.**
- The typed query is asked TWICE with the same question: `artist:"q"` at limit 8 (the resolver, for gate #2) and
  at limit 15 (the same-name set). A page opened by name pays the same pair (§A10).
- Each row costs its own name search plus one release count. Measured row by row, cold: 128 of 170 rows cost one
  request, 25 cost none (named like the query, already asked), 17 cost 2-6. Eight of those were joint credits that
  needed the whole alias, unquoted and joint-credit cascade.
- Junk credit strings are the worst case. For "Hall and Oates" Deezer returns ten entities such as "Andy Robinson,
  Hall And Oates" and "Tim Moore, Hall And Oates". Resolving them costs 46 requests, and 6 of the 11 rows lead
  nowhere.

**3. Measured building blocks.**

a. *MusicBrainz's result order does not depend on the page size.* The same request twice gave the same order for
102 of 102 names. The resolver's pick (read from the first 8) was the same at 8, 15 and 100 for 102 of 102: where
the first eight differed (2 names), only tied lower entries swapped (The La’s at position 8; Julie Byrne's two
90s). The same-name set in the first 15 positions was identical at 15 and 100 for 102 of 102. So ONE
`artist:"name"` request can serve both the resolver's first pass and the same-name set. (Common names have far
more same-name acts than the first 15 positions show, Rico 39, Spirit 27, Air 24, Genesis 19; the section has only
ever listed those in the first 15, and that stays.)

b. *The typed query's own search answers most rows.* Rule: a row whose exact name belongs to exactly one artist in
the query's 100 results takes that artist; the row named like the query takes the resolver's own pick. Soak: 85 of
149 rows answered, all 85 identical to the real resolver. Generic: 14 answered, all identical.

c. *One combined search answers most of the rest.* Rule: `artist:"A" OR artist:"B" …` for the rows (b) left,
trusted only when MusicBrainz reports the reply complete (`count` no more than it returned) and exactly one artist
has the row's name. Soak: 20 of 20 replies complete; 39 of the 64 remaining rows answered, all identical (on their
own they cost 40 requests). Generic: 9 answered, all identical. What remains: joint credits, names several artists
share (Bushido), alias-only names.

d. *Community-API counts* (`/music/artist/<name>/discography?mbid=`). First request median 0.39 s, p90 1.15 s, max
2.77 s (big discographies: Queen 2.8 s, Louis Armstrong 2.7 s); once Cloudflare holds it, 0.10 s. "Has releases"
agreed with MusicBrainz for 141 of 145. The other four returned 0 and are all credited only second (the API lists
first credits only, §C2). **Corrected the same day (§7):** this entry first read 139 of 145 with "two mbids the API
did not know"; those two (Le Concert Spirituel, Spiritual Cramp) were HTTP 429 refusals, not answers, and re-asked
slowly both echoed their mbid and agreed (2 and 11 groups). The 3.06 s "max" was one of them. Obscure same-name
acts are often missing: 5 of Genesis's 9 went to MusicBrainz. LBF and MAI send to this service one request at a
time; that precedent is kept.

**4. The proposed route, modelled from those measured parts.** The two queues run side by side, so time = the
larger of (MusicBrainz requests x 1.1 s + one community round trip) and (1.1 s + the community round trips):

| rows | today | gates removed as they stand | proposed route | the same, 3 community requests in flight |
|---|---|---|---|---|
| 1 | 2.2 s | 3.3 s | 1.7 s (1 MB request) | 1.5 s |
| 2-5 | 2.2 s | 6.6 s | 3.7 s (3) | 3.7 s |
| 6-10 | 6.6 s | 21.1 s | 8.1 s (7) | 8.1 s |
| 11+ | 5.0 s | 28.3 s | 8.5 s (6) | 6.4 s |

Generic searches, today → proposed route: Genesis 10.2 → 7.0 s, Madness 10.1 → 8.1 s, The Bees 11.2 → 10.3 s,
British Sea Power 1.3 → 2.6 s, Air 5.7 → 8.4 s, Bush 4.6 → 11.7 s (twelve counts, mostly big names, 10.6 s of
community round trips), Hall and Oates 1.8 → about 53 s (removing the gates as they stand costs the same). This is
a model built from measured parts, not an end-to-end run; step 4 below measures the build.

**5. Where it is still slower than today:** searches whose rows are big names (a first community count for a big
discography takes 1-3 s, one at a time), and searches whose rows are credit strings (every resolver pass, 4-5
requests each).

**6. Proposed steps** (each: suites before and after, then measured on the public API):

1. **One name search per name** (§A10). A shared `artist:"name"` request, one per name however many callers ask
   at once, read by `_artistMbidByName`'s first pass (positions 1-8, its rule unchanged) and `getArtistCandidates`
   (name-equal in positions 1-15, unchanged). It saves one request (1.1 s) on every cold page opened by name without
   a library tag, and on every search once gate #2 runs. Before building: the order test over all 1,117 library
   artists, as §A10 asked. **Done and BUILT 2026-09-30 (§8): 15 entries for a page AND a search, identical on
   every artist; the set reads only a reply fetched at 15; the row check asks 100 only for a result bigger than
   15** (the "100 for a search" first proposed here would have changed the same-name set for 29 artists).
2. **Release counts from the community API** (the first piece of stage 4). A hosted bucket in `_netGet` at the
   fleet's OWN rate, set from how MAI uses the service (the dev publishes none; LBF ledger A2 `ONE MUSICBRAINZ
   QUEUE, ONE COMMUNITY-API QUEUE`): one request in flight, no fixed gap, a shared 429 deadline 5 s doubling to 30.
   Every call registers the plugin with the mandatory `X-LMS-Plugin-ID` header (`apiHeaders`, guarded). A 4 s
   timeout, and a backoff after timeouts too, so a slow service cannot add 4 s to every count. **A 429 is NOT
   waited out on a search** (§7): the count goes to MusicBrainz at once (today's cost, 1.1 s) and, while the
   deadline stands, later counts are not sent to the service at all; a 429 is never cached as a zero. Ledger A2
   `THE COMMUNITY API IS ONE REQUEST AT A TIME, MAI'S RATE` has the full rule. `warmCandidateCounts` asks it first: a count above
   zero for the mbid sent is used; zero, a different mbid, a 429, an error or a timeout asks MusicBrainz as today. Used by the
   same-name counts (today's public cost), the resolver's zero-release check and the row check. Every reader of
   `dsc:rgcount` only asks zero or not, so storing the API's first-credit count is safe (3d).
3. **Remove the gates.** #1 (the row check) and #2 (the second service search) run on the public API, and a row
   lookup runs every pass a page lookup runs: #3-#5 and the unquoted pass, which rows also skip on every setup today
   (a sixth divergence of the same kind, missing from §B). The `speculative` flag keeps only its mirror-retry role.
   The row check resolves rows in three passes: the typed query's search (3b), one combined search for the rest
   (3c), the real resolver for what is left. Answers from the two searches decide the list only and are not
   written to the shared name cache; a row opened from the list resolves itself exactly as today. *(Changed by
   0.56.5, §A13: the community API takes what is left, and an answer the searches PROVE is written for the page.)* Suites:
   `t_zerorg` §5 flips; `t_fold` reaches the filter on the public API; new suites on captured replies (both rules,
   a complete and an incomplete combined reply, the hosted helper's header, echo, zero and timeout paths).
4. **Measure the build on the rig, public API**: the 28 sampled searches and the 7 generic ones with the real
   Qobuz/Tidal/Deezer rows; the field cases (Genesis's dead ends and Tommy Genesis, British Sea Power's Qobuz row,
   Hall and Oates, The Bees, Madness); and the four stage-2 pages (Kraftwerk, The Beatles, Brian Eno, Ladyhawke),
   to confirm stage 2's gains are intact.

Steps 1 and 2 change no answers and make pages and today's searches faster; step 3 is the behaviour change.

**Decisions for Simon (D1 settled by measurement, §7; D2 and D3 open):**
- ~~**D1, community requests in flight:** 1 (the MAI and LBF precedent) or 3 (11+ row searches 8.5 → 6.4 s; Bush
  about 12 → 9 s).~~ **Settled: 1.** It is the fleet's own rate for this service, set from how MAI uses it
  (Simon, 2026-09-30; ledger A2 `THE COMMUNITY API IS ONE REQUEST AT A TIME, MAI'S RATE`), and §7's measurement
  agrees: one request at a time with no gap already draws 429s after about 57 requests, so three at a time would
  reach that sooner. The table's "3 in flight" column is out.
- **D2, searches like Hall and Oates:** no cap (the list is always right; such a first search can take close to a
  minute on the public API) or a time cap (rows not checked in time are shown and checked in the background: the
  next search is clean, but a dead end can show on the first). Best decided with step 4's real rows; the Deezer-only
  rows here are not the rig's.
- **D3, counts for big names (added 2026-09-30, stage-3 review finding 2; open, held for step 4 by Simon):** as
  built, every count queues for the community API one at a time and MusicBrainz takes only those it could not
  answer, so it mostly sits idle while a big artist's first community count takes 1-3 s (the model's Bush 4.6 ->
  11.7 s and Air 5.7 -> 8.4 s above). Candidate: MusicBrainz takes the next waiting count whenever it is free,
  still one at a time and adding no community traffic. Decide on step 4's live times for Bush- and Air-type
  searches against 0.56.2's.
- **Where D2 and D3 stand (2026-09-30, night): both still open, for Simon.** Since 0.56.5 the junk results go to
  the community API, not the resolver, and the searches D2 was first about are fast (live, first search: Hall and
  Oates 58.6 -> 5.4 s, Pretenders 66.9 -> 5.0 s, Balthazar 46.5 -> 9.0 s). But a big name's first search still takes
  9-13 s, one community request per leftover result (§A15), so D2 still matters. D3 is
  unchanged by 0.56.5-0.56.6 (the counts path is the same); 0.56.4 measured it at a few seconds a search at most
  (§9).

**7. Can the community API do more of this? (Simon, 2026-09-30; measured the same day, public API.)** Only the
counts. It cannot take over the name lookups, which are where the cost is:
- *By name it gives one pick, not a list.* `/music/artist/<name>/aliases` with no mbid, asked for the same sample
  and scored against the real resolver (the plugin's own `_norm` for the name check):

  | | same act | a different act with the same name | different, caught by a name check | no answer |
  |---|---|---|---|---|
  | typed queries (28) | 24 | **4** (pencil, Dark Star, Kingfisher, Roswell) | 0 | 0 |
  | search rows (170) | 143 | **21** | 5 | 1 |

  A same-name pick passes any name check, so nothing can catch it. Which act each side opens, by group count (keyed
  by `?mbid=`, echo checked): pencil 24 vs the API's 3, Dark Star 8 vs 4, Kingfisher 7 vs 1, Au Pair 4 vs 1, Roswell
  2 vs 0. In five of six the API opens the smaller act. The sixth goes the other way (below). This extends ledger
  §A3 `safe drop-in for `_artistMbidByName`` from 22 field names to this sample; the verdict stands.
- *It has no batch route.* One request per name; one combined MusicBrainz search answers up to 100 rows (3c).
- *It does refuse, even at MAI's pace.* One request at a time with no gap: HTTP 429 on 20 of 149 name requests, the
  first after about 57 requests in 16 s, then every 3-5 s; each 429 took 1.1-3.1 s to come back. The count run
  (about 1.4 new requests a second) had 2 of 145, after about 100 s. Paced at one every 2 s: 0 of 19. The dev
  publishes no limit, so the fleet sets its own from how MAI uses the service, and MAI's scanner path is exactly one
  request at a time with a 5-30 s sleep after a 429 (MusicArtistInfo master `Common.pm::call`, read 2026-09-30).
  This measurement shows why that backoff exists; it does not change the rate. Hence step 2's 429 rule and D1
  (ledger A2 `THE COMMUNITY API IS ONE REQUEST AT A TIME, MAI'S RATE`, A3 `COMMUNITY API DOES REFUSE`).

**8. The order test, all 1,117 library artists (2026-09-30, public API; the gate on step 1).** Every album artist's
name was asked as the resolver asks it (`artist:"<name>"`, annotation stripped) at limit 8, 15 and 100, one
request every 1.1 s with the plugin's User-Agent: 3,351 requests in 64 minutes, 0 errors. Then the REAL
resolver and same-name set ran on those replies, the code at HEAD against the new code, every other request
answered identically, so any difference could only come from the page size:

| | resolver (answer and path) | same-name set | name searches |
|---|---|---|---|
| old: resolver at 8, set at 15 | — | — | 2,304 |
| **new: one request at 15 for both (page and search)** | **identical, 1,117 of 1,117** | **identical, 1,117 of 1,117** | **1,187** |
| resolver reading the first 8 of a reply at 100 | identical, 1,117 of 1,117 | — | — |
| set reading the first 15 of a reply at 100 (rejected) | — | differs for 29: 14 equal scores in another order, 12 a score off by one, 2 a different member (Lowlife, Oasis), 1 order and score (Weekend) | — |

And two facts about replies that are the whole result: a reply at 15 is the whole result for 983 names (88%),
and all 983 have exactly the members the reply at 100 has; but 23 of 943 whole results at 8 come back in another
order or with a score off by one at 15 or 100. **So, as built:** pages and searches resolve at 15 and the set
reads that very reply; the set never reads a reply fetched at another limit (`exact`, even a whole one); the row
batch, which reads only who is in the result, uses the reply at 15 when it is the whole result and asks for 100
otherwise (12% of names, one request). The plan's search model (§4) assumed one request at 100 for everything; as
built a search sends one at 15, plus one at 100 for a big result: the same for 88% of names, one more (1.1 s) for
the rest.

**9. Step 4, measured live on the rig (0.56.4, public API, 2026-09-30).** 16 searches (the 7 generic ones,
Pretenders, and two per band of the soak sample) and the four stage-2 pages, through the plugin's CLI on the
MacBook Pro player, with the rig's real rows (Local and Qobuz; Spotify's token is dead, so no search list is ever
cached there). Requests counted from `network.asynchttp` DEBUG, one `GETing` line per request, shed retries
included. State: the first search after the install, which empties `kv` but keeps the name->mbid and artist
tables, so most typed names were known and the rows' names were not. A second run after clearing proved nothing:
`clearcache` cannot reach the dropped rows' cached misses.

| search | first search | MB requests | MB sheds | rows answered by the shared searches |
|---|---|---|---|---|
| Pretenders | 66.9 s | 61 | 9 | 0 of 15 |
| Hall and Oates | 58.6 s | 48 | 8, and one 503 backoff | 0 of 10 |
| Balthazar | 46.5 s | 42 | 6 | 4 of 13 |
| The Specials | 44.4 s | 40 | 3 | 5 of 14 |
| Genesis | 31.0 s | about 27 | not split out | not split out |
| Bush | 25.2 s | 21 | 3 | 5 of 13 |
| Madness | 18.0 s | 13 | 1 | 12 of 13 |
| British Sea Power | 16.9 s | 13 | 3 | 2 of 4 |
| Spirit | 12.9 s | 10 | 2 | 7 of 11 |
| Kokoroko | 10.2 s | 9 | 2 | 0 of 2 |
| The Stooges | 10.2 s | 9 | 0 | 1 of 5 |
| Red Hot Chili Peppers | 9.0 s | 8 | 1 | 0 of 2 |
| The Bees | 7.0 s | 7 | 0 | 4 of 5 |
| Au Pairs | 6.8 s | 6 | 1 | 0 of 2 |
| Queen | 6.3 s | 3 | 0 | 12 of 13 |

- **§4's model was far too low for searches whose rows are the services' junk** (credit strings, "Jazz
  Pretenders"-style names): the soak sample's rows had survived a filter, which §A12 flagged ("row counts are a
  floor"). No shared search answers a junk row, so each pays the resolver's whole cascade (quoted, alias, unquoted,
  sometimes the credit split): 3-5 MB requests at 1.1 s each, plus sheds.
- **MB's search zone shed about 20 requests** in the 13 minutes of this traffic and rate-limited twice; the queue
  retried and backed off as designed.
- **A repeat search within the hour takes 0.3-1.7 s** (Pretenders, The Specials, Hall and Oates, Genesis). A miss is
  cached for an hour (`MBID_EMPTY_TTL`), so a junk-heavy search pays its cascade again after that.
- **The community counts are not what is slow (D3):** busy at most about 10 s a search (Madness, 21 counts one at a
  time, the slowest 1.6 s), with MusicBrainz almost idle meanwhile (1.8 s of overlap); D3 would save a few seconds
  there. The long searches are MusicBrainz time: Hall and Oates spent 42.7 s with an MB request in flight.
- **Every field case is right:** Genesis hides its dead ends (NEON GENESIS EVANGELION (OST), Genesis Scholz,
  Organización Génesis...) and keeps Tommy Genesis, Genesis P-Orridge and Genesis Piano Project; British Sea Power has
  its Qobuz row; Madness and The Bees list their same-name acts, and The Bees' owned split rows read "4 albums / 1
  album / 1 album"; Hall and Oates keeps Daryl Hall & John Oates and drops nine junk credits.
- **Stage 2's pages are intact:** Ladyhawke 3 requests (0.56.2: 4; the shared name search saved one) in 2.5 s
  (3.6 s); Kraftwerk 6 in 7.9 s (6.0 s); Brian Eno the same requests and a shed retry, 7.2 s (7.0 s); The Beatles 598
  of 600 classified with one shed retry, 17.8 s (14.8 s). The extra seconds match the MB load that day.
- 0.56.2 was not re-measured on the rig; the harness's 0.56.2 public medians (§1, "today") were 2-7 s.

**Found on the way, not changed by this plan:**
- **"The Pretenders" opens an obscure act, not the band.** In the "Pretenders" search, the row "The Pretenders"
  resolves to 6cee8afb, an act named exactly that with 1 group (credited second), rather than Pretenders e9c832b0
  (90 groups, alias "The Pretenders"): the exact-name preference beats an alias match, and one group is not zero,
  so the zero-release hold does not fire. A page opened by that name does the same today. Not checked on the rig
  (which service row carries the name, and what it opens).
- A joint-credit search row resolves to its FIRST act (0.47.0), often a different band: "Fools & Pretenders" opens
  a band called Fools, "Bridges and High Places" one called Bridges. It is also the most expensive row to check.
- A merged search row takes the spelling of the first service hit in its `_norm` bucket. With Deezer alone, the
  "Genesis" row reads "Gênesis (O Princípio)": Deezer returns fifteen "Genesis" entities and they fold into one row.
- The queue needs no priority lane: every MusicBrainz chain keeps one request queued at a time, so a new search or
  page waits at most one slot behind a previous page's post-render work. The row check is the one burst (it queues
  its rows at once, in rank order).
- Material requests plugin lists with no timeout (`server.js`: `lmsList` calls `lmsCommand` without one), and
  pages of 23.5 s rendered fine in 0.51.18's live soak. Responses longer than that are unproven.

**10. No MusicBrainz at search, tested (2026-09-30, public API; Simon's proposal; NOT TAKEN: Simon called it "a step
backwards", and §A13 was built instead).** A search row
has only ever sent its page the name and, for an owned act, the library `artist_id` (`Browse::_searchResultRow`),
never an mbid, so a tap already resolves the way an Artists-menu entry does. The proposal is therefore the search
list without the typed-name lookup, the canonical second pass, the row check and the same-name section, with the
page unchanged.

*Method.* Rows: §9's first run, read from its log (every service hit is logged by name and every merged row got a
verdict line); the two searches that ran a second pass were re-merged on their first pass only through the real
`Sources::mergeArtistHits` (scratch harness). Taps: `discography items artist:<name> [artist_id:<id>]` on the
MacBook Pro player after `clearcache` of the name, id and mbid, counted from `network.asynchttp` DEBUG until
MusicBrainz had been quiet for 7 s (after-render work included).

| | today (0.56.4) | no MusicBrainz at search |
|---|---|---|
| the 16 searches | 319 MB + 132 community requests; 6-67 s each on a first search (§9) | none; the list waits only for the services (Qobuz's artist search: 0.6-2.0 s) |
| rows | 99, plus 23 MusicBrainz-only (21 "Other artists with this name", Génesis, Mädness) | 159: 44 open "Couldn't identify this artist on MusicBrainz", 9 "No releases found", 6 repeat an act under another spelling; the 23 are gone |
| a tap on the act searched for (16, cold) | the page's own requests | the same plus 1 name search, the reply today's search already holds: 102 MB requests over the 16 taps (3-12 each), 20 of them name searches (16, 3 shed retries, 1 unquoted retry); 2.4-14.6 s to render |

- **Right act every time:** all 16 taps opened the artist today's check or typed-name lookup chose (6 by name, 10 by
  library tag), with full sections.
- **Renamed acts:** British Sea Power's row comes from the library (Qobuz returns nothing for the old name); its
  page matched all 12 releases to Qobuz under MusicBrainz's name. The row loses its "Qobuz" label, and with Qobuz
  only and the act not owned there would be no row. Hall and Oates on its first pass alone: 7 rows, the band's
  first (Local + Qobuz).
- **A dead-end tap** costs 3-4 MB requests (quoted, alias, unquoted) and shows "Couldn't identify this artist on
  MusicBrainz" with a Retry row; a zero-release act costs 2-6 and shows "No releases found".
- **A row under another spelling opens the right act but a thin page**, because the page asks the services under
  the row's own spelling: "Genesis Mohanraj" -> Tommy Genesis, "No releases found" (Qobuz's entity for that name
  holds 3 TOMMY GENESIS releases and the artist check rejects all three); "Darryl Hall and John Oates" -> the band, 3
  releases where its own page has about 50, though Qobuz returned the band's 101 (the artist check again; "Daryl
  Hall e John Oates" the same); "Iggy Pop & The Stooges" -> fine. Today's row check folds these into
  the canonical row. Without it the page would have to match under MusicBrainz's name when the row's spelling
  is only an alias: the resolver plan's canonical-first service search (§5) covers the search, not the artist check.
- **Every page already fetches the same-name list** (`$warm`'s `getArtistCandidates`: Genesis 9, Madness 9, The
  Bees 10 in these taps), so "Other artists with this name" could move to the artist page with no extra
  MusicBrainz request; the counts that hide the empty ones would be asked there.
- **Found on the way (today's build):** the "Genesis Mohanraj" page recorded Tommy Genesis (6281bbf0) as EMPTY,
  which hides her search row for 7 days: `_browsedAsSelf` accepts an alias. A2 `STAGE 1 CHANGED SIX` #1 says such a
  page asks the services under MusicBrainz's main name before it can come up empty; this one did not. Qobuz's
  entity for the browsed spelling corroborated (its titles are on her spine, `SPINE_STRONG` 2), so
  `_resolveArtist` never tried another name, and the release match then rejected all three on the artist name.
  Cleared on the rig by opening her page (a render with content clears it). With no row check nothing reads the
  verdict.

**11. The community API judging the search results instead (2026-09-30, Simon: "is there no way to use the
Community API instead of MB"; nothing decided).** Every result §9's row check judged (144, from its log) asked
`/music/artist/<name>/discography` BY NAME, one request at a time, one every 2 s, plugin-id header: 144 answers, 0
refusals, 69.8 s of request time in all (MusicBrainz: 319 requests, 370 s, for the same 16 searches). It cannot list
same-name acts (one pick per name), so "Other artists with this name" keeps its one MusicBrainz search per query.
- **As it comes:** the same show/hide as MusicBrainz for 125 of 144; one request both resolves a spelling and
  names the act ("Genesis Mohanraj" -> Tommy Genesis, "Iggy Pop & The Stooges" -> Iggy and The Stooges: 7 of the
  9 results MusicBrainz folded got the same id).
- **Trusted only when its name folds equal to the result's (case, accents, "&"/"and", a leading "the",
  punctuation), else hidden, and hidden on no answer or 0 releases, with NO MusicBrainz request per result:** it
  hides 5 real acts MusicBrainz shows (Genesis P-Orridge -> "Genesse P-Orridge" with 0; Luke Bushell -> another
  Luke Bushell with 0; Mixtape Madness and Balthazar Pouilloux, its list holding only first-credited groups, 0;
  Qobuz's "Daryl Hall & John Oates - The Philly Years", which MusicBrainz relabels Daryl Hall) and 2 junk results
  MusicBrainz keeps (Fools & Pretenders -> a band called Fools; a Christmas compilation credit), and shows 2
  spellings MusicBrainz folds or misses (Sea Power, "Daryl Hall John Oates", both the right act). "The Pretenders"
  gets the band, where MusicBrainz's resolver picks a one-single act (§9 "Found on the way").
- **Checking its 0-release answers with MusicBrainz** (9 of 144: 6 junk, Mixtape Madness, Luke Bushell, Balthazar
  Pouilloux) brings those three back for a MusicBrainz lookup each.

**12. Speed tests of "one MusicBrainz search, kept, then the community API" (2026-09-30, Simon: "with the MB request
let get all we can with that call so we can use the info in the next stage... Need some more speed tests"; nothing
decided, nothing built).** Assembled from measured parts, NOT a run of built code.
- *The one search:* `artist:"<typed>"` at 100 took 0.12-0.32 s (at 15: 0.10-0.32 s), 0-61 KB; one 503 shed (Spirit).
  It is the whole result (count <= 100) for 11 of 16 queries (Genesis 140, Madness 218, Bush 322, Air 628, Queen 806
  are not). An artist in it whose name or alias folds equal to a result's gives that result its MusicBrainz id: 36 of
  the 144 results, the same id as today's check for 34, and for "The Pretenders" the band (e9c832b0, 90 groups) where
  today's check picks a one-single act. The community API then asks BY ID, which brings Genesis P-Orridge back.
- *The rest, by name with §11's name check:* 10 results need a MusicBrainz check (0 releases); after it, the list
  differs from today only by hiding "Fools & Pretenders" and a Christmas credit (today's wrong keeps) and Qobuz's
  "Daryl Hall & John Oates - The Philly Years" (today relabelled Daryl Hall). Spellings of a shown act (Genesis
  Mohanraj, Iggy Pop & The Stooges, Sea Power, Daryl Hall John Oates) carry that act's id and merge into it, as
  today's alias fold does.
- *Community API speed:* uncached one request at a time, median 0.33 s, 90th percentile 1.03 s, max 3.64 s; a
  Cloudflare hit 0.09 s. 0 refusals in 288 requests, the second 144 back to back with no gap (mostly cache hits).
- *Estimated per search* (Qobuz or the MB search, whichever is longer, + the community requests uncached, one at a
  time, + 2.4 s per MusicBrainz check): the 16 searches 370 s -> about 109 s in all (Pretenders 66.9 -> 10.3 s, Hall
  and Oates 58.6 -> 10.6 s, Balthazar 46.5 -> 7.9 s, The Specials 44.4 -> 10.8 s, Genesis 31.0 -> 9.3 s, Madness
  18.0 -> 14.1 s); MusicBrainz requests 319 -> about 36. A repeat within Cloudflare's 30 days: 1-12 s. "Today" is
  §9's first run, partly warm (Air 0.3 s).
- *The tap, on the rig (5 unowned acts, cold, MacBook Pro player):* opened with the id and the same-name list the
  search would store, every page renders the same sections with one MusicBrainz request fewer (no name search) and
  1.2-1.4 s sooner: Genesis Owusu 3.7 -> 2.5 s, Air Supply 3.8 -> 2.4, Spiritbox 3.7 -> 2.4, Sam Bush 2.7 -> 1.4,
  Christine and the Queens 3.6 -> 2.4.

### A13. PLAN — the search's row check asks the community API; its one MusicBrainz search is kept and reused (2026-09-30)

**Status: BUILT as 0.56.5 (Simon: "build it"), INSTALLED and CHECKED LIVE, uncommitted** (CLAUDE.md dev log 0.56.5: the
16 searches' MusicBrainz requests 319 -> 51 on a first search, the list as simulated, every field case right). Part 2
was extended by §A14 (0.56.6). *Was: CODED, suites green (53 / 1,760, 22 mutants killed), zip not yet built.* One rule tightened while coding: a pick under another name merges only when the row's OWN name is
one MusicBrainz records for the artist (alias, canonical, or a joint credit headed by it), not merely the survivor's. Follows
§A12.10-12: no MusicBrainz at search was "a step backwards"; the costly part is not the search's MusicBrainz request
but the per-result resolver cascade (3-5 requests at 1.1 s for each result neither shared search answers).

**What stays exactly as it is:** the typed name's MusicBrainz lookup, sent with the service search; the canonical
second pass (British Sea Power -> Sea Power); passes 1 and 2 of `filterRowsWithContent` (the typed reply, one
combined search); the counts (`warmCandidateCounts`: community API first, MusicBrainz only for a 0 or no answer);
the fold, relabel and library attach; "Other artists with this name"; the owned split and the new merge; the page.

**Part 1 — the rows the two shared searches leave (`API::filterRowsWithContent`, `_rowBatch`):**
1. *Pass 1 also takes an ALIAS:* when no artist in the typed reply is named like the result, the ONE artist that
   carries it as an alias answers it (the reply lists every artist's aliases; nothing extra is asked). Genesis
   P-Orridge is an alias of "Genesis Breyer P-Orridge", which today only the resolver's alias pass finds.
2. *The rest ask the community API BY NAME* (`/music/artist/<name>/discography`, its own queue, one request at a
   time, `failFast`), instead of `getArtistMbid(speculative => 1)`:
   - no artist -> hidden ("Couldn't identify" is what its page would say);
   - its name `_norm`-equal to the result's and releases listed -> kept, with that id and count (the count cached
     as `rgcount`, so nothing asks again);
   - its name equal but 0 releases -> today's resolver and count decide (its list holds only first-credited groups,
     and by name it can pick another act of the name: Luke Bushell, Mixtape Madness);
   - its name different -> used only to MERGE into another kept result with the same id, through today's fold
     (one of the names an MB alias of the other, the one alias request per duplicated act); otherwise hidden;
   - no answer (refused, timeout) -> kept, unchecked (a failed request never hides a result, as for counts).
   Each answer cached per name (found 14 days, unknown 1 day). A2 `THE COMMUNITY API IS ONE REQUEST AT A TIME` holds;
   A3 `safe drop-in for `_artistMbidByName`` is respected: a by-name answer only decides show/hide and merges, and
   is never handed to the page as the artist's identity.
3. *Simulated on the 144 results §9 judged, with these exact rules* (the real MusicBrainz replies for both passes,
   the community answers of §11, MB alias lists for the merges): pass 1 answers 36, pass 2 35, the community 71,
   the resolver 2. The visible list is today's except four results: "The Pretenders" merges into Pretenders (today
   it opens a one-single act), "Fools & Pretenders" and a Christmas compilation credit are hidden (today's wrong
   keeps), and Qobuz's "Daryl Hall & John Oates - The Philly Years" is hidden (today relabelled Daryl Hall).
   MusicBrainz requests for the 16 searches: 319 -> 36.

**Part 2 — hand the page what the search proved (the tap):** when a result's id comes from a reply that holds every
artist of that name (pass 2's complete reply, or a whole typed reply whose words the name contains) and exactly one
artist has the name, write it as the name's resolution (`dsc:mbid`) and its same-name set (one member), as the
typed name's own lookup already does. Only there is it provably the resolver's answer; everything else resolves on
the page as today. Measured: one MusicBrainz request and 1.2-1.4 s less per tap (§12). **Behaviour change:** stage
3's rule "what the two passes decide is used for the LIST only" gives way for these cases; A2 entry and tests.

**Tests:** new suite on captured replies for every branch above (alias pass, each community outcome, a refused
answer, a merge through the fold, a name-differs answer that does not merge), the page-cache write only under its
conditions, and the request count (no resolver for a result the community answers); `t_rowbatch.pl` and
`t_searchflow.pl` updated; mutation-checked. **Live, on the rig, public API:** the 16 searches cold (time, requests,
the four differences above), taps with and without the stored id, and the field cases (Genesis dead ends and Tommy
Genesis, British Sea Power's Qobuz result, Hall and Oates, The Bees, Madness's section, Pretenders).

### A14. BUILT in 0.56.6 (RIDE), CHECKED LIVE — pass 1's unproven answers proved by riding in pass 2 (measured 2026-09-30)

**Why:** 0.56.5 live (dev log): a tap saves its name search only for a PROVEN result, and after a common one-word
search most are not. Pass 1 answers them from the typed reply, but that reply is partial (Genesis 140 matches, Air
628, Queen and Madness over 100) and a partial reply cannot show there is only one artist of the name. Genesis Owusu,
Air Supply and Sam Bush were answered that way, so their taps still searched.

**The change measured:** a result pass 1 answered BY NAME but could not prove (reply partial, or the name lacks the
typed words) joins pass 2's combined `artist:"A" OR ...` search, which is sent anyway. A complete reply proves it only
when exactly one artist has the name and it is pass 1's pick; the pick itself never changes. Alias picks and annotated
names are left out (they cannot be proven that way). Two variants: RIDE (only when pass 2 is sent anyway, 2+ results
unanswered) and ALWAYS (also send pass 2 when only these need it).

**Method:** the plugin's real `_rowBatch` (a scratch copy with the change behind an env switch, `proofsim.pl`, the
stage-3 driver with LMS stubbed) against the public API, on the results each search actually checks, read from the
rig's log: the 16 test searches plus b52s after the 0.56.5 cold run, and 25 generic one-word searches (Love, Heart,
Blue, Black, Fire, Sun, Star, America, Yes, Low, Soul, Eagles, Train, Europe, Boston, Chicago, The Band, Cream,
Journey, Garbage, Muse, Doves, Angel, King, Moon) run on the rig for the purpose.

| | today | with the change |
|---|---|---|
| proven, 17 test searches | 42 of 71 answered | **61** |
| proven, 25 generic searches | 112 of 208 answered | **195** |
| MusicBrainz requests | — | **the same** (every one of the 42 searches already sends pass 2, so RIDE and ALWAYS never differ) |
| picks changed | — | **0** |
| a complete reply made incomplete by the extra names | — | **0** (largest complete reply 50 of the 100 limit, Moon; the extra names added 0-16 matches) |

Star (129) and Angel (135) overflow today already and overflow the same way with the change: nothing proven either
way. **What stays unproven (23 of 279), by rule:** alias picks (Genesis P-Orridge, Genesis Mohanraj, Iggy Pop & The
Stooges) and names MusicBrainz holds for two or more artists (Sam Bush, Crown of Madness, Baby Queen, Queen Bee, Queen
Omega, Sacred Spirit), which the page's own same-name handling decides. A result neither pass answers (the community
API's) is never proven. **Tap cost measured on 0.56.5:** a proven result opens in about 1.3 s with no MusicBrainz name
search, against 2.4-3.5 s.

**Live on 0.56.6 (rig, public API; dev log 0.56.6):** proven 54 of 71 results over 9 searches (Air 7 -> 9 of 10, Queen
4 -> 9 of 13, Madness 4 -> 8 of 10), none lost, the same MusicBrainz requests per search; Genesis Owusu and Air Supply
now open with no name search, 2.3-2.4 s against 3.6-3.7 s opened cold.

### A15. MEASURED — why a big name is still slow on 0.56.6 (2026-09-30 night, rig, public API; nothing built)

**Why:** Simon, after searching Bob Dylan: *"it still feels very slow when the initial search takes 10secs and then
loading the list another 10-15"*. Scratchpad `dylan.py` / `cold2.py`, debug logging on for the runs, then back to WARN
/ ERROR.

**The page (Bob Dylan, owned, library tag, cold): 15.0 s to draw, 0.2 s warm.** It is the MusicBrainz queue and
nothing else: 14 requests, 1.1 s apart, and the page draws when the last is back.

| step | requests | time from the tap |
|---|---|---|
| the artist read (aliases, bands) | 1 | 0 s |
| the release-group browse, 100 a page, capped at 600 of his 1,198 groups (`RG_MAX_PAGES`) | 6 | 1.1-6.6 s |
| the same-name lookup (free when the search just asked it; this run had it cleared) | 1 | 7.7 s |
| the bootleg check by id, 100 a request (§A11) | 6 | 8.8-14.3 s |

Qobuz, the bio and the similar-artists leg ran alongside and held nothing up. **The community API's
`/discography?withReleases=1` for him, one request: 2.9 s uncached, 396 KB, 1,180 groups (MusicBrainz lists 1,198:
the difference is groups credited to him second), with the status of 2,284 releases.** That is the whole list, past
today's 600 cap, and the bootleg map, where the page asks 12 MusicBrainz requests (about 13 s) for 600. What it lacks
is §F.4's open question: groups credited second, release-group aliases and edition titles.

**The search, first time a term is searched: 8.6-12.6 s** (Neil Young 12.6, Johnny Cash 10.4, Leonard Cohen 8.6;
Bob Dylan again with the community answers cached: 2.3 s). Qobuz answers in 0.8 s. The rest is the result check asking
the community API, one request at a time (A2 `THE COMMUNITY API IS ONE REQUEST AT A TIME, MAI'S RATE`), about the
9-14 results the two shared MusicBrainz searches leave: Neil Young 14 requests over 10.7 s, most of them credit strings
and tribute acts that end up hidden (Bob Dylan: 13 asked, 13 hidden, one result shown). A request no one has made
before misses Cloudflare's cache (0.2-3 s each); the answers are cached per name for 14 days, so a second search is
about 2 s.
- **A timeout also lets junk through:** Johnny Cash's "... Ft Mistah FAB, San Quinn, Mac Mall & Various Others" hung
  for the full 4 s, the community queue then backed off, and it and three more ("Johnny Cash & Friends", "Johnny
  Cash/June Carter Cash & Merle Kilgore", "Johnny Cash/The Tennessee Two") were shown unchecked, as designed for a
  failed request.
- **A credit-separator rule would not fix it:** of the results asked by name, those with `;` `/` `,` ` - ` or `feat`
  were 4 of 11 (Neil Young), 6 of 12 (Leonard Cohen) and 2 of 5 (Johnny Cash). The rest are tribute acts,
  run-together names ("Johnny cash Neil young", "Leonard Cohen Leonard Cohen") and real acts ("Neil Young & The
  Bluenotes").

**What would change it:** for the page, §F.4 (the community API's list and status map for the first draw, MusicBrainz
for the rest after it); for the search, D2 (§A12.6: a time cap, results not checked in time shown and checked for the
next search). Neither is decided.

### A16. BUILT as 0.56.7 (route A) — the artist page without its long MusicBrainz wait (§F.4, 2026-10-01; checked live the same day)

**LIVE (2026-10-01, rig, public APIs; full table in CLAUDE.md dev log 0.56.7):** first visits Dylan 2.9 s (0.56.6:
15.0 s), The Beatles 2.7, Johnny Cash 2.7, Bowie 2.9, Willie Nelson 3.2, Eno 3.2, Kraftwerk 2.4, each 2-3 MusicBrainz
requests before the draw against Refresh's (0.56.6's path) 6.8-16.0 s and 6-14; second visits 0.05-0.45 s; a tap
during the completion 0.75 s. As predicted, albums matched only by an edition title or alias come a visit late: 22
over 7 of the 9 artists. Johnny Cash gains a Live albums section of 14 that 0.56.6 never reached. Found: a Refresh,
which takes MusicBrainz's list cut at 600, hid those past-cap groups for 14 days: fixed as 0.56.8 (`_pastCap`: a
Refresh past the cap also asks ListenBrainz and the community API and keeps their groups past it, with the
community's verdicts for those only; CLAUDE.md dev log 0.56.8). **Correction (same day):** most of these community
replies were Cloudflare hits; uncached they take 2.6-3.4 s, so a first visit nobody has primed is about 5-6 s. **And
the 1,500 ceiling is too low:** The Rolling Stones (1,914) and Bruce Springsteen (2,171) take the old path, 14.8 s.
**And the community keeps merged-away ids** (Nirvana 233, listed with no releases), which the first list added
(ledger §A3). 0.56.8 (second round): no ceiling, merged-away ids left out, at most two by-id requests before the
draw with the rest after it, `FAST_TIMEOUT` 12 s, special artists (Various Artists, 106 MB on ListenBrainz) on the
old path (CLAUDE.md dev log 0.56.8, A2 items 6 and 9).

**Why:** §A15. Bob Dylan's cold page is 13 MusicBrainz requests in a row (the artist read, 6 browse pages, 6 by-id
bootleg requests) and draws at 15 s. Simon: *"yes sounds good"* to planning the page first, then D2; then, on route A
being written off for its first-visit gap, *"Dont discount yet"*, which led to the ListenBrainz measurement below.

**Measured (2026-10-01, public APIs; scratchpad `cmpage.py`, `cmpage_cmp.py`, `lbartist.jsonl`):** 49 artists: 12 named
(Dylan, The Beatles, Neil Young, Johnny Cash, Radiohead, Kraftwerk, Brian Eno, David Bowie, Leonard Cohen, Ladyhawke,
Miles Davis, Sonic Boom), Willie Nelson, and 36 library artists drawn at random from the September sweep by size.
Against MusicBrainz's WHOLE browse (not capped at 600) and its by-id check on the first 600 groups, with the plugin's
rules:

| source, one request per artist | what it gives | measured |
|---|---|---|
| **community** `/discography?mbid=&withReleases=1` | groups credited FIRST, with every release's status | uncached median 0.78 s, max 2.95 s; cached 0.05 s; every mbid echoed. **Bootleg verdicts agree on 9,521 of 9,685 groups**: 6 it calls bootleg-only where MusicBrainz finds an official release, 2 the other way, 156 listed with no releases (unclassified). Lacks 399 groups on these pages, 317 of them official: those credited to the artist second (Willie Nelson 62, Duke Ellington 50, Miles Davis 31, Brian Eno 29, Sonic Boom 14). Lacks 903 of 26,244 release ids (3.4%) |
| **ListenBrainz** `/1/metadata/artist/?artist_mbids=&inc=release_group` | every group whatever the credit position, with title, type, secondary types, date; no statuses, no aliases (`aliases` is not an `inc`), no release titles | **11,769 of 11,790 groups** (Dylan 1,194 of 1,198, Willie Nelson 489 of 490, Brian Eno 183 of 183); fields differ on 16 (6 titles, 5 dates, 4 secondary types, 1 type). 0.12-0.41 s (three 1.4-2.9 s); 30 requests per 10 s. Its misses are mostly recent groups |
| **the two together** | | **11,786 of 11,790**. The 4 missing are new: Sonic Boom's "A ? of WHEN" (album, 2026-07-10) and two singles, Cake's "Long Jacket" (2026-08-28) |

Also measured: 292 official groups past MusicBrainz's 600 cap that the page cannot reach today (Johnny Cash 145, Miles
Davis 111); 246 visible groups with an alias that is more than punctuation, 144 of them also an official edition title
(so about 100 only an alias matches, e.g. Bowie's "★", which services call "Blackstar"); official edition titles not
already a title or alias on 514 visible groups. Simon (2026-10-01): the community data is updated daily.

**Route A — the page's list from ListenBrainz and the community API, MusicBrainz after it for the next visit.**
- **Before the draw:**
  - ListenBrainz's list and the community reply, together (both off the MusicBrainz queue);
  - the artist read (band links; the list itself under 25 groups);
  - ONE by-id request for the groups the community does not classify (needed on 40 of the 49 artists, never more
    than one);
  - the bootleg map from the community's statuses by the existing `_isOfficial` rule.
- **After the draw, in the background, for the next visit:** today's browse and by-id check give the aliases, edition
  titles, the newest groups and MusicBrainz's verdicts, and are merged over the list (MusicBrainz's fields win).
- **First draw:** 2 MusicBrainz requests plus about 0.3-3 s of outside requests (the by-id request waits for the
  community reply): **Dylan about 15 s -> 3-5 s**, and about
  the same for every artist (the 49: 285 -> 89 MusicBrainz requests before the draw).
- **What the first visit shows differently from today:**
  - the 292 groups past the cap now show;
  - groups matched only by an alias or an edition title (about 100 of the 49 artists' 9,685 groups, e.g. "★") show
    a visit later, since hide_unmatched hides them until then;
  - the 4 newest groups show a visit later;
  - 8 bootleg verdicts in 9,529 can differ until the background check lands.
- The alias gap closes when the community ships request 1 (release-group aliases, agreed).

**Route B — MusicBrainz keeps the list; the community's statuses replace the bootleg check before the draw.**
- **Before the draw:** the artist read, the browse, and one by-id request for the groups the community does not
  classify.
- **After the draw:** the by-id check in the background (edition titles, MusicBrainz's verdicts).
- **First draw:** Dylan 13 -> 7-8 requests (about 15 -> 8-9 s), Willie Nelson 11 -> 7, Björk 7 -> 4, Kraftwerk 5 ->
  3-4, under 25 groups 2 -> 1 (the 49: 285 -> about 175).
- **What the first visit shows differently from today:**
  - the groups past the cap show, added from the community list;
  - a group matched only by an edition title waits a visit;
  - 8 verdicts can differ until the background check lands;
  - aliases and the newest groups are there on the first visit.

**Common to both:**
1. **Background MusicBrainz requests yield** (`_netGet`): a job marked background is sent only when no other job waits.
   Needed: an album tap waits on one MusicBrainz request for its links, which would otherwise queue behind up to 12
   background requests.
2. **One visit, one list:** the spine a visit drew is kept for that visit (the per-visit ctx, beside `snap`), so a
   background result landing mid-visit changes nothing until the next entry. Needed for route A, where the list
   grows; for B only verdicts change, and visibility is already frozen per visit.
3. **Any outside source failing** (429, timeout, echo mismatch, unreadable, empty) falls back step by step:
   - ListenBrainz down: route B;
   - the community down: its verdicts come from the by-id check before the draw;
   - both down: today's path exactly.
4. **Refresh** stays a full MusicBrainz re-pull, awaited.
5. The community request uses the existing `hosted` bucket (one at a time, the plugin-id header); ListenBrainz gets
   its own bucket at its published rate.

**Tests:**
- `t_netqueue`: a background job never goes ahead of a waiting foreground one.
- A new suite on captured replies for each source: the rules, echo mismatch, 429, timeout, empty, the one by-id
  request, the groups past the cap, the background merge, and each fallback.
- The per-visit spine.
- `t_local` / `t_zerorg` / `t_rel2rg` for the maps' readers.
- Mutation-checked.

**AS BUILT (0.56.7, Simon: "yes"; CLAUDE.md dev log 0.56.7, ledger A2 `THE ARTIST PAGE DRAWS FROM LISTENBRAINZ AND
THE COMMUNITY API`).** Four changes from the plan below, each for a reason found while building:
- **the read goes first** and the two lists are asked for only when it lacks the whole list (under 25 groups nothing
  is sent: no wasted request for ~40% of library artists);
- **either source failing means the old path exactly**, not route B (one fallback path, not two);
- **a 1,500-group ceiling** (`FAST_RG_MAX`): Mozart is 6,092 groups on ListenBrainz (4.3 MB) and 7.3 s from the
  community API, J.S. Bach 6,174; such pages keep the old path and its 600 cap;
- **the completed list is also taken on a cache miss** (the drawn list expired: no tree to keep stable).

**BUILD PLAN — route A (Simon, 2026-10-01: "A"), as proposed:**

*Where the pieces go (API.pm unless named):*
1. **The queue** (`%NET`, `_netBucket`, `_netGet`):
   - a new `lb` bucket for `api.listenbrainz.org`: one request at a time, no gap, the shared 5-30 s backoff after a
     429, and the `slow` backoff after a timeout, as `hosted` has;
   - a `background => 1` option: such a job is queued behind every other job and never goes ahead of one. A job
     already sent is not recalled, so a tap waits at most one request (about 1.1 s).
2. **Two new fetches**, both `failFast` (the page never waits out a backoff), each answering undef on any failure:
   - `_lbGroups($mbid, $cb)`: ListenBrainz's artist list in the spine's shape (`mbid`, `title`, `date`, `type`,
     `secondary`, no aliases). The reply's `artist_mbid` must be the one asked, else a miss. An EMPTY list is a miss
     too, so an artist ListenBrainz does not know yet goes to MusicBrainz: the tag check before the page
     (`Browse::_resolveArtistMbid`) reads an empty spine as "wrong tag".
   - `_hostedDisco($mbid, $name, $cb)`: the community's `/discography?mbid=&withReleases=1` in the `hosted` bucket,
     with the echo check. It gives its groups (for the union) and a verdict per group by the existing
     `_isOfficial` rule, plus release id -> group.
3. **`getReleaseGroups(read => 1)` on a cache miss, not `force`** (the page and the tag check; every other caller is
   unchanged):
   - the artist read, `_lbGroups` and `_hostedDisco` go out together;
   - if the read carries the whole list (under 25 groups) it is used, as today;
   - otherwise ListenBrainz's list, plus the community groups it lacks, becomes the spine: cached under `dsc:rg` and
     marked `dsc:rgfast:<mbid>` (14 days), meaning "MusicBrainz still to complete";
   - if ListenBrainz gave nothing, the browse runs before the draw as today.
   - The community reply is kept for step 4 (`dsc:cmdisco:<mbid>`, the same 14 days).
4. **`warmOfficial` takes the community's verdicts when it has them:**
   - the groups it classifies need no request;
   - the rest (credited second, listed with no releases, or ListenBrainz-only) go to the by-id search as today, 100
     to a request;
   - the map is stored marked `src => 'cm'` (no edition titles yet);
   - without the community reply, today's check runs unchanged.
5. **After the draw, in the background** (`API::completeArtist`, started at the end of the page's post-render chain
   in `Browse::_discographyView`, only when `dsc:rgfast` is set and none is in flight):
   - the browse (today's pager, 6 pages at most) and the by-id check over the groups it lists, every request
     `background => 1`;
   - merged over the drawn list: MusicBrainz's entry wins where both have a group (aliases, titles, types, dates);
     groups only the first list has (past the 600 cap) are kept; groups only MusicBrainz has (the newest) are
     added; `_pruneAliases` over the whole; MusicBrainz's verdicts and edition titles over the `src => 'cm'` map;
   - written to `dsc:rgnext:<mbid>`, and `dsc:rgfast` cleared;
   - a failure caches nothing and the marker stays, so the next visit tries again.
6. **The swap** (`Browse::topLevel` / `_discographyView`): an entry that carries the artist (not a positional walk)
   moves `dsc:rgnext` to `dsc:rg` before it reads the spine. Such an entry already rebuilds a complete new tree and
   resets `snap`; a positional walk never swaps, so its tree keeps its item_ids.
7. **Refresh** (`force`) takes today's full MusicBrainz path, awaited. `clearArtistCache` also clears `rgfast`,
   `rgnext` and `cmdisco`.
8. **`CACHE_VERSION` 0.56.7**, install.xml / repo.xml, the zip and its sha.

*Unchanged:* the artist read, the band and collaboration lookups, the streaming pool (it starts on the drawn list's
titles, as it starts on today's), the bootleg rule itself, the search, the release page (it reads `dsc:rg`, which a
visit does not change under it).

*Tests:*
- `t_netqueue`: the `lb` bucket's rate and backoff; a foreground job overtakes waiting background jobs, never one
  already sent; failFast unchanged.
- A new `t_fastpage.pl` on captured replies:
  - ListenBrainz: the shape, echo mismatch, empty -> browse, 429 / timeout -> browse;
  - the union with the community's groups;
  - under 25 groups -> the read's list;
  - `force` -> today's path;
  - the community verdicts, and one by-id request for the rest;
  - the background merge rules (MusicBrainz wins, past-cap kept, newest added, aliases pruned, verdicts and
    edition titles replaced);
  - a failed completion keeps the marker;
  - the swap happens on an entry and never on a walk;
  - background jobs yield;
  - Refresh clears the new keys.
- `t_local`, `t_zerorg`, `t_rel2rg`, `t_perf` re-run for the maps' readers.
- Mutation-checked.

*Ledger:* A2 `THE ARTIST PAGE DRAWS FROM LISTENBRAINZ AND THE COMMUNITY API` covers the behaviour changes and why
(aliases, edition titles and the newest groups a visit late; groups past the cap shown; background requests yield;
the list swapped only on an entry). The dev log gets 0.56.7.

**Live on the rig, public API:** cold pages for Bob Dylan, The Beatles, Johnny Cash, Willie Nelson, Brian Eno, David
Bowie ("★"), Kraftwerk, Sonic Boom ("Reset"; "A ? of WHEN" under route A arrives on the second visit) and Ladyhawke,
each compared with 0.56.6's page, then a second visit (route A's background merge); an album tapped straight after a
big page; Refresh.

---

## B. Public API vs mirror — where the paths still differ

> **2026-09-30: all five are gone** (stage 3: built as 0.56.3, checked live on 0.56.4, uncommitted; §A12), and with
> them the unquoted pass that rows skipped on every setup. The line numbers below are the 2026-09-26 tree's.

The standing rule (top of `CLAUDE.md`): behaviour is identical everywhere, pacing is the only
allowed difference. **Five places break it. All five skip work; none of them pace it.** Gates 1
and 2 are the two already logged as OPEN in the ledger; gates 3–5 are the ones named in the
resolver plan §4. Verified present in this tree at the line numbers given.

| # | where | what a public user loses |
|---|---|---|
| 1 | `API::filterRowsWithContent` — `return $cb->($rows, 0) if $class->mbGap(1.1)` (API.pm:1342) | the whole search-row filter: dead-end rows stay ("Genesis Tajiri" → "Couldn't identify"), alias rows are not folded (Tommy Genesis), and the library is not attached to a row by its MusicBrainz tag |
| 2 | `Browse.pm:3459` — the second service search under MusicBrainz's canonical name | a renamed band loses a service. "British Sea Power" gets no Qobuz row, because Qobuz files it as "Sea Power" |
| 3 | `_artistMbidByName` alias pass — `$aliasOk = !$speculative \|\| !_mbGap(1.1)` (API.pm:982) | nothing today — only reachable through #1 |
| 4 | `_artistMbidByName` credit split — `$splitOk` (API.pm:1062) | nothing today — only reachable through #1 |
| 5 | `_artistMbidByName` zero-release check — `$countOk` (API.pm:1094) | nothing today — only reachable through #1 |

**#3–#5 are currently unreachable on the public API**, because #1 returns before any speculative
lookup happens. They are not harmless, though: if #1 is un-gated without also un-gating them, a
row lookup would write a *worse* answer into the shared `dsc:mbid` cache than a page lookup does,
and the page would then inherit it.

**What is legitimate and stays:**

- `_mbSearchVerdict` — a zero-result search on an unproven mirror is retried against the public
  API. That protects a mirror; it does not change public behaviour.
- `_mbGap` / `NET_GAP_MB` — the 1.1s courtesy gap on `musicbrainz.org` only. Pacing, which is the
  allowed difference.
- Cover Art Archive always goes to the public CAA. `musicbrainz-docker` does not mirror it.

**One non-gate difference worth naming.** The same code produces a different *result* on the two
bases, because it is slower: `official_wait` (15s) expires on the public API for any artist over
~1,300 releases, so the page renders **unfiltered**. That is not a gate — it is the strongest
argument for section A.

### B1. The two search types

Simon's rule, already in the code at `Browse.pm:3408`: *"we need to ensure all fixes we do for
matching are done across matching from the rows in Artists and via our search."*

| | row from **Artists** (browse) | row from **our search** |
|---|---|---|
| entry | `_discographyView` with `artist_id` | `_discographyView` with `artist_id` + `artist` — **the same sub, same args** |
| name → mbid | `getArtistMbid`: library tag first, then the full cascade | same |
| canonical-name second service pass | always (0.45.0, inside `getCandidates`) | **only when un-throttled** (gate #2) |
| dead-end / alias-fold / tag-attach on the row list | n/a | **only when un-throttled** (gate #1) |

**So: on a mirror the two are already the same. On the public API the search path is the poorer
of the two, and gates #1 and #2 are the entire reason.** Removing them — which section A makes
affordable — is what makes the two paths identical everywhere.

*Built 2026-09-30 (stage 3: 0.56.3, checked live on 0.56.4; uncommitted): both gates are gone, with the three that
were missing from this table (#3-#5 of §A12: a row lookup's alias, joint-credit and zero-release passes)
and the unquoted pass, which rows skipped on every setup. The cost is paid as §A12.6 proposed.*

---

## C. The Lyrion Community API — where it fits

Measured today, `https://api.lms-community.org`, `X-LMS-Plugin-ID` header sent, Cloudflare
`cf-cache-status: HIT`, `max-age=2592000` (30 days), no rate-limit headers. *(No published limit: the fleet sets its
own from how MAI uses the service, one request at a time with a 5-30 s backoff after a 429, and it does answer 429 to
one-at-a-time traffic after a burst; measured 2026-09-30, §A12.7.)*

### C1. What it answers now

`GET /music/artist/<name>/discography?mbid=<id>&withReleases=1`

| field | present | notes |
|---|---|---|
| `mbid`, `title` | yes | |
| `primary_type` | mostly | missing on 56 of 1039 Beatles entries |
| `secondary_types` | when set | absent on 275 of 1039 |
| `release_date` | mostly | missing on 156 of 1039 |
| `cover` | sometimes | missing on 763 of 1039 |
| `status` | mostly | a single guessed value; missing on 35 |
| `releases` | yes | `{release-mbid: status}` — 3268 releases for the Beatles; absent on 17 of 1039 |
| **release-group `aliases`** | **no** | request 1, agreed, not shipped |
| **release titles in `releases`** | **no** | request 2, expected, not shipped |

The Beatles: **1039 groups + 3268 releases, 383 KB, one call, 0.07s cached.** That is the whole
spine and the whole official/bootleg map in a single request (no fixed gap).

Other routes confirmed live: artist `/aliases`, `/mbid`, `/picture`, `/biography` (a link
directory, not prose), `/relatedArtists` (last.fm similar); album `/cover`, `/genres`, `/mbid`
(which returns a **release** id, not a release-group id — display only).
`?type=Album` filters server-side on the primary type (Kraftwerk 163 → 113).

### C2. Two behaviours to code against

1. **An unknown mbid is silently answered by NAME.** Re-verified today:
   `/artist/Radiohead/discography?mbid=00000000-…` returned Radiohead's 580 groups. So every
   reply's top-level `mbid` must be compared with the one sent, and a mismatch treated as a miss.
2. **It lists only groups where the artist is the FIRST credit.** Kraftwerk: MusicBrainz 167,
   hosted 163. I looked up the artist credit of all four missing groups:

   | missing group | credit order |
   |---|---|
   | Vangelis / Kraftwerk | 0: Vangelis, **1: Kraftwerk** |
   | 1997-05-25 BBC Radio 1 Essential Mix | 0: Sneaker Pimps … **3: Kraftwerk** |
   | The Kraut Invasion | 0: Su Kramer, **1: Kraftwerk** |
   | In the Kraftwerk Tonight | 0: Phil Collins, **1: Kraftwerk** |

   4 of 4. In MusicBrainz terms: the hosted query joins `artist_credit_name` at **position = 0**
   only. Same pattern at scale, measured today — The Beatles 1050 → 1039, Radiohead 585 → 580.
   (Willie Nelson 489 → 423, measured 2026-09-25, not re-run today.)

### C3. What it can replace, what it cannot

| our call | hosted replacement | verdict |
|---|---|---|
| `getReleaseGroups` (spine) | `/discography` | **yes**, minus second-credited groups |
| `warmOfficial` `o` + `r` maps | `/discography?withReleases=1` | **yes** |
| `warmOfficial` `t` (edition titles) | — | **no**, needs request 2 |
| release-group aliases | — | **no**, needs request 1 |
| `warmArtistAliases` | `/aliases?mbid=` | **yes** |
| `warmCandidateCounts` | `/discography` entry count | **partly** — an act credited only second counts 0 there, so a 0 must be confirmed against MusicBrainz |
| `_artistMbidByName`, `getArtistCandidates` | — | **no**. One guess, no score, no second candidate; 4 of 22 names were confidently wrong (2026-09-24, re-checked 2026-09-25) |
| `warmBandMembers` | — | **no** |
| `warmCollaborations` | — | **no** |
| `getReleaseGroupUrls` | — | **no**, hosted album links are keyed by title and a *release* id |
| bio prose | — | **no**, stays MusicArtistInfo |

### C4. The extra data we would need, and where it comes from in MusicBrainz

This is the answer to "what would we need, why, and from which part of the MusicBrainz database".

| # | data we need | why we need it | MusicBrainz source (table → ws/2 route) | hosted today |
|---|---|---|---|---|
| 1 | **Release-group aliases** | MusicBrainz titles a group in its original language. Without the alias, a service's English title never matches: *Radio‐Aktivität* vs "Radio-Activity", *Computerwelt* vs "Computer World", `3rd` vs "Third". 8% of groups (13 of Kraftwerk's 167) | `release_group_alias` → `release-group?…&inc=aliases` | **no** — request 1, agreed |
| 2 | **Release titles inside the `releases` map** | A group is named after its *first* release; the user's copy is often a later reissue with a different title, and a streaming copy never has a MusicBrainz tag. "Tour de France" (2009 remaster) sits in the group "Tour de France Soundtracks" | `release.name` → `release?release-group=<id>` or the search's `releases[].title` | **no** — request 2, expected |
| 3 | **Groups where the artist is not the first credit** | Collaborations vanish from the second-named artist's page. Willie Nelson loses 67 groups including 11 studio albums (measured 2026-09-25) | `artist_credit_name` (position > 0) → `release-group?artist=<mbid>` browse, or `arid:` search | **no** — first credit only |
| 4 | **Ranked same-name candidates for a name** | "which act is this?" needs a *list* with scores, not one guess. Rossini → "Rossini Quartet", The Las → "The Las Vegas Boneheads" | the Solr `artist` search index (not a table) → `artist?query=` | **no** — one guess only |
| 5 | **Band membership** | "Also a member of" — and the reason a member tagged only as COMPOSER on their band's record is still shown under the band | `l_artist_artist` + `link_type` "member of band" → `artist/<id>?inc=artist-rels` | **no** |
| 6 | **Collaboration links** | Holly Golightly → "Holly Golightly and The Brokeoffs"; and the collaborator count that separates a real duo from a 37-artist charity single | `l_artist_artist` + `link_type` "collaboration" → `artist/<id>?inc=artist-rels` | **no** |
| 7 | **Release-group external links** | AllMusic / Discogs / Wikipedia / review rows on a release page | `l_release_group_url` → `release-group/<id>?inc=url-rels` | **no** — hosted `/album` links are keyed by title + a release id, which is not an identity we can trust |
| 8 | **Per-release status** | the bootleg filter. Already there | `release.status` → `release_status` | **yes** |
| 9 | **Primary / secondary types, first release date** | sections, year labels, chronological sort. Already there, with gaps (56 / 275 / 156 missing of 1039) | `release_group_primary_type`, `release_group_secondary_type_join`, `release_group_meta.first_release_date_*` | **partly** |

**Nothing in rows 3–7 is being asked for.** Simon, 2026-09-25: *"Stop asking for things."* They
are listed so the split is explicit: those stay on MusicBrainz, permanently, and the hosted API
is used for what it is good at.

### C5. How the two fit together

The community API and the MusicBrainz search are **complementary, not alternatives**:

- The hosted call is one request, with no fixed gap, and covers the first-credit spine completely, but
  misses second-credited groups, aliases and edition titles.
- The MusicBrainz search is 1–6 throttled requests and covers everything including second-credit
  and edition titles, but misses aliases and caps at 500. *(Corrected 2026-09-29, §A11: paged by
  artist it loses groups. It is exact only by id, so it classifies the groups it is given and cannot
  list them. The browse stays the only complete MusicBrainz list, second-credited groups included.)*

Running **both in parallel** and merging by release-group id gives a first visit that is complete
on every axis except release-group aliases — and the hosted call costs nothing against the
MusicBrainz budget. If the hosted call fails or answers for a different mbid, the MusicBrainz side
alone still renders a correct page.

---

## D. The two pending requests, re-judged

| request | still needed? | why |
|---|---|---|
| **1 — release-group aliases** | **Yes, more than before.** | The MusicBrainz *search* does not carry them and the hosted API does not either. Only the group *browse* has them. Without the request we keep a background browse purely for aliases, on both routes. *(Corrected 2026-09-29, §A11: the artist lookup has them too, under 25 groups, and nothing runs "in the background": the browse is the spine, so its aliases are free. The request lets the browse go only if second-credited groups get another source, §F.4.)* |
| **2 — release titles in `releases`** | **Yes, but the reason has changed.** | The stated reason was "otherwise we keep a 40-page MusicBrainz release browse". **That is no longer true** — the search gives us `releases[].title` for free. The request is still right, because without it the hosted call cannot stand alone and always needs a MusicBrainz companion for edition titles. Worth saying so if it comes up, rather than letting a stale justification stand. *(Still true 2026-09-29: the by-id search carries the titles.)* |
| 3 — unknown mbid | retracted by Simon | we check the returned mbid ourselves |

---

## E. Dead ends measured today — do not re-derive

| attempt | result |
|---|---|
| `release-group?artist=X&inc=releases` | 400 — *"releases is not a valid inc parameter for the release-group resource"* |
| `release-group?artist=X&status=official` | 400 — *"status is not a valid parameter unless releases are requested"* |
| search past 500 results | 400 — *"Must retrieve at most 500 search results, not 550."* So `offset + limit <= 500` |
| `arid:X AND (status:official OR -status:[* TO *])` | count 0 — a bare negative inside an OR matches nothing in Lucene. Two queries required |
| batched `arid:A OR arid:B …` as a "has releases?" test | unsound — 3 of 8 artists appeared |
| batched `artist:"A" OR artist:"B" …` as a name resolver | unsound — 3 of 8 names found; one common name floods the page |
| splitting an over-500 artist by `primarytype` | insufficient — Elvis official Albums = 900, Miles official Albums = 535 |
| paging `arid:X` 100 at a time as a complete list (2026-09-29) | loses groups: Kraftwerk 162 of 167 on 3 runs of 3, five others returned twice (§A11) |
| paging `arid:X AND status:official` (2026-09-29) | The Beatles 257 of 330, 73 returned twice; Radiohead 101 of 101 |
| `inc=aliases` on the release-group search (2026-09-29) | ignored: only the artist-credit's aliases come back |
| the artist lookup's `inc=release-groups` as a full list (2026-09-29) | capped at 25 with no count; complete only below 25 |
| one `release-group/<id>?inc=aliases` per group (2026-09-29) | works, but 13 requests for Kraftwerk and 45 for Radiohead, against 0 from the browse |

Also observed: the MusicBrainz **search** cluster sheds more readily than the browse cluster. Four
requests today came back *"The MusicBrainz web server is currently busy"* — the documented shed
body, which `_netIsShed` already retries without moving the backoff curve. Any move onto the
search route leans harder on `NET_SHED_RETRIES`.

---

## F. What I would do, in order

Each stage: suites green before and after, then a live check **on the public API**.

1. **The four cheap ones (A7).** No design change, no new route: fold aliases into the band-member
   call, batch the owned-release lookups, fold the collaboration vetting, combine the name and
   alias query. Saves ~10 requests on a typical cold page and needs no new caching.
   **Status 2026-09-29: the first three are built (0.56.1) and VERIFIED LIVE on the public API (§A10).
   Combining the name and alias query is HELD for the resolver's Part C (§A7). The live run found one more
   saving of the same kind (§A10, "Found in the live run"), not built.**
2. **The bootleg check by id (re-designed 2026-09-29, §A11).** *The original plan (a new
   `getReleaseList` paging the search, with the alias browse demoted to the background) is withdrawn:
   paging loses groups, and the demotion saved nothing.* Instead:
   - **The spine stays the release-group browse**, with its free aliases. An artist with fewer than 25
     groups takes it from the artist read the page already makes (`_readArtist`, now
     `inc=aliases+artist-rels+release-groups`, sorted by group id), so that artist's browse request
     goes. The page asks for the read FIRST (`getReleaseGroups(read => 1)`); the other callers
     (the same-name disambiguation, the release page, play) keep the browse alone, as today.
   - **`warmOfficial` asks the search for the page's groups by id**, 100 per request (at most 6), and
     builds `o`, `r` and `t` from each group's release list, with the same rules. A group listed with no
     releases, or not returned, stays unclassified (shown). The 40-page release browse is deleted.
   - **The open question is answered: `warmLocalReleases` leaves the render path.** The check maps every
     release of every page group, so it runs after the render, only for owned releases the check did not
     place (normally none), or for all of them when the check failed. The next visit uses its answers.
   - **A failed check caches nothing** and is asked again on the next visit, as before.
   - Cost, cold page: under 25 groups 5 → 3 requests, Jamie Cullum 6 → 4, Kraftwerk 11 → 6, Radiohead
     21 → 14, The Beatles 43 → 14 (§A11). Aliases stay on the first visit at no extra cost.
   **Status 2026-09-29: built as 0.56.2, installed, VERIFIED LIVE on the public API, committed on dev**
   (`CLAUDE.md` dev log, 0.56.2). 49 suites, 1,564 assertions, 0 failures; 16 mutants caught. On the rig, cold,
   requests before the render: Ladyhawke 4 (the 3 above plus the name search an artist with no library tag
   already needs), Kraftwerk 6 (click to render 6.0 s; 0.56.1 took 12.4 s), The Beatles 14 (14.8 s; the check
   7.9 s, 598 of 600 classified, bootlegs hidden on the first visit), Brian Eno 7 including one retried shed
   (7.0 s; 0.56.1 took 12.5 s). Eno's two owned albums off the page were looked up after the render. The
   by-id search runs in MusicBrainz's SEARCH zone, which sheds when busy; the queue's shed retry covered the
   one seen live.
3. **Un-gate the five divergences (B).** Only once 1 and 2 have made the work affordable. #1 and
   #3–#5 must move together, or the row path poisons the shared name cache.
   **Corrected 2026-09-30 (§A12): that premise did not hold for the search.** Stages 1 and 2 made the PAGE
   cheaper and removed no search request; removing the gates as they stand multiplies a multi-row first search's
   MusicBrainz requests three to six times (measured). There is also a sixth divergence of the same kind: row
   lookups skip the unquoted pass on every setup. The proposed route, not yet decided, is §A12.6.
   **Carried in from the stage-1 review (2026-09-29):** once gate #1 is gone, the search-row fold's
   `warmArtistAliases` call runs on the public API, one per same-name MusicBrainz hit, and the search list
   waits for all of them. Since stage 1 that call is `_readArtist`'s `inc=aliases+artist-rels` read,
   about 20 KB instead of 1.6 KB for Radiohead. The number of requests is unchanged, and requests are
   what MusicBrainz limits, so this costs bytes and latency only; the bands it caches pay back on a later
   page visit. Decide here: accept it, or read the fold's aliases from the Community API's
   `/aliases?mbid=` (stage 4, §C3). **DECIDED 2026-09-30 in the stage-3 review: accepted** (Simon; ledger A2
   `STAGE 3 CHANGED FIVE BEHAVIOURS ON PURPOSE` #5): the request count a mirror always paid, cached 30 days, and
   the read also caches the bands the page uses; `/aliases` would add traffic to the community API's queue.
   **Status 2026-09-30 (night): BUILT and checked live**: stage 3 as 0.56.3/0.56.4 (§A12), then 0.56.5 (§A13) and
   0.56.6 (§A14); uncommitted. D2 and D3 (§A12.6) are still open.
4. **Add the community API alongside (C).** One request helper, mbid echo check, merged with the
   search result. It is additive: if it is down, everything still works.
   **To decide here (added 2026-09-29, §A11):** the community API's aliases (request 1) let the
   release-group browse go only if second-credited groups come from somewhere else. The community API
   lists first credits only, the artist read lists at most 25 groups, and paging the search loses groups,
   so for an artist with 25 or more groups the browse is the only complete list. The choice is to keep the
   browse (its aliases stay free and request 1 saves nothing here), or to fetch second-credited groups a
   visit late (Simon allowed next visit where it is needed, 2026-09-29). Its status map would replace
   the by-id requests for first-credited groups either way.
   **Status 2026-09-30 (night): partly in the code.** The one path to the service exists (`_netGet`'s `hosted`
   bucket, one request at a time; `_hostedHeaders`; the mbid echo check), and it answers two things: release counts
   (stage 3, `warmCandidateCounts`) and the search's leftover results by name (stage 3b, `_hostedByName`). The
   page's spine and status map are not started, and the choice above is still open.

Stage 1 is independent of everything else and could go in on its own.

---

## G. Tests run (2026-09-26, this tree)

```
tools/syntax_check.sh
  DB / Sources / API / Browse / Settings / Plugin   all OK
  CACHE_VERSION  OK (0.56.0, matches install.xml)
  PROBE_MBID     OK (a74b1b7f-71a5-4011-9441-d0b5e4122711 is Radiohead)
  XML            OK (Discography/install.xml, repo.xml)
```

All 45 Perl suites, **1,356 assertions, 0 failures**:

```
t_adapters 37   t_alias 45   t_artimg 49   t_bees 33   t_canon 12
t_collab 32     t_credit 16  t_db 108      t_detailshared 12  t_dupes 12
t_extid 29      t_extras 19  t_fold 67     t_fuzzy 26  t_hitmakers 8
t_joint 33      t_local 52   t_localonly 8 t_lone 30   t_loose 15
t_material_actions 40        t_mbname 15   t_mirror 23 t_netqueue 50
t_norm 51       t_perf 20    t_playurl 11  t_prose 67  t_rank 19
t_resolve 4     t_rivals 28  t_searchbtn 20  t_searchrank 4  t_settings 32
t_size 38       t_spotify 85 t_strips 39   t_svcname 18  t_thelas 12
t_tracklink 26  t_verdict 18 t_view 40     t_weak 14   t_worksbest 21
t_zerorg 18
```

This is the baseline. **No code was changed** in producing this analysis — everything above is a
proposal measured against the live APIs, not an edit.

Suites the changes in section F would need before they are called done: `t_netqueue` (the batched
`reid` query is a new URL shape through the one queue), `t_mirror` (the five gates), `t_thelas` and
`t_fuzzy` (the combined `artist OR alias` query changes scoring), `t_local` and `t_zerorg` (the
`o`/`r`/`t` maps built from a search payload instead of a browse payload), and a new suite for the
500-cap fallback. *(2026-09-29: the by-id design has no 500-cap fallback; the suites stage 2 touched
are listed in `CLAUDE.md`'s stage-2 dev log.)*

*Current (2026-09-30, the 0.56.6 tree): 53 suites, 1,775 assertions, 0 failures; `syntax_check.sh` clean.*
