package Plugins::Discography::Covers;

# THE ARCHIVE COVERS, LOADED IN THE VIEW (0.56.44). A tile with no source cover
# points at Discography's own image route, `imageproxy/dsc/caa/<group>/image.jpg`
# (tileImage). When a device asks for it, tileHandler holds the request, this
# module downloads the group's archive cover ITSELF, and the image proxy is
# handed the file, so the tile fills in where it is. Simon 2026-10-03: "they
# load albeit slowly in a view", the quickest material first, and "when backed
# out it may load them in the bg like LBF does, but a visit to another artist
# must then pause that and move to the opened page".
#
# WHY THIS NO LONGER FREEZES THE SERVER (found 2026-10-03, CLAUDE.md §A3 `THE
# FREEZE IS TLS 1.3`). LMS's HTTPS reader (Net::HTTPS::NB) waits inside a
# blocking select when a read finds no data, and under TLS 1.3 the session
# tickets arrive before the answer, so the whole server waited out archive.org's
# think time: 0.4-14 s a cover, which is why 0.56.26 showed icons and 0.56.30
# fetched at 05:00 only. A download forced to TLS 1.2 has nothing in front of
# its answer: reproduced with LMS's own reader, the longest call 0.14 s against
# 0.4-13.8 s. The proxy's own fetch takes no options, so this module downloads
# and the proxy only resizes (a `file:` url, as for a local cover).
#
# THE ORDER, LBF's scheduler (Simon: "works really well in this regard"):
#   1. the page in front of the user: first the covers a device is waiting for
#      (its tiles on screen), oldest request first, ON_SCREEN_MAX at a time and
#      from the first moment; then the rest of the page in page order (newPage
#      + want), after DRAW_GRACE and while no page request is out;
#   2. pages left behind, newest first, the same way: a new page goes to the
#      front and the old one's leftovers wait behind it (downloads already out
#      finish);
#   3. the 05:00 run: what is still wanted, newest first, at most NIGHT_MAX.
# Everything but a cover on screen uses LBF's widths: two while somebody
# browses Discography, eight after BROWSE_QUIET.
#
# BOUNDED: one download per cover at a time; at most MAX_JOBS queued (past it
# the oldest background ones go, still wanted for 05:00), and the same for one
# not reached within BG_TTL; a device waits at most WAIT_MAX for its download
# to start, then gets the proxy's placeholder (never cached); every download
# has a timeout and a watchdog; one retry, then a failure counts at most once
# per MISS_SPACING and the tile shows its icon meanwhile; three counted
# failures give the cover up for GIVEUP_TTL.
#
# LBF'S RESIZING: every size cut from ONE 1200 px download (the only archive
# size that never upscales Material's 600 px tile), stored as JPEG (the route
# ends `.jpg`; LBF measured a 600 px cover at 648,081 B as PNG against
# 101,100 B as JPEG). After a download the sizes the proxy is asked for (SPECS)
# are written into its cache from the file (_warm, keyed exactly as the proxy
# keys a request), so a cover fetched in the background shows on the next
# visit without a second download.
#
# NEVER FOR A COVER THAT DOES NOT EXIST: Browse gives a group ListenBrainz marks
# as having no archive cover its type icon (API::peekCoverFlags; 24 of 24
# agreed with the archive, 2026-10-02), as it does a cover given up.

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use File::Spec ();
use POSIX ();
use Time::HiRes ();

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

my $log = logger('plugin.discography');

# The route a tile points at. The proxy hands tileHandler the path minus its
# last segment (ImageProxy::getImage, `imageproxy/(.*)/[^/]*`): `dsc/caa/<group>`.
# Ours alone: LBF's handler matches `coverartarchive.org`, and LMS keeps one
# handler per pattern (Plugin.pm registers this one).
use constant ROUTE => 'imageproxy/dsc/caa/';
my $UUID = qr/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/;

# The sizes written into the proxy's cache after a download. '' is the unsized
# request Material 6.4.10 sends for an `icon` row; the rest what it asks once
# that is fixed and what the Default skin asks today: LMS_LIST_IMAGE_SZ 150/300
# and LMS_IMAGE_SZ 300/600 (LBF COVER_SPECS). Any other size a device asks
# goes through tileHandler like a first request.
use constant SPECS => ('', '_150x150_f', '_300x300_f', '_600x600_f');

