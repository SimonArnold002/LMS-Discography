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
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Cache' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { '' };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { $main::DATA };
    *{'Slim::Networking::SimpleAsyncHTTP::new'} = sub {
        my ($cls, $cb, $errcb, $opt) = @_;
        return bless { cb => $cb, err => $errcb }, 'T::HTTP';
    };
    # Fires immediately. Nothing in this suite depends on a real delay.
    *{'Slim::Utils::Timers::setTimer'} = sub {
        my (undef, $when, $cb) = @_;
        push @main::WHEN, $when;
        return $cb->();
    };
    *{'Slim::Utils::Timers::killSpecific'} = sub { 1 };
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
    # The band lookup reads the artist WITH its aliases since stage 1, and its
    # release groups since stage 2 (`?inc=aliases+artist-rels+release-groups`,
    # shared with warmArtistAliases — see t_artistread.pl); the vetting reads
    # each target's relations.
    if ($url =~ m{/artist/([^?]+)\?inc=(?:aliases\+)?artist-rels}) {
        my $id = $1;
        if (my $rels = $ARTIST{$id}) {
            return { name => 'X', relations => [ map {
                { type => $_->[0], direction => 'forward',
                  artist => { id => $_->[1], name => $NAME{ $_->[1] } } } } @$rels ] };
        }
        my $t = $T{$id} or return { relations => [], 'release-groups' => [] };
        return { name => $t->[0], relations => [
            (map { { type => 'collaboration', direction => 'backward',
                     artist => { id => "p$_", name => "P$_" } } } 1 .. $t->[1]),
            { type => 'collaboration', direction => 'forward',       # ignored
              artist => { id => 'x', name => 'x' } } ],
            # The vetting lookup (`?inc=artist-rels+release-groups`, stage 1)
            # carries the target's release groups in the SAME reply, in MB's
            # shape (captured from the public API 2026-09-29: Fripp & Eno 11,
            # Harmonia 76 2, N.M.L. 1, the Shostakovich Trio `[]`): a list, empty
            # for an act with none, stopping at 25. $NOLIST drops it, as a
            # malformed reply would.
            # Like MB, only when `inc=` asks for them.
            (($main::NOLIST{$id} || $url !~ /[?&]inc=[^&]*release-groups/) ? () : ('release-groups' => [
                map { { id => "rg-$id-$_", title => "$t->[0] $_", 'primary-type' => 'Album' } }
                1 .. ($t->[2] > 25 ? 25 : $t->[2]) ])) };
    }
    if ($url =~ m{release-group\?artist=([^&]+)}) {
        # The vetting no longer asks for a count (stage 1). Answered 0 for
        # every target ON PURPOSE: any code still reading it would drop the
        # Brokeoffs, and section 1 would go red.
        return { 'release-group-count' => 0 };
    }
    return {};
}
our %NOLIST;

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
# scalar(): a bare `=~` in ok()'s arguments returns its CAPTURES in list
# context, so this used to pass only when a comma followed the name (found by a
# mutant of the size cut-off, 2026-09-29).
ok(scalar($c && $names->($c) =~ /^Holly Golightly and The Brokeoffs(,|$)/),
   'the Brokeoffs are listed as a collaboration');
