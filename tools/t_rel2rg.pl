#!/usr/bin/env perl
#
# REGRESSION TEST — the owned-album release lookups are BATCHED (stage 1 of
# docs/mb-efficiency-and-community-api-analysis.md, A7 #2; 2026-09-29).
#
# warmLocalReleases resolves each owned album's release MBID to its release
# group, so a library copy can match its tile by id on the FIRST render. It used
# to send one `release/<mbid>?inc=release-groups` per album — 20 owned albums,
# 20 requests, 22 seconds on the public API. One search,
# `release?query=reid:A OR reid:B OR ...`, answers up to 50 at once. MEASURED on
# the public API: 50 real ids, all 50 resolved to the right group in 0.3s; 10 of
# 10 on the mirror.
#
# THE RULE THIS SUITE PINS: the search only ever SAVES requests. An id it does
# not return goes to the old one-by-one lookup and gets exactly the old verdict;
# a failed, unreadable or empty search sends its whole batch the same way.
#
# FIXTURES ARE CAPTURED (tools/fixtures/, all from the public API 2026-09-29):
#   mb_release_browse_radiohead10.json      release?artist=<Radiohead>&limit=10
#                                           &inc=release-groups  (ground truth)
#   mb_release_search_reid_radiohead12.json release?query=reid:... for those 10
#                                           ids + a GROUP id + an id MB never
#                                           issued: 10 hits, the other two absent
#   mb_release_lookup_radiohead.json        release/<id>?inc=release-groups
# Larger batches are built from the captured hit's own shape, because they pin
# OUR chunking, not MusicBrainz's data. The lookup's 404 is answered as
# '404 Not Found', the error text the existing lookup path already keys on
# (`\b404\b`); that path is unchanged by this work.
#
# Standalone -- no LMS install needed:  perl tools/t_rel2rg.pl
#
use strict;
use warnings;
use FindBin;
use JSON::PP ();

