#!/usr/bin/env perl
#
# REGRESSION TEST — the release DETAIL page must apply the list view's
# same-name guard (review 2026-09-19, finding 1).
#
# A secondary act that shares its exact name with a more prominent one
# ("Other artists with this name" -> Sonic Boom, Andrew Huang's group) gets
# NO name-keyed library lookup on its list view: `_discographyView` sets
# $opts->{shared_name} and gates `$local` on `shared_name && !artist_id`.
# The detail page is reached three ways — the tile's url coderef (passthrough
# = the list's $opts, flag present), Material's `_rgView` and `playCommand`
# (both rebuild $pass from action params, flag ABSENT). The last two used to
# look the name up anyway, so a detail page (and tile play) could claim the
# prominent act's owned album as Local where the tile did not.
#
# Drives the REAL `_releaseDetail` with API/Sources stubbed and asserts which
# library lookups it makes.
#
# Standalone — no LMS install needed:  perl tools/t_detailshared.pl
#
use strict;
use warnings;
use FindBin;

our (%SHARED, @SHARECALLS, @LA, @LT, $URLS);

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
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Strings::cstring'}   = sub { $_[1] };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Plugins::Discography::Sources::_norm'} = sub {
        my $s = lc($_[-1] // ''); $s =~ s/[^a-z0-9]+/ /g; $s =~ s/^ +| +$//g; $s };
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');

    my $A = 'Plugins::Discography::API';
    my $S = 'Plugins::Discography::Sources';
    *{"${A}::sharesNameWithProminentAsync"} = sub {
        my ($c, $name, $mbid, $cb) = @_;
        push @main::SHARECALLS, [$name, $mbid];
        return $cb->(0) unless $mbid;   # as the real sub
        $cb->($main::SHARED{$mbid} ? 1 : 0);
    };
    *{"${A}::getReleaseGroupUrls"}  = sub { $main::URLS++ };   # compose never runs
    *{"${A}::peekReleaseGroups"}    = sub { [] };
    *{"${A}::peekReleaseMap"}       = sub { {} };
    *{"${A}::peekLocalReleaseMap"}  = sub { {} };
    *{"${A}::peekOfficial"}         = sub { {} };
    *{"${A}::getReleaseGroups"}     = sub { my ($c, %a) = @_; $a{onError}->() };
    *{"${S}::getCandidates"}        = sub { $_[-2]->({}) };
    *{"${S}::localAlbums"}          = sub { shift; push @main::LA, [@_]; [] };
    *{"${S}::localTracks"}          = sub { shift; push @main::LT, [@_]; [] };
    # matchesFor pulls the lazy track pool, as the real one does for a miss.
    *{"${S}::matchesFor"}           = sub { my $o = $_[-1]; $o->{localTracks}->() if $o->{localTracks}; {} };
}

package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;
my $B = 'Plugins::Discography::Browse';
{ no warnings 'redefine'; no strict 'refs';
  *{"${B}::_fetchAlbumReview"} = sub { }; }

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

my $SECOND = '13a1f939-9e60-495f-b5f5-71c4bb3438a7';   # Sonic Boom (Huang group)
my $PROM   = '00000000-0000-0000-0000-00000000prom';   # the prominent act
$SHARED{$SECOND} = 1;
my $rg = { mbid => '11111111-1111-1111-1111-111111111111', title => 'Spectrum', type => 'Album', secondary => [] };

sub detail {
    my (%p) = @_;
    @SHARECALLS = (); @LA = (); @LT = (); $URLS = 0;
    $B->can('_releaseDetail')->(undef, sub { }, { artist => 'Sonic Boom', rg => $rg, %p });
}

# 1. Material/_rgView or playCommand: secondary act, no id, flag ABSENT.
detail(mbid => $SECOND);
ok(scalar(@SHARECALLS == 1), '1: flag absent -> detail resolves shared_name itself');
ok(scalar(@LA == 0), '1: shared name, no id -> NO localAlbums lookup (list view makes none)');
ok(scalar(@LT == 0), '1: shared name, no id -> NO localTracks lookup');
ok(scalar($URLS == 1), "1: the re-entry fetches the release links ONCE, not twice");

# 2. Same route, prominent act: nothing changes — name lookup as before.
detail(mbid => $PROM);
ok(scalar(@LA == 1 && ($LA[0][3]{fallback} // '') eq 'name'),
   '2: not shared -> localAlbums runs with the name fallback (unchanged)');
ok(scalar(@LT == 1), '2: not shared -> localTracks runs (unchanged)');

# 3. Secondary act entered WITH an own library id: lookup kept, mbid-only fallback
#    (same as the list's _idFallback).
detail(mbid => $SECOND, artist_id => 777);
ok(scalar(@LA == 1 && ($LA[0][3]{fallback} // '') eq 'mbid'),
   '3: shared name + own id -> localAlbums with fallback=mbid, as the list');
ok(scalar(@LT == 1 && ($LT[0][2]{fallback} // '') eq 'mbid'),
   '3: shared name + own id -> localTracks with fallback=mbid, as the list');

# 4. Tile coderef: passthrough already carries the flag — no second check.
detail(mbid => $SECOND, shared_name => 1);
ok(scalar(@SHARECALLS == 0), '4: flag present (tile passthrough) -> no extra check');
ok(scalar(@LA == 0 && @LT == 0), '4: flag present, no id -> no library lookups');
detail(mbid => $PROM, shared_name => 0);
ok(scalar(@SHARECALLS == 0 && @LA == 1), '4: flag present and false -> lookup runs, no extra check');

# 5. No artist mbid (stale passthrough): nothing to compare; lookup as before.
detail();
ok(scalar(@LA == 1), '5: no mbid -> lookup runs (nothing to guard against)');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
