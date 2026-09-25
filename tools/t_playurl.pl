#!/usr/bin/env perl
#
# REGRESSION TEST: Browse::_playUrl, the play string a tile / version row hands LMS.
# No suite covered it before the Spotify work (2026-09-25): section 1 pins every
# existing branch, section 2 adds Spotify. Harness copied from t_extid.pl.
#
# Standalone, no LMS install needed:  perl tools/t_playurl.pl
#
use strict;
use warnings;
use FindBin;

our ($SECTIONS);

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
    *{"${A}::caaImage"}            = sub { 'caa://' . ($_[1] // '') };
    *{"${A}::getReleaseGroupUrls"} = sub { my ($c, %a) = @_; $a{onDone}->([]) };
    *{"${A}::peekReleaseGroups"}   = sub { [] };
    *{"${A}::peekReleaseMap"}      = sub { {} };
    *{"${A}::peekLocalReleaseMap"} = sub { {} };
    *{"${S}::getCandidates"}       = sub { $_[-2]->({}) };
    *{"${S}::localAlbums"}         = sub { [] };
    *{"${S}::localTracks"}         = sub { [] };
    *{"${S}::matchesFor"}          = sub { $main::SECTIONS };
}

package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}

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
{ no warnings 'redefine'; no strict 'refs';
  *{"${B}::_fetchAlbumReview"} = sub { $_[-1]->(undef) }; }

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

my $play = $B->can('_playUrl');

# 1. EXISTING behaviour, pinned before Spotify was added (no suite covered _playUrl).
ok(scalar(($play->({ _svc => 'Local', _albumid => 5, play => 'db:album.id=29030' }) // '') eq 'db:album.id=29030'),
   "1: a node's own play string wins (Local db: url)");
ok(scalar(($play->({ _svc => 'Qobuz',  _albumid => '0724352774' }) // '') eq 'qobuz://album:0724352774.qbz'),
   '1: Qobuz -> qobuz://album:<id>.qbz (explodePlaylist needs .qbz)');
ok(scalar(($play->({ _svc => 'Tidal',  _albumid => '1234567' }) // '') eq 'tidal://album:1234567'), '1: Tidal -> tidal://album:<id>');
ok(scalar(($play->({ _svc => 'Deezer', _albumid => '99887' })   // '') eq 'deezer://album:99887'),  '1: Deezer -> deezer://album:<id>');
ok(scalar(($play->({ _svc => 'Other', _albumid => 'x', favorites_url => 'other://album:x?cover=a&a=b' }) // '') eq 'other://album:x'),
   '1: an unknown service -> its favurl minus our query params');
ok(scalar(!defined $play->({ _svc => 'Qobuz' })), '1: no album id -> undef');
ok(scalar(!defined $play->({ _albumid => 1 })), '1: no service -> undef');
ok(scalar(!defined $play->(undef) && !defined $play->('x')), '1: not a hash -> undef');
ok(scalar(($play->({ _svc => 'Qobuz', _albumid => 'q', play => sub {} }) // '') eq 'qobuz://album:q.qbz'),
   '1: a coderef play is ignored');

# 2. Spotify. Spotty's favorites_url is `spotify:album:<id>`; the play string is the
# protocol-handler form, which explodePlaylist -> tracksFromURI (`:album:`) -> album()
# turns into the track list (Spotty 4.62.2 source, read 2026-09-25).
ok(scalar(($play->({ _svc => 'Spotify', _albumid => '4qpB1EXFCmq0a209JGCsZt',
                     favorites_url => 'spotify:album:4qpB1EXFCmq0a209JGCsZt' }) // '')
          eq 'spotify://album:4qpB1EXFCmq0a209JGCsZt'), '2: Spotify -> spotify://album:<id>');
ok(scalar(!defined $play->({ _svc => 'Spotify' })), '2: Spotify with no album id -> undef');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
