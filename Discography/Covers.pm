package Plugins::Discography::Covers;

# THE ARCHIVE COVERS A PAGE SHOWED AN ICON FOR, FETCHED AT 05:00 (0.56.30).
# 0.56.27 fetched them right after the visit (Simon: "follow the same resizing
# we do in LBF as it works well", then "After the visit"); 0.56.30 keeps LBF's
# resizing and moves every fetch to the night.
#
# WHY ONLY AT NIGHT (measured on the rig, 2026-10-02). A first visit to Ocean
# Colour Scene (12 icon tiles) drew its thumbnails in 2.3 s, then the server
# FROZE 11.4, 4.4, 12.8 and 4.4 s in the next minute; Paul Weller's 32 s of
# freezes in 45 s started while its own thumbnails were loading (Qobuz covers
# 1.4 s each, 0.3-0.6 s with the server free) and held whatever page came
# next. An archive fetch holds LMS's one event loop until archive.org answers:
# up to ~4 s for a cover it has, 11-13 s for one it fails. Fetching two at a
# time "while browsing" does not help, as the loop stops whatever is in
# flight. So a page only records what it wants (want), and the fetching waits
# for 05:00 (Simon: "okay do it"). A helper process downloading outside LMS
# was offered and DECLINED (Simon: "ignore the helper").
#
# NEVER FOR A COVER THAT DOES NOT EXIST: Browse wants no group ListenBrainz
# marks as having none (API::peekCoverFlags; its `caa_id` agreed with the
# archive on 24 of 24 groups sampled, 2026-10-02). Those were the 11-13 s
# freezes.
#
# WHY NOT ON SCREEN (0.56.26, Browse::_caaHeld). A Cover Art Archive cover the
# image proxy fetches stalls the whole server about 0.65 s (an LMS core HTTPS
# read blocks the event loop; LBF CLAUDE.md "Slow artwork / server freezes"),
# and Sam Smith's page, drawn with every unmatched tile pointing at the
# archive, drew its covers slowly and held a second device's page. So a tile
# shows the archive cover only once the proxy holds it, and this module is
# what makes it hold it.
#
# LBF'S RESIZING, ALL THREE PARTS (its Plugin.pm handler, API::coverArtUrl and
# Browse::_warmCovers):
#   1. THE URL ENDS `.jpg` (API::caaImage), so the proxied path, and every
#      rendition cached under it, is JPEG. Extensionless, proxiedImage named it
#      `.png` and the proxy stored PNG: LBF measured one 600 px cover at
#      648,081 B as PNG against 101,100 B as JPEG.
#   2. EVERY SIZE IS CUT FROM ONE 1200 PX DOWNLOAD (proxyHandler). The proxy
#      queues by the REWRITTEN source url and resizes every waiting request
#      from one download, so the sizes requested together share it.
#   3. THE SIZES GO OUT TOGETHER, in one turn (_launch), or the first can land
#      before the others arrive and each pays its own download.
#
# AND ONE PART LBF DOES NOT NEED: the UNSIZED request. Material 6.4.10 asks an
# `icon` row's image with no size (Browse::_caaHeld), which is what a tile is,
# so that is the entry a tile actually reads today. It is the 1200 px original,
# stored as fetched (ImageProxy::_resizeFromFile's "original size requested"
# branch), and costs nothing extra: same source url, same download.
#
# NOTHING HERE RUNS DURING THE DAY. Browse records urls while it builds a page
# (want), kept in one kv row so a restart keeps them. At 05:00 the night run
# queues the most recently wanted first, at most NIGHT_MAX, and the pump runs
# them: eight releases at a time, two if someone is browsing at that hour, and
# none while a page has a request out (API::_netFgBusy) or within DRAW_GRACE
# of a Discography request.

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use POSIX ();
use Time::HiRes ();

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

my $log = logger('plugin.discography');

# '' is the unsized request (see above); the rest are what Material asks once
# its `icon` sizing is fixed, and what the Default skin asks today:
# LMS_LIST_IMAGE_SZ 150/300 and LMS_IMAGE_SZ 300/600 (LBF COVER_SPECS).
use constant SPECS => ('', '_150x150_f', '_300x300_f', '_600x600_f');

