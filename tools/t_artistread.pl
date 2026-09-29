#!/usr/bin/env perl
#
# REGRESSION TEST — ONE read of the MusicBrainz artist resource serves both the
# alias lookup and the band-member lookup (stage 1 of
# docs/mb-efficiency-and-community-api-analysis.md, A7 #1; 2026-09-29).
#
# warmArtistAliases used to ask for `artist/<mbid>?inc=aliases` and
# warmBandMembers for `artist/<mbid>?inc=artist-rels`: the same resource, twice,
# on every cold page whose artist name MusicBrainz shares with other acts.
# MEASURED on the public API (Radiohead, 2026-09-29): `?inc=aliases+artist-rels`
# returns exactly the alias list of the first call and exactly the relations of
# the second, for 974 bytes more than the relations call alone. So both now go
# through API::_readArtist, which fills the alias list, MB's canonical name, the
# band list and the collaboration candidates from one response.
#
# THE FIXTURE IS CAPTURED, NOT WRITTEN: tools/fixtures/mb_artist_eno_aliases_
# artistrels.json is the public reply to
#   https://musicbrainz.org/ws/2/artist/ff95eb47-41c4-4f7f-a104-cdc30f02e872
#     ?inc=aliases+artist-rels&fmt=json
# fetched 2026-09-29, byte for byte. Brian Eno carries six aliases (one
# Japanese), five "member of band" links, three collaborations and five other
# relation types that must be ignored — a hand-built fixture would only hold the
# shapes this suite's author expected.
#
# Standalone -- no LMS install needed:  perl tools/t_artistread.pl
#
use strict;
use warnings;
use FindBin;
use JSON::PP ();

our (%CACHE, $DATA, @URLS, @DEFERRED, $DEFER, $FAILMODE, $BADJSON);

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
    # $BADJSON models a 200 whose body is not JSON (an HTML error page from a
    # proxy, a truncated read): from_json DIES, as JSON::XS does.
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub {
        die "malformed JSON string\n" if $main::BADJSON;
        return $main::DATA;
    };
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
sub get    { return $main::CACHE{ $_[1] } }
sub set    { $main::CACHE{ $_[1] } = $_[2]; return 1 }
sub remove { delete $main::CACHE{ $_[1] }; return 1 }
package T::Prefs;
sub get { return $_[1] eq 'mb_base_url' ? 'http://mirror:5000/ws/2/' : undef }
sub set { return 1 } sub init { return 1 } sub setChange { return 1 }
package T::Resp;
sub new { bless {}, shift } sub content { '{}' } sub error { '503 Service Unavailable' }
package T::HTTP;
sub get {
    my ($self, $url) = @_;
    push @main::URLS, $url;
    my $fire = sub {
        return $self->{err}->(T::Resp->new) if $main::FAILMODE;
        $main::DATA = main::response_for($url);
        $self->{cb}->(T::Resp->new);
    };
    # $DEFER holds the response open, so a second caller genuinely arrives while
    # the first request is in flight. Answering synchronously would cache the
    # result first, and the join would never be exercised at all.
    if ($main::DEFER) { push @main::DEFERRED, $fire } else { $fire->() }
}

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::API;
my $API = 'Plugins::Discography::API';

# THE QUEUE IS NOT THIS SUITE'S SUBJECT (same reasoning as t_perf.pl): pacing is
# API::_netGet's job and tools/t_netqueue.pl owns it on a fake clock. Bypassed
# here so the transport stub sees each request as the code issues it.
{
    no strict 'refs'; no warnings 'redefine';
    *{'Plugins::Discography::API::_netGet'} = sub {
        my ($url, $ok, $err, %opt) = @_;
        return Slim::Networking::SimpleAsyncHTTP->new($ok, $err, \%opt)->get($url);
    };
}

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

