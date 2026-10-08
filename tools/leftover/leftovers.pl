#!/usr/bin/env perl
#
# Leftover replay, step 4: which owned albums no group claims TODAY, through the
# plugin's REAL code (Sources::claimedLocalIds, Browse::_editionTitles,
# Sources::_norm / _artistMatch / _titleWeight), and for each of the artist's
# OWN leftovers ("Also in your library", not Appearances) a title shortlist of
# the groups the page shows. Step 5 fetches those groups' tracklists.
#
# Replayed as the page draws it for a library Artists row (explicit artist_id):
#   - the claim pool = every group but the hidden types (Browse, "Also in your
#     library"), bootleg-only groups included;
#   - aliases pruned as API::_pruneAliases does (one another group owns: dropped);
#   - the release map + edition titles from the bootleg check's reply;
#   - an owned copy's release id from the July tags (july_tags.json), by title.
# Candidates for the new pass: groups the page SHOWS (not hidden, not
# bootleg-only), sharing at least one title word with the owned album.
#
# Usage:  perl tools/leftover/leftovers.pl [--holdout]
# Output: sweep/leftover/leftovers.json + a summary on stdout
#
use strict;
use warnings;
use FindBin;

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers Slim::Utils::Strings
                  Slim::Control::Request Slim::Schema Slim::Web::HTTP
                  Slim::Networking::SimpleAsyncHTTP Slim::Utils::Misc
                  Plugins::Discography::Plugin Plugins::Discography::API)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Null' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Slim::Utils::Strings::cstring'}   = sub { $_[1] };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');
}
package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}
package T::Prefs; our $AUTOLOAD; sub get { 1 } sub AUTOLOAD { return } sub DESTROY {}

package main;
use JSON::PP;
use File::Temp ();
binmode STDOUT, ':utf8';

my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
require Plugins::Discography::Browse;
my $S = 'Plugins::Discography::Sources';
my $B = 'Plugins::Discography::Browse';
my $N = \&Plugins::Discography::Sources::_norm;

my $dir = "$FindBin::Bin/../../sweep/leftover";
sub slurp { my $f = shift; decode_json(do { local $/; open my $fh, '<', $f or die "$f: $!"; <$fh> }) }
my $lib    = slurp("$dir/library.json");
my $tags   = slurp("$dir/july_tags.json");
my $spines = slurp("$dir/spines.json");
my $who    = $spines->{_who} || {};
# Cases from outside Simon's library (a tester's copy), labelled in the report.
if (-e "$dir/synthetic.json") {
    my $syn = slurp("$dir/synthetic.json");
    push @{ $lib->{artists} }, @{ $syn->{artists} };
    $lib->{tracks}{$_} = $syn->{tracks}{$_} for keys %{ $syn->{tracks} };
}

# API::_pruneAliases, line for line (API.pm is stubbed out here).
sub prune_aliases {
    my ($all) = @_;
    my %owners;
    push @{ $owners{ $N->($_->{title}) } }, $_->{mbid} for @$all;
    for my $rg (grep { $_->{aliases} } @$all) {
        my @keep = grep { my $own = $owners{ $N->($_) } || []; !grep { $_ ne $rg->{mbid} } @$own }
                   @{ $rg->{aliases} };
        if (@keep) { $rg->{aliases} = \@keep } else { delete $rg->{aliases} }
    }
}

my %STOP = map { $_ => 1 } qw(the a an of and s);
sub toks { grep { length && !$STOP{$_} } split / /, $_[0] }

# Title evidence for owned norm $o against one group title variant $g.
sub title_feat {
    my ($o, $g, $an, $oraw, $graw) = @_;
    my %art = map { $_ => 1 } toks($an);
    my @a = grep { !$art{$_} } toks($o); @a = toks($o) unless @a;
    my @b = grep { !$art{$_} } toks($g); @b = toks($g) unless @b;
    return undef unless @a && @b;
    my %bs = map { $_ => 1 } @b;
    my %as = map { $_ => 1 } @a;
    my $common = grep { $bs{$_} } keys %as;
    return undef unless $common;
    my $covO = $common / scalar(keys %as);
    my $covG = $common / scalar(keys %bs);
    my $prefix = (index($g, "$o ") == 0) ? 1 : 0;
    return { cov_o => $covO, cov_g => $covG, prefix => $prefix,
             tscore => 0.75 * $covO + 0.25 * $covG, variant => $graw };
}

# HOLDOUT (--holdout): the albums that ALREADY match, each with its real group(s)
# taken off the page - and every group sharing that title, so a twin cannot stand
# in - then offered to the new pass as if MusicBrainz lacked the album. Any match
# the rule makes here is a WRONG one (or MusicBrainz holding the same album twice).
my $HOLDOUT = grep { $_ eq '--holdout' } @ARGV;

