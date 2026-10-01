# Hosted LMS-Community API (`mai-api`) — discography spine migration

> **2026-09-25: the working plan is now `docs/community-api-and-resolver-plan.md`.** This file is kept for its design detail and measurements.


**Status:** ON HOLD (Simon, 2026-09-25) until Herger's side ships. He is away for a few weeks. We sent him THREE requests (the list is in `docs/community-api-forum-post.bbcode.txt`). (1) Release-group ALIASES on each `/discography` entry (replaces our `inc=aliases` MusicBrainz call): AGREED. (2) Release TITLES in the `?withReleases=1` releases map (lets us drop the up-to-40-page MusicBrainz release browse): expected. (3) The unknown-mbid comment: RETRACTED by Simon 2026-09-25. He is happy with the usage we described. The mbid check is ours to handle (below). No code written then. **Update 2026-09-29 (stage 2, `docs/mb-efficiency-and-community-api-analysis.md` §A11):** the release browse is gone anyway: the bootleg map, release map and edition titles now come from a MusicBrainz search BY ID for the page's groups (at most 6 requests). So (2) would save those by-id requests for first-credited groups, not a 40-page browse. And (1) can replace the `inc=aliases` browse only if second-credited groups get another source (§F.4): that browse is MusicBrainz's only complete list of them. Aliases were still absent on 2026-09-29 (Kraftwerk). **Update 2026-09-30 (night):** the code now calls the service for two things, through one path (`_netGet`'s `hosted` bucket and `_hostedHeaders`, §0 below): release counts (stage 3, 0.56.3) and, by name, the search results no shared MusicBrainz search answers (stage 3b, 0.56.5; show/hide and merges only). The spine migration this file describes is still not started.

**The `?mbid=` rule (verified live 2026-09-25):** a mbid the API knows overrides the name completely (name "Radiohead" + the horrorcore Madness' mbid returns him). An UNKNOWN mbid (merged-away or mis-tagged) falls back to the name and returns the most popular artist of that name, and a dummy name cannot switch that off. So: always send the mbid when we have one, and treat a reply whose top-level `mbid` differs from the one sent as a miss -> normal MusicBrainz artist path. LBF's `_hostedDiscoMap` lacks this check today (its `getArtistAliases` has it); add it when this work resumes.

**MEASURED 2026-09-25 — `/discography` lists ONLY groups where the artist is named FIRST in the credit.**
Willie Nelson (668fd73c): MusicBrainz `release-group?artist=` browse = 489 groups, hosted = 423. All 67 missing
groups credit Willie SECOND or later ("Merle Haggard & Willie Nelson", "Waylon Jennings & Willie Nelson",
"... feat. Willie Nelson"); 0 missing where he is first or solo. They include 11 studio albums (Pancho & Lefty,
The Winning Hand, Seashores of Old Mexico), 24 compilations, 23 singles, 5 live. Matched by TITLE too, 60 of the
67 are absent; the other 7 only share a title with a different group (hosted "Pancho and Lefty" is the 1982
SINGLE, 34146cb9; the Merle Haggard & Willie Nelson ALBUM is the one missing). **Not contradicted by MAI:** MAI's
Discography menu comes from DISCOGS (`Discogs::getDiscography` -> api.discogs.com `artists/<id>/releases`, read in
MAI master 2026-09-25); its MusicBrainz discography is commented out, and it does not call hosted `/discography`. The Beatles: 1050 vs 1039
(not broken down). **CORRECTION (same day, checked on the rig): the CURRENT build does not show them either.** Willie Nelson's
page on 0.55.0 (99 rows, fetched in full) has none of Pancho & Lefty, The Winning Hand, Seashores of Old
Mexico, Augusta, Together Again, VH1 Storytellers, Live Highwaymen. So the swap loses nothing the page shows
today; the claim that it would was mine, untested. The `releases` map and any count taken from `/discography` have the
same hole. **No NEW requests to Herger (Simon, 2026-09-25: "Stop asking for things"); the two pending ones (aliases, release titles) stand.** Not the same as
the A2 entry `A COLLABORATION CAN MISS ON THE SECOND-NAMED` — that is a streaming copy failing to match; this
is the MusicBrainz group itself missing.

**What it is:** `https://api.lms-community.org` — the LMS core dev's hosted MusicBrainz /
MusicArtistInfo REST API (`mai-api`). Cloudflare-cached (`max-age` 30d), ~90ms warm. The dev
publishes **no rate limit**, so the fleet sets its own from how MAI uses the service (§0.3): no fixed gap
like MusicBrainz's 1.1 s, but one request at a time and a shared backoff on a 429.
**Why it matters to DSC:** it replaces this plugin's serial, 1-req/s-throttled MusicBrainz
release-group pagination (Jamie Cullum ≈ 9 requests ≈ 10s; Radiohead ≈ 21 ≈ 23s — see the request-
budget section in CLAUDE.md) with a **single cached HTTP call**.

Verified with live HTTP calls against the running service and read against this plugin's source
(`API.pm` / `Browse.pm` / `Sources.pm`).

---

## 0. Three hard requirements before any call is written

**Built for the first call, 2026-09-30 (stage 3 step 2, the release counts; analysis §A12.6):** all three
live in `API::_netGet`'s `hosted` bucket and `API::_hostedHeaders`, the one path to this service.

1. **`X-LMS-Plugin-ID` header is MANDATORY on every call** (dev's explicit request: this is how a plugin
   registers itself with the service) — the calling plugin's package name, guarded (`apiHeaders` is a
   new `Slim::Utils::Misc` helper that may not exist on older LMS). Read in the LMS 9.1 source
   (2026-09-30): `apiHeaders($module)` returns `X-LMS-Plugin-ID => $module`, plus `X-LMS-ID` (the server
   id) when the Analytics plugin is enabled; on its early-startup error path it returns a HASHREF rather
   than a list, so `my %headers = apiHeaders(...)` would then send no plugin id at all. Discography's
   `_hostedHeaders` takes either shape and always sends the plugin id (`Plugins::Discography::Plugin`):

   ```perl
   # from Plugin.pm:
   my %headers = Slim::Utils::Misc->can('apiHeaders')
       ? Slim::Utils::Misc::apiHeaders(__PACKAGE__)
       : ('X-LMS-Plugin-ID' => __PACKAGE__);
   $http->get($apiUrl, %headers);

   # from API.pm / Sources.pm (not the Plugin package) — derive it once:
   use constant PLUGIN_PACKAGE => __PACKAGE__ =~ s/\b(?:\w+)$/Plugin/r;
   # ...then apiHeaders(PLUGIN_PACKAGE) with the same guard.
   ```

