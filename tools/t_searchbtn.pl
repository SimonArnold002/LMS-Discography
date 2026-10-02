#!/usr/bin/env perl
#
# REGRESSION TEST: the artist page opens search through a BUTTON (0.54.4+).
#
# Simon, 2026-09-24: the inline search box on the artist page got lost among the
# other rows (and Material drew it inline or as a popup with the page's size).
# The Options section now carries a plain link row, act:search, that opens the
# plugin's HOME page (_rootView), whose search section holds the search
# row. Pinned through the REAL _searchButtonRow / _rootView / _searchRow /
# _findRow / _runRow, plus a source check that the artist page no longer builds
# the search row itself.
#
# Standalone, no LMS install needed:  perl tools/t_searchbtn.pl
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
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Null' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Slim::Utils::Strings::cstring'}   = sub { $_[1] };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Plugins::Discography::Sources::_norm'} = sub {
        my $s = lc($_[-1] // ''); $s =~ s/[^a-z0-9]+/ /g; $s =~ s/^ +| +$//g; $s };
    *{'Plugins::Discography::Sources::orderedSources'} = sub { ({ name => 'Local' }, { name => 'Qobuz' }) };
    # _rootView (the page the button opens) probes the services and MAI.
    *{'Plugins::Discography::Sources::adapters'}      = sub { () };
    *{'Plugins::Discography::Sources::serviceStatus'} = sub { [] };
    *{'Plugins::Discography::Sources::_pluginIcon'}   = sub { undef };
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');
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
  *{"${B}::_coverCollageRow"} = sub { undef }; }   # the random banner reads the library

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

my $opts = { artist_id => 46825, artist => 'Marc Almond', features => 'hi' };

