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
our %CONTRIB;    # lc MusicBrainz artist mbid -> library contributors carrying it
our %OWNS;       # artist_id -> { albums => [...], titles => [...] } it PERFORMS on

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
    # Stubbed LMS: records what was asked, answers from %LIBRARY. A request
    # with no `search:` (the albums query the mbid path goes straight to) is
    # answered empty -- what matters there is that no SEARCH was needed.
    *{'Slim::Control::Request::executeRequest'} = sub {
        my (undef, $args) = @_;
        my ($search) = grep { /^search:/ } @$args;
        unless (defined $search) {
            # The id-keyed albums/titles queries answer from %OWNS (empty for
            # an unlisted id, as before).
            my ($aid) = map { /^artist_id:(\d+)$/ ? $1 : () } @$args;
            my $kind  = ($args->[0] // '') eq 'titles' ? 'titles' : 'albums';
            return bless { rows => ($aid && $main::OWNS{$aid} ? $main::OWNS{$aid}{$kind} || [] : []) }, 'T::Req';
        }
        $search =~ s/^search://;
        push @QUERIES, $search;
        return bless { rows => $LIBRARY{$search} || [] }, 'T::Req';
    };
    # The library's own MusicBrainz artist tag, the column getArtistMbid
    # already trusts ahead of any MB search (Contributor.musicbrainz_id).
    *{'Slim::Schema::rs'} = sub { bless {}, 'T::RS' };
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
# Contributor resultset: the search is `musicbrainz_id => { -in => [...] }`,
# and the column is compared EXACTLY -- so the stub matches exactly too, and
# the code's own case ladder is what has to do the work.
package T::RS;
sub search {
    my (undef, $where) = @_;
    my @try = @{ $where->{musicbrainz_id}{-in} || [] };
    my @hit = map  { @{ $main::CONTRIB{$_} || [] } } @try;
    return bless { rows => \@hit }, 'T::RS';
}
sub all { @{ $_[0]{rows} || [] } }
package T::Contrib;
sub new  { my ($c, %a) = @_; bless {%a}, $c }
sub id   { $_[0]{id} }
sub name { $_[0]{name} }

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

# ...AND THE LIBRARY MATCHES CHARACTERS, NEVER OCTETS (0.51.2, measured live
# against Simon's server: `search:Björk` as characters -> 1 hit, the identical
# string as UTF-8 octets -> 0, same for Sigur Rós / Röyksopp / ꉺლ). LMS's query
# ends up in a DBI handle with unicode on, so it encodes what it is given and
# octets are encoded twice. %LIBRARY is therefore keyed by the CHARACTER form:
# a fixture keyed by octets would assert the very bug this file now guards.
sub chars { my $s = shift; utf8::decode($s); $s }
my $BJORK_C = chars($BJORK);

# ---------------------------------------------------------------------------
# 1. THE FIELD CASE: a single-word accented name. LMS holds "Björk" and its
#    index folds accents, so the ASCII-folded spelling is the step that works.
#    The term probe cannot help -- there is only one term, and it has the mark.
# ---------------------------------------------------------------------------
@QUERIES = (); %LIBRARY = ('Bjork' => [{ id => 7, artist => $BJORK }]);
my $r = $rows->($BJORK);
ok(scalar(@$r) == 1 && $r->[0]{artist_id} == 7, 'Björk is found via the ASCII-folded spelling');
ok($QUERIES[0] eq $BJORK_C, '... after trying the exact spelling FIRST');
ok(scalar(utf8::is_utf8($QUERIES[0])),
   '... handed to LMS as CHARACTERS - octets match no non-ASCII name at all');
ok((grep { $_ eq 'Bjork' } @QUERIES), '... and the folded spelling was actually tried');

# ---------------------------------------------------------------------------
# 2. The exact spelling must WIN when it works -- no wasted queries, and no
#    chance of a folded spelling adopting a different artist.
# ---------------------------------------------------------------------------
@QUERIES = (); %LIBRARY = ($BJORK_C => [{ id => 7, artist => $BJORK }]);
$r = $rows->($BJORK);
ok(scalar(@$r) == 1, 'an exact hit is returned');
ok(scalar(@QUERIES) == 1, '... on the FIRST query, with no fallback work');
# The SAME call with the name already decoded must behave identically: both
# shapes reach the plugin (a CLI param vs a name out of from_json).
@QUERIES = ();
$r = $rows->($BJORK_C);
ok(scalar(@$r) == 1 && scalar(@QUERIES) == 1,
   'a name that arrives ALREADY decoded takes the identical single query');

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
#
#    0.51.2 — AND THE PROBE STILL FOUND NOTHING IN THE FIELD, because the token
#    was handed to LMS as OCTETS (see the %LIBRARY note at the top). This is the
#    same artist, still unresolved eight days later: the fix above was correct
#    and unreachable. The library key here is the CHARACTER form, so this case
#    now asserts BOTH halves — the right token, in the shape that can match.
# ---------------------------------------------------------------------------
my $TOK   = "\xea\x89\xba\xe1\x83\x9a";                 # ꉺლ  (U+A27A U+10DA)
my $ZALGO = "\xe2\xa3\x8e" . $TOK . " )( " . $TOK;      # ⣎ꉺლ )( ꉺლ  (braille + token)
my $TOK_C = chars($TOK);
@QUERIES = (); %LIBRARY = ($TOK_C => [{ id => 88, artist => $ZALGO }]);
$r = $rows->($ZALGO);
ok(scalar(@$r) == 1 && $r->[0]{artist_id} == 88, 'a short non-ASCII token is probed and locates the artist');
ok(scalar(grep { $_ eq $TOK_C } @QUERIES), '... the 2-char token was actually tried');
ok(scalar(grep { utf8::is_utf8($_) } @QUERIES) == scalar(@QUERIES),
   '... and EVERY query for this name was characters, not octets');
ok($QUERIES[0] eq chars($ZALGO), '... after the exact spelling was tried FIRST');
# A short ASCII token must STILL be skipped -- the floor is only lifted for
# non-ASCII, so this proves the change is surgical, not a blanket lowering. Both
# tokens of "Xy Zq" are 2-char ASCII, so no single-token probe may ever run.
@QUERIES = (); %LIBRARY = ();
$rows->('Xy Zq');
ok(!(grep { $_ eq 'Xy' || $_ eq 'Zq' } @QUERIES), 'a short ASCII token is NOT admitted as a probe term');

# ---------------------------------------------------------------------------
# 9. IDENTITY BEFORE SPELLING (0.51.3). Everything above is a SPELLING ladder,
#    and for this artist there is no spelling that works: his 2-char token is
#    the only handle LMS indexes, and 0.51.2 was the second fix aimed at it.
#    His library DOES carry the MusicBrainz artist tag (verified live:
#    2d9745dd-5dc6-4145-9453-fec582cfa9b8), so ask the identity question first.
#
#    RED against 0.51.2, which had no mbid parameter at all.
# ---------------------------------------------------------------------------
my $MB = '2d9745dd-5dc6-4145-9453-fec582cfa9b8';
%CONTRIB = ($MB => [ T::Contrib->new(id => 88810, name => $ZALGO) ]);

my $ids = [ Plugins::Discography::Sources::localArtistIdsByMbid($MB) ];
ok(scalar(@$ids) == 1 && $ids->[0] == 88810, 'the library artist is found by MusicBrainz tag');
ok(scalar(@{ Plugins::Discography::Sources::localArtistsByMbid(uc $MB) }) == 1,
   '... whatever case the tagger wrote it in');
ok($ids->[0] == Plugins::Discography::Sources::localArtistsByMbid($MB)->[0]{artist_id},
   '... and the id/rows forms agree');

# A DUPLICATE CONTRIBUTOR is a real artefact in this library (two "The La's",
# one holding the albums), so every tagged contributor counts -- returning the
# first would reintroduce the empty-artist trap 0.48.2 fixed for the name path.
%CONTRIB = ($MB => [ T::Contrib->new(id => 1, name => 'A'),
                     T::Contrib->new(id => 2, name => 'A') ]);
ok(scalar(() = Plugins::Discography::Sources::localArtistIdsByMbid($MB)) == 2,
   'ALL contributors carrying the tag are returned, not just the first');

# A malformed / absent mbid must never reach the database.
%CONTRIB = ();
ok(scalar(() = Plugins::Discography::Sources::localArtistIdsByMbid('not-an-mbid')) == 0,
   'a malformed mbid resolves nothing');
ok(scalar(() = Plugins::Discography::Sources::localArtistIdsByMbid(undef)) == 0,
   'an absent mbid resolves nothing');

# localAlbums: the tag is consulted BEFORE the name ladder, so a name nothing
# can spell costs no search at all.
%CONTRIB = ($MB => [ T::Contrib->new(id => 88810, name => $ZALGO) ]);
@QUERIES = (); %LIBRARY = ();
Plugins::Discography::Sources->localAlbums(undef, $ZALGO, $MB);
ok(scalar(@QUERIES) == 0, 'localAlbums resolves by tag with NO name search');

# ...and an UNTAGGED library still falls through to the ladder unchanged --
# the whole point is that nothing existing behaves differently.
%CONTRIB = ();
@QUERIES = (); %LIBRARY = ('Bjork' => [{ id => 7, artist => $BJORK }]);
Plugins::Discography::Sources->localAlbums(undef, $BJORK, $MB);
ok(scalar(grep { $_ eq 'Bjork' } @QUERIES) == 1,
   'an untagged library falls through to the name ladder exactly as before');

# An explicit artist_id is the user pointing at a contributor and still wins.
%CONTRIB = ($MB => [ T::Contrib->new(id => 88810, name => $ZALGO) ]);
@QUERIES = ();
Plugins::Discography::Sources->localAlbums(4242, $BJORK, $MB);
ok(scalar(@QUERIES) == 0, 'an explicit artist_id outranks the tag (and the name)');

# ---------------------------------------------------------------------------
# 10. AN EMPTY EXPLICIT ID FALLS BACK (field, The B-52's, 2026-09-19). LMS's own
#     search lists "The B-52's" (137553), a contributor that exists ONLY as the
#     COMPOSER of one track; the band's albums sit under "The B-52s" (137542).
#     Tapping it opened a page where nothing read Local. An id that performs on
#     no album cannot be what the user meant, so the page builders opt in to a
#     fallback: the MB tag first (exact), then the name, never the name on a
#     same-name page ('mbid' mode), and never back to the empty id itself.
# ---------------------------------------------------------------------------
{
    my $MB52  = '127f591a-7e27-4435-92db-0780f219f3a1';
    my $DEBUT = { id => 45730, album => "The B\x{2010}52s", year => 1979, artist => 'The B-52s' };
    # A Various Artists compilation track: the only kind track-linking uses.
    my $TRACK = { id => 678355, title => 'Rock Lobster', album => 'Sounds of the Seventies',
                  compilation => '1', albumartist_ids => '133736', artist_ids => '137542' };
    # LMS's `titles` IGNORES role_id once any tag is asked for (measured live,
    # 2026-09-19: role_id BAND / COMPOSER / 4 / none all return this row). So
    # the composer-only contributor's query answers with the ONE track it wrote,
    # and the role gate has to be applied to the per-role ids (`tags:S`).
    my $WROTE = { id => 678343, title => 'Future Generation', album => 'Planet Claire',
                  albumartist_ids => '137542', trackartist_ids => '137542',
                  composer_ids => '137553' };
    local %OWNS = (137542 => { albums => [ $DEBUT ], titles => [ $TRACK ] },
                   137553 => { albums => [],         titles => [ $WROTE ] });
    my $ids = sub { join ',', sort map { $_->{_albumid} } @{ $_[0] || [] } };
    my $LA  = sub { Plugins::Discography::Sources->localAlbums(@_) };
    my $LT  = sub { Plugins::Discography::Sources->localTracks(@_) };
    my $both = [ { id => 137553, artist => "The B-52's" }, { id => 137542, artist => 'The B-52s' } ];

    # By the library's MusicBrainz tag.
    local %CONTRIB = ($MB52 => [ T::Contrib->new(id => 137542, name => 'The B-52s') ]);
    %LIBRARY = ();
    ok($ids->($LA->(137553, "The B-52's", $MB52, { fallback => 'name' })) eq '45730',
       'an explicit id that performs on nothing falls back to the band by MB tag');

    # By name, when the library carries no tag. The empty id comes FIRST in the
    # search result, so the fallback must skip it or it just picks it again.
    %CONTRIB = (); %LIBRARY = ("The B-52's" => $both);
    ok($ids->($LA->(137553, "The B-52's", $MB52, { fallback => 'name' })) eq '45730',
       '... and by NAME in an untagged library, skipping the empty id itself');

    # A SAME-NAME page ('mbid' mode) never borrows another act by name.
    @QUERIES = ();
    ok(!@{ $LA->(137553, "The B-52's", $MB52, { fallback => 'mbid' }) },
       'on a same-name page the name fallback is OFF (no borrowed catalogue)');
    ok(!@QUERIES, '... and no name search is even made');

    # Controls: callers that do not opt in, and an id that owns albums.
    ok(!@{ $LA->(137553, "The B-52's", $MB52) },
       'without the opt-in an explicit id still outranks everything (other callers unchanged)');
    @QUERIES = ();
    ok($ids->($LA->(137542, 'The B-52s', $MB52, { fallback => 'name' })) eq '45730'
       && !@QUERIES, 'an id that OWNS albums is used as-is, with no fallback lookup');

    # The linked singles come back with the albums.
    my $t = $LT->(137553, "The B-52's", { fallback => 'name', mbid => $MB52 });
    ok(scalar(@{ $t || [] }) == 1 && $t->[0]{_trackid} == 678355,
       'localTracks falls back the same way (the linked singles come back too)');
    ok(!@{ $LT->(137553, "The B-52's") },
       'a track the id only WROTE is not an owned performance (the role gate holds)');

    # The role gate itself, for any artist: a covers track he only wrote must
    # not enter the track-link pool, or a single tile links to someone else's
    # recording. The band's own track stays (control).
    local $OWNS{137542}{titles} = [ $TRACK,
        { id => 1, title => 'Cover Of Theirs', album => 'Some VA Comp', compilation => '1',
          albumartist_ids => '133736', artist_ids => '999', composer_ids => '137542' } ];
    my $pool = $LT->(137542, 'The B-52s');
    ok(scalar(@$pool) == 1 && $pool->[0]{_trackid} == 678355,
       'a track the artist only COMPOSED stays out of the pool; his own recording stays in');
    %LIBRARY = ();
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
