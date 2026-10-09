#!/usr/bin/env perl
#
# The archive covers, loaded IN THE VIEW (Discography/Covers.pm, 0.56.44).
#
# Simon 2026-10-03: the blank tiles "defeat what we are trying to achieve"; they
# should "load albeit slowly in a view", the quickest material first, "when
# backed out it may load them in the bg like LBF does, but a visit to another
# artist must then pause that and move to the opened page", and LBF's scheduler
# "would stop this plugin potentially running out of control". 0.56.26-0.56.43
# showed the type icon and fetched at 05:00 only, because an archive fetch froze
# the whole server; the cause was TLS 1.3 (CLAUDE.md §A3 `THE FREEZE IS TLS
# 1.3`), so Covers now downloads over TLS 1.2 itself and hands the proxy a file.
#
# Drives the REAL Covers.pm against fakes of what it talks to: the image proxy's
# cache, LMS's resizer, SimpleAsyncHTTP (answered by the suite), the file
# system (a temp cache folder), LMS timers and a fake clock. Sections:
#   1  the tile's route; the icon for a cover given up or failed within the hour
#   2  the handler: holds the request, downloads at once over TLS 1.2 at 1200 px,
#      answers a file: url of the saved cover; a kept file answers at once;
#      one download per cover; not ours / given up -> the placeholder
#   3  covers on screen: four at a time, oldest request first, no grace, past
#      the background's width
#   4  the rest of a page: after the grace, not while a page request is out,
#      in page order, two while browsing, eight after the quiet window
#   5  a new page goes to the front; the old page's downloads finish; a cover
#      the device asks again comes to the front
#   6  a landing: no longer wanted, failures cleared, the four sizes cut into the
#      proxy's cache under its own keys, one per turn, the held ones skipped,
#      the file deleted later
#   7  nobody waiting: a cover the proxy holds is not downloaded; an unreadable
#      cache downloads nothing and counts nothing
#   8  failures: one retry, then the placeholder; counted once an hour; the icon
#      for the hour; three counted -> given up 30 days; no route counts
#      nothing; a 200 that is not an image; the watchdog
#   9  the bounds: MAX_JOBS (a waiting device never dropped), BG_TTL, WAIT_MAX,
#      SCAN_BUDGET per turn
#  10  05:00: the wanted ones, newest 300, at the idle width, behind a page
#  11  the 05:00 clock
#  12  the wanted row: one write, pruned, capped, kept over a restart
#  13  init deletes leftover downloads, nothing else
#  14  one wake-up timer, moved earlier when needed
#  15  the source: Plugin.pm registers our route; API::caaImage's url
#  16  at most two device requests held (2026-10-09): the third answered at once
#      with the placeholder, its cover downloaded as one on screen
#  17  Discogs first (2026-10-09): a thumbnail at once, a held request waiting
#      for the artist's list (no archive request, however long it takes; a page
#      that lands may answer it), the archive only once the list is complete
#      without it, a wanted cover not downloaded once Discogs has it
#  18  (review 2026-10-09) the page in front gets the held places: an older
#      page's request still waiting gives its place (the placeholder), a
#      download in flight keeps it; the same page: the cap as before
#
# Standalone, no LMS install needed:  perl tools/t_covers.pl
#
use strict;
use warnings;
use FindBin;
use POSIX ();
use File::Temp ();

our ($NOW, $FG, $NO_PROXY, $GET_DIES, $CACHEDIR, %HELD, %STORE, @REQ, @TIMERS, @RESIZE, @ANS,
     @READS, $SETS, $TID);

