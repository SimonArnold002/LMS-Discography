#!/usr/bin/env perl
#
# QOBUZ: AN ARTIST'S RECORDS UNDER ANOTHER CREDIT (0.56.13; Simon, 2026-10-01:
# albums MusicBrainz lists under the artist's own name "should come through",
# and if it lists them under a separate artist "we live with it").
#
# Field, James Yorkston: Qobuz credits "My Yoke Is Heavy" to Adrian Crowley AND
# James Yorkston (both main artists) and the foreign-credit filter, reading only
# the first, dropped it; and Qobuz files "Folk Songs" under a JOINT artist of its
# own, "James Yorkston & The Big Eyes Family Players", which his entry does not
# list. Both are in MusicBrainz's list for him.
#
# Drives the REAL Sources::_searchQobuz against a fake Qobuz API with the shapes
# read in the Qobuz plugin's source (API.pm getArtist: {albums}{items}; an
# album's `artists` entries carry id, name and roles, Plugin.pm _isMainArtist).
#
# Standalone -- no LMS install needed:  perl tools/t_qobuzjoint.pl
#
use strict;
use warnings;
use FindBin;

our (@SEARCHED, @FETCHED, %ARTISTS, %ALBUMS, %HOLD, @HELD, @TIMERS, %SARTISTS, %SALBUMS);

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
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    # Timers are RECORDED; the test fires them.
    *{'Slim::Utils::Timers::setTimer'}     = sub { my $t = [@_]; push @main::TIMERS, $t; $t };
    *{'Slim::Utils::Timers::killSpecific'} = sub { my ($t) = @_; @main::TIMERS = grep { $_ != $t } @main::TIMERS; 1 };
    push @{'Slim::Utils::Log::ISA'},   'Exporter';
    push @{'Slim::Utils::Prefs::ISA'}, 'Exporter';
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Prefs; sub get { 1 } sub set { 1 } sub init { 1 }

# The Qobuz plugin's API handler, as _searchQobuz calls it.
package T::QAPI;
sub search {
    my ($s, $cb, $q, $type) = @_;
    push @main::SEARCHED, $q;
    $cb->({ artists => { items => $main::ARTISTS{$q} || [] } });
}
sub getArtist {
    my ($s, $cb, $id) = @_;
    push @main::FETCHED, $id;
    return push @main::HELD, [ $cb, $id ] if $main::HOLD{$id};
    $cb->({ albums => { items => [ map { +{ %$_ } } @{ $main::ALBUMS{$id} || [] } ] } });
}