# Downloads in flight. A cover a device is waiting for goes at once, up to
# ON_SCREEN_MAX of them; the rest use LBF's widths, two while somebody browses
# Discography (a page wants the server too) and eight after BROWSE_QUIET.
use constant ON_SCREEN_MAX        => 4;
use constant CONCURRENCY_BROWSING => 2;
use constant CONCURRENCY_IDLE     => 8;
use constant BROWSE_QUIET         => 20;   # seconds without a request before "idle"

# The background waits DRAW_GRACE after a Discography request, so the page and
# its quick covers come first, and FG_WAIT at a time while a page has a request
# out (API::_netFgBusy). A cover on screen waits for neither.
use constant DRAW_GRACE => 3;
use constant FG_WAIT    => 1;

# One download: TLS 1.2 (the header), the proxy's own 30 s timeout, one retry
# RETRY_GAP later (an archive.org datanode answers a passing 500: 2026-10-03,
# the same cover failed on one node and loaded from another), and a watchdog
# for a download that never calls back.
use constant TLS_VERSION   => 'TLSv1_2';
use constant FETCH_TIMEOUT => 30;
use constant RETRY_GAP     => 2;
use constant WATCHDOG      => 150;

# A device waits at most WAIT_MAX for its download to start; then it gets the
# proxy's placeholder (never cached) and the download stays queued.
use constant WAIT_MAX => 90;

# The queue: at most MAX_JOBS (past it the oldest background ones go); a
# background job not reached within BG_TTL goes too. Either stays wanted for
# 05:00. At most SCAN_BUDGET jobs looked at in one turn (a run of covers the
# proxy already holds is four cache reads each: LBF's COVER_SCAN_BUDGET lesson).
use constant MAX_JOBS    => 400;
use constant BG_TTL      => 3600;
use constant SCAN_BUDGET => 25;

# The downloaded original is kept FILE_TTL seconds in the server's cache folder,
# for the sizes cut from it and any device asking meanwhile, then deleted.
use constant FILE_DIR => 'DiscographyCovers';
use constant FILE_TTL => 120;

# A cover that fails stays wanted. Its tile shows the type icon for
# MISS_SPACING, and a failure counts at most once in that time (a cover asked
# on every view must not use up its three tries in an hour). After RETRY_MAX
# counted failures it is given up for GIVEUP_TTL: icon, not asked at night, not
# recorded by a visit. Failing to reach archive.org at all (no address, no
# route) holds the cover back the same way but counts nothing. The counts live
# in ONE kv row, { group => [last failure at, counted failures] }.
use constant RETRY_MAX    => 3;
use constant GIVEUP_TTL   => 30 * 86400;
use constant MISS_SPACING => 3600;
use constant MISS_KEY     => 'dsc:cvmiss:v2';

# The wanted covers: ONE kv row, { group => last wanted at }, so a restart or a
# page left early still gets its covers (05:00). Written SAVE_DELAY after the
# first change, so a page's thirty wants are one write. A group not wanted
# again for WANT_TTL is dropped, and past WANT_MAX the oldest go. Both rows are
# emptied with every kv row when CACHE_VERSION changes (DB.pm).
use constant WANT_KEY   => 'dsc:cvwant:v2';
use constant WANT_TTL   => 30 * 86400;
use constant WANT_MAX   => 5000;
use constant SAVE_DELAY => 10;
# At most this many covers a night, the most recently wanted first.
use constant NIGHT_MAX  => 300;

# LBF's overnight clock: 05:00 local plus a fixed per-install offset, so every
# install in a timezone does not reach the archive in the same second.
use constant NIGHT_HOUR       => 5;
use constant NIGHT_JITTER_MAX => 1800;

# A job: { rg, seq, page, rank, at, waiters => [ [ $cb, since ] ], running,
# onScreen, attempts }. page = the page that wanted it (newPage's count), -1 for
# the 05:00 run.
my %jobs;             # group => job, queued or downloading
my $seq          = 0; # arrival order
my $page         = 0; # the page in front of the user (newPage)
my $rank         = 0; # page order within it (want)
my $running      = 0; # downloads in flight
my $runningOn    = 0; # ... of which a device was waiting for at launch
my $pumping      = 0; # re-entrancy guard on _tick's launch loop
my ($timer, $timerAt); # ONE wake-up, moved earlier when needed (_arm)
my $lastBrowseAt = 0; # Time::HiRes, the last Discography request (noteBrowse)
my $miss;             # the failure row, loaded on first use (_misses)
my $wants;            # the wanted row, loaded on first use (_wants)
my $saveArmed    = 0; # one pending write of the wanted row
my $proxyCache;
my $store;
# Per drain, for the debug line.
my %pass = (fetched => 0, skipped => 0, failed => 0);

