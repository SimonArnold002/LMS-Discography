#!/usr/bin/env perl
#
# THE SEARCH'S OWN MUSICBRAINZ STEPS (stage 3 review, 2026-09-30).
#
# 1. The typed query's MusicBrainz lookup goes out ALONGSIDE the service search,
#    and the list waits for both (review finding 1). It needs only the query;
#    started after the services had answered, it added its whole time to every
#    new search.
# 2. The same-name section does not ask again for a count the row check asked
#    for and saw settle (review finding 4): if that count failed, the section
#    shows the act (undef), exactly as a second failure would, without a second
#    wait.
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
our (@WARMED, %COUNT, $MARK, $OPT);
our $CANDS;      # section 7: the same-name set to answer with (undef = three Genesis)

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
        # A count the row check asked for and saw settle (here: failed).
        $opt->{asked}{ $main::MARK } = 1 if $main::MARK && ref $opt eq 'HASH' && $opt->{asked};
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
        return $cb->();
    };
    *{"${A}::peekReleaseGroupCount"} = sub { $main::COUNT{ $_[1] // '' } };
}

package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}

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
        push @main::MERGED, [ $q, [ map { $_->{name} } @{ $merged || [] } ] ];
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
    # 6. THE SAME-NAME SECTION ASKS ONCE PER SEARCH. The row check has asked for
    #    the second act's count and seen it fail; the section does not ask
    #    again, and still lists the act (an unknown count shows, never hides).
    # -----------------------------------------------------------------------
    my $out;
    my $run = sub {
        @WARMED = (); $OPT = undef; $out = undef;
        $realWith->('client', sub { $out = $_[0] }, '', 'Genesis',
                    [ { name => 'Genesis', sources => ['Qobuz'] } ]);
    };
    %COUNT = (id(1) => 40, id(3) => 7);    # id(2)'s count failed: never cached

    $MARK = id(2);
    $run->();
    ok(scalar(ref $OPT eq 'HASH' && ($OPT->{query} // '') eq 'Genesis' && ref $OPT->{asked} eq 'HASH'),
       '6: the search hands the row check the query and a set to collect its counts in');
    ok(scalar(join(',', @WARMED) eq join(',', id(1), id(3))),
       '6: the section does not ask again for a count the row check tried');
    my @names = map { $_->{name} } @{ ($out || {})->{items} || [] };
    ok(scalar(grep { $_ eq id(2) } @names),
       '6: ... and still lists that act (a failed count shows it, as before)');

    # CONTROL: nothing asked by the row check -> the section asks for all three.
    $MARK = undef;
    $run->();
    ok(scalar(join(',', @WARMED) eq join(',', id(1), id(2), id(3))),
       '6: control: with nothing asked before, the section counts every act');
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

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