# 1. The button itself: a plain link row, param-addressed like Refresh.
my $btn = $B->can('_searchButtonRow')->(undef, $opts);
ok(scalar($btn->{type} eq 'link'), '1: the button is a link row, not a search box');
ok(scalar($btn->{id} eq 'act:search'), '1: the button has the id act:search');
ok(scalar(!exists $btn->{nextWindow}), '1: the button drills (no nextWindow refresh)');
my $go = $btn->{itemActions}{items};
ok(scalar($go && $go->{command}[0] eq 'discography' && ($go->{fixedParams}{item} // '') eq 'act:search'),
   '1: tap sends item:act:search (param-addressed, no positional walk)');
ok(scalar(($go->{fixedParams}{artist_id} // '') eq '46825'), '1: tap carries the artist identity');
ok(scalar(!exists $btn->{itemActions}{play}), '1: the button has no play action');

# 2. Its page: the plugin's HOME page, identical to the one the Apps menu opens,
#    whose one search row submits param-addressed.
my @page;
$btn->{url}->(undef, sub { @page = @{ $_[0]{items} || [] } }, {}, $btn->{passthrough}[0]);
my @home = @{ ($B->can('_rootView')->(undef, 'hi') || {})->{items} || [] };
ok(scalar(@page && @page == @home), '2: the page is the home page (same rows as the Apps-menu entry)');
ok(scalar(join('|', map { $_->{name} // '' } @page) eq join('|', map { $_->{name} // '' } @home)),
   '2: same rows in the same order as the home page');
ok(scalar(grep { ($_->{name} // '') eq 'PLUGIN_DISCOGRAPHY_ABOUT_HDR' } @page), '2: it carries the About section');
my @srch = grep { ($_->{type} // '') eq 'search' } @page;
ok(scalar(@srch == 1), '2: it holds exactly one search box');
my $sgo = ($srch[0] // {})->{itemActions}{items}{fixedParams} || {};
ok(scalar(($sgo->{search} // '') eq '__TAGGEDINPUT__'), '2: submission sends search:<typed text>');
ok(scalar(!exists $sgo->{item_id} && !exists $sgo->{item}), '2: submission carries no item id');
ok(scalar(($sgo->{features} // '') eq 'hi'), '2: features ride through, so results get real headers');
ok(scalar((($srch[0] // {})->{line2} // '') eq "Local \x{00B7} Qobuz"), '2: line2 still names the sources searched');

# 3. The dispatch _listItemDispatch uses finds and runs it.
{
    my $feed = { items => [ { id => 'act:refresh', url => sub { } }, $btn ] };
    ok(scalar(($B->can('_findRow')->($feed, 'act:search') // {}) == $btn), '3: _findRow locates act:search');
    my @got;
    $B->can('_runRow')->(undef, sub { @got = @{ $_[0]{items} || [] } }, $btn, 'test');
    ok(scalar(@got == @home && grep { ($_->{type} // '') eq 'search' } @got), '3: _runRow opens the home page');
}

# 4. The artist page builds the button, not the search box.
{
    open my $fh, '<', "$FindBin::Bin/../Discography/Browse.pm" or die $!;
    my $src = do { local $/; <$fh> };
    my ($build) = $src =~ /^(sub _buildList \{.*?^\})/ms;
    ok(scalar(defined $build), '4: found _buildList');
    ok(scalar(($build // '') =~ /_searchButtonRow\(/), '4: _buildList adds the search button');
    ok(scalar(($build // '') !~ /_searchRow\(/), '4: _buildList no longer adds the inline search box');
    my ($root) = $src =~ /^(sub _rootView \{.*?^\})/ms;
    ok(scalar(($root // '') =~ /_searchRow\(/), '4: the home page keeps its inline search box');
}

# 5. "FIND AN ARTIST" SITS BETWEEN THE BANNER AND ABOUT (0.56.24; Simon,
#    2026-10-02: "The search needs to be below the banner but above about
#    discography", "needs a header too"). Material focuses an inline search box
#    only as row 0 (browse-page.js `:focus="index==0 && !IS_MOBILE"`), so with
#    its title above it the box is never focused on arrival: by his layout.
#    0.56.31 (Simon: "Search still feels to cramped in ... it needs space and to
#    be more prominent"; he chose the big title): for a client that draws
#    headers, a large title replaces the small header and a small grey line
#    under the box names what a search covers; "Works best with" left the page
#    for the settings page. A client without headers keeps 0.56.25's rows.
sub _kind {
    my ($r) = @_;
    my $n = $r->{name} // '';
    return 'search'  if ($r->{type} // '') eq 'search';
    return 'title'   if $n =~ /^<div style='font-size:1\.5em;[^']*'>PLUGIN_DISCOGRAPHY_SEARCH_HDR<\/div>$/;
    return 'caption' if $n =~ /^<div style='font-size:\.85em;opacity:\.7;[^']*'>MusicBrainz /;
    return $n;
}
sub _shape { map { _kind($_) } @_ }
my $L2 = "Local \x{00B7} Qobuz";
{
    no warnings 'redefine'; no strict 'refs';
    local *{"${B}::_coverCollageRow"} = sub { { name => '<div>covers</div>', type => 'text' } };
    my @wb = @{ $B->can('_rootView')->(undef, 'hi')->{items} };
    my @want = ('<div>covers</div>', 'title', 'search', 'caption', 'PLUGIN_DISCOGRAPHY_ABOUT_HDR');
    ok(scalar(join('|', (_shape(@wb))[0 .. 4]) eq join('|', @want)),
       '5: banner, the big "Find an artist" title, the search box, the grey caption, then the About section');
    ok(scalar(@wb == 7), '5: seven rows: banner, title, box, caption, About header + its two paragraphs (no Works best with)');
    ok(scalar(!grep { ($_->{name} // '') eq 'PLUGIN_DISCOGRAPHY_PLUGINS_HDR' || ($_->{name} // '') =~ /<div title='/ } @wb),
       '5: no "Works best with" header or tile on the home page');
    my ($title, $cap) = @wb[1, 3];
    ok(scalar(($title->{type} // '') eq 'text' && !exists $title->{url} && !exists $title->{image}),
       '5: the title is a dead text row (no url, no image), so Material draws its HTML');
    ok(scalar(($title->{name} // '') =~ /font-size:1\.5em;font-weight:500;/),
       '5: the title sets its own size and an explicit weight (Material draws text rows at 200)');
    ok(scalar(($title->{name} // '') =~ /padding:20px /), '5: space above the title');
    ok(scalar(($cap->{type} // '') eq 'text' && !exists $cap->{url} && !exists $cap->{image}),
       '5: the caption is a dead text row');
    ok(scalar(($cap->{name} // '') =~ /^<div style='[^']*'>MusicBrainz \x{00B7} \Q$L2\E<\/div>$/),
       '5: the caption names MusicBrainz, then the sources in the order line2 gives them');
    ok(scalar(($cap->{name} // '') =~ /padding:4px 0 24px/), '5: the caption leaves a gap before About');
    my @nh = @{ $B->can('_rootView')->(undef, '')->{items} };
    my @old = ('<div>covers</div>', 'PLUGIN_DISCOGRAPHY_SEARCH_HDR', 'search', 'PLUGIN_DISCOGRAPHY_ABOUT_HDR');
    ok(scalar(join('|', (_shape(@nh))[0 .. 3]) eq join('|', @old) && ($nh[1]{type} // '') eq 'text'),
       '5: a client without headers keeps the plain divider, the box, then About (no title, no caption)');
    ok(scalar(!grep { _kind($_) =~ /^(?:title|caption)$/ } @nh), '5: ... and gets no HTML title or caption');
    my ($iH)  = grep { _kind($wb[$_]) eq 'search' } 0 .. $#wb;
    my ($iNH) = grep { _kind($nh[$_]) eq 'search' } 0 .. $#nh;
    ok(scalar(defined $iH && defined $iNH && $iH == 2 && $iNH == 2),
       '5: the box is the same row (third) for both clients, as before');
}
{
    my @rows = @{ $B->can('_rootView')->(undef, 'hi')->{items} };
    ok(scalar(join('|', (_shape(@rows))[0 .. 3]) eq join('|', 'title', 'search', 'caption', 'PLUGIN_DISCOGRAPHY_ABOUT_HDR')),
       '5: a library with no artwork: no banner, the rest in the same order');
}
{
    open my $sf, '<', "$FindBin::Bin/../Discography/strings.txt" or die $!;
    my $str = do { local $/; <$sf> };
    my ($a2) = $str =~ /^PLUGIN_DISCOGRAPHY_ABOUT_2\n\tEN\t([^\n]*)/m;
    ok(scalar(defined $a2 && $a2 =~ /^Search for any artist above,/), '5: the About text points UP at the search');
    ok(scalar($str =~ /^PLUGIN_DISCOGRAPHY_SEARCH_HDR\n\tEN\tFind an artist$/m), '5: the title string is there');
    ok(scalar($str =~ /^PLUGIN_DISCOGRAPHY_ABOUT_HDR\n\tEN\tDiscography$/m),
       '5: the About section is headed "Discography", not "About Discography" (0.56.25, Simon)');
    my ($a1) = $str =~ /^PLUGIN_DISCOGRAPHY_ABOUT_1\n\tEN\t([^\n]*)/m;
    ok(scalar(defined $a1 && index($a1, "Browse an artist's discography - albums, EPs, singles and compilations that are "
        . "listed in MusicBrainz. Each release plays from your local library or, if available, your chosen streaming "
        . "service. Each release displays with artwork, original release dates, reviews and biographies.") == 0),
       "5: the About text opens with Simon's 0.56.31 wording");
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
