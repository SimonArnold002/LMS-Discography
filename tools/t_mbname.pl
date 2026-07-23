#!/usr/bin/env perl
#
# REGRESSION TEST — MusicBrainz's CANONICAL ARTIST NAME must be available
# whenever the alias list is, because three features silently depend on it.
#
# THE FIELD CASE (Simon, 2026-07-22): "a search for b52s returns an empty
# artist for Qobuz and Tidal" / "none of the searches seem consistent".
# Measured live on 0.46.2 against the box, on two independent code paths:
# `peekArtistAliases(127f591a)` returned all ELEVEN aliases while
# `peekArtistName(127f591a)` returned undef. Counted from the debug log — the
# attach loop tried exactly 11 names, i.e. the aliases and NOT the canonical
# name. So:
#
#   * the fold could not relabel the row  (needs the canonical name)
#   * the library attach could not run it (tries canonical first)
#   * 0.45.2's canonical second pass never armed
#
# and the surviving row kept a SERVICE spelling, "B52's". That name is then the
# artist identity for the whole page, and `_norm` splits a hyphen into a space:
#
#   _norm("B52's")     = 'b52s'       ONE token
#   _norm("The B-52s") = 'the b 52s'  candidates, library, MB — all of these
#
# `_artistMatch` is a token-subset test, so {b52s} is a subset of nothing and
# EVERY candidate was rejected: "No releases found", Qobuz and Tidal empty, on
# an artist whose pools were fully cached and healthy.
#
# The CAUSE of the missing cache entry is NOT established — an ASCII canonical
# name written by the same sub reads back fine (verified live on Sea Power:
# "relabelled 'British Sea Power' to MB canonical 'Sea Power'"). So these
# assertions pin the BEHAVIOUR that must hold however the cache misbehaves,
# rather than a theory about why it did.
#
# Standalone -- no LMS install needed:  perl tools/t_mbname.pl
#
use strict;
use warnings;
use FindBin;

