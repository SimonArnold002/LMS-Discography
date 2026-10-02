# Let a plugin's custom action open an artist page

Hi Craig,

Thanks for merging #1276. This is a small follow-up for the one place it can't reach.

## What I need and why

Since #1276, Discography's artist rows (search results, "Similar artists", "Also a member of") are
`artist-link` rows. They're round, and the page they open gets your artist header.

Discography also registers a custom action on the artist menu, so a library artist can be opened in
it from Library > Artists:

```perl
Plugins::MaterialSkin::Plugin::registerCustomAction('artist', {
    title     => 'Discography',
    icon      => 'album',
    lmsbrowse => {
        command => [ 'discography', 'items' ],
        params  => [ 'artist_id:$ARTISTID', 'artist:$TITLE', 'menu:discography', 'features:hi' ],
    },
});
```

A page opened from that action never gets the header. Both places that open a custom action's page
(`currentAction` and `itemCustomAction` in `browse-page.js`) give `fetchItems` only an id and a title.
`showDetailedSubtoolbar` reads `stdItem` and the image from that item, so the page has neither, and
nothing a plugin sends in its response can add them. The same artist therefore looks different
depending on whether it was opened from search or from the library.

## The change

An `lmsbrowse` action can say that the page it opens is an artist's page, with `"type":"artist"`:

```perl
lmsbrowse => {
    command => [ 'discography', 'items' ],
    params  => [ 'artist_id:$ARTISTID', 'artist:$TITLE', 'menu:discography', 'features:hi' ],
    type    => 'artist',
},
```

Material then opens the page as an online artist (`STD_ITEM_ONLINE_ARTIST`) with the artist's image,
exactly as a page opened from an `artist-link` row. The image is the image of the item the action was
run on. From the menu on Material's own artist page, it's the item's image or, failing that, the page's
current image (the photo in that page's own header).

### `customactions.js`: one helper

```diff
@@ -210,6 +210,18 @@ function doReplacements(string, player, item) {
     return val;
 }
 
+// A plugin's lmsbrowse action can ask for the page it opens to be an online artist's page ("type":"artist"
+// in its lmsbrowse), so the page gets the artist header and image as one opened from an "artist-link" row does.
+function customActionPage(action, page, image) {
+    if (action.lmsbrowse && "artist"==action.lmsbrowse.type) {
+        page.stdItem = STD_ITEM_ONLINE_ARTIST;
+        if (undefined!=image) {
+            page.image = image;
+        }
+    }
+    return page;
+}
+
 function doCustomAction(action, player, item) {
```

### `browse-page.js`: the two places a custom action opens its page

```diff
@@ -1421,7 +1421,7 @@ var lmsBrowse = Vue.component("lms-browse", {
             } else if (act.custom) {
                 let browseCmd = performCustomAction(act, this.$store.state.player, item);
                 if (undefined!=browseCmd) {
-                    this.fetchItems(browseCmd, {cancache:false, id:"currentaction:"+index, title:act.title+SEPARATOR+item.title});
+                    this.fetchItems(browseCmd, customActionPage(act, {cancache:false, id:"currentaction:"+index, title:act.title+SEPARATOR+item.title}, item.image ? item.image : this.currentImage));
                 }
@@ -1452,7 +1452,7 @@ var lmsBrowse = Vue.component("lms-browse", {
         itemCustomAction(act, item, index) {
             let browseCmd = performCustomAction(act, this.$store.state.player, item);
             if (undefined!=browseCmd) {
-                this.fetchItems(browseCmd, {cancache:false, id:"itemCustomAction:"+item.id+"-"+index, title:act.title+SEPARATOR+item.title});
+                this.fetchItems(browseCmd, customActionPage(act, {cancache:false, id:"itemCustomAction:"+item.id+"-"+index, title:act.title+SEPARATOR+item.title}, item.image));
             }
         },
```

## Compatibility

- **Only opt-in actions change.** Nothing changes unless an action carries `"type":"artist"`; every other
  custom action, from a plugin or a user's `actions.json`, opens exactly as today.
- **No server change.** `registerCustomAction` already serves the whole action object, so the new field
  reaches the client unchanged.
- **Safe on older versions.** An older Material ignores the field, so Discography can send it without
  checking the Material version.

Tested on a build of master (b652e87b1) with this change: opening a library artist in Discography from
Library > Artists now shows the artist header, as it does from Discography's own search.