my $ENO = 'ff95eb47-41c4-4f7f-a104-cdc30f02e872';
# A GROUP, captured the same way and the same day
# (artist/a74b1b7f-71a5-4011-9441-d0b5e4122711?inc=aliases+artist-rels): its 19
# "member of band" links are all BACKWARD — its members, not bands it is in.
my $RH  = 'a74b1b7f-71a5-4011-9441-d0b5e4122711';
my %RAW;
for ([ $ENO, 'eno' ], [ $RH, 'radiohead' ]) {
    open my $fh, '<:raw', "$FindBin::Bin/fixtures/mb_artist_$_->[1]_aliases_artistrels.json"
        or die "fixture: $!";
    local $/;
    $RAW{ $_->[0] } = <$fh>;
}
# Decoded afresh for every response, as from_json would: the code must never be
# able to pass by holding on to a structure an earlier test handed it.
sub response_for {
    my ($url) = @_;
    return JSON::PP::decode_json($RAW{$1})
        if $url =~ m{/artist/([0-9a-f-]{36})\?inc=aliases\+artist-rels&fmt=json$} && $RAW{$1};
    return {};
}
sub flush {
    for (1 .. 10) {
        my @d = @DEFERRED;
        last unless @d;
        @DEFERRED = ();
        $_->() for @d;
    }
}
sub reset_all {
    %CACHE = (); @URLS = (); @DEFERRED = ();
    $DEFER = 0; $FAILMODE = 0; $BADJSON = 0;
}
my $names = sub { join ',', map { $_->{name} } @{ $_[0] || [] } };
my $BANDS   = 'Roxy Music,801,The Portsmouth Sinfonia,Passengers,MDH Band';
my $COLLABS = 'Fripp & Eno,Harmonia 76,N.M.L. NO MORE LANDMINE';
my $JA      = "\x{30d6}\x{30e9}\x{30a4}\x{30a2}\x{30f3}\x{30fb}\x{30a4}\x{30fc}\x{30ce}";

