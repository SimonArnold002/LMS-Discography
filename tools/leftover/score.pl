#!/usr/bin/env perl
#
# Leftover replay, step 6: score each owned leftover against its shortlisted
# groups' ListenBrainz tracklists, and print every component so the weights and
# the threshold can be chosen by looking at real cases.
#
# Components (all 0..1):
#   title  - share of the owned title's words in the group's best title variant
#            (title / alias / edition), artist-name words and "the/a/of/and/s"
#            aside: 0.75 x owned-side coverage + 0.25 x group-side coverage
#   w      - Sources::_titleWeight of the owned title (0.5 generic or self-titled)
#   found  - share of YOUR tracks on the group's tracklist      (frac_o)
#   cover  - share of THE GROUP's tracks in your copy           (frac_g)
#   dur    - share of the paired tracks within max(4 s, 4%) of each other
#            (unknown when your copy has no durations)
# Track titles: Sources::_norm after dropping a " - Remastered 2009"-style tail.
#
# Usage:  perl tools/leftover/score.pl [--all] [holdout.json]
#
use strict;
use warnings;
use FindBin;

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers Slim::Utils::Strings
                  Slim::Control::Request Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Null' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs)) { push @{"${e}::ISA"}, 'Exporter' }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
}
package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}

package main;
use JSON::PP;
use File::Temp ();
use List::Util qw(max);
binmode STDOUT, ':utf8';

my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
my $N = \&Plugins::Discography::Sources::_norm;

