#!/usr/bin/env perl
#
# REGRESSION TEST — an MB artist with ZERO release groups is not an answer.
#
# FIELD (classical cluster, diagnosed 2026-07-22): browsing "Shostakovich"
# rendered **"No releases found"** while Tidal had 111 real candidates waiting.
# Measured on the mirror, and the whole defect is in these four lines:
#
#     artist:"Shostakovich"  -> 100 Shostakovich Trio          (Group, 0 RGs)
#                                99 The Shostakovich String Quartet
#     alias:"Shostakovich"   -> 100 Дмитрий Дмитриевич Шостакович  (the composer)
#
# The composer's MB canonical name is CYRILLIC, so the `artist:` field can never
# find him — only the alias pass can. But the alias pass runs on failure, and
# the artist pass "succeeded": it took a Group that shares his surname and has
# catalogued nothing. A confident-looking first hit stopped the better pass.
#
# The search-ROWS path already drops artists with no releases (0.43.5's
# `warmCandidateCounts`); the BROWSE resolver never did. This closes that.
#
# THE FALLBACK IS THE POINT, and it is what makes this safe: a zero-release
# winner is HELD, not discarded. If no later pass does better it is stored
# anyway, so the worst case is byte-identical to the old behaviour — this can
# rescue a dead page, never break a working one.
#
# Standalone -- no LMS install needed:  perl tools/t_zerorg.pl
#
use strict;
use warnings;
use FindBin;

