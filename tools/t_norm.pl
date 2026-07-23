#!/usr/bin/env perl
#
# REGRESSION TEST — _norm treats a DECORATIVE "!"/"$"/"@" as punctuation, and a
# leetspeak one as a letter.
#
# WHY THIS EXISTS (field, 2026-07-21). `_norm` folded every "!" to "i"
# unconditionally, so a name spelled WITH the mark did not match the same name
# spelled WITHOUT it. Three symptoms, one cause:
#   1. "Panic At The Disco" could not be searched without typing the "!"
#      ('panici at the disco' defeats the substring/token relevance gate).
#   2. The same-name row fold picked a different survivor per query, because
#      the two spellings keyed differently.
#   3. THE SERIOUS ONE — `_albumMatches`' artist gate is MANDATORY, so browsing
#      "Layo & Bushwacka" (no mark) rejected EVERY streaming candidate credited
#      "Layo & Bushwacka!" and the page read "No releases found" for an artist
#      with five MB albums and a correctly resolved MBID.
#
# The rule: substitute only when a word character FOLLOWS the mark (it is
# inside a word, so it stands in for a letter). Otherwise it is decoration.
#
# GUARD THE GUARD: a name made entirely of these marks ("!!!" — a real band)
# must NOT normalise to empty, because `_artistMatch` rejects an empty side
# outright, which would be the same bug wearing a different hat.
#
# DSC-ONLY DRIFT: `_norm` is fleet-synced (see CLAUDE.md). This change is
# deliberately Discography-only pending field proof, so matcher_sync_check.py
# reports drift on `_norm` BY DESIGN until it is ported.
#
# Standalone — no LMS install needed:  perl tools/t_norm.pl
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

my $norm = \&Plugins::Discography::Sources::_norm;
my $amat = \&Plugins::Discography::Sources::_artistMatch;
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

# 1. THE BUG: a decorative mark must not change the normalised form.
for my $p (['Layo & Bushwacka!',           'Layo & Bushwacka'],
           ['Panic! At The Disco',         'Panic At The Disco'],
           ['Godspeed You! Black Emperor', 'Godspeed You Black Emperor'],
           ['Wham!',                       'Wham']) {
    ok($norm->($p->[0]) eq $norm->($p->[1]),
       "'$p->[0]' == '$p->[1]'  (" . $norm->($p->[0]) . ')');
}

# 2. REGRESSION GUARD: an INTERIOR mark is a letter and must still fold.
ok($norm->('P!nk')  eq 'pink',  'P!nk -> pink');
ok($norm->('Ke$ha') eq 'kesha', 'Ke$ha -> kesha');
ok($norm->('M@ss')  eq 'mass',  'M@ss -> mass');

# A TRAILING "$" IS STILL A LETTER. Regression from the fleet port (2026-07-21):
# scoping the boundary rule to "$" as well as "!" turned "$uicideboy$" into
# "suicideboy", which no longer matches "Suicideboys" — a case PFR's own
# comment documents as supported. "!" has a decorative use ("Wham!"); "$" and
# "@" effectively do not, so only "!" is boundary-scoped. Caught by comparing
# all four repos' _norm behaviourally, NOT by the sync check (which compares
# text, so it would have happily reported four identical copies of a bug).
ok($norm->('$uicideboy$') eq 'suicideboys', 'trailing $ is a letter, not decoration');
ok($norm->('WOR$T')       eq 'worst',       'WOR$T -> worst');

# 3. A name of nothing but marks must not normalise away.
ok($norm->('!!!') ne '', "'!!!' does not normalise to empty (got '"
                          . $norm->('!!!') . "')");

# 4. The field failure itself, through the real artist gate.
ok($amat->($norm->('Layo & Bushwacka'), $norm->('Layo & Bushwacka!')),
   'artist gate: browsing without the mark accepts a marked credit');

