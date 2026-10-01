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
    # SAINT ETIENNE (field, 2026-09-19): a Various Artists compilation credited
    # the curator as a track artist, minting empty same-name contributors with
    # LOWER ids than the real act (which owns every album).
    { name => 'Saint Etienne', artist_id => 600 },
    { name => 'Saint Etienne', artist_id => 601 },
    { name => 'Saint Etienne', artist_id => 602 },
    { name => 'Saint Etienne', artist_id => 650 },   # the real act
    # TIE: two acts with the SAME album count -> the lower id goes first.
    { name => 'The Ties', artist_id => 710 },
    { name => 'The Ties', artist_id => 700 },
    # COST (2026-09-20): a name with TWO identities, one of which holds two
    # contributors (an apostrophe-variant duplicate). This is the only shape
    # that reaches the representative SORT with more than one candidate.
    { name => 'The Dupes', artist_id => 800 },
    { name => 'The Dupes', artist_id => 801 },   # same MB tag as 800
    { name => 'The Dupes', artist_id => 810 },   # a genuinely different act
    # THE MERGE (Simon, 2026-09-30: "Why do we get 2 air?"). One track on Air's
    # own Premiers Symptômes carries "Air" with Alex Gopher's MB id, so LMS holds
    # a second "Air" found only on that album. Listed FIRST, as LMS may.
    { name => 'Air', artist_id => 151914 },
    { name => 'Air', artist_id => 151906 },      # the duo, 5 albums
    # 15 Minutes' id on the bonus tracks of the band's Expanded Edition.
    { name => 'The Dream Syndicate', artist_id => 155735 },
    { name => 'The Dream Syndicate', artist_id => 155737 },
    # Two contributors on ONE compilation (First Class Rock Steady's shape).
    { name => 'The Jets', artist_id => 157355 },
    { name => 'The Jets', artist_id => 157388 },
    # One album of its OWN besides a shared one: a separate act.
    { name => 'The Mixed', artist_id => 1100 },
    { name => 'The Mixed', artist_id => 1101 },
    # Three identities: one found only on the main act's albums, one with its own.
    { name => 'The Three', artist_id => 1200 },
    { name => 'The Three', artist_id => 1201 },
    { name => 'The Three', artist_id => 1202 },
    # An UNTAGGED contributor found only on the main act's albums.
    { name => 'The Untagged', artist_id => 1300 },
    { name => 'The Untagged', artist_id => 1301 },
    # Lists longer than one page of albums (OWNED_ALBUMS_MAX).
    { name => 'The Big', artist_id => 1400 },
    { name => 'The Big', artist_id => 1401 },
);
my %MBID = (
    75007 => '276cfa71-6bc0-4b0f-8a9c-000000000001',
    79768 => '0790a093-6bc0-4b0f-8a9c-000000000002',
    77854 => 'dd11eecd-6bc0-4b0f-8a9c-000000000003',
    400   => 'ca700000-6bc0-4b0f-8a9c-000000000004',
    401   => 'ca700000-6bc0-4b0f-8a9c-000000000004',   # SAME tag as 400
    100   => 'a74b1b7f-71a5-4011-9441-d0b5e4122711',
    # 500/501/200 deliberately untagged
    600   => '5a100000-6bc0-4b0f-8a9c-000000000600',
    601   => '5a100000-6bc0-4b0f-8a9c-000000000601',
    602   => '5a100000-6bc0-4b0f-8a9c-000000000602',
    650   => '3997d4a6-bc09-43e7-8650-000000000650',
    700   => '71e50000-6bc0-4b0f-8a9c-000000000700',
    710   => '71e50000-6bc0-4b0f-8a9c-000000000710',
    800   => 'd0be0000-6bc0-4b0f-8a9c-000000000800',
    801   => 'd0be0000-6bc0-4b0f-8a9c-000000000800',   # SAME tag as 800
    810   => 'd0be0000-6bc0-4b0f-8a9c-000000000810',
    151906 => 'cb67438a-7f50-4f2b-a6f1-2bb2729fd538',   # Air
    151914 => 'ee1a6d4a-b1ff-46a8-acf2-af575424bda5',   # Alex Gopher, tagged "Air"
    155735 => '8577c385-6bc0-4b0f-8a9c-000000155735',   # The Dream Syndicate
    155737 => 'a819c124-6bc0-4b0f-8a9c-000000155737',   # 15 Minutes
    157355 => '1e7a0000-6bc0-4b0f-8a9c-000000157355',
    157388 => '1e7a0000-6bc0-4b0f-8a9c-000000157388',
    1100  => 'a1100000-6bc0-4b0f-8a9c-000000001100',
    1101  => 'a1100000-6bc0-4b0f-8a9c-000000001101',
    1200  => 'a1200000-6bc0-4b0f-8a9c-000000001200',
    1201  => 'a1200000-6bc0-4b0f-8a9c-000000001201',
    1202  => 'a1200000-6bc0-4b0f-8a9c-000000001202',
    1300  => 'a1300000-6bc0-4b0f-8a9c-000000001300',   # 1301 deliberately untagged
    1400  => 'a1400000-6bc0-4b0f-8a9c-000000001400',
    1401  => 'a1400000-6bc0-4b0f-8a9c-000000001401',
);
my %ALBUMS = (75007 => 18, 79768 => 7, 77854 => 1, 400 => 5, 401 => 0,
              500 => 3, 501 => 2, 100 => 9, 200 => 4,
              600 => 0, 601 => 0, 602 => 0, 650 => 31, 700 => 2, 710 => 2,
              800 => 6, 801 => 0, 810 => 2);
