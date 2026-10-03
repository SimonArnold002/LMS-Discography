#!/usr/bin/env perl
#
# REGRESSION TEST: what a tile with no source cover shows (0.56.44).
#
# History. 0.56.25 pointed such a tile at the Cover Art Archive and the image
# proxy fetched it while the user browsed, freezing the whole server (Simon,
# 2026-10-02, Adele -> Sam Smith). 0.56.26 showed the release-type icon unless
# the proxy's cache already held the cover; 0.56.30 fetched the missing ones at
# 05:00. Simon 2026-10-03: the blank tiles "defeat what we are trying to
# achieve", they should "load albeit slowly in a view". The freeze was TLS 1.3
# (CLAUDE.md §A3 `THE FREEZE IS TLS 1.3`), so now such a tile points at OUR
# route, `imageproxy/dsc/caa/<group>/image.jpg`, and Covers.pm downloads the
# cover over TLS 1.2 while the device waits (t_covers.pl).
#
# Pinned through the REAL _releaseItem / _typeIcon / _wantCovers and the REAL
# Covers::tileImage, against a fake kv store (Covers' failure row) and a fake
# proxy cache that must never be read while a tile is built.
#
# Standalone, no LMS install needed:  perl tools/t_tilecover.pl
#
use strict;
use warnings;
use FindBin;

our (%STORE, @ASKED);

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers Slim::Utils::Strings
                  Slim::Control::Request Slim::Schema Slim::Web::HTTP Slim::Web::ImageProxy
                  Slim::Networking::SimpleAsyncHTTP Slim::Utils::Misc
                  Plugins::Discography::Plugin Plugins::Discography::API
                  Plugins::Discography::Sources)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Store' }; $INC{'Plugins/Discography/DB.pm'} = 1;
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

    # The proxy's cache: building a tile must never read it.
    *{'Slim::Web::ImageProxy::Cache::new'} = sub { bless {}, 'Slim::Web::ImageProxy::Cache' };
    *{'Slim::Web::ImageProxy::Cache::get'} = sub { push @main::ASKED, $_[1]; 1 };
}

package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}
package T::Prefs; our %P; our $AUTOLOAD;
sub get { $P{ $_[1] } } sub AUTOLOAD { return } sub DESTROY {}
package T::Store;
sub get { $main::STORE{ $_[1] } }
sub set { $main::STORE{ $_[1] } = $_[2]; 1 }

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

my $tile  = $B->can('_releaseItem');
my $IMG   = 'plugins/Discography/html/images/';
my $MB    = '0dc27124-99ea-44f2-afbc-73e6f48b2c5b';   # a Sam Smith live single, CAA-only on the rig
my $ROUTE = "imageproxy/dsc/caa/$MB/image.jpg";
sub rg    { my (%o) = @_; { mbid => $MB, title => 'T', type => 'Album', secondary => [], date => '2023-01-01', %o } }
sub sec   { my ($svc, @items) = @_; { svc => $svc, items => \@items } }
sub fresh { %STORE = (); @ASKED = (); Plugins::Discography::Covers::_reset() }
use constant MISS => 'dsc:cvmiss:v2';

