#!/usr/bin/env perl
#
# REGRESSION TEST — SAME-TITLE RIVALRY: which release group owns a streaming
# candidate when several share a title.
#
# THE FIELD CASE (full-library sweep, 2026-07-21; diagnosed 2026-07-22).
# **Three of ABBA's nine studio albums were missing from the page** — and they
# were exactly the three whose title is ALSO a single:
#
#   Albums (6)  Voyage · The Visitors · Voulez-vous · The Album · Arrival · ABBA
#   MISSING     Ring Ring · Waterloo · Super Trouper
#
# Every fixture below is the REAL MusicBrainz record, read off the mirror:
#
#   Waterloo       Album 1974-03-04   vs  Single 1974-03
#   Super Trouper  Album 1980-11-03   vs  Single 1980-11
#   Ring Ring      Album 1973-03-26   vs  Single 1973-02-14
#
# The rivals were sorted by `date cmp`, so the SINGLE came first, took the
# streaming candidate, and `hide_unmatched` removed the album. Note WHY for two
# of the three, because it is not what anyone intended: a partial date is a
# PREFIX of the fuller one, so "1980-11" sorts before "1980-11-03" — the
# tie-break was deciding on date PRECISION, not chronology.
#
# The second half of the same finding: rivals included groups the user's TYPE
# FILTER hides, so with Singles hidden the single still won and NEITHER row
# appeared. That list already excludes bootlegs and Remix/DJ-mix for precisely
# this reason; `show_types` had been missed.
#
# Standalone -- no LMS install needed:  perl tools/t_rivals.pl
#
use strict;
use warnings;
use FindBin;

our %SHOW_TYPES;   # what _shownTypes() reports, per scenario

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::Timers Slim::Networking::SimpleAsyncHTTP
                  Slim::Utils::Strings Slim::Utils::PluginManager
                  Slim::Control::Request Slim::Schema Slim::Web::HTTP
                  Slim::Utils::Misc Slim::Menu::GlobalSearch
                  JSON::XS::VersionOneAndTwo Slim::Plugin::OPMLBased
                  Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}          = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Prefs' };
    *{'Slim::Utils::Strings::cstring'}     = sub { $_[1] };
    *{'Slim::Utils::Strings::string'}      = sub { $_[0] };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = qw(cstring string);
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Prefs;
sub get {
    my (undef, $k) = @_;
    return join(',', sort keys %main::SHOW_TYPES) if $k eq 'show_types';
    return undef;
}
sub set { 1 } sub init { 1 } sub setChange { 1 }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;
require Plugins::Discography::Sources;

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

my $rivalsBy = \&Plugins::Discography::Browse::_rivalsByTitle;
my $ownerOf  = \&Plugins::Discography::Sources::_rivalOwner;

# THE REAL ABBA RECORDS (mirror, 2026-07-22).
my $ALB_ST = { mbid => '24944755-aaaa', title => 'Super Trouper', type => 'Album',
               date => '1980-11-03', secondary => [] };
my $SNG_ST = { mbid => 'ba5c3173-bbbb', title => 'Super Trouper', type => 'Single',
               date => '1980-11',    secondary => [] };
my $ALB_WL = { mbid => '1f78ea53-aaaa', title => 'Waterloo', type => 'Album',
               date => '1974-03-04', secondary => [] };
my $SNG_WL = { mbid => '1ef433be-bbbb', title => 'Waterloo', type => 'Single',
               date => '1974-03',    secondary => [] };
my $ALB_RR = { mbid => '506764b9-aaaa', title => 'Ring Ring', type => 'Album',
               date => '1973-03-26', secondary => [] };
my $SNG_RR = { mbid => '6a7c56e2-bbbb', title => 'Ring Ring', type => 'Single',
               date => '1973-02-14', secondary => [] };   # genuinely EARLIER
my $COMP_RR = { mbid => 'a3d7d8c3-cccc', title => 'Ring Ring', type => 'Album',
                date => '1998', secondary => ['Compilation'] };

my $ALL = { map { $_ => 1 } qw(ALBUMS EPS SINGLES COMPILATIONS LIVE OTHER) };
sub rivals_for {
    my ($rgs, $show) = @_;
    my $r = $rivalsBy->($rgs, undef, $show || $ALL);
    return $r;
}

# ---------------------------------------------------------------------------
# 1. THE THREE FIELD CASES. The candidate's year matches BOTH rivals, so the
#    owner is decided purely by rival ORDER — the album must win.
# ---------------------------------------------------------------------------
for my $case ( ['Super Trouper', $ALB_ST, $SNG_ST, 1980],
               ['Waterloo',      $ALB_WL, $SNG_WL, 1974],
               ['Ring Ring',     $ALB_RR, $SNG_RR, 1973] ) {
    my ($title, $alb, $sng, $year) = @$case;
    my $r = rivals_for([ $sng, $alb ]);      # single listed FIRST, as MB returns it
    my $key = Plugins::Discography::Sources::_norm($title);
    ok($ownerOf->($year, $r->{$key}) eq $alb->{mbid},
       "$title: the ALBUM owns the candidate, not the single");
}

