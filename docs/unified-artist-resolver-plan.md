# One artist resolver — plan (rewritten 2026-09-25)

Status: PLAN, no code changed. The previous version (four evidence tiers, streaming-evidence ranking, renaming the page after it opened) went
beyond the brief and is withdrawn; a copy is in the session scratchpad only.

## The brief (Simon, 2026-09-25)

"All we want is one universal resolver that maintains all current features but fixes the issues with aliases,
displays in English and uses canonical names." Plus the decisions already made:

- the owned-album check runs every time there is more than one candidate, tag or no tag ("we need to
  disambiguate all the time");
- the alias query always runs;
- streaming is searched canonical first, then aliases;
- English spellings, not Cyrillic etc., where MusicBrainz has an English name;
- reuse existing mechanisms (the Kraftwerk alias matching, the Madness candidate handling);
- every feature must work on public MusicBrainz (no mirror-only behaviour);
- classical is out of scope.

## What the code does today (read 2026-09-25, 0.56.0 working tree)

There are two engines, and they disagree:

| path | code | how it picks |
|---|---|---|
| **Artist link** (Artists row, Material menu, similar artist, Search Hub hand-off) | `Browse::_resolveArtistMbid` :1541 → `API::getArtistMbid` :589 | library tag if present; else `_artistMbidByName` :692 (quoted `artist:` field, exact-name preference, then alias field ONLY if the name field found nothing, then unquoted, then joint-credit split; zero-release hit held as last resort). Owned-album check (`_disambiguateByLibrary` :1616) runs ONLY when the tag has 0 release groups |
| **Search list** | `Browse::_withMbCandidates` :3544 → `API::searchArtistCandidates` :2094 → `_mbFirstRows` :3651 | `artist:"X" OR alias:"X"`, name-or-alias equal, **sorted by MB score** |
| search row filter | `API::filterRowsWithContent` :1702 / :1711 | `getArtistMbid` (speculative), i.e. the link engine |
| search second service pass | Browse.pm :3506 / :3511 | `searchArtistCandidates` top, else `getArtistMbid` |

Also read, and NOT resolvers (they answer "does another act share this exact name?"):
`getArtistCandidates` :1953, used by the shared-name guard (`_sharesDecision` :1204) and the `$ambig` flag
(Browse.pm :1211). Unchanged by this plan, except that the ranker below reads it.

## The issues, measured on the mirror (all 1,117 library album artists + test names)

1. **Aliases, link path.** An obscure act literally named the query beats the famous alias act:
   ELO → Korean singer, PIL → Danish "Pil", NIN, EBTG, REM → "Rem". Search finds Electric Light Orchestra;
   the link path does not. OMD, KLF, BTO etc. already work (no act is literally named that, so the alias
   pass runs).
2. **Aliases, search path (0.56.0 regression).** Sorting name-or-alias hits by score lets aliases outrank the
   real act: Luna → DJ Luna, Tennis → DJ Tennis, James → Harry James, Love → =LOVE, Alfie → THE ALFEE,
   Bob → B.o.B (31 library names differ from today's pick). The combined query also re-scores name-equal
   acts (HAIM → Haïm), so its order cannot replace the name-field order.
3. **Display.** An MB-only search row shows MB's name: 米津玄師, Кино. MB has an English name for exactly
   these (primary alias, locale `en`, carried inline on every search hit, so no extra request): Kenshi Yonezu,
   Kino. Latin-script names (Sigur Rós, Björk, Bush) have none and are unchanged.
4. **Canonical name, streaming.** `_resolveArtist` (Sources.pm :2578) searches the browsed name first and MB's
   canonical only as a retry (Browse.pm :1232). Canonical first was measured better: ELO under "Electric Light
   Orchestra" = 21 titles, under "ELO" = 0.

## The design: one ranker, one resolver, both built from what exists

### 1. One ranked candidate list (`API::rankArtistCandidates(name, cb)`), used by both paths

- **Name tier** = `getArtistCandidates` (exists: `artist:` field, name-equal, cached 14d), in its own order.
  This is the order the link path's exact-name preference already follows.
- **Alias tier** = the alias-only hits of `searchArtistCandidates` (exists, cached 14d), after the name tier.
- **Initialism rule** (the one new rule, measured): an alias-tier act whose name's initials spell the query
  moves above the name tier when the combined query scores it above every name-tier act; not when the act's
  own name is single letters (B.o.B). Measured: fixes ELO, NIN, EBTG, PIL, REM; leaves ABC, TLC, GnR, SFA, OMD,
  KLF as today; **0 changes** across the 1,117 library artists.
- Both requests are ones the search already makes and caches; the link path adds at most one cached request
  per new name.

### 2. One resolver (`getArtistMbid`, extended in place; every caller already uses it)

1. Library tag, as today.
2. No tag: `_artistMbidByName` exactly as today (all its passes kept: alias field, unquoted, joint credit,
   zero-release hold, speculative limits, mirror→public fallback), **then**, if the ranked list's top is an
   initialism-lifted alias act, that act instead. Nothing else changes the name-search answer.
3. **Owned-album check** (the artist page AND every library row in search; not service rows, which stay
   speculative): when the ranked list plus the tag hold
   more than one act and the user owns albums by this artist, run the existing `_disambiguateByLibrary`
   weighting over them (its `_matchWeight`, `DISAMBIG_MIN_WEIGHT`, strictly-greater, `DISAMBIG_MAX`). The
   current pick is the incumbent and is replaced only by an act that out-weighs it. Today's zero-release-tag
   case is this check with the tag scoring 0.

### 3. Search list: library evidence first

Order, top to bottom:
1. **Acts the library holds** (0.48.4 "Local trumps", unchanged): a library row joined to its MB act by tag
   (`_ident_mbid`) or by the resolver's answer (`_mbid`), and an MB-only row the library holds by tag
   (`localArtistsByMbid`). The resolver that stamps a library row's `_mbid` now includes the owned-album check
   (§2.3), so an untagged owned act is joined to the act its albums match, and the list puts first the same act
   the page opens.
2. **Name-equal acts**, in name-field order.
3. **Alias-only acts** (with the initialism lift, §1).
4. Rows MB does not list.

`_mbFirstRows` takes steps 2 and 3 from `rankArtistCandidates` instead of the score sort; step 1 is its
existing owned-first sort. Everything else stays as it is: the joins (`_ident_mbid` / `_mbid`), the rows MB
does not list, the release-count drop, and the second service pass (it now names the ranked top, so search
and link agree).

### 4. English display

An MB-only row (`_mbCandidateRow` :3745) shows, and opens with, the English primary alias when MB has one,
else MB's name, as today. The page opens under the name the row shows, so nothing is renamed after opening.
Rows joined to a library or service row keep their own name (0.46.5 / 0.48.2 rules). Library-linked pages
keep the library name. The `locale`/`primary` fields are kept from the search response `searchArtistCandidates`
already parses (today it keeps alias names only).

### 5. Canonical first on the streaming services

The service search order becomes: English name (if any) → MB canonical → browsed name → other aliases,
through the existing `_resolveArtist` retry and spine check (unchanged limits: `ALIAS_MAX`, `WEAK_RETRY_MAX`,
`SPINE_STRONG`). The spine check is what rejects a wrong English hit (Kino finds other acts; the check moves
on to Кино). The streaming pool's cache key stays the browsed name (`Sources::_candKey`), so only the first
query changes, not the key. Outside name lookups get the ASCII spelling via `_svcQueryName` (0.49.2), as the
search second pass already does.

### 6. Same material whichever name opened the page (Simon, 2026-09-25)

"As long as they show the same material, it is fine for library to show by its spelling." So a page opened
from the library ("米津玄師", or "British Sea Power") and one opened from an English search row ("Kenshi
Yonezu", "Sea Power") must list the same releases, matches and extras for the same mbid. The name on screen
may differ; nothing else may. What reads the page's name today, and what makes each one name-independent:

| reads the name | code | how it is made the same |
|---|---|---|
| streaming search | `$go` Browse.pm :1217 | the first query is English/canonical by mbid (section 5), not the browsed name |
| matcher artist gate | `$artistNorm` Browse.pm :2241, `claimedLocalIds` :2521 | accepts the MB name or any MB alias as well as the browsed name (the `_aliasMatches` shape, for artists) |
| bio | `_fetchArtistBio` :1302 | fetched by mbid plus the MB name, cache keyed by mbid |
| similar artists | `_warmArtistExtras` :1323 | already cached by mbid; fetched by the MB name |
| shared-name guard | `sharesNameWithProminentAsync` :1298, :2089, :4219 | unchanged: it asks about the name a name-keyed lookup would use, which is now the MB name |
| library albums | `localAlbums` | unchanged: `artist_id`, then MB tag, then name, so the library route already finds its own albums |

Stage 7 gains a check: for every library artist whose library name differs from MB's (English) name, render
the page both ways and diff the release and match lists. Any difference is a failure.

## What stays exactly as it is

Band links by mbid; the shared-name guard and `$ambig` (exact-name questions); the Kraftwerk title/alias
matching (`_aliasMatches`, Sources.pm :3344); the release-count drop; the row filter's speculative limits for
SERVICE rows; `_identParams` / toggles / Refresh (no name changes after opening); `localAlbums`; cache keys
other than those listed below. (The bio and similar artists change only in which name they are fetched by,
section 6.)

## Carriers to change

| where | change |
|---|---|
| `API::rankArtistCandidates` (new) | name tier + alias tier + initialism rule |
| `API::searchArtistCandidates` :2094 | keep English primary alias per hit (`en_name`); cache key `dsc:asrchcand:1` → `:2` |
| `API::getArtistMbid` :589 / `_artistMbidByName` :692 | initialism override after the name search |
| `Browse::_resolveArtistMbid` :1541 | owned-album check whenever >1 act, not only on a 0-release tag |
| `Browse::_disambiguateByLibrary` :1616 | candidate set = ranked list (+ tag); incumbent = current pick |
| `Browse::_withMbCandidates` :3605, :3506 | ranked order for the list and the second pass |
| `API::filterRowsWithContent` :1702 (library rows only) | resolve with the owned-album check, so `_mbid` joins the owned act (§3) |
| `Browse::_mbCandidateRow` :3745 | English label + `artist` param |
| Browse.pm `$go` :1217 → `Sources::getCandidates` :886 | first query = English/canonical; browsed name moves into the retry list |
| matcher artist gate, Browse.pm :2241 / :2521 | also accepts the MB name and MB aliases (section 6) |
| `_fetchArtistBio` / `_warmArtistExtras` | fetch by the MB name, bio cache keyed by mbid (section 6) |
| `dsc:mbid` (`MBID_CACHE_V`) | bump: an initialism name cached under today's pick must re-resolve |

## Cost (delta over today)

- Link path, new name: +1 MB search (the combined query), cached 14d; the search already pays it.
- Owned-album check (page, and library rows in search): one release-group fetch per other candidate (≤ `DISAMBIG_MAX`), cached 14d, only for an
  artist the user owns that shares a name or alias with another act. Same fetches today's disambiguation makes.
- Streaming: no extra searches; the order changes, the retry limits do not.

## Stages (each gated by the existing suites, run before and after)

1. `rankArtistCandidates` + `en_name`: t_mbcands, t_mbfirst (Luna/James/Tennis list the real act first),
   t_searchrank, new fixtures ELO/PIL/NIN/EBTG/REM and ABC/TLC/GnR/Bob unchanged.
2. Resolver initialism override: t_resolve, t_alias, t_loose, t_credit, t_zerorg, t_thelas, t_bees.
3. Owned-album check always: t_bees, t_zerorg + new: a tagged owned act is not displaced by a coincidental
   single title.
4. Search list + second pass on the ranked order, library rows resolved with the owned-album check:
   t_mbfirst (an untagged owned act listed first and joined to the act its albums match), t_lone, t_fold,
   t_verdict, t_perf.
5. English label: t_mbname, t_canon, t_view (toggles on a page opened from an English-labelled row).
6. Canonical-first streaming: t_weak, t_svcname, t_worksbest, t_perf (request counts).
7. Same-material diff (section 6) for every library artist whose name differs from MB's. Re-run the 1,117-artist comparison through the real Perl engine; list every pick that changed with its
   reason. Then docs (ledger, dev log) and ask to build.

## Live check after install

ELO, PIL, NIN (famous act, both paths) · OMD, KLF, BTO, ABC, TLC (unchanged) · Luna, James, Tennis (real act
first in search) · Madness, Bush, Hawkwind (unchanged) · Kenshi Yonezu, Кино shown as Kino (English labels,
streaming found) · British Sea Power (Sea Power on Qobuz) · The Bees (tag heal still works) ·
Radiohead (no extra requests on a warm cache).

## Settled

Display (Simon, 2026-09-25): an MB-only search row shows MB's English name when MB has one; library-linked
pages keep the library's spelling, provided they show the same material (section 6). Nothing is renamed
after a page opens.
