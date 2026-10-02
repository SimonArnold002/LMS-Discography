#!/usr/bin/env perl
#
# THE SEARCH ROW CHECK ON EVERY SETUP (stage 3 step 3, 2026-09-30).
#
# filterRowsWithContent returned early on the public API from 0.44.7. It now
# runs everywhere, resolving rows in three passes, cheapest first (analysis
# §A12.3b-c; API::_rowBatch):
#   1. the TYPED QUERY's own reply (the shared name search's 15 entries when
#      they are the whole result, else one request at 100): a row takes the
#      artist when exactly ONE artist in it has the row's exact name, or (stage
#      3b) when none has it and exactly ONE carries it as an alias (§8);
#   2. ONE combined search, `artist:"A" OR artist:"B" ...`, for two or more rows
#      left: the same rule, trusted only when the reply is COMPLETE (since
#      0.56.6 the rows pass 1 answered unproven ride in it to be proven, §9);
#   3. since stage 3b (0.56.5) the community API by name for the rest (§6), the
#      real resolver only where it cannot decide.
# Both batch rules were measured identical to the real resolver on every row
# they answered (124 of 149 sampled rows). Stage 3 used what they decide for
# the list only; since stage 3b an answer the reply PROVES (every artist of the
# row's name in it, exactly one) is also cached as the name's resolution for
# the page (§7).
#
# Driven through the REAL _rowBatch and filterRowsWithContent (queue bypassed:
# t_netqueue.pl owns it), on the PUBLIC base.
#
# Standalone -- no LMS install needed:  perl tools/t_rowbatch.pl
#
use strict;
use warnings;
use FindBin;
use JSON::XS ();

my %CACHE;
my @QUERIES;
our @DEFERRED;
our $MB_BASE = 'https://musicbrainz.org/ws/2/';
our %REPLY;          # url prefix => reply | 'ERROR'
our %TAG;            # contributor id => its MusicBrainz tag
our @BGQ;            # per request in @QUERIES: 1 when sent as background work

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
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Cache' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Cache' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Utils::Timers::setTimer'}   = sub { $_[2]->() };
    *{'Slim::Utils::Timers::killTimers'} = sub { 1 };
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { JSON::XS::encode_json($_[0]) };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { JSON::XS::decode_json($_[0]) };
    # The library's tag (getArtistMbid / _libraryTagMbid) and the tag attach
    # (localArtistsByMbid): only %TAG answers; everything else is untagged.
    *{'Slim::Schema::find'} = sub {
        my (undef, $what, $id) = @_;
        return undef unless $what eq 'Contributor' && exists $main::TAG{$id};
        return bless { mb => $main::TAG{$id} }, 'T::Contrib';
    };
    *{'Slim::Schema::rs'} = sub { bless {}, 'T::RS' };
    *{'Slim::Control::Request::executeRequest'} = sub { undef };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs JSON::XS::VersionOneAndTwo)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
    @{'JSON::XS::VersionOneAndTwo::EXPORT'} = qw(to_json from_json);
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Cache;
sub get    { return $CACHE{ $_[1] } }
sub set    { $CACHE{ $_[1] } = $_[2]; return 1 }
sub remove { delete $CACHE{ $_[1] }; return 1 }
package T::Prefs;
sub get { return $_[1] eq 'mb_base_url' ? $main::MB_BASE : undef }
sub set { 1 } sub init { 1 } sub setChange { 1 }
package T::Contrib;
sub musicbrainz_id { $_[0]{mb} }
package T::RS;
sub search { bless {}, 'T::RS' }
sub all    { () }
package T::Resp;
sub new     { my ($c, $b) = @_; bless { b => $b }, $c }
sub content { $_[0]{b} }
sub error   { 'stub error' }
sub code    { 500 }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
require Plugins::Discography::API;
my $API = 'Plugins::Discography::API';

{
    no strict 'refs'; no warnings 'redefine';
    *{'Plugins::Discography::API::_netGet'} = sub {
        my ($url, $ok, $err, %opt) = @_;
        push @QUERIES, $url;
        # The real queue's rule (t_netqueue.pl): a job is background when asked
        # so or when made while $NET_BG is set, and its answer runs under it.
        my $bg = ($opt{background} || $Plugins::Discography::API::NET_BG) ? 1 : 0;
        push @BGQ, $bg;
        push @DEFERRED, sub {
            local $Plugins::Discography::API::NET_BG = $bg;
            my ($hit) = grep { index($url, $_) == 0 } sort { length $b <=> length $a } keys %REPLY;
            my $r = defined $hit ? $REPLY{$hit} : undef;
            return $err->(T::Resp->new(''), 'stub error', T::Resp->new(''))
                if !defined $r || (!ref $r && $r eq 'ERROR');
            # MusicBrainz returns at most `limit` entries (with the full count):
            # a reply longer than asked would pass for the whole result.
            my %copy = %$r;
            if (ref $r->{artists} eq 'ARRAY' && (my ($lim) = $url =~ /[?&]limit=(\d+)/)) {
                my $n = @{ $r->{artists} };
                $n = $lim if $lim < $n;
                $copy{artists} = [ @{ $r->{artists} }[0 .. $n - 1] ];
            }
            $ok->(T::Resp->new(JSON::XS::encode_json(\%copy)));
        };
    };
}

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}
sub flush {
    for (1 .. 50) {
        my @d = @DEFERRED;
        last unless @d;
        @DEFERRED = ();
        for my $cb (@d) {
            eval { $cb->(); 1 } or do { (my $e = $@) =~ s/\s+/ /g; ok(0, "a response callback died: $e") };
        }
    }
}
sub section {
    my ($n, $code) = @_;
    eval { $code->(); 1 } or do { (my $e = $@) =~ s/\s+/ /g; ok(0, "$n: the section died: $e") };
}
sub cold {
    %CACHE = (); @QUERIES = (); @DEFERRED = (); %REPLY = (); %TAG = (); @BGQ = ();
    no warnings "once";
    %Plugins::Discography::API::ROWCHECK_BUSY = ();
    %Plugins::Discography::API::NAME_MEMO = ();
    %Plugins::Discography::API::NAME_WAIT = ();
}
sub id { sprintf('%08d-0000-0000-0000-000000000000', $_[0]) }
sub q_for { $MB_BASE . Plugins::Discography::API::_nameQuery('artist', $_[0], 0) }
sub combined_asked { scalar grep { /artist\?query=.*%20OR%20/ } @QUERIES }
sub batch {
    my ($q, @names) = @_;
    my $got;
    my @pend = map { [ $_, $names[$_] ] } 0 .. $#names;
    $API->_rowBatch($q, \@pend, sub { $got = $_[0] });
    flush();
    return $got || {};
}

