#!/usr/bin/env perl
#
# REGRESSION TEST: a composer's works page (docs/classical-plan.md §9, step 1).
#
# Drives the REAL _discographyView for a composer our Open Opus copy holds
# (Mozart, with the shipped data) and for an artist it does not (Radiohead),
# with MusicBrainz, the services and the library stubbed:
#   1. the works page: Options (the switch first), bio, Popular then the
#      genres in order, counts, 30-row paging, similar artists;
#   2. it asks MusicBrainz nothing (no release groups, no completed list, no
#      streaming pool), and a library-tagged composer is not checked by one;
#   3. "In your library": the composer's line first; an "In your library"
#      section ahead of Popular, its rows without the mark; owned works with
#      their album's cover, the rest plain rows with none; an owned work
#      opens its WORK PAGE (plan §10.5 item 4): "About this work", then one
#      row per album holding it, each opening only the work's tracks (track
#      ids; `wka:<album>:<tracks>` for other clients); the library's unmatched
#      works under "Other works in your library"; a work listed in several
#      sections keeps distinct titles;
#   4. the Works | Albums switch: its own row, absolute targets, stale taps,
#      per composer, kept on a same-artist re-entry; on the album page "Show
#      works" sits above the Albums | Singles switch and never touches it;
#   5. a non-composer's page is today's page (no switch, no works).
#
# Standalone, no LMS install needed:  perl tools/t_works.pl
#
use strict;
use warnings;
use FindBin;
use JSON::PP ();

