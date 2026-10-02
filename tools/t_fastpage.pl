#!/usr/bin/env perl
#
# THE ARTIST PAGE'S FIRST LIST (0.56.7; docs/mb-efficiency-and-community-api-
# analysis.md §A16, route A).
#
# A big artist's cold page was 13 MusicBrainz requests in a row and drew at 15 s
# (Bob Dylan). It now draws from ListenBrainz's list of every group the artist is
# credited on and the community API's groups with their releases' statuses, one
# request each, off the MusicBrainz queue; MusicBrainz completes the list after
# the page is drawn, as background work, for the next entry.
#
# What this pins, on the REAL API.pm (the queue bypassed: t_netqueue.pl owns
# it; the page's chain end to end is t_chain.pl §8-§9):
#   1. ListenBrainz's reply: the spine's shape, the echo check, an empty list as
#      no list, a long one taken (no ceiling since 0.56.8), a failure as no list,
#      failFast;
#   2. the community's reply: the echo check, the verdict rule (official if any
#      release is or has no status), no verdict without releases, the release
#      map, the name in the path;
#   3. the two together: the union, sorted; the community's groups without
#      releases (merged-away ids) left out; what is cached; either failing
#      leaves nothing cached and is answered at once (no wait for the other);
#      a special-purpose artist (Various Artists) asks neither;
#   4. getReleaseGroups(read => 1): the read's whole list first; the first list
#      for 25 or more; a Refresh or `force` takes the browse; an expired spine
#      takes MusicBrainz's completed list with no request;
#   5. warmOfficial on a first list: the community's verdicts, at most two by-id
#      requests before the draw and the rest after it, in the background, merged
#      for the next visit (never into a map a Refresh cleared); an expired map
#      under a list past MusicBrainz's cap asks the community again; without
#      either, every group by id as before;
#   6. completeArtist: background requests; MusicBrainz's entries win; the
#      newest added; the first list's own groups kept only past a cut browse;
#      aliases pruned over the whole; verdicts merged; nothing stored on a
#      failure or after a Refresh; one at a time;
#   7. promoteCompleted and clearArtistCache's keys and Refresh marker;
#   8. a Refresh past the cap (0.56.8): ListenBrainz and the community API asked
#      once the browse's count says it will be cut, alongside its remaining
#      pages; the groups past the cap kept with the community's verdicts for
#      those groups only; MusicBrainz's own still asked by id; either source
#      failing, MusicBrainz's list alone; no ceiling; merged-away ids left out;
#      Various Artists asks nothing at all, not even its 600 (0.56.41); MusicBrainz's own groups all checked before
#      the draw, the kept ones bounded.
#
# Standalone -- no LMS install needed:  perl tools/t_fastpage.pl
#
use strict;
use warnings;
use FindBin;
use JSON::XS ();

my %CACHE;
our %TTLS;          # key => the lifetime it was stored with (0.56.40)
our @SENT;           # [ url, \%opt ]
our @DEFERRED;
our @DEFURL;         # the url of each deferred reply, in step
our $DEFER = 0;
our $MB_BASE = 'https://musicbrainz.org/ws/2/';
our %REPLY;          # url prefix => reply | 'ERROR'

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::Timers Slim::Networking::SimpleAsyncHTTP
                  Slim::Utils::Strings Slim::Utils::PluginManager
                  Slim::Control::Request Slim::Schema
                  JSON::XS::VersionOneAndTwo Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Cache' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Cache' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Utils::Timers::setTimer'}   = sub { $_[2]->() };
    *{'Slim::Utils::Timers::killTimers'} = sub { 1 };
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { JSON::XS::encode_json($_[0]) };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { JSON::XS::decode_json($_[0]) };
    *{'Slim::Schema::find'} = sub { undef };
    *{'Slim::Schema::rs'}   = sub { bless {}, 'T::RS' };
    *{'Slim::Control::Request::executeRequest'} = sub { undef };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs JSON::XS::VersionOneAndTwo)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
    @{'JSON::XS::VersionOneAndTwo::EXPORT'} = qw(to_json from_json);
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Cache;
sub get    { return $CACHE{ $_[1] } }
sub set    { $CACHE{ $_[1] } = $_[2]; $main::TTLS{ $_[1] } = $_[3]; return 1 }
sub remove { delete $CACHE{ $_[1] }; return 1 }
package T::Prefs;
sub get { return $_[1] eq 'mb_base_url' ? $main::MB_BASE : undef }
sub set { 1 } sub init { 1 } sub setChange { 1 }
package T::RS;
sub search { bless {}, 'T::RS' }
sub all    { () }
package T::Resp;
sub new     { my ($c, $b) = @_; bless { b => $b }, $c }
sub content { $_[0]{b} }
sub error   { 'stub error' }
sub code    { 500 }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
require Plugins::Discography::API;
my $A = 'Plugins::Discography::API';

{
    no strict 'refs'; no warnings 'redefine';
    *{"${A}::_netGet"} = sub {
        my ($url, $ok, $err, %opt) = @_;
        push @SENT, [ $url, \%opt ];
        my $fire = sub {
            my ($hit) = grep { index($url, $_) == 0 } sort { length $b <=> length $a } keys %REPLY;
            my $r = defined $hit ? $REPLY{$hit} : undef;
            return $err->(T::Resp->new(''), 'stub error', T::Resp->new(''))
                if !defined $r || (!ref $r && $r eq 'ERROR');
            $r = $r->($url) if ref $r eq 'CODE';
            return $err->(T::Resp->new(''), 'stub error', T::Resp->new('')) if !ref $r && $r eq 'ERROR';
            $ok->(T::Resp->new(JSON::XS::encode_json($r)));
        };
        if ($DEFER) { push @DEFERRED, $fire; push @DEFURL, $url } else { $fire->() }
    };
}
sub step  { my @d = @DEFERRED; @DEFERRED = (); @DEFURL = (); $_->() for @d; return scalar @d }
# Fire only the deferred replies whose url matches; the rest wait.
sub step_only {
    my ($re) = @_;
    my (@run, @keep, @keepu);
    for my $i (0 .. $#DEFERRED) {
        if ($DEFURL[$i] =~ $re) { push @run, $DEFERRED[$i] }
        else                    { push @keep, $DEFERRED[$i]; push @keepu, $DEFURL[$i] }
    }
    @DEFERRED = @keep; @DEFURL = @keepu;
    $_->() for @run;
    return scalar @run;
}
sub flush { for (1 .. 50) { last unless step() } }

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}
sub section {
    my ($n, $code) = @_;
    eval { $code->(); 1 } or do { (my $e = $@) =~ s/\s+/ /g; ok(0, "$n: the section died: $e") };
}
sub cold { %CACHE = (); @SENT = (); @DEFERRED = (); @DEFURL = (); %REPLY = (); $DEFER = 0 }
sub sent { my ($re) = @_; scalar grep { $_->[0] =~ $re } @SENT }
sub opts_of { my ($re) = @_; my ($s) = grep { $_->[0] =~ $re } @SENT; $s ? $s->[1] : {} }

