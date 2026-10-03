#!/usr/bin/env perl
#
# TEST BUILD 0.56.47: a "Discography" entry in LMS's own search.
#
# Simon, 2026-10-03, on Material's search showing results as you type: "can we
# try and build a test of this to see if it would work". DSC registers a source
# with Slim::Menu::GlobalSearch (the hook Qobuz uses); every LMS search then
# lists a "Discography" entry that opens DSC's artist search for the same words.
#
# What this pins, through the REAL Browse::globalSearchItem / _globalSearchWalk /
# _searchRow / topLevel and the Plugin.pm source:
#   1. the entry: titled with the plugin's name (Material's own list is keyed
#      by the lowercased title), its tap param-addressed exactly like the search
#      box's submission, and NO coderef on the entry itself (0.56.48: one there
#      cost every LMS search list its session id, so every source opened from a
#      search came back Empty), the walk's coderef one row down;
#   2. NOTHING IS SEARCHED at list time (LMS builds the list for every search
#      and every tap into it; Material asks on every pause while typing);
#   3. no words, no entry;
#   4. the words are trimmed;
#   5. UTF-8: characters stay, octets (a walk's item id, Misc::unescape) decode;
#   6. a client that walks in gets the same search, with no features;
#   7. the tap's command reaches the search dispatch with Material's features;
#   8. Plugin::initPlugin registers it.
#
# Standalone, no LMS install needed:  perl tools/t_globalsearch.pl
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
    # Any service search at all is a failure of section 2.
    *{'Plugins::Discography::Sources::searchArtists'} = sub { push @main::SVC, $_[2] };
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');
}

package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}

package main;

our @SVC;       # service searches started (section 2)
our @VIEW;      # _artistSearchView calls, each [args]

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;
my $B = 'Plugins::Discography::Browse';
{ no warnings 'redefine'; no strict 'refs';
  *{"${B}::_artistSearchView"} = sub { push @VIEW, [ @_ ] }; }

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

my $item = sub { my @r = $B->can('globalSearchItem')->(undef, @_); return @r };

