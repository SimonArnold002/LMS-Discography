#!/usr/bin/env perl
#
# REGRESSION TEST — a LONE search row still gets attached to the user's library.
#
# FIELD (Simon, 2026-07-22): searching "The Las" rendered "The La's" with only
# Tidal/Deezer, although he owns it. Three independent safety nets exist, and
# this is the one name that slips past ALL of them at once:
#
#   1. Local leg      `artists search:The Las` -> The Last / The Last Word /
#                     The Last Dinner Party. Real bands, WRONG ones — and
#                     `_localArtistRows` returns at the first NON-EMPTY step,
#                     so a wrong answer BLOCKS the fallbacks. ("Las" is a
#                     prefix of "Last"; "OJays" is a prefix of nothing.)
#   2. term probes    skipped: every word is under PUNCT_PROBE_MIN_LEN — "The"
#                     (3) and "Las" (3). Rag'n'Bone Man survives only because
#                     "Bone" happens to be 4 letters.
#   3. MB alias attach (API::filterRowsWithContent) runs ONLY for DUPLICATED
#                     mbid groups. Every service spells this one identically,
#                     so it is a lone row. The O'Jays is rescued there purely
#                     because the services disagreed (straight vs curly
#                     apostrophe) — luck, not design.
#
# Not an apostrophe problem: a SHORT-NAME problem, where the plain spelling
# collides with other real artists and the services happen to agree.
#
# Standalone -- no LMS install needed:  perl tools/t_lone.pl
#
use strict;
use warnings;
use FindBin;

my @QUERIES;

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
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    # THE LIBRARY, exactly as LMS indexes it: an apostrophe SPLITS the token,
    # so "La's" is reachable by "La's" / "La s" but never by "Las".
    *{'Slim::Control::Request::executeRequest'} = sub {
        my (undef, $args) = @_;
        # `albums artist_id:N` — how many albums that contributor holds. The
        # duplicate-contributor case turns on this: 58667 has NONE.
        if (my ($aid) = map { /^artist_id:(\d+)/ ? $1 : () } @$args) {
            return bless { count => main::albums_for($aid) }, 'T::Req';
        }
        my ($search) = grep { /^search:/ } @$args;
        return bless { rows => [] }, 'T::Req' unless defined $search;
        $search =~ s/^search://;
        push @QUERIES, $search;
        return bless { rows => main::library_for($search) }, 'T::Req';
    };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Prefs; sub get { 1 } sub set { 1 } sub init { 1 } sub setChange { 1 }
package T::Req;
sub getResult {
    my ($self, $what) = @_;
    return $self->{count} if defined $what && $what eq 'count';
    return $self->{rows};
}

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
my $SRC = 'Plugins::Discography::Sources';

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

# The user's library. Note BOTH apostrophe spellings exist as separate
# contributors — that is real (Simon's library holds The La's AND The La’s).
my @LIB = (
    { name => "The La\x{2019}s",  artist_id => 57545 },
    { name => "The La's",         artist_id => 58667 },
    { name => 'The Last',         artist_id => 60873 },
    { name => 'The Last Word',    artist_id => 56718 },
    { name => 'Allah-Las',        artist_id => 53643 },
    { name => 'The B-52s',        artist_id => 62125 },
    { name => "Bj\x{f6}rk",       artist_id => 54001 },
);

# Album counts, measured live: the ASCII "The La's" contributor holds NOTHING
# (it exists only as a compilation track-artist), the curly one holds five.
my %ALBUMS = (57545 => 5, 58667 => 0, 60873 => 2, 56718 => 1,
              53643 => 3, 62125 => 4, 54001 => 6);
