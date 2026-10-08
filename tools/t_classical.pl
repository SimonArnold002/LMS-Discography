#!/usr/bin/env perl
#
# REGRESSION TEST: Classical.pm, the composer works page's data and matching
# (docs/classical-plan.md §9, step 1).
#
#   1. The shipped data: the composer table by MusicBrainz id, a composer's
#      works in display order, each work's id the one build_data.py computes.
#   2. PARITY: the Perl port of wrule.py gives the Python's answer for every
#      library work in tools/fixtures/classical_parity.json (Simon's 397 WORK
#      tags whose composer is in the table; written by tools/classical/parity.py
#      against the same shipped files).
#   3. The library side: which contributor ids are read (artist_id, else the
#      MusicBrainz tag, else the name as COMPOSER), works a contributor only
#      PERFORMED dropped, the owned map and its memo, a work's albums.
#
# Standalone, no LMS install needed:  perl tools/t_classical.pl
#
use strict;
use warnings;
use FindBin;
use JSON::PP ();
use Time::HiRes ();

our (%CLI, @CLI_LOG, %TAG, %CTAG);

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Control::Request Plugins::Discography::Plugin
                  Plugins::Discography::Sources)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'} = sub { bless {}, 'T::Null' };
    push @{'Slim::Utils::Log::ISA'}, 'Exporter';
    @{'Slim::Utils::Log::EXPORT'} = ('logger');
    # executeRequest answers from %CLI by the command's own words, and logs them.
    *{'Slim::Control::Request::executeRequest'} = sub {
        my (undef, $cmd) = @_;
        my $k = join ' ', @$cmd;
        push @main::CLI_LOG, $k;
        return bless { r => ($main::CLI{$k} || {}) }, 'T::Req';
    };
    *{'Plugins::Discography::Sources::localArtistIdsByMbid'} = sub { @{ $main::TAG{ $_[0] } || [] } };
}

package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}
package T::Req;  sub getResult { $_[0]{r}{ $_[1] } }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Classical;
my $C = 'Plugins::Discography::Classical';

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

my $MOZART = '9a1e7d9b-4c38-4b7e-92a9-f5b4cd6c6d4c';
my $BACH   = '24f1766e-9635-4d58-a4d4-9413f9f98a4c';

