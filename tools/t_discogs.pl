#!/usr/bin/env perl
#
# Discogs first, for a tile with no cover of its own (Discography/Discogs.pm,
# 2026-10-09). Simon: "it needs to use discogs first not after CAA"; the small
# thumbnails are fine ("speed and performance are more important for these");
# a release with no MusicBrainz link to Discogs matches by exact title, guarded.
#
# Drives the REAL Discogs.pm against fakes of what it talks to: MusicBrainz's
# links (API::warmServiceLinks), the page's cached groups (API::peekReleaseGroups),
# MAI's Discogs request (answered by the suite), the plugin's store, timers and
# a fake clock. Sections:
#   1  the read: the Discogs artist MusicBrainz links, its own (Main) entries
#      newest first; page 1, then PARALLEL pages at once until a page holds
#      anything not his own, at most MAX_PAGES, one at a time when Discogs's
#      minute runs low; each page usable as it lands; { first => 1 } answered
#      at page 1; listeners told; thumbnails only, kept LIST_TTL
#   2  nothing to read: no link (kept a day), links unread (nothing kept), MAI
#      off (nothing asked), a page 1 failure (nothing kept), a later page
#      failing (what came, a day), MAI's request dying, the watchdog
#   3  one read per artist: a caller arriving mid-read joins it; pending()
#   4  the match: by the group's Discogs id first; a linked group never by title
#   5  the title rule: exact title (case, curly quotes, dashes aside, brackets
#      kept), the same year, exactly one entry, masters preferred, an entry a
#      linked group owns not taken, two groups of one title and year: neither
#   6  thumbFor reads only the cache; a new read is seen at once
#   7  what is a thumbnail
#   8  MusicBrainz's completed list's links, before it replaces the page's
#      list: a group with none takes its link (by id); linksChanged rebuilds
#   9  (review 2026-10-09) a read that kept nothing is not asked again for two
#      minutes, Discogs's side only; readSince says when a read started
#  10  (review) the title guard and the pages: a list kept after a page failed
#      matches titles only in years the pages in a row hold whole (an hour);
#      while read, the pages in so far, as before
#  11  (review) Discogs's minute is one for every read, a refusal's headers too
#
# Standalone, no LMS install needed:  perl tools/t_discogs.pl
#
use strict;
use warnings;
use utf8;
use FindBin;

our ($NOW, %KV, @SETS, @TIMERS, $TID, @CALLS, %LINKS, $LINKS_FAIL, %RGS, %NEXT, $MAI_ON, $CALL_DIES, @LINKREQ);