# LBF's numbers, in RELEASES in flight (each is up to four local requests
# sharing one archive download). LBF measured cold covers through the proxy at
# 0.40/s one at a time and 1.62/s eight at a time: the cost is archive.org's
# latency, and waiting parallelises. Two while somebody is looking, because
# every request holds one of the server's HTTP handler slots a page wants.
use constant CONCURRENCY_IDLE     => 8;
use constant CONCURRENCY_BROWSING => 2;
use constant BROWSE_QUIET         => 20;   # seconds without a request before "idle"

# Seconds after the last Discography request before the first launch, so the
# page that queued the work and its own covers are served first.
use constant DRAW_GRACE => 3;
# How soon to look again while a page has a request out.
use constant FG_WAIT    => 1;

# A cover that fails stays wanted and is asked again the next night. After
# RETRY_MAX failures in a row it is given up for GIVEUP_TTL: not asked at
# night and not recorded by a visit, so a group the archive has no cover for
# (one ListenBrainz did not flag) is not asked about every night for ever. A
# failure is never cached by the proxy (_artworkError sends no-cache). The
# counts live in ONE kv row, { url => [last failure at, failures in a row] }.
use constant RETRY_MAX  => 3;
use constant GIVEUP_TTL => 30 * 86400;
use constant MISS_KEY   => 'dsc:cvmiss:v1';

# The wanted covers: ONE kv row, { url => last wanted at }. Written SAVE_DELAY
# after the first change, so a page's thirty wants are one write. A url not
# wanted again for WANT_TTL is dropped, and past WANT_MAX the oldest go.
# Both rows are emptied with every kv row when CACHE_VERSION changes (DB.pm).
use constant WANT_KEY   => 'dsc:cvwant:v1';
use constant WANT_TTL   => 30 * 86400;
use constant WANT_MAX   => 5000;
use constant SAVE_DELAY => 10;
# At most this many covers a night, the most recently wanted first: each can
# freeze the server for seconds, so a day of heavy browsing is spread over
# several nights rather than freezing it for hours. The rest wait.
use constant NIGHT_MAX  => 300;

# LBF's overnight clock: 05:00 local plus a fixed per-install offset, so every
# install in a timezone does not reach the archive in the same second.
use constant NIGHT_HOUR       => 5;
use constant NIGHT_JITTER_MAX => 1800;

my @queue;            # [ { url => $caa } ], page order
my %queued;           # url => 1 while queued or in flight
my $running      = 0; # releases in flight
my $pumping      = 0; # re-entrancy guard on _tick's launch loop
my $armed        = 0; # one wake-up timer at a time
my $lastBrowseAt = 0; # Time::HiRes, the last Discography request (noteBrowse)
my $miss;             # the failure row, loaded on first use (_misses)
my $wants;            # the wanted row, loaded on first use (_wants)
my $saveArmed    = 0; # one pending write of the wanted row
my $proxyCache;
my $store;
# Per drain, for the debug line.
my %pass = (fetched => 0, skipped => 0, failed => 0);

sub _dbg { Plugins::Discography::Plugin::dbg(@_) if Plugins::Discography::Plugin->can('dbg') }

# For the suite: forget everything (DB.pm's _reset).
sub _reset {
    @queue = (); %queued = ();
    $running = $pumping = $armed = $lastBrowseAt = $saveArmed = 0;
    undef $miss; undef $wants; undef $proxyCache; undef $store; undef $Plugins::Discography::Covers::jitter;
    %pass = (fetched => 0, skipped => 0, failed => 0);
    return;
}

