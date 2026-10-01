#!/usr/bin/env perl
#
# REGRESSION TEST — the bootleg check asks for the page's release groups BY ID
# (stage 2 of docs/mb-efficiency-and-community-api-analysis.md, 2026-09-29; §A11
# has the measurements).
#
# API::warmOfficial built the bootleg map (o), the release->group map (r) and
# the edition titles (t) from a browse of every RELEASE of the artist:
# `release?artist=<id>&inc=release-groups`, 100 releases a page, 34 pages for
# The Beatles, which could not finish inside the first render's deadline. It
# now asks the release-group SEARCH for the groups on the page, by id,
# `rgid:A OR rgid:B ...`, 100 to a request (at most 6), and each hit lists every
# release of the group with its id, title and status. MEASURED on the public
# API against the old browse over the same groups: Jamie Cullum 1 request (2),
# Kraftwerk 2 (6), Radiohead 6 (12), The Beatles 6 (34), every group returned.
#
# NOT by artist (`arid:<id>`, paged): the pages overlap and groups go missing
# (Kraftwerk, 162 of 167, the same five lost on every run). By id cannot.
#
# THE FIXTURE IS CAPTURED, NOT WRITTEN: tools/fixtures/mb_rg_byid_mix.json is the
# public reply, 2026-09-29, byte for byte, to exactly the URL this suite asserts
# the code builds (section 1), for nine ids chosen for their cases:
#   Kraftwerk  Tour de France Soundtracks  Official + status-less + Promotion,
#                                          editions titled "Tour de France"
#              Radio‐Aktivität             Official + status-less, 38 releases
#              Autobahn                    Official + Promotion
#              An Atelier                  Bootleg only
#              Tribal Gathering            Bootleg + ONE status-less release
#              Die Broadcast Sammlung      Bootleg only
#   Beatles    Last Night in Hamburg       listed with NO releases (count 0)
#   Cullum     Jamie Cullum, Volume One    Promotion only (credited to Various
#                                          Artists: the old browse never saw it)
#   (none)     00000000-0000-4000-8000-000000000000, an id MB never issued
# Larger batches are built in the captured shape: they pin OUR chunking, not
# MusicBrainz's data.
#
# Standalone -- no LMS install needed:  perl tools/t_official.pl
#
use strict;
use warnings;
use FindBin;
use JSON::PP ();