BEGIN {
    # A zone WITH summer time, whatever the machine's, so section 11's clock
    # change tests mean something.
    $ENV{TZ} = 'Europe/London'; POSIX::tzset();
    $NOW = 1_800_000_000;
    *CORE::GLOBAL::time = sub () { int $main::NOW };
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Timers Slim::Utils::Misc
                  Slim::Utils::ImageResizer Slim::Web::ImageProxy Slim::Networking::SimpleAsyncHTTP
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

    *{'Slim::Utils::Timers::setTimer'}     = sub { my $id = ++$main::TID; push @main::TIMERS, [ $_[1], $_[2], $id ]; $id };
    *{'Slim::Utils::Timers::killSpecific'} = sub { my $id = $_[0]; @main::TIMERS = grep { $_->[2] != $id } @main::TIMERS; 1 };
    *{'Slim::Utils::Misc::fileURLFromPath'} = sub { 'file://' . $_[0] };

    # The proxy's cache: a hit is any value, as DbCache::get returns.
    *{'Slim::Web::ImageProxy::Cache::new'} = sub {
        die "no cache\n" if $main::NO_PROXY; bless {}, 'Slim::Web::ImageProxy::Cache' };
    *{'Slim::Web::ImageProxy::Cache::get'} = sub {
        push @main::READS, $_[1];
        die "db locked\n" if $main::GET_DIES; $main::HELD{ $_[1] } };

    # LMS's resizer, as sync_resize behaves: the key cached, then the callback.
    *{'Slim::Utils::ImageResizer::resize'} = sub {
        my (undef, $file, $key, $spec, $cb, $cache) = @_;
        push @main::RESIZE, { file => $file, key => $key, spec => $spec, cache => $cache };
        $main::HELD{$key} = 1;
        $cb->() if $cb;
        1 };

    # Outside HTTP: the suite answers each request (answer()).
    *{'Slim::Networking::SimpleAsyncHTTP::new'} = sub {
        my (undef, $ok, $err, $p) = @_; bless { ok => $ok, err => $err, params => $p }, 'Slim::Networking::SimpleAsyncHTTP' };
    *{'Slim::Networking::SimpleAsyncHTTP::get'} = sub {
        my ($self, $url, %h) = @_; push @main::REQ, { %$self, url => $url, headers => \%h }; 1 };

    *{'Plugins::Discography::API::_netFgBusy'} = sub { $main::FG ? 1 : 0 };
    # API.pm's own formula (section 15 checks the source still builds it).
    *{'Plugins::Discography::API::caaImage'} = sub {
        'https://coverartarchive.org/release-group/' . $_[1] . '/front-' . ($_[2] || 250) . '.jpg' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Store' };
}

# A stand-in for Discogs.pm (section 17): the suite says what it knows.
our (%DG_THUMB, %DG_PENDING, %DG_LIST, @DG_WARM, @DG_LISTEN);
{
    package Plugins::Discography::Discogs;
    sub thumbFor { my (undef, $a, $rg) = @_; $main::DG_THUMB{"$a|$rg"} }
    sub pending  { my (undef, $a) = @_; $main::DG_PENDING{$a} ? 1 : 0 }
    sub peekList { my (undef, $a) = @_; $main::DG_LIST{$a} }
    sub listen   { my (undef, $s) = @_; push @main::DG_LISTEN, $s unless grep { $_ == $s } @main::DG_LISTEN }
    sub warm {
        my (undef, $a, $cb) = @_;
        $cb ||= sub {};
        return $cb->() if defined $main::DG_LIST{$a};
        $main::DG_PENDING{$a} = 1;
        push @main::DG_WARM, [ $a, $cb ];
        return;
    }
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}
package T::Prefs; our $AUTOLOAD;
sub get { $_[1] eq 'cachedir' ? $main::CACHEDIR : $_[1] eq 'server_uuid' ? 'uuid-for-the-suite' : undef }
sub AUTOLOAD { return } sub DESTROY {}
package T::Store;
sub get { $main::STORE{ $_[1] } }
sub set { $main::STORE{ $_[1] } = $_[2]; $main::SETS++; 1 }
package T::Http;
sub new { my ($c, $type, $body) = @_; bless { type => $type, body => $body }, $c }
sub headers { bless { type => $_[0]{type} }, 'T::Headers' }
sub contentRef { \$_[0]{body} }
package T::Headers;
sub content_type { $_[0]{type} }

package main;

my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
$CACHEDIR = File::Temp->newdir()->dirname;
mkdir $CACHEDIR;
require Time::HiRes;
{ no warnings qw(redefine prototype once); *Time::HiRes::time = sub { $main::NOW }; }
require Plugins::Discography::Covers;
my $C = 'Plugins::Discography::Covers';
my $DIR = "$CACHEDIR/DiscographyCovers";

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

sub rg { sprintf('%08x-0000-4000-8000-%012x', $_[0], $_[0]) }
sub fresh {
    $C->can('_reset')->();
    %HELD = (); %STORE = (); @REQ = (); @TIMERS = (); @RESIZE = (); @ANS = (); @READS = ();
    $FG = 0; $NO_PROXY = 0; $GET_DIES = 0; $SETS = 0;
    if (opendir my $dh, $DIR) { unlink map { "$DIR/$_" } grep { !/^\./ } readdir $dh }
}
# Fire every timer due by now (a fired timer may arm another: run until none due).
sub tick {
    for (1 .. 200) {
        my @due = sort { $a->[0] <=> $b->[0] } grep { $_->[0] <= $NOW } @TIMERS or return;
        my %fire = map { $_->[2] => 1 } @due;
        @TIMERS = grep { !$fire{ $_->[2] } } @TIMERS;
        $_->[1]->() for @due;
    }
}
sub later { $NOW += $_[0]; tick() }
# A device asks for a size of a cover; its answer lands in @ANS.
sub ask {
    my ($rg, $spec) = @_;
    my $r = $C->can('tileHandler')->("dsc/caa/$rg", $spec // '300x300_f.jpg', sub { push @ANS, [ $rg, $_[0] ] });
    return $r;
}
sub answersFor { map { $_->[1] } grep { $_->[0] eq $_[0] } @ANS }
sub rgOf { $_[0] =~ m{release-group/([0-9a-f-]{36})/} ? $1 : '' }
sub out { map { rgOf($_->{url}) } @REQ }
# Answer the oldest request for a cover: 'ok' (a JPEG), 'html' (a 200 page), or
# an error text.
sub answer {
    my ($rg, $how) = @_;
    my ($i) = grep { rgOf($REQ[$_]{url}) eq $rg } 0 .. $#REQ;
    return 0 unless defined $i;
    my $r = splice @REQ, $i, 1;
    if    ($how eq 'ok')   { $r->{ok}->(T::Http->new('image/jpeg', "JPEG-$rg")) }
    elsif ($how eq 'html') { $r->{ok}->(T::Http->new('text/html', '<html>busy</html>')) }
    else                   { $r->{err}->(undef, $how) }
    return 1;
}
sub night { $C->can('_nightTick')->(); tick() }
sub snap { $C->can('_snapshot')->() }
sub key { my ($rg, $spec) = @_; "imageproxy/dsc/caa/$rg/image" . ($spec // '') . '.jpg' }
use constant WANT => 'dsc:cvwant:v2';
use constant MISS => 'dsc:cvmiss:v2';
my @SPECS = ('', '_150x150_f', '_300x300_f', '_600x600_f');

# 1. The tile's route; the icon (undef) for a cover given up or just failed.
{
    fresh();
    # The failure row as a restart finds it (the module reads it once).
    $STORE{+MISS} = { rg(2) => [ int($NOW) - 60, 3 ], rg(3) => [ int($NOW) - 60, 1 ], rg(4) => [ int($NOW) - 3601, 1 ],
                      rg(5) => [ int($NOW) - 7200, 3 ] };
    my $t = $C->can('tileImage');
    ok(scalar(($t->(uc rg(0xabcdef)) // '') eq 'imageproxy/dsc/caa/' . rg(0xabcdef) . '/image.jpg'),
       '1: a group -> imageproxy/dsc/caa/<group, lowercased>/image.jpg');
    ok(scalar(!defined $t->('not-an-mbid') && !defined $t->(undef) && !defined $t->('')), '1: not a group mbid -> undef');
    ok(scalar(!defined $t->(rg(2))), '1: given up (three counted failures) -> undef (the type icon)');
    ok(scalar(!defined $t->(rg(5))), '1: given up two hours ago -> still undef (30 days, not the hour)');
    ok(scalar(!defined $t->(rg(3))), '1: failed a minute ago -> undef for the hour');
    ok(scalar(defined $t->(rg(4))), '1: failed over an hour ago -> the route again');
}

# 2. The handler.
{
    fresh();
    $C->can('noteBrowse')->();     # inside the page's grace,
    $FG = 1;                       # and a page request out: a cover on screen waits for neither
    my $r = ask(rg(1));
    ok(scalar(!defined $r && !@ANS), '2: a request is held (undef), nothing answered yet');
    tick();
    ok(scalar(@REQ == 1 && $REQ[0]{url} eq 'https://coverartarchive.org/release-group/' . rg(1) . '/front-1200.jpg'),
       '2: one download at once, the 1200 px archive cover');
    ok(scalar(($REQ[0]{params}{options}{SSL_version} // '') eq 'TLSv1_2'), '2: ... over TLS 1.2 (the freeze is TLS 1.3)');
    ok(scalar(($REQ[0]{params}{timeout} // 0) == 30), "2: ... with the proxy's own 30 s timeout");
    ask(rg(1), '150x150_f.jpg');
    tick();
    ok(scalar(@REQ == 1), '2: a second size asked while it downloads -> no second download');
    answer(rg(1), 'ok');
    my @a = answersFor(rg(1));
    ok(scalar(@a == 2 && !grep { $_ ne "file://$DIR/" . rg(1) . '.jpg' } @a),
       '2: both requests answered with a file: url of the saved cover');
    my $body = do { local $/; open my $fh, '<', "$DIR/" . rg(1) . '.jpg' or die; <$fh> };
    ok(scalar($body eq 'JPEG-' . rg(1)), '2: the file holds the downloaded bytes, whole (no .part left)');
    ok(scalar(!-e "$DIR/" . rg(1) . '.jpg.part'), '2: ... and no .part file');
    @ANS = ();
    $r = ask(rg(1), '600x600_f.jpg');
    ok(scalar(($r // '') eq "file://$DIR/" . rg(1) . '.jpg' && !@REQ),
       '2: another size within the kept time -> the file at once, no download');
    later(121);
    ok(scalar(!-e "$DIR/" . rg(1) . '.jpg'), '2: the file is deleted after 120 s');
    $r = ask(rg(1), '600x600_f.jpg');
    tick();
    ok(scalar(!defined $r && @REQ == 1), '2: after that, a request downloads again');
    ok(scalar((ask('dsc/caa/not-ours') // 'undef') eq '' && ($C->can('tileHandler')->('coverartarchive.org/x', '', sub {}) // 'undef') eq ''),
       "2: not our route -> '' (the proxy's placeholder, never cached)");
    $STORE{+MISS} = { rg(9) => [ int($NOW) - 7200, 3 ] };
    $C->can('_reset')->();
    @REQ = ();
    ok(scalar((ask(rg(9)) // 'undef') eq '' && do { tick(); !@REQ }), "2: a given-up cover (last failure 2 h ago) -> '', nothing downloaded");

    # A background job while the file of a moment ago is kept: no second download.
    fresh();
    ask(rg(7));
    tick();
    answer(rg(7), 'ok');
    %HELD = ();                                     # as if a size were still being cut
    $C->can('want')->(rg(7));
    tick();
    ok(scalar(!@REQ), '2: wanted again while its file is kept -> not downloaded again');

    # The file is replaced by a rename: a reader in another process (LMS's
    # resizer daemon) holding the old one still reads it whole.
    fresh();
    mkdir $DIR;
    open my $old, '>', "$DIR/" . rg(8) . '.jpg' or die; print $old 'OLD'; close $old;
    open my $reader, '<', "$DIR/" . rg(8) . '.jpg' or die;
    $C->can('_saveFile')->(rg(8), \'NEW');
    my $seen = do { local $/; <$reader> };
    my $now  = do { local $/; open my $fh, '<', "$DIR/" . rg(8) . '.jpg' or die; <$fh> };
    ok(scalar($seen eq 'OLD' && $now eq 'NEW'), '2: a save replaces the file whole (an open reader keeps the old one)');
    ok(scalar((($C->can('tileHandler')->('dsc/caa/' . rg(10), '', undef)) // 'undef') eq ''),
       "2: no callback to answer later -> '' rather than a request that never ends");
}

# 3. Covers on screen: four at a time, oldest request first.
{
    fresh();
    for my $i (1 .. 6) { ask(rg($i)); $NOW += 0.01 }
    tick();
    ok(scalar(join(',', out()) eq join(',', map { rg($_) } 1 .. 4)), '3: six asked -> the four oldest download');
    answer(rg(2), 'ok');
    tick();
    ok(scalar(join(',', out()) eq join(',', map { rg($_) } 1, 3, 4, 5)), '3: one lands -> the fifth starts');
    fresh();
    $C->can('noteBrowse')->();
    $C->can('newPage')->();
    $C->can('want')->(rg($_)) for 10 .. 15;
    later(4);
    ok(scalar(@REQ == 2), '3: (the page fills the browsing width of two)');
    ask(rg(20));
    tick();
    ok(scalar(@REQ == 3 && (out())[2] eq rg(20)), '3: a cover on screen still starts at once, past the background width');
}

# 4. The rest of a page.
{
    fresh();
    $C->can('noteBrowse')->();
    $C->can('newPage')->();
    $C->can('want')->(rg($_)) for 1 .. 5;
    tick();
    ok(scalar(!@REQ), '4: wanted inside the grace -> nothing yet');
    later(2);
    ok(scalar(!@REQ), '4: 2 s on -> still nothing');
    $FG = 1;
    later(1.5);
    ok(scalar(!@REQ), '4: grace over but a page request is out -> waiting');
    $FG = 0;
    later(1);
    ok(scalar(join(',', out()) eq rg(1) . ',' . rg(2)), '4: then two, in page order');
    later(20);
    ok(scalar(@REQ == 5), '4: 20 s without a Discography request -> the idle width takes the rest');
    fresh();
    $C->can('want')->(rg($_)) for 1 .. 10;
    tick();
    ok(scalar(@REQ == 8), '4: nobody browsing -> eight at once');
}

# 5. A new page goes to the front.
{
    fresh();
    $C->can('noteBrowse')->();
    $C->can('newPage')->();
    $C->can('want')->(rg($_)) for 1 .. 6;           # page A
    later(4);
    ok(scalar(join(',', out()) eq rg(1) . ',' . rg(2)), '5: page A: its first two out');
    $C->can('noteBrowse')->();
    $C->can('newPage')->();
    $C->can('want')->(rg($_)) for 101 .. 103;       # page B
    later(4);
    answer(rg(1), 'ok');
    tick();
    ok(scalar((out())[-1] eq rg(101)), "5: one of A's lands -> B's first goes next, not A's third");
    answer(rg(2), 'ok');
    tick();
    answer(rg(101), 'ok');
    tick();
    ok(scalar(join(',', sort(out())) eq join(',', sort(rg(102), rg(103)))), "5: B's page before A's leftovers");
    ok(scalar(answer(rg(102), 'ok') && answer(rg(103), 'ok') && do { tick(); (out())[0] eq rg(3) }),
       "5: B done -> A resumes where it stopped (the background goes on)");
    ok(scalar(-e "$DIR/" . rg(1) . '.jpg' && -e "$DIR/" . rg(2) . '.jpg'), "5: A's downloads out when B opened were finished, not dropped");
    ask(rg(6));
    tick();
    ok(scalar(grep { $_ eq rg(6) } out()), '5: a device asking for one of A\'s covers -> it starts at once');

    # Requests still out from a page the user has left must not hold up the
    # page opened since (a browser need not cancel them).
    fresh();
    $C->can('newPage')->();
    for my $i (1 .. 5) { ask(rg(200 + $i)); $NOW += 0.01 }    # page A: four out, A5 waiting
    tick();
    $C->can('newPage')->();
    ask(rg(300));                                            # page B's tile, asked later
    tick();
    answer(rg(201), 'ok');
    tick();
    ok(scalar((out())[-1] eq rg(300)), "5: a slot frees -> page B's request goes before A's older one");
    fresh();
    $FG = 1;
    $C->can('newPage')->();
    $C->can('want')->(rg($_)) for 1 .. 3;
    $C->can('newPage')->();
    $C->can('want')->(rg(3));                               # shown again on the newer page
    my $s = snap();
    ok(scalar($s->{ rg(3) }{page} > $s->{ rg(1) }{page} && $s->{ rg(3) }{rank} == 0),
       '5: a cover wanted again by a newer page moves to that page');
}

# 6. A landing.
{
    fresh();
    $STORE{+MISS} = { rg(1) => [ int($NOW) - 7200, 1 ] };    # failed once, long ago
    $C->can('want')->(rg(1));
    ask(rg(1));
    tick();
    answer(rg(1), 'ok');
    ok(scalar(@RESIZE == 1), '6: the first size is cut in the same turn ...');
    tick();
    ok(scalar(@RESIZE == 4), '6: ... the next ones a turn each (four in all)');
    ok(scalar(join(',', map { $_->{key} } @RESIZE) eq join(',', map { key(rg(1), $_) } @SPECS)),
       "6: under the proxy's own keys: imageproxy/dsc/caa/<group>/image<spec>.jpg");
    ok(scalar(join(',', map { $_->{spec} } @RESIZE) eq '.jpg,150x150_f.jpg,300x300_f.jpg,600x600_f.jpg'),
       '6: with the spec Slim::Web::Graphics reads from that name');
    ok(scalar(!grep { $_->{file} ne "$DIR/" . rg(1) . '.jpg' || ref $_->{cache} ne 'Slim::Web::ImageProxy::Cache' } @RESIZE),
       "6: cut from the saved file, into the proxy's cache");
    ok(scalar(!exists $STORE{+MISS}{ rg(1) }), '6: its failure count is cleared');
    later(11);
    ok(scalar(!exists(($STORE{+WANT} || {})->{ rg(1) })), '6: and it is no longer wanted');
    fresh();
    $HELD{ key(rg(2), '') } = 1; $HELD{ key(rg(2), '_150x150_f') } = 1;
    ask(rg(2));
    tick();
    answer(rg(2), 'ok');
    tick();
    ok(scalar(join(',', map { $_->{spec} } @RESIZE) eq '300x300_f.jpg,600x600_f.jpg'), '6: sizes the proxy holds are not cut again');
}

# 7. Nobody waiting.
{
    fresh();
    $HELD{ key(rg(1), $_) } = 1 for @SPECS;
    $C->can('want')->(rg(1));
    tick();
    ok(scalar(!@REQ), '7: every size held -> no download');
    later(11);
    ok(scalar(!exists(($STORE{+WANT} || {})->{ rg(1) })), '7: ... and no longer wanted');
    fresh();
    $HELD{ key(rg(1), $_) } = 1 for '', '_150x150_f';
    $C->can('want')->(rg(1));
    tick();
    ok(scalar(@REQ == 1), '7: a size missing -> downloaded (one download for the missing sizes)');
    fresh();
    $NO_PROXY = 1;
    $C->can('want')->(rg(2));
    tick();
    later(11);
    ok(scalar(!@REQ && !exists(($STORE{+MISS} || {})->{ rg(2) }) && exists $STORE{+WANT}{ rg(2) }),
       '7: the proxy cache cannot be opened -> nothing downloaded, nothing counted, still wanted');
}

# 8. Failures.
{
    fresh();
    ask(rg(1));
    tick();
    answer(rg(1), '500 Internal Server Error');
    ok(scalar(!@ANS && !@REQ), '8: a first failure -> nobody answered yet');
    later(1);
    ok(scalar(!@REQ), '8: ... no retry within 2 s');
    later(1.5);
    ok(scalar(@REQ == 1 && rgOf($REQ[0]{url}) eq rg(1)), '8: ... then once more');
    answer(rg(1), '404 Not Found');
    ok(scalar(join(',', answersFor(rg(1))) eq ''  && @ANS == 1), "8: the second fails -> the device gets '' (the placeholder)");
    my $m = $STORE{+MISS}{ rg(1) };
    ok(scalar(ref $m eq 'ARRAY' && $m->[1] == 1 && $m->[0] == int $NOW), '8: one failure counted, now');
    ok(scalar(!defined $C->can('tileImage')->(rg(1))), '8: the tile shows its icon for the hour');
    ok(scalar((ask(rg(1)) // 'undef') eq '' && do { tick(); !@REQ }), "8: a request within the hour -> '', nothing downloaded");
    $C->can('want')->(rg(1));
    tick();
    ok(scalar(!@REQ), '8: wanted within the hour -> not queued');
    later(3601);
    ok(scalar(defined $C->can('tileImage')->(rg(1))), '8: an hour on -> the route again');

    fresh();
    my $note = $C->can('_missNote');
    $note->(rg(2), 1);
    later(600);
    $note->(rg(2), 1);
    ok(scalar($STORE{+MISS}{ rg(2) }[1] == 1), '8: two failures 10 minutes apart count once');
    later(3600);
    $note->(rg(2), 1);
    ok(scalar($STORE{+MISS}{ rg(2) }[1] == 2), '8: an hour after the last, the next counts');
    later(3600);
    $note->(rg(2), 1);
    ok(scalar(!defined $C->can('tileImage')->(rg(2)) && (ask(rg(2)) // 'undef') eq ''),
       '8: three counted -> given up: the icon, and a request gets the placeholder');
    $C->can('want')->(rg(2));
    later(11);
    ok(scalar(!exists(($STORE{+WANT} || {})->{ rg(2) })), '8: ... and a visit does not record it');
    later(7200);
    ok(scalar(!defined $C->can('tileImage')->(rg(2)) && (ask(rg(2)) // 'undef') eq ''),
       '8: two hours on, still given up (30 days, not the hour)');
    $C->can('want')->(rg(2));
    later(11);
    ok(scalar(!exists(($STORE{+WANT} || {})->{ rg(2) }) && !keys %{ snap() }), '8: ... and still not recorded or queued by a visit');
    later(30 * 86400 + 1);
    ok(scalar(defined $C->can('tileImage')->(rg(2))), '8: 30 days on -> the route again');

    fresh();
    ask(rg(3));
    tick();
    answer(rg(3), "Couldn't resolve IP address for: coverartarchive.org");
    later(2.5);
    answer(rg(3), "Couldn't resolve IP address for: coverartarchive.org");
    $m = $STORE{+MISS}{ rg(3) };
    ok(scalar(ref $m eq 'ARRAY' && $m->[1] == 0), '8: archive.org not reached at all -> no failure counted');
    ok(scalar(!defined $C->can('tileImage')->(rg(3))), '8: ... but the icon for the hour all the same');

    fresh();
    ask(rg(4));
    tick();
    answer(rg(4), 'html');
    later(2.5);
    answer(rg(4), 'html');
    ok(scalar(($STORE{+MISS}{ rg(4) } || [])->[1] == 1 && join(',', answersFor(rg(4))) eq ''),
       '8: a 200 that is not an image is a failure');

    fresh();
    ask(rg(5));
    tick();
    later(150);
    ok(scalar(@REQ == 1), '8: no answer at all -> the watchdog fails it ...');
    later(2.5);
    ok(scalar(@REQ == 2), '8: ... and it is asked once more');
    later(150);
    ok(scalar(join(',', answersFor(rg(5))) eq '' && @ANS == 1), "8: twice silent -> the device gets ''");
    answer(rg(5), 'ok');
    ok(scalar(@ANS == 1 && !-e "$DIR/" . rg(5) . '.jpg'), '8: an answer after the watchdog is ignored');
}

# 9. The bounds.
{
    fresh();
    for my $i (1 .. 5) { ask(rg($i)); $NOW += 0.01 }
    tick();                                          # four out, the fifth asked (past the cap)
    $C->can('newPage')->();
    $C->can('want')->(rg(1000 + $_)) for 1 .. 450;
    my $s = snap();
    ok(scalar(keys %$s <= 400), '9: 450 wanted -> at most 400 queued (got ' . scalar(keys %$s) . ')');
    ok(scalar($s->{ rg(5) } && !$s->{ rg(5) }{running}), '9: ... the cover a device asked for past the cap is kept');
    ok(scalar($s->{ rg(1001) } && !$s->{ rg(1450) }), "9: ... the page's last ones went, its first stayed");
    later(11);
    ok(scalar(exists $STORE{+WANT}{ rg(1450) }), '9: a dropped one is still wanted (05:00)');

    fresh();
    $FG = 1;                                         # a page request out for ever: nothing launches
    $C->can('want')->(rg($_)) for 1 .. 3;
    later(10);
    ok(scalar(keys %{ snap() } == 3), '9: background held up -> queued');
    later(3601);
    ok(scalar(!keys %{ snap() } && exists $STORE{+WANT}{ rg(1) }),
       '9: not reached within the hour -> dropped from the queue, still wanted');

    # WAIT_MAX: a HELD request whose download cannot start (the four on-screen
    # slots taken by covers asked past the cap) gets the placeholder at 90 s.
    fresh();
    for my $i (1 .. 6) { ask(rg($i)); $NOW += 0.01 }
    tick();
    answer(rg(1), 'ok'); answer(rg(2), 'ok');      # the two held ones land
    tick();                                          # 3-6 out, nobody held
    ask(rg(7));                                      # held, no slot
    tick();
    ok(scalar(snap()->{ rg(7) }{waiters} == 1 && !snap()->{ rg(7) }{running}), '9: a held cover with no free slot waits');
    later(91);
    ok(scalar(join(',', answersFor(rg(7))) eq ''  && scalar(answersFor(rg(7))) == 1),
       "9: ... and at 90 s gets '' (the placeholder)");
    $s = snap();
    ok(scalar($s->{ rg(7) } && !$s->{ rg(7) }{waiters}),
       '9: ... and its cover stays queued for the background');

    fresh();
    for my $i (1 .. 300) { $HELD{ key(rg($i), $_) } = 1 for @SPECS }
    $C->can('want')->(rg($_)) for 1 .. 300;
    @READS = ();
    $C->can('_tick')->();
    ok(scalar(@READS <= 100 && keys %{ snap() } == 275),
       '9: 300 held covers -> 25 looked at in one turn (' . scalar(@READS) . ' cache reads)');
    tick() for 1 .. 20;
    later(11);
    ok(scalar(!keys %{ snap() } && !keys %{ $STORE{+WANT} || {} } && !@REQ), '9: ... and the rest across the next turns');
}

# 10. 05:00.
{
    fresh();
    my $now = int $NOW;
    $STORE{+WANT} = { map { (rg(2000 + $_) => $now - 1000 + $_) } 1 .. 305 };
    night();
    my $s = snap();
    ok(scalar(keys %$s == 300 && !grep { $_->{page} != -1 } values %$s), '10: 305 wanted -> 300 queued for the night');
    ok(scalar(!$s->{ rg(2001) } && !$s->{ rg(2005) } && $s->{ rg(2006) } && $s->{ rg(2305) }),
       '10: ... the newest 300; the five oldest wait');
    ok(scalar(@REQ == 8 && (out())[0] eq rg(2305)), '10: nobody browsing -> eight at once, newest first');
    $C->can('noteBrowse')->();
    $C->can('newPage')->();
    $C->can('want')->(rg(9999));
    later(4);
    # Browsing: the width is two, so nothing new goes out until the night's
    # eight are down to one; the first to go then is the page's.
    for (1 .. 8) {
        last if grep { $_ eq rg(9999) } out();
        answer((out())[0], 'ok');
        tick();
    }
    ok(scalar(@REQ == 2 && (out())[-1] eq rg(9999)),
       "10: a page opened during the night run goes before the night's queue (at the browsing width)");
    ok(scalar(grep { $_->[0] > $NOW + 3600 } @TIMERS), '10: the run arms the next 05:00');

    fresh();
    $now = int $NOW;
    $FG = 1;                                         # a page's leftovers, held up
    $C->can('newPage')->();
    $C->can('want')->(rg(500 + $_)) for 1 .. 10;
    $STORE{+WANT} = { %{ $STORE{+WANT} || {} }, map { (rg(600 + $_) => $now + $_) } 1 .. 5 };
    night();
    $FG = 0;
    later(1);
    ok(scalar(@REQ == 8 && !grep { $_ !~ /^000001f/ } out()),
       "10: the night's covers go after a page's leftovers (all eight out are the page's)");

    fresh();
    $now = int $NOW;
    $STORE{+WANT} = { rg(1) => $now - 5, rg(2) => $now - 5, rg(3) => $now - 5 };
    $STORE{+MISS} = { rg(1) => [ $now - 7200, 3 ], rg(2) => [ $now - 60, 1 ] };
    $C->can('noteBrowse')->();
    night();
    later(4);
    ok(scalar(join(',', out()) eq rg(3)), '10: given up or failed within the hour -> not asked; browsing -> the browsing width');
}

# 11. The 05:00 clock.
{
    fresh();
    my $j  = $C->can('_jitter')->();
    my $at = sub { my @t = localtime($_[0]); POSIX::mktime($j, 0, 5, $t[3] + $_[1], $t[4], $t[5], 0, 0, -1) };
    my $base = POSIX::mktime(0, 0, 3, 15, 0, 126, 0, 0, -1);           # 2026-01-15 03:00 local
    my $s = $C->can('_secsUntilNight')->($base);
    ok(scalar($base + $s == $at->($base, 0)), '11: at 03:00 -> today 05:00 + offset');
    my $five = $at->($base, 0);
    ok(scalar($five + $C->can('_secsUntilNight')->($five) == $at->($base, 1)),
       '11: AT the instant -> tomorrow (strictly future, no refire loop)');
    ok(scalar($j >= 0 && $j < 1800 && $j == $C->can('_jitter')->()), '11: the offset is under 30 min and stable');
    for my $eve ([ 28, 2 ], [ 24, 9 ]) {
        my $b = POSIX::mktime(0, 0, 20, $eve->[0], $eve->[1], 126, 0, 0, -1);
        my @t = localtime($b + $C->can('_secsUntilNight')->($b));
        ok(scalar($t[2] == 5 && $t[3] == $eve->[0] + 1),
           "11: across a clock change (month $eve->[1]) -> 05:xx local the next day");
    }
}

# 12. The wanted row.
{
    fresh();
    my $at = int $NOW;
    $FG = 1;
    $C->can('want')->(rg($_)) for 1 .. 3;
    later(11);
    ok(scalar($SETS == 1 && ($STORE{+WANT}{ rg(1) } // 0) == $at), '12: three wants -> one write, with their time');
    $C->can('_reset')->();                          # a restart: the row is in the store
    @REQ = (); $FG = 0;
    night();
    ok(scalar(@REQ == 3), '12: after a restart the night asks for them');
    fresh();
    my $now = int $NOW;
    $STORE{+WANT} = { rg(1) => $now - 31 * 86400, rg(2) => $now - 86400 };
    $FG = 1;
    $C->can('want')->(rg(3));
    later(11);
    ok(scalar(!exists $STORE{+WANT}{ rg(1) } && exists $STORE{+WANT}{ rg(2) }), '12: a want not seen for 30 days is dropped');
    fresh();
    $now = int $NOW;
    $STORE{+WANT} = { map { (rg(10000 + $_) => $now - 10000 + $_) } 1 .. 5003 };
    $FG = 1;
    $C->can('want')->(rg(99999));
    later(11);
    my $row = $STORE{+WANT};
    ok(scalar(keys %$row == 5000 && exists $row->{ rg(99999) } && !exists $row->{ rg(10004) } && exists $row->{ rg(10005) }),
       '12: past 5,000 the oldest are dropped');
}

# 13. init deletes leftover downloads, nothing else.
{
    fresh();
    mkdir $DIR;
    for my $f (rg(1) . '.jpg', rg(2) . '.jpg.part', 'notes.txt') { open my $fh, '>', "$DIR/$f" or die; print $fh 'x'; close $fh }
    $C->can('init')->();
    ok(scalar(!-e "$DIR/" . rg(1) . '.jpg' && !-e "$DIR/" . rg(2) . '.jpg.part' && -e "$DIR/notes.txt"),
       "13: init deletes our leftover files and leaves anything else");
    unlink "$DIR/notes.txt";
    ok(scalar(grep { $_->[0] > $NOW + 60 } @TIMERS), '13: init arms the 05:00 run');
}

# 14. One wake-up timer, moved earlier when needed.
{
    fresh();
    my $arm = $C->can('_arm');
    $arm->(30);
    my $n = @TIMERS;
    $arm->(40);
    ok(scalar(@TIMERS == $n), '14: a later wake-up than the one armed -> no new timer');
    $arm->(5);
    ok(scalar(@TIMERS == $n && (sort { $a <=> $b } map { $_->[0] } @TIMERS)[0] == $NOW + 5),
       '14: an earlier one replaces it (still one)');
    fresh();
    $C->can('noteBrowse')->();
    $C->can('newPage')->();
    $C->can('want')->(rg($_)) for 1 .. 5;
    later(4);                                        # two out, the pump asleep until the quiet window ends
    ask(rg(50));
    tick();
    ok(scalar(grep { $_ eq rg(50) } out()), '14: a device asking while the pump sleeps -> its download starts now');
}

# 15. The source.
{
    open my $fh, '<', "$FindBin::Bin/../Discography/Plugin.pm" or die "Plugin.pm: $!";
    my $src = do { local $/; <$fh> };
    ok(scalar($src =~ m{match\s*=>\s*qr/\^dsc\\/caa\\//,\s*func\s*=>\s*\\&Plugins::Discography::Covers::tileHandler}),
       '15: Plugin.pm registers qr/^dsc\/caa\// -> Covers::tileHandler');
    ok(scalar($src !~ /match\s*=>\s*qr\/coverartarchive/ && $src !~ /proxyHandler/),
       "15: Plugin.pm no longer registers LBF's coverartarchive.org pattern");
    open $fh, '<', "$FindBin::Bin/../Discography/API.pm" or die "API.pm: $!";
    my $api = do { local $/; <$fh> };
    ok(scalar($api =~ m{CAA_RG_BASE_URL\s*=>\s*'https://coverartarchive\.org/release-group/'}
              && $api =~ m{return CAA_RG_BASE_URL \. \$rgMbid \. '/front-' \. \(\$size \|\| 250\) \. '\.jpg';}),
       '15: API::caaImage builds https://coverartarchive.org/release-group/<group>/front-<size>.jpg, as stubbed here');
}

# 16. At most two device requests held (2026-10-09). A browser keeps about six
#     connections to a server; every held request is one of them, and the alpha
#     tester's taps and Play queued behind the held covers (CLAUDE.md dev log
#     `REPRODUCED with no streaming service`).
{
    fresh();
    ok(scalar(!defined ask(rg(1)) && !defined ask(rg(2))), '16: the first two asked are held (undef)');
    my $r3 = ask(rg(3));
    ok(scalar(defined $r3 && $r3 eq ''), "16: a third is answered at once with '' (the placeholder), not held");
    ok(scalar(snap()->{ rg(3) } && snap()->{ rg(3) }{waiters} == 0), '16: ... its cover is queued, nobody held');
    $C->can('noteBrowse')->();                       # browsing: background work would wait the grace
    tick();
    ok(scalar(join(',', sort(out())) eq join(',', sort map { rg($_) } 1 .. 3)),
       '16: ... and downloads at once as a cover on screen, beside the two held');
    answer(rg(1), 'ok');
    tick();
    ok(scalar((answersFor(rg(1)))[0] =~ /^file:/), '16: a held one gets its file when it lands');
    ok(scalar(!defined ask(rg(4))), '16: ... which frees a place: the next ask is held again');
    my $r5 = ask(rg(5));
    ok(scalar(defined $r5 && $r5 eq ''), '16: ... and the cap is two again');
    answer(rg(3), 'ok');
    tick();
    my @a3 = answersFor(rg(3));
    ok(scalar(@a3 == 0), '16: the one answered early is not answered again when its cover lands (its reply was the return value)');
}

# 17. Discogs first (2026-10-09, Discogs.pm; Simon: "it needs to use discogs first
#     not after CAA"). The artist is noted by tileImage; the stand-in above says
#     what Discogs knows.
{
    my $ART = '11111111-2222-4333-8444-555555555555';
    my $T   = $C->can('tileImage');
    my $dgReset = sub { %DG_THUMB = (); %DG_PENDING = (); %DG_LIST = (); @DG_WARM = (); @DG_LISTEN = () };
    # A page of the artist's list lands: Discogs.pm tells its listeners.
    my $landed = sub { $_->($ART) for @DG_LISTEN };

    fresh(); $dgReset->();
    $T->(rg(1), $ART);
    $DG_THUMB{"$ART|" . rg(1)} = 'https://i.discogs.com/t1.jpg';
    ok(scalar((ask(rg(1)) // '') eq 'https://i.discogs.com/t1.jpg'), '17: a Discogs thumbnail -> handed to the proxy at once');
    tick();
    ok(scalar(!@REQ && !keys %{ snap() }), '17: ... nothing held, nothing asked of the archive');

    fresh(); $dgReset->();
    $DG_THUMB{"$ART|" . rg(1)} = 'https://i.discogs.com/t1.jpg';
    ok(scalar(!defined ask(rg(1))), '17: (control) the same group with no artist noted -> held for the archive');

    fresh(); $dgReset->();
    $STORE{+MISS} = { rg(2) => [ int($NOW) - 60, 3 ] };   # given up on the archive
    $T->(rg(2), $ART);
    $DG_THUMB{"$ART|" . rg(2)} = 'https://i.discogs.com/t2.jpg';
    ok(scalar((ask(rg(2)) // '') eq 'https://i.discogs.com/t2.jpg'), '17: an archive cover given up -> Discogs still answers');

    fresh(); $dgReset->();
    $DG_PENDING{$ART} = 1;
    $T->(rg(3), $ART);
    ok(scalar(!defined ask(rg(3))), "17: the artist's list being read -> held");
    tick();
    ok(scalar(!@REQ), '17: ... the archive not asked while it is read');
    ok(scalar(@DG_WARM == 1 && $DG_WARM[0][0] eq $ART), '17: ... the wait joins the read');
    later(2);
    ok(scalar(!@REQ && !answersFor(rg(3))), '17: ... 2 s on, still waiting');
    $DG_PENDING{$ART} = 0;
    $DG_THUMB{"$ART|" . rg(3)} = 'https://i.discogs.com/t3.jpg';
    $_->[1]->() for @DG_WARM;
    tick();
    ok(scalar(join(',', answersFor(rg(3))) eq 'https://i.discogs.com/t3.jpg' && !@REQ),
       '17: the list lands -> the held request gets the thumbnail; the archive never asked');

    # THE ARCHIVE ONLY ONCE DISCOGS HAS ANSWERED (Simon: "I said dicogs first
    # CAA nex"): no time limit of its own; 0.56.67 went to the archive at 6 s.
    fresh(); $dgReset->();
    $DG_PENDING{$ART} = 1;
    $T->(rg(4), $ART);
    ask(rg(4));
    tick();
    later(6.1);
    ok(scalar(!@REQ), '17: still being read after 6 s -> the archive NOT asked (0.56.67 asked it here)');
    later(30);
    ok(scalar(!@REQ && !answersFor(rg(4))), '17: ... nor 36 s in: the request still waits');
    ok(scalar(@DG_LISTEN == 1), '17: ... the queue listens for the pages that land (once)');
    $DG_THUMB{"$ART|" . rg(4)} = 'https://i.discogs.com/t4.jpg';     # its page lands, the read goes on
    $landed->();
    tick();
    ok(scalar(join(',', answersFor(rg(4))) eq 'https://i.discogs.com/t4.jpg' && !@REQ),
       '17: a page with its thumbnail lands mid-read -> the held request gets it; the archive never asked');

    fresh(); $dgReset->();
    $DG_PENDING{$ART} = 1;
    $T->(rg(9), $ART);
    ask(rg(9));
    tick();
    later(3);
    $landed->();                                      # a page with nothing for it
    tick();
    ok(scalar(!@REQ && !answersFor(rg(9))), '17: a page without it lands -> still waiting, no archive');
    $DG_PENDING{$ART} = 0;                            # the read ends without it
    $_->[1]->() for @DG_WARM;
    tick();
    ok(scalar(grep { $_ eq rg(9) } out()), '17: the list complete without it -> the archive is asked');

    fresh(); $dgReset->();
    $DG_PENDING{$ART} = 1;
    $T->(rg(10), $ART);
    ask(rg(10));
    tick();
    later(91);
    my @a10 = answersFor(rg(10));
    ok(scalar(@a10 == 1 && $a10[0] eq '' && !@REQ),
       '17: a device still waiting at WAIT_MAX -> the placeholder; the archive still not asked');

    fresh(); $dgReset->();
    $DG_LIST{$ART} = [];                              # read: nothing for this group
    $T->(rg(5), $ART);
    ask(rg(5));
    tick();
    ok(scalar(grep { $_ eq rg(5) } out()), '17: the list read with no thumbnail for the group -> the archive at once');

    fresh(); $dgReset->();
    $T->(rg(6), $ART);
    ask(rg(6));
    tick();
    ok(scalar(@DG_WARM == 1 && !@REQ), '17: a list never read -> the first look asks for it, and waits');

    fresh(); $dgReset->();
    $DG_LIST{$ART} = [];
    $T->(rg(7), $ART);
    $C->can('want')->(rg(7));
    $DG_THUMB{"$ART|" . rg(7)} = 'https://i.discogs.com/t7.jpg';    # came after the page wanted it
    later(4);
    ok(scalar(!@REQ && !keys %{ snap() }), '17: a wanted cover with a Discogs thumbnail by launch -> no archive download');
    later(11);
    ok(scalar(!exists(($STORE{+WANT} || {})->{ rg(7) })), '17: ... and no longer wanted for 05:00');
    $DG_THUMB{"$ART|" . rg(8)} = undef;
    $T->(rg(8), $ART);
    $C->can('want')->(rg(8));
    later(4);
    ok(scalar(grep { $_ eq rg(8) } out()), '17: (control) a wanted cover Discogs has nothing for -> downloaded');
}

# 18. The page in front gets the held places (review 2026-10-09, finding 2).
#     Requests a page left behind still hold their browser connections; a
#     request from the page now in front takes a place held by one of them
#     that is still waiting (nothing downloading for it), and that one gets the
#     placeholder (no-cache: drawn again, it is asked again). A download in
#     flight keeps its place: it lands in seconds.
{
    my $ART = '11111111-2222-4333-8444-555555555555';
    my $T   = $C->can('tileImage');
    my $NP  = $C->can('newPage');
    my $dgReset = sub { %DG_THUMB = (); %DG_PENDING = (); %DG_LIST = (); @DG_WARM = (); @DG_LISTEN = () };

    fresh(); $dgReset->();
    $DG_PENDING{$ART} = 1;                            # the artist's list being read
    $NP->();
    $T->($_, $ART) for rg(1), rg(2);
    ask(rg(1)); ask(rg(2));
    tick();
    ok(scalar(!@REQ && snap()->{ rg(1) }{waiters} == 1 && snap()->{ rg(2) }{waiters} == 1),
       '18: (two held on a page, waiting for Discogs, nothing downloading)');
    $NP->();                                          # the user opens another page
    $T->(rg(3), $ART);
    my $r3 = ask(rg(3));
    ok(scalar(!defined $r3), "18: a request from the page in front is held, though the older page's two fill the cap");
    my @a1 = answersFor(rg(1));
    ok(scalar(@a1 == 1 && $a1[0] eq '' && !answersFor(rg(2))),
       "18: ... the older page's oldest request gets the placeholder, and only that one");
    ok(scalar(snap()->{ rg(1) } && snap()->{ rg(1) }{waiters} == 0), '18: ... its cover stays queued (fetched as the page left behind)');
    $T->(rg(4), $ART);
    ask(rg(4));
    my $r5;
    $T->(rg(5), $ART);
    $r5 = ask(rg(5));
    my @a2 = answersFor(rg(2));
    ok(scalar(@a2 == 1 && $a2[0] eq '' && defined $r5 && $r5 eq ''),
       '18: ... the next takes the other place; with none of the older page left, the cap holds');

    # The OLDEST request is the one given up, whatever order the covers were
    # queued in (rg(9) queued first, asked second).
    fresh(); $dgReset->();
    $DG_PENDING{$ART} = 1;
    $NP->();
    $T->($_, $ART) for rg(9), rg(10), rg(11);
    $C->can('want')->(rg(9)); $C->can('want')->(rg(10));
    ask(rg(10)); later(1); ask(rg(9));
    $NP->();
    ask(rg(11));
    my @a10 = answersFor(rg(10));
    ok(scalar(@a10 == 1 && $a10[0] eq '' && !answersFor(rg(9))),
       '18: the request asked first gives its place, not the cover queued first');

    # Same page: the cap as before.
    fresh(); $dgReset->();
    $DG_PENDING{$ART} = 1;
    $NP->();
    $T->($_, $ART) for rg(1), rg(2), rg(3);
    ask(rg(1)); ask(rg(2));
    my $same = ask(rg(3));
    ok(scalar(defined $same && $same eq '' && !answersFor(rg(1)) && !answersFor(rg(2))),
       '18: (control) a third request from the same page -> the placeholder, the two held keep their places');

    # An older page's download in flight keeps its place.
    fresh(); $dgReset->();
    $NP->();
    ask(rg(6)); ask(rg(7));                           # no artist noted: the archive at once
    tick();
    ok(scalar(join(',', sort(out())) eq join(',', sort(rg(6), rg(7)))), '18: (two held, both downloading)');
    $NP->();
    my $r8 = ask(rg(8));
    ok(scalar(defined $r8 && $r8 eq '' && !answersFor(rg(6)) && !answersFor(rg(7))),
       '18: an older page whose two are downloading -> they keep their places, the new one gets the placeholder');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
