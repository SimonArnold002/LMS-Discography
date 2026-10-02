#!/usr/bin/env perl
#
# The archive covers a page showed an icon for, fetched AT 05:00 with LBF's
# resizing (Discography/Covers.pm). 0.56.27 fetched them after the visit
# (Simon: "follow the same resizing we do in LBF as it works well", "After the
# visit"); 0.56.30 records them by day and fetches at night, as an archive
# fetch froze the whole server for seconds (measured 2026-10-02).
#
# Drives the REAL Covers.pm against fakes of what it talks to: the image proxy
# (proxiedImage, its handler table, its cache), our own server over HTTP
# (SimpleAsyncHTTP, answered by the suite), LMS timers and a fake clock. Every
# rule the module states is pinned here:
#   1  the handler: every front-<n> becomes front-1200, the extension kept
#   2  the paths: unsized + 150/300/600 with a handler, no unsized without one
#   3  NOTHING IS FETCHED BY DAY: a want only records (one delayed write); the
#      05:00 run fetches, after the page grace and while no page request is out
#   4  a cover's paths go out in ONE turn (the shared download)
#   5  two at a time if someone is browsing at 05:00, eight otherwise
#   6  a cover that lands: no longer wanted, its failure count cleared
#   7  a cover that fails: counted, still wanted, asked the next night; both
#      rows survive a restart; a timeout is a failure
#   8  our own server going away counts nothing; a 401 stops the night
#   9  three failures in a row: given up 30 days, then asked again; the night
#      takes the newest NIGHT_MAX; old wants pruned, the row capped
#  10  the 05:00 clock: strictly future, 05:00 + the install's offset, local
#  11  a cover the proxy already holds is not fetched, and no longer wanted
#  12  a proxy cache that cannot be read after the fetch counts nothing
#
# Standalone, no LMS install needed:  perl tools/t_covers.pl
#
use strict;
use warnings;
use FindBin;
use POSIX ();

our ($NOW, $HANDLED, $FG, $NO_PROXY, $GET_DIES, %HELD, %STORE, @REQ, @TIMERS, $PORT, $SETS);

BEGIN {
    # A zone WITH summer time, whatever the machine's, so section 10's clock
    # change tests mean something.
    $ENV{TZ} = 'Europe/London'; POSIX::tzset();
    $NOW = 1_800_000_000;
    *CORE::GLOBAL::time = sub () { int $main::NOW };
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Timers
                  Slim::Utils::Misc Slim::Web::ImageProxy Slim::Networking::SimpleAsyncHTTP
                  Plugins::Discography::Plugin Plugins::Discography::API
                  Plugins::Discography::DB)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs)) { push @{"${e}::ISA"}, 'Exporter' }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');

    *{'Slim::Utils::Timers::setTimer'} = sub { push @main::TIMERS, [ $_[1], $_[2] ]; 1 };
    *{'Slim::Utils::Misc::unescape'}   = sub { my $s = $_[0]; $s =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge; $s };

    # proxiedImage as LMS 9.1 builds it: escaped url, extension from the url.
    *{'Slim::Web::ImageProxy::proxiedImage'} = sub {
        my ($url) = @_;
        return $url unless $url && $url =~ /^https?:/;
        my $ext = $url =~ /(\.(?:jpg|jpeg|png|gif))/ ? $1 : '.png';
        $ext =~ s/jpeg/jpg/;
        (my $esc = $url) =~ s/([^A-Za-z0-9\-_.~])/sprintf('%%%02X', ord $1)/ge;
        return '/imageproxy/' . $esc . '/image' . $ext;
    };
    *{'Slim::Web::ImageProxy::getHandlerFor'} = sub { $main::HANDLED ? sub {} : undef };
    *{'Slim::Web::ImageProxy::Cache::new'} = sub {
        die "no cache\n" if $main::NO_PROXY; bless {}, 'Slim::Web::ImageProxy::Cache' };
    *{'Slim::Web::ImageProxy::Cache::get'} = sub {
        die "db locked\n" if $main::GET_DIES; $main::HELD{ $_[1] } };

    # Our own server: the suite answers each request.
    *{'Slim::Networking::SimpleAsyncHTTP::new'} = sub {
        my (undef, $ok, $err) = @_; bless { ok => $ok, err => $err }, 'Slim::Networking::SimpleAsyncHTTP' };
    *{'Slim::Networking::SimpleAsyncHTTP::get'} = sub {
        my ($self, $url) = @_; push @main::REQ, { url => $url, %$self }; 1 };

    *{'Plugins::Discography::API::_netFgBusy'} = sub { $main::FG ? 1 : 0 };
    *{'Plugins::Discography::DB::store'}       = sub { bless {}, 'T::Store' };
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}
package T::Prefs; our $AUTOLOAD;
sub get { $_[1] eq 'httpport' ? $main::PORT : $_[1] eq 'server_uuid' ? 'uuid-for-the-suite' : undef }
sub AUTOLOAD { return } sub DESTROY {}
package T::Store;
sub get { $main::STORE{ $_[1] } }
sub set { $main::STORE{ $_[1] } = $_[2]; $main::SETS++; 1 }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Time::HiRes;
{ no warnings qw(redefine prototype once); *Time::HiRes::time = sub { $main::NOW }; }
require Plugins::Discography::Covers;
my $C = 'Plugins::Discography::Covers';

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

