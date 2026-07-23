#!/usr/bin/env perl
#
# REGRESSION TEST — MusicBrainz release-group ALIASES.
#
# FIELD (2026-07-22, Simon): *"The Kraftwerk issue needs looking at more as it
# resolves cleanly in MB using english as do all their titles."* He was right.
# MusicBrainz titles a release group in its ORIGINAL language and files other
# spellings as ALIASES -- and `getReleaseGroups` never asked for them:
#
#     Radio‐Aktivität      alias -> Radio-Activity
#     Computerwelt         alias -> Computer World
#     Die Mensch·Maschine  alias -> The Man·Machine
#
# So the owned/streaming copy under the English title had no tile to attach to.
# It was never a "translation source" problem; the data was one query parameter
# away (&inc=aliases). Two further cases fall to the same fix, and one is
# unreachable by ANY normalisation rule:
#
#     Prince    "Sign 'O' the Times"  -> MB titles it  Sign “☮︎” the Times
#     Big Star  "Third/Sister Lovers" -> release group `3rd`, alias "Third"
#
# THE ORDER IS THE SAFETY: the canonical title is always tried FIRST, so an
# alias can only ever rescue a MISS -- it can never change a match that already
# works. That property is asserted here, not assumed.
#
# Standalone -- no LMS install needed:  perl tools/t_alias.pl
#
use strict;
use warnings;
use FindBin;

my %CACHE;
my $DATA;
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
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Cache' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Utils::Timers::setTimer'}   = sub { $_[2]->() };
    *{'Slim::Utils::Timers::killTimers'} = sub { 1 };
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { '' };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { $DATA };
    *{'Slim::Networking::SimpleAsyncHTTP::new'} = sub {
        my ($cls, $cb, $errcb, $opt) = @_;
        return bless { cb => $cb, err => $errcb }, 'T::HTTP';
    };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs JSON::XS::VersionOneAndTwo)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
    @{'JSON::XS::VersionOneAndTwo::EXPORT'} = qw(to_json from_json);
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Cache;
sub get { return $CACHE{ $_[1] } }
sub set { $CACHE{ $_[1] } = $_[2]; return 1 }
sub remove { delete $CACHE{ $_[1] }; return 1 }
package T::Prefs;
sub get { return $_[1] eq 'mb_base_url' ? 'http://mirror:5000/ws/2/' : undef }
sub set { 1 } sub init { 1 } sub setChange { 1 }
package T::Resp;
sub new { bless {}, shift } sub content { '{}' } sub error { 'stub error' }
package T::HTTP;
sub get {
    my ($self, $url) = @_;
    push @QUERIES, $url;
    $DATA = main::response_for($url);
    $self->{cb}->(T::Resp->new);
}

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::API;
require Plugins::Discography::Sources;
my $API = 'Plugins::Discography::API';
my $SRC = 'Plugins::Discography::Sources';

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    # STRUCTURAL GUARD (see t_zerorg.pl): a bare =~ / grep / map in ok()'s
    # argument list returns the EMPTY LIST on failure, shifting the test NAME
    # into the condition slot so a FAILING assertion prints as a pass.
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

# ---------------------------------------------------------------------------
# FIXTURE — Kraftwerk's real spine as the mirror returns it, plus the two
# other real alias cases. Note the U+2010 HYPHEN in "Radio‐Aktivität" and the
# U+00B7 MIDDLE DOT in "Die Mensch·Maschine": both are genuine MB data.
# ---------------------------------------------------------------------------
my $KRAFT = '5700dcd4-c139-4f31-aa3e-6382b9af9032';
my %SPINE = (
    $KRAFT => [
        { id => 'rg-radio', title => "Radio\x{2010}Aktivit\x{e4}t", 'first-release-date' => '1975',
          'primary-type' => 'Album',
          aliases => [ { name => 'Radio-Activity' } ] },
        { id => 'rg-compw', title => 'Computerwelt', 'first-release-date' => '1981',
          'primary-type' => 'Album',
          aliases => [ { name => 'Computer World' }, { name => 'Computer World' } ] },
        { id => 'rg-mensch', title => "Die Mensch\x{b7}Maschine", 'first-release-date' => '1978',
          'primary-type' => 'Album',
          aliases => [ { name => "Die Mensch\x{2022}Maschine" }, { name => "The Man\x{b7}Machine" } ] },
        { id => 'rg-auto', title => 'Autobahn', 'first-release-date' => '1974',
          'primary-type' => 'Album' },
        # An alias that merely REPEATS the title must not be stored.
        { id => 'rg-tour', title => 'Tour de France Soundtracks', 'first-release-date' => '2003',
          'primary-type' => 'Album',
          aliases => [ { name => 'Tour de France Soundtracks' } ] },
    ],
);