# TIDAL, Deezer and Spotty as the adapters call them (shapes from their plugins'
# sources; none of the three is installed on the rig, so none is measured).
package T::Multi;
sub search {
    my ($s, $cb, $a) = @_;
    my $q = lc($a->{search} // $a->{query} // '');
    push @main::SEARCHED, "$s->{svc}:$q";
    $cb->($main::SARTISTS{ $s->{svc} }{$q} || []);
}
sub artistAlbums {
    my ($s, $cb, $id, $f) = @_;
    if (ref $id eq 'HASH') { ($id) = $id->{uri} =~ /:([^:]+)$/ }      # Spotty: {uri=>...}
    push @main::FETCHED, "$s->{svc}:$id" . (defined $f && !ref $f ? ":$f" : '');
    my $l = $main::SALBUMS{ $s->{svc} }{$id};
    $l = $l->{ $f // '' } || [] if ref $l eq 'HASH';                  # TIDAL's filter buckets
    $cb->([ map { +{ %$_ } } @{ $l || [] } ]);
}
package Plugins::TIDAL::Plugin;
sub getAPIHandler { bless { svc => 'Tidal' }, 'T::Multi' }
sub _renderAlbum  { my ($al) = @_; return { name => $al->{title}, type => 'playlist' } }
package Plugins::Deezer::Plugin;
sub getAPIHandler { bless { svc => 'Deezer' }, 'T::Multi' }
sub _renderAlbum  { my ($al) = @_; return { name => $al->{title}, type => 'playlist' } }
package Plugins::Spotty::Plugin;
sub getAPIHandler { bless { svc => 'Spotify' }, 'T::Multi' }
package Plugins::Spotty::OPML;
sub _albumItem { my ($c, $al) = @_; return { name => $al->{name}, type => 'playlist' } }

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

my $JY    = 409047;
my $JOINT = 9001;
sub main_artist { my ($id, $name, @roles) = @_; +{ id => $id, name => $name, roles => [ @roles ? @roles : 'main-artist' ] } }
sub reset_all {
    @SEARCHED = (); @FETCHED = (); %HOLD = (); @HELD = (); @TIMERS = ();
    %ARTISTS = ('james yorkston' => [
        { id => $JY,    name => 'James Yorkston' },
        { id => $JOINT, name => 'James Yorkston & The Big Eyes Family Players' },
        { id => 4242,   name => 'Yorkston/Thorne/Khan' },
    ]);
    %ALBUMS = (
        $JY => [
            { id => 'a1', title => 'The Year of the Leopard',
              artist => { id => $JY, name => 'James Yorkston' },
              artists => [ main_artist($JY, 'James Yorkston') ] },
            # Two main artists, Adrian Crowley first (the field case).
            { id => 'a2', title => 'My Yoke Is Heavy',
              artist => { id => 555900, name => 'Adrian Crowley' },
              artists => [ main_artist(555900, 'Adrian Crowley'), main_artist($JY, 'James Yorkston') ] },
            # Filed under his id with another spelling of his name: the id says
            # it is him, so he is credited under the spelling Qobuz gives.
            { id => 'a5', title => 'Hoopoe',
              artist => { id => 777, name => 'Someone Else' },
              artists => [ main_artist(777, 'Someone Else'), main_artist($JY, 'Yorkston') ] },
            # He only FEATURES: another act's record.
            { id => 'a3', title => 'Aval Allah',
              artist => { id => 2132778, name => 'Manika Kaur' },
              artists => [ main_artist(2132778, 'Manika Kaur'), main_artist($JY, 'James Yorkston', 'featured-artist') ] },
            # His other band, no artists list.
            { id => 'a4', title => 'Bales', artist => { id => 4242, name => 'Yorkston/Thorne/Khan' } },
        ],
        $JOINT => [
            { id => 'j1', title => 'Folk Songs',
              artist => { id => $JOINT, name => 'James Yorkston & The Big Eyes Family Players' } },
            # Also on his own entry: one copy only.
            { id => 'a1', title => 'The Year of the Leopard',
              artist => { id => $JOINT, name => 'James Yorkston & The Big Eyes Family Players' } },
        ],
    );
}
my ($got, $calls);
sub run {
    my (%o) = @_;
    ($got, $calls) = (undef, 0);
    $S->can('_searchQobuz')->('client', $o{query} // 'James Yorkston', 'Qobuz',
        sub { $calls++; $got = $_[0] }, $o{spine} || {}, undef, 0);
}
sub byTitle { my %h = map { ($_->{_candTitle} => $_) } @{ $got || [] }; \%h }
sub fire {
    for my $t (splice @TIMERS) { $t->[2]->() if ref $t->[2] eq 'CODE' }
}

# ---------------------------------------------------------------------------
# 1. A MAIN ARTIST NAMED SECOND IS HIS; A FEATURED ONE IS NOT.
# ---------------------------------------------------------------------------
reset_all(); run();
my $b = byTitle();
ok(scalar($b->{'My Yoke Is Heavy'}), "1: an album naming him as a second main artist is kept");
ok(scalar(($b->{'My Yoke Is Heavy'}{_candArtist} // '') eq 'James Yorkston'),
   "1: ... credited to him, so the matcher's artist gate sees his name");
ok(scalar(!$b->{'Aval Allah'}), '1: an album on which he only features is still dropped');
ok(scalar(($b->{'Hoopoe'}{_candArtist} // '') eq 'Yorkston'),
   '1: his id under another spelling of his name -> credited as Qobuz spells it, not to the first artist');
ok(scalar(!$b->{'Bales'}), "1: his other band's album (another act's credit) is still dropped");
ok(scalar(($b->{'The Year of the Leopard'}{_candArtist} // '') eq 'James Yorkston'),
   '1: control: his own album is credited as before');

# ---------------------------------------------------------------------------
# 2. A JOINT ARTIST'S ALBUMS ARE FETCHED BESIDE HIS, MARKED, ONCE.
# ---------------------------------------------------------------------------
ok(scalar($b->{'Folk Songs'}), "2: the joint artist's album is in his pool");
ok(scalar($b->{'Folk Songs'} && $b->{'Folk Songs'}{_joint}), '2: ... marked as a joint artist\'s');
ok(scalar(!grep { $_->{_joint} } grep { $_->{_candTitle} ne 'Folk Songs' } @{ $got || [] }),
   '2: ... and nothing of his own is');
ok(scalar((grep { ($_->{_albumid} // '') eq 'a1' } @{ $got || [] }) == 1),
   '2: an album on both entries is in the pool once');
ok(scalar((grep { $_ eq $JOINT } @FETCHED) == 1 && !grep { $_ eq 4242 } @FETCHED),
   "2: the joint artist is asked once; 'Yorkston/Thorne/Khan' (no spaced separator) is not a joint credit");
ok(scalar($calls == 1 && !@TIMERS), '2: answered once, and nothing left waiting');

# ---------------------------------------------------------------------------
# 3. WHICH NAMES ARE JOINT ARTISTS.
# ---------------------------------------------------------------------------
my $ja = sub { [ map { $_->{name} } $S->can('_jointArtists')->([ map { +{ id => $_, name => $_ } } @{ $_[1] } ], $_[0]) ] };
ok(scalar("@{ $ja->('Sonic Boom', ['Panda Bear & Sonic Boom', 'Sonic Boom']) }" eq 'Panda Bear & Sonic Boom'),
   '3: the second-named act of a joint credit counts (Panda Bear & Sonic Boom on Sonic Boom)');
ok(scalar(!@{ $ja->('Madness', ['Mixtape Madness', 'Madness', 'Madness Tribute']) }),
   '3: a name merely containing the artist is not a joint credit');
ok(scalar(!@{ $ja->('Madness', ['Simon & Garfunkel', 'Hall & Oates']) }),
   '3: a joint credit that does not name the artist is not his');
ok(scalar(@{ $ja->('Air', ['Air & A', 'Air & B', 'Air & C', 'Air & D']) } == 3),
   '3: at most JOINT_MAX joint artists');
ok(scalar(!@{ $ja->('James Yorkston', ['James Yorkston', 'Yorkston/Thorne/Khan']) }),
   '3: control: no joint credit, nothing fetched beside him');

# ---------------------------------------------------------------------------
# 4. NOTHING JOINT WITHOUT THE ARTIST HIMSELF.
# ---------------------------------------------------------------------------
{
    no warnings 'redefine'; no strict 'refs';
    local *{"${S}::_resolveArtist"} = sub { $_[5]->(undef, undef) };
    reset_all(); run(spine => { 'folk songs' => 1 });
    ok(scalar($calls == 1 && !defined $got),
       '4: his own entry unidentified (with a spine): unresolved, no joint albums adopted');
}

# ---------------------------------------------------------------------------
# 5. A JOINT LOOKUP NEVER HOLDS HIS POOL FOR LONG.
# ---------------------------------------------------------------------------
reset_all(); $HOLD{$JOINT} = 1; run();
ok(scalar($calls == 0 && @TIMERS == 1), '5: his answer waits a moment for a joint lookup still out');
my $wait = $Plugins::Discography::Sources::{JOINT_WAIT} ? $S->can('JOINT_WAIT')->() : -1;
ok(scalar($wait > 0 && $wait <= 3), "5: ... bounded ($wait s)");
fire();
$b = byTitle();
ok(scalar($calls == 1 && $b->{'My Yoke Is Heavy'} && !$b->{'Folk Songs'}),
   '5: ... then goes without it');
$_->[0]->({ albums => { items => $ALBUMS{$JOINT} } }) for splice @HELD;
ok(scalar($calls == 1), '5: a joint answer arriving after that changes nothing');

reset_all(); $HOLD{$JOINT} = 1; run();
$_->[0]->({ albums => { items => $ALBUMS{$JOINT} } }) for splice @HELD;
ok(scalar($calls == 1 && byTitle()->{'Folk Songs'} && !@TIMERS),
   '5: a joint answer inside the wait is used, and the wait is cancelled');

reset_all(); delete $ARTISTS{'james yorkston'}[1]; @{ $ARTISTS{'james yorkston'} } = grep { defined } @{ $ARTISTS{'james yorkston'} };
run();
ok(scalar($calls == 1 && !@TIMERS && !grep { $_ eq $JOINT } @FETCHED),
   '5: control: no joint artist, answered at once with no wait');

# ---------------------------------------------------------------------------
# 6. THE POOL IS SEARCHED UNDER THE NAME IT IS GIVEN (getCandidates `query`),
#    the page's own name kept for its key and its log. The field case: a page
#    opened as "James Yorkston & The Big Eyes Family Players" is James
#    Yorkston's (MusicBrainz), so his name is what the services are asked.
# ---------------------------------------------------------------------------
{
    reset_all();
    my $pool;
    $S->getCandidates('client', 'James Yorkston & The Big Eyes Family Players', 1,
        sub { $pool = shift }, { mbid => 'mb-jy', query => 'James Yorkston' });
    ok(scalar(@SEARCHED && $SEARCHED[0] eq 'james yorkston'),
       '6: the services are searched under the name given, not the page\'s');
    ok(scalar(ref $pool eq 'HASH' && grep { ($_->{_candTitle} // '') eq 'The Year of the Leopard' } @{ $pool->{Qobuz} || [] }),
       "6: ... and the pool is the artist's own catalogue");
    reset_all(); $pool = undef;
    $ARTISTS{'james yorkston & the big eyes family players'} = [ { id => $JOINT, name => 'James Yorkston & The Big Eyes Family Players' } ];
    $S->getCandidates('client', 'James Yorkston & The Big Eyes Family Players', 1,
        sub { $pool = shift }, { mbid => 'mb-jy' });
    ok(scalar(@SEARCHED && $SEARCHED[0] eq 'james yorkston & the big eyes family players'),
       "6: control: with no name given, the page's name is searched, as before");
}

# ---------------------------------------------------------------------------
# 7. THE SAME ON TIDAL, DEEZER AND SPOTIFY (Simon: "should be across all the
#    platforms we support"). One shared helper does the joint lookup; each
#    service's own credit shape decides the second-main-artist case.
# ---------------------------------------------------------------------------
{
    my $JN = 'James Yorkston & The Big Eyes Family Players';
    my $run = sub {
        my ($svc) = @_;
        ($got, $calls) = (undef, 0); @SEARCHED = (); @FETCHED = (); @TIMERS = ();
        $S->can("_search$svc")->('client', 'James Yorkston', $svc,
            sub { $calls++; $got = $_[0] }, {}, undef, 0);
    };
    my $art = sub { +{ id => $_[0], name => $_[1], (defined $_[2] ? (type => $_[2]) : ()) } };

    # TIDAL, album artist ids lining up with the artist's (the id filter engages).
    %SARTISTS = (Tidal => { 'james yorkston' => [ $art->('tjy', 'James Yorkston'), $art->('tj', $JN) ] });
    %SALBUMS = (Tidal => {
        tjy => { ALBUMS => [
            { id => 't1', title => 'The Year of the Leopard', artist => $art->('tjy', 'James Yorkston'),
              artists => [ $art->('tjy', 'James Yorkston', 'MAIN') ] },
            { id => 't2', title => 'My Yoke Is Heavy', artist => $art->('tac', 'Adrian Crowley'),
              artists => [ $art->('tac', 'Adrian Crowley', 'MAIN'), $art->('tjy', 'James Yorkston', 'MAIN') ] },
            { id => 't3', title => 'Aval Allah', artist => $art->('tmk', 'Manika Kaur'),
              artists => [ $art->('tmk', 'Manika Kaur', 'MAIN'), $art->('tjy', 'James Yorkston', 'FEATURED') ] } ] },
        tj  => { ALBUMS => [ { id => 't9', title => 'Folk Songs', artist => $art->('tj', $JN),
                               artists => [ $art->('tj', $JN, 'MAIN') ] } ] },
    });
    $run->('Tidal');
    my $b = byTitle();
    ok(scalar($calls == 1 && $b->{'Folk Songs'} && $b->{'Folk Songs'}{_joint}),
       "7: TIDAL - the joint artist's album is fetched beside his, marked");
    ok(scalar(($b->{'Folk Songs'}{_candArtist} // '') eq 'James Yorkston'),
       '7: TIDAL - ... credited to him for the matcher');
    ok(scalar(($b->{'My Yoke Is Heavy'}{_candArtist} // '') eq 'James Yorkston'),
       '7: TIDAL - an album naming him a MAIN artist second is credited to him');
    ok(scalar(!$b->{'Aval Allah'}), '7: TIDAL - one he only FEATURES on is still dropped');

    # TIDAL, album artist ids NOT lining up (the filter stands aside): the name
    # check alone credits the co-credit, and still not the feature.
    for my $al (@{ $SALBUMS{Tidal}{tjy}{ALBUMS} }) {
        $al->{artist}{id} = "x$al->{artist}{id}";
        $_->{id} = "x$_->{id}" for @{ $al->{artists} };
    }
    $run->('Tidal');
    $b = byTitle();
    ok(scalar(($b->{'My Yoke Is Heavy'}{_candArtist} // '') eq 'James Yorkston'),
       "7: TIDAL - with album ids that do not line up, the main-artist NAME credits it");
    ok(scalar(($b->{'Aval Allah'}{_candArtist} // '') eq 'Manika Kaur'),
       '7: TIDAL - ... and a featured credit is not taken for his (the gate will reject it)');

    # Deezer: artist-albums items carry no artist at all.
    %SARTISTS = (Deezer => { 'james yorkston' => [ $art->('djy', 'James Yorkston'), $art->('dj', $JN) ] });
    %SALBUMS = (Deezer => { djy => [ { id => 'd1', title => 'The Year of the Leopard' } ],
                            dj  => [ { id => 'd9', title => 'Folk Songs' } ] });
    $run->('Deezer');
    $b = byTitle();
    ok(scalar($b->{'Folk Songs'} && $b->{'Folk Songs'}{_joint}
              && ($b->{'Folk Songs'}{_candArtist} // '') eq 'James Yorkston'),
       "7: Deezer - the joint artist's album is in his pool, marked and credited to him");
    ok(scalar(($b->{'The Year of the Leopard'}{_candArtist} // '') eq 'James Yorkston' && !$b->{'The Year of the Leopard'}{_joint}),
       '7: Deezer - his own album as before');

    # Spotify: every album artist is a main one; artists[0] is the album artist.
    %SARTISTS = (Spotify => { 'james yorkston' => [ $art->('sjy', 'James Yorkston'), $art->('sj', $JN) ] });
    %SALBUMS = (Spotify => {
        sjy => [ { id => 's1', name => 'The Year of the Leopard', album_type => 'album',
                   artists => [ $art->('sjy', 'James Yorkston') ] },
                 { id => 's2', name => 'My Yoke Is Heavy', album_type => 'album',
                   artists => [ $art->('sac', 'Adrian Crowley'), $art->('sjy', 'James Yorkston') ] },
                 { id => 's3', name => 'Bales', album_type => 'album',
                   artists => [ $art->('syt', 'Yorkston/Thorne/Khan') ] } ],
        sj  => [ { id => 's9', name => 'Folk Songs', album_type => 'album', artists => [ $art->('sj', $JN) ] } ],
    });
    $run->('Spotify');
    $b = byTitle();
    ok(scalar($b->{'Folk Songs'} && $b->{'Folk Songs'}{_joint}),
       "7: Spotify - the joint artist's album is fetched beside his, marked");
    ok(scalar(($b->{'My Yoke Is Heavy'}{_candArtist} // '') eq 'James Yorkston'),
       '7: Spotify - an album listing him second is kept and credited to him');
    ok(scalar(!$b->{'Bales'}), "7: Spotify - another act's album is still dropped");

    # CONTROL: no joint artist in the search -> nothing extra fetched, no wait.
    %SARTISTS = (Deezer => { 'james yorkston' => [ $art->('djy', 'James Yorkston') ] });
    $run->('Deezer');
    ok(scalar($calls == 1 && !@TIMERS && !grep { /:dj$/ } @FETCHED),
       '7: control: no joint artist -> nothing extra asked, answered at once');
}

# ---------------------------------------------------------------------------
# 8. THE DUO'S OWN ENTRY, PASSED OVER FOR ONE OF ITS MEMBERS (0.56.14; Simon,
#    2026-10-01: Qobuz files "Raising Sand" under "Robert Plant & Alison
#    Krauss", "the other one is listed as separate artists"). Measured live:
#    the duo entry backs up 1 spine title and is held; the retry under "Robert
#    Plant" backs up 7 and wins; the duo's list - the only one holding "Raising
#    Sand" - was dropped, so the page showed it Local only.
# ---------------------------------------------------------------------------
{
    my $DUO = 'Robert Plant & Alison Krauss';
    my $n = $S->can('_norm');
    my $spine = { map { ($n->($_) => 1) } 'Raising Sand', 'Raise the Roof', "Can't Let Go", 'High and Lonesome' };
    my $duo = sub {
        @SEARCHED = (); @FETCHED = (); %HOLD = (); @HELD = (); @TIMERS = ();
        %ARTISTS = (lc($DUO)       => [ { id => 'qd',  name => $DUO }, { id => 'qrp', name => 'Robert Plant' } ],
                    'robert plant' => [ { id => 'qrp', name => 'Robert Plant' } ]);
        %ALBUMS = (
            qd  => [ { id => 'r1', title => 'Raising Sand', artist => { id => 'qd', name => $DUO },
                       artists => [ main_artist('qd', $DUO) ] } ],
            qrp => [ { id => 'r2', title => 'Raise the Roof', artist => { id => 'qrp', name => 'Robert Plant' },
                       artists => [ main_artist('qrp', 'Robert Plant'), main_artist('qak', 'Alison Krauss') ] },
                     { id => 'r3', title => "Can't Let Go", artist => { id => 'qrp', name => 'Robert Plant' } },
                     { id => 'r4', title => 'High and Lonesome', artist => { id => 'qrp', name => 'Robert Plant' } },
                     { id => 'r5', title => 'Saving Grace', artist => { id => 'qrp', name => 'Robert Plant' } } ],
        );
    };
    my $go = sub {
        my (%o) = @_;
        ($got, $calls) = (undef, 0);
        $S->can('_searchQobuz')->('client', $o{query} // $DUO, 'Qobuz', sub { $calls++; $got = $_[0] },
            $o{spine} // $spine, $o{aliases} // ['Robert Plant'], $o{strict} // 0);
    };

    $duo->(); $go->();
    my $b = byTitle();
    ok(scalar($calls == 1 && $b->{'Raise the Roof'} && !$b->{'Raise the Roof'}{_joint}),
       '8: the member who backs up more titles is still the answer');
    ok(scalar($b->{'Raising Sand'}), "8: the passed-over duo's own album is in the pool");
    ok(scalar($b->{'Raising Sand'} && $b->{'Raising Sand'}{_joint}),
       '8: ... marked as a joint artist\'s, so it only ever matches a release MB lists');
    ok(scalar(($b->{'Raising Sand'}{_candArtist} // '') eq 'Robert Plant'),
       "8: ... credited to the artist settled on, for the matcher's gate");
    ok(scalar((grep { $_ eq 'qd' } @FETCHED) == 1),
       "8: ... with no request of its own (the duo's list was fetched once, to score it)");

    $duo->(); $go->(strict => 1);
    $b = byTitle();
    ok(scalar($b->{'Raise the Roof'} && !$b->{'Raising Sand'}),
       '8: control: a SHARED name (Madness, The Bees) never keeps a passed-over entry');

    $duo->();
    %ARTISTS = (rossini => [ { id => 'qx', name => 'Rossini' } ],
                'gioachino rossini' => [ { id => 'qg', name => 'Gioachino Rossini' } ]);
    %ALBUMS = (qx => [ { id => 'x1', title => 'Il barbiere di Siviglia', artist => { id => 'qx', name => 'Rossini' } },
                       { id => 'x2', title => 'Trap Rossini', artist => { id => 'qx', name => 'Rossini' } } ],
               qg => [ { id => 'g1', title => 'Guillaume Tell', artist => { id => 'qg', name => 'Gioachino Rossini' } },
                       { id => 'g2', title => 'La Cenerentola', artist => { id => 'qg', name => 'Gioachino Rossini' } } ]);
    $go->(query => 'Rossini', aliases => ['Gioachino Rossini'],
          spine => { map { ($n->($_) => 1) } 'Il barbiere di Siviglia', 'Guillaume Tell', 'La Cenerentola' });
    $b = byTitle();
    ok(scalar($b->{'Guillaume Tell'} && !$b->{'Trap Rossini'} && !$b->{'Il barbiere di Siviglia'}),
       "8: control: a passed-over entry that is NOT a joint name stays dropped (0.47.0's Rossini rapper)");

    $duo->();
    $ARTISTS{'the honeydrippers'} = [ { id => 'qh', name => 'The Honeydrippers' } ];
    $ALBUMS{qh} = [ map { +{ id => "h$_", title => $_, artist => { id => 'qh', name => 'The Honeydrippers' } } }
                    'Raise the Roof', "Can't Let Go" ];
    $go->(aliases => ['The Honeydrippers']);
    $b = byTitle();
    ok(scalar($b->{'Raise the Roof'} && !$b->{'Raising Sand'}),
       "8: control: settled on an artist who is not one of the duo's parts -> the duo's list stays dropped");

    $duo->();
    # Picked (its name contains every word of the duo's), held on 1 title,
    # and "Robert Plant" is one of its parts - but it is not the duo's name.
    my $TRIB = 'Robert Plant & Alison Krauss Tribute';
    $ARTISTS{lc $DUO} = [ { id => 'qt', name => $TRIB } ];
    $ALBUMS{qt} = [ { id => 's1', title => 'Raising Sand', artist => { id => 'qt', name => $TRIB } },
                    { id => 's2', title => 'A Tribute Night', artist => { id => 'qt', name => $TRIB } } ];
    $go->();
    $b = byTitle();
    ok(scalar((grep { $_ eq 'qt' } @FETCHED) && $b->{'High and Lonesome'} && !$b->{'A Tribute Night'} && !$b->{'Raising Sand'}),
       "8: control: a passed-over joint entry under ANOTHER name (a tribute act) stays dropped");

    # Nothing reaches 2 titles, but a member backs up more than the duo entry:
    # the answer comes from the settle, and the duo's list still comes with it.
    $duo->(); $ALBUMS{qd} = [ { id => 'r1', title => 'Live in Nashville', artist => { id => 'qd', name => $DUO } } ];
    $ALBUMS{qrp} = [ $ALBUMS{qrp}[0] ];
    $go->();
    $b = byTitle();
    ok(scalar($b->{'Raise the Roof'} && $b->{'Live in Nashville'} && $b->{'Live in Nashville'}{_joint}),
       '8: settled on the member with 1 title over the duo with 0 -> the duo\'s list still comes with it');

    $duo->(); push @{ $ALBUMS{qd} }, { id => 'r6', title => 'High and Lonesome', artist => { id => 'qd', name => $DUO } };
    $go->();
    $b = byTitle();
    ok(scalar($b->{'Raising Sand'} && !$b->{'Raising Sand'}{_joint} && !grep { $_ eq 'robert plant' } @SEARCHED),
       '8: control: a duo entry that backs up 2+ titles is the answer itself, no retry, nothing joint');

    $duo->(); %ALBUMS = (qd => $ALBUMS{qd}, qrp => [ $ALBUMS{qrp}[3] ]);
    $go->();
    $b = byTitle();
    ok(scalar($b->{'Raising Sand'} && !$b->{'Raising Sand'}{_joint}
              && (grep { ($_->{_albumid} // '') eq 'r1' } @{ $got || [] }) == 1),
       '8: control: nothing corroborates better -> the duo entry itself, its album once, not joint');
}

# ---------------------------------------------------------------------------
# 9. A FIRST-NAMED ARTIST WHO IS ALREADY THE ONE SEARCHED KEEPS THE CREDIT
#    (0.56.14). Measured live on TIDAL, 2026-10-01: no duo artist there, so the
#    duo's page settled on Alison Krauss; TIDAL credits the duo's records Robert
#    Plant FIRST (its own search: "Raise The Roof (Deluxe Edition) / Robert
#    Plant") and lists them under both; the 0.56.13 render re-credited them to
#    her, and the page ("Robert Plant") matched nothing on TIDAL.
# ---------------------------------------------------------------------------
{
    my $DUO = 'Robert Plant & Alison Krauss';
    my $art = sub { +{ id => $_[0], name => $_[1], (defined $_[2] ? (type => $_[2]) : ()) } };
    my $tidal = sub {
        ($got, $calls) = (undef, 0); @SEARCHED = (); @FETCHED = (); @TIMERS = ();
        $S->can('_searchTidal')->('client', $_[0] // $DUO, 'Tidal', sub { $calls++; $got = $_[0] }, {}, undef, 0);
    };
    %SARTISTS = (Tidal => { lc($DUO) => [ $art->('tak', 'Alison Krauss'), $art->('tpl', 'Robert Plant') ] });
    %SALBUMS = (Tidal => { tak => { ALBUMS => [
        { id => 'k1', title => 'Raise the Roof', artist => $art->('tpl', 'Robert Plant'),
          artists => [ $art->('tpl', 'Robert Plant', 'MAIN'), $art->('tak', 'Alison Krauss', 'MAIN') ] },
        { id => 'k2', title => 'Forget About It', artist => $art->('tak', 'Alison Krauss'),
          artists => [ $art->('tak', 'Alison Krauss', 'MAIN') ] } ] } });
    $tidal->();
    my $b = byTitle();
    ok(scalar($calls == 1 && ($b->{'Raise the Roof'}{_candArtist} // '') eq 'Robert Plant'),
       "9: TIDAL - the duo's record keeps its first-named Robert Plant, not the artist settled on");
    ok(scalar(($b->{'Forget About It'}{_candArtist} // '') eq 'Alison Krauss'),
       "9: TIDAL - control: the settled artist's own album is credited to her as before");

    # Album ids that do not line up (the id filter stands aside): same answer.
    for my $al (@{ $SALBUMS{Tidal}{tak}{ALBUMS} }) {
        $al->{artist}{id} = "x$al->{artist}{id}"; $_->{id} = "x$_->{id}" for @{ $al->{artists} };
    }
    $tidal->();
    ok(scalar((byTitle()->{'Raise the Roof'}{_candArtist} // '') eq 'Robert Plant'),
       '9: TIDAL - ... and the same with album ids that do not line up');

    # The second-main-artist case is unchanged: first-named is NOT the one searched.
    %SARTISTS = (Tidal => { 'james yorkston' => [ $art->('tjy', 'James Yorkston') ] });
    %SALBUMS = (Tidal => { tjy => { ALBUMS => [
        # album ids in another space (the id filter stands aside), so the
        # RENDER is what credits the second main artist
        { id => 't1', title => 'The Year of the Leopard', artist => $art->('xjy', 'James Yorkston'),
          artists => [ $art->('xjy', 'James Yorkston', 'MAIN') ] },
        { id => 't2', title => 'My Yoke Is Heavy', artist => $art->('xac', 'Adrian Crowley'),
          artists => [ $art->('xac', 'Adrian Crowley', 'MAIN'), $art->('xjy', 'James Yorkston', 'MAIN') ] } ] } });
    $tidal->('James Yorkston');
    ok(scalar((byTitle()->{'My Yoke Is Heavy'}{_candArtist} // '') eq 'James Yorkston'),
       '9: TIDAL - control: an album naming the searched artist a MAIN artist second is still credited to him');
}

# ---------------------------------------------------------------------------
# 10. ONE FETCH PER POOL AT A TIME (0.56.15). Field, 2026-10-01: two opens of a
#     page 0.7 s apart each found no pool and each fetched TIDAL. Through the
#     REAL getCandidates and the fleet's SingleFlight.pm.
# ---------------------------------------------------------------------------
{
    my $flight = $S->can('_candFlight')->();
    ok(scalar(ref $flight), '10: the shared registry loads (SingleFlight.pm)');
    %SARTISTS = (); %SALBUMS = ();          # the other services answer at once, empty
    my (@p, @n);
    my $ask = sub {
        my ($i, %o) = @_;
        $S->getCandidates('client', $o{artist} // 'James Yorkston', $o{force} // 0,
            sub { $n[$i]++; $p[$i] = shift },
            { mbid => 'mb-jy', query => $o{query} // 'James Yorkston' });
    };
    my $qobuzAsks = sub { scalar grep { $_ eq 'james yorkston' } @SEARCHED };

    reset_all(); $flight->_reset; $HOLD{$JY} = 1; (@p, @n) = ();
    $ask->(0); $ask->(1);
    ok(scalar($qobuzAsks->() == 1 && (grep { $_ eq $JY } @FETCHED) == 1),
       '10: a second page asking for a pool already being fetched does not fetch it again');
    ok(scalar(!$n[0] && !$n[1]), '10: ... both wait for it');
    $_->[0]->({ albums => { items => [ map { +{ %$_ } } @{ $ALBUMS{$JY} } ] } }) for splice @HELD;
    fire();
    my $t = sub { [ sort map { $_->{_candTitle} } @{ $_[0]{Qobuz} || [] } ] };
    ok(scalar(($n[0] // 0) == 1 && ($n[1] // 0) == 1), '10: ... and each is answered exactly once');
    ok(scalar(@{ $t->($p[0]) } && "@{ $t->($p[0]) }" eq "@{ $t->($p[1]) }"),
       '10: ... with the same Qobuz pool');
    ok(scalar($p[0]{Qobuz}[0] && $p[1]{Qobuz}[0] && $p[0]{Qobuz}[0] != $p[1]{Qobuz}[0]),
       '10: ... each holding its own copy of every item');
    ok(scalar(!$flight->_count), '10: ... and nothing is left in flight');

    reset_all(); (@p, @n) = ();
    $ask->(0);
    ok(scalar($qobuzAsks->() == 1 && $n[0]), '10: once landed, the next caller fetches afresh (the claim is released)');

    reset_all(); $flight->_reset; $HOLD{$JY} = 1; (@p, @n) = ();
    $ask->(0); $ask->(1, force => 1);
    ok(scalar($qobuzAsks->() == 2), '10: a Refresh (forced) fetches for itself, never waiting on an older fetch');
    $_->[0]->({ albums => { items => $ALBUMS{$JY} } }) for splice @HELD;
    fire();

    reset_all(); $flight->_reset; $HOLD{$JY} = 1; (@p, @n) = ();
    $ask->(0); $ask->(1, query => 'Jim Yorkston');
    ok(scalar((grep { $_ eq $JY } @FETCHED) == 1 && grep { $_ eq 'jim yorkston' } @SEARCHED),
       '10: control: a caller searching under another name is not folded into this fetch');
    $_->[0]->({ albums => { items => $ALBUMS{$JY} } }) for splice @HELD;
    fire();

    # A fetch that never answers: the service watchdog answers EVERY waiter.
    reset_all(); $flight->_reset; $HOLD{$JY} = 1; (@p, @n) = ();
    $ask->(0); $ask->(1);
    fire();
    ok(scalar(($n[0] // 0) == 1 && ($n[1] // 0) == 1 && !@{ $p[0]{Qobuz} || [1] } && !@{ $p[1]{Qobuz} || [1] }),
       '10: a fetch that never answers -> both callers answered once, with an empty Qobuz pool');
    ok(scalar(!$flight->_count), '10: ... and the claim is released');
    @HELD = ();

    # A service whose adapter dies: both answered.
    reset_all(); $flight->_reset; (@p, @n) = ();
    {
        no warnings 'redefine'; no strict 'refs';
        local *{'T::QAPI::search'} = sub { die "boom\n" };
        $ask->(0);
    }
    ok(scalar(($n[0] // 0) == 1 && !$flight->_count), '10: an adapter that dies -> answered, claim released');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