# 1. No source cover -> our route, and the group to want; no cache read.
{
    fresh();
    my $t = $tile->(undef, {}, rg(), []);
    ok(scalar(($t->{image} // '') eq $ROUTE), '1: no source cover -> imageproxy/dsc/caa/<group>/image.jpg');
    ok(scalar(($t->{_caaWant} // '') eq $MB), '1: ... and the page wants that group (_caaWant)');
    ok(scalar(!@ASKED), "1: the proxy's cache is not read while the tile is built");
    ok(scalar($t->{type} eq 'link' && $t->{line2} eq "2023 \x{00B7} Album"), '1: the tile is otherwise unchanged (type, line2)');
    fresh();
    ok(scalar(($tile->(undef, {}, rg(mbid => uc $MB), [])->{image} // '') eq $ROUTE), '1: an upper-case mbid -> the lower-case route');
}

# 2. The type icon: flagged as having no archive cover, given up, failed within
#    the hour, or no group id. The same icon its section header shows.
for my $c ([ rg(), 'release-album' ], [ rg(type => 'EP'), 'release-ep' ],
           [ rg(type => 'Single'), 'release-single' ],
           [ rg(secondary => ['Live']), 'release-live' ],
           [ rg(secondary => ['Compilation']), 'album-multi' ],
           [ rg(type => 'Broadcast'), 'release' ], [ rg(type => undef), 'release' ]) {
    fresh();
    my $t = $tile->(undef, {}, $c->[0], [], { lc $MB => 0 });
    ok(scalar($t->{image} eq "${IMG}dsc_MTL_svg_$c->[1].png" && !exists $t->{_caaWant}),
       "2: flagged no cover -> icon $c->[1], nothing wanted");
}
{
    fresh();
    $STORE{+MISS} = { $MB => [ time() - 60, 3 ] };
    my $t = $tile->(undef, {}, rg(), []);
    ok(scalar($t->{image} eq "${IMG}dsc_MTL_svg_release-album.png" && !exists $t->{_caaWant}),
       '2: given up (three counted failures) -> icon, nothing wanted');
    fresh();
    $STORE{+MISS} = { $MB => [ time() - 60, 1 ] };
    $t = $tile->(undef, {}, rg(), []);
    ok(scalar($t->{image} eq "${IMG}dsc_MTL_svg_release-album.png" && !exists $t->{_caaWant}),
       '2: failed a minute ago -> icon for the hour, nothing wanted');
    fresh();
    $STORE{+MISS} = { $MB => [ time() - 3601, 1 ] };
    ok(scalar(($tile->(undef, {}, rg(), [])->{image} // '') eq $ROUTE), '2: failed over an hour ago -> the route again');
    fresh();
    $t = $tile->(undef, {}, rg(mbid => 'not-a-group'), []);
    ok(scalar($t->{image} eq "${IMG}dsc_MTL_svg_release-album.png" && !exists $t->{_caaWant}),
       '2: no group mbid -> icon, nothing wanted');
}

# 3. ListenBrainz's flags (0.56.30): marked or unknown -> the route.
{
    my $id = lc $MB;
    fresh();
    ok(scalar(($tile->(undef, {}, rg(), [], { $id => 1 })->{image} // '') eq $ROUTE), '3: flagged a cover -> the route');
    fresh();
    ok(scalar(($tile->(undef, {}, rg(), [], { 'other-group' => 0 })->{_caaWant} // '') eq $MB),
       '3: not in the flags (unknown) -> wanted');
    fresh();
    ok(scalar(($tile->(undef, {}, rg(), [], {})->{_caaWant} // '') eq $MB), '3: empty flags -> wanted');
    fresh();
    ok(scalar(!exists $tile->(undef, {}, rg(mbid => uc $MB), [], { $id => 0 })->{_caaWant}), '3: the flag is read case-blind');
}

# 4. A source cover wins, and nothing is wanted; a match with no cover gets the
#    route and stays playable.
{
    fresh();
    my $q = { name => 'T', type => 'playlist', _svc => 'Qobuz', _albumid => 'x',
              _cover => 'https://static.qobuz.com/x_600.jpg', favorites_url => 'qobuz://album:x' };
    my $t = $tile->(undef, {}, rg(), [ sec('Qobuz', $q) ]);
    ok(scalar($t->{image} eq 'https://static.qobuz.com/x_600.jpg' && !exists $t->{_caaWant}),
       "4: a matched source's cover -> used, nothing wanted");
    fresh();
    my $l = { name => 'T', type => 'playlist', _svc => 'Local', _albumid => 5, play => 'db:album.id=5' };
    $t = $tile->(undef, {}, rg(), [ sec('Local', $l) ]);
    ok(scalar($t->{image} eq $ROUTE && $t->{type} eq 'playlist' && ($t->{_caaWant} // '') eq $MB),
       '4: a match with no cover -> the route, still playable, wanted');
}

# 5. _wantCovers queues exactly the tiles that name a group, in order.
{
    my @wanted;
    no warnings qw(redefine once);
    local *Plugins::Discography::Covers::want = sub { push @wanted, $_[0] };
    $B->can('_wantCovers')->([ { _caaWant => 'g1' }, { image => 'x' }, 'not a tile', { _caaWant => 'g2' } ]);
    $B->can('_wantCovers')->(undef);
    ok(scalar("@wanted" eq 'g1 g2'), '5: _wantCovers queues only the tiles that name a group, in order');
}

# 6. The page: the flags read once and handed to every tile, and the page
#    taking the front of the cover queue before its sections want anything.
{
    open my $fh, '<', "$FindBin::Bin/../Discography/API.pm" or die "API.pm: $!";
    my $api = do { local $/; <$fh> };
    ok(scalar(scalar($api =~ /\(\$_->\{caa_id\} \? 1 : 0\)/) && scalar($api =~ /_caaFlagsKey\(\$mbid\), \\%flags/)),
       '6: _lbGroups keeps { group => caa_id ? 1 : 0 } under the artist');
    open $fh, '<', "$FindBin::Bin/../Discography/Browse.pm" or die "Browse.pm: $!";
    my $br = do { local $/; <$fh> };
    # The flags are read ONCE, before the release loop (0.56.46: the loop drops
    # an unplayable group with no cover), and handed to every tile after it.
    my ($bl) = $br =~ /(^sub _buildList \{.*?^\})/ms;
    my @reads = ($bl // '') =~ /Plugins::Discography::API->peekCoverFlags\(\$mbid\)/g;
    my $iRead = index($bl // '', 'my $coverFlags = Plugins::Discography::API->peekCoverFlags($mbid);');
    my $iLoop = index($bl // '', 'for my $rg (@$rgs) {');
    ok(scalar(@reads == 1 && $iRead >= 0 && $iLoop > $iRead
              && scalar(($bl // '') =~ /\n\s*Plugins::Discography::Covers::newPage\(\);/)
              && scalar(($bl // '') =~ /_releaseItem\(\$client, \$opts, \$_->\[0\], \$_->\[1\], \$coverFlags\)/)),
       '6: _buildList reads the flags once before the release loop, starts a new cover page, hands the flags to every tile');
    ok(scalar($br !~ /_caaHeld|CAA_HELD_SPECS/), '6: no tile reads the proxy cache any more (_caaHeld is gone)');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
