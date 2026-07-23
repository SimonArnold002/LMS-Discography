#!/usr/bin/env perl
#
# REGRESSION TEST — a COLLABORATION resolves to the user's own copy, whichever
# way MusicBrainz and the user's tags happen to model it.
#
# FIELD (Simon, 2026-07-22): *"can't find my album of Robert Plant & Alison
# Krauss, I see Qobuz only."* Measured on the live server:
#
#     album 19127 'Raising Sand'   artist (display string) -> "Robert Plant"
#     artist_id 56743 Robert Plant   -> 19127 Raising Sand
#     artist_id 56744 Alison Krauss  -> 19127 Raising Sand
#
# I first read that display string as LMS collapsing a multi-value ALBUMARTIST
# and said so. **Simon corrected me and he was right**: *"it lives under both
# artists, LMS will use both or more artists when it's separated by ; that is
# correct metadata tagging convention."* Only the `albums` query's single
# DISPLAY string collapses; the contributor JOIN carries both. What his library
# has no contributor for is the thing MusicBrainz models as a THIRD artist —
# "Robert Plant & Alison Krauss", mbid 38eb4af8 — so the duo's page asked for a
# name nobody holds and found nothing.
#
# THEN THE WIDER POINT, also his: *"some users might tag it as Robert Plant &
# Alison Krauss, same as they might for Panda Bear and Sonic Boom or any that
# are conjoined in MB. MB isn't itself consistent with doing this, some are new
# artists entirely."* So there are TWO independent inconsistencies and the
# matrix has four cells, of which only the diagonal worked:
#
#                      | library: separate contributors | library: one joint
#   -------------------+--------------------------------+---------------------
#   MB HAS a joint     | duo page finds NOTHING  <- the | works (name matches)
#   artist             | field report                   |
#   -------------------+--------------------------------+---------------------
#   MB has NO joint    | works (0.47.0 splits to the    | album INVISIBLE: the
#   artist             | head act, who IS a contributor)| head has no
#                      |                                | contributor at all
#
# ONE symmetric rule closes both corners — treat a joint name as the SET of its
# parts, on whichever side it appears. Verified live that MusicBrainz really is
# inconsistent here, which is why neither side can be assumed:
#     artist:"Robert Plant & Alison Krauss" -> count=1  (a real Group)
#     artist:"Nick Cave & Warren Ellis"     -> count=0
#     artist:"Panda Bear & Sonic Boom"      -> count=0
#
# Standalone -- no LMS install needed:  perl tools/t_joint.pl
#
use strict;
use warnings;
use FindBin;