sub response_for {
    my ($url) = @_;
    my ($mbid) = $url =~ m{release-group\?artist=([^&]+)};
    return { 'release-groups' => [], 'release-group-count' => 0 } unless $mbid;
    my $rgs = $SPINE{$mbid} || [];
    return { 'release-groups' => $rgs, 'release-group-count' => scalar @$rgs };
}

sub spine {
    %CACHE = (); @QUERIES = ();
    my $got;
    $API->getReleaseGroups(mbid => $KRAFT, onDone => sub { $got = shift });
    return $got;
}

# ---------------------------------------------------------------------------
# 1. THE FETCH asks for aliases, and parses them.
# ---------------------------------------------------------------------------
my $rgs = spine();
ok(scalar(@QUERIES == 1), 'the spine still costs exactly ONE request');
ok(scalar($QUERIES[0] =~ /\binc=aliases\b/), '... and that request asks for inc=aliases');

my %byId = map { $_->{mbid} => $_ } @$rgs;
ok(scalar(@{ $byId{'rg-radio'}{aliases} || [] } == 1
          && $byId{'rg-radio'}{aliases}[0] eq 'Radio-Activity'),
   'Radio‐Aktivität carries the English alias');
ok(scalar(@{ $byId{'rg-compw'}{aliases} || [] } == 1),
   'a REPEATED alias is stored once (deduped)');
ok(!exists $byId{'rg-auto'}{aliases},
   'a release group with no aliases stores no aliases key (spine stays small)');
ok(!exists $byId{'rg-tour'}{aliases},
   'an alias identical to the title is dropped (no wasted comparison)');
ok(scalar(@{ $byId{'rg-mensch'}{aliases} || [] } == 2),
   'multiple aliases are all kept');

# The cache key changed with the shape, so a v1 entry cannot be served as v2.
ok(scalar(grep { /^dsc:rg:v2:/ } keys %CACHE), 'the spine caches under the v2 key');

# ---------------------------------------------------------------------------
# 2. MATCHING — the whole point. A streaming/local copy under the ENGLISH
#    title attaches to the GERMAN-titled release group.
# ---------------------------------------------------------------------------
my @SOURCES = ( { name => 'Qobuz', local => 0 }, { name => 'Local', local => 1 } );