BEGIN {
    $NOW = 1_800_000_000;
    *CORE::GLOBAL::time = sub () { int $main::NOW };
    for my $m (qw(Slim::Utils::Log Slim::Utils::Timers Slim::Utils::PluginManager
                  Plugins::Discography::Plugin Plugins::Discography::API Plugins::Discography::DB)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'} = sub { bless {}, 'T::Null' };
    push @{'Slim::Utils::Log::ISA'}, 'Exporter';
    @{'Slim::Utils::Log::EXPORT'} = ('logger');
    *{'Slim::Utils::Timers::setTimer'}     = sub { my $id = ++$main::TID; push @main::TIMERS, [ $_[1], $_[2], $id ]; $id };
    *{'Slim::Utils::Timers::killSpecific'} = sub { my $id = $_[0]; @main::TIMERS = grep { $_->[2] != $id } @main::TIMERS; 1 };
    *{'Slim::Utils::PluginManager::isEnabled'} = sub { $main::MAI_ON ? 1 : 0 };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Store' };
    *{'Plugins::Discography::API::warmServiceLinks'} = sub {
        my (undef, $a, $cb) = @_;
        push @main::LINKREQ, $a;
        $cb->($main::LINKS_FAIL ? undef : ($main::LINKS{$a} // { qobuz => [], deezer => [], discogs => [] }));
    };
    *{'Plugins::Discography::API::peekReleaseGroups'} = sub { $main::RGS{ $_[1] } };
    *{'Plugins::Discography::API::peekNextDiscogsLinks'} = sub { $main::NEXT{ $_[1] } };
    # MAI's Discogs request: kept for the suite to answer.
    *{'Plugins::MusicArtistInfo::Discogs::_call'} = sub {
        die "MAI broke\n" if $main::CALL_DIES;
        my ($res, $args, $cb) = @_;
        push @main::CALLS, [ $res, { %$args }, $cb ];
    };
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}
package T::Store; sub get { $main::KV{ $_[1] } } sub set { $main::KV{ $_[1] } = $_[2]; push @main::SETS, [ $_[1], $_[3] ]; 1 }
package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Time::HiRes;
{ no warnings qw(redefine prototype once); *Time::HiRes::time = sub { $main::NOW }; }
require Plugins::Discography::Discogs;
my $D = 'Plugins::Discography::Discogs';

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

my $A  = '8247a3f2-3a8e-4256-b322-6c57b03a4e36';
my $A2 = '11111111-2222-4333-8444-555555555555';
sub rg { sprintf('%08x-0000-4000-8000-%012x', $_[0], $_[0]) }
sub fresh {
    %KV = (); @SETS = (); @TIMERS = (); @CALLS = (); %LINKS = (); %RGS = (); %NEXT = (); @LINKREQ = ();
    $LINKS_FAIL = 0; $MAI_ON = 1; $CALL_DIES = 0;
    $D->can('_resetForSuite')->() if $D->can('_resetForSuite');
}
sub entry {
    my (%e) = @_;
    return { role => 'Main', type => 'master', year => 1962, thumb => "https://i.discogs.com/$e{id}.jpg", %e };
}
# Answer the oldest MAI request with a page (headers: Discogs's, as a hash).
sub page {
    my ($rels, $pages, $hdr) = @_;
    my $c = shift @CALLS or return 0;
    $c->[2]->({ releases => $rels, pagination => { pages => $pages // 1 } }, $hdr || {});
    return 1;
}
sub asked { join(',', map { $_->[1]{page} } @CALLS) }
sub tick { my @due = grep { $_->[0] <= $NOW } @TIMERS; @TIMERS = grep { $_->[0] > $NOW } @TIMERS; $_->[1]->() for @due }
sub listOf { $D->peekList($_[0]) }
sub ttlOf  { my ($k) = @_; my ($s) = grep { $_->[0] eq $k } reverse @SETS; $s ? $s->[1] : undef }
my $KEY = "dsc:dg:v2:$A";

# 1. The read.
{
    fresh();
    $LINKS{$A} = { qobuz => [], deezer => [], discogs => [ 252310 ] };
    my @told;
    $D->listen(sub { push @told, $_[0] });
    my ($done, $first) = (0, 0);
    $D->warm(uc $A, sub { $done++ });
    $D->warm($A, sub { $first++ }, { first => 1 });
    ok(scalar(@CALLS == 1 && $CALLS[0][0] eq 'artists/252310/releases'), '1: the Discogs artist MusicBrainz links, asked through MAI, once');
    ok(scalar($CALLS[0][1]{per_page} == 100 && $CALLS[0][1]{page} == 1
              && $CALLS[0][1]{sort} eq 'year' && $CALLS[0][1]{sort_order} eq 'desc'),
       '1: ... 100 a page, page 1 first, newest first');
    ok(scalar($D->pending($A) && !$done && !$first), '1: ... pending while it is read');
    $RGS{$A} = [ g(n => 1, t => 'Interplay', d => '1962', dg => 'master:1') ];
    ok(scalar(!defined $D->thumbFor($A, rg(1))), '1: looked for before page 1 -> none yet');
    page([ entry(id => 1, title => 'Interplay', year => 1962),
           entry(id => 2, title => 'Portrait in Jazz', year => 1960, thumb => '') ], 35);
    ok(scalar($first == 1 && !$done), '1: page 1 in -> a { first } caller answered, the whole-list one not yet');
    ok(scalar(($D->thumbFor($A, rg(1)) // '') eq 'https://i.discogs.com/1.jpg' && !defined listOf($A)),
       '1: ... its entries usable at once (thumbFor, the map built before it rebuilt), nothing kept yet');
    ok(scalar(@told == 1 && $told[0] eq $A), '1: ... the listeners told');
    ok(scalar(asked() eq '2,3,4,5,6,7'), '1: page 1 all his own -> the next six pages asked at once');
    my $late = 0;
    $D->warm($A, sub { $late++ }, { first => 1 });
    ok(scalar($late == 1 && @CALLS == 6), '1: a { first } caller arriving after page 1 -> answered at once, nothing asked');
    page([ entry(id => 3, title => 'Moon Beams') ], 35) for 1 .. 2;          # pages 2, 3
    page([ entry(id => 4, title => 'Empathy'), entry(id => 5, title => 'Sideman', role => 'Appearance') ], 35);
    page([ entry(id => 6, title => 'X', role => 'Appearance') ], 35) for 1 .. 3;  # pages 5-7
    ok(scalar(!@CALLS && $done == 1 && !$D->pending($A)),
       '1: a page holding anything not his own -> the read ends with that wave (not all 35 pages)');
    my $l = listOf($A);
    ok(scalar(ref $l eq 'ARRAY' && join(',', sort map { $_->{id} } @$l) eq '1,3,3,4'),
       '1: kept: his own entries with a thumbnail, every page (an appearance and a blank thumbnail left out)');
    my ($e4) = grep { $_->{id} == 4 } @$l;
    ok(scalar($e4 && $e4->{kind} eq 'master' && $e4->{title} eq 'Empathy' && $e4->{year} == 1962
              && $e4->{thumb} eq 'https://i.discogs.com/4.jpg'), '1: ... each with kind, title, year and thumbnail');
    ok(scalar((ttlOf($KEY) // 0) == 30 * 86400), '1: ... kept 30 days');
    ok(scalar(@told == 8 && $told[-1] eq $A), '1: ... the listeners told at every page and at the end');
    $D->warm($A, sub { $done++ });
    ok(scalar(!@CALLS && $done == 2), '1: read already -> answered at once, nothing asked');

    # Pages of his own past the first wave: the next six, and so on, to MAX_PAGES.
    fresh();
    $LINKS{$A} = { discogs => [ 7 ] };
    $D->warm($A);
    my @waves;
    my $n = 0;
    while (@CALLS) {
        push @waves, asked();
        my @w = @CALLS;
        page([ entry(id => ++$n, title => "T$n") ], 50) for @w;
    }
    ok(scalar(join(' / ', @waves) eq '1 / 2,3,4,5,6,7 / 8,9,10,11,12,13 / 14,15,16,17,18,19 / 20'),
       '1: his own past each wave -> the next six, at most 20 pages (Miles Davis: 13)');
    ok(scalar(@{ listOf($A) } == 20), '1: ... every page kept');

    # Discogs's minute running low: one page at a time.
    fresh();
    $LINKS{$A} = { discogs => [ 7 ] };
    $D->warm($A);
    page([ entry(id => 1, title => 'A') ], 9, { 'x-discogs-ratelimit-remaining' => 8 });
    ok(scalar(asked() eq '2'), '1: fewer than 10 calls left in its minute -> the next page alone');
    page([ entry(id => 2, title => 'B') ], 9, { 'x-discogs-ratelimit-remaining' => 30 });
    ok(scalar(asked() eq '3'), '1: ... and one at a time after (the read stays gentle)');
    fresh();
    $LINKS{$A} = { discogs => [ 7 ] };
    $D->warm($A);
    page([ entry(id => 1, title => 'A') ], 9, { 'x-discogs-ratelimit-remaining' => 10 });
    ok(scalar(asked() eq '2,3,4,5,6,7'), '1: (control) 10 left -> six at once');

    # One page in all.
    fresh();
    $LINKS{$A} = { discogs => [ 7 ] };
    ($done, $first) = (0, 0);
    $D->warm($A, sub { $done++ });
    $D->warm($A, sub { $first++ }, { first => 1 });
    page([ entry(id => 1, title => 'A') ], 1);
    ok(scalar(!@CALLS && $done == 1 && $first == 1 && @{ listOf($A) } == 1), '1: one page in all -> read, both callers answered once');
}

# 2. Nothing to read.
{
    fresh();
    my $done = 0;
    $D->warm($A, sub { $done++ });
    ok(scalar(!@CALLS && $done == 1 && ref listOf($A) eq 'ARRAY' && !@{ listOf($A) }),
       '2: MusicBrainz links no Discogs artist -> nothing asked, an empty list kept');
    ok(scalar((ttlOf($KEY) // 0) == 86400), '2: ... for a day');

    fresh();
    $LINKS_FAIL = 1;
    $done = 0;
    $D->warm($A, sub { $done++ });
    ok(scalar($done == 1 && !defined listOf($A) && !@SETS), "2: MusicBrainz's links not read -> nothing kept (asked again next visit)");

    fresh();
    $MAI_ON = 0;
    $LINKS{$A} = { discogs => [ 1 ] };
    $done = 0;
    $D->warm($A, sub { $done++ });
    ok(scalar($done == 1 && !@CALLS && !@LINKREQ && !defined listOf($A)), '2: MAI off -> nothing asked, nothing kept');

    fresh();
    $LINKS{$A} = { discogs => [ 1 ] };
    $done = 0;
    $D->warm($A, sub { $done++ });
    (shift @CALLS)->[2]->({}, {});                   # MAI's failure: an empty reply
    ok(scalar($done == 1 && !defined listOf($A)), '2: page 1 not read -> nothing kept');

    fresh();
    $LINKS{$A} = { discogs => [ 1 ] };
    $D->warm($A);
    page([ entry(id => 1, title => 'A') ], 5);
    (shift @CALLS)->[2]->({}, {});                   # page 2 fails
    ok(scalar(!defined listOf($A) && $D->pending($A)), '2: a later page not read -> the rest of its wave still awaited');
    page([ entry(id => $_, title => "T$_") ], 5) for 3 .. 5;
    ok(scalar(@{ listOf($A) || [] } == 4 && (ttlOf($KEY) // 0) == 3600 && !@CALLS),
       '2: ... then what came, kept an hour (a day until the 2026-10-09 review), nothing more asked');

    fresh();
    $LINKS{$A} = { discogs => [ 1 ] };
    my ($dn, $fs) = (0, 0);
    $D->warm($A, sub { $dn++ });
    $D->warm($A, sub { $fs++ }, { first => 1 });
    (shift @CALLS)->[2]->({}, {});
    ok(scalar($dn == 1 && $fs == 1 && !defined listOf($A)), '2: page 1 not read -> every caller answered, { first } too, nothing kept');

    fresh();
    $LINKS{$A} = { discogs => [ 1 ] };
    $CALL_DIES = 1;
    $done = 0;
    $D->warm($A, sub { $done++ });
    ok(scalar($done == 1 && !defined listOf($A) && !$D->pending($A)), "2: MAI's request dies -> settled, nothing kept");

    fresh();
    $LINKS{$A} = { discogs => [ 1 ] };
    $done = 0;
    $D->warm($A, sub { $done++ });
    $NOW += 121;
    tick();
    ok(scalar($done == 1 && !$D->pending($A) && !defined listOf($A)), '2: no answer in 120 s -> settled by the watchdog, nothing kept');
    page([ entry(id => 1, title => 'A') ], 1);
    ok(scalar($done == 1), '2: ... a late answer calls nobody back twice');
    $NOW -= 121;
}

# 3. One read per artist.
{
    fresh();
    $LINKS{$A} = { discogs => [ 1 ] };
    my ($one, $two) = (0, 0);
    $D->warm($A, sub { $one++ });
    $D->warm($A, sub { $two++ });
    ok(scalar(@CALLS == 1 && @LINKREQ == 1), '3: a second caller mid-read joins it (one request)');
    page([ entry(id => 1, title => 'A') ], 1);
    ok(scalar($one == 1 && $two == 1), '3: ... both called back once');
    $LINKS{$A2} = { discogs => [ 2 ] };
    $D->warm($A2);
    ok(scalar(@CALLS == 1 && $CALLS[0][0] eq 'artists/2/releases'), '3: another artist reads its own');
    ok(scalar(!$D->pending('not-an-mbid') && !defined $D->peekList(undef)), '3: not an artist mbid -> not pending, no list');
}

# 4 + 5. The match.
sub g { my (%g) = @_; return { mbid => rg($g{n}), title => $g{t}, date => $g{d} // '', ($g{dg} ? (discogs => $g{dg}) : ()) } }
sub matchOf { my ($list, $rgs) = @_; return Plugins::Discography::Discogs::_match($list, $rgs) }
sub e { my (%e) = @_; return { kind => 'master', year => 1962, thumb => "T$e{id}", %e } }
{
    my $m = matchOf([ e(id => 10, title => 'Interplay'), e(id => 11, title => 'Empathy') ],
                    [ g(n => 1, t => 'Something Else', d => '1962', dg => 'master:10'),
                      g(n => 2, t => 'Empathy', d => '1962', dg => 'master:99') ]);
    ok(scalar(($m->{ rg(1) } // '') eq 'T10'), "4: a group linked to a Discogs master takes that master's thumbnail, whatever its title");
    ok(scalar(!exists $m->{ rg(2) }), '4: a group linked to a master not in the list -> none (never by title)');
    $m = matchOf([ e(id => 20, title => 'Live', kind => 'release') ], [ g(n => 3, t => 'Live', d => '1962', dg => 'release:20') ]);
    ok(scalar(($m->{ rg(3) } // '') eq 'T20'), '4: a release link matches a release entry');
}
{
    my @L = (e(id => 1, title => 'Interplay'),
             e(id => 2, title => 'Unholy', year => 2022),
             e(id => 3, title => 'Waltz for Debby', year => 1961),
             e(id => 4, title => 'Waltz for Debby', year => 1961),
             e(id => 5, title => 'Moon Beams', kind => 'release'),
             e(id => 6, title => 'Moon Beams'),
             e(id => 7, title => 'Owned Elsewhere'),
             e(id => 8, title => 'Twice'),
             e(id => 9, title => "Bill Evans's Finest Hour", year => 2000),
             e(id => 12, title => 'Re: Person I Knew', year => 0));
    my $m = matchOf(\@L, [
        g(n => 1,  t => 'INTERPLAY', d => '1962-07'),
        g(n => 2,  t => 'Unholy (live version)', d => '2022'),
        g(n => 3,  t => 'Waltz for Debby', d => '1961'),
        g(n => 4,  t => 'Interplay', d => '1963'),
        g(n => 5,  t => 'Moon Beams', d => '1962'),
        g(n => 6,  t => 'Owned Elsewhere', d => '1962'),
        g(n => 7,  t => 'Linked', d => '1962', dg => 'master:7'),
        g(n => 8,  t => 'Twice', d => '1962'),
        g(n => 9,  t => 'Twice', d => '1962'),
        g(n => 10, t => "Bill Evans\x{2019}s Finest Hour", d => '2000'),
        g(n => 11, t => 'Re: Person I Knew', d => '1974'),
        g(n => 12, t => 'Interplay', d => ''),
    ]);
    ok(scalar(($m->{ rg(1) } // '') eq 'T1'), '5: the same title (case aside) and year -> its thumbnail');
    ok(scalar(!exists $m->{ rg(2) }), '5: brackets kept: "Unholy (live version)" is not "Unholy" (the A3 name trap)');
    ok(scalar(!exists $m->{ rg(3) }), '5: two Discogs entries of that title and year -> none');
    ok(scalar(!exists $m->{ rg(4) }), '5: another year -> none');
    ok(scalar(($m->{ rg(5) } // '') eq 'T6'), '5: a master and a release of one title -> the master');
    ok(scalar(!exists $m->{ rg(6) } && ($m->{ rg(7) } // '') eq 'T7'), '5: an entry a linked group owns is not taken by title');
    ok(scalar(!exists $m->{ rg(8) } && !exists $m->{ rg(9) }), '5: two groups of one title and year -> neither');
    ok(scalar(($m->{ rg(10) } // '') eq 'T9'), '5: a curly apostrophe reads as a straight one');
    ok(scalar(!exists $m->{ rg(11) }), '5: a Discogs entry with no year -> none');
    ok(scalar(!exists $m->{ rg(12) }), '5: a group with no date -> none');
    my $k = Plugins::Discography::Discogs->can('_titleKey');
    ok(scalar($k->("  Evans \x{2013}  Live\x{201C}x\x{201D} ") eq 'evans - live"x"'), '5: the key: spaces collapsed, en dash and curly quotes plain');
}

# 6. thumbFor reads only the cache; a new read is seen at once.
{
    fresh();
    $RGS{$A} = [ g(n => 1, t => 'Interplay', d => '1962', dg => 'master:178735') ];
    ok(scalar(!defined $D->thumbFor($A, rg(1)) && !@CALLS && !@LINKREQ), '6: list not read -> undef, nothing asked');
    $LINKS{$A} = { discogs => [ 252310 ] };
    $D->warm($A);
    page([ entry(id => 178735, title => 'Interplay') ], 1);
    ok(scalar(($D->thumbFor(uc $A, uc rg(1)) // '') eq 'https://i.discogs.com/178735.jpg'),
       '6: read -> the thumbnail (any case of either mbid)');
    ok(scalar(!defined $D->thumbFor($A, rg(2))), '6: a group not on the page -> undef');
    $RGS{$A} = [ g(n => 2, t => 'Interplay', d => '1962', dg => 'master:178735') ];
    ok(scalar(!defined $D->thumbFor($A, rg(2))), '6: the map is reused for a minute (the page in hand)');
    $NOW += 61;
    ok(scalar(($D->thumbFor($A, rg(2)) // '') eq 'https://i.discogs.com/178735.jpg'), '6: ... then rebuilt from the cached groups');
    $NOW -= 61;
}

# 7. What is a thumbnail.
{
    my $u = Plugins::Discography::Discogs->can('_usable');
    ok(scalar($u->('https://i.discogs.com/abc/rs:fit/w:150/x.jpeg')), '7: an i.discogs.com url');
    ok(scalar(!$u->('https://s.discogs.com/images/default-release.png') && !$u->('https://x/spacer.gif')
              && !$u->('https://x/record90.png')), "7: Discogs' blank record / spacer -> not a thumbnail");
    ok(scalar(!$u->('') && !$u->(undef) && !$u->('ftp://x/y.jpg') && !$u->([])), '7: empty, not a url, not a string -> no');
}

# 8. MusicBrainz's completed list's links (API::peekNextDiscogsLinks).
{
    fresh();
    $LINKS{$A} = { discogs => [ 1 ] };
    $D->warm($A);
    page([ entry(id => 500, title => 'Live in Tokyo', year => 1975),
           entry(id => 7, title => 'Head Hunters', year => 1973) ], 1);
    $RGS{$A} = [ g(n => 1, t => 'Tokyo Live', d => '1976'),                    # no link, no title match
                 g(n => 2, t => 'Head Hunters', d => '1973', dg => 'master:7') ];
    ok(scalar(!defined $D->thumbFor($A, rg(1))), '8: no link and no title match -> none');
    my @told;
    $D->listen(sub { push @told, $_[0] });
    $NEXT{$A} = { rg(1) => 'master:500', rg(2) => 'master:999' };
    ok(scalar(!defined $D->thumbFor($A, rg(1))), '8: (the map is kept a minute)');
    $D->linksChanged(uc $A);
    ok(scalar(($D->thumbFor($A, rg(1)) // '') eq 'https://i.discogs.com/500.jpg'),
       "8: MusicBrainz's completed list links it -> linksChanged rebuilds, the master's thumbnail");
    ok(scalar(@told == 1 && $told[0] eq $A), '8: ... and the listeners told');
    ok(scalar(($D->thumbFor($A, rg(2)) // '') eq 'https://i.discogs.com/7.jpg'),
       "8: a group the page's list already links keeps its own link");
    $D->linksChanged('not-an-mbid');
    ok(scalar(@told == 1), '8: not an artist mbid -> nothing told');
}

# Answer (or fail) the request a predicate picks, in any order: a wave's pages
# land as Discogs answers them, not as they were asked.
sub reply {
    my ($pick, $rels, $pages, $hdr) = @_;
    my ($i) = grep { $pick->($CALLS[$_]) } 0 .. $#CALLS;
    return 0 unless defined $i;
    my $c = splice @CALLS, $i, 1;
    $c->[2]->(defined $rels ? { releases => $rels, pagination => { pages => $pages // 1 } } : {}, $hdr || {});
    return 1;
}
sub pageN { my ($n, @r) = @_; reply(sub { $_[0][1]{page} == $n }, @r) }
sub since { $D->can('readSince') ? $D->readSince($_[0]) : undef }

# 9. A read that kept nothing is noted (review 2026-10-09, finding 1): the next
#    look, the page's or a cover's, is answered at once for FAIL_TTL, so a
#    failing Discogs is neither waited for nor asked on every view. readSince
#    says when a read in flight started (Browse waits at most DG_PAGE_WAIT from
#    then, however many times the page is built).
{
    fresh();
    $LINKS{$A} = { discogs => [ 1 ] };
    my $t0 = $NOW;
    $D->warm($A);
    ok(scalar((since(uc $A) // -1) == $t0), '9: a read in flight says when it started');
    $NOW += 3;
    my $j = 0;
    $D->warm($A, sub { $j++ }, { first => 1 });
    ok(scalar((since($A) // -1) == $t0 && @CALLS == 1), '9: ... a caller joining it does not move that');
    (shift @CALLS)->[2]->({}, {});                  # page 1 not read
    ok(scalar(!defined since($A)), '9: ... and nothing once the read has ended');
    my ($n, $f) = (0, 0);
    $D->warm($A, sub { $n++ });
    $D->warm($A, sub { $f++ }, { first => 1 });
    ok(scalar($n == 1 && $f == 1 && !@CALLS && !$D->pending($A) && !defined since($A)),
       '9: page 1 failed a moment ago -> answered at once, nothing asked, nothing pending');
    $NOW += 110;
    $D->warm($A);
    ok(scalar(!@CALLS), '9: ... nor 110 s on');
    $NOW += 11;
    $D->warm($A);
    ok(scalar(@CALLS == 1), '9: ... then asked again (two minutes)');
    page([ entry(id => 1, title => 'A') ], 1);
    ok(scalar(ref listOf($A) eq 'ARRAY' && @{ listOf($A) } == 1), '9: ... and kept when it is read');

    fresh();
    $LINKS{$A} = { discogs => [ 1 ] };
    $LINKS{$A2} = { discogs => [ 2 ] };
    $D->warm($A);
    (shift @CALLS)->[2]->({}, {});
    $D->warm($A2);
    ok(scalar(@CALLS == 1 && $CALLS[0][0] eq 'artists/2/releases'), "9: another artist's read is not held back by it");

    fresh();
    $LINKS{$A} = { discogs => [ 1 ] };
    $CALL_DIES = 1;
    $D->warm($A);
    $CALL_DIES = 0;
    $D->warm($A);
    ok(scalar(!@CALLS), "9: MAI's request dying -> noted the same way");

    fresh();
    $LINKS{$A} = { discogs => [ 1 ] };
    $D->warm($A);
    $NOW += 121; tick(); $NOW -= 121;
    $D->warm($A);
    ok(scalar(@CALLS == 1), '9: the watchdog -> noted (the one request still out is all there is)');

    fresh();
    $LINKS_FAIL = 1;
    $D->warm($A);
    $LINKS_FAIL = 0;
    $LINKS{$A} = { discogs => [ 1 ] };
    $D->warm($A);
    ok(scalar(@CALLS == 1), "9: MusicBrainz's links not read -> NOT noted (not Discogs failing; the page reads them anyway)");
}

# 10. The title rule's guard and the pages (review 2026-10-09, finding 3).
#     A list kept after a page failed matches titles only in the years the
#     pages in a row from page 1 hold whole (entries come newest first, so a
#     year can straddle the missing page). While the list is read the rule runs
#     on the pages in so far, as before (Discogs.pm's header: holding back page
#     1's lowest year costs a big artist's first draw 1-4 covers), and the map
#     is rebuilt as each page lands, so a pair found later stops the match.
{
    fresh();
    $LINKS{$A} = { discogs => [ 1 ] };
    $RGS{$A} = [ g(n => 1, t => 'Aries',  d => '1991'), g(n => 2, t => 'Gemini', d => '1990'),
                 g(n => 3, t => 'Cancer', d => '1989'), g(n => 4, t => 'Leo',    d => '1987') ];
    $D->warm($A);
    page([ entry(id => 1, title => 'Aries', year => 1991), entry(id => 2, title => 'Gemini', year => 1990) ], 5);
    ok(scalar(($D->thumbFor($A, rg(1)) // '') eq 'https://i.discogs.com/1.jpg'
              && ($D->thumbFor($A, rg(2)) // '') eq 'https://i.discogs.com/2.jpg'),
       "10: page 1 in -> its titles matched at once, its lowest year too (the first draw keeps its covers)");
    ok(scalar(asked() eq '2,3,4,5'), '10: (pages 2-5 asked together)');
    pageN(3, [ entry(id => 4, title => 'Leo', year => 1987) ], 5);
    ok(scalar(($D->thumbFor($A, rg(4)) // '') eq 'https://i.discogs.com/4.jpg'), '10: page 3 before page 2 -> its titles matched as it lands');
    pageN(2, [ entry(id => 3, title => 'Gemini', year => 1990), entry(id => 5, title => 'Cancer', year => 1989) ], 5);
    ok(scalar(!defined $D->thumbFor($A, rg(2)) && ($D->thumbFor($A, rg(3)) // '') eq 'https://i.discogs.com/5.jpg'),
       '10: page 2 brings a second Gemini of 1990 -> none from then on, as the whole list says');
    pageN(4, [ entry(id => 6, title => 'Virgo', year => 1980), entry(id => 7, title => 'Guest', role => 'Appearance') ], 5);
    pageN(5, [ entry(id => 8, title => 'Guest 2', role => 'Appearance') ], 5);
    ok(scalar(ref $KV{$KEY} eq 'ARRAY' && !$D->pending($A)), '10: the read ends -> kept whole (no year held back)');
    ok(scalar(($D->thumbFor($A, rg(4)) // '') eq 'https://i.discogs.com/4.jpg' && !defined $D->thumbFor($A, rg(2))),
       '10: ... Leo matched, Gemini none');

    # His last own entry on page 1, later pages never read: the list is whole.
    fresh();
    $LINKS{$A} = { discogs => [ 1 ] };
    $RGS{$A} = [ g(n => 2, t => 'Gemini', d => '1990') ];
    $D->warm($A);
    page([ entry(id => 1, title => 'Aries', year => 1991), entry(id => 2, title => 'Gemini', year => 1990),
           entry(id => 3, title => 'Guest', year => 1990, role => 'Appearance') ], 9);
    ok(scalar(!@CALLS && ref $KV{$KEY} eq 'ARRAY' && ($D->thumbFor($A, rg(2)) // '') eq 'https://i.discogs.com/2.jpg'),
       "10: page 1 holds his last own entry (pages 2-9 never read) -> kept whole, its lowest year matched");

    # A page failing before his last own entry: what came is kept an hour,
    # titles only above the lowest year of the pages in a row from page 1.
    fresh();
    $LINKS{$A} = { discogs => [ 1 ] };
    $RGS{$A} = [ g(n => 1, t => 'Aries', d => '1991'), g(n => 2, t => 'Gemini', d => '1990'), g(n => 4, t => 'Leo', d => '1987') ];
    $D->warm($A);
    page([ entry(id => 1, title => 'Aries', year => 1991), entry(id => 2, title => 'Gemini', year => 1990) ], 5);
    pageN(3, [ entry(id => 4, title => 'Leo', year => 1987) ], 5);
    pageN(4, [ entry(id => 6, title => 'Virgo', year => 1980) ], 5);
    pageN(5, [ entry(id => 8, title => 'Guest', role => 'Appearance') ], 5);
    pageN(2, undef, 5);                              # page 2 not read
    ok(scalar(ref listOf($A) eq 'ARRAY' && @{ listOf($A) } == 4 && !$D->pending($A)), '10: a page failing -> what came is kept');
    ok(scalar((ttlOf($KEY) // 0) == 3600), '10: ... for an hour, not a day');
    ok(scalar(($D->thumbFor($A, rg(1)) // '') eq 'https://i.discogs.com/1.jpg'
              && !defined $D->thumbFor($A, rg(2)) && !defined $D->thumbFor($A, rg(4))),
       "10: ... and its titles only above page 1's lowest year (page 2 is missing)");
    $RGS{$A} = [ g(n => 9, t => 'Other', d => '1987', dg => 'master:4') ];
    $NOW += 61;
    ok(scalar(($D->thumbFor($A, rg(9)) // '') eq 'https://i.discogs.com/4.jpg'), '10: ... a group linked by id still takes any entry kept');
    $NOW -= 61;

    # A page failing after his last own entry: the list is whole.
    fresh();
    $LINKS{$A} = { discogs => [ 1 ] };
    $RGS{$A} = [ g(n => 2, t => 'Gemini', d => '1990'), g(n => 4, t => 'Leo', d => '1987') ];
    $D->warm($A);
    page([ entry(id => 1, title => 'Aries', year => 1991), entry(id => 2, title => 'Gemini', year => 1990) ], 9);
    pageN(2, [ entry(id => 4, title => 'Leo', year => 1987), entry(id => 7, title => 'Guest', role => 'Appearance') ], 9);
    pageN(3, undef, 9);
    pageN($_, [ entry(id => 10 + $_, title => "G$_", role => 'Appearance') ], 9) for 4 .. 7;
    ok(scalar(ref $KV{$KEY} eq 'ARRAY' && ($D->thumbFor($A, rg(2)) // '') eq 'https://i.discogs.com/2.jpg'
              && ($D->thumbFor($A, rg(4)) // '') eq 'https://i.discogs.com/4.jpg'),
       '10: a page failing after the one with his last own entry -> kept whole, every title matched');

    # Stopped at MAX_PAGES, all his own: kept as read, as before (a pair across
    # pages 20-21 is the same rare case as one during a read).
    fresh();
    $LINKS{$A} = { discogs => [ 1 ] };
    $D->warm($A);
    my $y = 2026;
    while (@CALLS) {
        my @w = @CALLS;
        for (@w) { my $p = $_->[1]{page}; pageN($p, [ entry(id => $p, title => "T$p", year => $y - $p) ], 40) }
    }
    $RGS{$A} = [ g(n => 2, t => 'T20', d => $y - 20) ];
    ok(scalar(ref $KV{$KEY} eq 'ARRAY' && @{ listOf($A) } == 20 && ($D->thumbFor($A, rg(2)) // '') eq 'https://i.discogs.com/20.jpg'),
       '10: stopped at 20 pages, all his own -> kept whole, page 20\'s lowest year matched');
}

# 11. Discogs's minute is one for every read (review 2026-10-09, finding 4): a
#     reply saying fewer than RESERVE calls are left slows EVERY read for the
#     rest of the minute, a refusal's own headers included.
{
    fresh();
    $LINKS{$A} = { discogs => [ 7 ] };
    $LINKS{$A2} = { discogs => [ 8 ] };
    $D->warm($A);
    page([ entry(id => 1, title => 'A') ], 9, { 'x-discogs-ratelimit-remaining' => 8 });
    ok(scalar(asked() eq '2'), '11: one read sees 8 left -> its next page alone');
    $D->warm($A2);
    reply(sub { $_[0][0] eq 'artists/8/releases' }, [ entry(id => 2, title => 'B') ], 9, { 'x-discogs-ratelimit-remaining' => 30 });
    ok(scalar(join(',', map { "$_->[0]:$_->[1]{page}" } @CALLS) eq 'artists/7/releases:2,artists/8/releases:2'),
       "11: another artist's read in the same minute -> one page at a time too");
    $NOW += 61;
    $LINKS{ rg(78) } = { discogs => [ 9 ] };
    $D->warm(rg(78));
    reply(sub { $_[0][0] eq 'artists/9/releases' }, [ entry(id => 3, title => 'C') ], 9, {});
    ok(scalar((grep { $_->[0] eq 'artists/9/releases' } @CALLS) == 6), '11: a minute on -> six at once again');
    $NOW -= 61;

    fresh();
    $LINKS{$A} = { discogs => [ 7 ] };
    $LINKS{$A2} = { discogs => [ 8 ] };
    $D->warm($A);
    (shift @CALLS)->[2]->({}, { 'x-discogs-ratelimit-remaining' => 0 });   # refused
    $D->warm($A2);
    reply(sub { 1 }, [ entry(id => 2, title => 'B') ], 9, {});
    ok(scalar(asked() eq '2'), "11: a refused page's headers (0 left) count too");
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