# ---------------------------------------------------------------------------
# 1. THE BAND LOOKUP FIRST (every cold artist page): one request, and it fills
#    the aliases and the canonical name as well as the bands.
# ---------------------------------------------------------------------------
reset_all();
my $bandCbs = 0;
$API->warmBandMembers($ENO, sub { $bandCbs++ });
ok(scalar(@URLS) == 1, '1: a cold band lookup costs exactly one request');
ok(scalar(($URLS[0] // '') =~ m{/artist/\Q$ENO\E\?inc=aliases\+artist-rels&fmt=json$}),
   '1: ... for the artist WITH its aliases (inc=aliases+artist-rels)');
ok($bandCbs == 1, '1: ... and calls back exactly once');
ok($names->($API->peekBands($ENO)) eq $BANDS,
   '1: the bands are the five forward "member of band" links, in MB order');
ok($names->($CACHE{"dsc:collabcand:v1:$ENO"}) eq $COLLABS,
   '1: the collaboration candidates are the three forward collaborations');
my $al = $API->peekArtistAliases($ENO);
ok(ref $al eq 'ARRAY' && scalar(@$al) == 6, '1: ... and the six aliases are cached from the same reply');
ok(scalar(grep { $_ eq $JA } @{ $al || [] }) == 1,
   '1: ... the Japanese alias among them, as a character string');
ok(($API->peekArtistName($ENO) // '') eq 'Brian Eno', "1: ... and MB's canonical name is readable");

@URLS = ();
my $got;
$API->warmArtistAliases($ENO, sub { $got = $_[0] });
ok(scalar(@URLS) == 0, '1: the alias lookup after it costs NO request');
ok(ref $got eq 'ARRAY' && scalar(@$got) == 6, '1: ... and still answers all six aliases');

# ---------------------------------------------------------------------------
# 2. THE ALIAS LOOKUP FIRST (an ambiguous name: the streaming warm asks for the
#    aliases before the serial MB chain reaches the bands). This is where the
#    request is saved: two lookups used to cost two requests.
# ---------------------------------------------------------------------------
reset_all();
$got = undef;
$API->warmArtistAliases($ENO, sub { $got = $_[0] });
ok(scalar(@URLS) == 1, '2: a cold alias lookup costs one request');
ok(ref $got eq 'ARRAY' && scalar(@$got) == 6, '2: ... and answers the six aliases');
$bandCbs = 0;
$API->warmBandMembers($ENO, sub { $bandCbs++ });
ok(scalar(@URLS) == 1, '2: the band lookup after it costs NO second request');
ok($bandCbs == 1, '2: ... calls back exactly once');
ok($names->($API->peekBands($ENO)) eq $BANDS, '2: ... with the bands already cached');

# ---------------------------------------------------------------------------
# 3. CALLERS THAT ARRIVE MID-FLIGHT JOIN THE ONE REQUEST, and the band caller
#    WAITS for it: answering early would push the bands off the first render.
# ---------------------------------------------------------------------------
reset_all();
$DEFER = 1;
my ($gotA, $gotC, $cbB) = (undef, undef, 0);
$API->warmArtistAliases($ENO, sub { $gotA = $_[0] });
$API->warmBandMembers($ENO, sub { $cbB++ });
$API->warmArtistAliases($ENO, sub { $gotC = $_[0] });
ok(scalar(@URLS) == 1, '3: three callers mid-flight make ONE request');
ok(!defined $gotA && !defined $gotC && $cbB == 0,
   '3: ... and nobody is answered before it lands (the band caller waits)');
flush();
ok($cbB == 1, '3: the waiting band caller is answered exactly once');
ok($names->($API->peekBands($ENO)) eq $BANDS, '3: ... AFTER the bands were cached');
ok(ref $gotA eq 'ARRAY' && scalar(@$gotA) == 6, '3: the first alias caller gets the aliases');
ok(ref $gotC eq 'ARRAY' && scalar(@$gotC) == 6, '3: ... and so does the queued one');
# The marker must be released, or the artist would be wedged for the life of
# the process with no request in flight.
%CACHE = (); @URLS = (); $DEFER = 0;
$API->warmBandMembers($ENO, sub {});
ok(scalar(@URLS) == 1, '3: the in-flight marker is released once it settles');

# ---------------------------------------------------------------------------
# 4. A FAILED REQUEST SETTLES EVERY WAITER and caches NOTHING (retried next
#    visit) — the render waits on the band lookup, so a queue drained only on
#    success would hang the page.
# ---------------------------------------------------------------------------
reset_all();
$DEFER = 1; $FAILMODE = 1;
my ($eA, $eB) = ('UNSET', 0);
$API->warmArtistAliases($ENO, sub { $eA = $_[0] });
$API->warmBandMembers($ENO, sub { $eB++ });
flush();
ok(ref $eA eq 'ARRAY' && !@$eA, '4: a failure answers the alias caller with an empty list');
ok($eB == 1, '4: ... and the band caller exactly once');
ok(!defined $CACHE{"dsc:alias:2:$ENO"} && !defined $CACHE{"dsc:bands:v2:$ENO"}
   && !defined $CACHE{"dsc:collabcand:v1:$ENO"} && !defined $CACHE{"dsc:mbname:1:$ENO"},
   '4: ... and nothing at all is cached');
$DEFER = 0; $FAILMODE = 0; @URLS = ();
$API->warmBandMembers($ENO, sub {});
ok(scalar(@URLS) == 1 && $names->($API->peekBands($ENO)) eq $BANDS,
   '4: the next visit asks again and caches normally');

# ---------------------------------------------------------------------------
# 5. AN UNREADABLE 200 caches nothing either. The alias fetch used to cache an
#    EMPTY alias list for a month here, silently disabling the alias retry for
#    that artist; the band lookup cached nothing. One request, one rule.
# ---------------------------------------------------------------------------
reset_all();
$BADJSON = 1;
my ($uA, $uB) = ('UNSET', 0);
$API->warmArtistAliases($ENO, sub { $uA = $_[0] });
$API->warmBandMembers($ENO, sub { $uB++ });
ok(ref $uA eq 'ARRAY' && !@$uA && $uB == 1, '5: an unreadable reply still answers both callers');
ok(!defined $CACHE{"dsc:alias:2:$ENO"}, '5: ... and caches NO alias list (it used to pin an empty one)');
ok(!defined $CACHE{"dsc:bands:v2:$ENO"}, '5: ... and no band list');
ok(scalar(@URLS) == 2, '5: ... so the second caller asked again rather than trusting it');
$BADJSON = 0; @URLS = ();
$API->warmArtistAliases($ENO, sub { $uA = $_[0] });
ok(scalar(@URLS) == 1 && scalar(@$uA) == 6, '5: a readable reply later is fetched and used');

# ---------------------------------------------------------------------------
# 6. GUARDS, unchanged: no mbid asks nothing; a band list with a candidate list
#    is a cache hit; a band list ALONE (written before collaborations existed)
#    is not, or the candidates would never be noted.
# ---------------------------------------------------------------------------
reset_all();
my ($nA, $nB) = ('UNSET', 0);
$API->warmArtistAliases(undef, sub { $nA = $_[0] });
$API->warmBandMembers(undef, sub { $nB++ });
ok(scalar(@URLS) == 0 && ref $nA eq 'ARRAY' && !@$nA && $nB == 1,
   '6: no mbid: no request, and both callers are answered');
$CACHE{"dsc:bands:v2:$ENO"}      = [];
$CACHE{"dsc:collabcand:v1:$ENO"} = [];
$API->warmBandMembers($ENO, sub {});
ok(scalar(@URLS) == 0, '6: bands + candidates cached: the band lookup is a cache hit');
delete $CACHE{"dsc:collabcand:v1:$ENO"};
$API->warmBandMembers($ENO, sub {});
ok(scalar(@URLS) == 1, '6: a band list alone still triggers a read');

# ---------------------------------------------------------------------------
# 8. A GROUP'S OWN MEMBERS ARE NOT BANDS IT IS IN. Radiohead's reply carries 19
#    "member of band" links, every one BACKWARD. Only a forward link means "this
#    artist is a member of that band"; without the direction test all 19
#    members would be listed under "Also a member of" on Radiohead's page.
# ---------------------------------------------------------------------------
reset_all();
$API->warmBandMembers($RH, sub {});
my $rhBands = $API->peekBands($RH);
ok(ref $rhBands eq 'ARRAY' && !@$rhBands, '8: a group with 19 backward member links has NO bands');
ok(ref $CACHE{"dsc:collabcand:v1:$RH"} eq 'ARRAY' && !@{ $CACHE{"dsc:collabcand:v1:$RH"} },
   '8: ... and no collaboration candidates');
ok(scalar(@{ $API->peekArtistAliases($RH) || [] }) == 5 && ($API->peekArtistName($RH) // '') eq 'Radiohead',
   "8: ... while its five aliases and MB's name are cached from the same reply");

# ---------------------------------------------------------------------------
# 7. SOURCE: both lookups go through the one reader, and the reader goes
#    through the queue. A stub cannot prove the absence of a request the code
#    never makes, so this is asserted on the shipped source.
# ---------------------------------------------------------------------------
{
    open my $fh, '<', "$FindBin::Bin/../Discography/API.pm" or die $!;
    my $src = do { local $/; <$fh> };
    my ($rd) = $src =~ /^(sub _readArtist \{.*?^\})/ms;
    ok(scalar($rd && $rd =~ /_netGet\(/ && $rd !~ /SimpleAsyncHTTP/),
       '7: _readArtist sends through the queue and builds no transport of its own');
    for my $s (qw(warmArtistAliases warmBandMembers)) {
        my ($body) = $src =~ /^(sub \Q$s\E \{.*?^\})/ms;
        ok(scalar($body && $body =~ /_readArtist\(/ && $body !~ /_netGet\(/),
           "7: $s asks _readArtist and sends nothing itself");
    }
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