sub _dbg { Plugins::Discography::Plugin::dbg(@_) if Plugins::Discography::Plugin->can('dbg') }

# For the suite: the queue as it stands, { group => { page, rank, waiters,
# running } }.
sub _snapshot {
    return { map { my $j = $jobs{$_};
                   ($_ => { page => $j->{page}, rank => $j->{rank},
                            waiters => scalar @{ $j->{waiters} }, running => $j->{running} ? 1 : 0 }) }
             keys %jobs };
}

# For the suite: forget everything (DB.pm's _reset).
sub _reset {
    %jobs = ();
    $seq = $page = $rank = $running = $runningOn = $pumping = $lastBrowseAt = $saveArmed = 0;
    undef $timer; undef $timerAt;
    undef $miss; undef $wants; undef $proxyCache; undef $store; undef $Plugins::Discography::Covers::jitter;
    %pass = (fetched => 0, skipped => 0, failed => 0);
    return;
}

# ---------------------------------------------------------------------------
# What Browse and the image proxy call.

# The image of a tile with no source cover: our route for its group, or undef
# (Browse shows the release-type icon) for a cover given up or one that failed
# within MISS_SPACING. No cache is read here (the page is being built): whether
# the proxy already holds the cover is the proxy's own first question.
sub tileImage {
    my $rg = _rg($_[0]) // return undef;
    return undef if _givenUp($rg) || _recentFail($rg);
    return ROUTE . $rg . '/image.jpg';
}

