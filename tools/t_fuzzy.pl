#!/usr/bin/env perl
#
# REGRESSION TEST — typo tolerance in the artist-search relevance gate.
#
# WHY (field, 2026-07-21): Simon typed "Layo & Bushwaka" (one letter out) and
# got NOTHING, while Qobuz, Tidal AND Deezer had all returned the correct
# "Layo & Bushwacka!" for that very misspelling. The gate discarded all 17 hits
# and kept only a vague "Layo" with no releases, which the dead-end filter then
# dropped. The search was strictly worse than the services it queries.
#
# The fixture is REAL: every candidate list below is copied from the actual
# `artist-search <svc>/'<query>'` lines in server.log, junk included. Inventing
# plausible-looking hits would prove nothing about the junk we must exclude.
#
# TWO DIRECTIONS, and the negatives are the point. A gate that admits
# everything would pass the typo half of this file; the 0.37.1 free-association
# junk (Tidal answering "The Beatles" with Led Zeppelin, Pink Floyd, The
# Monkees) must still be rejected.
#
# Standalone:  perl tools/t_fuzzy.pl
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

# Run the REAL merge and report which display names survived the gate.
# %bySvc may carry a _canon key: the name 0.45.2's second pass ALSO searched
# the services under, which the gate must judge those hits against (0.46.4).
sub merged {
    my ($query, %bySvc) = @_;
    my $canon = delete $bySvc{_canon};
    my %in = map { $_ => [ map { { name => $_ } } @{ $bySvc{$_} } ] } keys %bySvc;
    my $out = $S->mergeArtistHits($query, \%in, [ sort keys %bySvc ],
                                  ($canon ? [$canon] : undef));
    return [ map { $_->{name} } @$out ];
}
sub has { my ($rows, $want) = @_; return scalar grep { $_ eq $want } @$rows }

# --- THE FIELD CASE: one letter out. Real hits from server.log. -------------
my @tidal_layo = ('Layo & Bushwacka', 'Ya Levis', 'Lonyo', 'Bushwacka!',
                  'Black Motion', 'Buraka Som Sistema', 'The Chakachas', 'Layo',
                  'Layo & Bushwacka! featuring Cevin Fisher.', 'LAYO');
my $r = merged('Layo & Bushwaka',
               Tidal  => \@tidal_layo,
               Qobuz  => ['Layo & Bushwacka!'],
               Deezer => ['Layo and bushwacka!']);
ok(has($r, 'Layo & Bushwacka') || has($r, 'Layo & Bushwacka!')
   || has($r, 'Layo and bushwacka!'), 'typo "Bushwaka" still finds the band');
ok(!has($r, 'Lonyo'),              'typo search does not admit "Lonyo"');
ok(!has($r, 'The Chakachas'),      'typo search does not admit "The Chakachas"');
ok(!has($r, 'Buraka Som Sistema'), 'typo search does not admit "Buraka Som Sistema"');
ok(!has($r, 'Black Motion'),       'typo search does not admit "Black Motion"');

# The "&"/"and"/"!" spellings must land in ONE row (0.44.19 + 0.44.23 folds).
ok(scalar(@{[ grep { /bushwacka/i } @$r ]}) == 1,
   'the three service spellings collapse to a single row');

# --- THE 0.37.1 REGRESSION: free association must STILL be rejected ---------
# Tidal genuinely answers "The Beatles" with these.
$r = merged('The Beatles',
            Tidal => ['The Beatles', 'Led Zeppelin', 'Pink Floyd', 'The Monkees',
                      'Paul McCartney', 'The Rolling Stones']);
ok(has($r, 'The Beatles'),      'the real artist survives');
ok(!has($r, 'Led Zeppelin'),    'Led Zeppelin still rejected (0.37.1 junk)');
ok(!has($r, 'Pink Floyd'),      'Pink Floyd still rejected');
ok(!has($r, 'The Monkees'),     'The Monkees still rejected (0.545 - near miss)');
ok(!has($r, 'Paul McCartney'),  'Paul McCartney still rejected');

# --- SHORT NAMES: a single edit is a different word, the length floor holds --
$r = merged('Slayer', Tidal => ['Slayer', 'Player']);
ok(has($r, 'Slayer') && !has($r, 'Player'),
   'short name: "Player" not admitted for "Slayer" (length floor)');
$r = merged('Oasis', Tidal => ['Oasis', 'Basis']);
ok(has($r, 'Oasis') && !has($r, 'Basis'),
   'short name: "Basis" not admitted for "Oasis" (length floor)');

# "Eagles" -> "Beagles" IS admitted, and NOT by this change: "beagles" CONTAINS
# "eagles", so the 0.37.1 substring rule takes it — the same prefix-superset
# behaviour that entry documents ("Beatless" for query "beatles") and that LMS's
# own token-prefix library search has. Asserted so the distinction is recorded:
# the fuzzy rule declines it (length floor) and the pre-existing rule allows it.
ok(!Plugins::Discography::Sources::_closeEnough('eagles', 'beagles'),
   'fuzzy rule DECLINES eagles/beagles (0.857 but under the length floor)');
