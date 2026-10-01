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
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Null' }; $INC{'Plugins/Discography/DB.pm'} = 1;
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

# TWO OBJECTS, BECAUSE THE REAL CALLBACK GETS TWO. SimpleAsyncHTTP calls its
# error handler as ($self, $error, $response) — verified in the LMS 9.0 source
# and recorded in A3 — and the two carry DIFFERENT accessors. Modelling them as
# one object is what made the shed assertions vacuous: the fixture passed the
# same thing as both arguments, so code that read the wrong one still passed.
#
# T::HTTP is the ASYNC OBJECT. It answers ->error (every error handler in
# API.pm reads `shift->error`) and, on success, ->content. It does NOT answer
# ->header: whether the async object proxies the response's headers on the
# error path is undocumented and unverified, so nothing may depend on it.
package T::HTTP;
sub get { my ($s, $url, @h) = @_; $s->{url} = $url; $s->{headers} = { @h }; push @main::SENT, $s; return $s }
sub code    { return $_[0]{code}  // 0 }
sub error   { return $_[0]{error} // '' }
sub content { return $_[0]{body}  // '' }

# T::RESP is the HTTP::Response. It answers ->code, ->content and ->header, and
# deliberately has NO ->error — that accessor is the async object's, and a test
# that let this object answer it would hide the same class of mix-up.
package T::RESP;
sub new     { my ($c, %f) = @_; return bless { %f }, $c }
sub code    { return $_[0]{code} // 0 }
sub content { return $_[0]{body} // '' }
sub header  { return $_[0]{hdr}{ $_[1] } }
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

# Every bucket exactly as the module defines it, captured before any test runs,
# so a bucket added to API.pm (the community API's, stage 3 step 2) is reset too
# rather than autovivified half-formed by the first request that reaches it.
my %NET0 = map { $_ => { %{ $Plugins::Discography::API::NET{$_} } } }
           keys %Plugins::Discography::API::NET;
sub reset_all {
    @TIMERS = (); @SENT = (); $now = 1_000_000.0;
    %Plugins::Discography::API::NET = map { $_ => { %{ $NET0{$_} }, queue => [] } } keys %NET0;
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
    $r->{err}->($r, "HTTP $code", T::RESP->new(code => $code, hdr => {}));
}
# A SHED, verbatim off the wire (probed 2026-09-20). Note `Remaining` is well
# short of `Limit`: we were not over anything, their cluster was busy.
#
# THE SHED MARKERS GO ON THE RESPONSE ONLY, never on the async object. That is
# the whole discrimination: code that reads the shed off the wrong argument
# sees a bare 503 with no headers and no body, treats it as a refusal, and the
# backoff assertions in section 10 go red. The earlier fixture passed $r as
# both arguments, so it could not tell the two apart and the assertion that
# exists for exactly this case could never fail.
sub shedWith {
    my ($r, %o) = @_;
    return ok(0, 'expected a request to shed, but none was sent') unless ref $r;
    $r->{code}  = 503;
    $r->{error} = 'HTTP 503';
    my $resp = T::RESP->new(
        code => 503,
        body => '{"error": "The MusicBrainz web server is currently busy. Please try again later."}',
        hdr  => { 'X-RateLimit-Who' => 'search-shed', 'X-RateLimit-Zone' => 'search',
                  'X-RateLimit-Limit' => 1900, 'X-RateLimit-Remaining' => 269,
                  'Retry-After' => (defined $o{after} ? $o{after} : 0) },
    );
    $r->{err}->($r, 'HTTP 503', $resp);
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

# ---------------------------------------------------------------------------
# 10. A SHED IS RETRIED, NOT REPORTED, AND DOES NOT MOVE THE BACKOFF CURVE
#     (measured 2026-09-20). MusicBrainz answers a rate limit AND a busy search
#     cluster with the same 503; only the headers separate them. A shed carries
#     `X-RateLimit-Who: *-shed` and a Remaining well short of Limit — we were
#     not over anything. Probed from a cold IP: 4 sheds, all 4 recovered on the
#     FIRST retry 0.4s later, and one arrived after an 18.6s IDLE gap, which no
#     rate limiter could produce. Treating it as a limit stopped the queue for
#     5s escalating to 30 and failed the caller's request for nothing.
# ---------------------------------------------------------------------------
reset_all();
my $shedErr = 0;
$get->($PUBLIC . 'search1', sub {}, sub { $shedErr++ });
shedWith($SENT[0]);
ok(scalar($shedErr == 0), 'a shed is not reported to the caller');
ok(scalar(bucket()->{delay} == 0), '... and does not start the backoff curve');
ok(scalar(bucket()->{inflight} == 0), '... the slot is freed');
ok(scalar(@{ bucket()->{queue} } == 1), '... and the job is requeued, not dropped');
advance($now + 2);
ok(scalar(@SENT == 2 && $SENT[1]{url} =~ /search1$/), '... then sent again');
finish($SENT[1]);
ok(scalar($shedErr == 0 && bucket()->{delay} == 0),
   'a shed that succeeds on retry is invisible end to end');

# It is BOUNDED: a server that sheds for ever still fails the request.
reset_all();
my $errs2 = 0;
$get->($PUBLIC . 'sick', sub {}, sub { $errs2++ });
for my $i (1 .. 8) { shedWith($SENT[-1]) if @SENT; advance($now + 2) }
my $R = $A->can('NET_SHED_RETRIES')->();
ok(scalar($errs2 == 1), "an endless shed is reported once, after NET_SHED_RETRIES ($R)");
ok(scalar(@SENT == $R + 1), "... having been tried " . ($R + 1) . ' times in all');
ok(scalar(bucket()->{inflight} == 0), '... and the queue is left free, not wedged');
# The shed guard inside _netIsRateLimited is load-bearing ONLY here: while
# retries remain the shed branch returns before the backoff is ever consulted,
# so this is the one path that can move the curve. An anti-test caught this
# assertion missing.
ok(scalar(bucket()->{delay} == 0),
   '... and even an exhausted shed never moves the backoff curve');

# CONTROL: a real refusal still backs off exactly as before.
reset_all();
$get->($PUBLIC . 'a', sub {}, sub {});
failWith($SENT[0], 429);
ok(scalar(bucket()->{delay} == $B0), 'control: a 429 with no shed headers still backs off');
ok(scalar($A->can('_netIsShed')->(undef) == 0), 'control: nothing is not a shed');

# THE TWO SIGNALS ARE REDUNDANT ON PURPOSE — the header survives a change of
# wording, the body survives a change of header. The fixture above sets both,
# so it cannot tell which one fired: a mutant that deleted the header check
# passed it. Each is pinned alone here.
{
    my $isShed = $A->can('_netIsShed');
    my $hdrOnly  = T::RESP->new(code => 503, hdr => { 'X-RateLimit-Who' => 'search-shed' });
    my $bodyOnly = T::RESP->new(code => 503, hdr => {},
        body => '{"error": "The MusicBrainz web server is currently busy."}');
    my $plain503 = T::RESP->new(code => 503, hdr => {}, body => 'gateway error');
    ok(scalar($isShed->($hdrOnly)),  'the X-RateLimit-Who header alone identifies a shed');
    ok(scalar($isShed->($bodyOnly)), 'the "currently busy" body alone does too');
    ok(scalar(!$isShed->($plain503)), '... and an ordinary 503 is not one');

    # THE ARGUMENT-ORDER PIN. Both shed probes are variadic for a reason: the
    # markers are on the RESPONSE, and a reader handed only the async object
    # answers "not a shed" — silently, because the accessors are eval'd. That
    # is precisely what _netIsRateLimited did until 0.51.18, which let an
    # exhausted shed move the backoff curve. Asserted on the subs themselves,
    # so a future swap is named here rather than inferred from a stray delay.
    my $async = bless { code => 503, error => 'HTTP 503' }, 'T::HTTP';
    my $resp  = T::RESP->new(code => 503, hdr => { 'X-RateLimit-Who' => 'search-shed' });
    my $isLim = $A->can('_netIsRateLimited');
    ok(scalar(!$isShed->($async)), 'the async object alone carries no shed markers');
    ok(scalar($isShed->($resp, $async) && $isShed->($async, $resp)),
       '... so the response must be probed too, in either order');
    ok(scalar(!$isLim->($async, 'HTTP 503', $resp)),
       'a shed given the full callback arguments is never a rate limit');
    ok(scalar($isLim->($async, 'HTTP 503')),
       '... and WITHOUT the response it reads as one: why all three are passed');
}

# Retry-After is honoured as a floor when the server names one.
reset_all();
$get->($PUBLIC . 'later', sub {}, sub {});
shedWith($SENT[0], after => 4);
# PAST THE ORDINARY GAP, SHORT OF THE RETRY-AFTER. At +1s the 1.1s queue gap
# alone would still hold it, so the old probe there passed whether Retry-After
# was read or not — the mutant that ignored it survived.
advance($now + 2);
ok(scalar(@SENT == 1 && $GAP < 2),
   'a Retry-After of 4s holds the retry past the ordinary gap');
advance($now + 3);
ok(scalar(@SENT == 2), '... and releases it once it has passed');

# ---------------------------------------------------------------------------
# 13. THE COMMUNITY API'S BUCKET (stage 3 step 2). Its rate is OUR OWN, set from
#     how MAI uses the service (ledger A2 `THE COMMUNITY API IS ONE REQUEST AT A
#     TIME, MAI'S RATE`): one request in flight, no fixed gap, a shared 429
#     deadline 5 s doubling to 30. Every call carries the plugin id (the dev's
#     registration). A failFast job never waits out the deadline, and a timeout
#     backs the bucket off too.
# ---------------------------------------------------------------------------
{
    my $HOSTED = 'https://api.lms-community.org/music/';
    my $SLOW   = $A->can('NET_SLOW_BACKOFF')->();
    my $hbucket = sub { $Plugins::Discography::API::NET{hosted} };
    my $timeoutWith = sub {
        my ($r) = @_;
        return ok(0, 'expected a request to time out, but none was sent') unless ref $r;
        $r->{error} = 'Timed out waiting for data';
        $r->{err}->($r, 'Timed out waiting for data', T::RESP->new(code => 500, hdr => {}));
    };

    ok(scalar(($A->can('_netBucket')->($HOSTED . 'artist/x/discography') // '') eq 'hosted'),
       '13: a community-API url has its own bucket');

    reset_all();
    $get->($HOSTED . 'a', sub {}, sub {});
    $get->($PUBLIC . 'b', sub {}, sub {});
    ok(scalar(@SENT == 2), '13: the community API and MusicBrainz are sent side by side');
    ok(scalar(($SENT[0]{headers}{'X-LMS-Plugin-ID'} // '') eq 'Plugins::Discography::Plugin'),
       "13: a community-API call carries the plugin id (the dev's registration)");
    ok(scalar(!exists $SENT[1]{headers}{'X-LMS-Plugin-ID'}), '13: ... a MusicBrainz call does not');

    # One in flight, no gap.
    reset_all();
    $get->($HOSTED . 'a', sub {}, sub {});
    $get->($HOSTED . 'b', sub {}, sub {});
    ok(scalar(@SENT == 1), '13: one community-API request in flight at a time');
    finish($SENT[0]);
    ok(scalar(@SENT == 2), '13: ... and the next is sent the moment it answers, no fixed gap');
    # The only timer left is the in-flight request's watchdog; the bucket itself
    # armed no pacing wait.
    ok(scalar(!$hbucket->()->{timer} && $hbucket->()->{nextAt} <= $now),
       '13: ... with no pacing timer armed');

    # A 429: the shared deadline. Every failFast job fails at once, wherever it
    # sits in the queue; a job without the flag keeps its place and waits.
    reset_all();
    my %got;
    $get->($HOSTED . 'first', sub {}, sub {});
    $get->($HOSTED . 'ff1',  sub { $got{ff1} = 'ok' },  sub { $got{ff1} = $_[1] }, failFast => 1);
    $get->($HOSTED . 'wait', sub { $got{wait} = 'ok' }, sub { $got{wait} = $_[1] });
    $get->($HOSTED . 'ff2',  sub { $got{ff2} = 'ok' },  sub { $got{ff2} = $_[1] }, failFast => 1);
    failWith($SENT[0], 429);
    ok(scalar(($got{ff1} // '') eq 'backing off' && ($got{ff2} // '') eq 'backing off'),
       '13: after a 429 every failFast job fails at once, wherever it sat in the queue');
    ok(scalar(@SENT == 1 && !defined $got{wait}), '13: ... and a job without the flag waits');
    ok(scalar(abs($hbucket->()->{busyUntil} - ($now + $B0)) < 0.001),
       "13: the 429 set the community API's own deadline, ${B0}s");
    ok(scalar(bucket()->{busyUntil} == 0), "13: ... and MusicBrainz's is untouched");
    my %late;
    $get->($HOSTED . 'late', sub { $late{r} = 'ok' }, sub { $late{r} = $_[1] }, failFast => 1);
    ok(scalar(($late{r} // '') eq 'backing off' && @SENT == 1),
       '13: a failFast job arriving during the deadline is failed without being sent');
    advance($now + $B0 + 0.01);
    ok(scalar(@SENT == 2 && $SENT[1]{url} =~ /wait$/), '13: the waiting job goes once the deadline passes');

    # A timeout backs the bucket off too; a MusicBrainz timeout does not.
    reset_all();
    my %t;
    $get->($HOSTED . 'slow', sub {}, sub { $t{slow} = $_[1] }, failFast => 1);
    $timeoutWith->($SENT[0]);
    ok(scalar(abs($hbucket->()->{busyUntil} - ($now + $SLOW)) < 0.001),
       "13: a community-API timeout backs the bucket off ${SLOW}s");
    $get->($HOSTED . 'next', sub { $t{next} = 'ok' }, sub { $t{next} = $_[1] }, failFast => 1);
    ok(scalar(($t{next} // '') eq 'backing off' && @SENT == 1),
       '13: ... so the next count is not sent to it');
    advance($now + $SLOW + 0.01);
    $get->($HOSTED . 'after', sub {}, sub {}, failFast => 1);
    ok(scalar(@SENT == 2 && $SENT[1]{url} =~ /after$/), '13: ... and is sent again once that has passed');

    reset_all();
    $get->($PUBLIC . 'mbslow', sub {}, sub {});
    $timeoutWith->($SENT[0]);
    ok(scalar(bucket()->{busyUntil} == 0), '13: a MusicBrainz timeout moves no deadline');

    # The watchdog (no callback at all) counts as a timeout for the community API.
    reset_all();
    my $lost;
    $get->($HOSTED . 'lost', sub {}, sub { $lost = $_[1] }, failFast => 1, timeout => 4);
    advance($now + 4 + $PAD + 0.01);
    ok(scalar(defined $lost && $hbucket->()->{busyUntil} > $now),
       '13: a lost callback frees the slot and backs the community API off');

    # The plugin id is sent whatever shape apiHeaders answers in (LMS 9.1: a list,
    # or a HASHREF on its early-startup error path), and when it is absent.
    my $hh = $A->can('_hostedHeaders');
    {
        no strict 'refs'; no warnings 'redefine';
        local *{'Slim::Utils::Misc::apiHeaders'} = sub { ('X-LMS-ID' => 'srv', 'X-LMS-Plugin-ID' => $_[0]) };
        my %h = $hh->();
        ok(scalar(($h{'X-LMS-Plugin-ID'} // '') eq 'Plugins::Discography::Plugin' && ($h{'X-LMS-ID'} // '') eq 'srv'),
           '13: apiHeaders as a list: the plugin id and the server id are both sent');
        # A hashref carrying MORE than the plugin id: only reading the shape (not
        # the plugin-id fallback) keeps the rest of it.
        local *{'Slim::Utils::Misc::apiHeaders'} = sub { { 'X-LMS-Plugin-ID' => $_[0], 'X-LMS-ID' => 'srv' } };
        %h = $hh->();
        ok(scalar(($h{'X-LMS-Plugin-ID'} // '') eq 'Plugins::Discography::Plugin' && ($h{'X-LMS-ID'} // '') eq 'srv'),
           '13: apiHeaders as a HASHREF: read as headers, the plugin id and the rest are sent');
        local *{'Slim::Utils::Misc::apiHeaders'} = sub { { 'X-LMS-Plugin-ID' => $_[0] } };
        %h = $hh->();
        ok(scalar(($h{'X-LMS-Plugin-ID'} // '') eq 'Plugins::Discography::Plugin' && keys(%h) == 1),
           "13: ... LMS 9.1's own error-path hashref: exactly the plugin id");
    }
    {
        no strict 'refs';
        my %h = defined &Slim::Utils::Misc::apiHeaders ? () : $hh->();
        ok(scalar(!defined &Slim::Utils::Misc::apiHeaders
                  && ($h{'X-LMS-Plugin-ID'} // '') eq 'Plugins::Discography::Plugin'),
           '13: without apiHeaders (older LMS) the plugin id is sent directly');
    }
}

# ---------------------------------------------------------------------------
# 14. LISTENBRAINZ'S BUCKET AND BACKGROUND JOBS (0.56.7; analysis §A16).
#     ListenBrainz is one request at a time with no fixed gap, backs off on a 429
#     and a timeout, and carries no plugin id. A job sent as background work
#     never goes ahead of a waiting foreground job; a foreground job arriving
#     later still goes first, but a request already sent is not recalled.
# ---------------------------------------------------------------------------
{
    my $LB = 'https://api.listenbrainz.org/1/';
    my $SLOW = $A->can('NET_SLOW_BACKOFF')->();
    my $lbucket = sub { $Plugins::Discography::API::NET{lb} };
    ok(scalar(($A->can('_netBucket')->($LB . 'metadata/artist/?artist_mbids=x') // '') eq 'lb'),
       '14: a ListenBrainz url has its own bucket');

    reset_all();
    $get->($LB . 'a', sub {}, sub {});
    $get->($LB . 'b', sub {}, sub {});
    $get->($PUBLIC . 'c', sub {}, sub {});
    ok(scalar(@SENT == 2 && $SENT[0]{url} =~ /a$/ && $SENT[1]{url} =~ /c$/),
       '14: one ListenBrainz request at a time, side by side with MusicBrainz');
    ok(scalar(!exists $SENT[0]{headers}{'X-LMS-Plugin-ID'}), '14: ... with no community plugin id');
    finish($SENT[0]);
    ok(scalar(@SENT == 3 && $SENT[2]{url} =~ /b$/), '14: ... the next sent the moment it answers, no gap');

    reset_all();
    my %g;
    $get->($LB . 'first', sub {}, sub {});
    $get->($LB . 'ff', sub { $g{ff} = 'ok' }, sub { $g{ff} = $_[1] }, failFast => 1);
    failWith($SENT[0], 429);
    ok(scalar(($g{ff} // '') eq 'backing off' && abs($lbucket->()->{busyUntil} - ($now + $B0)) < 0.001
              && bucket()->{busyUntil} == 0),
       "14: a 429 backs ListenBrainz off ${B0}s, fails its failFast jobs at once, and leaves MusicBrainz alone");

    reset_all();
    $get->($LB . 'slow', sub {}, sub {}, failFast => 1);
    $SENT[0]{error} = 'Timed out waiting for data';
    $SENT[0]{err}->($SENT[0], 'Timed out waiting for data', T::RESP->new(code => 500, hdr => {}));
    ok(scalar(abs($lbucket->()->{busyUntil} - ($now + $SLOW)) < 0.001),
       "14: a ListenBrainz timeout backs it off ${SLOW}s");

    # Background jobs yield. One MusicBrainz request is out; two background
    # jobs wait; a foreground one arrives: it is next, and they keep their order.
    reset_all();
    $get->($PUBLIC . 'out', sub {}, sub {});
    $get->($PUBLIC . 'bg1', sub {}, sub {}, background => 1);
    $get->($PUBLIC . 'bg2', sub {}, sub {}, background => 1);
    $get->($PUBLIC . 'tap', sub {}, sub {});
    my @q = map { $_->{url} =~ m{/(\w+)$} } @{ bucket()->{queue} };
    ok(scalar("@q" eq 'tap bg1 bg2'), '14: a foreground job goes ahead of the background jobs waiting');
    ok(scalar(@SENT == 1 && $SENT[0]{url} =~ /out$/), '14: ... the request already out is not recalled');
    finish($SENT[0]);
    advance($now + $GAP + 0.01);
    ok(scalar(@SENT == 2 && $SENT[1]{url} =~ /tap$/), '14: ... and it is the next one sent');
    $get->($PUBLIC . 'tap2', sub {}, sub {});
    $get->($PUBLIC . 'bg3', sub {}, sub {}, background => 1);
    @q = map { $_->{url} =~ m{/(\w+)$} } @{ bucket()->{queue} };
    ok(scalar("@q" eq 'tap2 bg1 bg2 bg3'), '14: foreground jobs keep their own order, background ones theirs');

    # A shed background job goes back to the front of the BACKGROUND jobs, not
    # ahead of a foreground one; a shed foreground job goes to the very front.
    reset_all();
    $get->($PUBLIC . 'bgshed', sub {}, sub {}, background => 1);
    $get->($PUBLIC . 'fg', sub {}, sub {});
    $get->($PUBLIC . 'bg2', sub {}, sub {}, background => 1);
    shedWith($SENT[0]);
    @q = map { $_->{url} =~ m{/(\w+)$} } @{ bucket()->{queue} };
    ok(scalar("@q" eq 'fg bgshed bg2'), '14: a shed background job retries first of the background jobs, after the foreground');
    reset_all();
    $get->($PUBLIC . 'fgshed', sub {}, sub {});
    $get->($PUBLIC . 'fg2', sub {}, sub {});
    shedWith($SENT[0]);
    @q = map { $_->{url} =~ m{/(\w+)$} } @{ bucket()->{queue} };
    ok(scalar("@q" eq 'fgshed fg2'), '14: a shed foreground job still retries at the very front');
}

# ---------------------------------------------------------------------------
# 15. BACKGROUND IS INHERITED (0.56.9). The search's row check runs after the
#     list is shown, through eight request paths, so the flag rides the answers
#     instead of being passed to each: a request made while a background job's
#     answer runs is background too. Shared in-flight waiters call each caller
#     back under its OWN flag, and a page joining a background request still in
#     the queue moves it forward.
# ---------------------------------------------------------------------------
{
    no warnings 'once';
    my $NBG = sub { $Plugins::Discography::API::NET_BG };
    my $promote = $A->can('_netPromote');
    reset_all();
    my ($child, $seen);
    $get->($PUBLIC . 'bgjob', sub { $seen = $NBG->(); $child = $get->($PUBLIC . 'child', sub {}, sub {}) },
           sub {}, background => 1);
    finish($SENT[0]);
    ok(scalar($seen && ref $child eq 'HASH' && $child->{background}),
       "15: a request made in a background job's answer is background too");
    ok(scalar(!$NBG->()), '15: ... and the flag is clear again once that answer has run');

    reset_all(); $child = undef;
    $get->($PUBLIC . 'fgjob', sub { $child = $get->($PUBLIC . 'child', sub {}, sub {}) }, sub {});
    finish($SENT[0]);
    ok(scalar(ref $child eq 'HASH' && !$child->{background}), "15: one made in a foreground job's answer is not");

    reset_all(); $child = undef;
    $get->($PUBLIC . 'bgerr', sub {}, sub { $child = $get->($PUBLIC . 'child', sub {}, sub {}) },
           background => 1);
    failWith($SENT[0], 500);
    ok(scalar(ref $child eq 'HASH' && $child->{background}), '15: ... the error path inherits it too');

    reset_all(); $child = undef;
    my $H = 'https://api.lms-community.org/music/';
    $get->($H . 'a', sub {}, sub {});
    failWith($SENT[0], 429);
    $get->($H . 'ff', sub {}, sub { $child = $get->($PUBLIC . 'child', sub {}, sub {}) },
           failFast => 1, background => 1);
    ok(scalar(ref $child eq 'HASH' && $child->{background}),
       '15: ... and so does a background job failed at once while its bucket backs off');

    reset_all();
    $get->($PUBLIC . 'out', sub {}, sub {});
    my $bgX = $get->($PUBLIC . 'bgX', sub {}, sub {}, background => 1);
    $get->($PUBLIC . 'bgY', sub {}, sub {}, background => 1);
    $promote->($bgX);
    $get->($PUBLIC . 'tap', sub {}, sub {});
    my @q = map { $_->{url} =~ m{/(\w+)$} } @{ bucket()->{queue} };
    ok(scalar("@q" eq 'bgX tap bgY' && !$bgX->{background}),
       '15: a promoted job leaves the background jobs, and keeps its place among the foreground');
    $promote->($SENT[0]);
    ok(scalar(@SENT == 1 && "@{[ map { $_->{url} =~ m{/(\w+)$} } @{ bucket()->{queue} } ]}" eq 'bgX tap bgY'),
       '15: ... a request already out is left alone');

    # A page joins an artist read the background work started.
    reset_all();
    my $M = 'aaaaaaaa-0000-0000-0000-000000000001';
    my (%flag, %kid);
    $get->($PUBLIC . 'out', sub {}, sub {});
    {
        local $Plugins::Discography::API::NET_BG = 1;
        Plugins::Discography::API::_readArtist($M, sub {
            $flag{bg} = $NBG->(); $kid{bg} = $get->($PUBLIC . 'kidbg', sub {}, sub {}) });
    }
    $get->($PUBLIC . 'bgZ', sub {}, sub {}, background => 1);
    my ($read) = grep { $_->{url} =~ m{artist/$M} } @{ bucket()->{queue} };
    ok(scalar($read && $read->{background}), '15: an artist read the background work starts waits as background');
    Plugins::Discography::API::_readArtist($M, sub {
        $flag{fg} = $NBG->(); $kid{fg} = $get->($PUBLIC . 'kidfg', sub {}, sub {}) });
    @q = map { $_->{url} =~ m{artist/} ? 'read' : ($_->{url} =~ m{/(\w+)$})[0] } @{ bucket()->{queue} };
    ok(scalar("@q" eq 'read bgZ' && $read && !$read->{background}),
       '15: a page joining it moves it ahead of the background work');
    finish($SENT[0]);
    advance($now + $GAP + 0.01);
    my ($sentRead) = grep { $_->{url} =~ m{artist/$M} } @SENT;
    failWith($sentRead, 500);
    ok(scalar($flag{bg} && defined $flag{fg} && !$flag{fg}), '15: each caller hears back under its own flag');
    ok(scalar(ref $kid{bg} eq 'HASH' && $kid{bg}{background} && ref $kid{fg} eq 'HASH' && !$kid{fg}{background}),
       "15: ... so the page's next request is not demoted");

    # The same for a name search: a page joins the background work's request.
    reset_all();
    %Plugins::Discography::API::NAME_WAIT = (); %Plugins::Discography::API::NAME_MEMO = ();
    %Plugins::Discography::API::NAME_JOB = ();
    %flag = (); %kid = ();
    my $nq = Plugins::Discography::API::_nameQuery('artist', 'Joined Name', 0);
    $get->($PUBLIC . 'out', sub {}, sub {});
    {
        local $Plugins::Discography::API::NET_BG = 1;
        Plugins::Discography::API::_nameSearch($PUBLIC, $nq, 8, 8, sub {}, sub {
            $flag{bg} = $NBG->(); $kid{bg} = $get->($PUBLIC . 'kidbg', sub {}, sub {}) }, 'bg', 0);
    }
    $get->($PUBLIC . 'bgZ', sub {}, sub {}, background => 1);
    Plugins::Discography::API::_nameSearch($PUBLIC, $nq, 8, 15, sub {}, sub {
        $flag{fg} = $NBG->(); $kid{fg} = $get->($PUBLIC . 'kidfg', sub {}, sub {}) }, 'fg', 0);
    my ($nj) = grep { $_->{url} =~ m{artist\?query} } @{ bucket()->{queue} };
    $get->($PUBLIC . 'tap', sub {}, sub {});
    @q = map { $_->{url} =~ m{artist\?query} ? 'name' : ($_->{url} =~ m{/(\w+)$})[0] } @{ bucket()->{queue} };
    ok(scalar("@q" eq 'name tap bgZ' && $nj && !$nj->{background}),
       '15: a page joining a background name search moves it forward too');
    finish($SENT[0]);
    advance($now + $GAP + 0.01);
    my ($sentName) = grep { $_->{url} =~ m{artist\?query} } @SENT;
    failWith($sentName, 500);
    ok(scalar($flag{bg} && defined $flag{fg} && !$flag{fg}
              && ref $kid{fg} eq 'HASH' && !$kid{fg}{background}),
       '15: ... and its callers hear back under their own flags (a failed search)');

    # The same on an ANSWERED search: each caller's onOk under its own flag.
    reset_all();
    %Plugins::Discography::API::NAME_WAIT = (); %Plugins::Discography::API::NAME_MEMO = ();
    %Plugins::Discography::API::NAME_JOB = ();
    %flag = (); %kid = ();
    $nq = Plugins::Discography::API::_nameQuery('artist', 'Answered Name', 0);
    {
        local $Plugins::Discography::API::NET_BG = 1;
        Plugins::Discography::API::_nameSearch($PUBLIC, $nq, 8, 8, sub {
            $flag{bg} = $NBG->(); $kid{bg} = $get->($PUBLIC . 'kidbg', sub {}, sub {}) }, sub {}, 'bg', 0);
    }
    Plugins::Discography::API::_nameSearch($PUBLIC, $nq, 8, 15, sub {
        $flag{fg} = $NBG->(); $kid{fg} = $get->($PUBLIC . 'kidfg', sub {}, sub {}) }, sub {}, 'fg', 0);
    ($sentName) = grep { $_->{url} =~ m{artist\?query} } @SENT;
    $sentName->{body} = '{"count":0,"artists":[]}' if $sentName;
    finish($sentName);
    ok(scalar($flag{bg} && defined $flag{fg} && !$flag{fg}
              && ref $kid{bg} eq 'HASH' && $kid{bg}{background}
              && ref $kid{fg} eq 'HASH' && !$kid{fg}{background}),
       '15: ... and on an answered one');
}

# ---------------------------------------------------------------------------
# 16. BACKGROUND WORK WAITS FOR EVERY PAGE (0.56.11). Measured live on 0.56.10:
#     Bruce Springsteen opened straight after its search took 18.8 s. The row
#     check's community request went out while the page's first MusicBrainz
#     request waited; the page then queued behind it on the community API, it
#     timed out, and the 30 s backoff refused the page's own request. Now a
#     background job is not sent while any page request waits or is out, on
#     any host, and a background timeout holds background work only.
# ---------------------------------------------------------------------------
{
    my $H    = 'https://api.lms-community.org/music/';
    my $LB   = 'https://api.listenbrainz.org/1/';
    my $SLOW = $A->can('NET_SLOW_BACKOFF')->();
    my $hb   = sub { $Plugins::Discography::API::NET{hosted} };
    my $sent = sub { join ' ', map { $_->{url} =~ m{/([\w.]+)$} } @SENT };
    my $find = sub { my ($n) = @_; (grep { $_->{url} =~ m{/\Q$n\E$} } @SENT)[0] };
    my $timeoutWith = sub {
        my ($r) = @_;
        return ok(0, 'expected a request to time out, but none was sent') unless ref $r;
        $r->{error} = 'Timed out waiting for data';
        $r->{err}->($r, 'Timed out waiting for data', T::RESP->new(code => 500, hdr => {}));
    };

    # The measured sequence, replayed.
    reset_all();
    my %page;
    $get->($PUBLIC . 'combined', sub {}, sub {}, background => 1);
    ok(scalar($sent->() eq 'combined'), '16: background work with no page about goes out at once');
    $get->($PUBLIC . 'artist', sub {
        $get->($LB . 'lblist', sub { $page{lb} = 1 }, sub { $page{lb} = 'err' }, failFast => 1);
        $get->($H . 'pagelist', sub { $page{cm} = 1 }, sub { $page{cm} = $_[1] }, failFast => 1);
    }, sub {});
    $get->($H . 'bgname', sub {}, sub {}, background => 1, failFast => 1);
    ok(scalar($sent->() eq 'combined'),
       "16: the row check's community request waits while the page's MusicBrainz request is queued");
    finish($find->('combined'));
    advance($now + $GAP + 0.01);
    ok(scalar($sent->() eq 'combined artist'), '16: ... and while it is out');
    finish($find->('artist'));
    ok(scalar($sent->() eq 'combined artist lblist pagelist'),
       '16: the page asks the community API at once, ahead of the waiting background request');
    finish($find->('pagelist'));
    ok(scalar($sent->() eq 'combined artist lblist pagelist'),
       '16: ... the background request still waits while the page has ListenBrainz out');
    finish($find->('lblist'));
    ok(scalar($sent->() eq 'combined artist lblist pagelist bgname' && $page{cm} && $page{lb}),
       '16: ... and goes out when the page has nothing left waiting or out');

    # A background request already out when the page comes, and it times out.
    reset_all(); %page = ();
    $get->($H . 'bgout', sub {}, sub {}, background => 1);
    $get->($H . 'pagelist', sub { $page{cm} = 1 }, sub { $page{cm} = $_[1] }, failFast => 1);
    ok(scalar($sent->() eq 'bgout'), '16: a page request waits for a background request already out (one at a time)');
    $timeoutWith->($find->('bgout'));
    ok(scalar($sent->() eq 'bgout pagelist' && !defined $page{cm}),
       '16: that request timing out does not refuse the page: its request goes out');
    ok(scalar($hb->()->{busyUntil} == 0 && abs($hb->()->{bgBusyUntil} - ($now + $SLOW)) < 0.001),
       "16: ... the ${SLOW}s hold is on background work only");
    my $bgff;
    $get->($H . 'bgff', sub {}, sub { $bgff = $_[1] }, background => 1, failFast => 1);
    ok(scalar(($bgff // '') eq 'backing off'), '16: ... a background failFast request is failed at once meanwhile');
    $get->($H . 'bgwait', sub {}, sub {}, background => 1);
    finish($find->('pagelist'));
    ok(scalar($sent->() eq 'bgout pagelist' && $page{cm}),
       '16: ... and a background request that can wait, waits out the hold');
    advance($now + $SLOW + 0.01);
    ok(scalar($sent->() eq 'bgout pagelist bgwait'), '16: ... then goes');

    # The same after the watchdog (no callback at all).
    reset_all(); %page = ();
    $get->($H . 'bglost', sub {}, sub {}, background => 1);
    $get->($H . 'pagelist', sub { $page{cm} = 1 }, sub { $page{cm} = $_[1] }, failFast => 1);
    advance($now + 15 + $PAD + 0.01);
    ok(scalar($sent->() eq 'bglost pagelist' && !defined $page{cm} && $hb->()->{busyUntil} == 0),
       '16: a lost background callback (the watchdog) does not refuse the page either');

    # CONTROLS: a page request's own timeout still holds every request; a 429
    # on a background request still holds the page (the API's own rule).
    reset_all(); %page = ();
    $get->($H . 'fgout', sub {}, sub {});
    $get->($H . 'pagelist', sub { $page{cm} = 1 }, sub { $page{cm} = $_[1] }, failFast => 1);
    $timeoutWith->($find->('fgout'));
    ok(scalar(($page{cm} // '') eq 'backing off' && abs($hb->()->{busyUntil} - ($now + $SLOW)) < 0.001),
       "16: control: a page request's timeout still holds everything ${SLOW}s");
    reset_all(); %page = ();
    $get->($H . 'bg429', sub {}, sub {}, background => 1);
    $get->($H . 'pagelist', sub { $page{cm} = 1 }, sub { $page{cm} = $_[1] }, failFast => 1);
    failWith($find->('bg429'), 429);
    ok(scalar(($page{cm} // '') eq 'backing off'),
       '16: control: a 429 on a background request still holds the page (the community API rule)');

    # A page request that is failed at once frees the background work it held.
    reset_all();
    $get->($H . 'bgout', sub {}, sub {}, background => 1);
    $get->($H . 'pageff', sub {}, sub {}, failFast => 1);
    $get->($PUBLIC . 'bgmb', sub {}, sub {}, background => 1);
    ok(scalar($sent->() eq 'bgout'), '16: background MusicBrainz work waits while a page request is queued elsewhere');
    failWith($find->('bgout'), 429);
    ok(scalar($sent->() eq 'bgout bgmb'),
       '16: ... and goes once that page request is failed at once (nothing of the page left)');

    # The page's answer asks the SAME host again: the slot is freed before that
    # answer runs, and the background request waiting there must not take it.
    reset_all();
    $get->($H . 'pageA', sub { $get->($H . 'pageB', sub {}, sub {}) }, sub {});
    $get->($H . 'bgname', sub {}, sub {}, background => 1);
    finish($find->('pageA'));
    ok(scalar($sent->() eq 'pageA pageB'),
       "16: a page answer's next request on the same host goes before the background request waiting there");
    finish($find->('pageB'));
    ok(scalar($sent->() eq 'pageA pageB bgname'), '16: ... which goes once that answer has run and nothing waits');

    # A page answer that starts background work BEFORE asking its own next
    # request: the page's request still goes first, on the answer path and on
    # the failed-at-once path (the page falling back to MusicBrainz).
    reset_all();
    $get->($H . 'pageA', sub {
        $get->($PUBLIC . 'bgafter', sub {}, sub {}, background => 1);
        $get->($PUBLIC . 'fallback', sub {}, sub {});
    }, sub {});
    finish($find->('pageA'));
    ok(scalar($sent->() eq 'pageA fallback'),
       "16: background work a page answer starts waits for the page's next request");
    reset_all();
    $get->($H . 'bg429', sub {}, sub {}, background => 1);
    $get->($H . 'pageff', sub {}, sub {
        $get->($PUBLIC . 'bgafter', sub {}, sub {}, background => 1);
        $get->($PUBLIC . 'fallback', sub {}, sub {});
    }, failFast => 1);
    failWith($find->('bg429'), 429);
    ok(scalar($sent->() eq 'bg429 fallback'),
       "16: ... and so does background work started by a page request failed at once");

    # Background work alone is never held by other background work.
    reset_all();
    $get->($H . 'bgcm', sub {}, sub {}, background => 1);
    $get->($PUBLIC . 'bgmb', sub {}, sub {}, background => 1);
    ok(scalar($sent->() eq 'bgcm bgmb'), '16: background requests to two hosts go side by side when no page is about');

    # A page request answering wakes background work held in another bucket.
    reset_all();
    $get->($H . 'pageout', sub {}, sub {});
    $get->($PUBLIC . 'bgmb', sub {}, sub {}, background => 1);
    ok(scalar($sent->() eq 'pageout'), '16: background MusicBrainz work waits while a page request is out elsewhere');
    finish($find->('pageout'));
    ok(scalar($sent->() eq 'pageout bgmb'), '16: ... and goes the moment it answers');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
