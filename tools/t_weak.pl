#!/usr/bin/env perl
#
# REGRESSION TEST — ONE COINCIDENTAL TITLE IS NOT CORROBORATION.
#
# FIELD (classical cluster, 2026-07-22). Browsing "Rossini" rendered three
# albums plus 42 rows of a MODERN RAPPER — "Oxytocin II", "ZINALE", "Alté girl".
# The spine guard DID arm and lost on a single accidental title:
#
#     Tidal:  'Rossini' is ambiguous - 3637384=1, 51024775=0, 58712447=0, ...
#     Deezer: 'Rossini' is ambiguous - 1155894=1, 274461941=0, 106057932=0, ...
#
# Against a spine of several HUNDRED MusicBrainz release groups, one title hit
# is noise — but it beat zero, so the rapper was adopted. Measured proof that a
# better answer existed, same mbid, same session: browsing MB's own canonical
# name "Gioachino Rossini" scores the RIGHT Tidal artist 3, and the page goes
# from Albums (3) to Albums (19) + Compilations + Live.
#
# THE SECOND HALF, from Shostakovich on Qobuz/Deezer: when NO service artist is
# named exactly what was browsed, `_sameName` is empty, the verify path never
# arms at all, and `_pickArtist`'s token-subset fallback adopts whatever shares
# a token — "Maxim Shostakovich" (his son), "Shostakovich Quartet". Those are
# picked with ZERO corroboration. Scoring them costs nothing (their albums are
# already fetched) and it is what lets a weak pick be reconsidered.
#
# THE FALLBACK IS THE SAFETY ARGUMENT, exactly as in 0.47.1: a weak pick is
# HELD, not discarded. If no other name does better it is returned unchanged,
# so an artist whose service titles simply differ from MusicBrainz's spellings
# — the case the verify path was deliberately NOT made the default for — keeps
# the answer it gets today.
#
# Standalone -- no LMS install needed:  perl tools/t_weak.pl
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
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Prefs' };
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Null' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    push @{'Slim::Utils::Log::ISA'},   'Exporter';
    push @{'Slim::Utils::Prefs::ISA'}, 'Exporter';
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Prefs; sub get { 1 } sub set { 1 } sub init { 1 }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
my $S = 'Plugins::Discography::Sources';

my $norm = \&Plugins::Discography::Sources::_norm;
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
# THE ROSSINI FIXTURE, in the shape the field produced it.
#   3637384  the modern rapper — one accidental title hit
#   3901472  the composer, reachable ONLY under MB's canonical name
# ---------------------------------------------------------------------------
my @SPINE_TITLES = ('Il barbiere di Siviglia', 'La Cenerentola', 'Semiramide',
                    'Guillaume Tell', 'Petite Messe solennelle', 'Diana');
my $SPINE = { map { $norm->($_) => 1 } @SPINE_TITLES };

my %CAT = (
    # "Diana" is the coincidence: a real rapper single that happens to share a
    # title with a Rossini release group.
    3637384 => [ { title => 'Oxytocin II' }, { title => 'ZINALE' },
                 { title => 'Diana' }, { title => "Alt\x{e9} girl" } ],
    3901472 => [ { title => 'Il barbiere di Siviglia' }, { title => 'La Cenerentola' },
                 { title => 'Semiramide' }, { title => 'Rossini Gala' } ],
    # Shostakovich on Qobuz: the son. Nothing corroborates, and no better
    # artist exists on that service — the fallback must return him anyway.
    9001    => [ { title => 'Shostakovich: Symphony No.5 & Festive Overture' },
                 { title => 'Shostakovich: Piano Concerto No. 2' } ],
);

my @FETCHED;                      # every artist id whose albums were pulled
my @SEARCHED;                     # every extra name searched
my $fetch = sub { my ($id, $done) = @_; push @FETCHED, $id; $done->($CAT{$id} || []) };

# The service's artist search, by name.
my %BY_NAME = (
    'rossini'           => [ { id => 3637384, name => 'Rossini' } ],
    'gioachino rossini' => [ { id => 3901472, name => 'Gioachino Rossini' } ],
    'shostakovich'      => [ { id => 9001,    name => 'Maxim Shostakovich' } ],
);
my $search = sub {
    my ($name, $done) = @_;
    push @SEARCHED, $name;
    $done->($BY_NAME{ lc $name } || []);
};

sub resolve {
    my ($query, $aliases, $strict) = @_;
    @FETCHED = (); @SEARCHED = ();
    my ($artist, $albums) = ('UNSET', undef);
    $S->can('_resolveArtist')->(
        'TestSvc', $query, $BY_NAME{ lc $query } || [], $SPINE, $fetch,
        sub { ($artist, $albums) = @_ }, $aliases, $search, $strict);
    return ($artist, $albums);
}

