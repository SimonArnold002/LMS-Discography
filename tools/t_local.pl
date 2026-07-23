#!/usr/bin/env perl
#
# REGRESSION TEST — the LOCAL artist lookup must work for a name the user
# reaches BY NAME, not only by clicking an Artists row.
#
# WHY THIS EXISTS (full-library sweep + field, 2026-07-22). Simon: "we need to
# ensure all fixes we do for matching are done across matching from the rows in
# Artists and via our search." The &/and retry (0.44.23) and the punctuation
# probe (0.44.26) were built into searchArtists' Local leg ONLY. localAlbums'
# name fallback never got them, so browsing an artist BY NAME -- a search
# drill-in, a similar-artist link, a band link -- silently lost every album the
# user owns. Measured live on 0.45.1, browse by name:
#
#   Björk 0 local · Röyksopp 0 · The B‐52's 0 · Sigur Rós 5
#
# while the SAME artists browsed by artist_id return 2/1/4/5 correctly, and LMS
# itself finds all four. The library was never the problem.
#
# THE DEFECT: LMS's index folds accents (`search:Bjork` finds Björk), but
# nothing ever tried the folded spelling -- and a SINGLE-WORD accented name has
# no second term for the 0.44.26 term probe to use, so there was no route back.
#
# I ALSO expected a second defect -- `_norm` folding on octets while the name
# arrives as characters (the 0.43.3 _nameKey trap) -- and asserted it in a
# control below. THE CONTROL DISPROVED IT: 0.44.26's %FOLD extension already
# handles both shapes. Recorded because a wrong diagnosis left in the tests
# would send the next investigation somewhere there is no bug.
#
# Standalone -- no LMS install needed:  perl tools/t_local.pl
#
use strict;
use warnings;
use FindBin;

our @QUERIES;    # every search: string the code asked LMS for, in order
our %LIBRARY;    # search string -> rows LMS would return

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::Timers Slim::Networking::SimpleAsyncHTTP
                  Slim::Utils::Strings Slim::Utils::PluginManager
                  Slim::Control::Request Slim::Schema JSON::XS::VersionOneAndTwo
                  Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { '' };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { {} };
    # Stubbed LMS: records what was asked, answers from %LIBRARY.
    *{'Slim::Control::Request::executeRequest'} = sub {
        my (undef, $args) = @_;
        my ($search) = grep { /^search:/ } @$args;
        $search =~ s/^search://;
        push @QUERIES, $search;
        return bless { rows => $LIBRARY{$search} || [] }, 'T::Req';
    };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs JSON::XS::VersionOneAndTwo)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
    @{'JSON::XS::VersionOneAndTwo::EXPORT'} = qw(to_json from_json);
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Prefs; sub get { 1 } sub set { 1 } sub init { 1 } sub setChange { 1 }
package T::Req;   sub getResult { return $_[0]->{rows} }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
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

my $rows = \&Plugins::Discography::Sources::_localArtistRows;
my $key  = \&Plugins::Discography::Sources::_normKey;

# UTF-8 OCTETS, which is what the LMS database hands back and what a CLI param
# carries. Using a decoded literal here would misrepresent the input shape --
# the fixture bug this repo has hit three times (0.43.3, 0.44.19, 0.44.26).
my $BJORK  = "Bj\xc3\xb6rk";
my $SIGUR  = "Sigur R\xc3\xb3s";

# ---------------------------------------------------------------------------
# 1. THE FIELD CASE: a single-word accented name. LMS holds "Björk" and its
#    index folds accents, so the ASCII-folded spelling is the step that works.
#    The term probe cannot help -- there is only one term, and it has the mark.
# ---------------------------------------------------------------------------
@QUERIES = (); %LIBRARY = ('Bjork' => [{ id => 7, artist => $BJORK }]);
my $r = $rows->($BJORK);
ok(scalar(@$r) == 1 && $r->[0]{artist_id} == 7, 'Björk is found via the ASCII-folded spelling');
ok($QUERIES[0] eq $BJORK, '... after trying the exact spelling FIRST');
ok((grep { $_ eq 'Bjork' } @QUERIES), '... and the folded spelling was actually tried');

# ---------------------------------------------------------------------------
# 2. The exact spelling must WIN when it works -- no wasted queries, and no
#    chance of a folded spelling adopting a different artist.
# ---------------------------------------------------------------------------
@QUERIES = (); %LIBRARY = ($BJORK => [{ id => 7, artist => $BJORK }]);
$r = $rows->($BJORK);
ok(scalar(@$r) == 1, 'an exact hit is returned');
ok(scalar(@QUERIES) == 1, '... on the FIRST query, with no fallback work');

# ---------------------------------------------------------------------------
# 3. The &/and variant, which previously existed only on the search path.
# ---------------------------------------------------------------------------
@QUERIES = (); %LIBRARY = ('Simon & Garfunkel' => [{ id => 9, artist => 'Simon & Garfunkel' }]);
$r = $rows->('Simon and Garfunkel');
ok(scalar(@$r) == 1 && $r->[0]{artist_id} == 9, '"and" recovers an "&" artist');

# ---------------------------------------------------------------------------
# 4. The term probe still recovers a punctuation case (0.44.26's Jane's
#    Addiction), and runs LAST so it cannot pre-empt a cheaper exact match.
# ---------------------------------------------------------------------------
@QUERIES = (); %LIBRARY = ('Addiction' => [{ id => 11, artist => "Jane's Addiction" }]);
$r = $rows->('Janes Addiction');
ok(scalar(@$r) == 1 && $r->[0]{artist_id} == 11, "term probe recovers Jane's Addiction");
ok($QUERIES[-1] eq 'Addiction', '... and the probe ran last');