# The image proxy's handler for our route (Plugin.pm), reached only when its
# cache does not hold the size asked. Answers a `file:` url at once for a cover
# downloaded a moment ago; otherwise holds the request (undef: LMS 9.0+ waits
# for $cb) and puts the cover first in line. '' is the proxy's placeholder,
# sent with no-cache: not our route, or a cover given up / failed within the
# hour (a tile drawn before that).
sub tileHandler {
    my ($url, $spec, $cb) = @_;
    my ($rg) = ($url // '') =~ m{^dsc/caa/($UUID)$};
    return '' unless $rg && !_givenUp($rg) && !_recentFail($rg);
    if (my $path = _heldFile($rg)) { return _fileUrl($path) // '' }
    return '' unless ref $cb eq 'CODE';
    my $job = _job($rg, $page, 0);
    push @{ $job->{waiters} }, [ $cb, Time::HiRes::time() ];
    _trim();
    _arm(0);
    return undef;
}

# Somebody is looking: every Discography request (Browse::topLevel).
sub noteBrowse { $lastBrowseAt = Time::HiRes::time(); return }

# A page is being built (Browse::_buildList, a strip's own page): what it wants
# from here on goes in front of every earlier page's leftovers.
sub newPage { $page++; $rank = 0; return }

# A cover the page SHOWS (Browse::_wantCovers), in page order: recorded for
# 05:00 and queued behind the covers on screen. Called while the page is built,
# so nothing runs here: the pump starts on a timer.
sub want {
    my $rg = _rg($_[0]) // return;
    return if _givenUp($rg) || _recentFail($rg);
    _wants()->{$rg} = time();
    _armSave();
    _job($rg, $page, $rank++);
    _trim();
    _arm(0);
    return;
}

# Startup: no download is out, so the files left in our folder are leftovers;
# then arm 05:00.
sub init {
    _clearFiles();
    _armNight();
    return;
}

# A group mbid, lowercased, or undef.
sub _rg {
    my $m = lc($_[0] // '');
    return $m =~ /^$UUID$/ ? $m : undef;
}

# ---------------------------------------------------------------------------
# The pump.

# The background's width: two while somebody browses Discography, eight after.
sub _limit {
    return CONCURRENCY_BROWSING
        if $lastBrowseAt && Time::HiRes::time() - $lastBrowseAt < BROWSE_QUIET;
    return CONCURRENCY_IDLE;
}

# Seconds before the background may launch: the page's own grace, then any
# page request still out. 0 = now.
sub _waitFor {
    my $now = Time::HiRes::time();
    my $graceEnd = $lastBrowseAt + DRAW_GRACE;
    return $graceEnd - $now if $graceEnd > $now;
    my $fg = Plugins::Discography::API->can('_netFgBusy');
    return FG_WAIT if $fg && eval { $fg->() };
    return 0;
}

# ONE wake-up timer (every landing re-arms, and an unguarded arm would leave
# one timer per request), moved EARLIER when asked for sooner: a device asking
# while the pump sleeps out the quiet window must not wait for it (LBF's
# DetailWarm::_arm).
sub _arm {
    my ($in) = @_;
    my $at = Time::HiRes::time() + ($in && $in > 0 ? $in : 0);
    return if $timer && $timerAt <= $at;
    eval { Slim::Utils::Timers::killSpecific($timer); 1 } if $timer;
    undef $timer;
    $timerAt = $at;
    $timer = eval {
        Slim::Utils::Timers::setTimer(undef, $at, sub { undef $timer; _tick() });
    };
    return;
}

# One-off timers (a retry, a file's deletion, the next size to cut).
sub _later {
    my ($in, $code) = @_;
    eval { Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $in, $code); 1 }
        or eval { $code->() };
    return;
}

# Launch what the order allows (the header): a cover on screen while fewer
# than ON_SCREEN_MAX of those are out, anything else after the grace and
# within the width. Never called inside a callback chain (everything arms), and
# re-entrancy guarded as LBF's is.
sub _tick {
    return if $pumping;
    $pumping = 1;
    my $now = Time::HiRes::time();
    # Whatever stops the loop below, wake for the first device to reach WAIT_MAX.
    if (defined(my $due = _sweep($now))) { _arm($due - $now) }
    my $looked = 0;
    while (my $job = _next()) {
        if ($looked++ >= SCAN_BUDGET) { _arm(0); last }
        if (@{ $job->{waiters} }) {
            last if $runningOn >= ON_SCREEN_MAX;     # a landing wakes us
        }
        else {
            my $wait = _waitFor();
            if ($wait > 0) { _arm($wait); last }
            my $limit = _limit();
            if ($running >= $limit) {
                # At the browsing width nothing out is sure to land before the
                # quiet window ends: wake then to widen.
                _arm($lastBrowseAt + BROWSE_QUIET - $now) if $limit < CONCURRENCY_IDLE;
                last;
            }
        }
        _launch($job);
    }
    $pumping = 0;
    _drained();
    return;
}

# The queued job that goes next (the header's order).
sub _next {
    my $best;
    for my $j (values %jobs) {
        next if $j->{running};
        $best = $j if !$best || _before($j, $best);
    }
    return $best;
}

# The newest page first, and within a page the covers a device is waiting for
# (oldest request first), then page order. Page before waiting: requests still
# out from a page the user has left (a browser need not cancel them) must not
# hold up the page opened since. A request for a cover of an older page brings
# it to the page current at that moment (tileHandler): it is on screen now.
sub _before {
    my ($x, $y) = @_;
    return $x->{page} > $y->{page} if $x->{page} != $y->{page};
    my $wx = @{ $x->{waiters} } ? 1 : 0;
    my $wy = @{ $y->{waiters} } ? 1 : 0;
    return $wx > $wy if $wx != $wy;
    return $x->{waiters}[0][1] < $y->{waiters}[0][1]
        if $wx && $x->{waiters}[0][1] != $y->{waiters}[0][1];
    return $x->{rank} < $y->{rank} if $x->{rank} != $y->{rank};
    return $x->{seq} < $y->{seq};
}

# The queue's two time limits: a device waiting past WAIT_MAX for a download
# that has not started gets the placeholder; a background job not reached
# within BG_TTL is dropped (still wanted for 05:00). Returns when the next
# waiting device reaches WAIT_MAX, or undef: nothing else wakes the pump for
# it while the covers on screen are all out.
sub _sweep {
    my ($now) = @_;
    my $due;
    for my $j (values %jobs) {
        next if $j->{running};
        if (@{ $j->{waiters} }) {
            my @keep;
            for my $w (@{ $j->{waiters} }) {
                if ($now - $w->[1] >= WAIT_MAX) { _answer($w->[0], '') }
                else                            { push @keep, $w }
            }
            $j->{waiters} = \@keep;
            my $d = @keep ? $keep[0][1] + WAIT_MAX : undef;
            $due = $d if defined $d && (!defined $due || $d < $due);
        }
        delete $jobs{ $j->{rg} }
            if !@{ $j->{waiters} } && $j->{page} >= 0 && $now - $j->{at} > BG_TTL;
    }
    return $due;
}

# The job for a group, made if new; a later page, or an earlier place on the
# same page, moves it up. The caller trims (_trim) once its job is in place, so
# a job a device now waits for is never the one dropped.
sub _job {
    my ($rg, $pg, $rk) = @_;
    my $now = Time::HiRes::time();
    if (my $j = $jobs{$rg}) {
        if ($pg > $j->{page} || ($pg == $j->{page} && $rk < $j->{rank})) {
            $j->{page} = $pg;
            $j->{rank} = $rk;
        }
        $j->{at} = $now if $pg >= 0;
        return $j;
    }
    return $jobs{$rg} = { rg => $rg, seq => ++$seq, page => $pg, rank => $rk, at => $now,
                          waiters => [] };
}

# Past MAX_JOBS: the oldest page's last covers go first (the newest want can be
# the one dropped); never a cover a device waits for or one downloading.
sub _trim {
    return if keys %jobs <= MAX_JOBS;
    my @drop = sort { $a->{page} <=> $b->{page} || $b->{rank} <=> $a->{rank} || $b->{seq} <=> $a->{seq} }
               grep { !$_->{running} && !@{ $_->{waiters} } } values %jobs;
    delete $jobs{ (shift @drop)->{rg} } while keys %jobs > MAX_JOBS && @drop;
    return;
}

sub _drained {
    return if %jobs || $running;
    return unless $pass{fetched} || $pass{skipped} || $pass{failed};
    _dbg("covers: $pass{fetched} fetched, $pass{failed} failed, $pass{skipped} already held");
    %pass = (fetched => 0, skipped => 0, failed => 0);
    return;
}

# One cover. A device waiting: download. Nobody waiting: only if the proxy
# lacks a size; held already, or a cache that cannot be read, ends it here.
sub _launch {
    my ($job) = @_;
    my $rg = $job->{rg};
    unless (@{ $job->{waiters} }) {
        # Downloaded a moment ago: its sizes are being cut (_warm), so not again.
        if (_heldFile($rg)) { delete $jobs{$rg}; return }
        my $lack = _lacking($rg);
        if (!$lack || !@$lack) {
            if ($lack) { $pass{skipped}++; _missClear($rg); _wantDone($rg) }
            delete $jobs{$rg};
            return;
        }
    }
    $job->{running}  = 1;
    $job->{onScreen} = @{ $job->{waiters} } ? 1 : 0;
    $running++;
    $runningOn++ if $job->{onScreen};
    _download($job);
    return;
}

# The 1200 px archive cover over TLS 1.2 (the header), redirects followed by
# LMS with the same socket options. A 200 that is not an image is a failure.
sub _download {
    my ($job) = @_;
    $job->{attempts}++;
    my $rg  = $job->{rg};
    my $url = eval { Plugins::Discography::API->caaImage($rg, 1200) }
              // "https://coverartarchive.org/release-group/$rg/front-1200.jpg";
    my ($ended, $watch) = (0);
    my $end = sub {
        my ($ref, $why) = @_;
        return if $ended++;
        eval { Slim::Utils::Timers::killSpecific($watch); 1 } if $watch;
        if ($ref) {
            _landed($job, $ref);
        }
        elsif ($job->{attempts} < 2) {
            _dbg("cover $rg: $why; once more");
            _later(RETRY_GAP, sub { _download($job) });
        }
        else {
            _failed($job, $why);
        }
    };
    $watch = eval {
        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + WATCHDOG,
            sub { $end->(undef, 'no answer') });
    };
    eval {
        require Slim::Networking::SimpleAsyncHTTP;
        Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my ($http) = @_;
                my $type = eval { $http->headers->content_type } // '';
                my $ref  = eval { $http->contentRef };
                if ($type =~ m{^image/}i && ref $ref eq 'SCALAR' && length $$ref) { $end->($ref) }
                else { $end->(undef, 'not an image' . (length $type ? " ($type)" : '')) }
            },
            sub { my (undef, $error) = @_; $end->(undef, $error // 'failed') },
            { timeout => FETCH_TIMEOUT, options => { SSL_version => TLS_VERSION } },
        )->get($url, 'Accept' => 'image/jpeg,image/png;q=0.9');
        1;
    } or $end->(undef, "could not ask: $@");
    return;
}

# Downloaded: kept as a file, every device waiting handed it (the proxy cuts its
# size and caches it), no longer wanted, the sizes cut into the proxy's cache,
# the file deleted FILE_TTL later.
sub _landed {
    my ($job, $ref) = @_;
    my $rg   = $job->{rg};
    my $path = _saveFile($rg, $ref);
    my $file = $path ? _fileUrl($path) : undef;
    unless ($file) {
        # Our own folder failed, not the cover: the placeholder, nothing counted.
        _answer($_->[0], '') for @{ $job->{waiters} };
        $job->{waiters} = [];
        unlink $path if $path;
        $pass{failed}++;
        $log->warn("dsc: could not keep the cover of $rg in the cache folder");
        return _finish($job);
    }
    _answer($_->[0], $file) for @{ $job->{waiters} };
    $job->{waiters} = [];
    $pass{fetched}++;
    _missClear($rg);
    _wantDone($rg);
    _finish($job);
    _warm($rg, $path);
    _later(FILE_TTL, sub { unlink $path });
    return;
}

# Not to be had: every device waiting gets the placeholder (never cached), and
# the failure is noted. Not reaching archive.org at all counts nothing.
sub _failed {
    my ($job, $why) = @_;
    my $rg = $job->{rg};
    _answer($_->[0], '') for @{ $job->{waiters} };
    $job->{waiters} = [];
    _missNote($rg, ($why // '') !~ /resolve|unreachable|no route/i);
    $pass{failed}++;
    _dbg("cover $rg not fetched: " . ($why // '?'));
    return _finish($job);
}

sub _finish {
    my ($job) = @_;
    if ($job->{running}) {
        $running--;
        $runningOn-- if $job->{onScreen};
        $job->{running} = 0;
    }
    delete $jobs{ $job->{rg} } if ($jobs{ $job->{rg} } // 0) == $job;
    _arm(0);
    return;
}

sub _answer {
    my ($cb, $url) = @_;
    eval { $cb->($url); 1 } or $log->warn("dsc: a cover request could not be answered: $@");
    return;
}

# Each size the proxy lacks, cut from the file into its cache, one per turn,
# under the key the proxy itself would use: `imageproxy/dsc/caa/<group>/image
# <spec>.jpg`, with the spec as Slim::Web::Graphics reads it from that name.
sub _warm {
    my ($rg, $path) = @_;
    my $cache = _proxyCache() or return;
    my $lack  = _lacking($rg) or return;     # a cache that cannot be read: no warm
    my @todo  = @$lack;
    my $step;
    $step = sub {
        my $s = shift @todo;
        unless ($s) { undef $step; return }
        my $next = $step;
        my $ok = eval {
            require Slim::Utils::ImageResizer;
            Slim::Utils::ImageResizer->resize($path, $s->[0], $s->[1], sub { _later(0, $next) }, $cache);
            1;
        };
        _later(0, $next) unless $ok;
    };
    $step->();
    return;
}

# [ proxy cache key, resize spec ] for each of SPECS.
sub _sizes {
    my ($rg) = @_;
    return map { [ ROUTE . $rg . '/image' . $_ . '.jpg', (length $_ ? substr($_, 1) : '') . '.jpg' ] } SPECS;
}

# The sizes the proxy lacks, or undef when its cache cannot be read.
sub _lacking {
    my ($rg) = @_;
    my @lack;
    for my $s (_sizes($rg)) {
        my $h = _proxyHas($s->[0]);
        return undef unless defined $h;
        push @lack, $s unless $h;
    }
    return \@lack;
}

sub _proxyCache {
    $proxyCache ||= eval { require Slim::Web::ImageProxy; Slim::Web::ImageProxy::Cache->new() };
    return $proxyCache;
}

# 1 the proxy holds this key, 0 it does not, undef it could not be asked (LBF's
# three answers: a cache that cannot be read must not be recorded as a miss).
sub _proxyHas {
    my ($key) = @_;
    my $c = _proxyCache() or return undef;
    my $hit = eval { $c->get($key) };
    return undef if $@;
    return $hit ? 1 : 0;
}

# ---------------------------------------------------------------------------
# The downloaded files: <cachedir>/DiscographyCovers/<group>.jpg.

sub _dir {
    my ($make) = @_;
    my $root = eval { preferences('server')->get('cachedir') };
    return undef unless defined $root && length $root;
    my $dir = File::Spec->catdir($root, FILE_DIR);
    mkdir $dir if $make && !-d $dir;
    return -d $dir ? $dir : undef;
}

# Written whole, then renamed, so a request never reads half a cover.
sub _saveFile {
    my ($rg, $ref) = @_;
    my $dir = _dir(1) or return undef;
    my $path = File::Spec->catfile($dir, "$rg.jpg");
    my $part = "$path.part";
    open(my $fh, '>:raw', $part) or return undef;
    my $ok = print {$fh} $$ref;
    $ok = close($fh) && $ok;
    return $path if $ok && rename($part, $path);
    unlink $part;
    return undef;
}

sub _heldFile {
    my ($rg) = @_;
    my $dir = _dir() or return undef;
    my $path = File::Spec->catfile($dir, "$rg.jpg");
    return -s $path ? $path : undef;
}

sub _fileUrl {
    my ($path) = @_;
    my $u = eval { require Slim::Utils::Misc; Slim::Utils::Misc::fileURLFromPath($path) };
    return $u && $u =~ /^file:/ ? $u : undef;
}

sub _clearFiles {
    my $dir = _dir() or return;
    opendir(my $dh, $dir) or return;
    unlink map { File::Spec->catfile($dir, $_) } grep { /^$UUID\.jpg(?:\.part)?$/ } readdir $dh;
    closedir $dh;
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
    my ($rg) = @_;
    my $e = _misses()->{$rg};
    return 0 unless ref $e eq 'ARRAY' && ($e->[1] || 0) >= RETRY_MAX;
    return time() - ($e->[0] || 0) < GIVEUP_TTL ? 1 : 0;
}

# Failed within MISS_SPACING: the tile shows its icon and nothing is asked.
sub _recentFail {
    my ($rg) = @_;
    my $e = _misses()->{$rg};
    return ref $e eq 'ARRAY' && time() - ($e->[0] || 0) < MISS_SPACING ? 1 : 0;
}

# A failure: always its time; counted only when $counts and the last one is at
# least MISS_SPACING old.
sub _missNote {
    my ($rg, $counts) = @_;
    my $m = _misses();
    my ($at, $fails) = ref $m->{$rg} eq 'ARRAY' ? @{ $m->{$rg} } : (0, 0);
    my $now = time();
    $fails = ($fails || 0) + (($counts && $now - ($at || 0) >= MISS_SPACING) ? 1 : 0);
    $m->{$rg} = [ $now, $fails ];
    _missSave();
    return;
}

sub _missClear {
    my ($rg) = @_;
    my $m = _misses();
    return unless exists $m->{$rg};
    delete $m->{$rg};
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
    my ($rg) = @_;
    my $w = _wants();
    return unless exists $w->{$rg};
    delete $w->{$rg};
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

# What the day left wanted (a page left before its covers came, a restart, the
# queue's limits), newest first, at most NIGHT_MAX, behind anything a page
# wants meanwhile; a cover given up or failed within the hour waits. A failure
# keeps its group wanted, so it is asked again the next night.
sub _nightTick {
    my $w = _wants();
    my @rgs = sort { $w->{$b} <=> $w->{$a} || $a cmp $b }
              grep { !$jobs{$_} && !_givenUp($_) && !_recentFail($_) } keys %$w;
    my $left = @rgs > NIGHT_MAX ? @rgs - NIGHT_MAX : 0;
    splice @rgs, NIGHT_MAX if $left;
    my $r = 0;
    _job($_, -1, $r++) for @rgs;
    _trim();
    _dbg('covers: 05:00 run of ' . scalar(@rgs) . ' wanted cover(s)'
         . ($left ? ", $left left for the next night" : '')) if @rgs;
    _arm(0) if @rgs;
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
