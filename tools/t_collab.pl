#!/usr/bin/env perl
#
# REGRESSION TEST — "Collaborations": MusicBrainz COLLABORATION links, listed
# beside "Also a member of" (Simon, 2026-09-19).
#
# FIELD: Holly Golightly's page never linked to "Holly Golightly and The
# Brokeoffs", where she owns two albums. MusicBrainz records her there as a
# COLLABORATOR, not a band member, and warmBandMembers kept only "member of
# band". Her record on the mirror, verbatim:
#
#     collaboration   forward -> Holly Golightly and The Brokeoffs
#     member of band  forward -> Avenue A
#     member of band  forward -> Thee Headcoatees
#
# Most collaboration links are CHARITY supergroups (Band Aid 21 collaborators,
# USA for Africa 37, "1,000 UK Artists" 722). Measured over Simon's 1,100
# artists, the collaborator count on the TARGET separates them cleanly: real
# duos and side projects have 1-5 (Fripp & Eno, FFS, The Gutter Twins, the
# Brokeoffs), charity ensembles start at 10. So a link is kept when the target
# has 1..5 collaborators and at least one release group.
#
# Standalone -- no LMS install needed:  perl tools/t_collab.pl
#
use strict;
use warnings;
use FindBin;
use Time::HiRes ();

our (%CACHE, $DATA, @URLS, %FAIL, @EV, @WHEN);
our $BASE = 'http://mirror:5000/ws/2/';   # a mirror: _mbGap is 0

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::Timers Slim::Networking::SimpleAsyncHTTP
                  Slim::Utils::Strings Slim::Utils::PluginManager
                  Slim::Control::Request JSON::XS::VersionOneAndTwo
                  Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Cache' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { '' };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { $main::DATA };
    *{'Slim::Networking::SimpleAsyncHTTP::new'} = sub {
        my ($cls, $cb, $errcb, $opt) = @_;
        return bless { cb => $cb, err => $errcb }, 'T::HTTP';
    };
    # Fires immediately, but RECORDS that the chain waited — which is the whole
    # question for MusicBrainz's 1 req/s etiquette.
    *{'Slim::Utils::Timers::setTimer'} = sub {
        my (undef, $when, $cb) = @_;
        push @main::EV, 'wait';
        push @main::WHEN, $when;      # the DEADLINE, for the hi-res check in 5b
        return $cb->();
    };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs JSON::XS::VersionOneAndTwo)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
    @{'JSON::XS::VersionOneAndTwo::EXPORT'} = qw(to_json from_json);
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Cache;
sub get    { return $main::CACHE{ $_[1] } }
sub set    { $main::CACHE{ $_[1] } = $_[2]; return 1 }
sub remove { delete $main::CACHE{ $_[1] }; return 1 }
package T::Prefs;
# A mirror base ($BASE) leaves _mbGap at 0; the public API makes it 1.1.
sub get { return $_[1] eq 'mb_base_url' ? $main::BASE : undef }
sub set { return 1 } sub init { return 1 } sub setChange { return 1 }
package T::Resp;
sub new { bless {}, shift } sub content { '{}' } sub error { 'stub error' }
package T::HTTP;
sub get {
    my ($self, $url) = @_;
    push @main::URLS, $url;
    push @main::EV, 'get';
    if (grep { index($url, $_) >= 0 } keys %main::FAIL) {
        return $self->{err}->(T::Resp->new);
    }
    $main::DATA = main::response_for($url);
    $self->{cb}->(T::Resp->new);
}

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::API;
my $API = 'Plugins::Discography::API';

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

