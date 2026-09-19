# Hosted LMS-Community API (`mai-api`) — discography spine migration

**Status:** SCOPED, UNBLOCKED, NOT STARTED. Re-benchmarked 2026-08-01. No code written.
**What it is:** `https://api.lms-community.org` — the LMS core dev's hosted MusicBrainz /
MusicArtistInfo REST API (`mai-api`). Cloudflare-cached (`max-age` 30d), ~90ms warm, **un-throttled**.
**Why it matters to DSC:** it replaces this plugin's serial, 1-req/s-throttled MusicBrainz
release-group pagination (Jamie Cullum ≈ 9 requests ≈ 10s; Radiohead ≈ 21 ≈ 23s — see the request-
budget section in CLAUDE.md) with a **single cached HTTP call**.

Verified with live HTTP calls against the running service and read against this plugin's source
(`API.pm` / `Browse.pm` / `Sources.pm`).

---

## 0. Two hard requirements before any call is written

1. **`X-LMS-Plugin-ID` header is MANDATORY on every call** (dev's explicit request) — the calling
   plugin's package name, guarded (`apiHeaders` is a new `Slim::Utils::Misc` helper that may not exist
   on older LMS):

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
   `Authorization` header + graceful 401/403 fallback later. Don't scatter the base URL.

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

The hosted DB rebuilds **weekly** today (dev is building daily incremental updates, WIP). That's a
real gap for a *new-release* plugin like LBF (which must keep an MB fallback), but **DSC is
catalogue-oriented**, so weekly — soon daily — is fine and needs no live-MB fallback for the newest
tail. (Benchmark: even future-dated releases already appear, because MusicBrainz pre-announces them.)

---

## 3. What the hosted API does NOT replace

- **Prose bio** — the `/biography` and bare `/artist/<name>` endpoints are **link directories**, not
  prose (dev confirmed prose bio will NOT be added). Keep MusicArtistInfo `getBiography`.
- **"Also a member of"** — needs MB "member of band"; the API's `relatedArtists` is last.fm-similar.
- The **streaming resolver / matcher** — unaffected; this is metadata only.

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