my $MB  = '0dc27124-99ea-44f2-afbc-73e6f48b2c5b';
sub caa { 'https://coverartarchive.org/release-group/' . ($_[0] // $MB) . '/front-250.jpg' }
sub fresh {
    $C->can('_reset')->();
    %HELD = (); %STORE = (); @REQ = (); @TIMERS = ();
    $HANDLED = 1; $FG = 0; $NO_PROXY = 0; $GET_DIES = 0; $PORT = 9000; $SETS = 0;
}
# Fire every timer due by now (a fired timer may arm another: run until none due).
sub tick {
    for (1 .. 50) {
        my @due = grep { $_->[0] <= $NOW } @TIMERS or return;
        @TIMERS = grep { $_->[0] > $NOW } @TIMERS;
        $_->[1]->() for @due;
    }
}
sub later { $NOW += $_[0]; tick() }
sub keyOf { my ($url, $spec) = @_; "imageproxy/$url/image$spec.jpg" }
# Answer every request in flight for a url: ok (and the proxy now holds it), or
# an error text.
sub land {
    my ($url, $how) = @_;
    my @mine = grep { index($_->{url}, _esc($url)) >= 0 } @REQ;
    @REQ = grep { index($_->{url}, _esc($url)) < 0 } @REQ;
    if (!defined $how) { $HELD{ keyOf($url, $_) } = 1 for ('', '_150x150_f', '_300x300_f', '_600x600_f') }
    for my $r (@mine) {
        if (defined $how && $how ne 'placeholder') { $r->{err}->(undef, $how) }
        else                                        { $r->{ok}->(undef) }
    }
    return scalar @mine;
}
sub _esc { (my $e = $_[0]) =~ s/([^A-Za-z0-9\-_.~])/sprintf('%%%02X', ord $1)/ge; $e }
# The 05:00 run, then every timer it arms that is due.
sub night { $C->can('_nightTick')->(); tick() }
sub sentFor { my ($u) = @_; scalar grep { index($_->{url}, _esc($u)) >= 0 } @REQ }
use constant WANT => 'dsc:cvwant:v1';
use constant MISS => 'dsc:cvmiss:v1';
sub inflight { my %u; for (@REQ) { $u{$1} = 1 if $_->{url} =~ m{/imageproxy/([^/]+)/} } scalar keys %u }

# 1. The handler: LBF's rewrite, extension kept.
{
    my $h = $C->can('proxyHandler');
    ok(scalar($h->(caa(), '_300x300_f') eq 'https://coverartarchive.org/release-group/' . $MB . '/front-1200.jpg'),
       '1: front-250.jpg -> front-1200.jpg');
    ok(scalar($h->('https://coverartarchive.org/release/x/front-500', '') eq 'https://coverartarchive.org/release/x/front-1200'),
       '1: an extensionless front-500 -> front-1200, no extension added');
    ok(scalar($h->('http://coverartarchive.org/release/x/34228002660.jpg', '') eq 'http://coverartarchive.org/release/x/34228002660.jpg'),
       "1: an archive image that is not a front-<n> (MAI's) is left alone");
    ok(scalar($h->(caa(), '_150x150_f') eq $h->(caa(), '_600x600_f')),
       '1: every spec resolves to ONE source url (the shared download)');
}

# 2. The paths and their cache keys.
{
    fresh();
    my @p = $C->can('_paths')->(caa());
    ok(scalar(@p == 4 && $p[0][0] =~ m{/image\.jpg$}), '2: with a handler: unsized first, four paths');
    ok(scalar(join(',', map { $_->[1] } @p) eq join(',', map { keyOf(caa(), $_) } '', '_150x150_f', '_300x300_f', '_600x600_f')),
       '2: keys are the decoded path, no leading slash, `.jpg`');
    $HANDLED = 0;
    @p = $C->can('_paths')->(caa());
    ok(scalar(@p == 3 && !grep { $_->[0] =~ m{/image\.jpg$} } @p),
       '2: without a handler the unsized path is left out (it would be a 301 to the archive)');
    ok(scalar(!$C->can('_paths')->('not a url')), '2: not an http url -> no paths');
}

# 3. Nothing by day: a want only records; the 05:00 run fetches.
{
    fresh();
    $C->can('noteBrowse')->();
    my $at = int $NOW;
    $C->can('want')->(caa());
    $C->can('want')->(caa('b'));
    $C->can('want')->(caa('c'));
    later(3600);
    ok(scalar(!@REQ), '3: wanted by day -> nothing fetched, an hour later still nothing');
    ok(scalar(($STORE{+WANT} || {})->{ caa() } == $at), '3: the want is recorded with its time');
    ok(scalar($SETS == 1), '3: three wants -> one write of the row (got ' . ($SETS // 0) . ')');
    ok(scalar(!grep { $_->[0] > $NOW + 3600 } @TIMERS), '3: wanting arms no fetch for later either');

    fresh();
    $C->can('want')->(caa());
    $C->can('init')->();
    my ($t) = sort { $b->[0] <=> $a->[0] } @TIMERS;     # the latest: the 10 s write comes first
    ok(scalar($t && $t->[0] > $NOW + 60 && !@REQ), '3: init arms the 05:00 run, nothing sent');
    $NOW = $t->[0]; tick();
    ok(scalar(@REQ == 4), '3: at 05:00 the wanted cover goes out (four paths)');
    ok(scalar(!grep { $_->{url} !~ m{^http://127\.0\.0\.1:9000/imageproxy/} } @REQ),
       '3: every request is to our own server, through its image proxy');

    fresh();
    $C->can('want')->(caa());
    $C->can('noteBrowse')->();
    night();
    ok(scalar(!@REQ), '3: 05:00 within the grace of a Discography request -> waiting');
    $FG = 1;
    later(3.5);
    ok(scalar(!@REQ), '3: grace over but a page has a request out -> waiting');
    $FG = 0;
    later(1);
    ok(scalar(@REQ == 4), '3: page settled -> the cover goes out');
}

# 4. One turn for all of a cover's paths.
{
    fresh();
    $C->can('want')->(caa());
    night();
    ok(scalar(@REQ == 4), '4: all four paths are sent before any answer');
    night();
    ok(scalar(@REQ == 4), '4: a second run while it is out sends nothing more');
}

# 5. Two if someone is browsing at 05:00, eight otherwise.
{
    fresh();
    $C->can('want')->(caa(sprintf '%08d-0000-0000-0000-000000000000', $_)) for 1 .. 12;
    $C->can('noteBrowse')->();
    night();
    later(4);
    ok(scalar(inflight() == 2), '5: browsing -> two covers in flight (got ' . inflight() . ')');
    later(20);
    ok(scalar(inflight() == 8), '5: 20 s quiet -> eight in flight (got ' . inflight() . ')');
}

# 6. A cover that lands: no longer wanted, its failure count cleared.
{
    fresh();
    $STORE{+MISS} = { caa() => [ $NOW - 2 * 86400, 1 ] };   # failed once before
    $C->can('want')->(caa());
    $C->can('want')->(caa('b'));
    night();
    ok(scalar(land(caa()) == 4), '6: four answers for the first cover');
    ok(scalar(!exists $STORE{+MISS}{ caa() }), '6: its failure count is cleared');
    later(11);
    ok(scalar(!exists $STORE{+WANT}{ caa() } && exists $STORE{+WANT}{ caa('b') }),
       '6: it is no longer wanted; the one still out is');
    @REQ = ();
    night();
    ok(scalar(!sentFor(caa())), '6: the next night does not ask for it');
}

# 7. A cover that fails: counted, still wanted, asked the next night.
{
    fresh();
    $C->can('want')->(caa());
    night();
    land(caa(), 'placeholder');               # 200 + placeholder: nothing cached
    my $h = $STORE{+MISS}{ caa() };
    ok(scalar(ref $h eq 'ARRAY' && $h->[1] == 1 && $h->[0] == int $NOW), '7: failed -> one failure, now');
    later(11);
    ok(scalar(exists $STORE{+WANT}{ caa() }), '7: still wanted');
    $C->can('_reset')->();                    # a restart: both rows are in the store
    @REQ = ();
    later(86400);
    night();
    ok(scalar(sentFor(caa()) == 4), '7: after a restart, the next night asks again');
    land(caa(), 'Timed out waiting for data');
    ok(scalar($STORE{+MISS}{ caa() }[1] == 2), '7: a timeout is a failure too (two in a row)');
}

# 8. Our server going away counts nothing; a 401 stops the night.
{
    fresh();
    $C->can('want')->(caa());
    night();
    land(caa(), 'Connection refused');
    ok(scalar(!exists(($STORE{+MISS} || {})->{ caa() })), '8: refused -> no failure counted');
    later(11);
    ok(scalar(exists $STORE{+WANT}{ caa() }), '8: refused -> still wanted');
    fresh();
    $C->can('want')->(caa("c$_")) for 1 .. 10;
    night();
    my %asked;
    my $first = 1;
    for (1 .. 20) {
        last unless @REQ;
        my ($u) = $REQ[0]{url} =~ m{/imageproxy/([^/]+)/};
        $asked{$u} = 1;
        land(Plugins::Discography::Covers::_unescape($u), $first ? '401 Unauthorized' : undef);
        $first = 0;
        tick();
    }
    ok(scalar(keys %asked == 8),
       '8: 401 -> the eight already out finish, the other two are never sent (asked ' . scalar(keys %asked) . ')');
    ok(scalar(!%{ $STORE{+MISS} || {} }), '8: 401 -> no failure counted');
    later(11);
    ok(scalar(keys %{ $STORE{+WANT} || {} } == 3),
       '8: 401 -> the refused cover and the two never sent are still wanted (the seven that landed are not)');
}

# 9. Given up after three failures; the night takes the newest; pruning.
{
    fresh();
    my $now = int $NOW;
    $STORE{+MISS} = { caa('two') => [ $now - 3600, 2 ], caa('given') => [ $now - 3600, 3 ] };
    $STORE{+WANT} = { caa('two') => $now - 60, caa('given') => $now - 60 };
    night();
    ok(scalar(sentFor(caa('two')) && !sentFor(caa('given'))), '9: two failures -> asked; three -> given up');
    land(caa('two'), 'placeholder');
    ok(scalar($STORE{+MISS}{ caa('two') }[1] == 3), '9: its third failure in a row');
    @REQ = ();
    later(2 * 86400);
    night();
    ok(scalar(!sentFor(caa('two'))), '9: given up -> not asked two nights later');
    $C->can('want')->(caa('given'));
    ok(scalar(($STORE{+WANT}{ caa('given') } // 0) == $now - 60), '9: a visit does not re-record a given-up cover');
    later(31 * 86400);
    $C->can('want')->(caa('two'));
    night();
    ok(scalar(sentFor(caa('two'))), '9: 30 days on -> wanted and asked once more');

    fresh();
    $now = int $NOW;
    my %w = map { (caa(sprintf 'n%03d', $_) => $now - 1000 + $_) } 1 .. 305;
    $STORE{+WANT} = { %w };
    night();
    later(30);
    # Land everything that goes out, so the run drains: count what was ever asked.
    my %asked;
    for (1 .. 400) {
        last unless @REQ;
        my ($u) = $REQ[0]{url} =~ m{/imageproxy/([^/]+)/};
        $asked{$u} = 1;
        land(Plugins::Discography::Covers::_unescape($u));
        tick();
    }
    ok(scalar(keys %asked == 300), '9: 305 wanted -> the night asks 300 (got ' . scalar(keys %asked) . ')');
    ok(scalar(!$asked{ _esc(caa('n001')) } && !$asked{ _esc(caa('n005')) } && $asked{ _esc(caa('n006')) }
              && $asked{ _esc(caa('n305')) }), '9: ... the newest 300; the five oldest wait');
    later(11);
    ok(scalar(keys %{ $STORE{+WANT} } == 5), '9: the five left are still wanted');

    fresh();
    $now = int $NOW;
    $STORE{+WANT} = { caa('stale') => $now - 31 * 86400, caa('fresh') => $now - 86400 };
    $C->can('want')->(caa('new'));
    later(11);
    ok(scalar(!exists $STORE{+WANT}{ caa('stale') } && exists $STORE{+WANT}{ caa('fresh') }),
       '9: a want not seen for 30 days is dropped on the next write');

    fresh();
    $now = int $NOW;
    $STORE{+WANT} = { map { (caa(sprintf 'm%05d', $_) => $now - 10000 + $_) } 1 .. 5003 };
    $C->can('want')->(caa('newest'));
    later(11);
    my $row = $STORE{+WANT};
    ok(scalar(keys %$row == 5000 && exists $row->{ caa('newest') } && !exists $row->{ caa('m00004') }
              && exists $row->{ caa('m00005') }), '9: past 5,000 the oldest are dropped');
}

# 10. The 05:00 clock.
{
    fresh();
    my $j  = $C->can('_jitter')->();
    my $at = sub { my @t = localtime($_[0]); POSIX::mktime($j, 0, 5, $t[3] + $_[1], $t[4], $t[5], 0, 0, -1) };
    my $base = POSIX::mktime(0, 0, 3, 15, 0, 126, 0, 0, -1);           # 2026-01-15 03:00 local
    my $s = $C->can('_secsUntilNight')->($base);
    ok(scalar($base + $s == $at->($base, 0)), '10: at 03:00 -> today 05:00 + offset');
    my $five = $at->($base, 0);
    ok(scalar($five + $C->can('_secsUntilNight')->($five) == $at->($base, 1)),
       '10: AT the instant -> tomorrow (strictly future, no refire loop)');
    ok(scalar($j >= 0 && $j < 1800 && $j == $C->can('_jitter')->()), '10: the offset is under 30 min and stable');
    # The evening before the clocks go forward (Europe: 2026-03-29 01:00), and
    # back (2026-10-25 02:00): seconds arithmetic would land an hour out.
    for my $eve ([ 28, 2 ], [ 24, 9 ]) {
        my $b = POSIX::mktime(0, 0, 20, $eve->[0], $eve->[1], 126, 0, 0, -1);
        my @t = localtime($b + $C->can('_secsUntilNight')->($b));
        ok(scalar($t[2] == 5 && $t[3] == $eve->[0] + 1),
           "10: across a clock change (month $eve->[1]) -> 05:xx local the next day");
    }
    fresh();
    night();
    ok(scalar(grep { $_->[0] > $NOW + 3600 } @TIMERS), '10: a run arms the next 05:00');
}

# 11. Already held at 05:00 -> no request, and no longer wanted.
{
    fresh();
    $HELD{ keyOf(caa(), $_) } = 1 for ('', '_150x150_f', '_300x300_f', '_600x600_f');
    $C->can('want')->(caa());
    night();
    ok(scalar(!@REQ), '11: every path already held -> nothing fetched');
    later(11);
    ok(scalar(!exists $STORE{+WANT}{ caa() }), '11: ... and it is no longer wanted');
    fresh();
    $HELD{ keyOf(caa(), '') } = 1;
    $C->can('want')->(caa());
    night();
    ok(scalar(@REQ == 3 && !grep { $_->{url} =~ m{/image\.jpg$} } @REQ),
       '11: the unsized one held -> only the three sizes fetched');
}

# 12. The proxy cache unreadable after the fetch -> nothing counted.
{
    fresh();
    $C->can('want')->(caa());
    night();
    $GET_DIES = 1;
    land(caa(), 'placeholder');
    ok(scalar(!exists(($STORE{+MISS} || {})->{ caa() })), '12: cannot ask the cache -> no failure counted');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
