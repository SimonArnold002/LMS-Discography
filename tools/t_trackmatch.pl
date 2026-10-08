#!/usr/bin/env perl
#
# REGRESSION TEST - THE TRACK MATCH AND THE USER'S OWN MATCHES (0.56.61).
#
# Field (a tester, 2026-10-08): his "McCoy Tyner Plays John Coltrane" sat in
# "Also in your library" while MusicBrainz's "McCoy Tyner plays John Coltrane:
# Live at the Village Vanguard" read unowned - the title rules only let the
# OWNED side be the longer one. Simon: match some of the name, then the tracks;
# "base it on a weighting match"; and a manual match for what it cannot decide.
#
#   1. PARITY with the replay (tools/leftover/, CLAUDE.md "REPLAYED"): the real
#      cases the rule was measured on - Simon's leftovers, the tester's album,
#      and every case with its real group HIDDEN that any rule version came
#      close on (tools/fixtures/trackmatch_replay.json) - get the replay's
#      rule-v3 verdict from Sources::trackShortlist / trackEvidence / trackPick.
#   2. The rule's parts, one at a time (bonus tracks, a two-album set, unknown
#      times, a live version, a tie, the margin, the title weight, the shortlist).
#   3. matchesFor / claimedLocalIds take a PLACED owned copy as an id places it.
#   4. Browse::_placements: an id tag > the user's match > a title claim > the
#      track match; '-' stops the track match; tracklists not kept are asked
#      for, never decided on; only the artist's own albums; only shown groups;
#      only an UNTAGGED album (0.56.62: a tagged one is its tag's, right or
#      wrong); `cands` collects every shortlisted group (the library pass).
#   5. The artist page end to end (the REAL _buildList): the album reads Local
#      on its tile and leaves "Also in your library"; a tracklist not kept is
#      handed to the background work (TrackWarm::want), never asked for by the
#      page (0.56.62).
#   6. The release page: "Remove the match to ..." / "Match an album from your
#      library", the picker's order and rows, the action, _rgView's dispatch.
#
# Standalone:  perl tools/t_trackmatch.pl
#
use strict;
use warnings;
use FindBin;
use JSON::PP ();

our (%PREF, %OFFICIAL, %TRACKS, %MANUAL, @SET, %LIBTRACKS, $LOCAL, @RGS, @DETAIL, %EDITIONS);

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers Slim::Utils::Strings
                  Slim::Control::Request Slim::Schema Slim::Web::HTTP
                  Slim::Networking::SimpleAsyncHTTP Slim::Utils::Misc
                  Plugins::Discography::Plugin Plugins::Discography::API)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Null' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Plugins::Discography::DB::manualFor'} = sub { +{ %{ $main::MANUAL{ $_[1] } || {} } } };
    *{'Plugins::Discography::DB::manualSet'} = sub {
        my (undef, $a, $k, $rg, $t) = @_;
        push @main::SET, [ $a, $k, $rg, $t ];
        $main::MANUAL{$a}{$k} = $rg;
        return 1;
    };
    *{'Slim::Utils::Strings::cstring'}   = sub { my (undef, $t, @a) = @_; @a ? "$t(" . join('|', @a) . ')' : $t };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Control::Request::executeRequest'} = sub {
        my (undef, $cmd) = @_;
        my ($al) = map { /^album_id:(\d+)$/ ? $1 : () } @$cmd;
        my $loop = [ map { +{ title => $_->[0], duration => $_->[1], tracknum => $_->[2], disc => 1 } }
                     @{ $main::LIBTRACKS{ $al // '' } || [] } ];
        return bless { loop => $loop }, 'T::Req';
    };
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');

    my $A = 'Plugins::Discography::API';
    *{"${A}::peekOfficial"}        = sub { +{ %main::OFFICIAL } };
    *{"${A}::peekGroupTracks"}     = sub { $main::TRACKS{ $_[1] } };
    *{"${A}::peekEditions"}        = sub { +{ %main::EDITIONS } };
    *{"${A}::caaImage"}            = sub { 'caa' };
    *{"${A}::peekCoverFlags"}      = sub { undef };
    *{"${A}::peekReleaseMap"}      = sub { {} };
    *{"${A}::peekLocalReleaseMap"} = sub { {} };
    *{"${A}::peekLocalReleaseTypes"} = sub { {} };
    *{"${A}::clearArtistEmpty"}    = sub { 0 };
    *{"${A}::markArtistEmpty"}     = sub { };
    *{"${A}::peekBands"}           = sub { undef };
    *{"${A}::peekCollabs"}         = sub { undef };
    *{"${A}::peekArtistName"}      = sub { undef };
    *{"${A}::peekArtistAliases"}   = sub { undef };
    *{"${A}::peekArtistEnglishName"} = sub { undef };
    *{"${A}::getReleaseGroups"}    = sub { my ($c, %a) = @_; $a{onDone}->([ map { +{ %$_ } } @main::RGS ]) };
}
package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}
package T::Prefs; our $AUTOLOAD; sub get { $main::PREF{ $_[1] } } sub AUTOLOAD { return } sub DESTROY {}
package T::Req;   sub getResult { $_[0]{loop} }