sub cand {
    my ($title, $artist, $id) = @_;
    return { name => $title, _candTitle => $title, _candArtist => $artist // 'Kraftwerk',
             _albumid => $id // 'a1', _svc => 'Qobuz' };
}
sub matches {
    my ($rg, $candTitle) = @_;
    my $sec = $SRC->matchesFor(
        { Qobuz => [ cand($candTitle) ] }, 'Kraftwerk', $rg->{title}, undef,
        $rg->{mbid}, {}, undef,
        { sources => \@SOURCES, aliases => $rg->{aliases} });
    return scalar @{ $sec || [] };
}

ok(matches($byId{'rg-radio'}, 'Radio-Activity'),
   'Qobuz "Radio-Activity" MATCHES the release group "Radio‐Aktivität"');
ok(matches($byId{'rg-compw'}, 'Computer World'),
   'Qobuz "Computer World" MATCHES "Computerwelt"');
ok(matches($byId{'rg-mensch'}, 'The Man Machine'),
   'Qobuz "The Man Machine" MATCHES "Die Mensch·Maschine" (via The Man·Machine)');

# The canonical title still works, and an edition suffix still rides the
# existing prefix rule THROUGH an alias.
ok(matches($byId{'rg-auto'}, 'Autobahn'), 'a plain title match still works');
ok(matches($byId{'rg-radio'}, 'Radio-Activity (2009 Remaster)'),
   'an alias match still tolerates an edition suffix');

# ---------------------------------------------------------------------------
# 3. THE INDEX HOLE. peekPool narrows streaming candidates to the buckets
#    sharing a FIRST TOKEN with the release-group title -- and an alias
#    routinely starts with a different word ("computerwelt" vs "computer
#    world"). Without folding the alias keys in, the narrowed subset cannot
#    contain the very candidate the alias exists to reach. This asserts the
#    fix works through the INDEXED path, not just the full scan.
# ---------------------------------------------------------------------------
{
    my $rg = $byId{'rg-compw'};
    my $item = cand('Computer World');
    my $sec = $SRC->matchesFor(
        { Qobuz => [ $item ] }, 'Kraftwerk', $rg->{title}, undef, $rg->{mbid}, {}, undef,
        { sources => \@SOURCES, aliases => $rg->{aliases},
          index => { Qobuz => { computer => [ $item ] } } });
    ok(scalar(@{ $sec || [] }), 'the alias match survives the candidate INDEX narrowing');
}

# ---------------------------------------------------------------------------
# 4. IT CANNOT REGRESS. The canonical title is tried first, and a wrong album
#    is still wrong however many aliases the group carries.
# ---------------------------------------------------------------------------
ok(!matches($byId{'rg-radio'}, 'Trans Europa Express'),
   'an unrelated album is still NOT matched');
ok(!matches($byId{'rg-mensch'}, 'The Man-Machine Recreated'),
   'a remix album with a longer title is still rejected (self-titled/prefix rules hold)');
{
    # Same artist gate as ever: an alias must not smuggle past a wrong artist.
    my $rg  = $byId{'rg-radio'};
    my $sec = $SRC->matchesFor(
        { Qobuz => [ cand('Radio-Activity', 'Some Other Band') ] }, 'Kraftwerk',
        $rg->{title}, undef, $rg->{mbid}, {}, undef,
        { sources => \@SOURCES, aliases => $rg->{aliases} });
    ok(!scalar(@{ $sec || [] }), 'the MANDATORY artist gate still applies to an alias match');
}

# ---------------------------------------------------------------------------
# 5. LIBRARY CLAIMS. An owned copy under the English title must be CLAIMED by
#    the German-titled tile -- otherwise it leaks into "Also in your library"
#    while its own tile sits directly above it.
# ---------------------------------------------------------------------------
{
    my $local = [ { _candTitle => 'Radio-Activity', _candArtist => 'Kraftwerk', _albumid => 42 },
                  { _candTitle => 'Computer World', _candArtist => 'Kraftwerk', _albumid => 43 },
                  { _candTitle => 'Trans Europa Express', _candArtist => 'Kraftwerk', _albumid => 44 } ];
    my $claimed = $SRC->claimedLocalIds($rgs, 'Kraftwerk', $local, {});
    ok($claimed->{42}, 'owned "Radio-Activity" is claimed by "Radio‐Aktivität"');
    ok($claimed->{43}, 'owned "Computer World" is claimed by "Computerwelt"');
    ok(!$claimed->{44}, '... and an album with no release group is still unclaimed');
}

# ---------------------------------------------------------------------------
# 6. THE TWO CASES NO NORMALISATION RULE COULD EVER REACH.
# ---------------------------------------------------------------------------
{
    # Prince: the MB title contains the PEACE SYMBOL (U+262E + U+FE0E).
    my $rg = { mbid => 'rg-sott', title => "Sign \x{201c}\x{262e}\x{fe0e}\x{201d} the Times",
               aliases => [ "Sign o' the Times" ] };
    my $sec = $SRC->matchesFor(
        { Qobuz => [ { name => "Sign 'O' the Times", _candTitle => "Sign 'O' the Times",
                       _candArtist => 'Prince', _albumid => 'p1', _svc => 'Qobuz' } ] },
        'Prince', $rg->{title}, undef, $rg->{mbid}, {}, undef,
        { sources => \@SOURCES, aliases => $rg->{aliases} });
    ok(scalar(@{ $sec || [] }), "Prince \"Sign 'O' the Times\" matches the peace-symbol title");

    # Big Star: the group is titled "3rd"; the owned copy says "Third/Sister Lovers".
    my $rg2 = { mbid => 'rg-3rd', title => '3rd', aliases => [ 'Third' ] };
    my $claimed = $SRC->claimedLocalIds(
        [ $rg2 ], 'Big Star',
        [ { _candTitle => 'Third/Sister Lovers', _candArtist => 'Big Star', _albumid => 7 } ], {});
    ok($claimed->{7}, 'Big Star "Third/Sister Lovers" is claimed by the group "3rd" via alias "Third"');
}

# ---------------------------------------------------------------------------
# 7. DEFENSIVE. Malformed alias data must not crash or match everything.
# ---------------------------------------------------------------------------
{
    my $rg = { mbid => 'rg-junk', title => 'Autobahn',
               aliases => [ '', undef, '   ', 'Autobahn' ] };
    ok(!matches($rg, 'Computer World'), 'empty/undef aliases match nothing');
    ok(matches($rg, 'Autobahn'), '... and the real title still matches alongside them');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