our (%CACHE, $DATA, @URLS, @DEFERRED, $DEFER, $BADJSON,
     $SEARCH, %OMIT, %NOGROUP, @EXTRA, %KNOWN);

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::Timers Slim::Networking::SimpleAsyncHTTP
                  Slim::Utils::Strings Slim::Utils::PluginManager
                  Slim::Control::Request JSON::XS::VersionOneAndTwo
                  Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Cache' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Cache' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { '' };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub {
        die "malformed JSON string\n" if $main::BADJSON;
        return $main::DATA;
    };
    *{'Slim::Networking::SimpleAsyncHTTP::new'} = sub {
        my ($cls, $cb, $errcb) = @_;
        return bless { cb => $cb, err => $errcb }, 'T::HTTP';
    };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs JSON::XS::VersionOneAndTwo)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
    @{'JSON::XS::VersionOneAndTwo::EXPORT'} = qw(to_json from_json);
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Cache;
sub get    { return $main::CACHE{ $_[1] } }
sub set    { $main::CACHE{ $_[1] } = $_[2]; return 1 }
sub remove { delete $main::CACHE{ $_[1] }; return 1 }
package T::Prefs;
sub get { return $_[1] eq 'mb_base_url' ? 'http://mirror:5000/ws/2/' : undef }
sub set { return 1 } sub init { return 1 } sub setChange { return 1 }
package T::Resp;
sub new { my ($c, $e) = @_; bless { e => $e }, $c }
sub content { '{}' }
sub error   { $_[0]{e} // '503 Service Unavailable' }
package T::HTTP;
sub get {
    my ($self, $url) = @_;
    push @main::URLS, $url;
    my $fire = sub {
        my ($ok, $data, $err) = main::respond($url);
        return $self->{err}->(T::Resp->new($err)) unless $ok;
        $main::DATA = $data;
        # EACH reply sets its own flag. The stub answers synchronously, so the
        # lookups the code sends from inside this callback run inside this
        # dynamic scope; inheriting the flag made every one of them "unreadable"
        # too (caught on the first run: a harness bug that read as a code bug).
        local $main::BADJSON = ($ok eq 'bad') ? 1 : 0;
        $self->{cb}->(T::Resp->new);
    };
    if ($main::DEFER) { push @main::DEFERRED, $fire } else { $fire->() }
}

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::API;
my $API = 'Plugins::Discography::API';

# The queue is not this suite's subject (t_netqueue.pl owns it): bypassed so the
# stub sees each request as the code issues it.
{
    no strict 'refs'; no warnings 'redefine';
    *{'Plugins::Discography::API::_netGet'} = sub {
        my ($url, $ok, $err, %opt) = @_;
        return Slim::Networking::SimpleAsyncHTTP->new($ok, $err, \%opt)->get($url);
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

sub slurp {
    open my $fh, '<:raw', "$FindBin::Bin/fixtures/$_[0]" or die "fixture $_[0]: $!";
    local $/; return JSON::PP::decode_json(<$fh>);
}
my $BROWSE = slurp('mb_release_browse_radiohead10.json');
my $RAW12  = do { open my $fh, '<:raw', "$FindBin::Bin/fixtures/mb_release_search_reid_radiohead12.json" or die $!; local $/; <$fh> };
my $LOOKUP = do { open my $fh, '<:raw', "$FindBin::Bin/fixtures/mb_release_lookup_radiohead.json" or die $!; local $/; <$fh> };
my $HIT    = slurp('mb_release_search_reid_radiohead12.json')->{releases}[0];   # a real hit's shape

my %TRUTH = map { $_->{id} => $_->{'release-group'}{id} } @{ $BROWSE->{releases} };
my @TEN   = map { $_->{id} } @{ $BROWSE->{releases} };
my $GROUPID = $BROWSE->{releases}[0]{'release-group'}{id};   # a GROUP id, tagged as an album
my $NEVER   = '00000000-0000-4000-8000-000000000000';          # an id MB never issued
my @TWELVE  = (@TEN, $GROUPID, $NEVER);                         # exactly what was captured

sub decode_q { my $q = shift; $q =~ s/%([0-9A-F]{2})/chr hex $1/ge; return $q }

# The fake MusicBrainz. Returns (ok, data) / (0, undef, error) / ('bad', ...).
sub respond {
    my ($url) = @_;
    if ($url =~ m{/release\?query=([^&]+)(?:&limit=(\d+))?&fmt=json$}) {
        my ($q, $limit) = (decode_q($1), $2 // 25);        # MB's default limit is 25
        my @ask = $q =~ /reid:([0-9a-f-]{36})/g;
        return (0, undef, '503 Service Unavailable') if ($SEARCH // '') eq 'error';
        return ('bad', {})                             if ($SEARCH // '') eq 'unreadable';
        return (1, { count => 0, releases => [] })     if ($SEARCH // '') eq 'empty';
        # The exact captured batch gets the exact captured reply.
        if (!%OMIT && !%NOGROUP && !@EXTRA && join(',', sort @ask) eq join(',', sort @TWELVE)) {
            return (1, JSON::PP::decode_json($RAW12));
        }
        my @rel;
        # Stray hits FIRST: MB orders by score, so one could sit anywhere, and
        # last in line the `limit` cut would hide it from the code under test
        # (a vacuous section 8, caught by its mutant surviving).
        for my $x (@EXTRA) {
            my $h = JSON::PP::decode_json(JSON::PP::encode_json($HIT));
            $h->{id} = $x->[0]; $h->{'release-group'}{id} = $x->[1];
            push @rel, $h;
        }
        for my $id (@ask) {
            next if $OMIT{$id} || !$KNOWN{$id};
            my $h = JSON::PP::decode_json(JSON::PP::encode_json($HIT));   # the captured shape
            $h->{id} = $id;
            if ($NOGROUP{$id}) { delete $h->{'release-group'} }
            else               { $h->{'release-group'}{id} = $KNOWN{$id} }
            push @rel, $h;
        }
        my $count = scalar @rel;
        splice(@rel, $limit) if @rel > $limit;
        return (1, { count => $count, releases => \@rel });
    }
    if ($url =~ m{/release/([0-9a-f-]{36})\?inc=release-groups&fmt=json$}) {
        my $id = $1;
        return (0, undef, '404 Not Found') unless $KNOWN{$id};
        my $d = JSON::PP::decode_json($LOOKUP);            # the captured shape
        $d->{id} = $id; $d->{'release-group'}{id} = $KNOWN{$id};
        return (1, $d);
    }
    return (0, undef, "unexpected url $url");
}

sub flush {
    for (1 .. 10) { my @d = @DEFERRED; last unless @d; @DEFERRED = (); $_->() for @d }
}
sub reset_all {
    %CACHE = (); @URLS = (); @DEFERRED = (); $DEFER = 0; $BADJSON = 0;
    $SEARCH = ''; %OMIT = (); %NOGROUP = (); @EXTRA = (); %KNOWN = %TRUTH;
}
sub key { 'dsc:rel2rg:v1:' . $_[0] }
sub tkey { 'dsc:reltype:v1:' . $_[0] }
my $searches = sub { scalar grep { m{/release\?query=} } @URLS };
my $lookups  = sub { [ map { m{/release/([0-9a-f-]{36})\?} ? $1 : () } @URLS ] };
my $allTruth = sub { !grep { ($CACHE{ key($_) } // '') ne $TRUTH{$_} } @_ };

# ---------------------------------------------------------------------------
# 1. ONE uncached id: the lookup, as before — a search would cost the same one
#    request and give a weaker answer (absence is not a verdict).
# ---------------------------------------------------------------------------
reset_all();
my $cbs = 0;
$API->warmLocalReleases([ $TEN[0] ], sub { $cbs++ });
ok($searches->() == 0 && scalar(@URLS) == 1, '1: a single id is looked up directly, no search');
ok(($CACHE{ key($TEN[0]) } // '') eq $TRUTH{ $TEN[0] }, "1: ... and cached with its group");
ok($cbs == 1, '1: ... calling back exactly once');

# ---------------------------------------------------------------------------
# 2. THE SAVING: ten owned albums, one request.
# ---------------------------------------------------------------------------
reset_all();
$cbs = 0;
$API->warmLocalReleases([ @TEN ], sub { $cbs++ });
ok(scalar(@URLS) == 1 && $searches->() == 1, '2: ten uncached releases cost ONE request');
my $q = decode_q(($URLS[0] =~ m{query=([^&]+)})[0] // '');
ok(scalar(!grep { index($q, "reid:$_") < 0 } @TEN), '2: ... a search naming every one of them');
ok(scalar($q =~ /^reid:\S+( OR reid:\S+){9}$/), "2: ... joined by OR, nothing else in the query");
ok(scalar($URLS[0] =~ /&limit=10&/), '2: ... with a limit that can return all ten');
ok($allTruth->(@TEN), '2: all ten cached with the group the release browse gives');
ok($cbs == 1, '2: ... calling back exactly once');
@URLS = ();
$API->warmLocalReleases([ @TEN ], sub {});
ok(scalar(@URLS) == 0, '2: a second visit costs nothing (cached)');

# ---------------------------------------------------------------------------
# 3. WHAT THE SEARCH DOES NOT RETURN GETS THE OLD LOOKUP, and the old verdict.
#    The captured batch: a GROUP id and a never-issued id are simply absent from
#    the real reply. Each is then looked up; each 404s; each caches '' — exactly
#    what the one-by-one code did.
# ---------------------------------------------------------------------------
reset_all();
$API->warmLocalReleases([ @TWELVE ], sub {});
ok($searches->() == 1, '3: the captured twelve: one search');
my $lk = $lookups->();
ok(scalar(@$lk) == 2 && (join ',', sort @$lk) eq (join ',', sort $GROUPID, $NEVER),
   '3: ... then a lookup for exactly the two it did not return');
ok($allTruth->(@TEN), '3: the ten real releases cached from the search');
ok(defined $CACHE{ key($GROUPID) } && $CACHE{ key($GROUPID) } eq ''
   && defined $CACHE{ key($NEVER) } && $CACHE{ key($NEVER) } eq '',
   "3: ... and the two absent ones cached '' by their lookup's 404, as before");

# 3b. ABSENCE IS NOT A VERDICT: a real release the search index does not have
#     yet (a brand-new release) must still get its real group from the lookup.
reset_all();
%OMIT = ($TEN[3] => 1);
$API->warmLocalReleases([ @TEN ], sub {});
ok(scalar(@{ $lookups->() }) == 1 && $lookups->()->[0] eq $TEN[3],
   '3b: a real release missing from the search index is looked up');
ok(($CACHE{ key($TEN[3]) } // '') eq $TRUTH{ $TEN[3] },
   "3b: ... and gets its REAL group, not ''");

# ---------------------------------------------------------------------------
# 4-6. A SEARCH THAT FAILS, IS UNREADABLE, OR FINDS NOTHING (a mirror whose
#      search index was never built answers count 0 to everything) sends the
#      whole batch to the lookups: the answers are the old ones.
# ---------------------------------------------------------------------------
for my $case ([ error => '4: a failed search' ], [ unreadable => '5: an unreadable search reply' ],
              [ empty => '6: an empty search (unbuilt mirror index)' ]) {
    reset_all();
    $SEARCH = $case->[0];
    $cbs = 0;
    $API->warmLocalReleases([ @TEN ], sub { $cbs++ });
    ok($searches->() == 1 && scalar(@{ $lookups->() }) == 10,
       "$case->[1] sends all ten to the one-by-one lookup");
    ok($allTruth->(@TEN), "$case->[1]: ... which caches the right groups");
    ok($cbs == 1, "$case->[1]: ... calling back exactly once");
}

# ---------------------------------------------------------------------------
# 7-8. The search reply is only trusted for what it CLEARLY says.
# ---------------------------------------------------------------------------
reset_all();
%NOGROUP = ($TEN[5] => 1);
$API->warmLocalReleases([ @TEN ], sub {});
ok(scalar(@{ $lookups->() }) == 1 && $lookups->()->[0] eq $TEN[5]
   && ($CACHE{ key($TEN[5]) } // '') eq $TRUTH{ $TEN[5] },
   '7: a hit without its release group is looked up, not cached as empty');

reset_all();
my $STRAY = '11111111-2222-4333-8444-555555555555';
# Three asked, the search returns the stray plus two of them: three hits, which
# fits the limit of 3, so the stray really reaches the code.
@EXTRA = ([ $STRAY, $GROUPID ]);
%OMIT  = ($TEN[2] => 1);
$API->warmLocalReleases([ @TEN[0 .. 2] ], sub {});
ok(!exists $CACHE{ key($STRAY) }, '8: a hit for an id nobody asked about is ignored');
ok($allTruth->(@TEN[0 .. 1]), '8: ... the asked ones it returned are cached from it');
ok(scalar(@{ $lookups->() }) == 1 && $lookups->()->[0] eq $TEN[2] && $allTruth->($TEN[2]),
   '8: ... and the one it left out is looked up (the stray did not stand in for it)');

# ---------------------------------------------------------------------------
# 9. CHUNKING: 120 owned releases -> searches of 50, 50 and 20, nothing else.
# ---------------------------------------------------------------------------
reset_all();
my @MANY = map { sprintf '%08x-aaaa-4bbb-8ccc-%012x', $_, $_ } 1 .. 120;
%KNOWN = map { $_ => "rg-$_" } @MANY;
$cbs = 0;
$API->warmLocalReleases([ @MANY ], sub { $cbs++ });
my @sizes = map { scalar(() = decode_q($_) =~ /reid:/g) } grep { m{/release\?query=} } @URLS;
ok((join ',', @sizes) eq '50,50,20', '9: 120 releases -> three searches of 50, 50 and 20');
ok(scalar(@{ $lookups->() }) == 0, '9: ... and no one-by-one lookups');
ok(scalar(!grep { length($_) > 3200 } @URLS), '9: ... every URL well under what the public API accepted (3,002 chars for 50)');
ok(scalar(!grep { ($CACHE{ key($_) } // '') ne "rg-$_" } @MANY), '9: all 120 cached');
ok($cbs == 1, '9: ... calling back exactly once');

# 9b. A LAST BATCH OF ONE is a lookup, not a search (51 = 50 + 1): a search for
#     one id costs the same request as its lookup, and a second one on a miss.
reset_all();
my @FIFTY1 = @MANY[0 .. 50];
%KNOWN = map { $_ => "rg-$_" } @FIFTY1;
$cbs = 0;
$API->warmLocalReleases([ @FIFTY1 ], sub { $cbs++ });
@sizes = map { scalar(() = decode_q($_) =~ /reid:/g) } grep { m{/release\?query=} } @URLS;
ok((join ',', @sizes) eq '50', '9b: 51 releases -> ONE search of 50, no search of one');
ok(scalar(@{ $lookups->() }) == 1 && $lookups->()->[0] eq $FIFTY1[50],
   '9b: ... and the 51st is looked up directly');
ok(scalar(@URLS) == 2, '9b: ... two requests in all');
ok(scalar(!grep { ($CACHE{ key($_) } // '') ne "rg-$_" } @FIFTY1) && $cbs == 1,
   '9b: all 51 cached, calling back exactly once');

# ---------------------------------------------------------------------------
# 10. Cached and in-flight ids are never asked for twice.
# ---------------------------------------------------------------------------
reset_all();
$CACHE{ key($TEN[0]) } = $TRUTH{ $TEN[0] };
$CACHE{ key($TEN[1]) } = '';
# ... with their group types known too (0.56.39; without one, §12).
$CACHE{ tkey($TEN[0]) } = { type => 'EP', secondary => [] };
$CACHE{ tkey($TEN[1]) } = '';
$API->warmLocalReleases([ @TEN[0 .. 2] ], sub {});
ok(scalar(@URLS) == 1 && $searches->() == 0 && ($lookups->()->[0] // '') eq $TEN[2],
   '10: cached ids (a group, or the empty verdict) are skipped: one lookup for the one left');

reset_all();
$DEFER = 1;
my ($first, $second) = (0, 0);
$API->warmLocalReleases([ @TEN ], sub { $first++ });
$API->warmLocalReleases([ @TEN ], sub { $second++ });
ok(scalar(@URLS) == 1, '10: a second call while the batch is in flight sends nothing');
ok($second == 1 && $first == 0, '10: ... and is answered at once, as before');
flush();
ok($first == 1 && $allTruth->(@TEN), '10: the first call completes normally');
%CACHE = (); @URLS = (); $DEFER = 0;
$API->warmLocalReleases([ @TEN ], sub {});
ok(scalar(@URLS) == 1, '10: ... and the in-flight markers are released afterwards');

# 11. Nothing to do: no request, one callback.
reset_all();
$cbs = 0;
$API->warmLocalReleases([], sub { $cbs++ });
$API->warmLocalReleases(undef, sub { $cbs++ });
ok(scalar(@URLS) == 0 && $cbs == 2, '11: no ids: no request, and the callback still fires');

# ---------------------------------------------------------------------------
# 12. THE GROUP'S TYPE, FROM THE SAME REPLY (0.56.39; Simon, on a soundtrack
#     LMS reads as ALBUM: "this is Soundtrack not a compilation not sure if LMS
#     has that but MB does"). Kept beside the group, no extra request; a release
#     whose group was cached before it is asked once more, for the type.
# ---------------------------------------------------------------------------
my $LIVE   = 'ef561e76-4e77-4950-b8fb-05b3085938db';   # Album + Live in the captured reply
my $SINGLE = 'c24fd4e7-d513-4b59-a492-48fe0fff2738';   # Single, no secondary
reset_all();
$API->warmLocalReleases([ @TWELVE ], sub {});
my $tp = $API->peekLocalReleaseTypes([ $LIVE, $SINGLE, $GROUPID, $NEVER ]);
ok(scalar(($tp->{$LIVE}{type} // '') eq 'Album' && "@{ $tp->{$LIVE}{secondary} || [] }" eq 'Live'),
   '12: the search keeps each group type (Album + Live)');
ok(scalar(($tp->{$SINGLE}{type} // '') eq 'Single' && !@{ $tp->{$SINGLE}{secondary} || [] }),
   '12: ... a reply with no secondary types keeps none');
ok(scalar(!exists $tp->{$GROUPID} && !exists $tp->{$NEVER}
          && defined $CACHE{ tkey($GROUPID) } && $CACHE{ tkey($GROUPID) } eq ''),
   '12: a 404 keeps an empty type, which reads as none');
reset_all();
$API->warmLocalReleases([ $TEN[0] ], sub {});
$tp = $API->peekLocalReleaseTypes([ $TEN[0] ]);
ok(scalar(($tp->{ $TEN[0] }{type} // '') eq 'EP' && $lookups->()->[0] eq $TEN[0]),
   '12: the one-by-one lookup keeps it too');
reset_all();
$CACHE{ key($TEN[0]) } = $TRUTH{ $TEN[0] };
$API->warmLocalReleases([ $TEN[0] ], sub {});
ok(scalar(@URLS == 1 && ($lookups->()->[0] // '') eq $TEN[0] && ref $CACHE{ tkey($TEN[0]) } eq 'HASH'),
   '12: a group cached before (no type) is asked once more, and the type kept');
@URLS = ();
$API->warmLocalReleases([ $TEN[0] ], sub {});
ok(scalar(!@URLS), '12: ... then never again');
ok(scalar(!keys %{ $API->peekLocalReleaseTypes([ 'nope', undef, '' ]) }),
   '12: an unknown id reads as no type');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
