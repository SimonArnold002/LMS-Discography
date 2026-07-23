#!/usr/bin/env perl
#
# REGRESSION TEST — a LIBRARY artist outranks one you do not own.
#
# FIELD (Simon, 2026-07-22): *"when searching, a Local artist will show ahead of
# any matches that there is no local artist even if it doesn't make the top hit,
# local should always be trumps."* Ownership was not a ranking key at all — the
# order was exactness, then how many services carried the row, then first-seen.
# Both failure shapes were measured live against the running server BEFORE any
# code changed, and both are asserted below:
#
#   typed 'bush'      0  Bush          Qobuz·Tidal·Deezer   <- NOT owned
#                     1  Kate Bush     Local·Qobuz·Deezer
#                     2  Bush Tetras   Local·Qobuz·Deezer
#     an EXACT name match beat two artists he owns.
#
#   typed 'The Las'   0  The Las Vegas Boneheads  Qobuz·Tidal·Deezer
#                     ...
#                     6  The Last       Local     <- owned, sunk on breadth
#                     7  The Last Word  Local     <- owned, sunk on breadth
#     a Local-ONLY row loses to anything carried by three services.
#
# THE ACCEPTED COST, asserted here so nobody "fixes" it later: typing a name
# that exactly matches an artist you do NOT own now returns owned near-misses
# above it. Simon chose this over the alternative (exactness first, ownership
# second) after seeing both orderings on his own data — because "exact" is not
# purely what the user typed. 0.46.4 also accepts MusicBrainz's canonical name
# for whatever the query resolved to, and MB resolves the query "La's" to
# *Yo La Tengo*, so ranking ownership below that key subordinates the one thing
# the user can verify to an MB inference.
#
# THE CONTROLS ARE THE POINT. Everything about the previous ordering survives
# INSIDE each block, and a search that turns up nothing owned must come back
# byte-identical to before — that is what proves the change is surgical rather
# than a reshuffle.
#
# Standalone — no LMS install needed:  perl tools/t_rank.pl
#
use strict;
use warnings;
use FindBin;

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers
                  Slim::Control::Request Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}          = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    push @{'Slim::Utils::Log::ISA'},   'Exporter';
    push @{'Slim::Utils::Prefs::ISA'}, 'Exporter';
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
}

package T::Null;
our $AUTOLOAD;
sub AUTOLOAD { return }
sub DESTROY  { }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;

my $S = 'Plugins::Discography::Sources';
my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    # STRUCTURAL GUARD — see t_norm.pl. A bare `=~`/grep/map in ok()'s argument
    # list returns the EMPTY LIST on failure, shifting the NAME into the
    # condition slot so a FAILING assertion prints as a pass.
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