# The undated / non-matching-year branch takes rivals[0] outright — same answer.
my $r = rivals_for([ $SNG_ST, $ALB_ST ]);
my $stKey = Plugins::Discography::Sources::_norm('Super Trouper');
ok($ownerOf->(undef, $r->{$stKey}) eq $ALB_ST->{mbid},
   'an UNDATED candidate also goes to the album (rivals[0])');
ok($ownerOf->(2011, $r->{$stKey}) eq $ALB_ST->{mbid},
   'a remaster year matching NEITHER rival goes to the album too');

# ---------------------------------------------------------------------------
# 2. THE COMPILATION RANK STILL OUTRANKS TYPE — 0.16.0's rule, which is what
#    keeps the White Album off its four same-titled compilations. A compilation
#    is Album-typed, so without `comp` ranking first this would regress.
# ---------------------------------------------------------------------------
$r = rivals_for([ $COMP_RR, $SNG_RR, $ALB_RR ]);
my $rrKey = Plugins::Discography::Sources::_norm('Ring Ring');
ok($ownerOf->(1973, $r->{$rrKey}) eq $ALB_RR->{mbid},
   'the real album still beats a same-titled COMPILATION');
ok($ownerOf->(1998, $r->{$rrKey}) eq $COMP_RR->{mbid},
   '... and the compilation still wins on its OWN year (0.16.0 intact)');

# ---------------------------------------------------------------------------
# 3. A GROUP THE USER HAS HIDDEN CANNOT OWN ANYTHING. With Singles hidden, the
#    single must not take a candidate the album would then never show.
# ---------------------------------------------------------------------------
my $noSingles = { ALBUMS => 1, COMPILATIONS => 1, LIVE => 1, EPS => 1, OTHER => 1 };
$r = rivals_for([ $SNG_ST, $ALB_ST ], $noSingles);
ok(scalar(@{ $r->{$stKey} }) == 1, 'a hidden SINGLES group is not a rival at all');
ok($ownerOf->(1980, $r->{$stKey}) eq $ALB_ST->{mbid},
   '... so the album keeps its candidate');

# And the mirror image: hide ALBUMS and the single is the only rival left.
my $noAlbums = { SINGLES => 1, COMPILATIONS => 1, LIVE => 1, EPS => 1, OTHER => 1 };
$r = rivals_for([ $SNG_ST, $ALB_ST ], $noAlbums);
ok(scalar(@{ $r->{$stKey} }) == 1 && $ownerOf->(1980, $r->{$stKey}) eq $SNG_ST->{mbid},
   'hiding ALBUMS leaves the single owning it — the filter cuts both ways');

# ---------------------------------------------------------------------------
# 4. BOOTLEGS AND REMIX/DJ-MIX still cannot own a candidate (0.13.0 / 0.16.0),
#    and an EP sits between album and single.
# ---------------------------------------------------------------------------
my $BOOT = { mbid => 'deadbeef-boot', title => 'Super Trouper', type => 'Album',
             date => '1980-01-01', secondary => [] };
$r = $rivalsBy->([ $BOOT, $ALB_ST ], { 'deadbeef-boot' => 0, '24944755-aaaa' => 1 }, $ALL);
ok(scalar(@{ $r->{$stKey} }) == 1 && $r->{$stKey}[0]{mbid} eq $ALB_ST->{mbid},
   'a BOOTLEG is still excluded from the rivals');

my $REMIX = { mbid => 'remix-0001', title => 'Super Trouper', type => 'Album',
              date => '1980-01-01', secondary => ['Remix'] };
$r = rivals_for([ $REMIX, $ALB_ST ]);
ok(scalar(@{ $r->{$stKey} }) == 1, 'a REMIX group is still excluded');

my $EP = { mbid => 'ep-000001', title => 'Super Trouper', type => 'EP',
           date => '1980-01-01', secondary => [] };
$r = rivals_for([ $SNG_ST, $EP, $ALB_ST ]);
ok(join(',', map { $_->{mbid} } @{ $r->{$stKey} })
   eq join(',', $ALB_ST->{mbid}, $EP->{mbid}, $SNG_ST->{mbid}),
   'rank order is Album, EP, Single regardless of date');

# ---------------------------------------------------------------------------
# 5. AN UNTYPED GROUP SORTS WITH ALBUM, not last — demoting it would recreate
#    this bug for artists MusicBrainz has typed loosely.
# ---------------------------------------------------------------------------
my $UNTYPED = { mbid => 'untyped-01', title => 'Super Trouper', type => undef,
                date => '1980-11-03', secondary => [] };
$r = rivals_for([ $SNG_ST, $UNTYPED ]);
ok($ownerOf->(1980, $r->{$stKey}) eq $UNTYPED->{mbid},
   'an UNTYPED group beats a single (it is usually the studio release)');

# ---------------------------------------------------------------------------
# 6. ORDER IS DETERMINISTIC. Rebuilding the tree must give the same owner
#    whatever order MB returned the groups in — item_id walks depend on it.
# ---------------------------------------------------------------------------
my $a = rivals_for([ $SNG_ST, $ALB_ST, $EP ]);
my $b = rivals_for([ $EP, $ALB_ST, $SNG_ST ]);
ok(join(',', map { $_->{mbid} } @{ $a->{$stKey} })
   eq join(',', map { $_->{mbid} } @{ $b->{$stKey} }),
   'rival order does not depend on the input order');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
