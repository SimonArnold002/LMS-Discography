#!/usr/bin/env perl
#
# QOBUZ: AN ARTIST PAST THE PLUGIN'S 200 ALBUMS (0.56.54; Simon, 2026-10-07, Stan
# Getz: a fourth Qobuz copy of Getz/Gilberto, wku5y5j6r2vla, sat past the 200th
# album). The Qobuz plugin's getArtist calls artist/get with extra=albums and a
# fixed limit of 200, and passes no offset. Its developer: the API allows up to
# 500; more only through the catalog search. Sources::_qobuzMoreAlbums asks for
# the rest through the plugin's own handler (`_get`) and its exported
# `_precacheAlbum`, when the first answer says (`albums.total`) there is more.
#
# Drives the REAL Sources::_qobuzMoreAlbums and, once, _searchQobuz, against a
# fake handler. The shapes (albums: {offset, limit, total, items}; `_get` takes
# ($url, $cb, \%params), calls $cb->() with nothing on a failure; `_precacheAlbum`
# takes an arrayref and returns the playable albums) are from the Qobuz plugin's
# source (API.pm, API/Common.pm, master, read 2026-10-07). NOT measured live:
# that Qobuz honours `offset` on artist/get and sends `total`. That is what the
# first run of this build is for, and what its log lines say.
#
# Standalone -- no LMS install needed:  perl tools/t_qobuzpage.pl
#
use strict;
use warnings;
use FindBin;

our (@GETS, @HELD, @TIMERS, %CATALOG, $HOLD, $FAIL, $EMPTY, $NO_GET, $NO_PRE, @DBG);

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
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Null' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Plugins::Discography::Plugin::dbg'} = sub { push @main::DBG, join ' ', @_ };
    *{'Slim::Utils::Timers::setTimer'}     = sub { my $t = [@_]; push @main::TIMERS, $t; $t };
    *{'Slim::Utils::Timers::killSpecific'} = sub { my ($t) = @_; @main::TIMERS = grep { $_ != $t } @main::TIMERS; 1 };
    push @{'Slim::Utils::Log::ISA'},   'Exporter';
    push @{'Slim::Utils::Prefs::ISA'}, 'Exporter';
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Prefs; sub get { 1 } sub set { 1 } sub init { 1 }

