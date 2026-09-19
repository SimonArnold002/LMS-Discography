#!/usr/bin/env perl
#
# REGRESSION TEST -- COMPOUND-WORD / WORD-BOUNDARY variant in _albumMatches.
#
# FIELD (2026-07-24, Simon): the Rolling Stones' 1964 debut was missing from the
# discography though it is on every streaming service. MusicBrainz titles the
# release group "England's Newest Hit Makers" (two words); the services spell it
# "England's Newest Hitmakers" (one word). The only difference after _norm is the
# space between 'hit' and 'makers':
#
#     spine  norm:  'englands newest hit makers'
#     cand   norm:  'englands newest hitmakers'
#
# No tier in _albumMatches treated a space as optional, so the tile got NO MATCH
# against a HEALTHY candidate pool (Qobuz=184, Tidal=214, Deezer=126) and, with
# hide_unmatched on, was hidden. The fix is an EXACT space-collapsed equality
# tier (no prefix rule -- collapsing spaces destroys the word boundary the prefix
# tiers rely on), length-gated so a short key can't collide.
#
# DELIBERATE DSC-ONLY DIVERGENCE from the fleet matcher, held to prove in the
# field before porting -- matcher_sync_check reports the drift by design.
#
# Standalone -- no LMS install needed:  perl tools/t_hitmakers.pl
#
use strict;
use warnings;
use utf8;
use FindBin;

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::Timers Slim::Utils::PluginManager
                  Slim::Control::Request Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}          = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    push @{'Slim::Utils::Log::ISA'},   'Exporter';
    push @{'Slim::Utils::Prefs::ISA'}, 'Exporter';
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
}
package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}
package T::Prefs; sub get {1} sub set {1} sub init {1}

package main;
use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
binmode STDOUT, ':utf8';

my $M = \&Plugins::Discography::Sources::_albumMatches;
my $N = \&Plugins::Discography::Sources::_norm;

my $n = 0; my $bad = 0;
sub ok {
    my ($cond, $name) = @_;
    die "ok() needs a test name" unless defined $name && length $name;
    $n++;
    if ($cond) { print "ok $n - $name\n" }
    else       { print "not ok $n - $name\n"; $bad++ }
}

my $artist = "the rolling stones";

# The field case: MB two-word title vs the service one-word spelling, curly
# apostrophe on both (as they actually arrive).
my $spineRaw = "England\x{2019}s Newest Hit Makers";
my $spine    = $N->($spineRaw);

ok( $M->($artist, $spine, "The Rolling Stones", "England\x{2019}s Newest Hitmakers", $spineRaw),
    "MB 'Hit Makers' matches service 'Hitmakers' (curly apostrophe)" );
ok( $M->($artist, $spine, "The Rolling Stones", "England's Newest Hitmakers", $spineRaw),
    "straight-apostrophe service spelling also matches" );
ok( $M->($artist, $spine, "The Rolling Stones", "England\x{2019}s Newest Hit Makers", $spineRaw),
    "the exact two-word spelling still matches (unchanged path)" );

# The wrong ARTIST must still be rejected -- the space tier does not weaken the
# mandatory artist gate.
ok( !$M->($artist, $spine, "Some Tribute Band", "England's Newest Hitmakers", $spineRaw),
    "wrong artist still rejected" );

# A genuinely DIFFERENT title that merely shares no boundary must not match.
ok( !$M->($artist, $spine, "The Rolling Stones", "Out of Our Heads", $spineRaw),
    "an unrelated album does not match" );

# The tier is EXACT space-collapsed equality, NOT a prefix -- an unbracketed
# extra word after the collapsed key must NOT be swallowed (that is what makes
# collapsing safe).
ok( !$M->($artist, $spine, "The Rolling Stones", "England's Newest Hitmakers Live", $spineRaw),
    "space-collapse is exact, not a prefix (no 'Live' swallow)" );

# Short titles must not collide on the collapsed key (length gate). "Hot Rats"
# vs "Hotrats" is 7 chars collapsed -- allowed -- but a <6 char pair is not.
{
    my $sp = $N->("Go Go");   # collapses to 'gogo' (4) -- under the 6-char gate
    ok( !$M->("x", $sp, "x", "GoGo", "Go Go"),
        "a short collapsed key (<6 chars) does not match on the space tier" );
}

# Control: a real longer compound the OTHER way round -- service two words, MB
# one word -- also works (symmetry).
{
    my $sp = $N->("Hotrats");
    ok( $M->("frank zappa", $sp, "Frank Zappa", "Hot Rats", "Hotrats"),
        "symmetry: MB one word matches service two words" );
}

print "\n1..$n\n";
exit($bad ? 1 : 0);
