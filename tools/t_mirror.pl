#!/usr/bin/env perl
#
# REGRESSION TEST — a zero-result search on a PROVEN mirror must not be retried
# against the public API.
#
# WHY THIS EXISTS (field, 2026-07-21). The mirror -> public retry assumes a
# zero-result mirror search means an unbuilt Solr index. That is a real failure
# mode (a freshly imported musicbrainz-docker serves browses from Postgres while
# every ?query= returns count:0), but "zero results" is ALSO the correct answer
# to a query that matches nothing — and the code could not tell them apart, so
# every legitimately-empty lookup silently paid a round trip to musicbrainz.org.
#
# Measured on Simon's HEALTHY mirror, one log window, 6 wasted public requests:
#   artist:"janes addiction"          -> count 0   (correctly: an exact Lucene
#   artist:"jane's addiction"         -> count 1    phrase cannot match tokens
#                                                   [jane][s][addiction])
# Three of the six were plain typos, which take the same expensive route.
#
# The rule: ONE non-empty mirror result proves the index is built; from then on
# a 0 is a real 0. Sticky, self-healing, no probe request. Keyed by base so
# repointing re-proves, TTL'd so a mirror that later breaks is retested.
#
# Standalone — no LMS install needed:  perl tools/t_mirror.pl
#
use strict;
use warnings;
use FindBin;

my %CACHE;      # the stub cache's backing store
my $BASE;       # what the mb_base_url pref returns

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
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { '' };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { $main::PROBE_REPLY };
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
sub get { return $CACHE{ $_[1] } }
sub set { $CACHE{ $_[1] } = $_[2]; return 1 }
sub remove { delete $CACHE{ $_[1] }; return 1 }
package T::Resp; sub new { bless {}, shift } sub content { '{}' } sub error { 'err' }
package T::HTTP;
sub get {
    my ($self, $url) = @_;
    push @main::PROBED, $url;
    # undef reply = this host does not answer at all.
    return $self->{err}->(T::Resp->new) unless defined $main::PROBE_REPLY;
    $self->{cb}->(T::Resp->new);
}
package T::Prefs;
sub get { return $_[1] eq 'mb_base_url' ? $BASE : undef }
sub set { return 1 }
sub init { return 1 } sub setChange { return 1 }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::API;

my $verdict = \&Plugins::Discography::API::_mbSearchVerdict;
my $proven  = \&Plugins::Discography::API::_mbSearchProven;

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    # STRUCTURAL GUARD against the list-context trap that has cost time five
    # times in this repo: a bare `=~` (or grep/map) in ok()'s argument list
    # returns the EMPTY LIST on failure, which shifts the test NAME into the
    # condition slot so a FAILING assertion prints as a pass. A missing name is
    # the fingerprint, so refuse it loudly instead of scoring it.
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

my $MIRROR = 'http://plex:5000/ws/2/';
my $OTHER  = 'http://other:5000/ws/2/';
my @HIT    = ({ id => 'x', name => 'Jane’s Addiction' });

# 1. UNPROVEN mirror: an empty result is indistinguishable from a dead index, so
#    the public retry MUST still fire — the original protection, intact.
%CACHE = (); $BASE = $MIRROR;
ok(!$proven->(), 'a fresh mirror starts unproven');
ok($verdict->([], 1, 0) == 1, 'unproven mirror + empty result -> retry public');

# 2. One non-empty result PROVES the index, and proving is the side effect of a
#    normal lookup — no probe request.
ok($verdict->(\@HIT, 1, 0) == 0, 'non-empty result -> no retry');
ok($proven->(), 'a non-empty result proves the index');

# 3. THE BUG: once proven, an empty result is a REAL zero and must not cost a
#    round trip to musicbrainz.org.
ok($verdict->([], 1, 0) == 0, 'PROVEN mirror + empty result -> no public retry');

# 4. The verdict is keyed BY BASE, so repointing at a different mirror re-proves
#    rather than inheriting the old one's clean bill of health.
$BASE = $OTHER;
ok(!$proven->(), 'a different mirror base is not proven by the first one');
ok($verdict->([], 1, 0) == 1, 'unproven second mirror still retries public');
$BASE = $MIRROR;
ok($proven->(), 'the original mirror stays proven');

