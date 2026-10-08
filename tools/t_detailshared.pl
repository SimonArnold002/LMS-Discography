#!/usr/bin/env perl
#
# REGRESSION TEST — the release DETAIL page must apply the list view's
# same-name guard (review 2026-09-19, finding 1).
#
# A secondary act that shares its exact name with a more prominent one
# ("Other artists with this name" -> Sonic Boom, Andrew Huang's group) gets
# NO name-keyed library lookup on its list view: `_discographyView` sets
# $opts->{shared_name} and gates `$local` on `shared_name && !artist_id`.
# The detail page is reached three ways — the tile's url coderef (passthrough
# = the list's $opts, flag present), Material's `_rgView` and `playCommand`
# (both rebuild $pass from action params, flag ABSENT). The last two used to
# look the name up anyway, so a detail page (and tile play) could claim the
# prominent act's owned album as Local where the tile did not.
#
# Drives the REAL `_releaseDetail` with API/Sources stubbed and asserts which
# library lookups it makes.
#
# Standalone — no LMS install needed:  perl tools/t_detailshared.pl
#
use strict;
use warnings;
use FindBin;

our (%SHARED, @SHARECALLS, @LA, @LT, $URLS);
our (%CANON, @CANDOPTS);   # section 6: MusicBrainz's names, what the pool is asked for
our (%ACTS, %ALIASES, @MFOPT, @AREADS);   # section 7: same-name acts, aliases, matchesFor's options, alias reads
our (%ENNAME);   # section 8: MusicBrainz's primary English alias
our (%EPON);     # section 9: the member a band is named after (API::peekEponymous)

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
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Null' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Slim::Utils::Strings::cstring'}   = sub { $_[1] };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    # Letters of ANY script survive, as in the real _norm (an ASCII-only stand-in
    # erased "米津玄師" to '' and made section 8 test nothing).
    *{'Plugins::Discography::Sources::_norm'} = sub {
        my $s = lc($_[-1] // ''); $s =~ s/[^\p{Alnum}]+/ /g; $s =~ s/^ +| +$//g; $s };
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');

    my $A = 'Plugins::Discography::API';
    my $S = 'Plugins::Discography::Sources';
    *{"${A}::sharesNameWithProminentAsync"} = sub {
        my ($c, $name, $mbid, $cb) = @_;
        push @main::SHARECALLS, [$name, $mbid];
        return $cb->(0) unless $mbid;   # as the real sub
        $cb->($main::SHARED{$mbid} ? 1 : 0);
    };
    *{"${A}::getReleaseGroupUrls"}  = sub { $main::URLS++ };   # compose never runs
    *{"${A}::peekReleaseGroups"}    = sub { [] };
    *{"${A}::peekArtistName"}       = sub { $main::CANON{ $_[1] // '' } };   # the pool's search name (0.56.13)
    *{"${A}::peekArtistAliases"}    = sub { $main::ALIASES{ $_[1] // '' } };
    *{"${A}::peekArtistEnglishName"} = sub { $main::ENNAME{ $_[1] // '' } };   # section 8 (0.56.18)
    *{"${A}::peekEponymous"}        = sub { $main::EPON{ $_[1] // '' } };     # section 9 (2026-10-08)
    # Same-name acts by name (one = not shared), and the alias read.
    *{"${A}::getArtistCandidates"}  = sub { $_[2]->([ map { +{ mbid => $_ } } @{ $main::ACTS{ $_[1] // '' } || ['x'] } ]) };
    *{"${A}::warmArtistAliases"}    = sub { push @main::AREADS, $_[1]; $_[2]->($main::ALIASES{ $_[1] // '' } || []) };
    *{"${A}::peekReleaseMap"}       = sub { {} };
    *{"${A}::peekLocalReleaseMap"}  = sub { {} };
    *{"${A}::peekOfficial"}         = sub { {} };
    *{"${A}::getReleaseGroups"}     = sub { my ($c, %a) = @_; $a{onError}->() };
    *{"${S}::getCandidates"}        = sub { push @main::CANDOPTS, [ $_[2], $_[-1] ]; $_[-2]->({}) };
    *{"${S}::localAlbums"}          = sub { shift; push @main::LA, [@_]; [] };
    *{"${S}::localTracks"}          = sub { shift; push @main::LT, [@_]; [] };
    # matchesFor pulls the lazy track pool, as the real one does for a miss.
    *{"${S}::matchesFor"}           = sub { my $o = $_[-1]; push @main::MFOPT, $o;
                                            $o->{localTracks}->() if $o->{localTracks}; {} };
}

package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;
my $B = 'Plugins::Discography::Browse';
{ no warnings 'redefine'; no strict 'refs';
  *{"${B}::_fetchAlbumReview"} = sub { }; }

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

my $SECOND = '13a1f939-9e60-495f-b5f5-71c4bb3438a7';   # Sonic Boom (Huang group)
my $PROM   = '00000000-0000-0000-0000-00000000prom';   # the prominent act
$SHARED{$SECOND} = 1;
my $rg = { mbid => '11111111-1111-1111-1111-111111111111', title => 'Spectrum', type => 'Album', secondary => [] };

sub detail {
    my (%p) = @_;
    @SHARECALLS = (); @LA = (); @LT = (); $URLS = 0;
    $B->can('_releaseDetail')->(undef, sub { }, { artist => 'Sonic Boom', rg => $rg, %p });
}

# 1. Material/_rgView or playCommand: secondary act, no id, flag ABSENT.
detail(mbid => $SECOND);
ok(scalar(@SHARECALLS == 1), '1: flag absent -> detail resolves shared_name itself');
ok(scalar(@LA == 0), '1: shared name, no id -> NO localAlbums lookup (list view makes none)');
ok(scalar(@LT == 0), '1: shared name, no id -> NO localTracks lookup');
ok(scalar($URLS == 1), "1: the re-entry fetches the release links ONCE, not twice");

# 2. Same route, prominent act: nothing changes — name lookup as before.
detail(mbid => $PROM);
ok(scalar(@LA == 1 && ($LA[0][3]{fallback} // '') eq 'name'),
   '2: not shared -> localAlbums runs with the name fallback (unchanged)');
ok(scalar(@LT == 1), '2: not shared -> localTracks runs (unchanged)');

# 3. Secondary act entered WITH an own library id: lookup kept, mbid-only fallback
#    (same as the list's _idFallback).
detail(mbid => $SECOND, artist_id => 777);
ok(scalar(@LA == 1 && ($LA[0][3]{fallback} // '') eq 'mbid'),
   '3: shared name + own id -> localAlbums with fallback=mbid, as the list');
ok(scalar(@LT == 1 && ($LT[0][2]{fallback} // '') eq 'mbid'),
   '3: shared name + own id -> localTracks with fallback=mbid, as the list');

# 4. Tile coderef: passthrough already carries the flag — no second check.
detail(mbid => $SECOND, shared_name => 1);
ok(scalar(@SHARECALLS == 0), '4: flag present (tile passthrough) -> no extra check');
ok(scalar(@LA == 0 && @LT == 0), '4: flag present, no id -> no library lookups');
detail(mbid => $PROM, shared_name => 0);
ok(scalar(@SHARECALLS == 0 && @LA == 1), '4: flag present and false -> lookup runs, no extra check');

# 5. No artist mbid (stale passthrough): nothing to compare; lookup as before.
detail();
ok(scalar(@LA == 1), '5: no mbid -> lookup runs (nothing to guard against)');

# 6. THE POOL IS SEARCHED UNDER MUSICBRAINZ'S NAME (0.56.13). Field: a page opened
#    as "James Yorkston & The Big Eyes Family Players" resolves to James Yorkston,
#    and searching the services under ITS name stored a joint artist's 2 albums as
#    his pool. _poolQuery chooses the name; the detail page must pass it on, as the
#    list page does, or the two build the same pool under different names.
{
    my $pq = $B->can('_poolQuery');
    my $JOINT = 'James Yorkston & The Big Eyes Family Players';
    %CANON = ('m1' => 'James Yorkston', 'm2' => "The La\x{2019}s", 'm3' => "\x{41a}\x{438}\x{43d}\x{43e}");
    my ($q, $al) = $pq->($JOINT, 'm1', []);
    ok(scalar(($q // '') eq 'James Yorkston' && "@$al" eq $JOINT),
       "6: another name for the artist -> MusicBrainz's name searched, the page's retried after it");
    ($q, $al) = $pq->('The Las', 'm2', []);
    ok(scalar(($q // '') eq "The La's"), "6: ... folded to the marks the services key on (a straight apostrophe)");
    ($q, $al) = $pq->('James Yorkston', 'm1', [ 'J. Yorkston' ]);
    ok(scalar(!defined $q && "@$al" eq 'J. Yorkston'), '6: the same name -> searched as before, aliases untouched');
    ($q, $al, my $cmp) = $pq->('Kino', 'm3', []);
    ok(scalar(!defined $q && ($al->[0] // '') eq $CANON{m3} && ($cmp // 0) == 1),
       '6: a canonical name with no Latin letter is retried, not searched first (Kino) - and asked even when Kino corroborates (0.56.20)');
    ($q, $al) = $pq->($JOINT, 'unknown', [ 'X' ]);
    ok(scalar(!defined $q && "@$al" eq 'X'), '6: no canonical name cached -> as before');
    ($q, $al) = $pq->($JOINT, 'm1', [ 'James Yorkston', 'J. Yorkston', $JOINT ]);
    ok(scalar("@$al" eq "$JOINT J. Yorkston"), '6: aliases keep no copy of either name');

    @CANDOPTS = ();
    detail(mbid => 'm1', artist => $JOINT);
    my ($name, $o) = @{ $CANDOPTS[-1] || [] };
    ok(scalar(($o->{query} // '') eq 'James Yorkston' && ($o->{aliases}[0] // '') eq $JOINT && ($o->{mbid} // '') eq 'm1'),
       '6: the detail page asks for the pool under the same name the list page does');
    @CANDOPTS = ();
    detail(mbid => 'unknown', artist => $JOINT);
    ($name, $o) = @{ $CANDOPTS[-1] || [] };
    ok(scalar(ref $o eq 'HASH' && !exists $o->{query} && !exists $o->{aliases}),
       '6: control: no canonical name -> the detail page asks as before');
    %CANON = ();
}

# 7. THE RELEASE PAGE ASKS AS THE ARTIST PAGE DOES, AND KNOWS THE ARTIST'S OTHER
#    NAMES (resolver plan Part C, C5 and C3; 2026-10-01). It asked for its pool
#    without the shared-name flag and MusicBrainz's aliases, so one opened after
#    the 3-day pool had expired, for a name several acts share, took a lone
#    same-name service artist unchecked and wrote the pool both pages read. And
#    its matching tested only the name it was opened under.
{
    my $on = $B->can('_otherNames');
    %CANON   = ('tg' => 'Tommy Genesis');
    %ALIASES = ('tg' => [ 'Genesis Mohanraj', 'GENESIS MOHANRAJ', 'Genesis Yasmine Mohanraj', '***', '' ]);
    my $o = $on->('tg', 'Genesis Mohanraj');
    ok(scalar(join('|', @$o) eq 'tommy genesis|genesis yasmine mohanraj'),
       "7: the artist's other names: canonical first, then aliases, minus the page's own, once each");
    ok(scalar(@{ $on->(undef, 'Genesis Mohanraj') } == 0), '7: no artist mbid -> none');
    ok(scalar(@{ $on->('unknown', 'Genesis Mohanraj') } == 0), '7: nothing cached -> none (the page name alone, as before)');

    @MFOPT = ();
    detail(mbid => 'tg', artist => 'Genesis Mohanraj');
    ok(scalar("@{ ($MFOPT[-1] || {})->{otherNames} || [] }" eq 'tommy genesis genesis yasmine mohanraj'),
       "7: the release page matches with the artist's other names, as its tile does");

    # A name two acts share: the release page asks with the shared-name flag and
    # MusicBrainz's aliases, exactly as the artist page (both from _poolOpts).
    %ACTS = ('Sonic Boom' => [ $SECOND, $PROM ]);
    $ALIASES{$SECOND} = [ 'Sonic Boom (group)' ];
    @CANDOPTS = (); @AREADS = ();
    detail(mbid => $SECOND);
    my ($name, $d) = @{ $CANDOPTS[-1] || [] };
    ok(scalar($d->{ambiguous} && "@{ $d->{aliases} || [] }" eq 'Sonic Boom (group)' && "@AREADS" eq $SECOND),
       '7: a name two acts share -> the release page asks strictly, with the aliases');
    my $direct;
    $B->can('_poolOpts')->('Sonic Boom', $SECOND, { x => 1 }, sub { $direct = shift });
    ok(scalar(join('|', map { "$_=" . (ref $direct->{$_} ? "@{ $direct->{$_} }" : $direct->{$_} // '') }
                        grep { $_ ne 'spine' } sort keys %$direct)
              eq join('|', map { "$_=" . (ref $d->{$_} ? "@{ $d->{$_} }" : $d->{$_} // '') }
                        grep { $_ ne 'spine' } sort keys %$d)),
       '7: ... the same options the artist page builds');

    %ACTS = ();
    @CANDOPTS = (); @AREADS = ();
    detail(mbid => $SECOND);
    ($name, $d) = @{ $CANDOPTS[-1] || [] };
    ok(scalar(!$d->{ambiguous} && !exists $d->{aliases} && !@AREADS),
       '7: control: one act of the name -> not strict, no alias read');

    # Both pages build them in the one helper.
    open my $fh, '<', "$FindBin::Bin/../Discography/Browse.pm" or die $!;
    my $src = do { local $/; <$fh> };
    my %body;
    for my $sub (qw(_discographyView _releaseDetail)) {
        ($body{$sub}) = $src =~ /^sub \Q$sub\E \{(.*?)^\}/ms;
    }
    ok(scalar(($body{_discographyView} // '') =~ /_poolOpts\(/ && ($body{_releaseDetail} // '') =~ /_poolOpts\(/),
       '7: the artist page and the release page both ask through _poolOpts');
    %CANON = (); %ALIASES = ();
}

# 8. A NAME WITH NO LATIN LETTER IS SEARCHED UNDER MUSICBRAINZ'S ENGLISH NAME FIRST
#    (0.56.18). Field (rig, 2026-10-01): the "米津玄師" page, whose name is also
#    MusicBrainz's, searched the services under the Japanese name; Qobuz settled on
#    another act and Tidal found nothing, while "Kenshi Yonezu" had 5 albums. The
#    native name stays the first retry (an account in Japan may list it).
{
    my $pq = $B->can('_poolQuery');
    my $YZ   = "\x{7c73}\x{6d25}\x{7384}\x{5e2b}";                 # 米津玄師
    my $KO   = "\x{cf04}\x{c2dc} \x{c694}\x{b124}\x{c988}";       # his Korean search hint
    my $KINO = "\x{41a}\x{438}\x{43d}\x{43e}";                     # Кино
    %CANON  = (ky => $YZ, kino => $KINO, x => $YZ, mk => $YZ, jy => 'James Yorkston');
    %ENNAME = (ky => 'Kenshi Yonezu', kino => 'Kino', x => "\x{30ad}\x{30ce}", mk => "Yonezu\x{2019}s");

    my ($q, $al) = $pq->($YZ, 'ky', []);
    ok(scalar(($q // '') eq 'Kenshi Yonezu' && "@$al" eq $YZ),
       "8: MusicBrainz's English name searched first, the page's own name retried after it");
    ($q, $al) = $pq->($YZ, 'ky', [ 'Kenshi Yonezu', $KO ]);
    ok(scalar(($q // '') eq 'Kenshi Yonezu' && join('|', @$al) eq "$YZ|$KO"),
       '8: ... with the aliases after them, and no second copy of the English name');
    ($q, $al) = $pq->('Kenshi Yonezu', 'ky', []);
    ok(scalar(!defined $q && "@$al" eq $YZ),
       '8: a page whose name has Latin letters is searched as before (the Kino rule)');
    ($q, $al) = $pq->('Kenshi', 'ky', []);
    ok(scalar(!defined $q && "@$al" eq $YZ),
       '8: ... even when it is not the English name (another Latin spelling of the artist)');
    ($q, $al) = $pq->($YZ, 'ky', [ $YZ, 'Kenshi Yonezu' ]);
    ok(scalar(($q // '') eq 'Kenshi Yonezu' && "@$al" eq $YZ),
       "8: the page's own name is retried once, however the aliases spell it");
    ($q, $al) = $pq->($KINO, 'kino', [ 'Gruppa Kino', 'Kino' ]);
    ok(scalar(($q // '') eq 'Kino' && join('|', @$al) eq "$KINO|Gruppa Kino"),
       '8: the same for Cyrillic (Kino)');
    my $joint = "$YZ \x{d7} DAOKO";
    ($q, $al) = $pq->("$YZ \x{d7} \x{30c0}\x{30aa}\x{30b3}", 'ky', []);
    ok(scalar(($q // '') eq 'Kenshi Yonezu' && ($al->[0] // '') eq $YZ),
       "8: another name for the artist: MusicBrainz's English name, then MusicBrainz's own, then the page's");
    ($q, $al) = $pq->($YZ, 'x', []);
    ok(scalar(!defined $q && !@$al), '8: an English alias with no Latin letter -> as before');
    ($q, $al) = $pq->($YZ, 'mk', []);
    ok(scalar(($q // '') eq "Yonezu's"), "8: ... folded to the marks the services key on");
    ($q, $al) = $pq->($YZ, 'none', []);
    ok(scalar(!defined $q && !@$al), '8: control: no English name cached -> as before');

    @CANDOPTS = ();
    detail(mbid => 'ky', artist => $YZ);
    my ($name, $o) = @{ $CANDOPTS[-1] || [] };
    ok(scalar(($o->{query} // '') eq 'Kenshi Yonezu' && ($o->{aliases}[0] // '') eq $YZ),
       '8: the release page asks for the pool under the English name');
    my $direct;
    $B->can('_poolOpts')->($YZ, 'ky', {}, sub { $direct = shift });
    ok(scalar(($direct->{query} // '') eq 'Kenshi Yonezu' && !$direct->{ambiguous}),
       '8: ... and so does the artist page (one act of the name: not strict, as before)');
    ok(scalar($direct->{compare} && ($o->{compare} // 0) == 1),
       '8: ... both asking the services to try the native name too (0.56.19, 王菲 on Qobuz)');
    # 0.56.20: the page opened under the LATIN name of an artist whose MusicBrainz
    # name has none ("Faye Wong" for 王菲, "Kenshi Yonezu") asks for both too. It
    # got 4 Qobuz matches where 王菲 got 29, and the pool is shared by mbid.
    my $latin;
    $B->can('_poolOpts')->('Kenshi Yonezu', 'ky', {}, sub { $latin = shift });
    my @three = $pq->('Kenshi Yonezu', 'ky', []);
    ok(scalar(($latin->{compare} // 0) == 1 && !exists $latin->{query} && ($latin->{aliases}[0] // '') eq $YZ
              && ($three[2] // 0) == 1),
       "8: a Latin page name for a non-Latin artist asks for both names too (0.56.20, Faye Wong)");
    my $plain;
    $B->can('_poolOpts')->('James Yorkston', 'jy', {}, sub { $plain = shift });
    my @two = $pq->('James Yorkston', 'jy', []);
    ok(scalar(!exists $plain->{compare} && !defined $two[2]),
       '8: control: a Latin name that is MusicBrainz\'s own -> no compare, as before');
    my @joint = $pq->('James Yorkston & The Big Eyes Family Players', 'jy', []);
    ok(scalar(($joint[0] // '') eq 'James Yorkston' && !defined $joint[2]),
       "8: control: another Latin name, MusicBrainz's Latin one searched first -> no compare");
    %CANON = (); %ENNAME = ();
}

# 9. (0.56.51) The release page matches with the page's TITLES, as its tile does:
#    a copy whose title is exactly another album on the artist's page belongs to
#    that album (Stan Getz: "Getz/Gilberto #2" is not a version of "Getz /
#    Gilberto"). Without them the release page would list it while the tile does not.
{
    no strict 'refs'; no warnings 'redefine';
    my $A = 'Plugins::Discography::API';
    my @rgs = ({ mbid => 'b248d212', title => 'Getz / Gilberto',  type => 'Album', secondary => [], date => '1964' },
               { mbid => '1ae98569', title => 'Getz/Gilberto #2', type => 'Album', secondary => ['Live'], date => '1966' });
    local *{"${A}::getReleaseGroups"} = sub { my ($c, %a) = @_; $a{onDone}->([ map { +{ %$_ } } @rgs ]) };
    local *{"${A}::peekEditions"}     = sub { {} };
    local *{"${B}::_shownTypes"}      = sub { +{ map { $_ => 1 } qw(ALBUMS EPS SINGLES COMPILATIONS LIVE OTHER) } };
    @MFOPT = ();
    $B->can('_releaseDetail')->(undef, sub { }, { artist => 'Stan Getz', mbid => 'getz', rg => { %{ $rgs[0] } } });
    my $pt = ($MFOPT[-1] || {})->{pageTitles};
    my $n  = Plugins::Discography::Sources->can('_norm');
    ok(scalar(ref $pt eq 'HASH' && $pt->{ $n->('Getz/Gilberto #2') } && $pt->{ $n->('Getz / Gilberto') }),
       '9: the release page hands matchesFor the titles of every album on the page');
    ok(scalar(ref $pt eq 'HASH' && ref $pt->{ $n->('Getz/Gilberto #2') } eq 'ARRAY'
              && ($pt->{ $n->('Getz/Gilberto #2') }[0]{type} // '') eq 'Album'),
       '9: ... with each owner\'s type (a Single never takes an album-sized copy)');
}

# 10. A BAND NAMED AFTER ITS LEADER (2026-10-08, The Oscar Peterson Trio): the
#    member MusicBrainz marks `eponymous` rides in the pool's options, from the
#    artist page and the release page alike, never the band's own name.
{
    %EPON = ('opt' => [ { mbid => 'op', name => 'Oscar Peterson' } ],
             'selfy' => [ { mbid => 'sx', name => 'The Selfies' }, { mbid => 'sy', name => 'Ann Self' } ]);
    my $o;
    $B->can('_poolOpts')->('The Oscar Peterson Trio', 'opt', {}, sub { $o = shift });
    ok(scalar("@{ $o->{leaders} || [] }" eq 'Oscar Peterson'), '10: the band page asks with its eponymous leader');
    @CANDOPTS = ();
    detail(mbid => 'opt', artist => 'The Oscar Peterson Trio');
    my ($name, $d) = @{ $CANDOPTS[-1] || [] };
    ok(scalar("@{ ($d || {})->{leaders} || [] }" eq 'Oscar Peterson'), '10: ... and so does its release page');
    $B->can('_poolOpts')->('The Selfies', 'selfy', {}, sub { $o = shift });
    ok(scalar("@{ $o->{leaders} || [] }" eq 'Ann Self'), '10: a leader named as the band itself is left out');
    $B->can('_poolOpts')->('Radiohead', 'rh', {}, sub { $o = shift });
    ok(scalar(!exists $o->{leaders}), '10: control: no eponymous member (or not read yet) -> no leaders key, as before');
    %EPON = ();
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
