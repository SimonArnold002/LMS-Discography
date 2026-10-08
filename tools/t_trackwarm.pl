#!/usr/bin/env perl
#
# REGRESSION TEST - THE TRACK MATCH'S LIBRARY PASS (TrackWarm, 0.56.62).
#
# Live 2026-10-08 on 0.56.61: a page asked ListenBrainz for the track match's
# tracklists before its draw and waited for them; a slow ListenBrainz held
# Thievery Corporation's page 8.5 s past its check. Simon: no hangups, no
# slowing down, not "so much being done on 2nd visits". So the tracklists are
# fetched OFF the page, ahead of the visit, and kept; the page only reads them.
#
#   1. Which artists: the real library query, on a real SQLite file with LMS's
#      own columns: an album with no MusicBrainz release id, by its album
#      artist; tagged albums, compilations and Various Artists left out; the
#      signature follows a title, a track count, a length.
#   2. When: after startup, after a rescan (once more if one comes during a
#      pass), then daily; never while a scan runs; nothing when the library is
#      not used; an artist is done again only when due (its albums changed,
#      RECHECK passed, or RETRY_FAILED after a failure).
#   3. One artist: the page's own way (getArtistMbid, the kept list or
#      ListenBrainz's, localAlbums, the REAL Browse::_placements), every
#      request background work; only the due candidates of UNTAGGED leftovers
#      are asked for; the mark says whether everything it needed is now kept.
#   4. Off the page's way: no artist starts while a page has a request out; a
#      lost answer is given up at ARTIST_TIMEOUT and the pass goes on.
#   5. A page's hand-off (want): coalesced, asked once, in the background,
#      never while a scan runs.
#   6. Two library artists of one name keep a mark each (name + signature,
#      key v2), kept RECHECK.
#
# Standalone:  perl tools/t_trackwarm.pl
#
use strict;
use warnings;
use FindBin;
use DBI;