package main;
binmode STDOUT, ':utf8';

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
require Plugins::Discography::Browse;
my $S = 'Plugins::Discography::Sources';
my $B = 'Plugins::Discography::Browse';
{
    no strict 'refs'; no warnings 'redefine';
    *{"${S}::orderedSources"} = sub { ({ name => 'Local', local => 1 }) };
    *{"${S}::peekPool"}       = sub { +{ bySvc => {}, resolved => 1, index => {} } };
    *{"${S}::localTracks"}    = sub { [] };
    *{"${S}::localAlbums"}    = sub { [ map { +{ %$_ } } @{ $main::LOCAL || [] } ] };
    *{"${B}::_releaseDetail"} = sub { push @main::DETAIL, $_[2]; $_[1]->({ items => [] }) };
}

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

%PREF = (show_types => 'ALBUMS,EPS,SINGLES,COMPILATIONS,LIVE,OTHER', show_bio => 0,
         show_library_extras => 1, show_streaming_extras => 0, hide_unmatched => 0,
         svc_priority_local => 1);

# ---------------------------------------------------------------------------
# 1. PARITY WITH THE REPLAY (rule v3 on real cases).
# ---------------------------------------------------------------------------
{
    my $fx = do {
        open my $fh, '<:raw', "$FindBin::Bin/fixtures/trackmatch_replay.json" or die "fixture: $!";
        local $/; JSON::PP->new->utf8->decode(scalar <$fh>);
    };
    my (%n, @bad);
    for my $c (@$fx) {
        my @groups = map { +{ mbid => $_->{mbid}, title => $_->{title} } } @{ $c->{cands} };
        my %trk = map { ($_->{mbid} => $_->{tracks}) } @{ $c->{cands} };
        my @sl = $S->trackShortlist($c->{title}, $c->{artist}, \@groups, {});
        for my $x (@sl) {
            my $t = $trk{ $x->{rg}{mbid} };
            $x->{ev} = ($t && @$t && @{ $c->{own} }) ? $S->trackEvidence($c->{own}, $t) : undef;
        }
        my ($win, $ranked) = $S->trackPick(\@sl, $c->{title}, $c->{artist});
        my $got = $win ? 'match' : (grep { $_->{agree} } @$ranked) ? 'manual' : 'none';
        my $ok = $got eq $c->{expect}{verdict}
              && ($got ne 'match' || $win->{rg}{mbid} eq $c->{expect}{mbid})
              && scalar(@sl) == scalar(@{ $c->{cands} });
        $n{"$c->{kind}/$c->{expect}{verdict}"}++;
        push @bad, "$c->{artist} - $c->{title}: want $c->{expect}{verdict}, got $got" unless $ok;
    }
    ok(scalar(@$fx) == 245, '1: the replay fixture holds its 245 cases');
    ok(!@bad, '1: every case gets the replay\'s rule-v3 verdict (and the same group)'
              . (@bad ? ' - ' . join('; ', @bad[0 .. ($#bad < 4 ? $#bad : 4)]) : ''));
    ok(($n{'leftover/match'} // 0) == 6 && ($n{'synthetic/match'} // 0) == 1 && ($n{'leftover/manual'} // 0) == 1,
       "1: ... Simon's six matched leftovers, the tester's McCoy Tyner, Dusty Springfield to the manual list");
    ok(($n{'holdout/match'} // 0) == 6 && ($n{'holdout/none'} // 0) == 210,
       '1: ... and with the real group hidden, 6 matched (MusicBrainz holding the tracklist twice), 210 not');
}

# ---------------------------------------------------------------------------
# 2. THE RULE'S PARTS.
# ---------------------------------------------------------------------------
my @T10 = map { [ "Song $_", 200 + $_ ] } 1 .. 10;
sub ev { $S->trackEvidence(@_) }
sub pick {
    my ($title, $artist, @c) = @_;
    my ($win, $r) = $S->trackPick([ map { +{ %$_ } } @c ], $title, $artist);
    return ($win ? $win->{rg}{mbid} : undef, $r);
}
{
    my $e = ev([ @T10, [ 'Bonus 1', 100 ], [ 'Bonus 2', 100 ], [ 'Bonus 3', 100 ] ], \@T10);
    ok(abs($e->{found} - 10 / 13) < 1e-9 && $e->{cover} == 1 && $e->{dur} == 1,
       '2: your copy with 3 bonus tracks: found 10/13, cover 1, times agree');
    my ($w) = pick('Album', 'X', { rg => { mbid => 'g' }, tscore => 1, ev => $e });
    ok(($w // '') eq 'g', '2: ... matched (your copy may carry extras)');

    $e = ev(\@T10, [ @T10, map { [ "Other $_", 200 ] } 1 .. 10 ]);
    ($w) = pick('Album', 'X', { rg => { mbid => 'g' }, tscore => 1, ev => $e });
    ok(!defined $w, '2: a two-album set holding all your tracks (cover 0.5) is NOT matched');

    $e = ev(\@T10, [ map { [ $_->[0], 0 ] } @T10 ]);
    ok($e->{m} == 10 && $e->{timed} == 0 && !defined $e->{dur}, '2: no running times on the group: none timed');
    ($w) = pick('Album', 'X', { rg => { mbid => 'g' }, tscore => 1, ev => $e });
    ok(!defined $w, '2: ... so it is NOT matched (a live or demo version has the same titles)');

    $e = ev(\@T10, [ map { [ $_->[0], $_->[1] + 40 ] } @T10 ]);
    ok($e->{dur} == 0, '2: every track 40 s longer: times disagree');
    ($w) = pick('Album', 'X', { rg => { mbid => 'g' }, tscore => 1, ev => $e });
    ok(!defined $w, '2: ... NOT matched');
    $e = ev(\@T10, [ map { [ $_->[0], $_->[1] + 3 ] } @T10 ]);
    ok($e->{dur} == 1, '2: control: 3 s apart (a rip) agree');

    $e = ev([ [ 'Naima - 2001 Remaster', 737 ], [ 'Afro Blue (Live)', 738 ] ],
            [ [ 'Naima - Mono Version', 737 ], [ 'Afro Blue', 738 ] ]);
    ok($e->{m} == 2, '2: " - 2001 Remaster" / " - Mono Version" and "(Live)" are dropped before pairing');
    $e = ev([ [ 'Naima - Lisa', 737 ] ], [ [ 'Naima', 737 ] ]);
    ok($e->{m} == 1, '2: control: a title that is the other plus words still pairs');
    $e = ev([ [ 'Love', 200 ] ], [ [ 'Love Me Do', 200 ] ]);
    ok($e->{m} == 1, '2: ... one way or the other (one-to-one)');

    my $full = ev(\@T10, \@T10);
    my @two = ({ rg => { mbid => 'a' }, tscore => 1, ev => $full }, { rg => { mbid => 'b' }, tscore => 1, ev => $full });
    ($w) = pick('Album', 'X', @two);
    ok(!defined $w, '2: two groups with the same tracklist: a tie decides nothing (the manual list)');
    my ($wA, $rA) = pick('Album', 'X', { %{ $two[0] } }, { %{ $two[1] }, tscore => 0.6 });
    ok(($wA // '') eq 'a' && $rA->[0]{score} - $rA->[1]{score} >= 0.1 - 1e-9,
       '2: a lead of 0.12 (title 1 vs 0.6) passes the 0.1 margin');
    my ($wB) = pick('Album', 'X', { %{ $two[0] } }, { %{ $two[1] }, tscore => 0.7 });
    ok(!defined $wB, '2: a lead of 0.09 does not');

    my $part = ev(\@T10, \@T10);
    my ($g0) = pick('Greatest Hits', 'X', { rg => { mbid => 'g' }, tscore => 0.1, ev => $part });
    my ($g1) = pick('Something', 'X', { rg => { mbid => 'g' }, tscore => 0.2, ev => $part });
    ok(!defined $g0 && ($g1 // '') eq 'g',
       '2: identical tracks still need SOME title: 0.7 + 0.3 x 0.1 x 0.5 = 0.715 falls short, 0.7 + 0.06 passes');
    my $weak = ev(\@T10, [ @T10[0 .. 8], [ 'Song 10', 400 ] ]);
    my ($g2) = pick('Greatest Hits', 'X', { rg => { mbid => 'g' }, tscore => 0.3, ev => $weak });
    my ($g3) = pick('Something', 'X', { rg => { mbid => 'g' }, tscore => 0.3, ev => $weak });
    ok(!defined $g2 && ($g3 // '') eq 'g',
       '2: the title weight counts: a generic title ("Greatest Hits", 0.5) falls short where a distinctive one passes');

    my @gs = map { +{ mbid => "g$_", title => "Word$_ Common" } } 1 .. 8;
    my @sl = $S->trackShortlist('Common Ground', 'X', \@gs, {});
    ok(scalar(@sl) == 5, '2: the shortlist keeps 5');
    @sl = $S->trackShortlist('McCoy Tyner Plays John Coltrane', 'McCoy Tyner',
        [ { mbid => 'a', title => 'McCoy Tyner plays John Coltrane: Live at the Village Vanguard' },
          { mbid => 'b', title => 'McCoy Tyner Plays Ellington' },
          { mbid => 'c', title => 'Fly With the Wind' } ], {});
    ok(scalar(@sl) == 2 && $sl[0]{rg}{mbid} eq 'a' && $sl[0]{tscore} > $sl[1]{tscore},
       "2: the artist's own words set aside: 'plays' alone links Ellington, weaker; no shared word, no candidate");
    @sl = $S->trackShortlist('Third', 'Big Star',
        [ { mbid => 'a', title => '3rd', aliases => [ 'Third/Sister Lovers' ] } ], {});
    ok(scalar(@sl) == 1, '2: a group is judged by its aliases too');
    @sl = $S->trackShortlist('Tour de France', 'Kraftwerk',
        [ { mbid => 'a', title => 'Tour de France Soundtracks' } ], { a => [ [ 'tour de france', 'Tour de France', 0 ] ] });
    ok(scalar(@sl) == 1 && $sl[0]{tscore} == 1, '2: ... and its edition titles');
}

# ---------------------------------------------------------------------------
# 3. matchesFor / claimedLocalIds: a PLACED owned copy.
# ---------------------------------------------------------------------------
my $MT  = '4b65bc2e-8fc5-30ee-bec9-7b8c1da84354';
my $MTT = 'McCoy Tyner plays John Coltrane: Live at the Village Vanguard';
my $ELL = 'eeeeeeee-0000-4000-8000-000000000001';
my $own = { _albumid => 77, _candTitle => 'McCoy Tyner Plays John Coltrane', _candArtist => 'McCoy Tyner',
            _svc => 'Local', name => 'McCoy Tyner Plays John Coltrane', _year => 2001 };
{
    my $local = [ { %$own } ];
    my $sec = $S->matchesFor({}, 'McCoy Tyner', $MTT, $local, $MT, {}, undef, {});
    ok(!@$sec, '3: control: unplaced, the title rules leave the shorter owned title off the group');
    $sec = $S->matchesFor({}, 'McCoy Tyner', $MTT, $local, $MT, {}, undef, { placed => { 77 => $MT } });
    ok(scalar(@$sec) == 1 && $sec->[0]{svc} eq 'Local' && $sec->[0]{items}[0]{_albumid} == 77,
       '3: placed there, it reads Local on its group');
    $sec = $S->matchesFor({}, 'McCoy Tyner', 'McCoy Tyner Plays John Coltrane', $local, $ELL, {}, undef,
                          { placed => { 77 => $MT } });
    ok(!@$sec, '3: ... and on no other group, even one its title matches exactly');
    $sec = $S->matchesFor({}, 'McCoy Tyner', 'McCoy Tyner Plays John Coltrane', $local, $ELL, {}, undef, {});
    ok(scalar(@$sec) == 1, '3: control: unplaced, that exact title claims it');
    my $cl = $S->claimedLocalIds([ { mbid => $MT, title => $MTT } ], 'McCoy Tyner', $local, {}, {});
    ok(!$cl->{77}, '3: claimedLocalIds: unplaced, it is left over');
    $cl = $S->claimedLocalIds([ { mbid => $MT, title => $MTT } ], 'McCoy Tyner', $local, {}, {}, { 77 => $MT });
    ok($cl->{77}, '3: ... placed, it is claimed');
}

# ---------------------------------------------------------------------------
# 4. Browse::_placements.
# ---------------------------------------------------------------------------
my $ART = 'aaaaaaaa-0000-4000-8000-0000000000aa';
my @MT_TRACKS = ([ 'Naima', 737 ], [ "Moment's Notice", 428 ], [ 'Crescent', 748 ], [ 'After the Rain', 218 ],
                 [ 'Afro Blue', 738 ], [ 'I Want to Talk About You', 668 ], [ 'Mr. Day', 441 ]);
my @RG4 = ({ mbid => $MT,  title => $MTT, type => 'Album', secondary => ['Live'], date => '2001' },
           { mbid => $ELL, title => 'McCoy Tyner Plays Ellington', type => 'Album', secondary => [], date => '1965' },
           { mbid => 'ffffffff-0000-4000-8000-000000000003', title => 'Fly With the Wind', type => 'Album',
             secondary => [], date => '1976' });
sub plc {
    my (%o) = @_;
    return $B->can('_placements')->(mbid => $ART, artist => 'McCoy Tyner', rgs => [ map { +{ %$_ } } @RG4 ],
        local => $o{local} || [ map { +{ %$_ } } @{ $LOCAL } ], relMap => $o{relMap} || {},
        editions => {}, ($o{need} ? (need => $o{need}) : ()), ($o{cands} ? (cands => $o{cands}) : ()));
}
sub reset4 {
    %OFFICIAL = (); %MANUAL = (); @SET = (); %EDITIONS = ();
    %TRACKS = ($MT => [ map { [ $_->[0], $_->[1] ] } @MT_TRACKS ],
               $ELL => [ map { [ "Ellington $_", 300 ] } 1 .. 7 ]);
    %LIBTRACKS = (77 => [ map { [ $MT_TRACKS[$_][0], $MT_TRACKS[$_][1] + 1, $_ + 1 ] } 0 .. 6 ]);
    $LOCAL = [ { %$own } ];
}
{
    reset4();
    my $p = plc();
    ok(($p->{placed}{77} // '') eq $MT && $p->{how}{77} eq 'tracks',
       '4: the tester\'s album goes on "...: Live at the Village Vanguard" by its tracks');
    ok(!@{ $p->{leftovers} }, '4: ... and is no longer left over');
    ok(ref $p->{ranked}{77} eq 'ARRAY' && $p->{ranked}{77}[0]{rg}{mbid} eq $MT, '4: ... ranked first of its candidates');

    reset4(); delete $TRACKS{$MT};
    my %need;
    $p = plc(need => \%need);
    ok($need{$MT} && !$need{$ELL}, '4: a tracklist not kept is asked for (and only that one)');
    ok(!%{ $p->{placed} } && scalar(@{ $p->{leftovers} }) == 1 && !$p->{ranked}{77},
       '4: ... and nothing is decided on part of the evidence: the album stays left over');

    reset4(); $TRACKS{$MT} = [];
    $p = plc();
    ok(!%{ $p->{placed} }, '4: ListenBrainz has no tracklist for it ([]): not matched');

    reset4(); $MANUAL{$ART} = { "mccoy tyner plays john coltrane\x{1f}mccoy tyner" => '-' };
    $p = plc();
    ok(!%{ $p->{placed} } && scalar(@{ $p->{leftovers} }) == 1 && $p->{ranked}{77},
       "4: a '-' row (the user removed the match) stops the track match; the picker still has its ranking");

    reset4(); $MANUAL{$ART} = { "mccoy tyner plays john coltrane\x{1f}mccoy tyner" => $ELL };
    $p = plc();
    ok(($p->{placed}{77} // '') eq $ELL && $p->{how}{77} eq 'manual', "4: the user's match wins over the tracks");

    reset4();
    $LOCAL = [ { %$own, _candTitle => 'Fly With the Wind', name => 'Fly With the Wind' } ];
    $MANUAL{$ART} = { "fly with the wind\x{1f}mccoy tyner" => $MT };
    $p = plc();
    ok(($p->{placed}{77} // '') eq $MT, "4: ... and over a title claim (the album's exact title is another group's)");

    reset4();
    $LOCAL = [ { %$own, _candTitle => 'Fly With the Wind', name => 'Fly With the Wind' } ];
    $p = plc();
    ok($p->{claimed}{77} && !%{ $p->{placed} } && !@{ $p->{leftovers} },
       "4: control: unmatched by hand, that album is its own title's (the claims are not served stale for a new title)");

    reset4(); $MANUAL{$ART} = { "mccoy tyner plays john coltrane\x{1f}mccoy tyner" => $ELL };
    $LOCAL = [ { %$own, _mbid => 'rel-x' } ];
    $p = plc(relMap => { 'rel-x' => $MT });
    ok(!defined $p->{placed}{77}, "4: an id tag placing the copy on the page beats the user's match (A TAG IS TRUSTED)");

    reset4(); $MANUAL{$ART} = { "mccoy tyner plays john coltrane\x{1f}mccoy tyner" => 'dddddddd-0000-4000-8000-00000000dead' };
    $p = plc();
    ok(($p->{placed}{77} // '') eq $MT && $p->{how}{77} eq 'tracks',
       '4: a row naming a group the page no longer lists is ignored (the track match decides)');

    reset4(); $LOCAL = [ { %$own, _otherArtist => 1 } ];
    $p = plc();
    ok(!%{ $p->{placed} } && !@{ $p->{leftovers} }, '4: an album only credited ON the artist is never placed or offered');
    reset4(); $LOCAL = [ { %$own, _candArtist => 'Various Artists' } ];
    $p = plc();
    ok(!%{ $p->{placed} } && !@{ $p->{leftovers} }, '4: ... nor an Appearance (another album artist)');

    reset4(); %OFFICIAL = ($MT => 0);
    $p = plc();
    ok(!%{ $p->{placed} }, '4: a bootleg-only group is never a candidate');
    reset4();
    my @hidden = map { +{ %$_ } } @RG4; $hidden[0]{secondary} = [ 'Live', 'DJ-mix' ];
    $p = $B->can('_placements')->(mbid => $ART, artist => 'McCoy Tyner', rgs => \@hidden,
        local => [ { %$own } ], relMap => {}, editions => {});
    ok(!%{ $p->{placed} }, '4: ... nor a group the page never lists (a DJ mix)');

    reset4();
    {
        my $n = 0;
        my $real = $S->can('claimedLocalIds');
        no strict 'refs'; no warnings 'redefine';
        local *{"${S}::claimedLocalIds"} = sub { $n++; $real->(@_) };
        $LOCAL = [ { %$own, _albumid => 91 } ];
        $LIBTRACKS{91} = $LIBTRACKS{77};
        plc(); plc();
        ok($n == 1, '4: the claims are worked out ONCE for the same inputs (the draw, then its release page)');
        plc(relMap => { 'rel-new' => $MT });
        ok($n == 2, '4: ... and again when the release map changes (a later visit, after the check)');
    }

    reset4();
    $p = $B->can('_placements')->(mbid => undef, artist => 'McCoy Tyner', rgs => [ @RG4 ], local => [ { %$own } ]);
    ok(!%{ $p->{placed} } && !@{ $p->{leftovers} }, '4: no artist mbid: nothing placed, nothing asked');

    # ONLY AN UNTAGGED ALBUM (0.56.62). Thievery Corporation's "DJ-Kicks" carries
    # its release id; the group it names is a DJ mix the page hides.
    reset4();
    my $DJ = 'aceba45a-7f4f-38f2-bed2-0ef33f718c68';
    $LOCAL = [ { %$own, _mbid => '03b4e5aa-b136-3376-bf80-92d66adf743b' } ];
    my (%need2, %cands2);
    $p = plc(relMap => { '03b4e5aa-b136-3376-bf80-92d66adf743b' => $DJ }, need => \%need2, cands => \%cands2);
    ok(!%{ $p->{placed} } && scalar(@{ $p->{leftovers} }) == 1,
       '4: a TAGGED album whose group the page does not list stays in "Also in your library", by its tracks on nothing');
    ok(!$p->{ranked}{77} && !%need2 && !%cands2,
       '4: ... not shortlisted, no tracklist wanted, nothing ranked (its tag names its release)');
    reset4(); delete $TRACKS{$MT};
    $LOCAL = [ { %$own, _mbid => 'ffffffff-1111-4000-8000-00000000beef' } ];
    %need2 = ();
    $p = plc(need => \%need2);
    ok(!%need2 && !%{ $p->{placed} }, '4: ... nor a tagged album whose release no map knows yet (a first visit: Kraftwerk)');
    reset4(); delete $TRACKS{$MT};
    %need2 = (); %cands2 = ();
    $p = plc(need => \%need2, cands => \%cands2);
    ok($need2{$MT} && $cands2{$MT} && $cands2{$ELL},
       '4: control: the same album UNTAGGED is shortlisted, its missing tracklist wanted');
    ok(!$need2{$ELL}, '4: ... `need` only the missing, `cands` every shortlisted group (the library pass asks those due)');
}

# ---------------------------------------------------------------------------
# 5. The artist page end to end: the REAL _buildList.
# ---------------------------------------------------------------------------
sub flat { map { ($_, flat(@{ $_->{items} || [] })) } @_ }
{
    reset4();
    my $opts = { artist => 'McCoy Tyner', artist_id => 5, mbid => $ART, sort => 'newest', features => '' };
    my $rows = $B->can('_buildList')->(undef, { %$opts }, $ART, [ map { +{ %$_ } } @RG4 ], '', [ { %$own } ]);
    my @all = flat(@$rows);
    my ($tile) = grep { ($_->{name} // '') eq $MTT } @all;
    ok($tile && ($tile->{line2} // '') =~ /Local/, '5: the tile "...: Live at the Village Vanguard" reads Local');
    ok(!grep({ ($_->{name} // '') =~ /^PLUGIN_DISCOGRAPHY_LIBRARY_EXTRAS/ } @all),
       '5: ... and "Also in your library" is gone (its one album is on its tile)');

    reset4(); delete $TRACKS{$MT};
    $rows = $B->can('_buildList')->(undef, { %$opts }, $ART, [ map { +{ %$_ } } @RG4 ], '', [ { %$own } ]);
    @all = flat(@$rows);
    ($tile) = grep { ($_->{name} // '') eq $MTT } @all;
    ok(!($tile && ($tile->{line2} // '') =~ /Local/)
       && grep({ ($_->{name} // '') =~ /^PLUGIN_DISCOGRAPHY_LIBRARY_EXTRAS \(1\)/ } @all),
       '5: control: with no tracklist kept, the album stays in "Also in your library" as before');

    # THE HAND-OFF (0.56.62): a tracklist the page found missing goes to the
    # background work, never to a request of the page's own.
    {
        no strict 'refs'; no warnings 'redefine';
        my @wanted;
        local *{'Plugins::Discography::TrackWarm::want'} = sub { push @wanted, [ @{ $_[0] } ] };
        reset4(); delete $TRACKS{$MT};
        $B->can('_buildList')->(undef, { %$opts }, $ART, [ map { +{ %$_ } } @RG4 ], '', [ { %$own } ]);
        ok(scalar(@wanted) == 1 && join(',', @{ $wanted[0] }) eq $MT,
           '5: the missing tracklist is handed to the background work (TrackWarm::want), once, that group only');
        @wanted = ();
        reset4();
        $B->can('_buildList')->(undef, { %$opts }, $ART, [ map { +{ %$_ } } @RG4 ], '', [ { %$own } ]);
        ok(!@wanted, '5: ... nothing handed over when every tracklist is kept');
        reset4(); delete $TRACKS{$MT};
        $B->can('_buildList')->(undef, { %$opts }, $ART, [ map { +{ %$_ } } @RG4 ], '',
                                [ { %$own, _mbid => 'ffffffff-1111-4000-8000-00000000beef' } ]);
        ok(!@wanted, '5: ... nor for a tagged album');
    }
}

# ---------------------------------------------------------------------------
# 6. The release page: rows, picker, action, dispatch.
# ---------------------------------------------------------------------------
{
    my $pass6 = { artist => 'McCoy Tyner', artist_id => 5, mbid => $ART, features => '' };
    my $rgMT  = { %{ $RG4[0] } };
    my $rgEll = { %{ $RG4[1] } };

    reset4();
    my $p = plc();
    my @r = $B->can('_manualRows')->(undef, $pass6, $rgMT, $p);
    ok(scalar(@r) == 1 && $r[0]{id} eq 'lm:del:77' && $r[0]{name} eq 'PLUGIN_DISCOGRAPHY_MATCH_REMOVE(McCoy Tyner Plays John Coltrane)'
       && $r[0]{nextWindow} eq 'refresh',
       '6: the release its tracks put it on offers "Remove the match to McCoy Tyner Plays John Coltrane", refreshing');
    my $fp = $r[0]{itemActions}{items}{fixedParams} || {};
    ok(($fp->{rg} // '') eq $MT && ($fp->{item} // '') eq 'lm:del:77' && ($fp->{mbid} // '') eq $ART,
       '6: ... addressed by its own params (the release, the row, the artist), never by position');
    @r = $B->can('_manualRows')->(undef, $pass6, $rgEll, $p);
    ok(!@r, '6: another release offers nothing: nothing is left over, nothing placed there');

    reset4(); delete $TRACKS{$MT};
    $LOCAL = [ { %$own }, { %$own, _albumid => 78, _candTitle => 'Bon Voyage', name => 'Bon Voyage', _year => 1987 },
               { %$own, _albumid => 79, _candTitle => 'Atlantis', name => 'Atlantis', _year => 1975 } ];
    $LIBTRACKS{78} = [ [ 'One', 300, 1 ] ];
    $LIBTRACKS{79} = [ [ 'Two', 300, 1 ] ];
    $p = plc();
    @r = $B->can('_manualRows')->(undef, $pass6, $rgMT, $p);
    ok(scalar(@r) == 1 && $r[0]{id} eq 'lm:pick' && $r[0]{name} eq 'PLUGIN_DISCOGRAPHY_MATCH_PICK',
       '6: with albums left over: "Match an album from your library"');
    my $items = $B->can('_matchPicker')->(undef, $pass6, $rgMT, $p);
    ok(join(',', map { $_->{id} } @$items) eq 'lm:set:79,lm:set:78,lm:set:77',
       '6: the picker lists them by year when no tracks point here');

    reset4();
    $LOCAL = [ { %$own }, { %$own, _albumid => 79, _candTitle => 'Atlantis', name => 'Atlantis', _year => 1975 } ];
    $LIBTRACKS{79} = [ [ 'Two', 300, 1 ] ];
    $MANUAL{$ART} = { "mccoy tyner plays john coltrane\x{1f}mccoy tyner" => '-' };
    $p = plc();
    $items = $B->can('_matchPicker')->(undef, $pass6, $rgMT, $p);
    ok(join(',', map { $_->{id} } @$items) eq 'lm:set:77,lm:set:79',
       '6: an album whose tracks point at THIS release comes first, older albums after it');
    ok($items->[0]{line2} eq 'PLUGIN_DISCOGRAPHY_MATCH_TRACKS(7|7)' && $items->[1]{line2} eq "1975 \x{00B7} Local",
       '6: ... saying how many of its tracks are on it; the rest say year and Local');
    ok(($items->[0]{nextWindow} // '') eq 'parent' && ($items->[0]{itemActions}{items}{fixedParams}{item} // '') eq 'lm:set:77',
       '6: a picker row goes back to the release page when tapped, and is addressed by its own params');

    # The action: through _rgView, without building the page.
    reset4();
    @RGS = map { +{ %$_ } } @RG4; @DETAIL = ();
    my $got;
    $B->can('_rgView')->(undef, sub { $got = shift }, { %$pass6 }, $MT, 'lm:set:77');
    ok(scalar(@SET) == 1 && $SET[0][0] eq $ART && $SET[0][1] eq "mccoy tyner plays john coltrane\x{1f}mccoy tyner"
       && $SET[0][2] eq $MT && $SET[0][3] eq 'McCoy Tyner Plays John Coltrane',
       '6: lm:set stores the album (title + album artist) on this release for this artist');
    ok(!@DETAIL, '6: ... without building the release page');
    ok(ref $got eq 'HASH' && scalar(@{ $got->{items} }) == 1 && $got->{items}[0]{type} eq 'text'
       && $got->{items}[0]{name} eq 'PLUGIN_DISCOGRAPHY_MATCH_DONE',
       '6: ... answering one text row (Material shows it as a message)');
    @SET = ();
    $B->can('_rgView')->(undef, sub { $got = shift }, { %$pass6 }, $MT, 'lm:del:77');
    ok(scalar(@SET) == 1 && $SET[0][2] eq '-' && $got->{items}[0]{name} eq 'PLUGIN_DISCOGRAPHY_MATCH_REMOVED',
       "6: lm:del stores '-' (the track match leaves it alone from now on)");
    @SET = ();
    $B->can('_rgView')->(undef, sub { $got = shift }, { %$pass6 }, $MT, 'lm:set:999');
    ok(!@SET && $got->{items}[0]{name} eq 'PLUGIN_DISCOGRAPHY_ERROR', '6: an album the artist does not own: nothing stored');
    @SET = ();
    $B->can('_rgView')->(undef, sub { $got = shift }, { %$pass6, mbid => undef }, $MT, 'lm:set:77');
    ok(!@SET, '6: no artist mbid: nothing stored');
    @DETAIL = ();
    $B->can('_rgView')->(undef, sub { }, { %$pass6 }, $MT, 'lm:pick');
    ok(scalar(@DETAIL) == 1, '6: control: lm:pick (a row on the page) is found on the page as before');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
