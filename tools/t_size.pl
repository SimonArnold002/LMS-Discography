#!/usr/bin/env perl
#
# REGRESSION TEST — an ALBUM-sized copy never matches a MusicBrainz SINGLE.
#
# FIELD (Simon, Kraftwerk, 2026-09-19): his "Tour De France (2009 Digital
# Remaster)" — 12 tracks — read Local on the SINGLE "Tour de France (Etape 2)
# (edit)", because the matcher compares titles only and never asks what KIND of
# release either side is. Simon: "if its an album it should not be matching it
# to another release especially a single" — and it must hold for streaming as
# well as the library, with or without MusicBrainz ids.
#
# The size of a copy is judged the way the Qobuz plugin judges it on its own
# artist pages (Plugin.pm, artist/get album list): 30+ minutes or more than 6
# tracks = album, under 4 tracks = single, otherwise EP. Tidal and Deezer also
# state a type; the library states one only when the file carries a
# RELEASETYPE tag (LMS defaults the rest to ALBUM, so ALBUM proves nothing).
#
# Standalone -- no LMS install needed:  perl tools/t_size.pl
#
use strict;
use warnings;
use FindBin;

our (%ALBUMTRACKS, @TRACKQ);   # album_id -> [ {duration}, ... ]; album ids queried

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::Timers Slim::Networking::SimpleAsyncHTTP
                  Slim::Utils::Strings Slim::Utils::PluginManager
                  Slim::Control::Request Slim::Schema
                  JSON::XS::VersionOneAndTwo Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}          = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Control::Request::executeRequest'} = sub {
        my (undef, $args) = @_;
        if (($args->[0] // '') eq 'titles') {
            my ($al) = map { /^album_id:(\d+)$/ ? $1 : () } @$args;
            push @main::TRACKQ, $al;
            return bless { loop => ($main::ALBUMTRACKS{$al // ''} || []) }, 'T::Req';
        }
        return bless { loop => [] }, 'T::Req';
    };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs)) { push @{"${p}::ISA"}, 'Exporter' }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
}
package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Prefs; sub get { 1 } sub set { 1 } sub init { 1 } sub setChange { 1 }
package T::Req;
sub getResult { my ($s, $w) = @_; $w eq 'count' ? scalar @{ $s->{loop} } : $w eq 'titles_loop' ? $s->{loop} : undef }
package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
my $SRC  = 'Plugins::Discography::Sources';
my $size = $SRC->can('_candSize');

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" } else { $fail++; print "FAIL - $n\n" }
}
sub is_size { my ($album, $want, $n) = @_; ok((($size ? $size->($album) : undef) // 'undef') eq $want, $n) }

# ---------------------------------------------------------------------------
# 1. CLASSIFYING A STREAMING COPY, from each service's own field names.
# ---------------------------------------------------------------------------
is_size({ tracks_count => 12, duration => 2600 }, 'album',  'Qobuz: 12 tracks = album');
is_size({ tracks_count => 5,  duration => 2540 }, 'album',  'Qobuz: 5 tracks but 42 minutes = album (Autobahn)');
is_size({ tracks_count => 2,  duration => 460  }, 'single', 'Qobuz: 2 short tracks = single');
is_size({ tracks_count => 5,  duration => 1200 }, 'ep',     'Qobuz: 5 tracks, 20 minutes = EP');
is_size({ numberOfTracks => 1, duration => 240, type => 'SINGLE' }, 'single', 'Tidal: counts');
is_size({ type => 'ALBUM' },         'album',  'Tidal: its type when no counts');
is_size({ record_type => 'single' }, 'single', 'Deezer: record_type single');
is_size({ record_type => 'compile' },'album',  'Deezer: record_type compile = album-sized');
is_size({ record_type => 'ep' },     'ep',     'Deezer: record_type ep');
is_size({ release_type => 'album' }, 'undef',  'Qobuz\'s own release_type is NOT trusted (its plugin recomputes it)');
is_size({},                          'undef',  'nothing known = no size (behaves as before)');

# _decorate carries it onto the candidate.
{
    my $item = {};
    $SRC->can('_decorate')->($item, 'Qobuz', { id => 1, title => 'Tour de France', tracks_count => 12, duration => 3400 }, 'Kraftwerk');
    ok(($item->{_size} // '') eq 'album', 'the candidate carries its size');
}

# ---------------------------------------------------------------------------
# 2. THE GATE — a MusicBrainz SINGLE never takes an album-sized copy.
# ---------------------------------------------------------------------------
my @SOURCES = ( { name => 'Qobuz', local => 0 }, { name => 'Local', local => 1 } );
my $SINGLE  = 'Tour de France (Etape 2) (edit)';     # _norm -> "tour de france"
my $qAlbum  = { name => 'Tour de France', _svc => 'Qobuz', _candTitle => 'Tour de France',
                _candArtist => 'Kraftwerk', _albumid => 'q1', _size => 'album' };
my $qSingle = { name => 'Tour de France (Etape 2)', _svc => 'Qobuz', _candTitle => 'Tour de France (Etape 2)',
                _candArtist => 'Kraftwerk', _albumid => 'q2', _size => 'single' };
my $qNone   = { name => 'Tour de France', line2 => 'x', _svc => 'Qobuz', _candTitle => 'Tour de France',
                _candArtist => 'Kraftwerk', _albumid => 'q3' };
my $ids = sub { join ',', sort map { $_->{_albumid} } map { @{ $_->{items} } } @{ $_[0] || [] } };
my $mf  = sub {
    my ($title, $type, $bySvc, $local, $rgMbid, $relMap) = @_;
    $SRC->matchesFor($bySvc, 'Kraftwerk', $title, $local, $rgMbid // 'rg-x', $relMap || {}, undef,
                     { sources => \@SOURCES, rgType => $type });
};

ok($ids->($mf->($SINGLE, 'Single', { Qobuz => [ $qAlbum, $qSingle ] })) eq 'q2',
   'Qobuz: the album-sized "Tour de France" no longer lands on the single; the single copy still does');
ok($ids->($mf->($SINGLE, 'Single', { Qobuz => [ $qNone ] })) eq 'q3',
   'a copy of unknown size still matches as before (no signal, no change)');
ok($ids->($mf->('Tour de France', 'Album', { Qobuz => [ $qAlbum ] })) eq 'q1',
   'control: the same album-sized copy still matches an ALBUM');
ok($ids->($mf->($SINGLE, 'EP', { Qobuz => [ $qAlbum ] })) eq 'q1',
   'the gate is about SINGLES only: an EP release group is unchanged');

# The library: Simon's copy, 12 tracks, sized lazily from its tracks.
%ALBUMTRACKS = (900 => [ map { { duration => 300 } } 1..12 ],
                901 => [ map { { duration => 250 } } 1..2 ],
                902 => [ map { { duration => 300 } } 1..8 ]);
my $lAlbum  = { name => 'Tour De France (2009 Digital Remaster)', _svc => 'Local', _albumid => 900,
                _candTitle => 'Tour De France (2009 Digital Remaster)', _candArtist => 'Kraftwerk' };
my $lSingle = { name => 'Tour de France', _svc => 'Local', _albumid => 901,
                _candTitle => 'Tour de France', _candArtist => 'Kraftwerk' };
my $lTagged = { name => 'Tour de France Remixes', _svc => 'Local', _albumid => 902, _reltype => 'SINGLE',
                _candTitle => 'Tour de France', _candArtist => 'Kraftwerk' };

@TRACKQ = ();
ok($ids->($mf->($SINGLE, 'Single', {}, [ $lAlbum, $lSingle ])) eq '901',
   'library: the 12-track album no longer reads Local on the single; an owned 2-track single does');
ok($ids->($mf->($SINGLE, 'Single', {}, [ $lTagged ])) eq '902',
   'library: a RELEASETYPE=Single tag wins over the track count');
@TRACKQ = ();
$mf->('Tour de France', 'Album', {}, [ { %$lAlbum, _candTitle => 'Tour de France' } ]);
ok(!@TRACKQ, 'no track-count query unless a local copy title-matches a SINGLE');

# Identity (tier 0) is never second-guessed: an id that says it IS the single wins.
ok($ids->($mf->($SINGLE, 'Single', {}, [ { %$lAlbum, _mbid => 'rg-etape2' } ], 'rg-etape2')) eq '900',
   'a MusicBrainz id placing the copy IN this single still matches it');

# ---------------------------------------------------------------------------
# 3. "Also in your library" must agree: an album the single no longer claims is
#    not hidden as claimed (it would vanish from both places).
# ---------------------------------------------------------------------------
{
    my $rgs = [ { mbid => 'rg-etape2', title => $SINGLE, type => 'Single', secondary => [] } ];
    my $c = $SRC->claimedLocalIds($rgs, 'Kraftwerk', [ $lAlbum, $lSingle ], {});
    ok(!$c->{900}, 'the album-sized copy is not claimed by the single');
    ok($c->{901},  '... the owned single still is');
}

# ---------------------------------------------------------------------------
# 4. EDITION TITLES. The "Tour de France Soundtracks" group matches its 2009+
#    edition title "Tour de France" — album-only, because the 1983 single owns
#    that title too — so Simon's copy and the Qobuz album attach by title, with
#    or without an id, while a single-sized copy stays with the single.
# ---------------------------------------------------------------------------
{
    my $TDFS = 'Tour de France Soundtracks';
    my $eds  = [ [ 'tour de france', 'Tour de France', 1 ] ];
    my $mfe  = sub {
        my ($bySvc, $local, $e) = @_;
        $SRC->matchesFor($bySvc, 'Kraftwerk', $TDFS, $local, 'rg-tdfs', {}, undef,
                         { sources => \@SOURCES, rgType => 'Album', editions => $e || $eds });
    };
    ok($ids->($mfe->({ Qobuz => [ $qAlbum, $qSingle, $qNone ] })) eq 'q1',
       'the album group takes the album-sized Qobuz "Tour de France" by edition title, not the single or an unsized copy');
    ok($ids->($mfe->({}, [ $lAlbum, $lSingle ])) eq '900',
       'library: Simon\'s 12-track copy attaches by title alone (no id needed); an owned 2-track single does not');
    ok($ids->($mfe->({ Qobuz => [ $qNone ] }, undef, [ [ 'tour de france', 'Tour de France', 0 ] ])) eq 'q3',
       'an edition title with no clash matches any copy');
    ok(!@{ $SRC->matchesFor({ Qobuz => [ $qAlbum ] }, 'Kraftwerk', $TDFS, undef, 'rg-tdfs', {}, undef,
                            { sources => \@SOURCES, rgType => 'Album' }) },
       'control: without edition titles the album group matches nothing (today\'s behaviour)');
    my $rgs = [ { mbid => 'rg-tdfs', title => $TDFS, type => 'Album', secondary => [] } ];
    my $c = $SRC->claimedLocalIds($rgs, 'Kraftwerk', [ $lAlbum, $lSingle ], {}, { 'rg-tdfs' => $eds });
    ok($c->{900} && !$c->{901}, '"Also in your library" agrees: the album claims the copy, not the single');
}

# ---------------------------------------------------------------------------
# 5. MATCHED BY ID = NOT MATCHED AGAIN BY TITLE (Simon, 2026-09-19: "it should
#    not try to match again it if its matched via id"). A copy whose MusicBrainz
#    id places it in ANOTHER group on this page is that group's, so no title
#    rule may hand it to a second tile. The size gate only covers a SINGLE; an
#    EP titled "Tour de France" is the case it cannot reach.
# ---------------------------------------------------------------------------
{
    my $EP     = 'Tour de France';
    my $relMap = { 'rel-2009' => 'rg-tdfs' };                  # release -> its group
    my $page   = { 'rg-tdfs' => 1, 'rg-ep' => 1 };              # groups on this page
    my $tagged = { %$lAlbum, _mbid => 'rel-2009' };
    my $mfi = sub {
        my ($local, $groups, $rg) = @_;
        $SRC->matchesFor({}, 'Kraftwerk', $EP, $local, $rg // 'rg-ep', $relMap, undef,
                         { sources => \@SOURCES, rgType => 'EP', idGroups => $groups });
    };
    ok(!@{ $mfi->([ $tagged ], $page) },
       'an album copy whose id names the album group is NOT title-matched onto an EP');
    ok($ids->($mfi->([ { %$lAlbum, _mbid => 'rg-tdfs' } ], $page)) eq '',
       '... same when the tag is the release-GROUP id itself');
    ok($ids->($mfi->([ $tagged ], { 'rg-ep' => 1 })) eq '900',
       'an id naming a group NOT on this page proves nothing here: the title decides, as before');
    ok($ids->($mfi->([ $lAlbum ], $page)) eq '900',
       'a copy with no id is matched by title, as before');
    ok($ids->($mfi->([ { %$lAlbum, _mbid => 'rel-unknown' } ], $page)) eq '900',
       'an id the release map cannot place is matched by title, as before');
    ok($ids->($mfi->([ $tagged ], $page, 'rg-tdfs')) eq '900',
       'control: its own group still takes it by id');

    my $rgs = [ { mbid => 'rg-ep',   title => $EP,              type => 'EP',    secondary => [] },
                { mbid => 'rg-tdfs', title => 'Soundtracks',    type => 'Album', secondary => [] } ];
    my $c = $SRC->claimedLocalIds($rgs, 'Kraftwerk', [ $tagged ], $relMap);
    ok($c->{900}, '"Also in your library": the id-placed copy is still claimed (by its own group)');
    my $cEp = $SRC->claimedLocalIds([ $rgs->[0] ], 'Kraftwerk', [ $tagged ], $relMap);
    ok($cEp->{900}, 'control: with its own group absent from the pool, the title still claims it');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
