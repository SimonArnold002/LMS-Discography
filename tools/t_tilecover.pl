#!/usr/bin/env perl
#
# REGRESSION TEST: a tile with no source cover never makes the server fetch an
# archive cover while the user browses (0.56.26).
#
# Field (Simon, 2026-10-02, Adele -> Sam Smith): the artwork took a long time to
# draw. Measured on the rig: every tile without a Qobuz/TIDAL cover pointed at
# the Cover Art Archive, and the image proxy fetched each from archive.org on
# demand, about 3 s a cover, stalling the whole server about 0.65 s each (14 s
# for a cover archive.org failed, and a failure is never cached). Now such a
# tile carries the archive url ONLY when the proxy's own cache already holds
# it, else its release-type icon. Pinned through the REAL _releaseItem /
# _caaHeld / _typeIcon, against a fake proxy cache keyed exactly as LMS keys it
# (`imageproxy/<decoded url>/image<spec><ext>`, Slim::Web::HTTP + ImageProxy).
#
# Standalone, no LMS install needed:  perl tools/t_tilecover.pl
#
use strict;
use warnings;
use FindBin;

our ($SECTIONS, %HELD, @ASKED, $GET_DIES, $NEW_DIES);

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
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Null' }; $INC{'Plugins/Discography/DB.pm'} = 1;
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

    # caaImage as API.pm builds it (section 9 checks the source still does).
    *{'Plugins::Discography::API::caaImage'} = sub {
        'https://coverartarchive.org/release-group/' . $_[1] . '/front-' . ($_[2] || 250) . '.jpg' };

    # The image proxy's cache: a hit is any value, as DbCache::get returns.
    *{'Slim::Web::ImageProxy::Cache::new'} = sub {
        die "no cache\n" if $main::NEW_DIES; bless {}, 'Slim::Web::ImageProxy::Cache' };
    *{'Slim::Web::ImageProxy::Cache::get'} = sub {
        push @main::ASKED, $_[1];
        die "db locked\n" if $main::GET_DIES;
        $main::HELD{ $_[1] } };
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

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

my $tile = $B->can('_releaseItem');
my $IMG  = 'plugins/Discography/html/images/';
my $MB   = '0dc27124-99ea-44f2-afbc-73e6f48b2c5b';   # a Sam Smith live single, CAA-only on the rig
my $CAA  = "https://coverartarchive.org/release-group/$MB/front-250.jpg";
sub rg   { my (%o) = @_; { mbid => $MB, title => 'T', type => 'Album', secondary => [], date => '2023-01-01', %o } }
sub key  { "imageproxy/$CAA/image$_[0].jpg" }
sub sec  { my ($svc, @items) = @_; { svc => $svc, items => \@items } }
sub fresh { %HELD = (); @ASKED = (); $GET_DIES = 0; $NEW_DIES = 0 }

# 1. The proxy's cache cannot be opened (first, before _caaHeld keeps a handle):
#    the tile gets its icon, nothing dies.
fresh(); $NEW_DIES = 1;
{
    my $t = eval { $tile->(undef, {}, rg(), []) };
    ok(scalar($t && $t->{image} eq "${IMG}dsc_MTL_svg_release-album.png"),
       '1: no proxy cache -> the type icon, and the tile still builds');
}

