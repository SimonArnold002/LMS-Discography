#!/usr/bin/env perl
#
# ONE NAME SEARCH, SHARED (stage 3 step 1; analysis §A10, §A12.6, §A12.8).
#
# The resolver's first pass (_artistMbidByName, limit 8) and the same-name set
# (getArtistCandidates, limit 15) ask MusicBrainz the SAME quoted query. A cold
# page opened by name sent both, 1.1 s apart on the public API (found live, the
# 0.56.1 check). API::_nameSearch lets one reply serve both: the resolver reads
# the first 8 entries, the set the first 15 — exactly the entries its own
# request returned, because MusicBrainz ranks the same way whatever the page
# size (the order test over the 1,117 library artists, §A12.8).
#
# What this pins, against the REAL resolver and the REAL same-name set:
#   1. a page or a search: one request at limit 15 answers both, and each reads
#      ONLY its own entries (an exact-name act at position 10 must not move the
#      resolver);
#   2. the set is EXACT: after a reply at 100 it asks for its own 15 (measured:
#      the first 15 of a reply at 100 is not always the same set);
#   3. a caller arriving while the query is in flight waits for that reply;
#   4. an exact caller never waits on a request at another limit;
#   5. a whole result at 15 serves a caller wanting 100 (the row batch), not the
#      exact set; an incomplete one makes that caller fetch 100;
#   6. the kept reply expires after NAME_MEMO_TTL;
#   7. a parse error or an HTTP error is never kept, and every waiter hears;
#   8. the resolver's in-place edit (dropping special entities) does not reach
#      the kept reply;
#   9. Refresh (clearArtistCache) forgets the kept reply;
#  10. an annotated name is NOT shared (the two queries differ);
#  11. the mirror's zero-result public retry shares too, on the public key.
#
# Standalone -- no LMS install needed:  perl tools/t_namesearch.pl
#
use strict;
use warnings;
use FindBin;
use JSON::XS ();

my %CACHE;
my @QUERIES;              # every URL sent, in order
our @DEFERRED;            # responses held open, so "in flight" is real
our $MB_BASE = 'https://musicbrainz.org/ws/2/';
our %REPLY;               # url-prefix => reply hash, or 'ERROR' / 'GARBAGE'

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
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs JSON::XS::VersionOneAndTwo)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
    @{'JSON::XS::VersionOneAndTwo::EXPORT'} = qw(to_json from_json);
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Cache;
sub get { return $CACHE{ $_[1] } }
sub set { $CACHE{ $_[1] } = $_[2]; return 1 }
sub remove { delete $CACHE{ $_[1] }; return 1 }
package T::Prefs;
sub get { return $_[1] eq 'mb_base_url' ? $main::MB_BASE : undef }
sub set { 1 } sub init { 1 } sub setChange { 1 }
package T::Resp;
sub new     { my ($c, $body) = @_; bless { body => $body }, $c }
sub content { $_[0]{body} }
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