sub id { sprintf('%08x-0000-4000-8000-%012x', 0x5000 + $_[0], $_[0]) }
my $ART = 'a74b1b7f-71a5-4011-9441-d0b5e4122711';
my $LBQ = 'https://api.listenbrainz.org/1/metadata/artist/?artist_mbids=' . $ART . '&inc=release_group';
my $CMQ = 'https://api.lms-community.org/music/artist/';
my $BRQ = $MB_BASE . 'release-group?artist=' . $ART . '&';
my $IDQ = $MB_BASE . 'release-group?query=';
my $RDQ = $MB_BASE . 'artist/' . $ART . '?';
my $RG   = 'dsc:rg:v2:' . $ART;
my $FAST = 'dsc:rgfast:1:' . $ART;
my $NEXT = 'dsc:rgnext:1:' . $ART;
my $FULL = 'dsc:rgfull:1:' . $ART;
my $CMD  = 'dsc:cmdisco:1:' . $ART;
my $OFF  = 'dsc:rgo:v5:' . $ART;

# ListenBrainz: groups 1-$n, the odd ones with no type/date/secondary keys.
sub lb_reply {
    my ($n, %o) = @_;
    return [ { artist_mbid => $o{echo} // $ART, name => 'Radiohead', release_group => [ map {
        $_ % 2
          ? { mbid => id($_), name => "G$_" }
          : { mbid => id($_), name => "G$_", type => 'Album', date => '2001-02', secondary_types => ['Live'] }
    } 1 .. $n ] } ];
}
# The community: groups @ids with releases as given (status per release).
sub cm_reply {
    my (%g) = @_;
    my $echo = delete $g{_echo};
    return { mbid => $echo // $ART, name => 'Radiohead', discography => [ map {
        { mbid => id($_), title => "G$_", primary_type => 'Album', release_date => '2001',
          (ref $g{$_} eq 'HASH' ? (releases => $g{$_}) : ()) }
    } sort { $a <=> $b } keys %g ] };
}
# The by-id search: every asked id official, one release each.
sub byid_reply {
    my ($url) = @_;
    my @ids = $url =~ /rgid%3A([0-9a-f-]+)/g;
    return { count => scalar @ids, 'release-groups' => [ map {
        { id => $_, count => 1, releases => [ { id => "$_-mb", title => "Edition of $_", status => 'Official' } ] }
    } @ids ] };
}
# The read: 25 groups listed (MusicBrainz's cap), so no whole list.
sub read_reply {
    return { id => $ART, name => 'Radiohead', aliases => [], relations => [],
             'release-groups' => [ map { { id => id($_), title => "G$_" } } 1 .. 25 ] };
}