# 2. Held under the request Material 6.4.10 sends today (unsized .png).
fresh(); $HELD{ key('') } = { data_ref => \'x' };
{
    my $t = $tile->(undef, {}, rg(), []);
    ok(scalar($t->{image} eq $CAA), '2: held unsized -> the archive cover');
    ok(scalar(($ASKED[0] // '') eq key('')),
       '2: the key is the decoded url, no leading slash, `.jpg` from the url');
}

# 3. Held only at one of the sizes a fixed Material asks.
for my $spec ('_300x300_f', '_150x150_f', '_600x600_f') {
    fresh(); $HELD{ key($spec) } = 1;
    ok(scalar($tile->(undef, {}, rg(), [])->{image} eq $CAA), "3: held at $spec -> the archive cover");
}

# 4. Not held -> the release-type icon, the same one its section header shows.
for my $c ([ rg(), 'release-album' ], [ rg(type => 'EP'), 'release-ep' ],
           [ rg(type => 'Single'), 'release-single' ],
           [ rg(secondary => ['Live']), 'release-live' ],
           [ rg(secondary => ['Compilation']), 'album-multi' ],
           [ rg(type => 'Broadcast'), 'release' ], [ rg(type => undef), 'release' ]) {
    fresh();
    my $t = $tile->(undef, {}, $c->[0], []);
    ok(scalar($t->{image} eq "${IMG}dsc_MTL_svg_$c->[1].png"), "4: not held -> icon $c->[1]");
}
{
    fresh();
    my $t = $tile->(undef, {}, rg(), []);
    ok(scalar(@ASKED == 4), '4: a miss asks the four request shapes, nothing more');
    ok(scalar($t->{type} eq 'link' && $t->{line2} eq "2023 \x{00B7} Album"),
       '4: the tile is otherwise unchanged (type, line2)');
}

# 5. The ESCAPED form is not the key: a cover held only under proxiedImage's
#    own output (what a wrong key would read) does not count.
fresh();
(my $esc = $CAA) =~ s/([^A-Za-z0-9\-_.~])/sprintf('%%%02X', ord $1)/ge;
$HELD{ "/imageproxy/$esc/image.png" } = 1;
$HELD{ "imageproxy/$esc/image.png" }  = 1;
ok(scalar($tile->(undef, {}, rg(), [])->{image} eq "${IMG}dsc_MTL_svg_release-album.png"),
   '5: held only under an escaped path -> not counted (the proxy caches the decoded one)');

# 6. A source cover wins and the proxy cache is never asked.
{
    fresh(); $HELD{ key('') } = 1;
    my $q = { name => 'T', type => 'playlist', _svc => 'Qobuz', _albumid => 'x',
              _cover => 'https://static.qobuz.com/x_600.jpg', favorites_url => 'qobuz://album:x' };
    my $t = $tile->(undef, {}, rg(), [ sec('Qobuz', $q) ]);
    ok(scalar($t->{image} eq 'https://static.qobuz.com/x_600.jpg' && !@ASKED),
       "6: a matched source's cover -> used, the proxy cache not read");
    my $l = { name => 'T', type => 'playlist', _svc => 'Local', _albumid => 5, play => 'db:album.id=5' };
    fresh();
    $t = $tile->(undef, {}, rg(), [ sec('Local', $l) ]);
    ok(scalar($t->{image} eq "${IMG}dsc_MTL_svg_release-album.png" && $t->{type} eq 'playlist'),
       '6: a match with no cover, archive cover not held -> icon, still playable');
    fresh(); $HELD{ key('') } = 1;
    ok(scalar($tile->(undef, {}, rg(), [ sec('Local', $l) ])->{image} eq $CAA),
       '6: a match with no cover, archive cover held -> the archive cover');
}

# 7. A cache read that dies counts as not held.
fresh(); $HELD{ key('') } = 1; $GET_DIES = 1;
ok(scalar($tile->(undef, {}, rg(), [])->{image} eq "${IMG}dsc_MTL_svg_release-album.png"),
   '7: the cache read dies -> the type icon');

# 8. The extension follows proxiedImage's rule (a .jpg url is proxied as .jpg).
{
    my $held = $B->can('_caaHeld');
    fresh(); $HELD{ 'imageproxy/https://x/front-250.jpg/image_300x300_f.jpg' } = 1;
    ok(scalar($held->('https://x/front-250.jpg')), '8: a .jpg url -> the .jpg key');
    fresh(); $HELD{ 'imageproxy/https://x/a.jpeg/image.jpg' } = 1;
    ok(scalar($held->('https://x/a.jpeg')), "8: .jpeg -> proxied as .jpg, as LMS does");
    fresh();
    ok(scalar(!$held->(undef) && !$held->('') && !@ASKED), '8: no url -> not held, nothing read');
}

# 9. The url API.pm actually builds is the one this suite stands in for: a
#    front-250 under coverartarchive.org/release-group/, ending `.jpg` so the
#    proxy stores JPEG, not PNG (0.56.27, LBF's API::coverArtUrl).
{
    open my $fh, '<', "$FindBin::Bin/../Discography/API.pm" or die "API.pm: $!";
    my $src = do { local $/; <$fh> };
    ok(scalar($src =~ m{CAA_RG_BASE_URL\s*=>\s*'https://coverartarchive\.org/release-group/'}
              && $src =~ m{return CAA_RG_BASE_URL \. \$rgMbid \. '/front-' \. \(\$size \|\| 250\) \. '\.jpg';}),
       "9: API::caaImage builds https://coverartarchive.org/release-group/<mbid>/front-250.jpg");
}

# 10. A tile showing the icon names the cover to fetch after the visit
#     (`_caaWant`, 0.56.27); a tile with any cover names none. _wantCovers
#     queues exactly the named ones.
{
    fresh();
    my $t = $tile->(undef, {}, rg(), []);
    ok(scalar(($t->{_caaWant} // '') eq $CAA), '10: icon tile -> _caaWant is its archive url');
    fresh(); $HELD{ key('') } = 1;
    ok(scalar(!exists $tile->(undef, {}, rg(), [])->{_caaWant}), '10: held cover -> nothing to fetch');
    fresh();
    my $q = { name => 'T', type => 'playlist', _svc => 'Qobuz', _albumid => 'x',
              _cover => 'https://static.qobuz.com/x_600.jpg', favorites_url => 'qobuz://album:x' };
    ok(scalar(!exists $tile->(undef, {}, rg(), [ sec('Qobuz', $q) ])->{_caaWant}),
       '10: source cover -> nothing to fetch');
    my @wanted;
    no warnings qw(redefine once);
    local *Plugins::Discography::Covers::want = sub { push @wanted, $_[0] };
    $B->can('_wantCovers')->([ { _caaWant => 'u1' }, { image => 'x' }, 'not a tile', { _caaWant => 'u2' } ]);
    $B->can('_wantCovers')->(undef);
    ok(scalar("@wanted" eq 'u1 u2'), '10: _wantCovers queues only the tiles that name a cover, in order');
}

# 11. ListenBrainz says which groups the archive has a cover for (0.56.30): a
#     group it marks as having none keeps its icon and is never wanted; a
#     marked or unknown group is wanted as before; a cover the proxy holds
#     still shows, whatever the flag says.
{
    my $id = lc rg()->{mbid};
    fresh();
    my $t = $tile->(undef, {}, rg(), [], { $id => 0 });
    ok(scalar(!exists $t->{_caaWant} && ($t->{image} // '') ne $CAA), '11: flagged no cover -> icon, nothing wanted');
    fresh();
    ok(scalar(($tile->(undef, {}, rg(), [], { $id => 1 })->{_caaWant} // '') eq $CAA), '11: flagged a cover -> wanted');
    fresh();
    ok(scalar(($tile->(undef, {}, rg(), [], { 'other-group' => 0 })->{_caaWant} // '') eq $CAA),
       '11: not in the flags (unknown) -> wanted');
    fresh();
    ok(scalar(($tile->(undef, {}, rg(), [], {})->{_caaWant} // '') eq $CAA), '11: empty flags -> wanted');
    fresh();
    my $up = { %{ rg() }, mbid => uc rg()->{mbid} };
    ok(scalar(!exists $tile->(undef, {}, $up, [], { $id => 0 })->{_caaWant}), '11: the flag is read case-blind');
    fresh(); $HELD{ key('') } = 1;
    ok(scalar(($tile->(undef, {}, rg(), [], { $id => 0 })->{image} // '') eq $CAA),
       '11: held by the proxy -> the cover shows even when flagged none');
}

# 12. The flags come from ListenBrainz's own field and reach the tiles: API's
#     list reader keeps caa_id per group, and the page reads them once.
{
    open my $fh, '<', "$FindBin::Bin/../Discography/API.pm" or die "API.pm: $!";
    my $api = do { local $/; <$fh> };
    ok(scalar(scalar($api =~ /\(\$_->\{caa_id\} \? 1 : 0\)/) && scalar($api =~ /_caaFlagsKey\(\$mbid\), \\%flags/)),
       '12: _lbGroups keeps { group => caa_id ? 1 : 0 } under the artist');
    open $fh, '<', "$FindBin::Bin/../Discography/Browse.pm" or die "Browse.pm: $!";
    my $br = do { local $/; <$fh> };
    ok(scalar(scalar($br =~ /my \$coverFlags = Plugins::Discography::API->peekCoverFlags\(\$mbid\);/)
              && scalar($br =~ /_releaseItem\(\$client, \$opts, \$_->\[0\], \$_->\[1\], \$coverFlags\)/)),
       '12: _buildList reads the flags once and hands them to every tile');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
