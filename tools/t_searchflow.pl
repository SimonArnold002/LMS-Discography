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
our %LIBMBID;             # section 9: the album lookup's kept answers, by library id (C2)
our ($FUZZY, @FUZZY_ASKED); # section 11: the closest names MusicBrainz answers, and who asked
our @CANDS_ASKED;           # section 12: the names the same-name acts were asked for
our (%ENREAD, @ALIASES);    # section 13: the artist read's English names / aliases, by mbid
our (@PREFETCH, $REPLIED);  # section 14: what the Top Result prefetch was handed, and whether the page was out

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
              PLUGIN_DISCOGRAPHY_OWNED_ALBUMS => '%s albums',
              PLUGIN_DISCOGRAPHY_NOT_ONE_ARTIST => '%s is not a single artist, so there is no discography');
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
        push @main::CANDS_ASKED, $_[1];
        return $_[2]->([ map { +{ %$_ } } @$main::CANDS ]) if $main::CANDS;
        $_[2]->([ map { { mbid => main::id($_), name => 'Genesis' } } 1 .. 3 ]);
    };
    *{"${A}::peekArtistAliases"} = sub { @main::ALIASES ? [ @main::ALIASES ] : [] };
    *{"${A}::peekArtistEnglishName"} = sub { $main::ENREAD{ $_[1] // '' } };
    *{"${A}::warmCandidateCounts"} = sub {
        my ($class, $cands, $cb) = @_;
        push @main::WARMED, map { $_->{mbid} } @{ $cands || [] };
        push @main::WARM_BG, $Plugins::Discography::API::NET_BG ? 1 : 0;
        return $cb ? $cb->() : undef;
    };
    *{"${A}::peekReleaseGroupCount"} = sub { $main::COUNT{ $_[1] // '' } };
    # The closest names for a search that found nothing (0.56.38).
    *{"${A}::fuzzyArtists"} = sub {
        push @main::FUZZY_ASKED, $_[1];
        $_[2]->([ map { +{ %$_ } } @{ $main::FUZZY || [] } ]);
    };
    *{"${A}::peekArtistMbid"} = sub { push @main::PEEKED, $_[1]; $main::RESOLVED{ lc($_[1] // '') } };
    # Not one artist (0.56.41): the two names and MB's Various Artists id. The
    # real rule (the LMS name, the other special ids, _nameKey) is pinned in
    # t_various.pl against the real API.
    *{"${A}::isVarious"} = sub {
        my ($class, $n, $m) = @_;
        return 1 if defined $m && lc $m eq '89ad4ac3-39f7-470e-963a-56509c546377';
        return (defined $n && $n =~ /^\s*various (?:artists|composers)\s*$/i) ? 1 : 0;
    };
    # The album lookup's kept answer for an untagged library contributor (C2), by id.
    *{"${A}::peekLibraryMbid"} = sub { $main::LIBMBID{ $_[1] // '' } };
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
    # The Top Result prefetch (0.56.56) is t_prefetch.pl's subject: here only
    # what the search hands it is recorded (section 14).
    *{"${B}::_prefetchTop"}       = sub { push @main::PREFETCH, [ $_[1], $main::REPLIED ] };
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

    # Nothing on the services or in the library: the act the name opens is the
    # Top Result, the other under Artists (2026-10-09, Simon: Buckethead with no
    # streaming service; before, "No artists found" and both under Artists).
    $CANDS = [ map { { mbid => id($_), name => 'Madness', disambiguation => "act $_" } } 81 .. 82 ];
    $rows = $run->('Madness', []);
    ok(scalar($labels->($rows) eq 'H:TOP_RESULT|MB:81|H:ARTISTS_HDR|MB:82'),
       "8: nothing found -> MusicBrainz's first act the Top Result, the other under Artists, no \"No artists found\"");

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
    # ... unless its page has had its own albums name its act (resolver plan
    # C2): that answer stands as a tag does, still never by name. The row handed
    # in (the search cache's own) is not written to.
    %LIBMBID = (155540 => id(903));
    my $given = { name => 'The Bees', artist_id => 155540, sources => ['Local'], _seq => 0 };
    $rows = $run->('The Bees', [ $given ]);
    ok(scalar($l2->($rows, 155540) eq "Local \x{00B7} $LA" && !@PEEKED),
       "9: an untagged owned row whose albums named its act says which act it is (C2), no name lookup");
    ok(scalar(!exists $given->{_ident_mbid}), '9: ... stamped on a copy, not on the row handed in');
    %LIBMBID = (155528 => id(902));
    $rows = $run->('The Bees', $bees->());
    ok(scalar($l2->($rows, 155528) eq "Local \x{00B7} 4 albums \x{00B7} $IOW"),
       '9: a tagged owned row keeps its tag whatever the album lookup kept for its id');
    %LIBMBID = ();
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

section('10', sub {
    # -----------------------------------------------------------------------
    # 10. THE ONE MUSICBRAINZ ACT NO ROW OPENS (0.56.37, resolver plan Part D
    #     step 1). Measured live 2026-10-02: "Jandek" (on MusicBrainz, on no
    #     service, not owned) showed Qobuz's "JanDeKid", then "No artists
    #     found". Simon: such an act is the Top Result, unless something is
    #     owned; a row that opens it already keeps it out, as before.
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
    my $run = sub {
        my ($q, $merged, $part) = @_;
        my $out;
        @WARMED = (); @WARM_BG = (); @PEEKED = ();
        $realWith->('client', sub { $out = $_[0] }, '', $q, $merged, $part);
        return join('|', map { $label->($_) } @{ ($out || {})->{items} || [] });
    };
    my $one = sub { [ { mbid => id($_[0]), name => $_[1], type => 'Person', country => 'US' } ] };
    ($STRIPS, $LAYOUT) = (0, undef);

    # Jandek: one act, the typed name opens it, the only row is a near miss.
    $CANDS = $one->(1, 'Jandek');
    %RESOLVED = ('jandek' => id(1));
    %COUNT = ();
    ok(scalar($run->('Jandek', [ { name => 'JanDeKid', sources => ['Qobuz'], _seq => 0 } ])
              eq 'H:TOP_RESULT|MB:1|H:ARTISTS_HDR|JanDeKid'),
       '10: the one act no row opens is the Top Result; the near miss goes under Artists');
    ok(scalar("@WARMED" eq id(1) && "@WARM_BG" eq '1'),
       '10: ... its count, not known yet, is asked as background work');
    ok(scalar($run->('Jandek', []) eq 'H:TOP_RESULT|MB:1'),
       '10: nothing else found -> the act alone as the Top Result, no "No artists found" line');
    $COUNT{ id(1) } = 120;
    ok(scalar($run->('Jandek', []) eq 'H:TOP_RESULT|MB:1' && !@WARMED),
       '10: a known count is not asked again');
    $COUNT{ id(1) } = 0;
    ok(scalar($run->('Jandek', []) eq 'PLUGIN_DISCOGRAPHY_SEARCH_NONE'),
       '10: an act MusicBrainz counts no releases for is not listed (as for the same-name acts)');
    delete $COUNT{ id(1) };

    # The tap and the heading open the act by its id.
    ($STRIPS, $LAYOUT) = (1, undef);
    my $out;
    $realWith->('client', sub { $out = $_[0] }, '', 'Jandek', []);
    my @items = @{ ($out || {})->{items} || [] };
    my ($hdr) = grep { ($_->{name} // '') eq 'PLUGIN_DISCOGRAPHY_TOP_RESULT' } @items;
    my $hp = ((($hdr || {})->{itemActions} || {})->{items} || {})->{fixedParams} || {};
    ok(scalar(($hp->{mbid} // '') eq id(1) && ($hp->{artist} // '') eq 'Jandek'),
       "10: the Top Result heading's More opens the act by its id");
    my ($row) = grep { ((($_->{passthrough} || [])->[0] || {})->{c_mbid} // '') eq id(1) } @items;
    ok(scalar($row && ((($row->{itemActions} || {})->{items} || {})->{fixedParams} || {})->{mbid} eq id(1)),
       '10: ... and so does the tile');
    {
        # A photo needs MAI or a service; with neither every row has the icon.
        local *{'Plugins::Discography::Sources::orderedAdapters'} = sub { ({ name => 'Qobuz' }) };
        $realWith->('client', sub { $out = $_[0] }, '', 'Jandek', []);
        ($row) = grep { ((($_->{passthrough} || [])->[0] || {})->{c_mbid} // '') eq id(1) }
                 @{ ($out || {})->{items} || [] };
        ok(scalar($row && ($row->{image} // '') =~ m{^imageproxy/dsc/artist/Jandek/}),
           "10: ... which gets the act's photo (a name MusicBrainz has once), not the person icon");
    }
    ($STRIPS, $LAYOUT) = (0, undef);
    ok(scalar($run->('Jandek', [ { name => 'JanDeKid', sources => ['Qobuz'], _seq => 0 } ], 'sect:ARTISTS')
              eq 'JanDeKid'),
       "10: the Artists heading's More answers the rows under Artists, not the Top Result");

    # A row that opens the act keeps it out (no duplicate), as for 2+ acts.
    $CANDS = $one->(2, 'Hawkwind');
    %RESOLVED = ('hawkwind' => id(2));
    ok(scalar($run->('Hawkwind', [ { name => 'Hawkwind', sources => ['Qobuz'], _seq => 0 } ])
              eq 'H:TOP_RESULT|Hawkwind'),
       '10: a service row the name resolver takes to the act -> not listed again');
    %RESOLVED = ();
    ok(scalar($run->('Hawkwind', [ { name => 'Hawkwind', sources => ['Qobuz'], _seq => 0 } ])
              eq 'H:TOP_RESULT|Hawkwind'),
       '10: ... an unresolved service row named as typed opens it too (the tap resolves that name)');
    ok(scalar($run->('Hawkwind', [ { name => 'Hawkwind Zoo', sources => ['Qobuz'], _seq => 0 } ])
              eq 'H:TOP_RESULT|MB:2|H:ARTISTS_HDR|Hawkwind Zoo'),
       '10: ... an unresolved row of another name does not');
    $CANDS = $one->(3, 'British Sea Power');
    %RESOLVED = ('sea power' => id(3));
    ok(scalar($run->('British Sea Power', [ { name => 'Sea Power', sources => ['Qobuz'], _seq => 0 } ])
              eq 'H:TOP_RESULT|Sea Power'),
       '10: a row of another name that the resolver takes to the act opens it');
    $CANDS = $one->(4, 'Jandek');
    ok(scalar($run->('Jandek', [ { name => 'Jandek', artist_id => 7, sources => ['Local'], _ident_mbid => id(4), _seq => 0 } ])
              eq 'H:TOP_RESULT|Jandek'),
       '10: the owned act itself (by tag) -> not listed');
    ok(scalar($run->('Jandek', [ { name => 'Jandek', artist_id => 7, sources => ['Local'], _seq => 0 } ])
              eq 'H:TOP_RESULT|Jandek'),
       '10: an untagged owned row of the typed name opens the one act of it -> not listed');
    %LIBMBID = (7 => id(5));
    ok(scalar($run->('Jandek', [ { name => 'Jandek', artist_id => 7, sources => ['Local'], _seq => 0 } ])
              eq 'H:TOP_RESULT|Jandek|H:ARTISTS_HDR|MB:4'),
       "10: ... but one whose albums named ANOTHER act (C2) leaves it out of reach -> listed, under Artists");
    %LIBMBID = ();

    # Owned first: the act goes under Artists, the owned match stays on top.
    $CANDS = $one->(6, 'Bush');
    %RESOLVED = ('bush' => id(6));
    ok(scalar($run->('Bush', [ { name => 'Kate Bush', artist_id => 9, sources => ['Local', 'Qobuz'], _seq => 0 },
                               { name => 'Bushwick Bill', sources => ['Qobuz'], _seq => 1 } ])
              eq 'H:TOP_RESULT|Kate Bush|H:ARTISTS_HDR|MB:6|Bushwick Bill'),
       '10: something owned -> it stays the Top Result, the act leads Artists');

    # The typed name opens ANOTHER act (C1: ELO is the band): not the Top Result.
    $CANDS = $one->(7, 'ELO');
    %RESOLVED = ('elo' => id(8), 'electric light orchestra' => id(8));
    ok(scalar($run->('ELO', [ { name => 'Electric Light Orchestra', sources => ['Qobuz'], _seq => 0 } ])
              eq 'H:TOP_RESULT|Electric Light Orchestra|H:ARTISTS_HDR|MB:7'),
       '10: the typed name opens another act (the initials lift) -> the act goes under Artists');

    # The helper's own contract: ONE act, never the first of several.
    ok(scalar(!defined $B->can('_loneMbAct')->('Madness', [],
              [ map { { mbid => id($_), name => 'Madness' } } 81 .. 82 ])),
       '10: _loneMbAct answers nothing for two acts');

    # CONTROLS: no act, or several (the same-name rules, unchanged).
    $CANDS = [];
    ok(scalar($run->('Jandek', [ { name => 'JanDeKid', sources => ['Qobuz'], _seq => 0 } ])
              eq 'H:TOP_RESULT|JanDeKid' && !@PEEKED && !@WARMED),
       '10: control: no MusicBrainz act -> the page as before, nothing looked up or asked');
    $CANDS = [ map { { mbid => id($_), name => 'Madness', disambiguation => "act $_" } } 81 .. 82 ];
    %COUNT = map { (id($_) => 5) } 81 .. 82;
    ok(scalar($run->('Madness', []) eq 'H:TOP_RESULT|MB:81|H:ARTISTS_HDR|MB:82'),
       '10: two acts and nothing found -> the first the Top Result (2026-10-09), the other under Artists');
    %RESOLVED = ('madness' => id(82));
    ok(scalar($run->('Madness', []) eq 'H:TOP_RESULT|MB:82|H:ARTISTS_HDR|MB:81'),
       "10: ... the name resolver's answer leads when it is one of them");
    %RESOLVED = ('madness' => id(99));
    ok(scalar($run->('Madness', []) eq 'PLUGIN_DISCOGRAPHY_SEARCH_NONE|H:ARTISTS_HDR|MB:81|MB:82'),
       '10: ... the typed name opens another act (C1) -> no Top Result, the acts under Artists as before');
    %RESOLVED = ();
    ok(scalar($run->('Madness', [ { name => 'Madness', sources => ['Qobuz'], _seq => 0 } ])
              eq 'H:TOP_RESULT|Madness|H:ARTISTS_HDR|MB:82'),
       '10: (control) a row found -> it leads as before, the act it reaches not listed again');
    {
        # The lead's photo: by name only when the resolver's answer names it.
        local *{'Plugins::Discography::Sources::orderedAdapters'} = sub { ({ name => 'Qobuz' }) };
        my $leadImg = sub {
            my $o;
            $realWith->('client', sub { $o = $_[0] }, '', 'Madness', []);
            my ($r) = grep { ((($_->{passthrough} || [])->[0] || {})->{c_mbid} // '') eq $_[0] }
                      @{ ($o || {})->{items} || [] };
            return $r ? ($r->{image} // '') : 'NO ROW';
        };
        %RESOLVED = ('madness' => id(82));
        ok(scalar($leadImg->(id(82)) =~ m{^imageproxy/dsc/artist/Madness/}),
           "10: ... a lead the resolver names gets the name's photo");
        %RESOLVED = ();
        my $img = $leadImg->(id(81));
        ok(scalar($img ne 'NO ROW' && $img !~ m{^imageproxy/dsc/artist/}),
           '10: ... a lead taken as MusicBrainz\'s first keeps the person icon (never a guessed photo)');
    }
    ($CANDS, %RESOLVED, %COUNT) = (undef);
});

section('11', sub {
    # -----------------------------------------------------------------------
    # 11. NOTHING FOUND: THE CLOSEST NAMES MUSICBRAINZ KNOWS (0.56.38, resolver
    #     plan Part D step 2; Simon: "okay"). Measured on 0.56.37: "Beatels",
    #     "Hawkwnd", "Jandec" read "No artists found" after 4-7 s. Asked ONLY when
    #     nothing else was found, listed under Artists below that line, never the
    #     Top Result (the closest can be the wrong act: Jandec -> Handel).
    # -----------------------------------------------------------------------
    no warnings 'redefine'; no strict 'refs';
    local *{"${B}::_searchResultItems"} = $realItems;
    local *{"${B}::_mbCandidateRow"}    = $realMbRow;
    local *{"${B}::_sectionHeader"}     = $realHdr;
    local *{"${B}::_useStrips"}         = sub { $STRIPS };
    local *{'Plugins::Discography::Sources::orderedAdapters'} = sub { ({ name => 'Qobuz' }) };
    my $WJ = "\x{2060}";
    my $out;
    my $label = sub {
        my ($r) = @_;
        return 'H:' . ($r->{name} =~ s/^PLUGIN_DISCOGRAPHY_//r) if ($r->{type} // '') =~ /^header|^text$/
            && ($r->{name} // '') =~ /^PLUGIN_DISCOGRAPHY_(?:TOP_RESULT|ARTISTS_HDR)$/;
        my $pt = ($r->{passthrough} || [])->[0] || {};
        return 'MB:' . ($pt->{c_mbid} =~ s/^0*(\d+)-.*/$1/r) if $pt->{c_mbid};
        return ($r->{name} // '') =~ s/$WJ//gr;
    };
    my $run = sub {
        my ($q, $merged, $part) = @_;
        $out = undef;
        @WARMED = (); @WARM_BG = (); @FUZZY_ASKED = ();
        $realWith->('client', sub { $out = $_[0] }, '', $q, $merged, $part);
        return join('|', map { $label->($_) } @{ ($out || {})->{items} || [] });
    };
    my $row = sub { my ($n) = @_;
        (grep { ((($_->{passthrough} || [])->[0] || {})->{c_mbid} // '') eq id($n) } @{ ($out || {})->{items} || [] })[0] };
    ($STRIPS, $LAYOUT, %RESOLVED) = (0, undef);
    %COUNT = ();

    # Beatels: nothing on the services, no act of that name.
    $CANDS = [];
    $FUZZY = [ { mbid => id(1), name => 'The Beatles', disambiguation => 'UK rock band', type => 'Group' },
               { mbid => id(2), name => 'Beaters' } ];
    ok(scalar($run->('Beatels', []) eq 'PLUGIN_DISCOGRAPHY_SEARCH_NONE|H:ARTISTS_HDR|MB:1|MB:2'),
       '11: nothing found -> "No artists found", then the closest names under Artists, in their order');
    ok(scalar("@FUZZY_ASKED" eq 'Beatels'), '11: ... asked once, for the typed name');
    ok(scalar("@WARMED" eq id(1) . ' ' . id(2) && "@WARM_BG" eq '1'),
       '11: ... their unknown counts asked as background work');
    my $r1 = $row->(1);
    ok(scalar($r1 && (((($r1->{itemActions} || {})->{items} || {})->{fixedParams} || {})->{mbid} // '') eq id(1)),
       '11: ... each opens its act by id');
    ok(scalar($r1 && ($r1->{image} // '') =~ m{^imageproxy/dsc/artist/The%20Beatles/}),
       '11: ... a name shown once gets its photo by name');
    ok(scalar($run->('Beatels', [], 'sect:ARTISTS') eq 'MB:1|MB:2'),
       "11: the Artists heading's More answers the same names");

    # A repeated name keeps the person icon (which of them the photo shows is a guess).
    $FUZZY = [ { mbid => id(3), name => 'Nirvana', disambiguation => 'US grunge band' },
               { mbid => id(4), name => 'Nirvana', disambiguation => '60s band from the UK' } ];
    $run->('Nirvanna', []);
    ok(scalar(!grep { ($_->{image} // '') !~ /icon_person/ } grep { $_ } ($row->(3), $row->(4))),
       '11: a name shown twice keeps the person icon on both');
    ok(scalar($row->(3) && $row->(4)), '11: ... and both are listed');

    # Counts: 0 hidden, known not asked again.
    $FUZZY = [ { mbid => id(5), name => 'Jandek' }, { mbid => id(6), name => 'Jander' } ];
    %COUNT = (id(5) => 60, id(6) => 0);
    ok(scalar($run->('Jandec', []) eq 'PLUGIN_DISCOGRAPHY_SEARCH_NONE|H:ARTISTS_HDR|MB:5' && !@WARMED),
       '11: a name MusicBrainz counts no releases for is hidden; a known count is not asked again');
    %COUNT = ();

    # Nothing close: the page as before.
    $FUZZY = [];
    ok(scalar($run->('Xqzvw', []) eq 'PLUGIN_DISCOGRAPHY_SEARCH_NONE'),
       '11: no close name -> "No artists found" alone');

    # ASKED ONLY WHEN NOTHING ELSE WAS FOUND.
    $FUZZY = [ { mbid => id(1), name => 'The Beatles' } ];
    ok(scalar($run->('Beatels', [ { name => 'Beatels Tribute', sources => ['Qobuz'], _seq => 0 } ])
              eq 'H:TOP_RESULT|Beatels Tribute' && !@FUZZY_ASKED),
       '11: a result row found -> not asked');
    $CANDS = [ { mbid => id(7), name => 'Jandek' } ];
    %RESOLVED = ('jandek' => id(7));
    ok(scalar($run->('Jandek', []) eq 'H:TOP_RESULT|MB:7' && !@FUZZY_ASKED),
       '11: the one act of the name listed -> not asked');
    $COUNT{ id(7) } = 0;
    ok(scalar($run->('Jandek', []) eq 'PLUGIN_DISCOGRAPHY_SEARCH_NONE|H:ARTISTS_HDR|MB:1' && "@FUZZY_ASKED" eq 'Jandek'),
       '11: ... but one with no releases leaves nothing found -> asked');
    %COUNT = ();
    $CANDS = [ map { { mbid => id($_), name => 'Madness', disambiguation => "act $_" } } 81 .. 82 ];
    %COUNT = map { (id($_) => 5) } 81 .. 82;
    ok(scalar($run->('Madness', []) eq 'H:TOP_RESULT|MB:81|H:ARTISTS_HDR|MB:82' && !@FUZZY_ASKED),
       '11: two acts of the name and no rows -> the first the Top Result, the other under Artists, not asked');
    ($CANDS, $FUZZY, %RESOLVED, %COUNT) = (undef, undef);
});

section('12', sub {
    # -----------------------------------------------------------------------
    # 12. VARIOUS ARTISTS / VARIOUS COMPOSERS IS NEVER ONE ARTIST (0.56.41;
    #     Simon: "we should not allow a search for Various Artists"). Measured
    #     on 0.56.40: the search listed MusicBrainz's special entity and asked
    #     the community API for its discography (no answer in 30 s).
    # -----------------------------------------------------------------------
    no warnings 'redefine'; no strict 'refs';
    local *{"${B}::_searchResultItems"} = $realItems;
    local *{"${B}::_mbCandidateRow"}    = $realMbRow;
    local *{"${B}::_sectionHeader"}     = $realHdr;
    local *{"${B}::_useStrips"}         = sub { 0 };
    local *{'Plugins::Discography::Sources::orderedAdapters'} = sub { ({ name => 'Qobuz' }) };
    my $VA = '89ad4ac3-39f7-470e-963a-56509c546377';
    my $WJ = "\x{2060}";
    my $out;

    # The typed name: one line, nothing asked.
    for my $q ('Various Artists', '  various COMPOSERS ') {
        fresh(); @CANDS_ASKED = (); @FUZZY_ASKED = (); @WARMED = ();
        $out = undef;
        $B->can('_artistSearchView')->('client', sub { $out = $_[0] }, '', $q);
        my @items = @{ ($out || {})->{items} || [] };
        (my $t = $q) =~ s/^\s+|\s+$//g;
        ok(scalar(@items == 1 && ($items[0]{type} // '') eq 'text'
                  && ($items[0]{name} // '') eq "$t is not a single artist, so there is no discography"),
           "12: '$q' -> the one line saying it is not one artist, naming it");
        ok(scalar(!@SVC_CALLS && !@MB_CALLS && !@CANDS_ASKED && !@FUZZY_ASKED && !@WARMED && !@MERGED),
           "12: ... nothing asked: no service, no MusicBrainz lookup, no same-name acts, no closest names");
    }
    # Control: a name that only starts like it is searched as ever.
    fresh(); @CANDS_ASKED = ();
    view('Various Artists - Duck Records');
    ok(scalar("@SVC_CALLS" eq 'Various Artists - Duck Records' && @MB_CALLS == 1),
       '12: control: "Various Artists - Duck Records" is searched as before');

    # Its rows, from any source, are dropped before anything looks at them.
    my $label = sub {
        my ($r) = @_;
        return 'H:' . ($r->{name} =~ s/^PLUGIN_DISCOGRAPHY_//r) if ($r->{type} // '') =~ /^header|^text$/
            && ($r->{name} // '') =~ /^PLUGIN_DISCOGRAPHY_(?:TOP_RESULT|ARTISTS_HDR|SEARCH_NONE)$/;
        my $pt = ($r->{passthrough} || [])->[0] || {};
        return 'MB:' . ($pt->{c_mbid} =~ s/^0*(\d+)-.*/$1/r) if $pt->{c_mbid};
        return ($r->{name} // '') =~ s/$WJ//gr;
    };
    my $run = sub {
        my ($q, $merged) = @_;
        $out = undef; @FUZZY_ASKED = (); @WARMED = ();
        $realWith->('client', sub { $out = $_[0] }, '', $q, $merged);
        return join('|', map { $label->($_) } @{ ($out || {})->{items} || [] });
    };
    ($STRIPS, $LAYOUT, %RESOLVED, %COUNT) = (0, undef);
    $CANDS = []; $FUZZY = [];
    my $list = [ { name => 'Various Artists', artist_id => 151537, sources => ['Local'], _seq => 0 },
                 { name => 'VARIOUS COMPOSERS', sources => ['Qobuz'], _seq => 1 },
                 { name => 'VA', artist_id => 151659, sources => ['Local'], _ident_mbid => $VA, _seq => 2 },
                 { name => 'Various Artists - Duck Records', sources => ['Qobuz'], _seq => 3 } ];
    ok(scalar($run->('Various', $list) eq 'H:TOP_RESULT|Various Artists - Duck Records'),
       '12: Various Artists (Local), VARIOUS COMPOSERS (Qobuz) and a row tagged as MB\'s Various Artists are dropped; the rest stays');
    ok(scalar(@$list == 4), '12: ... the list it was handed (the search cache\'s own) is not changed');

    # All of them dropped = nothing found: the closest names, minus those.
    $FUZZY = [ { mbid => id(1), name => 'Various Artists' }, { mbid => $VA, name => 'Varioos' },
               { mbid => id(2), name => 'Varius' } ];
    ok(scalar($run->('Various', [ @$list[0 .. 2] ]) eq 'H:SEARCH_NONE|H:ARTISTS_HDR|MB:2'),
       '12: rows all dropped -> nothing found; among the closest names, Various Artists by name or by id is dropped too');
    ok(scalar("@WARMED" eq id(2)), '12: ... and only the kept name has its count asked');
    ($CANDS, $FUZZY) = (undef, undef);
});

section('13', sub {
    # -----------------------------------------------------------------------
    # 13. A NAME WITH NO LATIN LETTER IS TITLED WITH ITS ENGLISH ONE (0.56.42;
    #     Simon: "display the default from MB but with english translation as
    #     well", then "In the title"). Measured on 0.56.41: 宇多田ヒカル's row
    #     read "aka Cubic U", 坂本龍一's "aka R.S." (the first alias), Qobuz's
    #     王菲 and КИНО rows no English at all. The English name is MB's primary
    #     English alias, from the search reply (`en`) or the artist read's cache.
    #     Display only: a tap opens the real name.
    # -----------------------------------------------------------------------
    no warnings 'redefine'; no strict 'refs';
    local *{"${B}::_searchResultItems"} = $realItems;
    local *{"${B}::_mbCandidateRow"}    = $realMbRow;
    local *{"${B}::_sectionHeader"}     = $realHdr;
    local *{"${B}::_useStrips"}         = sub { 0 };
    local *{'Plugins::Discography::Sources::orderedAdapters'} = sub { ({ name => 'Qobuz' }) };
    my $WJ = "\x{2060}";
    my $fx  = sub { ((($_[0]{itemActions} || {})->{items} || {})->{fixedParams} || {}) };
    my $mb  = sub { $realMbRow->('client', $_[0], '', 1) };

    # Its own act rows (the same-name acts, the lone act, the closest names).
    @ALIASES = ('Cubic U'); %ENREAD = ();
    my $r = $mb->({ mbid => id(1), name => "宇多田ヒカル", en => 'Hikaru Utada',
                    disambiguation => 'Japanese-American singer-songwriter', type => 'Person' });
    ok(scalar($r->{name} eq "宇多田ヒカル (Hikaru Utada)"), '13: an act row: "宇多田ヒカル (Hikaru Utada)"');
    ok(scalar(($r->{line2} // '') eq "Japanese-American singer-songwriter \x{00B7} Person"),
       '13: ... and no "aka Cubic U" (the first alias is another spelling): the description as before');
    ok(scalar($fx->($r)->{artist} eq "宇多田ヒカル" && $fx->($r)->{mbid} eq id(1)
              && ($r->{passthrough}[0]{c_name} // '') eq "宇多田ヒカル"),
       '13: ... a tap opens the real name and mbid');
    ok(scalar(($r->{image} // '') !~ /Hikaru/), '13: ... its photo is looked up by the real name');
    # LMS hands names over as CHARACTERS; the literals above are UTF-8 bytes.
    my $chars = "宇多田ヒカル"; utf8::decode($chars);
    $r = $mb->({ mbid => id(1), name => $chars, en => 'Hikaru Utada' });
    ok(scalar($r->{name} eq "$chars (Hikaru Utada)" && $fx->($r)->{artist} eq $chars),
       '13: ... the same with the name in characters, as LMS hands it');
    %ENREAD = (id(2) => 'Ryuichi Sakamoto'); @ALIASES = ('R.S.');
    $r = $mb->({ mbid => id(2), name => "坂本龍一" });
    ok(scalar($r->{name} eq "坂本龍一 (Ryuichi Sakamoto)" && ($r->{line2} // '') !~ /aka/),
       '13: no English name in the reply -> the artist read\'s (cache), and no "aka R.S."');
    %ENREAD = (); @ALIASES = ('Ryuichi');
    $r = $mb->({ mbid => id(3), name => "坂本龍一" });
    ok(scalar($r->{name} eq "坂本龍一" && ($r->{line2} // '') =~ /^aka Ryuichi/),
       '13: no English name anywhere -> the name alone, and the aka as before');
    $r = $mb->({ mbid => id(4), name => "宇多田ヒカル", en => "宇多田光" });
    ok(scalar($r->{name} eq "宇多田ヒカル"), '13: an "English" name with no Latin letter is not added');
    @ALIASES = ('Tony Madness');
    $r = $mb->({ mbid => id(5), name => 'Madness', en => 'Madness Crew' });
    ok(scalar($r->{name} eq 'Madness' && ($r->{line2} // '') =~ /^aka Tony Madness/),
       '13: control: a Latin name is never retitled, and keeps its aka (the name its records sell under)');
    @ALIASES = ();

    # Result rows from the services and the library, through the real search page.
    my $out;
    my $run = sub {
        my ($q, $merged) = @_;
        $out = undef; @WARMED = ();
        $realWith->('client', sub { $out = $_[0] }, '', $q, $merged);
        return [ map { [ ($_->{name} // '') =~ s/$WJ//gr, $fx->($_)->{artist} // '' ] }
                 grep { ($_->{type} // '') ne 'text' && ($_->{name} // '') !~ /^PLUGIN_/ }
                 @{ ($out || {})->{items} || [] } ];
    };
    my $names = sub { join('|', map { $_->[0] } @{ $_[0] }) };
    ($STRIPS, $LAYOUT, %COUNT, %LIBMBID) = (0, undef);
    $CANDS = [ { mbid => id(11), name => "王菲", en => 'Faye Wong', disambiguation => 'Chinese singer-songwriter & actress' },
               { mbid => id(12), name => "王菲", disambiguation => 'Taiwan singer and actor' } ];
    %COUNT = (id(11) => 30, id(12) => 3);
    %RESOLVED = (lc("王菲") => id(11));
    my $got = $run->("王菲", [ { name => "王菲", sources => ['Qobuz'], _seq => 0 } ]);
    ok(scalar($got->[0][0] eq "王菲 (Faye Wong)" && $got->[0][1] eq "王菲"),
       '13: Qobuz\'s 王菲 (the act it opens, by the resolver\'s answer, is Faye Wong) -> "王菲 (Faye Wong)", opening "王菲"');
    ok(scalar($names->($got) =~ /\|王菲$/), '13: ... the other act of the name has no English name: titled as before');

    # The same act, but the English name only in the artist read's cache.
    $CANDS = [ { mbid => id(21), name => "КИНО" } ];
    %RESOLVED = (lc("КИНО") => id(21)); %ENREAD = (id(21) => 'Kino'); %COUNT = (id(21) => 20);
    $got = $run->("Кино", [ { name => "КИНО", sources => ['Qobuz'], _seq => 0 } ]);
    ok(scalar($got->[0][0] eq "КИНО (Kino)"), '13: Qobuz\'s КИНО -> "КИНО (Kino)" (the artist read\'s cache)');

    # The library: by its tag; an untagged owned row gets nothing (its page resolves by name).
    %ENREAD = (id(31) => 'Kenshi Yonezu'); $CANDS = []; %RESOLVED = (lc("米津玄師") => id(31));
    $got = $run->("米津玄師", [ { name => "米津玄師", artist_id => 7, sources => ['Local'], _ident_mbid => id(31), _seq => 0 } ]);
    ok(scalar($got->[0][0] eq "米津玄師 (Kenshi Yonezu)"), '13: an owned row by its library tag -> titled');
    $got = $run->("米津玄師", [ { name => "米津玄師", artist_id => 7, sources => ['Local'], _seq => 0 } ]);
    ok(scalar($got->[0][0] eq "米津玄師"), '13: an owned row with no tag -> as before (never a name guess)');
    @PEEKED = ();
    $got = $run->('Kenshi Yonezu', [ { name => 'Kenshi Yonezu', sources => ['Qobuz'], _seq => 0 } ]);
    ok(scalar($got->[0][0] eq 'Kenshi Yonezu'), '13: control: a Latin row name is never retitled');
    ok(scalar(!grep { $_ eq 'Kenshi Yonezu' } @PEEKED), '13: ... and costs no lookup of the act it opens');

    # A cached row (the 10-minute search list) is stamped afresh on every search.
    my $cachedRow = { name => "王菲", sources => ['Qobuz'], _seq => 0 };
    $CANDS = [ { mbid => id(11), name => "王菲", en => 'Faye Wong' } ]; %RESOLVED = (lc("王菲") => id(11));
    %COUNT = (id(11) => 30); %ENREAD = ();
    $run->("王菲", [ $cachedRow ]);
    $CANDS = [ { mbid => id(11), name => "王菲" } ];
    $got = $run->("王菲", [ $cachedRow ]);
    ok(scalar($got->[0][0] eq "王菲"), '13: a cached row keeps no English name a later search no longer has');

    # The one act of the name as the Top Result (0.56.37), from the reply's English name.
    $CANDS = [ { mbid => id(31), name => "米津玄師", en => 'Kenshi Yonezu' } ]; %ENREAD = ();
    %COUNT = (id(31) => 40);
    $got = $run->("米津玄師", []);
    ok(scalar($got->[0][0] eq "米津玄師 (Kenshi Yonezu)" && $got->[0][1] eq "米津玄師"),
       '13: the one act no row opens, as the Top Result -> "米津玄師 (Kenshi Yonezu)", opening "米津玄師"');
    ($CANDS, %RESOLVED, %COUNT, %ENREAD) = (undef);
});

section('14', sub {
    # -----------------------------------------------------------------------
    # 14. THE TOP RESULT IS HANDED TO THE PREFETCH (0.56.56; Simon, 2026-10-07:
    #     "start to cache the top hit after search"), once the page is out: the
    #     row _searchSections puts first, with the params its tap sends; undef
    #     when nothing was found (that stops an earlier search's prefetch); not
    #     at all for the Artists heading's More (the same search, its rows only).
    # -----------------------------------------------------------------------
    no warnings 'redefine'; no strict 'refs';
    local *{"${B}::_searchResultItems"} = $realItems;
    local *{"${B}::_mbCandidateRow"}    = $realMbRow;
    local *{"${B}::_sectionHeader"}     = $realHdr;
    local *{"${B}::_useStrips"}         = sub { 0 };
    ($STRIPS, $LAYOUT) = (0, undef);
    my $run = sub {
        my ($q, $merged, $part) = @_;
        @PREFETCH = (); $REPLIED = 0;
        my $out;
        $realWith->('client', sub { $out = $_[0]; $REPLIED = 1 }, '', $q, $merged, $part);
        return $out;
    };
    my $fixed = sub { ((($_[0] || {})->{itemActions} || {})->{items} || {})->{fixedParams} || {} };
    my $topOf = sub {
        my @it = @{ ($_[0] || {})->{items} || [] };
        for my $i (0 .. $#it) {
            return $it[ $i + 1 ] if ($it[$i]{name} // '') eq 'PLUGIN_DISCOGRAPHY_TOP_RESULT';
        }
        return undef;
    };

    $CANDS = []; %RESOLVED = (); %COUNT = ();
    my $out = $run->('Genesis', [ { name => 'Genesis', artist_id => 7, sources => ['Local', 'Qobuz'], _seq => 0 },
                                  { name => 'Genesis Owusu', sources => ['Qobuz'], _seq => 1 } ]);
    my $top = $topOf->($out);
    ok(scalar(@PREFETCH == 1 && $PREFETCH[0][1]), '14: the prefetch is started once, after the page is out');
    ok(scalar($top && ($fixed->($PREFETCH[0][0])->{artist} // '') eq 'Genesis'
              && ($fixed->($PREFETCH[0][0])->{artist_id} // '') eq '7'
              && $fixed->($PREFETCH[0][0])->{artist} eq ($fixed->($top)->{artist} // '')),
       "14: ... with the Top Result's own tap params (Genesis, library id 7), not the second row's");

    $run->('Genesis', [ { name => 'Genesis', artist_id => 7, sources => ['Local'], _seq => 0 } ], 'sect:ARTISTS');
    ok(scalar(!@PREFETCH), "14: the Artists heading's More (the same search) starts nothing");

    $CANDS = [ { mbid => id(1), name => 'Jandek', type => 'Person', country => 'US' } ];
    %RESOLVED = ('jandek' => id(1)); %COUNT = (id(1) => 30);
    $run->('Jandek', [ { name => 'JanDeKid', sources => ['Qobuz'], _seq => 0 } ]);
    ok(scalar(@PREFETCH == 1 && ($fixed->($PREFETCH[0][0])->{mbid} // '') eq id(1)),
       '14: the one MusicBrainz act as the Top Result is handed over by its mbid, not the near miss under Artists');

    $CANDS = []; %RESOLVED = (); %COUNT = (); $FUZZY = [];
    $run->('Zzyzx', []);
    ok(scalar(@PREFETCH == 1 && !defined $PREFETCH[0][0]),
       '14: nothing found: undef is handed over (an earlier prefetch stops)');
    ($CANDS, %RESOLVED, %COUNT, $FUZZY) = (undef);
});

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
