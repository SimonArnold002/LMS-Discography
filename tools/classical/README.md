# Classical: the measurements (step 0) and the shipped data (step 1)

## Step 1: the data the plugin ships (plan §9.1, decision 1)

| script / file | what it does |
|---|---|
| `build_data.py [dump]` | Open Opus's dump + `corrections.json` + `composers_mb.json` -> `Discography/classical/` (composers.json, works/<mbid>.json in display order), then reports what changed against the files in the repo. `--check` writes nothing. A dump is a file, a URL (`https://api.openopus.org/work/dump.json`) or, by default, `sweep/classical/work_dump.json`. |
| `corrections.json` | our corrections, kept apart from Open Opus's data: retitle, search names, added works; and `wikidata`, a field of one Wikidata item left out (by Q id) when Wikidata has it wrong. One that no longer applies is named in the report. |
| `composers_mb.json` | each Open Opus composer's MusicBrainz id (step 0's table, checked by hand). A new composer stops the build: map it with `oomap.py`, check it, add it here. |
| `parity.py` | the Perl port's reference answers: `wrule.match` over the library's WORK tags against the shipped files -> `tools/fixtures/classical_parity.json`, which `tools/t_classical.pl` checks. Run after a build. |
| `test_build.py` | the build tool's own check, on a small made-up dump; and the Wikidata join's rules. |
| `wdfetch.py [MBID ...] [--again]` | Wikidata's facts about each composer's works (plan §10): his item by MusicBrainz id, every item naming him composer, their dates, instrumentation, librettist and catalogue codes. Raw answers in `sweep/classical/wikidata/` (resumable); writes the snapshot `wikidata_works.json`. Public action API, 1.5 s apart, no e-mail in the User-Agent. About an hour for all 220. |
| `wikidata_works.json` | the snapshot `build_data.py` reads: per composer, the Wikidata items carrying a date, an instrumentation or a librettist. Absent: the build ships no years or instrumentation and says so. |
| `wdjoin.py` | the join (used by `build_data.py`): each Wikidata item to an Open Opus work by `wrule.match`, catalogue numbers agreeing, and no item whose instruments contradict the title's own scoring (`scoring_conflict`); the year (year-precise, within the composer's life, composition then premiere then publication); the instrumentation line (tidied, counts, ensembles last, at most 8 items, left out when the title says it). Writes `y` and `i` on the work. |

Taking a newer Open Opus: `python3 build_data.py URL`, read the report, run `parity.py`, `test_build.py` and the
suites, then build the plugin.

Taking newer Wikidata facts: `python3 wdfetch.py --again`, then `python3 build_data.py`; the report lists every
year and instrumentation that changed.

## Step 0: the measurements

Step 0 of `docs/classical-plan.md` (§5): measure before any page changes. Results are in that
doc's §8. These scripts produce them; raw data goes to `sweep/classical/` (git-ignored), or
wherever `CLASSICAL_DATA` points.

Read-only everywhere: public MusicBrainz at 1.15 s a request with a contact-free User-Agent,
the Open Opus dump (public domain), and the rig's own Qobuz and TIDAL menus over HTTP
(browse only; the "MacBook Pro" player unless `DSC_PLAYER` says otherwise; `DSC_HOST`,
default `plex:9000`).

| step | script | what it does | output |
|---|---|---|---|
| 0a | `oomap.py` | Open Opus's 220 composers -> MusicBrainz ids, by full name + birth year, then the short name, then the full name alone (always doubtful) | `oomap.jsonl` |
| 0c | `libmap.py` | the library's composers (LMS `works`) -> MusicBrainz ids, the way a page resolves a name | `lms_works.json`, `libmap.json` |
| 0c | `libmatch.py` | each library WORK tag -> an Open Opus work of its composer (`wrule.py`) | `libmatch.json` |
| 0b | `wsearch.py all 0 qobuz` / `... tidal` | the service album search for every recommended work, raw results kept (resumable) | `ws_all_<svc>.jsonl` |
| 0b | `report.py` | what the search finds once `waccept.py` judges each album | stdout |
| 0b | `handcheck.py N [seed] [first]` | a seeded sample for checking by hand (from work `first` on): kept albums, and dropped ones that look close | stdout |

- `wrule.py`: library tag -> Open Opus work. Signals, strongest first: catalogue number with
  its sub-number, catalogue number (the set entry wins over a sibling piece), type + number,
  main title equal, nickname, Open Opus title inside the tag; ties go to the weaker signals,
  the key, "suite", shared words, then Open Opus's recommended flag. Also `work_head()`, the one
  reading of a work's title both other scripts use: no catalogue number (lower or upper case,
  "JW III/9", "A.209", "G.xiv"), key, description ("tone poem", "ballet", ", for ..."), nickname or
  colon part; a head of form words and instruments keeps its scoring ("Concerto for Flute and
  Harp", "Concerto in D minor for 3 Harpsichords" -> "concerto for 3 harpsichords"); an apostrophe
  inside a word ("L'elisir d'amore") is not a quote.
- `waccept.py`: does an album hold a work? The composer must be named (a bare surname is the
  main composer of that name; "C.P.E. Bach", "Johann Strauss" need theirs), unless the title
  phrase is one only this composer uses. Then catalogue number ("Opp. 78, 100 & 108" counts each;
  "op. 71a" = "op. 71 a"), type + number, nickname, a generic head and its scoring in any order
  ("Flute and Harp Concerto"; "Serenade for Tenor" when no other work has both words; the form
  alone when it is the composer's only one), title words, and for a title of form words only
  ("Fantasia", "Piano Concerto"): the key, a count ("24 Preludes"), or being the composer's only
  work of that form, or being the one Open Opus recommends of that title ("Mendelssohn: Violin
  Concerto" = op. 64; never a collection like songs or dances, and never one of more than three
  works of that title). A title several works share needs the key when at least two of them are
  other works (another key, number, count or opus); suites, versions and Open Opus's repeated
  entries do not count ("Der Rosenkavalier", "Fratres"). When another work of the composer has a
  longer title holding this one's, that longer title is taken out of the album title first, so an
  album of it does not count for this work. A count must agree with the scoring ("Concerto for 2
  Pianos" is not the one for 3). A plural is the set when the set is small or "Complete ..." names
  the work's instrument. Excerpts and highlights are flagged, not dropped. v15; tuned on hand-check
  part 1, measured on part 2 (plan §8.2).
- `wsearch.py`: the search words. Surname + `work_head()` with a count in figures dropped
  ("biber rosenkranz sonaten", "glinka ruslan lyudmila"); a generic head with two of its scoring
  words ("bartok concerto orchestra", "britten serenade tenor horn"), or the form alone when the
  composer has three works of it or fewer ("stravinsky octet"), or its nickname when it has no
  number ("boccherini fandango"); a head of form words only, its nickname or the scoring the full
  title gives ("ravel piano concerto left hand"); "Passion according to St. John" as "st john passion".
