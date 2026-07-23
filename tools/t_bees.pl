#!/usr/bin/env perl
#
# REGRESSION TEST — an owned search row is split into one row per owned IDENTITY.
#
# FIELD (Simon, "The Bees"): he owns THREE distinct acts of that name — the UK
# band, a US garage band, and a third whose spine is bootleg-only — as three
# separate library contributors, each with its own MusicBrainz tag. LMS's own
# library search lists all three; ours listed ONE, because `mergeArtistHits`
# buckets by `_norm(name)` and keeps only the first contributor id, so two acts
# were unreachable and the surviving row drilled into the wrong band.
#
# Simon's rule, verbatim: "it should fold them if the same artist but if
# legitimate different acts it should not." The discriminator is the MB tag:
# same tag -> one act (fold), different tags -> different acts (a row each).
#
# Standalone -- no LMS install needed:  perl tools/t_bees.pl
#
use strict;
use warnings;
use FindBin;

my @QUERIES;

# ------------- the library, and its MusicBrainz tags -----------------------
# THREE "The Bees" contributors, three DIFFERENT tags -> three acts.
# One name ("The Cats") with TWO contributors sharing ONE tag -> one act.
# One name ("The Bats") with TWO UNTAGGED contributors -> cannot be proven one
# act, so they must NOT fold. Plus a plain single-identity artist and an
# untagged solo one.
my @LIB = (
    { name => 'The Bees', artist_id => 75007 },  # UK
    { name => 'The Bees', artist_id => 79768 },  # US garage
    { name => 'The Bees', artist_id => 77854 },  # bootleg-only spine
    { name => 'The Cats', artist_id => 400 },
    { name => 'The Cats', artist_id => 401 },    # apostrophe-variant duplicate
    { name => 'The Bats', artist_id => 500 },
    { name => 'The Bats', artist_id => 501 },
    { name => 'Radiohead', artist_id => 100 },
    { name => 'Solo Soul', artist_id => 200 },   # owned, untagged, unique name
);
my %MBID = (
    75007 => '276cfa71-6bc0-4b0f-8a9c-000000000001',
    79768 => '0790a093-6bc0-4b0f-8a9c-000000000002',
    77854 => 'dd11eecd-6bc0-4b0f-8a9c-000000000003',
    400   => 'ca700000-6bc0-4b0f-8a9c-000000000004',
    401   => 'ca700000-6bc0-4b0f-8a9c-000000000004',   # SAME tag as 400
    100   => 'a74b1b7f-71a5-4011-9441-d0b5e4122711',
    # 500/501/200 deliberately untagged
);
my %ALBUMS = (75007 => 18, 79768 => 7, 77854 => 1, 400 => 5, 401 => 0,
              500 => 3, 501 => 2, 100 => 9, 200 => 4);