our %CONTRIB;    # `artists search:` string -> [ { id, artist } ]
our %ALBUMS;     # artist_id               -> [ { id, album, year } ]
our @ALBUMQ;     # every artist_id an `albums` query was run for, in order

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
    # Stubbed LMS answering BOTH query shapes this path uses: the contributor
    # search and the per-contributor album list.
    *{'Slim::Control::Request::executeRequest'} = sub {
        my (undef, $args) = @_;
        if (($args->[0] // '') eq 'artists') {
            my ($s) = map { my $x = $_; $x =~ s/^search://; $x }
                      grep { /^search:/ } @$args;
            return bless { artists_loop => $CONTRIB{ $s // '' } || [] }, 'T::Req';
        }
        my ($id) = map { my $x = $_; $x =~ s/^artist_id://; $x }
                   grep { /^artist_id:/ } @$args;
        push @ALBUMQ, $id;
        return bless { albums_loop => $ALBUMS{ $id // '' } || [] }, 'T::Req';
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
package T::Req;   sub getResult { return $_[0]->{ $_[1] } }

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

sub titles { join '|', map { $_->{_candTitle} // '?' } @{ $_[0] } }
sub reset_lib { %CONTRIB = (); %ALBUMS = (); @ALBUMQ = () }

# ---------------------------------------------------------------------------
# 1. THE FIELD CASE — MB has the duo, the library has the two members.
#    Simon's real ids and album, and his real solo holdings (he owns exactly
#    one album under each name: Raising Sand itself).
# ---------------------------------------------------------------------------
reset_lib();
$CONTRIB{'Robert Plant & Alison Krauss'} = [];       # no such contributor
$CONTRIB{'Robert Plant'}  = [ { id => 56743, artist => 'Robert Plant' } ];
$CONTRIB{'Alison Krauss'} = [ { id => 56744, artist => 'Alison Krauss' } ];
$ALBUMS{56743} = [ { id => 19127, album => 'Raising Sand', year => 2007 } ];
$ALBUMS{56744} = [ { id => 19127, album => 'Raising Sand', year => 2007 } ];

my $out = $S->localAlbums(undef, 'Robert Plant & Alison Krauss');
ok(scalar(@$out) == 1, "the duo's page finds the owned album");
ok(titles($out) eq 'Raising Sand', '... and it is Raising Sand');
ok(($out->[0]{_albumid} // 0) == 19127, '... carrying the real album id, so it plays');

# ---------------------------------------------------------------------------
# 2. THE INTERSECTION IS WHAT MAKES IT SAFE. Give each member a solo record:
#    only the album BOTH hold may appear, or the duo's page would list two
#    solo discographies and "Also in your library" would be nonsense.
# ---------------------------------------------------------------------------
$ALBUMS{56743} = [ { id => 19127, album => 'Raising Sand' },
                   { id => 900,   album => 'Band of Joy' } ];      # Plant solo
$ALBUMS{56744} = [ { id => 19127, album => 'Raising Sand' },
                   { id => 901,   album => 'Forget About It' } ];  # Krauss solo
$out = $S->localAlbums(undef, 'Robert Plant & Alison Krauss');
ok(scalar(@$out) == 1, 'only the album BOTH members hold survives');
ok(titles($out) eq 'Raising Sand', '... solo records on either side are excluded');

# A part the library does not know at all voids the whole thing — a half match
# would let one member's solo catalogue speak for the duo.
reset_lib();
$CONTRIB{'Robert Plant'} = [ { id => 56743, artist => 'Robert Plant' } ];
$ALBUMS{56743} = [ { id => 900, album => 'Band of Joy' } ];
$out = $S->localAlbums(undef, 'Robert Plant & Alison Krauss');
ok(scalar(@$out) == 0, 'one member unknown -> no intersection, nothing claimed');

# ---------------------------------------------------------------------------
# 3. THE MIRRORED CORNER — MB has NO joint artist (Nick Cave & Warren Ellis,
#    count=0), so the resolver lands on the head act; the user tagged the album
#    as ONE joint string, so the head has no contributor of his own. Before
#    this, the owned album was invisible on the only page it could appear on.
# ---------------------------------------------------------------------------
reset_lib();
$CONTRIB{'Nick Cave'} = [ { id => 300, artist => 'Nick Cave & Warren Ellis' } ];
$ALBUMS{300} = [ { id => 500, album => 'CARNAGE', year => 2021 } ];
$out = $S->localAlbums(undef, 'Nick Cave');
ok(scalar(@$out) == 1, 'a JOINT contributor answers for a member browsed alone');
ok(titles($out) eq 'CARNAGE', '... surfacing the owned collaboration');

# The OTHER member reaches it too — the parts are a set, not a head.
$CONTRIB{'Warren Ellis'} = [ { id => 300, artist => 'Nick Cave & Warren Ellis' } ];
$out = $S->localAlbums(undef, 'Warren Ellis');
ok(scalar(@$out) == 1, '... and so does the second-named member');

# NOT gated on a miss, unlike the intersection: a user owning BOTH a plain
# contributor and a joint one must get both albums, or the collaboration
# vanishes from the page it belongs on.
$CONTRIB{'Nick Cave'} = [ { id => 301, artist => 'Nick Cave' },
                          { id => 300, artist => 'Nick Cave & Warren Ellis' } ];
$ALBUMS{301} = [ { id => 501, album => 'Skeleton Tree', year => 2016 } ];
$out = $S->localAlbums(undef, 'Nick Cave');
ok(scalar(@$out) == 2, 'a plain AND a joint contributor both contribute');
ok(scalar(grep { ($_->{_candTitle} // '') eq 'Skeleton Tree' } @$out),
   '... the solo record is still there');
ok(scalar(grep { ($_->{_candTitle} // '') eq 'CARNAGE' } @$out),
   '... and the collaboration with it');

# ---------------------------------------------------------------------------
# 4. THE MATCH IS ON A WHOLE PART, NEVER A SUBSTRING. This is the guard that
#    keeps the rule from behaving like the name-similarity folding rejected in
#    0.44.13 — "Nick Cave" must not adopt "Nick Cavendish & Friends".
# ---------------------------------------------------------------------------
reset_lib();
$CONTRIB{'Nick Cave'} = [ { id => 400, artist => 'Nick Cavendish & Friends' } ];
$ALBUMS{400} = [ { id => 600, album => 'Not His Record' } ];
$out = $S->localAlbums(undef, 'Nick Cave');
ok(scalar(@$out) == 0, 'a joint contributor that merely CONTAINS the name is refused');

# ---------------------------------------------------------------------------
# 5. NOTHING ORDINARY CHANGES. The overwhelmingly common cases must behave
#    exactly as before — one contributor, one query, no joint logic reached.
# ---------------------------------------------------------------------------
reset_lib();
$CONTRIB{'Radiohead'} = [ { id => 700, artist => 'Radiohead' } ];
$ALBUMS{700} = [ { id => 800, album => 'Kid A' }, { id => 801, album => 'Amnesiac' } ];
$out = $S->localAlbums(undef, 'Radiohead');
ok(scalar(@$out) == 2, 'CONTROL: a plain artist is unaffected');
ok(scalar(@ALBUMQ) == 1, '... and costs exactly ONE album query');

@ALBUMQ = ();
$out = $S->localAlbums(700, 'Radiohead');
ok(scalar(@$out) == 2, 'CONTROL: entry by artist_id is unchanged');
ok(scalar(@ALBUMQ) == 1 && $ALBUMQ[0] == 700,
   '... and asks for that contributor alone, with no name lookup');

reset_lib();
ok(scalar(@{ $S->localAlbums(undef, 'Nobody At All') }) == 0,
   'CONTROL: an unknown artist still returns nothing');
ok(scalar(@{ $S->localAlbums(undef, '') }) == 0, 'CONTROL: an empty name is refused');

# ---------------------------------------------------------------------------
# 6. THE SPLITTER IS SHARED WITH THE MUSICBRAINZ SIDE (API::_creditHead
#    delegates to it), so "what counts as a joint credit" has one definition.
# ---------------------------------------------------------------------------
my $parts = \&Plugins::Discography::Sources::_creditParts;
ok(scalar(($parts->('Robert Plant & Alison Krauss'))[0] eq 'Robert Plant'),
   'the splitter yields the members in order');
ok(scalar(() = $parts->('AC/DC')) == 0, 'a slash with no spaces is one name (AC/DC)');
ok(scalar(() = $parts->('Radiohead')) == 0, 'a plain name has no parts');
for my $sep ('and', 'feat.', 'with', '/', '+') {
    ok(scalar(() = $parts->("Alpha $sep Beta")) == 2, "'$sep' separates a credit");
}

# ---------------------------------------------------------------------------
# 7. THE SEARCH ROW gets a Local SOURCE for an owned collaboration (0.48.8).
#    Field (Simon, screenshot): the "Robert Plant & Alison Krauss" search row
#    read just "Qobuz" — no Local — though he owns Raising Sand under both
#    member contributors. attachLibraryArtists' exact probe finds no contributor
#    of the duo's name; the joint intersection does.
# ---------------------------------------------------------------------------
reset_lib();
$CONTRIB{'Robert Plant & Alison Krauss'} = [];
$CONTRIB{'Robert Plant'}  = [ { id => 56743, artist => 'Robert Plant' } ];
$CONTRIB{'Alison Krauss'} = [ { id => 56744, artist => 'Alison Krauss' } ];
$ALBUMS{56743} = [ { id => 19127, album => 'Raising Sand' } ];
$ALBUMS{56744} = [ { id => 19127, album => 'Raising Sand' } ];

my $rows = $S->attachLibraryArtists([
    { name => 'Robert Plant & Alison Krauss', sources => ['Qobuz'] },
]);
ok(scalar(@$rows) == 1, 'the owned collaboration row survives');
ok(scalar(grep { $_ eq 'Local' } @{ $rows->[0]{sources} }),
   '... and gains a Local source (it owns the duo via its members)');
ok(!defined $rows->[0]{artist_id},
   '... but NO artist_id — there is no single contributor to navigate to');

# A collaboration the user does NOT own gets no Local — the badge must be true.
reset_lib();
$CONTRIB{'Simon & Garfunkel'} = [];
$CONTRIB{'Simon'} = [ { id => 10, artist => 'Simon' } ];   # some other Simon
# no Garfunkel contributor -> intersection empty -> not owned
$rows = $S->attachLibraryArtists([
    { name => 'Simon & Garfunkel', sources => ['Qobuz'] },
]);
ok(!scalar(grep { $_ eq 'Local' } @{ $rows->[0]{sources} }),
   'a collaboration the user does NOT own gets no Local source');

# A plain (non-joint) row with no contributor is untouched — no joint probe.
reset_lib();
$rows = $S->attachLibraryArtists([ { name => 'Radiohead', sources => ['Qobuz'] } ]);
ok(!scalar(grep { $_ eq 'Local' } @{ $rows->[0]{sources} }),
   'CONTROL: a plain unowned row gains nothing');

# RANKING: an owned collaboration (Local, no artist_id) still trumps a
# non-owned exact match — the 0.48.8 ownership predicate.
my $ranked = $S->rankArtistHits([
    { name => 'Some Exact', sources => ['Qobuz','Tidal','Deezer'], _exact => 1 },
    { name => 'A & B',      sources => ['Local','Qobuz'],          _exact => 0 },
]);
ok(scalar($ranked->[0]{name} eq 'A & B'),
   'an owned collaboration with no artist_id still ranks first');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
