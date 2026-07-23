#!/usr/bin/env perl
#
# REGRESSION TEST — a release owned only as a COMPILATION TRACK becomes playable.
#
# FIELD (Simon, "The Bees"): the garage act's spine single "Voices Green and
# Purple / Trip to New Orleans" rendered as an unplayable orphan, while the
# track he owns (on the Nuggets comp) sat separately under Appearances — "odd
# having it orphaned like that and you can't play the track directly at all."
#
# The fix links an owned track to the spine release by title (A/B-side aware,
# gated to THIS artist's own tracks) ONLY when nothing else matched, and plays
# it via db:track.id. The comp album stays under Appearances (Simon's call).
#
# Standalone -- no LMS install needed:  perl tools/t_tracklink.pl
#
use strict;
use warnings;
use FindBin;

my @TITLE_QUERIES;
my %TITLES;   # artist_id -> [ {id,title,album,url,artwork_track_id}, ... ]

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::Timers Slim::Networking::SimpleAsyncHTTP
                  Slim::Utils::Strings Slim::Utils::PluginManager
                  Slim::Control::Request Slim::Schema
                  JSON::XS::VersionOneAndTwo Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}          = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Control::Request::executeRequest'} = sub {
        my (undef, $args) = @_;
        if (($args->[0] // '') eq 'titles') {
            my ($aid) = map { /^artist_id:(\d+)/ ? $1 : () } @$args;
            push @TITLE_QUERIES, $aid;
            return bless { loop => ($TITLES{$aid} || []) }, 'T::Req';
        }
        return bless { loop => [] }, 'T::Req';
    };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs)) { push @{"${p}::ISA"}, 'Exporter' }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
}
package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Prefs; sub get { 1 } sub set { 1 } sub init { 1 } sub setChange { 1 }
package T::Req;   sub getResult { my ($s,$w)=@_; $w eq 'titles_loop' ? $s->{loop} : undef }
package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
my $SRC  = 'Plugins::Discography::Sources';
my $norm = $SRC->can('_norm');
my $link = $SRC->can('_trackLinksRelease');

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" } else { $fail++; print "FAIL - $n\n" }
}
sub track { my ($t) = @_; return { _candTitle => $t } }
sub links { my ($rg, $t) = @_; $link->($norm->($rg), $rg, track($t)) ? 1 : 0 }

# ---------------------------------------------------------------------------
# 1. _trackLinksRelease — the title logic, A/B-side aware in both directions.
# ---------------------------------------------------------------------------
ok(links('Voices Green and Purple', 'Voices Green and Purple'),
   'an exact title links');
ok(links('Voices Green and Purple / Trip to New Orleans', 'Voices Green and Purple'),
   'the A-side of a 45 links to the owned track (field case)');
ok(links('Baby Let Me Follow You Down / Forget Me Girl', 'Forget Me Girl'),
   'the B-side links too');
ok(links('Forget Me Girl', 'Baby Let Me Follow You Down / Forget Me Girl'),
   'the reverse: a single-titled release links to an A/B owned track');
ok(!links('Some Entirely Other Song', 'Voices Green and Purple'),
   'an unrelated title does NOT link');
ok(!links('Yes', 'Yes'),
   'a title under 4 chars does NOT link (generic-collision guard)');

# An inline slash (no surrounding spaces) is NOT an A/B separator, so it is not
# split into fragments — "AC/DC" stays whole and matches only as a whole.
ok(scalar(@{ $SRC->can('_titleSides')->('AC/DC') } == 1),
   '"AC/DC" is not split on its inline slash');
ok(scalar(@{ $SRC->can('_titleSides')->('A-side / B-side') } == 2),
   'a spaced " / " IS split into two sides');

# ---------------------------------------------------------------------------
# 2. matchesFor — the track-link pass.
# ---------------------------------------------------------------------------
my @SOURCES = ( { name => 'Qobuz', local => 0, icon => 'q.png' },
                { name => 'Local', local => 1, icon => 'l.png' } );
my $comptrack = {
    _candTitle => 'Voices Green and Purple', _track => 1, _trackid => 500,
    play => 'db:track.id=500', _svc => 'Local', _fromAlbum => 'Nuggets',
};
my $rgTitle = 'Voices Green and Purple / Trip to New Orleans';