# LMS's own artist icon per act (folder artist-art). Two acts HAVE art; the
# bootleg act (77854) is in the menu but has NONE -> the split must give it a
# neutral icon, never MAI's online guess of the prominent act.
my %MENU_ICON = (75007 => 'contributor/uk/image', 79768 => 'contributor/garage/image');

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::Timers Slim::Networking::SimpleAsyncHTTP
                  Slim::Utils::Strings Slim::Utils::PluginManager
                  Slim::Control::Request Slim::Schema
                  JSON::XS::VersionOneAndTwo Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}          = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    # Forward contributor->mbid, the read _contribMbid makes (API.pm:285).
    *{'Slim::Schema::find'} = sub {
        my ($class, $type, $id) = @_;
        return bless { mbid => $MBID{$id} }, 'T::Contrib';
    };
    *{'Slim::Control::Request::executeRequest'} = sub {
        my (undef, $args) = @_;
        if (($args->[0] // '') eq 'albums') {
            my ($aid) = map { /^artist_id:(\d+)/ ? $1 : () } @$args;
            return bless { count => ($ALBUMS{$aid} // 0) }, 'T::Req';
        }
        if (($args->[0] // '') eq 'browselibrary') {
            my ($q) = map { /^search:(.*)/ ? $1 : () } @$args;
            my @items;
            for my $a (@LIB) {
                next unless lc($a->{name}) eq lc($q // '');
                my %it = (commonParams => { artist_id => $a->{artist_id} });
                $it{icon} = $MENU_ICON{ $a->{artist_id} } if $MENU_ICON{ $a->{artist_id} };
                push @items, \%it;
            }
            return bless { loop => \@items }, 'T::Req';
        }
        my ($search) = grep { /^search:/ } @$args;
        return bless { loop => [] }, 'T::Req' unless defined $search;
        $search =~ s/^search://;
        push @QUERIES, $search;
        return bless { loop => main::library_for($search) }, 'T::Req';
    };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
}

package T::Null;    our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Prefs;   sub get { 1 } sub set { 1 } sub init { 1 } sub setChange { 1 }
package T::Contrib; sub musicbrainz_id { $_[0]->{mbid} }
package T::Req;
sub getResult {
    my ($self, $what) = @_;
    return $self->{count} if defined $what && $what eq 'count';
    return $self->{loop};
}

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
my $SRC = 'Plugins::Discography::Sources';

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

# LMS index: token-prefix match, apostrophe splits, accents folded.
sub library_for {
    my ($q) = @_;
    my @want = map { lc } grep { length } split /[^\p{Alnum}]+/, $q;
    return [] unless @want;
    my @hits;
    for my $a (@LIB) {
        my @toks = map { lc } grep { length } split /[^\p{Alnum}]+/, $a->{name};
        my $all = 1;
        for my $w (@want) {
            $all = 0, last unless grep { index($_, $w) == 0 } @toks;
        }
        push @hits, { artist => $a->{name}, id => $a->{artist_id} } if $all;
    }
    return \@hits;
}

sub split_ { return $SRC->splitOwnedByIdentity($_[0]) }
sub row {
    my (%o) = @_;
    return { name => $o{name}, sources => $o{sources} || ['Local'],
             ($o{artist_id} ? (artist_id => $o{artist_id}) : ()),
             _exact => (defined $o{_exact} ? $o{_exact} : 1), _seq => $o{_seq} // 0 };
}
sub ids   { sort { $a <=> $b } map { $_->{artist_id} // 0 } @{ $_[0] } }
sub beeRow { row(name => 'The Bees', artist_id => 79768,
                 sources => ['Local','Qobuz','Tidal','Deezer']) }

# ---------------------------------------------------------------------------
# 1. THE FIELD CASE — the collapsed "The Bees" row becomes three owned rows.
# ---------------------------------------------------------------------------
{
    my $out = split_([ beeRow() ]);
    ok(scalar(@$out == 3), 'three owned "The Bees" acts become THREE rows');
    ok(scalar(join(',', ids($out)) eq '75007,77854,79768'),
       '... one per distinct contributor identity, order deterministic by id');
    ok(scalar(!grep { $_->{name} ne 'The Bees' } @$out),
       '... all still named "The Bees"');
    ok(scalar(!grep { my %s = map { $_ => 1 } @{ $_->{sources} };
                      !$s{Local} || keys %s != 1 } @$out),
       '... each shows Local ONLY (streaming is recovered on drill-in)');
    my %im = map { ($_->{artist_id} => $_->{_ident_mbid} // '') } @$out;
    ok(scalar($im{75007} eq $MBID{75007} && $im{79768} eq $MBID{79768}
              && $im{77854} eq $MBID{77854}),
       '... each carries its own MB identity mbid (for the disambiguation filter)');
    my %img = map { ($_->{artist_id} =>
                    ($_->{_img} // ($_->{_noart} ? 'NOART' : 'MAI'))) } @$out;
    ok(scalar($img{75007} eq 'contributor/uk/image'
              && $img{79768} eq 'contributor/garage/image'),
       '... the acts WITH artist art get their OWN LMS icon (not a shared MAI photo)');
    ok(scalar($img{77854} eq 'NOART'),
       '... the art-less act gets a neutral icon, NOT MAI online (the reported bug)');
}

# ---------------------------------------------------------------------------
# 2. FOLD SAME IDENTITY. Two "The Cats" contributors share one MB tag -> ONE
#    act -> ONE row, left intact (streaming sources kept, mbid stamped).
# ---------------------------------------------------------------------------
{
    my $out = split_([ row(name => 'The Cats', artist_id => 400,
                           sources => ['Local','Qobuz']) ]);
    ok(scalar(@$out == 1), 'two same-tag contributors FOLD into one row');
    ok(scalar($out->[0]{_ident_mbid} eq $MBID{400}), '... stamped with the shared mbid');
    ok(scalar(grep { $_ eq 'Qobuz' } @{ $out->[0]{sources} }),
       '... and a single-identity row keeps its streaming sources');
}

# ---------------------------------------------------------------------------
# 3. UNTAGGED same-name contributors are NOT folded — we cannot prove they are
#    one act, so each stays reachable (keyed by contributor id).
# ---------------------------------------------------------------------------
{
    my $out = split_([ row(name => 'The Bats', artist_id => 500) ]);
    ok(scalar(@$out == 2), 'two UNTAGGED same-name contributors stay TWO rows');
    ok(scalar(join(',', ids($out)) eq '500,501'), '... one per contributor id');
    ok(scalar(!defined $out->[0]{_ident_mbid} && !defined $out->[1]{_ident_mbid}),
       '... with no identity mbid (untagged)');
}

# ---------------------------------------------------------------------------
# 4. THE COMMON CASE IS UNTOUCHED. A single-identity owned artist keeps its
#    one row and every streaming source; it only GAINS the _ident_mbid stamp.
# ---------------------------------------------------------------------------
{
    my $out = split_([ row(name => 'Radiohead', artist_id => 100,
                           sources => ['Local','Qobuz','Tidal','Deezer']) ]);
    ok(scalar(@$out == 1), 'a normal owned artist stays ONE row');
    ok(scalar(@{ $out->[0]{sources} } == 4),
       '... with all four sources intact (nothing dropped)');
    ok(scalar($out->[0]{_ident_mbid} eq $MBID{100}), '... and gains its identity mbid');
}

# ---------------------------------------------------------------------------
# 5. A NON-OWNED ROW IS NEVER PROBED OR SPLIT.
# ---------------------------------------------------------------------------
{
    @QUERIES = ();
    my $out = split_([ { name => 'Some Band', sources => ['Qobuz','Tidal'] } ]);
    ok(scalar(@QUERIES == 0), 'a row with no artist_id costs NO library query');
    ok(scalar(@$out == 1 && !defined $out->[0]{_ident_mbid}),
       '... is returned untouched, with no identity mbid');
}

# ---------------------------------------------------------------------------
# 6. NO MUTATION OF THE INPUT (cached search rows must stay clean) + defensive.
# ---------------------------------------------------------------------------
{
    my $in = beeRow();
    split_([ $in ]);
    ok(scalar(@{ $in->{sources} } == 4 && $in->{artist_id} == 79768),
       'the INPUT row is not mutated by the split');

    my $out = split_([]);
    ok(scalar(ref $out eq 'ARRAY' && @$out == 0), 'an empty list is safe');
    $out = split_([ row(name => 'Solo Soul', artist_id => 200) ]);
    ok(scalar(@$out == 1 && !defined $out->[0]{_ident_mbid}),
       'an owned but UNTAGGED unique artist stays one row, unstamped');
}

# ---------------------------------------------------------------------------
# 7. COST IS BOUNDED — at most LIB_PROBE_MAX owned rows are probed.
# ---------------------------------------------------------------------------
{
    @QUERIES = ();
    my @many = map { row(name => "Owned Xyzzy $_", artist_id => 900 + $_) } 1 .. 25;
    split_(\@many);
    my %probed = map { $_ => 1 } grep { /^Owned Xyzzy \d+$/ } @QUERIES;
    ok(scalar(keys %probed) <= 10,
       'at most LIB_PROBE_MAX owned rows probed (' . scalar(keys %probed) . ')');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
