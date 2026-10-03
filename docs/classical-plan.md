# Classical: a works page for composers — plan

**Status 2026-10-02: PLAN, nothing built.** Simon: *"what I want now is a plan for classical handling perhaps we
need a different source I was looking at Open Opus for this side of things as its designed for classical and
supports works/compositions. So lets look over that and MB to come up with a plan."* Everything below was measured
on 2026-10-02 (rig on 0.56.42, public MusicBrainz, the live Open Opus API, Simon's library and Qobuz/TIDAL). It
answers the five questions in the ledger's `PARKED — CLASSICAL NEEDS A DIFFERENT SPINE` (2026-07-22). Four
decisions for Simon are in §6. Scratchpad probes: `oo/` (Open Opus, library, Qobuz/TIDAL), `mbc/` (MusicBrainz).

## 1. What is wrong today

Three kinds of classical artist, and only one of them is broken badly:

| page (today, 0.56.42) | kind | what it shows | why |
|---|---|---|---|
| Chopin | canon composer | 3 releases, all your own, of 2,066 MB groups (13.4 s) | Qobuz's Chopin artist holds 178 albums of his music; all dropped as "credited to other artist ids" (the pianists) |
| Debussy | canon composer | 8 of 1,645 (8.8 s) | Qobuz: 150 dropped the same way (Seong-Jin Cho, Bavouzet...) |
| Vivaldi | canon composer | 12 of 2,182 (15.2 s, 19 MB requests) | Qobuz: 188 dropped (Janine Jansen's and Gidon Kremer's Four Seasons...) |
| Mozart (0.56.8) | canon composer | 6 of 6,091 | the same |
| Karajan | performer | 36 of 1,047 MB groups, none Local | Qobuz offered 191 albums; only 36 groups' titles matched one |
| New York Philharmonic | performer | 24 (5 Local) of 725 | Qobuz offered 137; 22 groups matched |
| Bernstein / Thibaut Garcia / Bavouzet | performers | 41 / 5 / 3 | Garcia complete (3 Local); the others thin like Karajan |
| Max Richter / Philip Glass | modern composers | 49 / 51 | fine: they release their own music, credited to them |

- **A canon composer's page is the wrong model.** His "discography" is other people's recordings of his works.
  MusicBrainz files them under him ("Mozart; Wiener Philharmoniker, Karl Böhm"), the services under the performer,
  so nothing matches and `hide_unmatched` hides the rest. Patching the resolver cannot fix this (ledger A2
  `Classical composer/performer credit`, parked twice).
- **A classical performer's page has the music but loses it in title matching.** MusicBrainz titles a group
  "Symphony no. 6 'Pathétique'" with the composer in the credit; Qobuz titles it "Tchaikovsky: Symphony No. 6 in B
  Minor, Op. 74 'Pathétique'". The "Also on streaming" setting (off on the rig) would list the rest, unchecked.
- **A modern composer who releases his own music needs nothing.**

## 2. The sources, measured

### 2.1 Open Opus (api.openopus.org)
- **Up and fast:** API 1.20.6, 0.3 s a request, no key, no registration. **Data is public domain (CC0)**; the API
  code is GPL-3.0.
- **Coverage is the canon:** 220 composers, 24,975 works. 52 born after 1900, 3 after 1950. Not there: Hildegard,
  Einaudi, Max Richter, Nyman, Tavener, Hisaishi, film composers. All names Latin.
- **Per composer:** works grouped Orchestral / Chamber / Keyboard / Stage / Vocal, with `popular` (397 works in
  all) and `recommended` (1,234; 204 composers have one) flags. 10,258 titles carry a catalogue or opus number,
  1,183 a quoted nickname. Mozart: 557 works, 14 popular, 39 recommended, 549 with a K. number.
- **The whole database is one download** (`work/dump.json`): 3.3 MB, 379 KB gzipped. It carries **no ids at all**
  (the live API's ids are not in it).
- **No MusicBrainz ids, no recordings.** Mapping a composer to MusicBrainz by name plus birth year: 14 of 14
  sampled at random came back right, including Mussorgsky (his MusicBrainz name is Cyrillic) and Bartók
  (Hungarian name order).
- **The project looks dormant.** The API code was last pushed in February 2024. Its second host (`dynapi`, which
  serves the work guesser and performer roles) presents an expired certificate issued for another name
  (`dynapi.concertino.app`, expired 2026-08-28), so a plugin cannot call it. The main host's certificate is valid
  (renewed September 2026), so the read API and the download still work.
- **The work guesser** (free text to a work, the bridge Open Opus's own player used): 8 of 14 real album titles
  matched, across languages ("Le quattro stagioni" -> The Four Seasons). It failed on titles naming several works
  ("Symphonies Nos. 5 & 9", "The Complete Symphonies") and on Beethoven's "Symphony No. 9 'Choral'". Not needed
  by this plan, and unreachable anyway.

**Why it fits:** its 220 are exactly the composers whose pages are broken. The modern composers it lacks are the
ones whose pages already work.

### 2.2 MusicBrainz
- **Works are too fine to list.** Mozart has 5,589 works, because every movement is one. Most have no type and
  few attributes. A list of whole works would need each work's parent link: thousands of requests on the public
  API.
- **Release credits name the performers:** 91 of 100 sampled Mozart groups read "composer; performers". So a
  performer's MusicBrainz list does hold their recordings; their problem is title matching (§1).
- **It tells a classical artist apart, at no cost.** Composers, conductors, orchestras and pianists all carry the
  genre `classical` (Radiohead: rock genres). Composers carry the tag `composer`; Karajan's description is
  "conductor", Gould's "pianist"; ensembles are typed Orchestra or Choir. All of it comes on the artist read every
  page already makes (`inc=genres+tags` on the same request).
- **Modern composers' "works" are their tracks** (Max Richter 712, Einaudi 203): no list to use, and none needed.
- A work does carry its translated titles and links to recordings (529 for one movement of Mozart's 21st). Not
  needed for the first phases.

### 2.3 Simon's library (LMS 9)
- 2,949 albums, about 75 classical (genre Classical 61, plus Orchestral, Symphony, Opera).
- **LMS's own Works data is filled in:** 425 works, 72 composers, 59 albums, from the files' WORK tags.
  `works artist_id:<composer>` lists his works (Vivaldi 17); `albums work_id:` and `titles work_id:` give the
  albums and tracks. Some tags are movement-level ("...Op. 8/1-4: Autumn").
- 52 of the 72 composers are Open Opus composers (394 of the 425 works) with a loose name match. 233 of 342 works
  matched an Open Opus work with a crude title / catalogue rule; the rest are movement-level or messy tags.
- A composer's albums sit under the COMPOSER role, which the page's performance-role filter (0.19.0) leaves out on
  purpose for non-classical pages.

### 2.4 The services
- **Qobuz's release search finds a work's recordings.** Searching the composer and the work, over 18 works from
  Mozart's 21st to Finzi's Clarinet Concerto and Tárrega's Recuerdos: **16 to 20 of the top 20 results are that
  work**, up to 200 results a search. Line 2 carries the performers and year ("Daniel Barenboim, English Chamber
  Orchestra (2005)"), and titles come in every language ("Klavierkonzert Nr. 21").
- **TIDAL's too, a bit noisier:** 12 to 20 of the top 20 over 6 works, at most 100 results ("mozart piano
  concerto 21" also brings No. 20).
- **The wording decides it:** "mozart piano quartet 1" 200 results, all right; "mozart Piano Quartet no. 1" 22;
  "mozart K. 478" and "beethoven piano trio op. 97" find the wrong works; "beethoven archduke trio" 115, right.
  So the search uses plain words (surname, the work's type, its number, a nickname), and each result is accepted by
  number, catalogue number or nickname.
- A composer's own Qobuz artist page lists 150-190 recordings of his works that the page drops today (§1).
- Deezer and Spotify not measured (neither is enabled on the rig).

## 3. The plan in one paragraph

**A canon composer gets a works page; everything else keeps today's page.** A composer page lists his works by
genre, popular and recommended first, from Open Opus. Each work opens a page of recordings: yours first, then each
service's versions with performers and year, from one search on first open. Performers keep the album page, with
classical title matching added later (phase 3). Modern composers and everyone else are untouched.

## 4. The design

### 4.1 The composer table (built once, shipped with the plugin)
Open Opus's 220 composers, each with its MusicBrainz id, found by name and birth year (220 requests, once, at build
time; any doubtful one checked by hand), and the Open Opus works (title, genre, flags), shipped as a data file.
**Entering composer mode needs no request:** the page resolves its MusicBrainz id exactly as today (library tag,
search row, link), then looks it up in the table. The table also settles the cases names cannot: Shostakovich's
MusicBrainz name is Cyrillic, there are several Bachs, and two Johann Strausses.

### 4.2 The composer page
- Header, biography and similar artists as today.
- **Popular**, then **Orchestral (n), Chamber, Keyboard, Stage, Vocal**: recommended works first, then the rest by
  catalogue number, with the existing Show more paging.
- A row is the work's title; line 2 says when you own it ("In your library"). Owned works come from LMS's Works
  data, matched to Open Opus by catalogue number or title. **Other works in your library** lists owned works Open
  Opus does not have.
- Possibly a switch to today's album view (decision 2).
- No MusicBrainz request beyond the artist read the page makes now. Today Mozart's page is 19-28 MusicBrainz
  requests, 9-15 s, and nearly empty.

### 4.3 The work page
- **In your library:** albums holding the work (LMS `albums work_id:`), each playing as today.
- **On Qobuz / On TIDAL:** one release search per service on first open, worded as in §2.4, filtered by the work's
  number, catalogue number or nickname, and kept 14 days. Each tile shows the album, performers and year; a tap opens
  the service's album (the existing album drill) or plays it.
- Matching recordings by the work, not by artist, so a disc of several works counts for each.

### 4.4 Performers (phase 3)
Measure first, then one of two (decision 4). **Classical title matching:** drop a leading "Composer:" from service
titles and match by work number and catalogue number, so Karajan's 191 Qobuz albums attach to his 1,047 groups.
**Or show "Also on streaming" automatically** for a classical performer (MusicBrainz genre `classical` and type
Orchestra / Choir, or described conductor / pianist / violinist...). Cheaper, but unverified by design.

## 5. Order of work
Each step as usual: suites green before and after, mutation-checked, a live check on the rig, Simon's OK before the
next.

0. **Measure, no UI.**
   - Build the composer table and list the doubtful matches.
   - Run the work search over the 1,234 recommended works on Qobuz and TIDAL, through a test-only command. Hand-check
     100 for wrong and missed recordings, and settle the wording and acceptance rule.
   - Match the library's 425 works to Open Opus with the real rule.
   - Decide the numbers before any page changes.
1. **The composer page** (§4.2): works, owned marks, entry by the table. Live: Chopin, Debussy, Vivaldi, Mozart,
   Bach, Shostakovich. Controls: Max Richter, Philip Glass, Karajan unchanged.
2. **The work page** (§4.3): library first, then Qobuz and TIDAL. Live: ten works across the six composers; owned
   ones show your album first.
3. **Performers** (§4.4): Karajan, New York Philharmonic, Bernstein before and after.
4. **Later, if wanted:**
   - works pages built from the library alone for composers outside Open Opus (Tárrega, Villa-Lobos, Finzi,
     Tavener: 20 of the library's 72);
   - typing a work into search ("four seasons") to reach its page.

## 6. Decisions for Simon
1. **Ship Open Opus's data with the plugin** (recommended: public domain, the project looks dormant, about 380 KB
   gzipped against today's 427 KB zip, less if trimmed to what the pages show), or fetch it from api.openopus.org on
   first use and refresh it now and then (no plugin growth, but it depends on a dormant host).
2. **The composer page:** works only, or works with a switch to today's album view.
3. **Composers outside Open Opus:** today's page as now, or a works list built from your library alone (phase 4).
4. **Performers:** classical title matching (exact, more work) or "Also on streaming" shown automatically for
   classical performers (cheap, unverified).

## 7. Risks
- **Open Opus is frozen.** No new composers or works, and its mistakes stay unless we correct our copy (we may: CC0).
- **Search noise:** compilations ("Best of Mozart") can slip through on a number. TIDAL is noisier. Step 0 measures
  it, and the acceptance rule is the guard.
- **Owned albums:** WORK tags vary (movement-level, extra text). Unmatched owned works still show, under "Other
  works in your library".
- **Two filters must not collide:** the composer page reads COMPOSER-role albums for "In your library"; the
  performance-role filter (0.19.0) stays for every other page.
- **Matching is our own code.** No shared matcher sub (`_norm`, `_artistMatch`, `_albumMatches`) needs to change for
  phases 0-2, so there is no fleet port.