# 5. Genuinely different acts must STAY different (fold controls from the log).
for my $p (['Bush', 'Kate Bush'], ['Iron Maiden', 'The Iron Maidens'],
           ['Beatles', 'Beatless']) {
    ok($norm->($p->[0]) ne $norm->($p->[1]), "'$p->[0]' != '$p->[1]'");
}

# 5b. "&" / "+" are spoken "and" — the SAME act arriving from two services
#     under different spellings must key identically (field: Deezer's "Layo and
#     bushwacka!" vs Tidal's "Layo & Bushwacka").
for my $p (['Simon & Garfunkel',   'Simon and Garfunkel'],
           ['Layo & Bushwacka!',   'Layo and bushwacka!'],
           ['Florence + the Machine', 'Florence and the Machine'],
           ['Above & Beyond',      'Above and Beyond']) {
    ok($norm->($p->[0]) eq $norm->($p->[1]),
       "'$p->[0]' == '$p->[1]'  (" . $norm->($p->[0]) . ')');
}

# 5c. It must NOT over-merge: folding "&" to a word cannot make DIFFERENT acts
#     collide, and the leetspeak/decoration rules must survive alongside it.
ok($norm->('Simon & Garfunkel') ne $norm->('Garfunkel & Oates'),
   "'Simon & Garfunkel' != 'Garfunkel & Oates'");
ok($norm->('Layo & Bushwacka!') ne $norm->('Bushwacka!'),
   "'Layo & Bushwacka!' != 'Bushwacka!' (the solo project stays separate)");
ok($norm->('Above & Beyond') eq 'above and beyond', 'ampersand folds to the word');
ok($norm->('P!nk') eq 'pink', 'leetspeak still folds alongside the & rule');

# 6. Accent folding untouched, in BOTH real input shapes.
#
# The fixture matters as much as the assertion (0.43.3): a bare chr(0xF3) is a
# single UNFLAGGED byte — not valid UTF-8, and not what either real caller
# hands in — so testing it indicts the code for the fixture's fault. The two
# real shapes are a DECODED string (MB's JSON) and OCTETS (a CLI param), and
# `_norm` must agree on both.
my $chars = 'Sigur R' . chr(0xF3) . 's';
utf8::upgrade($chars);
my $octets = $chars;
utf8::encode($octets);
ok($norm->($chars)  eq 'sigur ros', 'accents fold (decoded string, as MB JSON)');
ok($norm->($octets) eq 'sigur ros', 'accents fold (octets, as a CLI param)');
ok($norm->($chars) eq $norm->($octets), 'both encodings agree');

# 7. APOSTROPHES ELIDE — they do not become a space (field, 2026-07-21).
#
# Spacing keyed "Jane's Addiction" as 'jane s addiction' against
# 'janes addiction'. `_artistMatch` is an exact-token SUBSET test, so the token
# 'janes' matched nothing and the act failed against EVERY source, library and
# streaming alike. Both spellings are common in the wild, and LMS's own index
# tokenises on the mark (verified live: `artists search:Connor` returns
# "Sinead O'Connor"), so eliding is what puts them on one key.
for my $p (["Jane's Addiction",  'Janes Addiction'],
           ["D'Angelo",          'DAngelo'],
           ["O'Neal",            'ONeal'],
           ["The B-52's",        'The B-52s'],
           ["'Til Tuesday",      'Til Tuesday'],
           ["Guns N' Roses",     'Guns N Roses']) {
    ok($norm->($p->[0]) eq $norm->($p->[1]),
       "'$p->[0]' == '$p->[1]'  (" . $norm->($p->[0]) . ')');
}

# 7a. The typographic apostrophe folds identically to the ASCII one — services
#     and MB disagree on which they use for the SAME act.
ok($norm->("Jane\x{2019}s Addiction") eq $norm->("Jane's Addiction"),
   'curly apostrophe == straight apostrophe');

