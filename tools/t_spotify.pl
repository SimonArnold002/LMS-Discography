#!/usr/bin/env perl
#
# SPOTIFY (via Spotty) as the fourth streaming service — docs/spotify-adapter-plan.md.
#
# Drives the REAL Sources.pm against a fake Spotty whose shapes were read in Spotty 4.62.2's
# own source (2026-09-25), not guessed:
#   - Plugins::Spotty::Plugin->getAPIHandler($client) is a CLASS method; no client -> undef.
#   - $api->search($cb, {query, type, limit}) and $api->artistAlbums($cb, {uri, limit, offset,
#     include}) call back with a bare ARRAY of NORMALISED items. Every failure (a 429, a dead
#     token, a 502) reaches the caller as an EMPTY array; a refusal does so SYNCHRONOUSLY
#     (getToken's `return $cb->(-429)`).
#   - Plugins::Spotty::API->hasError429 is a module global: set by a 429, cleared by the next
#     successful response. A 502 or a token failure never sets it.
#   - A normalised album: title in `name`, `artist` a STRING, `artists` [{id,name,uri}], no
#     `type`, `album_type` album|single|compilation, `total_tracks`, `release_date`, `image`
#     ('' when Spotify has no art), `id`, `uri`.
#   - OPML::_albumItem is copied field for field, including the IMG_ALBUM placeholder.
#
# What is pinned, by section:
#   1  the adapter registers only when every Spotty sub it calls exists, with the D1 fields
#   2  the reshaping step (title <- name, artist <- artists[0]) works on a COPY
#   3  answer rules: no handler / zero raw results / rate-limited empty -> undef (unresolved);
#      results present -> an answer, whatever the 429 flag says
#   4  paging: one request per page at limit 50, `include` without appears_on, stops at a
#      short page and at 4 pages, a refused page -> the whole list undef
#   5  rendering: favurl/url/passthrough are Spotty's, _candTitle/_candArtist/_albumid set,
#      the placeholder cover never becomes _cover, foreign-artist albums dropped
#   6  the album-search fallback and the same-name spine resolution
#   7  end to end through getCandidates/peekPool: a dead-token Spotify-only user's pool reads
#      as UNRESOLVED (hide_unmatched hides nothing), a working one caches and reattaches
#   8  matchesFor keeps Spotty's own favurl (native_favurl), WITH the control that a normal
#      adapter's favurl is still decorated
#   9  the artist-photo walk never asks Spotify; artist SEARCH does
#
# Standalone. Run from the repo root:  perl tools/t_spotify.pl
#
use strict;
use warnings;
use FindBin;

our (%PREF, %CACHE, @TIMERS);
our ($API, $RL, %ARTISTS, %ALBUMS, %ALBUMSEARCH, %PAGE_FAIL, @CALLS);

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers
                  Slim::Control::Request Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}          = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Prefs' };
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Cache' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    # Watchdogs are recorded, never fired: every fake answers synchronously.
    *{'Slim::Utils::Timers::setTimer'}     = sub { push @main::TIMERS, $_[2]; scalar @main::TIMERS };
    *{'Slim::Utils::Timers::killSpecific'} = sub { 1 };
    push @{'Slim::Utils::Log::ISA'},   'Exporter';
    push @{'Slim::Utils::Prefs::ISA'}, 'Exporter';
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
}

package T::Null;
our $AUTOLOAD;
sub AUTOLOAD { return }
sub DESTROY  { }

package T::Prefs;
sub get  { return $main::PREF{ $_[1] } }
sub set  { $main::PREF{ $_[1] } = $_[2]; 1 }
sub init { 1 }

package T::Cache;
use Storable ();
sub get    { my $v = $main::CACHE{ $_[1] }; defined $v ? Storable::thaw($v) : undef }
sub set    { $main::CACHE{ $_[1] } = Storable::nfreeze($_[2]); 1 }
sub remove { delete $main::CACHE{ $_[1] }; 1 }

# ---------------------------------------------------------------- fake Spotty
# (the fake's state is declared in package main, above)