2. **Auth may be added later** (dev heads-up; currently open). Funnel EVERY hosted call through **one
   request helper** in `API.pm` that adds the header now and has a slot for a token/key pref +
   `Authorization` header + graceful 401/403 fallback later. Don't scatter the base URL. (Discography:
   `_netGet` with the `hosted` bucket; the base URL is `HOSTED_BASE_URL`; the auth slot is marked in
   `_hostedHeaders`.)

3. **OUR OWN RATE LIMIT, set from how MAI uses the service** (the fleet rule; LBF ledger A2
   `ONE MUSICBRAINZ QUEUE, ONE COMMUNITY-API QUEUE`, Simon 2026-09-14: "we just cannot go over its
   rate"). The dev publishes none, and MAI (his own plugin) sends one request at a time, synchronously,
   so its round trip is the pacing and a 429 backs it off 5 s, doubling to 30. So: **ONE request in
   flight for the whole plugin, no concurrency, no fixed gap, and a SHARED 429 deadline, 5 s doubling to
   30, that only ever moves outward.** Measured 2026-09-30 that the rule is needed as it stands: one
   request at a time with no gap drew 429s after about 57 requests in 16 s (ledger A3
   `COMMUNITY API DOES REFUSE`). Discography's one difference from LBF is what a REFUSED request does
   next, never the rate: a count has MusicBrainz behind it, so it is sent `failFast` and, while the
   deadline is in force, is not sent at all and asks MusicBrainz instead (LBF, with no such fallback for
   some calls, waits the deadline out and retries a bounded number of times). A timeout backs the bucket
   off too (30 s), which is stricter than LBF.

---

## 1. The migration — `/discography` is now the whole spine

**Previously blocked** because `/discography` returned only `{mbid, title, cover}`. As of 2026-08-01
the dev **inlined the fields DSC needs**, so one call now yields the full grouped/chronological/
bootleg-filtered discography:

- **Plain** `GET /music/artist/<name>/discography` entries =
  `{mbid, title, cover, primary_type, secondary_types, release_date}`.
  → powers grouping (`_groupOf`, `Browse.pm:86`) + chronological sort + year labels directly.
- **`?withReleases=1`** adds `status` ("guessed from the releases") + `releases` = `{release-mbid:
  status}` map. Slight perf hit (dev made it optional) but negligible client-side and CF-cached 30d.
- **`?type=<Primary>`** server-side filter (Album/EP/Single/Broadcast/Other — PRIMARY only;
  `type=Live`→0 because Live is a *secondary* type; no comma multi-value). DSC groups client-side, so
  this is optional for us.

**DSC MUST call it with `?withReleases=1`.** Reason: an official live album AND a live bootleg both
carry `secondary_types:[Live]`, so `secondary_types` alone can't tell them apart — only `status`
separates "hide this bootleg" from "keep this official live album". The `releases` map even handles
the mixed case (keep the RG if any release is Official). This is the bootleg-noise filter DSC has
always had to approximate (verified: every Zappa "date: venue" live bootleg returns `status:Bootleg`,
real studio albums `Official`; the plain typeless list is 408 entries for Zappa, mostly this noise).

### The swap
Replace `getReleaseGroups`' serial MB pagination (`API.pm:375`; the field map at `API.pm:412-415`)
with **one `GET /discography?withReleases=1`**, mapping:

| hosted field | DSC field |
|---|---|
| `primary_type` | `type` |
| `secondary_types` | `secondary` |
| `release_date` | `date` |
| `status` (+ `releases` map) | bootleg gate |

**Everything downstream stays unchanged** if we map to DSC's existing `{mbid,title,cover,type,
secondary,date}` shape + a bootleg gate: `Browse.pm` `_groupOf` / `_buildList`, and `Sources.pm`'s
co-credit artist-gate (`Sources.pm:477`) don't move.

### Keep the library-tag disambiguation
`/artist/<name>/mbid` picks by popularity, which would fail same-name cases. DSC already resolves the
browsed artist by their **local library MBID** (`getArtistMbid` / `_artistMbidByName`, `API.pm:181` /
`API.pm:216`). Keep that, and pass the resolved MBID via **`?mbid=`** on the discography call — the
override propagates (verified: UK Nirvana `9282c8b4…` returns its own releases, not the grunge band's).

---

## 2. Freshness — fine for DSC (unlike LBF)

**Updated 2026-10-01 (Simon): the data is updated DAILY now; there is no weekly lag.** Cloudflare still caches
each reply up to 30 days (`max-age=2592000`), so a cached reply can be older than the data behind it.
*Was:* The hosted DB rebuilds **weekly** today (dev is building daily incremental updates, WIP). That's a
real gap for a *new-release* plugin like LBF (which must keep an MB fallback), but **DSC is
catalogue-oriented**, so weekly — soon daily — is fine and needs no live-MB fallback for the newest
tail. (Benchmark: even future-dated releases already appear, because MusicBrainz pre-announces them.)

---

## 3. What the hosted API does NOT replace

- **Prose bio** — the `/biography` and bare `/artist/<name>` endpoints are **link directories**, not
  prose (dev confirmed prose bio will NOT be added). Keep MusicArtistInfo `getBiography`.
- **"Also a member of"** — needs MB "member of band"; the API's `relatedArtists` is last.fm-similar.
- The **streaming resolver / matcher** — unaffected; this is metadata only.
- **Name -> artist (`_artistMbidByName`, `getArtistCandidates`, the search list).** The hosted routes answer
  a NAME with ONE guess (`name`, `mbid`, `aliases` only — no score, no description, no second candidate).
  Measured 2026-09-24, 22 field names: 4 confidently WRONG (The Las -> The Las Vegas Boneheads, Rossini ->
  Rossini Quartet, ...), re-checked live 2026-09-25. A wrong guess cannot be caught, so a miss-only
  MusicBrainz fallback does not help. Stays on MusicBrainz: page opens by name, the "every act called X"
  search list, and which act a search row is. Once the mbid is known, everything keyed by it can move.
  (Ledger §A3: `safe drop-in for `_artistMbidByName``.) *Since 0.56.5 its one guess decides whether a search
  result that no shared MusicBrainz search answers is SHOWN, and merges it into a shown act. Which act a tap opens is
  still MusicBrainz's; only an answer MusicBrainz proves is handed to the page (ledger A2 `STAGE 3b CHANGED FOUR
  BEHAVIOURS ON PURPOSE`).*
- **Collaboration links (`warmCollaborations`)** — MusicBrainz `artist-rels`; no hosted route.
- **External links on a release page (`getReleaseGroupUrls`)** — release-group `url-rels`; the hosted
  `/album/<title>/<artist>` links are keyed by title and a RELEASE id, not safe as an identity.
- **Second-named releases** — `/discography` lists only groups where the artist is FIRST in the credit
  (measured 2026-09-25, top of this file).

**This section was incomplete until 2026-09-25** (it listed only the first three rows), which is why checks
of the API against the code kept coming back clean. Check against the CODE's MusicBrainz calls, not this list.

---

## 4. Phases

1. **Phase 2 (the prize):** the discography-spine swap above. Now unblocked.
2. **Phase 1 (additive, anytime):** `/artist/*/picture`, `/album/*/cover`, `/album/*/genres`,
   `/artist/*/aliases`, and the link directory (DSC currently surfaces only Wikipedia). Note
   `/album/<t>/<a>/mbid` returns a **release** id, not our release-group id — display only, not an
   identity match.

Follow the usual gates (`perl -c`, the `tools/` triage chain), version + cache bumps
([dev-builds-clear-caches], version-scoped Cache namespace), and the fleet rules (no matcher change
here, so `matcher_sync_check.py` is N/A). No git commit without explicit OK.