my $dir = "$FindBin::Bin/../../sweep/leftover";
sub slurp { my $f = shift; decode_json(do { local $/; open my $fh, '<', $f or die "$f: $!"; <$fh> }) }
my ($src) = grep { /\.json$/ } @ARGV;
my $left = slurp("$dir/" . ($src // 'leftovers.json'));
my $lb   = slurp("$dir/lb.json");
my $lib  = slurp("$dir/library.json");
if (-e "$dir/synthetic.json") {
    my $syn = slurp("$dir/synthetic.json");
    $lib->{tracks}{$_} = $syn->{tracks}{$_} for keys %{ $syn->{tracks} };
}
my $all = grep { $_ eq '--all' } @ARGV;

my $TAIL = qr/remaster|version|mix|edit|mono|stereo|live|demo|take|single|bonus|acoustic|instrumental|session/i;
sub tnorm {
    my $t = shift // '';
    $t =~ s/\s+[-\x{2013}\x{2014}]\s+(.*)$// if $t =~ /\s[-\x{2013}\x{2014}]\s+.*$TAIL/;
    return $N->($t);
}

sub tracks_feat {
    my ($own, $grp) = @_;
    my @o = map { [ tnorm($_->{title}), $_->{dur} || 0 ] } @$own;
    my @g = map { [ tnorm($_->[0]), ($_->[1] || 0) / 1000 ] } @$grp;
    my (%used, @pairs);
    for my $x (@o) {
        next unless length $x->[0];
        my $hit;
        for my $i (0 .. $#g) {
            next if $used{$i};
            if ($g[$i][0] eq $x->[0]) { $hit = $i; last }
        }
        unless (defined $hit) {
            for my $i (0 .. $#g) {
                next if $used{$i} || !length $g[$i][0];
                if (index($g[$i][0], "$x->[0] ") == 0 || index($x->[0], "$g[$i][0] ") == 0) { $hit = $i; last }
            }
        }
        next unless defined $hit;
        $used{$hit} = 1;
        push @pairs, [ $x->[1], $g[$hit][1] ];
    }
    my $m = @pairs;
    my @timed = grep { $_->[0] > 0 && $_->[1] > 0 } @pairs;
    my $close = grep { abs($_->[0] - $_->[1]) <= max(4, 0.04 * $_->[1]) } @timed;
    return { n_o => scalar @o, n_g => scalar @g, m => $m, timed => scalar @timed,
             found => @o ? $m / @o : 0, cover => @g ? $m / @g : 0,
             dur => @timed ? $close / @timed : undef };
}

# PROPOSED RULE v1 (2026-10-08, to be agreed):
#   tracks agree  = found >= 0.9, or cover >= 0.9 with found >= 0.6 (a bonus-track
#                   edition either way), and paired durations >= 0.8 where known;
#   score         = 0.7 x track + 0.3 x title x w, where
#                   track = (2 x found + cover) / 3 x (0.5 + 0.5 x dur, 1 when unknown);
#   auto match    = the best passing candidate scores >= 0.75 AND beats every other
#                   passing candidate by >= 0.1; otherwise none (the manual list).
sub verdict_of {
    my ($c, $w) = @_;
    my $f = $c->{tf} or return (0, 0);
    my $agree = ($f->{found} >= 0.9 || ($f->{cover} >= 0.9 && $f->{found} >= 0.6))
             && (!defined $f->{dur} || $f->{dur} >= 0.8);
    my $track = (2 * $f->{found} + $f->{cover}) / 3 * (defined $f->{dur} ? 0.5 + 0.5 * $f->{dur} : 1);
    return ($agree ? 1 : 0, 0.7 * $track + 0.3 * $c->{tscore} * $w);
}

# RULE v2 (after the holdout, 2026-10-08): v1 matched 166 albums to the WRONG group
# with their real one hidden - two-album sets ("Raintown / When the World Knows
# Your Name": found 1.00, cover 0.5) and live / demo versions whose ListenBrainz
# tracks carry no length (unknown durations passed). So:
#   tracks agree = found >= 0.65 AND cover >= 0.65 (both ways: neither side much bigger),
#                  durations KNOWN for >= 80% of the paired tracks and >= 0.8 of those agree;
#   score, threshold and margin as v1.
sub verdict_v2 {
    my ($c, $w) = @_;
    my $f = $c->{tf} or return (0, 0);
    my $agree = $f->{found} >= 0.65 && $f->{cover} >= 0.65
             && $f->{m} && $f->{timed} >= 0.8 * $f->{m} && ($f->{dur} // 0) >= 0.8;
    my $track = (2 * $f->{found} + $f->{cover}) / 3 * (0.5 + 0.5 * ($f->{dur} // 0));
    return ($agree ? 1 : 0, 0.7 * $track + 0.3 * $c->{tscore} * $w);
}
# RULE v3: v2's nine holdout matches were mostly the GROUP holding more than the
# album ("Abandoned Shopping Trolley Hotline / Machismo EP", "songs and
# instrumentals"). Your copy may hold extras (an Expanded edition: the Furs,
# found 0.69); the group may not: cover >= 0.9, found >= 0.65.
sub verdict_v3 {
    my ($c, $w) = @_;
    my ($agree, $score) = verdict_v2(@_);
    my $f = $c->{tf} or return (0, 0);
    return (($agree && $f->{cover} >= 0.9) ? 1 : 0, $score);
}
my $RULE = (grep { $_ eq '--v1' } @ARGV) ? \&verdict_of
         : (grep { $_ eq '--v2' } @ARGV) ? \&verdict_v2 : \&verdict_v3;

my @rows;
for my $x (@$left) {
    next if $x->{artist} eq 'Various Artists';
    my $own = $lib->{tracks}{ $x->{album_id} } || [];
    my @sc;
    for my $c (@{ $x->{cands} }) {
        my $t = $lb->{ $c->{mbid} };
        my $f = $t ? tracks_feat($own, $t->{tracks}) : undef;
        push @sc, { %$c, tf => $f };
    }
    for my $c (@sc) { @$c{qw(agree score)} = $RULE->($c, $x->{weight}) }
    my @pass = sort { $b->{score} <=> $a->{score} } grep { $_->{agree} } @sc;
    my $v = !@pass ? 'none'
          : ($pass[0]{score} >= 0.75 && (@pass == 1 || $pass[0]{score} - $pass[1]{score} >= 0.1)) ? 'MATCH'
          : 'MANUAL';
    push @rows, { %$x, scored => \@sc, n_own => scalar @$own, verdict => $v,
                  pick => ($v eq 'MATCH' ? $pass[0]{title} . ' (' . substr($pass[0]{date} // '', 0, 4) . ')' : undef),
                  passing => scalar @pass };
}

for my $r (@rows) {
    next unless $all || @{ $r->{scored} };
    printf "\n%s  -  %s  (%d tracks%s, w %.1f)%s%s\n", $r->{artist}, $r->{title}, $r->{n_own},
        ($r->{tagged} ? ', tagged' : ''), $r->{weight}, ($r->{synthetic} ? "   [SYNTHETIC: $r->{synthetic}]" : ''),
        ($r->{real} ? '   [REAL GROUP HIDDEN: ' . join('; ', @{ $r->{real} }) . ']' : '');
    for my $c (@{ $r->{scored} }) {
        my $f = $c->{tf};
        printf "   title %.2f%s  %s  %-58s %s\n", $c->{tscore}, ($c->{prefix} ? 'P' : ' '),
            ($f ? sprintf('found %.2f cover %.2f (%2d/%2d of %2d) dur %s', $f->{found}, $f->{cover},
                          $f->{m}, $f->{n_o}, $f->{n_g}, defined $f->{dur} ? sprintf('%.2f', $f->{dur}) : ' -  ')
                : sprintf('%-45s', 'no tracklist')),
            substr("$c->{title} [" . join('/', grep { length } $c->{type}, @{ $c->{secondary} || [] }) . "] "
                   . substr($c->{date} // '', 0, 4), 0, 58),
            ($c->{via} ne 'title' ? "via $c->{via}" : '');
    }
}

print "\n\nVERDICTS (rule " . ($RULE == \&verdict_of ? 'v1' : $RULE == \&verdict_v2 ? 'v2' : 'v3') . ")\n";
my %n;
for my $r (sort { $a->{verdict} cmp $b->{verdict} || $a->{artist} cmp $b->{artist} } @rows) {
    $n{ $r->{verdict} }++;
    next if $r->{verdict} eq 'none' && !@{ $r->{scored} } && !$all;
    my ($top) = sort { $b->{score} <=> $a->{score} } @{ $r->{scored} };
    printf "  %-7s %-24s %-46s %s\n", $r->{verdict}, substr($r->{artist}, 0, 24), substr($r->{title}, 0, 46),
        $r->{pick} ? "-> $r->{pick}  [" . sprintf('%.2f', $top->{score}) . ']'
      : $top ? sprintf('best %.2f (%s), %d passing', $top->{score}, substr($top->{title}, 0, 30), $r->{passing}) : '';
}
printf "\n  %s: %d\n", $_, $n{$_} for sort keys %n;

open my $fh, '>', "$dir/scored" . ($src ? "-$src" : '.json') or die $!;
print $fh JSON::PP->new->utf8->canonical->encode(\@rows);
close $fh;