# (a) An orphaned release (no streaming, no local album) links the owned track.
{
    my $sec = $SRC->matchesFor(
        {}, 'The Bees', $rgTitle, undef, 'rg-1', {}, undef,
        { sources => \@SOURCES, localTracks => [ $comptrack ] });
    ok(scalar(@{ $sec || [] } == 1), 'an orphaned release gains ONE section');
    ok(scalar($sec->[0]{svc} eq 'Local'), '... a Local section');
    ok(scalar($sec->[0]{items}[0]{play} eq 'db:track.id=500'),
       '... whose item plays the track directly (db:track.id)');
    ok(scalar($sec->[0]{items}[0]{_fromAlbum} eq 'Nuggets'),
       '... and remembers the comp it came from (row hint)');
}

# (b) A release that DID match (streaming) must NOT get a track link bolted on.
{
    my $qcand = { _candTitle => $rgTitle, _candArtist => 'The Bees', _albumid => 'q1', _svc => 'Qobuz' };
    my $sec = $SRC->matchesFor(
        { Qobuz => [ $qcand ] }, 'The Bees', $rgTitle, undef, 'rg-1', {}, undef,
        { sources => \@SOURCES, localTracks => [ $comptrack ] });
    ok(scalar(@{ $sec || [] } == 1 && $sec->[0]{svc} eq 'Qobuz'),
       'a streaming-matched release keeps ONLY its streaming section (no track bolt-on)');
}

# (c) No owned track links this release -> NO MATCH, nothing invented.
{
    my $sec = $SRC->matchesFor(
        {}, 'The Bees', 'A Completely Different Single', undef, 'rg-2', {}, undef,
        { sources => \@SOURCES, localTracks => [ $comptrack ] });
    ok(scalar(@{ $sec || [] } == 0), 'a release with no linking owned track stays unmatched');
}

# (d) LAZY: the coderef is called for an UNMATCHED release, NOT for a matched one.
{
    my $calls = 0;
    my $lazy  = sub { $calls++; [ $comptrack ] };
    my $qcand = { _candTitle => $rgTitle, _candArtist => 'The Bees', _albumid => 'q1', _svc => 'Qobuz' };
    $SRC->matchesFor({ Qobuz => [ $qcand ] }, 'The Bees', $rgTitle, undef, 'rg-1', {}, undef,
        { sources => \@SOURCES, localTracks => $lazy });
    ok(scalar($calls == 0), 'the lazy track pool is NOT fetched when the release already matched');
    $SRC->matchesFor({}, 'The Bees', $rgTitle, undef, 'rg-1', {}, undef,
        { sources => \@SOURCES, localTracks => $lazy });
    ok(scalar($calls == 1), '... and IS fetched (once) for an unmatched release');
}

# (e) Cap at MAX_PER_SVC.
{
    my @many = map { { _candTitle => 'Voices Green and Purple', _track => 1,
                       _trackid => $_, play => "db:track.id=$_", _svc => 'Local' } } 1 .. 20;
    my $sec = $SRC->matchesFor(
        {}, 'The Bees', $rgTitle, undef, 'rg-1', {}, undef,
        { sources => \@SOURCES, localTracks => \@many });
    ok(scalar(@{ $sec->[0]{items} } <= 8),
       'track matches are capped (MAX_PER_SVC): ' . scalar(@{ $sec->[0]{items} }));
}

# ---------------------------------------------------------------------------
# 3. localTracks — the owned-track fetch shape.
# ---------------------------------------------------------------------------
{
    $TITLES{77854} = [
        { id => 900, title => 'Forget Me Girl',
          album => "Pushin' Too Hard", url => 'file:///a.flac', artwork_track_id => 55 },
    ];
    @TITLE_QUERIES = ();
    my $out = $SRC->localTracks(77854, 'The Bees');
    ok(scalar(@$out == 1), 'localTracks returns one owned track');
    ok(scalar($out->[0]{play} eq 'db:track.id=900'), '... with a db:track.id play string');
    ok(scalar($out->[0]{_track} && $out->[0]{_fromAlbum} eq "Pushin' Too Hard"),
       '... flagged _track and carrying its comp name');
    ok(scalar($out->[0]{_cover} eq '/music/55/cover'), '... and its artwork');
    ok(scalar(@TITLE_QUERIES == 1 && $TITLE_QUERIES[0] == 77854),
       '... via ONE titles query, id-keyed to that contributor');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
