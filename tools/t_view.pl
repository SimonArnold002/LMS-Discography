#!/usr/bin/env perl
#
# REGRESSION TEST: the artist page's Albums | Singles view (after 0.54.6).
#
# Simon, 2026-09-24 (LBF's "Showing ..." toggle): one cycling row in Options
# flips the page between the EPs + Singles sections (a true tab: no bio, extras
# or links) and every other release section. Drives the REAL _buildList with
# the services stubbed, and pins what the view must NOT change: a streaming
# album claimed by a SINGLE must not resurface in "Also on streaming" on the
# Albums view (claims are computed for every release before the view filters).
#
# Standalone, no LMS install needed:  perl tools/t_view.pl
#
use strict;
use warnings;
use FindBin;

our (%PREF, %MATCH, $POOL, $BANDS, $SIMILAR);

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers Slim::Utils::Strings
                  Slim::Control::Request Slim::Schema Slim::Web::HTTP
                  Slim::Networking::SimpleAsyncHTTP Slim::Utils::Misc
                  Plugins::Discography::Plugin Plugins::Discography::API
                  Plugins::Discography::Sources)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Cache' };
    *{'Slim::Utils::Strings::cstring'}   = sub {
        my $t = $_[1];
        return 'Showing %s (tap for %s)' if $t eq 'PLUGIN_DISCOGRAPHY_SHOWING';
        return 'Albums'  if $t eq 'PLUGIN_DISCOGRAPHY_ALBUMS';
        return 'Singles' if $t eq 'PLUGIN_DISCOGRAPHY_SINGLES';
        return 'Singles & EPs' if $t eq 'PLUGIN_DISCOGRAPHY_SINGLES_EPS';
        return $t };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');

    my $S = 'Plugins::Discography::Sources';
    my $A = 'Plugins::Discography::API';
    *{"${S}::_norm"} = sub { my $s = lc($_[-1] // ''); $s =~ s/[^a-z0-9]+/ /g; $s =~ s/^ +| +$//g; $s };
    *{"${S}::_artistMatch"}   = sub { 1 };
    *{"${S}::orderedSources"} = sub { ({ name => 'Qobuz' }) };
    *{"${S}::localAlbums"}    = sub { [] };
    *{"${S}::localTracks"}    = sub { [] };
    *{"${S}::peekPool"}       = sub { $main::POOL };
    *{"${S}::claimedLocalIds"} = sub { {} };
    *{"${S}::peekMatches"}    = sub { my ($c, $artist, $title) = @_;
        { sections => $main::MATCH{$title} || [], resolved => 1 } };
    *{"${A}::caaImage"}           = sub { 'caa' };
    *{"${A}::peekOfficial"}       = sub { undef };
    *{"${A}::peekReleaseMap"}     = sub { {} };
    *{"${A}::peekLocalReleaseMap"} = sub { {} };
    *{"${A}::peekEditions"}       = sub { {} };
    *{"${A}::clearArtistEmpty"}   = sub { 0 };
    *{"${A}::markArtistEmpty"}    = sub { };
    *{"${A}::peekBands"}          = sub { $main::BANDS };
    *{"${A}::peekCollabs"}        = sub { undef };
}

package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}
package T::Prefs; our $AUTOLOAD; sub get { $main::PREF{ $_[1] } } sub AUTOLOAD { return } sub DESTROY {}
package T::Cache; our $AUTOLOAD; sub get { $_[1] =~ /^dsc:similar:/ ? $main::SIMILAR : undef }
sub AUTOLOAD { return } sub DESTROY {}

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;
my $B = 'Plugins::Discography::Browse';

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

%PREF = (show_types => 'ALBUMS,EPS,SINGLES,COMPILATIONS,LIVE,OTHER', show_bio => 1,
         show_library_extras => 1, show_streaming_extras => 1, hide_unmatched => 0);

my $n = 0;
sub rg { my ($title, $type, @sec) = @_;
    { mbid => sprintf('%08d-0000-0000-0000-000000000000', ++$n), title => $title, type => $type,
      secondary => [@sec], date => '2000-01-01' } }
sub cand { my ($title, $id) = @_;
    { name => $title, type => 'playlist', _svc => 'Qobuz', _albumid => $id, _candArtist => 'Radiohead',
      favorites_url => "qobuz://album:$id", _year => 2000 } }

my @full = (rg('Kid A', 'Album'), rg('Airbag EP', 'EP'), rg('I Might Be Wrong', 'Album', 'Live'),
            rg('Creep', 'Single'), rg('Karma Police', 'Single'));
# "Creep" (a SINGLE) claims a streaming album; "Pablo Honey" nobody claims.
my $creep = cand('Creep', 'q-creep');
%MATCH = ('Creep' => [ { svc => 'Qobuz', items => [ $creep ] } ]);
$POOL  = { bySvc => { Qobuz => [ $creep, cand('Pablo Honey', 'q-pablo') ] } };
$BANDS = [ { mbid => 'b1', name => 'Atoms for Peace' } ];
$SIMILAR = [ 'Blur' ];

