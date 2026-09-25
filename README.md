# Discography — LMS Plugin

A plugin for **Lyrion Music Server (LMS)** that shows an artist's **complete discography**, not just the albums you own. Every album, EP, single, compilation and live album listed in **MusicBrainz**, grouped by type with artwork and original release dates, and each release playable from your **local library** or your streaming service (**Qobuz**, **Tidal** or **Deezer**).

Tested on LMS 9.x with the **Material Skin**.

---

## Features at a glance

| Feature | What it gives you | Needs |
|---|---|---|
| **The whole discography** | Every release MusicBrainz lists for the artist, not just what's in your library | Nothing |
| **Grouped by type** | Albums, EPs, Singles, Compilations, Live albums and Other releases, each in its own section | Nothing |
| **Plays from where you have it** | Each release plays from your library if you own it, otherwise from the first streaming service that has it | A streaming plugin, for albums you don't own |
| **You choose the order** | Rank your library and each service; set one to 0 to never use it | Nothing |
| **Every version** | A release page lists your library copy and each service's versions (deluxe, remaster and so on), so you pick which to play | Nothing |
| **Only what you can play** | Releases you can't play from anywhere are hidden, so a huge discography stays usable. Turn it off to see everything | Nothing |
| **Nothing you own goes missing** | *Also in your library* lists your albums by the artist that MusicBrainz doesn't | Nothing |
| **Bootlegs left out** | Unofficial releases are filtered out, while official live albums stay | Nothing |
| **Artist context** | A biography, *Also a member of*, *Collaborations* and *Similar artists*, each a link to that artist's discography | Music and Artist Information plugin, for the biography and similar artists |
| **Reviews** | A release page shows the album's review where one is available | Music and Artist Information plugin |
| **Search any artist** | Find an artist across your library and your streaming services, even one you own nothing by | Nothing |
| **Artist context menu** | *Discography* on any artist's "…" menu | Material Skin 6.4.6+ |
| **Your own MusicBrainz mirror** | Uses a MusicBrainz mirror on the same machine automatically, for fast, un-throttled lookups | A musicbrainz-docker mirror (optional) |

---

## Requirements

- **Lyrion Music Server 9.0.0+**.
- **Material Skin 6.4.6 or later** for the *Discography* entry on the artist menu. Without it, the plugin is still under **My Apps**.
- **The Music and Artist Information plugin, enabled.** It comes with LMS and is on by default. Discography needs it for biographies, reviews, artist photos and similar artists; with it turned off, those parts of the plugin don't work.
- To play releases you don't own: the **Qobuz**, **Tidal**, **Deezer** and/or **Spotty** (Spotify) plugin, installed and signed in. Playing from Spotify needs a Premium account.

The streaming services are optional. A service that isn't installed is simply skipped.

---

## Installation

Add this repository URL under **Settings → Plugins → Additional repositories**:

```
https://simonarnold002.github.io/LMS-Discography/repo.xml
```

Then install **Discography** from the plugin list and restart the server. If Material Skin is open, reload it so the artist menu picks up the new entry.

---

## Using it

### Opening a discography

- **From an artist**: on any artist in Material Skin, open the "…" menu and choose **Discography**.
- **From the plugin**: open **My Apps → Discography** and search for an artist. Results come from your library and your streaming services, so you can open an artist you own nothing by.

The first visit to an artist takes a few seconds while the discography is fetched. After that it's cached, and a repeat visit is instant.

### The discography page

- **Sections by type.** Albums, EPs, Singles, Compilations, Live albums and Other releases, each listed by original release date. The **Sorted by** row switches between newest and oldest first. Long sections show 30 releases at a time, with **Show more**.
- **Tap a release to play it**, from the first source in your priority order that has it. Streaming service badges appear on the artwork once a release has been matched.
- **Options** at the top: **Show only what you own** narrows the page to your library, and **Refresh discography** fetches the artist again.
- **Also in your library** lists your albums by this artist that MusicBrainz doesn't list, so nothing you own is missing. **Appearances** lists albums you own where the artist is a guest rather than the main credit.
- **Also a member of**, **Collaborations** and **Similar artists** each open that artist's own discography.
- **Other artists with this name** appears when MusicBrainz has several artists with the same name, so you can switch to the right one.

### A release page

Tap into a release to see:

- **Its versions.** The preferred version is shown first; **Show other versions** lists every match, from your library and from each service.
- **Its review**, where one is available, with **Read more** for the full text.
- **View on MusicBrainz**, and the release's other links.

---

## Settings reference

Open **Settings → Plugins → Discography**.

| Setting | Default | What it does |
|---|---|---|
| Source priority | Library 1, Qobuz 2, Tidal 3, Deezer 4, Spotify 5 | The order sources are tried for playback and listed on a release page. 0 turns a source off. Each shows whether its plugin is installed |
| Default sort | Newest first | The starting order of each section. The *Sorted by* row changes it for the visit |
| Release types | All | Which type sections to show |
| Hide releases you can't play | On | Hides releases that are neither in your library nor on a streaming service. Doesn't affect *Also in your library* or *Also on streaming* |
| Artist biography | On | A biography at the top of the page. Any text on a page turns off Material's grid view, so turn this off if you prefer tiles |
| Also in your library | On | Your albums by the artist that MusicBrainz doesn't list |
| Also on streaming | Off | Streaming albums MusicBrainz doesn't list. **Unverified**: a service that files several same-name acts under one artist will show their records here too |
| Always show all versions | Off | A release page lists every version, grouped by service, instead of the preferred one first |
| Material Skin artist menu entry | On | Adds *Discography* to the artist "…" menu. Changing it needs a server restart and a reload of Material |
| MusicBrainz server | Blank (auto-detect) | Blank finds a musicbrainz-docker mirror on this machine (port 5000) and otherwise uses the public MusicBrainz API. Or enter your own mirror's address |
| Debug logging | Off | Writes matching decisions to server.log, for diagnosing a missed match |

---

## Notes & limitations

- **Streaming services: Qobuz, Tidal, Deezer and Spotify (through the Spotty plugin).** Bandcamp isn't supported.
- **If Spotify stops answering, releases stay visible.** Spotty reports a signed-out or lapsed account, a Spotify outage and "no albums" the same way, so Discography never treats an empty answer from Spotify as "not on Spotify". It asks again an hour later.
- **Spotify doesn't supply artist photos.** Photos come from Music and Artist Information and the other services.
- **The first visit to a big artist is slower.** The public MusicBrainz API allows one request a second, so an artist with hundreds of releases takes several seconds to fetch the first time. A local MusicBrainz mirror removes the wait.
- **The discography is only as complete as MusicBrainz.** An artist MusicBrainz doesn't know shows *Couldn't identify this artist on MusicBrainz*; albums it doesn't list appear under *Also in your library*, or *Also on streaming* if you turn that on.
- **Classical music is a weak spot.** MusicBrainz mixes composer and performer credits, so a classical artist's page can be muddled.
- **Duplicate artists on a streaming service stay separate.** If a service lists *Beatles* and *The Beatles* as two artists, search shows both.
- **Cover art comes from the Cover Art Archive.** A release with no cover there may show a placeholder.