ok($c && $names->($c) !~ /Band Aid/, 'a charity supergroup (21 collaborators) is dropped');
ok($c && $names->($c) !~ /Amnesty/,  'a collaboration with no release groups is dropped');
ok(scalar($c && $names->($c) =~ /The Quintet/), 'exactly 5 collaborators is kept (the cut-off)');
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
# 5. THIS CHAIN DOES NOT BUILD ITS OWN TRANSPORT (0.51.17). Pacing used to live
#    here — a timer per request, sized by `mbGap` — and it was wrong twice: the
#    gap came from the CONFIGURED base, so a mirror install paced nothing even
#    on a public retry, and the deadline was built from core time(), which
#    truncates. Both are now the queue's job (`_netGet`, guarded by
#    tools/t_netqueue.pl, which owns the gap, the 503 backoff and the hi-res
#    deadlines). What is still THIS suite's business is that the vetting goes
#    through that door at all: a chain that builds its own SimpleAsyncHTTP
#    would be paced by nothing, and the queue could not see it.
#
#    Asserted on the SOURCE, because a stub cannot prove the absence of a call
#    the code never makes — and on the routing, by counting what _netGet saw.
# ---------------------------------------------------------------------------
{
    open my $fh, '<', "$FindBin::Bin/../Discography/API.pm" or die $!;
    my $src = do { local $/; <$fh> };
    my ($vet) = $src =~ /^(sub _vetCollabs \{.*?^\})/ms;
    ok(scalar($vet), '_vetCollabs found in the shipped source');
    ok(scalar($vet && $vet !~ /SimpleAsyncHTTP/),
       '... and it builds no transport of its own');
    ok(scalar($vet && $vet =~ /_netGet\(/),
       '... every request goes through the queue');
    # The band lookup's request is _readArtist's since stage 1 (shared with
    # the alias lookup), so that is where the door has to be.
    my ($warm) = $src =~ /^(sub warmBandMembers \{.*?^\})/ms;
    my ($read) = $src =~ /^(sub _readArtist \{.*?^\})/ms;
    ok(scalar($warm && $warm =~ /_readArtist\(/ && $warm !~ /SimpleAsyncHTTP/
              && $read && $read !~ /SimpleAsyncHTTP/ && $read =~ /_netGet\(/),
       'the band lookup goes through it too (via _readArtist)');
}
{
    # And the chain really does run end to end through the seam.
    %CACHE = (); @URLS = ();
    warm($HOLLY);
    ok(scalar(@URLS) > 3, 'the vetting chain really ran');
    ok(scalar(!grep { !m{^\Q$BASE\E} } @URLS),
       '... and every url it sent was built from the configured base');
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
    # The MIRROR base, deliberately. This section is about the ORDER of the
    # chain, not its pacing, and pacing now belongs to the queue: against the
    # public host the requests would be spread over real seconds by real
    # timers, which says nothing about ordering and makes the suite slow.
    # t_netqueue.pl owns the public-host behaviour, on a fake clock.
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

# ---------------------------------------------------------------------------
# 7. ONE REQUEST PER CANDIDATE (stage 1, 2026-09-29). The size test and the
#    "has any release group?" test are answered by ONE lookup,
#    `?inc=artist-rels+release-groups`; a candidate that passed the size test
#    used to pay a second request for a release-group count.
# ---------------------------------------------------------------------------
{
    %CACHE = (); @URLS = ();
    $API->warmBandMembers($HOLLY, sub {});
    my $afterBands = scalar @URLS;
    $API->warmCollaborations($HOLLY);
    my @vet = @URLS[$afterBands .. $#URLS];
    # Holly's five candidates: the Brokeoffs, Band Aid, Amnesty, the Quintet,
    # Six Of Us (Avenue A is a band, so never a candidate).
    ok(scalar(@vet) == 5, '7: five candidates, five requests (one each)');
    ok(scalar(!grep { !m{/artist/[^?]+\?inc=artist-rels\+release-groups&fmt=json$} } @vet),
       '7: ... every one the combined lookup');
    ok(scalar(!grep { m{release-group\?artist=} } @URLS),
       '7: ... and no release-group count is ever asked for');
    ok(scalar($names->($API->peekCollabs($HOLLY)) eq 'Holly Golightly and The Brokeoffs,The Quintet'),
       '7: ... with the same survivors as before');

    # A reply WITHOUT the list is malformed, so it is a failed lookup: nothing
    # cached, retried next visit. Read as "no release groups" it would drop a
    # real collaboration for 14 days.
    %CACHE = (); @URLS = ();
    local %NOLIST = (brokeoffs => 1);
    warm($HOLLY);
    ok(!defined $API->peekCollabs($HOLLY), '7: a reply with no release-group list caches nothing');
}
{
    # The count cache is no longer consulted: the lookup answers. A count of 0
    # cached earlier (by a search, say) does not drop a target whose lookup
    # lists release groups — the newer answer wins.
    %CACHE = (); @URLS = ();
    $API->warmBandMembers($HOLLY, sub {});
    $CACHE{'dsc:rgcount:1:brokeoffs'} = 0;
    $API->warmCollaborations($HOLLY);
    ok(scalar($names->($API->peekCollabs($HOLLY)) =~ /^Holly Golightly and The Brokeoffs/),
       '7: a stale cached count of 0 no longer decides; the lookup does');
    ok(($CACHE{'dsc:rgcount:1:brokeoffs'} // 'gone') eq '0' && !defined $CACHE{'dsc:rgcount:1:five'},
       '7: ... and the vetting writes no release-group count of its own');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
