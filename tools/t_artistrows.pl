#!/usr/bin/env perl
#
# REGRESSION TEST: artist rows are typed 'artist-link' (0.56.29), and WHO gets it.
#
# A row of type 'artist-link' is an artist to Material (Simon's PR #1276): a
# round image, and Material's artist header on the page it opens. The four
# builders of rows that open an artist page send it: search results
# (_searchResultRow), MusicBrainz same-name rows (_mbCandidateRow), Also a
# member of (_bandLinkRow) and Similar artists (_similarLinkRow). Only to a
# Material that has the type (6.4.10.9, Simon's test build, and up) AND a
# client that draws headers (features:h); everything else keeps 'link'. Never
# 'artist': Material offers Play on an 'artist' row whose go action carries
# `artist` or an id, and every one of ours does. Pinned through the REAL
# builders and _materialAtLeast.
#
# Standalone, no LMS install needed:  perl tools/t_artistrows.pl
# (re-runs itself once for each other Material version in %LINKS)
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
    # The installed Material's version decides _useArtistLinks and _useStrips
    # (each cached per process), so each run fixes it up front.
    $INC{'Plugins/MaterialSkin/Plugin.pm'} = 1;
    *{'Plugins::MaterialSkin::Plugin::getPluginVersion'} = sub { $ENV{T_MATERIAL_VER} // '6.4.10.9' };
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::PluginManager::isEnabled'} = sub { 1 };   # MAI on: the proxy image route
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Null' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Plugins::Discography::API::peekArtistAliases'} = sub { [] };
    *{'Plugins::Discography::Sources::orderedAdapters'} = sub { () };
    *{'Slim::Utils::Strings::cstring'}   = sub { $_[1] };   # returns the token
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
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

my $ver = $ENV{T_MATERIAL_VER} // '6.4.10.9';
# Which Material versions draw 'artist-link', written out rather than derived
# from the rule under test: Simon's test build 6.4.10.9 (upstream b652e87b1) is
# the first; 6.4.10.8, the rig's build before it, has the strips but not this.
# The numeric rows fail a string compare (6.4.10.10 > 6.4.10.9, 6.10.0 > 6.4.x).
my %LINKS = (
    '6.4.10.9' => 1, '6.4.10.10' => 1, '6.4.11'  => 1, '6.4.11.1' => 1,
    '6.5.0'    => 1, '6.10.0'    => 1, '7.0.0'   => 1,
    '6.4.10.8' => 0, '6.4.10.1'  => 0, '6.4.10'  => 0, '6.4.9.9'  => 0,
    '6.3.0'    => 0, 'DEVELOPMENT' => 0, ''      => 0,
);
die "t_artistrows: no expected answer for Material '$ver'\n" unless exists $LINKS{$ver};
my $on = $LINKS{$ver};

my %build = (
    'search result'   => sub { $B->can('_searchResultRow')->(undef, { name => 'Adele', sources => ['Qobuz'] }, $_[0]) },
    'same-name row'   => sub { $B->can('_mbCandidateRow')->(undef, { mbid => 'cc2c9c3c-b7bc-4b8b-84d8-4fbd8779e493',
                                                                     name => 'Adele', type => 'Person' }, $_[0], 1) },
    'member-of row'   => sub { $B->can('_bandLinkRow')->(undef, { features => $_[0] },
                                                         { name => 'Band Aid 30', mbid => 'b2b2b2b2-0000-4000-8000-000000000030' }) },
    'similar row'     => sub { $B->can('_similarLinkRow')->(undef, { features => $_[0] }, 'Adele') },
);

my $want = $on ? 'artist-link' : 'link';
for my $kind (sort keys %build) {
    my $hdr = $build{$kind}->('hi');
    ok(scalar(($hdr->{type} // '') eq $want), "[$ver] $kind, header client: type '$want'");
    for my $f (undef, '', 'i') {
        my $r = $build{$kind}->($f);
        ok(scalar(($r->{type} // '') eq 'link'),
           "[$ver] $kind, client without headers (" . (defined $f ? "'$f'" : 'undef') . "): type 'link'");
    }
    # Only the type changes: the row still opens the artist the same way.
    my $plain = $build{$kind}->(undef);
    ok(scalar(($hdr->{name} // '') eq ($plain->{name} // '') && ($hdr->{image} // '') eq ($plain->{image} // '')
              && ref $hdr->{url} eq 'CODE'
              && join(',', @{ $hdr->{itemActions}{items}{command} || [] }) eq 'discography,items'),
       "[$ver] $kind: name, image, url and go action as before");
    ok(scalar(($hdr->{type} // '') ne 'artist'), "[$ver] $kind: never type 'artist' (Material would offer Play)");
}

# The two gates are separate: the rig's 6.4.10.8 has strips but not artist rows.
ok(scalar(!!$B->can('_useArtistLinks')->() == !!$on), "[$ver] _useArtistLinks follows the table");
if ($ver eq '6.4.10.8') {
    ok(scalar($B->can('_useStrips')->() && !$B->can('_useArtistLinks')->()),
       "[$ver] strips on, artist rows off (separate caches)");
}

# Re-run once per other version in %LINKS.
if (!defined $ENV{T_MATERIAL_VER}) {
    for my $v (sort grep { $_ ne $ver } keys %LINKS) {
        local $ENV{T_MATERIAL_VER} = $v;
        local $ENV{T_CHILD} = 1;
        my $out = `$^X "$0"`;
        print $out;
        $pass += () = $out =~ /^ok   - /mg;
        $fail += () = $out =~ /^FAIL - /mg;
        $fail++ if $? && $out !~ /^FAIL - /m;
    }
}

print "\n", ($fail ? "FAILED" : "PASS"), ": $pass passed, $fail failed\n" unless $ENV{T_CHILD};
exit($fail ? 1 : 0);
