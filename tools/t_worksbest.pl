#!/usr/bin/env perl
#
# REGRESSION TEST: the home page's "Works best with" section is ONE row holding a
# strip of tiles (after 0.54.5).
#
# Simon, 2026-09-24: five stacked status rows took too much of the screen. Now a
# single dead text row whose HTML is a wrapping flex strip; each tile = the
# plugin's badge + name + tick/cross, the role only as the tile's tooltip (his
# pick), a not-installed plugin dimmed with a grey placeholder badge. Pinned
# through the REAL _rootView.
#
# Standalone, no LMS install needed:  perl tools/t_worksbest.pl
#
use strict;
use warnings;
use FindBin;

our %ENABLED;

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
    # Role strings with a quote in them, so the tooltip escaping is exercised.
    *{'Slim::Utils::Strings::cstring'}   = sub {
        my $t = $_[1];
        return "Streaming 'source'" if $t eq 'PLUGIN_DISCOGRAPHY_ROLE_STREAM';
        return 'not installed'      if $t eq 'PLUGIN_DISCOGRAPHY_SVC_NOT_DETECTED';
        return $t };
    *{'Slim::Utils::PluginManager::isEnabled'} = sub { $main::ENABLED{ $_[1] } ? 1 : 0 };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Plugins::Discography::Sources::_norm'} = sub {
        my $s = lc($_[-1] // ''); $s =~ s/[^a-z0-9]+/ /g; $s =~ s/^ +| +$//g; $s };
    *{'Plugins::Discography::Sources::orderedSources'} = sub { ({ name => 'Local' }, { name => 'Qobuz' }) };
    *{'Plugins::Discography::Sources::adapters'} = sub {
        ({ name => 'Qobuz', icon => 'plugins/Qobuz/html/images/icon.png' }) };
    *{'Plugins::Discography::Sources::serviceStatus'} = sub {
        [ { name => 'Qobuz', installed => 1 }, { name => 'Tidal', installed => 0 },
          { name => 'Deezer', installed => 0 }, { name => 'Spotify', installed => 0 } ] };
    *{'Plugins::Discography::Sources::_pluginIcon'} = sub { 'https://www.herger.net/slim-plugins/icons/mai.svg' };
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
  *{"${B}::_coverCollageRow"} = sub { undef }; }

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

sub section {
    my @items = @{ $B->can('_rootView')->(undef, 'hi')->{items} };
    my ($h) = grep { ($items[$_]{name} // '') eq 'PLUGIN_DISCOGRAPHY_PLUGINS_HDR' } 0 .. $#items;
    return (\@items, $h);
}
# Split the strip's HTML into its tiles (each opens with a title attribute).
sub tiles { my ($html) = @_; my @t = split /(?=<div title=')/, $html; shift @t; @t }

%ENABLED = ('Plugins::MusicArtistInfo::Plugin' => 1, 'Plugins::MaterialSkin::Plugin' => 0);
my ($items, $h) = section();

# 1. One row, not five, and it is the page's last row.
ok(scalar(defined $h), '1: the Works best with header is there');
ok(scalar(defined $h && $h == $#$items - 1), '1: exactly ONE row follows the header (was five)');
my $row = $items->[-1];
ok(scalar(($row->{type} // '') eq 'text'), '1: that row is a dead text row');
ok(scalar(!exists $row->{image} && !exists $row->{url}), '1: no image, no url (stays display-only)');
my $html = $row->{name} // '';
ok(scalar($html =~ /display:flex;flex-wrap:wrap/), '1: the tiles wrap (flex-wrap), one strip');

# 2. The tiles.
my @t = tiles($html);
ok(scalar(@t == 6), '2: six tiles: Qobuz, Tidal, Deezer, Spotify, MAI, Material Skin');
my %by = map { my ($n) = /<div>([^<]*?) <span/; (($n // '') => $_) } @t;
ok(scalar(join(',', sort keys %by) eq join(',', sort ('Qobuz', 'Tidal', 'Deezer', 'Spotify', 'Music &amp; Artist Information', 'Material Skin'))),
   '2: each tile names its plugin (HTML-escaped)');
ok(scalar(($by{Qobuz} // '') =~ /&#10003;/ && ($by{Qobuz} // '') !~ /opacity:\.55/), '2: installed -> tick, not dimmed');
ok(scalar(($by{Qobuz} // '') =~ m{<img src='/plugins/Qobuz/html/images/icon\.png'}), '2: installed -> its own badge, root-anchored');
ok(scalar(($by{Tidal} // '') =~ /&#10007;/ && ($by{Tidal} // '') =~ /opacity:\.55/), '2: not installed -> cross, dimmed');
ok(scalar(($by{Tidal} // '') !~ /<img/ && ($by{Tidal} // '') =~ /background:rgba\(128,128,128/),
   '2: not installed -> grey placeholder badge');
ok(scalar(($by{'Music &amp; Artist Information'} // '') =~ m{src='/imageproxy/https%3A%2F%2Fwww\.herger\.net}),
   '2: a remote icon still goes through the imageproxy');
ok(scalar(($by{'Material Skin'} // '') =~ /&#10007;/), '2: Material Skin disabled -> cross');
ok(scalar(($by{Spotify} // '') =~ /&#10007;/ && ($by{Spotify} // '') =~ /opacity:\.55/),
   '2: Spotify (Spotty not installed) -> cross, dimmed, like any missing service');
# The stub above mirrors the REAL list; pin that it does, or this suite could drift from it.
{
    my $src = do { local (@ARGV, $/) = ("$FindBin::Bin/../Discography/Sources.pm"); <> };
    my ($known) = $src =~ /my \@known = \((.*?)\);/s;
    ok(scalar(($known // '') =~ /'spotify', 'Spotify'/), "2: Sources::serviceStatus's real list includes Spotify");
}

# 3. The role is the tooltip, escaped for a single-quoted attribute.
ok(scalar(($by{Qobuz} // '') =~ m{^<div title='Streaming &#39;source&#39;'}), '3: tooltip = the role, quotes escaped');
ok(scalar(($by{Tidal} // '') =~ m{^<div title='Streaming &#39;source&#39; \x{00B7} not installed'}),
   "3: a missing plugin's tooltip adds 'not installed'");
ok(scalar($html !~ /Streaming 'source'/), '3: no unescaped quote reaches the markup');
ok(scalar(!grep { m{<div style='opacity:\.7'>} } @t), '3: no visible role line under the name');

# 4. Material enabled flips its tile; nothing above the section moves.
%ENABLED = ('Plugins::MusicArtistInfo::Plugin' => 1, 'Plugins::MaterialSkin::Plugin' => 1);
my ($items2, $h2) = section();
my %by2 = map { my ($n) = /<div>([^<]*?) <span/; (($n // '') => $_) } tiles($items2->[-1]{name});
ok(scalar(($by2{'Material Skin'} // '') =~ m{&#10003;} && ($by2{'Material Skin'} // '') =~ m{src='/material/html/images/icon\.png'}),
   "4: Material enabled -> tick + the skin's own icon");
ok(scalar($h2 == $h && join('|', map { $_->{name} // '' } @$items2[0 .. $h2])
                   eq join('|', map { $_->{name} // '' } @$items[0 .. $h])),
   '4: every row up to the header is unchanged');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
