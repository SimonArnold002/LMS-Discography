#!/usr/bin/env perl
#
# REGRESSION TEST: "Also on streaming" merges ONE album's copies across services.
#
# The section's cross-service dedupe (Browse::_buildList, field 2026-07-19 "Bajo
# Tu Voz . Tidal" above "Bajo Tu Voz . Qobuz") is documented as keyed on
# TITLE + YEAR, but was keyed on each service's rendered `name`. Only Tidal and
# Deezer put the bare title there. Read in the plugins' own source (2026-09-25):
#   Qobuz  _albumItem     name = "Artist - Title" (+ " (Hi-Res)", "\n(year)", " [E]", "* ")
#   TIDAL  _renderAlbum   name = title, and it APPENDS " [E]" to the album's own
#                         {title} first, so _candTitle carries it too
#   Deezer _renderAlbum   name = title (Discography passes addArtistToTitle 0)
#   Spotty _albumItem     name = "Title BY Artists" (" (YYYY)" inserted with showYear)
# so a Qobuz or Spotify copy never merged with anything.
#
# The fix keys the CROSS-SERVICE merge on _norm(_candTitle) + year and changes
# nothing else. PART A must pass before AND after (what was merged stays merged,
# what was apart within one service stays apart). PART B failed before the fix.
#
# Row fixtures are built with the renderers' exact name shapes above; _norm and
# _artistMatch are the REAL ones (t_view.pl stubs _norm, so it cannot see this).
#
# Standalone:  perl tools/t_extras.pl
#
use strict;
use warnings;
use FindBin;

our (%PREF, $POOL, @SOURCES);

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers Slim::Utils::Strings
                  Slim::Control::Request Slim::Schema Slim::Web::HTTP
                  Slim::Networking::SimpleAsyncHTTP Slim::Utils::Misc
                  Plugins::Discography::Plugin Plugins::Discography::API)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Cache' };
    *{'Slim::Utils::Strings::cstring'}   = sub { $_[1] };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');

    my $A = 'Plugins::Discography::API';
    *{"${A}::caaImage"}            = sub { 'caa' };
    *{"${A}::peekOfficial"}        = sub { undef };
    *{"${A}::peekReleaseMap"}      = sub { {} };
    *{"${A}::peekLocalReleaseMap"} = sub { {} };
    *{"${A}::peekEditions"}        = sub { {} };
    *{"${A}::clearArtistEmpty"}    = sub { 0 };
    *{"${A}::markArtistEmpty"}     = sub { };
    *{"${A}::peekBands"}           = sub { undef };
    *{"${A}::peekCollabs"}         = sub { undef };
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}
package T::Prefs; our $AUTOLOAD; sub get { $main::PREF{ $_[1] } } sub AUTOLOAD { return } sub DESTROY {}
package T::Cache; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;   # REAL _norm / _artistMatch
require Plugins::Discography::Browse;
my $B = 'Plugins::Discography::Browse';
my $S = 'Plugins::Discography::Sources';

{
    no strict 'refs'; no warnings 'redefine';
    *{"${S}::orderedSources"}  = sub { map { { name => $_ } } @main::SOURCES };
    *{"${S}::localAlbums"}     = sub { [] };
    *{"${S}::localTracks"}     = sub { [] };
    *{"${S}::peekPool"}        = sub { $main::POOL };
    *{"${S}::claimedLocalIds"} = sub { {} };
    *{"${S}::peekMatches"}     = sub { { sections => [], resolved => 1 } };
}

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

%PREF = (show_types => 'ALBUMS,EPS,SINGLES,COMPILATIONS,LIVE,OTHER', show_bio => 0,
         show_library_extras => 0, show_streaming_extras => 1, hide_unmatched => 0);

# One copy, shaped as each service's renderer + _decorate shape it.
my $ART = 'Radiohead';
sub copy {
    my ($svc, $title, $year, $id, %o) = @_;
    my $artist = $o{artist} // $ART;
    my $name = $svc eq 'Qobuz'   ? "$artist - $title"
             : $svc eq 'Spotify' ? "$title BY $artist"
             :                     $title;                 # Tidal, Deezer
    $name = $o{name} if exists $o{name};
    my %c = (name => $name, line1 => $title, line2 => $artist, type => 'playlist',
             _svc => $svc, _albumid => $id, _candArtist => $artist, _year => $year,
             favorites_url => lc($svc) . "://album:$id");
    $c{_candTitle} = exists $o{candTitle} ? $o{candTitle} : $title;
    delete $c{_candTitle} unless defined $c{_candTitle};
    return \%c;
}