# ---------------------------------------------------------------------------
# 1. THE FIELD CASE. One title hit is not enough to settle on.
# ---------------------------------------------------------------------------
my ($a, $al) = resolve('Rossini', ['Gioachino Rossini']);
ok(ref $a eq 'HASH' && $a->{id} == 3901472,
   'Rossini resolves to the COMPOSER, not the one-title rapper');
ok(scalar(grep { $_ eq 'Gioachino Rossini' } @SEARCHED),
   '... because a weak score made it try MB\'s canonical name');
my $titles = $al ? join(',', map { $_->{title} } @$al) : '';
# scalar() deliberately: a failing match returns the EMPTY LIST, which shifts
# the test NAME into the condition slot and the assertion "passes" with no name
# — the 0.43.5 trap, and this is the fourth time it has bitten in this repo.
ok(scalar($titles =~ /Cenerentola/), "the winner's albums travel with the winner");

# ---------------------------------------------------------------------------
# 2. THE FALLBACK — the assertion that proves this cannot regress. Nothing
#    corroborates on this service and no better name exists, so the weak pick
#    is returned unchanged (today's answer, and the useful one: they ARE
#    Shostakovich recordings, merely credited to his son).
# ---------------------------------------------------------------------------
($a, $al) = resolve('Shostakovich', ['Dmitri Shostakovich']);
ok(ref $a eq 'HASH' && $a->{id} == 9001,
   'an uncorroborated pick with no better alternative is STILL returned');
ok(scalar(@{ $al || [] }) == 2, '... with its albums intact');

# A weak pick whose retry name finds NOTHING also stays put.
($a) = resolve('Shostakovich', ['Nobody At All']);
ok(ref $a eq 'HASH' && $a->{id} == 9001, 'a fruitless retry leaves the pick alone');

# ---------------------------------------------------------------------------
# 3. THE COST. A STRONG pick is accepted at once — no extra search, no extra
#    album fetch. This is what keeps the ordinary artist as fast as today.
# ---------------------------------------------------------------------------
($a) = resolve('Gioachino Rossini', ['Rossini']);
ok(ref $a eq 'HASH' && $a->{id} == 3901472, 'a well-corroborated artist resolves');
ok(scalar(@SEARCHED) == 0, '... searching no further names');
ok(scalar(@FETCHED) == 1, '... and fetching exactly one catalogue');

# No aliases to try at all -> byte-identical to the old behaviour.
($a) = resolve('Rossini', undef);
ok(ref $a eq 'HASH' && $a->{id} == 3637384,
   'with no alternative name offered, the weak pick stands (as before)');

# The weak retry is capped at ONE name, so a weak artist cannot cost a walk
# through the whole alias list.
resolve('Rossini', ['No One', 'Nobody', 'Gioachino Rossini']);
ok(scalar(@SEARCHED) == 1, 'the weak retry tries ONE name, not the whole list');

# ---------------------------------------------------------------------------
# 4. NO SPINE = NO OPINION. Without release groups to score against there is
#    nothing to be weak about, so the pick is taken as-is and costs nothing.
# ---------------------------------------------------------------------------
@FETCHED = (); @SEARCHED = ();
my $noSpine = 'UNSET';
$S->can('_resolveArtist')->('TestSvc', 'Rossini', $BY_NAME{rossini}, {}, $fetch,
                            sub { $noSpine = $_[0] }, ['Gioachino Rossini'], $search, 0);
ok(ref $noSpine eq 'HASH' && $noSpine->{id} == 3637384,
   'with no spine the pick is taken unquestioned');
ok(scalar(@SEARCHED) == 0, '... and no retry is paid for');

# ---------------------------------------------------------------------------
# 5. THE 0.43.1 RULE IS UNTOUCHED: when the name IS shared by several MB
#    artists and NOTHING corroborates, the answer is still UNRESOLVED — never a
#    silent adoption of the prominent act. The fallback must not resurrect it.
# ---------------------------------------------------------------------------
my @same = ( { id => 100, name => 'Madness' }, { id => 200, name => 'Madness' } );
$CAT{100} = [ { title => 'Junk' } ];
$CAT{200} = [ { title => 'More Junk' } ];
my $un = 'UNSET';
$S->can('_resolveArtist')->('TestSvc', 'Madness', \@same, $SPINE, $fetch,
                            sub { $un = $_[0] }, undef, $search, 1);
ok(!defined $un, 'an ambiguous name with no corroboration is still UNRESOLVED');