# 1. The entry.
my ($e) = $item->({ search => 'Portishead' });
ok(scalar(ref $e eq 'HASH'), '1: a search lists one entry');
ok(scalar(($e->{type} // '') ne 'search'), '1: the entry is not a search box');
# 0.56.48: XMLBrowser gives the WHOLE search list its session id only when no
# top-level item has a ref url (`grep { ref $_->{url} } @{ $feed->{items} }`).
# 0.56.47 had one, and every source opened from an LMS search came back Empty.
ok(scalar(0 == grep { ref $_->{url} } ($e)),
   '1: no code link on the entry itself (the search list keeps its session id)');
ok(scalar(!exists $e->{url} && !exists $e->{passthrough}), '1: no url or passthrough at the top at all');
ok(scalar(ref $e->{items} eq 'ARRAY' && @{ $e->{items} } == 1),
   "1: a walk opens one row (Qobuz's shape: the coderef one level down)");
ok(scalar(($e->{name} // '') eq 'PLUGIN_DISCOGRAPHY'),
   "1: it is titled with the plugin's name (Material's list is keyed by the lowercased title)");
ok(scalar(!exists $e->{nextWindow}), '1: tapping it opens a page (no nextWindow)');
my $go = ($e->{itemActions} || {})->{items} || {};
ok(scalar(join(' ', @{ $go->{command} || [] }) eq 'discography items'),
   '1: the tap is `discography items`, not a walk back through globalsearch');
ok(scalar(($go->{fixedParams}{search} // '') eq 'Portishead'), '1: the tap carries the words');
ok(scalar(join(',', sort keys %{ $go->{fixedParams} || {} }) eq 'search'),
   '1: and nothing else (no item, item_id or features of its own)');
my $box = $B->can('_searchRow')->(undef, { features => '' });
my $bgo = $box->{itemActions}{items};
ok(scalar(join(' ', @{ $bgo->{command} }) eq join(' ', @{ $go->{command} || [] })
          && join(',', sort keys %{ $bgo->{fixedParams} }) eq 'search'),
   "1: the same route as the search box's own submission");
my $row = ($e->{items} || [])->[0] || {};
ok(scalar(ref $row->{url} eq 'CODE' && ($row->{passthrough}[0]{q} // '') eq 'Portishead'),
   "1: that row has the walk's coderef, with the words in its passthrough");
ok(scalar(($row->{name} // '') eq 'ARTISTS' && ($row->{type} // '') eq 'link'),
   '1: the row is an "Artists" link');

# 2. Nothing is searched while the list is built.
@SVC = (); @VIEW = ();
$item->({ search => 'Portishead' }) for 1 .. 3;
$item->({ search => 'Port' });
ok(scalar(@VIEW == 0), '2: building the entry runs no search (4 lists, 0 searches)');
ok(scalar(@SVC == 0), '2: and asks no service');

# 3. No words, no entry.
ok(scalar(!$item->({ search => '' })), '3: an empty search lists nothing');
ok(scalar(!$item->({ search => "  \t " })), '3: blanks list nothing');
ok(scalar(!$item->({})), '3: no search key lists nothing');
ok(scalar(!$item->(undef)), '3: no tags list nothing');
my @two = $item->({ search => 'ab' });
ok(scalar(@two == 1), '3: control: two letters do list it');

# 4. The words are trimmed.
my ($t) = $item->({ search => "  Massive Attack \n" });
ok(scalar(($t->{itemActions}{items}{fixedParams}{search} // '') eq 'Massive Attack'), '4: the tap gets the trimmed words');
ok(scalar(($t->{items}[0]{passthrough}[0]{q} // '') eq 'Massive Attack'), '4: so does a walk');

# 5. UTF-8: characters stay as they are, a walk's octets decode.
{
    my $bjork = "Bj\x{f6}rk";                      # Latin-1 range, no UTF8 flag
    my $flag  = "Bj\x{f6}rk"; utf8::upgrade($flag);  # the same, flagged (JSON's)
    my $jp    = "\x{7c73}\x{6d25}\x{7384}\x{5e2b}";   # 米津玄師
    my $words = sub { (($item->({ search => $_[0] }))[0] || {})->{itemActions}{items}{fixedParams}{search} // '' };
    ok(scalar($words->($bjork) eq $bjork), '5: Björk as unflagged characters is unchanged');
    ok(scalar($words->($flag) eq $bjork), '5: Björk as flagged characters is unchanged');
    ok(scalar($words->($jp) eq $jp), '5: 米津玄師 as characters is unchanged');
    (my $o1 = $bjork) =~ s/^//; utf8::encode($o1);
    (my $o2 = $jp)    =~ s/^//; utf8::encode($o2);
    ok(scalar(length($o1) == 6 && $words->($o1) eq $bjork), '5: Björk as UTF-8 octets (a walk) decodes');
    ok(scalar($words->($o2) eq $jp), '5: 米津玄師 as UTF-8 octets decodes');
}

# 6. A client that walks in: the same search, no features.
@VIEW = ();
my $cb = sub {};
$row->{url}->('client', $cb, { params => { features => 'hi' } }, $row->{passthrough}[0]);
ok(scalar(@VIEW == 1), '6: a walk runs the search once');
ok(scalar(($VIEW[0][3] // '') eq 'Portishead'), '6: for the words in the passthrough');
ok(scalar(defined $VIEW[0][2] && $VIEW[0][2] eq ''), '6: with no features (a walk is handed none)');
ok(scalar(($VIEW[0][1] // 0) == $cb && !defined $VIEW[0][4]), '6: the whole page, to the caller');

# 7. The tap's command, as Material sends it, reaches the search dispatch.
@VIEW = ();
$B->can('topLevel')->('client', sub {}, { params => {
    %{ $go->{fixedParams} }, features => 'hi', menu => 1 } });
ok(scalar(@VIEW == 1 && ($VIEW[0][3] // '') eq 'Portishead'), '7: topLevel dispatches the tap as a search for the words');
ok(scalar(($VIEW[0][2] // '') eq 'hi'), "7: with Material's features (headers and tiles)");
ok(scalar(!defined $VIEW[0][4]), '7: the whole results page');

# 8. Plugin::initPlugin registers it.
{
    open my $fh, '<', "$FindBin::Bin/../Discography/Plugin.pm" or die $!;
    my $src = do { local $/; <$fh> };
    my ($init) = $src =~ /^(sub initPlugin \{.*?^\})/ms;
    ok(scalar(defined $init), '8: found initPlugin');
    ok(scalar(($init // '') =~ /Slim::Menu::GlobalSearch->registerInfoProvider\(\s*discography\s*=>\s*\(\s*func\s*=>\s*\\&Plugins::Discography::Browse::globalSearchItem/),
       '8: initPlugin registers Browse::globalSearchItem as the discography search source');
    ok(scalar(($init // '') =~ /eval \{\s*require Slim::Menu::GlobalSearch;/),
       '8: guarded: an LMS without the global search menu still starts');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
