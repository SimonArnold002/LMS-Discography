#!/usr/bin/env perl
#
# THE SEARCH'S OWN MUSICBRAINZ STEPS (stage 3 review, 2026-09-30).
#
# 1. The typed query's MusicBrainz lookup goes out ALONGSIDE the service search,
#    and the list waits for both (review finding 1). It needs only the query;
#    started after the services had answered, it added its whole time to every
#    new search.
# 2. The search waits for no check (0.56.9): the row check runs in its `known`
#    mode, and the same-name section shows an uncounted act and asks its count
#    as background work, for the next search.
# 4. A result row that opens a MusicBrainz act sharing its name says which act
#    (0.56.12, Simon: "so the bees says its the 60's garage band").
# 3. The page's two sections (0.56.10, Simon): Top Result, then Artists (the
#    same-name acts, the other rows, the differently spelled acts), as tile rows
#    or a list by the `layout_search` setting on a strip-capable Material only.
#
# Drives the REAL Browse::_artistSearchView and _withMbCandidates. The services
# and MusicBrainz are stubbed to answer only when told to, so what is asserted
# is the ORDER of requests and answers, in both arrival orders.
#
# Standalone -- no LMS install needed:  perl tools/t_searchflow.pl
#
use strict;
use warnings;
use FindBin;

