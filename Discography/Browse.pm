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
use Slim::Utils::Timers;
use Slim::Schema;
use Time::HiRes ();

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

# Similar artists (MAI/Last.fm related artists).
use constant SIMILAR_FOUND_TTL => 30 * 86400;
use constant SIMILAR_EMPTY_TTL =>  1 * 86400;
use constant SIMILAR_MAX       => 25;          # cap the "Similar artists" list

# Plugin-shipped images. The *_MTL_icon_<name>.png convention makes Material
# swap in its themed '<name>' icon (icon-mapping.js); the PNG itself is the
# fallback for other skins.
use constant IMG_BASE     => 'plugins/Discography/html/images/';
use constant ICON         => IMG_BASE . 'DiscographyIcon_svg.png';
use constant MENU_SORT    => IMG_BASE . 'dsc-sort_MTL_icon_sort.png';
use constant MENU_REFRESH => IMG_BASE . 'dsc-refresh_MTL_icon_refresh.png';
use constant MENU_SEARCH  => IMG_BASE . 'dsc-find_MTL_icon_search.png';

use constant SEARCH_TTL   => 600;  # merged artist-search results (item_id walk
                                   # determinism across legacy re-walks, not a
                                   # data cache — searches are user-initiated)
use constant BANNER_MAX     => 20;  # cover tiles sent (CSS clips to one row —
                                    # what fits the viewport is what shows;
                                    # 20 x 132px fills up to ~2600px ultrawide)
use constant BANNER_TILE_PX => 120; # fixed tile size the responsive row clips to
# Detail-page rows: prose (type 'text') must stay IMAGE-LESS — Material
# mutates text+image items to type "other" (browse-resp.js:800), which loses
# the full-wrap prose rendering (0.7.2 regression: clamped review summary,
# broken view). Only LINK rows get thumb-slot icons; flush-left prose is the
# fleet-standard look (LBF detail pages do the same, deliberately).
use constant MENU_REVIEW  => IMG_BASE . 'dsc-review_MTL_icon_rate_review.png';
use constant MENU_WEBLINK => IMG_BASE . 'dsc-link_MTL_icon_launch.png';
use constant PAGE_MORE    => IMG_BASE . 'dsc-ver_MTL_icon_unfold_more.png';
use constant PAGE_LESS    => IMG_BASE . 'dsc-pg_MTL_icon_unfold_less.png';

# Rows shown per section before "Show more" (and the step it grows by).
use constant PAGE_SIZE => 30;

# Seconds the first render waits for the bootleg map (API::warmOfficial) before
# giving up and showing the unfiltered list. One MB request per 100 releases, so
# a normal artist resolves in one; 15s covers ~1500 releases. Pref
# `official_wait` overrides; 0 opts out of waiting entirely.
use constant OFFICIAL_WAIT_DEFAULT => 15;

# Seconds the first render waits for a COLD streaming pool when hide_unmatched
# is on (see the await block in _discographyView). Purely a safety net against a
# service handler that never calls back: the wait normally ends when resolution
# does. Long enough for three services to answer, short enough that a wedged
# handler doesn't look like a hung page.
use constant POOL_WAIT_MAX => 20;

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