package Plugins::Spotty::Plugin;
sub getAPIHandler { my ($class, $client) = @_; return unless $client; return $main::API }

package Plugins::Spotty::API;
sub hasError429 { return $main::RL }

package T::SpottyAPI;
sub search {
    my ($self, $cb, $args) = @_;
    push @main::CALLS, { call => 'search', %$args };
    my $q = lc($args->{query} // '');
    my $list = $args->{type} eq 'artist' ? $main::ARTISTS{$q} : $main::ALBUMSEARCH{$q};
    my @l = @{ $list || [] };
    splice @l, $args->{limit} if $args->{limit} && @l > $args->{limit};
    $main::RL = '' if @l;          # a successful response clears the flag
    $cb->(\@l);
}
sub artistAlbums {
    my ($self, $cb, $args) = @_;
    push @main::CALLS, { call => 'artistAlbums', %$args };
    my ($id) = $args->{uri} =~ /artist:(.*)/;
    my $off = $args->{offset} || 0;
    if (my $f = $main::PAGE_FAIL{$off}) {
        $main::RL = 'Access rate exceeded' if $f eq 'refuse';
        return $cb->([]);          # every failure is an empty list, synchronously
    }
    my @all = @{ $main::ALBUMS{$id} || [] };
    my @page = grep { defined } @all[$off .. $off + $args->{limit} - 1];
    $main::RL = '' if @page;
    $cb->(\@page);
}

package Plugins::Spotty::OPML;
use constant IMG_ALBUM => 'plugins/Spotty/html/images/album.png';
sub album { 'spotty-album' }
sub _albumItem {           # field for field from OPML.pm:1230 (cstring('BY') -> 'by')
    my ($client, $album, $textkey) = @_;
    my $artists = join(', ', map { $_->{name} } @{ $album->{artists} });
    return {
        type  => 'playlist',
        name  => $album->{name} . ($artists ? " by $artists" : ''),
        line1 => $album->{name},
        line2 => $artists,
        url   => \&album,
        favorites_url => $album->{uri},
        image => $album->{image} || IMG_ALBUM,
        passthrough => [{ uri => $album->{uri} }],
    };
}

# A fake Qobuz, for the native_favurl control in section 8.
package Plugins::Qobuz::Plugin;
sub getAPIHandler { undef }  sub _albumItem { {} }  sub QobuzGetTracks { 'qobuz-rebuild' }

package main;

use File::Temp ();
my $SRC = $ENV{DSC_SOURCES};   # anti-test hook: point at a mutated copy of Sources.pm
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
if ($SRC) {
    mkdir "$tmp/Plugins/Discography" or die;
    symlink $SRC, "$tmp/Plugins/Discography/Sources.pm" or die;
} else {
    symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
}
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
my $S = 'Plugins::Discography::Sources';
my $C = bless {}, 'T::Null';   # a client

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $name) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $name && length $name;
    if ($cond) { $pass++; print "ok   - $name\n" }
    else       { $fail++; print "FAIL - $name\n" }
}
sub fn { my $f = $S->can($_[0]); $f ? $f : sub { die "Sources.pm has no $_[0]\n" } }

# ---------------------------------------------------------------- fixtures
my %A = (
    boom  => { id => 'boom1', name => 'Sonic Boom',  uri => 'spotify:artist:boom1' },
    boom2 => { id => 'boom2', name => 'Sonic Boom',  uri => 'spotify:artist:boom2' },
    panda => { id => 'pnd',   name => 'Panda Bear',  uri => 'spotify:artist:pnd' },
    other => { id => 'oth',   name => 'Someone Else', uri => 'spotify:artist:oth' },
);
sub alb {   # a NORMALISED album, as Spotty's Cache::normalize leaves it
    my ($id, $name, $artists, %x) = @_;
    my @ar = map { { id => $_->{id}, name => $_->{name}, uri => $_->{uri} } } @$artists;
    return { name => $name, id => $id, uri => "spotify:album:$id", artist => $ar[0]{name},
             artists => \@ar, release_date => '2020-05-01', album_type => 'album',
             total_tracks => 10, image => "https://i.scdn.co/image/$id", %x };
}
sub many { my ($n, $who) = @_; [ map { alb("b$_", "Record $_", [$A{$who}]) } 1 .. $n ] }