# The ALBUMS themselves, where the merge needs to see which are shared. Every
# contributor above that is not listed here gets albums of its own
# ("<id>.<n>", as many as %ALBUMS says), so none of the earlier sections merges.
my %ALBUM_IDS = (
    151906 => [qw(air.10000hz air.moonsafari air.premiers air.talkiewalkie air.virginsuicides)],
    151914 => [qw(air.premiers)],
    155735 => [qw(ds.days ds.medicine ds.ghost ds.outofthegrey ds.expanded)],
    155737 => [qw(ds.expanded)],
    157355 => [qw(comp.firstclassrocksteady)],
    157388 => [qw(comp.firstclassrocksteady)],
    1100   => [qw(mx.1 mx.2 mx.3 mx.4)],
    1101   => [qw(mx.1 mx.own)],
    1200   => [qw(t3.1 t3.2 t3.3 t3.4)],
    1201   => [qw(t3.2)],
    1202   => [qw(t3.other1 t3.other2)],
    1300   => [qw(un.1 un.2 un.3)],
    1301   => [qw(un.3)],
    1400   => [ map { "big.$_" } 1 .. 600 ],
    1401   => [ map { "big.$_" } 1 .. 501 ],      # one more than a page
);
sub album_ids {
    my ($aid) = @_;
    return $ALBUM_IDS{$aid} || [ map { "$aid.$_" } 1 .. ($ALBUMS{$aid} // 0) ];
}
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
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Null' }; $INC{'Plugins/Discography/DB.pm'} = 1;
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
            push @main::ALBQ, $aid;      # §10 counts these
            # The ids as well (the merge reads them), cut at the request's own
            # page size as LMS cuts them; `count` stays the whole total.
            my $ids = main::album_ids($aid);
            my $max = $args->[2] // 0;
            my @page = @$ids[0 .. ($max < @$ids ? $max : scalar @$ids) - 1];
            return bless { count => scalar(@$ids),
                           loop  => [ map { { id => $_ } } grep { defined } @page ] }, 'T::Req';
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
       '... one per distinct contributor identity');
    ok(scalar(join(',', map { $_->{artist_id} } @$out) eq '75007,79768,77854'),
       '... emitted MOST ALBUMS FIRST (18, 7, 1), not by contributor id');
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
    # Stage 3 live check (The Dream Syndicate, 2026-09-30): split rows share a
    # name and a "Local" line, so each carries the album count its row opens on,
    # which Browse::_searchResultRow puts on the row to tell them apart.
    my %own = map { ($_->{artist_id} => $_->{_owned}) } @$out;
    ok(scalar(($own{75007} // -1) == 18 && ($own{79768} // -1) == 7 && ($own{77854} // -1) == 1),
       '... each carries its OWN album count (18, 7, 1) to tell the rows apart');
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
    ok(scalar(!exists $out->[0]{_owned}),
       '... and no album count: nothing on the list shares its name');
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

# ---------------------------------------------------------------------------
# 8. SAINT ETIENNE (field, 2026-09-19). Empty same-name contributors with LOWER
#    ids than the real act must not top the search: by id alone an empty one
#    came first and drilled to a blank page. The act with the albums leads;
#    equal counts fall back to the id, so the item_id walk stays deterministic.
# ---------------------------------------------------------------------------
{
    my $out = split_([ row(name => 'Saint Etienne', artist_id => 600) ]);
    ok(scalar(@$out == 4), 'four Saint Etienne identities -> four rows');
    ok(scalar(($out->[0]{artist_id} // 0) == 650),
       '... the act OWNING the albums is FIRST, despite the highest id');
    ok(scalar(join(',', map { $_->{artist_id} } @$out[1..3]) eq '600,601,602'),
       '... the empty ones follow, in id order (ties are deterministic)');
    ok(scalar(!grep { $_->{_seq} != 0 } @$out),
       '... all keep the original _seq, so rankArtistHits cannot reorder them');
    my $ranked = $SRC->rankArtistHits($out);
    ok(scalar(($ranked->[0]{artist_id} // 0) == 650),
       '... and the real act is still first after rankArtistHits');

    $out = split_([ row(name => 'The Ties', artist_id => 710) ]);
    ok(scalar(join(',', map { $_->{artist_id} } @$out) eq '700,710'),
       'equal album counts -> lower contributor id first');
}

# ---------------------------------------------------------------------------
# 10. WHAT THE SPLIT COSTS (review 2026-09-20). The 0.51.x entry for this fix
#     says "the count is the one already computed for the representative; no
#     new query" — and the code did not do that: `_albumCountFor` is a
#     `Slim::Control::Request` DB query and it was called from INSIDE the sort
#     comparator, so an identity holding n contributors ran it O(n log n)
#     times and then once more for the row it picked. A comment is not the
#     contract, so the count is now taken ONCE per contributor, before the
#     sort, and this pins it.
#
#     "The Dupes" is the only fixture shape that reaches the comparator with
#     more than one candidate: two identities, one of which holds an
#     apostrophe-variant duplicate (800/801 share a tag; 810 is another act).
# ---------------------------------------------------------------------------
our @ALBQ;
{
    @ALBQ = ();
    my $out = split_([ row(name => 'The Dupes', artist_id => 800) ]);
    ok(scalar(@$out == 2), 'two Dupes identities -> two rows');
    ok(scalar(join(',', map { $_->{artist_id} } @$out) eq '800,810'),
       '... the contributor owning the albums represents its identity');
    my %once; $once{$_}++ for @ALBQ;
    ok(scalar(!grep { $_ > 1 } values %once),
       'no contributor is counted twice: one album query each');
    ok(scalar(@ALBQ == 3),
       '... 3 contributors, 3 queries (it was 4, the comparator ran one twice)');
}

# ---------------------------------------------------------------------------
# 11. THE MERGE (Simon, 2026-09-30: "Why do we get 2 air?" ... "yes we need a
#     merge"). A same-name identity every one of whose albums the main act also
#     performs on is not another act: its result would open nothing the main
#     act's page does not hold. It merges; an identity with an album of its own
#     does not. The Bees (§1) and Saint Etienne's empty ones (§8) are the
#     controls: both keep every result they had.
# ---------------------------------------------------------------------------
{
    my $out = split_([ row(name => 'Air', artist_id => 151914,
                           sources => ['Local', 'Qobuz']) ]);
    ok(scalar(@$out == 1),
       "Air: a contributor found only on the main act's albums MERGES - one result");
    ok(scalar(($out->[0]{artist_id} // 0) == 151906),
       '... opening on the MAIN act (5 albums), though the row carried the merged contributor');
    ok(scalar(($out->[0]{_ident_mbid} // '') eq $MBID{151906}),
       "... stamped with the main act's identity, not Alex Gopher's");
    ok(scalar(join(',', @{ $out->[0]{sources} || [] }) eq 'Local,Qobuz'),
       '... an ordinary owned result again: its streaming sources kept');
    ok(scalar(!exists $out->[0]{_owned}),
       '... with no album count: nothing else on the list shares its name');

    $out = split_([ row(name => 'The Dream Syndicate', artist_id => 155735) ]);
    ok(scalar(@$out == 1 && ($out->[0]{artist_id} // 0) == 155735),
       "The Dream Syndicate: 15 Minutes' id on the Expanded Edition merges into the band");

    $out = split_([ row(name => 'The Jets', artist_id => 157388) ]);
    ok(scalar(@$out == 1 && ($out->[0]{artist_id} // 0) == 157355),
       'two contributors on ONE compilation: one result, the lower id on a tie');

    $out = split_([ row(name => 'The Untagged', artist_id => 1300) ]);
    ok(scalar(@$out == 1 && ($out->[0]{_ident_mbid} // '') eq $MBID{1300}),
       "an UNTAGGED contributor found only on the main act's albums merges too");

    $out = split_([ row(name => 'The Mixed', artist_id => 1100) ]);
    ok(scalar(@$out == 2),
       'ONE album of its own besides a shared one keeps it a separate act: two results');

    @ALBQ = ();
    $out = split_([ row(name => 'The Three', artist_id => 1200) ]);
    ok(scalar(join(',', map { $_->{artist_id} } @$out) eq '1200,1202'),
       "three identities: the one found only on the main act's albums goes, the one with its own stays");
    ok(scalar(($out->[0]{_owned} // -1) == 4 && ($out->[1]{_owned} // -1) == 2),
       '... the two left are still split results, each with its own album count');
    ok(scalar(@ALBQ == 3), '... still one album query per contributor');

    $out = split_([ row(name => 'The Big', artist_id => 1400) ]);
    ok(scalar(@$out == 2),
       'a list cut short at OWNED_ALBUMS_MAX proves nothing: no merge');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