# 5. Guards on the other arguments.
ok($verdict->([], 0, 0) == 0, 'public base is never "retried publicly"');
ok($verdict->([], 1, 1) == 0, 'the public retry itself never retries again');
ok($verdict->(undef, 1, 0) == 0, 'an unparseable response is not a proven zero');
%CACHE = ();
ok($verdict->(undef, 1, 0) == 0, 'an unparseable response does not prove either');
ok(!$proven->(), '... and leaves the mirror unproven');

# 6. A real 0 must not be provable by an empty array, or the flag would set
#    itself on exactly the case it is meant to gate.
%CACHE = ();
$verdict->([], 1, 0);
ok(!$proven->(), 'an empty result never proves the index');

# ---------------------------------------------------------------------------
# 7. MIRROR AUTO-DETECT (0.47.3). The probe validates a candidate by fetching a
#    known artist and comparing the NAME — which is right, and is exactly why a
#    wrong MB_PROBE_MBID was invisible for two releases: a 404 on the probe
#    artist looks identical to "nothing is running on :5000". These assertions
#    cover the LOGIC; that the constant is a real artist is checked live by
#    tools/syntax_check.sh, because no offline test can know it.
# ---------------------------------------------------------------------------
our (@PROBED, $PROBE_REPLY);
my $API = 'Plugins::Discography::API';

# A weak backstop only, and worth being honest about: the BROKEN constant was
# itself well-formed, so this would not have caught it. Only the live check in
# tools/syntax_check.sh can.
ok(scalar(Plugins::Discography::API::MB_PROBE_MBID()
          =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/),
   'the probe mbid is a well-formed MBID');

# A candidate that answers as the expected artist is adopted...
%CACHE = (); $BASE = ''; @PROBED = ();
$PROBE_REPLY = { name => Plugins::Discography::API::MB_PROBE_NAME() };
$API->autodetectMirror(sub {});
ok(scalar(grep { /\Q@{[ Plugins::Discography::API::MB_PROBE_MBID() ]}\E/ } @PROBED),
   'the probe asks for MB_PROBE_MBID');
# scalar(): a bare `=~` in an argument list returns the EMPTY LIST on failure,
# which shifts the test NAME into the condition slot so the assertion "passes".
# Caught here by mutating the name comparison in autodetectMirror and finding
# this test still green — the 0.43.5 trap, fifth sighting in this repo.
ok(scalar(($CACHE{'dsc:mbmirror:v1'} // '') =~ m{^http://localhost:5000/}),
   'a validating mirror is adopted and cached');

# ...and one that answers with something else is NOT. This is the guard that
# stops another :5000 service (AirPlay, a Flask app) being taken for a mirror.
%CACHE = (); @PROBED = ();
$PROBE_REPLY = { name => 'Some Other Service' };
$API->autodetectMirror(sub {});
ok(defined $CACHE{'dsc:mbmirror:v1'} && $CACHE{'dsc:mbmirror:v1'} eq '',
   'a responder that is not MusicBrainz is rejected (probed-none cached)');
ok(scalar(@PROBED) == 2, '... after trying BOTH same-host candidates');

# Nothing answering at all = probed-none, cached so it does not re-probe today.
%CACHE = (); @PROBED = ();
$PROBE_REPLY = undef;
$API->autodetectMirror(sub {});
ok(defined $CACHE{'dsc:mbmirror:v1'} && $CACHE{'dsc:mbmirror:v1'} eq '',
   'no responder -> probed-none');

# A MANUAL base always wins and costs no probe at all.
%CACHE = (); @PROBED = (); $BASE = $MIRROR;
$PROBE_REPLY = { name => Plugins::Discography::API::MB_PROBE_NAME() };
$API->autodetectMirror(sub {});
ok(scalar(@PROBED) == 0, 'a manually-set base is never probed over');
ok(!defined $CACHE{'dsc:mbmirror:v1'}, '... and nothing is cached for it');

# Already probed within the TTL -> no second probe.
%CACHE = ('dsc:mbmirror:v1' => ''); @PROBED = (); $BASE = '';
$API->autodetectMirror(sub {});
ok(scalar(@PROBED) == 0, 'a cached verdict is not re-probed');
$BASE = $MIRROR;

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