my $opts = { artist_id => 1, artist => 'Radiohead', features => 'hi', sort => 'newest' };
sub build {
    my ($rgs) = @_;
    return $B->can('_buildList')->(undef, { %$opts }, 'artist-mbid', $rgs, 'A bio paragraph.', []);
}
sub ids   { map { $_->{id} // () } @{ $_[0] } }
sub has   { my ($items, $id) = @_; scalar grep { ($_->{id} // '') eq $id } @$items }
sub row   { my ($items, $id) = @_; (grep { ($_->{id} // '') eq $id } @$items)[0] }

# 1. Albums view (the default).
my $a = build(\@full);
ok(scalar(has($a, 'sect:ALBUMS') && has($a, 'sect:LIVE')), '1: Albums view shows Albums and Live');
ok(scalar(!has($a, 'sect:SINGLES') && !has($a, 'sect:EPS')), '1: Albums view hides the Singles and EPs sections');
ok(scalar(has($a, 'sect:BIO') && has($a, 'sect:BANDS') && has($a, 'sect:SIMILAR')),
   '1: Albums view keeps the bio and the band/similar links');
my $tog = row($a, 'act:view');
ok(scalar($tog && $tog->{name} eq 'Showing Albums (tap for Singles & EPs)'), '1: toggle reads "Showing Albums (tap for Singles & EPs)"');
my @opt = ids($a);
my ($oi) = grep { ($opt[$_] // '') eq 'sect:OPT' } 0 .. $#opt;
ok(scalar(defined $oi && ($opt[$oi + 1] // '') eq 'act:view'), '1: the toggle is the first Options row');
ok(scalar(($tog->{nextWindow} // '') eq 'refresh'), '1: the toggle flips in place (nextWindow refresh)');
ok(scalar(($tog->{itemActions}{items}{fixedParams}{item} // '') eq 'act:view'), '1: the toggle tap is param-addressed');
ok(scalar(!grep { ($_->{id} // '') eq 'str:Qobuz:q-creep' } @$a),
   "1: a streaming album claimed by a SINGLE does not resurface under Also on streaming");
ok(scalar(grep { ($_->{id} // '') eq 'str:Qobuz:q-pablo' } @$a), '1: an unclaimed one still does');

# 2. Tap the toggle -> Singles view.
$tog->{url}->(undef, sub { }, {}, $tog->{passthrough}[0]);
my $s = build(\@full);
ok(scalar(has($s, 'sect:SINGLES') && has($s, 'sect:EPS')), '2: Singles view shows the EPs and Singles sections');
my @sids = ids($s);
my ($ie) = grep { $sids[$_] eq 'sect:EPS' } 0 .. $#sids;
my ($is) = grep { $sids[$_] eq 'sect:SINGLES' } 0 .. $#sids;
ok(scalar(defined $ie && defined $is && $ie < $is), '2: EPs come before Singles, each its own section');
ok(scalar(!has($s, 'sect:ALBUMS') && !has($s, 'sect:LIVE')),
   '2: Singles view hides every other release section');
ok(scalar(!has($s, 'sect:BIO') && !has($s, 'sect:BANDS') && !has($s, 'sect:SIMILAR') && !has($s, 'sect:STREAM')),
   '2: Singles view is a true tab: no bio, extras or links');
ok(scalar(has($s, 'sect:OPT') && has($s, 'act:refresh') && has($s, 'act:search')), '2: Options is still there');
my $tog2 = row($s, 'act:view');
ok(scalar($tog2 && $tog2->{name} eq 'Showing Singles & EPs (tap for Albums)'), '2: toggle now reads "Showing Singles & EPs (tap for Albums)"');
ok(scalar(($tog2->{image} // '') =~ /release-single/), "2: the toggle's icon shows the current view");
ok(scalar(grep { ($_->{name} // '') eq 'Creep' } @$s), '2: Creep is on the Singles view');

# 3. Idempotent + back to Albums.
$tog->{url}->(undef, sub { }, {}, $tog->{passthrough}[0]);   # the OLD row again: absolute target
ok(scalar(has(build(\@full), 'sect:SINGLES')), '3: a re-walked tap sets the same view (absolute target)');
$tog2->{url}->(undef, sub { }, {}, $tog2->{passthrough}[0]);
ok(scalar(has(build(\@full), 'sect:ALBUMS')), '3: tapping again returns to Albums');

# 4. Clamping: a page with only one family never opens empty and shows no toggle.
my @albumsOnly = (rg('OK Computer', 'Album'), rg('Amnesiac', 'Album'));
$tog->{url}->(undef, sub { }, {}, $tog->{passthrough}[0]);   # stored view = singles
my $ao = build(\@albumsOnly);
ok(scalar(has($ao, 'sect:ALBUMS') && !has($ao, 'act:view')), '4: albums-only artist: Albums shown, no toggle (even with Singles stored)');
$tog2->{url}->(undef, sub { }, {}, $tog2->{passthrough}[0]); # stored view = albums
my $so = build([ rg('Lift', 'Single'), rg('Man of War', 'Single') ]);
ok(scalar(has($so, 'sect:SINGLES') && !has($so, 'act:view')), '4: singles-only artist: opens on Singles, no toggle');
ok(scalar(has($so, 'sect:BIO') && has($so, 'sect:BANDS') && has($so, 'sect:SIMILAR')),
   '4: a singles-only artist keeps its bio and links (no Albums view to hold them, no toggle to reach one)');
$tog2->{url}->(undef, sub { }, {}, $tog2->{passthrough}[0]);
my $eo = build([ rg('Airbag EP', 'EP'), rg('Lift', 'Single') ]);
ok(scalar(has($eo, 'sect:EPS') && has($eo, 'sect:SINGLES') && !has($eo, 'act:view') && has($eo, 'sect:BIO')),
   '4: an EPs-and-singles-only artist opens on that view, no toggle, keeps its bio');

# 5. The fresh-entry ctx rebuild keeps `view` for the same artist (source check:
#    topLevel is async + HTTP-bound; the rule is the one line in the $same branch).
{
    open my $fh, '<', "$FindBin::Bin/../Discography/Browse.pm" or die $!;
    my $src = do { local $/; <$fh> };
    ok(scalar($src =~ /\$same \? \([^)]*view\s*=>\s*\$prev->\{view\}[^)]*\) : \(\)/s),
       '5: a same-artist fresh entry keeps the view flag');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