our (%PREF, %CACHE, @TIMERS, $NOW, @SUBS, $SCANNING, $LIBDBH, %MBID, %RGS, %LBRGS, %LOCALS,
     %TRACKS, @WARMED, @CALLS, $FGBUSY, $LB_FAIL, $HOLD_MBID, %KEEPCUR, %TTL);

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache Slim::Utils::Timers
                  Slim::Utils::PluginManager Slim::Utils::Strings Slim::Control::Request
                  Slim::Schema Slim::Music::Import Slim::Web::HTTP Slim::Networking::SimpleAsyncHTTP
                  Slim::Utils::Misc Plugins::Discography::Plugin Plugins::Discography::API)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Cache' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Plugins::Discography::DB::keepCurrent'} = sub { shift; $main::KEEPCUR{$_} = 1 for @_ };
    *{'Plugins::Discography::DB::manualFor'}   = sub { {} };
    *{'Slim::Utils::Strings::cstring'}   = sub { $_[1] };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    # Timers: [ when, code ]; the handle is the entry.
    *{'Slim::Utils::Timers::setTimer'}   = sub { my $t = [ $_[1], $_[2] ]; push @main::TIMERS, $t; $t };
    *{'Slim::Utils::Timers::killTimers'} = sub { my $c = $_[1]; @main::TIMERS = grep { $_->[1] != $c } @main::TIMERS; 1 };
    *{'Slim::Utils::Timers::killSpecific'} = sub { my $h = $_[0]; @main::TIMERS = grep { $_ != $h } @main::TIMERS; 1 };
    *{'Slim::Control::Request::subscribe'}   = sub { push @main::SUBS, [ 'sub', @_ ] };
    *{'Slim::Control::Request::unsubscribe'} = sub { push @main::SUBS, [ 'unsub', @_ ] };
    *{'Slim::Control::Request::executeRequest'} = sub { bless { loop => [] }, 'T::Req' };
    *{'Slim::Music::Import::stillScanning'} = sub { $main::SCANNING };
    *{'Slim::Schema::dbh'}               = sub { $main::LIBDBH };
    # The clock the pass reads. Installed BEFORE TrackWarm.pm compiles: a
    # builtin is overridden only by a sub imported into the package first.
    *{'Plugins::Discography::TrackWarm::time'} = sub { $main::NOW };
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');

    # The API: what the pass calls, recorded; every request it would send is a
    # call here, with the background flag the real one would carry.
    my $A = 'Plugins::Discography::API';
    *{"${A}::_netFgBusy"}      = sub { $main::FGBUSY ? 1 : 0 };
    *{"${A}::isVarious"}       = sub { my (undef, $n, $m) = @_; (($m // '') eq 'va' || ($n // '') =~ /^various artists$/i) ? 1 : 0 };
    *{"${A}::getArtistMbid"}   = sub {
        my (undef, %a) = @_;
        push @main::CALLS, [ 'mbid', $a{artist}, $Plugins::Discography::API::NET_BG ];
        return if $main::HOLD_MBID;                       # never answers
        $a{onDone}->($main::MBID{ $a{artist} }, 1);
    };
    *{"${A}::peekReleaseGroups"}  = sub { $main::RGS{ $_[1] } };
    *{"${A}::listenBrainzGroups"} = sub {
        my (undef, $mbid, $cb) = @_;
        push @main::CALLS, [ 'lblist', $mbid, $Plugins::Discography::API::NET_BG ];
        $cb->($main::LBRGS{$mbid});
    };
    *{"${A}::peekReleaseMap"}      = sub { {} };
    *{"${A}::peekLocalReleaseMap"} = sub { {} };
    *{"${A}::peekEditions"}        = sub { {} };
    *{"${A}::peekOfficial"}        = sub { {} };
    *{"${A}::peekGroupTracks"}     = sub { my $v = $main::TRACKS{ $_[1] }; ref $v eq 'HASH' ? $v->{t} : undef };
    *{"${A}::groupTracksDue"}      = sub {
        my $v = $main::TRACKS{ $_[1] };
        return 1 unless ref $v eq 'HASH';
        return ($v->{due} && $v->{due} <= $main::NOW) ? 1 : 0;
    };
    *{"${A}::warmGroupTracks"}     = sub {
        my (undef, $rgs, $cb, %o) = @_;
        push @main::WARMED, { rgs => [ @$rgs ], bg => ($o{background} ? 1 : 0),
                              netbg => $Plugins::Discography::API::NET_BG };
        unless ($main::LB_FAIL) {
            $main::TRACKS{$_} = { t => [ [ "t $_", 300 ] ], due => 0 } for @$rgs;
        }
        $cb->() if $cb;
    };
}
package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}
package T::Prefs; our $AUTOLOAD; sub get { $main::PREF{ $_[1] } } sub AUTOLOAD { return } sub DESTROY {}
package T::Cache;
sub get    { $main::CACHE{ $_[1] } }
sub set    { $main::CACHE{ $_[1] } = $_[2]; $main::TTL{ $_[1] } = $_[3]; 1 }
sub remove { delete $main::CACHE{ $_[1] }; 1 }
package T::Req; sub getResult { $_[0]{loop} }

package main;
binmode STDOUT, ':utf8';

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
require Plugins::Discography::Browse;
require Plugins::Discography::TrackWarm;
my $T = 'Plugins::Discography::TrackWarm';
{
    no strict 'refs'; no warnings 'redefine';
    *{'Plugins::Discography::Sources::localAlbums'} = sub {
        my (undef, $id) = @_;
        push @main::CALLS, [ 'local', $id ];
        return [ map { +{ %$_ } } @{ $main::LOCALS{$id} || [] } ];
    };
    *{'Plugins::Discography::Sources::ownTracks'} = sub { [ [ 'x', 300 ] ] };
}
# ... and its timers' clock (Time::HiRes::time, called by its full name).
{
    no strict 'refs'; no warnings 'redefine';
    *{'Time::HiRes::time'} = sub () { $main::NOW };
}

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

# The library: a real SQLite file with LMS's own columns (SQL/SQLite/schema_1_up.sql).
my $lib = "$tmp/library.db";
$LIBDBH = DBI->connect("dbi:SQLite:dbname=$lib", '', '', { RaiseError => 1, PrintError => 0, sqlite_unicode => 1 });
$LIBDBH->do('CREATE TABLE contributors (id INTEGER PRIMARY KEY, name blob, namesort text, musicbrainz_id varchar(40))');
$LIBDBH->do('CREATE TABLE albums (id INTEGER PRIMARY KEY, title blob, compilation bool, musicbrainz_id varchar(40), contributor int(10))');
$LIBDBH->do('CREATE TABLE tracks (id INTEGER PRIMARY KEY, album int(10), secs float)');
sub album {
    my ($id, $title, $cid, $mbid, $comp, @secs) = @_;
    $LIBDBH->do('INSERT INTO albums (id, title, compilation, musicbrainz_id, contributor) VALUES (?, ?, ?, ?, ?)',
                undef, $id, $title, $comp, $mbid, $cid);
    $LIBDBH->do('INSERT INTO tracks (album, secs) VALUES (?, ?)', undef, $id, $_) for @secs;
}
$LIBDBH->do("INSERT INTO contributors (id, name) VALUES (1, 'McCoy Tyner'), (2, 'Kraftwerk'), (3, 'Various Artists'),
             (4, ?), (5, 'Thievery Corporation'), (6, 'Cafe del Mar Records')", undef, "Bj\x{f6}rk");
album(10, 'McCoy Tyner Plays John Coltrane', 1, undef, 0, 737, 428);      # untagged (NULL)
album(11, 'Fly With the Wind', 1, '', 0, 300);                            # untagged ('')
album(12, 'Autobahn', 2, '881154df-871a-4681-a0ef-2a7a57e45bce', 0, 1300); # tagged
album(13, 'Now That\'s What I Call Music', 3, undef, 1, 200);             # a compilation
album(14, 'Some Mix', 3, undef, 0, 200);                                  # Various Artists, not flagged
album(15, "D\x{e9}but", 4, undef, 0, 250);                                # untagged, accented
album(16, 'DJ-Kicks: Thievery Corporation', 5, '03b4e5aa-b136-3376-bf80-92d66adf743b', 0, 3000); # tagged
album(17, 'Cafe del Mar Volumen Uno', 6, undef, 1, 400);                  # a compilation under a label's name

my $ART = 'aaaaaaaa-0000-4000-8000-0000000000aa';
my $MT  = '4b65bc2e-8fc5-30ee-bec9-7b8c1da84354';
my $ELL = 'eeeeeeee-0000-4000-8000-000000000001';
my @RG = ({ mbid => $MT,  title => 'McCoy Tyner plays John Coltrane: Live at the Village Vanguard',
            type => 'Album', secondary => ['Live'], date => '2001' },
          { mbid => $ELL, title => 'McCoy Tyner Plays Ellington', type => 'Album', secondary => [], date => '1965' });
my $own = { _albumid => 10, _candTitle => 'McCoy Tyner Plays John Coltrane', _candArtist => 'McCoy Tyner',
            _svc => 'Local', name => 'McCoy Tyner Plays John Coltrane' };

sub reset_all {
    $T->can('_reset')->();
    %CACHE = (); %TTL = (); @TIMERS = (); @SUBS = (); %TRACKS = (); @WARMED = (); @CALLS = ();
    $SCANNING = 0; $FGBUSY = 0; $LB_FAIL = 0; $HOLD_MBID = 0;
    %PREF = (svc_priority_local => 1, show_types => 'ALBUMS,EPS,SINGLES,COMPILATIONS,LIVE,OTHER');
    $NOW = 1_800_000_000;
    %MBID = ('McCoy Tyner' => $ART, "Bj\x{f6}rk" => 'bbbbbbbb-0000-4000-8000-0000000000bb', 'Thievery Corporation' => undef);
    %RGS = ($ART => [ map { +{ %$_ } } @RG ]);
    %LBRGS = ();
    %LOCALS = (1 => [ { %$own } ], 4 => []);
}
# Fire timers due by $NOW + $ahead, earliest first, at most $max.
sub run_timers {
    my ($ahead, $max) = @_;
    $max //= 200;
    for (1 .. $max) {
        my ($t) = sort { $a->[0] <=> $b->[0] } @TIMERS or last;
        last if $t->[0] > $NOW + $ahead;
        @TIMERS = grep { $_ != $t } @TIMERS;
        $NOW = $t->[0] if $t->[0] > $NOW;
        $t->[1]->();
    }
}
sub armed { my ($code) = @_; grep { $_->[1] == $code } @TIMERS }
# Fire the earliest timer, one at a time, until $cond holds (at most $max).
sub run_until {
    my ($cond, $max) = @_;
    for (1 .. ($max // 50)) {
        return 1 if $cond->();
        my ($t) = sort { $a->[0] <=> $b->[0] } @TIMERS or return 0;
        @TIMERS = grep { $_ != $t } @TIMERS;
        $NOW = $t->[0] if $t->[0] > $NOW;
        $t->[1]->();
    }
    return $cond->() ? 1 : 0;
}
my $start = \&Plugins::Discography::TrackWarm::_startPass;
# An artist's kept mark, under its name and its CURRENT signature (the key since v2).
sub mark {
    my ($name) = @_;
    my ($a) = grep { $_->{name} eq $name } @{ $T->can('_untaggedArtists')->() };
    return $a ? $CACHE{ $T->can('_markKey')->($a->{name}, $a->{sig}) } : undef;
}

# ---------------------------------------------------------------------------
# 1. Which artists.
# ---------------------------------------------------------------------------
{
    reset_all();
    my $list = $T->can('_untaggedArtists')->();
    my %by = map { $_->{name} => $_ } @$list;
    ok(join('|', map { $_->{name} } @$list) eq "Bj\x{f6}rk|McCoy Tyner",
       '1: the artists of untagged albums, by name: McCoy Tyner (NULL and empty ids), Bjork (accented)');
    ok(!$by{Kraftwerk} && !$by{'Thievery Corporation'}, '1: an artist whose albums are all tagged is not one (Kraftwerk, DJ-Kicks)');
    ok(!$by{'Various Artists'}, '1: compilations and Various Artists are not');
    ok(!$by{'Cafe del Mar Records'}, '1: ... a compilation is not, whoever it is credited to');
    ok(($by{'McCoy Tyner'}{id} // 0) == 1 && length($by{'McCoy Tyner'}{sig} // '') == 32, '1: ... each with its library id and a signature');
    my $sig = $by{'McCoy Tyner'}{sig};
    ok($T->can('_untaggedArtists')->()->[1]{sig} eq $sig, '1: the signature is stable');
    $LIBDBH->do('INSERT INTO tracks (album, secs) VALUES (11, 200)');
    my ($mt) = grep { $_->{name} eq 'McCoy Tyner' } @{ $T->can('_untaggedArtists')->() };
    ok($mt->{sig} ne $sig, '1: ... and changes with a track added');
    $LIBDBH->do('DELETE FROM tracks WHERE album = 11 AND secs = 200');
    ($mt) = grep { $_->{name} eq 'McCoy Tyner' } @{ $T->can('_untaggedArtists')->() };
    ok($mt->{sig} eq $sig, '1: ... and back');
    $LIBDBH->do("UPDATE albums SET title = 'Fly with the Wind (Remastered)' WHERE id = 11");
    ($mt) = grep { $_->{name} eq 'McCoy Tyner' } @{ $T->can('_untaggedArtists')->() };
    ok($mt->{sig} ne $sig, '1: ... and with a title changed');
    $LIBDBH->do("UPDATE albums SET title = 'Fly With the Wind' WHERE id = 11");
    {   # LMS's own handle sets no sqlite_unicode: names come back as UTF-8 bytes
        local $LIBDBH = DBI->connect("dbi:SQLite:dbname=$lib", '', '', { RaiseError => 1, PrintError => 0 });
        my ($b) = grep { $_->{id} == 4 } @{ $T->can('_untaggedArtists')->() };
        ok($b && $b->{name} eq "Bj\x{f6}rk" && $b->{sig} eq $by{"Bj\x{f6}rk"}{sig},
           "1: read through LMS's kind of handle (bytes), the name is decoded and the signature the same");
    }
    {
        local $LIBDBH = undef;
        ok(ref $T->can('_untaggedArtists')->() eq 'ARRAY' && !@{ $T->can('_untaggedArtists')->() },
           '1: no library handle: no artists, no death');
    }
}

# ---------------------------------------------------------------------------
# 2. When.
# ---------------------------------------------------------------------------
{
    reset_all();
    $T->can('init')->();
    ok(scalar(grep { $_->[0] eq 'sub' && ref $_->[2] eq 'ARRAY' && $_->[2][0][0] eq 'rescan' && $_->[2][1][0] eq 'done' } @SUBS) == 1,
       "2: init subscribes to LMS's rescan done");
    ok($KEEPCUR{'dsc:trkwarm:2:'}, '2: ... registers its mark family with the store (old key versions retired)');
    my ($t) = armed($start);
    ok($t && $t->[0] == $NOW + 300, '2: ... and arms the first pass START_DELAY (5 min) after startup');
    ok(!@CALLS && !@WARMED, '2: nothing is asked at startup itself');

    $SCANNING = 1;
    run_timers(300);
    ok(!@CALLS, '2: a scan is running at the pass time: nothing done');
    ($t) = armed($start);
    ok($t && $t->[0] == $NOW + 120, '2: ... looked at again SCAN_RETRY later');
    $SCANNING = 0;
    run_timers(120);
    ok(scalar(grep { $_->[0] eq 'mbid' } @CALLS) == 2, '2: the scan over, the pass does both artists');
    ($t) = armed($start);
    ok($t && $t->[0] == $NOW + 86400, '2: ... and arms the next pass a day later');

    @CALLS = ();
    $start->();
    run_timers(5);
    ok(!grep({ $_->[0] eq 'mbid' } @CALLS), '2: a second pass the same day does nothing (every artist done, unchanged)');

    @CALLS = ();
    $NOW += 30 * 86400;
    $start->(); run_timers(5);
    ok(scalar(grep { $_->[0] eq 'mbid' && $_->[1] eq 'McCoy Tyner' } @CALLS) == 1,
       '2: RECHECK (30 days) later McCoy Tyner is done again (MusicBrainz adds groups)');

    @CALLS = ();
    $start->(); run_timers(5);
    $LIBDBH->do('INSERT INTO tracks (album, secs) VALUES (11, 200)');
    $start->(); run_timers(5);
    ok(scalar(grep { $_->[0] eq 'mbid' && $_->[1] eq 'McCoy Tyner' } @CALLS) == 1,
       '2: ... and at once when his untagged albums change (a track added)');
    $LIBDBH->do('DELETE FROM tracks WHERE album = 11 AND secs = 200');

    # Failed: no MusicBrainz artist for Bjork this time.
    reset_all();
    $MBID{"Bj\x{f6}rk"} = undef;
    $start->(); run_timers(5);
    @CALLS = ();
    $NOW += 3600;
    $start->(); run_timers(5);
    ok(!grep({ $_->[0] eq 'mbid' && $_->[1] eq "Bj\x{f6}rk" } @CALLS), '2: an artist that failed is not tried again within the hour ...');
    $NOW += 86400;
    $start->(); run_timers(5);
    ok(scalar(grep { $_->[0] eq 'mbid' && $_->[1] eq "Bj\x{f6}rk" } @CALLS) == 1, '2: ... but after RETRY_FAILED (a day)');

    # A rescan: soon after; one during a pass runs once more after it.
    reset_all();
    $T->can('_onRescanDone')->();
    ($t) = armed($start);
    ok($t && $t->[0] == $NOW + 60, '2: a rescan arms a pass RESCAN_DELAY (1 min) later');
    $HOLD_MBID = 1;                                   # the first artist hangs: the pass is running
    run_timers(60, 1);
    ok($T->can('_state')->()->{running}, '2: (a pass is running)');
    $T->can('_onRescanDone')->();
    ok($T->can('_state')->()->{again} && !armed($start), '2: a rescan during a pass is noted, not started over it');
    $HOLD_MBID = 0;
    run_until(sub { !$T->can('_state')->()->{running} });   # the watchdog, then the rest of the pass
    ($t) = armed($start);
    ok($t && $t->[0] == $NOW + 60 && !$T->can('_state')->()->{again},
       '2: ... and the pass runs once more after it (RESCAN_DELAY), not a day later');

    reset_all();
    $PREF{svc_priority_local} = 0;
    $start->(); run_timers(5);
    ok(!@CALLS, '2: the library not used (svc_priority_local 0): nothing done');
}

# ---------------------------------------------------------------------------
# 3. One artist.
# ---------------------------------------------------------------------------
{
    reset_all();
    my $t0 = $NOW;
    $start->(); run_timers(5);
    my ($m) = grep { $_->[0] eq 'mbid' && $_->[1] eq 'McCoy Tyner' } @CALLS;
    ok($m && $m->[2], "3: the artist is resolved the page's way (getArtistMbid), as background work");
    ok(!grep({ $_->[0] eq 'lblist' && $_->[1] eq $ART } @CALLS), '3: a list a page kept is used: no ListenBrainz list asked');
    ok(scalar(@WARMED) == 1 && join(',', sort @{ $WARMED[0]{rgs} }) eq join(',', sort $ELL, $MT),
       "3: the tracklists of the untagged leftover's shortlisted groups are asked for (both its candidates)");
    ok($WARMED[0]{bg} && $WARMED[0]{netbg}, '3: ... as background work');
    my $mark = mark('McCoy Tyner');
    ok(ref $mark eq 'HASH' && $mark->{ok} && $mark->{at} >= $t0 && $mark->{at} <= $NOW && length($mark->{sig} // '') == 32,
       '3: the artist is marked done, ok, with the time and its signature');

    # The page then decides from what is kept: the REAL _placements places it.
    my $p = Plugins::Discography::Browse::_placements(mbid => $ART, artist => 'McCoy Tyner',
        rgs => [ map { +{ %$_ } } @RG ], local => [ { %$own } ], relMap => {}, editions => {});
    ok(exists $p->{ranked}{10}, '3: ... and the page now has the evidence to decide from (nothing missing)');

    # Kept already: nothing asked.
    reset_all();
    $TRACKS{$MT}  = { t => [ [ 'a', 1 ] ], due => 0 };
    $TRACKS{$ELL} = { t => [], due => $NOW + 86400 };
    $start->(); run_timers(5);
    ok(!@WARMED, '3: every candidate kept (a "none" not yet due): nothing asked');
    ok((mark('McCoy Tyner') || {})->{ok}, '3: ... and marked done');
    reset_all();
    $TRACKS{$MT}  = { t => [ [ 'a', 1 ] ], due => 0 };
    $TRACKS{$ELL} = { t => [], due => $NOW - 1 };
    $start->(); run_timers(5);
    ok(scalar(@WARMED) == 1 && join(',', @{ $WARMED[0]{rgs} }) eq $ELL, '3: a "none" that is due is asked again, alone');

    # No list kept: ListenBrainz's, in the background.
    reset_all();
    %RGS = (); %LBRGS = ($ART => [ map { +{ %$_ } } @RG ]);
    $start->(); run_timers(5);
    my ($l) = grep { $_->[0] eq 'lblist' && $_->[1] eq $ART } @CALLS;
    ok($l && $l->[2], "3: no list kept: ListenBrainz's list is asked, as background work");
    ok(scalar(@WARMED) == 1, '3: ... and the tracklists from it');

    # A tagged album only: nothing to ask.
    reset_all();
    %LOCALS = (1 => [ { %$own, _mbid => '03b4e5aa-b136-3376-bf80-92d66adf743b' } ]);
    $start->(); run_timers(5);
    ok(!@WARMED, '3: a tagged leftover is not the track match\'s: nothing asked for it');

    # Claimed by title: nothing to ask.
    reset_all();
    %LOCALS = (1 => [ { %$own, _candTitle => 'McCoy Tyner Plays Ellington', name => 'McCoy Tyner Plays Ellington' } ]);
    $start->(); run_timers(5);
    ok(!@WARMED, '3: an album its title claims: nothing asked');

    # ListenBrainz fails: not marked ok, so it is tried again sooner.
    reset_all();
    $LB_FAIL = 1;
    $start->(); run_timers(5);
    ok(scalar(@WARMED) == 1 && !(mark('McCoy Tyner') || {})->{ok},
       '3: the tracklists not answered: the artist is marked to retry, not done');

    # No artist found, no groups.
    reset_all();
    $MBID{'McCoy Tyner'} = undef;
    $start->(); run_timers(5);
    ok(!@WARMED && !(mark('McCoy Tyner') || { ok => 1 })->{ok}, '3: no MusicBrainz artist: nothing asked, retry later');
    reset_all();
    %RGS = (); %LBRGS = ();
    $start->(); run_timers(5);
    ok(!@WARMED && !(mark('McCoy Tyner') || { ok => 1 })->{ok}, '3: no release groups: nothing asked, retry later');
    reset_all();
    $MBID{'McCoy Tyner'} = 'va';
    $start->(); run_timers(5);
    ok(!@WARMED && (mark('McCoy Tyner') || {})->{ok}, "3: MusicBrainz's Various Artists: nothing asked, done");
}

# ---------------------------------------------------------------------------
# 4. Off the page's way.
# ---------------------------------------------------------------------------
{
    reset_all();
    $FGBUSY = 1;
    $start->();
    run_timers(2);
    ok(!@CALLS, '4: a page has a request out: no artist is started');
    $FGBUSY = 0;
    run_timers(3);
    ok(scalar(grep { $_->[0] eq 'mbid' } @CALLS) >= 1, '4: ... the page done, the pass goes on (BUSY_RETRY)');

    reset_all();
    $HOLD_MBID = 1;
    $start->();
    run_timers(1);
    ok(scalar(grep { $_->[0] eq 'mbid' } @CALLS) == 1, '4: an artist whose answer never comes ...');
    $HOLD_MBID = 0;
    run_timers(125, 5);
    my @m = grep { $_->[0] eq 'mbid' } @CALLS;
    ok(scalar(@m) == 2 && $m[1][1] ne $m[0][1], '4: ... is given up at ARTIST_TIMEOUT and the pass goes on to the next');
    ok(!(mark($m[0][1]) || { ok => 1 })->{ok}, '4: ... marked to retry');

    reset_all();
    $start->();                                       # Bjork, at once (no groups: done, failed)
    $SCANNING = 1;
    run_timers(2, 3);
    ok(!grep({ $_->[0] eq 'mbid' && $_->[1] eq 'McCoy Tyner' } @CALLS),
       '4: a scan starting mid-pass holds the next artist');
    $SCANNING = 0;
    run_timers(120);
    ok(scalar(grep { $_->[0] eq 'mbid' && $_->[1] eq 'McCoy Tyner' } @CALLS) == 1, '4: ... until it is over'); 
}

# ---------------------------------------------------------------------------
# 5. A page's hand-off.
# ---------------------------------------------------------------------------
{
    reset_all();
    my $want = $T->can('want');
    $want->([ $MT ]);
    $want->([ $MT, $ELL ]);
    ok(scalar(@TIMERS) == 1 && $TIMERS[0][0] == $NOW + 10, '5: a page\'s missing groups are asked WANT_DELAY later, one timer');
    ok(!@WARMED, '5: ... not at once (the page has drawn; nothing is asked on its way)');
    run_timers(10);
    ok(scalar(@WARMED) == 1 && join(',', @{ $WARMED[0]{rgs} }) eq "$MT,$ELL" && $WARMED[0]{bg} && $WARMED[0]{netbg},
       '5: ... then together, each once, as background work');
    $want->([ $MT ]);
    run_timers(10);
    ok(scalar(@WARMED) == 2, '5: wanted again later (after a failure): asked again');

    reset_all();
    $want->([ $MT ]);
    $SCANNING = 1;
    run_timers(10);
    ok(!@WARMED, '5: a scan running: held');
    $SCANNING = 0;
    run_timers(120);
    ok(scalar(@WARMED) == 1, '5: ... and asked once it is over');
}

# ---------------------------------------------------------------------------
# 6. Two library artists of one name (review 2026-10-08: Simon's library holds
#    London Symphony Orchestra under two ids). The mark was kept under the name
#    alone, so each overwrote the other's and one of them (whichever had not
#    written last) was done again on every pass. The second pass below is the
#    test that tells the two keys apart; the change after it pins the new one.
# ---------------------------------------------------------------------------
{
    reset_all();
    $LIBDBH->do("INSERT INTO contributors (id, name) VALUES (7, 'McCoy Tyner')");
    album(18, 'Sahara', 7, undef, 0, 600, 400);
    $LOCALS{7} = [];
    my @two = grep { $_->{name} eq 'McCoy Tyner' } @{ $T->can('_untaggedArtists')->() };
    ok(scalar(@two) == 2 && $two[0]{id} != $two[1]{id} && $two[0]{sig} ne $two[1]{sig},
       '6: (two library artists named McCoy Tyner, each with its own untagged album)');
    $start->(); run_timers(5);
    ok(scalar(grep { $_->[0] eq 'local' && ($_->[1] == 1 || $_->[1] == 7) } @CALLS) == 2, '6: the pass does both');
    my @keys = sort grep { /^dsc:trkwarm:2:mccoy tyner\|/ } keys %CACHE;
    ok(scalar(@keys) == 2 && $CACHE{ $keys[0] }{ok} && $CACHE{ $keys[1] }{ok}, '6: ... and keeps a mark for each, by name and signature');
    ok(scalar(grep { ($TTL{$_} // 0) == 30 * 86400 } @keys) == 2,
       '6: each mark is kept RECHECK (30 days), so one left behind by a change of albums goes');
    @CALLS = ();
    $start->(); run_timers(5);
    ok(!grep({ $_->[0] eq 'mbid' } @CALLS), '6: a second pass the same day does neither (each read its own mark)');
    # A change to one of them redoes that one only.
    $LIBDBH->do('INSERT INTO tracks (album, secs) VALUES (18, 200)');
    @CALLS = ();
    $start->(); run_timers(5);
    my @did = map { $_->[1] } grep { $_->[0] eq 'local' } @CALLS;
    ok(scalar(@did) == 1 && $did[0] == 7, '6: a track added to one: that one alone is done again');
    $LIBDBH->do('DELETE FROM tracks WHERE album = 18');
    $LIBDBH->do('DELETE FROM albums WHERE id = 18');
    $LIBDBH->do('DELETE FROM contributors WHERE id = 7');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