section('1', sub {
    # 1. LISTENBRAINZ'S LIST.
    my $f = $A->can('_lbGroups');
    cold(); $REPLY{$LBQ} = lb_reply(4);
    my $got; $f->($ART, sub { $got = shift });
    ok(ref $got eq 'ARRAY' && @$got == 4, '1: every group of the reply');
    my %by = map { $_->{mbid} => $_ } @{ $got || [] };
    ok(($by{ id(2) }{type} // '') eq 'Album' && ($by{ id(2) }{date} // '') eq '2001-02'
       && "@{ $by{ id(2) }{secondary} || [] }" eq 'Live' && ($by{ id(2) }{title} // '') eq 'G2',
       "1: the spine's shape: title, type, date, secondary types");
    ok(exists $by{ id(1) } && $by{ id(1) }{type} eq '' && $by{ id(1) }{date} eq ''
       && ref $by{ id(1) }{secondary} eq 'ARRAY' && !@{ $by{ id(1) }{secondary} } && !exists $by{ id(1) }{aliases},
       '1: absent fields are empty, as the browse leaves them; no aliases');
    my $o = opts_of(qr/listenbrainz/);
    ok($o->{failFast} && ($o->{timeout} // 0) == $A->can('FAST_TIMEOUT')->(), '1: sent failFast, with its own timeout');

    cold(); $REPLY{$LBQ} = lb_reply(4, echo => id(99)); undef $got; my $called = 0;
    $f->($ART, sub { $got = shift; $called++ });
    ok($called == 1 && !defined $got, '1: an answer for another artist is no list');
    cold(); $REPLY{$LBQ} = lb_reply(0); undef $got;
    $f->($ART, sub { $got = shift });
    ok(!defined $got, '1: an empty list is no list (the tag check reads an empty spine as a wrong tag)');
    cold(); $REPLY{$LBQ} = lb_reply(2500); undef $got;
    $f->($ART, sub { $got = shift });
    ok(ref $got eq 'ARRAY' && @$got == 2500,
       '1: a long list is taken: no ceiling (The Rolling Stones, 1,904, took the 15 s path on 0.56.7)');
    ok(!$A->can('FAST_RG_MAX'), '1: ... and the ceiling constant is gone');
    cold(); $REPLY{$LBQ} = 'ERROR'; $called = 0;
    $f->($ART, sub { $got = shift; $called++ });
    ok($called == 1 && !defined $got, '1: a failed request is no list, answered once');
});

section('2', sub {
    # 2. THE COMMUNITY'S LIST AND VERDICTS.
    my $f = $A->can('_hostedDisco');
    cold();
    $CACHE{ 'dsc:mbname:1:' . $ART } = 'Radiohead';
    $REPLY{$CMQ} = cm_reply(1 => { 'r1a' => 'Official', 'r1b' => 'Bootleg' },
                            2 => { 'r2' => 'Bootleg' },
                            3 => { 'r3' => undef },
                            4 => undef);
    my $got; $f->($ART, sub { $got = shift });
    my ($url) = map { $_->[0] } @SENT;
    ok(($url // '') =~ m{/artist/Radiohead/discography\?mbid=\Q$ART\E&withReleases=1$},
       "2: one request, MusicBrainz's name in the path, the mbid and the release statuses asked for");
    ok(ref $got eq 'HASH' && @{ $got->{groups} } == 4, '2: every group of the reply');
    ok(($got->{o}{ id(1) } // -1) == 1, '2: official if any release is');
    ok(($got->{o}{ id(2) } // -1) == 0, '2: bootleg-only when none is');
    ok(($got->{o}{ id(3) } // -1) == 1, '2: a release with no status counts as official (the check fails open)');
    ok(!exists $got->{o}{ id(4) }, '2: a group listed without releases has no verdict');
    ok(($got->{r}{r1b} // '') eq id(1) && ($got->{r}{r2} // '') eq id(2), '2: every release maps to its group');
    ok(opts_of(qr/lms-community/)->{failFast}, '2: sent failFast');

    cold(); $REPLY{$CMQ} = cm_reply(1 => { r => 'Official' });
    $f->($ART, sub { $got = shift });
    ok(($SENT[0][0] // '') =~ m{/artist/_/discography\?}, '2: no name known: the placeholder in the path');
    cold(); $REPLY{$CMQ} = cm_reply(1 => { r => 'Official' }, _echo => id(77)); undef $got;
    $f->($ART, sub { $got = shift });
    ok(!defined $got, '2: an answer for another artist (an unknown mbid answered by NAME) is no list');
    cold(); $REPLY{$CMQ} = { mbid => $ART, discography => [] }; undef $got;
    $f->($ART, sub { $got = shift });
    ok(!defined $got, '2: an empty list is no list');
    cold(); $REPLY{$CMQ} = 'ERROR'; undef $got;
    $f->($ART, sub { $got = shift });
    ok(!defined $got, '2: a failed request is no list');
});

section('3', sub {
    # 3. THE TWO TOGETHER.
    my $f = $A->can('_fastSpine');
    cold();
    $REPLY{$LBQ} = lb_reply(3);
    $REPLY{$CMQ} = cm_reply(2 => { r2 => 'Official' }, 5 => { r5 => 'Bootleg' });
    my $got; $f->($ART, sub { $got = shift });
    ok(ref $got eq 'ARRAY' && join(',', map { $_->{mbid} } @$got) eq join(',', sort map { id($_) } 1, 2, 3, 5),
       "3: ListenBrainz's groups and the community's it lacks, sorted by id");
    ok(ref $CACHE{$RG} eq 'ARRAY' && @{ $CACHE{$RG} } == 4 && $CACHE{$FAST}
       && ref $CACHE{$CMD} eq 'HASH' && ($CACHE{$CMD}{o}{ id(5) } // -1) == 0,
       '3: cached as the spine, marked as a first list, with the community verdicts kept');

    cold();
    $REPLY{$LBQ} = 'ERROR';
    $REPLY{$CMQ} = cm_reply(2 => { r2 => 'Official' });
    $DEFER = 1;
    my $n = 0; undef $got;
    $f->($ART, sub { $got = shift; $n++ });
    shift(@DEFERRED)->();                      # ListenBrainz answers first: a failure
    ok($n == 1 && !defined $got && @DEFERRED == 1,
       '3: ListenBrainz failing is answered at once, without waiting for the community');
    flush();
    ok($n == 1 && !defined $CACHE{$RG} && !defined $CACHE{$FAST} && !defined $CACHE{$CMD},
       '3: ... the community answering later changes nothing, and nothing is cached');

    cold();
    $REPLY{$LBQ} = lb_reply(3);
    $REPLY{$CMQ} = 'ERROR';
    $n = 0; undef $got;
    $f->($ART, sub { $got = shift; $n++ });
    ok($n == 1 && !defined $got && !defined $CACHE{$RG} && !defined $CACHE{$FAST},
       '3: the community failing: no list, nothing cached');

    cold();
    $REPLY{$LBQ} = lb_reply(3);
    # 3 is on ListenBrainz and listed without releases (kept: ListenBrainz has
    # it); 7 has releases (a new group); 8 and 9 have none (merged-away ids).
    $REPLY{$CMQ} = cm_reply(3 => undef, 7 => { r7 => 'Official' }, 8 => undef, 9 => undef);
    undef $got;
    $f->($ART, sub { $got = shift });
    my %in = map { $_->{mbid} => 1 } @{ $got || [] };
    ok($in{ id(3) } && $in{ id(7) } && !$in{ id(8) } && !$in{ id(9) } && @{ $got || [] } == 4,
       "3: a community group ListenBrainz lacks is taken only when it lists releases (a merged-away id has none)");

    cold();
    my $VA = '89ad4ac3-39f7-470e-963a-56509c546377';
    $REPLY{$LBQ} = lb_reply(3); $REPLY{$CMQ} = cm_reply(1 => { r => 'Official' });
    my $k = 0; undef $got;
    $f->($VA, sub { $got = shift; $k++ });
    ok($k == 1 && !defined $got && !@SENT,
       '3: Various Artists asks neither (106 MB on ListenBrainz): no list, no request');
});

section('4', sub {
    # 4. getReleaseGroups(read => 1), the page's way in.
    cold();
    $REPLY{$RDQ} = { %{ read_reply() }, 'release-groups' => [ map { { id => id($_), title => "G$_" } } 1 .. 3 ] };
    $REPLY{$LBQ} = lb_reply(9); $REPLY{$CMQ} = cm_reply(1 => { r => 'Official' });
    my $got; $A->getReleaseGroups(mbid => $ART, read => 1, onDone => sub { $got = shift });
    ok(ref $got eq 'ARRAY' && @$got == 3 && !sent(qr/listenbrainz|lms-community/),
       "4: under 25 groups the read's whole list is the spine, and no first list is asked for");

    cold();
    $REPLY{$RDQ} = read_reply();
    $REPLY{$LBQ} = lb_reply(30); $REPLY{$CMQ} = cm_reply(1 => { r => 'Official' });
    $REPLY{$BRQ} = { 'release-group-count' => 1, 'release-groups' => [ { id => id(1), title => 'G1' } ] };
    undef $got;
    $A->getReleaseGroups(mbid => $ART, read => 1, onDone => sub { $got = shift });
    ok(ref $got eq 'ARRAY' && @$got == 30 && !sent(qr/release-group\?artist=/) && $CACHE{$FAST},
       '4: 25 or more: the first list, no browse');
    ok(sent(qr{/artist/\Q$ART\E\?}) == 1 && $SENT[0][0] =~ m{/artist/},
       '4: ... asked for after the read (which says whether it is needed)');

    cold();
    $REPLY{$RDQ} = read_reply();
    $REPLY{$LBQ} = 'ERROR'; $REPLY{$CMQ} = cm_reply(1 => { r => 'Official' });
    $REPLY{$BRQ} = { 'release-group-count' => 1, 'release-groups' => [ { id => id(1), title => 'G1' } ] };
    undef $got;
    $A->getReleaseGroups(mbid => $ART, read => 1, onDone => sub { $got = shift });
    ok(ref $got eq 'ARRAY' && @$got == 1 && sent(qr/release-group\?artist=/) == 1 && !$CACHE{$FAST},
       '4: no first list: the browse, as before');

    cold();
    $CACHE{$FULL} = 1;
    $REPLY{$RDQ} = read_reply();
    $REPLY{$LBQ} = lb_reply(30); $REPLY{$CMQ} = cm_reply(1 => { r => 'Official' });
    $REPLY{$BRQ} = { 'release-group-count' => 1, 'release-groups' => [ { id => id(1), title => 'G1' } ] };
    undef $got;
    $A->getReleaseGroups(mbid => $ART, read => 1, onDone => sub { $got = shift });
    ok(ref $got eq 'ARRAY' && @$got == 1 && !sent(qr/listenbrainz|lms-community/) && sent(qr/release-group\?artist=/) == 1,
       "4: after a Refresh: MusicBrainz's browse, no first list");
    ok(!defined $CACHE{$FULL}, '4: ... and the Refresh marker is used up');

    cold();
    $REPLY{$RDQ} = read_reply();
    $REPLY{$LBQ} = lb_reply(30); $REPLY{$CMQ} = cm_reply(1 => { r => 'Official' });
    $REPLY{$BRQ} = { 'release-group-count' => 1, 'release-groups' => [ { id => id(1), title => 'G1' } ] };
    $A->getReleaseGroups(mbid => $ART, read => 1, force => 1, onDone => sub {});
    ok(!sent(qr/listenbrainz|lms-community/) && sent(qr/release-group\?artist=/) == 1,
       '4: force: the browse, no first list');

    cold();
    $CACHE{$NEXT} = [ { mbid => id(7), title => 'G7', date => '', type => 'Album', secondary => [] } ];
    $CACHE{$FAST} = 1; $CACHE{$CMD} = { o => {}, r => {} };
    undef $got;
    $A->getReleaseGroups(mbid => $ART, read => 1, onDone => sub { $got = shift });
    ok(ref $got eq 'ARRAY' && @$got == 1 && $got->[0]{mbid} eq id(7) && !@SENT,
       "4: an expired spine with MusicBrainz's completed list waiting: that list, no request");
    ok(!defined $CACHE{$NEXT} && !defined $CACHE{$FAST} && !defined $CACHE{$CMD},
       '4: ... and no first list is left to complete');
});

section('5', sub {
    # 5. THE BOOTLEG CHECK ON A FIRST LIST.
    my $rgs = [ map { { mbid => id($_) } } 1 .. 5 ];
    cold();
    $CACHE{$FAST} = 1;
    $CACHE{$CMD} = { o => { id(1) => 1, id(2) => 0, id(3) => 1 }, r => { 'r1' => id(1) } };
    $REPLY{$IDQ} = \&byid_reply;
    my $st = 'x'; $A->warmOfficial($ART, $rgs, sub { $st = shift });
    my @q = grep { $_->[0] =~ /release-group\?query=/ } @SENT;
    my @asked = @q ? ($q[0][0] =~ /rgid%3A([0-9a-f-]+)/g) : ();
    ok(@q == 1 && join(',', sort @asked) eq join(',', sort map { id($_) } 4, 5),
       "5: ONE by-id request, for the groups without the community's verdict only");
    my $m = $CACHE{$OFF} || {};
    ok(($m->{o}{ id(2) } // -1) == 0 && ($m->{o}{ id(1) } // -1) == 1 && ($m->{o}{ id(4) } // -1) == 1,
       "5: the map holds the community's verdicts and MusicBrainz's for the rest");
    ok(($m->{r}{r1} // '') eq id(1) && ($m->{r}{ id(4) . '-mb' } // '') eq id(4) && !defined $st,
       "5: ... both release maps, and the page is told it is done");
    ok(!exists $m->{t}{ id(1) } && ref $m->{t}{ id(4) } eq 'ARRAY',
       '5: edition titles only where MusicBrainz was asked (the rest come after the page)');

    cold();
    $CACHE{$FAST} = 1;
    $CACHE{$CMD} = { o => { map { (id($_) => 1) } 1 .. 5 }, r => {} };
    $A->warmOfficial($ART, $rgs, sub {});
    ok(!@SENT && ref $CACHE{$OFF} eq 'HASH', '5: every group classified by the community: no request');

    cold();
    $REPLY{$IDQ} = \&byid_reply;
    $REPLY{$CMQ} = cm_reply(1 => { r => 'Official' });
    $A->warmOfficial($ART, $rgs, sub {});
    @q = grep { $_->[0] =~ /release-group\?query=/ } @SENT;
    @asked = @q ? ($q[0][0] =~ /rgid%3A([0-9a-f-]+)/g) : ();
    ok(@asked == 5 && !sent(qr/lms-community/), '5: no first list: every group by id, as before');

    cold();
    $CACHE{$FAST} = 1;                          # marker kept, community verdicts gone
    $REPLY{$IDQ} = \&byid_reply;
    $REPLY{$CMQ} = cm_reply(1 => { r => 'Official' }, 2 => { r => 'Bootleg' });
    $A->warmOfficial($ART, $rgs, sub {});
    @q = grep { $_->[0] =~ /release-group\?query=/ } @SENT;
    @asked = @q ? ($q[0][0] =~ /rgid%3A([0-9a-f-]+)/g) : ();
    ok(sent(qr/lms-community/) == 1 && @asked == 3 && ($CACHE{$OFF}{o}{ id(2) } // -1) == 0,
       "5: a first list whose verdicts are gone asks the community again, then the rest by id");
    cold();
    $CACHE{$FAST} = 1;
    $REPLY{$IDQ} = \&byid_reply; $REPLY{$CMQ} = 'ERROR';
    $A->warmOfficial($ART, $rgs, sub {});
    @q = grep { $_->[0] =~ /release-group\?query=/ } @SENT;
    @asked = @q ? ($q[0][0] =~ /rgid%3A([0-9a-f-]+)/g) : ();
    ok(@asked == 5, '5: ... and that failing, every group by id');
    ok(!(opts_of(qr/release-group\?query=/)->{background}), '5: the check before the page is not background work');

    # THE BOUND (0.56.8): at most PREDRAW_RGID_MAX groups by id before the draw
    # when the rest may follow it. The callback leaves a marker in @SENT.
    my $max = $A->can('PREDRAW_RGID_MAX')->();
    my $split = sub {
        my ($i) = grep { $SENT[$_][0] eq 'CB' } 0 .. $#SENT;
        $i //= scalar @SENT;
        my @q = grep { $_->[0] =~ /release-group\?query=/ } @SENT[0 .. $i - 1];
        my @l = grep { $_->[0] =~ /release-group\?query=/ } @SENT[$i + 1 .. $#SENT];
        return ([ map { $_->[0] =~ /rgid%3A([0-9a-f-]+)/g } @q ], [ map { $_->[0] =~ /rgid%3A([0-9a-f-]+)/g } @l ],
                scalar(grep { !$_->[1]{background} } @l), scalar(@q));
    };
    my $big = [ map { { mbid => id($_) } } 1 .. 450 ];
    cold();
    $CACHE{$FAST} = 1;
    $CACHE{$CMD} = { o => { map { (id($_) => 1) } 1 .. 100 }, r => {} };
    $REPLY{$IDQ} = \&byid_reply;
    $A->warmOfficial($ART, $big, sub { push @SENT, [ 'CB', {} ] });
    my ($now, $later, $fg, $reqs) = $split->();
    ok(@$now == $max && $reqs == 2, "5: 350 unclassified on a first list: 200 by id before the draw, two requests");
    ok(@$later == 150 && !$fg, '5: ... the other 150 after it, as background work');
    my %seen = map { $_ => 1 } @$now, @$later;
    ok(keys(%seen) == 350 && !grep({ $seen{ id($_) } } 1 .. 100),
       "5: ... between them every unclassified group once, none the community classified");
    $m = $CACHE{$OFF} || {};
    ok((grep { defined $m->{o}{ id($_) } } 1 .. 450) == 450 && ref $m->{t}{ id(450) } eq 'ARRAY'
       && ref $m->{t}{ id(101) } eq 'ARRAY',
       '5: ... the late answers merged into the map (verdicts and edition titles), for the next visit');

    cold();
    $CACHE{$FAST} = 1;
    $CACHE{$CMD} = { o => {}, r => {} };
    $REPLY{$IDQ} = \&byid_reply;
    $DEFER = 1;
    my $drew = 0;
    $A->warmOfficial($ART, $big, sub { $drew++ });
    for (1 .. 10) { last if $drew; step() }
    ok($drew == 1 && @DEFERRED >= 1, '5: drawn after its two requests, the background ones still out');
    delete $CACHE{$OFF};                        # a Refresh clears the map meanwhile
    flush();
    ok(!defined $CACHE{$OFF}, '5: ... a map cleared meanwhile is not re-created by the late answers');

    cold();
    $CACHE{$FAST} = 1;
    $CACHE{$CMD} = { o => {}, r => {} };
    $REPLY{$IDQ} = 'ERROR';
    my $st2 = 'x';
    $A->warmOfficial($ART, [ map { { mbid => id($_) } } 1 .. 150 ], sub { $st2 = shift });
    ok(($st2 // '') eq 'failed' && !defined $CACHE{$OFF}, '5: the check before the draw failing: nothing cached, as before');

    # A first list whose verdicts are gone, the community failing again: still
    # bounded (every group of a first list may wait).
    cold();
    $CACHE{$FAST} = 1;
    $REPLY{$IDQ} = \&byid_reply; $REPLY{$CMQ} = 'ERROR';
    $A->warmOfficial($ART, $big, sub { push @SENT, [ 'CB', {} ] });
    ($now, $later, $fg) = $split->();
    ok(@$now == $max && @$later == 250 && !$fg,
       '5: a first list with no community verdicts at all: 200 before the draw, 250 after');

    # An expired map under a list longer than MusicBrainz's browse gives (no
    # marker, no community verdicts): the community is asked again, then the bound.
    cold();
    $REPLY{$IDQ} = \&byid_reply;
    $REPLY{$CMQ} = cm_reply(map { ($_ => { "r$_" => 'Official' }) } 1 .. 400);
    $A->warmOfficial($ART, [ map { { mbid => id($_) } } 1 .. 700 ], sub { push @SENT, [ 'CB', {} ] });
    ($now, $later, $fg, $reqs) = $split->();
    ok(sent(qr/lms-community/) == 1 && @$now == $max && @$later == 100 && !$fg,
       "5: an expired map under 700 groups: the community again, 200 by id before the draw, 100 after (Dylan was 12 requests)");
    cold();
    $REPLY{$IDQ} = \&byid_reply;
    $A->warmOfficial($ART, [ map { { mbid => id($_) } } 1 .. 450 ], sub { push @SENT, [ 'CB', {} ] });
    ($now, $later) = $split->();
    ok(@$now == 450 && !@$later && !sent(qr/lms-community/),
       "5: a list MusicBrainz's browse could give (600 or fewer), no verdicts: every group before the draw, as before");
});

section('6', sub {
    # 6. THE COMPLETION AFTER THE PAGE.
    my $drawn = [
        { mbid => id(1), title => 'First title', date => '', type => '', secondary => [] },
        { mbid => id(2), title => 'G2', date => '2001', type => 'Album', secondary => [] },
        { mbid => id(8), title => 'Only in the first list', date => '', type => 'Album', secondary => [] },
    ];
    my $browse = { 'release-group-count' => 3, 'release-groups' => [
        { id => id(1), title => 'MusicBrainz title', 'primary-type' => 'Album', 'first-release-date' => '1997',
          aliases => [ { name => 'Alias of 1' } ] },
        { id => id(2), title => 'G2', 'primary-type' => 'Album', aliases => [ { name => 'Only in the first list' } ] },
        { id => id(3), title => 'The newest', 'primary-type' => 'Single' } ] };
    my $seed = sub {
        cold();
        $CACHE{$RG}   = [ map { { %$_ } } @$drawn ];
        $CACHE{$FAST} = 1;
        $CACHE{$CMD}  = { o => {}, r => {} };
        $CACHE{$OFF}  = { o => { id(1) => 0, id(8) => 1 }, r => { 'cm-r' => id(8) }, t => { id(8) => ['Ed of 8'] } };
        $REPLY{$BRQ}  = $browse;
        $REPLY{$IDQ}  = \&byid_reply;
    };

    $seed->();
    my $n = 0; $A->completeArtist($ART, sub { $n++ });
    ok($n == 1 && @SENT == 2 && !grep({ !$_->[1]{background} } @SENT),
       '6: the browse and the by-id check, every request as background work');
    my $next = $CACHE{$NEXT} || [];
    my %by = map { $_->{mbid} => $_ } @$next;
    ok(@$next == 3 && ($by{ id(1) }{title} // '') eq 'MusicBrainz title' && ($by{ id(1) }{date} // '') eq '1997'
       && "@{ $by{ id(1) }{aliases} || [] }" eq 'Alias of 1',
       "6: MusicBrainz's entry wins where both have the group (title, date, aliases)");
    ok($by{ id(3) } && !$by{ id(8) },
       '6: the newest group is added; one only the first list had is dropped (the browse was whole)');
    ok(join(',', map { $_->{mbid} } @$next) eq join(',', sort map { $_->{mbid} } @$next), '6: sorted by id');
    my $m = $CACHE{$OFF} || {};
    ok(($m->{o}{ id(1) } // -1) == 1 && ($m->{o}{ id(8) } // -1) == 1 && ($m->{r}{'cm-r'} // '') eq id(8)
       && ref $m->{t}{ id(3) } eq 'ARRAY',
       "6: MusicBrainz's verdicts, release map and edition titles over the community's, which stay elsewhere");
    ok("@{ $m->{t}{ id(8) } || [] }" eq 'Ed of 8',
       "6: edition titles merged, not replaced: a group MusicBrainz's browse did not list keeps its own (0.56.8)");
    ok(!defined $CACHE{$FAST} && !defined $CACHE{$CMD} && @{ $CACHE{$RG} } == 3
       && ($CACHE{$RG}[0]{title} // '') eq 'First title',
       '6: the markers go; the drawn list stays for the visit in progress');
    @SENT = ();
    $A->completeArtist($ART, sub { $n++ });
    ok($n == 2 && !@SENT, '6: nothing left to complete: answered at once, no request');

    # A browse cut at its cap: the first list's own groups are past it, kept,
    # and an alias another group now owns by title is pruned.
    $seed->();
    my $pages = 0;
    $REPLY{$BRQ} = sub {
        $pages++;
        return { 'release-group-count' => 700, 'release-groups' => [
            { id => id(100 + $pages), title => "Page $pages", aliases => [ { name => 'Only in the first list' } ] } ] };
    };
    $A->completeArtist($ART, sub {});
    $next = $CACHE{$NEXT} || [];
    %by = map { $_->{mbid} => $_ } @$next;
    ok($pages == 6 && $by{ id(8) } && $by{ id(2) },
       '6: a browse cut at its cap: groups only the first list has are kept (they are past the cap)');
    ok(!grep({ grep { $_ eq 'Only in the first list' } @{ $_->{aliases} || [] } } @$next),
       "6: ... and an alias that a kept group's title now owns is pruned over the whole list");

    # Failures: nothing stored, the marker kept, the next visit tries again.
    $seed->();
    $REPLY{$BRQ} = 'ERROR';
    $n = 0; $A->completeArtist($ART, sub { $n++ });
    ok($n == 1 && !defined $CACHE{$NEXT} && $CACHE{$FAST} && ($CACHE{$OFF}{o}{ id(1) } // -1) == 0,
       '6: a failed browse stores nothing and keeps the marker');
    $REPLY{$BRQ} = $browse;
    $A->completeArtist($ART, sub { $n++ });
    ok($n == 2 && ref $CACHE{$NEXT} eq 'ARRAY', '6: ... and is tried again on the next visit');
    $seed->();
    $REPLY{$IDQ} = 'ERROR';
    $A->completeArtist($ART, sub {});
    ok(!defined $CACHE{$NEXT} && $CACHE{$FAST}, '6: a failed by-id check stores nothing and keeps the marker');

    # A Refresh while it runs: its result is discarded.
    $seed->();
    $DEFER = 1;
    $A->completeArtist($ART, sub {});
    step();                                      # the browse answers
    ok(scalar(@DEFERRED) == 1, '6: (the by-id check is in flight)');
    $A->clearArtistCache(mbid => $ART, refresh => 1);
    flush();
    ok(!defined $CACHE{$NEXT} && !defined $CACHE{$OFF}, '6: a Refresh while it runs discards its result');

    # One at a time.
    $seed->();
    $DEFER = 1;
    my $k = 0;
    $A->completeArtist($ART, sub { $k++ });
    $A->completeArtist($ART, sub { $k++ });
    ok($k == 1 && sent(qr/release-group\?artist=/) == 1, '6: a second call while one runs is answered at once, no request');
    flush();
});

section('7', sub {
    # 7. THE SWAP, AND WHAT A REFRESH CLEARS.
    cold();
    ok($A->promoteCompleted($ART) == 0, '7: nothing completed: no swap');
    $CACHE{$RG} = [ { mbid => id(1) } ];
    $CACHE{$NEXT} = [ { mbid => id(2) } ];
    $CACHE{$FAST} = 1; $CACHE{$CMD} = {};
    ok($A->promoteCompleted(uc $ART) == 1 && $CACHE{$RG}[0]{mbid} eq id(2)
       && !defined $CACHE{$NEXT} && !defined $CACHE{$FAST} && !defined $CACHE{$CMD},
       "7: the completed list replaces the drawn one (any case of id), and the markers go");

    cold();
    $CACHE{$_} = 1 for $FAST, $NEXT, $CMD;
    $A->clearArtistCache(mbid => $ART);
    ok(!defined $CACHE{$FAST} && !defined $CACHE{$NEXT} && !defined $CACHE{$CMD} && !defined $CACHE{$FULL},
       '7: clearcache clears the first list and its completion, and sets no Refresh marker (a plain cold start)');
    $A->clearArtistCache(mbid => $ART, refresh => 1);
    ok($CACHE{$FULL}, "7: the page's Refresh sets the marker: the next list is MusicBrainz's own");
});

section('8', sub {
    # 8. A REFRESH PAST THE CAP (0.56.8): found live on 0.56.7, Johnny Cash's
    # page lost its 14 live albums for 14 days after a Refresh.
    my $cap = $A->can('RG_MAX_PAGES')->() * $A->can('RG_PAGE_SIZE')->();
    # MusicBrainz lists $n groups, 1..$n, a page per offset.
    my $browse = sub {
        my ($n, %al) = @_;
        return sub {
            my ($url) = @_;
            my ($off) = $url =~ /offset=(\d+)/;
            return 'ERROR' if defined $al{fail_at} && $off == $al{fail_at};
            return { 'release-group-count' => $n, 'release-groups' => [ map {
                { id => id($_), title => "G$_", 'primary-type' => 'Album',
                  ($al{$_} ? (aliases => [ map { { name => $_ } } @{ $al{$_} } ]) : ()) }
            } grep { $_ <= $n } ($off + 1) .. ($off + 100) ] };
        };
    };
    my $setup = sub {
        my (%o) = @_;
        cold();
        $CACHE{$FULL} = 1;
        $REPLY{$RDQ} = read_reply();
        $REPLY{$BRQ} = $browse->($o{mb} // 650, 1 => [ 'G640', 'Keep me' ], %{ $o{al} || {} });
        # ListenBrainz in reverse id order, so the union's sort is tested.
        my $lbr = lb_reply(640); $lbr->[0]{release_group} = [ reverse @{ $lbr->[0]{release_group} } ];
        $REPLY{$LBQ} = $o{lb} // $lbr;
        $REPLY{$CMQ} = $o{cm} // cm_reply(5 => { r5 => 'Bootleg' }, 602 => { r602 => 'Official' },
                                          645 => { r645 => 'Bootleg' }, 603 => undef,
                                          660 => undef);   # a merged-away id: left out
        $REPLY{$IDQ} = \&byid_reply;
    };
    my ($got, $n, $errs);
    my $run = sub {
        ($got, $n, $errs) = (undef, 0, 0);
        $A->getReleaseGroups(mbid => $ART, read => 1,
            onDone => sub { $got = shift; $n++ }, onError => sub { $errs++ });
    };
    my $idx = sub { my ($re) = @_; my ($i) = grep { $SENT[$_][0] =~ $re } 0 .. $#SENT; $i // -1 };

    $setup->(); $run->();
    my ($p0, $p1) = ($idx->(qr/offset=0&/), $idx->(qr/offset=100&/));
    my ($lb, $cm) = ($idx->(qr/listenbrainz/), $idx->(qr/lms-community/));
    ok($p0 >= 0 && $lb > $p0 && $cm > $p0 && $lb < $p1 && $cm < $p1,
       "8: past the cap: both lists asked once the first page's count is in, before the second page");
    ok(sent(qr/release-group\?artist=/) == $A->can('RG_MAX_PAGES')->()
       && sent(qr/listenbrainz/) == 1 && sent(qr/lms-community/) == 1,
       '8: ... the browse keeps its cap, and each list is asked once');
    my %g = map { $_->{mbid} => $_ } @{ $got || [] };
    ok($n == 1 && @{ $got || [] } == $cap + 41 && (grep { $g{ id($_) } } 1 .. $cap) == $cap
       && (grep { $g{ id($_) } } 601 .. 640, 645) == 41 && !$g{ id(641) } && !$g{ id(660) },
       "8: MusicBrainz's 600 and the groups past the cap from ListenBrainz and the community API");
    ok(join(',', map { $_->{mbid} } @{ $got || [] }) eq join(',', sort keys %g), '8: ... sorted by id');
    ok("@{ $g{ id(1) }{aliases} || [] }" eq 'Keep me',
       "8: aliases pruned over the whole (one that a kept group's title owns is dropped)");
    my $c = $CACHE{$CMD} || {};
    ok(ref $CACHE{$RG} eq 'ARRAY' && @{ $CACHE{$RG} } == $cap + 41 && !defined $CACHE{$FAST} && !defined $CACHE{$FULL},
       '8: cached as the spine; no first-list marker (nothing to complete); the Refresh marker used up');
    ok(join(',', sort keys %{ $c->{o} || {} }) eq join(',', sort map { id($_) } 602, 645)
       && ($c->{o}{ id(645) } // -1) == 0 && join(',', sort keys %{ $c->{r} || {} }) eq 'r602,r645',
       "8: the community's verdicts and release map for the kept groups ONLY, not MusicBrainz's own");

    @SENT = ();
    $A->warmOfficial($ART, $got, sub {});
    my @q = grep { $_->[0] =~ /release-group\?query=/ } @SENT;
    my %asked = map { $_ => 1 } map { $_->[0] =~ /rgid%3A([0-9a-f-]+)/g } @q;
    ok(!$asked{ id(602) } && !$asked{ id(645) } && $asked{ id(5) } && $asked{ id(601) }
       && keys(%asked) == $cap + 39 && !sent(qr/lms-community/),
       "8: the bootleg check asks MusicBrainz's groups by id, and the kept ones it has no verdict for");
    my $m = $CACHE{$OFF} || {};
    ok(($m->{o}{ id(5) } // -1) == 1 && ($m->{o}{ id(645) } // -1) == 0 && ($m->{r}{r645} // '') eq id(645),
       "8: ... MusicBrainz's verdict for its own group (the community's ignored), the community's for a kept one");

    $setup->(lb => lb_reply(900)); $run->();
    @SENT = ();
    $A->warmOfficial($ART, $got, sub { push @SENT, [ 'CB', {} ] });
    {
        my ($i) = grep { $SENT[$_][0] eq 'CB' } 0 .. $#SENT;
        my @before = map { $_->[0] =~ /rgid%3A([0-9a-f-]+)/g } grep { $_->[0] =~ /query=/ } @SENT[0 .. $i - 1];
        my @after  = map { $_->[0] =~ /rgid%3A([0-9a-f-]+)/g } grep { $_->[0] =~ /query=/ } @SENT[$i + 1 .. $#SENT];
        my %b = map { $_ => 1 } @before;
        ok(@before == $cap + $A->can('PREDRAW_RGID_MAX')->() && (grep { $b{ id($_) } } 1 .. $cap) == $cap
           && @after == 298 - $A->can('PREDRAW_RGID_MAX')->(),
           "8: 298 kept groups unclassified: MusicBrainz's 600 and 200 of them before the draw, the other 98 after");
    }

    $setup->(mb => $cap); $run->();
    ok($n == 1 && @$got == $cap && !sent(qr/listenbrainz|lms-community/) && !defined $CACHE{$CMD},
       '8: a browse that is whole: nothing else asked');
    $setup->(mb => 6100, lb => lb_reply(2000), cm => cm_reply(2001 => { r => 'Official' })); $run->();
    ok($n == 1 && @$got == 2001 && sent(qr/listenbrainz/) == 1,
       "8: no ceiling: a count of 6,100 (Mozart) asks too, and every group past the cap is kept");
    $setup->(lb => 'ERROR'); $run->();
    ok($n == 1 && @$got == $cap && !defined $CACHE{$CMD} && @{ $CACHE{$RG} } == $cap,
       "8: ListenBrainz failing: MusicBrainz's 600, as before");
    $setup->(cm => 'ERROR'); $run->();
    ok($n == 1 && @$got == $cap && !defined $CACHE{$CMD}, "8: the community failing: MusicBrainz's 600");
    {
        my $VA = '89ad4ac3-39f7-470e-963a-56509c546377';
        $setup->();
        $REPLY{ $MB_BASE . 'artist/' . $VA . '?' } = read_reply();
        $REPLY{ $MB_BASE . 'release-group?artist=' . $VA . '&' } = sub {
            my ($off) = $_[0] =~ /offset=(\d+)/;
            return { 'release-group-count' => 900000, 'release-groups' => [ map { { id => id($_), title => "G$_" } } ($off + 1) .. ($off + 100) ] };
        };
        $CACHE{ 'dsc:rgfull:1:' . $VA } = 1;
        my %before = %CACHE;
        ($got, $n) = (undef, 0);
        $A->getReleaseGroups(mbid => $VA, read => 1, onDone => sub { $got = shift; $n++ });
        # 0.56.41 (Simon: Various Artists is never one artist): not its 600 any
        # more, nothing at all, and nothing kept.
        ok($n == 1 && ref $got eq 'ARRAY' && !@$got && !@SENT
           && join(',', sort keys %CACHE) eq join(',', sort keys %before),
           '8: a Refresh of Various Artists asks nothing at all: an empty list, nothing cached (0.56.41)');
        ($got, $n) = (undef, 0);
        $A->getReleaseGroups(mbid => uc $VA, onDone => sub { $got = shift; $n++ });
        ok($n == 1 && !@$got && !@SENT, '8: so does a plain visit, under any case of the id');
    }
    $setup->(lb => lb_reply(500), cm => cm_reply(5 => { r5 => 'Official' })); $run->();
    ok($n == 1 && @$got == $cap && !defined $CACHE{$CMD}, '8: nothing past the cap in either list: no verdicts kept');

    $setup->(); $DEFER = 1; $run->();
    for (1 .. 20) { last unless step_only(qr/musicbrainz/) }
    ok($n == 0 && sent(qr/release-group\?artist=/) == $A->can('RG_MAX_PAGES')->(),
       '8: the browse done before the two lists answer: the page waits for them');
    flush();
    ok($n == 1 && @$got == $cap + 41, '8: ... then answers once, with the groups past the cap');

    $setup->(al => { fail_at => 300 }); $DEFER = 1; $run->();
    for (1 .. 20) { last unless step_only(qr/musicbrainz/) }
    flush();
    ok($errs == 1 && $n == 0 && !defined $CACHE{$RG} && !defined $CACHE{$CMD},
       '8: the browse failing after the lists were asked: an error, and their late answers store nothing');

    $setup->(lb => 'ERROR'); delete $CACHE{$FULL}; $run->();
    ok($n == 1 && @$got == $cap && sent(qr/listenbrainz/) == 1 && sent(qr/lms-community/) == 1,
       '8: not a Refresh (the first list failed, the browse instead): the two are not asked again');

    # A LIST CUT AT THE CAP IS KEPT AN HOUR (0.56.40). Found live 2026-10-02:
    # ListenBrainz and the community API timed out on Ella Fitzgerald's first
    # visit after an install, the browse gave 600 of her 796 groups, and her Live
    # albums were gone for RG_TTL (14 days).
    my ($day14, $hour) = ($A->can('RG_TTL')->(), $A->can('RGCUT_TTL')->());
    ok($hour == 3600 && $day14 == 14 * 86400, '8c: the two lifetimes: an hour, and 14 days');
    ok(@{ $CACHE{$RG} || [] } == $cap && ($TTLS{$RG} // 0) == $hour,
       '8c: the first list failed and the browse was cut (Ella): kept an hour, not 14 days');
    delete $CACHE{$RG}; @SENT = ();
    $REPLY{$LBQ} = lb_reply(640);
    $run->();
    ok(sent(qr/listenbrainz/) == 1 && @{ $got || [] } > $cap,
       '8c: ... so the next visit after it asks ListenBrainz again, and gets the whole list');
    $setup->(lb => 'ERROR'); delete $CACHE{$FULL}; $REPLY{$BRQ} = $browse->(400); $run->();
    ok(@{ $got || [] } == 400 && ($TTLS{$RG} // 0) == $day14,
       '8c: the first list failed but the browse was whole: 14 days, as before');
    $setup->(); $run->();
    ok(($TTLS{$RG} // 0) == $day14, '8c: a Refresh with the groups past the cap: 14 days');
    $setup->(lb => 'ERROR'); $run->();
    ok(@$got == $cap && ($TTLS{$RG} // 0) == $hour, '8c: a Refresh whose lists failed: still cut, an hour');
    $setup->(lb => lb_reply(500), cm => cm_reply(5 => { r5 => 'Official' })); $run->();
    ok(@$got == $cap && ($TTLS{$RG} // 0) == $day14,
       '8c: a Refresh where both lists have nothing past the cap: the 600 are all of it, 14 days');
    $setup->(mb => $cap); $run->();
    ok(($TTLS{$RG} // 0) == $day14, '8c: a browse that is whole: 14 days');
});

section('9', sub {
    # 9. WHICH GROUPS THE ARCHIVE HAS A COVER FOR (0.56.30): ListenBrainz's
    #    caa_id, kept per artist whenever it answers, read by the page.
    my $f = $A->can('_lbGroups');
    my $KEY = 'dsc:caaflag:1:' . $ART;
    my $reply = sub {
        [ { artist_mbid => $ART, name => 'Radiohead', release_group => [
            { mbid => id(1), name => 'G1', caa_id => 12345, caa_release_mbid => id(101) },
            { mbid => id(2), name => 'G2', caa_id => undef, caa_release_mbid => undef },
            { mbid => uc id(3), name => 'G3' },
            { mbid => 'not-a-uuid', name => 'G4', caa_id => 9 },
        ] } ]
    };
    cold(); $REPLY{$LBQ} = $reply->();
    my $got; $f->($ART, sub { $got = shift });
    my $fl = $CACHE{$KEY};
    ok(ref $fl eq 'HASH' && ($fl->{ id(1) } // -1) == 1 && ($fl->{ id(2) } // -1) == 0 && ($fl->{ id(3) } // -1) == 0,
       '9: kept { group => 1 with a caa_id, 0 without }, ids lower-cased');
    ok(ref $fl eq 'HASH' && keys %$fl == 3, '9: an entry without a valid group id is left out');
    ok(ref $got eq 'ARRAY' && @$got == 3, '9: the list itself is unchanged by it');
    my $peek = $A->peekCoverFlags($ART);
    ok(ref $peek eq 'HASH' && ($peek->{ id(2) } // -1) == 0, '9: peekCoverFlags reads them back');
    ok(!defined $A->peekCoverFlags(id(77)) && !defined $A->peekCoverFlags(undef) && !defined $A->peekCoverFlags(''),
       '9: another artist, or none -> undef (every group counts as maybe)');

    cold(); $REPLY{$LBQ} = [ { artist_mbid => id(99), name => 'X', release_group => [ { mbid => id(1), name => 'G1', caa_id => 1 } ] } ];
    $f->($ART, sub {});
    ok(!exists $CACHE{$KEY}, '9: an answer for another artist keeps nothing');
    cold(); $REPLY{$LBQ} = 'ERROR';
    $f->($ART, sub {});
    ok(!exists $CACHE{$KEY}, '9: a failed request keeps nothing');
});

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
