# Round artist images and Material's artist header — plan

**Status (2026-10-02): ROUTE B BUILT in 0.56.29, INSTALLED with Material 6.4.10.9 and CHECKED LIVE** (Simon: header
with the bio first, no Play entry, the home page under the header all fine). Craig merged the PR the same day (#1276,
upstream b652e87b1). Route A below was not built and is kept for reference only.

## Goal

The rows that open an artist page show a round image, and the page they open gets Material's
artist header (the photo and name at the top), as Qobuz and TIDAL artists do. (Since 0.56.33 Options sits above the bio, Simon's order.) The bio stays first
on the page and nothing else on the page changes.

The rows: search result tiles (Top Result, Artists), the MusicBrainz same-name rows, Also a
member of, Similar artists.

## How Material decides (read in the live 6.4.10.8 bundle and upstream master)

- Material types a row from the row itself. On a plugin page it has two ways to know it's an
  artist: `metadata.type == "artist"` (needs slimserver #1452, stalled; LMS 9.1.2 never sends
  it), or a favourites link starting `qobuz://artist:`, `tidal://artist:`, `deezer://artist:` or
  `spotify:artist:` (`browse-resp.js`).
- LMS 9.1 forwards a row's favourites link only when the row is playable: `play`, `playlist`, or
  type `audio`/`playlist` (`XMLBrowser.pm`, `_favoritesParams` inside `if ($isPlayable)`).
- A row typed as an online artist gets the round image (`circular`) in lists, grids and strips.
- The page it opens gets the header at any width of 350 px or more: `showDetailedSubtoolbar`
  admits `stdItem>=STD_ITEM_MAI` (200) and an online artist is 300. The `wide>=WIDE_COVER` clause
  next to it is redundant for online artists. The header photo has square corners; only list and
  tile images are drawn round.
- `type => 'artist'` on our rows is NOT an option: Material offers Play on an `artist` row whose
  go action carries `artist`/an id (`hasPlayableId`), and ours do (`artist:Adele`, live).

Our release tiles already use this: they are playable and carry `qobuz://album:<id>` (measured on
Sam Smith's page, live), so Material already types them as streaming albums.

## Route A: Sven's approach (Qobuz 30.7.3.6, `_artistItem`)

He sends `type => 'artist'`, `favorites_url => 'qobuz://artist:<id>'` and `playlist =>` the same
link. The `playlist` line is only there to make LMS pass the link through (his own comment). His
Qobuz can play that link (the artist's top tracks); the stock Qobuz 3.7.2 can't: its
`explodePlaylist` turns it into one broken track.

### What a Discography row would send

`favorites_url => '<svc>://artist:<id>'`, `playlist =>` the same link, and **`type => 'link'` kept**,
so Material adds no Play entry (its play block only runs for `artist`, `album`, `playlist`,
`audio`...). Everything else on the row (name, image, itemActions, url) is unchanged. A row with
no id stays exactly as today.

### Where the service artist id comes from (no new requests)

1. **The search page's service searches.** `Sources::_artistHits` reads each Qobuz/TIDAL/Deezer
   artist hit and keeps only the name and photo; keep `id` too. Used only when the row's name is
   unique: a split owned act or a MusicBrainz same-name row must not take a name hit, which may
   be the wrong act.
2. **The artist page.** For each service, `_resolveArtist` already picks the service artist that
   matches MusicBrainz's release list, the most reliable id we have. Record it, keyed by the
   page's MusicBrainz id. Rows look it up from the cache while the page draws (never a request),
   by mbid (band and same-name rows) or by name through `API::peekArtistMbid` (search and similar
   rows).

So a search result tile is round on the first search when its name is unique, and any artist row
is round once that artist's page has been opened once.

### Which service

TIDAL first: the TIDAL plugin plays the artist's top tracks from `tidal://artist:<id>`, so a saved
favourite works. Qobuz only when the installed Qobuz can play the link (Sven's, version 30 and
up); with the stock Qobuz the row stays as today. Deezer and Spotify: not on the rig, unverified,
left out.

### Side effects

- **"Add to favourites"** appears on every row that carries the link (Material offers it on any
  row with a favourites link). It saves the TIDAL/Qobuz artist, not our page; opening it plays
  that artist's top tracks.
- **Pages opened from our artist page also get the header.** Material marks rows with no link of
  their own on an online artist's page as "artist category" rows. Our option rows carry Material
  icon names, not images, so the header falls back to the artist's photo. Read more, a section's
  More, and Search for an artist (our home page) would all open under the artist's header, as
  pages under a Qobuz artist do. Taps go where they go now. Release tiles carry their own album
  link, so release pages are unaffected. The home page under an artist's header is the one to
  look at live.
- **The header only shows when the page was opened from one of our round rows.** Opened from
  Material's own Discography action on a library artist, or from LBF or PFR, it has no header.
- **One strip can mix round and square** until each artist has an id.
- **Default skin and old controllers** see a playable row; playing it plays the TIDAL top tracks.

### Optional stage: ids for rows never opened

Similar artists and Also a member of only get an id once their page has been opened. If the mix
of round and square matters, the rows still without an id can be looked up after the visit, the
way `Covers.pm` fetches covers: one service artist search per row, keep only an exact-name single
hit, round on the next visit. Not worth building if route B is accepted, since B rounds every row
without an id.

## Route B: the `artist-link` type (if Craig takes the PR)

Send `type => 'artist-link'` on every artist row, gated like `header-strip`: on a Material that
ships it and a client that draws headers (`$useH`), so Default skin and old controllers keep
`link`. No id, no favourites entry, every row round. The pages opened from our artist page get
the header exactly as in route A. Route A's links can then go, or stay for older Material.
Decide when the release exists.

## Tests and checks

- **Suite:**
  - A row with an id carries the link and `playlist` and stays `type => 'link'`; a row without one
    is unchanged.
  - A shared-name row never takes a name hit.
  - The id store is written from `_resolveArtist` and only read from the cache while drawing.
  - TIDAL is preferred; a stock-Qobuz-only install sends no Qobuz link.
  - Each rule is anti-tested by mutation.
- **Live, on the phone:**
  1. Search Adele: the result tiles are round.
  2. Open it: Material's artist header shows the photo and name, with the bio first below.
  3. Similar artists turn round after their pages have been opened.
  4. No Play on artist rows.
  5. Add to favourites on a row, then open the favourite: TIDAL top tracks.
  6. Release pages are unchanged.

## Related follow-up (not this work)

DONE in 0.56.28: `Browse::_useStrips` accepts Material 6.4.11 and later, where the tile strips ship.