# ---------------------------------------------------------------------------
# The image proxy handler, LBF's to the character (its Plugin.pm, where the
# reasoning is): every `front-<n>` becomes `front-1200`, the only archive size
# that never upscales for Material's 600 px tile, and ONE source url for every
# spec so the specs of a cover share a download. The extension is captured and
# put back. Registered under the SAME pattern as LBF's (Plugin.pm), and LMS
# keeps one handler per pattern (Tie::RegexpHash::add replaces an equal key),
# so with both plugins installed whichever loads last serves both, identically.
sub proxyHandler {
    my ($url, $spec) = @_;
    $url =~ s{/front-\d+(\.\w+)?$}{'/front-1200' . ($1 // '')}e;
    return $url;
}

# Somebody is looking: every Discography request (Browse::topLevel).
sub noteBrowse { $lastBrowseAt = Time::HiRes::time(); return }

# Record a cover a page showed an icon for, for the night. Called while the
# page is built, so it only records: nothing is fetched and no pump is armed,
# only the row's delayed write. The two rows are read once per process.
sub want {
    my ($url) = @_;
    return unless defined $url && length $url;
    return if _givenUp($url);
    _wants()->{$url} = time();
    _armSave();
    return;
}

# 05:00: fetch what the pages wanted.
sub init {
    _armNight();
    return;
}

# ---------------------------------------------------------------------------
# The pump.

sub _limit {
    return CONCURRENCY_BROWSING
        if $lastBrowseAt && Time::HiRes::time() - $lastBrowseAt < BROWSE_QUIET;
    return CONCURRENCY_IDLE;
}

# Seconds before anything may launch: the page's own grace, then any page
# request still out. 0 = now.
sub _waitFor {
    my $now = Time::HiRes::time();
    my $graceEnd = $lastBrowseAt + DRAW_GRACE;
    return $graceEnd - $now if $graceEnd > $now;
    my $fg = Plugins::Discography::API->can('_netFgBusy');
    return FG_WAIT if $fg && eval { $fg->() };
    return 0;
}

# ONE wake-up at a time: every landing re-enters _tick, so an unguarded arm
# would schedule one timer per request.
sub _arm {
    my ($in) = @_;
    return if $armed;
    $armed = 1;
    eval {
        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + ($in > 0 ? $in : 0), sub {
            $armed = 0;
            _tick();
        });
        1;
    } or $armed = 0;
    return;
}

# Keep up to _limit() releases in flight. Re-entrancy guarded, as LBF's is: a
# release with nothing left to fetch completes inline, and without the guard a
# run of those would recurse one frame per queued release.
sub _tick {
    return if $pumping;
    if (@queue) {
        my $wait = _waitFor();
        if ($wait > 0) { _arm($wait); return }

        $pumping = 1;
        my $limit = _limit();
        _launch(shift @queue) while $running < $limit && @queue;
        $pumping = 0;

        # Stopped with work left at the browsing width: nothing in flight is
        # sure to land before the quiet window ends, so wake then to widen. At
        # the idle width the landings are the wake-up.
        _arm($lastBrowseAt + BROWSE_QUIET - Time::HiRes::time())
            if @queue && $limit < CONCURRENCY_IDLE;
    }
    _drained();
    return;
}

sub _drained {
    return if @queue || $running;
    return unless $pass{fetched} || $pass{skipped} || $pass{failed};
    _dbg("covers: $pass{fetched} fetched, $pass{failed} failed, $pass{skipped} already held");
    %pass = (fetched => 0, skipped => 0, failed => 0);
    return;
}

# Every request path for one cover, and the key the proxy caches it under.
# proxiedImage builds the path exactly as XMLBrowser does for the tile; the key
# is that path with the slash stripped and URL-DECODED, as Slim::Web::HTTP
# hands it to getImage (pinned live by LBF 1.0.17; Browse::_caaHeld reads it).
#
# THE UNSIZED REQUEST ONLY WHEN A HANDLER CLAIMS THE URL. Without one,
# ImageProxy::getImage answers an unsized https request with a 301 to the
# source, our own request would follow it, and the server would download the
# cover itself and cache nothing.
sub _paths {
    my ($url) = @_;
    my $base = eval { require Slim::Web::ImageProxy; Slim::Web::ImageProxy::proxiedImage($url) };
    return unless $base && $base =~ m{^/imageproxy/};
    my $handled = eval { Slim::Web::ImageProxy->getHandlerFor($url) } ? 1 : 0;
    my @out;
    for my $spec (SPECS) {
        next if $spec eq '' && !$handled;
        (my $path = $base) =~ s/(\.\w+)$/$spec$1/ or next;
        (my $key = $path) =~ s{^/}{};
        push @out, [ $path, _unescape($key) ];
    }
    return @out;
}

sub _unescape {
    my ($s) = @_;
    my $u = eval { require Slim::Utils::Misc; Slim::Utils::Misc::unescape($s) };
    return defined $u ? $u : $s;
}

# 1 the proxy holds this key, 0 it does not, undef it could not be asked (LBF's
# three answers: a cache that cannot be read must not be recorded as a miss).
sub _proxyHas {
    my ($key) = @_;
    $proxyCache ||= eval { require Slim::Web::ImageProxy; Slim::Web::ImageProxy::Cache->new() }
        or return undef;
    my $hit = eval { $proxyCache->get($key) };
    return undef if $@;
    return $hit ? 1 : 0;
}

# Launch ONE cover: every path it still lacks, in a single synchronous turn
# (LBF's _coverLaunch, where the reason is spelt out).
sub _launch {
    my ($job) = @_;
    my $url = $job->{url};
    $running++;

    my @paths = _paths($url);
    my @todo  = grep { !_proxyHas($_->[1]) } @paths;
    unless (@todo) {
        # Nothing to ask: held already (counted), or no proxy to ask through.
        if (@paths) { $pass{skipped}++; _missClear($url); _wantDone($url) }
        delete $queued{$url};
        $running--;
        _tick();
        return;
    }

    my $outstanding = scalar @todo;
    my ($ourFault, $refused, $ended) = (0, 0, 0);
    my $done = sub {
        return if $ended || --$outstanding > 0;
        $ended = 1;
        if ($refused) {
            _dropAll("the server refused a local request; covers not fetched");
        }
        else {
            my @held = map { _proxyHas($_->[1]) } @paths;
            if (grep { $_ } @held) {
                $pass{fetched}++;
                _missClear($url);
                _wantDone($url);
            }
            elsif ($ourFault || grep { !defined } @held) {
                # Our server went away, or its cache could not be read: says
                # nothing about the cover, so it is not held (LBF 1.0.24).
                $pass{failed}++;
            }
            else {
                $pass{failed}++;
                _missNote($url);
            }
        }
        delete $queued{$url};
        $running--;
        _tick();
    };

    my $port = eval { preferences('server')->get('httpport') } || 9000;
    for my $ent (@todo) {
        my $fired = 0;
        my $once = sub { $done->() unless $fired++ };
        my $ok = eval {
            require Slim::Networking::SimpleAsyncHTTP;
            Slim::Networking::SimpleAsyncHTTP->new(
                # AN ANSWER IS NOT A COVER: the proxy answers a failed fetch
                # 200 with its placeholder, so $done asks the proxy's cache.
                sub { $once->() },
                sub {
                    my (undef, $error) = @_;
                    my $err = $error // '';
                    # A server behind HTTP auth refuses its own requests; stop
                    # rather than log it once per cover.
                    if ($err =~ /\b40[13]\b/) { $refused = 1 }
                    # A refused or reset local connection is our server going
                    # away (a restart, the nightly backup), not the cover. A
                    # TIMEOUT is still a miss: an archive hang can expire our
                    # loopback request too (LBF mutant `timeout-no-miss`).
                    elsif ($err =~ /refused|reset by peer|connect(?:ion)? (?:failed|closed)|broken pipe|not connected|no route|unreachable/i) {
                        $ourFault = 1;
                    }
                    $once->();
                },
                { timeout => 30 },
            )->get("http://127.0.0.1:$port$ent->[0]");
            1;
        };
        unless ($ok) { $ourFault = 1; $once->() }
    }
    return;
}

sub _dropAll {
    my ($why) = @_;
    $log->info("dsc: $why");
    delete $queued{ $_->{url} } for @queue;
    @queue = ();
    return;
}

# ---------------------------------------------------------------------------
# The two rows.

# Reached at call time (Browse loads DB), so this module loads on its own.
sub _store { $store ||= eval { Plugins::Discography::DB->store() } }

sub _misses {
    return $miss if $miss;
    my $v = eval { _store()->get(MISS_KEY) };
    $miss = ref $v eq 'HASH' ? $v : {};
    return $miss;
}

sub _missSave {
    my $m = _misses();
    my $now = time();
    for my $u (keys %$m) {
        my $e = $m->{$u};
        delete $m->{$u} unless ref $e eq 'ARRAY' && $now - ($e->[0] || 0) < GIVEUP_TTL;
    }
    eval { _store()->set(MISS_KEY, $m, 0); 1 };
    return;
}

sub _givenUp {
    my ($url) = @_;
    my $e = _misses()->{$url};
    return 0 unless ref $e eq 'ARRAY' && ($e->[1] || 0) >= RETRY_MAX;
    return time() - ($e->[0] || 0) < GIVEUP_TTL ? 1 : 0;
}

sub _missNote {
    my ($url) = @_;
    my $m = _misses();
    my $fails = ref $m->{$url} eq 'ARRAY' ? ($m->{$url}[1] || 0) : 0;
    $m->{$url} = [ time(), $fails + 1 ];
    _missSave();
    return;
}

sub _missClear {
    my ($url) = @_;
    my $m = _misses();
    return unless exists $m->{$url};
    delete $m->{$url};
    _missSave();
    return;
}

sub _wants {
    return $wants if $wants;
    my $v = eval { _store()->get(WANT_KEY) };
    $wants = ref $v eq 'HASH' ? $v : {};
    return $wants;
}

sub _wantDone {
    my ($url) = @_;
    my $w = _wants();
    return unless exists $w->{$url};
    delete $w->{$url};
    _armSave();
    return;
}

# One write per SAVE_DELAY, however many wants came in. Written at once when
# no timer can be armed.
sub _armSave {
    return if $saveArmed;
    $saveArmed = 1;
    eval {
        Slim::Utils::Timers::setTimer(undef, time() + SAVE_DELAY, sub { $saveArmed = 0; _wantSave() });
        1;
    } or do { $saveArmed = 0; _wantSave() };
    return;
}

sub _wantSave {
    my $w = _wants();
    my $now = time();
    for my $u (keys %$w) {
        delete $w->{$u} unless ($w->{$u} || 0) > $now - WANT_TTL;
    }
    if (keys %$w > WANT_MAX) {
        my @old = sort { $w->{$a} <=> $w->{$b} || $a cmp $b } keys %$w;
        delete @$w{ @old[0 .. $#old - WANT_MAX] };
    }
    eval { _store()->set(WANT_KEY, $w, 0); 1 };
    return;
}

# ---------------------------------------------------------------------------
# 05:00.

# Queue what the pages wanted, newest first, at most NIGHT_MAX; a url failed
# RETRY_MAX times in a row waits out GIVEUP_TTL. A failure keeps its url
# wanted, so it is asked again the next night.
sub _nightTick {
    my $w = _wants();
    my @urls = sort { $w->{$b} <=> $w->{$a} || $a cmp $b }
               grep { !$queued{$_} && !_givenUp($_) } keys %$w;
    my $left = @urls > NIGHT_MAX ? @urls - NIGHT_MAX : 0;
    splice @urls, NIGHT_MAX if $left;
    for my $url (@urls) {
        $queued{$url} = 1;
        push @queue, { url => $url };
    }
    _dbg('covers: 05:00 run of ' . scalar(@urls) . ' wanted cover(s)'
         . ($left ? ", $left left for the next night" : '')) if @urls;
    _tick() if @urls;
    _armNight();
    return;
}

sub _armNight {
    eval {
        Slim::Utils::Timers::setTimer(undef, time() + _secsUntilNight(), \&_nightTick);
        1;
    } or $log->warn("dsc: could not arm the 05:00 cover run: $@");
    return;
}

# The next NIGHT_HOUR + jitter, LOCAL, strictly in the future. Built as a real
# local time with POSIX::mktime (isdst -1), as LBF's _secsUntilNextWarm is, so
# a summer-time change cannot move it an hour. $now is for the suite.
sub _secsUntilNight {
    my ($now) = @_;
    $now = time() unless defined $now;
    my @t = localtime($now);
    for my $d (0, 1, 2) {
        my $at = POSIX::mktime(_jitter(), 0, NIGHT_HOUR, $t[3] + $d, $t[4], $t[5], 0, 0, -1);
        return $at - $now if defined $at && $at > $now;
    }
    return 86400;
}

# Stable per install (LBF's _warmJitter): from the server's uuid, encoded to
# octets first because md5_hex dies on wide characters.
our $jitter;
sub _jitter {
    return $jitter if defined $jitter;
    my $seed = eval { preferences('server')->get('server_uuid') } // '';
    $seed = 'discography' unless length $seed;
    utf8::encode($seed) if utf8::is_utf8($seed);
    $jitter = hex(substr(md5_hex($seed), 0, 8)) % NIGHT_JITTER_MAX;
    return $jitter;
}

1;
