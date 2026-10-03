# Show Discography under "Search on..." in Material's search

Hi Craig,

This is a one-line addition to `SEARCH_OTHER`.

## What I need and why

Discography registers an LMS search provider, using the same hook Qobuz, TIDAL and Spotty use:

```perl
Slim::Menu::GlobalSearch->registerInfoProvider( discography => (
    func => \&Plugins::Discography::Browse::globalSearchItem,
) );
```

Every LMS search then lists a "Discography" entry, and the entry opens Discography's artist search for
the same words. Material's search only shows the "Search on..." sources named in `SEARCH_OTHER`
(`search-field.js`), so it leaves the entry out.

Material's search already runs as you type, which makes it the natural place to jump into Discography
from. The entry costs nothing while typing:
- **The list:** the provider only builds the entry, and nothing is searched until it's tapped.
  `globalsearch items` with the entry in it answers in 0.03-0.05 s.
- **The tap:** the entry carries its own go action, `discography items search:<words>` (`itemActions`).
  It opens Discography's results page directly, with the `features:hi` your `browseBuildCommand` adds.
- **The other sources:** the entry has no `url` of its own, only a row below it, the shape Qobuz's
  entry has. So XMLBrowser still gives the list its session id, and Qobuz, TIDAL and the rest open as
  before.

## The change

```diff
@@ -10,6 +10,7 @@ const SEARCH_OTHER = {
     "band's campout":{svg:"bandcamp"},
     "bbc sounds":{svg:"bbc-sounds"},
     "deezer":{svg:"deezer"},
+    "discography":{svg:"album-multi"},
     "qobuz":{svg:"qobuz"},
     "spotty":{svg:"spotify"},
     "tidal":{svg:"tidal"},
```

The icon is your `album-multi`. Discography uses it as its own logo too (the plugin icon and its
artist-menu action), so the plugin looks the same everywhere.

## Compatibility

- **Nothing changes without the plugin.** The entry is found by its title, like the others, so a server
  without Discography lists exactly what it does today.
- **No server change.** It's only the list.

Tested on a build of master (520b19c26) with this change: Discography appears under "Search on..." as
you type and opens its results for the search.
