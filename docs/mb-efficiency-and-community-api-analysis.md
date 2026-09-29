# MusicBrainz call efficiency, public/mirror parity, and the Community API — full analysis

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
   work rather than pace it. Section B lists them and what each costs a public user.
8. The two search types (a row from **Artists** vs a row from **our search**) are identical on a
   mirror and **not** identical on the public API — one of the five gates is the cause.
9. The Community API can replace the spine in one un-throttled call, but it **cannot** replace
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

---

## B. Public API vs mirror — where the paths still differ

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

---

## C. The Lyrion Community API — where it fits

Measured today, `https://api.lms-community.org`, `X-LMS-Plugin-ID` header sent, Cloudflare
`cf-cache-status: HIT`, `max-age=2592000` (30 days), no rate-limit headers.

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
spine and the whole official/bootleg map in a single un-throttled request.

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

- The hosted call is one un-throttled request and covers the first-credit spine completely, but
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
   **Carried in from the stage-1 review (2026-09-29):** once gate #1 is gone, the search-row fold's
   `warmArtistAliases` call runs on the public API, one per same-name MusicBrainz hit, and the search list
   waits for all of them. Since stage 1 that call is `_readArtist`'s `inc=aliases+artist-rels` read,
   about 20 KB instead of 1.6 KB for Radiohead. The number of requests is unchanged, and requests are
   what MusicBrainz limits, so this costs bytes and latency only; the bands it caches pay back on a later
   page visit. Decide here: accept it, or read the fold's aliases from the Community API's
   `/aliases?mbid=` (stage 4, §C3).
4. **Add the community API alongside (C).** One request helper, mbid echo check, merged with the
   search result. It is additive: if it is down, everything still works.
   **To decide here (added 2026-09-29, §A11):** the community API's aliases (request 1) let the
   release-group browse go only if second-credited groups come from somewhere else. The community API
   lists first credits only, the artist read lists at most 25 groups, and paging the search loses groups,
   so for an artist with 25 or more groups the browse is the only complete list. The choice is to keep the
   browse (its aliases stay free and request 1 saves nothing here), or to fetch second-credited groups a
   visit late (Simon allowed next visit where it is needed, 2026-09-29). Its status map would replace
   the by-id requests for first-credited groups either way.

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