my @ORDER = qw(Local Qobuz Tidal Deezer);
sub names { [ map { $_->{name} } @{ $_[0] } ] }
sub at { my ($r, $w) = @_; for my $i (0 .. $#$r) { return $i if $r->[$i] eq $w } return 9999 }
sub svc { [ map { { name => $_ } } @_ ] }

# ---------------------------------------------------------------------------
# 1. THE FIELD CASE 'bush' — an exact, NOT-owned name no longer outranks two
#    artists in the library. Hits are the real ones from the live search.
# ---------------------------------------------------------------------------
my %bush = (
    Local  => [ { name => 'Kate Bush',   artist_id => 11 },
                { name => 'Bush Tetras', artist_id => 12 } ],
    Qobuz  => svc('Bush', 'Kate Bush', 'Bush Tetras', 'Bushido', 'Sam Bush'),
    Tidal  => svc('Bush'),
    Deezer => svc('Bush', 'Kate Bush', 'Bush Tetras', 'Bushido'),
);
my $b = names($S->mergeArtistHits('bush', \%bush, \@ORDER));
ok(scalar(at($b, 'Kate Bush')   < at($b, 'Bush')),
   "'bush': owned Kate Bush outranks the non-owned exact match");
ok(scalar(at($b, 'Bush Tetras') < at($b, 'Bush')),
   "'bush': owned Bush Tetras outranks the non-owned exact match");
ok(scalar(at($b, 'Bush') < at($b, 'Bushido')),
   '... and BELOW the owned rows the old order is untouched (exact still wins)');
ok(scalar(at($b, 'Kate Bush') < at($b, 'Bush Tetras')),
   '... and two owned rows tying on everything keep their first-seen order');

# ---------------------------------------------------------------------------
# 2. THE SECOND SHAPE — breadth must no longer bury a Local-ONLY row. This is
#    the one that hurt most: owning an artist no service carries is exactly
#    when the library row is the ONLY useful answer.
# ---------------------------------------------------------------------------
my %las = (
    Local  => [ { name => 'The Last',      artist_id => 21 },
                { name => 'The Last Word', artist_id => 22 } ],
    Qobuz  => svc('The Las Vegas Boneheads', 'The Last Poets'),
    Tidal  => svc('The Las Vegas Boneheads', "The La's"),
    Deezer => svc('The Las Vegas Boneheads', "The La's"),
);
my $l = names($S->mergeArtistHits('The Las', \%las, \@ORDER));
ok(scalar(at($l, 'The Last') < at($l, 'The Las Vegas Boneheads')),
   "'The Las': a Local-ONLY row outranks a three-service row it does not own");
ok(scalar(at($l, 'The Last Word') < at($l, 'The Las Vegas Boneheads')),
   '... and so does the second Local-only row');

# ---------------------------------------------------------------------------
# 3. THE POST-ATTACH PASS, which is the whole reason the comparator is applied
#    TWICE. "The La's" is NOT returned by the Local leg (LMS's index answers
#    "The Las" with The Last / The Last Word — 0.48.1), so at merge time it is
#    a streaming-only row. attachLibraryArtists gives it the library artist_id
#    afterwards, and Browse::_withMbCandidates then re-ranks. Simulated exactly
#    as Browse does it: set artist_id on the row, call rankArtistHits.
# ---------------------------------------------------------------------------
my $rows = $S->mergeArtistHits('The Las', \%las, \@ORDER);
ok(scalar(at(names($rows), "The La's") > at(names($rows), 'The Last')),
   "pre-attach: \"The La's\" ranks BELOW the Local-leg rows (it is not Local yet)");
$_->{name} eq "The La's" and $_->{artist_id} = 57545 for @$rows;
my $after = names($S->rankArtistHits($rows));
ok(scalar(at($after, "The La's") < at($after, 'The Las Vegas Boneheads')),
   'post-attach: the rescued row is promoted above the rows nobody owns');
ok(scalar($after->[0] eq "The La's"),
   '... and lands FIRST, because inside the owned block exactness still ranks');

# ---------------------------------------------------------------------------
# 4. CONTROL — a search that turns up NOTHING owned must be byte-identical to
#    the old ordering. If this ever fails, the change stopped being surgical.
# ---------------------------------------------------------------------------
my %none = (
    Qobuz  => svc('Bushido', 'Bush', 'Sam Bush', 'Bush Tetras'),
    Tidal  => svc('Bush', 'Bushido'),
    Deezer => svc('Bush'),
);
my $c = names($S->mergeArtistHits('bush', \%none, [qw(Qobuz Tidal Deezer)]));
ok(scalar(join('|', @$c) eq 'Bush|Bushido|Sam Bush|Bush Tetras'),
   'CONTROL: nothing owned -> exact, then breadth, then first-seen, unchanged');

# ---------------------------------------------------------------------------
# 5. CONTROL — the relevance gate is untouched. Ownership decides ORDER, never
#    admission, so the 0.37.1 free-association junk must still be refused.
# ---------------------------------------------------------------------------
my %junk = (
    Local => [ { name => 'The Beatles', artist_id => 31 } ],
    Tidal => svc('The Beatles', 'Led Zeppelin', 'Pink Floyd', 'The Monkees'),
);
my $j = names($S->mergeArtistHits('The Beatles', \%junk, [qw(Local Tidal)]));
ok(scalar($j->[0] eq 'The Beatles'), 'CONTROL: the owned exact row is first');
ok(scalar(!grep { $_ eq 'Led Zeppelin' } @$j),
   'CONTROL: an owned row does not let free-association junk in (Led Zeppelin)');
ok(scalar(!grep { $_ eq 'Pink Floyd' } @$j),
   'CONTROL: ... nor Pink Floyd');

# ---------------------------------------------------------------------------
# 6. RANK BEFORE THE CAP. An owned row must not be truncated away before the
#    post-attach pass can promote it. 35 two-service rows outrank a Local-only
#    row on breadth under the OLD rule, pushing it past SEARCH_MERGED_MAX (30).
# ---------------------------------------------------------------------------
my @many = map { "bush club $_" } 1 .. 35;
my %cap  = (
    Local => [ { name => 'Kate Bush', artist_id => 41 } ],
    Qobuz => svc(@many),
    Tidal => svc(@many),
);
my $cp = names($S->mergeArtistHits('bush', \%cap, [qw(Local Qobuz Tidal)]));
ok(scalar(@$cp == 30), 'the merged list is still capped at SEARCH_MERGED_MAX');
ok(scalar($cp->[0] eq 'Kate Bush'),
   '... and the owned row survives the cap by being ranked before it');

# ---------------------------------------------------------------------------
# 7. STABILITY. `_seq` is preserved, not re-based, so re-ranking an already
#    ranked list is a no-op — the item_id walk depends on a given library state
#    producing one deterministic order however many times it is re-ranked.
# ---------------------------------------------------------------------------
my $once  = $S->rankArtistHits($S->mergeArtistHits('bush', \%bush, \@ORDER));
my $twice = $S->rankArtistHits($S->rankArtistHits($once));
ok(scalar(join('|', @{ names($once) }) eq join('|', @{ names($twice) })),
   're-ranking an already ranked list changes nothing (idempotent)');

# ---------------------------------------------------------------------------
# 8. Defensive: the sub must survive the shapes Browse can hand it.
# ---------------------------------------------------------------------------
ok(scalar(ref $S->rankArtistHits([]) eq 'ARRAY'), 'an empty list is returned as-is');
ok(scalar(!defined $S->rankArtistHits(undef)),    'undef is returned as-is');
ok(scalar(@{ $S->rankArtistHits([ { name => 'X' } ]) } == 1),
   'a row with no sources/_seq/_exact keys does not die');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
