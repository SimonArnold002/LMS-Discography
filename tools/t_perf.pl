#!/usr/bin/env perl
#
# REGRESSION TEST — the cold render stops paying for work it does not owe.
#
# MEASURED 2026-07-21 on the live box, cold Jamie Cullum, 2.32s total:
#
#     RG spine (1 page)                    80ms
#     targeted local release lookups      150ms
#     warmBandMembers                     240ms
#     _warmArtistExtras (MAI -> Last.fm) 1130ms   <-- 49%, and NOT MusicBrainz
#     warmOfficial (2 pages)              715ms
#
# The chain warmLocalReleases -> warmBandMembers -> _warmArtistExtras ->
# warmOfficial is SERIAL to respect MusicBrainz's 1 req/s etiquette. But the
# extras leg is MAI/Last.fm, so it was paying an etiquette tax it does not owe
# and gating half the render behind it.
#
# Second finding, same measurement: `getArtistCandidates` was fetched TWICE per
# cold artist. Proven, not inferred — the sub only logs inside its HTTP
# callback, and the line appears twice ~4ms apart (Radiohead 10.6165/10.6183,
# Cullum 00.4670/00.4715). Two callers race before either caches: the bio
# guard, and the candidate warm.
#
# THE TWO FIXES ARE COUPLED, and that is the interesting part. Moving the
# extras leg earlier means its shared-name guard reads a cache the bio path had
# previously warmed for it — a COLD peek answers "not shared", which is exactly
# the 0.44.5 bug (the prominent act's biography under a secondary act's name).
# So the guard becomes ASYNC, which would add a request — except the in-flight
# dedupe makes it free. Neither fix is safe alone.
#
# Standalone -- no LMS install needed:  perl tools/t_perf.pl
#
use strict;
use warnings;
use FindBin;

