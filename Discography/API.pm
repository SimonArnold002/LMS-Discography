package Plugins::Discography::API;

# Async MusicBrainz access for the Discography plugin.
#
# Two jobs:
#   1. Resolve an artist to a MusicBrainz artist MBID — library tag first
#      (contributor.musicbrainz_id, exact identity for free), MB name search as
#      fallback (port of the ListenBrainz Fresh Releases plugin's
#      getArtistMbidByName).
#   2. Fetch the artist's full RELEASE-GROUP list — the discography spine:
#      one entry per release (not per edition), with first-release-date and
#      primary/secondary types. Paginated serially at MusicBrainz's 1 req/s
#      etiquette; artwork comes from the Cover Art Archive by release-group
#      MBID (plain URL, no API call).

use strict;
use warnings;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::PluginManager;
use Slim::Utils::Timers;
# LMS timers fire against a HI-RES clock (`_makeTimer` does
# `EV::timer($when - EV::now, ...)`), so every deadline in this file must be
# built from Time::HiRes::time(). Core `time()` truncates to the second, which
# turns a 1.1s MB etiquette gap into `1.1 - frac(now)` — under 1s nine times
# out of ten. Browse.pm carries the same line; API.pm relied on it loading the
# module into the process, which is not a dependency to lean on.
use Time::HiRes ();
use JSON::XS::VersionOneAndTwo;

# For the shared matcher's _norm (same-name folding - see _nameKey). Sources
# does not use API, so this cannot go circular.
use Plugins::Discography::Sources;

my $log   = logger('plugin.discography');
my $prefs = preferences('plugin.discography');
# ---------------------------------------------------------------------------
# THE STORE: Discography's own SQLite file (DB.pm), not Slim::Utils::Cache.
# It answers get / set / remove exactly as the cache did, so no call site
# changed. Its `kv` table is EMPTIED WHENEVER CACHE_VERSION CHANGES, which is
# what Slim::Utils::Cache->new($namespace, $version) did before (LMS 9.1: "empty
# existing cache if version number is different"), so bumping the plugin version
# still wipes every dsc: cache. The artist-mbid and release-group families live
# in its `mbid` table instead, which a build does not empty (see DB.pm).
#
# WHY (Simon, 2026-07-22: "on all new builds whilst still in dev we clear the
# cache as its caught us out too many times now"): a correct fix repeatedly
# looked broken because the code path that would apply it never ran -- the
# answer was already cached. 0.45.0's canonical-name capture lives in
# _artistMbidByName, which short-circuits on a cached dsc:mbid (30d), so it
# could not fire for any artist visited before the upgrade.
#
# CACHE_VERSION MUST BE IDENTICAL IN API.pm, Sources.pm AND Browse.pm -- the
# first module to call DB->store() sets it and later calls are ignored.
# tools/syntax_check.sh asserts all three agree and match install.xml.
use Plugins::Discography::DB;
use constant CACHE_VERSION => '0.56.41';
my $cache = Plugins::Discography::DB->store(CACHE_VERSION);
# The families DB.pm keeps across builds, by their CURRENT key prefix, so rows
# written under an older key version are retired at open. Taken from the key
# builders themselves: bumping a version there is all it takes. (`can`: the
# suites load this module against a stubbed store with no DB.pm behind it; in
# LMS DB.pm ships in the same zip, so the call always runs.)
Plugins::Discography::DB->keepCurrent(
    _mbidKey(''), _rel2rgKey(''), _mbNameKey(''), _aliasKey(''), _libMbidKey(''))
    if Plugins::Discography::DB->can('keepCurrent');

# MB's canonical artist name, remembered in-process as well as cached — the
# cached copy was measured MISSING while the alias list written by the same
# response survived, which silently disabled three features. Declared here, not
# beside peekArtistName where it is explained, because the resolver writes it
# and compiles first (the 0.45.0 ALIAS_TTL ordering trap).
my %mbNameMem;

# MB resolution failures MUST go through this — "artist not found" with only
# info-level logging is undiagnosable in the field (Better Oblivion, 2026-07-09).
sub _dbg { Plugins::Discography::Plugin::dbg(@_) }

use constant MB_DEFAULT_BASE_URL => 'https://musicbrainz.org/ws/2/';
use constant CAA_RG_BASE_URL     => 'https://coverartarchive.org/release-group/';

# Auto-detect: when the user sets NO mb_base_url, a same-host musicbrainz-docker
# mirror is probed once at startup (autodetectMirror) and its base cached under
# this key so the SYNCHRONOUS _mbBase can pick it up. Value: a URL (mirror found),
# '' (probed, none found), or absent (never probed). Re-probed daily.
use constant MB_AUTO_KEY => 'dsc:mbmirror:v1';
use constant MB_AUTO_TTL => 86400;

# MIRROR SEARCH-INDEX HEALTH (field, 2026-07-21).
#
# The mirror -> public retry below fires on a ZERO-result mirror search, on the
# theory that a freshly imported musicbrainz-docker whose Solr indexes were never
# built returns count:0 for everything. That is a real failure mode and the retry
# earned its place — but "zero results" is ALSO the correct answer to a query that
# genuinely matches nothing, and the code could not tell the two apart. So every
# legitimately-empty lookup silently paid a round trip to musicbrainz.org.
#
# Measured on Simon's healthy mirror (one log window, 6 wasted public requests):
# `artist:"janes addiction"` returns 0 because the search is an exact Lucene
# PHRASE and "Jane's Addiction" tokenises as [jane][s][addiction] — the mirror was
# right, the heuristic was wrong. Three of the six were simple typos, which take
# the same expensive route.
#
# One non-empty mirror result PROVES the index is built, and that verdict is
# cheap, sticky and self-healing: no probe request, no config. Until it is proven,
# the original protection stands exactly as before. Keyed BY BASE so repointing at
# a different mirror re-proves, and TTL'd so one that later breaks is retested.
use constant MB_SEARCH_OK_TTL => 7 * 86400;
sub _mbSearchOkKey { 'dsc:mbsearchok:v1:' . _mbBase() }
sub _mbSearchProven { $cache->get(_mbSearchOkKey()) ? 1 : 0 }
sub _mbSearchProve  { eval { $cache->set(_mbSearchOkKey(), 1, MB_SEARCH_OK_TTL); 1 } }

# The whole decision in one place, so both call sites cannot drift and it can be
# tested without HTTP: given a mirror search result, should it be retried against
# the public API? Returns 1 only for an EMPTY result from an UNPROVEN mirror. A
# non-empty result proves the index as a side effect.
#   $arts   — decoded artists arrayref, or undef when the response did not parse
#   $mirror — the configured base is a mirror (not musicbrainz.org)
#   $isFb   — this request IS already the public retry
sub _mbSearchVerdict {
    my ($arts, $mirror, $isFb) = @_;
    return 0 unless $mirror && !$isFb && $arts;
    if (@$arts) { _mbSearchProve(); return 0 }
    return _mbSearchProven() ? 0 : 1;
}

# The MusicBrainz web-service base is a PREF (default = the public API) so the
# whole plugin can be pointed at a local mirror — e.g. a musicbrainz-docker
# instance at http://your-server:5000/ws/2/ — without touching code. The local server
# speaks the identical ws/2 API, so only the host changes. When the pref is
# blank, a same-host mirror auto-detected at startup is used if one was found;
# otherwise the public API. A missing trailing slash is tolerated.
# Note: the Cover Art Archive (CAA_RG_BASE_URL) is a SEPARATE service that
# musicbrainz-docker does NOT mirror, so it always stays on the public CAA.
sub _mbBase {
    my $u = $prefs->get('mb_base_url');
    unless (defined $u && $u =~ /\S/) {
        my $auto = $cache->get(MB_AUTO_KEY);
        $u = (defined $auto && length $auto) ? $auto : MB_DEFAULT_BASE_URL;
    }
    $u =~ s/\s+//g;
    $u .= '/' unless $u =~ m{/$};
    return $u;
}