my $HOLLY = 'c0d96e6b-ee48-422d-8c28-f169ada973a8';
my %T = (   # target id => [ name, collaborators, release groups ]
    brokeoffs => [ 'Holly Golightly and The Brokeoffs', 1, 11 ],
    bandaid   => [ 'Band Aid', 21, 3 ],
    dead      => [ 'The Amnesty Allstars', 1, 0 ],
    five      => [ 'The Quintet', 5, 1 ],
    six       => [ 'Six Of Us', 6, 1 ],
    avenuea   => [ 'Avenue A', 2, 1 ],      # ALSO a band: never a collaboration
);
my %ARTIST = (   # artist mbid => its forward relations
    $HOLLY => [ [ 'collaboration', 'brokeoffs' ], [ 'collaboration', 'bandaid' ],
                [ 'collaboration', 'dead' ],      [ 'collaboration', 'five' ],
                [ 'collaboration', 'six' ],       [ 'collaboration', 'avenuea' ],
                [ 'member of band', 'avenuea' ],  [ 'member of band', 'headcoatees' ],
                [ 'collaboration', 'brokeoffs' ] ],     # duplicate relation
    solo   => [ [ 'member of band', 'avenuea' ] ],
);
my %NAME = (headcoatees => 'Thee Headcoatees', map { $_ => $T{$_}[0] } keys %T);

sub response_for {
    my ($url) = @_;
    if ($url =~ m{/artist/([^?]+)\?inc=artist-rels}) {
        my $id = $1;
        if (my $rels = $ARTIST{$id}) {
            return { name => 'X', relations => [ map {
                { type => $_->[0], direction => 'forward',
                  artist => { id => $_->[1], name => $NAME{ $_->[1] } } } } @$rels ] };
        }
        my $t = $T{$id} or return { relations => [] };
        return { name => $t->[0], relations => [
            (map { { type => 'collaboration', direction => 'backward',
                     artist => { id => "p$_", name => "P$_" } } } 1 .. $t->[1]),
            { type => 'collaboration', direction => 'forward',       # ignored
              artist => { id => 'x', name => 'x' } } ] };
    }
    if ($url =~ m{release-group\?artist=([^&]+)}) {
        my $t = $T{$1};
        return { 'release-group-count' => $t ? $t->[2] : 0 };
    }
    return {};
}

# The MB chain: the band lookup (which gates the first render) and then, at the
# END of the chain, the collaboration vetting.
sub warm {
    my ($mbid) = @_;
    my $n = 0;
    $API->warmBandMembers($mbid, sub { $n++ });
    $API->warmCollaborations($mbid) if $API->can('warmCollaborations');
    return $n;
}
my $names = sub { join ',', map { $_->{name} } @{ $_[0] || [] } };

# ---------------------------------------------------------------------------
# 1. Holly Golightly: the Brokeoffs are kept, everything else is filtered.
# ---------------------------------------------------------------------------
my $cbs = warm($HOLLY);
ok($cbs == 1, 'the warm calls back exactly once');
ok($names->($API->peekBands($HOLLY)) eq 'Avenue A,Thee Headcoatees',
   'bands are unchanged: member-of-band links only');
my $c = $API->can('peekCollabs') ? $API->peekCollabs($HOLLY) : undef;
ok($c && $names->($c) =~ /^Holly Golightly and The Brokeoffs(,|$)/,
   'the Brokeoffs are listed as a collaboration');
ok($c && $names->($c) !~ /Band Aid/, 'a charity supergroup (21 collaborators) is dropped');
ok($c && $names->($c) !~ /Amnesty/,  'a collaboration with no release groups is dropped');
ok($c && $names->($c) =~ /The Quintet/, 'exactly 5 collaborators is kept (the cut-off)');
ok($c && $names->($c) !~ /Six Of Us/,   '6 collaborators is dropped');
ok($c && $names->($c) !~ /Avenue A/,    'a target already listed as a band is not repeated');
ok($c && scalar(grep { $_->{name} =~ /Brokeoffs/ } @$c) == 1, 'a duplicate relation is listed once');
ok(scalar($c && !(grep { !$_->{mbid} } @$c)), 'every collaboration carries its mbid (the drill enters by it)');

# ---------------------------------------------------------------------------
# 2. Cost and caching.
# ---------------------------------------------------------------------------
@URLS = ();
warm($HOLLY);
ok(!@URLS, 'a second warm is a pure cache hit: no requests');

