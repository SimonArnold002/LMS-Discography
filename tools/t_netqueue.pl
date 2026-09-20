#!/usr/bin/env perl
#
# REGRESSION TEST — THE ONE OUTBOUND REQUEST QUEUE (_netGet, 0.51.17).
#
# WHAT WENT WRONG. `_mbGap` decided pacing from the CONFIGURED BASE, so on a
# mirror install it returned 0 — and the four paths that deliberately retry a
# zero-result mirror search against the PUBLIC host (_artistMbidByName,
# getArtistCandidates) sent to musicbrainz.org with no gap, no backoff and no
# queue. MusicBrainz's ~1 req/s is per IP and refuses EVERY request above it,
# so those retries were the one part of this plugin that could earn a 503.
#
# The decision is now made on the URL. This drives the REAL subs out of the
# shipped API.pm against a FAKE CLOCK, so nothing here waits and nothing is
# sent anywhere.
#
# Standalone -- no LMS install needed:  perl tools/t_netqueue.pl
#
use strict;
use warnings;
use FindBin;

our $now = 1_000_000.0;
our (@TIMERS, @SENT);

# LOAD Time::HiRes BEFORE replacing its clock — a later `use Time::HiRes ()`
# (API.pm has one) would otherwise quietly reinstate the real one, and every
# timing assertion below would then measure the wall clock. LBF's t_mbqueue
# carries the same warning; it is the whole reason this suite can be exact.
use Time::HiRes ();
BEGIN { no warnings 'redefine'; *Time::HiRes::time = sub () { $main::now } }

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers
                  Slim::Networking::SimpleAsyncHTTP Slim::Utils::Strings
                  Slim::Control::Request Slim::Schema
                  JSON::XS::VersionOneAndTwo Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}          = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Utils::Strings::cstring'}     = sub { $_[1] };
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { '' };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { {} };
    # Timers are RECORDED, never run: the test advances the clock itself.
    *{'Slim::Utils::Timers::setTimer'}     = sub { my $t = [@_]; push @main::TIMERS, $t; $t };
    *{'Slim::Utils::Timers::killSpecific'} = sub {
        my ($t) = @_; @main::TIMERS = grep { $_ != $t } @main::TIMERS; 1 };
    *{'Slim::Utils::Timers::killTimers'}   = sub { 1 };
    # One recorded request per ->get, with its callbacks held for the test to fire.
    *{'Slim::Networking::SimpleAsyncHTTP::new'} = sub {
        my ($cls, $cb, $errcb, $opt) = @_;
        return bless { cb => $cb, err => $errcb, opt => $opt }, 'T::HTTP';
    };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings
                  JSON::XS::VersionOneAndTwo)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');
    @{'JSON::XS::VersionOneAndTwo::EXPORT'} = qw(to_json from_json);
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::HTTP;
sub get { my ($s, $url) = @_; $s->{url} = $url; push @main::SENT, $s; return $s }
sub code  { return $_[0]{code}  // 0 }
sub error { return $_[0]{error} // '' }
package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::API;
my $A = 'Plugins::Discography::API';

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

my $GAP = $A->can('NET_GAP_MB')->();
my $PAD = $A->can('NET_WATCHDOG_PAD')->();
my $B0  = $A->can('NET_BACKOFF_START')->();
my $BMX = $A->can('NET_BACKOFF_MAX')->();
my $get = $A->can('_netGet') or die "no _netGet\n";

sub reset_all {
    @TIMERS = (); @SENT = (); $now = 1_000_000.0;
    %Plugins::Discography::API::NET = (
        mb => { gap => $GAP, queue => [], inflight => 0, nextAt => 0,
                timer => undef, busyUntil => 0, delay => 0, pumping => 0, repump => 0 },
    );
}
sub bucket { return $Plugins::Discography::API::NET{mb} }
# Fire every timer due at or before $to, advancing the clock as each fires.
sub advance {
    my ($to) = @_;
    my $n = 0;
    while (1) {
        @TIMERS = sort { $a->[1] <=> $b->[1] } @TIMERS;
        last unless @TIMERS && $TIMERS[0][1] <= $to;
        die "timer spin\n" if ++$n > 1000;
        my $t = shift @TIMERS;
        $now = $t->[1] if $t->[1] > $now;
        next unless ref $t->[2] eq 'CODE';
        $t->[2]->($t->[0], @{$t}[3 .. $#$t]);
    }
    $now = $to if $to > $now;
}
# NEVER DIE ON A MISSING REQUEST. Under a broken queue the expected request is
# exactly what is absent, and a die here takes every later assertion with it —
# the fleet's ok()-must-not-die rule applied to the helpers. Anti-testing this
# suite is what surfaced it: a mutant aborted at the first divergence and hid
# the four assertions that would have named the cause.
sub finish {
    my ($r) = @_;
    return ok(0, 'expected a request to complete, but none was sent') unless ref $r;
    $r->{cb}->($r);
}
sub failWith {
    my ($r, $code) = @_;
    return ok(0, "expected a request to fail with $code, but none was sent") unless ref $r;
    $r->{code} = $code; $r->{error} = "HTTP $code";
    $r->{err}->($r, "HTTP $code");
}

my $MIRROR = 'http://mirror:5000/ws/2/';
my $PUBLIC = 'https://musicbrainz.org/ws/2/';

# ---------------------------------------------------------------------------
# 1. THE DECISION IS ON THE URL, NOT THE CONFIGURED BASE. This is the whole
#    defect: a mirror install paced nothing, so its public retries went out raw.
# ---------------------------------------------------------------------------
ok(scalar(!defined $A->can('_netBucket')->($MIRROR . 'artist/x')),
   'a mirror url has no bucket');
ok(scalar(($A->can('_netBucket')->($PUBLIC . 'artist/x') // '') eq 'mb'),
   'a public musicbrainz.org url does');
ok(scalar(($A->can('_netBucket')->('https://beta.musicbrainz.org/ws/2/x') // '') eq 'mb'),
   '... including its subdomains');
ok(scalar(!defined $A->can('_netBucket')->('https://coverartarchive.org/x')),
   '... and another host is left alone');

# ---------------------------------------------------------------------------
# 2. A MIRROR IS NEVER QUEUED, and never waits behind a public request.
# ---------------------------------------------------------------------------
reset_all();
$get->($PUBLIC . 'artist/1', sub {}, sub {});
$get->($MIRROR . 'artist/2', sub {}, sub {});
ok(scalar(@SENT == 2), 'a mirror request goes out beside an in-flight public one');
ok(scalar($SENT[1]{url} =~ /mirror/), '... and it is the mirror that went second, unqueued');
ok(scalar(bucket()->{inflight} == 1), '... the public slot is still held by the first');

# ---------------------------------------------------------------------------
# 3. ONE IN FLIGHT, AND THE GAP IS FROM THE PREVIOUS SEND.
# ---------------------------------------------------------------------------
reset_all();
$get->($PUBLIC . 'a', sub {}, sub {});
$get->($PUBLIC . 'b', sub {}, sub {});
ok(scalar(@SENT == 1), 'the second public request waits: one in flight at a time');
finish($SENT[0]);
ok(scalar(@SENT == 1), '... and is still held by the gap after the first completes');
advance($now + $GAP);
ok(scalar(@SENT == 2 && $SENT[1]{url} =~ /b$/), "... released $GAP" . 's after the first was SENT');

# ---------------------------------------------------------------------------
# 4. THE SHARED BACKOFF. A 503 is noted by the QUEUE, once, and doubles to a
#    cap; a success resets it. Callers must never note it themselves or one
#    refusal would double the curve twice.
# ---------------------------------------------------------------------------
reset_all();
$get->($PUBLIC . 'a', sub {}, sub {});
failWith($SENT[0], 503);
ok(scalar(bucket()->{delay} == $B0), "a 503 starts the backoff at ${B0}s");
ok(scalar(bucket()->{busyUntil} > $now), '... and holds the queue');
$get->($PUBLIC . 'b', sub {}, sub {});
ok(scalar(@SENT == 1), '... nothing is sent while it is in force');
advance($now + $B0);
ok(scalar(@SENT == 2), '... and the queue resumes when it expires');
failWith($SENT[1], 503);
ok(scalar(bucket()->{delay} == $B0 * 2), '... a second refusal doubles it');
my $spins = 0;
while (bucket()->{delay} < $BMX && $spins++ < 20) {
    advance(bucket()->{busyUntil});
    $get->($PUBLIC . "x$spins", sub {}, sub {});
    failWith($SENT[-1], 503);
}
ok(scalar(bucket()->{delay} == $BMX), "... and is capped at ${BMX}s");
advance(bucket()->{busyUntil});
$get->($PUBLIC . 'good', sub {}, sub {});
finish($SENT[-1]);
ok(scalar(bucket()->{delay} == 0), 'a success resets the backoff');

# ---------------------------------------------------------------------------
# 5. EVERY DEADLINE IS ON THE HI-RES CLOCK. Core time() truncates to the whole
#    second, so a deadline built from it fires up to a second early — the
#    0.51.16 bug, and the one LBF's own _mbNoteLimit still has. The fake clock
#    sits at a known fraction, so a truncated base would be visible here.
# ---------------------------------------------------------------------------
reset_all();
$now = 1_000_000.75;
$get->($PUBLIC . 'a', sub {}, sub {});
failWith($SENT[0], 503);
ok(scalar(abs(bucket()->{busyUntil} - ($now + $B0)) < 0.0001),
   'the backoff deadline keeps the sub-second fraction (not truncated)');
reset_all();
$now = 1_000_000.75;
$get->($PUBLIC . 'a', sub {}, sub {});
$get->($PUBLIC . 'b', sub {}, sub {});
finish($SENT[0]);
my ($pumpTimer) = grep { abs($_->[1] - ($now + $GAP)) < 0.0001 } @TIMERS;
ok(scalar($pumpTimer), 'the gap deadline keeps it too');

# ---------------------------------------------------------------------------
# 6. A LOST CALLBACK MUST NOT WEDGE THE QUEUE FOR THE LIFE OF THE PROCESS.
# ---------------------------------------------------------------------------
reset_all();
my $errs = 0;
$get->($PUBLIC . 'a', sub {}, sub { $errs++ }, timeout => 12);
ok(scalar(bucket()->{inflight} == 1), 'a request holds the slot');
advance($now + 12 + $PAD + 0.01);
ok(scalar($errs == 1), 'the watchdog reports the failure to the caller');
ok(scalar(bucket()->{inflight} == 0), '... and frees the slot');

# ---------------------------------------------------------------------------
# 7. RE-ENTRY. A callback that queues the next request — which is how every
#    paginated walk in this plugin works — must not strand the queue.
# ---------------------------------------------------------------------------
reset_all();
my $chain = 0;
my $step; $step = sub {
    return if ++$chain >= 3;
    $get->($PUBLIC . "p$chain", sub { $step->() }, sub {});
};
$get->($PUBLIC . 'p0', sub { $step->() }, sub {});
for my $i (1 .. 4) { finish($SENT[-1]) if @SENT; advance($now + $GAP) }
ok(scalar(@SENT == 3), 'a callback that queues the next request keeps the queue moving');
ok(scalar(bucket()->{pumping} == 0), '... and leaves no pump guard set');

# ---------------------------------------------------------------------------
# 8. CONTROL: an unbucketed url is not affected by a public backoff at all.
# ---------------------------------------------------------------------------
reset_all();
$get->($PUBLIC . 'a', sub {}, sub {});
failWith($SENT[0], 503);
my $before = scalar @SENT;
$get->($MIRROR . 'z', sub {}, sub {});
ok(scalar(@SENT == $before + 1), 'the mirror still sends while public is backed off');

# ---------------------------------------------------------------------------
# 9. NOTHING BYPASSES THE DOOR. A stub can only prove what the code DOES; the
#    rule this queue exists to enforce is about what no code may do — build its
#    own transport to MusicBrainz, where the queue cannot see it. That is a
#    property of the SOURCE, and it is how the defect got in: four public
#    retries written as bare ->get() calls, each correct-looking in isolation.
#    _netSend is the one permitted builder.
# ---------------------------------------------------------------------------
{
    open my $fh, '<', "$FindBin::Bin/../Discography/API.pm" or die $!;
    my $src = do { local $/; <$fh> };
    my @subs = $src =~ /^sub (\w+) \{/mg;
    my @builders;
    for my $name (@subs) {
        my ($body) = $src =~ /^(sub \Q$name\E \{.*?^\})/ms or next;
        push @builders, $name if $body =~ /SimpleAsyncHTTP->new/;
    }
    ok(scalar(join(',', sort @builders) eq '_netSend'),
       'API.pm builds a transport in _netSend and nowhere else'
       . (@builders > 1 ? ' (found: ' . join(', ', sort @builders) . ')' : ''));
    # COMMENTS ARE NOT CODE. The first cut of this matched the sentence in
    # _netGet's own header that tells you how to convert a call site, and
    # reported the documentation as a violation.
    (my $code = $src) =~ s/^\s*#.*$//mg;
    ok(scalar($code !~ /\)->get\(/),
       'no `)->get(` call site is left outside the queue');

    # Browse.pm keeps ONE transport of its own on purpose: the Deezer CDN
    # placeholder probe, which needs `maxRedirect => 0` and a HEAD, neither of
    # which the queue offers — and which never touches MusicBrainz.
    open my $bh, '<', "$FindBin::Bin/../Discography/Browse.pm" or die $!;
    my $browse = do { local $/; <$bh> };
    my @bsubs = $browse =~ /^sub (\w+) \{/mg;
    my @bbuild;
    for my $name (@bsubs) {
        my ($body) = $browse =~ /^(sub \Q$name\E \{.*?^\})/ms or next;
        push @bbuild, $name if $body =~ /SimpleAsyncHTTP->new/;
    }
    ok(scalar(join(',', sort @bbuild) eq '_probeArtistImage'),
       'Browse.pm builds a transport only for the image probe'
       . (@bbuild ? ' (found: ' . join(', ', sort @bbuild) . ')' : ''));
    my ($probe) = $browse =~ /^(sub _probeArtistImage \{.*?^\})/ms;
    ok(scalar($probe && $probe !~ /musicbrainz/i),
       '... and that probe never reaches MusicBrainz');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
