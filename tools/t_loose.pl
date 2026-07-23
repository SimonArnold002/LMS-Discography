#!/usr/bin/env perl
#
# REGRESSION TEST — the UNQUOTED (loose) MB artist pass may only adopt the artist
# that was actually asked for.
#
# WHY THIS EXISTS (field, 2026-07-21 — Simon: "If I search Janes Addiction in MB
# it finds it straight away top hit"). He was right: the restriction was OURS.
# The plugin sends an exact Lucene phrase, and measured against the mirror:
#   artist:"janes addiction"  -> count 0      an exact phrase cannot match
#   janes addiction           -> count 239    "Jane's Addiction", which
#   artist:janes addiction    -> count 208    tokenises [jane][s][addiction]
# with Jane's Addiction the top hit at score 100 unquoted — what MB's own search
# box does. So a loose LAST pass was added after both quoted passes miss.
#
# THE HAZARD IT GUARDS: Lucene normalises the best match to 100, so the >=90
# score gate is nearly a NO-OP on a loose query — any unquoted search returning
# rows offers a >=90 top hit. Left ungated, a nonsense query would adopt whatever
# came back and show the WRONG discography, which is strictly worse than the
# honest miss it replaced. So the loose winner must also BE the artist asked for:
# the exact-name preference matched, or `_closeEnough` accepts it.
#
# The fixtures are real MB top hits, measured against the mirror, not invented.
#
# Standalone — no LMS install needed:  perl tools/t_loose.pl
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
package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;

my $norm = \&Plugins::Discography::Sources::_norm;
my $ce   = \&Plugins::Discography::Sources::_closeEnough;

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

# The gate exactly as API.pm applies it on a loose pass: $exact means a candidate
# whose _norm name EQUALS the query (the 0.44.14 exact-name preference), which is
# accepted outright; otherwise the top hit must be _closeEnough.
sub accepts {
    my ($asked, $topHit) = @_;
    my $want = $norm->($asked);
    my $got  = $norm->($topHit);
    return 1 if $got eq $want;              # exact-name preference
    return $ce->($want, $got) ? 1 : 0;      # typo tolerance
}

# 1. THE FIX — the punctuation class this was built for.
ok(accepts('janes addiction', "Jane\x{2019}s Addiction"),
   "'janes addiction' adopts Jane's Addiction (the reported bug)");
ok(accepts("jane's addiction", "Jane\x{2019}s Addiction"),
   'the correctly spelled query still adopts it');

# 2. Typos come along for free — these are REAL queries from Simon's log that
#    each cost a wasted public round trip and resolved to nothing.
{
    my $sigur = "Sigur R\x{f3}s"; utf8::encode($sigur);
    ok(accepts('sigor ros', $sigur), "'sigor ros' adopts Sigur Ros");
}
ok(accepts('flornce and the machine', 'Florence + the Machine'),
   "'flornce and the machine' adopts Florence + the Machine");

# 3. THE HAZARD — a loose query returns a >=90 top hit for almost anything, so
#    these must be REJECTED or the plugin shows the wrong artist's discography.
ok(!accepts('blue addiction', "Jane\x{2019}s Addiction"),
   "'blue addiction' does NOT adopt Jane's Addiction");
ok(!accepts('addiction', "Jane\x{2019}s Addiction"),
   "a bare shared word does NOT adopt the band");
{
    my $sigur = "Sigur R\x{f3}s"; utf8::encode($sigur);
    ok(!accepts('sogor', $sigur), "'sogor' (garbage) adopts nothing");
}
ok(!accepts('machine', 'Florence + the Machine'),
   "'machine' does NOT adopt Florence + the Machine");
ok(!accepts('the', "Jane\x{2019}s Addiction"), 'a stopword adopts nothing');

# 4. THE DOCUMENTED TRAP MUST SURVIVE (0.44.14, field 2026-07-19: "i see Kate
#    Bush under Bush and none of thier albums"). Unquoted `artist:bush` returns
#    Kate Bush at 100 with the band Bush second at 95 — the exact-name preference
#    is what picks Bush, and it must still reject Kate Bush as the top hit.
ok(!accepts('bush', 'Kate Bush'), "'bush' does NOT adopt Kate Bush as top hit");
ok(accepts('bush', 'Bush'),       "'bush' adopts the band Bush (exact name)");

# 5. Accents and the apostrophe fold on BOTH sides of the gate.
{
    my $b = "Bj\x{f6}rk"; utf8::encode($b);
    ok(accepts('bjork', $b), "'bjork' adopts Bjork");
}
ok(accepts('guns n roses', "Guns N' Roses"), "'guns n roses' adopts Guns N' Roses");

# 6. A near-miss on a SHORT name must not sneak through: _closeEnough refuses
#    anything under FUZZY_MIN_LEN, which is what keeps 3-4 letter acts distinct.
ok(!accepts('abba', 'Abbas'), 'a short name is not fuzzy-matched');
ok(!accepts('muse', 'Music'), 'another short-name guard');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
