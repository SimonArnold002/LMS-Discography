package Plugins::Discography::Browse;

# Browse feeds for the Discography plugin.
#
# Step 2 (current): the real discography list — MusicBrainz release-groups in
# original-release-date order (newest/oldest toggle at the top of the view,
# fleet convention), Cover Art Archive tiles, and a per-release detail page
# with the MusicBrainz metadata + weblink. Step 3 adds source resolution
# (local library + Qobuz/Tidal/Deezer) and playback.
#
# String rule: NO non-ASCII literals in output strings (no `use utf8` in the
# fleet — a literal em dash double-encodes to mojibake). Use \x{..} escapes,
# which are proper Perl characters (same as LBF's tiles).

use strict;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Cache;
use Slim::Utils::PluginManager;
use Slim::Schema;

use Plugins::Discography::API;
use Plugins::Discography::Sources;

my $log   = Slim::Utils::Log->logger('plugin.discography');
my $prefs = preferences('plugin.discography');
my $cache = Slim::Utils::Cache->new();

use constant REVIEW_FOUND_TTL => 30 * 86400;
use constant REVIEW_EMPTY_TTL =>  1 * 86400;
use constant REVIEW_SUMMARY_CHARS => 380;   # summary cut point (word boundary)

use constant BIO_FOUND_TTL => 30 * 86400;
use constant BIO_EMPTY_TTL =>  1 * 86400;

# Plugin-shipped images. The *_MTL_icon_<name>.png convention makes Material
# swap in its themed '<name>' icon (icon-mapping.js); the PNG itself is the
# fallback for other skins.
use constant IMG_BASE     => 'plugins/Discography/html/images/';
use constant ICON         => IMG_BASE . 'DiscographyIcon_svg.png';
use constant MENU_SORT    => IMG_BASE . 'dsc-sort_MTL_icon_sort.png';
use constant MENU_REFRESH => IMG_BASE . 'dsc-refresh_MTL_icon_refresh.png';
# Detail-page rows: prose (type 'text') must stay IMAGE-LESS — Material
# mutates text+image items to type "other" (browse-resp.js:800), which loses
# the full-wrap prose rendering (0.7.2 regression: clamped review summary,
# broken view). Only LINK rows get thumb-slot icons; flush-left prose is the
# fleet-standard look (LBF detail pages do the same, deliberately).
use constant MENU_REVIEW  => IMG_BASE . 'dsc-review_MTL_icon_rate_review.png';
use constant MENU_WEBLINK => IMG_BASE . 'dsc-link_MTL_icon_launch.png';

# Secondary types NEVER shown (variant noise, not discography entries). Live
# is deliberately NOT here — it's its own selectable section now.
my %HIDE_SECONDARY = map { $_ => 1 } ('Remix', 'DJ-mix');

# Section order for the grouped view (fixed, independent of the date sort).
# MB primary types map: Album->ALBUMS, EP->EPS, Single->SINGLES; a secondary
# "Compilation" or "Live" wins over the primary; Broadcast/Other/untyped ->
# OTHER. Which sections actually show is the show_types pref (CSV of keys).
# Icons are Material's OWN release-type set, referenced via the MTL_svg_<name>
# image-name convention (icon-mapping.js maps it to the named built-in svg;
# the placeholder .png only exists so non-Material skins don't 404).
my @GROUP_ORDER = (
    [ ALBUMS       => 'PLUGIN_DISCOGRAPHY_ALBUMS',       'release-album'  ],
    [ EPS          => 'PLUGIN_DISCOGRAPHY_EPS',          'release-ep'     ],
    [ SINGLES      => 'PLUGIN_DISCOGRAPHY_SINGLES',      'release-single' ],
    [ COMPILATIONS => 'PLUGIN_DISCOGRAPHY_COMPILATIONS', 'album-multi'    ],
    [ LIVE         => 'PLUGIN_DISCOGRAPHY_LIVE',         'release-live'   ],
    [ OTHER        => 'PLUGIN_DISCOGRAPHY_OTHER',        'release'        ],
);

sub _groupOf {
    my ($rg) = @_;
    return 'COMPILATIONS' if grep { $_ eq 'Compilation' } @{ $rg->{secondary} };
    return 'LIVE'         if grep { $_ eq 'Live' }        @{ $rg->{secondary} };
    my $t = $rg->{type} || '';
    return 'ALBUMS'  if $t eq 'Album';
    return 'EPS'     if $t eq 'EP';
    return 'SINGLES' if $t eq 'Single';
    return 'OTHER';
}