# ---------------------------------------------------------------------------
# 4b. TYPOGRAPHIC PUNCTUATION. U+2010 HYPHEN and U+2019 APOSTROPHE are not
#     combining marks, so NFD leaves them and a naive strip JOINS the words --
#     "Yo\x{2010}Yo Ma" became "YoYo Ma", which LMS cannot match. Measured: this
#     is why these two still failed after the fold had recovered Bjork.
# ---------------------------------------------------------------------------
my $YOYO = "Yo\xe2\x80\x90Yo Ma";           # U+2010 HYPHEN
my $B52  = "The B\xe2\x80\x9052\xe2\x80\x99s";  # U+2010 + U+2019
@QUERIES = (); %LIBRARY = ('Yo-Yo Ma' => [{ id => 21, artist => $YOYO }]);
$r = $rows->($YOYO);
ok(scalar(@$r) == 1 && $r->[0]{artist_id} == 21, 'U+2010 hyphen transliterates to "-"');
ok((grep { $_ eq 'Yo-Yo Ma' } @QUERIES), '... and "Yo-Yo Ma" was the spelling tried');
ok(!(grep { $_ eq 'YoYo Ma' } @QUERIES), '... never the word-joining "YoYo Ma"');

@QUERIES = (); %LIBRARY = ("The B-52's" => [{ id => 22, artist => $B52 }]);
$r = $rows->($B52);
ok(scalar(@$r) == 1 && $r->[0]{artist_id} == 22, 'curly apostrophe + hyphen both transliterate');

# ---------------------------------------------------------------------------
# 5. A genuine miss stays a miss -- widening the net must not invent an artist.
# ---------------------------------------------------------------------------
@QUERIES = (); %LIBRARY = ();
ok(scalar(@{ $rows->('No Such Artist Anywhere') }) == 0, 'an unknown artist finds nothing');

# ---------------------------------------------------------------------------
# 6. THE COMPARISON, pinned in both encodings. _normKey encodes before folding
#    so the caller's key cannot depend on which shape the name arrived in --
#    defensive, not a fix (see the correction in the header).
# ---------------------------------------------------------------------------
my $chars = $BJORK; utf8::decode($chars);
ok($key->($chars) eq $key->($BJORK), '_normKey folds chars and octets identically');
ok($key->($chars) eq 'bjork', '... to the ASCII-folded key');
# MEASURED, and it CORRECTED my diagnosis: I expected raw _norm to disagree
# across encodings (the 0.43.3 _nameKey trap) and wrote this control asserting
# it did. It does NOT -- 0.44.26's %FOLD extension already handles both shapes,
# so that defect does not exist here and the ONLY real bug was the missing
# ASCII-folded QUERY. _normKey stays as explicit, defensive intent, not a fix.
ok(Plugins::Discography::Sources::_norm($chars) eq Plugins::Discography::Sources::_norm($BJORK),
   'raw _norm ALREADY agrees across encodings (corrects my hypothesis)');
my $sc = $SIGUR; utf8::decode($sc);
ok($key->($sc) eq $key->($SIGUR), '_normKey agrees for a multi-word accented name too');

# ---------------------------------------------------------------------------
# 7. Two different artists must not collapse onto one key.
# ---------------------------------------------------------------------------
ok($key->('Bush') ne $key->('Kate Bush'), 'distinct artists keep distinct keys');

# ---------------------------------------------------------------------------
# 8. A SHORT NON-ASCII TOKEN is a whole word, not a stopword (field 2026-07-23:
#    an artist whose name is symbols + combining marks whose ONLY LMS-indexable
#    handle is the 2-char token "ꉺლ"). The exact spelling and the ASCII fold both
#    miss; the length floor USED to skip a <4-char token, so the probe found
#    nothing and the owned album resolved to a streaming service instead of
#    Local. RED against the pre-fix floor (grep length >= 4). Octet fixtures per
#    the shape convention above.
# ---------------------------------------------------------------------------
my $TOK   = "\xea\x89\xba\xe1\x83\x9a";                 # ꉺლ  (U+A27A U+10DA)
my $ZALGO = "\xe2\xa3\x8e" . $TOK . " )( " . $TOK;      # ⣎ꉺლ )( ꉺლ  (braille + token)
@QUERIES = (); %LIBRARY = ($TOK => [{ id => 88, artist => $ZALGO }]);
$r = $rows->($ZALGO);
ok(scalar(@$r) == 1 && $r->[0]{artist_id} == 88, 'a short non-ASCII token is probed and locates the artist');
ok(scalar(grep { $_ eq $TOK } @QUERIES), '... the 2-char token was actually tried');
ok($QUERIES[0] eq $ZALGO, '... after the exact spelling was tried FIRST');
# A short ASCII token must STILL be skipped -- the floor is only lifted for
# non-ASCII, so this proves the change is surgical, not a blanket lowering. Both
# tokens of "Xy Zq" are 2-char ASCII, so no single-token probe may ever run.
@QUERIES = (); %LIBRARY = ();
$rows->('Xy Zq');
ok(!(grep { $_ eq 'Xy' || $_ eq 'Zq' } @QUERIES), 'a short ASCII token is NOT admitted as a probe term');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