sub albums_for { return $ALBUMS{ $_[0] } // 0 }

# LMS's index: a prefix match per TOKEN, an apostrophe SPLITS the token, and
# accents are FOLDED (verified live — `artists search:Bjork` finds "Björk",
# which is why _localArtistRows carries an ASCII-fold step at all).
sub _fold {
    my ($s) = @_;
    utf8::decode($s) unless utf8::is_utf8($s);
    if (eval { require Unicode::Normalize; 1 }) {
        $s = Unicode::Normalize::NFD($s);
        $s =~ s/\p{NonspacingMark}//g;
    }
    return lc $s;
}
sub library_for {
    my ($q) = @_;
    my @want = grep { length } split /[^\p{Alnum}]+/, _fold($q);
    return [] unless @want;
    my @hits;
    for my $a (@LIB) {
        my @toks = grep { length } split /[^\p{Alnum}]+/, _fold($a->{name});
        my $all = 1;
        for my $w (@want) {
            $all = 0, last unless grep { index($_, $w) == 0 } @toks;
        }
        push @hits, { artist => $a->{name}, id => $a->{artist_id} } if $all;
    }
    return \@hits;
}

# Sanity: the fixture must reproduce the REAL LMS behaviour this bug rests on.
{
    my $names = sub { join ',', map { $_->{artist} }
                      @{ library_for($_[0]) } };
    ok(scalar($names->('The Las') =~ /The Last/ && $names->('The Las') !~ /La.s,|La\x{2019}s/),
       'fixture: "The Las" finds The Last etc. but NOT The La\'s (non-empty, wrong)');
    ok(scalar($names->("The La's") =~ /La/), 'fixture: "The La\'s" DOES find the band');
}

sub row { my ($n, @s) = @_; return { name => $n, sources => [@s] } }
sub attach { return $SRC->attachLibraryArtists($_[0]) }

# ---------------------------------------------------------------------------
# 1. THE FIELD CASE.
# ---------------------------------------------------------------------------
{
    @QUERIES = ();
    my $out = attach([ row("The La's", 'Tidal', 'Deezer') ]);
    ok(scalar(@$out == 1), 'the row survives');
    ok(scalar(grep { $_ eq 'Local' } @{ $out->[0]{sources} }),
       'a lone "The La\'s" row GAINS Local from the library');
    ok($out->[0]{artist_id}, '... and carries the library artist_id (drill-in resolves by tag)');
    ok(scalar($out->[0]{sources}[0] eq 'Local'), '... with Local ordered first');
}

# ---------------------------------------------------------------------------
# 2. THE NEGATIVE THAT MATTERS. _normKey folds "The Las" and "The La's" to the
#    same key, so the gate must not let a DIFFERENT band adopt the library
#    artist. "The Last" is a real band in this library.
# ---------------------------------------------------------------------------
{
    my $out = attach([ row('The Last', 'Qobuz') ]);
    ok(scalar($out->[0]{name} eq 'The Last'), '"The Last" keeps its own name');
    ok(scalar(!grep { $_ eq 'Local' } @{ $out->[0]{sources} })
       || scalar($out->[0]{artist_id} && $out->[0]{artist_id} == 60873),
       '... and never adopts The La\'s (it may only match ITSELF)');
    my $out2 = attach([ row('The Las Vegas Boneheads', 'Qobuz') ]);
    ok(scalar(!grep { $_ eq 'Local' } @{ $out2->[0]{sources} }),
       'an unrelated band with a similar name gains nothing');

    # THE ONE THAT BITES. A service row spelled "The Las" makes the ladder
    # return The Last / The Last Word — a NON-EMPTY, WRONG answer, which is the
    # exact shape of the original bug. Only the _normKey gate stops that being
    # attached. Written after a mutation run proved the assertions above pass
    # happily with the gate deleted (they let the row match ITSELF, so removing
    # the gate changed nothing about them).
    @QUERIES = ();
    my $out3 = attach([ row('The Las', 'Qobuz') ]);
    ok(scalar(@QUERIES > 0), 'a "The Las" row IS probed');
    ok(scalar(!grep { $_ eq 'Local' } @{ $out3->[0]{sources} }),
       'and gains NO Local — the ladder\'s wrong-but-non-empty hits are rejected');
    ok(!defined $out3->[0]{artist_id},
       '... and adopts no artist_id (The Last must never be attached here)');
    ok(scalar($out3->[0]{name} eq 'The Las'), '... and keeps its own name');
}

# ---------------------------------------------------------------------------
# 3. THE SPELLING THAT RESOLVES WINS — not simply the library's.
#
#    0.48.1 adopted the library's spelling blindly and BROKE ARTIST ARTWORK,
#    caught by Simon the same day. Measured on the live image proxy:
#        "The La's" (ASCII, what the row already had) -> 2,317,943 bytes, photo
#        "The La’s" (curly, the library's spelling)   ->     5,071 bytes,
#                                                      the SAME silhouette a
#                                                      nonexistent band returns
#    0.46.5's "library wins" was right only because THERE the library held the
#    cleaner spelling. The artist_id must still come from the library (that is
#    where the albums are) — only the LABEL is kept.
# ---------------------------------------------------------------------------
{
    my $out = attach([ row("The La's", 'Tidal') ]);
    ok(scalar($out->[0]{name} eq "The La's"),
       'a CURLY library spelling does NOT replace the row\'s ASCII one (artwork)');
    ok(scalar($out->[0]{artist_id} == 57545),
       '... but the library artist_id IS attached (the albums live there)');

    # The other direction still works: where the library is the cleaner
    # spelling, it is adopted — 0.46.5's case must not regress.
    my $out2 = attach([ row("The B\x{2010}52s", 'Qobuz') ]);
    ok(scalar($out2->[0]{name} eq 'The B-52s'),
       'a U+2010 row name IS replaced by the library\'s ASCII spelling (0.46.5)');

    # Diacritics are NOT typographic punctuation, so an accented library name
    # is never penalised by the guard above.
    ok(scalar(Plugins::Discography::Sources::_typoMarks("Bj\x{f6}rk") == 0),
       'a diacritic is NOT counted as a typographic mark');
    ok(scalar(Plugins::Discography::Sources::_typoMarks("The La\x{2019}s") == 1
              && Plugins::Discography::Sources::_typoMarks("The B\x{2010}52s") == 1),
       '... while a curly apostrophe and a U+2010 hyphen both are');
    my $out3 = attach([ row("Bj\x{f6}rk", 'Deezer') ]);
    ok(scalar($out3->[0]{artist_id} && $out3->[0]{name} eq "Bj\x{f6}rk"),
       'an accented row attaches and keeps its accents');

    # KNOWN LIMITATION, measured here rather than assumed: the identity gate is
    # `_normKey`, which utf8::ENCODEs before folding, and _norm's diacritic
    # stripping is gated on utf8::is_utf8 — so it is skipped for encoded input
    # and "Bjork" does NOT key the same as "Björk". A service row carrying the
    # stripped spelling therefore will NOT attach to an accented library artist.
    # PRE-EXISTING and shared with the search Local leg and localAlbums, so it
    # is deliberately NOT changed here; recorded so nobody re-derives it.
    ok(scalar(Plugins::Discography::Sources::_normKey('Bjork')
              ne Plugins::Discography::Sources::_normKey("Bj\x{f6}rk")),
       'KNOWN: _normKey does not fold accents (encode-before-fold) - not fixed here');
}

# ---------------------------------------------------------------------------
# 3b. DUPLICATE CONTRIBUTORS. Simon's library holds BOTH apostrophe spellings
#     as separate artists and only ONE has the albums (58667 has none, 57545
#     has five) — attaching the empty one would open a blank page.
# ---------------------------------------------------------------------------
{
    my $out = attach([ row("The La's", 'Tidal') ]);
    ok(scalar($out->[0]{artist_id} == 57545),
       'the contributor WITH albums is chosen over the empty duplicate');
}

# ---------------------------------------------------------------------------
# 4. IT CANNOT DISTURB A ROW THAT ALREADY WORKS.
# ---------------------------------------------------------------------------
{
    @QUERIES = ();
    my $in  = [ { name => 'The B-52s', sources => ['Local','Qobuz'], artist_id => 62125 } ];
    my $out = attach($in);
    ok(scalar(@QUERIES == 0), 'a row that already has an artist_id costs NO library query');
    ok(scalar($out->[0]{name} eq 'The B-52s'), '... and is returned untouched');

    # The cached-row rule: the input row must never be decorated in place.
    my $shared = row("The La's", 'Tidal');
    my $res    = attach([ $shared ]);
    ok(scalar(!grep { $_ eq 'Local' } @{ $shared->{sources} }),
       'the INPUT row is not mutated (search cache entries stay clean)');
    ok(scalar(grep { $_ eq 'Local' } @{ $res->[0]{sources} }),
       '... while the returned copy carries Local');
}

# ---------------------------------------------------------------------------
# 5. COST IS BOUNDED. One local query per unattached row, capped.
# ---------------------------------------------------------------------------
{
    @QUERIES = ();
    my @many = map { row("Nobody Xyzzy $_", 'Qobuz') } 1 .. 25;
    attach(\@many);
    # The cap is on ROWS. Each row costs up to 3 CLI queries, because the
    # shared ladder runs its spelling try plus PUNCT_PROBE_MAX term probes —
    # worth knowing before raising LIB_PROBE_MAX.
    my %rowsProbed = map { $_ => 1 } grep { /^Nobody Xyzzy \d+$/ } @QUERIES;
    ok(scalar(keys %rowsProbed) <= 10,
       'at most LIB_PROBE_MAX ROWS probed per search (' . scalar(keys %rowsProbed) . ')');
    ok(scalar(@QUERIES) <= 10 * 2,
       '... at 1-2 CLI queries each: the spelling ladder, NO term probes ('
       . scalar(@QUERIES) . ')');
    ok(scalar(@QUERIES > 0), '... but it does probe');
}

# ---------------------------------------------------------------------------
# 6. DEFENSIVE.
# ---------------------------------------------------------------------------
{
    my $out = attach([]);
    ok(scalar(ref $out eq 'ARRAY' && @$out == 0), 'an empty row list is safe');
    $out = attach([ { sources => ['Qobuz'] } ]);
    ok(scalar(@$out == 1), 'a row with no name is passed through, not dropped');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
