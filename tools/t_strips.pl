#!/usr/bin/env perl
#
# REGRESSION TEST: release sections as tile strips (0.53.x), and WHO gets them.
#
# Which sections are strips is the user's layout setting (0.54.0).
# Strips need BOTH a patched Material on the server (_useStrips) AND a client that
# draws headers (features:h -> $useH). A strip shows STRIP_SIZE tiles and relies
# on the header's More for the rest; a client without headers gets a text
# divider with no url, so before 0.53.3 it lost every tile past the 25th in a
# section (Default/Classic web, CLI, Jive against a strip-enabled server). Pinned
# here through the REAL _sectionTiles / _sectionHeaderType / _stripsOn.
#
# Standalone, no LMS install needed:  perl tools/t_strips.pl
# (re-runs itself once with a release Material version, where strips are off)
#
use strict;
use warnings;
use FindBin;

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
    # The installed Material's version decides _useStrips (cached per process),
    # so each run fixes it up front; the suite re-runs itself for a release build.
    $INC{'Plugins/MaterialSkin/Plugin.pm'} = 1;
    *{'Plugins::MaterialSkin::Plugin::getPluginVersion'} = sub { $ENV{T_MATERIAL_VER} // '6.4.10.5' };
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Strings::cstring'}   = sub { $_[1] };   # returns the token
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    # Browse builds %GENERIC_TITLE via Sources::_norm at load — a light stub is
    # enough (this suite never depends on real normalisation).
    *{'Plugins::Discography::Sources::_norm'} = sub {
        my $s = lc($_[-1] // ''); $s =~ s/[^a-z0-9]+/ /g; $s =~ s/^ +| +$//g; $s };
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');
}

package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}

# Prefs backed by %T::Prefs::P, so each block can set the section layouts.
# An unset pref reads undef, as a fresh install would before init.
package T::Prefs; our %P; our $AUTOLOAD;
sub get { $P{ $_[1] } } sub AUTOLOAD { return } sub DESTROY {}

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

# 40 tiles: over both STRIP_SIZE (25) and PAGE_SIZE (30), so both modes cut.
my @tiles = map { { name => "t$_", type => 'playlist' } } 1 .. 40;
my $ts  = $B->can('_sectionTiles');
my $sht = $B->can('_sectionHeaderType');
my $on  = $B->can('_stripsOn');
my $ver = $ENV{T_MATERIAL_VER} // '6.4.10.5';
my $patched = $ver =~ /^6\.4\.10\.\d+$/;

# A client WITHOUT headers never gets strips, patched Material or not: plain
# paging, so every tile stays reachable through Show more.
{
    my ($vis, $pg, $all) = $ts->(undef, {}, 0, 'ALBUM', \@tiles);
    ok(scalar(@$vis == 30), "[$ver] no-header client: first page of 30 rows, not a 25-tile strip");
    ok(scalar(@$pg >= 1 && $pg->[0]{id} eq 'page:ALBUM:40'), "[$ver] no-header client: Show more row reaches the rest");
    ok(scalar(!$on->(0)), "[$ver] no-header client: strips off (Singles keeps its place)");
}

if ($patched) {
    my ($vis, $pg, $all) = $ts->(undef, {}, 1, 'ALBUM', \@tiles);
    ok(scalar(@$vis == 25 && !@$pg), "[$ver] header client: 25-tile strip, no paging rows");
    ok(scalar(@$all == 40), "[$ver] header client: the header's More holds every tile");
    ok(scalar($sht->(1, 'ALBUM') eq 'header-strip'), "[$ver] header client: strip header type");
    ok(scalar($on->(1)), "[$ver] header client: strips on");

    # Singles stays a list even for a header client.
    my ($sv, $sp) = $ts->(undef, {}, 1, 'SINGLES', \@tiles);
    ok(scalar(@$sv == 30 && @$sp >= 1), "[$ver] Singles stays a paged list under strips");
    ok(scalar($sht->(1, 'SINGLES') ne 'header-strip'), "[$ver] Singles header is an ordinary header");

    # A short section: the whole list, no empty slots.
    my ($shortV) = $ts->(undef, {}, 1, 'EP', [ @tiles[0 .. 2] ]);
    ok(scalar(@$shortV == 3 && !grep { !defined } @$shortV), "[$ver] short strip holds exactly its tiles");
    my ($emptyV, $emptyP, $emptyA) = $ts->(undef, {}, 1, 'EP', []);
    ok(scalar(!@$emptyV && !@$emptyP && !@$emptyA), "[$ver] empty section: no rows");
} else {
    my ($vis, $pg) = $ts->(undef, {}, 1, 'ALBUM', \@tiles);
    ok(scalar(@$vis == 30 && @$pg >= 1), "[$ver] release Material: header client keeps the plain paged list");
    ok(scalar($sht->(1, 'ALBUM') ne 'header-strip'), "[$ver] release Material: never sends header-strip");
    ok(scalar(!$on->(1)), "[$ver] release Material: strips off");
}

# The layout settings (0.54.0): Singles follow layout_singles, everything else
# layout_albums. Unset = the defaults (tiles, Singles a list), checked above.
if ($patched) {
    my $mode = sub { my ($k) = @_; my ($v, $p) = $ts->(undef, {}, 1, $k, \@tiles); @$p ? 'list' : (@$v == 25 ? 'tiles' : '?') };
    for my $case (['list',  'list',  'list',  'list',  'all list'],
                  ['tiles', 'tiles', 'tiles', 'tiles', 'all tiles'],
                  ['tiles', 'list',  'tiles', 'list',  'the mix'],
                  ['list',  'tiles', 'list',  'tiles', 'list albums, tile singles']) {
        my ($la, $ls, $wantA, $wantS, $name) = @$case;
        local %T::Prefs::P = (layout_albums => $la, layout_singles => $ls);
        ok(scalar($mode->('ALBUM') eq $wantA && $mode->('EPS') eq $wantA && $mode->('STREAM') eq $wantA
               && $mode->('LIB') eq $wantA),
           "[$ver] $name: every non-Singles section is $wantA");
        ok(scalar($mode->('SINGLES') eq $wantS), "[$ver] $name: Singles is $wantS");
        ok(scalar(($sht->(1, 'SINGLES') eq 'header-strip') == ($wantS eq 'tiles')),
           "[$ver] $name: Singles header type matches");
    }
    # Singles move to the end only in the mix (tile albums, list Singles).
    my $go = $B->can('_groupOrder');
    my $order = sub { join ',', map { $_->[0] } $go->(@_) };
    my $typeOrder = 'ALBUMS,EPS,SINGLES,COMPILATIONS,LIVE,OTHER';
    for my $case (['tiles', 'list',  1, 'ALBUMS,EPS,COMPILATIONS,LIVE,OTHER,SINGLES', 'the mix'],
                  ['tiles', 'tiles', 1, $typeOrder, 'all tiles'],
                  ['list',  'list',  1, $typeOrder, 'all list'],
                  ['list',  'tiles', 1, $typeOrder, 'list albums, tile singles'],
                  ['tiles', 'list',  0, $typeOrder, 'the mix, no-header client']) {
        my ($la, $ls, $h, $want, $name) = @$case;
        local %T::Prefs::P = (layout_albums => $la, layout_singles => $ls);
        ok(scalar($order->($h) eq $want), "[$ver] $name: section order $want");
    }

    # A no-header client ignores the settings: always the paged list.
    local %T::Prefs::P = (layout_albums => 'tiles', layout_singles => 'tiles');
    my ($v, $p) = $ts->(undef, {}, 0, 'SINGLES', \@tiles);
    ok(scalar(@$p >= 1), "[$ver] all tiles set: a no-header client still gets the paged list");
} else {
    local %T::Prefs::P = (layout_albums => 'tiles', layout_singles => 'tiles');
    ok(scalar($sht->(1, 'SINGLES') ne 'header-strip' && $sht->(1, 'ALBUMS') ne 'header-strip'),
       "[$ver] release Material: tiles set, still no header-strip");
    local %T::Prefs::P = (layout_albums => 'tiles', layout_singles => 'list');
    ok(scalar(join(',', map { $_->[0] } $B->can('_groupOrder')->(1)) eq 'ALBUMS,EPS,SINGLES,COMPILATIONS,LIVE,OTHER'),
       "[$ver] release Material: type order unchanged");
}

# Re-run once against a release Material (strips must be off for everyone).
if (!defined $ENV{T_MATERIAL_VER}) {
    local $ENV{T_MATERIAL_VER} = '6.4.10';
    local $ENV{T_CHILD} = 1;
    my $out = `$^X "$0"`;
    print $out;
    $pass += () = $out =~ /^ok   - /mg;
    $fail += () = $out =~ /^FAIL - /mg;
    $fail++ if $? && $out !~ /^FAIL - /m;
}

print "\n", ($fail ? "FAILED" : "PASS"), ": $pass passed, $fail failed\n" unless $ENV{T_CHILD};
exit($fail ? 1 : 0);