# The typed query "genesis": the reply of 100 the search resolved it with.
my @GEN = (
    { id => id(1),  name => 'Genesis',              score => 100 },
    { id => id(2),  name => 'Genesis',              score => 99 },    # a second exact "Genesis"
    { id => id(3),  name => 'Genesis Brass',        score => 90 },
    { id => id(4),  name => 'Gênesis',              score => 88 },    # folds to "genesis"
    { id => id(5),  name => 'Genesis Piano Project', score => 80 },
    { id => id(6),  name => 'Tommy Genesis',        score => 75 },
    { id => id(7),  name => 'Anthrax',              score => 70 },
    { id => '89ad4ac3-39f7-470e-963a-56509c546377', name => 'Genesis P', score => 60 },  # Various Artists' id
    { id => id(8),  name => 'Genesis P',            score => 60 },
);
my $GEN = { count => scalar(@GEN), artists => \@GEN };

section('1', sub {
    # -----------------------------------------------------------------------
    # 1. PASS 1: exactly one artist named like the row -> that artist.
    # -----------------------------------------------------------------------
    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    my $p = batch('genesis', 'Genesis Brass', 'Tommy Genesis', 'Genesis Piano Project');
    ok(($p->{0} // '') eq id(3) && ($p->{1} // '') eq id(6) && ($p->{2} // '') eq id(5),
       '1: rows named uniquely in the typed query\'s reply take that artist');
    ok(combined_asked() == 0, '1: every row answered: no combined search');

    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    # "Génesis" folds to the same name as three artists in the reply but is NOT
    # the query's own string, so it reaches the rule (a row spelled like the
    # query itself would go to the resolver before the rule ever looked).
    my $gen = "G\x{e9}nesis"; utf8::upgrade($gen);
    $p = batch('genesis', $gen, 'Nobody Like It', 'Genesis P');
    ok(!defined $p->{0}, '1: several artists so named (Genesis x2 + Gênesis): left for the resolver');
    ok(!defined $p->{1}, '1: none so named: left for the resolver');
    ok(($p->{2} // '') eq id(8), "1: MusicBrainz's special entities never count (Genesis P is unique)");

    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $p = batch('genesis', 'Anthrax (US)');
    ok(($p->{0} // '') eq id(7), "1: a service's annotation is stripped, as the resolver strips it");
});

section('2', sub {
    # -----------------------------------------------------------------------
    # 2. THE ROW NAMED EXACTLY LIKE THE QUERY is never taken by the batch: the
    #    resolver answered that very name for the search.
    # -----------------------------------------------------------------------
    cold();
    $REPLY{ q_for('Tommy Genesis') } = { count => 1, artists => [ { id => id(6), name => 'Tommy Genesis', score => 100 } ] };
    my $p = batch('Tommy Genesis', 'Tommy Genesis', 'tommy genesis ');
    ok(!defined $p->{0} && !defined $p->{1},
       '2: the query\'s own row (any case, any spacing) goes to the resolver');
});

section('3', sub {
    # -----------------------------------------------------------------------
    # 3. PASS 2: one combined search for two or more rows left.
    # -----------------------------------------------------------------------
    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $REPLY{ $MB_BASE . 'artist?query=artist%3A%22Au%20Pair' } = { count => 3, artists => [
        { id => id(20), name => 'Au Pair',     score => 100 },
        { id => id(21), name => 'Hall Of Fam', score => 100 },
        { id => id(22), name => 'Au Pairs',    score => 80 },
    ] };
    my $p = batch('genesis', 'Au Pair', 'Hall Of Fam');
    ok(combined_asked() == 1, '3: two rows left: ONE combined search');
    my ($u) = grep { /%20OR%20/ } @QUERIES;
    ok(scalar(($u // '') =~ /artist%3A%22Au%20Pair%22%20OR%20artist%3A%22Hall%20Of%20Fam%22&fmt=json&limit=100$/),
       '3: ... an OR of the rows\' quoted names, 100 entries');
    ok(($p->{0} // '') eq id(20) && ($p->{1} // '') eq id(21),
       '3: a COMPLETE reply answers each row named uniquely in it');

    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $REPLY{ $MB_BASE . 'artist?query=artist%3A%22Au%20Pair' } = { count => 250, artists => [
        { id => id(20), name => 'Au Pair', score => 100 },
        { id => id(21), name => 'Hall Of Fam', score => 100 },
    ] };
    $p = batch('genesis', 'Au Pair', 'Hall Of Fam');
    ok(!defined $p->{0} && !defined $p->{1},
       '3: an INCOMPLETE reply (250 matched, 2 returned) answers nothing');

    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $REPLY{ $MB_BASE . 'artist?query=artist%3A%22Au%20Pair' } = { artists => [
        { id => id(20), name => 'Au Pair', score => 100 } ] };
    $p = batch('genesis', 'Au Pair', 'Hall Of Fam');
    ok(!defined $p->{0}, '3: a reply with no count is not trusted as complete');

    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $REPLY{ $MB_BASE . 'artist?query=artist%3A%22Au%20Pair' } = 'ERROR';
    $p = batch('genesis', 'Au Pair', 'Hall Of Fam');
    ok(!defined $p->{0} && !defined $p->{1}, '3: a failed combined search answers nothing');

    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $p = batch('genesis', 'Au Pair', 'Genesis Brass');
    # Counted as ALL name searches: a combined search for one row would carry no
    # "OR" at all, so looking for one would miss it.
    ok(scalar(grep { index($_, 'artist?query=') >= 0 } @QUERIES) == 1 && ($p->{1} // '') eq id(3),
       "3: ONE row left: no combined search (the resolver's own first pass is that question)");

    # Annotations are stripped from the combined query too: parentheses are
    # Lucene syntax and would make MusicBrainz match nothing.
    cold();
    $p = batch('', 'Anthrax (US)', 'Other [UK]');
    my ($ua) = grep { /%20OR%20/ } @QUERIES;
    ok(scalar(($ua // '') =~ /artist%3A%22Anthrax%22%20OR%20artist%3A%22Other%22&/),
       '3: the combined query carries the names without their annotations');

    cold();
    $REPLY{ $MB_BASE . 'artist?query=artist%3A%22Say%20' } = { count => 2, artists => [
        { id => id(30), name => 'Say "Hello"', score => 100 },
        { id => id(31), name => 'Other',       score => 100 } ] };
    $p = batch('', 'Say "Hello"', 'Other');
    my ($u2) = grep { /%20OR%20/ } @QUERIES;
    ok(scalar(($u2 // '') =~ /artist%3A%22Say%20%20Hello%20%22%20OR%20/),
       '3: a quote inside a name is blanked in the combined query');
    ok(!grep({ index($_, 'artist%3A%22genesis') >= 0 } @QUERIES),
       '3: no typed query -> pass 1 is skipped');
});

section('4', sub {
    # -----------------------------------------------------------------------
    # 4. END TO END on the PUBLIC API: the typed query's reply is the one the
    #    search already fetched; batch answers are judged by their counts;
    #    none of them is cached as the name's resolution.
    # -----------------------------------------------------------------------
    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    # Counts: the community API gives nothing usable here, MusicBrainz answers.
    $REPLY{ $MB_BASE . 'release-group?artist=' . id(3) } = { 'release-group-count' => 12 };
    $REPLY{ $MB_BASE . 'release-group?artist=' . id(6) } = { 'release-group-count' => 0 };
    # The search's own lookup of the typed query has already fetched its reply.
    $API->getArtistMbid(artist => 'genesis', fetch => $API->NAME_FETCH, onDone => sub {});
    flush();
    my $before = scalar grep { index($_, 'artist%3A%22genesis') >= 0 } @QUERIES;
    my $out;
    $API->filterRowsWithContent([
        { name => 'Genesis Brass', sources => ['Qobuz'] },
        { name => 'Tommy Genesis', sources => ['Deezer'] },
    ], sub { $out = $_[0] }, { query => 'genesis' });
    flush();
    my $after = scalar grep { index($_, 'artist%3A%22genesis') >= 0 } @QUERIES;
    ok($before == 1 && $after == 1,
       '4: the rows are answered from the reply the search already fetched (no request)');
    ok(ref $out eq 'ARRAY' && join(',', map { $_->{name} } @$out) eq 'Genesis Brass',
       '4: a row with releases is kept; a row whose artist has none is dropped');
    # STAGE 3b (2026-09-30): an answer the reply PROVES (it is whole, so it
    # holds every artist of these names, and one of them has each) is now
    # handed to the page as the name's resolution. §7 pins the conditions.
    ok(($CACHE{ Plugins::Discography::API::_mbidKey('Genesis Brass') } // '') eq id(3)
       && ($CACHE{ Plugins::Discography::API::_mbidKey('Tommy Genesis') } // '') eq id(6),
       "4: the batch's PROVEN answers are cached as the names' resolution (stage 3b)");
    ok(scalar(grep { m{^https://api\.lms-community\.org/} } @QUERIES) == 2,
       '4: the counts were asked of the community API first');

    # A typed query whose 15-entry reply is NOT the whole result: "exactly one
    # so named" needs every artist the search matched, so the rows ask once for
    # the 100-entry reply (the rule as measured).
    cold();
    my @big = (@GEN, map { { id => id(200 + $_), name => "Filler $_", score => 10 } } 1 .. 20);
    $REPLY{ q_for('genesis') } = { count => scalar(@big), artists => \@big };
    $REPLY{ $MB_BASE . 'release-group?artist=' . id(3) } = { 'release-group-count' => 12 };
    $API->getArtistMbid(artist => 'genesis', fetch => $API->NAME_FETCH, onDone => sub {});
    flush();
    $out = undef;
    $API->filterRowsWithContent([ { name => 'Genesis Brass', sources => ['Qobuz'] } ],
        sub { $out = $_[0] }, { query => 'genesis' });
    flush();
    ok(scalar(grep { /artist%3A%22genesis%22&fmt=json&limit=100$/ } @QUERIES) == 1
       && ref $out eq 'ARRAY' && @$out == 1,
       '4: a typed query bigger than 15: the rows ask once for 100 and are answered');

    # A library row with a MusicBrainz tag is resolved by the tag, never searched.
    cold();
    %TAG = (77 => id(90));
    $REPLY{ q_for('genesis') } = $GEN;
    $out = undef;
    $API->filterRowsWithContent([ { name => 'Genesis', sources => ['Local'], artist_id => 77 } ],
        sub { $out = $_[0] }, { query => 'genesis' });
    flush();
    ok(ref $out eq 'ARRAY' && @$out == 1 && !@QUERIES,
       '4: a tagged library row is kept by its tag with no request');

    # An UNTAGGED library row whose page has had its own albums name its act
    # (resolver plan C2): that answer stands as a tag does - no request, and
    # never remembered under the name (a "Genesis" row from a service must open
    # what the name opens, not the user's act).
    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $CACHE{ Plugins::Discography::API::_libMbidKey(78, 'Genesis') } = id(91);
    $out = undef;
    $API->filterRowsWithContent([ { name => 'Genesis', sources => ['Local'], artist_id => 78 } ],
        sub { $out = $_[0] }, { query => 'genesis' });
    flush();
    ok(ref $out eq 'ARRAY' && @$out == 1 && !@QUERIES,
       "4: an untagged library row with its albums' answer kept is settled by it, no request");
    ok(!exists $CACHE{ Plugins::Discography::API::_rowKey('Genesis') }
       && !exists $CACHE{ Plugins::Discography::API::_mbidKey('Genesis') },
       '4: and nothing is remembered under the name');
    # Control: with no kept answer the same row is resolved by name, as before.
    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $out = undef;
    $API->filterRowsWithContent([ { name => 'Genesis', sources => ['Local'], artist_id => 78 } ],
        sub { $out = $_[0] }, { query => 'genesis' });
    flush();
    ok(ref $out eq 'ARRAY' && @$out == 1 && scalar(grep { index($_, 'artist?query=') >= 0 } @QUERIES) >= 1,
       '4: control - no kept answer: the untagged library row is resolved by name (it asks)');

    # The row named like the query is answered by the resolver's own cache.
    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $CACHE{ Plugins::Discography::API::_mbidKey('genesis') } = id(1);
    $REPLY{ $MB_BASE . 'release-group?artist=' . id(1) } = { 'release-group-count' => 40 };
    $out = undef;
    $API->filterRowsWithContent([ { name => 'Genesis', sources => ['Qobuz'] } ],
        sub { $out = $_[0] }, { query => 'Genesis' });
    flush();
    # One name search only: pass 1's (the typed query). The row's own lookup is
    # the resolver's, answered from dsc:mbid, so it sends none.
    ok(ref $out eq 'ARRAY' && @$out == 1
       && scalar(grep { index($_, 'artist?query=') >= 0 } @QUERIES) == 1,
       "4: the query's own row uses the resolver's cached answer for it");
});

# How many times this check asked for $mbid's count: the community API, and
# MusicBrainz behind it.
sub asks {
    my ($m) = @_;
    return (scalar(grep { m{^https://api\.lms-community\.org/} && /mbid=\Q$m\E$/ } @QUERIES),
            scalar(grep { /release-group\?artist=\Q$m\E&/ } @QUERIES));
}

section('5', sub {
    # -----------------------------------------------------------------------
    # 5. A COUNT IS ASKED ONCE PER SEARCH (stage 3 review, finding 4). A row is
    #    judged from the count already tried for it; a failed one keeps the row
    #    and is not asked again (while MusicBrainz is refusing, a second ask
    #    waited out its 5-30 s backoff). Only a SETTLED count counts as asked.
    # -----------------------------------------------------------------------

    # A batched row whose count fails everywhere (no reply for either).
    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    my %asked;
    my $out;
    $API->filterRowsWithContent([ { name => 'Genesis Brass', sources => ['Qobuz'] } ],
        sub { $out = $_[0] }, { query => 'genesis', asked => \%asked });
    flush();
    my ($c, $mb) = asks(id(3));
    ok($c == 1 && $mb == 1,
       "5: a batched row's failed count is asked once, not again by the row's judge ($c community, $mb MusicBrainz)");
    ok(ref $out eq 'ARRAY' && @$out == 1, '5: ... and the row is kept (a failed count is never a zero)');
    ok($asked{ id(3) }, "5: ... and the caller's set holds it, so the same-name section skips it too");

    # A resolver row whose winner is inexact ("Beatles" -> "The Beatles"): the
    # resolver's own zero-release check asks, fails, and the judge uses that.
    # The row named as typed, which still goes to the resolver (stage 3b sends
    # the others to the community API).
    cold();
    $REPLY{ q_for('Beatles') } = { count => 1, artists => [ { id => id(50), name => 'The Beatles', score => 100 } ] };
    $out = undef;
    $API->filterRowsWithContent([ { name => 'Beatles', sources => ['Qobuz'] } ],
        sub { $out = $_[0] }, { query => 'Beatles' });
    flush();
    ($c, $mb) = asks(id(50));
    ok($c == 1 && $mb == 1,
       "5: a resolver row's failed zero-release count is not asked again ($c community, $mb MusicBrainz)");
    ok(ref $out eq 'ARRAY' && @$out == 1, '5: ... and the row is kept');

    # CONTROL: a row nobody has counted yet IS asked (the judge still warms).
    cold();
    $REPLY{ q_for('Tommy Genesis') } = { count => 1, artists => [ { id => id(6), name => 'Tommy Genesis', score => 100 } ] };
    $out = undef;
    $API->filterRowsWithContent([ { name => 'Tommy Genesis', sources => ['Deezer'] } ],
        sub { $out = $_[0] }, { query => 'Tommy Genesis' });
    flush();
    ($c, $mb) = asks(id(6));
    ok($c == 1 && $mb == 1, '5: control: an exact winner nobody counted is asked for by the judge');

    # IN FLIGHT IS NOT ASKED. Two rows reach one act: "GENESIS BRASS!" by the
    # typed query's reply (its count goes out and waits), "Genesis Brass" (the
    # query's own row) by the resolver, answered at once from the kept reply.
    # The second row is judged while the first count is still out: it must ask
    # for itself, not read the unanswered count as a failure and keep a dead
    # end. The act has NO releases, so both rows must go.
    cold();
    $REPLY{ q_for('Genesis Brass') } = { count => 2, artists => [
        { id => id(3),  name => 'Genesis Brass',         score => 100 },
        { id => id(40), name => 'Genesis Brass Quintet', score => 90 } ] };
    $REPLY{ $MB_BASE . 'release-group?artist=' . id(3) } = { 'release-group-count' => 0 };
    $out = undef;
    $API->filterRowsWithContent([
        { name => 'GENESIS BRASS!', sources => ['Qobuz'] },
        { name => 'Genesis Brass',  sources => ['Deezer'] },
    ], sub { $out = $_[0] }, { query => 'Genesis Brass' });
    flush();
    ok(ref $out eq 'ARRAY' && @$out == 0,
       '5: a count still in flight is not read as failed: both rows of an act with no releases go');

    # The same for two JUDGES: both rows are the query's own (the resolver, the
    # second answered from the first's cached resolution), so the second row's
    # judge runs while the first judge's count is still out.
    cold();
    $REPLY{ q_for('Genesis Brass') } = { count => 2, artists => [
        { id => id(3),  name => 'Genesis Brass',         score => 100 },
        { id => id(40), name => 'Genesis Brass Quintet', score => 90 } ] };
    $REPLY{ $MB_BASE . 'release-group?artist=' . id(3) } = { 'release-group-count' => 0 };
    $out = undef;
    $API->filterRowsWithContent([
        { name => 'Genesis Brass', sources => ['Qobuz'] },
        { name => 'genesis brass', sources => ['Deezer'] },
    ], sub { $out = $_[0] }, { query => 'Genesis Brass' });
    flush();
    ok(ref $out eq 'ARRAY' && @$out == 0,
       "5: ... nor is another row's judge's count still out: both rows go");
});

# ---------------------------------------------------------------------------
# STAGE 3b (2026-09-30; analysis §A13): the rows the shared searches leave ask
# the COMMUNITY API by name instead of the MusicBrainz resolver; answers the
# shared searches PROVE are handed to the page; pass 1 also reads aliases.
# ---------------------------------------------------------------------------
no warnings 'once';
my $A = 'Plugins::Discography::API';
sub cm_url { 'https://api.lms-community.org/music/artist/' . Plugins::Discography::API::_hostedSeg($_[0]) . '/discography' }
sub cm_asked { my $u = cm_url($_[0]); scalar grep { $_ eq $u } @QUERIES }
sub mb_name_asked { my $u = q_for($_[0]); scalar grep { index($_, $u) == 0 } @QUERIES }
sub cm_answer { my ($id, $name, $n) = @_; { mbid => $id, name => $name, discography => [ (1) x $n ] } }
# Rows kept, by name, after a whole filter pass (the community API and
# MusicBrainz both stubbed by %REPLY).
sub kept {
    my ($q, @rows) = @_;
    my $out;
    $API->filterRowsWithContent([ @rows ], sub { $out = $_[0] }, { query => $q });
    flush();
    return $out;
}
sub names { join ',', map { $_->{name} } @{ $_[0] || [] } }

section('6', sub {
    # 6. A ROW NO SHARED SEARCH ANSWERS ASKS THE COMMUNITY API.
    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $REPLY{ cm_url('Genesis Scholz') } = { name => 'genesis scholz' };
    my $out = kept('genesis', { name => 'Genesis Scholz', sources => ['Qobuz'] });
    ok(ref $out eq 'ARRAY' && !@$out, '6: no artist of that name -> the row goes');
    ok(cm_asked('Genesis Scholz') == 1 && mb_name_asked('Genesis Scholz') == 0,
       '6: ... on ONE community request, with no MusicBrainz resolver for it');
    $out = kept('genesis', { name => 'Genesis Scholz', sources => ['Qobuz'] });
    ok(cm_asked('Genesis Scholz') == 1, '6: ... and a repeat search asks nothing (the answer is cached)');

    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $REPLY{ cm_url('Genesis Owusu') } = cm_answer(id(60), 'Genesis Owusu', 28);
    $out = kept('genesis', { name => 'Genesis Owusu', sources => ['Qobuz'] });
    my ($c, $mb) = asks(id(60));
    ok(names($out) eq 'Genesis Owusu', '6: its name is the row\'s and it lists releases -> kept');
    ok(($CACHE{ Plugins::Discography::API::_rgCountKey(id(60)) } // -1) == 28 && $c == 0 && $mb == 0,
       '6: ... its count is cached, and no count is asked again');
    ok(mb_name_asked('Genesis Owusu') == 0, '6: ... and MusicBrainz is not asked for the name');
    ok(!defined $CACHE{ Plugins::Discography::API::_mbidKey('Genesis Owusu') },
       '6: ... and its id is NOT handed to the page (a by-name pick, A3)');

    # No releases listed: its lists hold first credits only, and by name it may
    # have picked another act of the name. Today's resolver decides.
    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $REPLY{ cm_url('Genesis Tajiri') } = cm_answer(id(61), 'Genesis Tajiri', 0);
    $REPLY{ q_for('Genesis Tajiri') } = { count => 1, artists => [ { id => id(62), name => 'Genesis Tajiri', score => 100 } ] };
    $REPLY{ $MB_BASE . 'release-group?artist=' . id(62) } = { 'release-group-count' => 15 };
    $out = kept('genesis', { name => 'Genesis Tajiri', sources => ['Qobuz'] });
    ok(names($out) eq 'Genesis Tajiri' && mb_name_asked('Genesis Tajiri') >= 1,
       '6: its name is the row\'s but it lists NO releases -> the resolver decides (kept here, 15 groups)');

    # Another name: kept only to merge into a row of the same artist, by alias.
    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $REPLY{ cm_url('Genesis Brass') . '?mbid=' . id(3) } = cm_answer(id(3), 'Genesis Brass', 12);
    $REPLY{ cm_url('Genesis Brass Band') } = cm_answer(id(3), 'Genesis Brass', 12);
    $CACHE{ Plugins::Discography::API::_aliasKey(id(3)) } = [ 'Genesis Brass Band' ];
    $CACHE{ Plugins::Discography::API::_mbNameKey(id(3)) } = 'Genesis Brass';
    $out = kept('genesis', { name => 'Genesis Brass', sources => ['Qobuz'] },
                           { name => 'Genesis Brass Band', sources => ['Deezer'] });
    ok(names($out) eq 'Genesis Brass' && join(',', @{ $out->[0]{sources} || [] }) eq 'Qobuz,Deezer',
       '6: another name, a row of that artist, an MB alias -> MERGED into it (both services)');

    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $REPLY{ cm_url('Genesis Brass') . '?mbid=' . id(3) } = cm_answer(id(3), 'Genesis Brass', 12);
    $REPLY{ cm_url('Genesis Brass Band') } = cm_answer(id(3), 'Genesis Brass', 12);
    $CACHE{ Plugins::Discography::API::_aliasKey(id(3)) } = [ 'Something Else' ];
    $CACHE{ Plugins::Discography::API::_mbNameKey(id(3)) } = 'Genesis Brass';
    $out = kept('genesis', { name => 'Genesis Brass', sources => ['Qobuz'] },
                           { name => 'Genesis Brass Band', sources => ['Deezer'] });
    ok(names($out) eq 'Genesis Brass',
       '6: another name, same artist, but NOT an MB alias -> not merged, and the row goes');

    # The survivor's name being an alias is not enough for a merge-only row:
    # ITS OWN name must be one MusicBrainz records for the artist.
    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $REPLY{ cm_url('Genesis Brass') . '?mbid=' . id(3) } = cm_answer(id(3), 'Genesis Brass', 12);
    $REPLY{ cm_url('The 3 Brasses') } = cm_answer(id(3), 'Genesis Brass', 12);
    $CACHE{ Plugins::Discography::API::_aliasKey(id(3)) } = [ 'Genesis Brass' ];
    $CACHE{ Plugins::Discography::API::_mbNameKey(id(3)) } = 'The Genesis Brass';
    $out = kept('genesis', { name => 'Genesis Brass', sources => ['Qobuz'] },
                           { name => 'The 3 Brasses', sources => ['Deezer'] });
    ok(names($out) eq 'Genesis Brass' && join(',', @{ $out->[0]{sources} || [] }) eq 'Qobuz',
       "6: a merge-only row whose OWN name MusicBrainz does not record is not merged, even when the survivor's is");

    # The merge-only row arrives FIRST: it is never the survivor.
    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $REPLY{ cm_url('Genesis Brass') . '?mbid=' . id(3) } = cm_answer(id(3), 'Genesis Brass', 12);
    $REPLY{ cm_url('Genesis Brass Band') } = cm_answer(id(3), 'Genesis Brass', 12);
    $CACHE{ Plugins::Discography::API::_aliasKey(id(3)) } = [ 'Genesis Brass Band' ];
    $CACHE{ Plugins::Discography::API::_mbNameKey(id(3)) } = 'Genesis Brass';
    $out = kept('genesis', { name => 'Genesis Brass Band', sources => ['Deezer'] },
                           { name => 'Genesis Brass', sources => ['Qobuz'] });
    ok(names($out) eq 'Genesis Brass',
       '6: ... listed first, the merge-only row still merges INTO the row, never the other way');

    # Two merge-only rows of one artist and no row of it: nothing to merge into,
    # so both go, and no alias list is fetched for them.
    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $REPLY{ cm_url('Genesis Brass Band') } = cm_answer(id(64), 'Genesis Brass Ensemble', 12);
    $REPLY{ cm_url('Genesis Brass Orchestra') } = cm_answer(id(64), 'Genesis Brass Ensemble', 12);
    $out = kept('genesis', { name => 'Genesis Brass Band', sources => ['Deezer'] },
                           { name => 'Genesis Brass Orchestra', sources => ['Qobuz'] });
    ok(ref $out eq 'ARRAY' && !@$out && !grep({ m{/artist/\Q${\ id(64)}\E} } @QUERIES),
       '6: merge-only rows with no row of their artist all go, and no alias list is fetched for them');

    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $REPLY{ cm_url('Beats of Genesis') } = cm_answer(id(63), 'Cluster', 2);
    $out = kept('genesis', { name => 'Beats of Genesis', sources => ['Qobuz'] });
    ok(ref $out eq 'ARRAY' && !@$out && mb_name_asked('Beats of Genesis') == 0,
       '6: another name and no row of that artist ("Bush Lily" -> "Cluster") -> the row goes, no MusicBrainz');

    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $REPLY{ cm_url('Genesis Scholz') } = 'ERROR';
    $out = kept('genesis', { name => 'Genesis Scholz', sources => ['Qobuz'] });
    ok(names($out) eq 'Genesis Scholz' && mb_name_asked('Genesis Scholz') == 0,
       '6: NO answer (refused, timed out) -> kept, unchecked: a failed request never hides a row');

    # The row named as typed and a library row keep the resolver.
    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $out = kept('genesis', { name => 'Genesis', sources => ['Qobuz'] },
                           { name => 'Genesis Scholz', sources => ['Local'], artist_id => 5 });
    ok(cm_asked('Genesis') == 0 && cm_asked('Genesis Scholz') == 0,
       '6: the row named as typed and a library row never ask the community API');
    ok(names($out) =~ /Genesis Scholz/ ? 1 : 0, '6: ... and the library row is kept, as ever');
});

section('7', sub {
    # 7. WHAT IS HANDED TO THE PAGE: only an answer the reply PROVES.
    cold();
    $REPLY{ $MB_BASE . 'artist?query=artist%3A%22Au%20Pair' } = { count => 3, artists => [
        { id => id(20), name => 'Au Pair',     score => 100, disambiguation => 'Welsh band' },
        { id => id(21), name => 'Hall Of Fam', score => 100 },
        { id => id(22), name => 'Au Pairs',    score => 80 } ] };
    my $p = batch('', 'Au Pair', 'Hall Of Fam');
    kept('', { name => 'Au Pair', sources => ['Qobuz'] }, { name => 'Hall Of Fam', sources => ['Qobuz'] });
    my $set = $CACHE{ Plugins::Discography::API::_candKey('Au Pair') };
    ok(($CACHE{ Plugins::Discography::API::_mbidKey('Au Pair') } // '') eq id(20)
       && ref $set eq 'ARRAY' && @$set == 1 && $set->[0]{mbid} eq id(20)
       && ($set->[0]{disambiguation} // '') eq 'Welsh band',
       '7: a COMPLETE combined reply proves its answers: the resolution and a one-artist same-name set');
    my $before = scalar @QUERIES;
    my ($m, $cands);
    $A->getArtistMbid(artist => 'Au Pair', onDone => sub { $m = $_[0] });
    $A->getArtistCandidates('Au Pair', sub { $cands = $_[0] });
    flush();
    ok(($m // '') eq id(20) && ref $cands eq 'ARRAY' && @$cands == 1 && @QUERIES == $before,
       '7: ... so the page resolves the name and its same-name set with NO request');

    cold();
    $REPLY{ q_for('genesis') } = { count => 140, artists => [ @GEN ] };
    kept('genesis', { name => 'Genesis Brass', sources => ['Qobuz'] });
    ok(!defined $CACHE{ Plugins::Discography::API::_mbidKey('Genesis Brass') },
       '7: a typed reply that is NOT whole (140 matched) proves nothing');

    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $REPLY{ cm_url('Anthrax') . '?mbid=' . id(7) } = cm_answer(id(7), 'Anthrax', 30);
    kept('genesis', { name => 'Anthrax', sources => ['Qobuz'] });
    ok(!defined $CACHE{ Plugins::Discography::API::_mbidKey('Anthrax') },
       '7: a row whose name lacks the typed words proves nothing (its namesakes need not be in the reply)');

    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    kept('genesis', { name => 'Genesis Brass (UK)', sources => ['Qobuz'] });
    ok(!defined $CACHE{ Plugins::Discography::API::_mbidKey('Genesis Brass (UK)') },
       '7: a name with an annotation is left to the page');

    cold();
    $REPLY{ q_for('genesis') } = $GEN;
    $CACHE{ Plugins::Discography::API::_mbidKey('Genesis Brass') } = id(99);
    $CACHE{ Plugins::Discography::API::_mbidKey('Tommy Genesis') } = '';
    kept('genesis', { name => 'Genesis Brass', sources => ['Qobuz'] }, { name => 'Tommy Genesis', sources => ['Qobuz'] });
    ok($CACHE{ Plugins::Discography::API::_mbidKey('Genesis Brass') } eq id(99)
       && $CACHE{ Plugins::Discography::API::_mbidKey('Tommy Genesis') } eq id(6),
       '7: an entry already there is left alone; a cached MISS gives way to the proof');
});

section('8', sub {
    # 8. PASS 1 READS ALIASES: the ONE artist carrying the row's name as an
    #    alias, when none is named so (Genesis P-Orridge, Genesis Mohanraj).
    my @GA = map { { %$_ } } @GEN;
    $_->{aliases} = [ { name => 'Genesis Mohanraj' } ] for grep { $_->{id} eq id(6) } @GA;
    $_->{aliases} = [ { name => 'Gen Twice' }, { name => 'Genesis Brass' } ] for grep { $_->{id} eq id(3) } @GA;
    $_->{aliases} = [ { name => 'Gen Twice' } ] for grep { $_->{id} eq id(5) } @GA;
    my $GA = { count => scalar(@GA), artists => \@GA };
    cold();
    $REPLY{ q_for('genesis') } = $GA;
    my $p = batch('genesis', 'Genesis Mohanraj', 'Gen Twice', 'Genesis Brass');
    ok(($p->{0} // '') eq id(6), '8: an alias held by ONE artist answers the row');
    ok(!defined $p->{1}, '8: an alias held by TWO artists answers nothing');
    ok(($p->{2} // '') eq id(3), '8: an artist NAMED like the row beats an alias');
    # Two artists NAMED like the row (the resolver's call which) and a third
    # carrying it as an alias: the alias must not settle what the names cannot.
    my @GB = ( { id => id(70), name => 'Twin', score => 100 }, { id => id(71), name => 'Twin', score => 99 },
               { id => id(72), name => 'Other', score => 90, aliases => [ { name => 'Twin' } ] } );
    cold();
    $REPLY{ q_for('twins') } = { count => 3, artists => \@GB };
    $p = batch('twins', 'Twin');
    ok(!defined $p->{0}, '8: two artists NAMED like the row: no alias answers it either');
    cold();
    $REPLY{ q_for('genesis') } = $GA;
    $REPLY{ cm_url('Genesis Mohanraj') . '?mbid=' . id(6) } = cm_answer(id(6), 'Tommy Genesis', 42);
    kept('genesis', { name => 'Genesis Mohanraj', sources => ['Qobuz'] });
    ok(!defined $CACHE{ Plugins::Discography::API::_mbidKey('Genesis Mohanraj') },
       '8: an alias answer is never handed to the page (its namesakes need not be in the reply)');
});

section('9', sub {
    # 9. PASS 1'S UNPROVEN ANSWERS RIDE IN PASS 2 (0.56.6, analysis §A14): a
    #    common query's reply is partial, so a row it answers by name cannot be
    #    proven there; the combined search, sent anyway for the rows left,
    #    carries its name too and proves it. It never changes a pick.
    my $A = 'Plugins::Discography::API';
    my $both = sub {
        my ($q, @names) = @_;
        my ($pk, $pr);
        $A->_rowBatch($q, [ map { [ $_, $names[$_] ] } 0 .. $#names ], sub { ($pk, $pr) = @_ });
        flush();
        return ($pk || {}, $pr || {});
    };
    my $partial = { count => 140, artists => [ @GEN ] };    # "genesis": 140 matched
    my $cq = $MB_BASE . 'artist?query=artist%3A%22Au%20Pair';
    my @AU = ( { id => id(20), name => 'Au Pair', score => 100 },
               { id => id(21), name => 'Hall Of Fam', score => 100 } );
    my $ride = qr/artist%3A%22Au%20Pair%22%20OR%20artist%3A%22Hall%20Of%20Fam%22%20OR%20artist%3A%22Genesis%20Brass%22%20OR%20artist%3A%22Tommy%20Genesis%22&fmt=json&limit=100$/;
    my ($comb) = sub { (grep { /%20OR%20/ } @QUERIES)[0] // '' };

    cold();
    $REPLY{ q_for('genesis') } = $partial;
    $REPLY{$cq} = { count => 5, artists => [ @AU,
        { id => id(3), name => 'Genesis Brass', score => 100 },
        { id => id(6), name => 'Tommy Genesis', score => 100 },
        { id => id(40), name => 'Genesis Brass Band', score => 60 } ] };
    my ($pk, $pr) = $both->('genesis', 'Genesis Brass', 'Tommy Genesis', 'Au Pair', 'Hall Of Fam');
    ok(scalar($comb->() =~ $ride), '9: the rows pass 1 answered unproven ride in the combined search, after the rows left');
    ok(combined_asked() == 1 && scalar(grep { index($_, 'artist?query=') >= 0 } @QUERIES) == 2,
       '9: ... in the one search sent anyway (no extra request)');
    ok(($pr->{0}{id} // '') eq id(3) && ($pr->{1}{id} // '') eq id(6),
       '9: a COMPLETE combined reply with one artist of the name, the pick, proves it');
    ok(($pr->{2}{id} // '') eq id(20) && ($pr->{3}{id} // '') eq id(21),
       '9: ... and the rows left are answered and proven as before');
    ok(($pk->{0} // '') eq id(3) && ($pk->{1} // '') eq id(6), '9: the picks are pass 1\'s');

    # Two artists of the name in the complete reply, or one that is not the
    # pick: the pick stands, unproven (which one the page opens is its call).
    cold();
    $REPLY{ q_for('genesis') } = $partial;
    $REPLY{$cq} = { count => 5, artists => [ @AU,
        { id => id(3),  name => 'Genesis Brass', score => 100 },
        { id => id(41), name => 'Genesis Brass', score => 90 },
        { id => id(66), name => 'Tommy Genesis', score => 100 } ] };
    ($pk, $pr) = $both->('genesis', 'Genesis Brass', 'Tommy Genesis', 'Au Pair', 'Hall Of Fam');
    ok(!$pr->{0} && ($pk->{0} // '') eq id(3), '9: two artists of the name: not proven, the pick unchanged');
    ok(!$pr->{1} && ($pk->{1} // '') eq id(6), '9: another artist of the name: not proven, the pick unchanged');

    # An incomplete combined reply proves nothing, and changes nothing.
    cold();
    $REPLY{ q_for('genesis') } = $partial;
    $REPLY{$cq} = { count => 300, artists => [ @AU,
        { id => id(3), name => 'Genesis Brass', score => 100 },
        { id => id(6), name => 'Tommy Genesis', score => 100 } ] };
    ($pk, $pr) = $both->('genesis', 'Genesis Brass', 'Tommy Genesis', 'Au Pair', 'Hall Of Fam');
    ok(!%$pr && ($pk->{0} // '') eq id(3) && ($pk->{1} // '') eq id(6),
       '9: an INCOMPLETE combined reply proves nothing; the picks stand');

    # Fewer than two rows left: no combined search is sent, and nothing makes
    # one be sent for the ridden rows alone.
    cold();
    $REPLY{ q_for('genesis') } = $partial;
    ($pk, $pr) = $both->('genesis', 'Genesis Brass', 'Tommy Genesis', 'Au Pair');
    ok(combined_asked() == 0 && scalar(grep { index($_, 'artist?query=') >= 0 } @QUERIES) == 1,
       '9: ONE row left: no combined search, the ridden rows send none of their own');
    ok(!%$pr && ($pk->{0} // '') eq id(3), '9: ... and they stay answered, unproven');

    # What never rides: an alias pick, a name with an annotation, a row the
    # typed reply already covered (whole, and the name holds the typed words).
    my @GA = map { { %$_ } } @GEN;
    $_->{aliases} = [ { name => 'Genesis Mohanraj' } ] for grep { $_->{id} eq id(6) } @GA;
    cold();
    $REPLY{ q_for('genesis') } = { count => 140, artists => \@GA };
    $REPLY{$cq} = { count => 2, artists => [ @AU ] };
    ($pk, $pr) = $both->('genesis', 'Genesis Mohanraj', 'Genesis Brass (UK)', 'Au Pair', 'Hall Of Fam');
    ok(($pk->{0} // '') eq id(6) && ($pk->{1} // '') eq id(3), '9: (the alias and the annotated name are answered by pass 1)');
    ok(scalar($comb->() =~ /artist%3A%22Au%20Pair%22%20OR%20artist%3A%22Hall%20Of%20Fam%22&fmt=json/),
       '9: an alias pick and an annotated name do not ride');

    cold();
    $REPLY{ q_for('genesis') } = $GEN;                         # whole
    $REPLY{$cq} = { count => 3, artists => [ @AU, { id => id(7), name => 'Anthrax', score => 100 } ] };
    ($pk, $pr) = $both->('genesis', 'Genesis Brass', 'Anthrax', 'Au Pair', 'Hall Of Fam');
    ok(scalar($comb->() =~ /artist%3A%22Hall%20Of%20Fam%22%20OR%20artist%3A%22Anthrax%22&fmt=json/),
       '9: a whole typed reply: a row it covered does not ride, one whose name lacks the typed words does');
    ok(($pr->{0}{id} // '') eq id(3) && ($pr->{1}{id} // '') eq id(7),
       '9: ... the covered row proven by pass 1, the other by pass 2');

    # End to end: a ridden row's proof is handed to the page.
    cold();
    $REPLY{ q_for('genesis') } = $partial;
    $REPLY{$cq} = { count => 3, artists => [ @AU, { id => id(3), name => 'Genesis Brass', score => 100 } ] };
    kept('genesis', map { { name => $_, sources => ['Qobuz'] } } 'Genesis Brass', 'Au Pair', 'Hall Of Fam');
    ok(($CACHE{ Plugins::Discography::API::_mbidKey('Genesis Brass') } // '') eq id(3),
       '9: a ridden row\'s proof is cached as the name\'s resolution for the page');
});

section('10', sub {
    # -----------------------------------------------------------------------
    # 10. THE SEARCH DOES NOT WAIT FOR THE CHECK (0.56.9; Simon: the search
    #     "should be the quickest part ... just hide them on 2nd search").
    #     `known`: every row decided from what earlier checks left, the rest
    #     shown unchecked; the reply goes out before any request; the full check
    #     then runs as background work and keeps its answers per result name, so
    #     the next search hides the junk and merges the credit variant.
    # -----------------------------------------------------------------------
    cold();
    my $TP = id(20);
    $REPLY{ q_for('tom petty') } = { count => 1, artists => [ { id => $TP, name => 'Tom Petty', score => 100 } ] };
    $CACHE{ Plugins::Discography::API::_mbidKey('Tom Petty') } = $TP;   # the typed query's own lookup
    $CACHE{ Plugins::Discography::API::_rgCountKey($TP) } = 50;
    $REPLY{ cm_url('Jeff Lynne;Tom Petty') } = { name => '' };
    $REPLY{ cm_url('Cypress Hill Tom Petty Led Zeppelin') } = {};
    $REPLY{ cm_url('Tom Petty & Jeff Lynne') } = cm_answer($TP, 'Tom Petty', 50);
    $REPLY{ $MB_BASE . "artist/$TP?inc=aliases" } =
        { name => 'Tom Petty', aliases => [], relations => [], 'release-groups' => [] };
    $TAG{9} = id(21);
    my @rows = ({ name => 'Tom Petty', sources => ['Qobuz'] },
                { name => 'Jeff Lynne;Tom Petty', sources => ['Qobuz'] },
                { name => 'Tom Petty & Jeff Lynne', sources => ['Deezer'] },
                { name => 'Cypress Hill Tom Petty Led Zeppelin', sources => ['Qobuz'] },
                { name => 'Tom Petty and the Heartbreakers', sources => ['Local'], artist_id => 9 });
    my $copy = sub { [ map { +{ %$_, sources => [ @{ $_->{sources} } ] } } @rows ] };
    my ($out, $sentAtReply);
    my $search = sub {
        ($out, $sentAtReply) = (undef, undef);
        $API->filterRowsWithContent($copy->(), sub { $out = $_[0]; $sentAtReply = scalar @QUERIES },
                                    { query => 'tom petty', known => 1 });
    };

    $search->();
    ok(scalar(defined $out && $sentAtReply == 0), '10: the list is answered at once, before any request');
    ok(names($out) eq join(',', map { $_->{name} } @rows),
       '10: ... every row nothing is known about shown, unchecked');
    ok(scalar(@QUERIES && !grep { !$_ } @BGQ), '10: then the check is asked, as background work');

    my $n = scalar @QUERIES;
    $search->();
    ok(scalar(@QUERIES == $n), '10: a repeat search while that check runs does not start another');

    flush();
    ok(scalar(combined_asked() == 1 && cm_asked('Jeff Lynne;Tom Petty') == 1),
       '10: ... once its answers came: one combined search, one community request per name');
    ok(scalar(!grep { !$_ } @BGQ), '10: every request the check\'s answers led to is background work too');
    my $rv = sub { $CACHE{ Plugins::Discography::API::_rowKey($_[0]) } };
    ok(scalar(ref $rv->('Jeff Lynne;Tom Petty') eq 'HASH' && $rv->('Jeff Lynne;Tom Petty')->{m} eq ''),
       '10: the community\'s "no artist" is kept for the name');
    ok(scalar(ref $rv->('Tom Petty & Jeff Lynne') eq 'HASH' && $rv->('Tom Petty & Jeff Lynne')->{m} eq $TP
              && $rv->('Tom Petty & Jeff Lynne')->{o}),
       '10: a pick under another name is kept as merge-only');
    ok(scalar(!defined $rv->('Tom Petty and the Heartbreakers')),
       '10: a library row its tag decides is not kept (the tag answers every time)');

    @QUERIES = (); @BGQ = ();
    $search->();
    ok(names($out) eq 'Tom Petty,Tom Petty and the Heartbreakers',
       '10: the next search hides the junk and merges the credit variant');
    my ($tp) = grep { $_->{name} eq 'Tom Petty' } @{ $out || [] };
    ok(scalar($tp && join(',', @{ $tp->{sources} }) eq 'Qobuz,Deezer'),
       '10: ... the merged row carrying both services');
    ok(scalar(!@QUERIES), '10: ... and asks nothing, everything being known');

    # A count not known yet: the row is kept, and its count asked after.
    delete $CACHE{ Plugins::Discography::API::_rgCountKey($TP) };
    @QUERIES = (); @BGQ = ();
    $search->();
    ok(scalar(grep { $_->{name} eq 'Tom Petty' } @{ $out || [] }), '10: a row whose count is not known is kept');
    ok(scalar(@QUERIES && !grep { !$_ } @BGQ), '10: ... and its count is asked after, as background work');
    flush();

    # The branches the known mode decides on, each from the cache alone.
    cold();
    my $sentBefore;
    my $known = sub {
        my ($r) = (undef);
        $API->filterRowsWithContent([ map { +{ %$_, sources => [ @{ $_->{sources} } ] } } @_ ],
                                    sub { $r = $_[0]; $sentBefore = scalar @QUERIES },
                                    { query => 'tom petty', known => 1 });
        return $r;
    };
    my $rk = sub { Plugins::Discography::API::_rowKey($_[0]) };
    $CACHE{ Plugins::Discography::API::_mbidKey('Tom Petty') } = $TP;
    $CACHE{ Plugins::Discography::API::_rgCountKey($TP) } = 50;
    # A merge-only row whose artist's aliases are not cached: it cannot fold yet,
    # so it is shown as an ordinary row and the aliases are asked after.
    $CACHE{ $rk->('Tom Petty & Jeff Lynne') } = { m => $TP, o => 1 };
    $out = $known->({ name => 'Tom Petty', sources => ['Qobuz'] },
                    { name => 'Tom Petty & Jeff Lynne', sources => ['Deezer'] });
    ok(names($out) eq 'Tom Petty,Tom Petty & Jeff Lynne',
       '10: a merge-only row whose aliases are not cached is shown, not dropped');
    ok(scalar(grep { m{artist/$TP\?inc=aliases} } @QUERIES),
       '10: ... and the aliases are asked after, for the next search');
    flush();
    # Count 0, a proven-empty page, the resolver's "not found": each drops.
    cold();
    my ($Z, $E) = (id(30), id(31));
    $CACHE{ $rk->('Zero Act') } = { m => $Z, o => 0 };
    $CACHE{ Plugins::Discography::API::_rgCountKey($Z) } = 0;
    $CACHE{ $rk->('Empty Act') } = { m => $E, o => 0 };
    $CACHE{ Plugins::Discography::API::_rgCountKey($E) } = 4;
    $CACHE{ Plugins::Discography::API::_emptyKey($E) } = 1;
    $CACHE{ Plugins::Discography::API::_mbidKey('Unknown Act') } = '';
    # Kept 7 days for the name, after the community's own 1-day answer is gone.
    $CACHE{ $rk->('Junk Credit') } = { m => '', o => 0 };
    $out = $known->({ name => 'Zero Act', sources => ['Qobuz'] }, { name => 'Empty Act', sources => ['Qobuz'] },
                    { name => 'Unknown Act', sources => ['Qobuz'] }, { name => 'Junk Credit', sources => ['Qobuz'] },
                    { name => 'New Act', sources => ['Qobuz'] });
    ok(names($out) eq 'New Act',
       '10: a known count of 0, a proven-empty page, the resolver\'s "not found" and a kept "no artist" each drop; the unknown row stays');
    ok(scalar(defined $sentBefore && $sentBefore == 0), '10: ... all decided before any request is sent');
    flush();

    # CONTROL: without `known` the check still waits for its answers (the
    # background run itself, and any other caller).
    cold();
    $REPLY{ q_for('tom petty') } = { count => 1, artists => [ { id => $TP, name => 'Tom Petty', score => 100 } ] };
    $REPLY{ cm_url('Jeff Lynne;Tom Petty') } = { name => '' };
    $out = undef;
    $API->filterRowsWithContent([ { name => 'Jeff Lynne;Tom Petty', sources => ['Qobuz'] } ],
                                sub { $out = $_[0] }, { query => 'tom petty' });
    ok(scalar(!defined $out), '10: control: without known the check waits for its answers');
    flush();
    ok(scalar(ref $out eq 'ARRAY' && !@$out), '10: control: ... and drops the junk when they come');
});

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