my %CACHE;        # the stub cache's backing store
my $DROP_NAME;    # when set, the cache SILENTLY refuses to store the name
my $DATA;         # what the next from_json call should return
my @URLS;         # every URL requested, in order

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
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { $DATA };
    *{'Slim::Networking::SimpleAsyncHTTP::new'} = sub {
        my ($cls, $cb, $errcb, $opt) = @_;
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
# The name key can be made a BLACK HOLE — set() reports success and the value
# is never readable again. That is exactly the state measured in the field.
sub set {
    return 1 if $DROP_NAME && $_[1] =~ /^dsc:mbname:/;
    $CACHE{ $_[1] } = $_[2];
    return 1;
}
sub remove { delete $CACHE{ $_[1] }; return 1 }
package T::Prefs;
sub get { return $_[1] eq 'mb_base_url' ? 'http://mirror:5000/ws/2/' : undef }
sub set { return 1 } sub init { return 1 } sub setChange { return 1 }
package T::Resp;
sub new { bless {}, shift } sub content { '{}' } sub error { 'stub error' }
package T::HTTP;
sub get {
    my ($self, $url) = @_;
    push @URLS, $url;
    $DATA = main::response_for($url);
    $self->{cb}->(T::Resp->new);
}

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::API;

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

# THE REAL MB RECORD, fetched from the mirror during the diagnosis. The
# canonical name carries U+2010 HYPHEN and the aliases are the exact eleven the
# plugin was measured trying — inventing a tidier fixture would not reproduce
# the case (see t_norm.pl 0.44.19 for what a wrong fixture costs).
my $MBID   = '127f591a-7e27-4435-92db-0780f219f3a1';
my $CANON  = "The B\x{2010}52s";
my @ALIAS  = ('B-52s', 'B52', "B52's", "BC-52's", "B\x{2010}52\x{2019}s",
              "The B-52's", "The B.C.52's", "The B52's", 'The B52s',
              "The BC-52's", "The B\x{2010}52\x{2019}s");

our $RESPONDER = sub {
    { name => $CANON, aliases => [ map { { name => $_ } } @ALIAS ] };
};
sub response_for { return $RESPONDER->($_[0]) }

my $API = 'Plugins::Discography::API';

sub reset_all {
    %CACHE = (); @URLS = (); $DROP_NAME = 0;
    # The in-process memo lives for the plugin's lifetime by design, so each
    # scenario uses a DIFFERENT mbid rather than pretending it can be cleared.
}

# ---------------------------------------------------------------------------
# 1. A COLD ARTIST: one fetch, and BOTH values are readable afterwards.
# ---------------------------------------------------------------------------
reset_all();
my $got;
$API->warmArtistAliases($MBID, sub { $got = $_[0] });
ok(scalar(@URLS) == 1, 'a cold artist costs exactly one MB request');
ok(ref $got eq 'ARRAY' && scalar(@$got) == 11, '... returning all 11 aliases');
ok(($API->peekArtistName($MBID) // '') eq $CANON,
   '... and the canonical name is readable');

# ---------------------------------------------------------------------------
# 2. WARM: no request at all. The recovery must not cost a fetch per render.
# ---------------------------------------------------------------------------
@URLS = ();
$API->warmArtistAliases($MBID, sub { $got = $_[0] });
ok(scalar(@URLS) == 0, 'a warm artist costs NO request');
ok(scalar(@$got) == 11, '... and still returns the aliases');

# ---------------------------------------------------------------------------
# 3. THE FIELD STATE: aliases cached, canonical name absent. This is the case
#    that was silently disabling the relabel, the attach and the second pass —
#    it must REFETCH, not shrug.
# ---------------------------------------------------------------------------
my $M3 = '00000000-0000-0000-0000-000000000003';
reset_all();
$CACHE{ 'dsc:alias:2:' . $M3 } = [@ALIAS];   # aliases only, exactly as measured
ok(!defined $API->peekArtistName($M3), 'the field state: aliases cached, no name');
$API->warmArtistAliases($M3, sub { $got = $_[0] });
ok(scalar(@URLS) == 1, '... so the name is refetched');
ok(($API->peekArtistName($M3) // '') eq $CANON, '... and is available afterwards');
ok(scalar(@$got) == 11, '... with the alias list still returned intact');

# ---------------------------------------------------------------------------
# 4. THE RECOVERY IS BOUNDED. If the cache keeps losing the name, a second
#    call must NOT fetch again — a request per render would be a worse bug than
#    the one being fixed. The in-process memo answers instead.
# ---------------------------------------------------------------------------
my $M4 = '00000000-0000-0000-0000-000000000004';
reset_all();
$DROP_NAME = 1;                              # the cache swallows every name write
$CACHE{ 'dsc:alias:2:' . $M4 } = [@ALIAS];
$API->warmArtistAliases($M4, sub { });
ok(scalar(@URLS) == 1, 'a cache that loses the name still only refetches once');
ok(!defined $CACHE{ 'dsc:mbname:1:' . $M4 }, '... the cache genuinely did not keep it');
ok(($API->peekArtistName($M4) // '') eq $CANON,
   '... yet the canonical name is still readable (in-process memo)');
@URLS = ();
$API->warmArtistAliases($M4, sub { });
ok(scalar(@URLS) == 0, '... and a second call fetches nothing');

# ---------------------------------------------------------------------------
# 5. GUARDS. A missing mbid asks nothing; a response with no name must not
#    invent one (a name belonging to nobody is worse than none).
# ---------------------------------------------------------------------------
reset_all();
$API->warmArtistAliases(undef, sub { $got = $_[0] });
ok(scalar(@URLS) == 0 && ref $got eq 'ARRAY' && !@$got,
   'no mbid: no request, empty alias list');

my $M5 = '00000000-0000-0000-0000-000000000005';
reset_all();
local $RESPONDER = sub { { aliases => [ { name => 'Some Alias' } ] } };
$API->warmArtistAliases($M5, sub { });
ok(!defined $API->peekArtistName($M5),
   'a response with no name caches no canonical name');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