%CACHE = (); @URLS = ();
warm('solo');
ok(ref $API->peekCollabs('solo') eq 'ARRAY' && !@{ $API->peekCollabs('solo') },
   'an artist with no collaboration links caches an empty list');
ok(scalar(@URLS) == 1, '... and costs no request beyond the one it already made');

# A warm band list with no collaboration entry (a pre-upgrade cache) must not
# keep the collaborations from ever being fetched.
%CACHE = ();
warm($HOLLY);
# ANCHOR THE PREFIX. `/collab/` also matches `dsc:collabcand:v1:`, and Perl
# randomises hash key order per process, so this picked the candidate key on
# roughly half of all runs and then asserted against the wrong one — a suite
# that failed 6 times in 10 and still went green through a build gate
# (2026-09-20).
my ($collabKey) = grep { /^dsc:collabs:/ } keys %CACHE;
delete $CACHE{$collabKey} if $collabKey;
@URLS = ();
warm($HOLLY);
ok($collabKey && $CACHE{$collabKey}, 'a cached band list alone does not stop the collaborations being fetched');

# ---------------------------------------------------------------------------
# 3. A failed vetting request caches NOTHING for collaborations (retried next
#    visit) — a blip must not hide a real collaboration for a fortnight.
# ---------------------------------------------------------------------------
%CACHE = ();
%FAIL = ('/artist/brokeoffs?' => 1);
$cbs = warm($HOLLY);
ok($cbs == 1, 'a vetting failure still calls back exactly once');
ok(!defined $API->peekCollabs($HOLLY), '... and leaves the collaborations uncached');
ok($names->($API->peekBands($HOLLY)) eq 'Avenue A,Thee Headcoatees', '... while the bands are cached as usual');
%FAIL = ();

# ---------------------------------------------------------------------------
# 4. Refresh clears it.
# ---------------------------------------------------------------------------
%CACHE = ();
warm($HOLLY);
$API->clearArtistCache(mbid => $HOLLY);
ok(!defined $API->peekCollabs($HOLLY), 'clearArtistCache removes the collaborations too');