# The Qobuz plugin's handler: getArtist answers the FIRST 200 of the artist's
# catalogue, `_get` any window of it.
package T::QAPI;
sub _window {
    my ($id, $offset, $limit) = @_;
    my $all = $main::CATALOG{$id} || [];
    my $end = $offset + $limit - 1; $end = $#$all if $end > $#$all;
    return { offset => $offset, limit => $limit, total => scalar @$all,
             items => [ map { +{ %$_ } } ($offset <= $#$all ? @$all[$offset .. $end] : ()) ] };
}
sub search {
    my ($s, $cb, $q, $type) = @_;
    $cb->({ artists => { items => [ { id => 7, name => 'Test Getz' } ] } });
}
sub getArtist {
    my ($s, $cb, $id) = @_;
    my $w = _window($id, 0, 200);
    delete $w->{total} if $main::NO_TOTAL;
    $cb->({ id => $id, albums => $w });
}
sub _get {
    my ($s, $url, $cb, $p) = @_;
    push @main::GETS, [ $url, { %$p } ];
    return $cb->() if $main::FAIL;
    return $cb->({ albums => { items => [] } }) if $main::EMPTY;
    my $reply = { albums => _window($p->{artist_id}, $p->{offset} // 0, $p->{limit} // 50) };
    return push @main::HELD, [ $cb, $reply ] if $main::HOLD;
    $cb->($reply);
}
package T::QAPI::NoGet;
our @ISA = ('T::QAPI');
sub can { my ($s, $m) = @_; return undef if $m eq '_get'; return $s->SUPER::can($m) }

# The plugin's exported _precacheAlbum: a function over an arrayref that drops
# what cannot be played (filterPlayables).
package Plugins::Qobuz::API::Common;
sub _precacheAlbum {
    my ($albums) = @_;
    return unless $albums && ref $albums eq 'ARRAY';
    return [ grep { !defined $_->{streamable} || $_->{streamable} } @$albums ];
}
package Plugins::Qobuz::Plugin;
sub getAPIHandler { bless {}, 'T::QAPI' }
sub _albumItem    { my ($c, $al) = @_; return { name => $al->{title}, type => 'playlist' } }
sub QobuzGetTracks { 'qobuz-rebuild' }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
my $S = 'Plugins::Discography::Sources';

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

sub catalog {
    my ($n, %o) = @_;
    return [ map { +{ id => "al$_", title => "Album $_", artist => { id => 7, name => 'Test Getz' },
                      ($o{unplayable}{$_} ? (streamable => 0) : ()) } } 1 .. $n ];
}
sub reset_all {
    @GETS = (); @HELD = (); @TIMERS = (); @DBG = (); %CATALOG = ();
    ($HOLD, $FAIL, $EMPTY, $NO_GET, $NO_PRE) = (0, 0, 0, 0, 0);
    $main::NO_TOTAL = 0;
}
# Run _qobuzMoreAlbums the way $fetch does: from getArtist's first answer.
my ($got, $done);
sub more {
    my (%o) = @_;
    my $api = $o{api} || bless {}, 'T::QAPI';
    ($got, $done) = (undef, 0);
    my $r;
    $api->getArtist(sub { $r = shift }, 7);
    my $albums = $S->can('_albumArray')->($r->{albums});
    $S->can('_qobuzMoreAlbums')->($api, 7, $r, $albums, sub { $got = $_[0]; $done++ });
}
sub ids { [ map { $_->{id} } @{ $got || [] } ] }

# ================================================================== 1
print "# 1. more than 200: the rest is asked for, from where the first answer stopped\n";
{
    reset_all(); $CATALOG{7} = catalog(650);
    more();
    ok(scalar($done == 1 && @$got == 650), '1: all 650 albums come back, once (' . scalar(@{ $got || [] }) . ')');
    ok(scalar(@GETS == 1), '1: ONE request for the other 450 (' . scalar(@GETS) . ')');
    my ($url, $p) = @{ $GETS[0] || [] };
    ok(scalar(($url // '') eq 'artist/get' && ($p->{artist_id} // '') == 7 && ($p->{extra} // '') eq 'albums'
              && ($p->{offset} // -1) == 200 && ($p->{limit} // 0) == 450),
       '1: artist/get, artist 7, extra=albums, offset 200, limit 450 (the rest, never over 500)');
    ok(scalar(($p->{_ttl} // 0) == 86400), '1: the plugin caches the page a day, not its thirty');
    ok(scalar(join(',', @{ ids() }[0, 199, 200, 649]) eq 'al1,al200,al201,al650'), '1: in order, none doubled');
}

# ================================================================== 2
print "# 2. a page is at most 500; one request at a time\n";
{
    reset_all(); $CATALOG{7} = catalog(900); $HOLD = 1;
    more();
    ok(scalar(@GETS == 1 && $GETS[0][1]{offset} == 200 && $GETS[0][1]{limit} == 500), '2: the first extra page is offset 200, limit 500');
    ok(scalar(!$done), '2: nothing is delivered while a page is out');
    my $h = shift @HELD; $h->[0]->($h->[1]);
    ok(scalar(@GETS == 2 && $GETS[1][1]{offset} == 700), '2: the second page is asked only after the first answered (offset 700)');
    ok(scalar(@HELD == 1 && !$done), '2: ... and again only one is out');
    $HOLD = 0;
    $h = shift @HELD; $h->[0]->($h->[1]);
    ok(scalar($done == 1 && @$got == 900 && @GETS == 2 && $GETS[1][1]{limit} == 200),
       '2: 900 albums, 2 requests, the second asking only for the 200 left (' . scalar(@GETS) . ' requests)');
}

# ================================================================== 3
print "# 3. the cap\n";
{
    reset_all(); $CATALOG{7} = catalog(5000);
    more();
    ok(scalar($done == 1 && @$got == 1000), '3: a 5000-album artist is read to 1000 (' . scalar(@{ $got || [] }) . ')');
    ok(scalar(@GETS == 2 && join(',', map { $_->[1]{offset} . '/' . $_->[1]{limit} } @GETS) eq '200/500,700/300'),
       '3: 2 requests, 200/500 700/300: ' . join(' ', map { $_->[1]{offset} . '/' . $_->[1]{limit} } @GETS));
    ok(scalar(grep { /cut at 1000/ } @DBG), '3: the log says it was cut');
}

# ================================================================== 4
print "# 4. nothing more is asked unless the answer says there is more\n";
{
    reset_all(); $CATALOG{7} = catalog(150);
    more();
    ok(scalar($done == 1 && @$got == 150 && !@GETS), '4: 150 albums, total 150: no request');
    reset_all(); $CATALOG{7} = catalog(200);
    more();
    ok(scalar($done == 1 && @$got == 200 && !@GETS), '4: exactly 200 of 200: no request');
    reset_all(); $CATALOG{7} = catalog(900); $main::NO_TOTAL = 1;
    more();
    ok(scalar($done == 1 && @$got == 200 && !@GETS), '4: no `total` in the answer: the 200 stand, no blind request');
    ok(scalar(grep { /carries no total/ } @DBG), '4: ... and the log says why');
}

# ================================================================== 5
print "# 5. anything wrong leaves the 200\n";
{
    reset_all(); $CATALOG{7} = catalog(650); $FAIL = 1;
    more();
    ok(scalar($done == 1 && @$got == 200 && @GETS == 1), '5: a failed page (the handler calls back with nothing): the 200, once');
    reset_all(); $CATALOG{7} = catalog(650); $EMPTY = 1;
    more();
    ok(scalar($done == 1 && @$got == 200 && @GETS == 1), '5: an empty page: the 200, no second request');
    reset_all(); $CATALOG{7} = catalog(650);
    more(api => bless {}, 'T::QAPI::NoGet');
    ok(scalar($done == 1 && @$got == 200 && !@GETS), '5: a handler with no `_get`: the 200');
    reset_all(); $CATALOG{7} = catalog(650);
    {
        no warnings 'redefine'; no strict 'refs';
        local *{'Plugins::Qobuz::API::Common::_precacheAlbum'} = sub { die "boom" };
        more();
        ok(scalar($done == 1 && @$got == 200), '5: a _precacheAlbum that dies: the 200, once');
    }
    reset_all(); $CATALOG{7} = catalog(650);
    {
        no warnings 'redefine'; no strict 'refs';
        my $saved = \&Plugins::Qobuz::API::Common::_precacheAlbum;
        delete $Plugins::Qobuz::API::Common::{_precacheAlbum};
        more();
        ok(scalar($done == 1 && @$got == 200 && !@GETS), '5: no `_precacheAlbum` in the Qobuz plugin: the 200, no request');
        *{'Plugins::Qobuz::API::Common::_precacheAlbum'} = $saved;
    }
}

# ================================================================== 6
print "# 6. unplayable albums are dropped, and the next page starts after what was READ\n";
{
    reset_all(); $CATALOG{7} = catalog(950, unplayable => { map { $_ => 1 } 250 .. 349 }); $HOLD = 1;
    more();
    my $h = shift @HELD; $h->[0]->($h->[1]);
    ok(scalar(@GETS == 2 && $GETS[1][1]{offset} == 700), '6: offset follows the 500 read (700), not the 400 kept');
    $HOLD = 0;
    $h = shift @HELD; $h->[0]->($h->[1]);
    ok(scalar($done == 1 && @$got == 850), '6: 950 listed, 100 not streamable: 850 kept (' . scalar(@{ $got || [] }) . ')');

    reset_all(); $CATALOG{7} = catalog(650); $HOLD = 1;
    more();
    # Qobuz shifted under us: the next window repeats an album already held.
    my $hh = shift @HELD; unshift @{ $hh->[1]{albums}{items} }, { id => 'al5', title => 'Album 5' };
    $hh->[0]->($hh->[1]);
    ok(scalar($done == 1 && @$got == 650 && (grep { $_->{id} eq 'al5' } @$got) == 1), '6: an album that came twice is kept once');
}

# ================================================================== 7
print "# 7. a slow page cannot cost the whole Qobuz pool\n";
{
    reset_all(); $CATALOG{7} = catalog(650); $HOLD = 1;
    more();
    ok(scalar(@TIMERS == 1 && ($TIMERS[0][1] - time()) <= 11 && ($TIMERS[0][1] - time()) >= 8),
       '7: one deadline of about 10 s is set (below the 20 s per-service watchdog)');
    my $t = $TIMERS[0];
    $t->[2]->();
    ok(scalar($done == 1 && @$got == 200), '7: the deadline hands back the 200 that had arrived');
    my $h = shift @HELD; $h->[0]->($h->[1]);
    ok(scalar($done == 1 && @$got == 200), '7: the page that arrives late is ignored (answered once)');
    reset_all(); $CATALOG{7} = catalog(650);
    more();
    ok(scalar(!@TIMERS && $done == 1), '7: the deadline is cleared when the pages are done');
}

# ================================================================== 8
print "# 8. through _searchQobuz: the pool gets the albums past 200\n";
{
    reset_all(); $CATALOG{7} = catalog(650);
    my ($pool, $calls) = (undef, 0);
    $S->can('_searchQobuz')->('client', 'Test Getz', 'Qobuz', sub { $calls++; $pool = $_[0] }, {}, undef, 0);
    ok(scalar($calls == 1 && ref $pool eq 'ARRAY' && @$pool == 650), '8: 650 candidates, not 200 (' . scalar(@{ $pool || [] }) . ')');
    ok(scalar($pool && (grep { ($_->{_candTitle} // '') eq 'Album 650' } @$pool) == 1), '8: the 650th album is a candidate');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