our (%PREF, %CLI, @CALLS, $SIMILAR, $BIO, %KV);

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
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Cache' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Cache' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    my %S = (PLUGIN_DISCOGRAPHY_SHOWING => 'Showing %s (tap for %s)', PLUGIN_DISCOGRAPHY_ALBUMS => 'Albums',
             PLUGIN_DISCOGRAPHY_WORKS => 'Works', PLUGIN_DISCOGRAPHY_SHOW_WORKS => 'Show works',
             PLUGIN_DISCOGRAPHY_SINGLES_EPS => 'Singles & EPs', PLUGIN_DISCOGRAPHY_POPULAR => 'Popular',
             PLUGIN_DISCOGRAPHY_IN_LIBRARY => 'In your library',
             PLUGIN_DISCOGRAPHY_OTHER_WORKS => 'Other works in your library',
             PLUGIN_DISCOGRAPHY_SHOW_MORE => 'Show more', PLUGIN_DISCOGRAPHY_SHOW_LESS => 'Show less',
             PLUGIN_DISCOGRAPHY_ABOUT_WORK => 'About this work',
             PLUGIN_DISCOGRAPHY_ABOUT_WORK_NONE => 'No information found about this work.',
             PLUGIN_DISCOGRAPHY_ABOUT_WORK_LATER => 'Try again later.',
             PLUGIN_DISCOGRAPHY_BORN => 'born %s', PLUGIN_DISCOGRAPHY_ONE_WORK => '1 work',
             PLUGIN_DISCOGRAPHY_N_WORKS => '%s works',
             map { ("PLUGIN_DISCOGRAPHY_GENRE_\U$_" => $_) } qw(Orchestral Chamber Keyboard Stage Vocal));
    *{'Slim::Utils::Strings::cstring'} = sub { $S{ $_[1] } // $_[1] };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');

    *{'Slim::Control::Request::executeRequest'} = sub {
        my (undef, $cmd) = @_;
        my $k = join ' ', @$cmd;
        push @main::CALLS, "cli $k";
        return bless { r => ($main::CLI{$k} || {}) }, 'T::Req';
    };
    *{'Slim::Utils::Timers::setTimer'}   = sub { push @main::CALLS, 'timer' };
    *{'Slim::Utils::Timers::killTimers'} = sub { };

    my $S = 'Plugins::Discography::Sources';
    my $A = 'Plugins::Discography::API';
    *{"${S}::_norm"} = sub { my $s = lc($_[-1] // ''); $s =~ s/[^a-z0-9]+/ /g; $s =~ s/^ +| +$//g; $s };
    *{"${S}::_artistMatch"}   = sub { 1 };
    *{"${S}::orderedSources"} = sub { ({ name => 'Qobuz' }) };
    *{"${S}::localAlbums"}    = sub { [] };
    *{"${S}::localTracks"}    = sub { [] };
    # Sources::libraryAlbumActions' shape, filter off (t_localalbumtracks.pl tests the real one).
    *{"${S}::libraryAlbumActions"} = sub {
        my ($al, $ar) = @_;
        return undef unless defined $al && $al =~ /^\d+$/;
        return { allAvailableActionsDefined => 1,
                 info  => { command => ['albuminfo', 'items'], fixedParams => { album_id => $al } },
                 items => { command => ['browselibrary', 'items'],
                            fixedParams => { mode => 'tracks', album_id => $al, ($ar ? (material_skin_artist_id => $ar) : ()) } },
                 map { $_ => { command => ['playlistcontrol'], fixedParams => { cmd => ($_ eq 'play' ? 'load' : $_), album_id => $al } } } qw(play add insert) };
    };
    *{"${S}::localArtistIdsByMbid"} = sub { () };
    *{"${S}::peekPool"}       = sub { { bySvc => {} } };
    *{"${S}::claimedLocalIds"} = sub { {} };
    *{"${S}::peekMatches"}    = sub { { sections => [], resolved => 1 } };
    *{"${S}::getCandidates"}  = sub { push @main::CALLS, 'getCandidates' };
    *{"${S}::_localAlbumTracks"} = sub { my ($c, $cb, $a, $p) = @_;
                                         push @main::CALLS, "tracks $p->{album_id}"
                                             . ($p->{track_ids} ? ' ' . join(',', @{ $p->{track_ids} }) : '');
                                         $cb->({ items => [ { name => 'track' } ] }) };
    # Sources::libraryWorkActions' shape (t_localalbumtracks.pl tests the real one).
    *{"${S}::libraryWorkActions"} = sub {
        my ($al, $t) = @_;
        return undef unless defined $al && $al =~ /^\d+$/ && $t && @$t;
        my %p = (track_id => join(',', @$t), work_id => -1);
        return { allAvailableActionsDefined => 1,
                 info  => { command => ['albuminfo', 'items'], fixedParams => { album_id => $al } },
                 items => { command => ['browselibrary', 'items'], fixedParams => { mode => 'tracks', album_id => $al, %p } },
                 map { $_ => { command => ['playlistcontrol'], fixedParams => { cmd => ($_ eq 'play' ? 'load' : $_), %p } } } qw(play add insert) };
    };
    *{"${A}::isVarious"}          = sub { 0 };
    *{"${A}::NAME_FETCH"}         = sub { 15 };
    *{"${A}::promoteCompleted"}   = sub { push @main::CALLS, 'promoteCompleted' };
    *{"${A}::getReleaseGroups"}   = sub { my ($c, %a) = @_; push @main::CALLS, "getReleaseGroups $a{mbid}";
                                          $a{onError}->() if $a{onError} };
    *{"${A}::getArtistMbid"}      = sub { my ($c, %a) = @_; push @main::RESOLVE, { %a }; $a{onDone}->(@main::TAGGED) };
    *{"${A}::sharesNameWithProminentAsync"} = sub { $_[3]->(0) };
    *{"${A}::sharesNameWithProminent"}      = sub { 0 };
    *{"${A}::caaImage"}           = sub { 'caa' };
    *{"${A}::peekCoverFlags"}     = sub { undef };
    *{"${A}::peekOfficial"}       = sub { undef };
    *{"${A}::peekReleaseMap"}     = sub { {} };
    *{"${A}::peekLocalReleaseMap"} = sub { {} };
    *{"${A}::peekLocalReleaseTypes"} = sub { {} };
    *{"${A}::peekEditions"}       = sub { {} };
    *{"${A}::clearArtistEmpty"}   = sub { 0 };
    *{"${A}::markArtistEmpty"}    = sub { };
    *{"${A}::peekBands"}          = sub { undef };
    *{"${A}::peekCollabs"}        = sub { undef };
    *{"${A}::peekArtistName"}     = sub { undef };
    *{"${A}::peekArtistAliases"}  = sub { undef };
    *{"${A}::peekArtistEnglishName"} = sub { undef };
}
our @TAGGED;
our @RESOLVE;   # every getArtistMbid call's arguments (section 6)

package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}
package T::Prefs; our $AUTOLOAD; sub get { $main::PREF{ $_[1] } } sub AUTOLOAD { return } sub DESTROY {}
package T::Cache; our $AUTOLOAD; sub get { $_[1] =~ /^dsc:similar:/ ? $main::SIMILAR : $main::KV{ $_[1] } }
# Only "About this work" keeps its text here; everything else stays uncached, as before.
sub set { $main::KV{ $_[1] } = $_[2] if $_[1] =~ /^dsc:wrev:/; return }
sub AUTOLOAD { return } sub DESTROY {}
package T::Req; sub getResult { $_[0]{r}{ $_[1] } }
package T::Client; sub id { $_[0][0] }
sub execute { push @main::CALLS, 'execute ' . join(' ', @{ $_[1] }) }
# A CLI request for Browse::playCommand.
package T::PReq;
sub new { my ($c, %p) = @_; bless { p => \%p, done => 0 }, $c }
sub getParam { $_[0]{p}{ $_[1] } }
sub client { $_[0]{p}{_client} }
sub setStatusDone { $_[0]{done}++ }
sub setStatusProcessing { }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;
my $B = 'Plugins::Discography::Browse';
my $C = 'Plugins::Discography::Classical';

binmode STDOUT, ':encoding(UTF-8)';   # labels carry the composer line's dash
my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

%PREF = (show_types => 'ALBUMS,EPS,SINGLES,COMPILATIONS,LIVE,OTHER', show_bio => 1,
         show_library_extras => 1, show_streaming_extras => 0, hide_unmatched => 0, official_wait => 15);
$SIMILAR = [ 'Joseph Haydn' ];

{   no warnings 'redefine'; no strict 'refs';
    *{"${B}::_fetchArtistBio"}   = sub { $_[3]->('Mozart was a composer.') };
    *{"${B}::_fetchExactBio"}    = sub { $_[3]->('Mozart was a composer.') };
    *{"${B}::_warmArtistExtras"} = sub { $_[3]->() };
    *{'Plugins::Discography::Covers::noteBrowse'} = sub { };
}

my $client = bless ['aa:bb'], 'T::Client';
my $table  = do { local $/; open my $fh, '<:raw', "$FindBin::Bin/../Discography/classical/composers.json" or die; JSON::PP->new->utf8->decode(<$fh>) };
my ($MOZART) = grep { $table->{composers}{$_}{c} eq 'Wolfgang Amadeus Mozart' } keys %{ $table->{composers} };
my $RADIOHEAD = 'a74b1b7f-71a5-4011-9441-d0b5e4122711';
my $works = $C->works($MOZART);

# Simon's Mozart, as LMS lists it: movement-level tags, and one aria.
%CLI = ('works 0 2000 artist_id:151651' => { works_loop => [
            { work_id => 7413, work => 'Clarinet Concerto in A major, K. 622: Adagio', composer_id => '151651', album_id => 49625, artwork_track_id => 'bd0fc9e5' },
            { work_id => 7415, work => 'Piano Concerto No. 21 in C major ("Elvira Madigan") K. 467: 2. Andante', composer_id => '151651', album_id => 49625, artwork_track_id => 'bd0fc9e5' },
            { work_id => 7457, work => 'Voi Che Sapete (The Marriage Of Figaro)', composer_id => '151651', album_id => 49632, artwork_track_id => 'c0ffee12' },
            { work_id => 9999, work => 'La Mer', composer_id => '151589', album_id => 1 } ] },
        # A work's albums (Classical::albumsFor): the work's tracks, then the albums.
        'tracks 0 2000 work_id:7415 performance:-1 tags:eit' => { titles_loop => [
            { id => 7002, album_id => '49625', disc => 1, tracknum => '5' },
            { id => 7001, album_id => '49625', disc => 1, tracknum => '4' } ] },
        'albums 0 1 album_id:49625 tags:ljya' => { albums_loop => [
            { id => 49625, album => 'Masters of Music: Mozart', year => 1995, artwork_track_id => 'bd0fc9e5' } ] });

my $opts0 = { artist_id => 151651, artist => 'Wolfgang Amadeus Mozart', mbid => $MOZART, features => 'hi' };
sub page {
    my ($o) = @_;
    my $got;
    $B->can('topLevel') or die;
    $B->can('_discographyView')->($client, sub { $got = shift }, { %{ $o || $opts0 } });
    return $got ? $got->{items} : undef;
}
sub row  { my ($items, $id) = @_; (grep { ($_->{id} // '') eq $id } @{ $items || [] })[0] }
sub has  { scalar row(@_) }
sub hdrs { [ map { $_->{name} } grep { ($_->{id} // '') =~ /^sect:W:/ } @{ $_[0] || [] } ] }
sub tap  { my ($id, $o) = @_; my $got;
           $B->can('_listItemDispatch')->($client, sub { $got = shift }, { %{ $o || $opts0 } }, $id); $got }
sub calls { my $re = shift; scalar grep { /$re/ } @CALLS }

# Seed the per-player ctx as topLevel's fresh entry does.
$B->can('topLevel')->($client, sub {}, { params => { artist => 'Wolfgang Amadeus Mozart', mbid => $MOZART, features => 'hi', item => 'none' } });

# ---------------------------------------------------------------------------
print "\n# 1. the works page\n";
@CALLS = ();
my $p = page();
ok($p && has($p, 'sect:OPT'), '1: a composer\'s page renders, with Options');
my @ids = map { $_->{id} // '' } @$p;
ok($ids[0] eq '' && ($p->[0]{type} // '') eq 'text' && $ids[1] eq 'sect:OPT' && $ids[2] eq 'act:works:albums',
   '1: the composer\'s line first (plan §10.5 item 2), then Options, the switch first');
{
    my $mz  = $table->{composers}{$MOZART};
    my $sum = "$mz->{b}\x{2013}$mz->{d} \x{00B7} $mz->{e} \x{00B7} " . scalar(@$works) . ' works';
    ok(index($p->[0]{name} // '', $sum) >= 0, "1: it reads years, epoch, the works listed ($sum)");
    my $sr = $B->can('_composerSummaryRow');
    my ($alive) = $sr->($client, { b => '1935', d => '', e => 'Post-War' }, 1);
    ok(scalar(($alive->{name} // '') =~ /born 1935 \x{00B7} Post-War \x{00B7} 1 work</), '1: no death year: "born", and one work is "1 work"');
    ok(!$sr->($client, { b => '', d => '', e => '' }, 0), '1: nothing known: no line');
}
ok(row($p, 'act:works:albums')->{name} eq 'Showing Works (tap for Albums)', '1: it reads "Showing Works (tap for Albums)"');
ok(has($p, 'act:search') && has($p, 'opt:more'), '1: Search and More options follow');
ok(!has($p, 'act:view:singles') && !has($p, 'act:view:albums'), '1: no Albums | Singles switch on the works page');
ok(has($p, 'sect:BIO'), '1: the biography is there');
my $pop = grep { $_->{popular} } @$works;
my %n; $n{ $_->{genre} }++ for @$works;
my @want = ('In your library (2)', "Popular ($pop)",   # K. 467 and K. 622 are owned in the fixture
            map { "$_ ($n{$_})" } grep { $n{$_} } qw(Orchestral Chamber Keyboard Stage Vocal));
ok(join('|', @{ hdrs($p) }[0 .. $#want]) eq join('|', @want),
   '1: In your library, Popular, then the genres in order, with their counts: ' . join(', ', @{ hdrs($p) }));
my ($oi) = grep { ($ids[$_] // '') eq 'sect:W:Orchestral' } 0 .. $#ids;
my @orch = @$p[ $oi + 1 .. $oi + 31 ];
ok(30 == grep({ ($_->{type} // '') =~ /^(?:text|link)$/ } @orch[0 .. 29]) && ($orch[30]{id} // '') eq 'page:W:Orchestral:60',
   '1: Orchestral shows 30 works, then Show more (page:W:Orchestral:60)');
my @orchW = grep { $_->{genre} eq 'Orchestral' } @$works;
# A work row's title as shown: a work not held carries it in its first <div>
# on Material (_workTextHtml).
my $shown = sub {
    my $n = ($_[0]{name} // '') =~ s/\x{2060}+$//r;
    return $n unless $n =~ m{^<div[^>]*>(.*?)</div>};
    return $1 =~ s/&lt;/</gr =~ s/&gt;/>/gr =~ s/&amp;/&/gr;
};
ok($shown->($orch[0]) eq $orchW[0]{title}, '1: in the file\'s display order (recommended first): ' . $orchW[0]{title});
ok(has($p, 'sect:SIMILAR') && grep({ ($_->{name} // '') eq 'Joseph Haydn' } @$p), '1: similar artists, as today');

# ---------------------------------------------------------------------------
print "\n# 2. no MusicBrainz\n";
ok(!calls(qr/^getReleaseGroups/), '2: no release-group request');
ok(!calls(qr/^promoteCompleted/), '2: no completed-list promotion');
ok(!calls(qr/^getCandidates/), '2: no streaming pool');
{
    my $got;
    @CALLS = (); @TAGGED = ($MOZART, 1);
    $B->can('_resolveArtistMbid')->($client, { artist => 'Wolfgang Amadeus Mozart' }, sub { $got = shift });
    ok($got eq $MOZART && !calls(qr/^getReleaseGroups/), '2: a library tag naming a composer is not checked with a release-group request');
    @CALLS = (); @TAGGED = ($RADIOHEAD, 1);
    $B->can('_resolveArtistMbid')->($client, { artist => 'Radiohead' }, sub { $got = shift });
    ok(calls(qr/^getReleaseGroups/), '2: (control) any other tag still is');
}

# ---------------------------------------------------------------------------
print "\n# 3. In your library\n";
my ($k467) = grep { $_->{title} =~ /^Piano Concerto no\. 21 in C major, K\.\s?467/ } @$works;
my @k467rows = grep { ($_->{id} // '') eq "wk:$k467->{id}" } @$p;
my ($libRow, $own) = @k467rows[0, 1];   # the "In your library" section's row, then Popular's
my $want467 = join(" \x{00B7} ", grep { length } ($k467->{year}, 'In your library', $k467->{instr}, $k467->{subtitle}));
ok($own && $own->{type} eq 'link' && ($own->{line2} // '') eq $want467,
   '3: an owned work is a link marked "In your library", after its year (' . ($own->{line2} // '') . ')');
my $wantLib = join(" \x{00B7} ", grep { length } ($k467->{year}, $k467->{instr}, $k467->{subtitle}));
ok($libRow && $libRow->{type} eq 'link' && ($libRow->{line2} // '') eq $wantLib,
   '3: under "In your library" the same work leaves the mark off (the heading says it)');
{
    my @i   = map { $_->{id} // '' } @$p;
    my ($l) = grep { $i[$_] eq 'sect:W:LIB' } 0 .. $#i;
    my ($q) = grep { $i[$_] eq 'sect:W:POP' } 0 .. $#i;
    my @lib = @$p[ $l + 1 .. $q - 1 ];
    ok(defined $l && defined $q && $l < $q && @lib == 2 && !grep({ ($_->{id} // '') !~ /^wk:/ } @lib),
       '3: "In your library" comes before Popular and holds the owned works only (' . scalar(@lib) . ')');
}
ok(($own->{image} // '') eq '/music/bd0fc9e5/cover' && ($libRow->{image} // '') eq '/music/bd0fc9e5/cover',
   '3: an owned work shows its album\'s cover (plan §10.5 item 1)');
{   # Line 2's order (plan §10): year, the mark, instrumentation, subtitle - Material
    # cuts line 2 at the edge, so the short year and the mark go first.
    my $wf = { id => 'x', title => 'Violin Concerto no. 3', subtitle => 'Concerto', year => 1775,
               instr => 'violin, 2 oboes, 2 horns, strings' };
    my $r1 = $B->can('_workRow')->($client, {}, $wf, [ { work_id => 1 } ]);
    ok(($r1->{line2} // '') eq "1775 \x{00B7} In your library \x{00B7} violin, 2 oboes, 2 horns, strings \x{00B7} Concerto",
       '3: line 2 reads year, mark, instrumentation, subtitle (' . ($r1->{line2} // '') . ')');
    my $r2 = $B->can('_workRow')->($client, {}, $wf, undef);
    ok(($r2->{line2} // '') eq "1775 \x{00B7} violin, 2 oboes, 2 horns, strings \x{00B7} Concerto" && $r2->{type} eq 'text'
       && $r2->{name} eq 'Violin Concerto no. 3',
       '3: a work not held, on a client without headers: a plain row, the same line 2 without the mark');
    my $r3 = $B->can('_workRow')->($client, {}, { id => 'y', title => 'T', subtitle => '', year => '', instr => '' }, undef);
    ok(!exists $r3->{line2}, '3: nothing known: no line 2');

    # On Material (features h) a work not held is drawn like an owned row
    # (Simon 2026-10-08: "in Bold like it is when owned"): Material forces a
    # text row's title to weight 200, an owned title has --std-weight (400).
    my $T  = "<div style='font-weight:var(--std-weight,400)'>";
    my $L2 = "<div style='font-weight:var(--std-weight,400);font-size:var(--small-font-size,13px);color:var(--icon-color);"
           . "opacity:var(--sub-opacity,0.7);white-space:nowrap;overflow:hidden;text-overflow:ellipsis'>";
    my $m2 = $B->can('_workRow')->($client, { features => 'hi' }, $wf, undef);
    ok($m2->{type} eq 'text' && !exists $m2->{line2} && !exists $m2->{image} && !exists $m2->{id}
       && $m2->{name} eq "${T}Violin Concerto no. 3</div>${L2}1775 \x{00B7} violin, 2 oboes, 2 horns, strings \x{00B7} Concerto</div>",
       '3: on Material a work not held has its title at the owned weight and line 2 in the subtitle style, still a text row with no image');
    my $m3 = $B->can('_workRow')->($client, { features => 'hi' }, { id => 'y', title => 'T', subtitle => '', year => '', instr => '' }, undef);
    ok($m3->{name} eq "${T}T</div>", '3: ...and nothing known: the title alone');
    my $m4 = $B->can('_workRow')->($client, { features => 'hi' },
        { id => 'z', title => 'Trio <"Kegelstatt"> & more', subtitle => 'for <3', year => '', instr => '' }, undef);
    ok($m4->{name} eq "${T}Trio &lt;\"Kegelstatt\"&gt; &amp; more</div>${L2}for &lt;3</div>",
       '3: ...its title and line 2 escaped for the HTML');
    my $m1 = $B->can('_workRow')->($client, { features => 'hi' }, $wf, [ { work_id => 1 } ]);
    ok($m1->{type} eq 'link' && $m1->{name} eq 'Violin Concerto no. 3' && exists $m1->{line2},
       '3: an owned work on Material is unchanged: a link with its plain title and line 2');
}
{
    my %seen = map { $_->{name} => 1 } @k467rows;
    ok($k467->{popular} && @k467rows == 3 && keys(%seen) == 3
       && !grep({ ($_->{name} =~ s/\x{2060}+$//r) ne $k467rows[0]{name} } @k467rows),
       '3: an owned popular work is listed three times (In your library, Popular, its genre), each a distinct title (Material keys rows by title)');
}
my ($plain) = grep { ($_->{type} // '') eq 'text' && !defined $_->{id} } @orch;
ok($plain && ($plain->{name} // '') =~ /^<div style='font-weight:var\(--std-weight,400\)'>/
   && ($plain->{name} // '') !~ /library/ && !exists $plain->{line2} && !exists $plain->{image},
   '3: a work not held is a text row: no id, no mark, no image (a text row with one is tappable in Material), its title at the owned weight');
ok(!grep({ ($_->{name} // '') eq 'La Mer' } @$p), '3: a work Mozart only performed in LMS\'s list is not his');
my $other = row($p, 'lw:7457');
ok($other && $other->{name} eq 'Voi Che Sapete (The Marriage Of Figaro)' && has($p, 'sect:W:OTHER'),
   '3: the aria no Open Opus work matched is under "Other works in your library"');
ok(($other->{image} // '') eq '/music/c0ffee12/cover', '3: ...with its album\'s cover');

# Tapping an owned work opens ITS PAGE (plan §10.5 item 4): "About this work",
# "In your library (1)", then the album holding it.
@CALLS = ();
my $wp    = tap("wk:$k467->{id}");
my @wpi   = @{ ($wp && $wp->{items}) || [] };
my ($ab, $wh, $al) = @wpi;
ok(@wpi == 3 && ($ab->{name} // '') eq 'About this work' && ($wh->{name} // '') eq 'In your library (1)'
   && ($al->{name} // '') eq 'Masters of Music: Mozart' && $al->{type} eq 'playlist',
   '3: tapping it opens its page: About this work, In your library (1), the album holding it');
ok(($ab->{passthrough}[0]{title} // '') eq $k467->{title}
   && ($ab->{passthrough}[0]{composer} // '') eq 'Wolfgang Amadeus Mozart',
   '3: "About this work" asks by the Open Opus title and the composer\'s name');
{
    no strict 'refs'; no warnings 'redefine';
    my $n = 0;
    local *{"${B}::_fetchWorkAbout"} = sub { $n++ };
    tap("wk:$k467->{id}");
    ok(!$n, '3: the page itself asks MAI nothing (About is fetched on tap)');
}
# Opens and plays as LMS's own work view does: Material's album page with the
# work's tracks only (track ids, work_id:-1), Play the same tracks in album
# order. The XMLBrowser play string and the coderef stay for other clients.
ok(($al->{play} // '') eq 'db:album.id=49625', '3: its play string is the library album (db:album.id)');
ok(join(' ', @{ $al->{itemActions}{play}{command} || [] }) eq 'playlistcontrol'
   && ($al->{itemActions}{play}{fixedParams}{cmd} // '') eq 'load'
   && ($al->{itemActions}{play}{fixedParams}{track_id} // '') eq '7001,7002'
   && ($al->{itemActions}{play}{fixedParams}{work_id} // '') eq '-1'
   && !exists $al->{itemActions}{play}{fixedParams}{album_id},
   '3: Play is playlistcontrol load of the work\'s tracks, in track order (7001,7002), not the whole album');
ok(join(' ', @{ $al->{itemActions}{items}{command} || [] }) eq 'browselibrary items'
   && ($al->{itemActions}{items}{fixedParams}{mode} // '') eq 'tracks'
   && ($al->{itemActions}{items}{fixedParams}{album_id} // '') eq '49625'
   && ($al->{itemActions}{items}{fixedParams}{track_id} // '') eq '7001,7002'
   && !exists $al->{itemActions}{items}{fixedParams}{artist_id},
   '3: a tap opens Material\'s album page with only the work\'s tracks, no artist narrowing');
ok($al->{itemActions}{allAvailableActionsDefined} && $al->{itemActions}{info},
   '3: every action defined + info, as a library album row (the My Apps empty-page trap, 0.56.58)');
ok(($al->{id} // '') eq 'wka:49625:7001,7002' && $al->{url} == \&Plugins::Discography::Sources::_localAlbumTracks
   && join(',', @{ $al->{passthrough}[0]{track_ids} || [] }) eq '7001,7002',
   '3: for other clients the row\'s id and coderef carry the work\'s tracks');
ok(($al->{line2} // '') eq '1995', '3: line 2 is its year');
@CALLS = ();
my $tr;
$B->can('topLevel')->($client, sub { $tr = shift },
    { params => { artist => 'Wolfgang Amadeus Mozart', mbid => $MOZART, features => 'hi', item => 'wka:49625:7001,7002' } });
ok(calls(qr/^tracks 49625 7001,7002$/) && $tr && $tr->{items}[0]{name} eq 'track',
   '3: topLevel answers wka:49625:7001,7002 with the work\'s tracks');
ok(!calls(qr/^cli works/), '3: ...without rebuilding the works page');
@CALLS = ();
$B->can('topLevel')->($client, sub { $tr = shift },
    { params => { artist => 'Wolfgang Amadeus Mozart', mbid => $MOZART, features => 'hi', item => 'wka:49625' } });
ok(calls(qr/^tracks 49625$/), '3: an older row\'s wka:49625 still opens the whole album');

# The work row plays the work (Simon 2026-10-08, "buttons at top dont do what
# they should"): Material puts Append / Next / Play on the work page acting on
# the WORK ROW, so it carries its own, to the plugin's playcmd with its LMS works.
for my $r ([ $own, '7415', 'an owned work' ], [ $other, '7457', 'an "Other works" row' ]) {
    my ($w, $ids, $what) = @$r;
    my $a = $w->{itemActions} || {};
    ok(!grep({ join(' ', @{ $a->{$_}{command} || [] }) ne 'discography playcmd'
               || ($a->{$_}{fixedParams}{cmd} // '') ne $_
               || ($a->{$_}{fixedParams}{works} // '') ne $ids } qw(play add insert))
       && join(' ', @{ $a->{items}{command} || [] }) eq 'discography items',
       "3: $what row has its own play / add / insert: discography playcmd works:$ids (and still opens its page)");
}
{
    my $l = $B->can('_libWorkLink')->($client, $opts0, { name => 'W' }, 'wk:x', [ 7415, 7413, 'x' ], {});
    ok(($l->{itemActions}{play}{fixedParams}{works} // '') eq '7415,7413',
       '3: a work held as several LMS works plays them all (ids only)');
}
{
    my $preq = sub { T::PReq->new(_client => $client, @_) };
    my $run  = sub { my $q = $preq->(@_); @CALLS = (); $B->can('playCommand')->($q); return $q };
    my $q = $run->(cmd => 'play', works => '7415');
    ok(calls(qr/^execute playlistcontrol cmd:load track_id:7001,7002 work_id:-1$/) && $q->{done} == 1,
       '3: playcmd works:7415 play = playlistcontrol load of the work\'s tracks in track order, work_id:-1');
    $run->(cmd => 'add', works => '7415');
    ok(calls(qr/^execute playlistcontrol cmd:add track_id:7001,7002 work_id:-1$/), '3: ...add appends them');
    $run->(cmd => 'insert', works => '7415');
    ok(calls(qr/^execute playlistcontrol cmd:insert track_id:7001,7002 work_id:-1$/), '3: ...insert plays them next');
    {   # Two LMS works on two albums: album by album as the work page lists them (year first).
        local $CLI{'tracks 0 2000 work_id:7413 performance:-1 tags:eit'} = { titles_loop => [
            { id => 8002, album_id => '49700', disc => 1, tracknum => '2' },
            { id => 8001, album_id => '49700', disc => 1, tracknum => '1' } ] };
        local $CLI{'albums 0 2 album_id:49625,49700 tags:ljya'} = { albums_loop => [
            { id => 49625, album => 'Masters of Music: Mozart', year => 1995 },
            { id => 49700, album => 'Earlier Mozart', year => 1990 } ] };
        $run->(cmd => 'play', works => '7415,7413');
        ok(calls(qr/^execute playlistcontrol cmd:load track_id:8001,8002,7001,7002 work_id:-1$/),
           '3: a work held as two LMS works on two albums plays album by album, the earlier album first');
    }
    $q = $run->(cmd => 'play', works => '7415;stop');
    ok(!calls(qr/^execute/) && $q->{done}, '3: a works param that is not a list of ids plays nothing (and answers)');
    $run->(cmd => 'play', works => '7415,abc');
    ok(!calls(qr/^execute/), '3: ...nor one with a valid id beside junk (only our own rows write it, ids only)');
    $q = $run->(cmd => 'play', works => '424242');
    ok(!calls(qr/^execute/) && $q->{done}, '3: a work with no library tracks plays nothing (and answers)');
    $q = T::PReq->new(cmd => 'play', works => '7415'); @CALLS = ();
    $B->can('playCommand')->($q);
    ok(!calls(qr/^execute/), '3: no player: nothing played');
}

# "About this work": MAI asked on tap, its text kept; MAI with nothing says so.
{
    no strict 'refs'; no warnings 'redefine';
    my @asked;
    local *{'Slim::Utils::PluginManager::isEnabled'} = sub { 1 };
    local *{'Plugins::MusicArtistInfo::WorkInfo::getWorkReview'} = sub {
        my ($c, $cb, $prm, $a) = @_;
        push @asked, "$a->{composer}|$a->{title}";
        $cb->([ { name => "<p>The concerto was finished in 1785.</p>\n<p>Its second movement became famous in 1967.</p>" } ]);
    };
    local %KV = ();
    my $got;
    $ab->{url}->($client, sub { $got = shift }, {}, $ab->{passthrough}[0]);
    my $text = join ' ', map { $_->{name} // '' } @{ ($got && $got->{items}) || [] };
    ok(scalar(@asked == 1 && $asked[0] eq "Wolfgang Amadeus Mozart|$k467->{title}"
              && $text =~ /finished in 1785/ && $text =~ /became famous/),
       '3: About this work: MAI asked by composer + title, its whole text shown');
    $ab->{url}->($client, sub { $got = shift }, {}, $ab->{passthrough}[0]);
    ok(@asked == 1, '3: ...and kept, so a second tap asks nothing');
    no warnings 'redefine';
    local *{'Plugins::MusicArtistInfo::WorkInfo::getWorkReview'} = sub { push @asked, 'x'; $_[1]->([]) };
    my $none = $B->can('_aboutWorkRow')->($client, { title => 'Unknown Piece', composer => 'Wolfgang Amadeus Mozart' });
    $none->{url}->($client, sub { $got = shift }, {}, $none->{passthrough}[0]);
    ok(scalar(($got->{items}[0]{name} // '') =~ /No information found/), '3: MAI with nothing: "No information found"');
    # MAI's own NOT-FOUND answer is an item (ledger A3 `MAI's NOT-FOUND answer is an item`), never the text.
    local *{'Slim::Utils::Strings::stringExists'} = sub { 1 };
    local *{'Plugins::MusicArtistInfo::WorkInfo::getWorkReview'} = sub { $_[1]->([ { name => '<p>PLUGIN_MUSICARTISTINFO_NOT_FOUND</p>' } ]) };
    my $nf = $B->can('_aboutWorkRow')->($client, { title => 'Another Piece', composer => 'Wolfgang Amadeus Mozart' });
    $nf->{url}->($client, sub { $got = shift }, {}, $nf->{passthrough}[0]);
    ok(scalar(($got->{items}[0]{name} // '') =~ /No information found/) && @{ $got->{items} } == 1,
       '3: MAI\'s own "not found" item is not shown as the text');
    ok(!$B->can('_aboutWorkRow')->($client, { title => 'T', composer => '' }), '3: no composer, no About row');
}

# A library without WORK tags: the list, no marks, no Other works.
{
    local %CLI = ();
    my $q = page();
    ok($q && hdrs($q)->[0] eq "Popular ($pop)" && !has($q, 'sect:W:OTHER') && !grep({ ($_->{line2} // '') =~ /library/ } @$q),
       '3: no WORK tags: every work listed, none marked, no "Other works"');
}

# ---------------------------------------------------------------------------
print "\n# 4. the Works | Albums switch\n";
@CALLS = ();
# The row's own url run twice (a positional re-walk) from the works page: an
# ABSOLUTE target, so the second run cannot flip it back.
{
    my $sw = row($p, 'act:works:albums');
    $sw->{url}->($client, sub {}, {}, $sw->{passthrough}[0]);
    my $once = $B->can('_worksOff')->($client, $MOZART);
    $sw->{url}->($client, sub {}, {}, $sw->{passthrough}[0]);
    ok($once && $B->can('_worksOff')->($client, $MOZART), '4: the switch run twice still means albums (absolute target)');
    my $bk = $B->can('_worksToggleItem')->($client, $opts0, $MOZART, 0);   # back to works
    $bk->{url}->($client, sub {}, {}, $bk->{passthrough}[0]);
}
ok(tap('act:works:albums'), '4: the switch tap answers');
my $alb = page();
ok(calls(qr/^getReleaseGroups $MOZART/), '4: the page is now the album page (release groups asked)');
ok(!has($alb, 'act:works:albums'), '4: and no works rows');
my $stale = tap('act:works:albums');
ok($stale && !@{ $stale->{items} || [] }, '4: a stale switch tap (the works page\'s, again) finds no row and answers empty');
@CALLS = ();
page();
ok(calls(qr/^getReleaseGroups $MOZART/), '4: ...and the page stays the album page');

# The album page's Options (the REAL _buildList, as a composer).
my $rg = sub { { mbid => sprintf('%08d-0000-0000-0000-000000000000', $_[2]), title => $_[0], type => $_[1], secondary => [], date => '2000-01-01' } };
my $list = $B->can('_buildList')->($client, { %$opts0, composer => 1 }, $MOZART,
    [ $rg->('Requiem', 'Album', 1), $rg->('Rondo', 'Single', 2) ], 'Bio.', []);
my @lids = map { $_->{id} // '' } @$list;
ok($lids[0] eq 'sect:OPT' && $lids[1] eq 'act:works:works' && $lids[2] eq 'act:view:singles',
   '4: album page: "Show works" first, then the Albums | Singles switch');
ok(row($list, 'act:works:works')->{name} eq 'Show works', '4: it reads "Show works"');
ok(row($list, 'act:view:singles')->{name} eq 'Showing Albums (tap for Singles & EPs)', '4: the Albums | Singles switch is unchanged');
my $plainList = $B->can('_buildList')->($client, { %$opts0 }, $RADIOHEAD, [ $rg->('Kid A', 'Album', 3) ], 'Bio.', []);
ok(!grep({ ($_->{id} // '') =~ /^act:works/ } @$plainList), '5: a non-composer\'s page has no works switch');

# Back to works through the album page's row (dispatched as Material sends it).
{
    no warnings 'redefine'; no strict 'refs';
    local *{"${B}::_discographyView"} = sub { my ($c, $cb) = @_; $cb->({ items => $list }) };
    ok(tap('act:works:works'), '4: "Show works" answers');
}
@CALLS = ();
my $back = page();
ok(has($back, 'act:works:albums') && !calls(qr/^getReleaseGroups/), '4: and the works page is back, with no release-group request');

# Per composer: switching Mozart to albums leaves another composer on works.
tap('act:works:albums');
my ($BACH) = grep { $table->{composers}{$_}{c} eq 'Johann Sebastian Bach' } keys %{ $table->{composers} };
@CALLS = ();
my $bach = page({ artist => 'Johann Sebastian Bach', mbid => $BACH, features => 'hi' });
ok(has($bach, 'act:works:albums') && !calls(qr/^getReleaseGroups/), '4: the switch is per composer: Bach still opens on works');
tap('act:works:works');

# Kept on a same-artist re-entry (topLevel's $same branch; source check, as t_view does).
{
    open my $fh, '<', "$FindBin::Bin/../Discography/Browse.pm" or die $!;
    my $src = do { local $/; <$fh> };
    ok(scalar($src =~ /\$same \? \([^)]*works\s*=>\s*\$prev->\{works\}[^)]*\) : \(\)/s),
       '4: a same-artist fresh entry keeps the works switch');
}

# ---------------------------------------------------------------------------
print "\n# 5. a non-composer\n";
@CALLS = ();
my $rh = page({ artist => 'Radiohead', mbid => $RADIOHEAD, features => 'hi' });
ok(calls(qr/^getReleaseGroups $RADIOHEAD/), '5: Radiohead takes today\'s path (release groups asked)');
ok(!grep({ ($_->{id} // '') =~ /^(?:act:works|sect:W:)/ } @{ $rh || [] }), '5: and gets no works rows');

# ---------------------------------------------------------------------------
# 6. A NAME-ONLY PAGE FOR AN ARTIST THE LIBRARY HOLDS OPENS AS THAT LIBRARY
#    ARTIST (2026-10-08: a Similar artists row "Bob" opened Bob Dylan): the
#    real _discographyView asks Sources::libraryArtistIdByName and resolves by
#    the id it gives, exactly as the artist's library page does.
# ---------------------------------------------------------------------------
{
    no strict 'refs'; no warnings 'redefine';
    my @asked;
    local *{"Plugins::Discography::Sources::libraryArtistIdByName"} = sub { push @asked, $_[0]; $_[0] eq 'Bob' ? 152344 : undef };
    local @TAGGED = ();
    @RESOLVE = (); page({ artist => 'Bob', features => 'hi' });
    ok(scalar(@RESOLVE == 1 && ($RESOLVE[0]{artist_id} // '') eq '152344' && "@asked" eq 'Bob'),
       '6: a name-only page for a library artist resolves by its library id');
    @RESOLVE = (); @asked = (); page({ artist => 'Nobody Owned', features => 'hi' });
    ok(scalar(@RESOLVE == 1 && !defined $RESOLVE[0]{artist_id}),
       '6: control: a name the library does not hold resolves by name, as before');
    @RESOLVE = (); @asked = (); page({ artist => 'Bob', artist_id => 4242, features => 'hi' });
    ok(scalar(@RESOLVE == 1 && ($RESOLVE[0]{artist_id} // '') eq '4242' && !@asked),
       '6: control: an id given is kept, nothing looked up');
    @RESOLVE = (); @asked = (); page({ artist => 'Bob', mbid => $MOZART, features => 'hi' });
    ok(scalar(!@RESOLVE && !@asked), '6: control: an mbid given (a band or same-name link) is browsed as before');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