our (%CACHE, $DATA, @URLS, @DEFERRED, $DEFER, $RESPONDER);

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
    # 'BAD' models a 200 whose body is not JSON: from_json DIES, as JSON::XS does.
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub {
        die "malformed JSON string\n" if !ref $main::DATA && ($main::DATA // '') eq 'BAD';
        return $main::DATA;
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
sub get    { return $main::CACHE{ $_[1] } }
sub set    { $main::CACHE{ $_[1] } = $_[2]; return 1 }
sub remove { delete $main::CACHE{ $_[1] }; return 1 }
package T::Prefs;
sub get { return $_[1] eq 'mb_base_url' ? 'https://musicbrainz.org/ws/2/' : undef }
sub set { return 1 } sub init { return 1 } sub setChange { return 1 }
package T::Resp;
sub new { bless {}, shift } sub content { '{}' } sub error { '503 Service Unavailable' }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::API;
my $API = 'Plugins::Discography::API';

# THE QUEUE IS NOT THIS SUITE'S SUBJECT (t_netqueue.pl owns pacing): _netGet is
# replaced by a transport that records each URL and answers from $RESPONDER,
# which returns a structure, 'FAIL' (the error callback) or 'BAD' (unreadable).
# $DEFER holds replies open so a second caller really arrives mid-check.
{
    no strict 'refs'; no warnings 'redefine';
    *{'Plugins::Discography::API::_netGet'} = sub {
        my ($url, $ok, $err) = @_;
        push @URLS, $url;
        my $fire = sub {
            my $r = $RESPONDER->($url);
            return $err->(T::Resp->new) if !ref $r && $r eq 'FAIL';
            $DATA = $r;
            $ok->(T::Resp->new);
        };
        if ($DEFER) { push @DEFERRED, $fire } else { $fire->() }
    };
}
sub flush {
    for (1 .. 20) {
        my @d = @DEFERRED;
        last unless @d;
        @DEFERRED = ();
        $_->() for @d;
    }
}

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

my $MIX = do {
    open my $fh, '<:raw', "$FindBin::Bin/fixtures/mb_rg_byid_mix.json" or die "fixture: $!";
    local $/; <$fh>;
};
my %ID = (
    tdfs   => 'e963cb1e-ec72-303d-9a3f-9fcb89188436',
    radio  => '104cc34f-b4f9-3fb1-b2a0-fce32b36ec1f',
    auto   => '5bb58171-9e68-4da2-bdae-f6e5e8ae7524',
    atel   => 'ca763b6b-cf6b-441b-a9ee-1b2395f7bc38',
    tribal => '417046d4-7b36-3d0f-a306-8cdcdaab9d6d',
    bcast  => 'd727d700-f18e-4c5d-8546-02e37029df4b',
    lnih   => '363c0ba5-57dd-3e0f-8f8f-c4b651f8b285',
    vol1   => '485035f7-4d44-4054-b2ba-5deb36904c03',
    none   => '00000000-0000-4000-8000-000000000000',
);
my @ORDER = qw(tdfs radio auto atel tribal bcast lnih vol1 none);
# The spine the page would hand over, in its order.
my @MIXRGS = map { { mbid => $ID{$_}, title => $_ } } @ORDER;
# The URL the public reply was captured from, 2026-09-29.
my $MIXURL = 'https://musicbrainz.org/ws/2/release-group?query='
    . join('%20OR%20', map { "rgid%3A$ID{$_}" } @ORDER) . '&limit=9&fmt=json';

# Generated groups in the captured shape: $n official releases each unless the
# id is listed in %$spec as [ status, ... ] or { count => N, st => [...] }.
sub gen_responder {
    my ($spec) = @_;
    return sub {
        my ($url) = @_;
        my @ids = $url =~ /rgid%3A([0-9a-z-]+)/g;
        my @hits;
        for my $id (@ids) {
            my $s = $spec->{$id};
            next if $s && !ref $s && $s eq 'MISSING';
            my @st = ref $s eq 'HASH' ? @{ $s->{st} } : ref $s eq 'ARRAY' ? @$s : ('Official');
            my $i = 0;
            my @rels = map { { id => "$id-r" . ++$i, title => "Title $i", status => $_ } } @st;
            push @hits, { id => $id, title => $id, score => 100,
                          count => (ref $s eq 'HASH' ? $s->{count} : scalar @rels), releases => \@rels };
        }
        return { created => 'x', count => scalar @hits, offset => 0, 'release-groups' => \@hits };
    };
}
sub gid { sprintf('%08x-0000-4000-8000-%012x', $_[0], $_[0]) }
sub reset_all { %CACHE = (); @URLS = (); @DEFERRED = (); $DEFER = 0 }
my $KEY = 'dsc:rgo:v5:';

# ---------------------------------------------------------------------------
# 1. THE CAPTURED REPLY. One request, built exactly as the reply was captured.
# ---------------------------------------------------------------------------
reset_all();
$RESPONDER = sub { $_[0] eq $MIXURL ? JSON::PP::decode_json($MIX) : 'FAIL' };
my @st1;
my $calls1 = 0;
$API->warmOfficial('artist-mix', \@MIXRGS, sub { @st1 = @_; $calls1++ });
ok(scalar(@URLS) == 1, '1: nine groups cost ONE request');
ok(($URLS[0] // '') eq $MIXURL, "1: ... the URL the public reply was captured from ('-' raw, limit=9)");
ok($calls1 == 1 && !@st1, '1: ... and the caller is answered once, with no failure');
my $o = $API->peekOfficial('artist-mix') || {};
ok(($o->{ $ID{tdfs} } // -1) == 1 && ($o->{ $ID{radio} } // -1) == 1 && ($o->{ $ID{auto} } // -1) == 1,
   '1: groups with an official release are official');
ok(($o->{ $ID{tribal} } // -1) == 1,
   '1: Tribal Gathering is official through its ONE status-less release (fail-open, as before)');
ok(($o->{ $ID{atel} } // -1) == 0 && ($o->{ $ID{bcast} } // -1) == 0, '1: bootleg-only groups are bootlegs');
ok(($o->{ $ID{vol1} } // -1) == 0,
   '1: a promo-only group is not official (Volume One; the old browse never saw it)');
ok(!exists $o->{ $ID{lnih} }, '1: a group listed with NO releases stays unclassified, i.e. shown');
ok(!exists $o->{ $ID{none} }, '1: a group the reply does not return stays unclassified');
ok(scalar(keys %$o) == 7, '1: ... so seven of nine are classified');
my $r = $API->peekReleaseMap('artist-mix') || {};
my $mixData = JSON::PP::decode_json($MIX);
my ($radioHit) = grep { $_->{id} eq $ID{radio} } @{ $mixData->{'release-groups'} };
ok(scalar(keys %$r) == 67, '1: every listed release is mapped (67)');
ok(scalar(!grep { ($r->{ lc $_->{id} } // '') ne $ID{radio} } @{ $radioHit->{releases} }),
   "1: ... each to its own group (Radio-Aktivität's 38)");
my $t = $API->peekEditions('artist-mix') || {};
ok(scalar(grep { $_ eq 'Tour de France' } @{ $t->{ $ID{tdfs} } || [] }),
   '1: the "Tour de France" edition title is recorded (Simon\'s copy)');
ok(join('|', @{ $t->{ $ID{tribal} } || [] }) eq 'Tribal Gathering (The 1997 Festival Broadcast)',
   "1: only a non-bootleg release's title is recorded ('Tribal Gathering 1997' is bootleg-only)");
ok(!$t->{ $ID{atel} } && !$t->{ $ID{vol1} }, '1: a bootleg or promo title is never a way in');
ok(ref $CACHE{"${KEY}artist-mix"} eq 'HASH', '1: cached under the v5 key');

# A cached map answers at once, with no request.
@URLS = ();
my @st1b = ('UNSET');
$API->warmOfficial('artist-mix', \@MIXRGS, sub { @st1b = @_ });
ok(scalar(@URLS) == 0 && !@st1b, '1: a cached map costs nothing and answers with no failure');

# ---------------------------------------------------------------------------
# 2. 100 TO A REQUEST, each id once, lowercased, `limit` = the ids asked.
# ---------------------------------------------------------------------------
reset_all();
$RESPONDER = gen_responder({});
my @big = map { { mbid => uc gid($_) } } 1 .. 250;
push @big, { mbid => gid(7) }, { title => 'no id' }, 'not a hash';
$API->warmOfficial('artist-big', \@big, sub {});
ok(scalar(@URLS) == 3, '2: 250 groups cost three requests');
my @lims = map { /&limit=(\d+)&/ ? $1 : 0 } @URLS;
ok("@lims" eq '100 100 50', '2: ... of 100, 100 and 50, each limit the number of ids asked');
my @asked = map { /rgid%3A([0-9a-f-]+)/g } @URLS;
my %cnt; $cnt{$_}++ for @asked;
ok(scalar(@asked == 250 && !(grep { $_ > 1 } values %cnt)), '2: ... each id once, the repeat dropped');
ok(scalar(!grep { /[A-F]/ } @asked), '2: ... lowercased');
ok(length($URLS[0]) < 5300, '2: a 100-id URL stays at the measured size (' . length($URLS[0]) . ' chars)');
ok(scalar(keys %{ $API->peekOfficial('artist-big') || {} }) == 250, '2: ... and all 250 are classified');

# ---------------------------------------------------------------------------
# 3. A FAILURE ANYWHERE CACHES NOTHING, answers 'failed' once, and releases the
#    artist: the next visit asks again. A partial map cannot prove a bootleg.
# ---------------------------------------------------------------------------
reset_all();
my $n3 = 0;
my $gen3 = gen_responder({});
$RESPONDER = sub { ++$n3 == 2 ? 'FAIL' : $gen3->(@_) };
my @st3; my $calls3 = 0;
$API->warmOfficial('artist-f', \@big, sub { @st3 = @_; $calls3++ });
ok(scalar(@URLS) == 2, '3: the check stops at the failed request');
ok($calls3 == 1 && ($st3[0] // '') eq 'failed', "3: ... answers 'failed', once");
ok(!defined $CACHE{"${KEY}artist-f"}, '3: ... and caches nothing, not even the first 100');
@URLS = (); $RESPONDER = gen_responder({});
$API->warmOfficial('artist-f', \@big, sub {});
ok(scalar(@URLS) == 3 && defined $CACHE{"${KEY}artist-f"}, '3: the next visit asks again and completes');

reset_all();
$RESPONDER = sub { 'BAD' };
my @st3b;
$API->warmOfficial('artist-bad', \@MIXRGS, sub { @st3b = @_ });
ok(($st3b[0] // '') eq 'failed' && !defined $CACHE{"${KEY}artist-bad"},
   "3: an unreadable reply is a failure too: 'failed', nothing cached");
reset_all();
$RESPONDER = sub { { count => 0 } };
my @st3c;
$API->warmOfficial('artist-nolist', \@MIXRGS, sub { @st3c = @_ });
ok(($st3c[0] // '') eq 'failed' && !defined $CACHE{"${KEY}artist-nolist"},
   "3: ... and so is a reply with no group list");

# ---------------------------------------------------------------------------
# 4. ONE CHECK PER ARTIST. A second caller while it runs (a rebuild) is told
#    'busy' at once and sends nothing; it renders unfiltered, as before.
# ---------------------------------------------------------------------------
reset_all();
$DEFER = 1;
$RESPONDER = gen_responder({});
my (@stA, @stB); my ($cA, $cB) = (0, 0);
$API->warmOfficial('artist-busy', \@big, sub { @stA = @_; $cA++ });
$API->warmOfficial('artist-busy', \@big, sub { @stB = @_; $cB++ });
ok(scalar(@URLS) == 1, '4: the second caller sends nothing');
ok($cB == 1 && ($stB[0] // '') eq 'busy', "4: ... and is answered 'busy' at once");
ok($cA == 0, '4: the first is still waiting');
flush();
ok($cA == 1 && !@stA && scalar(@URLS) == 3, '4: ... and completes normally');
@URLS = ();
$API->warmOfficial('artist-busy', \@big, sub {});
ok(scalar(@URLS) == 0, '4: the artist is released once it settles (a cache hit now)');

# ---------------------------------------------------------------------------
# 5. A CUT-SHORT RELEASE LIST PROVES NOTHING. Every list measured was whole (up
#    to 151 releases), but a group whose own `count` exceeds what is listed can
#    only be judged official from an official release among them.
# ---------------------------------------------------------------------------
reset_all();
my @g5 = map { gid(500 + $_) } 1 .. 4;
$RESPONDER = gen_responder({
    $g5[0] => { count => 9, st => [ 'Bootleg', 'Bootleg' ] },     # cut short, none official
    $g5[1] => { count => 9, st => [ 'Bootleg', 'Official' ] },    # cut short, one official
    $g5[2] => { count => 2, st => [ 'Bootleg', 'Bootleg' ] },     # whole
    $g5[3] => [ 'Bootleg' ],                                       # whole, count from the list
});
$API->warmOfficial('artist-cut', [ map { { mbid => $_ } } @g5 ], sub {});
my $o5 = $API->peekOfficial('artist-cut') || {};
ok(!exists $o5->{ $g5[0] }, '5: a cut-short list with no official release stays unclassified');
ok(($o5->{ $g5[1] } // -1) == 1, '5: ... one official release among it is enough');
ok(($o5->{ $g5[2] } // -1) == 0 && ($o5->{ $g5[3] } // -1) == 0, '5: a whole bootleg-only list is a bootleg');
ok(scalar(keys %{ $API->peekReleaseMap('artist-cut') || {} }) == 7,
   '5: every listed release is still mapped');

# ---------------------------------------------------------------------------
# 6. ONLY THE GROUPS ASKED FOR ARE READ. A hit for any other id is ignored.
# ---------------------------------------------------------------------------
reset_all();
my $stray = gid(999);
my $gen6 = gen_responder({ $stray => [ 'Bootleg' ] });
$RESPONDER = sub {
    my $d = $gen6->(@_);
    push @{ $d->{'release-groups'} }, { id => $stray, title => 'stray', count => 1,
        releases => [ { id => 'stray-r1', title => 'Stray', status => 'Bootleg' } ] };
    return $d;
};
$API->warmOfficial('artist-stray', [ { mbid => gid(1) } ], sub {});
my $o6 = $API->peekOfficial('artist-stray') || {};
ok(!exists $o6->{$stray} && !exists(($API->peekReleaseMap('artist-stray') || {})->{'stray-r1'}),
   '6: a group that was not asked for is ignored');

# ---------------------------------------------------------------------------
# 7. NO GROUPS ON THE PAGE: nothing to ask, an empty map cached, one answer.
# ---------------------------------------------------------------------------
reset_all();
my (@st7, $c7) = ((), 0);
$API->warmOfficial('artist-empty', [], sub { @st7 = @_; $c7++ });
ok(scalar(@URLS) == 0 && $c7 == 1 && !@st7, '7: no groups: no request, one answer, no failure');
ok(ref $CACHE{"${KEY}artist-empty"} eq 'HASH' && !%{ $CACHE{"${KEY}artist-empty"}{o} },
   '7: ... and an empty map is cached, so the page does not ask on every render');
reset_all();
my $c7b = 0;
$API->warmOfficial(undef, \@MIXRGS, sub { $c7b++ });
ok(scalar(@URLS) == 0 && $c7b == 1, '7: no artist: no request, one answer');

# ---------------------------------------------------------------------------
# 8. SOURCE: the release browse is gone, and the check goes through the queue.
# ---------------------------------------------------------------------------
{
    open my $fh, '<', "$FindBin::Bin/../Discography/API.pm" or die $!;
    my $src = do { local $/; <$fh> };
    # Since 0.56.7 the by-id requests live in _officialById, which warmOfficial
    # and the background completion share.
    my ($body) = $src =~ /^(sub warmOfficial \{.*?^\})/ms;
    my ($byid) = $src =~ /^(sub _officialById \{.*?^\})/ms;
    ok(scalar($body && $body =~ /_officialById\(/ && $body !~ /SimpleAsyncHTTP/
              && $byid && $byid =~ /_netGet\(/ && $byid !~ /SimpleAsyncHTTP/),
       '8: warmOfficial sends through the queue (its by-id requests in _officialById)');
    (my $code = $src) =~ s/^\s*#.*$//mg;     # the history in comments may name it
    ok(scalar($code !~ m{release\?artist=}), "8: no code in API.pm browses an artist's releases any more");
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