my %CACHE;
my $DATA;
my @QUERIES;
our @DEFERRED;      # HTTP callbacks held open, so "in flight" is real here

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::Timers Slim::Networking::SimpleAsyncHTTP
                  Slim::Utils::Strings Slim::Utils::PluginManager
                  Slim::Control::Request Slim::Schema Slim::Web::HTTP
                  Slim::Utils::Misc Slim::Menu::GlobalSearch
                  Slim::Plugin::OPMLBased
                  JSON::XS::VersionOneAndTwo Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}          = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Cache' };
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Utils::Strings::cstring'} = sub { $_[1] };
    *{'Slim::Utils::Strings::string'}  = sub { $_[0] };
    push @{'Slim::Utils::Strings::ISA'}, 'Exporter';
    @{'Slim::Utils::Strings::EXPORT'} = qw(cstring string);
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { '' };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { $DATA };
    *{'Slim::Networking::SimpleAsyncHTTP::new'} = sub {
        my ($cls, $cb, $errcb) = @_;
        return bless { cb => $cb, err => $errcb }, 'T::HTTP';
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
sub get { return $CACHE{ $_[1] } }
sub set { $CACHE{ $_[1] } = $_[2]; return 1 }
sub remove { delete $CACHE{ $_[1] }; return 1 }
package T::Prefs;
sub get { return $_[1] eq 'mb_base_url' ? 'http://mirror:5000/ws/2/' : undef }
sub set { 1 } sub init { 1 } sub setChange { 1 }
package T::Resp;
sub new { bless {}, shift } sub content { '{}' } sub error { 'stub' }
package T::HTTP;
sub get {
    my ($self, $url) = @_;
    push @QUERIES, $url;
    # Hold the response open so a second caller genuinely arrives mid-flight —
    # answering synchronously would cache the result first and the dedupe would
    # never be exercised at all.
    push @main::DEFERRED, sub { $DATA = main::response_for($url); $self->{cb}->(T::Resp->new) };
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

# Two MB artists share the name, so the shared-name decision has real content.
my $PROMINENT = 'aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa';
my $SECONDARY = 'bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb';
sub response_for {
    return { artists => [
        { id => $PROMINENT, name => 'Madness', score => 100 },
        { id => $SECONDARY, name => 'Madness', score => 70  },
    ] };
}
# Drain REPEATEDLY: a mirror error legitimately retries against the public API,
# which queues another deferred call. Draining one snapshot leaves that retry
# unfired and the caller unanswered — which looked exactly like the hung-render
# bug being tested for, in the harness rather than the code.
sub flush {
    for (1 .. 10) {
        my @d = @main::DEFERRED;
        last unless @d;
        @main::DEFERRED = ();
        $_->() for @d;
    }
}

# ---------------------------------------------------------------------------
# 1. ONE FETCH PER NAME, however many callers ask at once.
# ---------------------------------------------------------------------------
%CACHE = (); @QUERIES = (); @DEFERRED = ();
my (@gotA, @gotB);
$API->getArtistCandidates('Madness', sub { push @gotA, $_[0] });
$API->getArtistCandidates('Madness', sub { push @gotB, $_[0] });
ok(scalar(@QUERIES) == 1, 'a second caller mid-flight issues NO second request');
flush();
ok(scalar(@gotA) == 1 && scalar(@gotB) == 1, 'both callers are answered');

# THE POINT: the queued caller must get the REAL list. Answering it empty (the
# house in-flight pattern for optional warms) would tell the bio guard "no
# same-name act", which is the 0.44.5 leak wearing a new hat.
ok(ref $gotB[0] eq 'ARRAY' && scalar(@{ $gotB[0] }) == 2,
   'the QUEUED caller gets the real candidate set, not an empty one');
ok(ref $gotA[0] eq 'ARRAY' && scalar(@{ $gotA[0] }) == 2, '... as does the first');

# Warm cache: no request, and no queue left behind.
@QUERIES = ();
my $warm;
$API->getArtistCandidates('Madness', sub { $warm = $_[0] });
ok(scalar(@QUERIES) == 0, 'a warm cache costs no request');
ok(ref $warm eq 'ARRAY' && scalar(@$warm) == 2, '... and still answers in full');

# A THIRD round after everything settled must fetch again if the cache is
# cleared — i.e. the in-flight marker was released, not left pinned. A stuck
# marker would silently wedge the name forever.
%CACHE = (); @QUERIES = (); @DEFERRED = ();
my $again;
$API->getArtistCandidates('Madness', sub { $again = $_[0] });
ok(scalar(@QUERIES) == 1, 'the in-flight marker is released after settling');
flush();
ok(ref $again eq 'ARRAY' && scalar(@$again) == 2, '... and the refetch answers');

# Different names must not share a queue.
%CACHE = (); @QUERIES = (); @DEFERRED = ();
$API->getArtistCandidates('Madness', sub {});
$API->getArtistCandidates('Genesis', sub {});
ok(scalar(@QUERIES) == 2, 'two different names are two different fetches');
flush();

# ---------------------------------------------------------------------------
# 2. AN HTTP FAILURE MUST SETTLE EVERY WAITER — a queue that is only drained on
#    success would hang the bio leg forever, and the render waits on it.
# ---------------------------------------------------------------------------
{
    %CACHE = (); @QUERIES = (); @DEFERRED = ();
    no warnings 'redefine';
    local *T::HTTP::get = sub {
        my ($self, $url) = @_;
        push @QUERIES, $url;
        push @main::DEFERRED, sub { $self->{err}->(T::Resp->new) };
    };
    my ($e1, $e2) = ('UNSET', 'UNSET');
    $API->getArtistCandidates('Madness', sub { $e1 = $_[0] });
    $API->getArtistCandidates('Madness', sub { $e2 = $_[0] });
    flush();
    ok(ref $e1 eq 'ARRAY', 'an HTTP error settles the first caller');
    ok(ref $e2 eq 'ARRAY', '... and every queued caller too (no hung render)');
    ok(!defined $CACHE{'dsc:acand:7:madness'} || !@{ $CACHE{'dsc:acand:7:madness'} },
       'a failure is not cached as "no such artist"');
}

# ---------------------------------------------------------------------------
# 3. THE SHARED-NAME DECISION IS UNCHANGED BY ANY OF THIS. The async guard is
#    what lets the extras leg move off the MusicBrainz chain, so it has to keep
#    answering exactly as it did.
# ---------------------------------------------------------------------------
%CACHE = (); @DEFERRED = ();
my $sharedSecondary = 'UNSET';
$API->sharesNameWithProminentAsync('Madness', $SECONDARY, sub { $sharedSecondary = $_[0] });
flush();
ok(scalar($sharedSecondary), 'a SECONDARY same-name act is flagged as sharing');

my $sharedTop = 'UNSET';
$API->sharesNameWithProminentAsync('Madness', $PROMINENT, sub { $sharedTop = $_[0] });
ok(!$sharedTop, 'the PROMINENT act itself is never flagged');

# And it must not need its own request once the warm has run.
@QUERIES = ();
$API->sharesNameWithProminentAsync('Madness', $SECONDARY, sub {});
ok(scalar(@QUERIES) == 0, 'the guard is free once the candidate set is cached');

# ---------------------------------------------------------------------------
# 4. THE TRAP THE SPEED-UP COULD HAVE SPRUNG. _warmArtistExtras moved OFF the
#    MusicBrainz chain, so its shared-name guard no longer runs after the bio
#    path has warmed the same-name set — it runs against a COLD cache. A sync
#    peek answers "not shared" when cold, which would warm (and cache, by mbid)
#    the PROMINENT act's similar artists under a secondary act's key: 0.44.5,
#    re-created by a change that never touched it.
# ---------------------------------------------------------------------------
require Plugins::Discography::Browse;
my @WARMED;
{
    no warnings 'redefine', 'once';
    *Plugins::Discography::Browse::_warmSimilarArtists = sub {
        my ($client, $mbid, $artist, $cb) = @_;
        push @WARMED, $mbid;
        $cb->();
    };
}
my $extras = \&Plugins::Discography::Browse::_warmArtistExtras;

# COLD cache, secondary act: must NOT warm.
%CACHE = (); @DEFERRED = (); @WARMED = ();
my $done = 0;
$extras->('client', $SECONDARY, 'Madness', sub { $done = 1 });
flush();
ok(scalar(@WARMED) == 0,
   'a shared-name act is not warmed even when the guard cache is COLD');
ok(scalar($done), '... and the leg still settles (the render waits on it)');

# COLD cache, the prominent act: must warm normally.
%CACHE = (); @DEFERRED = (); @WARMED = (); $done = 0;
$extras->('client', $PROMINENT, 'Madness', sub { $done = 1 });
flush();
ok(scalar(@WARMED) == 1 && $WARMED[0] eq $PROMINENT,
   'the prominent act IS warmed from cold');
ok(scalar($done), '... and settles too');

# No client (a background/CLI path): settles immediately, warms nothing.
@WARMED = (); $done = 0;
$extras->(undef, $PROMINENT, 'Madness', sub { $done = 1 });
ok(scalar($done) && scalar(@WARMED) == 0, 'no client -> settles without warming');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
