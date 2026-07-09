# Material emblem patch — service badges on plugin-feed rows

`material-deferred.min.js` in this folder is the server's stock bundle
(fetched from http://plex:9000, Material with PR #1235, 2026-07-09) plus ONE
inserted statement. **A Material update reverts it — re-apply after every
Material upgrade** (re-fetch the new bundle, re-run the insertion below, or
re-run the python snippet in CLAUDE.md's 0.4.2 log entry).

## What it does
Stock Material only draws the corner service badge (emblem) on LIBRARY items
(`extid` → `getEmblem()`); plugin-feed (`item_loop`) rows never get one — the
Now Playing logo is a third, separate mechanism (`getTrackSource`, playing
track's URL scheme, NP screen only).

The patch adds a post-pass at the top of `browseHandleListResponse()` (in
`browse-functions.js`, part of the deferred bundle): any item that carries a
`presetParams.favorites_url` with a service scheme (`qobuz://`, `tidal://`,
`deezer://`, …) gets `item.emblem = getEmblem(<scheme>)`. `file`/`http(s)` are
excluded; unknown schemes miss the emblem map and draw nothing. Zero effect on
items that already have an emblem or no favurl.

Any plugin whose rows set `favorites_url` benefits: Discography (tiles +
detail version rows), and the LBF / Pitchfork Reviews / Listen Later feeds.

## Unminified equivalent (for the upstream PR — a generic capability ask)
```js
// browse-functions.js, top of browseHandleListResponse(view, item, command, resp, prevPage, appendItems)
if (resp && resp.items && "function"==typeof getEmblem) {
    for (var i=0, len=resp.items.length; i<len; ++i) {
        var it = resp.items[i];
        if (it && undefined==it.emblem && it.presetParams && it.presetParams.favorites_url) {
            var m = /^([a-z0-9]+):\/\//.exec(it.presetParams.favorites_url);
            if (m && "file"!==m[1] && "http"!==m[1] && "https"!==m[1]) {
                it.emblem = getEmblem(m[1]);
            }
        }
    }
}
```
(Craig left a commented-out emblem-from-URL variant inside `getEmblem` itself —
frame the upstream ask around that.)

## Deploy (Simon runs; server path per fleet notes)
```bash
sudo cp /var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins/MaterialSkin/HTML/material/html/js/material-deferred.min.js \
        /var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins/MaterialSkin/HTML/material/html/js/material-deferred.min.js.stock
sudo cp material-deferred.min.js \
        /var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins/MaterialSkin/HTML/material/html/js/material-deferred.min.js
```
No LMS restart needed; hard-refresh the Material tab (the bundle is cached
with the Material version as cache-buster, so a normal reload may serve the
old one).