# ---------------------------------------------------------------------------
print "\n# 1. the shipped data\n";
{
    my $raw = do { local $/; open my $fh, '<:raw', "$FindBin::Bin/../Discography/classical/composers.json" or die; <$fh> };
    my $table = JSON::PP->new->utf8->decode($raw)->{composers};
    ok(scalar(keys %$table) == 220, 'the table holds 220 composers (' . scalar(keys %$table) . ')');
    my ($mz) = grep { $table->{$_}{c} eq 'Wolfgang Amadeus Mozart' } keys %$table;
    $MOZART = $mz if $mz;
    my $m = $C->composer($MOZART);
    ok($m && $m->{c} eq 'Wolfgang Amadeus Mozart', 'Mozart is found by his MusicBrainz id');
    ok($C->composer(uc $MOZART), 'an upper-case mbid finds him too');
    ok(!defined $C->composer('a74b1b7f-71a5-4011-9441-d0b5e4122711'), 'Radiohead is not a composer');
    ok(!defined $C->composer('mozart'), 'a name is not an id');
    ok(!defined $C->composer(undef), 'no id, no composer');

    my $w = $C->works($MOZART);
    ok(@$w == $m->{w}, 'Mozart\'s works file holds the count the table gives (' . scalar(@$w) . ')');
    my %ids; $ids{ $_->{id} }++ for @$w;
    ok(!grep({ $_ > 1 } values %ids), 'every work id is unique');
    ok(!grep({ $_->{id} !~ /^[0-9a-f]{8}$/ } @$w), 'every work id is 8 hex characters');
    my $firstPlain = (grep { !$w->[$_]{recommended} } 0 .. $#$w)[0];
    ok(!grep({ $w->[$_]{recommended} } $firstPlain .. $#$w), 'display order: every recommended work comes first');
    ok($w->[0]{title} =~ /K\.\s?183/, 'and those are in catalogue order: K.183 first (' . $w->[0]{title} . ')');
    ok(!@{ $C->works('a74b1b7f-71a5-4011-9441-d0b5e4122711') }, 'a non-composer has no works');
    ok($C->works($MOZART) == $w, 'a second read is the memo');

    # The id is build_data.py's: sha1("mbid|title|subtitle|genre")[:8].
    ok(Plugins::Discography::Classical::workId('m', { title => 'T', subtitle => '', genre => 'Vocal' })
           eq substr(Digest::SHA::sha1_hex('m|T||Vocal'), 0, 8), 'workId is sha1 of mbid|title|subtitle|genre');
    ok(Plugins::Discography::Classical::workId('m', { title => "\x{e9}", subtitle => '', genre => 'g' })
           eq substr(Digest::SHA::sha1_hex("m|\xc3\xa9||g"), 0, 8), 'workId hashes UTF-8 bytes, as Python does');

    # Our corrections are in the shipped copy.
    my ($deb) = grep { $table->{$_}{c} eq 'Claude Debussy' } keys %$table;
    ok(grep({ $_->{title} eq 'Deux arabesques, L.66' } @{ $C->works($deb) }), 'correction: Deux arabesques added');
    my ($kh) = grep { $table->{$_}{c} eq 'Aram Khachaturian' } keys %$table;
    ok(grep({ $_->{title} eq 'Masquerade' } @{ $C->works($kh) }), 'correction: Masquerada retitled Masquerade');
    my ($bern) = grep { $table->{$_}{c} eq 'Leonard Bernstein' } keys %$table;
    ok(2 == grep({ $_->{title} eq 'Candide' } @{ $C->works($bern) }), 'a real pair survives the repeat rule: Candide opera and suite');
}

# ---------------------------------------------------------------------------
print "\n# 2. parity with tools/classical/wrule.py\n";
{
    my $raw = do { local $/; open my $fh, '<:raw', "$FindBin::Bin/fixtures/classical_parity.json" or die; <$fh> };
    my $rows = JSON::PP->new->utf8->decode($raw);
    ok(@$rows >= 397, 'the fixture holds the library works (' . scalar(@$rows) . ')');
    # Twice: scoring every work, and as owned() runs it, through the index
    # (only the works that could raise a signal are scored).
    for my $how ('every work scored', 'through the index') {
        my ($same, @diff) = (0);
        my $t0 = Time::HiRes::time();
        for my $r (@$rows) {
            my $works = $C->works($r->{mbid});
            my $ix = $how eq 'through the index'
                   ? Plugins::Discography::Classical::_indexFor(lc $r->{mbid}, $works) : undef;
            my ($i, $why) = $C->match($r->{work}, $works, $ix);
            my $got = defined $i ? $works->[$i]{id} : undef;
            # the same work AND the same reason, so a changed tie-break shows
            if (($got // '-') eq ($r->{expect} // '-') && $why eq $r->{rule}) { $same++ }
            else { push @diff, "$r->{work}: perl " . (defined $got ? $works->[$i]{title} : '-') . " ($why), python " . ($r->{title} // '-') . " ($r->{rule})" }
        }
        my $secs = Time::HiRes::time() - $t0;
        ok(!@diff, "$how: every library work gets the Python's answer ($same of " . scalar(@$rows) . ')');
        print "     $_\n" for @diff[0 .. ($#diff < 9 ? $#diff : 9)];
        printf "     (%.2f s for %d matches)\n", $secs, scalar @$rows;
    }
    my $matched = grep { $_->{expect} } @$rows;
    ok($matched == 352, "352 of them match an Open Opus work (plan §8.3's 345, plus our 7 corrections): $matched");

    # The rule's own reasons, on cases plan §8.3 names.
    my ($i, $why) = $C->match('Symphony no. 5', [ { title => 'Symphony no. 5 in C minor, op. 67', genre => 'Orchestral' },
                                                   { title => 'Symphony no. 6 in F major, op. 68', genre => 'Orchestral' } ]);
    ok(defined $i && $i == 0 && $why eq 'tn', 'type and number: "Symphony no. 5" (' . ($why // '') . ')');
    ($i, $why) = $C->match('Violin Concerto In D Minor, Op. 4', [ { title => 'String Quartet in D minor, op. 4', genre => 'Chamber' } ]);
    ok(!defined $i, 'a work type that disagrees never matches on a catalogue number (' . ($why // '') . ')');
    ($i, $why) = $C->match('Violin Concerto in D major, Op. 4 No. 2', [ { title => 'String Quartet in D major, op. 4, no. 2', genre => 'Chamber' } ]);
    ok(!defined $i, '...nor on a catalogue number with its sub-number (' . ($why // '') . ')');
    # A nickname in the TAG found in an Open Opus title that is not its nickname
    # there, and shares nothing else: the index must still offer that work.
    my $sc = [ { title => 'Sinfonia concertante, K.364 (Jeunehomme)', genre => 'Orchestral' } ];
    for my $ix (undef, Plugins::Discography::Classical::_index($sc)) {
        ($i, $why) = $C->match('Rondo "Jeunehomme"', $sc, $ix);
        ok(defined $i && $why eq 'nick', 'the tag\'s nickname inside an Open Opus title, '
           . ($ix ? 'through the index' : 'every work scored') . ' (' . ($why // '') . ')');
    }
    ($i, $why) = $C->match('Piano Concerto No. 2 in B flat major', [ { title => 'Piano Concerto no. 2 in C minor, op. 18', genre => 'Orchestral' } ]);
    ok(!defined $i, 'a key that disagrees never matches on title (' . ($why // '') . ')');
}

# ---------------------------------------------------------------------------
print "\n# 3. the library side\n";
{
    my $works = sub { { works_loop => [ @_ ] } };
    my $w = sub { my ($id, $title, $cid) = @_; { work_id => $id, work => $title, composer_id => $cid, album_id => 1 } };

    # artist_id first; a work he only PERFORMED (another composer's) is dropped.
    %CLI = ('works 0 2000 artist_id:10' => $works->($w->(1, 'Symphony no. 40', '10'),
                                                    $w->(2, 'La Mer', '99')));
    @CLI_LOG = ();
    my $lib = $C->libraryWorks(artist_id => 10, mbid => $MOZART, names => ['Mozart']);
    ok(@$lib == 1 && $lib->[0]{title} eq 'Symphony no. 40', 'artist_id: his works, not ones he performed');
    ok(@CLI_LOG == 1, 'one query when artist_id has works');

    # artist_id with none -> the MusicBrainz tag.
    %CLI = ('works 0 2000 artist_id:20' => $works->($w->(3, 'Requiem', '20')));
    %TAG = ($MOZART => [20]);
    $lib = $C->libraryWorks(artist_id => 10, mbid => $MOZART, names => []);
    ok(@$lib == 1 && $lib->[0]{work_id} == 3, 'artist_id with no works -> the library\'s MusicBrainz tag');

    # no tag -> the name, as COMPOSER, an exact (folded) name only.
    %TAG = ();
    %CLI = ('artists 0 20 search:Antonin Dvorak role_id:COMPOSER' => { artists_loop => [
                { id => 31, artist => "Anton\x{ed}n Dvo\x{159}\x{e1}k" }, { id => 32, artist => 'Antonin Dvorak Society' } ] },
            'works 0 2000 artist_id:31' => $works->($w->(4, 'Rusalka', '31')),
            'works 0 2000 artist_id:32' => $works->($w->(5, 'Wrong', '32')));
    @CLI_LOG = ();
    $lib = $C->libraryWorks(mbid => $MOZART, names => ['Antonin Dvorak']);
    ok(@$lib == 1 && $lib->[0]{title} eq 'Rusalka', 'by name: the exact folded name only ("Antonín Dvořák", not "... Society")');
    ok((grep { /role_id:COMPOSER/ } @CLI_LOG), 'the name is looked up with the COMPOSER role');
    ok(!@{ $C->libraryWorks(mbid => $MOZART, names => ['Nobody']) }, 'nothing found -> no works, no error');

    # The tag tier also takes his own UNTAGGED exact-name entry (2026-10-07,
    # Sources::localArtistIdsByIdentity): a joint credit can carry his tag while his
    # own entry carries none. One of his name TAGGED as another composer stays out.
    {
        no strict 'refs'; no warnings 'redefine';
        local *{'Plugins::Discography::Sources::_contributorTag'} = sub { $main::CTAG{ $_[0] } // '' };
        local %TAG  = ($MOZART => [20]);
        local %CTAG = (20 => $MOZART, 22 => $BACH);
        local %CLI  = ('works 0 2000 artist_id:20' => $works->($w->(3, 'Requiem', '20')),
                       'artists 0 20 search:Wolfgang Amadeus Mozart role_id:COMPOSER' => { artists_loop => [
                           { id => 21, artist => 'Wolfgang Amadeus Mozart' },
                           { id => 22, artist => 'Wolfgang Amadeus Mozart' } ] },
                       'works 0 2000 artist_id:21' => $works->($w->(6, 'Die Zauberflote', '21')),
                       'works 0 2000 artist_id:22' => $works->($w->(9, 'Wrong', '22')));
        my $l = $C->libraryWorks(mbid => $MOZART, names => ['Wolfgang Amadeus Mozart']);
        ok(join(',', sort { $a <=> $b } map { $_->{work_id} } @$l) eq '3,6',
           'tag tier: the tag\'s entry AND his own untagged one, not one tagged as another composer');
        local %TAG = ();
        $l = $C->libraryWorks(mbid => $MOZART, names => ['Wolfgang Amadeus Mozart']);
        ok(join(',', sort { $a <=> $b } map { $_->{work_id} } @$l) eq '6,9',
           'no tag hit: the name tier exactly as before (every exact-name composer)');
        # The tag tier finds NO works: the name tier must still see the one tagged as
        # another composer, as before (the tag is read before an id is marked tried).
        local %TAG = ($MOZART => [20]);
        local %CLI = (%CLI, 'works 0 2000 artist_id:20' => $works->(), 'works 0 2000 artist_id:21' => $works->());
        $l = $C->libraryWorks(mbid => $MOZART, names => ['Wolfgang Amadeus Mozart']);
        ok(join(',', map { $_->{work_id} } @$l) eq '9',
           'tag tier empty: the name tier still reaches the other-tagged namesake (unchanged)');
    }

    # owned(): several library works can name one Open Opus work; the rest are "other".
    my $mw = $C->works($MOZART);
    my ($k622) = grep { $mw->[$_]{title} =~ /^Clarinet Concerto in A major, K\.\s?622/ } 0 .. $#$mw;
    my $libRows = [ { work_id => 7, title => 'Clarinet Concerto in A major, K. 622: Adagio' },
                    { work_id => 8, title => 'Clarinet Concerto in A major, K. 622: Rondo' },
                    { work_id => 9, title => 'Voi Che Sapete (The Marriage Of Figaro)' } ];
    my $own = $C->owned($MOZART, $mw, $libRows);
    my $held = $own->{byWork}{ $mw->[$k622]{id} } || [];
    ok(defined $k622 && @$held == 2, 'two movement tags name one Open Opus work (K. 622)');
    ok(@{ $own->{other} } == 1 && $own->{other}[0]{work_id} == 9, 'an aria named by its own title is "other"');
    ok($C->owned($MOZART, $mw, [ @$libRows ]) == $own, 'the same library works: the memo answers');
    ok($C->owned($MOZART, $mw, [ @$libRows[0, 1] ]) != $own, 'the library changed: worked out again');
    ok(!%{ $C->owned($MOZART, $mw, [])->{byWork} }, 'a library without WORK tags: nothing owned, no error');

    # albumsFor(): one list across the works, each album once, oldest first,
    # each with the works' tracks on it in the album's order (the work page,
    # plan §10.5 item 4). Two LMS works name one Open Opus work here (7, 8),
    # as movement tags do; album 50 holds both.
    %CLI = ('tracks 0 2000 work_id:7 performance:-1 tags:eit' => { titles_loop => [
                { id => 501, album_id => '50', disc => 1, tracknum => '3' },
                { id => 502, album_id => '50', disc => 1, tracknum => '1' },
                { id => 511, album_id => '51', disc => 2, tracknum => '1' },
                { id => 512, album_id => '51', disc => 1, tracknum => '5' },
                { id => 599, disc => 1, tracknum => '1' } ] },
            'tracks 0 2000 work_id:8 performance:-1 tags:eit' => { titles_loop => [
                { id => 503, album_id => '50', disc => 1, tracknum => '2' } ] },
            'albums 0 2 album_id:50,51 tags:ljya' => { albums_loop => [
                { id => 50, album => 'B', year => 2001, artwork_track_id => 'ab', artist => 'Orchestra' },
                { id => 51, album => 'A', year => 1990 } ] });
    @CLI_LOG = ();
    my $al = $C->albumsFor([7, 8]);
    ok(@$al == 2 && $al->[0]{_albumid} == 51 && $al->[1]{_albumid} == 50, 'a work\'s albums: each once, oldest first');
    ok(($al->[1]{image} // '') eq '/music/ab/cover', 'the album\'s cover is the library\'s');
    ok(($al->[1]{_artist} // '') eq 'Orchestra', 'the album\'s artist comes from the album_id read (work_id: answers none)');
    ok(join(',', @{ $al->[1]{_tracks} || [] }) eq '502,503,501',
       'the tracks of both works on one album, in track order (' . join(',', @{ $al->[1]{_tracks} || [] }) . ')');
    ok(join(',', @{ $al->[0]{_tracks} || [] }) eq '512,511', 'disc before track number (disc 1 track 5 before disc 2 track 1)');
    ok(!grep({ $_->{_albumid} eq '' } @$al), 'a track with no album is left out');
    ok(1 == grep({ /^albums / } @CLI_LOG) && 2 == grep({ /^tracks / } @CLI_LOG),
       'one tracks read per work, ONE albums read for all of them');
    {
        local %CLI = ('tracks 0 2000 work_id:7 performance:-1 tags:eit' => { titles_loop => [
                          { id => 501, album_id => '50', disc => 1, tracknum => '1' } ] });
        ok(!@{ $C->albumsFor([7]) }, 'an album the albums read does not return is left out');
        local $CLI{'albums 0 1 album_id:50 tags:ljya'} = { albums_loop => [
            { id => 60, album => 'Not asked for', year => 1999 }, { id => 50, album => 'B', year => 2001 } ] };
        my $got = eval { $C->albumsFor([7]) } || [];
        ok(@$got == 1 && $got->[0]{_albumid} == 50, 'an album the read answers that holds none of the tracks is left out');
    }
    ok(!@{ $C->albumsFor(['1; drop']) }, 'a work id that is not a number is never queried');
}

# ---------------------------------------------------------------------------
print "\n# 4. Wikidata's facts in the data (plan §10): y and i\n";
{
    require File::Temp; require File::Path;
    my $dir = File::Temp::tempdir(CLEANUP => 1);
    my $m = '00000000-0000-0000-0000-0000000000aa';
    File::Path::make_path("$dir/works");
    my $put = sub { open(my $fh, '>:raw', $_[0]) or die $!; print $fh JSON::PP->new->utf8->encode($_[1]); close $fh };
    $put->("$dir/composers.json", { composers => { $m => { n => 'T', c => 'Test', b => '1800', d => '1850', w => 4 } } });
    $put->("$dir/works/$m.json", { mbid => $m, works => [
        { t => 'Symphony no. 1', g => 'Orchestral', y => 1830, i => 'choir, orchestra' },
        { t => 'Ballade', g => 'Keyboard', i => 'piano' },
        { t => 'Song', g => 'Vocal', y => 'c. 1840', i => { x => 1 } },
        { t => 'Plain', g => 'Chamber' } ] });
    my $C = 'Plugins::Discography::Classical';
    local $Plugins::Discography::Classical::DATA_DIR = $dir;
    $C->forget;
    my $w = $C->works($m);
    ok(@$w == 4, 'the fixture composer\'s four works');
    ok($w->[0]{year} == 1830 && $w->[0]{instr} eq 'choir, orchestra', 'y and i are the work\'s year and instr');
    ok($w->[1]{year} eq '' && $w->[1]{instr} eq 'piano', 'a work with only an instrumentation: no year');
    ok($w->[2]{year} eq '' && $w->[2]{instr} eq '', 'a year that is not a number, or an instrumentation that is not text: left out');
    ok($w->[3]{year} eq '' && $w->[3]{instr} eq '', 'a work Wikidata knows nothing of: both empty');
    ok($w->[0]{id} eq Plugins::Discography::Classical::workId($m, { title => 'Symphony no. 1', subtitle => '', genre => 'Orchestral' }),
       'the id does not depend on the facts (a rebuild that adds a year keeps every id)');
    $C->forget;
}
Plugins::Discography::Classical->forget;

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