# The <=1 req/s courtesy gap between paginated requests is MusicBrainz etiquette
# for THEIR servers only. A local mirror is our own hardware with no such limit,
# so pages there fetch back-to-back. True only when the base is the public host
# (incl. beta./test. subdomains); any other host (a mirror) returns false.
sub _mbThrottled {
    return _mbBase() =~ m{^https?://([^/]*\.)?musicbrainz\.org/}i ? 1 : 0;
}

# (_mbGap and the public mbGap are gone, stage 3, 2026-09-30. Pacing moved to
# _netGet in 0.51.17; what was left were the "are we throttled?" policy checks
# that skipped work on the public API, and those gates are removed.)

# ---------------------------------------------------------------------------
# THE ONE OUTBOUND REQUEST QUEUE (0.51.17)
# ---------------------------------------------------------------------------
# Every MusicBrainz ws/2 request in this plugin goes through _netGet. Nothing
# here may build its own SimpleAsyncHTTP to that host.
#
# WHY, and why it is NOT the same design as LBF's. MusicBrainz publishes ~1
# request/s per IP, averaged, and refuses EVERY request from that IP with 503
# above it. LBF hit that in the field (~80 refusals in ten minutes, 2026-09-14)
# because five of its paths sent unpaced beside two that paced themselves, and
# built one queue. Discography's exposure is smaller and differently shaped —
# it sends only on a page open or a search, with no warm and no library sweep —
# so a CROSS-PLUGIN gate shared with LBF was scoped and DECLINED (Simon,
# 2026-09-20; see the ledger). What was wrong here is narrower and real:
#
#   `_mbGap` decides from the CONFIGURED BASE. On a mirror install it returns 0,
#   and the four paths that deliberately retry a zero-result mirror search
#   against the PUBLIC host (_artistMbidByName, getArtistCandidates) therefore
#   sent to musicbrainz.org with no gap, no backoff and no queue at all.
#
# So the decision is made on the URL, exactly as LBF's comment says it must be:
# a request to the user's own mirror is not queued and never waits behind a
# public one, and a public retry is paced even when the configured base is a
# mirror.
#
# THE RULE, enforced here and nowhere else:
#   * ONE public request in flight at a time;
#   * the next no sooner than NET_GAP_MB after the previous one was SENT;
#   * nothing goes out while the shared backoff is in force, and the queue
#     itself notes a 503 and a success — callers must not, or one refusal would
#     double the curve twice.
#
# ONE CLOCK, DELIBERATELY. Every deadline here is built from Time::HiRes::time()
# and handed to Slim::Utils::Timers, which compares against a hi-res clock
# (`_makeTimer` does `EV::timer($when - EV::now, ...)`). Mixing core time() into
# a deadline silently shortens it by frac(now) — that was the 0.51.16 bug.
#
# LBF's backoff mixes the two clocks and that is NOT a bug to port a fix for:
# its whole public-MusicBrainz surface is two user-triggered call sites (the
# tracklist fallback when ListenBrainz has none, and Diag's connection probe),
# so it cannot earn a 503 and `_mbNoteLimit` never runs. HERE the backoff is
# reachable — a user with no mirror sends every request of a cold artist page
# through this queue, which for a big discography is dozens — so the clock has
# to be right. Same shape, different reachability; see the ledger.
#
# $onOk / $onErr receive exactly what SimpleAsyncHTTP hands its callbacks, so a
# call site converts by replacing `->new(...)->get(...)` and nothing else.
#
# THE COMMUNITY API (api.lms-community.org) HAS ITS OWN BUCKET, `hosted` (stage 3
# step 2, 2026-09-30), and its RATE IS OUR OWN, set from how MAI uses it — the
# fleet rule (LBF ledger A2 `ONE MUSICBRAINZ QUEUE, ONE COMMUNITY-API QUEUE`,
# Simon 2026-09-14: "we just cannot go over its rate"). The dev publishes no
# limit, and MAI, his own plugin, sends to this service one request at a time
# on its scanner path, synchronously, sleeping 5 s, doubling to 30, after a 429
# (read in MusicArtistInfo master `Common.pm::call`, 2026-09-30; its token bucket
# is for Discogs, not this service). So: ONE request in flight for the whole
# plugin, no fixed gap (the round trip is the pacing), and a 429 moves this
# bucket's own shared deadline, 5 s doubling to 30, only ever outward, reset by
# a success. Every request carries the MANDATORY `X-LMS-Plugin-ID` header, the
# dev's requirement, which is how a plugin registers with the service
# (_hostedHeaders). The backoff is load-bearing: measured 2026-09-30, one
# request at a time with no gap drew HTTP 429 after about 57 requests, each 429
# taking 1-3 s to come back (ledger A3 `COMMUNITY API DOES REFUSE`). On top of
# the fleet rule, and only ever stricter than it:
#   * a job sent with `failFast => 1` is failed AT ONCE while its bucket is
#     backing off, instead of waiting it out. The count lookups send that way:
#     their caller has a MusicBrainz answer to fall back to, and a page or a
#     search must not stand still for 5-30 s for a number it can get elsewhere;
#   * a TIMEOUT backs the bucket off too (NET_SLOW_BACKOFF), so a slow service
#     cannot add its whole timeout to every lookup that follows.
#
# LISTENBRAINZ (api.listenbrainz.org) HAS ITS OWN BUCKET TOO, `lb` (0.56.7;
# analysis §A16). The artist page's first list comes from it. It publishes its
# limit in headers (30 requests per 10 s, measured 2026-10-01) and a page sends
# one request, so the bucket only has to keep it to one at a time and honour a
# 429 or a timeout the way the community bucket does.
#
# BACKGROUND JOBS YIELD (0.56.7). A job sent with `background => 1` (the work a
# page does after it is drawn, for the next visit) is queued behind every job
# without the flag and never goes ahead of one, so a tap made meanwhile waits
# for at most the one request already out. A shed retry goes back to the front
# of its own kind, never ahead of a foreground job.
#
# BACKGROUND WORK WAITS FOR EVERY PAGE, NOT JUST ITS OWN BUCKET'S (0.56.11).
# Measured live on 0.56.10: Bruce Springsteen opened straight after its search
# took 18.8 s (3-6 s before). The search's background row check sent a community
# request while the page's first MusicBrainz request was still queued; the page
# then needed the community API, which takes one request at a time, and waited
# behind it; that request timed out, and the 30 s slow backoff that followed
# refused the page's own request, so the page took the slow MusicBrainz route.
# So, two rules on top of the yield above:
#   * a background job is not SENT while any foreground job is queued or in
#     flight in ANY bucket, or while a foreground job's answer is running
#     (_netFgBusy, $NET_SETTLING): the slot is freed BEFORE the answer runs, and
#     the page's next request is only queued BY that answer, so without the
#     second test the background work took the free slot first. Woken when the
#     answer has run (_netWake). A tap therefore finds every host free, except
#     for a background request already out when it came, which it waits for;
#   * a background request's TIMEOUT backs off background work only
#     (`bgBusyUntil`); foreground jobs still go out. A 429 still backs off
#     everything (`busyUntil`): that is the community API's own rule.
#
# BACKGROUND IS INHERITED (0.56.9). A job's callbacks run with $NET_BG set to its
# own flag, so every request a background job's answer leads to is background
# too, however many subs deep, without each one being told: the search's row
# check (filterRowsWithContent, run after the list is shown) reaches eight
# request paths. The shared in-flight waiters (_nameSearch, _readArtist,
# getArtistCandidates) call each caller back under ITS OWN flag, so a page that
# joins a background request is not demoted by it; and a foreground caller that
# joins a background request still waiting in the queue moves it forward
# (_netPromote). No request in this module is launched from a timer, which is
# what would lose the flag.
our $NET_BG = 0;
use constant NET_GAP_MB        => 1.1;   # public musicbrainz.org only
use constant NET_BACKOFF_START => 5;
use constant NET_BACKOFF_MAX   => 30;
use constant NET_WATCHDOG_PAD  => 5;     # past the timeout, a lost callback frees the slot
use constant NET_SHED_RETRIES  => 3;     # a shed 503 is transient - see _netIsShed
use constant NET_SHED_WAIT     => 0.5;   # floor when the server sends Retry-After: 0
use constant NET_SLOW_BACKOFF  => 30;    # the community API after a timeout

# One bucket per rate-limited host. A URL with no bucket is sent straight out.
# `our`, not `my`, ON PURPOSE: the guard suite resets and inspects this between
# sections. LBF's equivalent suite has to lift its queue's source out of the
# file and eval it into another package to get at the same state, which then
# needs every constant re-declared beside it; one word here avoids all of that.
our %NET = (
    mb     => { gap => NET_GAP_MB, queue => [], inflight => 0, nextAt => 0,
                timer => undef, busyUntil => 0, delay => 0, pumping => 0, repump => 0,
                inflightBg => 0, bgBusyUntil => 0 },
    hosted => { gap => 0, queue => [], inflight => 0, nextAt => 0,
                timer => undef, busyUntil => 0, delay => 0, pumping => 0, repump => 0,
                inflightBg => 0, bgBusyUntil => 0, slow => NET_SLOW_BACKOFF },
    lb     => { gap => 0, queue => [], inflight => 0, nextAt => 0,
                timer => undef, busyUntil => 0, delay => 0, pumping => 0, repump => 0,
                inflightBg => 0, bgBusyUntil => 0, slow => NET_SLOW_BACKOFF },
);

# True while any bucket has a foreground job waiting or out, or a foreground
# job's answer is running. Foreground jobs always queue ahead of background
# ones, so a queue's first job tells.
our $NET_SETTLING = 0;
sub _netFgBusy {
    return 1 if $NET_SETTLING;
    for my $s (values %NET) {
        return 1 if $s->{inflight} && !$s->{inflightBg};
        my $head = ($s->{queue} || [])->[0];
        return 1 if $head && !$head->{background};
    }
    return 0;
}

# A foreground job has gone and its answer has run: background jobs held in the
# other buckets (every bucket when $except is undef) may go.
sub _netWake {
    my ($except) = @_;
    _netPump($_) for grep { $_ ne ($except // '') && @{ $NET{$_}{queue} || [] } } sort keys %NET;
    return;
}

# Runs a job's answer: under its own background flag, and, for a foreground
# job, with background work held until the answer has queued what it needs next.
# The wake runs even when the answer dies, or held background work would wait
# for the next page to wake it.
sub _netAnswer {
    my ($b, $job, $code) = @_;
    my $fg = $b && !$job->{background};
    my $ok = eval {
        local $NET_SETTLING = $NET_SETTLING + ($fg ? 1 : 0);
        local $NET_BG = $job->{background};
        $code->();
        1;
    };
    my $e = $@;
    _netWake() if $fg && !$NET_SETTLING;
    die $e unless $ok;
    return;
}

sub _netBucket {
    my ($url) = @_;
    return undef unless defined $url;
    return 'mb'     if $url =~ m{^https?://([^/]*\.)?musicbrainz\.org/}i;
    return 'hosted' if $url =~ m{^https?://api\.lms-community\.org/}i;
    return 'lb'     if $url =~ m{^https?://api\.listenbrainz\.org/}i;
    return undef;
}

# Queue a job: a background job at the very back; any other job ahead of the
# first background job waiting. $front (a shed retry) puts it first of its own
# kind instead.
sub _netEnqueue {
    my ($q, $job, $front) = @_;
    my ($bg) = grep { $q->[$_]{background} } 0 .. $#$q;
    if ($job->{background}) {
        if ($front && defined $bg) { splice @$q, $bg, 0, $job }
        else                       { push @$q, $job }
    }
    elsif ($front)      { unshift @$q, $job }
    elsif (defined $bg) { splice @$q, $bg, 0, $job }
    else                { push @$q, $job }
    return;
}

# The package name the community API is told who is calling with. Derived from
# this package, as LBF does, so it cannot drift: ...::API -> ...::Plugin.
use constant PLUGIN_PACKAGE => __PACKAGE__ =~ s/\b(?:\w+)$/Plugin/r;

# The MANDATORY header, the dev's spec: every call names the calling plugin's
# package in `X-LMS-Plugin-ID`. `apiHeaders` is new in Slim::Utils::Misc and
# absent on older LMS, so it is probed, never called blind (LBF's and MAI's
# guarded form). Read in the LMS 9.1 source (2026-09-30): it returns
# `X-LMS-Plugin-ID => $module`, plus `X-LMS-ID` (the server id) when the
# Analytics plugin is enabled — but on its early-startup error path it returns a
# HASHREF instead of a list, and `%h = apiHeaders(...)` then sends no plugin id.
# So either shape is taken, and the plugin id is always there.
# AUTH SLOT (dev heads-up, docs/hosted-lms-community-api.md §0.2): when a scheme
# is published, its token and `Authorization` header are added here and a
# 401/403 is treated as a miss, never a hard failure.
sub _hostedHeaders {
    my @h = Slim::Utils::Misc->can('apiHeaders')
        ? Slim::Utils::Misc::apiHeaders(PLUGIN_PACKAGE) : ();
    @h = %{ $h[0] } if @h == 1 && ref $h[0] eq 'HASH';
    @h = () if @h % 2;
    my %h = @h;
    $h{'X-LMS-Plugin-ID'} ||= PLUGIN_PACKAGE;
    return %h;
}

# A response-shaped object for a job failed without being sent (failFast while
# the bucket backs off): error handlers call ->error and ->code on it.
{
    package Plugins::Discography::API::BackingOff;
    sub new     { return bless {}, shift }
    sub code    { return 0 }
    sub error   { return 'backing off' }
    sub content { return '' }
}

# A SHED IS NOT A RATE LIMIT, and telling them apart is the whole point
# (measured 2026-09-20). MusicBrainz answers BOTH with 503, and the headers are
# the only way to know which. A shed, verbatim off the wire:
#
#   X-RateLimit-Who: search-shed      X-RateLimit-Zone: search
#   X-RateLimit-Limit: 1900           X-RateLimit-Remaining: 269
#   Retry-After: 0
#   {"error": "The MusicBrainz web server is currently busy. Please try again later."}
#
# `Remaining: 269` of 1900 says we were nowhere near a limit: their search
# cluster was momentarily busy and dropped the request. It is INDEPENDENT of our
# rate — one arrived after an 18.6s idle gap — so spacing requests further apart
# does not prevent it, and backing off 5-30s punishes us for their weather.
# Measured from a cold IP: 4 sheds, all 4 recovered on the FIRST retry 0.4s
# later. So a shed is retried, and only a real refusal moves the backoff curve.
#
# Takes the error callback's arguments in any order and probes whichever object
# can answer: it gets ($self, $error, $response) and the HTTP::Response is the
# THIRD (see §A3's note on _probeArtistImage), but not every transport supplies
# one.
sub _netIsShed {
    for my $r (@_) {
        next unless ref $r;
        next unless (eval { $r->code } // 0) == 503;
        return 1 if (eval { $r->header('X-RateLimit-Who') } // '') =~ /shed/i;
        return 1 if (eval { $r->content } // '') =~ /currently busy/i;
    }
    return 0;
}

# Retry-After in seconds when the server names one (0 = "now", which is what a
# shed sends), else 0.
sub _netRetryAfter {
    for my $r (@_) {
        next unless ref $r;
        my $ra = eval { $r->header('Retry-After') };
        return $1 + 0 if defined $ra && $ra =~ /^\s*(\d+(?:\.\d+)?)\s*$/;
    }
    return 0;
}

# SAME CONTRACT AS _netIsShed: hand it the error callback's arguments in any
# order and it probes whichever object can answer. It must see ALL of them.
#
# The accessors it needs live on DIFFERENT objects — `->code`/`->header` on the
# HTTP::Response (the THIRD argument), `->error` on the SimpleAsyncHTTP object
# (the FIRST; every error handler in this file reads `shift->error`). The old
# fixed ($resp, $err) signature forced the one call site to pick one of them,
# and it picked the async object — so the shed guard below, which reads
# HEADERS, saw an object with none and fell through. An exhausted shed then
# moved the backoff curve: the exact thing 0.51.18 exists to stop.
#
# The accessors are eval'd because an object that cannot answer one must not
# die inside a network callback. The price is that a WRONG argument looks
# exactly like a negative answer — which is why the old miss survived a review
# round and a suite — so the contract is "pass everything", never "pass the
# right one".
sub _netIsRateLimited {
    return 0 if _netIsShed(@_);         # busy, not throttled
    my $err = '';
    for my $r (@_) {
        unless (ref $r) { $err .= $r if defined $r; next }
        my $code = eval { $r->code } // 0;
        return 1 if $code == 503 || $code == 429;
        $err .= (eval { $r->error } // '');
    }
    return $err =~ /rate limit|exceeding the allowable|too many requests|\b503\b|\b429\b/i ? 1 : 0;
}

sub _netNoteOk { $NET{ $_[0] }{delay} = 0; return }

sub _netNoteLimit {
    my ($b) = @_;
    my $s = $NET{$b} or return 0;
    $s->{delay} = $s->{delay} ? $s->{delay} * 2 : NET_BACKOFF_START;
    $s->{delay} = NET_BACKOFF_MAX if $s->{delay} > NET_BACKOFF_MAX;
    my $until = Time::HiRes::time() + $s->{delay};
    $s->{busyUntil} = $until if $until > $s->{busyUntil};   # only ever outward
    $log->warn("$b rate limit - backing off $s->{delay}s");
    return $s->{delay};
}

# A timeout, from the transport's error text or our own watchdog. Same "pass
# every argument" contract as _netIsRateLimited.
sub _netIsTimeout {
    for my $r (@_) {
        my $e = ref $r ? (eval { $r->error } // '') : ($r // '');
        return 1 if $e =~ /timed?\s*out/i;
    }
    return 0;
}

# A bucket with a `slow` setting (the community API) is not asked again for that
# many seconds after a timeout, so a slow service cannot add its whole timeout to
# every job behind it. The deadline only ever moves outward, as _netNoteLimit's
# does; the MusicBrainz bucket has no `slow` and is untouched. A BACKGROUND
# request's timeout ($bg) holds background work only (0.56.11): a page must not
# lose its own request to the after-work of the page before it.
sub _netNoteSlow {
    my ($b, $bg) = @_;
    my $s = $NET{ $b // '' } or return;
    return unless $s->{slow};
    my $key   = $bg ? 'bgBusyUntil' : 'busyUntil';
    my $until = Time::HiRes::time() + $s->{slow};
    $s->{$key} = $until if $until > ($s->{$key} // 0);
    $log->warn("$b timed out" . ($bg ? ' on background work - background work not asking it'
                                     : ' - not asking it') . " for $s->{slow}s");
    return;
}

# Returns the job, so a shared in-flight registry can promote it (_netPromote).
sub _netGet {
    my ($url, $onOk, $onErr, %opt) = @_;
    my $job = { url => $url, ok => ($onOk || sub {}), err => ($onErr || sub {}),
                timeout => ($opt{timeout} || 15), tries => 0,
                failFast => ($opt{failFast} ? 1 : 0),
                background => (($opt{background} || $NET_BG) ? 1 : 0) };
    my $b = _netBucket($url);
    $job->{bucket} = $b;
    unless ($b) { _netSend(undef, $job); return $job }
    _netEnqueue($NET{$b}{queue}, $job);
    _netPump($b);
    return $job;
}

# A foreground caller has joined a BACKGROUND request: if it is still waiting in
# its queue, it becomes foreground and moves ahead of the background jobs (a
# request already sent cannot be recalled, and is answered soon anyway).
sub _netPromote {
    my ($job) = @_;
    return unless ref $job eq 'HASH' && $job->{background} && $job->{bucket};
    my $q = $NET{ $job->{bucket} }{queue} or return;
    my ($at) = grep { $q->[$_] == $job } 0 .. $#$q;
    return unless defined $at;
    splice @$q, $at, 1;
    $job->{background} = 0;
    _netEnqueue($q, $job);
    _dbg("promoted $job->{url} to the foreground (a tap is waiting on it)");
    _netPump($job->{bucket});
    return;
}

# A LOOP, NOT RECURSION, AND RE-ENTRY IS FOLDED INTO IT (LBF's reasoning): a
# callback that lands synchronously — a test stub, a cached transport —
# re-enters the pump from inside _netSend, and a plain guard would drop that
# wake-up and strand the queue. `local` restores the guard even if a caller's
# callback dies inside the loop; a flag left set would silence every request to
# that host for the life of the process.
sub _netPump {
    my ($b) = @_;
    my $s = $NET{$b} or return;
    if ($s->{pumping}) { $s->{repump} = 1; return }
    local $s->{pumping} = 1;
    do {
        $s->{repump} = 0;
        while (@{ $s->{queue} }) {
            my $now = Time::HiRes::time();
            # failFast jobs are failed AT ONCE while the bucket backs off, wherever
            # they sit in the queue and whether or not a request is in flight:
            # their callers have another source (see the community API note
            # above) and must not wait out 5-30 s for this. Jobs without the flag
            # keep their place and wait for the deadline as before. A background
            # job also backs off for a background timeout (`bgBusyUntil`).
            my $bgUntil = $s->{bgBusyUntil} // 0;
            my @ff = grep { $_->{failFast}
                            && ($s->{busyUntil} > $now || ($_->{background} && $bgUntil > $now)) }
                     @{ $s->{queue} };
            if (@ff) {
                my %out = map { ($_ => 1) } @ff;
                @{ $s->{queue} } = grep { !$out{$_} } @{ $s->{queue} };
                for my $job (@ff) {
                    _dbg("$b backing off - not sending $job->{url}");
                    local $NET_SETTLING = $NET_SETTLING + ($job->{background} ? 0 : 1);
                    local $NET_BG = $job->{background};
                    $job->{err}->(Plugins::Discography::API::BackingOff->new, 'backing off',
                                  Plugins::Discography::API::BackingOff->new);
                }
                # This bucket is pumped again by the loop; the others are woken.
                _netWake($b) if !$NET_SETTLING && grep { !$_->{background} } @ff;
                next;
            }
            last if $s->{inflight};
            # A background job waits while any page has a request waiting or out,
            # on any host (0.56.11; see BACKGROUND WORK WAITS above). Woken by
            # the foreground job that leaves last (_netWakeOthers).
            my $head = $s->{queue}[0];
            if ($head->{background} && _netFgBusy()) {
                _dbg("$b holding background work - a page has a request waiting or out")
                    unless $s->{held}++;
                last;
            }
            $s->{held} = 0;
            my $until = $s->{busyUntil};
            $until = $bgUntil if $head->{background} && $bgUntil > $until;
            my $at  = $s->{nextAt} > $until ? $s->{nextAt} : $until;
            if ($at > $now) {
                # CLAIM THE SLOT BEFORE SCHEDULING, and keep a boolean rather
                # than the handle (nothing ever kills this timer). `$s->{timer}
                # ||= setTimer(...)` assigns AFTER the call returns, so a
                # transport or timer that fires synchronously clears the flag
                # first and then has the stale handle written back over it —
                # leaving a claim nothing will ever release and a queue stalled
                # for the life of the process.
                unless ($s->{timer}) {
                    $s->{timer} = 1;
                    Slim::Utils::Timers::setTimer(undef, $at,
                        sub { $s->{timer} = 0; _netPump($b) });
                }
                last;
            }
            my $job = shift @{ $s->{queue} };
            $s->{inflight}   = 1;
            $s->{inflightBg} = $job->{background} ? 1 : 0;
            $s->{nextAt}     = $now + $s->{gap};
            _netSend($b, $job);
        }
    } while ($s->{repump});
    return;
}

sub _netSend {
    my ($b, $job) = @_;
    my ($settled, $watchdog) = (0, undef);
    # Frees the slot exactly once, whichever of the two callbacks or the
    # watchdog gets there first, and BEFORE the caller's callback runs — so a
    # callback that queues its next request finds the queue ready for it.
    my $release = sub {
        return if $settled++;
        return unless $b;
        Slim::Utils::Timers::killSpecific($watchdog) if $watchdog;
        $NET{$b}{inflight}   = 0;
        $NET{$b}{inflightBg} = 0;
        _netPump($b);
    };
    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $already = $settled;
            my @a = @_;
            _netNoteOk($b) if $b;
            _netAnswer($b, $job, sub {
                $release->();
                $job->{ok}->(@a) unless $already;
            });
        },
        sub {
            my $already = $settled;
            # A SHED IS RETRIED, NOT REPORTED. It is MusicBrainz being busy for
            # a moment, it recovers on the first retry, and the caller never
            # needs to know. Bounded, so a genuinely sick server still fails
            # the request rather than spinning: after NET_SHED_RETRIES it falls
            # through and is reported like any other error.
            if ($b && !$already && _netIsShed($_[2], $_[0])
                    && ++$job->{tries} <= NET_SHED_RETRIES) {
                my $s    = $NET{$b};
                my $wait = _netRetryAfter($_[2], $_[0]) || NET_SHED_WAIT;
                my $at   = Time::HiRes::time() + $wait;
                $s->{nextAt} = $at if $at > $s->{nextAt};
                # Back to the FRONT: this job was already waiting its turn, and
                # the caller's chain is stalled behind it. (A background job:
                # first of the background jobs, still behind every other.)
                _netEnqueue($s->{queue}, $job, 1);
                _dbg("$b shed $job->{url} - retry $job->{tries}/"
                     . NET_SHED_RETRIES . " in ${wait}s");
                $release->();        # frees the slot and pumps; job is queued
                return;
            }
            # ALL THREE ARGUMENTS, like the shed test above: the response
            # carries the code and the headers, the async object carries
            # ->error, and handing over only one of them blinds the shed guard.
            if ($b && _netIsRateLimited(@_)) { _netNoteLimit($b) }
            elsif ($b && !$already && _netIsTimeout(@_)) { _netNoteSlow($b, $job->{background}) }
            my @a = @_;
            _netAnswer($b, $job, sub {
                $release->();
                $job->{err}->(@a) unless $already;
            });
        },
        { timeout => $job->{timeout} },
    );
    # USER_AGENT() with parens: it is a SUB declared further down this file, not
    # a constant, so a bareword here is a strict-subs error at compile time.
    my @headers = ('Accept' => 'application/json', 'User-Agent' => USER_AGENT());
    push @headers, _hostedHeaders() if ($b // '') eq 'hosted';
    $http->get($job->{url}, @headers);
    # ARMED AFTER THE SEND, AND ONLY IF STILL UNSETTLED. The watchdog measures
    # time from the moment the request went out, which is what it is for; and a
    # transport that answers synchronously (a cached layer, a test stub) has
    # already settled by now, so there is no timer to arm and immediately kill.
    if ($b && !$settled) {
        $watchdog = Slim::Utils::Timers::setTimer(undef,
            Time::HiRes::time() + $job->{timeout} + NET_WATCHDOG_PAD, sub {
                return if $settled;
                $log->warn("no callback for $job->{url} - freeing the queue");
                $watchdog = undef;
                _netNoteSlow($b, $job->{background});
                # A response-shaped object: error handlers call ->error and
                # ->code on their first argument.
                _netAnswer($b, $job, sub {
                    $release->();
                    $job->{err}->(Plugins::Discography::API::LostResponse->new, 'timed out');
                });
            });
    }
    return;
}

{
    package Plugins::Discography::API::LostResponse;
    sub new     { return bless {}, shift }
    sub code    { return 0 }
    sub error   { return 'no callback' }
    sub content { return '' }
}

# Auto-detect a LOCAL MusicBrainz mirror on the SAME host — the common
# musicbrainz-docker-alongside-LMS setup — so it works with zero config. Only
# runs when the user has set NO mb_base_url: probe a small FIXED same-host list
# and, if one answers as a genuine ws/2 endpoint, cache its base for _mbBase.
# Validation is the point: a known artist MBID must come back with the expected
# name, which proves the responder is MusicBrainz and not some other service on
# :5000 (macOS AirPlay, a Flask app, ...) — so a false positive is effectively
# impossible. A manually-set base always wins and skips the probe; the LAN is
# NEVER scanned (localhost only — a mirror on another host is typed in by hand).
# THE PROBE MBID MUST BE REAL, and this one was not for two releases (0.47.3).
# `a74b1b7f-06a0-4672-a641-eb3353aa608d` 404s on the mirror AND on
# musicbrainz.org — a mangled copy of Radiohead's actual id, sharing only the
# first block. So the probe could never validate, `autodetectMirror` could never
# succeed, and EVERY install with a blank mb_base_url and a same-host mirror ran
# the whole plugin against the public API at 1 req/s, re-probing daily forever.
# The feature shipped twice (0.30.0, 0.30.1) without ever once firing.
# Verified live against both hosts before changing it, and `tools/syntax_check.sh`
# now asks MusicBrainz whether this id really is MB_PROBE_NAME — a wrong
# constant is invisible at runtime (it looks exactly like "no mirror here"), so
# the check has to live outside the runtime.
use constant MB_PROBE_MBID => 'a74b1b7f-71a5-4011-9441-d0b5e4122711';   # Radiohead
use constant MB_PROBE_NAME => 'Radiohead';
my @MB_AUTO_CANDIDATES = (
    'http://localhost:5000/ws/2/',
    'http://127.0.0.1:5000/ws/2/',
);

sub autodetectMirror {
    my ($class, $cb) = @_;
    $cb ||= sub {};

    # Manual base set -> respect it, never probe.
    my $u = $prefs->get('mb_base_url');
    return $cb->() if defined $u && $u =~ /\S/;

    # Already probed within MB_AUTO_TTL (found a URL or confirmed none) -> done.
    return $cb->() if defined $cache->get(MB_AUTO_KEY);

    my $i = 0;
    my $try; $try = sub {
        if ($i >= @MB_AUTO_CANDIDATES) {
            eval { $cache->set(MB_AUTO_KEY, '', MB_AUTO_TTL); 1 };   # none; don't re-probe today
            return $cb->();
        }
        my $base = $MB_AUTO_CANDIDATES[$i++];
        _netGet($base . 'artist/' . MB_PROBE_MBID . '?fmt=json',
            sub {
                my $data = eval { from_json(shift->content) };
                if (!$@ && ref $data eq 'HASH' && ($data->{name} // '') eq MB_PROBE_NAME) {
                    eval { $cache->set(MB_AUTO_KEY, $base, MB_AUTO_TTL); 1 };
                    _dbg("autodetected local MusicBrainz mirror: $base");
                    return $cb->();
                }
                $try->();   # answered but not MusicBrainz -> next candidate
            },
            sub { $try->() },   # unreachable / error -> next candidate
            timeout => 3);
    };
    $try->();
    return;
}

# Artist-MBID lookups: hits are stable for weeks. A MISS is cached only briefly
# — a "not found" is far more often a TRANSIENT infrastructure blip (a MB mirror
# whose search index is still building returns 0 for everything; a timeout) than
# a genuinely unknown artist, and pinning a transient miss for a whole day made a
# fixed mirror still look broken (field, 2026-07-11). 1h is long enough to avoid
# hammering on a genuine miss, short enough to self-heal. The error view also
# offers a Refresh that clears the miss immediately (clearArtistMbid).
# Bumped when RESOLUTION SEMANTICS change, not just the cached shape: v2 adds
# the exact-name preference, and a v1 entry may hold a confidently wrong artist
# (Bush -> Kate Bush) that would otherwise persist for 30 days. v3 (0.56.36):
# the initials lift (_initialsLift), so a v2 "ELO" still holding the act
# literally named ELO goes now rather than in 30 days.
use constant MBID_CACHE_V => 3;
sub _mbidKey {
    my $k = 'dsc:mbid:' . MBID_CACHE_V . ':' . lc($_[0] // '');
    utf8::encode($k) if utf8::is_utf8($k);
    return $k;
}

use constant MBID_FOUND_TTL => 30 * 86400;
# Hoisted here from the alias section: the artist-name resolver caches MB's
# canonical name under this TTL, and a `use constant` must be declared
# textually BEFORE its first use or the bareword fails to compile.
use constant ALIAS_TTL => 30 * 86400;
use constant MBID_EMPTY_TTL =>       3600;

# Release-group lists change rarely (a new release every few months at most).
# The browse view's Refresh action bypasses this.
use constant RG_TTL => 14 * 86400;
# A list MusicBrainz cut at its cap, with nothing to complete it (0.56.40): kept
# an hour, so the next visit tries ListenBrainz and the community API again
# instead of drawing the cut list for RG_TTL. Found live 2026-10-02: ListenBrainz
# and the community API both timed out on Ella Fitzgerald's first visit after an
# install (ListenBrainz measured from outside LMS: 40 s without an answer, then
# 21 s), the page fell back to the browse, 600 of her 796 groups, and her Live
# albums section was gone for 14 days. 0.56.8 fixed this for a Refresh only.
use constant RGCUT_TTL => 3600;

# MB pagination: 100/page max; pages fetched serially with a courtesy gap
# (MB asks for <=1 req/s). 6 pages = 600 release groups — beyond any artist
# this UI can usefully show; truncation is logged.
use constant RG_PAGE_SIZE => 100;
use constant RG_MAX_PAGES => 6;
# (RG_PAGE_GAP removed in 0.51.17 — the queue supplies the gap, once.)

# An ARTIST lookup lists at most 25 of its release groups
# (`artist/<id>?inc=release-groups`) and gives no count, so exactly 25 may be
# cut short. Fewer is the whole list, and _readArtist caches it as the spine
# (stage 2; measured identical to the browse, see _readArtist).
use constant ARTIST_RG_LIST_MAX => 25;

# Bump when the cached release-group shape or filtering changes — versioned key
# invalidates every stale entry at once (the fleet's bump-every-layer rule).
use constant RG_CACHE_V => 'v2';   # v2 adds `aliases` to each entry

# UA per MB etiquette: identify the app + a contact URL. Version read from the
# plugin manifest so it can't drift.
my $_userAgent;
sub USER_AGENT {
    return $_userAgent if defined $_userAgent;
    my $ver = eval {
        Slim::Utils::PluginManager->dataForPlugin('Plugins::Discography::Plugin')->{version};
    };
    $ver = 'dev' unless defined $ver && length $ver;
    return $_userAgent =
        "LMS-Discography/$ver ( https://github.com/SimonArnold002/LMS-Discography )";
}

sub _rgKey { 'dsc:rg:' . RG_CACHE_V . ':' . $_[0] }

# ---------------------------------------------------------------------------
# Artist -> MBID
# ---------------------------------------------------------------------------

my $UUID_RE = qr/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

# The MusicBrainz artist id the library's own tag gives a contributor, or undef.
# The first thing getArtistMbid trusts; the search row check reads it too.
sub _libraryTagMbid {
    my ($artistId) = @_;
    return undef unless $artistId;
    my $mbid = eval {
        require Slim::Schema;
        my $c = Slim::Schema->find('Contributor', $artistId);
        $c ? $c->musicbrainz_id : undef;
    };
    return ($mbid && $mbid =~ $UUID_RE) ? lc $mbid : undef;
}

# getArtistMbid(artist_id => N, artist => 'Name', onDone => sub($mbid, $fromTag))
# Library tag wins (exact identity); for a library artist with no tag, the act
# its own albums name (C2, _libraryAlbumMbid); MB name search otherwise. onDone
# always fires exactly once. $fromTag is 1 when the mbid came from the library
# tag, 0 from the albums or a name search — the caller uses it to distinguish a trusted-but-possibly
# WRONG tag (a mis-tagged / merged same-name artist) from a name-search result,
# and to decide whether to try a fallback if the tag mbid has no discography.
# %a: artist (name), artist_id (library contributor), onDone,
#     speculative => 1  - see _artistMbidByName,
#     fetch => N        - entries the shared name search asks for (_nameSearch),
#     asked => \%h      - the search row check's settled counts (see
#                         filterRowsWithContent); the zero-release check marks
#                         the one it asked for.
sub getArtistMbid {
    my ($class, %a) = @_;
    my $onDone = $a{onDone} || sub {};

    if (my $mbid = _libraryTagMbid($a{artist_id})) {
        _dbg("artist mbid from library tag: $mbid");
        $onDone->($mbid, 1);
        return;
    }

    my $byName = sub {
        my ($cb) = @_;
        $class->_artistMbidByName($a{artist}, $cb, $a{speculative}, $a{fetch}, $a{asked});
    };
    # A library artist with no tag: its own albums say which act it is (C2,
    # _libraryAlbumMbid). Not for a speculative guess (the search's row check),
    # which reads that answer from the store instead.
    return _libraryAlbumMbid($a{artist_id}, $a{artist}, $byName, sub { $onDone->($_[0], 0) })
        if $a{artist_id} && !$a{speculative};
    $byName->(sub { $onDone->($_[0], 0) });
}

# Port of the ListenBrainz plugin's getArtistMbidByName: quoted artist query,
# top hit only, score gate >= 90 so a wrong same-name artist is rejected rather
# than adopted. '' is the cached "not found" sentinel.
#
# MIRROR SEARCH FALLBACK (field, 2026-07-10): a musicbrainz-docker mirror serves
# entity BROWSES (release-group?artist=<mbid>) straight from Postgres, but its
# SEARCH (?query=) goes through Solr — and a freshly imported mirror whose search
# indexes were never built returns count:0 for EVERY query while browses work
# perfectly. That silently fails every artist resolved by name (any contributor
# without a library MB tag), which is exactly how it presented ("Couldn't
# identify this artist" for Alison Krauss / Neil Hannon / Luke Haines while
# tagged artists worked). So when the configured base is a mirror and its search
# yields zero results (or is unreachable), we retry the SAME query ONCE against
# the public API before accepting a miss. The MBID is universal, so a public-
# resolved MBID then browses fine against the mirror.
# $speculative: this lookup is a GUESS about a name we were handed (the search
# row check), not a resolution the user asked for. Since stage 3 (2026-09-30)
# it changes ONE thing: an unproven mirror's empty or failed search is not
# retried against the public API — the retry that made one "Sonic Boom" search
# cost 61 public requests (2026-07-19). Every pass a page lookup runs (the alias
# field, the unquoted pass, the joint-credit split, the zero-release count)
# runs for a row too, on every setup: the row check exists to say what the page
# would show, and a row that skipped a pass could be kept or dropped on an
# answer its page never gives (analysis §A12, gates #3-#5 and the unquoted pass,
# which rows skipped even on a mirror). The bulk cost is paid differently now:
# filterRowsWithContent answers most rows from one or two shared searches, the
# community API most of the rest (stage 3b), and only a row it cannot decide
# (no releases listed) reaches this resolver.
#
# A speculative miss is simply "no answer" - the caller decides.
# The first act named in a joint credit, or undef when the string is not one.
# Splits on the FIRST separator only — "Stan Getz / João Gilberto feat. Antônio
# Carlos Jobim" yields "Stan Getz". Separators are matched with spaces around
# them so an ampersand INSIDE a name is left alone ("Hall & Oates" splits, but
# only after that whole name has failed to resolve, which it does not).
#   * `and` is included deliberately, and is safe ONLY because the caller has
#     already failed to resolve the whole string: "Belle and Sebastian" resolves,
#     so it never gets here.
#   * a head shorter than 3 characters is refused — "A & B" style noise would
#     resolve to something arbitrary, which is worse than the honest miss.
#
# 0.48.6: the splitter itself now lives in Sources::_creditParts, so "what
# counts as a joint credit" has ONE definition shared by the MusicBrainz side
# (this resolver, and the search-row fold) and the LIBRARY side (localAlbums'
# joint-credit lookup). Two copies of that regex would have drifted the moment
# either end learned a new separator.
sub _creditHead {
    my ($name) = @_;
    my @parts = Plugins::Discography::Sources::_creditParts($name);
    return undef unless @parts >= 2;
    my $head = $parts[0];
    return undef unless defined $head && length($head) >= 3;
    return undef if lc $head eq lc $name;    # nothing was actually removed
    return $head;
}

# MusicBrainz's special-purpose entities. These carry real, high-scoring rows in
# a search but are never a browsable ARTIST page, so a degenerate query must not
# resolve to one — measured (2026-07-23): artist:"La's" AND alias:"La's" both
# return "Various Artists" at score 100. Reserved mbids, stable forever.
my %MB_SPECIAL_ARTIST = map { $_ => 1 } (
    '89ad4ac3-39f7-470e-963a-56509c546377',   # Various Artists
    '125ec42a-7229-4250-afc5-e057484327fe',   # [unknown]
    'eec63d3c-3b81-4ad4-b1e4-7c147d4d2b61',   # [no artist]
    'f731ccc4-e22a-43af-a747-64213329e088',   # [anonymous]
    '9be7f096-97ec-4615-8957-8d40b5dcbc41',   # [traditional]
);

# NEVER ONE ARTIST (0.56.41; Simon, 2026-10-02: "we should not allow a search for
# Various Artists or look up on albums tagged with various artists or various
# composers. MB uses this to put any non artist compilation under it"). True for
# the special entities above, and for the names compilations are filed under:
# Various Artists, Various Composers, and LMS's own name for them (the
# variousArtistsString pref, which a user may have renamed). The callers ask
# nothing at all for one. Measured live on 0.56.40: a search asked the community
# API for 89ad4ac3's discography (no answer in 30 s); the library's Various
# Composers, tagged 89ad4ac3, drew 600 unrelated compilations in 10 s; a Various
# Artists with a dead tag browsed 89ad4ac3's six pages to disambiguate (14 s, 12
# requests). The names are compared under _nameKey, so "VARIOUS ARTISTS" is one.
sub isVarious {
    my ($class, $name, $mbid) = @_;
    return 1 if defined $mbid && $MB_SPECIAL_ARTIST{ lc $mbid };
    return 0 unless defined $name && length $name;
    my $k = _nameKey($name);
    return 0 unless length $k;
    my $lms = eval { Slim::Music::Info::variousArtistString() };
    return (grep { defined $_ && _nameKey($_) eq $k }
                 'Various Artists', 'Various Composers', $lms) ? 1 : 0;
}

# Is $cand plausibly the SAME artist as the query $want (both already _norm'd)?
# True when the names are token-subset-equal give or take a SINGLE token — an
# article or honorific ("beatles" vs "the beatles", "lauryn hill" vs "ms lauryn
# hill", or the query being the longer side, "british sea power" vs "sea
# power"). False when the candidate carries TWO or more extra name tokens ("the
# las" vs "the las vegas boneheads"), which signals a different, longer-named
# act. Used ONLY to decide whether to HOLD a quoted artist-field top hit and let
# the alias pass run; it never tightens the alias field (whose whole purpose is a
# differing name) or the loose pass (which has its own _closeEnough typo gate).
sub _plausibleName {
    my ($want, $cand) = @_;
    return 1 if $want eq $cand;
    return 0 unless Plugins::Discography::Sources::_artistMatch($want, $cand);
    my @tw = split ' ', $want;
    my @tc = split ' ', $cand;
    return (abs(@tw - @tc) <= 1) ? 1 : 0;
}

# SERVICE ANNOTATIONS ARE NOT PART OF THE NAME (see the resolver below for the
# measured reason). The name with its bracketed annotations removed, or the name
# itself when nothing would be left. Shared by the resolver's query and by
# _nameMemoForget, which must find the query the resolver sent.
sub _stripAnnotation {
    my ($name) = @_;
    my $q = $name;
    $q =~ s/\s*\([^)]*\)/ /g;
    $q =~ s/\s*\[[^\]]*\]/ /g;
    $q =~ s/\s+/ /g;
    $q =~ s/^\s+|\s+$//g;
    return length $q ? $q : $name;
}

# ---------------------------------------------------------------------------
# ONE NAME SEARCH, SHARED (stage 3 step 1; analysis §A10, §A12.6, §A12.8).
#
# The resolver's first pass (_artistMbidByName) and the same-name set
# (getArtistCandidates) ask MusicBrainz the same question, `artist:"<name>"`
# quoted: the resolver at limit 8, the set at limit 15. A cold page opened by
# name sent both, 1.1 s apart on the public API (found live, §A10), and a search
# resolving its typed query sends the same pair. Now the resolver asks at 15
# (NAME_FETCH) and the set reads that very reply. Measured over all 1,117
# library artists before this was built, the REAL resolver and set run on
# replies captured from the public API at limits 8, 15 and 100 (§A12.8):
#   * the resolver reads the first 8 entries of a reply at 15 or at 100 and
#     decides exactly as it does at 8, for every artist;
#   * the set read from the first 15 of a reply at 100 is NOT always what a reply
#     at 15 gives (equal scores in another order, a score off by one, now and
#     then a different member), and even a WHOLE small result can come back in
#     another order or with a score off by one at another limit. So the set
#     reads only a reply fetched at 15 (`exact`);
#   * a reply at 15 that is the whole result (88% of names) has exactly the
#     members a reply at 100 has, so the search row check — which reads only who
#     is in the result — uses it, and asks for 100 only when the result is
#     bigger (_rowBatch, NAME_FETCH_ROWS).
#
# A reply is kept in memory for NAME_MEMO_TTL per base, query and limit. A later
# caller is answered from a kept reply that serves it: at least its entries or
# the whole result, or, for an EXACT caller, a reply at its own limit. A caller
# arriving while such a request is in flight waits for it, and asks again itself
# only if the reply turns out not to serve it. Each caller gets its own SLICE,
# never the kept list: the resolver edits its list in place (it drops
# MusicBrainz's special entities).
#
# Only the QUOTED artist-field query is shared. The alias and unquoted passes run
# only after it has found nothing, and keep their own requests unchanged.
# ---------------------------------------------------------------------------
use constant NAME_FETCH      => 15;    # a page or a search: the resolver's 8 + the set's 15
use constant NAME_FETCH_ROWS => 100;   # the search row check, when the result is bigger
use constant NAME_MEMO_TTL   => 600;   # seconds; the search list's own cache is 10 min
use constant NAME_MEMO_MAX   => 64;    # kept replies, across queries and limits

# `our`, like %NET, so the suite can reset and inspect them: {key}{limit}.
our (%NAME_MEMO, %NAME_WAIT);
# The request each {key}{limit} in %NAME_WAIT is waiting on, for _netPromote.
our %NAME_JOB;

# The name-search request without its limit, byte for byte what both callers
# built before: UTF-8 octets, every non-alphanumeric byte percent-encoded.
sub _nameQuery {
    my ($field, $name, $loose) = @_;
    my $q = $loose ? $field . ':' . $name : $field . ':"' . $name . '"';
    utf8::encode($q) if utf8::is_utf8($q);
    (my $safe = $q) =~ s/([^A-Za-z0-9])/sprintf("%%%02X",ord($1))/ge;
    return 'artist?query=' . $safe . '&fmt=json';
}

# Does reply $r hold the first $want entries of the result? Yes when it was asked
# for at least that many, or when it is the whole result set (fewer entries than
# asked for, or no more than MusicBrainz counted).
sub _nameCovers {
    my ($r, $want) = @_;
    return 1 if $r->{limit} >= $want;
    my $n = scalar @{ $r->{arts} };
    return 1 if $n < $r->{limit};
    return 1 if defined $r->{count} && $r->{count} =~ /^\d+$/ && $r->{count} <= $n;
    return 0;
}

sub _nameSlice {
    my ($arts, $want) = @_;
    my $n = @$arts < $want ? scalar @$arts : $want;
    return [ @{$arts}[0 .. $n - 1] ];
}

sub _nameMemoPut {
    my ($key, $limit, $r) = @_;
    $NAME_MEMO{$key}{$limit} = $r;
    my @all = map { my $k = $_; map { [ $k, $_, $NAME_MEMO{$k}{$_}{at} ] } keys %{ $NAME_MEMO{$k} } }
              keys %NAME_MEMO;
    return if @all <= NAME_MEMO_MAX;
    my $cut  = Time::HiRes::time() - NAME_MEMO_TTL;
    my @drop = grep { $_->[2] <= $cut } @all;
    my @keep = sort { $a->[2] <=> $b->[2] } grep { $_->[2] > $cut } @all;
    push @drop, @keep[0 .. @keep - NAME_MEMO_MAX - 1] if @keep > NAME_MEMO_MAX;
    for my $d (@drop) {
        delete $NAME_MEMO{ $d->[0] }{ $d->[1] };
        delete $NAME_MEMO{ $d->[0] } unless %{ $NAME_MEMO{ $d->[0] } };
    }
    return;
}

# Refresh must ask MusicBrainz again, not answer from a reply kept a minute ago.
# Drops the kept replies for $name's quoted query, as the resolver sends it
# (annotation stripped) and as the same-name set sends it, on any base and limit.
sub _nameMemoForget {
    my ($name) = @_;
    return unless defined $name && length $name;
    my %q = map { _nameQuery('artist', $_, 0) => 1 } $name, _stripAnnotation($name);
    for my $key (keys %NAME_MEMO) {
        for my $q (keys %q) {
            next unless length($key) >= length($q) && substr($key, -length $q) eq $q;
            delete $NAME_MEMO{$key};
            last;
        }
    }
    return;
}

# _nameSearch($base, $q, $want, $fetch, $onOk, $onErr, $label, $exact)
#   $q      _nameQuery() of the search
#   $want   how many entries this caller reads
#   $fetch  how many to ask for when it has to send (never fewer than $want)
#   $onOk   ->(\@arts, $parseErr, $contentLength, $count): the first $want
#           entries, or undef when the reply did not parse ($parseErr then says
#           why); $count is MusicBrainz's count of the whole result
#   $onErr  ->(@_ of the HTTP error callback), exactly as _netGet hands it over
#   $label  for the log only
#   $exact  only a reply fetched at $fetch may answer (the same-name set)
sub _nameSearch {
    my ($base, $q, $want, $fetch, $onOk, $onErr, $label, $exact) = @_;
    $fetch = $want if !$fetch || $fetch < $want;
    my $key = $base . $q;
    my $now = Time::HiRes::time();
    my $serves = sub {
        my ($limit, $r, $w, $f, $ex) = @_;
        return $ex ? $limit == $f : _nameCovers($r, $w);
    };

    # A kept reply that serves this caller, the smallest first.
    if (my $memo = $NAME_MEMO{$key}) {
        for my $l (sort { $a <=> $b } keys %$memo) {
            my $m = $memo->{$l};
            if ($m->{at} + NAME_MEMO_TTL <= $now) { delete $memo->{$l}; next }
            next unless $serves->($l, $m, $want, $fetch, $exact);
            _dbg('name search ' . ($label // $q) . ": answered from the reply kept"
                . " a moment ago (limit $l, first $want read)");
            $onOk->(_nameSlice($m->{arts}, $want), '', $m->{len}, $m->{count});
            return;
        }
        delete $NAME_MEMO{$key} unless %$memo;
    }

    # A request in flight that may serve it: an exact caller waits only on its
    # own limit; the rest on the largest in flight (a smaller one may still turn
    # out to be the whole result).
    # Each waiter keeps its own background flag (see $NET_BG).
    my $entry = [ $want, $fetch, $onOk, $onErr, $label, $exact, $NET_BG ];
    if (my $waits = $NAME_WAIT{$key}) {
        my ($l) = $exact ? grep { $_ == $fetch } keys %$waits
                         : sort { $b <=> $a } keys %$waits;
        if (defined $l) {
            push @{ $waits->{$l} }, $entry;
            _netPromote($NAME_JOB{$key}{$l}) unless $NET_BG;
            return;
        }
    }
    $NAME_WAIT{$key}{$fetch} = [ $entry ];

    my $job = _netGet($base . $q . '&limit=' . $fetch,
        sub {
            my $resp     = shift;
            my $content  = $resp->content;
            my $data     = eval { from_json($content) };
            my $parseErr = $@;
            my $arts = (!$parseErr && ref $data eq 'HASH' && ref $data->{artists} eq 'ARRAY')
                       ? $data->{artists} : undef;
            my $len = length($content // '');
            # Released BEFORE the callbacks run, as getArtistCandidates' own
            # marker is: one of them may ask again, and a marker still held would
            # wedge the query with nothing in flight to release it.
            my $cbs = delete $NAME_WAIT{$key}{$fetch};
            delete $NAME_WAIT{$key} unless %{ $NAME_WAIT{$key} || {} };
            delete $NAME_JOB{$key}{$fetch};
            delete $NAME_JOB{$key} unless %{ $NAME_JOB{$key} || {} };
            my $r;
            if ($arts) {
                $r = { arts => $arts, limit => $fetch, count => $data->{count},
                       len => $len, at => Time::HiRes::time() };
                _nameMemoPut($key, $fetch, $r);
            }
            for my $c (@{ $cbs || [] }) {
                my ($cw, $cf, $ok, $err, $lbl, $ex, $bg) = @$c;
                local $NET_BG = $bg;
                # A waiter this reply does not serve after all asks again itself.
                if ($r && !$serves->($fetch, $r, $cw, $cf, $ex)) {
                    _nameSearch($base, $q, $cw, $cf, $ok, $err, $lbl, $ex);
                    next;
                }
                $ok->($arts ? _nameSlice($arts, $cw) : undef, $parseErr, $len,
                      $r ? $r->{count} : undef);
            }
        },
        sub {
            my @e = @_;
            my $cbs = delete $NAME_WAIT{$key}{$fetch};
            delete $NAME_WAIT{$key} unless %{ $NAME_WAIT{$key} || {} };
            delete $NAME_JOB{$key}{$fetch};
            delete $NAME_JOB{$key} unless %{ $NAME_JOB{$key} || {} };
            for my $c (@{ $cbs || [] }) {
                local $NET_BG = $c->[6];
                $c->[3]->(@e);
            }
        },
        timeout => 12);
    # Kept only while the request is still waited on: a transport that answers
    # at once has already settled it.
    $NAME_JOB{$key}{$fetch} = $job if $NAME_WAIT{$key} && $NAME_WAIT{$key}{$fetch};
    return;
}

# ---------------------------------------------------------------------------
# THE INITIALS LIFT (0.56.36, resolver plan C1; Simon 2026-10-02: "we should be
# looking at alieses for this if no alias for initials then we dont pass it,
# keep it simple"). The exact-name preference (0.44.14) opens an act LITERALLY
# named what was asked for, so an abbreviation opened an obscure act of that
# name: "ELO" a Korean singer, "PIL" a Danish Pil. For a SHORT name (2-5
# letters once spaces and dots go) the resolver asks one combined query,
# `artist:"X" OR alias:"X"`, and takes an act instead when ALL of:
#   1. MusicBrainz lists X as one of its ALIASES (no alias, no lift);
#   2. its own name's initials spell X (_initials) -- without this, an alias
#      alone moved Luna -> DJ Luna, Lamb -> Cainon Lamb, Cast -> [theatre];
#   3. an act NAMED X exists, and this one scores above every such act -- with
#      no act named X the resolver's own alias pass already answers (BTO), and
#      lifting there broke OMD (-> Of Mexican Descent).
# The best-scoring act wins. Measured on the PUBLIC API 2026-10-02 (ledger A3
# `THE INITIALS LIFT NEEDS AN ACT NAMED THE ABBREVIATION`): ELO, PIL, NIN, EBTG
# lift; ABC, TLC, HAIM, KLF, Bob, REM, GnR, SFA, OMD, BTO unchanged; none of the
# library's 73 short-named album artists changes.
# The shared-name guard must not call a lifted band the lesser act of a name it
# is not literally called (_abbreviates).
# ---------------------------------------------------------------------------

# The initials of a multi-word name ("Electric Light Orchestra" -> "elo"), or ''
# when there is no initialism to speak of: a one-word name, or a name that is
# already single letters ("B.o.B", "R.E.M.") -- an abbreviation, not a name
# spelled out; letting it lift made "Bob" open B.o.B (the 0.57.0 stash, measured).
sub _initials {
    my @w = split ' ', _nameKey($_[0]);
    return '' unless @w >= 2 && grep { length > 1 } @w;
    return join '', map { substr($_, 0, 1) } @w;
}

# The lift's key: the name folded with spaces dropped, when it is 2-5 letters;
# '' otherwise (no lift is asked for).
sub _initialsKey {
    (my $k = _nameKey($_[0])) =~ s/ //g;
    return (length($k) >= 2 && length($k) <= 5) ? $k : '';
}

# Which act of a combined reply the rule lifts, or undef. Pure (tools/t_initials.pl).
sub _liftFrom {
    my ($name, $arts) = @_;
    my $key = _initialsKey($name) or return undef;
    my $want = _nameKey($name);
    my ($named, $top, @alias) = (0, 0);
    for my $art (@{ ref $arts eq 'ARRAY' ? $arts : [] }) {
        next unless ref $art eq 'HASH' && $art->{id} && !$MB_SPECIAL_ARTIST{ lc $art->{id} };
        my $score = $art->{score} // 0;
        if (_nameKey($art->{name}) eq $want) {
            $named = 1;
            $top = $score if $score > $top;
            next;
        }
        next unless grep { ref $_ eq 'HASH' && _nameKey($_->{name} // '') eq $want }
                    @{ ref $art->{aliases} eq 'ARRAY' ? $art->{aliases} : [] };
        push @alias, $art if _initials($art->{name}) eq $key;
    }
    return undef unless $named;
    my ($best) = sort { ($b->{score} // 0) <=> ($a->{score} // 0) }
                 grep { ($_->{score} // 0) > $top } @alias;
    return $best;
}

# Does $mbid's own name abbreviate to $name ("Electric Light Orchestra" for
# "ELO")? Then the page is that band, not a lesser act sharing the name ELO.
# Read from MB's canonical name (peekArtistName: the kept artist table, written
# by the lift itself), NOT a marker of its own: a kv marker is emptied by every
# new build while the name's answer (the kept mbid table) survives it, so the
# band would lose its bio again after an update.
sub _abbreviates {
    my ($name, $mbid) = @_;
    my $key = _initialsKey($name) or return 0;
    return 0 unless $mbid;
    my $canon = __PACKAGE__->peekArtistName($mbid);
    return (defined $canon && _initials($canon) eq $key) ? 1 : 0;
}

# _initialsLift($name, sub($art|undef)): one combined query for a short name.
# Any failure answers undef, so the resolver keeps the answer it had.
sub _initialsLift {
    my ($class, $name, $cb) = @_;
    return $cb->(undef) unless _initialsKey($name);
    my $q = 'artist:"' . $name . '" OR alias:"' . $name . '"';
    utf8::encode($q) if utf8::is_utf8($q);
    (my $safe = $q) =~ s/([^A-Za-z0-9])/sprintf("%%%02X",ord($1))/ge;
    _netGet(_mbBase() . 'artist?query=' . $safe . '&fmt=json&limit=25',
        sub {
            my $data = eval { from_json(shift->content) };
            my $arts = (!$@ && ref $data eq 'HASH' && ref $data->{artists} eq 'ARRAY') ? $data->{artists} : [];
            $cb->(_liftFrom($name, $arts));
        },
        sub { $cb->(undef) },
        timeout => 12);
    return;
}

# $fetch: how many entries the shared first pass asks for when it has to send
# (NAME_FETCH on a page or a search, 8 otherwise). The resolver reads the first
# 8 whatever it fetched; the extra entries are for the same-name set that comes
# after it (see _nameSearch).
# $asked: the search row check's settled counts (filterRowsWithContent); the
# zero-release check below marks the count it asked for once it has settled.
sub _artistMbidByName {
    my ($class, $name, $onDone, $speculative, $fetch, $asked) = @_;

    $name = defined $name ? $name : '';
    $name =~ s/^\s+|\s+$//g;
    unless (length $name) { $onDone->(undef); return; }

    my $cacheKey = _mbidKey($name);
    if (defined(my $c = $cache->get($cacheKey))) {
        _dbg("artist mbid cache hit '$name': " . ($c || 'NOT-FOUND sentinel (retried daily)'));
        $onDone->($c || undef);
        return;
    }

    # Fielded exact-phrase query. The 'artist' field searches the NAME only —
    # an artist reachable solely through an MB ALIAS ("The Oh Sees" -> Osees)
    # returns 0 results there, so a second stage retries the 'alias' field
    # (verified live: artist:"The Oh Sees" = 0, alias:"The Oh Sees" = score
    # 100). Alias runs ONLY when the name field found nothing acceptable, so
    # it can never change a resolution that works today.
    # SERVICE ANNOTATIONS ARE NOT PART OF THE NAME. Streaming catalogues append
    # a parenthetical the artist is not actually called — "Daryl Hall and John
    # Oates (Hall and Oates)", "Anthrax (US)", "!!! (Chk Chk Chk)".
    # MusicBrainz keeps that OUT of the name (it has a separate disambiguation
    # field), so the annotation GUARANTEES zero results: measured 2026-07-21,
    # `artist:"Daryl Hall and John Oates (Hall and Oates)"` returns nothing
    # while `artist:"Daryl Hall and John Oates"` scores 100. The search row was
    # therefore dropped as a dead end and the band was unreachable.
    #
    # UNCONDITIONAL, and safe because the unstripped query is ALREADY broken:
    # parentheses are Lucene syntax and survive our percent-encoding, so MB
    # returns nothing for them even inside a quoted phrase. Measured on two
    # unrelated names — `artist:"(Sandy) Alex G"` and the Hall & Oates row
    # above both return ZERO — so there is no working resolution to regress,
    # only a failing one to rescue. The `>= 90` score gate and the exact-name
    # preference still apply to whatever comes back (and `_norm` strips
    # brackets too, so the preference compares like for like).
    #
    # Stripped for the QUERY only — the cache key keeps the caller's spelling,
    # so each service spelling caches its own entry pointing at the same mbid.
    # Falls back to the original if stripping would leave nothing (a name that
    # IS a parenthetical).
    my $qname = _stripAnnotation($name);
    _dbg("MB artist search: querying '$qname' (annotation stripped from '$name')")
        if $qname ne $name;

    # $loose drops the quotes, turning an exact PHRASE into ordinary terms.
    #
    # WHY (field, 2026-07-21 — Simon: "If I search Janes Addiction in MB it finds
    # it straight away top hit, I dont understand your last comment"). He was
    # right, and the quoting was ours, not MusicBrainz's. Measured on the mirror:
    #   artist:"janes addiction"  -> count 0     (an exact phrase cannot match
    #   janes addiction           -> count 239    "Jane's Addiction", which
    #   artist:janes addiction    -> count 208    tokenises [jane][s][addiction])
    # with Jane's Addiction the TOP HIT at score 100 in both unquoted forms —
    # exactly what musicbrainz.org's own search box does.
    #
    # The quoted form stays PRIMARY and unloosened: it is precise, and every name
    # that resolves today must keep resolving identically. The loose pass runs
    # only after the quoted artist AND alias passes have both found nothing, so
    # it can only ever rescue a definite miss.
    my $mkQuery = sub {
        my ($field, $loose) = @_;
        # limit=8, not 1: MB's top hit is not necessarily the artist ASKED
        # for (see the exact-name preference below).
        return _nameQuery($field, $qname, $loose) . '&limit=8';
    };

    # The configured base is a mirror when it is NOT the public host; only then is
    # the public retry available (and only once, guarded by $isFallback).
    my $mirror = !_mbThrottled();

    my $save = sub {
        my ($mbid) = @_;
        eval { $cache->set($cacheKey, $mbid, $mbid ? MBID_FOUND_TTL : MBID_EMPTY_TTL); 1 }
            or $log->warn("artist-mbid cache set failed: $@");
        $onDone->($mbid || undef);
    };
    # The initials lift (above), last, on whatever the passes settled on.
    my $store = sub {
        my ($mbid) = @_;
        $class->_initialsLift($name, sub {
            my ($art) = @_;
            if ($art && lc $art->{id} ne lc($mbid // '')) {
                my $lifted = lc $art->{id};
                _dbg("MB artist search '$name': initials lift - '" . ($art->{name} // '?')
                    . "' ($lifted, aka '$name') over " . ($mbid || 'nothing'));
                # Its canonical name, kept: the page's name, and what
                # _abbreviates reads for the shared-name guard.
                $mbNameMem{$lifted} = $art->{name} if defined $art->{name};
                _setMbName($lifted, $art->{name});
                $mbid = $lifted;
            }
            $save->($mbid);
        });
    };

    # A ZERO-RELEASE ARTIST IS NOT AN ANSWER — but it is a fallback of last
    # resort, and holding it here rather than discarding it is what makes this
    # safe (0.47.1).
    #
    # FIELD: browsing "Shostakovich" rendered "No releases found" while Tidal
    # held 111 real candidates. Measured on the mirror:
    #     artist:"Shostakovich" -> 100 Shostakovich Trio  (Group, 0 release groups)
    #     alias:"Shostakovich"  -> 100 Дмитрий Дмитриевич Шостакович
    # The composer's MB canonical name is CYRILLIC, so the `artist:` field can
    # never find him and only the alias pass can — but the alias pass runs on
    # FAILURE, and the artist pass "succeeded" by taking a group that shares his
    # surname and has catalogued nothing. The same shape as 0.43.7 and 0.44.28:
    # a confident-looking first hit stopping a better pass.
    #
    # These live OUTSIDE $run so the held hit survives the alias / unquoted /
    # credit-split passes. If none of them does better it is stored anyway, so
    # the worst case is byte-identical to the old behaviour — this can rescue a
    # dead page, never break a working one.
    my ($zeroMbid, $zeroName) = ('', '');
    my %counted;

    # Pass the sub to itself ($self) rather than capturing $run lexically: a
    # self-capturing closure is a reference cycle Perl never reclaims, and this
    # resolver runs once per name-resolved artist, so each call would leak a little
    # memory. $self keeps the CV alive across the async gap (the in-flight callbacks
    # hold it) and frees when they finish. (Ported from LBF 0.9.95.)
    my $run = sub {
        my ($self, $base, $isFallback, $field, $loose) = @_;
        $log->info("resolving artist name to MBID: $name ($field field"
            . ($loose ? ', unquoted' : '')
            . ($isFallback ? ', public fallback' : '') . ')');

        # The reply, however it arrived: its own request or the shared one
        # (dispatch at the end of $run). $arts is this pass's list (the first 8
        # entries), undef when the reply did not parse; $parseErr says why and
        # $len is the reply's size, for the "unparseable" report.
        my $onReply =
            sub {
                my ($arts, $parseErr, $len) = @_;

                # Zero results on an UNPROVEN mirror = probable unbuilt search
                # index -> retry the public API once before caching a miss. Once
                # proven, a 0 is a REAL 0 and the retry is a wasted internet round
                # trip (see MB_SEARCH_OK_TTL). Evaluated before the $speculative
                # test so a non-empty result still proves the index.
                if (_mbSearchVerdict($arts, $mirror, $isFallback) && !$speculative) {
                    _dbg("MB artist search '$name' ($field) => 0 results on mirror; retrying public API");
                    $self->($self, MB_DEFAULT_BASE_URL, 1, $field, $loose);
                    return;
                }

                my $mbid = '';
                my $why  = 'no results';
                # MB's canonical name for the winner, captured in the block
                # below where $a is in scope (see the note at the cache write).
                my $canonName = '';
                # Did the winner's name FAIL the exact-name preference? That is
                # the only case worth spending a release-group count on: an
                # artist named exactly what was asked for is the artist asked
                # for, while "Shostakovich" -> "Shostakovich Trio" is precisely
                # the shape that goes wrong. Captured here for the same scoping
                # reason as $canonName.
                my $inexact = 0;
                # Drop MB's special-purpose entities (Various Artists, [unknown],
                # ...) so neither the exact-name preference nor the top-hit
                # fallback can adopt one — a degenerate query ("La's") returns
                # Various Artists at score 100 on both the artist and alias fields.
                @$arts = grep { $_->{id} && !$MB_SPECIAL_ARTIST{ lc $_->{id} } } @$arts
                    if $arts;
                if ($arts && @$arts) {
                    # EXACT-NAME PREFERENCE (0.44.14).
                    #
                    # MB's Lucene score alone picks the wrong artist for common
                    # surnames: artist:"Bush" returns KATE BUSH at 100 with the
                    # English rock band named exactly "Bush" second at 95. The
                    # old code took the top hit whenever it scored >=90, so
                    # searching Bush drilled into Kate Bush's discography and
                    # matched none of the user's albums (field, 2026-07-19:
                    # "i see Kate Bush under Bush and none of thier albums").
                    #
                    # So: if any candidate's NAME equals what was asked for
                    # (after _norm, which folds case/punctuation/accents), take
                    # the best-scoring such candidate. Otherwise fall back to
                    # the previous top-hit rule, which is what keeps "Beatles"
                    # -> The Beatles working: no candidate is named exactly
                    # "Beatles", and the intended artist is the top hit.
                    my $want = Plugins::Discography::Sources::_norm($name);
                    my ($exact) = grep {
                        $_->{id} && ($_->{score} // 0) >= 90
                        && Plugins::Discography::Sources::_norm($_->{name} // '') eq $want
                    } @$arts;

                    my $a = $exact || $arts->[0];
                    # THE SCORE GATE IS NEARLY A NO-OP ON A LOOSE QUERY, and that
                    # is the whole risk of unquoting: Lucene normalises the best
                    # match to 100, so ANY unquoted search returning rows offers a
                    # >=90 top hit. Left alone, a nonsense query would adopt
                    # whatever came back and show the wrong discography — strictly
                    # worse than the honest miss it replaces.
                    #
                    # So on the loose pass the winner must also BE the artist that
                    # was asked for: either the exact-name preference matched (its
                    # `_norm` name equals the query), or `_closeEnough` accepts it
                    # — the same tested typo gate the search rows use. Measured:
                    #   janes addiction         -> Jane's Addiction       ACCEPT
                    #   sigor ros               -> Sigur Ros              ACCEPT
                    #   flornce and the machine -> Florence + the Machine ACCEPT
                    #   blue addiction          -> Jane's Addiction       reject
                    #   addiction               -> Jane's Addiction       reject
                    my $close = !$loose || $exact
                        || Plugins::Discography::Sources::_closeEnough(
                               $want, Plugins::Discography::Sources::_norm($a->{name} // ''));
                    if (!$a->{id} || ($a->{score} // 0) < 90) {
                        $why = "top hit '" . ($a->{name} // '?') . "' score " . ($a->{score} // '?') . ' < 90';
                    }
                    elsif (!$close) {
                        $why = "unquoted top hit '" . ($a->{name} // '?')
                             . "' is not the artist asked for";
                    }
                    elsif ($field eq 'artist' && !$loose && !$exact
                           && !_plausibleName($want,
                                  Plugins::Discography::Sources::_norm($a->{name} // ''))) {
                        # A quoted ARTIST-field top hit that only CONTAINS the
                        # query as a token subset with a whole extra name is
                        # probably a DIFFERENT act: artist:"The Las" -> "The Las
                        # Vegas Boneheads" (100), while the intended "The La's" is
                        # not in the artist-field results at all (Lucene tokenises
                        # it [the][la][s]). HOLD it as a last-resort fallback and
                        # let the alias pass run — alias:"The Las" DOES return
                        # "The La's" at 100, accepted there (an alias match is
                        # trusted by design, 0.32.0). The SAME held-fallback slot
                        # the zero-release hit uses (below): if no later pass does
                        # better it is stored, so a resolution that works today is
                        # untouched. The gate fires only at +2 tokens, so "Beatles"
                        # -> "The Beatles" and "Lauryn Hill" -> "Ms. Lauryn Hill"
                        # (both +1) are accepted here, exactly as before.
                        ($zeroMbid, $zeroName) = (lc $a->{id}, $a->{name} // '')
                            unless $zeroMbid;
                        $why = "artist-field top hit '" . ($a->{name} // '?')
                             . "' adds a whole name - held, trying alias";
                    }
                    else {
                        $mbid = lc $a->{id};
                        $canonName = $a->{name} // '';
                        $inexact   = $exact ? 0 : 1;
                        _dbg("MB artist search '$name': exact-name candidate '"
                            . ($a->{name} // '?') . "' (score " . ($a->{score} // '?')
                            . ") preferred over top hit '"
                            . ($arts->[0]{name} // '?') . "' (score "
                            . ($arts->[0]{score} // '?') . ')')
                            if $exact && $arts->[0] != $exact;
                    }
                }
                # Report the ACTUAL error, and how much content came back --
                # "unparseable" alone sent a diagnosis after an encoding bug
                # that did not exist. A parse failure is now distinguishable
                # from an honest empty result, which keeps $why = 'no results'.
                elsif ($parseErr) {
                    ($why = "unparseable MB response ($len bytes: $parseErr)") =~ s/\s+/ /g;
                }

                my $decide = sub {
                    # Name field found nothing acceptable -> ONE alias-field pass
                    # (same base/fallback state; the mirror-0-results branch above
                    # still gives the alias pass its own public retry). A search
                    # row gets it too, on every setup (stage 3; see $speculative):
                    # it is what makes an alias-only spelling reachable at all
                    # (measured 2026-07-21): `alias:"Hall And Oates"` and even the
                    # misspelled `alias:"Darryl Hall and John Oates"` both return
                    # Daryl Hall & John Oates at score 100, while the artist field
                    # returns NOTHING for either — so every service row for that
                    # band was dropped as a dead end and the band was unreachable.
                    if (!$mbid && $field eq 'artist' && !$loose) {
                        _dbg("MB artist search '$name' => $why on name field; retrying alias field");
                        $self->($self, $base, $isFallback, 'alias');
                        return;
                    }

                    # LAST PASS — drop the quotes (see $mkQuery). Reached only when
                    # BOTH quoted passes found nothing, so there is no working
                    # resolution to regress, only a failing one to rescue. A search
                    # row runs it too since stage 3: rows skipped it on EVERY setup
                    # before, a mirror included, so a row could be dropped as a dead
                    # end for a name its page resolves ("janes addiction").
                    if (!$mbid && !$loose) {
                        _dbg("MB artist search '$name' => $why; retrying unquoted");
                        $self->($self, $base, $isFallback, 'artist', 1);
                        return;
                    }
                    # NOTHING BETTER TURNED UP -> give back the release-less hit
                    # we held. This is the line that makes the whole change
                    # safe: every path that used to return that artist still
                    # returns it, so a page that works today cannot break.
                    if (!$mbid && $zeroMbid) {
                        _dbg("MB artist search '$name': no artist with releases found"
                            . " - falling back to '" . ($zeroName || '?') . "' ($zeroMbid)");
                        ($mbid, $canonName) = ($zeroMbid, $zeroName);
                    }
                    # MB's CANONICAL name is already in the response we just paid
                    # for -- capture it (0.44.20's "free, it was in the response"
                    # pattern). It matters most on the ALIAS path: the user browses
                    # "British Sea Power" and MB answers with the renamed act,
                    # "Sea Power", which is the name the streaming services file it
                    # under. Without this the services are only ever asked for the
                    # old name, and Qobuz (which does not absorb it) settles
                    # unresolved -- 24/52 releases, no Qobuz at all.
                    # NB $canonName, not $a: `my $a` lives INSIDE the block above,
                    # and `$a` out here is sort's global -- silently undef, no
                    # strict error. That is the 0.44.18 shadowing trap exactly.
                    if ($mbid && $canonName ne '') {
                        $mbNameMem{ lc $mbid } = $canonName;
                        _setMbName($mbid, $canonName);
                    }
                    # TTL named from the constant, not a literal: this said "1d" for
                    # months after 0.23.1 shortened it to 1h, and a diagnostic that
                    # lies about cache lifetime is exactly how the next
                    # investigation goes wrong (0.23.1 was itself a poisoned miss).
                    # A JOINT CREDIT IS NOT AN ARTIST NAME — resolve its FIRST act
                    # (0.47.0). Field, from the full-library sweep: albums whose
                    # ALBUMARTIST is a joint credit dead-ended on
                    # "Couldn't identify this artist":
                    #     Stan Getz / João Gilberto feat. Antônio Carlos Jobim
                    #     Charlie Parker & Dizzy Gillespie
                    #     Django Reinhardt & Jean Sablon
                    # MusicBrainz has no ARTIST for those: it models them as an
                    # artist CREDIT of two artists on the release, so every pass
                    # above is asking for something that cannot exist.
                    #
                    # MEASURED SCOPE, and the guard is the whole design. 49 of
                    # Simon's 1107 album artists look like joint credits, but 36 of
                    # them are real band names that resolve fine — Belle and
                    # Sebastian, Nick Cave & the Bad Seeds, Booker T. & the MG's.
                    # They never reach this line. 13 failed on MusicBrainz; the
                    # plugin's own alias/unquoted passes already rescue 2 of those
                    # (Antony and the Johnsons, Echo and the Bunnymen), and the
                    # remaining 11 are exactly what this recovers.
                    #
                    # So it runs ONLY where a definite miss would otherwise be
                    # cached — the same shape as 0.32.0's alias retry and 0.44.28's
                    # unquoted pass: it can rescue a failure, never change a
                    # resolution that works. The result is cached under the JOINT
                    # name, so the cost is one extra lookup per such artist per 30
                    # days.
                    #
                    # The rest follows for free, both verified before building:
                    # `_artistMatch` is a token-subset test and the joint credit is
                    # the LARGER set, so candidates credited "Stan Getz" still
                    # match; and 0.45.0 puts MB's canonical name at the front of the
                    # service alias list, so the services get asked for "Stan Getz"
                    # rather than the unsearchable joint string.
                    if (!$mbid && (my $head = _creditHead($name))) {
                        _dbg("MB artist search '$name' => $why; "
                            . "treating as a joint credit, resolving '$head'");
                        $class->_artistMbidByName($head, sub {
                            my ($alt) = @_;
                            _dbg("joint credit '$name' -> " . ($alt || 'still nothing'));
                            # A held release-less hit still beats nothing — this
                            # is the last exit before a miss is cached.
                            $store->($alt || $zeroMbid);
                        }, $speculative, undef, $asked);
                        return;
                    }
                    _dbg("MB artist search '$name' ($field"
                        . ($loose ? ', unquoted' : '') . ') => '
                        . ($mbid || "NO MATCH ($why; cached "
                                    . int(MBID_EMPTY_TTL / 60) . 'm)')
                        . ($isFallback ? ' [via public fallback]' : ''));
                    $store->($mbid);
                };

                # DOES THE WINNER ACTUALLY HAVE A DISCOGRAPHY? Asked only when
                # its name is NOT what was searched for — an exact-name winner
                # is the artist asked for and pays nothing, so the ordinary
                # artist is untouched (measured by test: "Radiohead" issues zero
                # release-group requests).
                #
                # A search row asks it too since stage 3 (see $speculative); the
                # count is the community API's first (warmCandidateCounts) and
                # lands in the cache the row check reads next, so the row pays
                # for it once: the check is told it has settled ($asked), and
                # judges the row from it rather than asking again if it failed.
                # This check itself never skips on $asked: its answer is cached
                # for 30 days as the name's resolution.
                if ($mbid && $inexact && !$counted{$mbid}++) {
                    $class->warmCandidateCounts([ { mbid => $mbid } ], sub {
                        $asked->{ lc $mbid } = 1 if $asked;
                        my $n = $class->peekReleaseGroupCount($mbid);
                        # undef = the count could not be fetched. FAIL OPEN:
                        # an HTTP error is not evidence of an empty catalogue,
                        # and hiding a real artist is far worse than showing a
                        # thin one (0.43.5's rule, same cache).
                        if (defined $n && $n == 0) {
                            _dbg("MB artist search '$name' ($field): '"
                                . ($canonName || '?') . "' ($mbid) has NO release"
                                . ' groups - held as a fallback, looking further');
                            ($zeroMbid, $zeroName) = ($mbid, $canonName)
                                unless $zeroMbid;
                            ($mbid, $canonName) = ('', '');
                            $why = 'top hit has no releases';
                        }
                        $decide->();
                    });
                    return;
                }
                $decide->();
            };
        my $onError =
            sub {
                my $err = shift->error // '?';
                # A mirror unreachable for search: fall back to public once.
                if ($mirror && !$isFallback && !$speculative) {
                    _dbg("MB artist search '$name' ($field) => mirror error ($err); retrying public API");
                    $self->($self, MB_DEFAULT_BASE_URL, 1, $field, $loose);
                    return;
                }
                $log->error("MB artist search failed: $err");
                _dbg("MB artist search '$name' ($field) => HTTP error ($err; not cached, retry works)");
                $onDone->(undef);
            };

        # THE QUOTED ARTIST-FIELD PASS IS THE SHARED ONE (see _nameSearch): the
        # same-name set asks exactly this query, so one reply serves both. The
        # first 8 entries are read here whatever $fetch asked for.
        if ($field eq 'artist' && !$loose) {
            _nameSearch($base, _nameQuery('artist', $qname, 0), 8, $fetch,
                        $onReply, $onError, "'$qname'");
            return;
        }
        _netGet($base . $mkQuery->($field, $loose),
            sub {
                my $resp = shift;
                # CAPTURE THE PARSE ERROR HERE, not 80 lines below. $@ is a
                # GLOBAL, and the old code re-read it at the "unparseable"
                # branch after several intervening calls (_mbSearchVerdict ->
                # _mbSearchProve is itself an eval, _dbg, _norm, _closeEnough) --
                # any of which can reset it. Field symptom: a legitimately EMPTY
                # result was reported as "unparseable MB response".
                # Proven not to be a real parse failure: the exact URL this
                # builds for "British Sea Power" returns valid JSON with count=0
                # on BOTH the mirror and public MB -- correct, because MB knows
                # that name only as an ALIAS of "Sea Power". (_nameSearch
                # captures it the same way for the shared pass.)
                my $data     = eval { from_json($resp->content) };
                my $parseErr = $@;
                my $arts = (!$parseErr && ref $data eq 'HASH'
                            && ref $data->{artists} eq 'ARRAY')
                           ? $data->{artists} : undef;
                $onReply->($arts, $parseErr, length($resp->content // ''));
            },
            $onError,
            timeout => 12);
    };

    $run->($run, _mbBase(), 0, 'artist', 0);
}

# ---------------------------------------------------------------------------
# AN UNTAGGED LIBRARY ARTIST IS NAMED BY ITS OWN ALBUMS (resolver plan C2).
#
# With no MusicBrainz tag on the files, the page resolved by name and took the
# best-scoring act of that name: Simon's Welsh band Jack opened Jack Johnson, his
# Roswell (MusicBrainz's "Roswell Road", an alias no name search reaches) a
# psytrance act, Muzz the producer MUZZ, Rico an MC (2026-07-22 triage, still so
# on 0.56.20). An album title is far more particular than a name, so the owned
# albums are asked instead: `releasegroup:"<title>" AND artist:"<name>"`, and
# the act credited on the hits with that very title is the one.
#
# MEASURED 2026-10-02 beyond those four (Simon: "needs to work for others ...
# needs to disambiguate properly"; resolver plan C2, MEASURED): his 1,119 album
# artists as if untagged, scored against the tags July's sweep logged (15 put
# right, the lesser act of a shared name each time, none made wrong), and 436
# pretend libraries of a LESSER same-name act over 154 common names (by name 85
# right; one title asked 322; these rules 415, none made wrong). Each rule below
# is there for a case that measurement showed:
#   * up to LIBMBID_TITLES titles, distinctive first (Sources::_titleWeight): one
#     title reached 322 of the 415;
#   * only hits whose title IS the one asked count, and a title that two acts of
#     the name both hold counts for neither (a self-titled album, "Greatest Hits");
#   * the act's name must be the library's (2: spacing and a leading "The" aside,
#     so every spelling of the Chocolate Watchband is one act) or hold it (1:
#     Roswell / Roswell Road, Rico / Rico Rodriguez). Without it July's classical
#     albums moved orchestras onto their COMPOSERS;
#   * an act named as the library beats one whose name only holds it: "The Best
#     of the Nat King Cole Trio" outvoted his "The Collection" until it did;
#   * otherwise an outright winner by weight, a tie deciding nothing;
#   * the first title agreeing with the name's own answer ends it, one request
#     in the common case (the same answers, 1,092 requests where 1,285);
#   * the artist is asked without a leading "The" (MusicBrainz calls them
#     "Go-Go's"; a quoted phrase finds the shorter name inside the longer one);
#     the title again without edition words when the first form finds nobody.
# Nothing decided, a request failing: the name's answer, as before. A tag still
# wins (getArtistMbid). Kept per library CONTRIBUTOR, id and name together (an
# id LMS reuses after a rescan cannot inherit it), in the store's kept mbid
# table, and NEVER under the name: a service row called "Jack" opens what the
# name opens. Refresh asks again (clearArtistCache).
# ---------------------------------------------------------------------------
use constant LIBMBID_V        => 1;
use constant LIBMBID_TTL      => 30 * 86400;   # an act decided
use constant LIBMBID_NONE_TTL =>  7 * 86400;   # albums found, no act decided
use constant LIBMBID_MISS_TTL =>      86400;   # no album found at all
use constant LIBMBID_TITLES   => 3;
use constant LIBMBID_LIMIT    => 12;           # July's probe asked 12

sub _libMbidKey {
    my ($id, $name) = @_;
    my $k = 'dsc:libmbid:' . LIBMBID_V . ':'
          . ((defined $id && length $id) ? "$id:" . lc($name // '') : '');
    utf8::encode($k) if utf8::is_utf8($k);
    return $k;
}

# The contributor's own name: the albums carry it, whatever spelling a search
# row that attached the id wears. undef outside LMS (the suites).
sub _libraryName {
    my ($id) = @_;
    return undef unless $id;
    my $n = eval {
        require Slim::Schema;
        my $c = Slim::Schema->find('Contributor', $id);
        $c ? $c->name : undef;
    };
    return (defined $n && length $n) ? $n : undef;
}

# What the album lookup decided for library contributor $id, from the store
# only: an mbid, or undef when it was not asked or decided nothing.
sub peekLibraryMbid {
    my ($class, $id, $name) = @_;
    return undef unless $id;
    my $m = $cache->get(_libMbidKey($id, _libraryName($id) // $name));
    return (defined $m && $m =~ $UUID_RE) ? lc $m : undef;
}

# Lucene's reserved characters escaped, as July's probe sent them (its esc()).
sub _luceneEsc {
    my ($s) = @_;
    $s =~ s/([+\-!(){}\[\]^"~*?:\\\/]|&&|\|\|)/\\$1/g;
    return $s;
}

# The title without its edition words, July's T2 (its clean()): "(Deluxe
# Edition)", "[Remastered 2011]", " - Expanded". Itself when nothing is left.
my $EDITION_WORDS = qr/deluxe|expanded|remaster|remastered|edition|anniversary|bonus|disc\s*\d
                      |digital|version|mono|stereo|reissue|special|original\s+score
                      |original\s+motion\s+picture|explicit|japan|import/xi;
sub _editionless {
    my ($t) = @_;
    my $s = $t // '';
    1 while $s =~ s/\s*[(\[][^)\]]*(?:$EDITION_WORDS)[^)\]]*[)\]]//;
    $s =~ s/\s*[:\-]\s*(?:deluxe|expanded|remastered).*$//i;
    $s =~ s/^\s+|\s+$//g;
    return length $s ? $s : $t;
}

sub _rgQueryUrl {
    my ($title, $artist) = @_;
    my $q = 'releasegroup:"' . _luceneEsc($title) . '" AND artist:"' . _luceneEsc($artist) . '"';
    utf8::encode($q) if utf8::is_utf8($q);
    (my $safe = $q) =~ s/([^A-Za-z0-9])/sprintf("%%%02X",ord($1))/ge;
    return _mbBase() . 'release-group?query=' . $safe . '&fmt=json&limit=' . LIBMBID_LIMIT;
}

# A credited act's name against the library's: 2 the same name (case, marks,
# spacing and a leading "The" aside), 1 one name's words all inside the other's
# (the shared matcher's token test), 0 neither.
sub _libNameMatch {
    my ($lib, $mb) = @_;
    my ($a, $b) = map {
        my $n = Plugins::Discography::Sources::_norm($_ // '');
        $n =~ s/^the //;
        $n;
    } $lib, $mb;
    return 0 unless length $a && length $b;
    (my $ca = $a) =~ s/ //g;
    (my $cb = $b) =~ s/ //g;
    return 2 if $ca eq $cb;
    return Plugins::Discography::Sources::_artistMatch($a, $b) ? 1 : 0;
}

# One title's vote, from a release-group search reply: the act credited on the
# hits whose title is one of @asked, by a name _libNameMatch passes (a hit's
# first such credit). undef when no hit is one; { ambiguous => 1 } when two
# acts are; otherwise { mbid, exact }.
sub _titleVote {
    my ($rgs, $name, @asked) = @_;
    my %want = map { Plugins::Discography::Sources::_norm($_) => 1 } grep { defined } @asked;
    my %acts;
    for my $rg (@{ $rgs || [] }) {
        next unless ref $rg eq 'HASH'
            && $want{ Plugins::Discography::Sources::_norm($rg->{title} // '') };
        for my $c (@{ $rg->{'artist-credit'} || [] }) {
            my $a = ref $c eq 'HASH' ? $c->{artist} : undef;
            next unless ref $a eq 'HASH' && $a->{id} && !$MB_SPECIAL_ARTIST{ lc $a->{id} };
            my $m = _libNameMatch($name, $a->{name}) or next;
            $acts{ lc $a->{id} } = $m;
            last;
        }
    }
    return undef unless %acts;
    return { ambiguous => 1 } if keys %acts > 1;
    my ($id) = keys %acts;
    return { mbid => $id, exact => ($acts{$id} == 2 ? 1 : 0) };
}

# _libraryAlbumMbid($id, $pageName, $byName, $cb): getArtistMbid's answer for an
# untagged library contributor. $byName->(sub($mbid)) is the name resolver.
sub _libraryAlbumMbid {
    my ($id, $pageName, $byName, $cb) = @_;
    my $name = _libraryName($id) // $pageName;
    return $byName->($cb) unless defined $name && length $name;
    my $key  = _libMbidKey($id, $name);
    my $kept = $cache->get($key);
    if (defined $kept) {
        if ($kept =~ $UUID_RE) {
            _dbg("artist mbid from the library's albums (kept): '$name' ($id) -> $kept");
            return $cb->(lc $kept);
        }
        _dbg("library artist '$name' ($id): its albums decided no act (kept) - by name");
        return $byName->($cb);
    }

    my $own = Plugins::Discography::Sources->ownAlbumTitles($id) || [];
    return $byName->($cb) unless @$own;
    my $i = 0;
    my @titles = map  { $_->[1] }
                 sort { $b->[0] <=> $a->[0] || $a->[2] <=> $b->[2] }
                 map  { [ Plugins::Discography::Sources::_titleWeight($_, $name), $_, $i++ ] } @$own;
    splice @titles, LIBMBID_TITLES if @titles > LIBMBID_TITLES;
    (my $qArtist = $name) =~ s/^\s*the\s+(?=\S)//i;

    my @jobs;    # [title number, title, form asked]
    for my $n (0 .. $#titles) {
        my $t = $titles[$n];
        push @jobs, [ $n, $t, $t ];
        # Compared as strings, not by _norm: _norm drops what is in brackets,
        # so "X (Remastered)" and "X" are one key there and the second form
        # would never be asked.
        my $e = _editionless($t);
        push @jobs, [ $n, $t, $e ] if $e ne $t;
    }

    $byName->(sub {
        my ($named) = @_;
        $named = lc $named if $named;
        my (%exact, %part, %settled, $found, $failed, $done);
        my $finish = sub {
            my ($agreed) = @_;
            return if $done++;
            my $pick = $agreed;
            unless ($pick || $failed) {
                for my $t (\%exact, \%part) {
                    next unless %$t;
                    my @o = sort { $t->{$b} <=> $t->{$a} || $a cmp $b } keys %$t;
                    $pick = (@o > 1 && $t->{ $o[0] } == $t->{ $o[1] }) ? undef : $o[0];
                    last;
                }
            }
            if ($failed) {
                _dbg("library artist '$name' ($id): an album lookup failed - by name, nothing kept");
            }
            else {
                my $ttl = $pick ? LIBMBID_TTL : $found ? LIBMBID_NONE_TTL : LIBMBID_MISS_TTL;
                eval { $cache->set($key, $pick // '', $ttl); 1 }
                    or $log->warn("library-artist mbid cache set failed: $@");
                _dbg("library artist '$name' ($id): "
                    . ($pick ? "its albums name $pick" . ($named && $pick ne $named
                                   ? " (the name gives $named)" : '')
                             : 'its albums decided no act - by name'));
            }
            $cb->($pick || $named);
        };
        my $j = 0;
        my $step = sub {
            my ($self) = @_;
            $j++ while $j < @jobs && $settled{ $jobs[$j][0] };
            return $finish->() if $j >= @jobs;
            my ($n, $t, $form) = @{ $jobs[$j++] };
            _netGet(_rgQueryUrl($form, $qArtist),
                sub {
                    my $d = eval { from_json(shift->content) };
                    my $rgs = (ref $d eq 'HASH' && ref $d->{'release-groups'} eq 'ARRAY')
                            ? $d->{'release-groups'} : undef;
                    unless ($rgs) { $failed = 1; return $finish->() }
                    $found = 1 if @$rgs;
                    my $v = _titleVote($rgs, $name, $t, $form);
                    if ($v) {
                        $settled{$n} = 1;
                        _dbg("library artist '$name': '$form' -> "
                            . ($v->{mbid} ? $v->{mbid} . ($v->{exact} ? '' : ' (name inside)')
                                          : 'two acts of the name - counts for neither'));
                        if (my $m = $v->{mbid}) {
                            ($v->{exact} ? \%exact : \%part)->{$m}
                                += Plugins::Discography::Sources::_titleWeight($t, $name);
                            return $finish->($m) if $n == 0 && $named && $m eq $named;
                        }
                    }
                    $self->($self);
                },
                sub { $failed = 1; $finish->() },
                timeout => 15);
        };
        _dbg("library artist '$name' ($id): no tag - asking " . scalar(@titles)
            . " of its album(s) at most");
        $step->($step);
    });
}

# getArtistCandidates($name, sub(\@cands)) — the SAME-NAME candidate set for
# disambiguation: [{ mbid, name, score }] for every hit whose (lc, trimmed) name
# equals the searched name, score-sorted. Where _artistMbidByName takes the top
# hit, this returns them ALL so the caller can pick the one whose discography
# matches the user's library (title match — works when the files have no MBIDs).
# Same mirror->public fallback (an empty/dead mirror search must not starve
# disambiguation). NOT cached — it's only run on the rare wrong-tag path.
# Same-name MB artists are now read on EVERY artist search (to list the other
# acts sharing a name), not just on the rare wrong-tag path, so this is cached.
# A same-name set changes about as slowly as a discography does.
use constant CAND_TTL => 14 * 86400;

# Same-name comparison key. NOT `lc`: MusicBrainz's second hit for "Madness"
# is "Maedness" (German rapper Marco Doell, score 77) and lc-equality dropped
# it, so a genuinely different act sharing the spoken name was invisible in the
# disambiguation section while Search Hub - which folds - listed it (field,
# 2026-07-19).
#
# TWO things are needed and one alone is useless: the matcher's fold (a-umlaut
# -> a) AND UTF-8 OCTETS. `_norm`'s fold table matches on octets, while MB's
# JSON decodes to CHARACTER strings, so `_norm` on the decoded name leaves the
# umlaut unfolded. Verified both ways before writing this.
#
# This widens `getArtistCandidates` for ALL its callers, including the
# wrong-tag `_disambiguateByLibrary` path whose 0.32.0 note recorded lc
# equality. Deliberate and safe: which candidate wins there is decided by
# LIBRARY corroboration, never by the name, so admitting a diacritic variant
# adds a candidate to test rather than changing how one is chosen.
sub _nameKey {
    my ($name) = @_;
    $name = defined $name ? $name : '';
    utf8::encode($name) if utf8::is_utf8($name);
    return Plugins::Discography::Sources::_norm($name);
}

sub _candKey {
    my ($name) = @_;
    # v2: the same-name set is fold-matched, so v1 entries hold a NARROWER set.
    # v3: `_norm` no longer folds a DECORATIVE "!"/"$"/"@" into a letter, so the
    # key for a mark-bearing name changed ("layo bushwackai" -> "layo
    # bushwacka") and now COLLIDES with what v2 stored for the mark-less
    # spelling — a set computed when the two were considered different names,
    # i.e. narrower again. Same reason as the v1 -> v2 bump.
    # v7: the same-name lookup now falls back to an UNQUOTED query, so a name
    # that only the loose form can find (artist:"janes addiction" returns 0)
    # would otherwise stay pinned to the empty set v6 cached for FOURTEEN DAYS.
    # v6: `_norm` now ELIDES the apostrophe instead of spacing it, so a
    # mark-bearing name's key changed again ("jane s addiction" -> "janes
    # addiction") and collides with what v5 stored for the mark-less spelling —
    # a set computed while the two counted as different names. Same reason as
    # the v2 -> v3 bump, one mark along.
    my $k = 'dsc:acand:7:' . _nameKey($name);
    utf8::encode($k) if utf8::is_utf8($k);
    return $k;
}

# Sync cache read of the same-name set (undef when never fetched). Lets a
# render decide, without a network call, whether the artist it is showing is a
# SECONDARY act sharing its name with a more prominent one.
sub peekArtistCandidates {
    my ($class, $name) = @_;
    return undef unless defined $name && length $name;
    my $c = $cache->get(_candKey($name));
    return ref $c eq 'ARRAY' ? $c : undef;
}

# Is $mbid a secondary act whose MB name is the SAME STRING as the prominent
# one's? That is exactly when every name-keyed lookup in this plugin — library
# albums, the MAI biography, Last.fm similar artists — silently returns the
# PROMINENT act's data (field, 2026-07-19: the horrorcore Madness's page listed
# the ska band's owned albums, appearances and similar artists).
#
# The name-STRING test is the point, and it is why "Maedness" is unaffected:
# a differently spelled act gets its own name-keyed results, correctly. Only an
# identical string is indistinguishable to a lookup that has nothing but the
# name to go on.
sub _sharesDecision {
    my ($cands, $name, $mbid) = @_;
    return 0 unless ref $cands eq 'ARRAY' && @$cands > 1;
    my $top = $cands->[0] or return 0;
    return 0 if lc($top->{mbid} // '') eq lc $mbid;          # this IS the prominent act
    return lc($top->{name} // '') eq lc($name // '') ? 1 : 0;
}

# Sync form: answers only from cache, and a COLD CACHE ANSWERS "no".
#
# That fail-open is a real hazard, so prefer sharesNameWithProminentAsync
# anywhere a network call is affordable. It is why the biography guard leaked:
# on the first visit to a secondary act's page the peek returned undef, this
# returned 0, and the PROMINENT act's biography rendered under the other
# artist's name (field, 2026-07-19 — Pete Kember's life story on the Andrew
# Huang/Rob Scallon group's page). Warm caches hid it from every test.
sub sharesNameWithProminent {
    my ($class, $name, $mbid) = @_;
    return 0 unless $mbid;
    # A band whose name abbreviates to this one is the name's main act, not a
    # lesser one sharing it (ELO is not one of the acts named "ELO").
    return 0 if _abbreviates($name, $mbid);
    my $cands = $class->peekArtistCandidates($name) or return 0;
    return _sharesDecision($cands, $name, $mbid);
}

# Authoritative form: FETCHES the same-name set (cached thereafter) so the
# answer does not depend on what an earlier visit happened to warm.
sub sharesNameWithProminentAsync {
    my ($class, $name, $mbid, $cb) = @_;
    $cb ||= sub {};
    return $cb->(0) unless $mbid && defined $name && length $name;
    return $cb->(0) if _abbreviates($name, $mbid);    # see sharesNameWithProminent
    if (my $c = $class->peekArtistCandidates($name)) {
        return $cb->(_sharesDecision($c, $name, $mbid));
    }
    $class->getArtistCandidates($name, sub {
        $cb->(_sharesDecision(shift, $name, $mbid));
    });
}

# ---------------------------------------------------------------------------
# PER-CANDIDATE RELEASE-GROUP COUNTS
#
# A same-name candidate with ZERO release groups can never show anything - MB
# knows the artist exists but has catalogued no releases for it, so its page is
# empty by construction ("John Olson", "features on a Robert de Boron track").
# Listing those as choices is offering the user a dead end.
#
# COST: one MusicBrainz browse per candidate, at its 1 req/s on the public API.
# The search and the row check now WAIT for the counts (0.44.5: nothing may show
# and then vanish), so since stage 3 step 2 (2026-09-30) each count is asked of
# the COMMUNITY API first (_hostedCount): its own queue, no fixed gap, running
# beside MusicBrainz's. Only an answer ABOVE ZERO for the mbid we sent is used.
# Everything else asks MusicBrainz exactly as before:
#   * zero: the community API lists only groups where the artist is credited
#     FIRST (analysis §C2), so an act credited only second counts 0 there;
#   * a different mbid in the reply: it answers an mbid it does not know by
#     NAME (ledger A3 `silently falls back to the NAME`);
#   * a 429, a timeout, an error, or its bucket backing off (failFast).
# Measured on stage 3's sample (analysis §A12.3d): "has releases" agreed with
# MusicBrainz for 141 of 145, and the four others were all zero there, i.e.
# asked of MusicBrainz. Storing the community API's first-credit count is safe
# because every reader of dsc:rgcount asks only "zero or not".
# ---------------------------------------------------------------------------
use constant RGCOUNT_TTL => 14 * 86400;

use constant HOSTED_BASE_URL => 'https://api.lms-community.org/music/';
use constant HOSTED_TIMEOUT  => 4;    # every count has MusicBrainz behind it

# One path segment for the community API, percent-encoded per BYTE (LBF's
# _hostedSeg): names arrive as wide strings, and a '/' in one would otherwise
# invent a route.
sub _hostedSeg {
    my ($s) = @_;
    $s = defined $s ? $s : '';
    utf8::encode($s) if utf8::is_utf8($s);
    $s =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}

# _hostedCount(\%cand, $cb) -> $cb->($n): the community API's release-group count
# for $cand->{mbid}, or undef when it gave no usable answer (see above; the
# caller then asks MusicBrainz). The mbid rides as ?mbid=, which overrides the
# name for a KNOWN artist, so the name only fills the path: the candidate's own,
# else MusicBrainz's name for it, else a placeholder. Sent failFast: while its
# bucket backs off the caller hears at once and asks MusicBrainz instead.
sub _hostedCount {
    my ($c, $cb) = @_;
    my $mbid = lc($c->{mbid} // '');
    my $name = $c->{name};
    $name = Plugins::Discography::API->peekArtistName($mbid)
        unless defined $name && length $name;
    $name = '_' unless defined $name && length $name;
    my $url = HOSTED_BASE_URL . 'artist/' . _hostedSeg($name)
            . '/discography?mbid=' . $mbid;
    _netGet($url,
        sub {
            my $d = eval { from_json(shift->content) };
            if ($@ || ref $d ne 'HASH' || lc($d->{mbid} // '') ne $mbid) {
                _dbg("community count $mbid: "
                    . ($@ || ref $d ne 'HASH' ? 'unreadable reply'
                          : 'answered for ' . ($d->{mbid} || 'no mbid') . ', not this one')
                    . ' - asking MusicBrainz');
                return $cb->(undef);
            }
            my $n = ref $d->{discography} eq 'ARRAY' ? scalar @{ $d->{discography} } : 0;
            _dbg("community count $mbid: $n" . ($n ? '' : ' - asking MusicBrainz (first credits only)'));
            $cb->($n > 0 ? $n : undef);
        },
        sub {
            my $err = eval { $_[0]->error } // $_[1] // '?';
            _dbg("community count $mbid: $err - asking MusicBrainz");
            $cb->(undef);
        },
        timeout => HOSTED_TIMEOUT, failFast => 1);
    return;
}

sub _rgCountKey { 'dsc:rgcount:1:' . lc($_[0] // '') }

# THE COMMUNITY API'S ANSWER FOR A NAME (stage 3b, 2026-09-30; analysis §A11-A13):
# its pick of an artist of that name, MusicBrainz's name for it and how many
# release groups it lists (first credits only). $cb->({ mbid, name, n }), `mbid`
# empty when it knows no artist of that name, or $cb->(undef) when it gave no
# answer (refused, timed out, unreadable), which a caller must never read as "no
# artist". By NAME it can pick another act of the name (A3 `safe drop-in`), so
# the row check trusts it only when its name is the row's, and never hands it to
# the page. Cached per name, found 14 days, unknown 1 day (the service is rebuilt
# daily); Cloudflare keeps its own copy for 30. failFast, like the counts: while
# the bucket backs off, the caller hears at once.
use constant CMNAME_FOUND_TTL => 14 * 86400;
use constant CMNAME_EMPTY_TTL => 86400;
sub _cmNameKey {
    my $k = 'dsc:cmname:1:' . lc($_[0] // '');
    utf8::encode($k) if utf8::is_utf8($k);
    return $k;
}
sub _hostedByName {
    my ($class, $name, $cb) = @_;
    $name = defined $name ? $name : '';
    $name =~ s/^\s+|\s+$//g;
    return $cb->({ mbid => '', name => '', n => 0 }) unless length $name;
    my $c = $cache->get(_cmNameKey($name));
    return $cb->($c) if ref $c eq 'HASH';
    _netGet(HOSTED_BASE_URL . 'artist/' . _hostedSeg($name) . '/discography',
        sub {
            my $d = eval { from_json(shift->content) };
            if ($@ || ref $d ne 'HASH') {
                _dbg("community name '$name': unreadable reply");
                return $cb->(undef);
            }
            my $mbid = lc($d->{mbid} // '');
            $mbid = '' unless $mbid =~ $UUID_RE;
            my $a = { mbid => $mbid, name => ($mbid ? $d->{name} // '' : ''),
                      n => ($mbid && ref $d->{discography} eq 'ARRAY'
                            ? scalar @{ $d->{discography} } : 0) };
            _dbg("community name '$name': "
                . ($mbid ? "'$a->{name}' ($mbid), $a->{n} release group(s)" : 'no artist'));
            eval { $cache->set(_cmNameKey($name), $a,
                               $mbid ? CMNAME_FOUND_TTL : CMNAME_EMPTY_TTL); 1 };
            $cb->($a);
        },
        sub {
            my $err = eval { $_[0]->error } // $_[1] // '?';
            _dbg("community name '$name': $err - no answer");
            $cb->(undef);
        },
        timeout => HOSTED_TIMEOUT, failFast => 1);
    return;
}

# ---------------------------------------------------------------------------
# THE ARTIST PAGE'S FIRST LIST (0.56.7; docs/mb-efficiency-and-community-api-
# analysis.md §A16, route A, Simon: "A")
# ---------------------------------------------------------------------------
# A big artist's cold page was 13 MusicBrainz requests in a row (the artist
# read, 6 browse pages, 6 by-id bootleg requests) and drew at 15 s (Bob Dylan,
# §A15). It now draws from two outside lists, one request each, off the
# MusicBrainz queue:
#   * LISTENBRAINZ's artist metadata (`/1/metadata/artist/?inc=release_group`)
#     lists every group the artist is credited on, first or not, uncapped:
#     11,769 of MusicBrainz's 11,790 groups over 49 artists, fields alike on all
#     but 16 (measured 2026-10-01). No aliases, no statuses, no release titles.
#   * the COMMUNITY API's `/discography?withReleases=1` lists the groups where
#     the artist is credited FIRST, with every release's status: its bootleg
#     verdicts agree with MusicBrainz's on 9,521 of 9,685 groups. Its groups
#     ListenBrainz lacks join the list (together: 11,786 of 11,790, the 4
#     missing all 2026 additions).
# What the first visit lacks, MusicBrainz gives the next one: after the page is
# drawn, completeArtist browses it and runs the by-id check in the background
# (aliases, edition titles, the newest groups, its own verdicts) and stores the
# result for the next entry (promoteCompleted), never under a visit in
# progress. Ledger A2 `THE ARTIST PAGE DRAWS FROM LISTENBRAINZ AND THE
# COMMUNITY API`.
#
# Both must answer, for THIS mbid, with a list; anything else (a refusal, a
# timeout, an echo for another artist, an empty list) and the page takes the
# MusicBrainz browse exactly as before. There is NO size ceiling (0.56.8; the
# 0.56.7 one at 1,500 sent The Rolling Stones, 1,904, down the 15 s path): the
# cost that grows with an artist is the bootleg check's by-id requests, and
# warmOfficial bounds those before the draw instead (PREDRAW_RGID_MAX). MusicBrainz's
# special-purpose artists never take it (%MB_SPECIAL_ARTIST: Various Artists is
# 106 MB on ListenBrainz).
use constant LB_BASE_URL  => 'https://api.listenbrainz.org/1/';
# The slowest uncached replies measured (2026-10-01): the community API 6.5 s
# for Bach and 7.3 s for Mozart, 4.7 s for Springsteen; ListenBrainz 2.5 s for
# Mozart (4.3 MB). 8 s left the composers one slow day from the old path.
use constant FAST_TIMEOUT => 12;

sub _rgFastKey  { 'dsc:rgfast:1:'  . lc($_[0] // '') }   # the list is the first one; MusicBrainz still to complete it
sub _rgNextKey  { 'dsc:rgnext:1:'  . lc($_[0] // '') }   # MusicBrainz's completed list, for the next entry
sub _rgFullKey  { 'dsc:rgfull:1:'  . lc($_[0] // '') }   # a Refresh asked for MusicBrainz itself
sub _cmDiscoKey { 'dsc:cmdisco:1:' . lc($_[0] // '') }   # the community's verdicts for the first draw
sub _caaFlagsKey { 'dsc:caaflag:1:' . lc($_[0] // '') }  # ListenBrainz: which groups the archive has a cover for
use constant RGFULL_TTL => 3600;

# WHICH GROUPS THE ARCHIVE HAS A COVER FOR (0.56.30). ListenBrainz's artist list
# gives each group's `caa_id`, null when the Cover Art Archive has no front for
# it: 24 of 24 sampled agreed with the archive (David Bowie, 12 each way,
# 2026-10-02). Kept per artist whenever ListenBrainz answers, { group => 1|0 },
# longer than the list itself (RG_TTL), since MusicBrainz's completed list that
# replaces it carries no such field. Browse wants no cover for a 0 (Covers.pm:
# a failing archive fetch froze the server 11-13 s).
use constant CAA_FLAGS_TTL => 30 * 86400;

# { group mbid => 1|0 } for an artist, cache only, or undef when ListenBrainz
# has not answered for it (every group then counts as maybe having a cover).
sub peekCoverFlags {
    my ($class, $mbid) = @_;
    return undef unless defined $mbid && length $mbid;
    my $f = eval { $cache->get(_caaFlagsKey($mbid)) };
    return ref $f eq 'HASH' ? $f : undef;
}

# One spine entry from an outside list, in the browse's shape (no aliases), or
# undef without a group id or a title.
sub _fastEntry {
    my ($id, $title, $date, $type, $sec) = @_;
    return undef unless defined $id && $id =~ $UUID_RE && defined $title && length $title;
    return {
        mbid      => lc $id,
        title     => $title,
        date      => $date // '',
        type      => $type // '',
        secondary => ref $sec eq 'ARRAY' ? [ grep { defined && length } @$sec ] : [],
    };
}

# $cb->(\@entries) from ListenBrainz, or $cb->(undef): no answer, an answer for
# another artist, or an empty list.
sub _lbGroups {
    my ($mbid, $cb) = @_;
    _netGet(LB_BASE_URL . 'metadata/artist/?artist_mbids=' . $mbid . '&inc=release_group',
        sub {
            my $d = eval { from_json(shift->content) };
            my ($a) = grep { ref $_ eq 'HASH' && lc($_->{artist_mbid} // $_->{mbid} // '') eq $mbid }
                      (ref $d eq 'ARRAY' ? @$d : ());
            my $list = ($a && ref $a->{release_group} eq 'ARRAY') ? $a->{release_group} : [];
            unless (@$list) {
                _dbg("ListenBrainz list $mbid: " . (!$a ? 'no answer for this artist' : 'no groups'));
                return $cb->(undef);
            }
            my @all = grep { $_ } map {
                ref $_ eq 'HASH'
                    ? _fastEntry($_->{mbid}, $_->{name}, $_->{date}, $_->{type}, $_->{secondary_types})
                    : undef
            } @$list;
            my %flags = map { (lc $_->{mbid} => ($_->{caa_id} ? 1 : 0)) }
                        grep { ref $_ eq 'HASH' && defined $_->{mbid} && $_->{mbid} =~ $UUID_RE } @$list;
            eval { $cache->set(_caaFlagsKey($mbid), \%flags, CAA_FLAGS_TTL) if %flags; 1 };
            $cb->(@all ? \@all : undef);
        },
        sub {
            my $err = eval { $_[0]->error } // $_[1] // '?';
            _dbg("ListenBrainz list $mbid: $err");
            $cb->(undef);
        },
        timeout => FAST_TIMEOUT, failFast => 1);
    return;
}

# $cb->({ groups => \@entries, o => { rg => 0|1 }, r => { release => rg } }) from
# the community API, or $cb->(undef). A verdict is given only for a group whose
# releases are listed, by the bootleg check's own rule (_isOfficial: official if
# any release is, or has no status); a group listed without releases has none.
sub _hostedDisco {
    my ($mbid, $cb) = @_;
    my $name = Plugins::Discography::API->peekArtistName($mbid);
    $name = '_' unless defined $name && length $name;
    _netGet(HOSTED_BASE_URL . 'artist/' . _hostedSeg($name)
            . '/discography?mbid=' . $mbid . '&withReleases=1',
        sub {
            my $d = eval { from_json(shift->content) };
            my $list = (!$@ && ref $d eq 'HASH' && ref $d->{discography} eq 'ARRAY') ? $d->{discography} : [];
            unless (@$list && lc($d->{mbid} // '') eq $mbid) {
                _dbg("community list $mbid: " . (ref $d ne 'HASH' ? 'unreadable reply'
                     : lc($d->{mbid} // '') ne $mbid ? 'answered for ' . ($d->{mbid} || 'no mbid')
                     : 'no groups'));
                return $cb->(undef);
            }
            my (@groups, %o, %r);
            for my $g (@$list) {
                next unless ref $g eq 'HASH';
                my $e = _fastEntry($g->{mbid}, $g->{title}, $g->{release_date},
                                   $g->{primary_type}, $g->{secondary_types}) or next;
                push @groups, $e;
                my $rels = ref $g->{releases} eq 'HASH' ? $g->{releases} : {};
                next unless %$rels;
                my $any = 0;
                for my $rid (keys %$rels) {
                    $any ||= _isOfficial($rels->{$rid});
                    $r{ lc $rid } = $e->{mbid};
                }
                $o{ $e->{mbid} } = $any ? 1 : 0;
            }
            $cb->({ groups => \@groups, o => \%o, r => \%r });
        },
        sub {
            my $err = eval { $_[0]->error } // $_[1] // '?';
            _dbg("community list $mbid: $err");
            $cb->(undef);
        },
        timeout => FAST_TIMEOUT, failFast => 1);
    return;
}

# The community's groups to add to a list that %$have holds (marked into it as
# they are taken): only those it lists releases for. Its data keeps the old ids
# of groups MusicBrainz has MERGED, listed with no releases (Nirvana: 233 of 789,
# every one sampled redirects on MusicBrainz; ledger §A3); such an id would show
# as an unchecked duplicate on the page. A real group it alone has (a new one
# ListenBrainz has not caught up with) lists its releases.
sub _cmExtra {
    my ($cm, $have) = @_;
    return grep { defined $cm->{o}{ $_->{mbid} } && !$have->{ $_->{mbid} }++ } @{ $cm->{groups} };
}

# The two requests together; $cb->(\@spine) once both have a list, cached as
# the spine with the markers completeArtist and warmOfficial read, or
# $cb->(undef) as soon as either has none (the caller browses). A
# special-purpose artist (Various Artists) asks neither and browses.
sub _fastSpine {
    my ($mbid, $cb) = @_;
    return $cb->(undef) if $MB_SPECIAL_ARTIST{ lc $mbid };
    my ($lb, $cm, $decided);
    my $finish = sub { return if $decided++; $cb->(@_) };
    my $both = sub {
        return unless $lb && $cm;
        my %have = map { $_->{mbid} => 1 } @$lb;
        my @all = sort { $a->{mbid} cmp $b->{mbid} } (@$lb, _cmExtra($cm, \%have));
        eval {
            $cache->set(_rgKey($mbid), \@all, RG_TTL);
            $cache->set(_cmDiscoKey($mbid), { o => $cm->{o}, r => $cm->{r} }, RG_TTL);
            $cache->set(_rgFastKey($mbid), 1, RG_TTL);
            1;
        } or do {
            $log->warn("release-group cache set failed: $@");
            $cache->remove($_) for _rgKey($mbid), _cmDiscoKey($mbid), _rgFastKey($mbid);
            return $finish->(undef);
        };
        _dbg("release groups for $mbid: " . scalar(@all) . ' from ListenBrainz ('
             . scalar(@$lb) . ') and the community API (' . scalar(@{ $cm->{groups} })
             . '), ' . scalar(keys %{ $cm->{o} }) . ' with its verdict, '
             . scalar(grep { !$have{ $_->{mbid} } } @{ $cm->{groups} })
             . " of its own left out (no releases: merged-away ids); MusicBrainz completes it after the page");
        $finish->(\@all);
    };
    _lbGroups($mbid, sub {
        $lb = shift;
        return $finish->(undef) unless $lb;
        $both->();
    });
    _hostedDisco($mbid, sub {
        $cm = shift;
        unless ($cm) { _dbg("first list for $mbid: no community answer - the browse"); return $finish->(undef) }
        $both->();
    });
    return;
}

# A REFRESH PAST THE CAP (0.56.8; found live on 0.56.7): a Refresh takes
# MusicBrainz's list, awaited, and that browse stops at RG_MAX_PAGES. Without
# this the groups past it (Johnny Cash's live albums) vanished for RG_TTL, since
# nothing completes a browsed list. Called once the browse's first page gives
# the count, so both lists come in alongside its remaining pages. Returns
# $merge->(\@mb, $done): $done->(\@list, \%cm) with the groups MusicBrainz did
# not reach added, plus the community's verdicts and release map for THOSE
# groups only (MusicBrainz's by-id check answers for its own) and `past`, the
# kept ids, whose by-id check may wait until after the draw (warmOfficial); or
# $done->(\@mb) when either source has no list or neither has a group past the
# cap. It waits for both answers (each failFast, FAST_TIMEOUT). The community's
# merged-away ids are left out, as on a first list (_cmExtra).
sub _pastCap {
    my ($mbid, $total) = @_;
    my ($lb, $cm, $answered, $waiting) = (undef, undef, 0);
    _dbg("Refresh of $mbid: MusicBrainz lists $total groups, past its cap of "
         . RG_MAX_PAGES * RG_PAGE_SIZE . ' - ListenBrainz and the community API asked for the rest');
    my $in = sub { $waiting->() if ++$answered == 2 && $waiting };
    _lbGroups($mbid,    sub { $lb = shift; $in->() });
    _hostedDisco($mbid, sub { $cm = shift; $in->() });
    return sub {
        my ($mb, $done) = @_;
        my $go = sub {
            unless ($lb && $cm) {
                _dbg("release groups for $mbid: no list past the cap - MusicBrainz's " . scalar(@$mb) . ' only');
                return $done->($mb);    # still cut: kept RGCUT_TTL
            }
            my %have = map { $_->{mbid} => 1 } @$mb;
            my @extra = ((grep { !$have{ $_->{mbid} }++ } @$lb), _cmExtra($cm, \%have));
            unless (@extra) {
                _dbg("release groups for $mbid: nothing past the cap - MusicBrainz's " . scalar(@$mb) . ' only');
                return $done->($mb, undef, 1);    # both lists say this is all of it
            }
            my @all = sort { $a->{mbid} cmp $b->{mbid} } (@$mb, @extra);
            _pruneAliases(\@all);
            my %x = map { $_->{mbid} => 1 } @extra;
            my %o = map { ($_ => $cm->{o}{$_}) } grep { $x{$_} } keys %{ $cm->{o} };
            my %r = map { ($_ => $cm->{r}{$_}) } grep { $x{ $cm->{r}{$_} } } keys %{ $cm->{r} };
            _dbg("release groups for $mbid: MusicBrainz's " . scalar(@$mb) . ' and ' . scalar(@extra)
                 . ' past its cap from ListenBrainz and the community API, ' . scalar(keys %o)
                 . ' of those with its verdict');
            $done->(\@all, { o => \%o, r => \%r, past => \%x }, 1);
        };
        $answered == 2 ? $go->() : ($waiting = $go);
    };
}

# AFTER THE PAGE IS DRAWN, for the next visit: MusicBrainz's browse and its
# by-id bootleg check, every request sent as background work so a tap goes
# first. $cb->() when done or when there is nothing to do (no first list
# pending, or one already completing).
#   * The list: MusicBrainz's entry wins where both have a group (aliases,
#     titles, types, dates); groups only it has (the newest) are added; groups
#     only the first list has are kept only when the browse was cut at its cap
#     (they are past it), else dropped (merged away or removed in MusicBrainz).
#     Aliases are pruned over the whole. Stored for the next entry, never
#     under the visit in progress (promoteCompleted).
#   * The verdicts: MusicBrainz's over the browse's groups, with their edition
#     titles and release map; the community's stay for groups it did not
#     classify. Written at once: visibility is frozen per visit (Browse `snap`).
#   * A failure stores nothing and leaves the marker, so the next visit tries
#     again. A Refresh meanwhile (the marker gone) discards the result.
my %completing;
sub completeArtist {
    my ($class, $mbid, $cb) = @_;
    $cb ||= sub {};
    $mbid = lc($mbid // '');
    return $cb->() unless length $mbid && $cache->get(_rgFastKey($mbid));
    return $cb->() if $completing{$mbid};
    $completing{$mbid} = 1;
    my $done = sub {
        my ($why) = @_;
        _dbg("completing $mbid from MusicBrainz: $why") if $why;
        delete $completing{$mbid};
        $cb->();
    };
    _dbg("completing $mbid from MusicBrainz in the background");
    _browseGroups($mbid,
        sub {
            my ($mb, $total, $truncated) = @_;
            my $drawn = $class->peekReleaseGroups($mbid) || [];
            my %inMb = map { $_->{mbid} => 1 } @$mb;
            my @kept = $truncated ? (map { { %$_ } } grep { !$inMb{ $_->{mbid} } } @$drawn) : ();
            my @merged = sort { $a->{mbid} cmp $b->{mbid} } (@$mb, @kept);
            _pruneAliases(\@merged);
            _officialById([ map { $_->{mbid} } @$mb ], sub {
                my ($res, $err) = @_;
                return $done->('bootleg check ' . ($err // 'failed') . ' - kept for the next visit')
                    unless $res;
                return $done->('a Refresh came first - result discarded')
                    unless $cache->get(_rgFastKey($mbid));
                my $cur = $cache->get(_officialKey($mbid));
                $cur = {} unless ref $cur eq 'HASH';
                my $ok = eval {
                    $cache->set(_officialKey($mbid), {
                        o => { %{ $cur->{o} || {} }, %{ $res->{o} } },
                        r => { %{ $cur->{r} || {} }, %{ $res->{r} } },
                        # merged: a group past the cap keeps the titles its
                        # own check found (warmOfficial, _officialLater)
                        t => { %{ $cur->{t} || {} }, %{ $res->{t} } },
                    }, OFFICIAL_TTL());   # parens: the constant is declared further down
                    $cache->set(_rgNextKey($mbid), \@merged, RG_TTL);
                    1;
                };
                return $done->("cache set failed: $@") unless $ok;
                $cache->remove($_) for _rgFastKey($mbid), _cmDiscoKey($mbid);
                _dbg("completed $mbid from MusicBrainz: " . scalar(@merged) . ' groups ('
                     . scalar(@$mb) . " of $total browsed, " . scalar(@kept) . ' kept past the cap), '
                     . scalar(keys %{ $res->{o} }) . ' verdicts, for the next visit');
                $done->();
            }, background => 1);
        },
        sub { $done->('browse failed (' . ($_[0] // '?') . ') - kept for the next visit') },
        background => 1);
    return;
}

# On a FRESH entry to an artist page (never a positional walk, whose tree must
# stay the one the client holds), MusicBrainz's completed list replaces the
# first one. 1 when it did.
sub promoteCompleted {
    my ($class, $mbid) = @_;
    $mbid = lc($mbid // '');
    return 0 unless length $mbid;
    my $next = $cache->get(_rgNextKey($mbid));
    return 0 unless ref $next eq 'ARRAY';
    eval { $cache->set(_rgKey($mbid), $next, RG_TTL); 1 } or return 0;
    # MusicBrainz's list now: no first list is left to complete.
    $cache->remove($_) for _rgNextKey($mbid), _rgFastKey($mbid), _cmDiscoKey($mbid);
    _dbg("release groups for $mbid: MusicBrainz's completed list (" . scalar(@$next)
         . ') replaces the first one');
    return 1;
}

# undef = never counted (the caller must NOT treat that as zero - fail open).
sub peekReleaseGroupCount {
    my ($class, $mbid) = @_;
    return undef unless $mbid;
    my $v = $cache->get(_rgCountKey($mbid));
    return defined $v ? $v + 0 : undef;
}

sub warmCandidateCounts {
    my ($class, $cands, $cb) = @_;
    $cb ||= sub {};
    my %seen;
    my @todo = grep {
        $_->{mbid} && !$seen{ lc $_->{mbid} }++
        && !defined $cache->get(_rgCountKey($_->{mbid}))
    } @{ $cands || [] };
    return $cb->() unless @todo;

    my $pending = scalar @todo;           # counts not yet settled; $cb at 0
    my $settle  = sub { $cb->() unless --$pending };

    # MusicBrainz for what the community API could not answer, ONE AT A TIME
    # as before: this chain keeps a single request in the MusicBrainz queue, so
    # a page's own requests are never stuck behind a burst of counts. No gap of
    # its own: _netGet paces on the URL (0.51.17).
    my (@mbTodo, $mbBusy);
    my $mbRun = sub {
        my ($self) = @_;
        return if $mbBusy;
        my $c = shift @mbTodo or return;
        $mbBusy = 1;
        my $after = sub { $mbBusy = 0; $settle->(); $self->($self) };
        _netGet(_mbBase() . 'release-group?artist=' . $c->{mbid} . '&fmt=json&limit=1',
            sub {
                my $d = eval { from_json(shift->content) };
                my $n = (!$@ && ref $d eq 'HASH') ? ($d->{'release-group-count'} // 0) : undef;
                # Only a real answer is cached. An HTTP error must not pin "0"
                # and hide a legitimate artist for a fortnight.
                eval { $cache->set(_rgCountKey($c->{mbid}), $n + 0, RGCOUNT_TTL); 1 }
                    if defined $n;
                $after->();
            },
            sub { $after->() },
            timeout => 12);
    };

    # The community API first, every candidate at once: its own queue sends them
    # one at a time with no gap, beside whatever MusicBrainz is doing.
    for my $c (@todo) {
        _hostedCount($c, sub {
            my ($n) = @_;
            if (defined $n) {
                eval { $cache->set(_rgCountKey($c->{mbid}), $n + 0, RGCOUNT_TTL); 1 };
                return $settle->();
            }
            push @mbTodo, $c;
            $mbRun->($mbRun);
        });
    }
    return;
}

# ---------------------------------------------------------------------------
# THE ROW CHECK'S ANSWER PER RESULT NAME (0.56.9), for the search's known mode
# (filterRowsWithContent): { m => mbid, o => 1 when kept only to merge }, or
# { m => '' } when the community API knows no artist of that name. Written by the
# full check as each row settles, never for a row whose check got no answer, nor
# for a library row (its tag decides). Found kept 14 days, as the community's
# names are; "no artist" 7 days, as a proven-empty page is (_emptyKey): long
# enough that a junk credit stays hidden, short enough to notice one becoming an
# artist. The count and the proven-empty verdict are read afresh each search.
use constant ROWV_FOUND_TTL    => 14 * 86400;
use constant ROWV_NONE_TTL     =>  7 * 86400;
# A query's background check is not started twice in this long (a repeat search
# while the first is still asking); cleared when it finishes.
use constant ROWCHECK_BUSY_MAX => 120;
our %ROWCHECK_BUSY;
sub _rowKey {
    my $k = 'dsc:rowv:1:' . lc($_[0] // '');
    utf8::encode($k) if utf8::is_utf8($k);
    return $k;
}
sub _rememberRow {
    my ($name, $mbid, $merge) = @_;
    return unless defined $name && length $name && defined $mbid;
    my $none = $mbid eq '';
    eval { $cache->set(_rowKey($name), { m => lc $mbid, o => ($merge ? 1 : 0) },
                       $none ? ROWV_NONE_TTL : ROWV_FOUND_TTL); 1 };
    return;
}

# ---------------------------------------------------------------------------
# "DOES THIS SEARCH ROW LEAD ANYWHERE?"
#
# Simon: "It either has contents or it doesnt and its hidden from view if it
# doesn't." Right — and the contents of a Discography page ARE the MusicBrainz
# discography, so the only honest test is the one the page itself performs:
# resolve the name to an MB artist, then count its release groups. A row is a
# DEAD END when the name resolves to nothing ("Couldn't identify this artist on
# MusicBrainz: Genesis Tajiri") or resolves to an artist with no releases
# ("Beats of Genesis" -> "No releases found").
#
# CHEAPER ORACLES WERE TRIED AND MEASURED FALSE (2026-07-19), do not re-propose:
#   - the service's own release count: Deezer reports releases=1 for real
#     artists and for junk alike.
#   - the single MB search we already run for the query: it returned 100
#     artists for "Genesis" and STILL omitted "Genesis P-Orridge" and "Genesis
#     Piano Project", both of which have real pages. Filtering on it would hide
#     two genuine artists to remove four dead ends.
#
# RUNS ON EVERY SETUP SINCE STAGE 3 (2026-09-30; analysis §A12). It returned
# early on the public API from 0.44.7, a gate that skipped work there instead
# of pacing it — CLAUDE.md's top rule makes that a defect, and public users got
# no dead-end hiding, no alias fold, no library attach by tag. Removing it as it
# stood made a multi-row first search three to six times slower (measured), so
# the rows are now resolved in three passes, cheapest first:
#   1. the TYPED QUERY's own reply (the shared name search the search already
#      made, when its 15 entries are the whole result, else one request at
#      100): a row takes the artist when exactly ONE artist in it has the row's
#      exact name, or (stage 3b) when none has it and exactly ONE carries it as
#      an alias;
#   2. ONE combined search, `artist:"A" OR artist:"B" ...`, for two or more rows
#      left: the name rule, trusted only when the reply is COMPLETE. Since
#      0.56.6 (analysis §A14) the rows pass 1 answered by name but could not
#      PROVE ride in it too, to be proven (never re-picked);
#   3. since stage 3b (2026-09-30, analysis §A13), the COMMUNITY API by name for
#      the rest (see the loop below for how far its answer is trusted); the
#      real resolver only where it cannot decide (no releases listed), for the
#      row named as typed (answered from the search's own lookup) and for a
#      library row.
# Passes 1-2 answered 124 of 149 sampled rows with one or two requests, every
# answer identical to the real resolver's (analysis §A12.3b-c). What the two
# passes decide is handed to the page ONLY when it is PROVEN (_rememberProven:
# the reply holds every artist of the row's name, exactly one); everything else
# decides the list only, and a row opened from the list resolves itself.
# NOT the oracle the note above rules out: nothing is dropped for being absent
# from a batch reply. A row the batch cannot answer goes on to the next pass;
# only "no artist", a zero count, or a pick under another name that merges
# into no row drops it.
#
# $opt: query => the typed query (pass 1); asked => a hash the caller shares,
# which collects every mbid whose count this check asked for and saw SETTLE, so
# the search's same-name acts do not ask again for one that failed;
# known => 1, the search's mode (below).
#
# THE SEARCH DOES NOT WAIT FOR THIS CHECK (0.56.9; Simon, 2026-10-01: "this in
# reality should be the quickest part it is searching Qobuz and local data. If
# the main delay is to clear the empty junk entries then lets not do that just
# hide them on 2nd search"). Measured cold: Qobuz and the library answer in
# 0.7-0.9 s, and the check then took the search to 6-13 s, asking the community
# API about each leftover result one at a time (Tom Petty: 12 asked, 13.5 s).
# With `known`, each row is decided from what earlier checks left behind - its
# own answer (_rememberRow), the resolver's cached answer for the name, the
# community API's "no artist" - and a row nothing is known about is SHOWN,
# unchecked, as a row whose check failed always was. Counts and aliases are
# read from the cache, never fetched. The reply goes out at once; THEN this same
# check, unchanged, runs on the original rows as background work ($NET_BG), and
# every answer it reaches is kept per result name, so the next search, for any
# term, hides the junk and merges the duplicates. Nothing leaves a list while it
# is shown. Ledger A2 `THE SEARCH DOES NOT WAIT FOR ITS ROW CHECK`.
sub filterRowsWithContent {
    my ($class, $rows, $cb, $opt) = @_;
    $cb ||= sub {};
    $rows ||= [];
    $opt  ||= {};
    my $asked = $opt->{asked} || {};
    my $known = $opt->{known} ? 1 : 0;
    return $cb->($rows, 0) unless @$rows;
    # The background check must see the rows as they CAME, and the fold below
    # edits them in place (sources merged, a name relabelled, Local attached).
    my @orig = $known ? map { { %$_, sources => [ @{ $_->{sources} || [] } ] } } @$rows : ();
    my (@later, %needCount, %aliasLater);   # known: what the background check is for
    my %tagged;                             # library rows settled by their own tag

    # Rows are resolved concurrently and their requests share the queues, so
    # order is preserved by writing into a slot per row rather than pushing on
    # completion.
    my @slot = (undef) x scalar(@$rows);
    my @mbof = (undef) x scalar(@$rows);
    my $left = scalar @$rows;
    # Rows kept ONLY so the fold can merge them into a row of the same artist
    # (a community API answer under another name, see below): never the fold's
    # survivor, never attached, and dropped if nothing takes them in.
    my %mergeOnly;

    my $finish = sub {
        my @kept = grep { defined $slot[$_] } 0 .. $#slot;

        # FOLD rows that MusicBrainz says are the SAME artist BY ALIAS.
        #
        # Simon: "it should only be doing this if the artist has an alias in MB
        # to fold it." That rule is what makes this safe.
        #
        # 0.44.11 folded on "both rows resolved to the same MBID" and was pulled
        # the same day: _artistMbidByName is FUZZY - MB's Lucene scoring gives
        # artist:"Bush" a score-100 top hit of KATE BUSH, and the >=90 gate
        # checks only the SCORE, never the name. So "Kate Bush" was merged into
        # "Bush", destroying a real result. The Iron Maidens control in
        # tools/acceptance.py caught it.
        #
        # An alias is asserted data, not a similarity score:
        #   The Eurythmics   IS an alias of Eurythmics     -> fold
        #   Genesis Mohanraj IS an alias of Tommy Genesis  -> fold (her legal
        #                                                     name; correct)
        #   Bush             is NOT an alias of Kate Bush  -> stay separate
        # Tested in BOTH directions because warmArtistAliases omits the
        # canonical name, so a row carrying the canonical name would otherwise
        # never match while the survivor holds the alias.
        my %group;
        for my $i (@kept) {
            push @{ $group{ $mbof[$i] } }, $i if $mbof[$i];
        }
        # A group of merge-only rows alone has nothing to merge into.
        my @dup = grep { scalar @{ $group{$_} } > 1
                         && grep { !$mergeOnly{$_} } @{ $group{$_} } } keys %group;

        my $emit = sub {
            my %folded;
            for my $mbid (@dup) {
                my @idx   = @{ $group{$mbid} };
                my %alias = map { Plugins::Discography::Sources::_norm($_) => 1 }
                            @{ $class->peekArtistAliases($mbid) || [] };

                # Survivor: prefer a row with a library artist_id - that id is
                # what makes the user's OWN albums match on the page.
                #
                # SEVERAL library rows in one group: the id that matches the
                # user's albums is the one OWNING them, not the first by rank.
                # Field (Simon, 2026-09-19): "James Yorkston and friends" (3
                # owned albums) folded as a joint credit into "James Yorkston"
                # (one VA track), which ranked first on its extra Qobuz source;
                # the survivor kept the bare contributor's id and the page read
                # 0 matched / 0 local, against 6 / 6 for the owning id. Most
                # albums wins, rank order breaking ties — so a group with ONE
                # library row, or with equal counts, behaves exactly as before,
                # and the count queries run only when two library rows collide.
                my @owned = grep { $slot[$_]{artist_id} } @idx;
                my ($keepIdx) = @owned;
                if (@owned > 1) {
                    my %n = map { $_ => Plugins::Discography::Sources::_albumCountFor(
                                      $slot[$_]{artist_id}) } @owned;
                    ($keepIdx) = sort { $n{$b} <=> $n{$a} || $a <=> $b } @owned;
                }
                ($keepIdx) = grep { !$mergeOnly{$_} } @idx unless defined $keepIdx;

                my $didFold = 0;

                # A JOINT CREDIT IS FOLD EVIDENCE TOO (0.48.5).
                #
                # Simon: *"Nick Cave & Warren Ellis is the same as Panda Bear &
                # Sonic Boom, Robert Plant & Diana Krall — why is it being
                # treated differently as we sorted our conjoined artists some
                # time ago"* — and *"this never got implemented into search and
                # is just row based."* Both correct. 0.47.0 taught the RESOLVER
                # about joint credits, and that half does run in search. The
                # search-ROW half never learned: this gate accepted only an MB
                # ALIAS, and a joint credit is not an alias — MusicBrainz has no
                # such artist at all (verified: `artist:"Nick Cave & Warren
                # Ellis"` and `artist:"Panda Bear & Sonic Boom"` both count=0,
                # while `artist:"Robert Plant & Alison Krauss"` count=1, which is
                # the ONLY reason that one behaves differently).
                #
                # So every credit-split row stayed a SEPARATE row pointing at the
                # same page. Measured in one log window, all of them duplicates:
                #   Neil Young & The Chrome Hearts  -> Neil Young
                #   Lou Reed and Kris Kristofferson -> Lou Reed
                #   Lou Reed & John Cale            -> Lou Reed
                #   Nick Cave & Warren Ellis        -> Nick Cave
                # and because the empty verdict and the candidate pool are both
                # MBID-keyed, those duplicates then collide — which is how ONE
                # empty render hid the solo artist from search entirely.
                #
                # This is NOT string inference, the bar 0.44.13 set after the
                # "Kate Bush folded into Bush" withdrawal: the rows already
                # resolved to the SAME MBID, and `_creditHead` is the very
                # function that put them there. We are agreeing with a mapping we
                # made deliberately, not guessing from a name similarity. Pure
                # and cache-only — no extra request.
                my $canonNorm = do {
                    my $c = $class->peekArtistName($mbid);
                    defined $c && length $c ? Plugins::Discography::Sources::_norm($c) : '';
                };
                my $splitsTo = sub {
                    my ($from, $to) = @_;
                    my $head = _creditHead($from);
                    return 0 unless defined $head;

                    # MUSICBRAINZ HAS A DEDICATED ARTIST FOR THE WHOLE CREDIT ->
                    # NEVER FOLD IT AWAY (0.48.7). Field (Simon): searching
                    # "Robert Plant" lost the "Robert Plant & Alison Krauss" row
                    # entirely, while "Alison Krauss" kept it. The duo IS a real
                    # MB artist (38eb4af8, its canonical name literally "Robert
                    # Plant & Alison Krauss"), and the two rows shared that mbid
                    # only because the user's library tags BOTH member
                    # contributors with the duo's id — so the "Robert Plant" row
                    # resolved via that tag into the duo's fold group, where the
                    # duo's head ("Robert Plant") matched it and 0.48.5 folded
                    # the duo in. The whole point of the credit fold was the
                    # OPPOSITE case, where MB has NO artist for the credit and it
                    # only reached this mbid by splitting to the head act (Nick
                    # Cave & Warren Ellis -> Nick Cave, count=0). The clean
                    # discriminator: when the credit's OWN name is the mbid's
                    # canonical name, MB gave it a page and it keeps its row.
                    return 0 if $canonNorm
                        && Plugins::Discography::Sources::_norm($from) eq $canonNorm;

                    my $hn = Plugins::Discography::Sources::_norm($head);
                    return 0 unless length $hn;
                    return 1 if $hn eq $to;
                    return 1 if $canonNorm && $hn eq $canonNorm;
                    return 0;
                };

                for my $i (@idx) {
                    next if $i == $keepIdx;
                    my $a = Plugins::Discography::Sources::_norm($slot[$i]{name} // '');
                    my $b = Plugins::Discography::Sources::_norm($slot[$keepIdx]{name} // '');
                    # A MERGE-ONLY row (the community API's pick, made under
                    # another name) merges only when ITS OWN name is one
                    # MusicBrainz records for this artist, or a joint credit
                    # headed by it: the survivor's alias proves nothing about a
                    # row whose pick may be wrong ("The 3 Stooges" answered as
                    # The Stooges stays out of The Stooges' row, and goes).
                    if ($mergeOnly{$i}
                        && !($alias{$a} || (length $canonNorm && $a eq $canonNorm)
                             || $splitsTo->($slot[$i]{name}, $b))) {
                        _dbg("search rows: NOT merging '" . ($slot[$i]{name} // '?')
                            . "' into '" . ($slot[$keepIdx]{name} // '?')
                            . "' - its own name is not one MusicBrainz records for $mbid");
                        next;
                    }
                    my $split = $splitsTo->($slot[$i]{name}, $b)
                             || $splitsTo->($slot[$keepIdx]{name}, $a);
                    unless ($alias{$a} || $alias{$b} || $split) {
                        _dbg("search rows: NOT folding '" . ($slot[$i]{name} // '?')
                            . "' into '" . ($slot[$keepIdx]{name} // '?')
                            . "' - same MBID $mbid but neither name is an MB alias"
                            . ' or a joint credit of the other');
                        next;
                    }
                    my $keep = $slot[$keepIdx];
                    my %have = map { $_ => 1 } @{ $keep->{sources} || [] };
                    push @{ $keep->{sources} },
                         grep { !$have{$_}++ } @{ $slot[$i]{sources} || [] };
                    $keep->{artist_id} ||= $slot[$i]{artist_id};
                    $folded{$i} = 1;
                    $didFold = 1;
                    _dbg("search rows: folded '" . ($slot[$i]{name} // '?')
                        . "' into '" . ($keep->{name} // '?') . "' ("
                        . ($alias{$a} || $alias{$b} ? 'MB alias' : 'joint credit')
                        . ", $mbid)");
                }

                # LABEL THE MERGED ROW WITH MUSICBRAINZ'S CANONICAL NAME.
                #
                # Which row survives depends on the merge ranking, which
                # depends on the QUERY — so the same band was labelled
                # "Layo & Bushwacka!" for one search and Deezer's lowercase
                # "Layo and bushwacka!" for another (field, 2026-07-21: "if a
                # user uses and instead of & it shows Layo and Bushwacka").
                # Both are real service spellings and neither is authoritative.
                # MB's canonical name is — and a folded row has already been
                # PROVEN to be that MB artist (grouped by resolved mbid, gated
                # on a real alias). So the row now reads the same however it
                # was reached.
                #
                # STRICTLY AFTER THE FOLD LOOP, and that ordering is load
                # bearing: `warmArtistAliases` deliberately omits the canonical
                # name from the alias list, so relabelling FIRST can make
                # `$alias{$b}` false and block the very fold this is tidying up
                # (rows "Canon" + "Some Alias" would stop merging).
                #
                # Only when something actually folded — a row that stayed
                # separate keeps its own name. Free: the canonical name rides
                # the alias fetch this branch already made.
                # LIMIT: a LONE row keeps its service spelling, since only
                # duplicated groups fetch aliases and a per-row MB request at
                # search time is exactly the cost this design avoids.
                #
                # THE LIBRARY'S SPELLING OUTRANKS MB's (0.46.5). Field (Simon):
                # "still missing the artist artwork for The b52s". MB's
                # canonical name for that band is "The B‐52s" with a U+2010
                # HYPHEN, and NOTHING else in the chain can resolve that string
                # — measured on the live image proxy:
                #     "The B-52s" (library, ASCII) -> 1,966,381 bytes, a photo
                #     "The B‐52s" (MB canonical)   ->     5,071 bytes, the
                #                                        silhouette placeholder
                # The same applies to every other name-keyed lookup (localAlbums
                # by name, the matcher's artist gate). So when the row already
                # carries a library artist_id, the name the USER's own library
                # uses wins — it is what they see everywhere else in LMS, and
                # it is the one spelling known to resolve. MB canonical remains
                # the right answer for a row the library does not know, which is
                # the case 0.44.20 was written for.
                # ...BUT A LIBRARY ENTRY CALLED BY MUSICBRAINZ'S NAME LABELS THE
                # ROW (0.56.13; Simon, 2026-10-01: the search showed "James
                # Yorkston and friends", not James Yorkston, though "they all
                # link back to James Yorkston in MB"). The survivor is the entry
                # owning the most albums (above), which can be a variant name;
                # when another folded library entry is literally MusicBrainz's
                # name for the act, that is both a library spelling and the
                # act's own name, so the row reads it. It still opens on the
                # survivor's id, the one holding the albums.
                my $libCanon;
                if ($didFold && $slot[$keepIdx]{artist_id}) {
                    my $canon = $class->peekArtistName($mbid);
                    my $cn = (defined $canon && length $canon)
                           ? Plugins::Discography::Sources::_norm($canon) : '';
                    ($libCanon) = grep {
                        $folded{$_} && $slot[$_]{artist_id} && length $cn
                        && Plugins::Discography::Sources::_norm($slot[$_]{name} // '') eq $cn
                    } @idx;
                    $libCanon = undef if defined $libCanon && length $cn
                        && Plugins::Discography::Sources::_norm($slot[$keepIdx]{name} // '') eq $cn;
                }
                if (defined $libCanon) {
                    _dbg("search rows: labelling '" . ($slot[$keepIdx]{name} // '?')
                        . "' as the library's '" . ($slot[$libCanon]{name} // '?')
                        . "' (MB's name for $mbid), still opening artist_id "
                        . $slot[$keepIdx]{artist_id});
                    $slot[$keepIdx]{name} = $slot[$libCanon]{name};
                }
                elsif ($didFold && $slot[$keepIdx]{artist_id}) {
                    _dbg("search rows: keeping the LIBRARY spelling '"
                        . ($slot[$keepIdx]{name} // '?')
                        . "' (artist_id " . $slot[$keepIdx]{artist_id}
                        . ") over MB canonical");
                }
                elsif ($didFold) {
                    my $canon = $class->peekArtistName($mbid);
                    if (!$canon) {
                        # NOT a silent no-op any more. A missing canonical name
                        # leaves the row wearing a service spelling, and that
                        # name becomes the artist identity the matcher gates on
                        # — which is how "b52s" produced an empty page.
                        _dbg("search rows: NO MB canonical name for $mbid - "
                            . "row keeps '" . ($slot[$keepIdx]{name} // '?') . "'");
                    }
                    elsif (($slot[$keepIdx]{name} // '') ne $canon) {
                        _dbg("search rows: relabelled '"
                            . ($slot[$keepIdx]{name} // '?')
                            . "' to MB canonical '$canon'");
                        $slot[$keepIdx]{name} = $canon;
                    }
                }

                # ATTACH THE USER'S OWN LIBRARY ARTIST VIA MB's ALIASES.
                #
                # Field (Simon, 2026-07-22): "b52s, b-52s and b-52's all produce
                # different results". Measured — all three resolve to the SAME MB
                # artist (127f591a) and fold correctly; what differs is which row
                # SURVIVES, because the survivor prefers a row carrying a library
                # artist_id and for "b52s" there was none: LMS cannot match that
                # string to "The B‐52’s" (its tokens are B / 52 / s), so the Local
                # leg returned nothing and the streaming row won, with no Local
                # source and a different label.
                #
                # But MB's alias list — already fetched to gate the fold above —
                # contains spellings LMS CAN match ("The B-52's"). So when the
                # surviving row still has no library artist, try the canonical
                # name and each alias through the shared local lookup. This is
                # MBID-VERIFIED, not string inference: every candidate name is
                # one MusicBrainz records for this exact artist, which is the
                # standard the 2026-07-17 decision set for any merge.
                if (!$slot[$keepIdx]{artist_id}) {
                    my $canon = $class->peekArtistName($mbid);
                    my @try   = grep { defined && length }
                                $canon, @{ $class->peekArtistAliases($mbid) || [] };
                    for my $name (@try) {
                        my ($hit) = grep {
                            Plugins::Discography::Sources::_normKey($_->{name})
                                eq Plugins::Discography::Sources::_normKey($name)
                        } @{ Plugins::Discography::Sources::_localArtistRows($name) };
                        next unless $hit;
                        $slot[$keepIdx]{artist_id} = $hit->{artist_id};
                        my %have = map { $_ => 1 } @{ $slot[$keepIdx]{sources} || [] };
                        unshift @{ $slot[$keepIdx]{sources} }, 'Local' unless $have{Local};
                        # Prefer the LIBRARY's spelling once we know the user
                        # owns this artist: it is what they see everywhere else
                        # in LMS, and it keeps every spelling of the query
                        # landing on one identical row.
                        $slot[$keepIdx]{name} = $hit->{name};
                        _dbg("search rows: attached library artist "
                            . $hit->{artist_id} . " ('" . $hit->{name}
                            . "') to the folded row via MB alias '$name'");
                        last;
                    }
                }
            }

            # ATTACH THE USER'S OWN LIBRARY ARTIST BY MUSICBRAINZ TAG (0.51.3).
            #
            # Every attach above this line is spelled: the fold's alias pass
            # asks the library for a NAME, so it can only rescue a row whose
            # artist LMS can find by some spelling. For Simon's braille/Yi/
            # Georgian act there is no such spelling — LMS's index holds one
            # 2-char token of a name that normalises to almost nothing — and
            # his library carries that artist's MB tag all the same. So the row
            # said Qobuz/Deezer for an artist he owns, and only the DRILL-IN
            # (which resolves through the tag) knew better.
            #
            # This asks the identity question instead: which contributors carry
            # this row's resolved mbid? Exact, spelling-free, and the SAME read
            # `getArtistMbid` already trusts ahead of any MB search — one
            # direction of it was never wired to the search rows.
            #
            # RUNS AFTER THE FOLD, deliberately: the fold's survivor choice
            # prefers a row that ALREADY has an artist_id, so attaching ids
            # first would change which row survives and which spelling it wears.
            # Here it can only add Local to rows the fold has finished with.
            #
            # Only rows with NO artist_id — a row the Local leg or the alias
            # attach already claimed is left exactly as it was, including its
            # name.
            # An id already on a kept row is not handed to a second one. The
            # fold keeps rows apart when MB has no alias joining them, and the
            # tag cannot overrule that: "Luxembourg Signal" (Qobuz) sat beside
            # the library's "THE LUXEMBOURG SIGNAL" and gained its id, giving
            # two Local rows that open one artist (review, live 2026-09-19).
            my %carried = map { $slot[$_]{artist_id} => 1 }
                          grep { !$folded{$_} && $slot[$_]{artist_id} } @kept;
            for my $i (@kept) {
                next if $folded{$i} || $mergeOnly{$i};
                next if $slot[$i]{artist_id};
                next unless $mbof[$i];
                my @hits = @{ Plugins::Discography::Sources::localArtistsByMbid($mbof[$i]) };
                next unless @hits;
                # Several contributors can carry one tag (a duplicate
                # contributor, one holding the albums): take the OWNER, as the
                # survivor choice above does. The first by DB order could be
                # the empty one, and an explicit artist_id outranks the mbid in
                # localAlbums, so the row would read Local over 0 owned albums.
                my ($hit) = @hits;
                if (@hits > 1) {
                    my %n = map { $_ => Plugins::Discography::Sources::_albumCountFor(
                                      $hits[$_]{artist_id}) } 0 .. $#hits;
                    ($hit) = map { $hits[$_] }
                             sort { $n{$b} <=> $n{$a} || $a <=> $b } 0 .. $#hits;
                }
                next if $carried{ $hit->{artist_id} }++;
                $slot[$i]{artist_id} = $hit->{artist_id};
                my %have = map { $_ => 1 } @{ $slot[$i]{sources} || [] };
                unshift @{ $slot[$i]{sources} }, 'Local' unless $have{Local};
                _dbg("search rows: attached library artist " . $hit->{artist_id}
                    . " ('" . ($hit->{name} // '?') . "') to '"
                    . ($slot[$i]{name} // '?') . "' by MusicBrainz tag "
                    . $mbof[$i]);
            }

            for my $i (grep { $mergeOnly{$_} && !$folded{$_} } @kept) {
                _dbg("search row DROP '" . ($slot[$i]{name} // '?')
                    . "': answered under another name, and no row of that artist to merge into");
            }
            my @out = map { $slot[$_] } grep { !$folded{$_} && !$mergeOnly{$_} } @kept;
            _dbg('search rows: ' . scalar(@out) . ' of ' . scalar(@$rows)
                . ' lead somewhere');
            $cb->(\@out, scalar(@$rows) - scalar(@out));
        };

        # Known: only the groups whose aliases are cached fold now. The rest stay
        # apart, a merge-only row in them shown as an ordinary one, and their
        # aliases are fetched after the reply, for the next search.
        if ($known) {
            my @cold = grep { !$class->peekArtistAliases($_) } @dup;
            if (@cold) {
                my %cold = map { $_ => 1 } @cold;
                @dup = grep { !$cold{$_} } @dup;
                for my $m (@cold) {
                    $aliasLater{$m} = 1;
                    delete $mergeOnly{$_} for @{ $group{$m} };
                }
            }
            return $emit->();
        }

        # Alias lists only for the ambiguous groups (usually none), then decide.
        # Cached, so at most one MB request per duplicated artist.
        my $pend = scalar @dup;
        return $emit->() unless $pend;
        for my $mbid (@dup) {
            $class->warmArtistAliases($mbid, sub { $emit->() unless --$pend });
        }
    };

    # Every row settles exactly once: kept (with its mbid, for the fold) or
    # dropped. The last one to settle runs $finish.
    # A full check keeps every answer it reaches for a non-library row (kept or
    # dropped, with its artist) for the next search's known mode.
    my $settle = sub {
        my ($i, $keep, $mbid) = @_;
        $slot[$i] = $rows->[$i] if $keep;
        $mbof[$i] = $mbid       if $keep;
        _rememberRow($rows->[$i]{name}, $mbid, $mergeOnly{$i})
            if !$known && $mbid && !$tagged{$i};
        $finish->() unless --$left;
    };

    # A NON-library row, resolved (or not) to $mbid: does it lead anywhere?
    # PER-ROW REASONS ARE LOGGED. The summary line ("1 of 9 lead somewhere")
    # says nothing about WHY a given row went, which left a real complaint - The
    # Iron Maidens vanishing from an Iron Maiden search - undiagnosable without
    # another build.
    my $judge = sub {
        my ($i, $mbid, $how) = @_;
        my $name = $rows->[$i]{name};
        # Unresolvable -> the page could only say "couldn't identify", so the
        # row leads nowhere and is dropped.
        unless ($mbid) {
            _dbg("search row DROP '$name': no MB artist ($how)");
            return $settle->($i, 0);
        }
        # PROVEN EMPTY by an earlier render (0.46.6) — MusicBrainz lists
        # releases for this artist but nothing here can play any of them, so
        # the row leads to "No releases found". Checked BEFORE the count fetch:
        # it is a cache read, and it is a stronger answer than the count, which
        # only ever knew what MB holds. Library rows never reach here, and the
        # verdict is only ever set with the pools resolved — see
        # Browse::_buildList.
        if ($class->peekArtistEmpty($mbid)) {
            _dbg("search row DROP '$name': proven empty on a previous "
                . "render (mbid=$mbid)");
            return $settle->($i, 0, $mbid);
        }
        my $decide = sub {
            my $n = $class->peekReleaseGroupCount($mbid);
            # undef = the count fetch FAILED. Keep the row: a failed request
            # must never read as "this artist has nothing".
            my $keep = (!defined $n || $n > 0) ? 1 : 0;
            _dbg("search row " . ($keep ? 'keep' : 'DROP') . " '$name': "
                . "mbid=$mbid rgcount=" . (defined $n ? $n : 'unknown') . " ($how)");
            $settle->($i, $keep, $mbid);
        };
        # ASKED ONCE PER SEARCH (stage 3 review, 2026-09-30). A count this
        # search has already asked for, and that has SETTLED, is decided from
        # what it got: cached if it answered, undef (keep) if it failed. Asking
        # again only repeated the failure, and while MusicBrainz is refusing it
        # waited out the 5-30 s backoff to do it. Marked only once settled, so
        # a count still in flight for another row is never read as "failed".
        return $decide->() if $asked->{ lc $mbid };
        $class->warmCandidateCounts([{ mbid => $mbid }], sub {
            $asked->{ lc $mbid } = 1;
            $decide->();
        });
    };

    # KNOWN MODE: a row decided by what is in the cache, as the full check would
    # decide it with the same answers; anything else shown and checked later.
    my $judgeKnown = sub {
        my ($i, $mbid, $how) = @_;
        my $name = $rows->[$i]{name};
        if ($class->peekArtistEmpty($mbid)) {
            _dbg("search row DROP '$name': proven empty on a previous render (mbid=$mbid)");
            return $settle->($i, 0);
        }
        my $n = $class->peekReleaseGroupCount($mbid);
        $needCount{ lc $mbid } = 1 unless defined $n;
        my $keep = (!defined $n || $n > 0) ? 1 : 0;
        _dbg("search row " . ($keep ? 'keep' : 'DROP') . " '$name': mbid=$mbid rgcount="
            . (defined $n ? $n : 'not counted yet') . " ($how)");
        $settle->($i, $keep, $mbid);
    };
    my $decideKnown = sub {
        my ($i, $name) = @_;
        my $lib = $rows->[$i]{artist_id};
        my $v = $cache->get(_rowKey($name));
        if (ref $v eq 'HASH' && defined $v->{m} && $v->{m} eq '' && !$lib) {
            _dbg("search row DROP '$name': no MB artist (checked before)");
            return $settle->($i, 0);
        }
        if (ref $v eq 'HASH' && $v->{m}) {
            if ($v->{o} && !$lib) {
                _dbg("search row '$name': checked before, answered as $v->{m} - kept only to merge");
                $mergeOnly{$i} = 1;
                return $settle->($i, 1, $v->{m});
            }
            return $settle->($i, 1, $v->{m}) if $lib;
            return $judgeKnown->($i, $v->{m}, 'checked before');
        }
        # The resolver's own answer for the name (a page's, the typed query's).
        my $m = $cache->get(_mbidKey($name));
        if (defined $m && length $m) {
            return $settle->($i, 1, $m) if $lib;
            return $judgeKnown->($i, $m, 'resolver, cached');
        }
        unless ($lib) {
            my $cm = $cache->get(_cmNameKey($name));
            if ((defined $m && $m eq '')
                || (ref $cm eq 'HASH' && defined $cm->{mbid} && $cm->{mbid} eq '')) {
                _dbg("search row DROP '$name': no MB artist (checked before)");
                return $settle->($i, 0);
            }
        }
        _dbg("search row keep '$name': not checked yet - shown, checked after the list");
        push @later, $i;
        $settle->($i, 1, undef);
    };

    my @pend;   # [index, name] of the rows to resolve by name
    for my $i (0 .. $#$rows) {
        my $row  = $rows->[$i];
        my $name = $row->{name};
        unless (defined $name && length $name) { $settle->($i, 1); next }

        # A LIBRARY row is never filtered - an artist the user owns that MB
        # does not list must not vanish from search - but it still RESOLVES,
        # so it can take part in folding and carry its artist_id across. Its
        # own tag first, as getArtistMbid always has.
        # An untagged one: the act its albums named on its page (C2), when a
        # visit has found it - cache only, and like a tag never remembered
        # under the name (_rememberRow).
        if ($row->{artist_id} && (my $tag = _libraryTagMbid($row->{artist_id})
                                  // $class->peekLibraryMbid($row->{artist_id}, $name))) {
            $tagged{$i} = 1;
            $settle->($i, 1, $tag);
            next;
        }
        if ($known) { $decideKnown->($i, $name); next }
        push @pend, [ $i, $name ];
    }

    # Known: the reply has gone (every row settled above, at once). What it could
    # not decide is now asked as background work, for the next search: the full
    # check on the rows as they came (it sees every row, so a merge-only answer
    # finds the row it merges into), the counts not yet known, the aliases of the
    # groups that could not fold. One run per query at a time.
    if ($known) {
        my $qk = lc($opt->{query} // '');
        my $now = Time::HiRes::time();
        if ((@later || %needCount || %aliasLater) && ($ROWCHECK_BUSY{$qk} // 0) <= $now) {
            $ROWCHECK_BUSY{$qk} = $now + ROWCHECK_BUSY_MAX;
            _dbg('search rows: ' . scalar(@later) . ' not checked yet, '
                . scalar(keys %needCount) . ' count(s), ' . scalar(keys %aliasLater)
                . ' alias list(s) - checking after the list');
            local $NET_BG = 1;
            $class->warmCandidateCounts([ map { { mbid => $_ } } keys %needCount ])
                if %needCount;
            $class->warmArtistAliases($_) for keys %aliasLater;
            if (@later) {
                $class->filterRowsWithContent(\@orig, sub {
                    delete $ROWCHECK_BUSY{$qk};
                    _dbg("search rows for '$qk': checked after the list, for the next search");
                }, { query => $opt->{query} });
            }
            else { delete $ROWCHECK_BUSY{$qk} }
        }
        return;
    }
    return unless @pend;

    $class->_rowBatch($opt->{query}, \@pend, sub {
        my ($pick, $proven) = @_;
        my @batched = grep {  defined $pick->{ $_->[0] } } @pend;
        my @rest    = grep { !defined $pick->{ $_->[0] } } @pend;
        # What the shared searches PROVED goes to the page (see _rememberProven).
        $class->_rememberProven($rows->[$_]{name}, $proven->{$_}) for keys %{ $proven || {} };
        _dbg('search rows: ' . scalar(@batched) . ' of ' . scalar(@pend)
            . ' answered by the shared searches (' . scalar(keys %{ $proven || {} })
            . ' handed to the page), ' . scalar(@rest) . ' left');

        # The batch answers' counts in ONE warm: the community API sends them
        # back to back, and whatever falls to MusicBrainz goes one at a time.
        # Each row is then judged from what the warm got, never asked again.
        my @counted = map  { $pick->{ $_->[0] } }
                      grep { !$rows->[ $_->[0] ]{artist_id} } @batched;
        $class->warmCandidateCounts([ map { { mbid => $_ } } @counted ], sub {
            $asked->{ lc $_ } = 1 for @counted;
            for my $p (@batched) {
                my $i = $p->[0];
                if ($rows->[$i]{artist_id}) { $settle->($i, 1, $pick->{$i}); next }
                $judge->($i, $pick->{$i}, 'shared search');
            }
        });

        # 'artist' is the name parameter (NOT 'name' - that silently resolves
        # nothing and hides every row). `asked`: the resolver's own zero-release
        # check marks the count it settled, so the row is judged from it.
        my $resolve = sub {
            my ($i, $name) = @_;
            $class->getArtistMbid(artist => $name, speculative => 1,
                                  asked => $asked, onDone => sub {
                my ($mbid) = @_;
                return $settle->($i, 1, $mbid) if $rows->[$i]{artist_id};
                $judge->($i, $mbid, 'resolver');
            });
        };

        # THE REST ASK THE COMMUNITY API, not MusicBrainz (stage 3b, 2026-09-30;
        # analysis §A11-A13). They are mostly the services' junk, which no
        # shared search answers, and the resolver spent 3-5 MusicBrainz requests
        # at 1.1 s on each: Pretenders took 60 requests and 67 s. One request
        # each on the community API's own queue instead (§A13: 319 MusicBrainz
        # requests -> 36 for the 16 test searches, the list the same but for
        # four rows). By name it can pick another act of the name (A3 `safe
        # drop-in`), so its answer is trusted only as far as it goes:
        #   - no answer at all (refused, timed out)   -> kept, unchecked, as a
        #     failed count is: a failed request never hides a row;
        #   - no artist                                -> dropped;
        #   - ITS name is the row's, releases listed   -> kept, with its id and
        #     count;
        #   - its name is the row's, NO releases       -> the resolver decides:
        #     its lists hold first credits only, and by name it may have picked
        #     another act of the name (Luke Bushell, Mixtape Madness);
        #   - another name                             -> kept ONLY to merge
        #     into a kept row of the same id through the fold below (one name an
        #     MB alias of the other), else dropped: "The Pretenders" joins
        #     Pretenders; "Bush Lily" answered as "Cluster" goes.
        # Its id is never handed to the page, which resolves such a row itself.
        # The row named as typed, and a library row, keep the resolver: the
        # first is answered from the search's own lookup (cached), the second is
        # never hidden and its id joins the fold and the library attach.
        (my $qlc = lc($opt->{query} // '')) =~ s/^\s+|\s+$//g;
        for my $p (@rest) {
            my ($i, $name) = @$p;
            (my $nlc = lc $name) =~ s/^\s+|\s+$//g;
            if ($rows->[$i]{artist_id} || (length $qlc && $nlc eq $qlc)) {
                $resolve->($i, $name);
                next;
            }
            $class->_hostedByName($name, sub {
                my ($a) = @_;
                unless ($a) {
                    _dbg("search row keep '$name': the community API gave no answer - unchecked");
                    return $settle->($i, 1, undef);
                }
                unless ($a->{mbid}) {
                    _rememberRow($name, '');
                    return $judge->($i, undef, 'community API');
                }
                my $n = Plugins::Discography::Sources::_norm(_stripAnnotation($name));
                my $same = length($n)
                    && $n eq Plugins::Discography::Sources::_norm(_stripAnnotation($a->{name} // ''));
                unless ($same) {
                    _dbg("search row '$name': the community API answered '"
                        . ($a->{name} // '?') . "' ($a->{mbid}) - kept only to merge");
                    $mergeOnly{$i} = 1;
                    return $settle->($i, 1, $a->{mbid});
                }
                return $resolve->($i, $name) unless $a->{n};
                eval { $cache->set(_rgCountKey($a->{mbid}), $a->{n} + 0, RGCOUNT_TTL); 1 }
                    unless defined $cache->get(_rgCountKey($a->{mbid}));
                $asked->{ lc $a->{mbid} } = 1;
                $judge->($i, $a->{mbid}, 'community API');
            });
        }
    });
    return;
}

# THE SEARCH HANDS THE PAGE WHAT IT HAS PROVEN (stage 3b, 2026-09-30; analysis
# §A13 part 2). A row whose artist came from a reply holding EVERY artist of its
# name, and exactly one of them, has the answer the page's own lookup would
# reach: the resolver's exact-name pick, and a same-name set of that one artist.
# So both are written as those entries, and a tap resolves from the cache: one
# MusicBrainz request and 1.2-1.4 s less (measured on the rig, §A12.12), as the
# typed name's own row already had. An entry already there is left alone (a
# cached miss excepted: this is proof there is an artist).
sub _rememberProven {
    my ($class, $name, $a) = @_;
    return unless defined $name && length $name && ref $a eq 'HASH' && $a->{id};
    my $mbid = lc $a->{id};
    my $k = _mbidKey($name);
    my $had = $cache->get($k);
    eval { $cache->set($k, $mbid, MBID_FOUND_TTL); 1 }
        unless defined $had && length $had;
    my $ck = _candKey($name);
    eval { $cache->set($ck, [ {
        mbid  => $mbid,
        name  => $a->{name},
        score => $a->{score} // 0,
        disambiguation => $a->{disambiguation},
        country        => $a->{country},
        type           => $a->{type},
    } ], CAND_TTL); 1 } unless defined $cache->get($ck);
    if (defined $a->{name} && length $a->{name} && !$class->peekArtistName($mbid)) {
        $mbNameMem{$mbid} = $a->{name};
        _setMbName($mbid, $a->{name});
    }
    return;
}

# The batch passes of filterRowsWithContent (see its header): the typed query's
# own reply, then one combined search. $cb->(\%pick, \%proven): row index =>
# mbid, for the rows they answer, and row index => the reply's entry for those
# whose answer is PROVEN (see _rememberProven). Every other row is left for the
# next step: none named exactly like the row, several so named (which of several
# the page opens is the resolver's call), an incomplete combined reply, or a
# failed request.
sub _rowBatch {
    my ($class, $q, $pend, $cb) = @_;
    # %recheck: rows pass 1 answered by name without proof, for pass 2 to prove.
    my (%pick, %proven, %recheck);
    my $norm = \&Plugins::Discography::Sources::_norm;

    # The ONE artist in $arts named exactly like the row (after _norm and the
    # annotation strip, as measured), or undef.
    my $unique = sub {
        my ($arts, $name) = @_;
        my $w = $norm->(_stripAnnotation($name));
        return undef unless defined $w && length $w;
        my @ex = grep {
            $_->{id} && !$MB_SPECIAL_ARTIST{ lc $_->{id} }
            && $norm->($_->{name} // '') eq $w
        } @{ $arts || [] };
        return @ex == 1 ? lc $ex[0]{id} : undef;
    };

    # The ONE artist in $arts that carries the row's name as an ALIAS, when none
    # is NAMED so (stage 3b). MusicBrainz lists every artist's aliases in a name
    # search reply, so this costs nothing, and it is what the resolver's alias
    # pass would have found: "Genesis P-Orridge" is an alias of "Genesis Breyer
    # P-Orridge", and "Genesis Mohanraj" of Tommy Genesis. Never PROVEN: artists
    # holding the alias whose name lacks the typed words are not in this reply.
    my $uniqueAlias = sub {
        my ($arts, $name) = @_;
        my $w = $norm->(_stripAnnotation($name));
        return undef unless defined $w && length $w;
        my @ok = grep { $_->{id} && !$MB_SPECIAL_ARTIST{ lc $_->{id} } } @{ $arts || [] };
        return undef if grep { $norm->($_->{name} // '') eq $w } @ok;
        my @al = grep {
            grep { ref $_ eq 'HASH' && $norm->($_->{name} // '') eq $w } @{ $_->{aliases} || [] }
        } @ok;
        return @al == 1 ? lc $al[0]{id} : undef;
    };

    # The reply's entry for a pick that is PROVEN, given a reply holding every
    # artist of the row's name: exactly one of them, by the same-name set's own
    # key, and it is the pick. A name with an annotation is left to the page (the
    # set is keyed on the name as given, the pick on the name stripped).
    my $provenEntry = sub {
        my ($arts, $name, $mbid) = @_;
        return undef unless defined $mbid && _stripAnnotation($name) eq $name;
        my $want = _nameKey($name);
        my @same = grep { $_->{id} && _nameKey($_->{name}) eq $want } @{ $arts || [] };
        return (@same == 1 && lc $same[0]{id} eq $mbid) ? $same[0] : undef;
    };

    $q = defined $q ? $q : '';
    $q =~ s/^\s+|\s+$//g;
    # A row whose name IS the query: the resolver answered that very name for
    # the search a moment ago, so it goes to the resolver and costs nothing.
    my $isQuery = sub {
        my ($n) = @_;
        $n =~ s/^\s+|\s+$//g;
        return length($q) && lc($n) eq lc($q);
    };

    # PASS 2: one combined search for the rows still unanswered. Only for two or
    # more: for one, the resolver's own first pass is that same question.
    # The rows pass 1 answered by name but could not prove RIDE in it (0.56.6,
    # analysis §A14): a common query's reply is partial (Genesis 140 matches,
    # Air 628), so it cannot show a name has one artist, and the tap on such a
    # row paid for its own name search. They ride only when the search is sent
    # anyway, so they cost no request (every one of 42 searches measured sent
    # it), and they never change a pick: they can only be proven.
    my $combined = sub {
        my @left = grep { !defined $pick{ $_->[0] } && !$isQuery->($_->[1]) } @$pend;
        return $cb->(\%pick, \%proven) if @left < 2;
        my @check = grep { $recheck{ $_->[0] } } @$pend;
        my $query = join ' OR ', map {
            (my $n = _stripAnnotation($_->[1])) =~ s/"/ /g;
            'artist:"' . $n . '"';
        } @left, @check;
        utf8::encode($query) if utf8::is_utf8($query);
        (my $safe = $query) =~ s/([^A-Za-z0-9])/sprintf("%%%02X",ord($1))/ge;
        _netGet(_mbBase() . 'artist?query=' . $safe . '&fmt=json&limit=100',
            sub {
                my $d = eval { from_json(shift->content) };
                my $arts = (!$@ && ref $d eq 'HASH' && ref $d->{artists} eq 'ARRAY')
                           ? $d->{artists} : undef;
                my $count = ($arts && defined $d->{count} && $d->{count} =~ /^\d+$/)
                            ? $d->{count} : undef;
                # COMPLETE or nothing: "exactly one artist so named" means
                # something only when every artist the search matched is here.
                # And then it holds every artist of each row's name (each row's
                # own phrase is one of the terms), so an answer is proven.
                my ($got, $upgraded) = (0, 0);
                if ($arts && defined $count && $count <= @$arts) {
                    for my $p (@left) {
                        my $m = $unique->($arts, $p->[1]) or next;
                        $pick{ $p->[0] } = $m;
                        my $e = $provenEntry->($arts, $p->[1], $m);
                        $proven{ $p->[0] } = $e if $e;
                        $got++;
                    }
                    # A ridden row is proven only when the one artist of its
                    # name here is pass 1's pick. Two so named, or another one,
                    # and the pick stands unproven: the page decides it.
                    for my $p (@check) {
                        my $m = $unique->($arts, $p->[1]);
                        next unless $m && $m eq $pick{ $p->[0] };
                        my $e = $provenEntry->($arts, $p->[1], $m) or next;
                        $proven{ $p->[0] } = $e;
                        $upgraded++;
                    }
                }
                _dbg("search rows: one combined search for " . scalar(@left)
                    . " rows answered $got"
                    . (@check ? ", and proved $upgraded of " . scalar(@check)
                       . " answered by the typed query's reply" : '')
                    . ($arts && !(defined $count && $count <= @$arts)
                       ? ' (reply incomplete, ' . ($count // 'no count') . ' matched)' : ''));
                $cb->(\%pick, \%proven);
            },
            sub { $cb->(\%pick, \%proven) },
            timeout => 12);
    };

    # PASS 1: the typed query's own reply. The search resolved the query with
    # NAME_FETCH (15) entries; when those are the whole result (88% of names,
    # measured) they have exactly the members a reply at 100 has, and that
    # reply answers this with no request. Otherwise one request at
    # NAME_FETCH_ROWS (100), as the rule was measured.
    return $combined->() unless length $q;
    my $qq = _stripAnnotation($q);
    my $qk = _nameKey($qq);
    _nameSearch(_mbBase(), _nameQuery('artist', $qq, 0), NAME_FETCH_ROWS, NAME_FETCH_ROWS,
        sub {
            my ($arts, undef, undef, $count) = @_;
            # A WHOLE reply holds every artist whose name contains the typed
            # words, so for a row whose name contains them it holds every artist
            # of that name too: the condition for a proven answer here.
            my $whole = $arts && defined $count && $count =~ /^\d+$/ && $count <= @$arts;
            my ($byAlias) = (0);
            if ($arts) {
                for my $p (@$pend) {
                    next if $isQuery->($p->[1]);
                    if (my $m = $unique->($arts, $p->[1])) {
                        $pick{ $p->[0] } = $m;
                        unless ($whole && length $qk
                            && index(' ' . _nameKey($p->[1]) . ' ', ' ' . $qk . ' ') >= 0) {
                            # Not provable here: pass 2 may prove it. Not a
                            # name with an annotation, which is never proven.
                            $recheck{ $p->[0] } = 1 if _stripAnnotation($p->[1]) eq $p->[1];
                            next;
                        }
                        my $e = $provenEntry->($arts, $p->[1], $m);
                        $proven{ $p->[0] } = $e if $e;
                    }
                    elsif (my $ma = $uniqueAlias->($arts, $p->[1])) {
                        $pick{ $p->[0] } = $ma;
                        $byAlias++;
                    }
                }
            }
            _dbg("search rows: the typed query's reply answered $byAlias row(s) by an alias")
                if $byAlias;
            $combined->();
        },
        sub { $combined->() },
        "'$qq' (search rows)");
    return;
}

# ---------------------------------------------------------------------------
# MB ARTIST ALIASES
#
# An artist's records are often sold under a name MusicBrainz files as an
# ALIAS. Field case (2026-07-19): MB's "Madness" (US rapper Manuel Gomez) has
# every streaming release under **Tony Madness** - so searching the services
# for "Madness" finds the ska band, scores zero against this artist's spine,
# and correctly concludes nothing corroborates. The artist is not absent; we
# were asking under the wrong name.
#
# Sibling of the 0.32.0 fix, in the opposite direction: that one searched MB by
# alias when the NAME found nothing; this searches the SERVICES by MB's aliases
# when the name finds nothing that corroborates.
# ---------------------------------------------------------------------------

# v2: the SAME fetch now also stores MB's canonical name (see _mbNameKey).
# `warmArtistAliases` early-returns on a cached alias list, so a v1 entry would
# keep the canonical name from ever being fetched and the fold relabel would
# silently never fire. Bumping repopulates both from one request.
# v3 (0.56.18): the entry is { names => [...], en => MB's primary English alias }
# (peekArtistEnglishName says why). A v2 list has no English name, and the
# artist page would keep reading it for up to 30 days; the bump retires them
# (DB.pm keeps this family across builds), and the artist read every first
# visit after a build makes anyway refills them.
sub _aliasKey { 'dsc:alias:3:' . lc($_[0] // '') }

# MusicBrainz's CANONICAL name for the artist. The alias fetch has always had
# it (it uses `$d->{name}` to keep the canonical spelling out of the alias
# list) and threw it away; the fold needs it to label a merged row. Written by
# _readArtist (the one artist read behind both warmArtistAliases and
# warmBandMembers) and by the name resolver, so it costs no extra request.
sub _mbNameKey { 'dsc:mbname:1:' . lc($_[0] // '') }

# THE CAUSE OF THE MISSING NAME, FOUND 2026-07-31 (see peekArtistName below,
# which has carried "the CAUSE is not established" since 0.46.x).
#
# `Slim::Utils::DbCache` DIES on a character string — the live log, caught by
# the eval that was hiding it:
#
#     artist-name cache set failed: Wide character in subroutine entry
#         at /usr/share/perl5/Slim/Utils/DbCache.pm
#
# MB names arrive from `from_json` as CHARACTERS, so every NON-ASCII canonical
# name silently failed to cache while ASCII ones wrote fine — exactly the split
# that was measured and could not be explained (the B-52s canonical is
# "The B\x{2010}52s", non-ASCII by one hyphen). The alias LIST written by the
# same response survived because an arrayref goes through Storable, which
# handles wide characters perfectly well.
#
# So the value is stored as OCTETS and decoded on read. NB this is the mirror
# image of the rule for LMS's own queries, which match CHARACTERS and nothing
# else (Sources::_cliChars). Both are load-bearing; neither is a preference.
sub _setMbName {
    my ($mbid, $name) = @_;
    return unless $mbid && defined $name && !ref $name && $name ne '';
    my $enc = $name;
    utf8::encode($enc) if utf8::is_utf8($enc);
    eval { $cache->set(_mbNameKey($mbid), $enc, ALIAS_TTL); 1 }
        or $log->warn("artist-name cache set failed: $@");
    return;
}

# IN-PROCESS FALLBACK, and it exists because the cached name went MISSING while
# the alias list written by the SAME response survived.
#
# MEASURED 2026-07-22, on two independent code paths, for the B-52's
# (127f591a): `peekArtistAliases` returned all 11 aliases while
# `peekArtistName` returned undef -- so neither the fold relabel nor the
# library attach nor 0.45.2's canonical second pass could fire, and a search
# for "b52s" produced a row named with a SERVICE spelling ("B52's"). That name
# then became the artist identity for the whole page, and `_norm` splits a
# hyphen into a space -- "B52's" -> `b52s` (one token) while every real
# candidate is `the b 52s` -- so the matcher's token-subset artist gate
# rejected EVERY candidate and the page read "No releases found" with Qobuz and
# Tidal empty, on an artist whose pools were fully cached.
#
# The CAUSE of the missing cache entry is not established (an ASCII canonical
# name written by the same sub reads back fine -- verified live on Sea Power).
# Rather than guess at it, the code no longer depends on that value surviving:
# the name is remembered in %mbNameMem as well (declared at the top of the
# file, because the resolver writes it and compiles first), and
# `warmArtistAliases` refetches when the cache has aliases but no name.
# What the name resolver answered for a name, from the cache only: the act a
# result row entered by name opens. undef when it was not asked, or found none.
sub peekArtistMbid {
    my ($class, $name) = @_;
    return undef unless defined $name && length $name;
    my $m = $cache->get(_mbidKey($name));
    return (defined $m && length $m) ? $m : undef;
}

sub peekArtistName {
    my ($class, $mbid) = @_;
    return undef unless $mbid;
    my $n = $cache->get(_mbNameKey($mbid));
    if (defined $n && length $n) {
        # Stored as octets (_setMbName); every caller compares it with names
        # that came out of from_json as CHARACTERS, so hand back characters.
        utf8::decode($n) unless utf8::is_utf8($n);
        return $n;
    }
    $n = $mbNameMem{ lc $mbid };
    return (defined $n && length $n) ? $n : undef;
}

# ---------------------------------------------------------------------------
# THE EMPTY-ARTIST VERDICT (0.46.6)
#
# Set ONLY by a real render that found nothing playable with the pools resolved
# (Browse::_buildList holds the guards and the reasoning). Read by
# filterRowsWithContent to drop a search row that leads to an empty page.
#
# Deliberately SHORT-LIVED next to the 30d name/alias entries: this is a
# judgement about a CATALOGUE, which changes when a service adds the artist,
# whereas a canonical name does not. A week means a wrongly-recorded verdict
# cannot outlive a build cycle, and the cost of being wrong is one re-render.
use constant EMPTY_TTL => 7 * 86400;

sub _emptyKey { 'dsc:empty:1:' . lc($_[0] // '') }

sub markArtistEmpty {
    my ($class, $mbid, $name) = @_;
    return unless $mbid;
    eval { $cache->set(_emptyKey($mbid), 1, EMPTY_TTL); 1 } or return;
    _dbg("empty artist recorded: " . ($name // '?') . " ($mbid) - search rows "
        . 'for it will be hidden for ' . int(EMPTY_TTL / 86400) . 'd');
}

sub peekArtistEmpty {
    my ($class, $mbid) = @_;
    return 0 unless $mbid;
    return $cache->get(_emptyKey($mbid)) ? 1 : 0;
}

# THE VERDICT MUST BE FALSIFIABLE (0.48.5).
#
# Field (Simon, 2026-07-22): *"a first search for Nick Cave gave 4 hits ... now
# going back to search again it's hidden the solo Nick Cave and it shouldn't
# have."* It was hidden by a verdict recorded against his mbid, and the page
# for that mbid demonstrably renders 9 albums, 5 singles and a compilation. So
# the verdict was WRONG — and 0.46.6 gave it no way to be proven wrong: it
# could only be SET, never unset, short of the 7-day TTL or a Refresh on a page
# the user can no longer reach from search.
#
# A judgement that only ever accumulates is not a cache, it is a ratchet. Any
# render that finds real content is the strongest possible disproof and costs
# nothing to act on, so it clears the entry. Returns whether anything went, so
# the caller can say so in the log rather than clearing silently every render.
sub clearArtistEmpty {
    my ($class, $mbid) = @_;
    return 0 unless $mbid;
    return 0 unless $cache->get(_emptyKey($mbid));
    eval { $cache->remove(_emptyKey($mbid)); 1 } or return 0;
    return 1;
}

sub peekArtistAliases {
    my ($class, $mbid) = @_;
    return undef unless $mbid;
    my $a = $cache->get(_aliasKey($mbid));
    $a = $a->{names} if ref $a eq 'HASH';
    return ref $a eq 'ARRAY' ? $a : undef;
}

# MusicBrainz's PRIMARY ENGLISH ALIAS (locale "en", primary), from the same
# artist read as the aliases; undef when it has none. Cache only. Wanted for an
# artist whose own name has no Latin letter (米津玄師): the services outside Japan
# file him as "Kenshi Yonezu", so his page searches that first
# (Browse::_poolQuery). NOT the first Latin alias: measured 2026-10-01 over nine
# such artists, all nine have a primary English alias and for six it is not the
# first Latin one (宇多田ヒカル: "Cubic U" before "Hikaru Utada"; 坂本龍一: "R.S.").
sub peekArtistEnglishName {
    my ($class, $mbid) = @_;
    return undef unless $mbid;
    my $a = $cache->get(_aliasKey($mbid));
    return undef unless ref $a eq 'HASH';
    my $en = $a->{en};
    return undef unless defined $en && length $en;
    utf8::decode($en) unless utf8::is_utf8($en);
    return $en;
}

my %nameRefetched;   # one recovery fetch per artist per plugin run -- see below

sub warmArtistAliases {
    my ($class, $mbid, $cb) = @_;
    $cb ||= sub {};
    return $cb->([]) unless $mbid;
    if (my $have = $class->peekArtistAliases($mbid)) {
        # A cached alias list with NO canonical name is the state measured
        # above, and it is silently disabling three features. Fetch once to
        # recover it -- ONE request per artist per plugin run even if the write
        # fails again, because %mbNameMem then answers and this branch is not
        # reached; %nameRefetched is the belt-and-braces bound.
        return $cb->($have)
            if $class->peekArtistName($mbid) || $nameRefetched{ lc $mbid }++;
        _dbg("aliases $mbid: cached, but no canonical name - refetching for it");
    }

    # ONE request for the aliases AND the band members (stage 1, 2026-09-29):
    # _readArtist fetches the artist resource once and fills both caches, so
    # the band lookup later in the MB chain finds its answer already there.
    _readArtist($mbid, sub { $cb->($_[0] ? $_[0]{aliases} : []) });
    return;
}

# THE CLOSEST NAMES MUSICBRAINZ KNOWS, FOR A SEARCH THAT FOUND NOTHING (0.56.38,
# resolver plan Part D step 2; Simon 2026-10-02: "okay", on the trade of about a
# second more on a search that today ends in "No artists found"). Measured on
# 0.56.37: a misspelt name costs 2-3 requests before the reply (3.9-7.0 s) and
# finds nothing; of the query forms, only MusicBrainz's FUZZY one finds the act
# (Beatels -> The Beatles, Hawkwnd -> Hawkwind, Jandk -> Jandek). Its scores are
# RELATIVE (the top hit is always 100, Jandec -> Handel 100), so they cannot say
# how close a hit is: the pick is by edit distance from what was typed instead.
#
# ONE request, each word fuzzy (`artist:(w1~ w2~)`, limit 25), asked by Browse
# only when the services, the library and the same-name acts gave nothing. Kept:
# a name at most 2 edits from the typed one (1 for 4 letters or fewer), compared
# after _norm with a leading "the" dropped, a swap of neighbouring letters
# counting as one edit; closest first, then MusicBrainz's score; at most 3.
# Measured on 21 misspellings (mirror, scratchpad fuzzydesign.py): the act meant
# kept for all 21, first for 18. Cached with its answer (CAND_TTL), empty too;
# a failed request answers nothing and is not cached.
use constant FUZZY_MAX => 3;

sub _fuzzyKey {
    my $k = 'dsc:fuzzy:1:' . lc($_[0] // '');
    utf8::encode($k) if utf8::is_utf8($k);
    return $k;
}

sub _fuzzyFold {
    (my $k = _nameKey($_[0])) =~ s/^the //;
    return $k;
}

# Edits between two strings, a swap of neighbouring letters counting as one
# ("beatels" is one from "beatles").
sub _editDistance {
    my @a = split //, $_[0];
    my @b = split //, $_[1];
    my @d = ([ 0 .. scalar @b ]);
    for my $i (1 .. @a) {
        $d[$i][0] = $i;
        for my $j (1 .. @b) {
            my $v = $d[$i-1][$j-1] + ($a[$i-1] eq $b[$j-1] ? 0 : 1);
            $v = $d[$i-1][$j] + 1 if $d[$i-1][$j] + 1 < $v;
            $v = $d[$i][$j-1] + 1 if $d[$i][$j-1] + 1 < $v;
            $v = $d[$i-2][$j-2] + 1
                if $i > 1 && $j > 1 && $a[$i-1] eq $b[$j-2] && $a[$i-2] eq $b[$j-1]
                && $d[$i-2][$j-2] + 1 < $v;
            $d[$i][$j] = $v;
        }
    }
    return $d[scalar @a][scalar @b];
}

sub _fuzzyPick {
    my ($name, $arts) = @_;
    my $want = _fuzzyFold($name);
    return [] unless length $want;
    (my $letters = $want) =~ s/ //g;
    my $lim = length($letters) <= 4 ? 1 : 2;
    my @near;
    for my $art (@{ ref $arts eq 'ARRAY' ? $arts : [] }) {
        next unless ref $art eq 'HASH' && $art->{id} && !$MB_SPECIAL_ARTIST{ lc $art->{id} };
        my $k = _fuzzyFold($art->{name});
        next unless length $k && abs(length($k) - length($want)) <= $lim;
        my $d = _editDistance($want, $k);
        push @near, [ $d, $art ] if $d <= $lim;
    }
    @near = sort { $a->[0] <=> $b->[0] || ($b->[1]{score} // 0) <=> ($a->[1]{score} // 0) } @near;
    splice @near, FUZZY_MAX if @near > FUZZY_MAX;
    return [ map { my $x = $_->[1];
                   +{ mbid => lc $x->{id}, name => $x->{name}, score => $x->{score} // 0,
                      disambiguation => $x->{disambiguation}, country => $x->{country},
                      type => $x->{type} } } @near ];
}

sub fuzzyArtists {
    my ($class, $name, $cb) = @_;
    my @w = split ' ', _fuzzyFold($name);
    return $cb->([]) unless @w;
    if (my $hit = $cache->get(_fuzzyKey($name))) {
        return $cb->(ref $hit eq 'ARRAY' ? $hit : []);
    }
    my $q = 'artist:(' . join(' ', map { "$_~" } @w) . ')';
    utf8::encode($q) if utf8::is_utf8($q);
    (my $safe = $q) =~ s/([^A-Za-z0-9])/sprintf("%%%02X",ord($1))/ge;
    _netGet(_mbBase() . 'artist?query=' . $safe . '&fmt=json&limit=25',
        sub {
            my $data = eval { from_json(shift->content) };
            my $arts = (!$@ && ref $data eq 'HASH' && ref $data->{artists} eq 'ARRAY')
                       ? $data->{artists} : undef;
            return $cb->([]) unless $arts;
            my $near = _fuzzyPick($name, $arts);
            eval { $cache->set(_fuzzyKey($name), $near, CAND_TTL); 1 };
            _dbg("closest names '$name': " . (join('; ', map { $_->{name} } @$near) || 'none'));
            $cb->($near);
        },
        sub { _dbg("closest names '$name': request failed"); $cb->([]) },
        timeout => 12);
    return;
}

my %candWaiting;

sub getArtistCandidates {
    my ($class, $name, $cb) = @_;
    $cb ||= sub {};
    $name = defined $name ? $name : '';
    $name =~ s/^\s+|\s+$//g;
    return $cb->([]) unless length $name;
    my $want = _nameKey($name);

    if (my $hit = $cache->get(_candKey($name))) {
        return $cb->(ref $hit eq 'ARRAY' ? $hit : []);
    }

    # IN-FLIGHT DEDUPE — one fetch per name, however many callers ask at once.
    # MEASURED (2026-07-21): this was fetched TWICE per cold artist, because the
    # bio's shared-name guard and the candidate warm both call it before either
    # caches. Proven from the log rather than inferred — the sub only logs
    # inside its HTTP callback and the line appears twice ~4ms apart (Radiohead
    # 10.6165/10.6183). One wasted MB request per cold artist, 1.1s of it on the
    # public API.
    #
    # It QUEUES rather than answering empty, unlike the house in-flight pattern
    # (warmOfficial, which hands a late caller nothing because its result is
    # optional; warmBandMembers queued too from stage 1, through _readArtist's
    # %artistReadWaiting). Here the result DECIDES something: an empty
    # list tells `sharesNameWithProminentAsync` there is no same-name act, which
    # is precisely the 0.44.5 leak — the prominent act's biography rendered
    # under a secondary act's name.
    my $key = _candKey($name);
    if ($candWaiting{$key}) {
        push @{ $candWaiting{$key} }, [ $cb, $NET_BG ];
        return;
    }
    $candWaiting{$key} = [];
    my $bg0 = $NET_BG;
    my $settle = sub {
        my ($cands) = @_;
        # Released BEFORE the callbacks run: one of them may ask again (a
        # Refresh path clears the cache), and a marker still held would wedge
        # the name with no fetch in flight to release it.
        my $queued = delete $candWaiting{$key};
        # Each caller under its own background flag (see $NET_BG).
        { local $NET_BG = $bg0; $cb->($cands); }
        for my $w (@{ $queued || [] }) {
            local $NET_BG = $w->[1];
            $w->[0]->($cands);
        }
    };

    # Quoted primary, unquoted retry — the same rule as _artistMbidByName, and
    # for the same measured reason (artist:"janes addiction" returns 0 because an
    # exact phrase cannot match [jane][s][addiction]). No closeness gate is needed
    # here: the `_nameKey eq $want` filter below already demands the candidate's
    # NAME normalise equal to the query, which is a stricter test than the loose
    # pass in _artistMbidByName has to apply to a top hit.
    my $mkQ = sub {
        my ($loose) = @_;
        return _nameQuery('artist', $name, $loose) . '&limit=15';
    };
    my $mirror = !_mbThrottled();

    # Self-passing ($self) closure, not a lexical $run capture — avoids the
    # reference-cycle leak (same fix as _artistMbidByName, ported from LBF 0.9.95).
    my $run = sub {
        my ($self, $base, $isFb, $loose) = @_;
        # The reply, however it arrived (dispatch at the end of $run): the first
        # 15 entries, or undef when it did not parse.
        my $onReply =
            sub {
                my ($arts) = @_;
                # Same proven-index rule as _artistMbidByName above.
                if (_mbSearchVerdict($arts, $mirror, $isFb)) {
                    _dbg("artist candidates '$name': 0 on mirror; retrying public API");
                    return $self->($self, MB_DEFAULT_BASE_URL, 1, $loose);
                }
                my @out;
                for my $a (@{ $arts || [] }) {
                    next unless $a->{id} && _nameKey($a->{name}) eq $want;
                    # Never one of MB's special entities, as every other name
                    # lookup here already drops them (0.56.41): listed, a search
                    # asked about 89ad4ac3's discography, and a dead library tag
                    # browsed its six pages to disambiguate (_disambiguateByLibrary).
                    next if $MB_SPECIAL_ARTIST{ lc $a->{id} };
                    # disambiguation/country/type are what make several acts
                    # with ONE name tellable apart ("English pop/ska band" vs
                    # "Horrorcore rapper, member of Bedlam"). MB has always
                    # sent them; this used to keep only the mbid and score,
                    # which is fine for picking a winner and useless for
                    # showing a user the alternatives.
                    push @out, {
                        mbid  => lc $a->{id},
                        name  => $a->{name},
                        score => $a->{score} // 0,
                        disambiguation => $a->{disambiguation},
                        country        => $a->{country},
                        type           => $a->{type},
                    };
                }
                @out = sort { $b->{score} <=> $a->{score} } @out;

                # Nothing NAMED like the query -> retry unquoted once before
                # caching "MB knows no artist by this name".
                if (!@out && !$loose) {
                    _dbg("artist candidates '$name': 0 same-name; retrying unquoted");
                    return $self->($self, $base, $isFb, 1);
                }
                _dbg("artist candidates '$name': " . scalar(@out) . ' same-name'
                    . ($loose ? ' [unquoted]' : '')
                    . ($isFb ? ' [public fallback]' : ''));
                # Cached even when EMPTY — "MB knows no artist by this name" is
                # a real answer and re-asking on every search is pure cost. An
                # HTTP failure below is NOT cached (same rule as the rest).
                eval { $cache->set(_candKey($name), \@out, CAND_TTL); 1 };
                $settle->(\@out);
            };
        my $onError =
            sub {
                my $err = shift->error // '?';
                return $self->($self, MB_DEFAULT_BASE_URL, 1, $loose) if $mirror && !$isFb;
                _dbg("artist candidates '$name' HTTP error ($err)");
                # EVERY waiter must be settled on the failure path too: the bio
                # leg gates the render, so a queue drained only on success would
                # hang the page rather than degrade it.
                $settle->([]);
            };

        # The QUOTED query is the one the resolver's first pass asks too, so it
        # goes through the shared search (_nameSearch): a reply the resolver
        # fetched a moment ago answers it, reading the first 15 entries.
        # EXACT: only a reply fetched at 15 answers it (a first 15 read from a
        # reply at 100 is not always the same set; see _nameSearch).
        return _nameSearch($base, _nameQuery('artist', $name, 0), 15, 15,
                           $onReply, $onError, "'$name'", 1)
            unless $loose;
        _netGet($base . $mkQ->($loose),
            sub {
                my $data = eval { from_json(shift->content) };
                my $arts = (!$@ && ref $data eq 'HASH' && ref $data->{artists} eq 'ARRAY')
                           ? $data->{artists} : undef;
                $onReply->($arts);
            },
            $onError,
            timeout => 12);
    };
    $run->($run, _mbBase(), 0, 0);
}


# ---------------------------------------------------------------------------
# MBID -> release groups
# ---------------------------------------------------------------------------

# getReleaseGroups(mbid => $m, force => 0|1, read => 0|1,
#                  onDone => sub(\@rgs), onError => sub($msg))
# Each entry: { mbid, title, date ('YYYY[-MM[-DD]]' or ''), type (primary,
# may be ''), secondary => [..] }. Cached whole; force bypasses the cache read
# (the write still happens, so Refresh renews the entry). It does not skip the
# artist read that read => 1 asks for.
#
# read => 1 is the ARTIST PAGE's way in (stage 2, 2026-09-29): read the artist
# first (_readArtist), because the page makes that request anyway for its band
# members, and for an artist with fewer than 25 groups the reply carries the
# whole spine, so the browse is not sent at all. At 25 or more, or when the read
# fails, the list comes from ListenBrainz and the community API (0.56.7,
# _fastSpine), and the browse runs only when they give none, or after a Refresh
# (_rgFullKey). Every other caller (the same-name disambiguation, the release
# page, play) leaves it off and browses: for them the read would be an extra
# request.

# Sync cache read of an artist's release groups — undef when not yet fetched.
# The detail page needs the same MB title spine the list used (to resolve the
# same service artist) and cannot afford an async fetch mid-render.
sub peekReleaseGroups {
    my ($class, $mbid) = @_;
    return undef unless $mbid;
    my $c = $cache->get(_rgKey(lc $mbid));
    return ref $c eq 'ARRAY' ? $c : undef;
}

sub getReleaseGroups {
    my ($class, %a) = @_;
    my $mbid    = $a{mbid} or do { ($a{onError} || sub {})->('no mbid'); return };
    my $onDone  = $a{onDone}  || sub {};
    my $onError = $a{onError} || sub { $onDone->([]) };

    # One of MB's special entities has no list worth asking for (0.56.41,
    # isVarious): Various Artists is every compilation, six pages to browse.
    # No page shows one since; this answers a release tile or play action left
    # over from a page drawn before, and anything else that would ask. Nothing
    # is cached.
    if ($MB_SPECIAL_ARTIST{ lc $mbid }) {
        _dbg("release groups for $mbid: a special MB entity - nothing asked");
        $onDone->([]);
        return;
    }

    my $key = _rgKey($mbid);
    if (!$a{force} && (my $c = $cache->get($key))) {
        $log->info("release-group cache hit: $key (" . scalar(@$c) . " entries)");
        $onDone->($c);
        return;
    }
    # The drawn list has expired but MusicBrainz's completed one is waiting
    # (0.56.7): there is no tree to keep stable, so it is taken at once.
    if (!$a{force} && $class->promoteCompleted($mbid)) {
        $onDone->($class->peekReleaseGroups($mbid) || []);
        return;
    }

    # MusicBrainz's list, cached as the spine. It replaces a first list from
    # ListenBrainz (0.56.7), so that list's markers go with it.
    # $refresh (0.56.8): a Refresh whose browse will be cut at the cap also
    # keeps the groups past it, from ListenBrainz and the community API, asked
    # alongside the browse's remaining pages (_pastCap).
    my $browse = sub {
        my ($refresh) = @_;
        my $past;
        _browseGroups($mbid,
            sub {
                my ($all, $total, $truncated) = @_;
                # $whole: the groups past the cap were asked and answered
                # (_pastCap). A list still cut at the cap is kept RGCUT_TTL.
                my $store = sub {
                    my ($list, $cm, $whole) = @_;
                    my $ttl = ($truncated && !$whole) ? RGCUT_TTL : RG_TTL;
                    $cache->remove($_) for _rgFastKey($mbid), _cmDiscoKey($mbid), _rgFullKey($mbid);
                    eval {
                        $cache->set($key, $list, $ttl);
                        $cache->set(_cmDiscoKey($mbid), $cm, RG_TTL) if $cm;
                        1;
                    } or do {
                        # Without the verdicts the kept groups would all be
                        # asked by id: MusicBrainz's own list instead.
                        $log->warn("release-group cache set failed: $@");
                        $cache->remove(_cmDiscoKey($mbid));
                        $list = $all;
                        $ttl  = $truncated ? RGCUT_TTL : RG_TTL;
                        eval { $cache->set($key, $all, $ttl); 1 }
                            or $log->warn("release-group cache set failed: $@");
                    };
                    $log->info("release groups for $mbid: " . scalar(@$list) . " of $total"
                        . ($ttl == RGCUT_TTL ? ' (cut at the cap: kept an hour)' : ''));
                    $onDone->($list);
                };
                return $store->($all) unless $truncated && $past;
                $past->($all, $store);
            },
            $onError,
            ($refresh ? (onTotal => sub {
                my ($total) = @_;
                $past = _pastCap(lc $mbid, $total)
                    if $total > RG_MAX_PAGES * RG_PAGE_SIZE && !$MB_SPECIAL_ARTIST{ lc $mbid };
            }) : ()));
    };

    if ($a{read}) {
        # The read caches the spine itself when it carries the whole list
        # (fewer than 25 groups); otherwise it answers without one.
        _readArtist($mbid, sub {
            my ($r) = @_;
            return $onDone->($r->{rgs}) if $r && $r->{rgs};
            # THE ARTIST PAGE'S FIRST LIST (0.56.7; analysis §A16): from
            # ListenBrainz and the community API, not the browse, unless a
            # Refresh asked for MusicBrainz itself. See _fastSpine.
            my $refresh = $cache->get(_rgFullKey($mbid));
            if (!$a{force} && !$refresh) {
                return _fastSpine(lc $mbid, sub {
                    my ($rgs) = @_;
                    return $onDone->($rgs) if $rgs;
                    $browse->();
                });
            }
            $browse->($refresh ? 1 : 0);
        });
        return;
    }
    $browse->();
}

# The release-group browse: $onOk->(\@all, $total, $truncated), every page up to
# RG_MAX_PAGES, entries built and their aliases pruned; $onErr->($err). Nothing
# is cached here. `background => 1` sends every page as background work;
# `onTotal => sub { $total }` is told MusicBrainz's count after the first page.
sub _browseGroups {
    my ($mbid, $onOk, $onErr, %opt) = @_;
    my @all;
    my $page = 0;

    # Self-passing closure, not a captured lexical (the 0.30.1 leak fix): this
    # pager runs on every artist page that misses the release-group cache.
    my $fetchPage = sub {
        my ($self, $offset) = @_;
        # inc=aliases: MusicBrainz titles a release group in its ORIGINAL
        # language and carries other spellings as ALIASES, which no amount of
        # title normalisation can reach. Kraftwerk is filed under
        # "Radio‐Aktivität" / "Computerwelt" / "Die Mensch·Maschine" with the
        # English titles as aliases; Prince's is literally `Sign “☮︎” the Times`
        # (alias "Sign o' the Times"); Big Star's "Third/Sister Lovers" is the
        # release group `3rd` (alias "Third"). Measured cost: NO extra requests
        # (same call, one more parameter) and +20% payload on a 100-RG page
        # (28.4KB -> 34.2KB); only ~5% of release groups carry an alias at all.
        my $url = _mbBase() . 'release-group?artist=' . $mbid
                . '&limit=' . RG_PAGE_SIZE . '&offset=' . $offset
                . '&inc=aliases&fmt=json';

        $log->info("fetching release groups: $url");

        _netGet($url,
            sub {
                my $resp = shift;
                my $data = eval { from_json($resp->content) };
                if ($@ || ref $data ne 'HASH' || ref $data->{'release-groups'} ne 'ARRAY') {
                    _dbg("MB release-group page unparseable for $mbid (offset $offset)");
                    $onErr->('bad MB response'); return;
                }

                for my $rg (@{ $data->{'release-groups'} }) {
                    my $e = _rgEntry($rg) or next;
                    push @all, $e;
                }

                my $total = $data->{'release-group-count'} // scalar @all;
                $page++;
                # The count, once, before the next page is asked for (a
                # Refresh starts its past-the-cap requests here, 0.56.8).
                $opt{onTotal}->($total) if $opt{onTotal} && $page == 1;
                if ($offset + RG_PAGE_SIZE < $total && $page < RG_MAX_PAGES) {
                    # Straight on to the next page: the pages are serial by
                    # construction (each is asked for from the previous one's
                    # response) and _netGet supplies the MB etiquette gap on
                    # the public host. A second gap here would double it.
                    $self->($self, $offset + RG_PAGE_SIZE);
                    return;
                }

                my $truncated = $offset + RG_PAGE_SIZE < $total ? 1 : 0;
                $log->warn("release-group list truncated at " . scalar(@all) . " of $total for $mbid")
                    if $truncated;

                _pruneAliases(\@all);
                $onOk->(\@all, $total, $truncated);
            },
            sub {
                my $err = shift->error // 'HTTP error';
                $log->error("MB release-group fetch failed: $err");
                $onErr->($err);
            },
            timeout => 20, ($opt{background} ? (background => 1) : ()));
    };

    $fetchPage->($fetchPage, 0);
    return;
}

# One MusicBrainz release group -> its spine entry, or undef without an id or a
# title. The browse and the artist read give a group the same fields, so both
# build their entries here. Alias NAMES only, deduped, and never the title
# itself — the matcher tries the title first, so repeating it here would just
# cost a second identical comparison. Stored only when non-empty to keep the
# cached spine small.
sub _rgEntry {
    my ($rg) = @_;
    return undef unless ref $rg eq 'HASH' && $rg->{id} && defined $rg->{title};
    my (@aka, %seenAka);
    if (ref $rg->{aliases} eq 'ARRAY') {
        for my $al (@{ $rg->{aliases} }) {
            my $n = ref $al eq 'HASH' ? $al->{name} : undef;
            next unless defined $n && length $n;
            next if $n eq $rg->{title};
            push @aka, $n unless $seenAka{$n}++;
        }
    }
    return {
        mbid      => lc $rg->{id},
        title     => $rg->{title},
        date      => $rg->{'first-release-date'} // '',
        type      => $rg->{'primary-type'}       // '',
        secondary => ref $rg->{'secondary-types'} eq 'ARRAY'
                       ? $rg->{'secondary-types'} : [],
        (@aka ? (aliases => \@aka) : ()),
    };
}

# An alias that is ANOTHER group's canonical title already has an owner, so
# drop it. MB aliases The B-52's box "3 Original CDs" as "The B‐52’s", the title
# of one of its releases and of the 1979 debut group. Through the alias pass
# the box claimed the user's copy of the debut (field, 2026-09-19). Done once
# per spine, before it is cached, so every reader of {aliases} (the list, the
# detail page, claimedLocalIds, the index keys) sees the same spine, whichever
# request built it. Edits the entries in place.
sub _pruneAliases {
    my ($all) = @_;
    my %owners;
    push @{ $owners{ Plugins::Discography::Sources::_norm($_->{title}) } }, $_->{mbid}
        for @$all;
    for my $rg (grep { $_->{aliases} } @$all) {
        my @keep = grep {
            my $own = $owners{ Plugins::Discography::Sources::_norm($_) } || [];
            !grep { $_ ne $rg->{mbid} } @$own;
        } @{ $rg->{aliases} };
        if (@keep < @{ $rg->{aliases} }) {
            _dbg("aliases of '$rg->{title}': dropped "
                . (@{ $rg->{aliases} } - @keep) . " that another group owns");
        }
        if (@keep) { $rg->{aliases} = \@keep } else { delete $rg->{aliases} }
    }
    return;
}

# Drop the cached artist-name -> MBID entry (found OR the '' miss sentinel), so
# the next lookup re-queries. Keyed exactly like _artistMbidByName. Used by the
# "not found" view's Refresh to bust a stale miss without waiting out the TTL.
sub clearArtistMbid {
    my ($class, $name) = @_;
    return unless defined $name && length $name;
    $name =~ s/^\s+|\s+$//g;
    return unless length $name;
    my $key = _mbidKey($name);
    $cache->remove($key);
}

# The biography of an act that shares its name, kept under its MusicBrainz id and
# never its name (0.56.22, Browse::_fetchExactBio). Lives here so Refresh below
# and the page use one spelling.
sub _bioMbidKey { return 'dsc:biomb:1:' . lc($_[0] // '') }

# Clear ALL of an artist's cached MusicBrainz data in one shot: resolution (mbid,
# incl. the '' miss sentinel), release-group list, bootleg map, band members,
# and bio (by name, and by mbid for a shared name). Streaming candidates live in Sources — call Sources::clearCandidates
# alongside (the CLI command and the view Refresh both do). This is the "re-pull
# from MusicBrainz" primitive: a stale/poisoned cache (e.g. a miss pinned while a
# mirror's search index was still building) can always be busted, from the UI
# Refresh OR the HTTP `discography clearcache` command. Recovers the mbid from a
# cached HIT when the caller passes only a name (a MISS has no mbid-keyed caches
# to clear). Returns an arrayref of the cache classes touched, for logging.
# `refresh => 1` (the page's Refresh row, not the clearcache command): the next
# list for this artist comes from MusicBrainz itself, awaited, not the first list
# from ListenBrainz and the community API (0.56.7, _rgFullKey). The command keeps
# a plain cold start, which is the fast path.
sub clearArtistCache {
    my ($class, %a) = @_;
    my $name = $a{name};
    $name =~ s/^\s+|\s+$//g if defined $name;
    my $mbid = $a{mbid};

    # THE LIBRARY TAG BEFORE THE NAME, as the page resolves it (getArtistMbid:
    # "Library tag wins"). Field, 2026-10-01: `clearcache artist_id:154055`
    # (Radiohead, tagged) found no mbid under the name, cleared only the
    # name-keyed streaming pools, and the next open read the MB-keyed one the
    # page actually uses (`peekPool ...:tidal:mb:a74b1b7f...: HIT`).
    $mbid = _libraryTagMbid($a{artist_id}) if !$mbid && $a{artist_id};

    # An untagged library artist's page opened the act its albums named (C2):
    # that act's caches are the page's, and Refresh asks the albums again.
    my $libKey;
    if ($a{artist_id} && !_libraryTagMbid($a{artist_id})) {
        $libKey = _libMbidKey($a{artist_id}, _libraryName($a{artist_id}) // $name);
        my $l = $cache->get($libKey);
        $mbid = $l if !$mbid && $l && $l =~ $UUID_RE;
    }

    if (!$mbid && defined $name && length $name) {
        my $ck = _mbidKey($name);
        my $c = $cache->get($ck);
        $mbid = $c if $c && $c =~ $UUID_RE;
    }
    $mbid = lc $mbid if $mbid;

    my @cleared;
    if ($libKey) { $cache->remove($libKey); push @cleared, 'library-albums' }
    if (defined $name && length $name) {
        $class->clearArtistMbid($name);
        my $bk = 'dsc:bio:2:' . lc $name;   # Browse::_fetchArtistBio's key — keep in step
        utf8::encode($bk) if utf8::is_utf8($bk);
        $cache->remove($bk);
        # The SAME-NAME SET. Without this, clearcache could not shift a wrong
        # disambiguation list at all — and, worse for diagnosis, it left the
        # cache that the bio guard peeks at intact, so a "cold" reproduction
        # attempt silently ran warm (2026-07-19: this cost a false negative
        # while chasing exactly that guard).
        # Drop the candidates' release-group counts BEFORE the list that names
        # them, or they outlive their only index and clearing by name leaves
        # the empty-artist filter still deciding from stale numbers.
        for my $c (@{ $class->peekArtistCandidates($name) || [] }) {
            $cache->remove(_rgCountKey($c->{mbid})) if $c->{mbid};
        }
        $cache->remove(_candKey($name));
        # And the name-search reply kept in memory (_nameSearch), or a Refresh
        # inside NAME_MEMO_TTL would resolve from the reply it means to replace.
        _nameMemoForget($name);
        push @cleared, qw(mbid bio candnames);
    }
    if ($mbid) {
        $cache->remove(_rgKey($mbid));       push @cleared, 'rg';
        # The first list's markers and MusicBrainz's completed list (0.56.7).
        $cache->remove($_) for _rgFastKey($mbid), _rgNextKey($mbid), _cmDiscoKey($mbid);
        if ($a{refresh}) {
            eval { $cache->set(_rgFullKey($mbid), 1, RGFULL_TTL); 1 };
            push @cleared, 'musicbrainz-next';
        }
        $cache->remove(_officialKey($mbid)); push @cleared, 'official';
        $cache->remove(_bandsKey($mbid));    push @cleared, 'bands';
        $cache->remove(_bioMbidKey($mbid));  push @cleared, 'bio-mbid';
        $cache->remove(_collabsKey($mbid));
        $cache->remove(_collabCandKey($mbid)); push @cleared, 'collabs';
        $cache->remove(_rgCountKey($mbid));  push @cleared, 'rgcount';
        # The empty verdict MUST go with them: Refresh exists to say "look
        # again", and a stale "nothing here" would keep the artist's search row
        # hidden however many times the user asked.
        $cache->remove(_emptyKey($mbid));    push @cleared, 'empty';
        # MusicBrainz's name and aliases for this artist. The store keeps them
        # across builds (DB.pm's artist table), so a build no longer re-pulls
        # them and Refresh must — an alias edited in MusicBrainz is exactly what
        # "look again" is for. The in-process memo and the once-per-run recovery
        # bound go too, or the memo would keep answering with the old name and
        # warmArtistAliases would refuse to fetch it again this run.
        $cache->remove(_mbNameKey($mbid));
        $cache->remove(_aliasKey($mbid));
        delete $mbNameMem{$mbid};
        delete $nameRefetched{$mbid};
        push @cleared, 'name', 'aliases';
    }

    # Owned release -> release group, for the albums this artist's page shows.
    # Kept across builds too (DB.pm's mbid table), and keyed by RELEASE, so the
    # artist's own keys do not reach it: ask the library which albums it owns
    # (the lookup the page makes, artist_id then tag then name) and clear each
    # one's entry. The page passes its id fallback (Browse::_idFallback), so an
    # artist_id that performs on no album (The B-52's composer credit) still
    # finds the albums it warmed; without it Refresh cleared none of them.
    # Refresh and clearcache do not know the page's shared_name, so 'name' is
    # passed always: it finds a SUPERSET of the 'mbid' mode's albums, and
    # clearing one entry too many costs only a lookup on the next visit.
    my $owned = eval {
        Plugins::Discography::Sources->localAlbums($a{artist_id}, $name, $mbid,
                                                    { fallback => 'name' })
    } || [];
    my $nrel = 0;
    for my $al (@$owned) {
        next unless $al->{_mbid};
        $cache->remove(_rel2rgKey($al->{_mbid}));
        $nrel++;
    }
    push @cleared, "releases($nrel)" if $nrel;
    _dbg("clearArtistCache name='" . ($name // '') . "' mbid='" . ($mbid // '')
        . "' -> " . (join(',', @cleared) || 'nothing'));
    # The RESOLVED mbid is returned in list context, because the caller cannot
    # work it out: it is recovered HERE from the name cache, and clearing that
    # cache is the first thing this sub does. The CLI reply used to echo the
    # mbid the caller PASSED, so `clearcache artist:<name>` reported mbid=""
    # while the log showed a real one being cleared — a reply that contradicts
    # the log is how a later diagnosis goes wrong. Scalar context is unchanged,
    # so the Refresh row and every existing caller are untouched.
    return wantarray ? (\@cleared, $mbid) : \@cleared;
}

# ---------------------------------------------------------------------------
# Release-group officialness ("is this a bootleg?").
#
# MusicBrainz gives bootlegs their OWN release-groups, indistinguishable from a
# real album on every field the release-group browse returns — title, primary
# type, no secondary types. The Beatles have 14 release-groups titled exactly
# "The Beatles" (7 with no official release) plus a 2000 bootleg titled
# "The Beatles (White Album)". The only distinguishing field is release STATUS.
#
# Status is NOT available on the release-group browse we build the spine from
# ("status is not a valid parameter unless releases are requested"), and
# `inc=releases` is rejected there too. The release-group SEARCH carries it:
# each hit lists every release of the group with its id, title and status.
# Asked BY ID for the groups on the page (`rgid:A OR rgid:B ...`, 100 to a
# request) it classifies them all in at most 6 requests (stage 2, 2026-09-29;
# docs/mb-efficiency-and-community-api-analysis.md A11). It replaced a browse of
# every RELEASE of the artist (`release?artist=<arid>&inc=release-groups`),
# which took 34 requests for The Beatles and could not finish inside the first
# render's deadline, so a big artist's first page showed its bootlegs.
#
# NOT asked by ARTIST (`arid:<arid>`, paged): its pages overlap and groups go
# missing (Kraftwerk, 162 of 167 over two pages, the same five lost on every
# run, measured). So the ids come from the browse, which lists them whole.
#
# FAIL-OPEN, deliberately, everywhere: a release-group we never classified (not
# yet warmed, HTTP failure, listed with no releases, or newer than the search
# index) shows, and so does one whose releases carry NO status. MB leaves status
# unset on plenty of obscure releases — the real White Album has 2 status-less
# releases among its 25 — and hiding a real album is far worse than showing a
# bootleg.
# ---------------------------------------------------------------------------

use constant OFFICIAL_TTL       => 14 * 86400;
# Groups per by-id query: MusicBrainz's largest page, so one query is one page
# and is never paged. MEASURED: 100 ids make a 5,160-character URL, HTTP 200,
# all 100 returned (Kraftwerk, public API, 2026-09-29).
use constant RGID_BATCH_MAX     => 100;
# The most groups the bootleg check asks by id BEFORE a page is drawn when
# the rest may follow it (0.56.8, warmOfficial): two requests. Every rock artist
# measured needs one (the community classifies the rest); Bach, Beethoven, Mozart
# and Vivaldi leave 327-746 unclassified, which would be 4-8 requests in a row.
use constant PREDRAW_RGID_MAX   => 2 * RGID_BATCH_MAX;

sub _officialKey { 'dsc:rgo:v5:' . $_[0] }   # v5: built by id from the search (stage 2)

# 1 unless the release carries an explicit non-official status. A status-less
# release counts as official (see FAIL-OPEN above).
sub _isOfficial {
    my ($status) = @_;
    return 1 if !defined $status || lc($status) eq 'official';
    return 0;
}

# Cache-only, sync, safe in the render path: returns the artist's
# { rg-mbid => 0|1 } map, or undef when not yet warmed. A release-group ABSENT
# from a present map was never classified by the check -> caller fails open.
sub peekOfficial {
    my ($class, $artistMbid) = @_;
    my $c = $cache->get(_officialKey($artistMbid)) or return undef;
    return $c->{o};
}

# { release-mbid => release-group-mbid } for the same artist, or undef. Falls
# out of the SAME check as the officialness map (each group lists its
# releases), so exact MBID matching of local albums costs no extra request. It
# holds every release of every group on the page, whoever it is credited to. A
# library album tagged MUSICBRAINZ_ALBUMID holds a RELEASE mbid, and MB models
# reissues/box sets as releases under one group — which is exactly the mapping
# the title matcher can't do ("The Beatles and Esher Demos" -> White Album).
sub peekReleaseMap {
    my ($class, $artistMbid) = @_;
    my $c = $cache->get(_officialKey($artistMbid)) or return undef;
    return $c->{r};
}

# { release-group-mbid => [ distinct official edition titles ] }, or undef —
# the same check again. Browse::_editionTitles decides which a group may
# actually match by.
sub peekEditions {
    my ($class, $artistMbid) = @_;
    my $c = $cache->get(_officialKey($artistMbid)) or return undef;
    return $c->{t};
}

# ---------------------------------------------------------------------------
# Targeted release -> release-group lookups for the LIBRARY's own albums.
#
# Written (2026-07-10, Simon's Esher Demos) when the release map came from a
# release browse that took ~33 requests for a big artist and missed the first
# render. Since stage 2 (2026-09-29) the bootleg check maps every release of
# every group on the page within the deadline, owned ones included, so this
# runs AFTER the render, only for the owned releases the check did not place
# (Browse::_unplacedReleases: normally none), or for all of them when the check
# failed. The next visit uses its answers. One search for up to 50 of them at a
# time, and a `release/<mbid>?inc=release-groups` lookup for any the search
# does not return (see warmLocalReleases). Cached per release (14d), so a
# revisit costs nothing.
# ---------------------------------------------------------------------------

use constant REL2RG_TTL => 14 * 86400;

sub _rel2rgKey { 'dsc:rel2rg:v1:' . $_[0] }

# Cache-only, sync: { release-mbid => release-group-mbid } for the given release
# MBIDs that are cached with a non-empty group. Safe in the render path.
sub peekLocalReleaseMap {
    my ($class, $mbids) = @_;
    my %map;
    for my $m (@{ $mbids || [] }) {
        next unless $m;
        my $rg = $cache->get(_rel2rgKey($m));
        $map{$m} = $rg if defined $rg && length $rg;
    }
    return \%map;
}

# THE GROUP'S TYPE, FROM THE SAME REPLY (0.56.39; Simon 2026-10-02, on Ella
# Fitzgerald's "The Last Time I Committed Suicide": "this is Soundtrack not a
# compilation not sure if LMS has that but MB does"). LMS keeps no such type (the
# album reads ALBUM); MusicBrainz's group does (Album + Soundtrack), and both the
# batched search and the one-by-one lookup below already carry it, so it is kept
# beside the group at no extra request: { type => primary, secondary => [...] },
# '' for a release with no group. Read by Browse for the Appearances rows.
sub _relTypeKey { 'dsc:reltype:v1:' . $_[0] }

sub _setRelType {
    my ($m, $g) = @_;
    my $v = ref $g eq 'HASH'
        ? { type      => $g->{'primary-type'} // '',
            secondary => [ grep { defined && length } @{ ref $g->{'secondary-types'} eq 'ARRAY'
                                                         ? $g->{'secondary-types'} : [] } ] }
        : '';
    eval { $cache->set(_relTypeKey($m), $v, REL2RG_TTL); 1 }
        or $log->warn("local-release type cache set failed: $@");
}

# Cache-only, sync: { release-mbid => { type, secondary } } for the given
# release MBIDs whose group type is known. Safe in the render path.
sub peekLocalReleaseTypes {
    my ($class, $mbids) = @_;
    my %map;
    for my $m (@{ $mbids || [] }) {
        next unless $m;
        my $t = $cache->get(_relTypeKey($m));
        $map{$m} = $t if ref $t eq 'HASH' && length($t->{type} // '');
    }
    return \%map;
}

my %rel2rgInFlight;

# BATCHED FIRST (stage 1, 2026-09-29; docs/mb-efficiency-and-community-api-
# analysis.md A7 #2). One search, `release?query=reid:A OR reid:B OR ...`,
# answers up to REL_BATCH_MAX releases at once. MEASURED on the public API: 50
# real release ids in one request, all 50 resolved to the right group (59 KB,
# 0.3s, a 3,002-character URL); 10 of 10 on the mirror. A library holding 20
# tagged albums by one artist now costs 1 request instead of 20.
#
# The search only ever SAVES requests; it never decides a verdict alone. An id it
# does not return — a GROUP id tagged as an album (no release has that id; the
# measured case), a release newer than the search index, every id on a mirror
# whose search index was never built — goes to the one-by-one lookup below,
# unchanged, and gets exactly the verdict it got before (a 404 caches ''). A
# failed or unreadable search sends its whole batch the same way. So the worst
# case costs what it did before plus one request, and the answers are the ones
# the lookup gives. A batch of one uncached id skips the search (a lone id, or
# the last of 51): its lookup is already one request.
use constant REL_BATCH_MAX => 50;

# Resolve the uncached release MBIDs: in batches by search where there are two
# or more, then one by one for whatever the search left (1.1s apart on the
# public API — the queue's gap). $cb fires once when all are done (or
# immediately if none need doing). '' is cached for a release with no group / a
# 404 (e.g. the tag was actually a GROUP mbid — _mbidMatch handles that case
# directly, so no retry is wanted). HTTP failures cache nothing and are retried
# on a later visit.
sub warmLocalReleases {
    my ($class, $mbids, $cb) = @_;
    $cb ||= sub {};

    # A release whose group is known but whose TYPE is not (cached before
    # 0.56.39) is asked again, once, for it.
    my @todo = grep { $_ && !$rel2rgInFlight{$_}
                      && (!defined $cache->get(_rel2rgKey($_)) || !defined $cache->get(_relTypeKey($_))) }
               @{ $mbids || [] };
    return $cb->() unless @todo;

    $rel2rgInFlight{$_} = 1 for @todo;
    _dbg('local-release warm: ' . scalar(@todo) . ' release(s) to resolve directly');

    my @single;       # what the search did not settle -> one lookup each
    my @batches;
    push @batches, [ splice(@todo, 0, REL_BATCH_MAX) ] while @todo;
    # A batch of ONE is a lookup, not a search: a lone id, and equally the last
    # of 51 or 101. Only the last batch can be that short.
    push @single, @{ pop @batches } if @{ $batches[-1] } == 1;

    # Self-passing closures, not captured lexicals (the 0.30.1 leak fix): these
    # run on every page open that has unresolved release mbids.
    my $next;   # the one-by-one leg, defined below; $search hands over to it
    my $search = sub {
        my ($self) = @_;
        my $batch = shift @batches;
        return $next->($next) unless $batch;

        # Ids arrive lowercased (Sources::localAlbums), as MB returns them;
        # %orig still maps back to the id as given, which is what the cache
        # key and the in-flight marker were built from.
        my %orig = map { lc($_) => $_ } @$batch;
        my $q = join ' OR ', map { 'reid:' . lc $_ } @$batch;
        (my $safe = $q) =~ s/([^A-Za-z0-9])/sprintf("%%%02X",ord($1))/ge;
        my $url = _mbBase() . 'release?query=' . $safe
                . '&limit=' . scalar(@$batch) . '&fmt=json';

        my $fallBack = sub {
            my ($why) = @_;
            push @single, @$batch;
            _dbg("local-release search: $why - " . scalar(@$batch)
                 . ' release(s) to look up one by one');
            $self->($self);
        };
        _netGet($url,
            sub {
                my $data = eval { from_json(shift->content) };
                return $fallBack->('unreadable reply')
                    unless !$@ && ref $data eq 'HASH' && ref $data->{releases} eq 'ARRAY';
                my %got;
                for my $r (@{ $data->{releases} }) {
                    next unless ref $r eq 'HASH';
                    my $m = $orig{ lc($r->{id} // '') } or next;   # only ids we asked for
                    next if exists $got{$m};
                    my $rg = ref $r->{'release-group'} eq 'HASH'
                           ? lc($r->{'release-group'}{id} // '') : '';
                    next unless $rg;     # a hit without its group: the lookup decides
                    eval { $cache->set(_rel2rgKey($m), $rg, REL2RG_TTL); 1 }
                        or $log->warn("local-release cache set failed: $@");
                    _setRelType($m, $r->{'release-group'});
                    $got{$m} = $rg;
                    delete $rel2rgInFlight{$m};
                }
                my @miss = grep { !exists $got{$_} } @$batch;
                push @single, @miss;
                _dbg('local-release search: ' . scalar(keys %got) . ' of '
                     . scalar(@$batch) . ' resolved in one request'
                     . (@miss ? '; ' . scalar(@miss) . ' to look up one by one' : ''));
                $self->($self);
            },
            sub { $fallBack->('request failed (' . (shift->error // 'HTTP error') . ')') },
            timeout => 15);
    };

    $next = sub {
        my ($self) = @_;
        my $m = shift @single;
        unless ($m) { $cb->(); return; }

        my $done = sub { delete $rel2rgInFlight{$m}; $self->($self); };
        my $url  = _mbBase() . 'release/' . $m . '?inc=release-groups&fmt=json';

        _netGet($url,
            sub {
                my $data = eval { from_json(shift->content) };
                if ($@ || ref $data ne 'HASH') {
                    _dbg("local-release: unparseable for $m (retry next visit)");
                    $done->(); return;      # nothing cached -> retried later
                }
                my $rg = ref $data->{'release-group'} eq 'HASH'
                       ? lc($data->{'release-group'}{id} // '') : '';
                eval { $cache->set(_rel2rgKey($m), $rg, REL2RG_TTL); 1 }
                    or $log->warn("local-release cache set failed: $@");
                _setRelType($m, $rg ? $data->{'release-group'} : undef);
                _dbg("local-release: $m -> " . ($rg || 'no group'));
                $done->();
            },
            sub {
                my $err = shift->error // 'HTTP error';
                # A 404 means the mbid is not a valid release (often a GROUP id);
                # cache '' so we don't keep retrying — _mbidMatch matches a group
                # id directly anyway. Other errors cache nothing (retry later).
                if ($err =~ /\b404\b/) {
                    eval { $cache->set(_rel2rgKey($m), '', REL2RG_TTL); 1 };
                    _setRelType($m, undef);
                    _dbg("local-release: $m -> 404 (not a release mbid; cached empty)");
                }
                else {
                    _dbg("local-release: lookup failed for $m: $err (not cached)");
                }
                $done->();
            },
            timeout => 15);
    };

    $search->($search);   # the batches first; it hands over to $next when done
}

# ---------------------------------------------------------------------------
# Band membership — "show my band's albums under me".
#
# The library can't tell a band album from a write-only cover credit: a member
# is often tagged only as COMPOSER on their own band's record (Marc Almond is
# COMPOSER-only on Soft Cell's "Non-Stop Erotic Cabaret"), identical to Dylan
# writing one track on a covers comp. MusicBrainz DOES know, via the artist's
# "member of band" relationships. One cached call per artist yields the bands,
# which the page lists as "Also a member of" links (Browse::_bandLinkRow): browse
# the band itself for its albums, which are not folded into the member's page
# (Simon's call, 2026-07-11).
# ---------------------------------------------------------------------------

use constant BANDS_TTL => 14 * 86400;

# v2: the SAME fetch now also stores MB's canonical name. warmBandMembers
# early-returns on a cached band list, so a v1 entry would keep the name from
# EVER being fetched and the canonical-name retry would silently never fire --
# the exact "mechanism correct but unreachable" trap 0.44.20 hit with aliases.
sub _bandsKey { 'dsc:bands:v2:' . $_[0] }

# Cache-only, sync: arrayref of { mbid, name } bands the artist is a member of,
# or undef until warmed. Empty arrayref = warmed, no bands.
sub peekBands {
    my ($class, $artistMbid) = @_;
    return $cache->get(_bandsKey($artistMbid));
}

# COLLABORATIONS (Simon, 2026-09-19). The SAME artist-rels response carries
# MusicBrainz "collaboration" links — Holly Golightly -> "Holly Golightly and The
# Brokeoffs", where she is recorded as a collaborator, not a band member. Most
# such links are charity supergroups (Band Aid 21 collaborators, USA for Africa
# 37, "1,000 UK Artists" 722); measured over 1,100 library artists, the TARGET's
# collaborator count separates them cleanly: real duos and side projects have
# 1-5, charity ensembles start at 10. So a link is kept when its target has
# 1..COLLAB_MAX_MEMBERS collaborators and at least one release group. Each
# candidate costs ONE artist lookup, which carries both (stage 1; _vetCollabs).
use constant COLLAB_MAX_MEMBERS => 5;
use constant COLLAB_CHECK_MAX   => 8;    # candidates vetted per artist, at most

sub _collabsKey { 'dsc:collabs:v1:' . $_[0] }
# The unvetted candidates the band lookup found, kept so the vetting needs no
# second artist-rels request (see warmCollaborations).
sub _collabCandKey { 'dsc:collabcand:v1:' . $_[0] }

# Cache-only, sync: arrayref of { mbid, name } kept collaborations, or undef
# until warmed. Empty arrayref = warmed, none.
sub peekCollabs {
    my ($class, $artistMbid) = @_;
    return $cache->get(_collabsKey($artistMbid));
}

# Vet collaboration candidates serially (MB etiquette gap; 0 on a mirror).
# $done->(\@kept, $ok): $ok is false when any lookup failed, and the caller
# then caches nothing, so a blip cannot hide a real collaboration for 14 days.
sub _vetCollabs {
    my ($class, $cands, $done) = @_;
    my (@kept, $ok);
    $ok = 1;
    my $i = 0;
    # PACING IS NOT THIS SUB'S JOB ANY MORE (0.51.17). Every request here used
    # to be spaced by a timer of its own, which was right in intent and wrong
    # twice over: the gap came from `mbGap`, which reads the CONFIGURED base, so
    # a mirror install paced nothing even on a public retry; and the deadline
    # was built from core time(), which truncates. _netGet paces on the URL, so
    # a mirror still waits for nothing and a public request always waits.
    my $get = sub {
        my ($url, $onData) = @_;
        _netGet($url,
            sub {
                my $d = eval { from_json(shift->content) };
                return $onData->(($@ || ref $d ne 'HASH') ? undef : $d);
            },
            sub { $onData->(undef) },
            timeout => 12);
    };
    # ONE REQUEST PER CANDIDATE (stage 1, 2026-09-29; docs/mb-efficiency-and-
    # community-api-analysis.md A7 #3). The target's relations AND its release
    # groups come from one lookup, `?inc=artist-rels+release-groups`, where a
    # candidate that passed the size test used to pay a second request,
    # `release-group?artist=<id>&limit=1`, for the count. MEASURED on the public
    # API against those two calls: Fripp & Eno (2 collaborators, 11 groups),
    # Harmonia 76 (2, 2), N.M.L. NO MORE LANDMINE (22, 1) and the Shostakovich
    # Trio (0, 0) — identical relations, and the listed groups equal the count.
    # The list stops at 25 (Sonic Boom: 25 of 29) and includes groups where the
    # act is only the SECOND credit (15 of Sonic Boom's 18), as the count does,
    # so "has at least one release group" reads the same.
    #
    # MB always sends the list, empty for an act with none (the Trio: `[]`), so a
    # reply WITHOUT it is malformed and counts as a failed lookup — never as
    # "no release groups", which would drop a real collaboration for 14 days.
    #
    # The release-group COUNT cache (dsc:rgcount) is no longer written here: a
    # list that stops at 25 is not a count, and that key keeps its exact meaning
    # for every reader. Nor is it read here any more: the one lookup answers.
    my $next = sub {
        my ($self) = @_;
        my $c = $cands->[$i++];
        return $done->(\@kept, $ok) unless $c && $ok;
        my $step = sub { $self->($self) };
        $get->(_mbBase() . 'artist/' . $c->{mbid} . '?inc=artist-rels+release-groups&fmt=json', sub {
            my $d = shift;
            unless ($d && ref $d->{'release-groups'} eq 'ARRAY') { $ok = 0; return $step->() }
            my %who;
            for my $rel (@{ ref $d->{relations} eq 'ARRAY' ? $d->{relations} : [] }) {
                next unless ($rel->{type} // '') eq 'collaboration'
                         && ($rel->{direction} // '') eq 'backward';
                my $id = lc($rel->{artist}{id} // '') or next;
                $who{$id} = 1;
            }
            my $n = scalar keys %who;
            push @kept, $c if $n >= 1 && $n <= COLLAB_MAX_MEMBERS
                           && @{ $d->{'release-groups'} };
            $step->();
        });
    };
    $next->($next);
    return;
}

my %collabsInFlight;

# Vet the candidates the band lookup stored, and cache the survivors. Called at
# the END of the MB chain (after the bootleg pass), so it can never delay a
# render: the Collaborations section is cache-only at render time and appears on
# the next entry, the same second-load contract as the bands themselves.
# $cb fires exactly once. Nothing is cached when a lookup failed, so a blip is
# retried rather than pinned for 14 days.
sub warmCollaborations {
    my ($class, $artistMbid, $cb) = @_;
    $cb ||= sub {};
    return $cb->() unless $artistMbid;
    return $cb->() if defined $cache->get(_collabsKey($artistMbid));
    return $cb->() if $collabsInFlight{$artistMbid};

    my $cands = $cache->get(_collabCandKey($artistMbid));
    # No candidate list yet: the band lookup has not run (or failed), and it is
    # what produces one. Nothing to do here.
    return $cb->() unless ref $cands eq 'ARRAY';
    unless (@$cands) {
        eval { $cache->set(_collabsKey($artistMbid), [], BANDS_TTL); 1 };
        return $cb->();
    }

    $collabsInFlight{$artistMbid} = 1;
    $class->_vetCollabs($cands, sub {
        my ($kept, $ok) = @_;
        if ($ok) {
            eval { $cache->set(_collabsKey($artistMbid), $kept, BANDS_TTL); 1 }
                or $log->warn("collaborations cache set failed: $@");
        }
        _dbg("collaborations: $artistMbid -> " . scalar(@$kept) . ' of '
             . scalar(@$cands) . ' kept' . ($ok ? '' : ' (lookup failed - not cached)')
             . (@$kept ? ': ' . join(', ', map { $_->{name} } @$kept) : ''));
        delete $collabsInFlight{$artistMbid};
        $cb->();
    });
    return;
}

# ---------------------------------------------------------------------------
# ONE READ OF THE ARTIST RESOURCE (stage 1 of the MusicBrainz efficiency plan,
# docs/mb-efficiency-and-community-api-analysis.md A7 #1; 2026-09-29).
#
# warmArtistAliases asked for `artist/<mbid>?inc=aliases` and warmBandMembers
# for `artist/<mbid>?inc=artist-rels` — the same resource, twice. MEASURED on
# the public API (Radiohead): `?inc=aliases+artist-rels` returns exactly the
# alias list of the first and exactly the relations of the second, for 974
# bytes more than the relations call alone (19,956 B vs 18,982 B). So both now
# read it through this sub, which fills every cache the response can: the alias
# list, MB's canonical name, the band list and the collaboration candidates.
# Whichever caller comes first pays the one request; the other finds its cache
# warm, or joins the request in flight.
#
# The saving on the artist page: an AMBIGUOUS name fetched its aliases for the
# streaming warm AND its band members for "Also a member of" — two requests,
# now one. Every other artist pays the one request it always paid, and gets its
# aliases with it.
#
# AND THE SPINE, for an artist with fewer than 25 groups (stage 2, 2026-09-29;
# docs/mb-efficiency-and-community-api-analysis.md A11). `+release-groups` adds
# the artist's release groups WITH their aliases, at most 25 and with no count.
# MEASURED on the public API, library artists under 25 groups: the same groups,
# titles, types, dates and aliases as the release-group browse (10 of 10), and
# the same order once sorted by group id (9 of 9); the lookup itself orders by
# type then date, a one-page browse by group id, and the list's date sort keeps
# the input order for equal dates, so the sort is not cosmetic. Such a list is
# cached as the spine, exactly as the browse would have cached it, so the page
# (getReleaseGroups with read => 1) sends no browse. A list of 25 may be cut
# short and is ignored: the browse runs. The extra bytes: Radiohead 19,956 ->
# 29,704, Bonny Light Horseman 2,028 -> 4,473.
#
# A CALLER THAT ARRIVES MID-FLIGHT WAITS (getArtistCandidates' pattern, 0.47.4).
# The old warmBandMembers answered it at once with nothing cached, which was
# harmless while the band lookup was its own only caller. Now the streaming
# warm's alias fetch can be the request in flight when the serial MB chain
# reaches the band lookup, and answering early would push the bands off the
# first render. The wait is one request, bounded by its timeout and the queue's
# watchdog.
#
# $cb->($r): $r = { aliases, bands, cands } (arrayrefs, each cached as it
# always was), plus rgs (the spine, cached) when the reply listed fewer than 25
# groups, when a readable response arrived; undef otherwise, and then
# NOTHING is cached, so the next visit asks again. (The alias fetch used to
# cache an EMPTY list for ALIAS_TTL on an unreadable reply, while the band
# lookup cached nothing. One request gets one rule, and it is the one that
# cannot pin a blip for a month.)
#
# The in-flight key is the mbid exactly as passed, because the band keys are
# built from it as passed (every caller hands over a lowercased id).
# ---------------------------------------------------------------------------
my (%artistReadWaiting, %artistReadJob);

sub _readArtist {
    my ($mbid, $cb) = @_;
    # Each waiter keeps its own background flag; a page joining a background read
    # (the search's row check folding two results) moves it forward (see $NET_BG).
    if ($artistReadWaiting{$mbid}) {
        push @{ $artistReadWaiting{$mbid} }, [ $cb, $NET_BG ];
        _netPromote($artistReadJob{$mbid}) unless $NET_BG;
        return;
    }
    $artistReadWaiting{$mbid} = [ [ $cb, $NET_BG ] ];
    my $settle = sub {
        my ($r) = @_;
        # Released BEFORE the callbacks run (getArtistCandidates' reason): one
        # may ask again at once, and a marker still held would wedge the artist
        # with no request in flight to release it.
        my $queued = delete $artistReadWaiting{$mbid};
        delete $artistReadJob{$mbid};
        for my $w (@{ $queued || [] }) {
            local $NET_BG = $w->[1];
            $w->[0]->($r);
        }
    };

    my $job = _netGet(_mbBase() . "artist/$mbid?inc=aliases+artist-rels+release-groups&fmt=json",
        sub {
            my $d = eval { from_json(shift->content) };
            if ($@ || ref $d ne 'HASH') {
                _dbg("artist read: unparseable for $mbid (nothing cached - retry next visit)");
                return $settle->(undef);
            }

            # ALIASES: every spelling but the name itself, each once; and the
            # primary English one among them (peekArtistEnglishName).
            my (@names, %seenA, $en);
            for my $al (@{ ref $d->{aliases} eq 'ARRAY' ? $d->{aliases} : [] }) {
                next unless ref $al eq 'HASH';
                my $n = $al->{name};
                next unless defined $n && length $n;
                next if lc $n eq lc($d->{name} // '');   # the name itself
                push @names, $n unless $seenA{ lc $n }++;
                $en //= $n if ($al->{locale} // '') eq 'en' && $al->{primary};
            }
            _dbg("aliases $mbid: " . (@names ? join(', ', @names) : 'none')
                 . (defined $en ? " (English: $en)" : ''));
            eval { $cache->set(_aliasKey($mbid),
                               { names => \@names, (defined $en ? (en => $en) : ()) },
                               ALIAS_TTL); 1 };

            # MB'S CANONICAL NAME — see peekArtistName. Kept in memory TOO: this
            # is the value that was measured missing from the cache while the
            # alias list beside it survived, and every caller treats its absence
            # as "no canonical name exists". It is also the only free source of
            # the name for an artist resolved from the LIBRARY TAG, which never
            # runs an MB search.
            if (defined $d->{name} && length $d->{name}) {
                $mbNameMem{ lc $mbid } = $d->{name};
                _setMbName($mbid, $d->{name});
            }

            # BANDS: "member of band", forward = this artist is a member of the
            # target group (backward would be the group listing its members).
            my $rels = ref $d->{relations} eq 'ARRAY' ? $d->{relations} : [];
            my (%seenB, @bands);
            for my $rel (@$rels) {
                next unless ($rel->{type} // '') eq 'member of band';
                next unless ($rel->{direction} // '') eq 'forward';
                my $band = $rel->{artist} or next;
                my $id = lc($band->{id} // '') or next;
                next if $seenB{$id}++;
                push @bands, { mbid => $id, name => $band->{name} };
            }
            eval { $cache->set(_bandsKey($mbid), \@bands, BANDS_TTL); 1 }
                or $log->warn("band-members cache set failed: $@");
            _dbg("band-members: $mbid -> " . scalar(@bands) . ' band(s): '
                 . join(', ', map { $_->{name} } @bands));

            # COLLABORATIONS: forward links, never a target already listed as a
            # band, each once. STORED, NOT VETTED HERE: the band lookup sits in
            # the serial MB chain AHEAD of the bootleg pass, and the first render
            # waits on that pass under `official_wait` (15s), so vetting here
            # would push the page past its deadline with bootlegs unfiltered
            # (review 2026-09-19). warmCollaborations reads these back at the END
            # of the chain.
            my %isBand = map { $_->{mbid} => 1 } @bands;
            my (%seenC, @cands);
            for my $rel (@$rels) {
                next unless ($rel->{type} // '') eq 'collaboration'
                         && ($rel->{direction} // '') eq 'forward';
                my $t  = $rel->{artist} or next;
                my $id = lc($t->{id} // '') or next;
                next if $isBand{$id} || $seenC{$id}++;
                push @cands, { mbid => $id, name => $t->{name} };
            }
            splice(@cands, COLLAB_CHECK_MAX) if @cands > COLLAB_CHECK_MAX;
            eval { $cache->set(_collabCandKey($mbid), \@cands, BANDS_TTL); 1 }
                or $log->warn("collaboration candidates cache set failed: $@");
            _dbg("collaborations: $mbid -> " . scalar(@cands)
                 . ' candidate(s) to vet'
                 . (@cands ? ': ' . join(', ', map { $_->{name} } @cands) : ''));

            # THE SPINE, when the list is whole (see the header). Built and
            # pruned as the browse builds it, in the browse's order.
            my $spine;
            my $list = $d->{'release-groups'};
            if (ref $list eq 'ARRAY' && @$list < ARTIST_RG_LIST_MAX) {
                my @all = sort { $a->{mbid} cmp $b->{mbid} }
                          grep { $_ } map { _rgEntry($_) } @$list;
                _pruneAliases(\@all);
                eval { $cache->set(_rgKey($mbid), \@all, RG_TTL); 1 }
                    or $log->warn("release-group cache set failed: $@");
                $log->info("release groups for $mbid: " . scalar(@all)
                           . ' from the artist read (no browse needed)');
                $spine = \@all;
            }

            $settle->({ aliases => \@names, bands => \@bands, cands => \@cands,
                        ($spine ? (rgs => $spine) : ()) });
        },
        sub {
            _dbg("artist read: lookup failed for $mbid (aliases + band members): "
                 . (shift->error // 'HTTP error') . ' - not cached, retry next visit');
            $settle->(undef);
        },
        timeout => 15);
    # Kept only while the read is still waited on (a transport that answers at
    # once has already settled it).
    $artistReadJob{$mbid} = $job if $artistReadWaiting{$mbid};
    return;
}

# Resolve the artist's "member of band" relationships once and cache them, and
# (same response) note its collaboration candidates for warmCollaborations.
# $cb fires exactly once (cache hit / done / failure). The request itself is
# _readArtist's, shared with warmArtistAliases.
sub warmBandMembers {
    my ($class, $artistMbid, $cb) = @_;
    $cb ||= sub {};
    return $cb->() unless $artistMbid;
    # The band list alone is not enough: one written before collaborations
    # existed would keep the candidates from ever being noted. Either a vetted
    # list or a pending candidate list counts as "this artist has been read".
    return $cb->() if defined $cache->get(_bandsKey($artistMbid))
                   && (defined $cache->get(_collabsKey($artistMbid))
                       || defined $cache->get(_collabCandKey($artistMbid)));
    _readArtist($artistMbid, sub { $cb->() });
    return;
}

my %officialInFlight;

# The bootleg check for the groups on the page: $rgs is the spine the page
# renders. The release-group search is asked for them BY ID, RGID_BATCH_MAX to a
# request, and each hit lists the group's releases with their status and title.
# Builds the whole map, then caches it. Nothing is cached until every request
# has answered. Each group's verdict is whole in its own hit, so a part-built
# map would be right for the groups it holds; it is still never cached, because
# a cached map counts as done for OFFICIAL_TTL: the groups of the request that
# failed would go unchecked, and shown unfiltered, for 14 days. A failure caches
# nothing, so the next visit asks for every group again.
#
# Only the groups asked for are read from a reply. A group listed with no
# releases, or not returned at all (newer than the search index), stays out of
# the map, i.e. shown: the release browse this replaced never saw such a group
# either (The Beatles' "Last Night in Hamburg" is listed with none). A group
# whose own `count` says it has more releases than are listed gets a verdict
# only from an official one among them. Every list measured was whole, up to
# 151 releases.
#
# $cb (optional) fires exactly once: with no argument when the map is cached
# (a cache hit, or the check done); 'busy' when another visit's check for this
# artist is still running; 'failed' when a request failed or a reply could not
# be read, and then nothing is cached and the next visit asks again. The page
# AWAITS it before its first render, under a deadline, and uses the argument to
# decide which owned albums still need a lookup — see
# Browse::_discographyView.
sub warmOfficial {
    my ($class, $artistMbid, $rgs, $cb) = @_;
    $cb ||= sub {};

    return $cb->() unless $artistMbid;
    return $cb->() if defined $cache->get(_officialKey($artistMbid));

    # Every rebuild (drill, sort, back) re-enters here; one check per artist.
    # A caller arriving mid-check renders unfiltered rather than waiting on
    # someone else's — the map lands for the next render either way.
    return $cb->('busy') if $officialInFlight{$artistMbid};

    my (%want, @ids);
    for my $rg (@{ $rgs || [] }) {
        my $id = ref $rg eq 'HASH' ? lc($rg->{mbid} // '') : '';
        push @ids, $id if length $id && !$want{$id}++;
    }
    my $asked = scalar @ids;

    my $store = sub {
        my ($official, $rgOf, $editions, $how) = @_;
        eval { $cache->set(_officialKey($artistMbid),
                           { o => $official, r => $rgOf, t => $editions }, OFFICIAL_TTL); 1 }
            or $log->warn("official-status cache set failed: $@");

        my $boot = grep { !$official->{$_} } keys %$official;
        _dbg("official-status: $artistMbid -> " . scalar(keys %$official) . " of $asked"
             . " release-groups classified" . ($how ? " ($how)" : '') . ", $boot bootleg-only, "
             . scalar(keys %$rgOf) . " releases mapped to groups");

        delete $officialInFlight{$artistMbid};
        $cb->();
    };
    # No groups on the page: nothing to ask, and an empty map says so.
    return $store->({}, {}, {}) unless @ids;

    $officialInFlight{$artistMbid} = 1;

    # $cm: the community's verdicts and release map, or undef. The groups it
    # does not classify, or all of them, are asked BY ID; its own answers stand
    # beside MusicBrainz's. $mayWait (0.56.8): which of those may be checked
    # AFTER the page. At most PREDRAW_RGID_MAX of them are asked before the draw;
    # the rest show unchecked on this visit (the check's fail-open rule) and are
    # asked as background work, for the next one (_officialLater). Without it,
    # every group is asked before the draw, as before.
    my $check = sub {
        my ($cm, $mayWait) = @_;
        my @rest = $cm ? grep { !defined $cm->{o}{$_} } @ids : @ids;
        my @later;
        if ($mayWait) {
            my @may = grep { $mayWait->($_) } @rest;
            @rest  = ((grep { !$mayWait->($_) } @rest), splice(@may, 0, PREDRAW_RGID_MAX));
            @later = @may;
        }
        my $how = $cm ? 'the community API for ' . ($asked - @rest - @later) . ', MusicBrainz for '
                      . scalar(@rest) : '';
        $how .= ($how ? ', ' : '') . scalar(@later) . ' after the page' if @later;
        my $done = sub { $store->(@_); _officialLater($artistMbid, \@later) if @later };
        return $done->({ %{ $cm->{o} } }, { %{ $cm->{r} || {} } }, {}, $how) unless @rest;
        _officialById(\@rest, sub {
            my ($res, $why) = @_;
            unless ($res) {
                # Nothing cached: the view keeps showing everything and the
                # check is asked again on a later visit.
                _dbg("official-status: $why - nothing cached, retried next visit");
                delete $officialInFlight{$artistMbid};
                return $cb->('failed');
            }
            $done->({ %{ $cm ? $cm->{o} : {} },      %{ $res->{o} } },
                    { %{ $cm ? $cm->{r} || {} : {} }, %{ $res->{r} } },
                    $res->{t}, $how);
        });
    };

    # A FIRST LIST (0.56.7, _fastSpine) takes the community's verdicts, kept
    # with it: they agree with MusicBrainz's on 9,521 of 9,685 groups, and they
    # spare the page up to 6 requests before it is drawn. MusicBrainz's own
    # check follows after the page, with the edition titles (completeArtist).
    # Any of its groups may wait.
    my $all = sub { 1 };
    my $cm = $cache->get(_cmDiscoKey($artistMbid));
    $cm = undef unless ref $cm eq 'HASH' && ref $cm->{o} eq 'HASH';
    if ($cache->get(_rgFastKey($artistMbid))) {
        return $check->($cm, $all) if $cm;
        return _hostedDisco(lc $artistMbid, sub { $check->($_[0], $all) });
    }
    # A Refresh's list past MusicBrainz's cap (0.56.8, _pastCap) keeps the
    # community's verdicts for those groups only; MusicBrainz's own are asked
    # by id before the draw, as before, and only the kept ones may wait.
    return $check->($cm, ref $cm->{past} eq 'HASH' ? sub { $cm->{past}{ $_[0] } } : undef) if $cm;
    # A list longer than MusicBrainz's browse ever gives (a first list after
    # its completion, the community's verdicts gone with it) whose map has
    # expired: asked of the community again, as for a first list, rather than
    # by id in full (Bob Dylan: 12 requests before the draw).
    return _hostedDisco(lc $artistMbid, sub { $check->($_[0], $all) })
        if @ids > RG_MAX_PAGES * RG_PAGE_SIZE;
    $check->(undef);
}

# The rest of a bounded bootleg check (warmOfficial, 0.56.8), after the page,
# as background work: merged into the map for the NEXT visit (this one's
# visibility is frozen). It never creates a map: one gone meanwhile (a Refresh)
# would come back holding only these groups and stop the full check.
sub _officialLater {
    my ($mbid, $ids) = @_;
    _officialById($ids, sub {
        my ($res, $why) = @_;
        unless ($res) {
            _dbg("official-status after the page for $mbid: " . ($why // 'failed')
                 . ' - those groups stay unchecked until the map is rebuilt');
            return;
        }
        my $cur = $cache->get(_officialKey($mbid));
        unless (ref $cur eq 'HASH') {
            _dbg("official-status after the page for $mbid: the map is gone (a Refresh) - discarded");
            return;
        }
        eval {
            $cache->set(_officialKey($mbid), {
                o => { %{ $cur->{o} || {} }, %{ $res->{o} } },
                r => { %{ $cur->{r} || {} }, %{ $res->{r} } },
                t => { %{ $cur->{t} || {} }, %{ $res->{t} } },
            }, OFFICIAL_TTL());
            1;
        } or return $log->warn("official-status cache set failed: $@");
        _dbg("official-status after the page for $mbid: " . scalar(keys %{ $res->{o} })
             . ' more classified, for the next visit');
    }, background => 1);
    return;
}

# THE BY-ID CHECK (stage 2): the groups in $ids asked for by id, 100 to a
# request, each group's every release read for its status, its id and, when
# official, its title. $cb->({ o => {rg => 0|1}, r => {release => rg},
# t => {rg => [edition titles]} }) once all are in, or $cb->(undef, $why) at the
# first failure. `background => 1` sends every request as background work.
sub _officialById {
    my ($ids, $cb, %opt) = @_;
    my (%want, @ids);
    for my $i (@{ $ids || [] }) {
        my $id = lc($i // '');
        push @ids, $id if length $id && !$want{$id}++;
    }
    my (%official, %rgOf, %editions);
    my @batches;
    push @batches, [ splice(@ids, 0, RGID_BATCH_MAX) ] while @ids;
    _dbg("official-status warm: " . scalar(keys %want) . " release-group(s) by id, "
         . scalar(@batches) . ' request(s)' . ($opt{background} ? ' (background)' : ''));

    # Self-passing closure, not a captured lexical (the 0.30.1 leak fix): this
    # runs once per artist page whose official map is cold.
    my $fetch = sub {
        my ($self) = @_;
        my $batch = shift @batches or return $cb->({
            o => \%official, r => \%rgOf,
            t => { map { $_ => [ sort keys %{ $editions{$_} } ] } keys %editions },
        });

        # Everything but letters, digits and '-' is percent-encoded. The ids
        # come from MusicBrainz, so this is Lucene's own syntax; leaving '-'
        # raw keeps 100 ids at 5,160 characters (5,960 encoded, also accepted).
        my $q = join ' OR ', map { "rgid:$_" } @$batch;
        (my $safe = $q) =~ s/([^A-Za-z0-9-])/sprintf('%%%02X', ord($1))/ge;
        # `limit` is required: the search answers 25 by default.
        my $url = _mbBase() . 'release-group?query=' . $safe
                . '&limit=' . scalar(@$batch) . '&fmt=json';

        _netGet($url,
            sub {
                my $data = eval { from_json(shift->content) };
                return $cb->(undef, 'unreadable reply')
                    unless !$@ && ref $data eq 'HASH' && ref $data->{'release-groups'} eq 'ARRAY';

                for my $g (@{ $data->{'release-groups'} }) {
                    next unless ref $g eq 'HASH';
                    my $id = lc($g->{id} // '');
                    next unless $want{$id};
                    my $rels = ref $g->{releases} eq 'ARRAY' ? $g->{releases} : [];
                    next unless @$rels;
                    my $any = 0;
                    for my $rel (@$rels) {
                        next unless ref $rel eq 'HASH';
                        # A release-group is official if ANY of its releases is.
                        my $off = _isOfficial($rel->{status});
                        $any ||= $off;
                        # ... and every release points back at its group, which
                        # is how a library album's MUSICBRAINZ_ALBUMID finds its
                        # tile.
                        $rgOf{ lc $rel->{id} } = $id if $rel->{id};
                        # ... and each OFFICIAL edition's own title. MusicBrainz
                        # names a group after its first edition, so later
                        # editions sold under another name ("Tour de France",
                        # 2009, inside the 2003 "Tour de France Soundtracks")
                        # are only findable here. A bootleg's title never
                        # becomes a way in.
                        $editions{$id}{ $rel->{title} } = 1
                            if $off && defined $rel->{title} && length $rel->{title};
                    }
                    if ($any) {
                        $official{$id} = 1;
                    }
                    elsif (!defined $g->{count} || $g->{count} <= @$rels) {
                        $official{$id} //= 0;
                    }
                }
                $self->($self);
            },
            sub { $cb->(undef, 'request failed (' . (shift->error // 'HTTP error') . ')') },
            timeout => 20, ($opt{background} ? (background => 1) : ()));
    };

    $fetch->($fetch);
    return;
}

# CAA cover by release-group MBID — a plain URL; CAA redirects to the front
# image of the group's representative release. A CAA miss 404s and the UI shows
# its default art, which is the honest state.
#
# THE `.jpg` IS FOR THE IMAGE PROXY, NOT THE ARCHIVE (0.56.27, LBF's
# API::coverArtUrl). The archive answers `/front-250` and `/front-250.jpg` alike
# (probed 2026-10-02 on a release group: same 17,439 bytes, image/jpeg). LMS
# names the proxied path after the url's extension and defaults to `.png`
# (proxiedImage), and the proxy then stores every rendition as PNG: LBF measured
# a 600 px cover at 648,081 B as PNG against 101,100 B as JPEG. The size is
# rewritten to 1200 by the proxy handler (Covers::proxyHandler) either way.
sub caaImage {
    my ($class, $rgMbid, $size) = @_;
    return CAA_RG_BASE_URL . $rgMbid . '/front-' . ($size || 250) . '.jpg';
}

# ---------------------------------------------------------------------------
# Release-group external links (AllMusic, Discogs, Wikipedia, reviews, ...)
# via MB url-relationships. One extra MB call per detail open, heavily cached.
# ---------------------------------------------------------------------------

use constant URLS_FOUND_TTL => 30 * 86400;
use constant URLS_EMPTY_TTL =>  7 * 86400;

# Relation types worth a row, in display order. MB types not listed (streaming,
# purchase, lyrics, wikidata, ...) are skipped — link rows should be curated,
# not a dump.
my @URL_REL_TYPES = (
    [ 'allmusic'          => 'AllMusic'      ],
    [ 'discogs'           => 'Discogs'       ],
    [ 'wikipedia'         => 'Wikipedia'     ],
    [ 'review'            => 'Review'        ],
    [ 'official homepage' => 'Official site' ],
);

# getReleaseGroupUrls(mbid => $m, onDone => sub(\@links)) — each link is
# { label => 'AllMusic', url => 'https://...' }. Errors resolve to [] (the
# detail page must never stall on link decoration).
sub getReleaseGroupUrls {
    my ($class, %a) = @_;
    my $mbid   = $a{mbid} or do { ($a{onDone} || sub {})->([]); return };
    my $onDone = $a{onDone} || sub {};

    my $key = 'dsc:urls:1:' . $mbid;
    if (my $c = $cache->get($key)) {
        $onDone->($c);
        return;
    }

    my $url = _mbBase() . 'release-group/' . $mbid . '?inc=url-rels&fmt=json';
    _netGet($url,
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            my @links;
            if (!$@ && ref $data eq 'HASH' && ref $data->{relations} eq 'ARRAY') {
                for my $want (@URL_REL_TYPES) {
                    my ($type, $label) = @$want;
                    for my $rel (@{ $data->{relations} }) {
                        next unless ($rel->{type} // '') eq $type
                                 && ref $rel->{url} eq 'HASH'
                                 && $rel->{url}{resource};
                        push @links, { label => $label, url => $rel->{url}{resource} };
                        last;   # one row per type
                    }
                }
            }
            eval { $cache->set($key, \@links, @links ? URLS_FOUND_TTL : URLS_EMPTY_TTL); 1 }
                or $log->warn("url-rels cache set failed: $@");
            $log->info("url-rels for $mbid: " . scalar(@links));
            $onDone->(\@links);
        },
        sub {
            $log->warn("MB url-rels fetch failed: " . (shift->error // '?'));
            $onDone->([]);
        },
        timeout => 15);
}

1;