# Release-groups grouped by the MATCHER's normalised title: the rivals that will
# all title-match the same streaming candidate. Only groups that can actually be
# rendered take part — a bootleg or a Remix/DJ-mix group must never win a
# candidate away from the real album, which would then show nothing.
#
# Order IS the ownership order (Sources::_rivalOwner takes rivals->[0] as the
# default winner) and must be deterministic across rebuilds:
#   1. real album before compilation. "The Beatles" the album (1968) beats
#      "The Beatles" the compilation (1967) even though the compilation is
#      EARLIER — a self-titled record is the album; the same-named ones are
#      collections of it. Date alone would hand the White Album to a 1967 comp.
#   2. earliest first-release-date (undated last).
#   3. mbid, so ordering can never depend on hash iteration.
sub _rivalsByTitle {
    my ($rgs, $officialMap) = @_;

    my %by;
    for my $rg (@$rgs) {
        next if grep { $HIDE_SECONDARY{$_} } @{ $rg->{secondary} };
        my $official = $officialMap ? $officialMap->{ $rg->{mbid} } : undef;
        next if defined $official && !$official;          # bootleg: can't own anything

        push @{ $by{ Plugins::Discography::Sources::_norm($rg->{title}) } }, {
            mbid => $rg->{mbid},
            year => ($rg->{date} =~ /^(\d{4})/) ? $1 : undef,
            comp => ((grep { $_ eq 'Compilation' } @{ $rg->{secondary} }) ? 1 : 0),
            date => (length $rg->{date} ? $rg->{date} : '9999'),
        };
    }

    for my $k (keys %by) {
        @{ $by{$k} } = sort {
               $a->{comp} <=> $b->{comp}
            || $a->{date} cmp $b->{date}
            || $a->{mbid} cmp $b->{mbid}
        } @{ $by{$k} };
    }
    return \%by;
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

sub _dbg { Plugins::Discography::Plugin::dbg(@_) }

# Prose rows: Material's text-row CSS is padding:0 (flush to the viewport
# edge), while icon/thumbnail rows start at the avatar column — ragged. Text
# rows render via v-html, so the indent lives INSIDE the content: escaped text
# wrapped in a margin-left div aligned to the avatar column (72px = Material's
# list avatar slot). Images on text rows are NOT an option (0.7.2: text+image
# mutates to a clamped one-line row).
use constant PROSE_INDENT => '72px';

sub _escHtml {
    my $s = shift // '';
    $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g;
    return $s;
}

sub _proseRow {
    my ($text, $extraStyle) = @_;
    return {
        name => "<div style='margin-left:" . PROSE_INDENT . ($extraStyle // '') . "'>"
              . _escHtml($text) . '</div>',
        type => 'text',
    };
}

# A section-header divider (walk-stable: emitted whenever its rows exist, only
# the type differs per client). Older Material forces a drill action on
# 'header' items, so it points at its own child rows.
sub _sectionHeader {
    my ($client, $token, $useH, $image, $kids, $act) = @_;
    my $hdr = {
        name  => cstring($client, $token),
        type  => $useH ? _headerType() : 'text',
        ($image ? (image => $image) : ()),
    };
    if ($useH) {
        my @k = @{ $kids || [] };
        $hdr->{url}         = sub { $_[1]->({ items => \@k }) };
        $hdr->{passthrough} = [{}];
        # Self-identifying drill (stale-view fix): older Material forces a go
        # action onto headers; give it explicit params so it lands on this
        # section's rows regardless of server state.
        if ($act && $act->{id}) {
            $hdr->{id}          = $act->{id};
            $hdr->{itemActions} = $act->{itemActions};
        }
    }
    return $hdr;
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
# Fix: stash the entry context per player; a paramless WALK call (item_id
# present) rebuilds the same view (deterministic order, data served from the
# API cache) so the item_id walk resolves. A paramless call WITHOUT item_id is
# the app root and renders the root (search/hint) view instead — restoring the
# stash there trapped the app on the last artist (0.37.2). Known limit: one
# artist per player at a time — jumping back to an older artist's still-open
# view after opening another artist's walks the newer tree.
my %lastCtx;
sub _cid { my ($client) = @_; return $client ? $client->id : '_none' }

sub topLevel {
    my ($client, $callback, $args) = @_;

    my $params   = ref $args->{params} eq 'HASH' ? $args->{params} : {};
    my $artistId = _cleanParam($params->{artist_id});
    my $artist   = _cleanParam($params->{artist});
    # A KNOWN MusicBrainz artist mbid — set by an "Also a member of" band link
    # (via its %lastCtx re-stash) to enter that band's discography directly,
    # skipping name/tag resolution. Absent on the normal artist entry.
    my $mbid     = _cleanParam($params->{mbid});
    # Param-addressed navigation (the stale-view fix): rg = a release-group
    # mbid -> render that release's DETAIL directly; item = a row id — WITH rg
    # a row of that detail view, WITHOUT rg a row of the artist LIST view
    # (toggles/paging/headers/extras). sort = an explicit list order (the sort
    # toggle's fresh-entry param; also re-issued by refresh toggles inside a
    # sorted view, so the order sticks). All arrive from itemActions'
    # fixedParams (always alongside the artist identity), never positional.
    my $rgParam   = _cleanParam($params->{rg});
    my $itemParam = _cleanParam($params->{item});
    my $sortParam = _cleanParam($params->{sort});
    $sortParam = undef unless ($sortParam // '') =~ /^(?:newest|oldest)$/;

    # Param-addressed search submission (the search row's overridden go
    # action: search:<text> + features, NO item_id — see _searchRow). Rendered
    # directly, BEFORE any ctx stash/restore: the results view must be immune
    # to whatever artist is stashed, and the request carries no artist
    # identity to stash anyway. Raw param (not _cleanParam — typed text may
    # legitimately start with '$'); _artistSearchView trims/guards it.
    #
    # GATED ON item_id BEING ABSENT (0.42.2). A POSITIONAL walk into the search
    # row sends item_id:<path> + search:<text> in the SAME request (the legacy
    # path _searchRow's url coderef exists for — Control/XMLBrowser.pm:493
    # hands the text to the row's coderef as $args->{search}). Without this
    # guard that request was intercepted here and the RESULTS were returned as
    # the TOP feed, whereupon XMLBrowser descended the item_id path into them
    # (_cliQuery_done splits item_id and indexes $feed->{items} positionally) —
    # so the walk landed on an arbitrary result row. Reproduced live: root-view
    # item_id:5 + search:"The Beatles" rendered "The Beatles Tribute Band"
    # (result index 5) instead of the result list. Material is unaffected
    # either way — its submitted go action carries only search + features +
    # menu, never item_id (verified live on the served item JSON).
    my $searchParam = $params->{search};
    my $walking     = defined $params->{item_id} && length $params->{item_id};
    if (defined $searchParam && !ref $searchParam && length $searchParam
        && !$walking) {
        my $features = $params->{features} // '';
        _artistSearchView($client, $callback, $features, $searchParam);
        return;
    }

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

    if ($artistId || $artist || $mbid) {
        # Fresh entry resets the ctx — EXCEPT the expand flags when it's the
        # SAME artist: the bio "Read more" toggle refreshes the TOP view, and
        # that re-fetch carries the artist params (= lands here), so wiping
        # everything would discard the very flag the toggle just set (0.8.0
        # bug: bio expansion never showed). `page` is the same class of state:
        # the section "Show more" rows refresh the TOP view too. The visibility
        # snapshot is still reset — the refreshed render is a complete,
        # consistent new tree.
        my $prev = $lastCtx{ _cid($client) };
        my $same = $prev
            && ($prev->{artist_id} // '') eq ($artistId // '')
            && ($prev->{artist}    // '') eq ($artist   // '')
            && ($prev->{mbid}      // '') eq ($mbid     // '');
        $lastCtx{ _cid($client) } = {
            artist_id => $artistId, artist => $artist, mbid => $mbid,
            features => $features,
            $same ? ( bio  => $prev->{bio}, rev => $prev->{rev},
                      ver  => $prev->{ver}, page => $prev->{page} ) : (),
        };
    }
    elsif ($walking && (my $ctx = $lastCtx{ _cid($client) })) {
        # Restore the stash ONLY for positional WALK requests (they always
        # carry item_id — cliQuery passes the full request params copy, so a
        # walk's item_id is visible here): a deeper click re-runs this feed
        # paramless and must rebuild the identical stashed view for its
        # item_id path to resolve. A paramless request WITHOUT item_id is a
        # genuine app-root entry (Apps menu / Material re-fetching the root)
        # and falls through to the root view below — before 0.37.2 it ALSO
        # restored the stash, so once any artist was browsed the app re-opened
        # stuck on that artist and the search/root view was unreachable
        # (Simon, field). Ctx itself is untouched — walks keep working.
        ($artistId, $artist, $mbid) = @$ctx{qw(artist_id artist mbid)};
        $features ||= $ctx->{features} // '';
        _dbg("topLevel: paramless walk re-entry, using stashed context");
    }

    _dbg("topLevel: artist_id=" . ($artistId // '-') . " artist=" . ($artist // '-')
        . " mbid=" . ($mbid // '-'));

    # No artist context: the app-root view (Apps menu) — search, about, and
    # a live plugin-status list, sectioned with the same header dividers as
    # the artist view.
    if (!$artistId && !$artist && !$mbid) {
        $callback->(_rootView($client, $features));
        return;
    }

    my $opts = {
        artist_id => $artistId,
        artist    => $artist,
        mbid      => $mbid,
        features  => $features,
        sort      => $sortParam || $prefs->get('sort_order') || 'newest',
        force     => 0,
    };

    # Param-addressed release detail (rg carries its own artist identity, just
    # stashed above — so this view is durable across any navigation order,
    # restarts, other artists: nothing here depends on a positional walk).
    if ($rgParam && $rgParam =~ /^[0-9a-f-]{36}$/i) {
        _rgView($client, $callback, $opts, lc $rgParam, $itemParam);
        return;
    }

    # Param-addressed LIST-view row (no rg): rebuild the list privately and
    # invoke the named row's own coderef — toggles/paging/headers/extras reuse
    # their existing logic (the same collector pattern as _rgView).
    if (defined $itemParam && length $itemParam) {
        _listItemDispatch($client, $callback, $opts, $itemParam);
        return;
    }

    _discographyView($client, $callback, $opts);
}

# Locate a feed row by its self-identifying id (topLevel's item: dispatch).
sub _findRow {
    my ($feed, $id) = @_;
    return undef unless ref $feed eq 'HASH';
    my ($row) = grep { defined $_->{id} && $_->{id} eq $id }
                @{ $feed->{items} || [] };
    return $row;
}

# Run a located row's OWN url coderef (toggles / version drills / header drills
# reuse their existing logic — zero duplication). A missing or urlless row ->
# empty response; the tapped action's nextWindow=>'refresh' then re-renders the
# view cleanly (unknown id = stale view from an older build / vanished section).
sub _runRow {
    my ($client, $callback, $row, $what) = @_;
    if ($row && ref $row->{url} eq 'CODE') {
        my $p = ref $row->{passthrough} eq 'ARRAY' ? $row->{passthrough}[0] : {};
        $row->{url}->($client, $callback, {}, $p);
    }
    else {
        _dbg("dispatch: $what not found");
        $callback->({ items => [], cachetime => 0 });
    }
}

# Find a list-view row by id and run it (see topLevel).
sub _listItemDispatch {
    my ($client, $callback, $opts, $item) = @_;
    _discographyView($client, sub {
        _runRow($client, $callback, _findRow(shift, $item), "list item '$item'");
    }, $opts);
}

# ---------------------------------------------------------------------------
# Param-addressed release detail (the stale-view fix). Entered by an rg: param
# carrying full artist identity — resolves the release group from the CACHED
# RG list (14d; the tile that emitted the param came from the same list) and
# renders _releaseDetail directly. With an item: param, the detail is rendered
# PRIVATELY and the matching row's own url coderef is invoked instead — so
# toggles/version rows reuse their existing logic with zero duplication.
# ---------------------------------------------------------------------------
sub _rgView {
    my ($client, $callback, $opts, $rgMbid, $item) = @_;

    my $err = sub {
        $callback->({ items => [{
            name => cstring($client, 'PLUGIN_DISCOGRAPHY_ERROR'), type => 'text',
        }], cachetime => 0 });
    };

    # The artist mbid is part of every rg action's fixedParams; without it we
    # can't fetch the RG list this release belongs to.
    my $ambid = $opts->{mbid};
    return $err->() unless $ambid && $ambid =~ /^[0-9a-f-]{36}$/i;

    Plugins::Discography::API->getReleaseGroups(
        mbid   => lc $ambid,
        onDone => sub {
            my $rgs = shift || [];
            my ($rel) = grep { ($_->{mbid} // '') eq $rgMbid } @$rgs;
            unless ($rel) {
                _dbg("rgView: rg $rgMbid not in the artist's RG list");
                return $err->();
            }
            my $pass = { %$opts, rg => $rel };
            if (defined $item && length $item) {
                _releaseDetail($client, sub {
                    _runRow($client, $callback, _findRow(shift, $item),
                            "detail item '$item'");
                }, $pass);
            }
            else {
                _releaseDetail($client, $callback, $pass);
            }
        },
        onError => $err,
    );
}

# ---------------------------------------------------------------------------
# CLI ["discography","playcmd"]: param-addressed play/add/insert for a release
# (tiles + detail rows point their play actions here — XMLBrowser's default
# play action is positional and breaks on a stale view). Resolves the target
# via the SAME cache-backed _releaseDetail build the page uses: with item: the
# named row's play url, else the detail's kept (preferred-source) play string.
# Async CLI command (candidates may need fetching on a cold cache).
# ---------------------------------------------------------------------------
sub playCommand {
    my $request = shift;
    my $client  = $request->client;

    my $rgMbid = lc($request->getParam('rg') // '');
    my $cmd    = $request->getParam('cmd') // 'play';
    my $item   = $request->getParam('item');
    $cmd = 'play' unless $cmd =~ /^(?:play|add|insert)$/;

    my %opts = map { $_ => scalar $request->getParam($_) }
               grep { defined $request->getParam($_) }
               qw(artist_id artist mbid features);
    my $ambid = lc($opts{mbid} // '');

    # Direct-url mode (library-extras tiles): the play target is already a
    # core-resolved db: url — no resolution step, whitelisted shape only. A
    # lib: tile carries a url but NO rg, so once a url is present this is the
    # only path it can take: play it if whitelisted, else refuse it explicitly
    # (never hand an arbitrary string to the player, and don't fall through to
    # the misleading "missing rg" branch — surface the real reason instead).
    my $direct = $request->getParam('url');
    if ($client && defined $direct && length $direct) {
        if ($direct =~ /^db:album\.id=\d+$/) {
            _dbg("playcmd: $cmd -> $direct (direct)");
            $client->execute(['playlist', $cmd, $direct]);
        }
        else {
            $log->warn("discography playcmd: rejected non-whitelisted url '$direct'");
        }
        $request->setStatusDone();
        return;
    }

    unless ($client && $rgMbid =~ /^[0-9a-f-]{36}$/ && $ambid =~ /^[0-9a-f-]{36}$/) {
        _dbg('playcmd: missing client/rg/artist-mbid');
        $request->setStatusDone();
        return;
    }

    $request->setStatusProcessing();
    my $done = sub {
        my ($url) = @_;
        if (defined $url && length $url) {
            _dbg("playcmd: $cmd -> $url");
            $client->execute(['playlist', $cmd, $url]);
        }
        else {
            _dbg("playcmd: no playable url resolved for rg $rgMbid");
        }
        $request->setStatusDone();
    };

    Plugins::Discography::API->getReleaseGroups(
        mbid   => $ambid,
        onDone => sub {
            my $rgs = shift || [];
            my ($rel) = grep { ($_->{mbid} // '') eq $rgMbid } @$rgs;
            return $done->(undef) unless $rel;
            _releaseDetail($client, sub {
                my $feed = shift || {};
                my $row;
                if (defined $item && length $item) {
                    $row = _findRow($feed, $item);
                }
                else {
                    # The kept preferred-source row is the one carrying a play
                    # string (same node tile-play collects).
                    ($row) = grep { defined $_->{play} } @{ $feed->{items} || [] };
                }
                $done->($row ? ($row->{play} // _playUrl($row)) : undef);
            }, { %opts, sort => $prefs->get('sort_order') || 'newest',
                 force => 0, rg => $rel });
        },
        onError => sub { $done->(undef) },
    );
}

# ---------------------------------------------------------------------------
# The discography list. $opts: artist_id, artist, sort ('newest'|'oldest'),
# force (bypass the release-group cache). Re-entered by the sort toggle and
# Refresh rows via passthrough.
# ---------------------------------------------------------------------------
sub _discographyView {
    my ($client, $callback, $opts) = @_;

    my $artist = $opts->{artist} // '';

    # The post-resolution body, run with whatever mbid we end up with.
    my $withMbid = sub {
            my $mbid = shift;

            unless ($mbid) {
                my @items = ({
                    name => cstring($client, 'PLUGIN_DISCOGRAPHY_NOT_FOUND') . ($artist ? ": $artist" : ''),
                    type => 'text',
                });
                # Retry row: clears the cached miss for this name and re-enters.
                # A "not found" is usually transient (a MB mirror still building
                # its search index returns 0 for everyone), and the short miss TTL
                # alone would still make the user wait — this busts it on demand.
                push @items, {
                    name        => cstring($client, 'PLUGIN_DISCOGRAPHY_RETRY_LOOKUP'),
                    type        => 'link',
                    image       => MENU_REFRESH,
                    nextWindow  => 'refresh',
                    url         => sub {
                        my ($c, $cb) = @_;
                        Plugins::Discography::API->clearArtistMbid($artist);
                        $cb->({ items => [] });
                    },
                } if length $artist;
                $callback->({ items => \@items, cachetime => 0 });
                return;
            }

            # Warm the streaming candidate caches in the background (async, does
            # NOT delay this render): the first list view may be badge-less, but
            # any navigation re-renders with playable, tagged tiles — no drill
            # needed first. Client-gated: without a player context the service
            # handlers can't be created and would pollute the cache with empties.
            # SPINE-AWARE: with an ambiguous name a blind warm fetches the
            # WRONG act's catalogue and caches it (field, 0.43.0 — the rapper's
            # page matched against the ska band's 289 albums). So the warm is
            # deferred to the release-group callback, where the MB titles that
            # identify THIS artist are available. Unambiguous names warm
            # immediately, exactly as before.
            my $warm = sub {
                my ($spine, $done) = @_;
                $done ||= sub {};
                unless ($client && defined $artist && length $artist) {
                    return $done->();   # every path must settle $done
                }

                # FETCHED, not peeked. The same-name set was only ever
                # populated by the plugin's own SEARCH, so an artist entered
                # from the Material context menu - the main entry point - was
                # never known to be ambiguous: no strict verification and no
                # alias retry (field, 2026-07-19: Sonic Boom, FOUR MB artists
                # of that name, resolved to a Qobuz entity holding 2 albums and
                # nothing checked it). Cached 14 days, so this is one MB
                # request per artist per fortnight.
                Plugins::Discography::API->getArtistCandidates($artist, sub {
                    my ($cands) = @_;
                    my $ambig = ($mbid && $cands && @$cands > 1) ? 1 : 0;

                    my $go = sub {
                        Plugins::Discography::Sources->getCandidates(
                            $client, $artist, 0, sub { $done->() },
                            { spine => $spine, mbid => $mbid, aliases => $_[0],
                              ambiguous => $ambig });
                    };

                    # Aliases only for an AMBIGUOUS name, where a failed
                    # resolution is expected and the retry is what rescues it.
                    if ($ambig) {
                        Plugins::Discography::API->warmArtistAliases($mbid, $go);
                    }
                    else { $go->(undef) }
                });
            };

            # Bio + release groups fetched in PARALLEL; render once when both
            # settle. $render assigned BEFORE the fetches (all-caches-warm runs
            # the chain synchronously — the 0.7.0 compose-order trap). The bio
            # is awaited (not fire-and-forget) so its rows are part of the
            # first render — a bio popping in on a REBUILD would shift every
            # item_id below it (walk-stability).
            my ($bio, $bioDone, $rgs, $rgsErr, $local, $offDone, $rendered,
                $poolDone);
            my $render = sub {
                return if $rendered || !$bioDone || !$offDone || !$poolDone
                       || (!defined $rgs && !$rgsErr);
                $rendered = 1;
                if ($rgsErr) {
                    $callback->({ items => [{
                        name => cstring($client, 'PLUGIN_DISCOGRAPHY_ERROR'),
                        type => 'text',
                    }], cachetime => 0 });
                }
                else {
                    $callback->({
                        items => _buildList($client, $opts, $mbid, $rgs, $bio, $local),
                        # No feed-level caching: the sort toggle and Refresh must
                        # re-run us (the data layer has its own cache).
                        cachetime => 0,
                    });
                }
            };

            # The MAI/Last.fm biography is name-keyed too — the prominent
            # act's life story under a different artist's name is worse than no
            # biography at all.
            #
            # ASYNC guard (0.44.5). The sync form answers from cache only and a
            # cold cache answers "no", so the FIRST visit to a secondary act's
            # page rendered the prominent act's biography — the exact leak Simon
            # reported (Pete Kember's bio on the Sonic Boom group with Andrew
            # Huang). The fetch is cached and the page is already waiting on MB,
            # so correctness here costs nothing a user can perceive.
            if ($prefs->get('show_bio')) {
                Plugins::Discography::API->sharesNameWithProminentAsync(
                    $opts->{artist}, $mbid, sub {
                        my ($shared) = @_;
                        if ($shared) { $bioDone = 1; $render->(); return }
                        _fetchArtistBio($client, $artist, $mbid, sub {
                            $bio = shift; $bioDone = 1; $render->();
                        });
                    });
            }
            else {
                # Bio off (grid-friendly view): no text rows from us.
                $bioDone = 1;
            }

            Plugins::Discography::API->getReleaseGroups(
                mbid    => $mbid,
                force   => $opts->{force},
                onDone  => sub {
                    $rgs = shift;

                    # A secondary act sharing the prominent one's exact name:
                    # every name-keyed lookup below would return the PROMINENT
                    # act's data. See API::sharesNameWithProminent.
                    my $shared = Plugins::Discography::API
                        ->sharesNameWithProminent($opts->{artist}, $mbid);
                    $opts->{shared_name} = $shared;
                    _dbg("'$opts->{artist}' shares its name with a more prominent"
                        . ' act - suppressing name-keyed library/bio/similar')
                        if $shared;

                    # The MB titles for THIS mbid — the reference a service
                    # artist has to corroborate when several share the name.
                    # _resolveArtist self-gates on the service actually
                    # returning >1 same-name artist, so passing this always is
                    # safe: an unambiguous artist takes the identical path it
                    # always did.
                    # AWAIT the streaming warm when hide_unmatched is on and no
                    # pool exists yet. Rendering first produces a page that
                    # ignores the pref (the !resolved exemption treats "not
                    # asked yet" as "asked and found nothing") and then
                    # contradicts itself on the next visit — 85 unmatched
                    # releases, then 0. Version-scoped pool keys mean EVERY
                    # artist is cold after an update, so this was not an edge
                    # case. Costs the streaming resolution once per artist.
                    #
                    # Only when the pref is on: with it off, unmatched releases
                    # are shown anyway, so there is nothing to wait for.
                    my $poolCold = Plugins::Discography::Sources
                        ->peekPool($opts->{artist}, $mbid)->{cold};
                    my $await = ($prefs->get('hide_unmatched') && $poolCold) ? 1 : 0;
                    $poolDone = 1 unless $await;
                    _dbg("pool is cold - awaiting streaming resolution before render")
                        if $await;

                    if ($await) {
                        # SAFETY NET: getCandidates fans out to several service
                        # plugins, and one that never calls back would leave the
                        # page hanging forever — a far worse failure than the
                        # one being fixed. Render regardless after this long.
                        my $settled = 0;
                        my $finish = sub {
                            return if $settled++;
                            $poolDone = 1;
                            $render->();
                        };
                        Slim::Utils::Timers::setTimer(undef, time() + POOL_WAIT_MAX,
                            sub {
                                return if $settled;
                                _dbg('pool warm did not settle in '
                                    . POOL_WAIT_MAX . 's - rendering anyway');
                                $finish->();
                            });
                        $warm->(_spineTitles($rgs), $finish);
                    }
                    else { $warm->(_spineTitles($rgs)) }

                    # Library albums, fetched ONCE here (sync DB) so we know which
                    # release MBIDs to pre-resolve; the same list is handed to
                    # _buildList so it doesn't query again.
                    # Library lookup is by NAME (via artist_id), so for a
                    # shared-name act it returns the prominent act's albums and
                    # would assert the user owns records this artist never made.
                    # No signal exists to split them — suppress rather than lie.
                    $local = $opts->{shared_name} ? []
                           : Plugins::Discography::Sources->localAlbums(
                                 $opts->{artist_id}, $opts->{artist});

                    # Release MBIDs the artist-wide browse hasn't already resolved
                    # -> resolve them directly (a few requests) so a library
                    # album's exact-MBID match is ready on THIS render, not after
                    # a re-entry. Empty when the big map is already warm.
                    my $known = Plugins::Discography::API->peekReleaseMap($mbid) || {};
                    my @needMbids = grep { $_ && !$known->{$_} }
                                    map  { $_->{_mbid} } @$local;

                    # AWAITED, bounded. The bootleg map (a group is a bootleg only
                    # if NONE of its releases is official) can't be used partial,
                    # so the first render either waits for it or shows bootlegs —
                    # we wait. One MB request per 100 releases: one for a normal
                    # artist, 33 for The Beatles; the deadline caps that and the
                    # pass finishes in the background for the next entry.
                    #
                    # ONE serial MB chain (never parallel — 2 chains break MB's
                    # 1 req/s etiquette): the few targeted library lookups FIRST
                    # (they fix the visible orphan and finish inside the
                    # deadline), THEN the full bootleg browse.
                    my $wait = $prefs->get('official_wait');
                    $wait = OFFICIAL_WAIT_DEFAULT unless defined $wait;

                    my $startBootleg = sub {
                        my ($await) = @_;
                        if ($await) {
                            Plugins::Discography::API->warmOfficial($mbid, sub {
                                return if $offDone;
                                $offDone = 1;
                                Slim::Utils::Timers::killTimers(undef, $await);
                                $render->();
                            });
                        }
                        else {
                            Plugins::Discography::API->warmOfficial($mbid);
                        }
                    };

                    unless ($wait > 0) {           # 0 = never wait (opt-out)
                        $offDone = 1; $render->();
                        Plugins::Discography::API->warmLocalReleases(\@needMbids, sub {
                            Plugins::Discography::API->warmBandMembers($mbid, sub {
                                _warmArtistExtras($client, $mbid, $artist,
                                    sub { $startBootleg->(undef) });
                            });
                        });
                        return;
                    }

                    my $deadline = sub {
                        return if $offDone;
                        $offDone = 1;
                        _dbg("official-status: ${wait}s deadline hit - rendering, "
                             . "pass continues in the background");
                        $render->();
                    };
                    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $wait, $deadline);

                    Plugins::Discography::API->warmLocalReleases(\@needMbids, sub {
                        # Then the band-member lookup (one fast call), then the
                        # slow bootleg pass — one serial MB chain. Both the local
                        # release map and the band list are cached before the
                        # bootleg leg sets $offDone, so both are ready for the
                        # first render (deadline permitting).
                        Plugins::Discography::API->warmBandMembers($mbid, sub {
                            _warmArtistExtras($client, $mbid, $artist,
                                sub { $startBootleg->($deadline) });
                        });
                    });
                },
                # EVERY $render flag must be settled here, $poolDone included:
                # it is only otherwise set inside the onDone above, so an MB
                # error left $render permanently gated and the callback was
                # never fired at all — a spinner that hangs forever instead of
                # the error row. There is nothing to await anyway: with no
                # release groups there is no spine, so the streaming warm this
                # flag exists to wait for is never started.
                onError => sub {
                    $rgsErr = 1; $offDone = 1; $poolDone = 1; $render->();
                },
            );
    };

    # Enter by a KNOWN artist mbid (an "Also a member of" band link) to browse
    # that band directly; otherwise resolve the artist (library tag, then MB name
    # search, with a corroborated fallback for a wrong tag). Both feed $withMbid.
    if ($opts->{mbid} && $opts->{mbid} =~ /^[0-9a-f-]{36}$/i) {
        $withMbid->(lc $opts->{mbid});
    }
    else {
        _resolveArtistMbid($client, $opts, $withMbid);
    }
}

# Resolve an artist to the mbid we should actually BROWSE, healing a wrong/merged
# library tag. getArtistMbid trusts the file's album-artist MBID first (exact
# identity, normally right). But a mis-tagged same-name artist resolves fine yet
# browses EMPTY — field case: Simon's UK "The Bees" albums carry a US garage
# band's mbid (dd11eecd, 0 release-groups), while the real band (276cfa71, 18
# RGs) is what a name search finds. So if a TAG mbid has no release-groups, hand
# off to _disambiguateByLibrary. Name-searched mbids are trusted as-is (no tag to
# be wrong). getReleaseGroups is cached, so the main chain re-fetching the chosen
# mbid is a cache hit.
sub _resolveArtistMbid {
    my ($client, $opts, $cb) = @_;
    my $api  = 'Plugins::Discography::API';
    my $name = $opts->{artist};

    $api->getArtistMbid(
        artist_id => $opts->{artist_id},
        artist    => $name,
        onDone    => sub {
            my ($mbid, $fromTag) = @_;
            return $cb->($mbid) unless $mbid && $fromTag && defined $name && length $name;

            $api->getReleaseGroups(mbid => $mbid,
                onError => sub { $cb->($mbid) },
                onDone  => sub {
                    my $rgs = shift;
                    return $cb->($mbid) if $rgs && @$rgs;    # tag has a discography -> good
                    _dbg("tag mbid $mbid has 0 release-groups; disambiguating '$name' by library");
                    _disambiguateByLibrary($opts, $mbid, $cb);
                });
        },
    );
}

# Titles that corroborate WEAKLY for same-name disambiguation, because lots of
# artists have one: a match on "Greatest Hits"/"Live"/etc. is near-coincidence.
# Stored _norm'd so they compare against a _norm'd title. (English-biased, but
# that's where most MB/streaming titles land; self-titled is handled separately
# and universally.) Down-weighted, not excluded — two of them still corroborate.
my %GENERIC_TITLE = map { Plugins::Discography::Sources::_norm($_) => 1 } (
    'Greatest Hits', 'The Greatest Hits', 'Best Of', 'The Best Of',
    'Very Best Of', 'The Very Best Of', 'Collection', 'The Collection',
    'Anthology', 'Live', 'Unplugged', 'Hits', 'The Hits', 'Singles',
    'The Singles', 'Compilation', 'Essential', 'The Essential', 'Gold',
    'Retrospective', 'Discography', 'Rarities', 'Demos', 'Christmas',
);

# Weight of one owned-album title as disambiguation EVIDENCE for a same-name
# artist. A SELF-TITLED album (title == artist name) is worthless here: every
# same-name candidate has one, so it matches them ALL and could hand a wrong one
# the tie-break — so 0.5, never decisive alone. A generic compilation title is
# likewise weak (0.5). A distinctive title is strong (1.0). Sums per candidate;
# adoption needs >= DISAMBIG_MIN_WEIGHT so a single self-titled/generic collision
# can't drive a wrong adoption, while ONE distinctive album still heals a tag.
sub _matchWeight {
    my ($title, $artist) = @_;
    my $n = Plugins::Discography::Sources::_norm($title // '');
    return 0.5 if length $n && $n eq Plugins::Discography::Sources::_norm($artist // '');
    return 0.5 if $GENERIC_TITLE{$n};
    return 1.0;
}

# Among the SAME-NAME MusicBrainz artists, pick the one whose discography best
# matches the user's OWNED albums (title match — no MBIDs needed). Deliberately
# checks EVERY candidate and keeps the BEST-scoring, NOT the first that matches:
# the right "The Bees" isn't necessarily the highest MB-scored one, and a wrong
# same-name artist can coincidentally share a single album title (Simon, 2026-07).
# Matches are WEIGHTED (see _matchWeight): self-titled and generic-compilation
# titles corroborate weakly, so a lone coincidental collision can't win — a
# candidate is adopted only when its weight >= DISAMBIG_MIN_WEIGHT, else the tag
# is kept (an obscure same-name contributor is never mis-attributed). Ties break
# toward the higher search score (strictly-greater keeps the earlier candidate).
# Probes are serial, spaced to MB's 1 req/s on the public API (0 on a mirror),
# bounded to DISAMBIG_MAX; each RG list is cached (14d) so a repeat visit is free.
use constant DISAMBIG_MAX        => 8;
use constant DISAMBIG_MIN_WEIGHT => 1.0;
sub _disambiguateByLibrary {
    my ($opts, $tagMbid, $cb) = @_;
    my $api  = 'Plugins::Discography::API';
    my $name = $opts->{artist};

    my $local = Plugins::Discography::Sources->localAlbums($opts->{artist_id}, $name);
    return $cb->($tagMbid) unless $local && @$local;   # nothing to corroborate against

    $api->getArtistCandidates($name, sub {
        my $cands = shift || [];
        @$cands = grep { ($_->{mbid} // '') ne $tagMbid } @$cands;   # tag already known dead
        @$cands = @$cands[0 .. DISAMBIG_MAX - 1] if @$cands > DISAMBIG_MAX;
        return $cb->($tagMbid) unless @$cands;

        my ($best, $bestW) = ($tagMbid, 0);
        my $i = 0;
        my $step; $step = sub {
            if ($i >= @$cands) {
                my $ok = $bestW >= DISAMBIG_MIN_WEIGHT;
                _dbg("disambiguate '$name': "
                    . ($ok ? "adopting $best (weight $bestW)"
                           : "no confident match (best weight $bestW) - keeping $tagMbid"));
                return $cb->($ok ? $best : $tagMbid);
            }
            my $c = $cands->[$i++];
            $api->getReleaseGroups(mbid => $c->{mbid},
                onError => sub { $step->() },
                onDone  => sub {
                    my $rgs = shift;
                    if ($rgs && @$rgs) {
                        my $claimed = Plugins::Discography::Sources->claimedLocalIds(
                                          $rgs, $name, $local, {});
                        my $w = 0;
                        for my $it (@$local) {
                            $w += _matchWeight($it->{_candTitle}, $name)
                                if $claimed->{ $it->{_albumid} };
                        }
                        ($best, $bestW) = ($c->{mbid}, $w) if $w > $bestW;   # strictly-greater keeps higher score on ties
                        _dbg("disambiguate '$name': candidate $c->{mbid} (score "
                            . ($c->{score} // '?') . ") weight $w ("
                            . scalar(keys %$claimed) . " raw match(es))");
                    }
                    my $gap = $api->mbGap(1.1);   # 0 on a mirror
                    if ($gap > 0) {
                        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $gap,
                            sub { $step->() });
                    }
                    else { $step->() }
                });
        };
        $step->();
    });
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

# ---------------------------------------------------------------------------
# Similar artists via MAI (the same guarded direct-function pattern as the
# bio). The NAME LIST is cached (keyed by artist mbid) and warmed in the MB
# chain, so the section is usually part of the first render. Thumbnails are
# NOT pre-fetched: each row's image points at MAI's own image proxy
# (imageproxy/mai/artist/<name>/image.png — accepts a NAME, resolves local
# artwork -> Discogs/Last.fm -> MAI's default silhouette), so the browser
# loads every photo asynchronously IN-VIEW, like Material's native artist
# lists. No exit-and-re-enter needed (the 0.31.x photo-warm design's flaw).
# ---------------------------------------------------------------------------
sub _similarKey { 'dsc:similar:v1:' . ($_[0] // '') }

# Cache-only, sync: arrayref of similar-artist names, or undef until warmed.
sub _peekSimilar { $cache->get(_similarKey($_[0])) }

# Row thumbnail: MAI's artist image proxy URL (name-keyed), or the person
# icon when MAI isn't available (same look as pre-0.31.0).
sub _artistImg {
    my ($name) = @_;
    my $mai;
    eval {
        $mai = Slim::Utils::PluginManager->isEnabled('Plugins::MusicArtistInfo::Plugin');
        1;
    };
    return IMG_BASE . 'dsc-bio_MTL_icon_person.png'
        unless $mai && defined $name && length $name;
    require URI::Escape;
    return 'imageproxy/mai/artist/' . URI::Escape::uri_escape_utf8($name) . '/image.png';
}

sub _maiFn {
    my ($name) = @_;
    my $fn;
    eval {
        $fn = Plugins::MusicArtistInfo::ArtistInfo->can($name)
            if Slim::Utils::PluginManager->isEnabled('Plugins::MusicArtistInfo::Plugin');
        1;
    };
    return $fn;
}

# Resolve + cache the related-artist NAME list once. $cb fires (arrayref) on
# cache hit / done / MAI-unavailable / failure.
sub _warmSimilarArtists {
    my ($client, $mbid, $artist, $cb) = @_;
    $cb ||= sub {};
    return $cb->([]) unless $mbid && defined $artist && length $artist;

    my $key = _similarKey($mbid);
    if (defined(my $c = $cache->get($key))) { return $cb->($c) }

    my $fn = _maiFn('getRelatedArtists');
    unless ($fn) {
        _dbg("similar '$artist': MAI unavailable");
        eval { $cache->set($key, [], SIMILAR_EMPTY_TTL); 1 };
        return $cb->([]);
    }

    my $ok = eval {
        $fn->($client, sub {
            my $items = shift || [];
            my (@names, %seen);
            for my $it (@$items) {
                next unless ref $it eq 'HASH';
                next if ($it->{type} // '') eq 'text';   # MAI error row
                my $n = $it->{name};
                next unless defined $n && length $n;
                next if $seen{lc $n}++;
                push @names, $n;
                last if @names >= SIMILAR_MAX;
            }
            eval { $cache->set($key, \@names,
                @names ? SIMILAR_FOUND_TTL : SIMILAR_EMPTY_TTL); 1 };
            _dbg("similar '$artist': " . scalar(@names) . ' artist(s)');
            $cb->(\@names);
        }, {}, { artist => $artist, ($mbid ? (mbid => $mbid) : ()) });
        1;
    };
    unless ($ok) {
        $log->warn("MAI getRelatedArtists threw: $@");
        eval { $cache->set($key, [], SIMILAR_EMPTY_TTL); 1 };
        $cb->([]);
    }
}

# Warm the "Similar artists" name list (awaited — cached before the bootleg
# leg sets $offDone, so the section is normally part of the FIRST render).
# Thumbnails need no warming — the rows point at MAI's image proxy and load
# in-view (see _artistImg).
sub _warmArtistExtras {
    my ($client, $mbid, $artist, $cb) = @_;
    $cb ||= sub {};
    return $cb->() unless $client;
    # Don't POISON the cache either: the fetch is by name, the key is by mbid,
    # so warming a shared-name act writes the prominent act's similar artists
    # under this artist's key — where a later render would trust it.
    return $cb->() if Plugins::Discography::API
                        ->sharesNameWithProminent($artist, $mbid);
    _warmSimilarArtists($client, $mbid, $artist, sub { $cb->() });
}

# Normalised MB release titles, used to tell same-named service artists apart.
# Keyed with the matcher's own _norm so it compares like for like with the
# candidate titles it will be scored against.
sub _spineTitles {
    my ($rgs) = @_;
    my %t;
    for my $rg (@{ $rgs || [] }) {
        next unless ref $rg eq 'HASH' && defined $rg->{title};
        my $n = Plugins::Discography::Sources::_norm($rg->{title});
        $t{$n} = 1 if $n ne '';
    }
    return \%t;
}

sub _buildList {
    my ($client, $opts, $mbid, $rgs, $bio, $local) = @_;

    # Carry the RESOLVED artist MBID on every tile's passthrough so the detail
    # page can rebuild the same relMap + rivals the list used (without it,
    # drill-in loses tier-0 identity — Local wouldn't show — and the rival rule).
    #
    # But keep the ENTRY mbid separate: the LIST-view identity actions must NOT
    # carry the resolved mbid. The Material entry/refresh command (the custom
    # action) carries no mbid on a person/name entry, so emitting the resolved
    # one there desyncs topLevel's $same identity check and wipes the
    # refresh-toggle ctx flags (the 0.8.1 bug — bio "Read more" / section paging
    # dead; verified live 2026-07-15). _identParams emits the ENTRY mbid (present
    # only for a band-link entry, which DOES carry it end-to-end); _rgIdent adds
    # the resolved mbid explicitly where detail dispatch genuinely needs it.
    $opts = { %$opts, entry_mbid => $opts->{mbid}, mbid => $mbid };

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

    # Local library albums for this artist: ONE sync DB query, fed into every
    # release's match. Local matches count for visibility (owned = shown) but do
    # NOT mark a release streaming-resolved. Passed in by _discographyView
    # (which needs the mbids to pre-resolve them); fetched here on the paths that
    # don't (e.g. a direct unit call).
    $local ||= Plugins::Discography::Sources->localAlbums($opts->{artist_id}, $opts->{artist});

    # Streaming candidate pools: read + reattached ONCE for the whole build,
    # then filtered per release. Peeking each release separately re-copied
    # every cached item (pools run to thousands since the artist-first fetch).
    # $mbid scopes the pool to THIS MusicBrainz artist — same key getCandidates
    # wrote under. Without it the render reads the name-keyed pool and a
    # same-name act matches against the prominent act's catalogue.
    my $pool = Plugins::Discography::Sources->peekPool($opts->{artist}, $mbid);

    # Filled by the release loop below: { svc => { album-id => 1 } }.
    my %claimedSvc;

    # Bootleg filter: { rg-mbid => 0|1 } for the whole artist, or undef until
    # the background release browse has completed once. A release-group MISSING
    # from a present map was never seen (page cap) — fail open, like undef.
    my $officialMap = Plugins::Discography::API->peekOfficial($mbid);

    # { release-mbid => release-group-mbid }: lets a library album's
    # MUSICBRAINZ_ALBUMID match its tile by identity — the title matcher can't
    # get "The Beatles and Esher Demos" to the White Album. Two sources merged:
    # the artist-wide browse (all releases, but ~36s on a huge artist) and the
    # targeted per-library-album lookups (a few requests, ready first render).
    # Whichever is warm answers; the targeted map covers the deadline gap.
    my $relMap = { %{ Plugins::Discography::API->peekReleaseMap($mbid) || {} },
                   %{ Plugins::Discography::API->peekLocalReleaseMap(
                          [ map { $_->{_mbid} } grep { $_->{_mbid} } @$local ] ) } };

    # Same-title release-groups compete for one candidate (four official groups
    # normalise to "the beatles"); this decides which one owns it.
    my $rivals = _rivalsByTitle($rgs, $officialMap);

    # Invariants for the whole list, computed ONCE (matchesFor used to redo both
    # for every release group): the artist norm and the source order. The RG
    # title norm is computed once per RG below and reused for BOTH the rivals
    # lookup and the matcher (was normed twice).
    my $artistNorm = Plugins::Discography::Sources::_norm($opts->{artist} // '');
    my $sources    = [ Plugins::Discography::Sources::orderedSources() ];

    my @shown;
    for my $rg (@$rgs) {
        next if grep { $HIDE_SECONDARY{$_} } @{ $rg->{secondary} };
        next unless $show->{ _groupOf($rg) };

        my $official = $officialMap ? $officialMap->{ $rg->{mbid} } : undef;
        my $bootleg = (defined $official && !$official) ? 1 : 0;

        my $rgNorm = Plugins::Discography::Sources::_norm($rg->{title});
        my $peek = Plugins::Discography::Sources->peekMatches(
            $opts->{artist}, $rg->{title}, $local, $pool, $rg->{mbid}, $relMap,
            $rivals->{$rgNorm},
            { artistNorm => $artistNorm, albumNorm => $rgNorm, sources => $sources,
              index => $pool->{index} });
        # Which streaming candidates a release group CLAIMED. Collected here
        # rather than recomputed, because matching every candidate against
        # every release group is exactly the work this loop already does.
        for my $sec (@{ $peek->{sections} || [] }) {
            next if ($sec->{svc} // '') eq 'Local';
            $claimedSvc{ $sec->{svc} }{ $_->{_albumid} } = 1
                for grep { defined $_->{_albumid} } @{ $sec->{items} || [] };
        }

        my $visible = exists $snap->{ $rg->{mbid} }
            ? $snap->{ $rg->{mbid} }
            # Any match (local or streaming) shows; a miss only hides once
            # streaming was actually RESOLVED (cached) — never on unresolved.
            # Bootleg-only groups never show. Both live in the SAME snapshot so
            # a background resolve can't shift item_ids mid-visit.
            : ($snap->{ $rg->{mbid} } = $bootleg ? 0
                : (!$hideUnmatched || @{ $peek->{sections} } || !$peek->{resolved}) ? 1 : 0);
        next unless $visible;

        push @shown, [ $rg, $peek->{sections} ];
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
                map { (my $t = $_) =~ s/\s+/ /g; _proseRow($t) }
                grep { /\S/ } split /\n{2,}/, $bio;
            push @bioRows, {
                name        => cstring($client, 'PLUGIN_DISCOGRAPHY_SHOW_LESS'),
                type        => 'link',
                image       => MENU_REVIEW,
                nextWindow  => 'refresh',
                id          => 'bio:less',
                itemActions => _listItemActions($opts, 'bio:less'),
                passthrough => [{ akey => $akey }],
                url         => sub {
                    my ($c, $cb, $a, $p) = @_;
                    delete $lastCtx{ _cid($c) }{bio}{ $p->{akey} };
                    $cb->({ items => [] });
                },
            };
        }
        else {
            push @bioRows, _proseRow($summary);
            if ($truncated) {
                push @bioRows, {
                    name        => cstring($client, 'PLUGIN_DISCOGRAPHY_READ_MORE'),
                    type        => 'link',
                    image       => MENU_REVIEW,
                    nextWindow  => 'refresh',
                    id          => 'bio:more',
                    itemActions => _listItemActions($opts, 'bio:more'),
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

    unshift @bioRows, _sectionHeader($client, 'PLUGIN_DISCOGRAPHY_BIOGRAPHY', $useH,
        IMG_BASE . 'dsc-bio_MTL_icon_person.png', \@bioRows,
        { id => 'sect:BIO', itemActions => _listItemActions($opts, 'sect:BIO') }) if @bioRows;

    # The search row rides here too: after any artist browse the app re-opens
    # on that artist (the %lastCtx model), so the Apps-view search would be
    # unreachable without it. Submission is walk-safe: the paramless re-fetch
    # rebuilds this SAME view from ctx, so the row's item_id resolves.
    my @optRows = (_sortToggleItem($client, $opts), _refreshItem($client, $opts, $mbid),
                   _searchRow($client, $opts));
    my @items = (@bioRows,
        _sectionHeader($client, 'PLUGIN_DISCOGRAPHY_OPTIONS', $useH,
            IMG_BASE . 'dsc-opt_MTL_icon_tune.png', \@optRows,
            { id => 'sect:OPT', itemActions => _listItemActions($opts, 'sect:OPT') }),
        @optRows);

    for my $g (@GROUP_ORDER) {
        my ($key, $token, $iconName) = @$g;
        my $rels = $bucket{$key} or next;

        # ISO dates sort lexically; undated entries go LAST in either direction
        # (an unknown date shouldn't float to the top of "newest").
        my @dated   = sort { $a->[0]{date} cmp $b->[0]{date} } grep {  length $_->[0]{date} } @$rels;
        my @undated =                                          grep { !length $_->[0]{date} } @$rels;
        @dated = reverse @dated if $sort eq 'newest';

        my @tiles = map { _releaseItem($client, $opts, @$_) } @dated, @undated;

        # Long sections are capped; the header keeps naming the TRUE total, so
        # "Singles (87)" over 30 rows reads as paging, not as a lost release.
        my ($vis, $pgRows) = _pageSection($client, $opts, $key, \@tiles);

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
            my @kids = (@$vis, @$pgRows);
            $hdr->{id}          = 'sect:' . $key;
            $hdr->{itemActions} = _listItemActions($opts, $hdr->{id});
            $hdr->{url}         = sub { $_[1]->({ items => \@kids }) };
            $hdr->{passthrough} = [{}];
        }

        push @items, $hdr, @$vis, @$pgRows;
    }

    # Safety net: library albums under this artist that NO release group
    # claimed (MB gaps, odd editions, matcher misses) — nothing owned may
    # silently vanish. Claims run across ALL non-hidden-secondary RGs
    # (including type-filtered ones, so hiding e.g. Singles doesn't resurface
    # a matched single here). These tiles ARE the playable node (their feed is
    # the album tracklist), no MB detail to drill to.
    if ($prefs->get('show_library_extras')) {
        my @rgPool = grep {
            my $rg = $_;
            !grep { $HIDE_SECONDARY{$_} } @{ $rg->{secondary} };
        } @$rgs;
        my $claimed = ($local && @$local)
            ? Plugins::Discography::Sources->claimedLocalIds(\@rgPool, $opts->{artist}, $local, $relMap)
            : {};
        my @extras  = grep { !$claimed->{ $_->{_albumid} } } @{ $local || [] };

        # NOTE: a band's owned albums are NO LONGER folded in here (they used to
        # land in "Appearances" via Sources::bandAlbums). They now live behind
        # the "Also a member of" links section below — browse the band itself to
        # see its discography, rather than mixing it into this solo spine
        # (Simon's call, 2026-07-11). This section is now the artist's OWN library
        # orphans (odd editions, MB gaps) + VA comps/soundtracks they perform on.

        # Why did each orphan miss? mbid NONE = untagged/multi-disc; mbid present
        # but not in relMap = neither the artist browse nor the targeted lookup
        # has resolved it yet (or it's credited to another artist).
        if (@extras) {
            _dbg('library-extras (orphans): relMap=' . scalar(keys %$relMap) . ' releases'
                . ' | ' . join('; ', map {
                      my $mb = $_->{_mbid};
                      ($_->{_candTitle} // '?') . ' mbid=' . ($mb // 'NONE')
                          . ($mb ? ($relMap && exists $relMap->{$mb}
                                      ? '->rg:' . $relMap->{$mb}
                                      : '(not in relMap)') : '')
                  } @extras));
        }

        # Split into two sections:
        #   "Also in your library" — the artist's OWN albums MB's spine missed
        #      (album artist IS this artist).
        #   "Appearances"          — VA comps/soundtracks they only perform on
        #      (album artist is Various/someone else).
        # The album-artist field is the clean signal (verified: Dylan's own
        # albums read "Bob Dylan"; The Big Lebowski reads "Various Composers").
        my $an = Plugins::Discography::Sources::_norm($opts->{artist} // '');
        my (@own, @appear);
        for my $a (@extras) {
            my $ca = Plugins::Discography::Sources::_norm($a->{_candArtist} // '');
            # No album artist to judge -> keep it in "Also in your library"
            # (fail safe: never demote an unknown to Appearances).
            if (!length $ca || !length $an
                || Plugins::Discography::Sources::_artistMatch($an, $ca)) {
                push @own, $a;
            }
            else {
                push @appear, $a;
            }
        }

        push @items, _extraSection($client, $opts, $useH, $sort,
            'PLUGIN_DISCOGRAPHY_LIBRARY_EXTRAS',
            IMG_BASE . 'dsc-lib_MTL_icon_library_music.png', 'EXTRAS', \@own);
        push @items, _extraSection($client, $opts, $useH, $sort,
            'PLUGIN_DISCOGRAPHY_APPEARANCES',
            IMG_BASE . 'dsc-bio_MTL_icon_person.png', 'APPEAR', \@appear);
    }

    # ---------------------------------------------------------------------
    # "Also on <service>" — the STREAMING safety net.
    #
    # Exactly the same principle as "Also in your library": MusicBrainz is the
    # spine, and anything playable that the spine does not list must not
    # silently vanish. Field case (2026-07-19): MB has ONE release group for
    # the US rapper Manuel Gomez while Deezer carries TEN albums, so nine
    # records were invisible.
    #
    # These rows are the service plugins' OWN rendered nodes, so they browse
    # and play natively — no MB detail page to drill into, same as a library
    # extras tile.
    #
    # Depends on _filterForeignArtist: without it Qobuz's ~20 appears-on
    # entries by OTHER artist ids would land here as this artist's records.
    # ---------------------------------------------------------------------
    if ($prefs->get('show_streaming_extras')) {
        my @unclaimed;
        for my $svc (map { $_->{name} } @$sources) {
            next if $svc eq 'Local';
            my $claimed = $claimedSvc{$svc} || {};
            for my $it (@{ $pool->{bySvc}{$svc} || [] }) {
                next unless defined $it->{_albumid};
                next if $claimed->{ $it->{_albumid} };

                # CREDIT GATE. The pool is what a service returned for the
                # artist SEARCH, which includes records by other acts with
                # similar names and by bands this artist merely belongs to
                # (field, 2026-07-19: Sonic Boom's section listed Experimental
                # Audio Research releases). A matched release is verified by
                # the MB spine; an UNCLAIMED one has nothing vouching for it,
                # so it must at least be credited to this artist. Token-subset,
                # so "Panda Bear & Sonic Boom" still counts as his.
                #
                # LIMIT (measured 2026-07-19, do not mistake this for a bug to
                # fix here): this gate compares NAMES, so it is powerless when
                # the intruder shares the artist's name. Qobuz files at least
                # five different "Madness" acts under one artist id, all
                # credited "Madness", and 90 of that entity's 139 albums are
                # not the ska band's. Nothing available separates them — see
                # the show_streaming_extras note in Plugin.pm for the three
                # signals tested and why each fails. Hence the pref now
                # defaults OFF and the section is labelled unverified.
                next unless Plugins::Discography::Sources::_artistMatch(
                    $artistNorm,
                    Plugins::Discography::Sources::_norm($it->{_candArtist} // ''));

                my %t = %$it;
                $t{_svc} = $svc;   # line2 is built after the cross-service merge
                # Self-identifying go (stale-view fix): WITHOUT this the row
                # sends a positional item_id, the feed is rebuilt, and the click
                # lands on whatever now sits at that index — field 2026-07-19,
                # "Help Me Please" opened Experimental Audio Research's
                # "Phenomena 256". Every other actionable row here is
                # param-addressed; these were not.
                $t{id}          = 'str:' . $svc . ':' . $t{_albumid};
                $t{itemActions} = _listItemActions($opts, $t{id}, $t{play});
                push @unclaimed, \%t;
            }
        }
        # DEDUPE ACROSS SERVICES, as a matched release already does: one row per
        # album naming every service that carries it, not one row per service
        # (field, 2026-07-19: "Bajo Tu Voz · Tidal" directly above "Bajo Tu Voz
        # · Qobuz"). Keyed on title+year, so genuinely different records that
        # share a title stay apart. The FIRST occurrence wins the row, and the
        # loop above runs in source-priority order, so the preferred service
        # supplies the node that plays.
        my (@merged, %byKey);
        for my $t (@unclaimed) {
            my $k = join('|', Plugins::Discography::Sources::_norm($t->{name} // ''),
                              $t->{_year} // '');
            if (my $have = $byKey{$k}) {
                push @{ $have->{_svcs} }, $t->{_svc} if $t->{_svc};
                next;
            }
            $t->{_svcs} = [ $t->{_svc} ? $t->{_svc} : () ];
            $byKey{$k} = $t;
            push @merged, $t;
        }
        for my $t (@merged) {
            my %seen;
            my @svcs = grep { !$seen{$_}++ } @{ $t->{_svcs} || [] };
            $t->{line2} = join(" \x{00B7} ",
                grep { length } ($t->{_year} // ''), join('/', @svcs));
        }
        @unclaimed = @merged;

        if (@unclaimed) {
            my @dated   = sort { ($a->{_year} || 0) <=> ($b->{_year} || 0) }
                          grep {  $_->{_year} } @unclaimed;
            my @undated = grep { !$_->{_year} } @unclaimed;
            @dated = reverse @dated if $sort eq 'newest';
            my @tiles = (@dated, @undated);

            my ($vis, $pgRows) = _pageSection($client, $opts, 'STREAM', \@tiles);
            my $hdr = {
                name  => cstring($client, 'PLUGIN_DISCOGRAPHY_STREAM_EXTRAS')
                       . ' (' . scalar(@tiles) . ')',
                type  => $useH ? _headerType() : 'text',
                image => IMG_BASE . 'dsc-lib_MTL_icon_library_music.png',
            };
            if ($useH) {
                my @kids = (@$vis, @$pgRows);
                $hdr->{id}          = 'sect:STREAM';
                $hdr->{itemActions} = _listItemActions($opts, $hdr->{id});
                $hdr->{url}         = sub { $_[1]->({ items => \@kids }) };
                $hdr->{passthrough} = [{}];
            }
            push @items, $hdr, @$vis, @$pgRows;
        }
    }

    # "Also a member of" — LINKS to the discography of each band/project this
    # artist belongs to (MusicBrainz "member of band"; API::peekBands, warmed in
    # the MB chain). Shown regardless of show_library_extras: it's navigation,
    # not library content. Cache-cold on the very first render -> appears on
    # re-entry (same second-load contract as bootlegs/emblems). LAST section, so
    # a cold->warm flip only ever adds trailing rows — nothing above shifts.
    my $bands = Plugins::Discography::API->peekBands($mbid);
    if ($bands && @$bands) {
        push @items, _sectionHeader($client, 'PLUGIN_DISCOGRAPHY_ALSO_MEMBER_OF',
            $useH, IMG_BASE . 'dsc-bio_MTL_icon_person.png',
            [ map { _bandLinkRow($client, $opts, $_) }
                sort { lc($a->{name}) cmp lc($b->{name}) } @$bands ],
            { id => 'sect:BANDS', itemActions => _listItemActions($opts, 'sect:BANDS') });
        push @items, map { _bandLinkRow($client, $opts, $_) }
            sort { lc($a->{name}) cmp lc($b->{name}) } @$bands;
    }

    # "Similar artists" — MAI/Last.fm related artists, each a DRILL into that
    # artist's discography (identical behaviour to an "Also a member of" link,
    # only resolved by NAME rather than a known mbid). Same second-load contract
    # as the bands section (peek is cache-only; warmed after the first render ->
    # appears on re-entry) and it sits AFTER bands as the LAST section, so a
    # cold->warm flip only adds trailing rows. Kept in MAI's relevance order.
    # NB the CACHE is mbid-keyed but the DATA is not: _warmSimilarArtists asks
    # Last.fm (via MAI) by NAME, so a shared-name act's key holds the prominent
    # act's similar artists. Suppress rather than show the wrong band's peers.
    my $similar = $opts->{shared_name} ? undef : _peekSimilar($mbid);
    if ($similar && @$similar) {
        push @items, _sectionHeader($client, 'PLUGIN_DISCOGRAPHY_SIMILAR_ARTISTS',
            $useH, IMG_BASE . 'dsc-bio_MTL_icon_person.png',
            [ map { _similarLinkRow($client, $opts, $_) } @$similar ],
            { id => 'sect:SIMILAR', itemActions => _listItemActions($opts, 'sect:SIMILAR') });
        push @items, map { _similarLinkRow($client, $opts, $_) } @$similar;
    }

    return \@items;
}

# One "Also a member of" row: a DRILL-IN that renders the band's own discography
# as a nested sub-feed. (An earlier "re-stash %lastCtx + nextWindow refresh"
# design did NOT work: a refresh re-issues the person's TOP command WITH its
# artist params — 0.8.1 — which clobbers the band stash before it's read, so the
# view bounced straight back to the person. A drill-in instead renders the band
# inline via its own coderef, entered by mbid.) Each deeper click re-walks THROUGH
# this coderef, which deterministically re-renders the band, so nested navigation
# (band -> release detail) stays consistent. The band's library contributor id is
# resolved lazily (only on click) for exact local matching; absent when the band
# isn't owned (localAlbums' name fallback covers it).
# KNOWN LIMIT: toggles that refresh the TOP view (bio "Read more", section "Show
# more" paging) land on the PERSON, since a top refresh re-sends the person's
# params. Browse / sort / Refresh / drill-into-a-release all work. A band as a
# true top-level view (all toggles working) needs a fresh top command with the
# band's params, which a feed item can't emit from within — future work.
sub _bandLinkRow {
    my ($client, $opts, $band) = @_;
    return {
        name        => $band->{name},
        type        => 'link',
        # MAI image-proxy URL: the photo loads asynchronously in-view.
        image       => _artistImg($band->{name}),
        # Self-identifying go (stale-view fix): enters the band as a fresh
        # top-level view via the direct-mbid path — durable and, as a bonus,
        # retires the 0.26.1 known limit (top toggles landing on the person).
        itemActions => { items => { command => ['discography', 'items'],
            fixedParams => { mbid => $band->{mbid}, artist => $band->{name},
                (length($opts->{features} // '') ? (features => $opts->{features}) : ()) } } },
        passthrough => [{ band_mbid => $band->{mbid}, band_name => $band->{name},
                          features => $opts->{features} }],
        url         => sub {
            my ($c, $cb, $a, $p) = @_;
            my $bid = Plugins::Discography::Sources::_bandContributorId(
                $p->{band_mbid}, $p->{band_name});
            _dbg("band drill -> '$p->{band_name}' (mbid $p->{band_mbid}, artist_id "
                . ($bid // '-') . ')');
            _discographyView($c, $cb, {
                artist_id => $bid,
                artist    => $p->{band_name},
                mbid      => $p->{band_mbid},
                features  => $p->{features},
                sort      => $prefs->get('sort_order') || 'newest',
                force     => 0,
            });
        },
    };
}

# One "Similar artists" row: the SAME drill-in as a band link, but entered by
# NAME (these come from Last.fm with no mbid). The paramless person path
# (_resolveArtistMbid -> getArtistMbid) resolves the name exactly like a
# top-level entry, so browse / sort / Refresh / drill-into-a-release all work;
# an owned similar artist matches locally via localAlbums' name fallback.
# Image = MAI image-proxy URL, loads asynchronously in-view.
sub _similarLinkRow {
    my ($client, $opts, $name) = @_;
    return {
        name        => $name,
        type        => 'link',
        image       => _artistImg($name),
        # Self-identifying go (stale-view fix): fresh top-level entry by name.
        itemActions => { items => { command => ['discography', 'items'],
            fixedParams => { artist => $name,
                (length($opts->{features} // '') ? (features => $opts->{features}) : ()) } } },
        passthrough => [{ sim_name => $name, features => $opts->{features} }],
        url         => sub {
            my ($c, $cb, $a, $p) = @_;
            _dbg("similar drill -> '$p->{sim_name}'");
            _discographyView($c, $cb, {
                artist   => $p->{sim_name},
                features => $p->{features},
                sort     => $prefs->get('sort_order') || 'newest',
                force    => 0,
            });
        },
    };
}

# One library section ("Also in your library" or "Appearances"): year-sorted
# tiles, paged, with a walk-stable header. A band album names its band in line2,
# everything else says Local. Returns the feed rows (empty list when no albums).
sub _extraSection {
    my ($client, $opts, $useH, $sort, $token, $image, $pageKey, $albums) = @_;
    return () unless $albums && @$albums;

    my @dated   = sort { ($a->{_year} || 0) <=> ($b->{_year} || 0) } grep {  $_->{_year} } @$albums;
    my @undated =                                                    grep { !$_->{_year} } @$albums;
    @dated = reverse @dated if $sort eq 'newest';

    my @tiles = map {
        my %t = %$_;
        $t{line2} = join(" \x{00B7} ", grep { length } ($t{_year} // ''), ($t{_band} // 'Local'));
        # Self-identifying go + play (stale-view fix): the tile IS the playable
        # node (its feed = the album tracklist, play = a core-resolved db: url),
        # so go dispatches by id and play/add/insert carry the db: url directly.
        if ($t{_albumid}) {
            $t{id} = 'lib:' . $t{_albumid};
            $t{itemActions} = _listItemActions($opts, $t{id}, $t{play});
        }
        \%t;
    } @dated, @undated;

    my ($vis, $pgRows) = _pageSection($client, $opts, $pageKey, \@tiles);

    my $hdr = {
        name  => cstring($client, $token) . ' (' . scalar(@tiles) . ')',
        type  => $useH ? _headerType() : 'text',
        image => $image,
    };
    if ($useH) {
        my @kids = (@$vis, @$pgRows);
        $hdr->{id}          = 'sect:' . $pageKey;
        $hdr->{itemActions} = _listItemActions($opts, $hdr->{id});
        $hdr->{url}         = sub { $_[1]->({ items => \@kids }) };
        $hdr->{passthrough} = [{}];
    }
    return ($hdr, @$vis, @$pgRows);
}

# Section paging. Sections run long (Singles reaches the hundreds), so each is
# capped at PAGE_SIZE rows and grown a page at a time by a "Show more" row —
# the bio's refresh-toggle with a COUNT in the ctx instead of a boolean.
#
# Two properties this depends on:
#   - The row carries its target as an ABSOLUTE count, never "+= PAGE_SIZE".
#     Every deeper click re-executes the whole item_id path, so a relative
#     bump could advance the page more than once (the plugin-wide idempotence
#     rule). Paging rows are leaves, but absolute targets make that irrelevant.
#   - `page` survives the fresh-entry ctx reset in topLevel (same-artist
#     branch): these rows refresh the TOP view, whose re-fetch carries the
#     artist params, so it lands there.
#
# Cap also keeps typical views under Material's LMS_MAX_NON_SCROLLER_ITEMS
# (100), above which the fixed-row RecycleScroller clips tall text rows (bio).
#
# Returns (visible tiles, paging rows) — both go in the tree in that order.
sub _pageSection {
    my ($client, $opts, $key, $tiles) = @_;

    my $total = scalar @$tiles;
    return ($tiles, []) if $total <= PAGE_SIZE;

    my $ctx   = $lastCtx{ _cid($client) } ||= {};
    my $shown = $ctx->{page}{$key} || PAGE_SIZE;
    $shown = $total if $shown > $total;

    my @rows;
    if ($shown < $total) {
        my $next = $shown + PAGE_SIZE;
        $next = $total if $next > $total;
        push @rows, _pageRow($client, $opts, $key, $next,
            cstring($client, 'PLUGIN_DISCOGRAPHY_SHOW_MORE') . ' (' . ($total - $shown) . ')',
            PAGE_MORE);
    }
    if ($shown > PAGE_SIZE) {
        push @rows, _pageRow($client, $opts, $key, PAGE_SIZE,
            cstring($client, 'PLUGIN_DISCOGRAPHY_SHOW_LESS'), PAGE_LESS);
    }

    return ([ @$tiles[ 0 .. $shown - 1 ] ], \@rows);
}

sub _pageRow {
    my ($client, $opts, $key, $target, $name, $image) = @_;
    my $id = "page:$key:$target";
    return {
        name        => $name,
        type        => 'link',
        image       => $image,
        nextWindow  => 'refresh',
        id          => $id,
        itemActions => _listItemActions($opts, $id),
        passthrough => [{ key => $key, target => $target }],
        url         => sub {
            my ($c, $cb, $a, $p) = @_;
            my $ctx = $lastCtx{ _cid($c) } ||= {};
            # Collapsing back to the cap clears the key rather than storing the
            # default, so an unpaged section leaves no ctx residue.
            if ($p->{target} <= PAGE_SIZE) { delete $ctx->{page}{ $p->{key} } }
            else                           { $ctx->{page}{ $p->{key} } = $p->{target} }
            $cb->({ items => [] });
        },
    };
}

# Action rows live at the TOP of the feature's own view (fleet convention).
# Both re-enter _discographyView via passthrough with adjusted opts.
sub _sortToggleItem {
    my ($client, $opts) = @_;
    my $newest = ($opts->{sort} || 'newest') eq 'newest';
    my $flip   = $newest ? 'oldest' : 'newest';
    return {
        name        => cstring($client, $newest ? 'PLUGIN_DISCOGRAPHY_SORT_NEWEST'
                                                : 'PLUGIN_DISCOGRAPHY_SORT_OLDEST'),
        type        => 'link',
        image       => MENU_SORT,
        # Self-identifying go (stale-view fix): a FRESH entry with an explicit
        # sort param — same drill-in UX (new level, back returns), and the
        # opened view's own rows/toggles re-issue the sorted command, so the
        # order sticks throughout that view.
        itemActions => { items => { command => ['discography', 'items'],
            fixedParams => { _identParams({ %$opts, sort => $flip }) } } },
        passthrough => [{ %$opts, sort => $flip }],
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
        id          => 'act:refresh',
        itemActions => _listItemActions($opts, 'act:refresh'),
        passthrough => [{ mbid => $mbid, artist => $opts->{artist} }],
        url         => sub {
            my ($c, $cb, $a, $pass) = @_;
            # Full "re-check MusicBrainz": drop EVERY cached layer for this
            # artist — resolution (mbid + '' miss sentinel), release groups,
            # bootleg map, band members, bio, and streaming candidates — so the
            # re-entry re-pulls the lot. (A person view re-resolves by name; a
            # band view keeps its stashed mbid, so it re-pulls by mbid.)
            Plugins::Discography::API->clearArtistCache(
                name => $pass->{artist}, mbid => $pass->{mbid});
            Plugins::Discography::Sources->clearCandidates($pass->{artist}, $pass->{mbid})
                if defined $pass->{artist} && length $pass->{artist};
            $cb->({ items => [] });
        },
    };
}

# ---------------------------------------------------------------------------
# Global artist search — the plugin-view entry point that doesn't need the
# Material artist context menu.
#
# SUBMISSION IS PARAM-ADDRESSED (0.37.1 — the stale-walk fix, verified live:
# with an artist ctx stashed, the 0.37.0 positional submission walked into the
# artist view's Biography row and rendered "Empty"). The row is a `type =>
# 'search'` item WHOSE go ACTION IS OVERRIDDEN via itemActions: XMLBrowser's
# search branch builds its positional item_id+search action first, but the
# itemActions pass runs AFTER it and replaces `go` while keeping the `input`
# field (Control/XMLBrowser.pm:1188 vs :1274). Material types a row as a
# search input purely from its go-action params carrying the literal
# `__TAGGEDINPUT__` under `search` (browse-resp.js:279) and substitutes the
# typed term into those params on submit (browse-functions.js:2885) — so the
# submitted command is `search:<text>` + features, NO item_id, and topLevel's
# search dispatch renders the results directly: no positional walk, immune to
# whatever ctx is stashed. The url coderef stays for legacy (classic web skin)
# walks, which deliver the text as $args->{search} (XMLBrowser.pm:493).
# The row sits in the hint view AND the artist view's Options section, so it
# is reachable in both ctx states.
# ---------------------------------------------------------------------------
sub _searchRow {
    my ($client, $opts) = @_;
    my $features = $opts->{features} // '';
    # line2 names what the search actually covers (the enabled sources, in
    # priority order — same names the result rows use).
    my @srcs = map { $_->{name} } Plugins::Discography::Sources::orderedSources();
    return {
        name        => cstring($client, 'PLUGIN_DISCOGRAPHY_SEARCH'),
        type        => 'search',
        image       => MENU_SEARCH,
        (@srcs ? (line2 => join(" \x{00B7} ", @srcs)) : ()),
        itemActions => { items => { command => ['discography', 'items'],
            fixedParams => { search => '__TAGGEDINPUT__',
                (length $features ? (features => $features) : ()) } } },
        passthrough => [{ features => $features }],
        url         => \&_artistSearch,
    };
}

# Decorative banner row: random library ALBUM COVERS as a centred strip
# (0.40.1 — was MAI artist photos, but an artist MAI has no image for
# rendered as a blank/silhouette tile; covers are filtered to albums that
# HAVE artwork, so a blank is impossible, and need no MAI). Cover URLs are
# root-absolute so they resolve from Material's /material/ page. Fresh
# server-side random roll per render. Returns undef (no row) when the
# library has no artwork.
#
# RESPONSIVE COUNT (0.41.0): the server can't know the viewport (one feed
# serves every client; Material's PWA breakpoints never reach plugin rows),
# so the row carries MORE tiles than any screen needs (BANNER_MAX) at a
# FIXED size, and pure CSS shows exactly as many complete tiles as fit:
# flex-wrap pushes what doesn't fit onto a second row, which the one-row
# max-height + overflow:hidden clips. Phone ~3, tablet ~5-6, desktop ~9+,
# self-adjusting on resize/rotation. Hidden tiles cost only local thumbnail
# fetches (LMS-resized, cached).
sub _coverCollageRow {
    my ($client) = @_;
    my $covers = Plugins::Discography::Sources->randomAlbumCovers(BANNER_MAX);
    return undef unless @$covers;
    my $html = "<div style='display:flex;justify-content:center;align-items:center;"
             . "gap:12px;flex-wrap:wrap;max-height:" . BANNER_TILE_PX . "px;"
             . "overflow:hidden;margin:6px 8px'>";
    for my $src (@$covers) {
        $html .= "<img src='$src' style='width:" . BANNER_TILE_PX . "px;height:"
               . BANNER_TILE_PX . "px;border-radius:8px;flex:0 0 auto'/>";
    }
    $html .= '</div>';
    return { name => $html, type => 'text' };
}

# The app-root view — artist-photo banner, about, search, and a live
# plugin-status list, in the artist view's own visual language:
# _sectionHeader dividers (real headers under Material w/ features:hi, text
# dividers elsewhere), _proseRow indent for the about text, MTL/_svg icons
# throughout. Status rows are type 'text' + image: XMLBrowser styles text
# rows itemNoAction, so they render as dead one-liner rows with the plugin's
# icon — a status readout, not a control.
sub _rootView {
    my ($client, $features) = @_;
    my $useH = _wantHeaders($features);
    my @items;

    # --- Decorative album-cover banner, re-rolled every open ---
    # A single NON-clickable text row whose v-html is a strip of <img> tags
    # (Simon: decorative only, no drill). The BROWSER composes the collage —
    # no server-side image work (fleet rule: no GD/Imager). Skipped when the
    # library has no artwork. Being a text row it cannot affect grid state
    # beyond what the About prose already does.
    if (my $banner = _coverCollageRow($client)) {
        push @items, $banner;
    }

    # --- About ---
    # The second prose row carries bottom padding: a visual gap before the
    # "Find an artist" section (Simon: the sections butted together). Padding
    # INSIDE the row keeps the item count/shape untouched (walk stability).
    my @about = (
        _proseRow(cstring($client, 'PLUGIN_DISCOGRAPHY_ABOUT_1')),
        _proseRow(cstring($client, 'PLUGIN_DISCOGRAPHY_ABOUT_2'), ';padding-bottom:24px'),
    );
    push @items,
        _sectionHeader($client, 'PLUGIN_DISCOGRAPHY_ABOUT_HDR', $useH, ICON, \@about),
        @about;

    # --- Find an artist ---
    my @search = ( _searchRow($client, { features => $features }) );
    push @items,
        _sectionHeader($client, 'PLUGIN_DISCOGRAPHY_SEARCH_HDR', $useH, MENU_SEARCH, \@search),
        @search;

    # --- Works best with (live detection) ---
    # v-html rows (0.42.0, Simon: rows felt crowded, wanted the real service
    # badges and a tick instead of the word "detected"): each row is a dead
    # text row whose HTML lays out the plugin's OWN icon as a badge, the bold
    # name with a green tick (installed) or muted cross, and the role line —
    # with vertical margin for breathing room. Badge geometry mimics a native
    # icon row: 16px indent + 42px badge + 14px gap = text at the 72px avatar
    # column. A not-installed plugin has no local logo to serve, so a spacer
    # keeps the text aligned; ticks/crosses are HTML entities (the no-non-
    # ASCII-literals rule).
    # Badge src normalisation (0.42.1, field): _pluginDataFor('icon') is not
    # always a relative path — MAI returns a FULL REMOTE URL (herger.net
    # mai.svg), which a blind '/' prefix mangled into '/https://...' (broken
    # img). Remote icons go through LMS's imageproxy (server-cached,
    # same-origin — verified live: 200 image/svg+xml); relative paths get
    # root-anchored; already-absolute paths pass through.
    my $badgeSrc = sub {
        my ($icon) = @_;
        return undef unless $icon;
        if ($icon =~ m{^https?://}) {
            require URI::Escape;
            return '/imageproxy/' . URI::Escape::uri_escape($icon) . '/image_96x96_f.png';
        }
        return $icon =~ m{^/} ? $icon : "/$icon";
    };
    my $status = sub {
        my ($name, $installed, $roleToken, $img) = @_;
        my $mark = $installed
            ? "<span style='color:#4caf50;font-size:1.1em'>&#10003;</span>"
            : "<span style='opacity:.45;font-size:1.1em'>&#10007;</span>";
        my $role = _escHtml(cstring($client, $roleToken));
        $role .= " \x{00B7} " . _escHtml(cstring($client, 'PLUGIN_DISCOGRAPHY_SVC_NOT_DETECTED'))
            unless $installed;
        my $src   = $badgeSrc->($img);
        my $badge = $src
            ? "<img src='$src' style='width:42px;height:42px;border-radius:8px;flex:0 0 auto'/>"
            : "<div style='width:42px;height:42px;flex:0 0 auto'></div>";
        return { type => 'text', name =>
            "<div style='display:flex;align-items:center;gap:14px;margin:10px 8px 10px 16px'>"
          . $badge
          . "<div style='flex:1;min-width:0'>"
          . "<div style='font-weight:bold'>" . _escHtml($name) . " $mark</div>"
          . "<div style='opacity:.7'>$role</div>"
          . '</div></div>' };
    };
    # ONE capability probe for the whole section: adapters() walks every
    # service plugin's ->can() surface, and both the icon map and the
    # installed/not-installed status derive from that same list.
    my @adapters = Plugins::Discography::Sources::adapters();
    my %icon     = map { $_->{name} => $_->{icon} } @adapters;
    my @plugins;
    for my $s (@{ Plugins::Discography::Sources::serviceStatus(\@adapters) }) {
        push @plugins, $status->($s->{name}, $s->{installed},
            'PLUGIN_DISCOGRAPHY_ROLE_STREAM', $icon{ $s->{name} });
    }
    my $mai = eval { Slim::Utils::PluginManager->isEnabled('Plugins::MusicArtistInfo::Plugin') } ? 1 : 0;
    push @plugins, $status->('Music & Artist Information', $mai,
        'PLUGIN_DISCOGRAPHY_ROLE_MAI',
        $mai ? Plugins::Discography::Sources::_pluginIcon('Plugins::MusicArtistInfo::Plugin') : undef);
    # Material Skin exposes no plugin icon (_pluginDataFor('icon') is undef) —
    # use the skin's own served asset (verified live: 200).
    my $mat = eval { Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin') } ? 1 : 0;
    push @plugins, $status->('Material Skin', $mat,
        'PLUGIN_DISCOGRAPHY_ROLE_MATERIAL',
        $mat ? '/material/html/images/icon.png' : undef);
    push @items,
        _sectionHeader($client, 'PLUGIN_DISCOGRAPHY_PLUGINS_HDR', $useH,
            IMG_BASE . 'dsc-opt_MTL_icon_tune.png', \@plugins),
        @plugins;

    return { items => \@items };
}

# Legacy positional entry (classic web skin walk): same view, text from
# $args->{search}.
sub _artistSearch {
    my ($client, $callback, $args, $pt) = @_;
    my $features = ref $pt eq 'HASH' ? ($pt->{features} // '') : '';
    _artistSearchView($client, $callback, $features, $args->{search});
}

# Search every source, merge, render result rows. The MERGED list is cached
# briefly (SEARCH_TTL) so a re-issued identical query (view refresh, legacy
# re-walk) sees the identical ordering even if a service times out the second
# time.
sub _artistSearchView {
    my ($client, $callback, $features, $q) = @_;

    $q //= '';
    $q =~ s/^\s+|\s+$//g;
    # An unsubstituted placeholder means the client sent the action verbatim
    # without collecting input — treat as empty, never search for the literal.
    $q = '' if $q eq '__TAGGEDINPUT__';
    unless (length $q) { $callback->({ items => [] }); return }

    # v2: 0.37.1 gated results — bypass any cached ungated 0.37.0 lists.
    # v3: `mergeArtistHits` buckets by `_norm`, and the decorative-mark change
    # makes "Layo & Bushwacka!" and "Layo & Bushwacka" bucket TOGETHER. A v2
    # entry holds them as separate rows. Only a 10-minute TTL, but that is
    # exactly the window someone tests the fix in.
    my $ckey = 'dsc:asearch:6:' . lc $q;
    utf8::encode($ckey) if utf8::is_utf8($ckey);

    # Both the cached and the fresh path finish the same way: streaming rows
    # first, then the MusicBrainz same-name section (see _withMbCandidates).
    my $finish = sub {
        my ($merged) = @_;
        _withMbCandidates($client, $callback, $features, $q, $merged);
    };

    if (my $cached = $cache->get($ckey)) {
        _dbg("artist search '$q': cached (" . scalar(@$cached) . ' merged)');
        $finish->($cached);
        return;
    }

    Plugins::Discography::Sources->searchArtists($client, $q, sub {
        my ($bySvc, $failed) = @_;
        my $merged = Plugins::Discography::Sources->mergeArtistHits($q, $bySvc);
        my @bad    = sort keys %{ $failed || {} };
        _dbg("artist search '$q': " . scalar(@$merged) . ' merged from '
            . join(',', map { "$_=" . scalar(@{ $bySvc->{$_} }) } sort keys %$bySvc)
            . (@bad ? ' | FAILED: ' . join(',', @bad) : ''));
        # Only persist a COMPLETE result set. A service that errored or timed
        # out contributed an empty list, so caching here would pin the degraded
        # ordering for SEARCH_TTL and every retry inside the window would be
        # served from cache without re-searching (0.42.2). The user still sees
        # what did come back — it just isn't remembered, so retrying works.
        if (@bad) {
            _dbg("artist search '$q': NOT cached (incomplete)");
        }
        else {
            $cache->set($ckey, $merged, SEARCH_TTL);
        }
        $finish->($merged);
    });
}

# ---------------------------------------------------------------------------
# SAME-NAME ARTISTS FROM MUSICBRAINZ
#
# THE PROBLEM (field, 2026-07-18): several DIFFERENT acts share one name, and
# only one of them was reachable. Searching "Madness" found the ska band on
# every service; the seven other MB artists called Madness — a horrorcore
# rapper, a US funk rock group, an Indiana black metal band — could not be
# reached at all, and every route into the plugin (name search, or Search Hub
# handing off by name) landed on the SAME prominent act. Wrong discography, no
# way to correct it.
#
# The streaming services cannot fix this: their search returns whichever acts
# they happen to carry, under one indistinguishable name. MusicBrainz can — it
# models them as separate artists WITH disambiguation comments, which is the
# only thing that makes them tellable apart in a list.
#
# So the search results gain a section listing every MB artist of that name,
# each labelled with its comment ("English pop/ska band" / "Horrorcore rapper,
# member of Bedlam"). Each row enters by MBID, skipping name resolution
# entirely — which is the whole point, since the name is exactly what cannot
# distinguish them.
#
# Shown only when MB has MORE THAN ONE artist by the name: a single candidate
# is the act the streaming rows already lead to, and repeating it would just be
# a duplicate row. The MB lookup is cached (14d), so this costs one request per
# name and nothing on a repeat search.
# ---------------------------------------------------------------------------
sub _withMbCandidates {
    my ($client, $callback, $features, $q, $merged) = @_;

    # Drop rows whose page could only be empty BEFORE building any of them —
    # both the row list and the "already covered above" test below must see the
    # same set, or the disambiguation section would hide a candidate on the
    # strength of a row that is no longer there. No-op unless MB is un-throttled
    # (see API::filterRowsWithContent).
    Plugins::Discography::API->filterRowsWithContent($merged, sub {
    my ($kept) = @_;
    $merged = $kept;

    my @rows = @{ _searchResultItems($client, $merged, $features) };

    Plugins::Discography::API->getArtistCandidates($q, sub {
        my ($cands) = @_;
        $cands ||= [];

        if (@$cands < 2) {
            _dbg("artist search '$q': " . scalar(@$cands)
                . ' MB same-name artist(s) — no disambiguation section');
            return $callback->({ items => \@rows });
        }

        # WAIT for the release-group counts rather than filtering on whatever a
        # background warm happened to have finished.
        #
        # This used to fire the warm and filter on a PEEK, which meant the
        # counts never existed on the visit that mattered: the FIRST search for
        # a name rendered every candidate, and a later search silently removed
        # the empty ones. Field-confirmed 2026-07-19 — a first search for
        # "Bush" listed the "techno" act, which has zero release groups in MB.
        # Simon: "I dont want users getting confused by stuff showing then
        # disappearing", and chose correctness over resolution latency.
        #
        # COST: one MB browse per uncounted candidate, serialised at MB's
        # 1 req/s etiquette (mbGap) — milliseconds against a local mirror,
        # a few seconds against the public API, then cached for RGCOUNT_TTL.
        # The planned move to the hosted LMS-community API removes the
        # throttle, which is why this trade was acceptable.
        Plugins::Discography::API->warmCandidateCounts($cands, sub {

        # A candidate MB has catalogued NO releases for can only ever render an
        # empty page — drop it. undef still means SHOW: an HTTP failure leaves
        # the count uncached (see warmCandidateCounts), and a fetch that failed
        # must never be read as "this artist has nothing".
        my @live = grep {
            my $n = Plugins::Discography::API->peekReleaseGroupCount($_->{mbid});
            !defined $n || $n > 0;
        } @$cands;
        _dbg("artist search '$q': " . (scalar(@$cands) - scalar(@live))
            . ' MB artist(s) dropped as having no releases')
            if @live < @$cands;
        $cands = \@live;

        # A DIFFERENTLY SPELLED act is not something the user needs help
        # telling apart — "Mädness" reads as its own artist. Those belong in
        # the main result list, not under a "can't tell these apart" header,
        # and because their name is unique the name-keyed artist photo is
        # CORRECT for them (unlike the same-string acts, which would all get
        # the prominent act's picture).
        my (@distinct, @sameString);
        for my $c (@$cands) {
            if (lc($c->{name} // '') eq lc $q) { push @sameString, $c }
            else                               { push @distinct,   $c }
        }
        push @rows, map { _mbCandidateRow($client, $_, $features, 1) } @distinct;

        $cands = \@sameString;
        if (@$cands < 2) {
            _dbg("artist search '$q': " . scalar(@$cands)
                . ' same-spelling artist(s) after filtering — no section');
            return $callback->({ items => \@rows });
        }

        # DROP THE ACT THE ROWS ABOVE ALREADY REACH. getArtistCandidates sorts
        # by MB score, and the top one is exactly what name resolution picks —
        # so a streaming/library row for this name already drills into it, and
        # listing it again put the ska band on the page TWICE under a header
        # that says "OTHER artists" (field, 0.43.2).
        #
        # Only when such a row exists: with no result above (an artist absent
        # from every service and the library), the whole set must stay or the
        # prominent act becomes unreachable.
        my $qn = Plugins::Discography::Sources::_norm($q);
        my $covered = grep { Plugins::Discography::Sources::_norm($_->{name} // '') eq $qn }
                      @{ $merged || [] };
        my @show = @$cands;
        shift @show if $covered;
        unless (@show) {
            _dbg("artist search '$q': every MB artist is already listed above");
            return $callback->({ items => \@rows });
        }

        _dbg("artist search '$q': " . scalar(@$cands)
            . ' MB artists share this name — listing ' . scalar(@show)
            . ' other' . ($covered ? ' (top one already shown above)' : ''));

        my @mb = map { _mbCandidateRow($client, $_, $features) } @show;
        push @rows, _sectionHeader($client, 'PLUGIN_DISCOGRAPHY_SAME_NAME',
            _wantHeaders($features), IMG_BASE . 'dsc-bio_MTL_icon_person.png',
            \@mb);
        push @rows, @mb;

        $callback->({ items => \@rows });
        });   # warmCandidateCounts
    });
    });       # filterRowsWithContent
}

# One MB artist row. Entered by MBID (fixedParams `mbid`), which _discographyView
# takes as a resolved identity and browses directly — the name would resolve
# back to the prominent act and defeat the entire section.
sub _mbCandidateRow {
    my ($client, $cand, $features, $named) = @_;

    # The ALIAS is the name this artist's records are actually sold under on the
    # services ("Madness" the US rapper sells as "Tony Madness"), so it is often
    # the most recognisable thing on the row — and it explains why a row named
    # "Madness" leads to a catalogue filed elsewhere.
    my $alias = (@{ Plugins::Discography::API->peekArtistAliases($cand->{mbid}) || [] })[0];

    my @bits = grep { defined && length }
               ($cand->{disambiguation}, $cand->{type}, $cand->{country});
    unshift @bits, "aka $alias" if defined $alias && length $alias;
    my $line2 = @bits ? join(" \x{00B7} ", @bits)
                      : cstring($client, 'PLUGIN_DISCOGRAPHY_SAME_NAME_NOINFO');

    my %fixed = (
        mbid   => $cand->{mbid},
        artist => $cand->{name},
        (length($features // '') ? (features => $features) : ()),
    );
    return {
        name        => $cand->{name},
        type        => 'link',
        line2       => $line2,
        # _artistImg is keyed by NAME. For an act whose spelling is UNIQUE
        # ($named) that resolves to the right artist, so it gets a real photo.
        # For acts sharing one spelling it would hand every row the prominent
        # act's picture — worse than none on a list whose purpose is telling
        # them apart (field, 0.43.0) — so those keep the person icon.
        image       => $named ? _artistImg($cand->{name})
                              : IMG_BASE . 'dsc-bio_MTL_icon_person.png',
        itemActions => { items => { command => ['discography', 'items'],
            fixedParams => \%fixed } },
        passthrough => [{ c_mbid => $cand->{mbid}, c_name => $cand->{name},
                          features => $features }],
        url         => sub {
            my ($c, $cb, $a, $p) = @_;
            _dbg("MB same-name drill -> '$p->{c_name}' ($p->{c_mbid})");
            _discographyView($c, $cb, {
                mbid     => $p->{c_mbid},
                artist   => $p->{c_name},
                features => $p->{features},
                sort     => $prefs->get('sort_order') || 'newest',
                force    => 0,
            });
        },
    };
}

sub _searchResultItems {
    my ($client, $merged, $features) = @_;
    return [ { name => cstring($client, 'PLUGIN_DISCOGRAPHY_SEARCH_NONE'),
               type => 'text' } ] unless @$merged;
    return [ map { _searchResultRow($client, $_, $features) } @$merged ];
}

# One artist link row — the SAME drill-in as a similar-artist link, entered by
# name (plus the contributor id when the library knows the artist, so the
# reliable library-tag resolution path applies). line2 names the sources the
# artist was found on — the dedupe means one row can speak for several.
# (The 0.39.0 app-root spotlight also used this row with no sources, hence the
# old conditional line2; that section was replaced by the cover banner in
# 0.40.0, so search results are now the only caller and mergeArtistHits always
# records at least one source per bucket.)
sub _searchResultRow {
    my ($client, $hit, $features) = @_;
    my $name = $hit->{name};
    my %fixed = (
        artist => $name,
        ($hit->{artist_id}  ? (artist_id => $hit->{artist_id}) : ()),
        (length($features // '') ? (features => $features)     : ()),
    );
    return {
        name        => $name,
        type        => 'link',
        image       => _artistImg($name),
        line2       => join(" \x{00B7} ", @{ $hit->{sources} || [] }),
        # Self-identifying go (stale-view fix): fresh top-level entry.
        itemActions => { items => { command => ['discography', 'items'],
            fixedParams => \%fixed } },
        passthrough => [{ q_name => $name, q_aid => $hit->{artist_id},
                          features => $features }],
        url         => sub {
            my ($c, $cb, $a, $p) = @_;
            _dbg("search drill -> '$p->{q_name}'"
                . ($p->{q_aid} ? " (artist_id $p->{q_aid})" : ''));
            _discographyView($c, $cb, {
                artist_id => $p->{q_aid},
                artist    => $p->{q_name},
                features  => $p->{features},
                sort      => $prefs->get('sort_order') || 'newest',
                force     => 0,
            });
        },
    };
}

# One release-group tile: title, "year . Type [. services]" line, CAA art
# (native service art as fallback when a cached match carries one). The
# services part is OPPORTUNISTIC — cache-only (peekMatches never searches, so
# the list build stays sync and fast): before the artist's first drill-in the
# tiles are untagged; afterwards matched tiles name their services.
# A PLAYABLE url for a matched candidate — NOT the favurl. The ListenLater
# favurl (`<svc>://album:<id>`) is a Favorites/handshake reference, and only
# Tidal and Deezer resolve that form to tracks; Qobuz's ProtocolHandler explodes
# an album ONLY when the url ends in `.qbz` (verified live: `qobuz://album:ID`
# enqueues one bogus track titled "album:ID" — Simon's Now-Playing junk id;
# `qobuz://album:ID.qbz` plays the 17-track album). Local carries a real
# db:album.id play string already.
#   Local  -> item's own `play` (db:album.id=N)
#   Qobuz  -> qobuz://album:<id>.qbz
#   Tidal  -> tidal://album:<id>
#   Deezer -> deezer://album:<id>
sub _playUrl {
    my ($it) = @_;
    return undef unless ref $it eq 'HASH';
    return $it->{play} if defined $it->{play} && !ref $it->{play};   # Local db: url

    my $svc = lc($it->{_svc} // '');
    my $id  = $it->{_albumid};
    return undef unless length $svc && defined $id && length $id;
    return "qobuz://album:$id.qbz" if $svc eq 'qobuz';
    return "$svc://album:$id"      if $svc eq 'tidal' || $svc eq 'deezer';

    # Unknown service: fall back to the favurl minus our private query params.
    my $u = $it->{favorites_url};
    $u =~ s/\?.*$// if defined $u;
    return $u;
}

sub _releaseItem {
    my ($client, $opts, $rg, $sections) = @_;

    my $year = ($rg->{date} =~ /^(\d{4})/) ? $1 : '';
    my $type = _displayType($client, $rg);
    my $image = Plugins::Discography::API->caaImage($rg->{mbid});

    my ($favurl, $playUrl, $svcTag);
    if ($sections && @$sections) {
        $svcTag = join('/', map { $_->{svc} } @$sections);

        # Tile play = the PREFERRED source's play string — Local now has one
        # (db:album.id=N, core-resolved like album Favorites), so local-first
        # priority genuinely plays the library copy. The tile's own `play`
        # attr is advisory; the real mechanism is the detail feed's first
        # play-string row (XMLBrowser play collects those — see 0.9.4 log),
        # which _releaseDetail keeps in the same priority order.
        my $best = $sections->[0]{items}[0];
        $playUrl = _playUrl($best);

        # favurl (LL add + emblem badge) stays streaming-only — no service
        # scheme exists for a library album.
        my ($stream) = grep { $_->{svc} ne 'Local' } @$sections;
        $favurl = $stream->{items}[0]{favorites_url} if $stream;

        # A matched source (Local file art or the service's CDN cover, in
        # priority order) ALWAYS has art; the Cover Art Archive frequently 404s
        # even on dated releases (verified: Marc Almond "Against Nature" /
        # "The Dancing Marquis" — matched, but CAA-less -> blank tile). We can't
        # detect a CAA 404 server-side, and the source cover is already in the
        # candidate cache (no extra fetch, faster CDN load), so PREFER it and
        # keep the CAA url only as the fallback for a tile with no match yet
        # (pre-warm) or an unmatched release shown with hide_unmatched off.
        my ($cover) = grep { defined && length } map { $_->{items}[0]{_cover} } @$sections;
        $image = $cover if defined $cover && length $cover;
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
    #
    # itemActions = SELF-IDENTIFYING clicks (the stale-view fix): the go action
    # carries rg + full artist identity as explicit params instead of a
    # positional item_id, so a tap works no matter what was browsed in between
    # (topLevel's rg: dispatch renders the detail directly and re-stashes ctx).
    # play/add/insert route to the explicit ['discography','playcmd'] dispatch
    # for the same reason — XMLBrowser's default play action is positional too.
    # The url coderef stays for the legacy walk path and non-menu skins.
    return {
        name        => $rg->{title},
        line2       => $line2,
        type        => defined $playUrl ? 'playlist' : 'link',
        image       => $image,
        (defined $playUrl ? (play => $playUrl)           : ()),
        (defined $favurl  ? (favorites_url => $favurl)   : ()),
        itemActions => _rgItemActions($opts, $rg->{mbid}, undef, defined $playUrl),
        passthrough => [{ %$opts, rg => $rg }],
        url         => sub {
            my ($c, $cb, $a, $pass) = @_;
            _releaseDetail($c, $cb, $pass);
        },
    };
}

# The artist-identity params every self-addressed action carries — enough to
# rebuild the view from scratch (no %lastCtx needed).
sub _identParams {
    my ($opts) = @_;
    return (
        ($opts->{artist_id}              ? (artist_id => $opts->{artist_id}) : ()),
        (defined $opts->{artist} && length $opts->{artist}
                                         ? (artist    => $opts->{artist})    : ()),
        # ENTRY mbid ONLY (a band link enters by mbid; a person/name entry has
        # none) — deliberately NOT the resolved mbid, which would desync the
        # mbid-less refresh command and wipe the toggle ctx (0.8.1). Detail
        # actions add the resolved mbid explicitly via _rgIdent.
        ($opts->{entry_mbid}             ? (mbid      => $opts->{entry_mbid}) : ()),
        (length($opts->{features} // '') ? (features  => $opts->{features})  : ()),
        # The list view's sort rides the params end-to-end (a toggle-opened
        # view re-issues its own command on refresh, keeping its order).
        (($opts->{sort} // '') =~ /^(?:newest|oldest)$/
                                         ? (sort      => $opts->{sort})      : ()),
    );
}

# Identity + the release group (detail-view actions). Detail dispatch (_rgView)
# needs the RESOLVED artist mbid to fetch the RG list, so add it explicitly here
# — _identParams intentionally carries only the ENTRY mbid (see _buildList). For
# a band view the entry and resolved mbid are equal, so the duplicate key is
# harmless; for a person view _identParams omits mbid and this supplies it.
sub _rgIdent {
    my ($opts, $rgMbid) = @_;
    return { rg => $rgMbid,
             ($opts->{mbid} ? (mbid => $opts->{mbid}) : ()),
             _identParams($opts) };
}

# A LIST-view row's self-identifying actions: go re-enters topLevel with the
# artist identity + item:<id>, dispatched through _listItemDispatch (which
# rebuilds the list privately and invokes the row's own coderef). $playUrl
# (optional, whitelisted in playcmd) adds direct play/add/insert for the
# library-extras tiles (their play string is a core-resolved db: url — no
# resolution step needed).
sub _listItemActions {
    my ($opts, $id, $playUrl) = @_;
    my %ident = (_identParams($opts), item => $id);
    my %a = (
        items => { command => ['discography', 'items'], fixedParams => { %ident } },
    );
    if (defined $playUrl && length $playUrl) {
        for my $cmd (qw(play add insert)) {
            $a{$cmd} = {
                command     => ['discography', 'playcmd'],
                fixedParams => { %ident, cmd => $cmd, url => $playUrl },
            };
        }
    }
    return \%a;
}

# itemActions for a release tile or a detail-page row. $item = the row id
# within the detail view (undef for the tile itself -> go opens the detail).
# $playable adds explicit play/add/insert actions via the playcmd dispatch.
sub _rgItemActions {
    my ($opts, $rgMbid, $item, $playable) = @_;
    my $ident = _rgIdent($opts, $rgMbid);
    $ident->{item} = $item if defined $item;
    my %a = (
        items => { command => ['discography', 'items'], fixedParams => $ident },
    );
    if ($playable) {
        for my $cmd (qw(play add insert)) {
            $a{$cmd} = {
                command     => ['discography', 'playcmd'],
                fixedParams => { %$ident, cmd => $cmd },
            };
        }
    }
    return \%a;
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

    # Meta as an indented prose row (the view header already shows the
    # artwork; an image here would mutate the row to a clamped one-liner).
    my $metaTitle = _escHtml($rg->{title} . ($artist ? " \x{2013} $artist" : ''));
    my $metaSub   = _escHtml(join(" \x{00B7} ", grep { length } $rg->{date}, _displayType($client, $rg)));
    my $meta = {
        name => "<div style='margin-left:" . PROSE_INDENT . "'><b>$metaTitle</b>"
              . (length $metaSub ? "<br/>$metaSub" : '') . '</div>',
        type => 'text',
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

        my $useHdr = _wantHeaders($pass->{features});
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
                    map { (my $t = $_) =~ s/\s+/ /g; _proseRow($t) }
                    grep { /\S/ } split /\n{2,}/, $review;
                push @rows, {
                    name        => cstring($client, 'PLUGIN_DISCOGRAPHY_SHOW_LESS'),
                    type        => 'link',
                    image       => MENU_REVIEW,
                    nextWindow  => 'refresh',
                    id          => 'rev:less',
                    itemActions => _rgItemActions($pass, $rg->{mbid}, 'rev:less'),
                    passthrough => [{ mbid => $rg->{mbid} }],
                    url         => sub {
                        my ($c, $cb, $a, $p) = @_;
                        delete $lastCtx{ _cid($c) }{rev}{ $p->{mbid} };
                        $cb->({ items => [] });
                    },
                };
            }
            else {
                push @rows, _proseRow($summary);
                if ($truncated) {
                    push @rows, {
                        name        => cstring($client, 'PLUGIN_DISCOGRAPHY_FULL_REVIEW'),
                        type        => 'link',
                        image       => MENU_REVIEW,
                        nextWindow  => 'refresh',
                        id          => 'rev:more',
                        itemActions => _rgItemActions($pass, $rg->{mbid}, 'rev:more'),
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

        # Header above the review block (walk-stable: present iff review rows
        # are, and the review is cache-fixed for the visit).
        if (@rows) {
            my @kids = @rows;
            splice @rows, 0, 0, _sectionHeader($client, 'PLUGIN_DISCOGRAPHY_REVIEW', $useHdr,
                MENU_REVIEW, \@kids,
                { id => 'hdr:review',
                  itemActions => _rgItemActions($pass, $rg->{mbid}, 'hdr:review') });
        }

        my $preVersionRows = scalar @rows;
        my $keptPlay = 0;
        my $totalVersions = 0;
        $totalVersions += scalar @{ $_->{items} } for @$sections;
        my $showAll = $prefs->get('show_all_versions')
            || $lastCtx{ _cid($client) }{ver}{ $rg->{mbid} };
        if (!$showAll) {
            # Default: ONE row — the preferred service's best version (the
            # same node tile-play uses). Cuts the drill-in to a single
            # thumbnail; the all-services view stays behind the pref.
            if (@$sections) {
                my %row = %{ $sections->[0]{items}[0] };
                $row{line2} = $sections->[0]{svc};
                # A WORKING play string (Qobuz needs .qbz; the native url coderef
                # still handles drill + row Play, but tile-play-via-expansion
                # collects this string).
                my $p = _playUrl(\%row);
                $row{play} = $p if defined $p;
                $keptPlay = 1;
                $row{id} = 'v:' . $sections->[0]{svc} . ':0';
                $row{itemActions} = _rgItemActions($pass, $rg->{mbid}, $row{id}, 1);
                push @rows, \%row;

                # Inline expand to the full per-service layout (the same
                # refresh-toggle pattern as reviews/bios) — only offered when
                # there IS more than the one row.
                if ($totalVersions > 1) {
                    push @rows, {
                        name        => cstring($client, 'PLUGIN_DISCOGRAPHY_OTHER_VERSIONS'),
                        type        => 'link',
                        image       => IMG_BASE . 'dsc-ver_MTL_icon_unfold_more.png',
                        nextWindow  => 'refresh',
                        id          => 'ver:show',
                        itemActions => _rgItemActions($pass, $rg->{mbid}, 'ver:show'),
                        passthrough => [{ mbid => $rg->{mbid} }],
                        url         => sub {
                            my ($c, $cb, $a, $p) = @_;
                            $lastCtx{ _cid($c) }{ver}{ $p->{mbid} } = 1;
                            $cb->({ items => [] });
                        },
                    };
                }
            }
        }
        else {
            # One Material header divider per service, its playable versions
            # below. Same divider rules as the list view: emitted for every
            # client (only the type differs) so the tree is walk-stable; no
            # image on detail-page headers (nothing to brand — LBF's
            # detail-page convention; service icons are plain .png anyway,
            # which dividers never render).
            for my $sec (@$sections) {
                my @svcRows;
                my $vidx = 0;
                for my $it (@{ $sec->{items} }) {
                    my %row = %$it;
                    # Native node from the service plugin's own renderer (url
                    # coderef + passthrough), so play/add/insert work natively.
                    $row{line2} = $sec->{svc};
                    # Tile play collects EVERY play-string row in this feed
                    # (XMLBrowser one-level collection) — only the FIRST
                    # (preferred) version gets a WORKING play string (Qobuz
                    # needs .qbz) or tile play would enqueue every service's
                    # copy. The stripped rows still play via their url feeds.
                    if ($keptPlay) {
                        delete $row{play};
                    }
                    else {
                        my $p = _playUrl(\%row);
                        $row{play} = $p if defined $p;
                        $keptPlay = 1;
                    }
                    $row{id} = 'v:' . $sec->{svc} . ':' . $vidx++;
                    $row{itemActions} = _rgItemActions($pass, $rg->{mbid}, $row{id}, 1);
                    push @svcRows, \%row;
                }
                my $hdr = {
                    name => $sec->{svc} . ' (' . scalar(@svcRows) . ')',
                    type => $useHdr ? _headerType() : 'text',
                };
                if ($useHdr) {
                    my @kids = @svcRows;
                    $hdr->{id}          = 'hdr:' . $sec->{svc};
                    $hdr->{itemActions} = _rgItemActions($pass, $rg->{mbid}, $hdr->{id});
                    $hdr->{url}         = sub { $_[1]->({ items => \@kids }) };
                    $hdr->{passthrough} = [{}];
                }
                push @rows, $hdr, @svcRows;
            }

            if (!$prefs->get('show_all_versions') && $totalVersions > 1) {
                push @rows, {
                    name        => cstring($client, 'PLUGIN_DISCOGRAPHY_HIDE_VERSIONS'),
                    type        => 'link',
                    image       => IMG_BASE . 'dsc-ver_MTL_icon_unfold_more.png',
                    nextWindow  => 'refresh',
                    id          => 'ver:hide',
                    itemActions => _rgItemActions($pass, $rg->{mbid}, 'ver:hide'),
                    passthrough => [{ mbid => $rg->{mbid} }],
                    url         => sub {
                        my ($c, $cb, $a, $p) = @_;
                        delete $lastCtx{ _cid($c) }{ver}{ $p->{mbid} };
                        $cb->({ items => [] });
                    },
                };
            }
        }

        unless (@rows > $preVersionRows) {
            push @rows, _proseRow(cstring($client, 'PLUGIN_DISCOGRAPHY_NO_MATCH'));
        }

        # Side-effecting row -> nextWindow refresh (never a drill-in): clear
        # this artist's candidate caches and let the client re-fetch this very
        # page, which re-resolves fresh.
        push @rows, {
            name        => cstring($client, 'PLUGIN_DISCOGRAPHY_REFRESH_MATCHES'),
            type        => 'link',
            image       => MENU_REFRESH,
            nextWindow  => 'refresh',
            id          => 'act:refresh',
            itemActions => _rgItemActions($pass, $rg->{mbid}, 'act:refresh'),
            passthrough => [{ artist => $artist }],
            url         => sub {
                my ($c, $cb, $a, $p) = @_;
                Plugins::Discography::Sources->clearCandidates($p->{artist}, $p->{mbid});
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

    # Same spine as the list view, or the detail page resolves a DIFFERENT
    # service artist than the tile did and the two disagree — the exact class of
    # bug 0.18.0 fixed for the rival/MBID context.
    my $dSpine = _spineTitles(
        Plugins::Discography::API->peekReleaseGroups($pass->{mbid}));

    Plugins::Discography::Sources->getCandidates($client, $artist, 0, sub {
        my $bySvc = shift;
        my $local = Plugins::Discography::Sources->localAlbums($pass->{artist_id}, $artist);
        my $ambid = $pass->{mbid};   # artist MBID (carried on the tile)

        # Rebuild the SAME context the list used, so drill-in agrees with the
        # tile: tier-0 identity (the Local/Esher row that only matches by MBID)
        # and the same-title rival rule (a compilation must not show the album's
        # streaming versions). Falls back to plain title matching if a stale
        # passthrough (pre-mbid) or a cold cache leaves the maps unavailable.
        my $relMap = { %{ $ambid ? (Plugins::Discography::API->peekReleaseMap($ambid) || {}) : {} },
                       %{ Plugins::Discography::API->peekLocalReleaseMap(
                              [ map { $_->{_mbid} } grep { $_->{_mbid} } @$local ] ) } };

        my $finish = sub {
            my ($rivalBucket) = @_;
            $sections = Plugins::Discography::Sources->matchesFor(
                $bySvc, $artist, $rg->{title}, $local, $rg->{mbid}, $relMap, $rivalBucket);
            $sectionsDone = 1;
            # Review needs $sections (Qobuz-description fallback rides the match).
            _fetchAlbumReview($client, $artist, $rg->{title}, $rg->{mbid}, $sections, sub {
                $review = shift;
                $reviewDone = 1;
                $compose->() if defined $links;
            });
        };

        # Rivals need every same-title release-group; the RG list is cached from
        # the list view, so this is a cache hit. No mbid (stale passthrough) ->
        # skip the rival rule rather than force a fetch.
        if ($ambid) {
            Plugins::Discography::API->getReleaseGroups(
                mbid   => $ambid,
                onDone => sub {
                    my $rgs = shift;
                    my $rivals = _rivalsByTitle($rgs,
                        Plugins::Discography::API->peekOfficial($ambid));
                    $finish->($rivals->{ Plugins::Discography::Sources::_norm($rg->{title}) });
                },
                onError => sub { $finish->(undef) },
            );
        }
        else {
            $finish->(undef);
        }
    }, { spine => $dSpine, mbid => $pass->{mbid} });
}

1;