$r = merged('Eagles', Tidal => ['Eagles', 'Beagles']);
ok(has($r, 'Beagles'),
   'eagles/beagles admitted by the PRE-EXISTING substring rule, not by fuzzy');

# --- LONGER TYPOS the floor does admit --------------------------------------
$r = merged('Led Zepplin',  Tidal => ['Led Zeppelin', 'Pink Floyd']);
ok(has($r, 'Led Zeppelin') && !has($r, 'Pink Floyd'), 'typo "Led Zepplin" -> Led Zeppelin');
$r = merged('Foo Fighers',  Tidal => ['Foo Fighters', 'Paramore']);
ok(has($r, 'Foo Fighters') && !has($r, 'Paramore'),   'typo "Foo Fighers" -> Foo Fighters');

# --- ADDITIVE: everything that passed before still passes -------------------
$r = merged('beatl', Tidal => ['The Beatles']);
ok(has($r, 'The Beatles'), 'partial typing still works (substring rule)');
$r = merged('Beatles', Tidal => ['The Beatles']);
ok(has($r, 'The Beatles'), 'token-subset still works');

# ---------------------------------------------------------------------------
# THE CANONICAL-NAME PASS (0.46.4). Field: Simon searched "b52s" and the row
# came back WITHOUT Deezer, while "b-52s" had all three.
#
# Deezer was never missing -- the log reads `Deezer=2` -- its two hits were
# discarded HERE, because 0.45.2 fetches them under MusicBrainz's canonical
# name and the gate then judged them against what the user TYPED. Qobuz and
# Tidal survived only because their lists happened to also contain "B52's",
# which folds exactly onto the typed query: a spelling coincidence, not a
# service difference. Fixture verbatim from the artist-search log lines.
# ---------------------------------------------------------------------------
my $CANON  = "The B\x{2010}52s";                  # MB's spelling: U+2010 HYPHEN
my @deezer = ("The B-52's", 'B-52');              # everything Deezer returned
# Tidal's answer to the CANONICAL name is mostly free association -- the exact
# junk the 0.37.1 gate exists to reject, now arriving through the new door.
my @tidal_b52 = ("The B-52's", 'Talking Heads', 'DEVO', "The Go-Go's",
                 'Missing Persons', 'Kate Pierson', 'The B-69s');

$r = merged('b52s', Deezer => \@deezer, Tidal => \@tidal_b52);
ok(!has($r, "The B-52's"),
   'PRE-FIX: judged against "b52s" alone, the canonical hit is thrown away');

$r = merged('b52s', _canon => $CANON, Deezer => \@deezer, Tidal => \@tidal_b52);
ok(has($r, "The B-52's"),
   'a hit fetched under the canonical name is judged against THAT name');
ok(!has($r, 'Talking Heads') && !has($r, 'DEVO') && !has($r, "The Go-Go's")
   && !has($r, 'Missing Persons'),
   '... and the free-association junk is STILL rejected');
ok(!has($r, 'Kate Pierson'), '... including a band MEMBER, who is a real artist');
# "B-52" and "The B-69s" are the near misses that prove the door is narrow:
# neither normalises onto the typed query OR the canonical name.
ok(!has($r, 'B-52') && !has($r, 'The B-69s'),
   '... and near-miss names are not swept in with it');

# The row must speak for every service that reached it — that is the whole
# report ("missing Deezer").
my %in = (Deezer => [ map { { name => $_ } } @deezer ],
          Tidal  => [ map { { name => $_ } } @tidal_b52 ]);
my ($row) = grep { $_->{name} eq "The B-52's" }
            @{ $S->mergeArtistHits('b52s', \%in, [qw(Deezer Tidal)], [$CANON]) };
ok($row && (grep { $_ eq 'Deezer' } @{ $row->{sources} })
        && (grep { $_ eq 'Tidal'  } @{ $row->{sources} }),
   '... and the surviving row lists BOTH services');

# The extra query is OPTIONAL, and omitting it must change NOTHING — most
# searches never run a second pass. Compared as whole result lists (names AND
# order), not a spot check, because ranking reads the same exactness flag.
my %layo = (Tidal  => [ map { { name => $_ } } @tidal_layo ],
            Qobuz  => [ { name => 'Layo & Bushwacka!' } ],
            Deezer => [ { name => 'Layo and bushwacka!' } ]);
my @ord  = qw(Deezer Qobuz Tidal);
my $old  = $S->mergeArtistHits('Layo & Bushwaka', \%layo, \@ord);
my $new  = $S->mergeArtistHits('Layo & Bushwaka', \%layo, \@ord, undef);
# scalar() is load bearing: `... && @$old` in ok()'s LIST of args flattens the
# array into the argument list and the test name becomes a hashref — the 0.43.5
# fixture trap, which duly reappeared while writing this.
ok(scalar(join('|', map { $_->{name} } @$old) eq join('|', map { $_->{name} } @$new)
          && @$old),
   'the extra query is OPTIONAL — omitted, the result is unchanged');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
