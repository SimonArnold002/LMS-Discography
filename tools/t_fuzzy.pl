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
sub ok { my ($c, $n) = @_; if (scalar $c) { $pass++; print "ok   - $n\n" }
                           else           { $fail++; print "FAIL - $n\n" } }

# Run the REAL merge and report which display names survived the gate.
sub merged {
    my ($query, %bySvc) = @_;
    my %in = map { $_ => [ map { { name => $_ } } @{ $bySvc{$_} } ] } keys %bySvc;
    my $out = $S->mergeArtistHits($query, \%in, [ sort keys %bySvc ]);
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

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