sub reset_all {
    $API = bless {}, 'T::SpottyAPI'; $RL = '';
    %ARTISTS = (); %ALBUMS = (); %ALBUMSEARCH = (); %PAGE_FAIL = (); @CALLS = (); @TIMERS = ();
    %CACHE = ();
    %PREF = (svc_priority_local => 0, svc_priority_qobuz => 0, svc_priority_tidal => 0,
             svc_priority_deezer => 0, svc_priority_spotify => 5);
    no warnings 'once';
    $Plugins::Discography::Sources::SPOTIFY_REFUSED_AT = 0;
}
# Run the REAL adapter once; returns (answer, times-collected).
sub run_spotify {
    my ($query, $spine, $aliases, $strict) = @_;
    my ($got, $n);
    fn('_searchSpotify')->($C, $query, 'Spotify', sub { $got = shift; $n++ }, $spine, $aliases, $strict);
    return ($got, $n);
}
sub calls { my ($c) = @_; grep { $_->{call} eq $c } @CALLS }

# ================================================================== 1
print "# 1. registration\n";
reset_all();
{
    my ($sp) = grep { $_->{name} eq 'Spotify' } $S->can('adapters')->();
    ok(scalar($sp), 'Spotify adapter registered when Spotty exposes getAPIHandler/_albumItem/album');
    $sp ||= {};
    ok(($sp->{rebuild} // 0) == \&Plugins::Spotty::OPML::album, 'rebuild = Spotty OPML::album');
    ok(scalar($sp->{native_favurl}), 'native_favurl set (Spotty\'s own favorites_url is kept)');
    ok(defined $sp->{artist_image} && !$sp->{artist_image}, 'artist_image => 0 (kept out of the photo walk)');
    ok(($sp->{query_enc} // '') eq 'chars', 'query_enc chars (Spotty escapes with uri_escape_utf8)');
    ok(ref $sp->{run} eq 'CODE' && ref $sp->{artists} eq 'CODE', 'run + artists legs present');
    my @names = map { $_->{name} } $S->can('adapters')->();
    ok($names[-1] eq 'Spotify', 'Spotify is appended after the existing services');

    # Each probed sub, removed in turn, keeps the adapter out.
    for my $probe (['Plugins::Spotty::Plugin::', 'getAPIHandler'],
                   ['Plugins::Spotty::OPML::',   '_albumItem'],
                   ['Plugins::Spotty::OPML::',   'album']) {
        no strict 'refs';
        my ($stash, $sub) = @$probe;
        my $glob = delete ${$stash}{$sub};
        my $has = grep { $_->{name} eq 'Spotify' } $S->can('adapters')->();
        ${$stash}{$sub} = $glob;
        ok(!$has, "not registered without $stash$sub");
    }
    my $st = Plugins::Discography::Sources::serviceStatus();
    my ($row) = grep { $_->{key} eq 'spotify' } @$st;
    ok($row && $row->{name} eq 'Spotify' && $row->{installed} == 1 && $row->{priority} == 5,
       'serviceStatus lists spotify, installed, with its priority');
}

# ================================================================== 2
print "# 2. reshaping\n";
{
    my $raw = alb('x1', 'Reset', [$A{panda}, $A{boom}]);
    my $r = fn('_spotifyAlbum')->($raw);
    ok($r->{title} eq 'Reset', 'title <- name');
    ok(ref $r->{artist} eq 'HASH' && $r->{artist}{id} eq 'pnd' && $r->{artist}{name} eq 'Panda Bear',
       'artist <- artists[0] (the {id,name} hash)');
    ok(!ref $raw->{artist} && $raw->{artist} eq 'Panda Bear' && !exists $raw->{title},
       'the raw album is not mutated (Spotty caches it)');
    ok($r->{name} eq 'Reset' && $r->{uri} eq 'spotify:album:x1' && ref $r->{artists} eq 'ARRAY',
       'the fields _albumItem reads are untouched');
    ok(Plugins::Discography::Sources::_albumArtistId($r) eq 'pnd', '_albumArtistId sees the id');
    my $bare = fn('_spotifyAlbum')->({ name => 'Solo', id => 's', artist => 'X' });
    ok($bare->{title} eq 'Solo' && !ref $bare->{artist} && $bare->{artist} eq 'X',
       'no artists list: the string artist is left as it is');
    ok(!defined fn('_spotifyAlbum')->('junk'), 'a non-hash reshapes to undef');
}

# ================================================================== 3
print "# 3. answer rules\n";
{
    reset_all(); $API = undef;
    my ($got, $n) = run_spotify('Sonic Boom');
    ok($n == 1 && !defined $got, 'no API handler: answered once, UNRESOLVED (undef)');
    ok(!@CALLS, '...and nothing was requested');

    reset_all();
    my $got2;
    fn('_searchSpotify')->(undef, 'Sonic Boom', 'Spotify', sub { $got2 = shift }, undef);
    ok(!defined $got2 && !@CALLS, 'no client (getAPIHandler(undef)): undef, no request');

    reset_all();   # dead token: every search answers []
    ($got) = run_spotify('Sonic Boom');
    ok(!defined $got, 'zero raw artist results: undef, never a confirmed miss');
    ok(scalar(calls('search')) == 1 && !grep({ $_->{type} eq 'album' } calls('search')),
       '...and NO album-search fallback on an empty artist search');
    no warnings 'once';
    ok($Plugins::Discography::Sources::SPOTIFY_REFUSED_AT == 0, '...no refusal stamp when Spotty is not rate-limiting');

    reset_all(); $RL = 'Access rate exceeded';
    ($got) = run_spotify('Sonic Boom');
    ok(!defined $got && $Plugins::Discography::Sources::SPOTIFY_REFUSED_AT > 0,
       'empty while rate-limited: undef AND the refusal stamp is set');
    ok(fn('_spotifyBackingOff')->() == 1, '_spotifyBackingOff true inside the window');
    $Plugins::Discography::Sources::SPOTIFY_REFUSED_AT = time() - 31;
    ok(fn('_spotifyBackingOff')->() == 0, '_spotifyBackingOff false after SPOTIFY_BACKOFF_WINDOW');

    reset_all(); $ARTISTS{'sonic boom'} = [$A{boom}]; $ALBUMS{boom1} = [];
    ($got) = run_spotify('Sonic Boom');
    ok(!defined $got, 'resolved artist, empty album list: undef');

    reset_all(); $ARTISTS{'sonic boom'} = [$A{boom}]; $ALBUMS{boom1} = many(3, 'boom');
    # Present results are an answer whatever the flag says. Set INSIDE the album call: the
    # artist search before it succeeds, which would clear a flag set any earlier.
    {
        no warnings 'redefine';
        local *T::SpottyAPI::artistAlbums = sub {
            my ($self, $cb, $args) = @_; push @main::CALLS, { call => 'artistAlbums', %$args };
            $main::RL = 'stale flag';
            $cb->([ @{ $main::ALBUMS{boom1} } ]);
        };
        ($got) = run_spotify('Sonic Boom');
    }
    ok(ref $got eq 'ARRAY' && @$got == 3, 'albums present while the 429 flag is set: an ANSWER');
}

# ================================================================== 4
print "# 4. paging\n";
{
    reset_all(); $ARTISTS{'sonic boom'} = [$A{boom}]; $ALBUMS{boom1} = many(120, 'boom');
    my ($got) = run_spotify('Sonic Boom');
    my @p = calls('artistAlbums');
    ok(scalar(@p) == 3, '120 albums: exactly 3 requests (50+50+20, stops on the short page)');
    ok(join(',', map { $_->{offset} // 0 } @p) eq '0,50,100', '...one at a time, offsets 0/50/100');
    ok(!grep({ ($_->{limit} // 0) != 50 } @p), '...each at limit 50 (one Pipeline request per call)');
    ok(!grep({ $_->{uri} ne 'spotify:artist:boom1' } @p), '...for the resolved artist uri');
    ok(!grep({ ($_->{include} // '') ne 'album,single,compilation' } @p), '...include has no appears_on');
    ok(ref $got eq 'ARRAY' && @$got == 120, '...and all 120 are candidates');
    my ($as) = calls('search');
    ok(($as->{type} // '') eq 'artist' && ($as->{limit} // 999) <= 50,
       'artist search: type artist, limit <= 50 (Spotty defaults to 200 = 4 requests)');

    reset_all(); $ARTISTS{'sonic boom'} = [$A{boom}]; $ALBUMS{boom1} = many(260, 'boom');
    ($got) = run_spotify('Sonic Boom');
    ok(scalar(calls('artistAlbums')) == 4 && @$got == 200, '260 albums: capped at 4 pages / 200');

    reset_all(); $ARTISTS{'sonic boom'} = [$A{boom}]; $ALBUMS{boom1} = many(50, 'boom');
    ($got) = run_spotify('Sonic Boom');
    ok(scalar(calls('artistAlbums')) == 2 && @$got == 50, 'exactly 50: page 2 empty and not rate-limited -> the 50');

    reset_all(); $ARTISTS{'sonic boom'} = [$A{boom}]; $ALBUMS{boom1} = many(120, 'boom');
    $PAGE_FAIL{50} = 'refuse';
    ($got) = run_spotify('Sonic Boom');
    ok(!defined $got, 'page 2 refused (429): the WHOLE list is undef, never a shortened pool');
    ok(scalar(calls('artistAlbums')) == 2, '...and page 3 was never asked for');
    ok($Plugins::Discography::Sources::SPOTIFY_REFUSED_AT > 0, '...and the refusal is stamped');

    reset_all(); $ARTISTS{'sonic boom'} = [$A{boom}]; $ALBUMS{boom1} = many(120, 'boom');
    $PAGE_FAIL{0} = 'error';
    ($got) = run_spotify('Sonic Boom');
    ok(!defined $got && scalar(calls('artistAlbums')) == 1, 'page 1 empty (502/dead token): undef, no further pages');
    ok($Plugins::Discography::Sources::SPOTIFY_REFUSED_AT == 0, '...and no refusal stamp (not a 429)');

    reset_all(); $ARTISTS{'sonic boom'} = [$A{boom}]; $ALBUMS{boom1} = many(120, 'boom');
    $PAGE_FAIL{0} = 'refuse';
    ($got) = run_spotify('Sonic Boom');
    ok(!defined $got && scalar(calls('artistAlbums')) == 1 && $Plugins::Discography::Sources::SPOTIFY_REFUSED_AT > 0,
       'page 1 refused (429): undef, no further pages, refusal stamped');
}

# ================================================================== 5
print "# 5. rendering\n";
{
    reset_all(); $ARTISTS{'sonic boom'} = [$A{boom}];
    $ALBUMS{boom1} = [ alb('a1', 'Spectrum', [$A{boom}]),
                       alb('a2', 'Bare', [$A{boom}], image => ''),
                       alb('a3', 'Not His', [$A{other}]),
                       alb('a4', 'Duo', [$A{boom}, $A{panda}]) ];
    my ($got) = run_spotify('Sonic Boom');
    my %by = map { $_->{_candTitle} => $_ } @{ $got || [] };
    my $it = $by{Spectrum} || {};
    ok(($it->{favorites_url} // '') eq 'spotify:album:a1', "favorites_url is Spotty's own spotify:album:<id>");
    ok(($it->{url} // 0) == \&Plugins::Spotty::OPML::album && ($it->{passthrough}[0]{uri} // '') eq 'spotify:album:a1',
       'url/passthrough are Spotty\'s (album rebuild)');
    ok(($it->{_svc} // '') eq 'Spotify' && ($it->{_albumid} // '') eq 'a1', '_svc Spotify, _albumid = the Spotify id');
    ok(($it->{_candArtist} // '') eq 'Sonic Boom' && ($it->{_year} // '') eq '2020', '_candArtist and _year');
    ok(($it->{_cover} // '') eq 'https://i.scdn.co/image/a1', 'a real cover becomes _cover');
    my $bare = $by{Bare} || {};
    ok(!defined $bare->{_cover} && ($bare->{image} // '') eq 'plugins/Spotty/html/images/album.png',
       'the album.png PLACEHOLDER never becomes _cover (the row keeps it as its icon)');
    ok(!$by{'Not His'}, 'an album credited to another artist id is dropped (_filterForeignArtist)');
    ok(scalar($by{Duo}), 'a collaboration with the browsed artist listed FIRST is kept');
    ok(!exists $ALBUMS{boom1}[0]{title} && !ref $ALBUMS{boom1}[0]{artist},
       "Spotty's own album hashes are not mutated");
}

# ================================================================== 6
print "# 6. fallback + spine\n";
{
    reset_all(); $ARTISTS{'sonic boom'} = [$A{other}];   # results, but no name match
    $ALBUMSEARCH{'sonic boom'} = [ alb('f1', 'Spectrum', [$A{boom}]) ];
    my ($got) = run_spotify('Sonic Boom');
    my ($fs) = grep { $_->{type} eq 'album' } calls('search');
    ok($fs && ($fs->{limit} // 0) == 50, 'no artist match: album-search fallback, type album, limit 50');
    ok(ref $got eq 'ARRAY' && @$got == 1 && $got->[0]{_candArtist} eq 'Sonic Boom',
       '...rendered, _candArtist from artists[0]');

    reset_all(); $ARTISTS{'sonic boom'} = [$A{other}];
    ($got) = run_spotify('Sonic Boom');
    ok(!defined $got, 'album-search fallback with zero raw results: undef');

    reset_all(); $ARTISTS{'sonic boom'} = [$A{other}];
    $ALBUMSEARCH{'sonic boom'} = [ alb('f1', 'Spectrum', [$A{boom}]) ];
    ($got) = run_spotify('Sonic Boom', { spectrum => 1 });
    ok(!defined $got && !grep({ $_->{type} eq 'album' } calls('search')),
       'with a spine, an unresolved artist settles undef and never album-searches');

    # Two same-name artists; only boom2's catalogue corroborates the MB spine.
    reset_all(); $ARTISTS{'sonic boom'} = [$A{boom}, $A{boom2}];
    $ALBUMS{boom1} = [ alb('w1', 'Bajo Tu Voz', [$A{boom}]) ];
    $ALBUMS{boom2} = [ alb('r1', 'Spectrum', [$A{boom2}]), alb('r2', 'Almost Nothing', [$A{boom2}]) ];
    ($got) = run_spotify('Sonic Boom', { spectrum => 1, 'almost nothing' => 1 });
    ok(ref $got eq 'ARRAY' && @$got == 2 && !grep({ $_->{_albumid} !~ /^r/ } @$got),
       'same-name artists: the spine picks the corroborating one (_spineScore reads the reshaped title)');
}

# ================================================================== 7
print "# 7. end to end: getCandidates / peekPool\n";
{
    reset_all();   # Spotify-only user, dead token
    my $got;
    $S->getCandidates($C, 'Sonic Boom', 0, sub { $got = shift }, { mbid => 'mb-1' });
    ok(ref $got eq 'HASH' && ref $got->{Spotify} eq 'ARRAY' && !@{ $got->{Spotify} },
       'dead token: getCandidates settles, Spotify empty');
    my $pool = $S->peekPool('Sonic Boom', 'mb-1');
    ok($pool->{resolved} == 0 && $pool->{cold} == 0,
       '...and the pool reads UNRESOLVED, not cold: hide_unmatched hides nothing, and no cold-pool await');

    reset_all(); $ARTISTS{'sonic boom'} = [$A{boom}];
    $ALBUMS{boom1} = [ alb('a1', 'Spectrum', [$A{boom}]) ];
    $S->getCandidates($C, 'Sonic Boom', 0, sub { $got = shift }, { mbid => 'mb-1' });
    ok(ref $got->{Spotify} eq 'ARRAY' && @{ $got->{Spotify} } == 1, 'working: one candidate');
    $pool = $S->peekPool('Sonic Boom', 'mb-1');
    ok($pool->{resolved} == 1, '...cached as a resolved pool');
    my $it = $pool->{bySvc}{Spotify}[0] || {};
    ok(($it->{url} // 0) == \&Plugins::Spotty::OPML::album && ($it->{passthrough}[0]{uri} // '') eq 'spotify:album:a1',
       '...and read back with OPML::album reattached and the passthrough intact');
    ok(scalar(keys %{ $pool->{index}{Spotify} || {} }) > 0, '...title index built from the reshaped title');
}

# ================================================================== 8
print "# 8. matchesFor keeps Spotty's favurl (with the control)\n";
{
    reset_all(); $PREF{svc_priority_qobuz} = 2;
    my $sp = { name => 'Spotify', items => [] };
    my $bySvc = {
        Spotify => [ { name => 'Spectrum', line2 => 'Sonic Boom', _svc => 'Spotify', _albumid => 'a1',
                       _candTitle => 'Spectrum', _candArtist => 'Sonic Boom', _cover => 'https://c/1',
                       favorites_url => 'spotify:album:a1' } ],
        Qobuz   => [ { name => 'Spectrum', line2 => 'Sonic Boom', _svc => 'Qobuz', _albumid => 'q1',
                       _candTitle => 'Spectrum', _candArtist => 'Sonic Boom', _cover => 'https://c/2' } ],
    };
    my $secs = $S->matchesFor($bySvc, 'Sonic Boom', 'Spectrum', []);
    my %s = map { $_->{svc} => $_->{items}[0] } @{ $secs || [] };
    ok(($s{Spotify}{favorites_url} // '') eq 'spotify:album:a1', 'Spotify: favorites_url left exactly as Spotty set it');
    ok(($s{Qobuz}{favorites_url} // '') =~ m{^qobuz://album:q1\?cover=}, 'CONTROL: Qobuz still gets the decorated LL favurl');
    ok(!exists $bySvc->{Spotify}[0]{extid} && $bySvc->{Spotify}[0]{favorites_url} eq 'spotify:album:a1',
       'the pool entry itself is not decorated');

    # VERSION DEDUPE on name|line2 (matchesFor), with Spotty's REAL name shape
    # (OPML.pm _albumItem: "<name>[ (YYYY)] BY <artists>", the year only with
    # LMS showYear). Pins what the ledger's SPOTIFY ROWS KEEP SPOTTY'S OWN says:
    # with showYear OFF two same-titled editions (explicit + clean) share
    # name|line2 and collapse to ONE version row; with it ON, editions from
    # different years stay apart.
    my $ed = sub { my ($id, $name) = @_;
        { name => $name, line1 => 'Spectrum', line2 => 'Sonic Boom', _svc => 'Spotify', _albumid => $id,
          _candTitle => 'Spectrum', _candArtist => 'Sonic Boom', favorites_url => "spotify:album:$id" } };
    my $spRows = sub { my ($secs) = @_;
        my ($sec) = grep { $_->{svc} eq 'Spotify' } @{ $secs || [] }; $sec ? @{ $sec->{items} } : () };
    my @off = $spRows->($S->matchesFor({ Spotify => [ $ed->('e1', 'Spectrum BY Sonic Boom'),
                                                      $ed->('e2', 'Spectrum BY Sonic Boom') ] },
                                       'Sonic Boom', 'Spectrum', []));
    ok(scalar(@off == 1 && $off[0]{_albumid} eq 'e1'),
       'showYear OFF: two same-titled Spotify editions collapse to ONE version row (the first)');
    my @on = $spRows->($S->matchesFor({ Spotify => [ $ed->('y1', 'Spectrum (1990) BY Sonic Boom'),
                                                     $ed->('y2', 'Spectrum (2020) BY Sonic Boom') ] },
                                      'Sonic Boom', 'Spectrum', []));
    ok(scalar(@on == 2), 'showYear ON: editions from different years stay two version rows');
}

# ================================================================== 9
print "# 9. artist photos never ask Spotify; artist search does\n";
{
    reset_all(); $ARTISTS{'sonic boom'} = [$A{boom}];
    my @img;
    $S->artistImage(undef, 'Sonic Boom', sub { @img = @_ });
    ok(!@CALLS, 'artistImage: Spotify is never asked (no client, and artist_image => 0)');
    ok(!defined $img[0] && $img[1], '...and with no photo-capable service it concludes (no photo, conclusive)');

    reset_all(); $ARTISTS{'sonic boom'} = [$A{boom}, $A{panda}];
    my ($out, $failed);
    $S->searchArtists($C, 'Sonic Boom', sub { ($out, $failed) = @_ });
    ok(ref $out->{Spotify} eq 'ARRAY' && join(',', map { $_->{name} } @{ $out->{Spotify} }) eq 'Sonic Boom,Panda Bear',
       'searchArtists: the Spotify leg returns its artist names');
    ok(!$failed->{Spotify}, '...and is not marked failed');
    my ($q) = calls('search');
    ok(($q->{type} // '') eq 'artist' && ($q->{limit} // 999) <= 50, '...artist type, limit <= 50');

    reset_all();   # dead token
    $S->searchArtists($C, 'Sonic Boom', sub { ($out, $failed) = @_ });
    ok($failed->{Spotify}, 'searchArtists: zero raw Spotify results mark it FAILED, so the merged list is not cached');
}

# ================================================================== 10
print "# 10. sizing (album / ep / single) through the SHARED _candSize, unchanged\n";
{
    my $size = sub {
        my (%x) = @_;
        my $r = fn('_spotifyAlbum')->(alb('z', 'Z', [$A{boom}], %x));
        return Plugins::Discography::Sources::_candSize($r) // 'unknown';
    };
    ok($size->(album_type => 'album', total_tracks => 5) eq 'album',
       'album_type album, 5 tracks -> album (no duration, so the type decides, not the count)');
    ok($size->(album_type => 'compilation', total_tracks => 3) eq 'album', 'compilation -> album');
    ok($size->(album_type => 'single', total_tracks => 2) eq 'single', 'single, 2 tracks -> single');
    ok($size->(album_type => 'single', total_tracks => 5) eq 'ep', 'single, 5 tracks -> ep (Spotify files EPs as singles)');
    ok($size->(album_type => 'single', total_tracks => 8) eq 'album', 'single, 8 tracks -> album (counts, as Qobuz is judged)');
    ok($size->(album_type => 'single', total_tracks => undef) eq 'unknown', 'single with no count -> unknown (matches as before)');
    ok($size->(album_type => undef, total_tracks => undef) eq 'unknown', 'no type, no count -> unknown');
    ok($size->(album_type => 'ALBUM', total_tracks => 5) eq 'album', 'album_type is case-insensitive');
    my $raw = alb('z', 'Z', [$A{boom}], album_type => 'single', total_tracks => 5);
    fn('_spotifyAlbum')->($raw);
    ok(!exists $raw->{tracks_count} && !exists $raw->{record_type}, "sizing fields go on the copy, never Spotty's hash");

    reset_all(); $ARTISTS{'sonic boom'} = [$A{boom}];
    $ALBUMS{boom1} = [ alb('s1', 'Spectrum', [$A{boom}], album_type => 'album', total_tracks => 6),
                       alb('s2', 'Angel', [$A{boom}], album_type => 'single', total_tracks => 2) ];
    my ($got) = run_spotify('Sonic Boom');
    my %sz = map { $_->{_candTitle} => $_->{_size} } @{ $got || [] };
    ok(($sz{Spectrum} // '') eq 'album' && ($sz{Angel} // '') eq 'single', 'rendered candidates carry _size');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