sub _shownTypes {
    my %show = map { uc($_) => 1 } split /\s*,\s*/, ($prefs->get('show_types') // '');
    return \%show;
}

# True when the client advertises the "header" item type ('h' in features) —
# LBF's convention. Material sends features:hi on drill commands itself; the
# custom-action entry carries it because we put it in the action's params.
sub _wantHeaders {
    my ($features) = @_;
    return (defined $features && $features =~ /h/) ? 1 : 0;
}

# Which header type to emit for a header-capable client (LBF's port):
# 'header-basic' (Material >= 6.4.3) is a non-actionable full-width divider;
# older Material only has 'header', which is drawn bold BUT gets a forced
# drill action — so header items always carry a url to their own section.
my $_headerTypeCache;
sub _headerType {
    return $_headerTypeCache if defined $_headerTypeCache;
    my $ver = eval { Plugins::MaterialSkin::Plugin->getPluginVersion() };
    my $useBasic;
    if (!defined $ver) {
        $useBasic = 0;
    } elsif ($ver =~ /^(\d+)\.(\d+)\.(\d+)/) {
        $useBasic = ( $1 <=> 6 || $2 <=> 4 || $3 <=> 3 ) >= 0 ? 1 : 0;
    } else {
        $useBasic = 1;   # dev/test build -> assume new type
    }
    return $_headerTypeCache = $useBasic ? 'header-basic' : 'header';
}

sub _dbg {
    my ($msg) = @_;
    if ($prefs->get('debug_log')) { $log->error("dsc[dbg]: $msg") }
    else                          { $log->info("dsc: $msg") }
}

# Material substitutes $VARS in the custom action's params from the tapped
# item; a $VAR the item doesn't carry arrives as the literal token. Treat those
# (and empties) as absent.
sub _cleanParam {
    my ($v) = @_;
    return undef unless defined $v && length $v;
    return undef if $v =~ /^\$/;
    return $v;
}

# XMLBrowser drill-ins re-run the TOP feed with only item_id:<path> — the
# lmsbrowse entry params (artist_id/artist) are NOT echoed back by Material,
# and with cachetime=>0 there is no server-side session tree either (verified
# live: the drill request carried just item_id + menu, and the paramless
# re-run served the Apps-hint page, so every click landed on a dead text row).
# Fix: stash the entry context per player; a paramless call rebuilds the same
# view (deterministic order, data served from the API cache) so the item_id
# walk resolves. Known limit: one artist per player at a time — jumping back
# to an older artist's still-open view after opening another artist's walks
# the newer tree.
my %lastCtx;
sub _cid { my ($client) = @_; return $client ? $client->id : '_none' }

sub topLevel {
    my ($client, $callback, $args) = @_;

    my $params   = ref $args->{params} eq 'HASH' ? $args->{params} : {};
    my $artistId = _cleanParam($params->{artist_id});
    my $artist   = _cleanParam($params->{artist});

    # artist_id is the reliable key (Material fills $ARTISTID from the item
    # id); the DB name beats the $TITLE fallback whenever we have it.
    if ($artistId) {
        my $contributor = eval { Slim::Schema->find('Contributor', $artistId) };
        $artist = $contributor->name if $contributor && $contributor->name;
    }

    # features comes on the entry (from the custom action) and on drills (from
    # Material's browseBuildCommand); stash it with the artist context so any
    # rebuild renders the SAME tree shape either way.
    my $features = $params->{features} // '';

    if ($artistId || $artist) {
        # Fresh entry resets the ctx — EXCEPT the expand flags when it's the
        # SAME artist: the bio "Read more" toggle refreshes the TOP view, and
        # that re-fetch carries the artist params (= lands here), so wiping
        # everything would discard the very flag the toggle just set (0.8.0
        # bug: bio expansion never showed). The visibility snapshot is still
        # reset — the refreshed render is a complete, consistent new tree.
        my $prev = $lastCtx{ _cid($client) };
        my $same = $prev
            && ($prev->{artist_id} // '') eq ($artistId // '')
            && ($prev->{artist}    // '') eq ($artist   // '');
        $lastCtx{ _cid($client) } = {
            artist_id => $artistId, artist => $artist, features => $features,
            $same ? ( bio => $prev->{bio}, rev => $prev->{rev} ) : (),
        };
    }
    elsif (my $ctx = $lastCtx{ _cid($client) }) {
        ($artistId, $artist) = @$ctx{qw(artist_id artist)};
        $features ||= $ctx->{features} // '';
        _dbg("topLevel: paramless re-entry, using stashed context");
    }

    _dbg("topLevel: artist_id=" . ($artistId // '-') . " artist=" . ($artist // '-'));

    # No artist context: reached from the Apps menu. Explain the entry point.
    if (!$artistId && !$artist) {
        $callback->({ items => [
            { name => cstring($client, 'PLUGIN_DISCOGRAPHY_APPS_HINT'),  type => 'text' },
            { name => cstring($client, 'PLUGIN_DISCOGRAPHY_APPS_HINT2'), type => 'text' },
        ]});
        return;
    }

    _discographyView($client, $callback, {
        artist_id => $artistId,
        artist    => $artist,
        features  => $features,
        sort      => $prefs->get('sort_order') || 'newest',
        force     => 0,
    });
}

# ---------------------------------------------------------------------------
# The discography list. $opts: artist_id, artist, sort ('newest'|'oldest'),
# force (bypass the release-group cache). Re-entered by the sort toggle and
# Refresh rows via passthrough.
# ---------------------------------------------------------------------------
sub _discographyView {
    my ($client, $callback, $opts) = @_;

    my $artist = $opts->{artist} // '';

    Plugins::Discography::API->getArtistMbid(
        artist_id => $opts->{artist_id},
        artist    => $artist,
        onDone    => sub {
            my $mbid = shift;

            unless ($mbid) {
                $callback->({ items => [{
                    name => cstring($client, 'PLUGIN_DISCOGRAPHY_NOT_FOUND') . ($artist ? ": $artist" : ''),
                    type => 'text',
                }], cachetime => 0 });
                return;
            }

            # Warm the streaming candidate caches in the background (async, does
            # NOT delay this render): the first list view may be badge-less, but
            # any navigation re-renders with playable, tagged tiles — no drill
            # needed first. Client-gated: without a player context the service
            # handlers can't be created and would pollute the cache with empties.
            Plugins::Discography::Sources->getCandidates($client, $artist, 0, sub {})
                if $client && defined $artist && length $artist;

            # Bio + release groups fetched in PARALLEL; render once when both
            # settle. $render assigned BEFORE the fetches (all-caches-warm runs
            # the chain synchronously — the 0.7.0 compose-order trap). The bio
            # is awaited (not fire-and-forget) so its rows are part of the
            # first render — a bio popping in on a REBUILD would shift every
            # item_id below it (walk-stability).
            my ($bio, $bioDone, $rgs, $rgsErr, $rendered);
            my $render = sub {
                return if $rendered || !$bioDone || (!defined $rgs && !$rgsErr);
                $rendered = 1;
                if ($rgsErr) {
                    $callback->({ items => [{
                        name => cstring($client, 'PLUGIN_DISCOGRAPHY_ERROR'),
                        type => 'text',
                    }], cachetime => 0 });
                }
                else {
                    $callback->({
                        items => _buildList($client, $opts, $mbid, $rgs, $bio),
                        # No feed-level caching: the sort toggle and Refresh must
                        # re-run us (the data layer has its own cache).
                        cachetime => 0,
                    });
                }
            };

            if ($prefs->get('show_bio')) {
                _fetchArtistBio($client, $artist, $mbid, sub {
                    $bio = shift; $bioDone = 1; $render->();
                });
            }
            else {
                # Bio off (grid-friendly view): no text rows from us.
                $bioDone = 1;
            }

            Plugins::Discography::API->getReleaseGroups(
                mbid    => $mbid,
                force   => $opts->{force},
                onDone  => sub { $rgs = shift;  $render->() },
                onError => sub { $rgsErr = 1;   $render->() },
            );
        },
    );
}

# ---------------------------------------------------------------------------
# Artist biography (list header): MAI's getBiography via LBF's direct-function
# pattern (guarded; artist MBID passed for exact identity). Cached per artist;
# '' = confirmed none. No Last.fm fallback (that needs LBF's key infra).
# ---------------------------------------------------------------------------
sub _fetchArtistBio {
    my ($client, $artist, $mbid, $cb) = @_;

    unless (defined $artist && length $artist) { $cb->(undef); return }

    my $key = 'dsc:bio:1:' . lc $artist;
    utf8::encode($key) if utf8::is_utf8($key);
    if (defined(my $c = $cache->get($key))) {
        $cb->(length $c ? $c : undef);
        return;
    }

    my $bioFn;
    eval {
        $bioFn = Plugins::MusicArtistInfo::ArtistInfo->can('getBiography')
            if Slim::Utils::PluginManager->isEnabled('Plugins::MusicArtistInfo::Plugin');
        1;
    };
    unless ($bioFn) {
        _dbg("bio '$artist': MAI unavailable");
        eval { $cache->set($key, '', BIO_EMPTY_TTL); 1 };
        $cb->(undef);
        return;
    }

    my $ok = eval {
        $bioFn->($client, sub {
            my $items = shift || [];
            my $text;
            for my $it (@$items) {
                next unless ref $it eq 'HASH';
                my $t = $it->{name};
                if (defined $t && length $t) { $text = _stripHtml($t); last }
            }
            _dbg("bio '$artist': " . (defined $text ? 'len=' . length $text : 'empty'));
            eval { $cache->set($key, $text // '', (defined $text && length $text) ? BIO_FOUND_TTL : BIO_EMPTY_TTL); 1 };
            $cb->( (defined $text && length $text) ? $text : undef );
        }, {}, { artist => $artist, ($mbid ? (mbid => $mbid) : ()) });
        1;
    };
    unless ($ok) {
        $log->warn("MAI getBiography threw: $@");
        eval { $cache->set($key, '', BIO_EMPTY_TTL); 1 };
        $cb->(undef);
    }
}

sub _buildList {
    my ($client, $opts, $mbid, $rgs, $bio) = @_;

    my $sort = $opts->{sort} || 'newest';
    my $useH = _wantHeaders($opts->{features});
    my $show = _shownTypes();
    my $hideUnmatched = $prefs->get('hide_unmatched');

    # WALK-STABILITY: hide_unmatched visibility is SNAPSHOTTED per visit. The
    # background warm means a release can gain/lose "matched" between the
    # render and a click — and since every click re-walks a REBUILT tree by
    # index, a tile disappearing mid-session would shift every item_id under
    # it and clicks would land on the wrong release. The snapshot (kept in the
    # per-player ctx, reset on every fresh entry / Refresh) freezes the
    # visible set for the visit; a re-entry picks up newly-warmed matches.
    my $ctx  = $lastCtx{ _cid($client) } ||= {};
    my $snap = $ctx->{snap} ||= {};

    my @shown;
    for my $rg (@$rgs) {
        next if grep { $HIDE_SECONDARY{$_} } @{ $rg->{secondary} };
        next unless $show->{ _groupOf($rg) };

        my $peek = Plugins::Discography::Sources->peekMatches($opts->{artist}, $rg->{title});
        my $visible = exists $snap->{ $rg->{mbid} }
            ? $snap->{ $rg->{mbid} }
            # Unresolved (no candidate cache yet) stays visible — only a
            # RESOLVED no-match hides.
            : ($snap->{ $rg->{mbid} } =
                (!$hideUnmatched || !defined $peek || @$peek) ? 1 : 0);
        next unless $visible;

        push @shown, [ $rg, $peek ];
    }

    unless (@shown) {
        return [{ name => cstring($client, 'PLUGIN_DISCOGRAPHY_NO_RESULTS'), type => 'text' }];
    }

    my %bucket;
    push @{ $bucket{ _groupOf($_->[0]) } }, $_ for @shown;

    # Artist bio at the very top (the phase-2 artist-view vision, list-native):
    # summary + the same refresh-toggle inline expand the review uses. Awaited
    # in _discographyView, so its row count is fixed for the whole visit.
    my @bioRows;
    if (defined $bio && length $bio) {
        my $akey     = lc($opts->{artist} // '');
        my $expanded = $lastCtx{ _cid($client) }{bio}{$akey};
        my ($summary, $truncated) = _reviewSummary($bio);
        if ($expanded && $truncated) {
            push @bioRows,
                map { (my $t = $_) =~ s/\s+/ /g; { name => $t, type => 'text' } }
                grep { /\S/ } split /\n{2,}/, $bio;
            push @bioRows, {
                name        => cstring($client, 'PLUGIN_DISCOGRAPHY_SHOW_LESS'),
                type        => 'link',
                image       => MENU_REVIEW,
                nextWindow  => 'refresh',
                passthrough => [{ akey => $akey }],
                url         => sub {
                    my ($c, $cb, $a, $p) = @_;
                    delete $lastCtx{ _cid($c) }{bio}{ $p->{akey} };
                    $cb->({ items => [] });
                },
            };
        }
        else {
            push @bioRows, { name => $summary, type => 'text' };
            if ($truncated) {
                push @bioRows, {
                    name        => cstring($client, 'PLUGIN_DISCOGRAPHY_READ_MORE'),
                    type        => 'link',
                    image       => MENU_REVIEW,
                    nextWindow  => 'refresh',
                    passthrough => [{ akey => $akey }],
                    url         => sub {
                        my ($c, $cb, $a, $p) = @_;
                        $lastCtx{ _cid($c) }{bio}{ $p->{akey} } = 1;
                        $cb->({ items => [] });
                    },
                };
            }
        }
    }

    my @items = (@bioRows, _sortToggleItem($client, $opts), _refreshItem($client, $opts, $mbid));

    for my $g (@GROUP_ORDER) {
        my ($key, $token, $iconName) = @$g;
        my $rels = $bucket{$key} or next;

        # ISO dates sort lexically; undated entries go LAST in either direction
        # (an unknown date shouldn't float to the top of "newest").
        my @dated   = sort { $a->[0]{date} cmp $b->[0]{date} } grep {  length $_->[0]{date} } @$rels;
        my @undated =                                          grep { !length $_->[0]{date} } @$rels;
        @dated = reverse @dated if $sort eq 'newest';

        my @tiles = map { _releaseItem($client, $opts, @$_) } @dated, @undated;

        # The divider row is emitted for EVERY client — only its type differs
        # (real header vs text) — so the tree shape (and item_id indexing) is
        # identical however the feed is rebuilt. The image name maps to
        # Material's own release-type svg (and any image keeps the grid toggle
        # available — image-less items disable it page-wide, LBF lesson).
        my $hdr = {
            name  => cstring($client, $token) . ' (' . scalar(@tiles) . ')',
            type  => $useH ? _headerType() : 'text',
            image => IMG_BASE . 'dsc_MTL_svg_' . $iconName . '.png',
        };
        if ($useH) {
            # Older Material forces a drill action onto 'header' items; point
            # it at this section's own tiles rather than a dead page.
            # 'header-basic' ignores the url harmlessly.
            my @kids = @tiles;
            $hdr->{url}         = sub { $_[1]->({ items => \@kids }) };
            $hdr->{passthrough} = [{}];
        }

        push @items, $hdr, @tiles;
    }

    return \@items;
}

# Action rows live at the TOP of the feature's own view (fleet convention).
# Both re-enter _discographyView via passthrough with adjusted opts.
sub _sortToggleItem {
    my ($client, $opts) = @_;
    my $newest = ($opts->{sort} || 'newest') eq 'newest';
    return {
        name        => cstring($client, $newest ? 'PLUGIN_DISCOGRAPHY_SORT_NEWEST'
                                                : 'PLUGIN_DISCOGRAPHY_SORT_OLDEST'),
        type        => 'link',
        image       => MENU_SORT,
        passthrough => [{ %$opts, sort => $newest ? 'oldest' : 'newest' }],
        url         => sub {
            my ($c, $cb, $a, $pass) = @_;
            _discographyView($c, $cb, $pass);
        },
    };
}

# Refresh is NOT a drill-in (LBF's pattern): clear the cache, return empty
# with nextWindow=>'refresh', and the client re-fetches the PARENT view — which
# still carries the artist params. A drill-in Refresh would also poison later
# navigation: every subsequent item_id walk would pass back through it and
# re-clear the cache on every click.
sub _refreshItem {
    my ($client, $opts, $mbid) = @_;
    return {
        name        => cstring($client, 'PLUGIN_DISCOGRAPHY_REFRESH'),
        type        => 'link',
        image       => MENU_REFRESH,
        nextWindow  => 'refresh',
        passthrough => [{ mbid => $mbid }],
        url         => sub {
            my ($c, $cb, $a, $pass) = @_;
            Plugins::Discography::API->clearReleaseGroups($pass->{mbid});
            $cb->({ items => [] });
        },
    };
}

# One release-group tile: title, "year . Type [. services]" line, CAA art
# (native service art as fallback when a cached match carries one). The
# services part is OPPORTUNISTIC — cache-only (peekMatches never searches, so
# the list build stays sync and fast): before the artist's first drill-in the
# tiles are untagged; afterwards matched tiles name their services.
sub _releaseItem {
    my ($client, $opts, $rg, $peek) = @_;

    my $year = ($rg->{date} =~ /^(\d{4})/) ? $1 : '';
    my $type = _displayType($client, $rg);
    my $image = Plugins::Discography::API->caaImage($rg->{mbid});

    my ($favurl, $playUrl, $svcTag);
    if ($peek && @$peek) {
        # Best = first section (orderedAdapters is svc_priority-sorted, so the
        # preferred service wins and a service with no match simply isn't in
        # the list — automatic fallback to the next one).
        my $best = $peek->[0]{items}[0];
        $favurl  = $best->{favorites_url};
        $svcTag  = join('/', map { $_->{svc} } @$peek);

        # Play target: the native node's own play string when it has one, else
        # the favurl minus our private ?cover=/&a= params — <svc>://album:<id>
        # is the exact URL LMS Favorites replays, so the protocol handlers
        # accept it.
        $playUrl = (defined $best->{play} && !ref $best->{play}) ? $best->{play} : $favurl;
        $playUrl =~ s/\?.*$// if defined $playUrl;

        my ($cover) = grep { defined && length } map { $_->{items}[0]{_cover} } @$peek;
        # CAA misses 404 to a placeholder; a matched service always has art —
        # but CAA wins when present, so only known-missing art would benefit.
        # We can't cheaply know a CAA 404 server-side; use service art only for
        # UNDATED releases (the obscure tail where CAA gaps live) — cheap
        # heuristic, refine later if it misfires.
        $image = $cover if !length($rg->{date}) && defined $cover;
    }

    # Service names stay in line2 as the skin-independent fallback (the emblem
    # patch adds the corner badge on top — redundant text can go once badges
    # are verified).
    my $line2 = join(" \x{00B7} ", grep { defined && length } $year, $type, $svcTag);

    # Matched tiles are type 'playlist': tap still drills (go -> detail page),
    # but play/add work on the whole tile via the play URL — AND XMLBrowser
    # only forwards favorites_url into presetParams for playable types
    # (verified live: identical favurl on a 'link' tile is dropped, on a
    # 'playlist' row forwarded), so this is also what makes the badge and the
    # ListenLater Add possible on tiles. Item COUNT is unchanged either way
    # (walk-stable tree; only the type differs as the cache warms).
    return {
        name        => $rg->{title},
        line2       => $line2,
        type        => defined $playUrl ? 'playlist' : 'link',
        image       => $image,
        (defined $playUrl ? (play => $playUrl)           : ()),
        (defined $favurl  ? (favorites_url => $favurl)   : ()),
        passthrough => [{ %$opts, rg => $rg }],
        url         => sub {
            my ($c, $cb, $a, $pass) = @_;
            _releaseDetail($c, $cb, $pass);
        },
    };
}

# Primary type, with a meaningful secondary appended LBF-style
# ("Album / Soundtrack"); a secondary "Compilation" replaces the primary label
# since that's what the release IS to a listener.
sub _displayType {
    my ($client, $rg) = @_;
    my $type = $rg->{type} // '';
    my @sec  = @{ $rg->{secondary} };
    return 'Compilation' if grep { $_ eq 'Compilation' } @sec;
    return @sec ? join(' / ', grep { length } $type, $sec[0]) : $type;
}

# ---------------------------------------------------------------------------
# Album review (detail page): MAI's albumreview when the plugin is installed
# (same direct-function pattern LBF uses for artist bios), else a Qobuz
# editorial description riding the match candidates. Cached per release group;
# a cached '' means "confirmed none" (don't re-ask every open).
# ---------------------------------------------------------------------------

sub _stripHtml {
    my $s = shift // '';
    $s =~ s/<br\s*\/?>/\n/gi;
    $s =~ s/<\/p>/\n\n/gi;
    $s =~ s/<[^>]+>//g;
    $s =~ s/&amp;/&/g;  $s =~ s/&quot;/"/g; $s =~ s/&#?39;|&apos;/'/g;
    $s =~ s/&lt;/</g;   $s =~ s/&gt;/>/g;   $s =~ s/&nbsp;/ /g;
    $s =~ s/\x{2028}|\x{2029}/\n/g;
    $s =~ s/[ \t]+/ /g; $s =~ s/ *\n */\n/g;
    $s =~ s/\n{3,}/\n\n/g;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

sub _fetchAlbumReview {
    my ($client, $artist, $album, $rgMbid, $sections, $cb) = @_;

    my $key = 'dsc:rev:1:' . $rgMbid;
    if (defined(my $c = $cache->get($key))) {
        $cb->(length $c ? $c : undef);   # '' = confirmed none
        return;
    }

    my $qobuzFallback = sub {
        my $desc;
        for my $sec (@{ $sections || [] }) {
            ($desc) = grep { defined && length } map { $_->{_desc} } @{ $sec->{items} };
            last if $desc;
        }
        $desc = _stripHtml($desc) if defined $desc;
        eval { $cache->set($key, $desc // '', (defined $desc && length $desc) ? REVIEW_FOUND_TTL : REVIEW_EMPTY_TTL); 1 };
        $cb->( (defined $desc && length $desc) ? $desc : undef );
    };

    # MAI's albumreview as a direct function (LBF's bio pattern): guarded via
    # can() — a signature/shape change in MAI degrades to the Qobuz fallback,
    # never an error. Callback items carry the review text in `name`.
    my $reviewFn;
    eval {
        $reviewFn = Plugins::MusicArtistInfo::AlbumInfo->can('getAlbumReview')
            if Slim::Utils::PluginManager->isEnabled('Plugins::MusicArtistInfo::Plugin');
        1;
    };
    unless ($reviewFn && length($artist // '') && length($album // '')) {
        _dbg("review '$album': MAI " . ($reviewFn ? 'skipped (missing artist/album)' : 'unavailable') . " -> Qobuz fallback");
        $qobuzFallback->();
        return;
    }

    my $ok = eval {
        $reviewFn->($client, sub {
            my $items = shift || [];
            my $text;
            for my $it (@$items) {
                next unless ref $it eq 'HASH';
                my $t = $it->{name};
                if (defined $t && length $t) { $text = _stripHtml($t); last }
            }
            if (defined $text && length $text) {
                _dbg("review '$album': MAI len=" . length $text);
                eval { $cache->set($key, $text, REVIEW_FOUND_TTL); 1 };
                $cb->($text);
            }
            else {
                _dbg("review '$album': MAI empty -> Qobuz fallback");
                $qobuzFallback->();
            }
        }, {}, { artist => $artist, album => $album });
        1;
    };
    unless ($ok) {
        $log->warn("MAI albumreview threw: $@");
        $qobuzFallback->();
    }
}

# Summary cut at a word boundary; returns (summary, wasTruncated).
sub _reviewSummary {
    my ($text) = @_;
    (my $flat = $text) =~ s/\s+/ /g;
    return ($flat, 0) if length($flat) <= REVIEW_SUMMARY_CHARS;
    my $cut = substr($flat, 0, REVIEW_SUMMARY_CHARS);
    $cut =~ s/\s+\S*$//;
    return ($cut . " \x{2026}", 1);
}

# Detail page: MB metadata header, review summary (tap through to the full
# text), the playable version row(s), a Refresh-matches action, and the
# external links (MB + AllMusic/Discogs/... from MB url-relationships). All
# fetches are cache-backed and therefore IDEMPOTENT — this page is re-executed
# on every deeper item_id walk (the 0.2.1 design rule).
sub _releaseDetail {
    my ($client, $callback, $pass) = @_;
    my $rg     = $pass->{rg};
    my $artist = $pass->{artist} // '';

    my $meta = {
        name  => $rg->{title} . ($artist ? " \x{2013} $artist" : ''),
        line2 => join(" \x{00B7} ", grep { length } $rg->{date}, _displayType($client, $rg)),
        type  => 'text',
        image => Plugins::Discography::API->caaImage($rg->{mbid}, 500),
    };
    my $mbLink = {
        name    => cstring($client, 'PLUGIN_DISCOGRAPHY_VIEW_ON_MB'),
        type    => 'link',
        image   => MENU_WEBLINK,
        weblink => 'https://musicbrainz.org/release-group/' . $rg->{mbid},
    };

    # $compose MUST be assigned before the fetches fire: with every cache warm
    # the whole callback chain runs SYNCHRONOUSLY, and an undef $compose would
    # crash. Composed exactly once, when both legs (url-rels; candidates ->
    # review) have settled — each leg's guard checks the other's completion.
    my ($links, $reviewDone, $review, $sectionsDone, $sections);
    my $compose = sub {

        my @rows;

        # Review under the artwork header. Material has NO inline expander for
        # browse rows (its v-list-group accordion is context-menu-only), so
        # "Read full review" is a REFRESH TOGGLE: it flips a per-release flag
        # in the player ctx and returns nextWindow=>'refresh' — Material
        # re-fetches this same view, which now renders the full text inline
        # (one text row per PARAGRAPH, split on blank lines only, single
        # newlines collapsed so rows wrap cleanly — LBF's full-bio recipe)
        # with everything below pushed down; "Show less" flips it back.
        # Walk-safe: the flag only changes via these toggle rows, and each
        # flip immediately re-renders the very view whose shape it changes.
        if (defined $review && length $review) {
            my $expanded = $lastCtx{ _cid($client) }{rev}{ $rg->{mbid} };
            my ($summary, $truncated) = _reviewSummary($review);
            if ($expanded && $truncated) {
                push @rows,
                    map { (my $t = $_) =~ s/\s+/ /g; { name => $t, type => 'text' } }
                    grep { /\S/ } split /\n{2,}/, $review;
                push @rows, {
                    name        => cstring($client, 'PLUGIN_DISCOGRAPHY_SHOW_LESS'),
                    type        => 'link',
                    image       => MENU_REVIEW,
                    nextWindow  => 'refresh',
                    passthrough => [{ mbid => $rg->{mbid} }],
                    url         => sub {
                        my ($c, $cb, $a, $p) = @_;
                        delete $lastCtx{ _cid($c) }{rev}{ $p->{mbid} };
                        $cb->({ items => [] });
                    },
                };
            }
            else {
                push @rows, { name => $summary, type => 'text' };
                if ($truncated) {
                    push @rows, {
                        name        => cstring($client, 'PLUGIN_DISCOGRAPHY_FULL_REVIEW'),
                        type        => 'link',
                        image       => MENU_REVIEW,
                        nextWindow  => 'refresh',
                        passthrough => [{ mbid => $rg->{mbid} }],
                        url         => sub {
                            my ($c, $cb, $a, $p) = @_;
                            $lastCtx{ _cid($c) }{rev}{ $p->{mbid} } = 1;
                            $cb->({ items => [] });
                        },
                    };
                }
            }
        }

        my $preVersionRows = scalar @rows;
        if (!$prefs->get('show_all_versions')) {
            # Default: ONE row — the preferred service's best version (the
            # same node tile-play uses). Cuts the drill-in to a single
            # thumbnail; the all-services view stays behind the pref.
            if (@$sections) {
                my %row = %{ $sections->[0]{items}[0] };
                $row{line2} = $sections->[0]{svc};
                push @rows, \%row;
            }
        }
        else {
            # One Material header divider per service, its playable versions
            # below. Same divider rules as the list view: emitted for every
            # client (only the type differs) so the tree is walk-stable; no
            # image on detail-page headers (nothing to brand — LBF's
            # detail-page convention; service icons are plain .png anyway,
            # which dividers never render).
            my $useH = _wantHeaders($pass->{features});
            for my $sec (@$sections) {
                my @svcRows;
                for my $it (@{ $sec->{items} }) {
                    my %row = %$it;
                    # Native node from the service plugin's own renderer (url
                    # coderef + passthrough), so play/add/insert work natively.
                    $row{line2} = $sec->{svc};
                    push @svcRows, \%row;
                }
                my $hdr = {
                    name => $sec->{svc} . ' (' . scalar(@svcRows) . ')',
                    type => $useH ? _headerType() : 'text',
                };
                if ($useH) {
                    my @kids = @svcRows;
                    $hdr->{url}         = sub { $_[1]->({ items => \@kids }) };
                    $hdr->{passthrough} = [{}];
                }
                push @rows, $hdr, @svcRows;
            }
        }

        unless (@rows > $preVersionRows) {
            push @rows, { name => cstring($client, 'PLUGIN_DISCOGRAPHY_NO_MATCH'), type => 'text' };
        }

        # Side-effecting row -> nextWindow refresh (never a drill-in): clear
        # this artist's candidate caches and let the client re-fetch this very
        # page, which re-resolves fresh.
        push @rows, {
            name        => cstring($client, 'PLUGIN_DISCOGRAPHY_REFRESH_MATCHES'),
            type        => 'link',
            image       => MENU_REFRESH,
            nextWindow  => 'refresh',
            passthrough => [{ artist => $artist }],
            url         => sub {
                my ($c, $cb, $a, $p) = @_;
                Plugins::Discography::Sources->clearCandidates($p->{artist});
                $cb->({ items => [] });
            },
        };

        # External links: MB always, then whatever url-relationships MB has
        # for this release group (AllMusic, Discogs, Wikipedia, ...).
        my @linkRows = ($mbLink,
            map { { name => $_->{label}, type => 'link', weblink => $_->{url}, image => MENU_WEBLINK } }
            @{ $links || [] });

        $callback->({ items => [ $meta, @rows, @linkRows ], cachetime => 0 });
    };

    Plugins::Discography::API->getReleaseGroupUrls(
        mbid   => $rg->{mbid},
        onDone => sub { $links = shift; $compose->() if $sectionsDone && $reviewDone },
    );

    Plugins::Discography::Sources->getCandidates($client, $artist, 0, sub {
        my $bySvc = shift;
        $sections = Plugins::Discography::Sources->matchesFor($bySvc, $artist, $rg->{title});
        $sectionsDone = 1;
        # Review needs $sections (Qobuz-description fallback rides the match).
        _fetchAlbumReview($client, $artist, $rg->{title}, $rg->{mbid}, $sections, sub {
            $review = shift;
            $reviewDone = 1;
            $compose->() if defined $links;
        });
    });
}

1;