# The groups the new pass would consider for one owned copy: the page's shown
# groups sharing a title word with it, best 5 by title evidence.
sub shortlist {
    my ($it, $shown, $editions, $an) = @_;
    my $o = $N->($it->{_candTitle});
    my @cands;
    for my $rg (@$shown) {
        my @vars = ([ $N->($rg->{title}), $rg->{title}, 'title' ]);
        push @vars, [ $N->($_), $_, 'alias' ] for @{ $rg->{aliases} || [] };
        push @vars, [ $_->[0], $_->[1], 'edition' ] for @{ $editions->{ $rg->{mbid} } || [] };
        my $best;
        for my $v (@vars) {
            next unless length $v->[0];
            my $f = title_feat($o, $v->[0], $an, $it->{_candTitle}, $v->[1]) or next;
            $f->{via} = $v->[2];
            $best = $f if !$best || $f->{tscore} > $best->{tscore};
        }
        next unless $best;
        push @cands, { mbid => $rg->{mbid}, title => $rg->{title}, type => $rg->{type},
                       secondary => $rg->{secondary}, date => $rg->{date}, %$best };
    }
    @cands = (sort { $b->{tscore} <=> $a->{tscore} } @cands)[0 .. ($#cands < 4 ? $#cands : 4)];
    return ($o, @cands);
}

my (%tally, @out);
for my $a (sort { lc $a->{name} cmp lc $b->{name} } @{ $lib->{artists} }) {
    my $name = $a->{name};
    my $mbid = $who->{$name};
    my $sp   = $mbid ? $spines->{$mbid} : undef;
    unless ($sp && @{ $sp->{rgs} || [] }) { $tally{'artist: no MusicBrainz spine'}++; next }
    $tally{'artist: replayed'}++;

    my @rgs = map { +{ %$_, aliases => [ @{ $_->{aliases} || [] } ] } } @{ $sp->{rgs} };
    delete $_->{aliases} for grep { !@{ $_->{aliases} } } @rgs;
    prune_aliases(\@rgs);
    my $relMap   = $sp->{rel} || {};
    my $official = $sp->{official} || {};
    my $editions = $B->can('_editionTitles')->(\@rgs, $sp->{editions} || {});
    my @pool     = grep { !$B->can('_hiddenType')->($_) } @rgs;
    my @shown    = grep { !defined $official->{ $_->{mbid} } || $official->{ $_->{mbid} } } @pool;

    my $jt = ($tags->{$name} || {})->{albums} || {};
    my @local;
    for my $al (@{ $a->{albums} }) {
        my $tr = $lib->{tracks}{ $al->{id} } || [];
        my $dur = 0; $dur += $_->{dur} for @$tr;
        my $rt = uc($al->{release_type} // '');
        my $size = $rt eq 'SINGLE' ? 'single' : $rt eq 'EP' ? 'ep'
                 : @$tr ? Plugins::Discography::Sources::_sizeFromCounts(scalar @$tr, $dur) : undef;
        push @local, {
            _albumid => $al->{id}, _candTitle => $al->{title}, _candArtist => $al->{artist},
            ($al->{other} ? (_otherArtist => 1) : ()),
            _mbid => (exists $jt->{ $al->{title} } ? $jt->{ $al->{title} } : undef),
            _july => (exists $jt->{ $al->{title} } ? 1 : 0),
            _reltype => $al->{release_type}, _year => $al->{year}, _size => $size,
        };
    }
    next unless @local;
    my $claimed = $S->claimedLocalIds(\@pool, $name, \@local, $relMap, $editions);
    my $an = $N->($name);
    for my $it (@local) {
        my $ca = $N->($it->{_candArtist} // '');
        my $own = (!length $ca || !length $an || Plugins::Discography::Sources::_artistMatch($an, $ca));
        if ($HOLDOUT) {
            next unless $claimed->{ $it->{_albumid} } && $own && !$it->{_otherArtist};
            my @real = grep { $S->claimedLocalIds([$_], $name, [$it], $relMap, $editions)->{ $it->{_albumid} } } @pool;
            next unless @real;
            my %gone = map { $N->($_->{title}) => 1 } @real;
            my %goneId = map { $_->{mbid} => 1 } @real;
            my @rest = grep { !$goneId{ $_->{mbid} } && !$gone{ $N->($_->{title}) } } @shown;
            my ($o, @cands) = shortlist($it, \@rest, $editions, $an);
            $tally{'holdout: matched albums replayed'}++;
            $tally{'holdout: with a title candidate left'}++ if @cands;
            push @out, {
                artist => $name, artist_mbid => $mbid, album_id => $it->{_albumid},
                title => $it->{_candTitle}, norm => $o, year => $it->{_year}, size => $it->{_size},
                tagged => $it->{_mbid}, weight => Plugins::Discography::Sources::_titleWeight($it->{_candTitle}, $name),
                real => [ map { "$_->{title} (" . substr($_->{date} // '', 0, 4) . ")" } @real ],
                cands => \@cands,
            } if @cands;
            next;
        }
        $tally{'owned: claimed today'}++, next if $claimed->{ $it->{_albumid} };
        $tally{'owned: leftover, Appearances'}++, next unless $own;
        $tally{'owned: leftover, Also in your library'}++;
        $tally{'  of which untagged or new since July'}++ unless $it->{_mbid};

        my ($o, @cands) = shortlist($it, \@shown, $editions, $an);
        push @out, {
            artist => $name, artist_mbid => $mbid, album_id => $it->{_albumid},
            title => $it->{_candTitle}, norm => $o, year => $it->{_year}, size => $it->{_size},
            tagged => $it->{_mbid}, ($a->{synthetic} ? (synthetic => $a->{synthetic}) : ()), weight => Plugins::Discography::Sources::_titleWeight($it->{_candTitle}, $name),
            cands => \@cands,
        };
    }
}

my $outf = $HOLDOUT ? "$dir/holdout.json" : "$dir/leftovers.json";
open my $fh, '>', $outf or die $!;
print $fh JSON::PP->new->utf8->canonical->encode(\@out);
close $fh;
printf "%-42s %d\n", $_, $tally{$_} for sort keys %tally;
printf "%-42s %d\n", 'own leftovers with a title candidate', scalar grep { @{ $_->{cands} } } @out;
printf "%-42s %d\n", 'candidate groups to fetch tracklists for',
    scalar keys %{ { map { map { $_->{mbid} => 1 } @{ $_->{cands} } } @out } };
print "-> $outf\n";
