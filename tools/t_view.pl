#!/usr/bin/env perl
#
# REGRESSION TEST: the artist page's Albums | Singles view (after 0.54.6).
#
# Simon, 2026-09-24 (LBF's "Showing ..." toggle): one cycling row in Options
# flips the page between the EPs + Singles sections (a true tab: no bio, extras
# or links) and every other release section. Drives the REAL _buildList with
# the services stubbed, and pins what the view must NOT change: a streaming
# album claimed by a SINGLE must not resurface in "Also on streaming" on the
# Albums view (claims are computed for every release before the view filters).
#
# Standalone, no LMS install needed:  perl tools/t_view.pl
#
use strict;
use warnings;
use FindBin;

our (%PREF, %MATCH, $POOL, $BANDS, $SIMILAR);

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers Slim::Utils::Strings
                  Slim::Control::Request Slim::Schema Slim::Web::HTTP
                  Slim::Networking::SimpleAsyncHTTP Slim::Utils::Misc
                  Plugins::Discography::Plugin Plugins::Discography::API
                  Plugins::Discography::Sources)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Cache' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Cache' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Slim::Utils::Strings::cstring'}   = sub {
        my $t = $_[1];
        return 'Showing %s (tap for %s)' if $t eq 'PLUGIN_DISCOGRAPHY_SHOWING';
        return 'Albums'  if $t eq 'PLUGIN_DISCOGRAPHY_ALBUMS';
        return 'Singles' if $t eq 'PLUGIN_DISCOGRAPHY_SINGLES';
        return 'Singles & EPs' if $t eq 'PLUGIN_DISCOGRAPHY_SINGLES_EPS';
        return $t };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    # Section 8's tile-strip run (a child process: _useStrips caches its answer).
    *{'Plugins::MaterialSkin::Plugin::getPluginVersion'} = sub { '6.4.10.8' } if $ENV{T_VIEW_STRIPS};
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');

    my $S = 'Plugins::Discography::Sources';
    my $A = 'Plugins::Discography::API';
    *{"${S}::_norm"} = sub { my $s = lc($_[-1] // ''); $s =~ s/[^a-z0-9]+/ /g; $s =~ s/^ +| +$//g; $s };
    *{"${S}::_artistMatch"}   = sub { 1 };
    *{"${S}::orderedSources"} = sub { ({ name => 'Qobuz' }) };
    *{"${S}::localAlbums"}    = sub { [] };
    *{"${S}::localTracks"}    = sub { [] };
    *{"${S}::peekPool"}       = sub { $main::POOL };
    *{"${S}::claimedLocalIds"} = sub { {} };
    *{"${S}::peekMatches"}    = sub { my ($c, $artist, $title) = @_;
        { sections => $main::MATCH{$title} || [], resolved => 1 } };
    *{"${A}::caaImage"}           = sub { 'caa' };
    *{"${A}::peekCoverFlags"}     = sub { undef };   # ListenBrainz never answered: every group maybe
    *{"${A}::peekOfficial"}       = sub { undef };
    *{"${A}::peekReleaseMap"}     = sub { {} };
    *{"${A}::peekLocalReleaseMap"} = sub { {} };
    *{"${A}::peekEditions"}       = sub { {} };
    *{"${A}::clearArtistEmpty"}   = sub { 0 };
    *{"${A}::markArtistEmpty"}    = sub { };
    *{"${A}::peekBands"}          = sub { $main::BANDS };
    *{"${A}::peekCollabs"}        = sub { undef };
    # The artist's other names (_otherNames): none cached.
    *{"${A}::peekArtistName"}     = sub { undef };
    *{"${A}::peekArtistAliases"}  = sub { undef };
    *{"${A}::peekArtistEnglishName"} = sub { undef };
}

package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}
package T::Prefs; our $AUTOLOAD; sub get { $main::PREF{ $_[1] } } sub AUTOLOAD { return } sub DESTROY {}
package T::Cache; our $AUTOLOAD; sub get { $_[1] =~ /^dsc:similar:/ ? $main::SIMILAR : undef }
sub AUTOLOAD { return } sub DESTROY {}

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;
my $B = 'Plugins::Discography::Browse';

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

%PREF = (show_types => 'ALBUMS,EPS,SINGLES,COMPILATIONS,LIVE,OTHER', show_bio => 1,
         show_library_extras => 1, show_streaming_extras => 1, hide_unmatched => 0);

