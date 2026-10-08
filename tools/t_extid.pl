#!/usr/bin/env perl
#
# REGRESSION TEST: Material's service badge (extid) on streaming rows (after 0.54.2).
#
# Material (upstream d3f1d9227, first released in 6.4.10) draws a service emblem
# over a row's artwork from `extid`, reading only the part before the first ':'
# against its misc/emblems.json. The LL 1.0.7 / PFR 1.0.2 shape: '<svc>:album:<id>'.
# Pinned here through the REAL _extid / _releaseItem / _releaseDetail:
#   - a tile's badge names the source it PLAYS (sections[0]); a Local-first tile
#     has none even when a streaming favurl rides along (Simon, 2026-09-24);
#   - line2 keeps listing every source (Simon, 2026-09-24);
#   - every streaming version row on the detail page is badged, Local is not;
#   - the badge is set on the row COPY, never on the cached candidate node.
#
# Standalone, no LMS install needed:  perl tools/t_extid.pl
#
use strict;
use warnings;
use FindBin;

our ($SECTIONS, @MF_OPTS);

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
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Null' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Slim::Utils::Strings::cstring'}   = sub { $_[1] };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Plugins::Discography::Sources::_norm'} = sub {
        my $s = lc($_[-1] // ''); $s =~ s/[^a-z0-9]+/ /g; $s =~ s/^ +| +$//g; $s };
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');

    my $A = 'Plugins::Discography::API';
    my $S = 'Plugins::Discography::Sources';
    *{"${A}::caaImage"}            = sub { 'caa://' . ($_[1] // '') };
    *{"${A}::getReleaseGroupUrls"} = sub { my ($c, %a) = @_; $a{onDone}->([]) };
    *{"${A}::peekReleaseGroups"}   = sub { [] };
    *{"${A}::peekReleaseMap"}      = sub { {} };
    *{"${A}::peekLocalReleaseMap"} = sub { {} };
    # The pool's options (_poolOpts) and the artist's other names (_otherNames):
    # nothing cached, one act of the name.
    *{"${A}::getArtistCandidates"} = sub { $_[2]->([]) };
    *{"${A}::warmArtistAliases"}   = sub { $_[2]->([]) };
    *{"${A}::peekArtistName"}      = sub { undef };
    *{"${A}::peekArtistAliases"}   = sub { undef };
    *{"${A}::peekArtistEnglishName"} = sub { undef };
    *{"${A}::peekEponymous"}       = sub { undef };   # no band leader (Browse::_poolLeaders)
    *{"${S}::getCandidates"}       = sub { $_[-2]->({}) };
    *{"${S}::localAlbums"}         = sub { [] };
    *{"${S}::localTracks"}         = sub { [] };
    # Sources::libraryAlbumActions' shape, filter off (t_localalbumtracks.pl tests the real one).
    *{"${S}::libraryAlbumActions"} = sub {
        my ($al, $ar) = @_;
        return undef unless defined $al && $al =~ /^\d+$/;
        return { allAvailableActionsDefined => 1,
                 info  => { command => ['albuminfo', 'items'], fixedParams => { album_id => $al } },
                 items => { command => ['browselibrary', 'items'],
                            fixedParams => { mode => 'tracks', album_id => $al, ($ar ? (material_skin_artist_id => $ar) : ()) } },
                 map { $_ => { command => ['playlistcontrol'], fixedParams => { cmd => ($_ eq 'play' ? 'load' : $_), album_id => $al } } } qw(play add insert) };
    };
    *{"${S}::matchesFor"}          = sub { push @main::MF_OPTS, $_[8]; $main::SECTIONS };
}

package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}

package T::Prefs; our %P; our $AUTOLOAD;
sub get { $P{ $_[1] } } sub AUTOLOAD { return } sub DESTROY {}

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;
my $B = 'Plugins::Discography::Browse';
{ no warnings 'redefine'; no strict 'refs';
  *{"${B}::_fetchAlbumReview"} = sub { $_[-1]->(undef) }; }

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

my $extid = $B->can('_extid');

# Candidate nodes in the shape Sources::_decorate / localAlbums leave them.
sub qobuz  { { name => 'Kid A', type => 'playlist', _svc => 'Qobuz',  _albumid => '0724352774', _cover => 'q.jpg',
               favorites_url => 'qobuz://album:0724352774' } }
sub tidal  { { name => 'Kid A', type => 'playlist', _svc => 'Tidal',  _albumid => '1234567',    _cover => 't.jpg',
               favorites_url => 'tidal://album:1234567' } }
sub deezer { { name => 'Kid A', type => 'playlist', _svc => 'Deezer', _albumid => '99887',      _cover => 'd.jpg',
               favorites_url => 'deezer://album:99887' } }
sub lib  { { name => 'Kid A', type => 'playlist', _svc => 'Local',  _albumid => 29030, _cover => '/music/5/cover',
               play => 'db:album.id=29030' } }
sub sec    { my ($svc, @items) = @_; { svc => $svc, items => \@items } }

# 1. _extid itself: one Material emblems.json key per service, lowercased.
ok(scalar(($extid->(qobuz())  // '') eq 'qobuz:album:0724352774'), '1: Qobuz  -> qobuz:album:<id>');
ok(scalar(($extid->(tidal())  // '') eq 'tidal:album:1234567'),    '1: Tidal  -> tidal:album:<id>');
ok(scalar(($extid->(deezer()) // '') eq 'deezer:album:99887'),     '1: Deezer -> deezer:album:<id>');
ok(scalar(($extid->({ _svc => 'Spotify', _albumid => '4qpB1EXFCmq0a209JGCsZt' }) // '') eq 'spotify:album:4qpB1EXFCmq0a209JGCsZt'),
   '1: Spotify -> spotify:album:<id> (the key is in Material emblems.json)');
ok(scalar(!defined $extid->(lib())), '1: Local has no emblem -> no extid');
ok(scalar(!defined $extid->({ _svc => 'Bandcamp', _albumid => 1 })), '1: a service outside the set -> no extid');
ok(scalar(!defined $extid->(undef) && !defined $extid->('x')), '1: not a hash -> no extid');
ok(scalar(($extid->({ _svc => 'Qobuz' }) // '') eq 'qobuz:'), "1: no album id -> bare 'qobuz:'");
ok(scalar(($extid->({ _svc => 'Qobuz', _albumid => '' }) // '') eq 'qobuz:'), "1: empty album id -> bare 'qobuz:'");
ok(scalar(($extid->({ %{ qobuz() }, extid => 'qobuz:album:native' }) // '') eq 'qobuz:album:native'),
   "1: a node's own extid is kept");

# 2. Release tiles: the badge follows the source that PLAYS.
my $rg = { mbid => '11111111-1111-1111-1111-111111111111', title => 'Kid A', type => 'Album',
           secondary => [], date => '2000-10-02' };
my $tile = $B->can('_releaseItem');
{
    my $t = $tile->(undef, {}, $rg, [ sec('Qobuz', qobuz()), sec('Tidal', tidal()) ]);
    ok(scalar(($t->{extid} // '') eq 'qobuz:album:0724352774'), '2: streaming-first tile -> the preferred service badge');
    ok(scalar($t->{line2} =~ m{Qobuz/Tidal}), '2: line2 still lists every source');
    ok(scalar($t->{type} eq 'playlist'), '2: badged tile stays playable');
}
{
    my $t = $tile->(undef, {}, $rg, [ sec('Local', lib()), sec('Qobuz', qobuz()) ]);
    ok(scalar(!exists $t->{extid}), '2: Local-first tile -> NO badge (it plays the library copy)');
    ok(scalar(($t->{favorites_url} // '') eq 'qobuz://album:0724352774'),
       '2: Local-first tile keeps its streaming favurl (the LL handshake is unchanged)');
    ok(scalar($t->{line2} =~ m{Local/Qobuz}), '2: Local-first tile line2 lists Local and Qobuz');
}
{
    my $t = $tile->(undef, {}, $rg, [ sec('Tidal', tidal()), sec('Local', lib()) ]);
    ok(scalar(($t->{extid} // '') eq 'tidal:album:1234567'), '2: priority puts Tidal first -> Tidal badge');
}
{
    my $t = $tile->(undef, {}, $rg, []);
    ok(scalar(!exists $t->{extid} && $t->{type} eq 'link'), '2: unmatched tile -> no badge');
    $t = $tile->(undef, {}, $rg, undef);
    ok(scalar(!exists $t->{extid}), '2: no sections at all -> no badge');
}

# 3. The cached candidate is never written to.
{
    my $cached = qobuz();
    my %before = %$cached;
    $tile->(undef, {}, $rg, [ sec('Qobuz', $cached) ]);
    ok(scalar(!exists $cached->{extid}), '3: tile build leaves the cached node without extid');
    ok(scalar(join(',', sort keys %$cached) eq join(',', sort keys %before)), '3: tile build adds no key to the cached node');
}

# 4. Detail page version rows.
sub detail {
    my @items;
    $B->can('_releaseDetail')->(undef, sub { @items = @{ $_[0]{items} || [] } },
        { artist => 'Radiohead', rg => $rg, shared_name => 0 });
    return grep { ($_->{id} // '') =~ /^v:/ } @items;
}
{
    local $T::Prefs::P{show_all_versions} = 0;
    my $cq = qobuz();
    local $SECTIONS = [ sec('Qobuz', $cq), sec('Tidal', tidal()) ];
    my @v = detail();
    ok(scalar(@v == 1 && ($v[0]{extid} // '') eq 'qobuz:album:0724352774'),
       '4: single-version detail -> the preferred row is badged');
    ok(scalar(($v[0]{line2} // '') eq 'Qobuz'), '4: single-version row keeps its service name in line2');
    ok(scalar(!exists $cq->{extid}), '4: single-version detail leaves the cached node alone');
}
{
    local $T::Prefs::P{show_all_versions} = 1;
    my ($cl, $cq, $ct) = (lib(), qobuz(), tidal());
    local $SECTIONS = [ sec('Local', $cl), sec('Qobuz', $cq), sec('Tidal', $ct) ];
    my %by = map { ($_->{id} => $_) } detail();
    ok(scalar(keys %by == 3), '4: all-versions detail -> three version rows');
    ok(scalar(!exists $by{'v:Local:0'}{extid}), '4: all-versions: the Local row has no badge');
    ok(scalar(($by{'v:Qobuz:0'}{extid} // '') eq 'qobuz:album:0724352774'), '4: all-versions: the Qobuz row is badged');
    ok(scalar(($by{'v:Tidal:0'}{extid} // '') eq 'tidal:album:1234567'),    '4: all-versions: the Tidal row is badged');
    ok(scalar(!grep { exists $_->{extid} } $cl, $cq, $ct), '4: all-versions detail leaves every cached node alone');
}

# 5. "Refresh matches" clears the pool THIS page reads (0.56.15). Since 0.43 the
#    detail page's pool is keyed by the ARTIST's mbid (getCandidates `mbid =>
#    $pass->{mbid}`); the row passed only the name, so it cleared the name-keyed
#    copy nothing reads and changed nothing.
{
    my $AM = 'a74b1b7f-71a5-4011-9441-d0b5e4122711';
    our @CLR;
    no warnings 'redefine'; no strict 'refs';
    local *{'Plugins::Discography::Sources::clearCandidates'} = sub { shift; push @CLR, [@_] };
    # With an mbid the page asks MusicBrainz's name for its pool (_poolQuery).
    local *{'Plugins::Discography::API::peekArtistName'} = sub { undef };
    # ... and the artist's groups, as t_detailshared stubs them.
    local *{'Plugins::Discography::API::getReleaseGroups'} = sub { my ($c, %a) = @_; $a{onError}->() };
    local *{'Plugins::Discography::API::peekOfficial'}     = sub { {} };
    local $SECTIONS = [];
    my @items;
    $B->can('_releaseDetail')->(undef, sub { @items = @{ $_[0]{items} || [] } },
        { artist => 'Radiohead', rg => $rg, shared_name => 0, mbid => $AM });
    my ($row) = grep { ($_->{id} // '') eq 'act:refresh' } @items;
    ok(scalar($row && ref $row->{url} eq 'CODE'), '5: the detail page has its Refresh matches row');
    @CLR = ();
    $row->{url}->(undef, sub { }, {}, @{ $row->{passthrough} || [] }) if $row;
    ok(scalar(@CLR == 1 && ($CLR[0][0] // '') eq 'Radiohead' && ($CLR[0][1] // '') eq $AM),
       "5: ... it clears with the artist's mbid as well as the name (the key the page's pool is under)");
}

# 6. WHERE AN OWNED SONG LIVES, AND WHAT MUSICBRAINZ CALLS AN APPEARANCE
#    (0.56.39; Simon, Ella Fitzgerald: "not one gives the album name", and
#    "this is Soundtrack not a compilation not sure if LMS has that but MB does").
{
    my $single = { mbid => '22222222-2222-2222-2222-222222222222', title => 'Voices Green and Purple',
                   type => 'Single', secondary => [], date => '1966' };
    my $track  = { name => 'Voices Green and Purple', type => 'audio', _svc => 'Local', _track => 1,
                   _trackid => 500, play => 'db:track.id=500', _fromAlbum => 'Nuggets' };
    my $t = $tile->(undef, {}, $single, [ sec('Local', $track) ]);
    ok(scalar(($t->{line2} // '') eq "1966 \x{00B7} Single \x{00B7} Local \x{00B7} from Nuggets"),
       '6: a single played from a compilation track says which album: "from Nuggets"');
    $t = $tile->(undef, {}, $single, [ sec('Local', { %$track, _fromAlbum => undef }) ]);
    ok(scalar(($t->{line2} // '') eq "1966 \x{00B7} Single \x{00B7} Local"),
       '6: ... no album name known: nothing added');
    $t = $tile->(undef, {}, $rg, [ sec('Local', lib()) ]);
    ok(scalar(($t->{line2} // '') !~ /from/), '6: an owned ALBUM tile is unchanged');

    my $extra = $B->can('_extraSection');
    my $albums = sub { [
        { name => 'The Last Time I Committed Suicide', _albumid => 1, _year => 1997, _mbid => 'rel-1' },
        { name => 'Jazz in the Charts 078',            _albumid => 2, _year => 2006, _mbid => 'rel-2' },
        { name => 'Greatest Divas',                    _albumid => 3, _year => 1999 },
        { name => 'Unknown type',                      _albumid => 4, _year => 2001, _mbid => 'rel-4' },
    ] };
    my $types = { 'rel-1' => { type => 'Album', secondary => [ 'Soundtrack' ] },
                  'rel-2' => { type => 'Album', secondary => [ 'Compilation' ] } };
    my %l2 = map { ($_->{name} // '') => ($_->{line2} // '') }
             grep { $_->{_albumid} } $extra->(undef, {}, 0, 'newest',
                 'PLUGIN_DISCOGRAPHY_APPEARANCES', 'x.png', 'APPEAR', $albums->(), $types);
    ok(scalar($l2{'The Last Time I Committed Suicide'} eq "1997 \x{00B7} Album / Soundtrack \x{00B7} Local"),
       '6: an Appearances row says Soundtrack, as MusicBrainz types it');
    ok(scalar($l2{'Jazz in the Charts 078'} eq "2006 \x{00B7} Compilation \x{00B7} Local"),
       '6: ... a compilation says Compilation');
    ok(scalar($l2{'Greatest Divas'} eq "1999 \x{00B7} Local" && $l2{'Unknown type'} eq "2001 \x{00B7} Local"),
       '6: ... an untagged album, or one whose type is not known yet, as before');
    %l2 = map { ($_->{name} // '') => ($_->{line2} // '') }
          grep { $_->{_albumid} } $extra->(undef, {}, 0, 'newest',
              'PLUGIN_DISCOGRAPHY_LIBRARY_EXTRAS', 'x.png', 'EXTRAS', $albums->());
    ok(scalar($l2{'The Last Time I Committed Suicide'} eq "1997 \x{00B7} Local"),
       '6: a section given no types (Also in your library) is unchanged');

    # The release page tells the track link what the group is, as the list does.
    local $T::Prefs::P{show_all_versions} = 0;
    local $SECTIONS = [];
    for my $case ([ 'Album', ['Compilation'], 1 ], [ 'Single', [], 0 ]) {
        @MF_OPTS = ();
        my $g = { mbid => '33333333-3333-3333-3333-333333333333', title => 'A-Tisket, A-Tasket',
                  type => $case->[0], secondary => $case->[1], date => '1996' };
        $B->can('_releaseDetail')->(undef, sub {}, { artist => 'Ella Fitzgerald', rg => $g, shared_name => 0 });
        my ($o) = grep { ref $_ eq 'HASH' } @MF_OPTS;
        ok(scalar($o && ($o->{rgType} // '') eq $case->[0] && ($o->{rgComp} // -1) == $case->[2]),
           "6: the release page passes rgType $case->[0] and rgComp $case->[2]");
    }
}

# 7. AN OWNED ALBUM OPENS AS A LIBRARY ALBUM (0.56.56; Simon 2026-10-07: "We need
# to copy exactly how LMS does this"). A Local album row carries LMS's own album
# actions (browselibrary mode:tracks to open, playlistcontrol to play), so Material
# draws its native album page; every other row keeps its param-addressed actions.
{
    my $native = sub {
        my ($r, $album) = @_;
        my $a = $r->{itemActions} || {};
        return join(' ', @{ $a->{items}{command} || [] }) eq 'browselibrary items'
            && ($a->{items}{fixedParams}{mode} // '') eq 'tracks'
            && ($a->{items}{fixedParams}{album_id} // '') eq "$album"
            && join(' ', @{ $a->{play}{command} || [] }) eq 'playlistcontrol'
            && ($a->{play}{fixedParams}{cmd} // '') eq 'load'
            && ($a->{add}{fixedParams}{cmd} // '') eq 'add'
            && ($a->{insert}{fixedParams}{cmd} // '') eq 'insert'
            # every action defined + LMS's album `info`: no positional params, so
            # Material under My Apps can id the row (the 0.56.57 empty-page fix)
            && ($a->{allAvailableActionsDefined} // 0) == 1
            && join(' ', @{ $a->{info}{command} || [] }) eq 'albuminfo items'
            && ($a->{info}{fixedParams}{album_id} // '') eq "$album";
    };
    my $own = sub { join(' ', @{ $_[0]{itemActions}{items}{command} || [] }) eq 'discography items' };

    local $T::Prefs::P{show_all_versions} = 0;
    { local $SECTIONS = [ sec('Local', { %{ lib() }, _listedUnder => 154055 }), sec('Qobuz', qobuz()) ];
      my @v = detail();
      ok(scalar(@v == 1 && $native->($v[0], 29030)), '7: single-version detail: the Local row opens and plays as a library album');
      ok(scalar(($v[0]{itemActions}{items}{fixedParams}{material_skin_artist_id} // '') eq '154055'),
         '7: ... carrying the artist it was listed under (Material highlights its tracks)');
      ok(scalar(($v[0]{play} // '') eq 'db:album.id=29030'), '7: ... its play string unchanged (clients that are not Material)'); }
    { local $SECTIONS = [ sec('Qobuz', qobuz()), sec('Local', lib()) ];
      my @v = detail();
      ok(scalar(@v == 1 && $own->($v[0]) && !$native->($v[0], 29030)),
         '7: a Qobuz-first detail: the streaming row keeps its own actions'); }

    local $T::Prefs::P{show_all_versions} = 1;
    { local $SECTIONS = [ sec('Local', lib()), sec('Qobuz', qobuz()) ];
      my %by = map { ($_->{id} => $_) } detail();
      ok(scalar($native->($by{'v:Local:0'}, 29030)), '7: all-versions: the Local row opens as a library album');
      ok(scalar($own->($by{'v:Qobuz:0'})), '7: all-versions: the Qobuz row keeps its own actions'); }
    { my $song = { name => 'Voices Green and Purple', type => 'audio', _svc => 'Local', _track => 1,
                   _trackid => 7, _albumid => 9, play => 'db:track.id=7' };
      local $SECTIONS = [ sec('Local', $song) ];
      my %by = map { ($_->{id} => $_) } detail();
      ok(scalar(!$native->($by{'v:Local:0'}, 9)), '7: an owned SONG (a track link) is not turned into its whole album'); }

    my @t = grep { $_->{_albumid} } $B->can('_extraSection')->(undef, {}, 0, 'newest',
        'PLUGIN_DISCOGRAPHY_APPEARANCES', 'x.png', 'APPEAR',
        [ { name => 'Greatest Divas', type => 'playlist', _svc => 'Local', _albumid => 52249, _year => 2005,
            _listedUnder => 151861, play => 'db:album.id=52249' } ]);
    ok(scalar(@t == 1 && $native->($t[0], 52249)), '7: an Appearances tile opens and plays as a library album');
    ok(scalar(($t[0]{itemActions}{items}{fixedParams}{material_skin_artist_id} // '') eq '151861'
              && ($t[0]{id} // '') eq 'lib:52249'),
       '7: ... with the artist it was listed under, and its lib: id kept');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
