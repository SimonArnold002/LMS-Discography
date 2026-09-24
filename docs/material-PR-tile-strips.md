# Let a plugin show a row of tiles on a list page

Hi Craig,

I'd like a plugin page to mix text rows and tiles, the way your search results already do.

## What I need and why

My plugin Discography shows an artist's full discography. One artist page looks like this:

```
Biography            <- text
Albums (24)          <- header
  [tile] [tile] [tile] ...
EPs (6)              <- header
  [tile] [tile] ...
Also a member of     <- header
  The Band           <- ordinary row
```

A plugin page is either all list or all grid. One text row, like the biography, turns the grid
off for the whole page (`browse-resp.js`, the `types.has("text")` check), so every album shows
as a list row with a small thumbnail. If I drop the text, the whole page becomes a grid,
including rows that should stay rows.

Search already does exactly what I want. Its page is a list, and each section of tiles is one
list item holding the tiles, which the `grid-scroll` template draws as a strip that scrolls
sideways. Text rows sit happily between the strips. But only `buildSearchResp` can build that
item, so a plugin has no way to ask for it.

## The change

A plugin sends a header of a new type, `header-strip`. Material puts the items after it, up to
the next header, into one strip, using the existing search template. `type` already reaches
Material unchanged from XMLBrowser, so no server change is needed.

What the plugin sends:

```perl
{ name => 'Albums (24)', type => 'header-strip', url => \&allAlbums },  # the header
{ name => 'Abbey Road', type => 'playlist', image => $cover, url => ... },
{ name => 'Let It Be',  type => 'playlist', image => $cover, url => ... },
{ name => 'EPs (6)',    type => 'header-strip', url => \&allEps },
...
```

A header with an action already gets your **More** link, so it can open the full set as a grid
on its own page.

### 1. `browse-resp.js`: mark the header

```diff
                     if (i.type=="header") {
                         i.header = true;
                         resp.numHeaders++;
                     } else if (i.type=="header-basic") {
                         i.header = true;
                         resp.numHeaders++;
                         i.actions = undefined;
+                    } else if (i.type=="header-strip") {
+                        i.header = true;
+                        i.stripHeader = true;
+                        resp.numHeaders++;
+                        resp.haveStrips = true;
                     }
```

### 2. `browse-resp.js`: gather the items after it into a strip

After the item loop, next to the other grid checks. It only folds when the first batch holds the
whole list, judged by the count LMS sent (a plugin page normally does, as it is fetched in one
batch). `data.result.count` isn't used because the item loop lowers it for skipped items, and a
count of -1 (unknown) never folds. Otherwise the items stay as plain rows, so a later batch can't
start at the wrong offset or split a strip from its header.

```diff
+           // Fold only when this response holds the whole list: a later batch would start at the wrong offset
+           // and could carry a strip's tiles without its header. Past one batch the items stay as plain rows.
+           // Uses LMS's own count: data.result.count is reduced for skipped items, and -1 means unknown.
+           if (resp.haveStrips && 0==startIndex && origCount>=0 && origCount<=data.result.item_loop.length) {
+               let items = [];
+               let rowOf = []; // original position -> row after folding (a tile maps to its strip's row)
+               let stripHeader = undefined;
+               let strip = undefined;
+               for (let i=0, loop=resp.items, len=loop.length; i<len; ++i) {
+                   let itm = loop[i];
+                   if (itm.header) {
+                       stripHeader = itm.stripHeader ? i : undefined;
+                       strip = undefined;
+                       items.push(itm);
+                   } else if (undefined!=stripHeader) {
+                       if (undefined==strip) { // added with its first tile, so an empty strip never becomes a row
+                           strip = {id:"strip."+stripHeader, strip:true, items:[]};
+                           items.push(strip);
+                       }
+                       strip.items.push(itm);
+                   } else {
+                       items.push(itm);
+                   }
+                   rowOf.push(items.length-1);
+               }
+               let folded = resp.items.length - items.length;
+               resp.items = items;
+               // listSize counts every item LMS sent, but a strip's tiles are now one row. Without this the
+               // list looks unfinished, so scrolling fetches (and appends) items it already has.
+               resp.listSize -= folded;
+               // The item count shown in the subtitle is taken from the rows, so add the folded tiles back.
+               resp.foldedItems = folded;
+               // Jumplist positions were recorded against the unfolded items.
+               for (let j=0, loop=resp.jumplist, len=loop.length; j<len; ++j) {
+                   let pos = loop[j].index - startIndex;
+                   if (pos>=0 && pos<rowOf.length) {
+                       loop[j].index = startIndex + rowOf[pos];
+                   }
+               }
+               resp.canUseGrid = false; // the page is a list; the strips are its tiles
+           }
             if (1==resp.items.length && 'text'==resp.items[0].type && 'itemNoAction'==resp.items[0].style && msgIsEmpty(resp.items[0].title)) {
```

And the subtitle's item count, which is taken from the rows, adds the folded tiles back:

```diff
-                    let itemCount = startIndex + (resp.items.length-((categories.size>1 ? categories.size : 0) + resp.numHeaders));
+                    let itemCount = startIndex + (resp.items.length-((categories.size>1 ? categories.size : 0) + resp.numHeaders)) +
+                                    (undefined==resp.foldedItems ? 0 : resp.foldedItems);
```

### 3. `browse-page.js`: draw a plugin strip with the search template

```diff
-    <v-list-tile v-else-if="undefined!=item.searchcat && undefined!=item.items" class="grid-scroll list-grid icon-only" ...
+    <v-list-tile v-else-if="(undefined!=item.searchcat || item.strip) && undefined!=item.items" class="grid-scroll list-grid icon-only" ...
```

### 4. `browse-page.js`: keep a page with strips out of the virtual scroller

The virtual scroller has no strip template. Search avoids it because its first item always has
`searchcat`. A plugin page usually starts with something else, such as a text row.

```diff
         useRecyclerForLists() {
-            return !this.isTop && this.items.length>LMS_MAX_NON_SCROLLER_ITEMS && undefined==this.items[0].searchcat
+            return !this.isTop && this.items.length>LMS_MAX_NON_SCROLLER_ITEMS && undefined==this.items[0].searchcat &&
+                   !this.items.some(itm => itm.strip)
         },
```

### 5. `search-list.js`: let "Search list" find tiles inside a strip

It already looks inside grouped rows, but only when the first row has `searchcat`.

```diff
-        if (this.view.items.length>0 && undefined!=this.view.items[0].searchcat) {
+        if (this.view.items.length>0 && (undefined!=this.view.items[0].searchcat || this.view.items.some(itm => itm.strip))) {
```

## Compatibility

Nothing changes unless a plugin sends `header-strip`. An older Material doesn't recognise the
type, so the header shows as an ordinary row rather than a header, and its items as ordinary rows
below it. A plugin should only send `header-strip` to a Material that supports it, and send
`header` otherwise. Discography checks the Material version before sending it.