our (@MB_CALLS, @MB_PENDING, @SVC_CALLS, @SVC_PENDING, @MERGED, %CANON);
our ($MB_SYNC, $SVC_ANSWERED);
our (@WARMED, %COUNT, $OPT, @WARM_BG);
our $CANDS;      # section 7: the same-name set to answer with (undef = three Genesis)
our ($LAYOUT, $STRIPS);   # section 8: the layout_search pref, a strip-capable Material
our (%RESOLVED, @PEEKED); # section 9: the name resolver's cached answers, and who asked

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
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Null' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    # The strings the search rows format; any other key comes back as itself.
    my %EN = (PLUGIN_DISCOGRAPHY_OWNED_ALBUM  => '1 album',
              PLUGIN_DISCOGRAPHY_OWNED_ALBUMS => '%s albums');
    *{'Slim::Utils::Strings::cstring'}   = sub { $EN{ $_[1] } // $_[1] };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');

    my $A = 'Plugins::Discography::API';
    *{"${A}::NAME_FETCH"} = sub { 15 };
    # The typed query's lookup. Recorded with how many service searches had
    # ANSWERED when it was asked; answered only when the test says so, or at
    # once when $MB_SYNC is set (a cached name answers inside the call).
    *{"${A}::getArtistMbid"} = sub {
        my ($class, %a) = @_;
        push @main::MB_CALLS, { artist => $a{artist}, fetch => $a{fetch},
                                svc_answered => $main::SVC_ANSWERED };
        return $a{onDone}->($main::MB_SYNC || undef, 0) if defined $main::MB_SYNC;
        push @main::MB_PENDING, $a{onDone};
    };
    *{"${A}::peekArtistName"} = sub { $main::CANON{ $_[1] // '' } };

    # Section 2: the row check, the same-name set and its counts.
    *{"${A}::filterRowsWithContent"} = sub {
        my ($class, $rows, $cb, $opt) = @_;
        $main::OPT = $opt;
        return $cb->($rows);
    };
    *{"${A}::getArtistCandidates"} = sub {
        return $_[2]->([ map { +{ %$_ } } @$main::CANDS ]) if $main::CANDS;
        $_[2]->([ map { { mbid => main::id($_), name => 'Genesis' } } 1 .. 3 ]);
    };
    *{"${A}::peekArtistAliases"} = sub { [] };
    *{"${A}::warmCandidateCounts"} = sub {
        my ($class, $cands, $cb) = @_;
        push @main::WARMED, map { $_->{mbid} } @{ $cands || [] };
        push @main::WARM_BG, $Plugins::Discography::API::NET_BG ? 1 : 0;
        return $cb ? $cb->() : undef;
    };
    *{"${A}::peekReleaseGroupCount"} = sub { $main::COUNT{ $_[1] // '' } };
    *{"${A}::peekArtistMbid"} = sub { push @main::PEEKED, $_[1]; $main::RESOLVED{ lc($_[1] // '') } };
}

package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}
# Prefs and cache share this stub: only the search layout answers.
sub get { return ($_[1] // '') eq 'layout_search' ? $main::LAYOUT : undef }

package main;

sub id { sprintf('%08d-0000-0000-0000-000000000000', $_[0]) }

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;
my $B = 'Plugins::Discography::Browse';
my $realWith  = \&Plugins::Discography::Browse::_withMbCandidates;
my $realItems = \&Plugins::Discography::Browse::_searchResultItems;
my $realMbRow = \&Plugins::Discography::Browse::_mbCandidateRow;
my $realHdr   = \&Plugins::Discography::Browse::_sectionHeader;
{
    no warnings 'redefine'; no strict 'refs';
    # The services answer only when the test says so.
    *{'Plugins::Discography::Sources::searchArtists'} = sub {
        my ($class, $client, $q, $cb) = @_;
        push @main::SVC_CALLS, $q;
        push @main::SVC_PENDING, $cb;
    };
    # The merge is not what this suite is about: every hit, in service order.
    *{'Plugins::Discography::Sources::mergeArtistHits'} = sub {
        my ($class, $q, $bySvc) = @_;
        return [ map { @{ $bySvc->{$_} || [] } } sort keys %{ $bySvc || {} } ];
    };
    # Section 1 captures the finished list here instead of building rows.
    *{"${B}::_withMbCandidates"} = sub {
        my ($client, $callback, $features, $q, $merged) = @_;
        push @main::MERGED, [ $q, [ map { $_->{name} } @{ $merged || [] } ], $_[5] ];
    };
    *{'Plugins::Discography::Sources::attachLibraryArtists'} = sub { $_[1] };
    *{'Plugins::Discography::Sources::splitOwnedByIdentity'} = sub { $_[1] };
    *{'Plugins::Discography::Sources::rankArtistHits'}       = sub { $_[1] };
    *{"${B}::_searchResultItems"} = sub { [] };
    *{"${B}::_mbCandidateRow"}    = sub { { name => $_[1]{mbid} } };
    *{"${B}::_sectionHeader"}     = sub { { name => 'header' } };
    *{"${B}::_wantHeaders"}       = sub { 1 };
}

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}
sub section {
    my ($n, $code) = @_;
    eval { $code->(); 1 } or do { (my $e = $@) =~ s/\s+/ /g; ok(0, "$n: the section died: $e") };
}
sub fresh {
    @MB_CALLS = (); @MB_PENDING = (); @SVC_CALLS = (); @SVC_PENDING = ();
    @MERGED = (); %CANON = (); $MB_SYNC = undef; $SVC_ANSWERED = 0;
}
sub view { $B->can('_artistSearchView')->('client', sub {}, '', $_[0]) }
sub answer_svc {
    my ($i, $bySvc, $failed) = @_;
    my $cb = $SVC_PENDING[$i] or die "no service search $i was sent\n";
    $SVC_ANSWERED++;
    $cb->($bySvc || {}, $failed || {});
}
sub answer_mb {
    my ($i, $mbid) = @_;
    my $cb = $MB_PENDING[$i] or die "no lookup $i was sent\n";
    $cb->($mbid, 0);
}
sub merged_names { join(',', @{ ($MERGED[0] || [undef, []])->[1] }) }

section('1', sub {
    # -----------------------------------------------------------------------
    # 1. The lookup goes out WITH the service search; the services answer first.
    # -----------------------------------------------------------------------
    fresh();
    view('Genesis');
    ok(scalar(@MB_CALLS == 1 && @SVC_CALLS == 1),
       '1: the lookup and the service search both go out');
    ok(scalar(@MB_CALLS && $MB_CALLS[0]{svc_answered} == 0),
       '1: ... the lookup before any service has answered');
    ok(scalar(@MB_CALLS && ($MB_CALLS[0]{fetch} // 0) == 15),
       '1: ... asked at NAME_FETCH entries (the same-name section reads that reply)');
    answer_svc(0, { Qobuz => [ { name => 'Genesis' } ] });
    ok(scalar(!@MERGED), '1: services back first: nothing is built until the lookup answers');
    $CANON{ id(1) } = 'Genesis';
    answer_mb(0, id(1));
    ok(scalar(@MERGED == 1 && merged_names() eq 'Genesis'),
       '1: ... then the list is built, once');
    ok(scalar(@SVC_CALLS == 1),
       '1: MusicBrainz names the act as typed: no second service search');
});

section('2', sub {
    # -----------------------------------------------------------------------
    # 2. The lookup answers first, the services later.
    # -----------------------------------------------------------------------
    fresh();
    view('Genesis');
    $CANON{ id(1) } = 'Genesis';
    answer_mb(0, id(1));
    ok(scalar(!@MERGED), '2: lookup back first: nothing is built until the services answer');
    answer_svc(0, { Qobuz => [ { name => 'Genesis' } ] });
    ok(scalar(@MERGED == 1), '2: ... then the list is built, once');
});

section('3', sub {
    # -----------------------------------------------------------------------
    # 3. A cached name answers inside the call.
    # -----------------------------------------------------------------------
    fresh();
    $MB_SYNC = id(1);
    $CANON{ id(1) } = 'Genesis';
    view('Genesis');
    ok(scalar(@SVC_CALLS == 1 && !@MERGED),
       '3: a cached name answers at once, and the list still waits for the services');
    answer_svc(0, { Qobuz => [ { name => 'Genesis' } ] });
    ok(scalar(@MERGED == 1), '3: ... and is built once when they answer');
});

section('4', sub {
    # -----------------------------------------------------------------------
    # 4. MusicBrainz's name differs from what was typed: the second service
    #    search runs after BOTH, in either arrival order, and the list waits
    #    for it.
    # -----------------------------------------------------------------------
    fresh();
    view('beatles');
    $CANON{ id(2) } = 'The Beatles';
    answer_mb(0, id(2));
    ok(scalar(@SVC_CALLS == 1), '4: the second pass waits for the first service search');
    answer_svc(0, { Qobuz => [ { name => 'Beatles Tribute' } ] });
    ok(scalar(@SVC_CALLS == 2 && $SVC_CALLS[1] eq 'The Beatles'),
       "4: then the services are searched under MusicBrainz's name");
    ok(scalar(!@MERGED), '4: ... and nothing is built until that answers too');
    answer_svc(1, { Qobuz => [ { name => 'The Beatles' } ] });
    ok(scalar(@MERGED == 1 && merged_names() eq 'Beatles Tribute,The Beatles'),
       '4: both passes merged into one list, built once');

    fresh();
    view('beatles');
    answer_svc(0, { Qobuz => [ { name => 'Beatles Tribute' } ] });
    $CANON{ id(2) } = 'The Beatles';
    answer_mb(0, id(2));
    ok(scalar(@SVC_CALLS == 2 && $SVC_CALLS[1] eq 'The Beatles'),
       '4: services first, then the lookup: the second pass still runs');
    answer_svc(1, { Qobuz => [ { name => 'The Beatles' } ] });
    ok(scalar(@MERGED == 1), '4: ... and the list is built once');
});

section('5', sub {
    # -----------------------------------------------------------------------
    # 5. No MusicBrainz artist for the query.
    # -----------------------------------------------------------------------
    fresh();
    view('Xyzzy Nobody');
    answer_svc(0, {});
    answer_mb(0, undef);
    ok(scalar(@MERGED == 1 && @SVC_CALLS == 1),
       '5: no MusicBrainz artist: the list is built once, no second pass');
});

section('6', sub {
    # -----------------------------------------------------------------------
    # 6. THE SEARCH WAITS FOR NO CHECK (0.56.9; Simon: the search "should be the
    #    quickest part ... just hide them on 2nd search"). The row check runs in
    #    its known mode; the same-name section lists an act whose count is not
    #    known yet and asks it AFTER, as background work; a count known to be 0
    #    still drops its act.
    # -----------------------------------------------------------------------
    my $out;
    my $run = sub {
        @WARMED = (); @WARM_BG = (); $OPT = undef; $out = undef;
        $realWith->('client', sub { $out = $_[0] }, '', 'Genesis',
                    [ { name => 'Genesis', sources => ['Qobuz'] } ]);
    };
    my $names = sub { [ map { $_->{name} } @{ ($out || {})->{items} || [] } ] };
    %COUNT = (id(1) => 40, id(3) => 0);    # id(2) not counted yet

    $run->();
    ok(scalar(ref $OPT eq 'HASH' && ($OPT->{query} // '') eq 'Genesis' && $OPT->{known}),
       '6: the search runs the row check in its known mode, with the query');
    ok(scalar(defined $out), '6: the list is answered without waiting for any count');
    ok(scalar(grep { $_ eq id(2) } @{ $names->() }),
       '6: an act whose count is not known yet is listed');
    ok(scalar(!grep { $_ eq id(3) } @{ $names->() }),
       '6: ... and one whose count is known to be 0 is not');
    ok(scalar(join(',', @WARMED) eq id(2) && "@WARM_BG" eq '1'),
       '6: only the uncounted act is asked, as background work');

    # CONTROL: every count known -> nothing is asked.
    %COUNT = (id(1) => 40, id(2) => 3, id(3) => 0);
    $run->();
    ok(scalar(!@WARMED), '6: control: every count known, nothing is asked');
});

section('7', sub {
    # -----------------------------------------------------------------------
    # 7. ONE ROW PER TITLE, AS MATERIAL COUNTS THEM (stage 3 live check,
    #    2026-09-30). Material ids an item_id-less row by "<parent id>.<first
    #    line of its name>" and draws one tile per id, the LATER winning: the
    #    search for The Dream Syndicate showed only 15 Minutes' row. Every
    #    repeat of a name must reach Material as a DIFFERENT title that reads the
    #    same, and a tap must still open the real name.
    # -----------------------------------------------------------------------
    no warnings 'redefine'; no strict 'refs';
    local *{"${B}::_searchResultItems"} = $realItems;
    local *{"${B}::_mbCandidateRow"}    = $realMbRow;
    my $WJ = "\x{2060}";
    my $shown = sub { (my $n = $_[0] // '') =~ s/$WJ//g; $n };
    my $out;
    my $run = sub {
        my ($q, $merged) = @_;
        $out = undef;
        $realWith->('client', sub { $out = $_[0] }, '', $q, $merged);
        return [ grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'link' } @{ ($out || {})->{items} || [] } ];
    };

    # Two owned acts split by MusicBrainz identity: the band, and 15 Minutes
    # (its tracks credited "The Dream Syndicate").
    $CANDS = [];
    my $rows = $run->('The Dream Syndicate', [
        { name => 'The Dream Syndicate', artist_id => 155735, sources => ['Local'], _owned => 5, _seq => 0 },
        { name => 'The Dream Syndicate', artist_id => 155737, sources => ['Local'], _owned => 1, _seq => 0 },
    ]);
    ok(scalar(@$rows == 2 && $rows->[0]{name} ne $rows->[1]{name}),
       '7: two acts with one name reach Material as two different titles');
    ok(scalar(@$rows == 2 && $rows->[0]{name} eq 'The Dream Syndicate'
              && $shown->($rows->[1]{name}) eq 'The Dream Syndicate'),
       '7: ... the first unchanged, the second reading the same on screen');
    my @go = map { $_->{itemActions}{items}{fixedParams} || {} } @$rows;
    ok(scalar(@go == 2 && ($go[0]{artist} // '') eq 'The Dream Syndicate'
              && ($go[1]{artist} // '') eq 'The Dream Syndicate'
              && ($go[0]{artist_id} // 0) == 155735 && ($go[1]{artist_id} // 0) == 155737),
       '7: ... and each tap opens the real name and its own library id');
    ok(scalar(@$rows == 2 && ($rows->[0]{line2} // '') eq "Local \x{00B7} 5 albums"
              && ($rows->[1]{line2} // '') eq "Local \x{00B7} 1 album"),
       '7: ... told apart by the albums each opens on ("5 albums" / "1 album")');

    # An owned act and the "Other artists with this name" rows share a title:
    # Air (the user's, 5 albums) and three MusicBrainz-only acts called Air.
    $CANDS = [ { mbid => id(71), name => 'Air', disambiguation => 'Pete Namlook project' },
               { mbid => id(72), name => 'Air', disambiguation => '70s-80s US jazz trio' },
               { mbid => id(73), name => 'Air', disambiguation => 'US jazz rock band' } ];
    %COUNT = (id(71) => 3, id(72) => 4, id(73) => 2);
    $rows = $run->('Air', [ { name => 'Air', artist_id => 151906, sources => ['Local'], _seq => 0 } ]);
    my %titles = map { ($_->{name} => 1) } @$rows;
    ok(scalar(@$rows == 4 && keys(%titles) == 4),
       '7: the owned Air and three MusicBrainz acts called Air: four different titles');
    ok(scalar(@$rows == 4 && !grep { $shown->($_->{name}) ne 'Air' } @$rows),
       '7: ... all reading "Air" on screen');
    ok(scalar(@$rows && ($rows->[0]{line2} // '') eq 'Local'),
       '7: ... and an owned row that was not split keeps its line as it was (no count)');

    # CONTROL: a list with no repeated name goes out exactly as built.
    $CANDS = [];
    $rows = $run->('Radiohead', [
        { name => 'Radiohead',         artist_id => 100, sources => ['Local', 'Qobuz'], _seq => 0 },
        { name => 'Radiohead Tribute', sources => ['Qobuz'], _seq => 1 },
    ]);
    ok(scalar(join('|', map { $_->{name} } @$rows) eq 'Radiohead|Radiohead Tribute'),
       '7: control: no repeated name -> every title exactly as built');
    $CANDS = undef;
});

section('8', sub {
    # -----------------------------------------------------------------------
    # 8. TOP RESULT, THEN ARTISTS (0.56.10; Simon, 2026-10-01). The best-ranked
    #    row alone under "Top Result"; under "Artists" the other acts with the
    #    same name first, then the other rows in their order, then the
    #    differently spelled MusicBrainz acts. No "Other artists with this name"
    #    heading. On a strip-capable Material the top result is a one-tile row
    #    and the artists a list ('split') or a tile row ('tiles'); elsewhere the
    #    setting changes nothing. The rows are the same in every layout.
    # -----------------------------------------------------------------------
    no warnings 'redefine'; no strict 'refs';
    local *{"${B}::_searchResultItems"} = $realItems;
    local *{"${B}::_mbCandidateRow"}    = $realMbRow;
    local *{"${B}::_sectionHeader"}     = $realHdr;
    local *{"${B}::_useStrips"}         = sub { $STRIPS };
    my $WJ = "\x{2060}";
    my $label = sub {
        my ($r) = @_;
        return 'H:' . ($r->{name} =~ s/^PLUGIN_DISCOGRAPHY_//r) if ($r->{type} // '') =~ /^header|^text$/
            && ($r->{name} // '') =~ /^PLUGIN_DISCOGRAPHY_(?:TOP_RESULT|ARTISTS_HDR|SAME_NAME)$/;
        my $pt = ($r->{passthrough} || [])->[0] || {};
        return 'MB:' . ($pt->{c_mbid} =~ s/^0*(\d+)-.*/$1/r) if $pt->{c_mbid};
        return ($r->{name} // '') =~ s/$WJ//gr;
    };
    my $out;
    my $run = sub {
        my ($q, $merged, $part) = @_;
        $out = undef;
        $realWith->('client', sub { $out = $_[0] }, '', $q, $merged, $part);
        return $out->{items} || [];
    };
    my $labels = sub { join('|', map { $label->($_) } @{ $_[0] }) };
    my $hdr = sub { my ($rows, $key) = @_;
        (grep { ($_->{name} // '') eq "PLUGIN_DISCOGRAPHY_$key" } @$rows)[0] || {} };
    my $merged = sub { [
        { name => 'Madness',           artist_id => 1, sources => ['Local', 'Qobuz'], _seq => 0 },
        { name => 'Madness & Friends', artist_id => 2, sources => ['Local'],          _seq => 1 },
        { name => 'Madness Tribute',   sources => ['Qobuz'],                          _seq => 2 },
    ] };
    $CANDS = [ { mbid => id(81), name => 'Madness', disambiguation => 'English ska band' },
               { mbid => id(82), name => 'Madness', disambiguation => 'Horrorcore rapper' },
               { mbid => id(83), name => 'Madness', disambiguation => 'US funk rock group' },
               { mbid => id(84), name => "M\x{00E4}dness" } ];
    %COUNT = map { (id($_) => 5) } 81 .. 84;
    my $want = "H:TOP_RESULT|Madness|H:ARTISTS_HDR|MB:81|MB:82|MB:83"
             . "|Madness & Friends|Madness Tribute|MB:84";

    # Headers, no strip-capable Material.
    ($STRIPS, $LAYOUT) = (0, undef);
    my $rows = $run->('Madness', $merged->());
    ok(scalar($labels->($rows) eq $want),
       '8: Top Result over the best row; Artists = same-name acts, the other rows, the other spellings');
    ok(scalar(!grep { ($_->{name} // '') eq 'PLUGIN_DISCOGRAPHY_SAME_NAME' } @$rows),
       '8: no "Other artists with this name" heading');
    ok(scalar(($hdr->($rows, 'TOP_RESULT')->{image} // '') =~ /_MTL_icon_star\.png$/),
       '8: Top Result carries the star icon');
    ok(scalar(!grep { ($_->{type} // '') eq 'header-strip' } @$rows),
       '8: no strip-capable Material -> no tile rows');
    $LAYOUT = 'tiles';
    $rows = $run->('Madness', $merged->());
    ok(scalar(!grep { ($_->{type} // '') eq 'header-strip' } @$rows),
       "8: ... and 'All tiles' changes nothing there");

    # Strip-capable Material, split (the default).
    ($STRIPS, $LAYOUT) = (1, undef);
    $rows = $run->('Madness', $merged->());
    my $top = $hdr->($rows, 'TOP_RESULT');
    ok(scalar(($top->{type} // '') eq 'header-strip'), '8: split: the top result is a tile row');
    my $tp = (($top->{itemActions} || {})->{items} || {})->{fixedParams} || {};
    ok(scalar(($tp->{artist} // '') eq 'Madness' && ($tp->{artist_id} // 0) == 1 && !exists $tp->{item}),
       "8: ... its heading's More opens the top artist itself");
    ok(scalar(($hdr->($rows, 'ARTISTS_HDR')->{type} // '') ne 'header-strip'),
       '8: ... and the artists are a list');
    ok(scalar($labels->($rows) eq $want), '8: ... the same rows in the same order');

    # Strip-capable Material, all tiles.
    $LAYOUT = 'tiles';
    $rows = $run->('Madness', $merged->());
    my $art = $hdr->($rows, 'ARTISTS_HDR');
    ok(scalar(($hdr->($rows, 'TOP_RESULT')->{type} // '') eq 'header-strip'
              && ($art->{type} // '') eq 'header-strip'),
       "8: 'All tiles': the top result and the artists are both tile rows");
    my $ap = (($art->{itemActions} || {})->{items} || {})->{fixedParams} || {};
    ok(scalar(($ap->{search} // '') eq 'Madness' && ($ap->{item} // '') eq 'sect:ARTISTS'),
       "8: ... the Artists heading's More re-asks the search for that section");
    ok(scalar($labels->($rows) eq $want), '8: ... the same rows in the same order');

    # The More: the Artists rows alone, in the page's order.
    $rows = $run->('Madness', $merged->(), 'sect:ARTISTS');
    ok(scalar($labels->($rows) eq "MB:81|MB:82|MB:83|Madness & Friends|Madness Tribute|MB:84"),
       '8: the More answers every artist and nothing else');

    # One result: Top Result alone.
    ($STRIPS, $LAYOUT) = (0, undef);
    $CANDS = [];
    $rows = $run->('Madness', [ $merged->()->[0] ]);
    ok(scalar($labels->($rows) eq 'H:TOP_RESULT|Madness'),
       '8: one result -> Top Result, no Artists heading');

    # Nothing on the services or in the library: the line stays, the
    # MusicBrainz acts go under Artists, no Top Result.
    $CANDS = [ map { { mbid => id($_), name => 'Madness', disambiguation => "act $_" } } 81 .. 82 ];
    $rows = $run->('Madness', []);
    ok(scalar($labels->($rows) eq 'PLUGIN_DISCOGRAPHY_SEARCH_NONE|H:ARTISTS_HDR|MB:81|MB:82'),
       '8: nothing found -> "No artists found", then the MusicBrainz acts under Artists');

    # An unowned row named as typed already reaches MB's top act: dropped from
    # the same-name acts (0.43.2's rule, unchanged).
    $CANDS = [ map { { mbid => id($_), name => 'Madness', disambiguation => "act $_" } } 81 .. 83 ];
    $rows = $run->('Madness', [ { name => 'Madness', sources => ['Qobuz'], _seq => 0 } ]);
    ok(scalar($labels->($rows) eq 'H:TOP_RESULT|Madness|H:ARTISTS_HDR|MB:82|MB:83'),
       '8: the act the top result reaches is not listed again');

    # The tap that asks for the section reaches the view with it.
    fresh();
    $B->can('_artistSearchView')->('client', sub {}, '', 'Madness', 'sect:ARTISTS');
    answer_svc(0, { Qobuz => [ { name => 'Madness' } ] });
    answer_mb(0, undef);
    ok(scalar(@MERGED == 1 && ($MERGED[0][2] // '') eq 'sect:ARTISTS'),
       '8: the section param reaches the layout');
    fresh();
    my @args;
    local *{"${B}::_artistSearchView"} = sub { @args = @_ };
    $B->can('topLevel')->('client', sub {}, { params => {
        search => 'Madness', item => 'sect:ARTISTS', features => 'hi' } });
    ok(scalar(($args[3] // '') eq 'Madness' && ($args[4] // '') eq 'sect:ARTISTS'),
       "8: the Artists heading's More (search + item) is dispatched as that section");
    @args = ();
    $B->can('topLevel')->('client', sub {}, { params => { search => 'Madness', features => 'hi' } });
    ok(scalar(($args[3] // '') eq 'Madness' && !defined $args[4]),
       '8: control: a plain search asks for the whole page');
    ($CANDS, $LAYOUT, $STRIPS) = (undef, undef, 0);
});

section('9', sub {
    # -----------------------------------------------------------------------
    # 9. THE DESCRIPTION OF THE ACT A RESULT OPENS (0.56.12; Simon, 2026-10-01:
    #    "show the disambiguation when they are matched so the bees says its the
    #    60's garage band"). His three owned The Bees, measured on MusicBrainz:
    #    the Isle of Wight band and two 1960s garage bands. An owned row by its
    #    library tag, an unowned row by the name resolver's answer; only for a
    #    name MusicBrainz has more than once; never a guess for an untagged row.
    # -----------------------------------------------------------------------
    no warnings 'redefine'; no strict 'refs';
    local *{"${B}::_searchResultItems"} = $realItems;
    local *{"${B}::_mbCandidateRow"}    = $realMbRow;
    local *{"${B}::_sectionHeader"}     = $realHdr;
    my $WJ = "\x{2060}";
    my $out;
    my $run = sub {
        my ($q, $merged) = @_;
        $out = undef; @PEEKED = ();
        $realWith->('client', sub { $out = $_[0] }, '', $q, $merged);
        return [ grep { ($_->{type} // '') eq 'link' } @{ ($out || {})->{items} || [] } ];
    };
    # line2 of the result row that opens library id $aid (or the named row).
    my $l2 = sub { my ($rows, $aid, $name) = @_;
        my ($r) = grep { my $p = ($_->{passthrough} || [])->[0] || {};
                         defined $aid ? (($p->{q_aid} // 0) == $aid)
                                      : (!$p->{q_aid} && !$p->{c_mbid} && ($p->{q_name} // '') eq $name) } @$rows;
        return $r ? ($r->{line2} // '') : 'NO ROW' };
    my $IOW = 'Isle of Wight, UK band, known as "A Band of Bees" in the US';
    my $COV = "mid\x{2010}1960s garage rock band from Covina, CA";
    my $LA  = '1960s garage band from Los Angeles, CA';
    $CANDS = [ { mbid => id(901), name => 'The Bees', disambiguation => $IOW },
               { mbid => id(902), name => 'The Bees', disambiguation => $COV },
               { mbid => id(903), name => 'The Bees', disambiguation => $LA },
               { mbid => id(904), name => 'The Bees', disambiguation => '1980s South African' },
               { mbid => id(905), name => 'The Bees', disambiguation => '' },
               { mbid => id(907), name => 'The Bees', disambiguation => '1960s Singapore guitar band' },
               { mbid => id(906), name => 'Honey & the Bees', disambiguation => 'girl group from Philadelphia' } ];
    %COUNT = map { (id($_) => 3) } 901 .. 907;
    %RESOLVED = ('honey & the bees' => id(906));
    my $bees = sub { [
        { name => 'The Bees', artist_id => 155528, sources => ['Local'], _owned => 4, _ident_mbid => id(901), _seq => 0 },
        { name => 'The Bees', artist_id => 155529, sources => ['Local'], _owned => 1, _ident_mbid => id(902), _seq => 1 },
        { name => 'The Bees', artist_id => 155530, sources => ['Local'], _owned => 1, _ident_mbid => id(903), _seq => 2 },
        { name => 'The Bees', artist_id => 155531, sources => ['Local'], _ident_mbid => id(905), _seq => 3 },
        { name => 'The King Bees', artist_id => 155600, sources => ['Local'], _seq => 4 },
        { name => 'Honey & The Bees', sources => ['Qobuz'], _seq => 5 },
    ] };
    my $rows = $run->('The Bees', $bees->());
    ok(scalar($l2->($rows, 155528) eq "Local \x{00B7} 4 albums \x{00B7} $IOW"),
       '9: the owned Isle of Wight band says which act it is, after its sources and count');
    ok(scalar($l2->($rows, 155529) eq "Local \x{00B7} 1 album \x{00B7} $COV"
              && $l2->($rows, 155530) eq "Local \x{00B7} 1 album \x{00B7} $LA"),
       '9: ... and the two owned 1960s garage bands are told apart by theirs');
    ok(scalar($l2->($rows, 155531) eq 'Local'),
       '9: an act MusicBrainz gives no description adds nothing (no trailing dot)');
    ok(scalar($l2->($rows, 155600) eq 'Local'), '9: a row whose act is not in the list is unchanged');
    ok(scalar($l2->($rows, undef, 'Honey & The Bees') eq 'Qobuz'),
       '9: a name MusicBrainz has once gets no description, even matched');
    ok(scalar(!grep { ($_->{line2} // '') =~ /\Q$COV\E|\Q$LA\E|Wight/ && (($_->{passthrough} || [])->[0] || {})->{c_mbid} } @$rows),
       '9: the owned acts are still not listed again as MusicBrainz entries');
    ok(scalar(grep { ($_->{line2} // '') =~ /^1980s South African/ } @$rows),
       '9: ... and an unowned one still is, with its own description');
    ok(scalar(!grep { lc($_ // '') eq 'the bees' } @PEEKED),
       "9: a tagged owned row is never matched by name");

    # An unowned row is matched by the resolver's answer for its name.
    %RESOLVED = ('the bees' => id(902));
    $rows = $run->('The Bees', [ { name => 'The Bees', sources => ['Qobuz'], _seq => 0 } ]);
    ok(scalar($l2->($rows, undef, 'The Bees') eq "Qobuz \x{00B7} $COV"),
       "9: an unowned row says which act a tap opens (the resolver's answer for its name)");
    # An owned row with no tag is not guessed from its name.
    $rows = $run->('The Bees', [ { name => 'The Bees', artist_id => 155540, sources => ['Local'], _seq => 0 } ]);
    ok(scalar($l2->($rows, 155540) eq 'Local' && !@PEEKED),
       '9: an owned row with no tag gets nothing, and its name is not looked up');
    # An owned collaboration (Local, no single library artist, no tag): the same.
    $rows = $run->('The Bees', [ { name => 'The Bees', sources => ['Local', 'Qobuz'], _seq => 0 } ]);
    ok(scalar($l2->($rows, undef, 'The Bees') eq "Local \x{00B7} Qobuz" && !@PEEKED),
       '9: ... nor does an owned row with no library artist (a collaboration)');
    # CONTROL: no MusicBrainz list -> every line as before, nothing looked up.
    $CANDS = [];
    $rows = $run->('The Bees', $bees->());
    ok(scalar($l2->($rows, 155528) eq "Local \x{00B7} 4 albums" && !@PEEKED),
       '9: control: no MusicBrainz list -> lines as before, nothing looked up');
    ($CANDS, %RESOLVED) = (undef);
});

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