# The queue is not this suite's subject (t_netqueue.pl owns it): every request
# is held here and answered when flush() runs, from %REPLY by URL prefix.
{
    no strict 'refs'; no warnings 'redefine';
    *{'Plugins::Discography::API::_netGet'} = sub {
        my ($url, $ok, $err, %opt) = @_;
        push @QUERIES, $url;
        push @DEFERRED, sub {
            my ($hit) = grep { index($url, $_) == 0 } sort { length $b <=> length $a } keys %REPLY;
            my $r = defined $hit ? $REPLY{$hit} : 'ERROR';
            return $err->(T::Resp->new(''), 'stub error', T::Resp->new('')) if $r eq 'ERROR';
            return $ok->(T::Resp->new('{"not json')) if $r eq 'GARBAGE';
            # MB answers a limit: return only that many entries.
            my %copy = %$r;
            if (ref $r->{artists} eq 'ARRAY') {
                my ($lim) = $url =~ /[?&]limit=(\d+)/;
                my $n = @{ $r->{artists} };
                $n = $lim if $lim && $lim < $n;
                $copy{artists} = [ @{ $r->{artists} }[0 .. $n - 1] ];
            }
            $ok->(T::Resp->new(JSON::XS::encode_json(\%copy)));
        };
    };
}

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}
# A callback that DIES is reported as a failure, not allowed to end the run: a
# suite that stops half-way hides every assertion after the one that broke.
sub flush {
    for (1 .. 20) {
        my @d = @DEFERRED;
        last unless @d;
        @DEFERRED = ();
        for my $cb (@d) {
            eval { $cb->(); 1 } or do {
                (my $e = $@) =~ s/\s+/ /g;
                ok(0, "a response callback died: $e");
            };
        }
    }
}
# Each numbered section runs inside section(): a section that DIES is reported
# as a failure and the next one still runs.
sub section {
    my ($n, $code) = @_;
    eval { $code->(); 1 } or do {
        (my $e = $@) =~ s/\s+/ /g;
        ok(0, "$n: the section died: $e");
    };
}
sub cold {
    %CACHE = (); @QUERIES = (); @DEFERRED = (); %REPLY = ();
    %Plugins::Discography::API::NAME_MEMO = ();
    %Plugins::Discography::API::NAME_WAIT = ();
}
sub id { sprintf('%08d-0000-0000-0000-000000000000', $_[0]) }
sub q_for {   # the URL prefix of a quoted artist-field search (no limit)
    my ($name, $base) = @_;
    return ($base // $MB_BASE) . Plugins::Discography::API::_nameQuery('artist', $name, 0);
}
# The name searches only: not the initials lift's combined `artist:"X" OR alias:"X"`
# (0.56.36), which a short name like "La's" ("las") asks once after its answer.
sub nsearch { scalar grep { index($_, 'artist?query=artist%3A%22') >= 0 && index($_, '%20OR%20alias%3A') < 0 } @QUERIES }

# A "Genesis" reply of 30 entries. Positions 1-8 hold NO act named exactly
# Genesis; the top hit is "The Genesis" (score 100, one extra token, so the
# resolver accepts it and counts its releases). Position 10 is an exact
# "Genesis" at 95: a resolver that read past its 8 would pick it instead.
my @GEN = (
    { id => id(1), name => 'The Genesis', score => 100 },
    (map { { id => id($_), name => "Genesis Act $_", score => 99 - $_ } } 2 .. 9),
    { id => id(10), name => 'Genesis', score => 95 },
    (map { { id => id($_), name => "Genesis Act $_", score => 80 - $_ } } 11 .. 14),
    { id => id(15), name => 'Genesis', score => 60 },
    (map { { id => id($_), name => "Genesis Act $_", score => 50 } } 16 .. 29),
    { id => id(30), name => 'Genesis', score => 40 },
);
my $GEN = { count => 30, artists => \@GEN };
my $COUNT = { 'release-group-count' => 7 };   # the top hit has releases
my ($mbid, $cands);   # the two answers, reused by every section
sub kept { map { values %$_ } values %Plugins::Discography::API::NAME_MEMO }
my $FETCH = $API->NAME_FETCH;
my $ROWS  = $API->NAME_FETCH_ROWS;

# ---------------------------------------------------------------------------
# 1. A PAGE OR A SEARCH: one request at NAME_FETCH (15) answers the resolver
#    AND the set, and each reads ONLY its own entries.
# ---------------------------------------------------------------------------
section('1', sub {
cold();
$REPLY{ q_for('Genesis') } = $GEN;
$REPLY{ $MB_BASE . 'release-group?artist=' } = $COUNT;
($mbid, $cands) = ();
$API->getArtistMbid(artist => 'Genesis', fetch => $FETCH, onDone => sub { $mbid = $_[0] });
flush();
$API->getArtistCandidates('Genesis', sub { $cands = $_[0] });
flush();
ok(nsearch() == 1, '1: one name search for the resolver and the set');
ok(scalar(grep { /limit=15$/ } @QUERIES) == 1, '1: ... at limit 15');
ok(($mbid // '') eq id(1),
   '1: the resolver reads ONLY its first 8 (the exact "Genesis" at 10 does not move it)');
ok(ref $cands eq 'ARRAY' && join(',', map { $_->{mbid} } @$cands) eq id(10) . ',' . id(15),
   '1: the set reads ONLY its first 15 (positions 10 and 15, not 30)');
});

# ---------------------------------------------------------------------------
# 2. THE SET IS EXACT: it never reads a reply fetched at another limit. Measured
#    (§A12.8): the first 15 of a reply at 100 is not always what a reply at 15
#    gives. So after a fetch at 100 the set asks for its own 15.
# ---------------------------------------------------------------------------
section('2', sub {
cold();
$REPLY{ q_for('Genesis') } = $GEN;
$REPLY{ $MB_BASE . 'release-group?artist=' } = $COUNT;
($mbid, $cands) = ();
$API->getArtistMbid(artist => 'Genesis', fetch => $ROWS, onDone => sub { $mbid = $_[0] });
flush();
$API->getArtistCandidates('Genesis', sub { $cands = $_[0] });
flush();
ok(nsearch() == 2 && scalar(grep { /limit=100$/ } @QUERIES) == 1
   && scalar(grep { /limit=15$/ } @QUERIES) == 1,
   '2: after a reply at 100 the set sends its own request at 15');
ok(($mbid // '') eq id(1), '2: the resolver reads its first 8 of the 100 (identical, measured)');
ok(ref $cands eq 'ARRAY' && @$cands == 2, "2: ... and the set is read from its own reply");
});

# ---------------------------------------------------------------------------
# 3. IN FLIGHT: a second caller waits for the reply instead of sending.
# ---------------------------------------------------------------------------
section('3', sub {
cold();
$REPLY{ q_for('Genesis') } = $GEN;
$REPLY{ $MB_BASE . 'release-group?artist=' } = $COUNT;
($mbid, $cands) = ();
$API->getArtistMbid(artist => 'Genesis', fetch => $FETCH, onDone => sub { $mbid = $_[0] });
$API->getArtistCandidates('Genesis', sub { $cands = $_[0] });
ok(nsearch() == 1, '3: a caller arriving mid-flight sends nothing');
flush();
ok(($mbid // '') eq id(1) && ref $cands eq 'ARRAY' && @$cands == 2,
   '3: both are answered from the one reply');
ok(!%Plugins::Discography::API::NAME_WAIT, '3: no in-flight marker is left behind');
});

# ---------------------------------------------------------------------------
# 4. AN EXACT CALLER DOES NOT WAIT ON ANOTHER LIMIT: a row lookup fetches 8 by
#    default; the set arriving mid-flight sends its own 15 at once.
# ---------------------------------------------------------------------------
section('4', sub {
cold();
$REPLY{ q_for('Genesis') } = $GEN;
$REPLY{ $MB_BASE . 'release-group?artist=' } = $COUNT;
($mbid, $cands) = ();
$API->getArtistMbid(artist => 'Genesis', onDone => sub { $mbid = $_[0] });   # fetch 8
$API->getArtistCandidates('Genesis', sub { $cands = $_[0] });
ok(scalar(nsearch() == 2 && $QUERIES[0] =~ /limit=8$/ && $QUERIES[1] =~ /limit=15$/),
   '4: the set does not wait on the 8: its own request at 15 goes at once');
flush();
ok(ref $cands eq 'ARRAY' && @$cands == 2 && ($mbid // '') eq id(1), '4: ... and both answers are right');
});

# ---------------------------------------------------------------------------
# 5. A WHOLE RESULT serves a wider caller that reads only who is in it (the
#    row batch, want 100) — but not the exact set at another limit.
# ---------------------------------------------------------------------------
section('5', sub {
cold();
$REPLY{ q_for('Radiohead') } = { count => 1, artists => [
    { id => id(40), name => 'Radiohead', score => 100 } ] };
my $got;
$API->getArtistMbid(artist => 'Radiohead', fetch => $FETCH, onDone => sub {});
flush();
Plugins::Discography::API::_nameSearch($MB_BASE, Plugins::Discography::API::_nameQuery('artist', 'Radiohead', 0),
    $ROWS, $ROWS, sub { $got = $_[0] }, sub { $got = 'ERR' }, 'rows');
flush();
ok(nsearch() == 1 && ref $got eq 'ARRAY' && @$got == 1,
   '5: a whole result at 15 answers a caller wanting 100, with no request');

cold();
$REPLY{ q_for('Radiohead') } = { count => 1, artists => [
    { id => id(40), name => 'Radiohead', score => 100 } ] };
$API->getArtistMbid(artist => 'Radiohead', onDone => sub {});   # fetch 8, whole result
flush();
$API->getArtistCandidates('Radiohead', sub { $cands = $_[0] });
flush();
ok(nsearch() == 2 && ref $cands eq 'ARRAY' && @$cands == 1,
   '5: ... but the set still asks its own 15 after a whole result at 8');

cold();
$REPLY{ q_for('Genesis') } = $GEN;
$REPLY{ $MB_BASE . 'release-group?artist=' } = $COUNT;
$API->getArtistMbid(artist => 'Genesis', fetch => $FETCH, onDone => sub {});
flush();
$got = undef;
Plugins::Discography::API::_nameSearch($MB_BASE, Plugins::Discography::API::_nameQuery('artist', 'Genesis', 0),
    $ROWS, $ROWS, sub { $got = $_[0] }, sub { $got = 'ERR' }, 'rows');
flush();
ok(scalar(grep { /limit=100$/ } @QUERIES) == 1 && ref $got eq 'ARRAY' && @$got == 30,
   '5: a reply at 15 that is NOT the whole result (30 counted): one request at 100');
# Both replies are kept, one per limit: the set that follows still has its 15.
$API->getArtistCandidates('Genesis', sub { $cands = $_[0] });
flush();
ok(nsearch() == 2 && ref $cands eq 'ARRAY' && @$cands == 2,
   '5: ... and the set is still answered from the reply at 15 (both kept)');
});

# ---------------------------------------------------------------------------
# 6. THE KEPT REPLY EXPIRES.
# ---------------------------------------------------------------------------
section('6', sub {
cold();
$REPLY{ q_for('Radiohead') } = { count => 1, artists => [
    { id => id(40), name => 'Radiohead', score => 100 } ] };
$API->getArtistMbid(artist => 'Radiohead', fetch => $FETCH, onDone => sub {});
flush();
$_->{at} -= $API->NAME_MEMO_TTL + 1 for kept();
$API->getArtistCandidates('Radiohead', sub { $cands = $_[0] });
flush();
ok(nsearch() == 2, '6: a reply older than NAME_MEMO_TTL is not used');
});

# ---------------------------------------------------------------------------
# 7. ERRORS ARE NEVER KEPT, and every waiter hears.
# ---------------------------------------------------------------------------
section('7', sub {
cold();
$REPLY{ q_for('Madness') } = 'ERROR';
my ($m1, $c1) = ('UNSET', 'UNSET');
$API->getArtistMbid(artist => 'Madness', fetch => $FETCH, onDone => sub { $m1 = $_[0] });
$API->getArtistCandidates('Madness', sub { $c1 = $_[0] });
flush();
ok(!defined $m1, '7: an HTTP error reaches the resolver (no mbid)');
ok(ref $c1 eq 'ARRAY' && !@$c1, '7: ... and the waiting set, settled empty');
ok(!kept(), '7: an HTTP error is not kept');

cold();
$REPLY{ q_for('Madness') } = 'GARBAGE';
$API->getArtistMbid(artist => 'Madness', fetch => $FETCH, onDone => sub {});
flush();
ok(!kept(), '7: an unparseable reply is not kept');
@QUERIES = ();
$REPLY{ q_for('Madness') } = { count => 1, artists => [
    { id => id(50), name => 'Madness', score => 100 } ] };
$API->getArtistCandidates('Madness', sub { $c1 = $_[0] });
flush();
ok(nsearch() == 1 && ref $c1 eq 'ARRAY' && @$c1 == 1, '7: ... so the next caller asks again');
});

# ---------------------------------------------------------------------------
# 8. THE RESOLVER'S IN-PLACE EDIT DOES NOT REACH THE KEPT REPLY. It drops
#    MusicBrainz's special entities from its own list.
# ---------------------------------------------------------------------------
section('8', sub {
cold();
$REPLY{ q_for("La's") } = { count => 2, artists => [
    { id => '89ad4ac3-39f7-470e-963a-56509c546377', name => 'Various Artists', score => 100 },
    { id => id(60), name => "La's", score => 95 } ] };
$API->getArtistMbid(artist => "La's", fetch => $FETCH, onDone => sub {});
flush();
my ($kept) = kept();
ok($kept && @{ $kept->{arts} } == 2 && $kept->{arts}[0]{name} eq 'Various Artists',
   '8: the kept reply still holds every entry the reply had');

# The other order: the set fetches first, the resolver is answered from the
# KEPT reply - the path where handing out the kept list itself would let the
# resolver's edit reach it.
cold();
$REPLY{ q_for("La's") } = { count => 2, artists => [
    { id => '89ad4ac3-39f7-470e-963a-56509c546377', name => 'Various Artists', score => 100 },
    { id => id(60), name => "La's", score => 95 } ] };
$API->getArtistCandidates("La's", sub {});
flush();
my $got = 'UNSET';
$API->getArtistMbid(artist => "La's", onDone => sub { $got = $_[0] });
flush();
($kept) = kept();
ok(nsearch() == 1 && ($got // '') eq id(60),
   '8: the resolver answered from the kept reply picks past the special entity');
ok($kept && @{ $kept->{arts} } == 2 && $kept->{arts}[0]{name} eq 'Various Artists',
   '8: ... and the kept reply is untouched by its edit');
});

# ---------------------------------------------------------------------------
# 9. REFRESH FORGETS THE KEPT REPLY.
# ---------------------------------------------------------------------------
section('9', sub {
cold();
$REPLY{ q_for('Radiohead') } = { count => 1, artists => [
    { id => id(40), name => 'Radiohead', score => 100 } ] };
$API->getArtistMbid(artist => 'Radiohead', fetch => $FETCH, onDone => sub {});
flush();
$API->clearArtistCache(name => 'Radiohead');
ok(!kept(), '9: clearArtistCache drops the kept reply');
$API->getArtistCandidates('Radiohead', sub {});
flush();
ok(nsearch() == 2, '9: ... so the set asks MusicBrainz again');
});

# ---------------------------------------------------------------------------
# 10. AN ANNOTATED NAME IS NOT SHARED: the resolver strips "(Hall and Oates)",
#     the set does not, so their queries differ and each keeps its own.
# ---------------------------------------------------------------------------
section('10', sub {
cold();
my $raw = 'Daryl Hall and John Oates (Hall and Oates)';
$REPLY{ q_for('Daryl Hall and John Oates') } = { count => 1, artists => [
    { id => id(70), name => 'Daryl Hall & John Oates', score => 100 } ] };
$REPLY{ q_for($raw) } = { count => 0, artists => [] };
$REPLY{ $MB_BASE . 'release-group?artist=' } = $COUNT;
$REPLY{ $MB_BASE . Plugins::Discography::API::_nameQuery('artist', $raw, 1) } = { count => 0, artists => [] };
$API->getArtistMbid(artist => $raw, fetch => $FETCH, onDone => sub {});
flush();
$API->getArtistCandidates($raw, sub {});
flush();
ok(scalar(grep { index($_, q_for('Daryl Hall and John Oates')) == 0 } @QUERIES) == 1
   && scalar(grep { index($_, q_for($raw)) == 0 } @QUERIES) == 1,
   '10: an annotated name sends both queries, as before');
});

# ---------------------------------------------------------------------------
# 11. THE MIRROR'S ZERO-RESULT PUBLIC RETRY SHARES TOO, on the public key.
# ---------------------------------------------------------------------------
section('11', sub {
    local $MB_BASE = 'http://mirror:5000/ws/2/';
    cold();
    $REPLY{ q_for('Radiohead', $MB_BASE) } = { count => 0, artists => [] };
    $REPLY{ q_for('Radiohead', 'https://musicbrainz.org/ws/2/') } = { count => 1, artists => [
        { id => id(40), name => 'Radiohead', score => 100 } ] };
    ($mbid, $cands) = ();
    $API->getArtistMbid(artist => 'Radiohead', fetch => $FETCH, onDone => sub { $mbid = $_[0] });
    flush();
    $API->getArtistCandidates('Radiohead', sub { $cands = $_[0] });
    flush();
    ok(($mbid // '') eq id(40) && ref $cands eq 'ARRAY' && @$cands == 1,
       '11: an unindexed mirror still resolves through the public retry');
    ok(nsearch() == 2,
       '11: two name searches (mirror + public), where there were four');
});

# ---------------------------------------------------------------------------
# 12. EACH ACT KEEPS MUSICBRAINZ'S PRIMARY ENGLISH NAME (0.56.42), from the
#     reply the set already asks for: the search row titles a name with no Latin
#     letter with it. The aliases as the public search returned them for
#     宇多田ヒカル (2026-10-02): three locale-en aliases come before the PRIMARY one.
# ---------------------------------------------------------------------------
section('12', sub {
    cold();
    my $name = 'Utada';   # the reply's own name; the alias rule is what is pinned
    $REPLY{ q_for($name) } = { count => 3, artists => [
        { id => id(50), name => $name, score => 100, aliases => [
        { name => 'Utada',        locale => 'en', primary => undef },
        { name => 'Cubic U',      locale => 'en', primary => undef },
        { name => 'Utada Hikaru', locale => 'en_PH', primary => JSON::XS::true },
        { name => 'Hikaru Utada', locale => 'en', primary => undef, type => 'Legal name' },
        { name => 'Hikaru Utada', locale => 'en', primary => JSON::XS::true },
        { name => 'U3053', locale => 'ja', primary => JSON::XS::true },
    ] },
        { id => id(51), name => $name, score => 80, aliases => [ { name => 'Utada Ensemble', locale => 'en', primary => undef } ] },
        { id => id(52), name => $name, score => 70 },
    ] };
    my $got;
    $API->getArtistCandidates($name, sub { $got = $_[0] });
    flush();
    my %by = map { $_->{mbid} => $_ } @{ $got || [] };
    ok(scalar(($by{ id(50) }{en} // '') eq 'Hikaru Utada'),
       '12: the PRIMARY locale-en alias, not the first en alias (Utada, Cubic U), not en_PH, not a non-primary legal name');
    ok(scalar(!exists $by{ id(51) }{en} && !exists $by{ id(52) }{en}),
       '12: no primary English alias, or no aliases: no `en` at all');
    my ($key) = grep { /^dsc:acand:/ } keys %CACHE;
    ok(scalar(($key // '') =~ /^dsc:acand:8:/ && ($CACHE{$key}[0]{en} // '') eq 'Hikaru Utada'),
       '12: kept under the v8 key (a v7 set has no English names), the English name with it');
    ok(scalar(@QUERIES == 1), '12: ... from the one request the set already made');
});

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