# 7b. GUARD THE GUARD — "'n'" contracting "and" joins two WORDS rather than
#     sitting inside one, so a blind elide would key "Rock'n'Roll" as
#     'rocknroll' while the spaced form stayed 'rock n roll'. All three
#     spellings agreed BEFORE this change and must still agree after it.
ok($norm->("Rock'n'Roll") eq $norm->("Rock 'n' Roll"),
   "\"Rock'n'Roll\" == \"Rock 'n' Roll\"  (" . $norm->("Rock'n'Roll") . ')');
ok($norm->("Rock'n'Roll") eq $norm->('Rock N Roll'),
   "\"Rock'n'Roll\" == 'Rock N Roll'");
ok($norm->("Rock \x{2019}n\x{2019} Roll") eq $norm->('Rock N Roll'),
   'curly "n" contraction agrees too');

# 7c. It must NOT over-merge: eliding a mark cannot make different acts collide,
#     and it must not swallow a name down to a token that matches anything.
ok($norm->("Jane's Addiction") ne $norm->('Jane'),
   "'Jane's Addiction' != 'Jane'");
ok($norm->('N.W.A') ne $norm->('N.E.R.D'),
   "'N.W.A' != 'N.E.R.D' (initialisms keep their separate tokens)");
ok($norm->("Jane's Addiction") eq 'janes addiction', 'elide, not space');
ok($amat->($norm->("Sin\x{e9}ad O\x{2019}Connor"), $norm->("Sinead O'Connor")),
   'accent + apostrophe fold together through _artistMatch');

# 8. ACCENTED NAMES MUST BE FINDABLE TYPED PLAIN (Simon, 2026-07-21:
#    "any accented characters need to pass").
#
# Two different mechanisms, and the distinction is the point:
#   - a letter + COMBINING MARK (ó ö ř é è ï ü ñ) folds via the NFD pass, which
#     needs no table and covers the whole Unicode range;
#   - a letter carrying a STROKE, HOOK or LIGATURE (ø đ ł ŧ æ œ ß ĳ ǉ) has NO
#     canonical decomposition, so NFD cannot touch it and %FOLD must.
# Tested in the OCTET encoding, which is how a library name actually arrives.
for my $p (["Sigur R\x{f3}s",       'Sigur Ros'],
           ["Bj\x{f6}rk",           'Bjork'],
           ["Mot\x{f6}rhead",       'Motorhead'],
           ["Beyonc\x{e9}",         'Beyonce'],
           ["Blue \x{d6}yster Cult",'Blue Oyster Cult'],
           ["Antonin Dvo\x{159}\x{e1}k", 'Antonin Dvorak'],
           ["Bj\x{f6}rk Gu\x{f0}mundsd\x{f3}ttir", 'Bjork Gudmundsdottir'],
           ["Stra\x{df}e",          'Strasse'],
           ["\x{c6}on",             'Aeon'],
           ["\x{141}ukasz",         'Lukasz'],
           ["Ni\x{f1}o",            'Nino']) {
    my ($x, $y) = map { my $s = $_; utf8::encode($s); $norm->($s) } @$p;
    ok($x eq $y, "'$p->[0]' == '$p->[1]'  ($x)");
}

# 8a. NOTHING accented may reach the key still non-ASCII, or the name is
#     unfindable typed plain. Swept over the Latin ranges; the only survivors
#     allowed are click/glottal/tone letters with no ASCII base.
{
    my @bad;
    for my $cp (0xC0 .. 0x24F) {
        my $ch = chr($cp);
        next unless $ch =~ /\p{L}/;
        my $s = "test${ch}name";
        utf8::encode($s);
        push @bad, sprintf('U+%04X', $cp) if $norm->($s) =~ /[^\x00-\x7f]/;
    }
    ok(@bad <= 26, 'Latin sweep: no accented letter survives to the key ('
       . scalar(@bad) . ' unmapped phonetic letters, was 130)');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