# ---------------------------------------------------------------------------
# 6. BOTH NAMES WHEN THE PAGE ASKS (`$compare`, 0.56.19). The query is
#    MusicBrainz's English name standing in for a name with no Latin letter, the
#    first alias that name. Field (rig, 2026-10-01): Qobuz files 王菲 as two
#    artists, "王菲" (25 of her releases) and "Faye Wong" (4, none in common);
#    0.56.18 answered "Faye Wong" at once (4 is strong) and lost 21.
# ---------------------------------------------------------------------------
my $WF = "\x{738b}\x{83f2}";   # 王菲
my $SP6 = { map { $norm->($_) => 1 } qw(Sky Fable Toy Eyebrows Everything Wishing) };
%CAT = (%CAT,
    601 => [ { title => 'Everything' }, { title => 'Wishing' }, { title => 'Unrelated' } ],          # "Faye Wong": 2
    602 => [ { title => 'Sky' }, { title => 'Fable' }, { title => 'Toy' }, { title => 'Eyebrows' } ], # "王菲": 4
    603 => [ { title => 'Sky' } ],                                                                     # weak: 1
    604 => [ { title => 'Toy' }, { title => 'Fable' } ],                                               # a tie: 2
);
sub both {
    my ($query, $native, %o) = @_;
    @FETCHED = (); @SEARCHED = ();
    my %saved = %BY_NAME;            # a lexical: restored by hand, not local()
    %BY_NAME = (%saved, %{ $o{names} || {} });
    my @got = ('UNSET');
    $S->can('_resolveArtist')->(
        'TestSvc', $query, $BY_NAME{ lc $query } || [], exists $o{spine} ? $o{spine} : $SP6, $fetch,
        sub { @got = @_ }, [ $native ], $search, 0, $o{compare} // 1);
    %BY_NAME = %saved;
    return @got;
}
my %FW = ('faye wong' => [ { id => 601, name => 'Faye Wong' } ], $WF => [ { id => 602, name => $WF } ]);

my ($w6, $al6, $bs6) = both('Faye Wong', $WF, names => \%FW);
ok(scalar(ref $w6 eq 'HASH' && $w6->{id} == 602),
   "6: the English name corroborates, the native one more: the native one wins (王菲 on Qobuz)");
ok(scalar(@SEARCHED == 1 && $SEARCHED[0] eq $WF), '6: ... because the native name was asked too, once');
ok(scalar(ref $bs6 eq 'ARRAY' && ($bs6->[0]{id} // 0) == 601 && @{ $bs6->[1] || [] } == 3),
   "6: ... and the English entry's albums go beside it (it corroborates strongly on its own)");

($w6, $al6, $bs6) = both('Faye Wong', $WF, names => \%FW, compare => 0);
ok(scalar(ref $w6 eq 'HASH' && $w6->{id} == 601 && !@SEARCHED && !defined $bs6),
   '6: control: without compare a strong first answer is taken at once (no extra search), as before');

($w6, $al6, $bs6) = both('Faye Wong', $WF, names => { %FW, $WF => [ { id => 603, name => $WF } ] });
ok(scalar(ref $w6 eq 'HASH' && $w6->{id} == 601 && !defined $bs6),
   '6: the English name corroborates more: it wins, and a weak native entry is not kept beside');

($w6, $al6, $bs6) = both('Faye Wong', $WF, names => { %FW, $WF => [ { id => 604, name => $WF } ] });
ok(scalar(ref $w6 eq 'HASH' && $w6->{id} == 601 && ref $bs6 eq 'ARRAY' && $bs6->[0]{id} == 604),
   '6: a tie keeps the English entry, the other beside');

($w6, $al6, $bs6) = both('Faye Wong', $WF, names => { %FW, $WF => [ { id => 601, name => $WF } ] });
ok(scalar(ref $w6 eq 'HASH' && $w6->{id} == 601 && !defined $bs6 && "@SEARCHED" eq $WF),
   '6: both names reach the SAME service artist: answered once, nothing beside');

($w6, $al6, $bs6) = both('Faye Wong', $WF, names => { %FW, $WF => [] });
ok(scalar(ref $w6 eq 'HASH' && $w6->{id} == 601 && !defined $bs6), '6: the native name finds nothing: the English answer stands');

($w6) = both('Faye Wong', $WF, names => { %FW, 'faye wong' => [ { id => 603, name => 'Faye Wong' } ] });
ok(scalar(ref $w6 eq 'HASH' && $w6->{id} == 602 && "@SEARCHED" eq $WF),
   '6: a weak English answer: the native name is asked next and wins, as any alias retry');

($w6) = both('Faye Wong', $WF, names => \%FW, spine => {});
ok(scalar(ref $w6 eq 'HASH' && $w6->{id} == 601 && !@SEARCHED), '6: no spine, no opinion: no extra search');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