# The page: ONE release group that claims nothing (an empty discography returns
# "no results" before the extras section is built), so every pool copy is unclaimed.
my $RG = { mbid => '00000001-0000-0000-0000-000000000000', title => 'Zzz Unrelated Title',
           type => 'Album', secondary => [], date => '1990-01-01' };
my $opts = { artist_id => 1, artist => $ART, features => 'hi', sort => 'newest' };
sub extras {
    my ($pool, @srcs) = @_;
    local @SOURCES = @srcs;
    local $POOL = { bySvc => $pool };
    my $items = $B->can('_buildList')->(undef, { %$opts }, 'artist-mbid', [ { %$RG } ], '', []);
    return [ grep { ($_->{id} // '') =~ /^str:/ } @$items ];
}
sub rowFor { my ($rows, $id) = @_; (grep { $_->{id} eq $id } @$rows)[0] }
sub svcsOf { my ($r) = @_; $r ? (split(/ \x{00B7} /, $r->{line2}))[-1] : '' }

my @ALL = qw(Qobuz Tidal Deezer Spotify);

# ------------------------------------------------------------------ PART A
print "# PART A - must hold before AND after\n";

# A1. Tidal + Deezer, same title/year: one row naming both (the 2026-07-19 case).
my $r = extras({ Tidal => [ copy('Tidal', 'Pablo Honey', 1993, 't1') ],
                 Deezer => [ copy('Deezer', 'Pablo Honey', 1993, 'd1') ] }, @ALL);
ok(scalar(@$r == 1 && $r->[0]{id} eq 'str:Tidal:t1' && svcsOf($r->[0]) eq 'Tidal/Deezer'),
   'A1: Tidal + Deezer copies merge into one row, the preferred service plays');

# A2. Same title, DIFFERENT year: two records, two rows (all services).
$r = extras({ Qobuz  => [ copy('Qobuz', 'Live', 2001, 'q1') ],
              Tidal  => [ copy('Tidal', 'Live', 2008, 't1') ] }, @ALL);
ok(scalar(@$r == 2), 'A2: same title, different year stays two rows');

# A3. Different titles never merge.
$r = extras({ Qobuz => [ copy('Qobuz', 'Kid A', 2000, 'q1') ],
              Spotify => [ copy('Spotify', 'Amnesiac', 2000, 's1') ] }, @ALL);
ok(scalar(@$r == 2), 'A3: different titles stay apart');

# A4. WITHIN one service, two copies the old key kept apart stay apart: Qobuz,
# same title and year, different credited artist (name differs).
$r = extras({ Qobuz => [ copy('Qobuz', 'Reckoner', 2008, 'q1'),
                         copy('Qobuz', 'Reckoner', 2008, 'q2', artist => 'Radiohead & Friends') ] }, @ALL);
ok(scalar(@$r == 2), 'A4: two Qobuz copies with different names stay two rows');
$r = extras({ Spotify => [ copy('Spotify', 'Reckoner', 2008, 's1'),
                           copy('Spotify', 'Reckoner', 2008, 's2', artist => 'Radiohead, Friends') ] }, @ALL);
ok(scalar(@$r == 2), 'A4: two Spotify copies with different names stay two rows');

# A5. Within one service, copies the old key merged stay merged (Qobuz explicit
# + clean: " [E]" is bracketed, _norm strips it; same for "\n(2000)").
$r = extras({ Qobuz => [ copy('Qobuz', 'Kid A', 2000, 'q1', name => "Radiohead - Kid A\n(2000) [E]"),
                         copy('Qobuz', 'Kid A', 2000, 'q2', name => "Radiohead - Kid A\n(2000)") ] }, @ALL);
ok(scalar(@$r == 1 && $r->[0]{id} eq 'str:Qobuz:q1' && svcsOf($r->[0]) eq 'Qobuz'),
   'A5: Qobuz explicit + clean copies still one row, service named once');

# A6. A copy with no _candTitle falls back to its name, as before.
$r = extras({ Tidal  => [ copy('Tidal',  'OK Computer', 1997, 't1', candTitle => undef) ],
              Deezer => [ copy('Deezer', 'OK Computer', 1997, 'd1', candTitle => undef) ] }, @ALL);
ok(scalar(@$r == 1 && svcsOf($r->[0]) eq 'Tidal/Deezer'), 'A6: no _candTitle -> keyed on name, Tidal + Deezer still merge');
# ...and two DIFFERENT albums with no _candTitle, same year, different services,
# must not collide on an empty title key.
$r = extras({ Tidal  => [ copy('Tidal',  'Kid A',    2000, 't1', candTitle => undef) ],
              Deezer => [ copy('Deezer', 'Amnesiac', 2000, 'd1', candTitle => undef) ] }, @ALL);
ok(scalar(@$r == 2), 'A6: two different titleless albums, same year, stay two rows');

# A7. Row ids, labels and first-wins order are unchanged by the merge.
$r = extras({ Tidal  => [ copy('Tidal', 'The Bends', 1995, 't1'), copy('Tidal', 'Hail to the Thief', 2003, 't2') ],
              Deezer => [ copy('Deezer', 'The Bends', 1995, 'd1') ] }, @ALL);
ok(scalar(@$r == 2 && rowFor($r, 'str:Tidal:t1') && rowFor($r, 'str:Tidal:t2') && !rowFor($r, 'str:Deezer:d1')),
   'A7: survivor ids are the preferred copies; merged-away ids do not render');
ok(scalar(rowFor($r, 'str:Tidal:t1')->{name} eq 'The Bends'), "A7: the row keeps its service's own label");

# A8. Priority order decides the survivor, whatever the pool order.
$r = extras({ Deezer => [ copy('Deezer', 'In Rainbows', 2007, 'd1') ],
              Tidal  => [ copy('Tidal',  'In Rainbows', 2007, 't1') ] }, qw(Deezer Tidal));
ok(scalar(@$r == 1 && $r->[0]{id} eq 'str:Deezer:d1' && svcsOf($r->[0]) eq 'Deezer/Tidal'),
   'A8: the higher-priority service supplies the row');

# ------------------------------------------------------------------ PART B
print "# PART B - the cross-service merge (failed before the fix)\n";

# B1. All four services carry the album: ONE row, all four named, Qobuz plays.
$r = extras({ Qobuz   => [ copy('Qobuz',   'Pablo Honey', 1993, 'q1') ],
              Tidal   => [ copy('Tidal',   'Pablo Honey', 1993, 't1') ],
              Deezer  => [ copy('Deezer',  'Pablo Honey', 1993, 'd1') ],
              Spotify => [ copy('Spotify', 'Pablo Honey', 1993, 's1') ] }, @ALL);
ok(scalar(@$r == 1), 'B1: one album on all four services is ONE row');
ok(scalar(@$r && $r->[0]{id} eq 'str:Qobuz:q1'), 'B1: the preferred service (Qobuz) supplies it');
ok(scalar(@$r && svcsOf($r->[0]) eq 'Qobuz/Tidal/Deezer/Spotify'), 'B1: the row names all four services');

# B2. Spotify + Tidal (the review's case).
$r = extras({ Tidal   => [ copy('Tidal',   'Amnesiac', 2001, 't1') ],
              Spotify => [ copy('Spotify', 'Amnesiac', 2001, 's1') ] }, @ALL);
ok(scalar(@$r == 1 && svcsOf($r->[0]) eq 'Tidal/Spotify'), 'B2: Tidal + Spotify copies merge');

# B3. Qobuz with its decorations vs Tidal's mutated explicit title.
$r = extras({ Qobuz => [ copy('Qobuz', 'Kid A', 2000, 'q1', name => "* Radiohead - Kid A (Hi-Res)\n(2000) [E]") ],
              Tidal => [ copy('Tidal', 'Kid A [E]', 2000, 't1') ] }, @ALL);
ok(scalar(@$r == 1 && svcsOf($r->[0]) eq 'Qobuz/Tidal'), 'B3: decorated Qobuz name + Tidal " [E]" title merge');

# B4. Spotify with LMS showYear on: "Title (YYYY) BY Artists" (Spotty OPML.pm).
$r = extras({ Deezer  => [ copy('Deezer',  'OK Computer', 1997, 'd1') ],
              Spotify => [ copy('Spotify', 'OK Computer', 1997, 's1', name => 'OK Computer (1997) BY Radiohead') ] }, @ALL);
ok(scalar(@$r == 1 && svcsOf($r->[0]) eq 'Deezer/Spotify'), 'B4: Spotify with showYear merges with Deezer');

# B5. A same-service twin kept apart (A4) still gets the OTHER service's copy
# once, on the first row, and the second twin stays its own row.
$r = extras({ Qobuz => [ copy('Qobuz', 'Reckoner', 2008, 'q1'),
                         copy('Qobuz', 'Reckoner', 2008, 'q2', artist => 'Radiohead & Friends') ],
              Tidal => [ copy('Tidal', 'Reckoner', 2008, 't1') ] }, @ALL);
ok(scalar(@$r == 2), 'B5: Qobuz twins + one Tidal copy -> two rows');
ok(scalar(svcsOf(rowFor($r, 'str:Qobuz:q1')) eq 'Qobuz/Tidal' && svcsOf(rowFor($r, 'str:Qobuz:q2')) eq 'Qobuz'),
   'B5: the Tidal copy joins the first twin only');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
