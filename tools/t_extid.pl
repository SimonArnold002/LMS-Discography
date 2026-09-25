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

our ($SECTIONS);

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
    *{"${S}::getCandidates"}       = sub { $_[-2]->({}) };
    *{"${S}::localAlbums"}         = sub { [] };
    *{"${S}::localTracks"}         = sub { [] };
    *{"${S}::matchesFor"}          = sub { $main::SECTIONS };
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

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
