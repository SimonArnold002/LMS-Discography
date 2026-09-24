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

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
