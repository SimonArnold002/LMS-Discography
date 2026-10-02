# Let a plugin mark a row as an artist

Hi Craig,

Thanks for pointing me at the SlimBrowse metadata PR (slimserver #1452) and Sven's Qobuz. This asks
for a small stopgap until #1452 lands, for servers that will never forward `metadata`.

## What I need and why

My plugin Discography has rows that open an artist page: search results, "Similar artists" and
"Also a member of". I'd like them to look like your artist rows (a round image) and the page they
open to get your artist header (the artist's photo and name at the top), as Qobuz and TIDAL
artists do.

Material only treats an app row as an artist when the row tells it so:

- `metadata.type == "artist"`, which needs #1452 (LMS 9.1.2 and 9.2 don't forward `metadata`), or
- a favourites link starting `qobuz://artist:`, `tidal://artist:`, `deezer://artist:` or
  `spotify:artist:`. LMS only forwards it on a playable row (`_favoritesParams` runs inside
  `if ($isPlayable)` in `XMLBrowser.pm`).

Sven gets the second one by adding `playlist => 'qobuz://artist:<id>'` to his artist rows, which
makes them playable. That doesn't fit Discography's rows:

- Many have no service id: an artist only in the user's library, or one only on MusicBrainz.
  "Similar artists" are names only.
- A favourites link adds "Add to favourites", which would save the service's artist rather than
  the page the row opens. Stock Qobuz turns a `qobuz://artist:` link into one broken track.

`type => 'artist'` doesn't work either. Material already reads it as a playable artist and offers
Play when the row's go action carries an `artist` or id parameter, which Discography's do (its
`artist:` parameter passes `hasPlayableId`).

## The change

A plugin sends a row of a new type, `artist-link`. Material treats it as an online artist, which
already gives it the round image (lists, grids and strips) and gives the page it opens the
artist header (`showDetailedSubtoolbar` already admits online artists through `stdItem>=STD_ITEM_MAI`).
`type` already reaches Material unchanged from XMLBrowser, so no server change is needed.

What the plugin sends:

```perl
{ name => 'Adele', type => 'artist-link', image => $photo, url => \&artistPage },
```

### `browse-resp.js`: mark the row

```diff
@@ -635,8 +635,12 @@ function parseBrowseResp(data, parent, options, cacheKey) {
                                  ( i.presetParams.favorites_url.startsWith("https:") && command=="bandcamp"))) {
                         numTracks++;
                         isOnlineTrack = true;
                     }
+                } else if ("artist-link"==i.type) {
+                    // A plugin row that opens an artist page but has nothing to play. Not "artist", as Material
+                    // offers Play on an "artist" row whose go action carries an artist or id parameter.
+                    i.stdItem = STD_ITEM_ONLINE_ARTIST;
                 } else if (parent && parent.stdItem==STD_ITEM_ONLINE_ARTIST) {
                     i.stdItem = STD_ITEM_ONLINE_ARTIST_CATEGORY;
                 }
```

It sits after the `metadata` and favourites-link checks, so a row that carries either is typed
exactly as today. It sits before the parent check, so an artist row on an online artist's page
(such as "Similar artists") stays an artist rather than becoming a category.

## Compatibility

Nothing changes unless a plugin sends `artist-link`. No other Material code reads a row's type as
`link`, so an older Material shows an `artist-link` row exactly like a `link` row: a square image
and no header. Discography checks the Material version before sending it, as it does for
`header-strip`.

Once #1452 lands, Discography can send `hasMetadata => 'artist'` instead and this type can go.
