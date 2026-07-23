#!/usr/bin/env perl
#
# REGRESSION TEST — the artist-name resolver must CAPTURE MusicBrainz's
# canonical name, because that is the name the streaming services file a
# RENAMED act under.
#
# WHY THIS EXISTS (full-library sweep, 2026-07-22). Simon's library has the band
# as "British Sea Power"; they renamed to "Sea Power" in 2021, so MusicBrainz
# carries the old name only as an ALIAS. Measured live on the box:
#
#   search "British Sea Power" (old name) -> Qobuz ERROR / absent
#   search "Sea Power"          (new name) -> Qobuz PRESENT
#   candidates Tidal/'British Sea Power':  32  e.g. Sea Power - Everything Was...
#   candidates Deezer/'British Sea Power': 26  e.g. Sea Power - Disco Elysium
#   candidates Qobuz/'British Sea Power':  <no pool>
#
# Tidal and Deezer absorb the old name themselves and return the renamed
# catalogue (which still MATCHES, because _artistMatch is a token-subset test
# and {sea,power} is a subset of {british,sea,power}). Qobuz does not, and
# settled unresolved -- the whole Qobuz catalogue missing, 24/52 matched.
#
# The plugin already resolved the MBID *through the alias field*, so MB's
# canonical name was sitting in the response it had just paid for -- and it was
# thrown away. Capturing it is free, and it is what lets the existing 0.43.6
# retry ask Qobuz for "Sea Power".
#
# Standalone -- no LMS install needed:  perl tools/t_canon.pl
#
use strict;
use warnings;
use FindBin;

my %CACHE;      # the stub cache's backing store
my $DATA;       # what the next from_json call should return
my @URLS;       # every URL requested, in order

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
    # The HTTP stub decides what the response "is"; from_json just hands it over.
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
sub set { $CACHE{ $_[1] } = $_[2]; return 1 }
sub remove { delete $CACHE{ $_[1] }; return 1 }
package T::Prefs;
sub get { return $_[1] eq 'mb_base_url' ? 'http://mirror:5000/ws/2/' : undef }
sub set { return 1 }
sub init { return 1 } sub setChange { return 1 }
package T::Resp;
sub new { bless {}, shift } sub content { '{}' } sub error { 'stub error' }
package T::HTTP;
# The response for a URL is whatever main::respond_with has queued for it.
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

# Queued per-request behaviour: a coderef taking the URL and returning the
# decoded body. Set fresh by each scenario.
our $RESPONDER = sub { { artists => [] } };
sub response_for { return $RESPONDER->($_[0]) }

my $MBID = '8830afec-83b3-4213-aad0-f6377f1d73ac';

# ---------------------------------------------------------------------------
# 1. THE FIELD CASE. The `artist:` field finds nothing (MB knows the old name
#    only as an alias); the `alias:` field returns the artist under its CURRENT
#    name. The canonical name must be captured, NOT the name that was asked for.
# ---------------------------------------------------------------------------
%CACHE = (); @URLS = ();
$RESPONDER = sub {
    my ($url) = @_;
    # Sea Power has a real discography — answer the 0.47.1 zero-release check
    # truthfully, or the resolver rightly goes looking for a better artist.
    return { 'release-group-count' => 52 } if $url =~ m|release-group\?artist=|;
    return { artists => [] } unless $url =~ /alias/;
    return { artists => [ { id => $MBID, name => 'Sea Power', score => 100 } ] };
};
my $got;
Plugins::Discography::API->_artistMbidByName('British Sea Power', sub { $got = shift });
ok(($got // '') eq $MBID, 'resolves the renamed act through the alias field');
ok(scalar(grep { /alias/ } @URLS), '... and it really did take the alias path');
ok((Plugins::Discography::API->peekArtistName($MBID) // '') eq 'Sea Power',
   'THE FIX: MB canonical name "Sea Power" is captured, not "British Sea Power"');

# ---------------------------------------------------------------------------
# 2. The capture must cost NO extra request -- the name was already in the
#    response the resolver had to fetch anyway.
# ---------------------------------------------------------------------------
# Release-group counts are excluded: those are 0.47.1's zero-release identity
# check, not the name capture this section is about.
my $urls_with_capture = scalar grep { !m|release-group\?artist=| } @URLS;
ok($urls_with_capture <= 3,
   "capture is free: $urls_with_capture request(s), no lookup added");

# ---------------------------------------------------------------------------
# 3. An ORDINARY artist, resolved on the name field, caches its own name --
#    so the canonical name is present but EQUAL, and the Browse call site will
#    correctly add nothing to the alias list.
# ---------------------------------------------------------------------------
%CACHE = (); @URLS = ();
$RESPONDER = sub { { artists => [ { id => 'rh-mbid', name => 'Radiohead', score => 100 } ] } };
Plugins::Discography::API->_artistMbidByName('Radiohead', sub { $got = shift });
ok(($got // '') eq 'rh-mbid', 'an ordinary artist still resolves on the name field');
ok((Plugins::Discography::API->peekArtistName('rh-mbid') // '') eq 'Radiohead',
   '... and caches its own canonical name');
ok(Plugins::Discography::Sources::_norm('Radiohead')
   eq Plugins::Discography::Sources::_norm(
        Plugins::Discography::API->peekArtistName('rh-mbid')),
   '... which folds EQUAL to the browsed name, so no retry name is added');

# ---------------------------------------------------------------------------
# 4. A genuine miss must cache NO name. Storing one for an unresolved lookup
#    would hand the retry a name belonging to nobody.
# ---------------------------------------------------------------------------
%CACHE = (); @URLS = ();
$RESPONDER = sub { { artists => [] } };
Plugins::Discography::API->_artistMbidByName('Not A Real Band At All', sub { $got = shift });
ok(!defined $got, 'an unresolvable name resolves to nothing');
ok(!defined(Plugins::Discography::API->peekArtistName('anything')),
   '... and caches no canonical name');

# ---------------------------------------------------------------------------
# 5. A low-scoring top hit is rejected, and must not leak its name either.
#    (The >=90 gate is what stops a nonsense query adopting a stranger.)
# ---------------------------------------------------------------------------
%CACHE = (); @URLS = ();
$RESPONDER = sub { { artists => [ { id => 'weak', name => 'Somebody Else', score => 40 } ] } };
Plugins::Discography::API->_artistMbidByName('Nonsense Query Here', sub { $got = shift });
ok(!defined(Plugins::Discography::API->peekArtistName('weak')),
   'a sub-threshold hit caches no canonical name');

# ---------------------------------------------------------------------------
# 6. The dedupe rule the Browse call site applies, asserted on real names:
#    the canonical name leads, and an alias that merely repeats it is dropped.
# ---------------------------------------------------------------------------
my $canon = 'Sea Power';
my @aliases = ('Sea Power', 'British Sea Power Ltd');
my $ck = Plugins::Discography::Sources::_norm($canon);
my @out = ($canon, grep { Plugins::Discography::Sources::_norm($_) ne $ck } @aliases);
ok($out[0] eq 'Sea Power', 'canonical name leads the retry list');
ok(scalar(@out) == 2, '... and a duplicate alias is folded out');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
