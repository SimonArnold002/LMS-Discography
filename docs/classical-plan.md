# Classical: a works page for composers — plan

**Status 2026-10-08: step 0 MEASURED (§8), the four decisions MADE (§6), step 1 (the composer page) BUILT in 0.56.50
(§9; what changed from the plan, §9.7); the year written and the instrumentation from Wikidata, and the layout items
1-4 of §10.5 (covers, the composer's line, "In your library" first, the work page) BUILT in 0.56.63, not installed (§10; item 5
waits, Simon 2026-10-08).** Simon: *"what I want now is a plan for classical handling perhaps we need a different source I was
looking at Open Opus for this side of things as its designed for classical and supports works/compositions. So lets
look over that and MB to come up with a plan."* Sections 1-7 were measured on 2026-10-02 (rig on 0.56.42, public
MusicBrainz, the live Open Opus API, Simon's library and Qobuz/TIDAL); step 0 (§8) on 2026-10-03, with the scripts
in `tools/classical/`. The plan answers the five questions in the ledger's `PARKED — CLASSICAL NEEDS A DIFFERENT
SPINE` (2026-07-22). Scratchpad probes: `oo/` (Open Opus, library, Qobuz/TIDAL), `mbc/` (MusicBrainz).

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
- A switch to today's album view (decision 2); if that makes the page messy, works only.
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

0. **Measure, no UI. DONE 2026-10-03, results in §8.**
   - Build the composer table and list the doubtful matches.
   - Run the work search over the 1,234 recommended works on Qobuz and TIDAL (done through the rig's own search menus,
     no plugin command needed). Hand-check 100 for wrong and missed recordings, and settle the wording and
     acceptance rule.
   - Match the library's 425 works to Open Opus with the real rule.
   - Decide the numbers before any page changes.
1. **The composer page** (§4.2): works, owned marks, entry by the table, the switch to today's album view (decision
   2). **BUILT 2026-10-07 in 0.56.50 (§9), not yet installed.** Live: Chopin, Debussy, Vivaldi, Mozart, Bach, Shostakovich. Controls: Max Richter, Philip Glass, Karajan
   unchanged.
2. **The work page** (§4.3): library first, then Qobuz and TIDAL. Live: ten works across the six composers; owned
   ones show your album first.
3. **Composers outside Open Opus** (decision 3): a works list built from the library (Tárrega, Finzi, Tavener,
   Giuliani ...: 18 of the library's 72 composers), measured first for libraries tagged unlike Simon's.
4. **Performers** (§4.4): ON HOLD (decision 4).
5. **Later, if wanted:** typing a work into search ("four seasons") to reach its page.

## 6. Decisions (Simon, 2026-10-03)
1. **Ship our own corrected copy of Open Opus, with a way to take a newer version.** Simon: *"ship it with a facility
   for us to update easily from another version if it does ever get updated, as most composers in classical are no
   longer alive it may well stay as is as neo classical isnt looked at the same."* So our corrections (§8.4) live in
   a file of their own, apart from Open Opus's data, and a build tool applies them to whichever dump it is given and
   says what changed. (The other choice was fetching from api.openopus.org on first use.)
2. **The composer page: works, with a switch to today's album view.** Simon: *"both for now. But if it becomes too
   messy we stick to works."* The switch is its own row, works and albums only, apart from the Singles & EPs row
   (Simon, 2026-10-07; §9.4).
3. **Composers outside Open Opus: try a works list built from the library.** Simon: *"lets try a works list but it
   needs to work for others collections to."* So it must not depend on how Simon tags his files (§7).
4. **Performers: on hold.** Simon: *"Hold on that one for now."* §4.4 is not started.

## 7. Risks
- **Open Opus is frozen.** No new composers or works. Our copy carries our corrections (CC0 allows it), and the build
  tool can take a newer dump if one appears (decision 1).
- **Other people's libraries are tagged differently.** The owned marks and the library-only works list (step 3) read
  LMS's Works data, which exists only where files carry WORK tags. Simon's do; many libraries will not. Each step
  says what a library without WORK tags gets.
- **Search noise:** compilations ("Best of Mozart") can slip through on a number. TIDAL is noisier. Measured in step
  0: about 2 albums in 100 kept are wrong on works the rule has not seen, and about 5 in 100 are missed (§8.2).
- **Owned albums:** WORK tags vary (movement-level, extra text). Unmatched owned works still show, under "Other
  works in your library".
- **Two filters must not collide:** the composer page reads COMPOSER-role albums for "In your library"; the
  performance-role filter (0.19.0) stays for every other page.
- **Matching is our own code.** No shared matcher sub (`_norm`, `_artistMatch`, `_albumMatches`) needs to change for
  phases 0-2, so there is no fleet port.

## 8. Step 0, measured (2026-10-03)

Simon: *"lets look to make a start on our classical plan"*. Step 0 only: nothing in the plugin changed. The scripts
are in `tools/classical/` (its README says which does what), the raw data in `sweep/classical/` (git-ignored).

### 8.1 The composer table (0a)
- **All 220 Open Opus composers have a MusicBrainz id.** 210 by full name and birth year with a single hit; Moeran by
  surname and birth year ("Ernest John Moeran"); 9 by full name alone, because Open Opus's birth year is not
  MusicBrainz's (Charpentier 1636 / 1643, Dufay, Duruflé, Gesualdo, Léonin, Alessandro Marcello, Obrecht, Ockeghem,
  Victoria). Each of those had exactly one MusicBrainz artist of that name, described as a composer. The 11 doubtful
  ones (those 10 and Pérotin, whose death year differs) checked by hand: all right. No id is used twice. 239 requests
  to the public API, under 5 minutes, once.
- **39 of the 220 have another name on MusicBrainz:** 17 in Cyrillic (Tchaikovsky, Shostakovich, Prokofiev,
  Rachmaninoff, Stravinsky, Mussorgsky ...), Armenian (Khachaturian), Greek (Xenakis), Japanese (Takemitsu),
  Hungarian order (Bartók Béla, Kodály Zoltán), "Sir" (Bax, Birtwistle, Tippett), other spellings (Fryderyk Chopin,
  Joseph Haydn, "Johann Strauss" for Johann Strauss Jr). Keyed by mbid, the table makes these a lookup, not a guess.
- **Four surnames are shared:** Bach (3), Scarlatti, Marcello, Strauss (2 each). Open Opus already marks the lesser
  ones ("Bach, C.P.E.", "Scarlatti, A.", "Marcello, A.", "Strauss Jr"); the search wording and acceptance use that
  (8.2).
- **Open Opus's own faults, to fix in our copy:** 262 work entries repeat another of the same composer word for word
  (210 groups; 18 hold a recommended work: An American in Paris, Sibelius's Pelléas et Mélisande, Bernstein's Candide
  twice each), some differ only by a wrong key (Dvořák's Violin Concerto op. 53 "in A minor" and "in C minor"), and
  well-known works are missing (Debussy's Deux arabesques, Falla's Siete canciones populares españolas). Building the
  table: drop exact repeats; keep the rest as they are.

### 8.2 The work search (0b)
- **What ran:** all 1,234 recommended works, searched on Qobuz and on TIDAL through the rig's own search menus (no
  plugin change; browse only, the MacBook Pro player): 2,468 searches, no errors, 0.8 s a search (median; 90% under
  1.2 s, slowest 5.8 s). Up to 200 results a search on Qobuz, 100 on TIDAL. The raw results are kept
  (`ws_all_<svc>.jsonl`) and judged offline, so the rule was tuned without searching again.
- **The search words, settled** (`wsearch.py`): the surname and the work's title with its catalogue number, key,
  description and nickname cut off ("bizet jeux enfants", "glinka ruslan lyudmila"). A count in figures is dropped
  ("biber rosenkranz sonaten"), one in words kept ("four seasons"). A title that is only a form adds the scoring the
  full title gives ("ravel piano concerto left hand"). A generic title ("Concerto for ...") is searched by its
  nickname when it has one and no number ("boccherini fandango"), by the form alone when the composer has three works
  of it or fewer ("stravinsky octet"), else with two scoring words ("britten serenade tenor horn"). "Passion according
  to St. John" is searched the way albums title it, "st john passion". Used: the main title for 1,160 works, the form
  alone 31, form and scoring 21, the nickname 22. The two rounds of rewording re-searched 150 works: more recordings
  kept in 202 of those 300 searches, fewer in 28.
- **The acceptance rule, settled** (`waccept.py` v15). An album holds the work when its title names the composer (a
  bare surname is the main composer of that name; "C.P.E. Bach" and "Johann Strauss" need theirs) and, in that
  composer's part of the title, gives one of: the catalogue number ("Opp. 78, 100 & 108" counts each), the type and
  number ("Symphony No. 5"), the nickname, or the title's words (any order for a generic title: "Flute and Harp
  Concerto"). A title of form words only ("Fantasia", "Piano Concerto") also needs the key, a count ("24 Preludes"),
  the composer having one work of that form, or the work being the one Open Opus recommends of that title
  ("Mendelssohn: Violin Concerto" = op. 64). A title several works share needs the key when two or more of them are
  other works (another key, number, count or opus; versions and Open Opus's repeats do not count: "Fratres"). A plural
  is the set when the set is small or "Complete" names it. Excerpts and highlights are kept and marked.

| | Qobuz | TIDAL |
|---|---|---|
| works with a recording | 1,177 of 1,234 (95%) | 1,134 (92%) |
| recordings a work, median (mean) | 21 (42.9) | 17 (27.9) |
| kept of the first 20 results, median | 14 | 10 |
| works with 20 or more recordings | 634 | 568 |
| albums kept / of them excerpts or highlights | 52,946 / 7% | 34,381 / 6% |

On at least one service: **1,179 works (96%)**; on both: 1,132 (92%). Most Qobuz albums are kept on the title's words
(34%), the catalogue number (23%) or the type and number (20%).

- **Hand check, 100 searches** (`handcheck.py`; the top 20 results of each, every album judged by eye):
  - Part 1, 35 searches, was the tuning set. Every fault it showed was fixed except other-language titles and
    "Quartet No. 3" without "String".
  - **Part 2, 65 searches the rule had not seen** (works 399 on, seed 11), judged under v14 as it stood: 768 albums
    kept, **14 wrong (1.8%)**, 8 uncertain, **37 missed (about 95% found)**, 13 excerpts not marked. 7 of the 65
    searches had a wrong album, 12 a missed one. These are the honest numbers for works the rule has not seen.
  - v15 fixed what part 2 showed. On the same 65: 775 kept, 3 wrong (0.4%), 14 missed (about 98% found), 9 excerpts
    not marked. Those 65 are no longer unseen, so on new works expect between the two.
  - **The 3 still wrong:** an album of Webern's contemporaries whose title lists "String Quartets" (taken for his
    op. 28), an organ album titled "Fantasia" (taken for Mozart's K. 397), and a "Mozart & Strauss" album's Mozart oboe
    concerto (taken for Strauss's).
  - **The 14 still missed:** another language or another version's name ("Don Carlos" x2, "Noonday Witch" x2,
    Webern in French, Liszt in Portuguese), the service's own typos ("Variations Symphonique", "chasseur meudit"), and
    a title that leaves out the instrument or the set ("Sonata in B minor" for Liszt's piano sonata x2, Enescu's
    "Sonata No. 3", Webern's "String Trios and Quartets" x2, "Quartet & Quintet").
- **Found nowhere: 55 works (4%)**, each looked at:
  - 35: no album found names the work. Rare on both services (Camargo Guarnieri x6, Charpentier's theatre music x2,
    Lassus's masses x2, Cage's HPSCHD, Dohnányi's Suite romantique), or there only inside an album titled by its other
    contents (Reich's "Early Works" for It's Gonna Rain, "Music for Queen Mary" for Purcell's March and Canzona,
    Nielsen's "Complete Piano Music" for Den Luciferiske).
  - 14: one of a numbered set that the albums do not number: J.C. Bach's op. 7 and op. 13 harpsichord concertos (4),
    C.P.E. Bach's Wq.183 symphonies (2), a J.C. Bach op. 3 symphony, Berio's Sequenza I, Glass's Symphony no. 1,
    Gubaidulina's Offertorium, Nielsen's Piacevolezza quartet, a Telemann Paris quartet, Cage's piano concerto, a
    Boccherini piano quintet.
  - 5: another spelling or language. Open Opus's "Masquerada" (albums: Masquerade), "Metastasis" (Metastaseis) and
    "Wasser Overture" (Wassermusik), Schmidt's Variations (albums use the German title), and the services' own
    "Imaginery Landscape" (Cage).
  - 1 rule gap: Lopes-Graça's "Rústica Suite No. 1", the words the other way round.

### 8.3 The library's works (0c)
- **425 works, 72 composers.** 52 composers (397 works) are in the table, found by the lookup a page makes (the name
  or an alias, an exact match first). Outside Open Opus: 18 composers, 25 works (Tárrega, Finzi, Tavener, Giuliani,
  Tansman, Barrios, Sáinz de la Maza, de Visée ...). "[traditional]" (2) is MusicBrainz's special entity; "Sir
  William Walton" (1) was not found by a quoted name or alias search (MusicBrainz has him as William Walton; the
  page's resolver has more passes than this probe).
- **The rule** (`tools/classical/wrule.py`), each library work against its composer's Open Opus works, strongest
  first: catalogue number with its sub-number (op. 37 no. 1, RV 269), catalogue number (a set, "Nocturnes, op. 9", wins
  over a sibling piece), type and number ("Symphony no. 5", "Piano Concerto No.2"), the main title equal (a count and
  articles aside: "Trois Nocturnes" = "Nocturnes, L.91"), a nickname either way ("Trout", "From the New World"), the
  Open Opus title inside the tag ("Ballet Of The Chicks ... (Pictures From An Exhibition)"). A tie goes to the weaker
  signals, then the key, "suite", shared words (an instrument the tag does not name counts against), then Open Opus's
  recommended flag. A key that disagrees never matches on title; a work type that disagrees never matches on a
  catalogue number (the library's "Violin Concerto In D Minor, Op. 4" is not Sibelius's String Quartet op. 4).
  Open Opus's search terms give other-language titles (Le Sacre du printemps, L'Oiseau de feu, Pétrouchka).
- **345 of 397 matched (87%).** Every match checked by hand: 1 wrong (Bernstein's "Anniversaries: For Felicia
  Montealegre", orchestrated, given "7 Anniversaries"; the piece is one of the Four Anniversaries).
- **The 52 left:** 26 tags name no work (Chopin "No.13 In F Sharp Major" x8, Tchaikovsky ballet numbers and movements
  x13, Saint-Saëns organ pieces x5); 7 works Open Opus lacks (Debussy's Deux arabesques, Copland's Three Latin-American
  Sketches, Falla's Siete canciones, Satie x2, Rodrigo, Shostakovich's Élégie); 6 excerpts named by their own title
  (Sabre Dance, Dance of the Blessed Spirits, Un bel dì, Voi che sapete, Primavera porteña, Bach/Gounod's Ave Maria); 5
  titles in another language than Open Opus's (The Barber of Seville, William Tell, The Thieving Magpie, A Night on the
  Bare Mountain, "Symphonie en si mineur"); 5 ambiguous (Schubert's Impromptu in E flat and Moments musicaux, two
  Ständchen, a Scarlatti sonata); 2 typos ("Le Coraire", "Monor"); 1 rule gap (Bach's "Kantate ... BWV 147", which
  Open Opus titles "Cantata no. 147" with no BWV). They are the plan's "Other works in your library".

### 8.4 What the numbers say (0d)
- **The work page can stand on one search per service** (§4.3). 96% of the recommended works have recordings on
  Qobuz or TIDAL, the median work 21 on Qobuz, a search takes about a second, and about 98 albums in 100 kept are
  right on works the rule has not seen. Step 2 asks for the full 200 (Qobuz) and 100 (TIDAL) results: two thirds of
  the works found have recordings past the first 20 results (Qobuz 793 of 1,177). The rule runs on the titles the
  search returns, with no request of its own.
- **The library half is ready** (§4.2): 87% of the library's works in Open Opus match, 1 wrong; the rest are "Other
  works in your library".
- **The composer table is ready** (§4.1): all 220 composers have their MusicBrainz id, checked.
- **Our copy of Open Opus needs fixing, and step 0 found what:** drop the 262 repeated entries; correct a misspelt
  title ("Masquerada" for Masquerade); add missing works (Deux arabesques, Siete canciones populares españolas); add
  the names albums use as search words ("Metastaseis", "Wassermusik", "Don Carlos", "The Noonday Witch"). That favours
  decision 1: ship our own corrected copy.
- **For step 2's page:** excerpts and highlights are 6-7% of what is kept and are marked, so the page can list whole
  recordings first. A work found on neither service (4%) says so.

## 9. Step 1: the composer page (planned 2026-10-03, BUILT 2026-10-07 in 0.56.50)

Simon approved it on 2026-10-07 (*"build it"*), with the switch as its own Works | Albums row (§9.4). §9.1-9.6 are the
plan as approved; §9.7 says where the build differs. Measured on 2026-10-03 where a number is given.

### 9.1 The data we ship (decision 1)
- **Our corrections, kept apart:** `tools/classical/corrections.json`. It drops repeated entries, retitles
  ("Masquerada" -> Masquerade), adds the seven missing works §8.3 found (Deux arabesques, Siete canciones
  populares españolas, Three Latin-American Sketches ...) and adds the names albums use to Open Opus's own
  `searchterms` field (Metastaseis, Wassermusik, Don Carlos, The Noonday Witch; step 2 searches with them).
- **The repeat rule, tightened:** an entry is dropped only when the composer already has one with the same words in
  the title AND the subtitle, in the same genre. §8.1's 262 compared titles alone, which would also drop real pairs:
  Bernstein's Candide is an opera (Stage) and a suite (Orchestral). So fewer than 262 go; the build prints the count.
- **The build tool:** `tools/classical/build_data.py [dump]` takes Open Opus's dump (a file, or the live
  `work/dump.json`), applies the corrections, joins each composer to its MusicBrainz id (from a committed copy of the
  step-0 table, `tools/classical/composers_mb.json`), and writes the plugin's files. It then says what changed
  against the files already in the repo: works added, removed or retitled, corrections that no longer apply. A
  composer with no id stops the build and is named; `oomap.py` maps it (one request, checked by hand). Taking a newer
  Open Opus is: run it, read the report, build the plugin.
- **The files:** `Discography/classical/composers.json` (the 220 composers by MusicBrainz id: name, years, epoch)
  and one `Discography/classical/works/<mbid>.json` per composer, already in display order (recommended first, then
  by catalogue number, then title; Open Opus's own order is alphabetical). Measured: 1.35 MB on disk, 401 KB in the
  zip (today's zip is 436 KB). The plugin reads the composer list once, and one composer's works when that page
  opens (the largest, Bach, 59 KB), kept in a small memo. Files, not the database: the data changes only with a
  build, like the plugin's images, so it needs no cache rules, no migration and no import at startup.

### 9.2 Entering the page
- In `_discographyView`, once the mbid is known (library tag, search row, link, name), the composer list is
  checked. A composer opens on the works view; anyone else gets today's page, unchanged.
- **The works view asks MusicBrainz nothing.** No release-group list, no streaming pool, no bands or collaborations:
  those belong to the album view and are fetched only when the switch opens it. What it reads: the composer's file,
  one LMS `works` query, the biography and similar artists as today. Expected: Mozart's first visit from 4.8 s
  (0.56.8, 4 MusicBrainz requests) to about the biography's time.

### 9.3 The page
```
Options
  Showing works (tap for albums)        <- the switch, 9.4
  Search for another artist
  More options                          <- Refresh only (sort does not apply to works)