my $n = 0;
sub rg { my ($title, $type, @sec) = @_;
    { mbid => sprintf('%08d-0000-0000-0000-000000000000', ++$n), title => $title, type => $type,
      secondary => [@sec], date => '2000-01-01' } }
sub cand { my ($title, $id) = @_;
    { name => $title, type => 'playlist', _svc => 'Qobuz', _albumid => $id, _candArtist => 'Radiohead',
      favorites_url => "qobuz://album:$id", _year => 2000 } }

my @full = (rg('Kid A', 'Album'), rg('Airbag EP', 'EP'), rg('I Might Be Wrong', 'Album', 'Live'),
            rg('Creep', 'Single'), rg('Karma Police', 'Single'));
# "Creep" (a SINGLE) claims a streaming album; "Pablo Honey" nobody claims.
my $creep = cand('Creep', 'q-creep');
%MATCH = ('Creep' => [ { svc => 'Qobuz', items => [ $creep ] } ]);
$POOL  = { bySvc => { Qobuz => [ $creep, cand('Pablo Honey', 'q-pablo') ] } };
$BANDS = [ { mbid => 'b1', name => 'Atoms for Peace' } ];
$SIMILAR = [ 'Blur' ];

my $opts = { artist_id => 1, artist => 'Radiohead', features => 'hi', sort => 'newest' };
sub build {
    my ($rgs) = @_;
    return $B->can('_buildList')->(undef, { %$opts }, 'artist-mbid', $rgs, 'A bio paragraph.', []);
}
sub ids   { map { $_->{id} // () } @{ $_[0] } }
sub has   { my ($items, $id) = @_; scalar grep { ($_->{id} // '') eq $id } @$items }
sub togs  { scalar grep { ($_->{id} // '') =~ /^act:view/ } @{ $_[0] } }
sub row   { my ($items, $id) = @_; (grep { ($_->{id} // '') eq $id } @$items)[0] }

# Section 8 as tile strips (run by section 8 in a child process): a strip shows
# STRIP_SIZE tiles of its full list and only those are queued; its header's own
# page queues the rest.
if ($ENV{T_VIEW_STRIPS}) {
    my @wanted;
    no warnings qw(redefine once);
    local *Plugins::Discography::Covers::want = sub { push @wanted, $_[0] };
    local *Plugins::Discography::API::caaImage = sub { "caa-$_[1]" };
    my $items = build([ map { rg("Album $_", 'Album') } 1 .. 40 ]);
    my ($hdr) = grep { ($_->{id} // '') eq 'sect:ALBUMS' } @$items;
    ok(scalar($hdr && ($hdr->{type} // '') eq 'header-strip'), '8s: the Albums section is a tile strip');
    ok(scalar(@wanted == 30), '8s: 40 albums in a strip of 30 -> 30 queued (got ' . scalar(@wanted) . ')');
    @wanted = ();
    $hdr->{url}->(undef, sub {});
    ok(scalar(@wanted == 40), "8s: opening the strip's header queues all 40");
    print "\n$pass passed, $fail failed\n";
    exit($fail ? 1 : 0);
}

# 1. Albums view (the default).
my $a = build(\@full);
ok(scalar(has($a, 'sect:ALBUMS') && has($a, 'sect:LIVE')), '1: Albums view shows Albums and Live');
ok(scalar(!has($a, 'sect:SINGLES') && !has($a, 'sect:EPS')), '1: Albums view hides the Singles and EPs sections');
ok(scalar(has($a, 'sect:BIO') && has($a, 'sect:BANDS') && has($a, 'sect:SIMILAR')),
   '1: Albums view keeps the bio and the band/similar links');
my $tog = row($a, 'act:view:singles');
ok(scalar($tog && $tog->{name} eq 'Showing Albums (tap for Singles & EPs)'), '1: toggle reads "Showing Albums (tap for Singles & EPs)"');
my @opt = ids($a);
my ($oi) = grep { ($opt[$_] // '') eq 'sect:OPT' } 0 .. $#opt;
ok(scalar(defined $oi && ($opt[$oi + 1] // '') eq 'act:view:singles'), '1: the toggle is the first Options row');
ok(scalar(($tog->{nextWindow} // '') eq 'refresh'), '1: the toggle flips in place (nextWindow refresh)');
ok(scalar(($tog->{itemActions}{items}{fixedParams}{item} // '') eq 'act:view:singles'), '1: the toggle tap is param-addressed, target in the id');
ok(scalar(!grep { ($_->{id} // '') eq 'str:Qobuz:q-creep' } @$a),
   "1: a streaming album claimed by a SINGLE does not resurface under Also on streaming");
ok(scalar(grep { ($_->{id} // '') eq 'str:Qobuz:q-pablo' } @$a), '1: an unclaimed one still does');

# 2. Tap the toggle -> Singles view.
$tog->{url}->(undef, sub { }, {}, $tog->{passthrough}[0]);
my $s = build(\@full);
ok(scalar(has($s, 'sect:SINGLES') && has($s, 'sect:EPS')), '2: Singles view shows the EPs and Singles sections');
my @sids = ids($s);
my ($ie) = grep { $sids[$_] eq 'sect:EPS' } 0 .. $#sids;
my ($is) = grep { $sids[$_] eq 'sect:SINGLES' } 0 .. $#sids;
ok(scalar(defined $ie && defined $is && $ie < $is), '2: EPs come before Singles, each its own section');
ok(scalar(!has($s, 'sect:ALBUMS') && !has($s, 'sect:LIVE')),
   '2: Singles view hides every other release section');
ok(scalar(!has($s, 'sect:BIO') && !has($s, 'sect:BANDS') && !has($s, 'sect:SIMILAR') && !has($s, 'sect:STREAM')),
   '2: Singles view is a true tab: no bio, extras or links');
ok(scalar(has($s, 'sect:OPT') && has($s, 'opt:more') && has($s, 'act:search') && !has($s, 'sect:FIND')),
   '2: Options (collapsed, with Search) is still there');
ok(scalar((ids($s))[0] eq 'sect:OPT'), '2: Options first on the Singles tab too');
my $tog2 = row($s, 'act:view:albums');
ok(scalar($tog2 && $tog2->{name} eq 'Showing Singles & EPs (tap for Albums)'), '2: toggle now reads "Showing Singles & EPs (tap for Albums)"');
ok(scalar(($tog2->{image} // '') =~ /release-single/), "2: the toggle's icon shows the current view");
ok(scalar(grep { ($_->{name} // '') eq 'Creep' } @$s), '2: Creep is on the Singles view');

# 3. Idempotent + back to Albums.
$tog->{url}->(undef, sub { }, {}, $tog->{passthrough}[0]);   # the OLD row again: absolute target
ok(scalar(has(build(\@full), 'sect:SINGLES')), '3: a re-walked tap sets the same view (absolute target)');
$tog2->{url}->(undef, sub { }, {}, $tog2->{passthrough}[0]);
ok(scalar(has(build(\@full), 'sect:ALBUMS')), '3: tapping again returns to Albums');

# 4. Clamping: a page with only one family never opens empty and shows no toggle.
my @albumsOnly = (rg('OK Computer', 'Album'), rg('Amnesiac', 'Album'));
$tog->{url}->(undef, sub { }, {}, $tog->{passthrough}[0]);   # stored view = singles
my $ao = build(\@albumsOnly);
ok(scalar(has($ao, 'sect:ALBUMS') && !togs($ao)), '4: albums-only artist: Albums shown, no toggle (even with Singles stored)');
$tog2->{url}->(undef, sub { }, {}, $tog2->{passthrough}[0]); # stored view = albums
my $so = build([ rg('Lift', 'Single'), rg('Man of War', 'Single') ]);
ok(scalar(has($so, 'sect:SINGLES') && !togs($so)), '4: singles-only artist: opens on Singles, no toggle');
ok(scalar(has($so, 'sect:BIO') && has($so, 'sect:BANDS') && has($so, 'sect:SIMILAR')),
   '4: a singles-only artist keeps its bio and links (no Albums view to hold them, no toggle to reach one)');
$tog2->{url}->(undef, sub { }, {}, $tog2->{passthrough}[0]);
my $eo = build([ rg('Airbag EP', 'EP'), rg('Lift', 'Single') ]);
ok(scalar(has($eo, 'sect:EPS') && has($eo, 'sect:SINGLES') && !togs($eo) && has($eo, 'sect:BIO')),
   '4: an EPs-and-singles-only artist opens on that view, no toggle, keeps its bio');

# 5. The fresh-entry ctx rebuild keeps `view` for the same artist (source check:
#    topLevel is async + HTTP-bound; the rule is the one line in the $same branch).
{
    open my $fh, '<', "$FindBin::Bin/../Discography/Browse.pm" or die $!;
    my $src = do { local $/; <$fh> };
    ok(scalar($src =~ /\$same \? \([^)]*view\s*=>\s*\$prev->\{view\}[^)]*\) : \(\)/s),
       '5: a same-artist fresh entry keeps the view flag');
}

# 6. A REAL tap: Material sends item=<the toggle's own item param>; topLevel runs
#    _listItemDispatch, which rebuilds the page from the SERVER's current view and
#    runs the row _findRow finds. A stale tap (double tap before the refresh lands,
#    or a second Material window on the same player) must land where the button
#    promised, never flip relative to the server's state (the absolute-target rule).
{
    no warnings 'redefine'; no strict 'refs';
    local *{"${B}::_discographyView"} = sub { my ($c, $cb) = @_; $cb->({ items => build(\@full) }) };
    my $view = sub { my $p = build(\@full); has($p, 'sect:ALBUMS') ? 'albums' : has($p, 'sect:SINGLES') ? 'singles' : '?' };
    my $togOf = sub { (grep { (($_->{itemActions} || {})->{items}{fixedParams}{item} // '') =~ /^act:view/ } @{ $_[0] })[0] };
    my $tapId = sub { (($togOf->($_[0]) || {})->{itemActions} || {})->{items}{fixedParams}{item} };
    my $got;
    my $dispatch = sub { $got = undef; $B->can('_listItemDispatch')->(undef, sub { $got = shift }, { %$opts }, $_[0]) };

    ok(scalar($view->() eq 'albums'), '6: starts on Albums');
    my $fromAlbums  = $tapId->(build(\@full));
    ok(scalar(defined $fromAlbums && $togOf->(build(\@full))->{id} eq $fromAlbums),
       "6: the tap's item param IS the toggle row's id (the dispatch finds the row it came from)");
    $dispatch->($fromAlbums);
    ok(scalar($view->() eq 'singles'), '6: a tap from the Albums page opens Singles');
    ok(scalar(ref $got eq 'HASH'), '6: the dispatch answered (the refresh then re-renders)');
    my $fromSingles = $tapId->(build(\@full));
    ok(scalar(defined $fromSingles && $fromSingles ne $fromAlbums),
       '6: the two pages send DIFFERENT taps (the target rides in the id)');

    $dispatch->($fromAlbums);                       # the same Albums-page tap again
    ok(scalar($view->() eq 'singles'), '6: a stale second tap from the Albums page STAYS on Singles (no flip back)');
    ok(scalar(ref $got eq 'HASH'), '6: ...and still answers, so the refresh lands');

    $dispatch->($fromSingles);
    ok(scalar($view->() eq 'albums'), '6: a tap from the Singles page returns to Albums');
    $dispatch->($fromSingles);
    ok(scalar($view->() eq 'albums'), '6: a stale second tap from the Singles page STAYS on Albums');

    $dispatch->($fromAlbums); $dispatch->($fromAlbums); $dispatch->($fromAlbums);
    ok(scalar($view->() eq 'singles'), '6: three taps from one Albums page = Singles (idempotent)');
    $dispatch->($fromSingles);                      # leave it on Albums

    # A stale toggle tap on an artist with no toggle: harmless, answers, view kept.
    local *{"${B}::_discographyView"} = sub { my ($c, $cb) = @_;
        $cb->({ items => build([ rg('OK Computer', 'Album'), rg('Amnesiac', 'Album') ]) }) };
    $dispatch->($fromAlbums);
    ok(scalar(ref $got eq 'HASH' && !@{ $got->{items} || [] }), '6: a toggle tap where there is no toggle answers empty');
}
ok(scalar(has(build(\@full), 'sect:ALBUMS')), '6: ...and changes nothing');

# 7. Every param-addressed row on both views: the tap finds ITS OWN row, and no two
#    rows share an id (a duplicate would make _findRow run the first one).
for my $v (['albums', $tog2], ['singles', $tog]) {
    $v->[1]{url}->(undef, sub { }, {}, $v->[1]{passthrough}[0]);
    my $p = build(\@full);
    my @bad = grep { my $i = (($_->{itemActions} || {})->{items}{fixedParams} || {})->{item};
                     defined $i && ($_->{id} // '') ne $i } @$p;
    ok(scalar(!@bad), "7: $v->[0] view: every row's tap names its own id");
    my %seen; my @dup = grep { $seen{$_}++ } ids($p);
    ok(scalar(!@dup), "7: $v->[0] view: row ids are unique (" . join(',', @dup) . ')');
}

# 8. The covers a page SHOWS are queued for the fetch after the visit
#    (0.56.27): the visible tiles of a paged section, not the ones behind
#    "Show more"; a tile with its own cover queues nothing.
{
    my @wanted;
    no warnings qw(redefine once);
    local *Plugins::Discography::Covers::want = sub { push @wanted, $_[0] };
    local *Plugins::Discography::API::caaImage = sub { "caa-$_[1]" };
    my @many = map { rg("Album $_", 'Album') } 1 .. 35;
    my $cov = { %{ cand('Covered', 'q-cov') }, _cover => 'https://static.qobuz.com/c.jpg' };
    local %MATCH = (%MATCH, 'Covered' => [ { svc => 'Qobuz', items => [ $cov ] } ]);
    my $items = build([ @many, rg('Covered', 'Album') ]);
    my %shown = map { ($_->{_caaWant} // '') => 1 } grep { ref $_ eq 'HASH' && $_->{_caaWant} } @$items;
    my $shownWant = grep { ref $_ eq 'HASH' && $_->{_caaWant} } @$items;
    ok(scalar(@wanted == $shownWant && $shownWant >= 29 && $shownWant <= 30),
       "8: 36 albums, 30 shown -> only the shown icon tiles queued ($shownWant, not 35)");
    ok(scalar(!grep { !$shown{$_} } @wanted), '8: every queued cover is a tile on the page');
    my $coveredMbid = (grep { $_->{title} eq 'Covered' } map { $_->{passthrough}[0]{rg} // () }
                       grep { ref $_->{passthrough} eq 'ARRAY' } @$items)[0];
    ok(scalar(!$coveredMbid || !grep { $_ eq "caa-$coveredMbid->{mbid}" } @wanted),
       '8: the album with its own cover is not queued');
    open my $fh, '<', "$FindBin::Bin/../Discography/Browse.pm" or die "Browse.pm: $!";
    my $src = do { local $/; <$fh> };
    ok(scalar($src =~ /\$hdr->\{url\}\s*=\s*sub \{ _wantCovers\(\\\@kids\);/),
       "8: a strip header's own page queues its full list");
    local $ENV{T_VIEW_STRIPS} = 1;
    my $out = qx{"$^X" "$0" 2>&1};
    ok(scalar($? == 0 && $out =~ /\b3 passed, 0 failed/), '8: as tile strips, only the strip\'s shown tiles are queued');
    print map { "    | $_\n" } grep { /^(ok|FAIL)/ } split /\n/, $out;
}

# 9. ListenBrainz's cover flags reach the tiles (0.56.30): the page asks once
#    for ITS artist, and a release flagged as having no archive cover keeps its
#    icon and is not wanted; flagged or unlisted ones are wanted as before.
{
    my (@wanted, @asked);
    no warnings qw(redefine once);
    local *Plugins::Discography::Covers::want = sub { push @wanted, $_[0] };
    local *Plugins::Discography::API::caaImage = sub { "caa-$_[1]" };
    my @rgs = map { rg("Flag $_", 'Album') } 1 .. 6;
    my %flags = (lc $rgs[0]{mbid} => 0, lc $rgs[1]{mbid} => 0, lc $rgs[2]{mbid} => 1);
    local *Plugins::Discography::API::peekCoverFlags = sub { push @asked, $_[1]; \%flags };
    my $items = build(\@rgs);
    ok(scalar("@asked" eq 'artist-mbid'), "9: the flags are read once, for the page's own artist (got '@asked')");
    my %w = map { $_ => 1 } @wanted;
    ok(scalar(!$w{"caa-$rgs[0]{mbid}"} && !$w{"caa-$rgs[1]{mbid}"}), '9: the two flagged with no cover are not wanted');
    ok(scalar($w{"caa-$rgs[2]{mbid}"} && $w{"caa-$rgs[3]{mbid}"} && $w{"caa-$rgs[5]{mbid}"} && @wanted == 4),
       '9: the one flagged with a cover and the three unlisted are (' . scalar(@wanted) . ')');
    my ($t0) = grep { ref $_ eq 'HASH' && ($_->{name} // '') eq 'Flag 1' } @$items;
    ok(scalar($t0 && ($t0->{image} // '') !~ /^caa-/ && !exists $t0->{_caaWant}),
       '9: a flagged-none tile shows its type icon and names nothing to fetch');
}

# 10. OPTIONS COLLAPSED (0.56.32; Simon 2026-10-02: hide the options "like we do
#     with text and open up if needed", "keep the Albums switch visible all else
#     hidden"), SEARCH BACK IN OPTIONS, ALWAYS VISIBLE (0.56.35: "Lets put search
#     back in options. It only needs icon though to move us to search page").
#     Through the REAL _buildList and _listItemDispatch, the bio Read more's
#     mechanics.
{
    no warnings 'redefine'; no strict 'refs';
    local *{"${B}::_discographyView"} = sub { my ($c, $cb) = @_; $cb->({ items => build(\@full) }) };
    my $tap = sub { my $got; $B->can('_listItemDispatch')->(undef, sub { $got = shift }, { %$opts }, $_[0]); $got };
    my $SORT  = 'plugins/Discography/html/images/dsc-sort_MTL_icon_sort.png';
    my $LOCAL = 'plugins/Discography/html/images/dsc-lib_MTL_icon_library_music.png';
    # The rows between the Options header and the next header, by id or image.
    my $optKinds = sub {
        my ($items) = @_;
        my @i = @$items;
        my ($o) = grep { ($i[$_]{id} // '') eq 'sect:OPT' } 0 .. $#i;
        return () unless defined $o;
        my @k;
        for my $r (@i[$o + 1 .. $#i]) {
            last if ($r->{type} // '') =~ /^header/;
            push @k, ($r->{image} // '') eq $SORT ? 'sort' : ($r->{image} // '') eq $LOCAL ? 'local'
                   : ($r->{id} // '') =~ /^act:view:/ ? 'view' : ($r->{id} // '?');
        }
        return @k;
    };
    $tap->('opt:less');                                  # start closed, whatever ran before
    $tap->('act:view:albums');                           # ... and on Albums (section 7 leaves Singles)
    my $p = build(\@full);
    ok(scalar(join(',', $optKinds->($p)) eq 'view,act:search,opt:more'),
       '10: closed: Options shows the Albums switch, Search, then More options (got ' . join(',', $optKinds->($p)) . ')');
    ok(scalar(!has($p, 'act:refresh') && !grep { ($_->{image} // '') eq $SORT } @$p),
       '10: closed: sort and Refresh are hidden');
    my $more = row($p, 'opt:more');
    ok(scalar($more && ($more->{name} // '') eq 'PLUGIN_DISCOGRAPHY_MORE_OPTIONS' && ($more->{nextWindow} // '') eq 'refresh'
              && ($more->{itemActions}{items}{fixedParams}{item} // '') eq 'opt:more'),
       '10: More options opens in place (nextWindow refresh) by its own id');
    # The page's order (Simon 2026-10-02): Options at the top, then the bio, then
    # the releases; no separate search section (0.56.35).
    my @ids = ids($p);
    my $at = sub { my ($re) = @_; (grep { $ids[$_] =~ $re } 0 .. $#ids)[0] };
    my ($iO, $iM, $iB, $iR) = map { $at->($_) }
        (qr/^sect:OPT$/, qr/^opt:more$/, qr/^sect:BIO$/, qr/^sect:(?:ALBUMS|SINGLES|EPS)$/);
    ok(scalar(defined $iO && $iO == 0 && !has($p, 'sect:FIND')), '10: Options is the page\'s first section; no search section');
    ok(scalar(defined $iM && defined $iB && $iB > $iM && defined $iR && $iR > $iB), '10: then the bio, then the releases');
    my $srch = row($p, 'act:search');
    ok(scalar(($srch->{name} // '') eq 'PLUGIN_DISCOGRAPHY_SEARCH_ANOTHER' && ($srch->{type} // '') eq 'link'
              && ($srch->{image} // '') =~ /dsc-find_MTL_icon_search\.png$/),
       '10: the Search row reads "Search for another artist" with the search icon, a plain link');
    {
        my $str = do { local (@ARGV, $/) = ("$FindBin::Bin/../Discography/strings.txt"); <> };
        ok(scalar($str =~ /^PLUGIN_DISCOGRAPHY_SEARCH_ANOTHER\n\tEN\tSearch for another artist$/m),
           '10: the row string reads "Search for another artist"');
    }

    my $got = $tap->('opt:more');
    ok(scalar(ref $got eq 'HASH' && !@{ $got->{items} || [] }), '10: the More options tap answers empty (the refresh re-renders)');
    $p = build(\@full);
    ok(scalar(join(',', $optKinds->($p)) eq 'view,act:search,sort,act:refresh,opt:less'),
       '10: open: the switch, Search, sort, Refresh, then Fewer options (got ' . join(',', $optKinds->($p)) . ')');
    ok(scalar(!has($p, 'opt:more') && has($p, 'act:search')), '10: open: no More options; Search still there');
    $p = build(\@full);
    ok(scalar(has($p, 'act:refresh')), '10: it stays open on the next render of the same page');
    $tap->('opt:more');
    ok(scalar(has(build(\@full), 'act:refresh') && !has(build(\@full), 'opt:more')), '10: a second More options tap changes nothing');

    $got = $tap->('opt:less');
    ok(scalar(ref $got eq 'HASH'), '10: the Fewer options tap answers');
    ok(scalar(join(',', $optKinds->(build(\@full))) eq 'view,act:search,opt:more'), '10: Fewer options closes them again');
    $tap->('opt:less');
    ok(scalar(join(',', $optKinds->(build(\@full))) eq 'view,act:search,opt:more'), '10: a stale Fewer options tap changes nothing');

    # The only-what-I-own filter ON: its row stays out (closed AND open), once.
    my $lb = sub { $B->can('_buildList')->(undef, { %$opts, local_only => 1 }, 'artist-mbid', \@full, 'A bio paragraph.', []) };
    ok(scalar(join(',', $optKinds->($lb->())) eq 'view,local,act:search,opt:more'),
       '10: with the filter on, closed: the switch, the filter row (the way back out), More options');
    $tap->('opt:more');
    ok(scalar(join(',', $optKinds->($lb->())) eq 'view,local,act:search,sort,act:refresh,opt:less'),
       '10: with the filter on, open: the filter row once, not twice');
    $tap->('opt:less');

    # The user owns something by the artist, filter off: the filter row is one
    # of the hidden ones (offered when open, not when closed).
    my $own = sub { $B->can('_buildList')->(undef, { %$opts }, 'artist-mbid', \@full, 'A bio paragraph.',
                       [ { name => 'Kid A', id => 9, _svc => 'Local', _albumid => 9, _candArtist => 'Radiohead' } ]) };
    ok(scalar(join(',', $optKinds->($own->())) eq 'view,act:search,opt:more'), '10: owned, filter off, closed: the filter row is hidden');
    $tap->('opt:more');
    ok(scalar(join(',', $optKinds->($own->())) eq 'view,act:search,sort,local,act:refresh,opt:less'),
       '10: owned, filter off, open: sort, the filter row, Refresh');
    $tap->('opt:less');

    # An artist with no Singles: no switch, only More options.
    my $one = $B->can('_buildList')->(undef, { %$opts }, 'artist-mbid', [ rg('OK Computer', 'Album') ], undef, []);
    ok(scalar(join(',', $optKinds->($one)) eq 'act:search,opt:more'), '10: an albums-only artist: Search and More options');
}
# The open state is kept on a same-artist re-entry (sort and the filter re-enter;
# so does Material's refresh after the tap) and dropped for another artist: the
# one line in topLevel's $same branch (source check, as section 5).
{
    open my $fh, '<', "$FindBin::Bin/../Discography/Browse.pm" or die $!;
    my $src = do { local $/; <$fh> };
    ok(scalar($src =~ /\$same \? \([^)]*opts\s*=>\s*\$prev->\{opts\}[^)]*\) : \(\)/s),
       '10: a same-artist fresh entry keeps the open state; another artist starts closed');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