# ---------------------------------------------------------------------------
# 5. MUSICBRAINZ ETIQUETTE (review 2026-09-19). Against the PUBLIC API every
#    request in the vetting chain must be spaced, not just the first of each
#    candidate: the release-group count used to follow its own artist-rels
#    response immediately, i.e. two requests back to back. A 503 there caches
#    nothing, and since the warm needs BOTH keys the whole vet re-runs on every
#    render. On a mirror the gap is 0 and nothing waits.
# ---------------------------------------------------------------------------
{
    local $BASE = 'https://musicbrainz.org/ws/2/';
    %CACHE = (); @URLS = (); @EV = ();
    warm($HOLLY);
    # The band lookup itself opens the chain; everything after it must wait.
    my @after = @EV[1 .. $#EV];
    my $back2back = 0;
    for my $i (1 .. $#after) {
        $back2back++ if $after[$i] eq 'get' && $after[$i - 1] eq 'get';
    }
    ok(scalar(@URLS) > 3, 'public API: the vetting chain really ran');
    ok($back2back == 0, 'public API: no two MusicBrainz requests go out back to back');
    ok(scalar($after[0] eq 'wait'), '... including the first vetting request after the band lookup');
}
{
    %CACHE = (); @EV = ();
    warm($HOLLY);
    ok(scalar(!grep { $_ eq 'wait' } @EV), 'a mirror still waits for nothing');
}

# ---------------------------------------------------------------------------
# 5b. THE GAP IS SCHEDULED AGAINST THE HI-RES CLOCK (review 2026-09-20).
#     Slim::Utils::Timers::_makeTimer does `EV::timer($when - EV::now, ...)`,
#     and EV::now is a hi-res epoch. A deadline built from CORE time(), which
#     truncates to the whole second, therefore fires after `1.1 - frac(now)` —
#     under one second nine times in ten, which is exactly the MB etiquette
#     limit the gap exists to respect. Pacing that quietly does not pace is
#     worse than none, because the 503 it earns caches nothing and the whole
#     vet re-runs on the next render.
#
#     Deterministic by construction: spin (bounded, < 1s, once) until the
#     clock is at least half a second past the whole second, so a truncated
#     base is off by more than half a second and a hi-res one by ~0.
# ---------------------------------------------------------------------------
{
    local $BASE = 'https://musicbrainz.org/ws/2/';
    my $gap = $API->mbGap(1.1);
    ok(scalar($gap == 1.1), 'public API: the courtesy gap is 1.1s');

    # Bounded by the WALL CLOCK, not an iteration count: within one second the
    # fraction must cross 0.5, and a fast machine must not spin out early and
    # weaken the check.
    my $stop = Time::HiRes::time() + 1.2;
    1 while Time::HiRes::time() < $stop
         && (Time::HiRes::time() - int(Time::HiRes::time())) < 0.5;

    %CACHE = (); @URLS = (); @EV = (); @WHEN = ();
    my $t0 = Time::HiRes::time();
    warm($HOLLY);

    ok(scalar(@WHEN > 0), 'public API: a deadline was actually scheduled');
    my $drift = @WHEN ? abs($WHEN[0] - $gap - $t0) : 99;
    ok(scalar($drift < 0.25),
       sprintf('the deadline is built on the HI-RES clock: it lands %.3fs from now+gap (a truncated time() would sit %.3fs short)',
               $drift, $t0 - int($t0)));
}

# ---------------------------------------------------------------------------
# 6. THE VETTING MUST NOT GATE THE FIRST RENDER (review 2026-09-19).
#    warmBandMembers sits in the serial MB chain AHEAD of the bootleg pass, and
#    the render waits on that pass under OFFICIAL_WAIT_DEFAULT (15s). Vetting 8
#    candidates is up to 8 x 2 x 1.1s = 17.6s against the public API, i.e. the
#    deadline fires and the page renders with no official map — bootlegs
#    unfiltered. So the band lookup must call back on its OWN request, and the
#    vetting runs at the END of the chain (warmCollaborations), after the pass.
# ---------------------------------------------------------------------------
{
    local $BASE = 'https://musicbrainz.org/ws/2/';
    %CACHE = (); @URLS = ();
    my $n = 0;
    $API->warmBandMembers($HOLLY, sub { $n++ });
    ok($n == 1, 'the band lookup calls back');
    ok(scalar(@URLS) == 1, '... after ONE request: the vetting does not gate the render');
    ok($API->peekBands($HOLLY), '... with the bands cached');
    ok(!defined $API->peekCollabs($HOLLY), '... and the collaborations not yet decided');

    $API->warmCollaborations($HOLLY);
    my $c = $API->peekCollabs($HOLLY);
    # The same survivors as §1: the Brokeoffs and the 5-collaborator boundary
    # case, with every filtered target still filtered.
    ok(scalar($c && $names->($c) eq 'Holly Golightly and The Brokeoffs,The Quintet'),
       'the end-of-chain warm vets them (same result as before)');
    ok(scalar(@URLS) > 1, '... and that is where the extra requests happen');

    # It must not re-fetch the relations to find the candidates again.
    %CACHE = (); @URLS = ();
    $API->warmBandMembers($HOLLY, sub {});
    my $afterBands = scalar @URLS;
    $API->warmCollaborations($HOLLY);
    my $vetUrls = scalar(@URLS) - $afterBands;
    ok(scalar(!grep { m{/artist/\Q$HOLLY\E\?} } @URLS[$afterBands .. $#URLS]),
       'the vetting re-uses the candidates the band lookup already found');

    # A second pass is a cache hit, and an artist whose vetting already ran
    # never pays again.
    @URLS = ();
    $API->warmCollaborations($HOLLY);
    ok(!@URLS, 'a vetted artist costs nothing on the next render');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
