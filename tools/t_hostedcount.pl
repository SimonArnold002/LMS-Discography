#!/usr/bin/env perl
#
# RELEASE COUNTS FROM THE COMMUNITY API FIRST (stage 3 step 2, 2026-09-30).
#
# warmCandidateCounts asks api.lms-community.org for each uncounted artist and
# uses ONLY an answer above zero for the mbid it sent; everything else asks
# MusicBrainz exactly as before (analysis §A12.6 step 2; ledger A2 `THE
# COMMUNITY API IS ONE REQUEST AT A TIME, MAI'S RATE`):
#   * zero: the service lists only groups where the artist is credited FIRST;
#   * a different mbid in the reply: an unknown mbid is answered by NAME;
#   * a 429, a timeout, an error, or the bucket backing off (failFast).
# Driven through the REAL warmCandidateCounts, _hostedCount and the REAL queue
# (_netGet / _netPump / _netSend) on a FAKE CLOCK: nothing waits, nothing is
# sent anywhere.
#
# Standalone -- no LMS install needed:  perl tools/t_hostedcount.pl
#
use strict;
use warnings;
use FindBin;
use JSON::XS ();

our $now = 1_000_000.0;
our (@TIMERS, @SENT, %CACHE);

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
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Cache' };
    *{'Plugins::Discography::DB::store'}   = sub { bless {}, 'T::Cache' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Utils::Strings::cstring'}     = sub { $_[1] };
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { JSON::XS::encode_json($_[0]) };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { JSON::XS::decode_json($_[0]) };
    *{'Slim::Utils::Timers::setTimer'}     = sub { my $t = [@_]; push @main::TIMERS, $t; $t };
    *{'Slim::Utils::Timers::killSpecific'} = sub {
        my ($t) = @_; @main::TIMERS = grep { $_ != $t } @main::TIMERS; 1 };
    *{'Slim::Utils::Timers::killTimers'}   = sub { 1 };
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
package T::Cache;
sub get    { return $main::CACHE{ $_[1] } }
sub set    { $main::CACHE{ $_[1] } = $_[2]; return 1 }
sub remove { delete $main::CACHE{ $_[1] }; return 1 }
package T::Prefs;
sub get { return $_[1] eq 'mb_base_url' ? 'https://musicbrainz.org/ws/2/' : undef }
sub set { 1 } sub init { 1 } sub setChange { 1 }
# The async object (->error, ->content) and the response (->code, ->header):
# two objects, as SimpleAsyncHTTP really hands them over (see t_netqueue.pl).
package T::HTTP;
sub get     { my ($s, $url, @h) = @_; $s->{url} = $url; $s->{headers} = { @h }; push @main::SENT, $s; $s }
sub code    { $_[0]{code}  // 0 }
sub error   { $_[0]{error} // '' }
sub content { $_[0]{body}  // '' }
package T::RESP;
sub new     { my ($c, %f) = @_; bless { %f }, $c }
sub code    { $_[0]{code} // 0 }
sub content { $_[0]{body} // '' }
sub header  { $_[0]{hdr}{ $_[1] } }
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

my %NET0 = map { $_ => { %{ $Plugins::Discography::API::NET{$_} } } }
           keys %Plugins::Discography::API::NET;
sub reset_all {
    @TIMERS = (); @SENT = (); %CACHE = (); $now = 1_000_000.0;
    %Plugins::Discography::API::NET = map { $_ => { %{ $NET0{$_} }, queue => [] } } keys %NET0;
}
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
# Answer / fail a sent request. Never die on a missing one: report it.
sub answer {
    my ($r, $data) = @_;
    return ok(0, 'expected a request to answer, but none was sent') unless ref $r;
    $r->{body} = ref $data ? JSON::XS::encode_json($data) : $data;
    $r->{cb}->($r);
}
sub failWith {
    my ($r, $code) = @_;
    return ok(0, "expected a request to fail with $code, but none was sent") unless ref $r;
    $r->{code} = $code; $r->{error} = "HTTP $code";
    $r->{err}->($r, "HTTP $code", T::RESP->new(code => $code, hdr => {}));
}
sub timeoutWith {
    my ($r) = @_;
    return ok(0, 'expected a request to time out, but none was sent') unless ref $r;
    $r->{error} = 'Timed out waiting for data';
    $r->{err}->($r, 'Timed out waiting for data', T::RESP->new(code => 500, hdr => {}));
}
sub hosted { grep { $_->{url} =~ m{^https://api\.lms-community\.org/} } @SENT }
sub mb     { grep { $_->{url} =~ m{^https://musicbrainz\.org/} } @SENT }
sub disco  { my ($mbid, $n) = @_; { mbid => $mbid, discography => [ map { { mbid => "rg$_" } } 1 .. $n ] } }
sub count  { $CACHE{ 'dsc:rgcount:1:' . lc $_[0] } }

my $M1 = '11111111-1111-1111-1111-111111111111';
my $M2 = '22222222-2222-2222-2222-222222222222';
my $M3 = '33333333-3333-3333-3333-333333333333';
my $GAP  = $A->can('NET_GAP_MB')->();
my $B0   = $A->can('NET_BACKOFF_START')->();
my $SLOW = $A->can('NET_SLOW_BACKOFF')->();

# ---------------------------------------------------------------------------
# 1. A count above zero for the mbid sent is used; MusicBrainz is not asked.
# ---------------------------------------------------------------------------
reset_all();
my $done = 0;
$A->warmCandidateCounts([ { mbid => $M1, name => 'Radiohead' } ], sub { $done++ });
ok(scalar(hosted() == 1 && mb() == 0), '1: the community API is asked first');
my ($h) = hosted();
ok(scalar(($h->{headers}{'X-LMS-Plugin-ID'} // '') eq 'Plugins::Discography::Plugin'),
   '1: ... registering the plugin with its id header');
ok(scalar($h->{url} eq 'https://api.lms-community.org/music/artist/Radiohead/discography?mbid=' . $M1),
   '1: ... for the candidate by name, the mbid overriding it');
answer($h, disco($M1, 42));
ok(scalar((count($M1) // -1) == 42 && mb() == 0 && $done == 1),
   '1: 42 groups stored, MusicBrainz never asked, callback once');

# ---------------------------------------------------------------------------
# 2-4, 7. Everything else asks MusicBrainz, and MusicBrainz's answer is stored.
# ---------------------------------------------------------------------------
my @cases = (
    [ 'zero (first credits only)', sub { answer($_[0], disco($M1, 0)) } ],
    [ 'a different mbid (answered by NAME)', sub { answer($_[0], disco($M2, 9)) } ],
    [ 'an unreadable reply', sub { answer($_[0], '{"not json') } ],
    [ 'an HTTP 500', sub { failWith($_[0], 500) } ],
);
for my $c (@cases) {
    my ($what, $how) = @$c;
    reset_all();
    $done = 0;
    $A->warmCandidateCounts([ { mbid => $M1, name => 'Kraftwerk' } ], sub { $done++ });
    $how->((hosted())[0]);
    my ($m) = mb();
    ok(scalar($m && $m->{url} =~ m{release-group\?artist=$M1&fmt=json&limit=1$}),
       "2: $what -> MusicBrainz is asked");
    ok(scalar(!defined count($M1) && $done == 0), "2: ... nothing stored yet, the caller still waits");
    answer($m, { 'release-group-count' => 3 });
    ok(scalar((count($M1) // -1) == 3 && $done == 1), "2: ... MusicBrainz's count stored, callback once");
}

# ---------------------------------------------------------------------------
# 5. A 429: MusicBrainz is asked AT ONCE, and while the deadline stands the next
#    count is not sent to the community API at all.
# ---------------------------------------------------------------------------
reset_all();
$done = 0;
$A->warmCandidateCounts([ { mbid => $M1, name => 'Bush' } ], sub { $done++ });
failWith((hosted())[0], 429);
ok(scalar(mb() == 1), '5: a 429 sends the count to MusicBrainz at once, no wait');
answer((mb())[0], { 'release-group-count' => 11 });
ok(scalar((count($M1) // -1) == 11 && $done == 1), "5: ... and MusicBrainz's count is used");
my $before = hosted();
$A->warmCandidateCounts([ { mbid => $M2, name => 'Genesis' } ], sub { $done++ });
ok(scalar(hosted() == $before), '5: during the deadline the next count is not sent to the community API');
advance($now + $GAP);   # MusicBrainz's own 1.1 s gap after the previous send
ok(scalar(mb() == 2), '5: ... it goes straight to MusicBrainz');
answer((mb())[1], { 'release-group-count' => 4 });
advance($now + $B0 + 0.01);
$A->warmCandidateCounts([ { mbid => $M3, name => 'Madness' } ], sub { $done++ });
ok(scalar(hosted() == $before + 1), '5: once the deadline passes, the community API is asked again');

# ---------------------------------------------------------------------------
# 6. A timeout: MusicBrainz is asked, and the community API rests for 30 s.
# ---------------------------------------------------------------------------
reset_all();
$done = 0;
$A->warmCandidateCounts([ { mbid => $M1, name => 'Air' } ], sub { $done++ });
timeoutWith((hosted())[0]);
ok(scalar(mb() == 1), '6: a timeout sends the count to MusicBrainz');
answer((mb())[0], { 'release-group-count' => 8 });
$before = hosted();
$A->warmCandidateCounts([ { mbid => $M2, name => 'Beirut' } ], sub { $done++ });
ok(scalar(hosted() == $before), "6: for ${SLOW}s after it, counts skip the community API");
advance($now + $SLOW + 0.01);
$A->warmCandidateCounts([ { mbid => $M3, name => 'Blondie' } ], sub { $done++ });
ok(scalar(hosted() == $before + 1), '6: ... and use it again afterwards');

# ---------------------------------------------------------------------------
# 8. SEVERAL CANDIDATES: the community API is asked one at a time with no gap;
#    what falls to MusicBrainz goes one at a time; the callback waits for all.
# ---------------------------------------------------------------------------
reset_all();
$done = 0;
$A->warmCandidateCounts([ { mbid => $M1, name => 'A' }, { mbid => $M2, name => 'B' },
                          { mbid => $M3, name => 'C' } ], sub { $done++ });
ok(scalar(hosted() == 1), '8: one community-API request in flight');
answer((hosted())[0], disco($M1, 0));           # -> MusicBrainz
ok(scalar(hosted() == 2), '8: the next is sent the moment the first answers');
answer((hosted())[1], disco($M2, 0));           # -> MusicBrainz
answer((hosted())[2], disco($M3, 5));           # used
ok(scalar(mb() == 1 && @{ $Plugins::Discography::API::NET{mb}{queue} } == 0),
   '8: two fell to MusicBrainz, and ONE is in its queue at a time');
ok(scalar($done == 0), '8: the callback waits for the MusicBrainz counts');
answer((mb())[0], { 'release-group-count' => 1 });
advance($now + $GAP);
ok(scalar(mb() == 2), '8: the second MusicBrainz count follows at its 1.1 s gap');
answer((mb())[1], { 'release-group-count' => 0 });
ok(scalar($done == 1 && count($M1) == 1 && count($M2) == 0 && count($M3) == 5),
   '8: all three counts stored (1, 0, 5), callback once');

# ---------------------------------------------------------------------------
# 9. Cached counts are skipped; a duplicate mbid is counted once.
# ---------------------------------------------------------------------------
reset_all();
$CACHE{ 'dsc:rgcount:1:' . $M1 } = 7;
$done = 0;
$A->warmCandidateCounts([ { mbid => $M1 } ], sub { $done++ });
ok(scalar(@SENT == 0 && $done == 1), '9: a cached count sends nothing');
$done = 0;
$A->warmCandidateCounts([ { mbid => $M2, name => 'X' }, { mbid => uc $M2, name => 'X' } ], sub { $done++ });
# One in flight hides a duplicate until the first answers, so answer it first.
answer((hosted())[0], disco($M2, 2));
ok(scalar(hosted() == 1 && $done == 1), '9: the same mbid twice is asked once');

# ---------------------------------------------------------------------------
# 10. THE NAME IN THE PATH: the candidate's, else MusicBrainz's name for the
#     mbid, else a placeholder; encoded per byte, a '/' included.
# ---------------------------------------------------------------------------
# Both real shapes of a name: CHARACTERS (decoded JSON, the same-name set) and
# UTF-8 OCTETS (an LMS contributor name). A bare "\x{f6}" literal is neither — an
# unflagged Latin-1 byte no caller ever passes — so the fixture is upgraded.
my $chars = "AC/DC Mot\x{f6}rhead"; utf8::upgrade($chars);
my $octets = "AC/DC Mot\xc3\xb6rhead";
for my $n ([ 'characters', $chars ], [ 'UTF-8 octets', $octets ]) {
    reset_all();
    $A->warmCandidateCounts([ { mbid => $M1, name => $n->[1] } ], sub {});
    ok(scalar((hosted())[0]{url} =~ m{/artist/AC%2FDC%20Mot%C3%B6rhead/discography\?mbid=$M1$}),
       "10: a '/' and a non-ASCII letter are encoded per byte ($n->[0])");
}
reset_all();
$A->can('_setMbName')->($M2, 'Sea Power');
$A->warmCandidateCounts([ { mbid => $M2 } ], sub {});
ok(scalar((hosted())[0]{url} =~ m{/artist/Sea%20Power/discography\?mbid=$M2$}),
   "10: no name given: MusicBrainz's name for the mbid");
reset_all();
$A->warmCandidateCounts([ { mbid => uc $M3 } ], sub {});
ok(scalar((hosted())[0]{url} =~ m{/artist/_/discography\?mbid=$M3$}),
   '10: no name known at all: a placeholder, and the mbid lowercased');

# ---------------------------------------------------------------------------
# 12. MusicBrainz failing too: nothing is cached (a failure is not "none"), and
#     the caller is still answered.
# ---------------------------------------------------------------------------
reset_all();
$done = 0;
$A->warmCandidateCounts([ { mbid => $M1, name => 'Z' } ], sub { $done++ });
failWith((hosted())[0], 500);
failWith((mb())[0], 500);
ok(scalar(!defined count($M1) && $done == 1), '12: both failing caches nothing and still answers');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