my %CACHE;
my $DATA;
my @QUERIES;          # every URL the resolver asked for, in order
our $MB_BASE = 'http://mirror:5000/ws/2/';   # flipped to public in section 5

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
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    # The etiquette gap between counted candidates: fire it straight away so a
    # PUBLIC-base scenario is testable without a real 1.1s wait.
    *{'Slim::Utils::Timers::setTimer'}   = sub { $_[2]->() };
    *{'Slim::Utils::Timers::killTimers'} = sub { 1 };
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
sub set { $CACHE{ $_[1] } = $_[2]; return 1 }
sub remove { delete $CACHE{ $_[1] }; return 1 }
package T::Prefs;
sub get { return $_[1] eq 'mb_base_url' ? $main::MB_BASE : undef }
sub set { 1 } sub init { 1 } sub setChange { 1 }
package T::Resp;
sub new { bless {}, shift } sub content { '{}' } sub error { 'stub error' }
package T::HTTP;
sub get {
    my ($self, $url) = @_;
    push @QUERIES, $url;
    # The one artist whose COUNT request fails: proves an HTTP error is not
    # read as "zero releases".
    return $self->{err}->(T::Resp->new)
        if $url =~ /release-group\?artist=err-0000/;
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
my $API = 'Plugins::Discography::API';

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

# ---------------------------------------------------------------------------
# THE FIXTURE — the mirror's real answers, keyed by "<field>:<name>".
# ---------------------------------------------------------------------------
my $TRIO   = '6fe7c51d-eed2-4866-847d-44ce45eda9dd';   # Shostakovich Trio, 0 RGs
my $DMITRI = '824f4e8e-46f3-4c47-8ba9-1eea6ad38d1c';   # the composer (Cyrillic name)
my $RADIO  = 'a74b1b7f-71a5-4011-9441-d0b5e4122711';
my $FABS   = 'b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d';
my $GHOST  = 'ghost-000-0000';                         # 0 RGs and nothing better
my $ERRC   = 'err-0000';                               # its count request fails

my %ARTIST = (
    'artist:shostakovich' => [ { id => $TRIO, name => 'Shostakovich Trio', score => 100 } ],
    'alias:shostakovich'  => [ { id => $DMITRI,
                                 name => "\x{414}\x{43c}\x{438}\x{442}\x{440}\x{438}\x{439} "
                                       . "\x{428}\x{43e}\x{441}\x{442}\x{430}\x{43a}\x{43e}\x{432}\x{438}\x{447}",
                                 score => 100 } ],
    'artist:radiohead'    => [ { id => $RADIO, name => 'Radiohead',   score => 100 } ],
    'artist:beatles'      => [ { id => $FABS,  name => 'The Beatles', score => 100 } ],
    'artist:ghost trio'   => [ { id => $GHOST, name => 'Ghost Trio Ensemble', score => 100 } ],
    'artist:errcount'     => [ { id => $ERRC,  name => 'Errcount Band',      score => 100 } ],
);
my %RGCOUNT = ( $TRIO => 0, $DMITRI => 214, $RADIO => 582, $FABS => 800, $GHOST => 0 );

sub response_for {
    my ($url) = @_;
    if ($url =~ m{release-group\?artist=([^&]+)}) {
        return { 'release-group-count' => ($RGCOUNT{$1} // 0) };
    }
    my ($q) = $url =~ /query=([^&]*)/;
    $q = '' unless defined $q;
    $q =~ s/%([0-9a-f]{2})/chr hex $1/gie;
    $q =~ s/\+/ /g;
    my ($field, $want) = $q =~ /^(artist|alias):"?([^"]*)"?/;
    return { artists => [] } unless defined $field;
    $want =~ s/^\s+|\s+$//g;
    return { artists => $ARTIST{ lc "$field:$want" } || [] };
}

sub resolve {
    my ($name, $spec) = @_;
    %CACHE = (); @QUERIES = ();
    my $got = 'UNSET';
    $API->_artistMbidByName($name, sub { $got = $_[0] }, $spec);
    return $got;
}
sub counts_asked { return scalar grep { m{release-group\?artist=} } @QUERIES }
sub fields_asked { return join ',', map { /query=(artist|alias)%3A/ ? $1 : () } @QUERIES }

# ---------------------------------------------------------------------------
# 1. THE FIELD CASE.
# ---------------------------------------------------------------------------
ok((resolve('Shostakovich') // '') eq $DMITRI,
   'Shostakovich resolves to the COMPOSER, not the release-less Trio');
ok(scalar(fields_asked() =~ /artist.*alias/s),
   '... because the zero-release hit let the ALIAS pass run');

# The count is cached under the SHARED key, so the dead-end row filter reads it
# rather than paying for it again.
resolve('Shostakovich');
ok(defined $API->peekReleaseGroupCount($TRIO) && $API->peekReleaseGroupCount($TRIO) == 0,
   'the Trio\'s zero count is cached where the row filter looks');

# ---------------------------------------------------------------------------
# 2. THE COST IS TARGETED. An EXACT-name winner is never count-checked.
# ---------------------------------------------------------------------------
ok((resolve('Radiohead') // '') eq $RADIO, 'an exact-name artist still resolves');
ok(counts_asked() == 0, '... and costs NO release-group request at all');
ok(scalar(fields_asked() eq 'artist'), '... and stops after the first pass');

ok((resolve('Beatles') // '') eq $FABS, '"Beatles" still resolves to The Beatles');
ok(counts_asked() == 1, '... an INEXACT winner is checked (exactly once)');

# ---------------------------------------------------------------------------
# 3. THE FALLBACK. Nothing better exists -> the old answer is still given.
#    This is the assertion that proves the change cannot regress.
# ---------------------------------------------------------------------------
ok((resolve('Ghost Trio') // '') eq $GHOST,
   'a release-less artist with no better alternative is STILL returned');

# ---------------------------------------------------------------------------
# 4. FAIL OPEN. An HTTP error is not evidence of zero releases.
# ---------------------------------------------------------------------------
ok((resolve('Errcount') // '') eq $ERRC,
   'a FAILED count keeps the artist (an error is not a zero)');

# A miss is still an honest miss.
ok(!defined resolve('Nobody At All Xyzzy'), 'an unknown name still misses');

# ---------------------------------------------------------------------------
# 5. THROTTLE POLICY. A SPECULATIVE lookup against the PUBLIC API adds no
#    requests — the same rule the alias and credit-split passes follow.
# ---------------------------------------------------------------------------
{
    local $main::MB_BASE = 'https://musicbrainz.org/ws/2/';
    ok((resolve('Beatles', 1) // '') eq $FABS,
       'public API + speculative: still resolves');
    ok(counts_asked() == 0, '... and asks for NO counts (bulk row guesses stay cheap)');

    ok((resolve('Shostakovich') // '') eq $DMITRI,
       'public API, NOT speculative: the fix still applies');
    ok(counts_asked() >= 1, '... paying one count on the inexact hit');
}

# ---------------------------------------------------------------------------
# 6. CACHING. A repeat resolution costs nothing.
# ---------------------------------------------------------------------------
%CACHE = (); @QUERIES = ();
$API->_artistMbidByName('Shostakovich', sub { });
my $n1 = scalar @QUERIES;
$API->_artistMbidByName('Shostakovich', sub { });
ok(scalar(@QUERIES) == $n1, 'a repeat resolution issues no further requests');

# And the WINNER's canonical name is what gets cached — not the Trio's.
%CACHE = ();
$API->_artistMbidByName('Shostakovich', sub { });
my $canon = $API->peekArtistName($DMITRI);
ok(scalar(defined $canon && $canon =~ /\x{428}/), "the COMPOSER's canonical name is cached");
ok(!defined $API->peekArtistName($TRIO), '... and the rejected Trio caches no name');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