Biography
  ...
Popular (14)
  Piano Concerto No. 21 in C major, K. 467
      In your library                   <- line 2: Open Opus's subtitle, then this mark
  ...
Orchestral (180)  Chamber  Keyboard  Stage  Vocal     <- only the genres the composer has
  recommended first, then by catalogue number; 30 rows, then Show more (the existing paging)
Other works in your library (n)         <- owned works Open Opus lacks (§8.3's 52)
Similar artists                         <- as today
```
- A popular work is listed under Popular and under its genre. Two rows with one title collide in Material (A2 `A
  REPEATED SEARCH-ROW NAME CARRIES INVISIBLE WORD JOINERS`); the same fix applies.
- **Owned works open the albums holding them** (LMS `albums work_id:`, playable as library albums are today). In
  step 1 the other rows are plain text; step 2 gives every work its page.

### 9.4 The switch (decision 2)
Its own row, independent of today's Albums | Singles & EPs row. Simon, 2026-10-07: *"classical works should be
independant of that, classical compostions dont do singles"*. So it goes between works and albums only:
```
Works view:   Showing works (tap for albums)
Album view:   Show works                            <- above today's Albums | Singles & EPs row, which is unchanged
```
Two flags, kept per artist like today's (`act:view:<to>`): works on/off, and today's albums/singles flag, which
the works row never touches. The album view is today's page exactly, its own row included. If this reads as messy,
the fallback is decision 2's: works only.

### 9.5 Owned marks
- One `works artist_id:<composer>` query. The composer's library id comes from the page's `artist_id`, else the
  library's MusicBrainz tag (`localArtistIdsByMbid`), else the name, as `localAlbums` finds it.
- Each library work is matched to an Open Opus work by `wrule.py`'s rule (§8.3), ported to Perl in a new
  `Classical.pm`. The port is checked against the Python: the same answer for all 425 library works.
- Several library works can name one Open Opus work (movement-level tags); the work's albums are all of theirs.
- **A library without WORK tags** (§7): no marks and no "Other works" section; the works list is unchanged. Step 2's
  album-title rule can then find owned albums by their titles, the way it judges streaming albums.

### 9.6 Tests and the live check
- New suites: the composer lookup and file loading; the page (sections, order, paging, marks, Other works, the
  switch and a stale tap); no MusicBrainz request on the works view; a non-composer page unchanged. The Perl rule
  against the Python over the 425 works. The build tool: corrections applied, an unchanged dump reports nothing, a
  changed one reports the change. Mutation-checked as usual.
- Live, on the rig: Chopin, Debussy, Vivaldi, Mozart, Bach, Shostakovich (works, marks against §8.3, the switch, cold
  time against 0.56.49); controls Max Richter, Philip Glass, Karajan unchanged.

### 9.7 As built (0.56.50, 2026-10-07)
- **The files:** `Discography/Classical.pm` (data reader, the rule's port, the library side);
  `Discography/classical/composers.json` and `classical/works/<mbid>.json` (220); the page in `Browse.pm`
  (`_worksView`, `_worksList`, `_workRow`, `_libWorkLink`, `_workAlbumRows`, `_worksToggleItem`, `_worksOff`; the
  biography block moved into `_bioSection`, shared with the artist page). Tools: `tools/classical/build_data.py`,
  `corrections.json`, `composers_mb.json`, `parity.py`, `test_build.py`.
- **Repeats dropped: 191** of 24,975 entries (the title-only count was 262). 24,790 works ship.
- **Corrections: six works added, not seven.** Shostakovich's "Élégie" is the first of Open Opus's "2 Pieces for
  String Quartet" (Elegy and Polka), so it became a search name on that work. Added: Deux arabesques, Three
  Latin-American Sketches, Siete canciones populares españolas, Sonata a la española, La belle excentrique, Croquis et
  agaceries. Search names: Metastaseis, Wassermusik, Don Carlos, The Noonday Witch, Elegy / Élégie. Retitled:
  Masquerade.
- **Size: 1.58 MB on disk, the zip 436 KB -> 921 KB** (§9.1 said about 401 KB more; one work per line, for readable
  diffs, costs a little). Work ids are not shipped: the plugin computes them as the build does (sha1 of
  mbid|title|subtitle|genre, 8 hex), which saved 80 KB.
- **Library matches: 352 of 397** (step 0: 345; the 7 more are the corrections). The Perl port gives the Python's
  answer AND reason for all 397 (`tools/fixtures/classical_parity.json`, written by `parity.py`).
- **Speed:** the rule scores only the Open Opus works that could raise one of its signals (an index; an exact
  superset, proven by the parity run both ways). Measured on this Mac: Bach (975 works, 10 library works) 0.1 s the
  first time his page opens in a server run (reading the works and working out their features), about 1 ms a library
  work after that; kept per composer while his library works are unchanged.
- **`works artist_id:` also lists works a contributor PERFORMED** (measured on the rig: Karajan's are Debussy's,
  Mussorgsky's and Ravel's), so only rows whose composer is the page's composer are kept.
- **The `official_wait` deadline covers the biography too** on the works page (the artist page waits for a bio
  without one); a page that never draws is worse than one without a bio.
- **A work's albums show the year only:** LMS's `albums work_id:` carries no album artist.
- **Refresh (More options) is the artist page's own** (clears the artist's cached lookups).
- **Tests:** `t_classical.pl` (42) and `t_works.pl` (43), 14 of 14 mutants; `test_build.py` (18). 69 suites green.

## 10. The year written, the instrumentation (Wikidata) and the work page, 2026-10-08 — BUILT in 0.56.63, not installed

Simon, on the works page (0.56.50 installed with 0.56.61): *"when showing works on composers page can we have the year
they where wrtten if thats available also its not the most attractive looking layout, what other metadata could we use
to add some details?"*, then *"if we have instrumentation use it"*. So both are shown; the layout and work-page ideas
offered alongside them (§10.5) wait for his answer.

### 10.1 Where it comes from, measured
- **Open Opus has no date.** A work carries only title, subtitle, genre, popular, recommended and search names.
- **Wikidata has both** (CC0, like Open Opus), on the items that name the composer (P86): composition date P571,
  premiere P1191, publication P577, instrumentation P870 (with quantity P1114), librettist P87, catalogue codes P528.
  Read once at BUILD time and shipped in our copy (decision 1's build tool); the page asks nothing.
- **Coverage, 8 composers matched to our lists** (Bach, Beethoven, Brahms, Chopin, Debussy, Mozart, Shostakovich,
  Vivaldi; strict join, §10.2): recommended works 121 of 174 have a year (70%), 115 instrumentation (66%), 147 one or
  the other (84%); all 3,042 works 754 a year (25%), 1,090 instrumentation (36%). Baroque thin (Vivaldi 48 of 594
  years). Premiere 45 / dedicatee 39 / duration 26 of the 174: too sparse, not shipped. Librettist 53 of 107 stage
  works: not shipped (Simon asked for the year and instrumentation).
- **All 220 composers:** see §10.4.
- **MusicBrainz** also holds composition dates on some works (composer relationship dates); not measured.

### 10.2 The join and its rules (`tools/classical/wdjoin.py`)
- Each Wikidata item is matched to an Open Opus work with the library rule (`wrule.match`), its label plus catalogue
  codes standing in for a WORK tag. **Catalogue numbers must agree** when both sides carry one (Wikidata's codes often
  come bare: "364", "320d"): a dateless K. 364 item otherwise let K. 297b's 1778 reach K. 364. Several items on one
  work: the strongest rule wins, then the one whose numbers agree.
- **The year:** precise to the year only (K. 331 is stored "1770s" beside a correct 1783 publication), within the
  composer's life from age 4 (films and productions carry P86 too: The Magic Flute 1975, 2006, 2016), composition
  date first, then premiere, then publication; the earliest of the first that has one.
- **The instrumentation:** Wikidata's names tidied ("continuo group" -> continuo, "string orchestra" / "string
  section" -> strings, "Western concert flute" -> flute, "symphony orchestra" -> orchestra, "mixed choir" -> choir),
  repeats folded, counts kept ("2 oboes"), a bare "keyboard" beside a named keyboard dropped, ensembles last (choir,
  orchestra, strings, continuo). **Left out when the title already says it all:** the instrument named in the title
  or subtitle ("Piano Sonata" + piano), or implied by its form (symphony -> orchestra; concerto -> orchestra, strings,
  continuo; string quartet / trio / quintet, piano trio / quartet / quintet, violin / cello sonata -> their
  instruments; mass, requiem, oratorio, passion, cantata, motet... -> choir, orchestra, voices, organ).
- `wrule.oo_features` is cached in `wdjoin` (pure, only read): Bach's join 63 s -> 3.6 s.

### 10.3 What changed
- **Tools:** `wdfetch.py` (new: per composer, his Wikidata item by MusicBrainz id, then every item naming him composer;
  raw answers in `sweep/classical/wikidata/`, resumable; the snapshot the build reads is
  `tools/classical/wikidata_works.json`, only items with a date, an instrumentation or a librettist). Several items can
  carry one MusicBrainz id (Debussy: Q4700, Q121316); the human with the most sitelinks is taken. The query service
  (SPARQL) was throttled to one request a minute that day, so it uses the action API, 1.5 s apart. `wdjoin.py` (new).
  `build_data.py` reads the snapshot (none: no facts, nothing else changes), writes `y` and `i` per work, counts them,
  and reports changes to them like any other field.
- **Data:** `works/<mbid>.json` rows gain `y` (the year) and `i` (the instrumentation line). Not in the work id, so a
  rebuild that adds a year keeps every id.
- **Plugin:** `Classical::works` reads them as `year` / `instr` (a year that is not 3-4 digits, or an `i` that is not
  text, is left out). `Browse::_workRow` line 2: **year · In your library · instrumentation · subtitle**. The order is
  deliberate: Material cuts line 2 at the edge, so the short year and the mark go first, ahead of the long parts (the
  mark was last in §9.3, written when line 2 held only the subtitle).
- **Tests:** `test_build.py` 18 -> 42 (the year rule, the instrumentation line, the join's catalogue check, the facts
  in the build, the report, the shipped file); `t_classical.pl` §4 (+6, a fixture data dir); `t_works.pl` (+3, line 2's
  order; the owned row's assertion now built from the work's own fields). Mutants: 8 of 8 in `wdjoin.py`, 6 of 6 in the
  plugin. 77 suites green; `syntax_check.sh` OK.

### 10.4 All 220 composers (fetched 2026-10-08, 11,897 Wikidata items; the shipped data)
- **Overall:** of 24,790 works, a year for **3,843 (16%)**, an instrumentation line for **1,357 (5%)**. Recommended
  works (1,234): a year for **745 (60%)**, a line for **167 (14%)**; popular (397): a year for 259 (65%), a line for 69 (17%).
- **CORRECTION of §10.1's "66% instrumentation":** that counted works whose Wikidata item HAS instrumentation. A line is
  shown only when the title does not already say it all (a piano sonata, a string quartet, a symphony, a mass show
  none), so the line on screen is the 14% above. The year figure holds (70% on 8 composers, 60% on all 220).
- **By epoch** (works / with a year / with a line, then the recommended ones):

  | epoch | works | year | line | recommended | year | line |
  |---|---|---|---|---|---|---|
  | Medieval | 157 | 1 (0%) | 0 | 4 | 1 (25%) | 0 |
  | Renaissance | 2,244 | 47 (2%) | 16 | 22 | 9 (40%) | 1 |
  | Baroque | 5,018 | 341 (6%) | 414 | 101 | 37 (36%) | 14 |
  | Classical | 2,065 | 460 (22%) | 131 | 88 | 53 (60%) | 3 |
  | Early Romantic | 2,254 | 375 (16%) | 88 | 90 | 55 (61%) | 7 |
  | Romantic | 3,675 | 695 (18%) | 265 | 271 | 165 (60%) | 56 |
  | Late Romantic | 3,250 | 674 (20%) | 234 | 232 | 153 (65%) | 44 |
  | 20th Century | 4,255 | 851 (20%) | 155 | 318 | 205 (64%) | 32 |
  | Post-War | 1,760 | 357 (20%) | 45 | 90 | 53 (58%) | 5 |
  | 21st Century | 112 | 42 (37%) | 9 | 18 | 14 (77%) | 3 |

  22 composers get no year at all; 9 (Léonin, Pérotin, Obrecht, Janequin, Taverner, Sweelinck, C. Stamitz, Guarnieri,
  Lopes-Graça) have no Wikidata item with a date or instrumentation. Four MusicBrainz ids carry two Wikidata items
  (Beethoven, Mahler, Mendelssohn, Schütz); the composer (most sitelinks) was picked each time.
- **Samples:** Mozart K.216 "1775 · violin, 2 oboes, 2 horns, strings"; K.467 "1785"; Vivaldi The Four Seasons "1725 ·
  violin, viola, cello, continuo"; Bach BWV 564 "1708 · organ"; Chopin Ballade no. 1 "1831 · piano"; Beethoven
  Symphony 9 "1824"; Copland Quiet City "1940".

### 10.4a The quality rules the full run added (measured over all 5,287 matched works, 2026-10-08)
The 8-composer measurement missed these; each was found in the full build's report and audited across all matches
(scratchpad `wq/audit.py`, `wq/conflict.py`) before a rule was written:
- **The title's own scoring against Wikidata's** (`wdjoin.scoring_conflict`): an item whose solo instruments
  contradict the scoring the title states is another work or another version, and is not used at all (its year
  either); the join then takes the next item. (1) the title names instruments, none is in Wikidata's list, and the
  list has one the title neither names nor implies (Marcello's harp concerto against the oboe concerto; Arnold's
  2-piano concerto against his viola concerto; Dvořák's Cypresses song cycle against the quartet set); (2) a
  complete chamber group in the title (string quartet / trio / quintet, piano trio / quartet / quintet) with more of
  Wikidata's instruments outside it than inside (Berg's "Adagio ... for string quartet" against the Adagio for violin,
  clarinet and piano; Beethoven's op. 11 trio, clarinet + cello + piano, stays). A quoted nickname is not scoring
  ("Harp" quartet); viola da gamba is the viol; a sonata naming an instrument has its keyboard. 35 items refused;
  4 are the same work with another stated scoring and lose a year (Vaughan Williams's Household Music, Ives's Universe
  Symphony, Debussy's Première Rhapsodie "for piano", Albéniz's Asturias "for guitar").
- **Labels:** Wikidata's ways of saying a known thing ("percussion guitare" is its percussion item's label, "a
  clarinet", "soprano clarinet", "vocal range", "choral music", "string instrument") tidied; labels saying nothing
  ("instrumental ensemble", "musical duo", "concertino", "ripieno", "fanfare") dropped. Strings and continuo take no
  count ("2 stringses" was shipped by the first full build). Synonyms a title uses ("English horn" for cor anglais,
  "gamba" for viol, "contrabass"). More sacred forms imply their choir/orchestra/organ (Te Deum showed only "organ").
- **More than 8 items:** a full orchestration, no line (Schnittke's Symphony no. 2 had 30).
- **Wikidata's own errors:** rarity does not find them (90 of 155 labels occur fewer than 3 times, nearly all real:
  koto, djembe, cannon). One found, The Rite of Spring's only instrument "lihua", left out by the new `wikidata`
  section of `corrections.json` (item + fields to drop; reported applied, or stale once Wikidata changes).

### 10.5 Offered 2026-10-08; Simon: *"all good for 1 - 4 we wait for 5"*
1. Cover art on owned works (the album's cover, as Material's own Works list); the work icon on the rest.
2. A summary line under the composer's name: years and epoch ("1678–1741 · Baroque · 594 works"), already shipped.
3. An "In your library" section first, with covers.
4. **The work page, LMS's way, with the Open Opus name**: the page titled by the Open Opus work; "About this work"
   (MAI `workreview work:<title> composer:<name>`, works without a library work id: 0.5-1.1 s on the rig, fetched on
   tap); "In your library" one row per album (cover, album, performers from `albums album_id:X tags:aaS`, year); a tap
   opens Material's own album page narrowed to the work's tracks by track id (`tracks album_id:X track_id:<ids>` gave
   exactly the 12 Four Seasons tracks of 21). LMS's own work page cannot stand in: its queries take ONE work id, and a
   library can tag one Open Opus work as several (The Four Seasons: 9 LMS works). Not verified: Material drawing a
   track-id-narrowed album as its native page, and "play from here" staying narrowed.
5. Whether works not held also open a page now (About only) or wait for step 2's streaming recordings. **WAITS.**

### 10.6 Items 1-4 as built (0.56.63, not installed)
1. **Covers:** an owned work (and an "Other works in your library" row) shows the cover of its first held album
   (`/music/<artwork id>/cover`, from LMS's `works` reply). A work NOT held stays a plain row with no image: Material
   turns a text row WITH an image into a tappable one (browse-resp.js: "treat as a standard actionable item", type
   "other"), whose tap would open a dead page. So "the work icon on the rest" was not built; possible only once
   those works open a page (item 5).
2. **The composer's line**, the page's first row (a prose row, the bio's indent): "1756–1791 · Classical · 555 works";
   "born 1935" when Open Opus has no death year (always true: Open Opus still lists Birtwistle, Rorem, Rihm and
   Gubaidulina as living). The count is the works listed.
3. **"In your library (N)" first**, before Popular, the owned works in the list's order, each still in its genre;
   these rows leave "In your library" off line 2 (the heading says it).
4. **The work page** (`Browse::_workPage`), opened by an owned work: "About this work" (MAI `WorkInfo::getWorkReview`
   by the Open Opus title and the composer's name, asked on tap, kept 30 days / 1 day by composer + title, a 15 s
   watchdog), then "In your library (N)", one row per album holding the work: cover, album, artist · year. A tap opens
   Material's own album page with only the work's tracks: `browselibrary items mode:tracks album_id track_id:<the
   work's tracks> work_id:-1` (measured on the rig: LMS's browselibrary and tracks both narrow to the list; work_id
   makes Material draw it as LMS's Works view, without track numbers), Play/Add the same tracks in album order
   (`playlistcontrol track_id ... work_id:-1`, so "play from here" stays on the work), every action defined + info
   (the 0.56.58 My Apps trap). Other clients: `wka:<album>:<track ids>`. The tracks come from `tracks work_id:<each
   LMS work> performance:-1` (`Classical::albumsFor`), the albums' artist from one `albums album_id:<list>` read.
   "Other works in your library" open the same page (About by the LMS work title).
- **Not verified live** (needs a build and an install): Material drawing the narrowed album page as its own, and the
  track menu's "Play release starting at track" on it; MAI's answer for Open Opus titles beyond the three measured.
