#!/usr/bin/env perl
#
# REGRESSION TEST: "Works best with" is ONE strip of tiles (after 0.54.5), and
# since 0.56.31 the SETTINGS page's first section, not the home page's last.
#
# Simon, 2026-09-24: five stacked status rows took too much of the screen. Now
# one wrapping flex strip; each tile = the plugin's badge + name + tick/cross,
# the role only as the tile's tooltip (his pick), a not-installed plugin dimmed
# with a grey placeholder badge. Simon, 2026-10-02: "the works best with needs
# to move to the settings page at the top". Pinned through the REAL
# worksBestStrip, _rootView, Settings::beforeRender and settings.html.
#
# Standalone, no LMS install needed:  perl tools/t_worksbest.pl
#
use strict;
use warnings;
use FindBin;

our %ENABLED;

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache Slim::Web::Settings
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
    *{'Slim::Web::Settings::beforeRender'} = sub { };   # Settings.pm's base class (section 5)
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

sub strip { $B->can('worksBestStrip')->(undef, @_) }
# Split the strip's HTML into its tiles (each opens with a title attribute).
sub tiles { my ($html) = @_; my @t = split /(?=<div title=')/, $html; shift @t; @t }

%ENABLED = ('Plugins::MusicArtistInfo::Plugin' => 1, 'Plugins::MaterialSkin::Plugin' => 0);
my $html = strip() // '';

# 1. One strip, its margin the caller's.
ok(scalar($html =~ /^<div style='display:flex;flex-wrap:wrap;gap:12px 8px;margin:12px 8px 12px 16px'>/),
   '1: one wrapping flex strip (default margin)');
ok(scalar((strip('8px 0 4px') // '') =~ /^<div style='display:flex;flex-wrap:wrap;gap:12px 8px;margin:8px 0 4px'>/),
   "1: the caller's margin is used");

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

# 4. Material enabled flips its tile.
%ENABLED = ('Plugins::MusicArtistInfo::Plugin' => 1, 'Plugins::MaterialSkin::Plugin' => 1);
my %by2 = map { my ($n) = /<div>([^<]*?) <span/; (($n // '') => $_) } tiles(strip());
ok(scalar(($by2{'Material Skin'} // '') =~ m{&#10003;} && ($by2{'Material Skin'} // '') =~ m{src='/material/html/images/icon\.png'}),
   "4: Material enabled -> tick + the skin's own icon");

# 5. WHERE IT SHOWS (0.56.31): the settings page's first section, not the home page.
{
    my @home = @{ $B->can('_rootView')->(undef, 'hi')->{items} };
    ok(scalar(!grep { ($_->{name} // '') eq 'PLUGIN_DISCOGRAPHY_PLUGINS_HDR' || ($_->{name} // '') =~ /<div title='/ } @home),
       '5: the home page no longer carries it');
    require "$FindBin::Bin/../Discography/Settings.pm";
    my %p;
    Plugins::Discography::Settings->beforeRender(\%p, undef);
    ok(scalar(defined $p{dsc_works_best} && $p{dsc_works_best} eq strip('8px 0 4px')),
       '5: beforeRender hands the settings page the same strip (settings margin)');
    {
        no warnings 'redefine'; no strict 'refs';
        local *{"${B}::worksBestStrip"} = sub { die "probe failed\n" };
        my %q;
        my $ok = eval { Plugins::Discography::Settings->beforeRender(\%q, undef); 1 };
        ok(scalar($ok && defined $q{dsc_works_best} && $q{dsc_works_best} eq '' && ref $q{dsc_types} eq 'ARRAY'),
           '5: a failing strip leaves it empty and the rest of the page is still prepared');
    }
    my $tpl = do { local (@ARGV, $/) = ("$FindBin::Bin/../Discography/HTML/EN/plugins/Discography/settings.html"); <> };
    my $iWorks = index($tpl, 'id="dsc_works_Header"');
    my $iFirst = index($tpl, 'class="prefHead');
    ok(scalar($iWorks > 0 && $iWorks == index($tpl, 'id=', $iFirst) && $iFirst < index($tpl, 'id="dsc_sources_Header"')),
       '5: settings.html: "Works best with" is the first section, above Sources');
    ok(scalar($tpl =~ /\[% IF dsc_works_best %\]\s*<div class="prefHead collapsableSection" id="dsc_works_Header">\[% "PLUGIN_DISCOGRAPHY_PLUGINS_HDR" \| string %\]<\/div>\s*<div id="dsc_works">\s*\[% dsc_works_best %\]\s*<\/div>\s*\[% END %\]/),
       '5: settings.html: the section is the strip under its header, dropped when empty');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
