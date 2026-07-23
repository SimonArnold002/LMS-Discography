#!/usr/bin/env perl
#
# Run owned/candidate album titles through the plugin's REAL matcher against
# each artist's REAL MusicBrainz spine, and say which rule (if any) claimed
# them. Reads sweep/spines.json from tools/spine_fetch.py.
#
# WHY THIS EXISTS: it is the difference between "I think the matcher rejects
# this" and knowing. It loads Sources.pm itself, so every verdict is the
# shipped code's own -- including the release-group ALIAS pass (0.48.0) and the
# type filter, both reported separately so a "miss" can be told apart from a
# match that is merely HIDDEN.
#
# TWO HARNESS BUGS THAT PRODUCED CONFIDENT NONSENSE, both fixed here and worth
# knowing before writing another one of these (2026-07-22):
#   - the argument order is (artistNorm, albumNorm, candArtist, candTitle,
#     albumRaw) -- the SPINE title is the pre-NORMALISED second arg and the
#     owned album is the CANDIDATE. Getting it backwards reported NO MATCH for
#     everything, including albums that plainly match.
#   - an mbid hand-retyped from a truncated 8-char display 404'd. Never
#     reconstruct an mbid from a shortened one.
#
# Usage:  perl tools/spine_match.pl [sweep/spines.json]
#
use strict;
use warnings;
use FindBin;

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers
                  Slim::Control::Request Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}          = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Prefs' };
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    push @{'Slim::Utils::Log::ISA'},   'Exporter';
    push @{'Slim::Utils::Prefs::ISA'}, 'Exporter';
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
}
package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Prefs; sub get { 1 } sub set { 1 } sub init { 1 }

package main;
use JSON::PP;
use File::Temp ();
binmode STDOUT, ':utf8';

my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
my $M = \&Plugins::Discography::Sources::_albumMatches;
my $A = \&Plugins::Discography::Sources::_aliasMatches;
my $N = \&Plugins::Discography::Sources::_norm;

my $file = shift || "$FindBin::Bin/../sweep/spines.json";
die "no such file: $file\n(run tools/spine_fetch.py first)\n" unless -e $file;
my $data = decode_json(do { local $/; open my $fh, '<', $file or die "$file: $!"; <$fh> });

# The browse list hides these secondary types (%HIDE_SECONDARY), so a match
# against one is real but invisible -- a different thing from a miss.
my %HIDE = (Remix => 1, 'DJ-mix' => 1);

my %tally;
for my $artist (sort { lc $a cmp lc $b } keys %$data) {
    my $d = $data->{$artist};
    my $an = $N->($artist);
    for my $owned (@{ $d->{albums} || [] }) {
        my (@hit, @via_alias);
        for my $rg (@{ $d->{rgs} }) {
            my $hidden = grep { $HIDE{$_} } @{ $rg->{sec} || [] };
            my $label  = sprintf('%s [%s%s]%s', $rg->{title}, $rg->{type} // '?',
                                 (@{ $rg->{sec} || [] } ? '/' . join('+', @{ $rg->{sec} }) : ''),
                                 $hidden ? '  <-- HIDDEN by the type filter' : '');
            if ($M->($an, $N->($rg->{title}), $artist, $owned, $rg->{title})) {
                push @hit, $label;
                next;
            }
            for my $al (@{ $rg->{al} || [] }) {
                next unless $A->($an, $N->($al), $al, $artist, $owned);
                push @via_alias, "$label   (via alias \"$al\")";
                last;
            }
        }
        my $verdict = @hit      ? ($hit[0] =~ /HIDDEN/ ? 'HIDDEN' : 'MATCH')
                    : @via_alias ? 'ALIAS'
                    : !$d->{mbid} ? 'NO-MB-ARTIST'
                    :               'NOMATCH';
        $tally{$verdict}++;
        printf "%-12s %-24s %-44s -> %s\n", $verdict, substr($artist, 0, 23),
               substr($owned, 0, 42),
               @hit ? $hit[0] : @via_alias ? $via_alias[0] : 'nothing in the spine';
        printf "%-12s %-24s %-44s    also: %s\n", '', '', '', $_ for @hit[1 .. $#hit];
    }
}
print "\n";
printf "%-14s %s\n", $_, $tally{$_} for sort keys %tally;
print "\nMATCH = claimed and visible | HIDDEN = claimed but the type filter hides the tile\n"
    . "ALIAS = claimed only via an MB release-group alias (0.48.0)\n"
    . "NOMATCH = the shipped matcher rejects every release group in the spine\n";
