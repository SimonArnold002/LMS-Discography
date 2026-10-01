#!/usr/bin/env perl
#
# REGRESSION TEST — the artist page's MusicBrainz chain, end to end (stage 2 of
# docs/mb-efficiency-and-community-api-analysis.md, 2026-09-29).
#
# Drives the REAL Browse::_discographyView over the REAL API.pm, with only the
# network, the timers, the library query and the list builder replaced, and
# logs every event in order: each MusicBrainz request, the render, the
# owned-album lookups and the collaboration vetting. The chain had no suite
# before stage 2 re-ordered it:
#
#   before  spine browse -> owned-album lookups -> artist read (bands) ->
#           release browse (up to 40 pages) -> RENDER -> collaborations
#   now     artist read (bands AND, under 25 groups, the spine) -> spine browse
#           (25 or more only) -> band lookup (a cache hit) -> bootleg check by
#           id (at most 6) -> RENDER -> owned albums the check did not place ->
#           collaborations
#
# What this pins:
#   1. a cold 24-group artist renders after exactly TWO requests, the artist
#      read and one by-id check, and the by-id URL is the one the public reply
#      was captured from;
#   2. owned albums are looked up only AFTER the render and only those the
#      check did not place (not a release it mapped, not a group id on the page,
#      each once);
#   3. an artist listing 25 groups is browsed after the read;
#   4. a failed check still renders (unfiltered) and sends every owned album to
#      the lookups;
#   5. a rebuild during a running check renders at once and leaves the lookups
#      to the visit whose check it is;
#   6. official_wait 0 renders before the check; the deadline renders without
#      it and the check still finishes;
#   7. a warm revisit sends nothing;
#   8. (0.56.7, analysis §A16) an artist whose read lists 25 draws from
#      ListenBrainz's and the community API's lists with the community's
#      verdicts and ONE by-id request; MusicBrainz completes it after the
#      render, every request as background work; the completed list waits for a
#      fresh entry; a Refresh takes MusicBrainz's own list, awaited.
#
# FIXTURES ARE CAPTURED (tools/fixtures/, public API, 2026-09-29): Ladyhawke's
# read (mb_artist_ladyhawke_aliases_artistrels_releasegroups.json, 24 groups)
# and her by-id check (mb_rg_byid_ladyhawke.json, 24 of 24 groups, 72
# releases); Radiohead's read (25 listed, MB's cap). Radiohead's browse and
# by-id replies are built in the captured shape: they pin OUR chain, not
# MusicBrainz's data.
#
# Standalone -- no LMS install needed:  perl tools/t_chain.pl
#
use strict;
use warnings;
use FindBin;
use JSON::PP ();

our (%CACHE, $DATA, @EV, @DEFERRED, $DEFER, $RESPONDER, %PREF, $LOCAL, @TIMERS,
     @BUILT, $FAIL_BYID);

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers Slim::Utils::Strings
                  Slim::Control::Request Slim::Schema Slim::Web::HTTP
                  Slim::Networking::SimpleAsyncHTTP Slim::Utils::Misc
                  JSON::XS::VersionOneAndTwo Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}          = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Cache' };
    *{'Plugins::Discography::DB::store'}   = sub { bless {}, 'T::Cache' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Utils::Strings::cstring'}     = sub { $_[1] };
    *{'Slim::Utils::Strings::string'}      = sub { $_[0] };
    *{'Slim::Utils::Timers::setTimer'}     = sub { push @main::TIMERS, $_[2]; push @main::EV, 'timer'; return };
    *{'Slim::Utils::Timers::killTimers'}   = sub {
        my $cb = $_[1];
        @main::TIMERS = grep { $_ != $cb } @main::TIMERS;
        push @main::EV, 'timer killed';
        return;
    };
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { '' };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { $main::DATA };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings JSON::XS::VersionOneAndTwo)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');
    @{'JSON::XS::VersionOneAndTwo::EXPORT'} = qw(to_json from_json);
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Cache;
sub get    { return $main::CACHE{ $_[1] } }
sub set    { $main::CACHE{ $_[1] } = $_[2]; return 1 }
sub remove { delete $main::CACHE{ $_[1] }; return 1 }
package T::Prefs;
sub get { return $_[1] eq 'mb_base_url' ? 'https://musicbrainz.org/ws/2/' : $main::PREF{ $_[1] } }
sub set { return 1 } sub init { return 1 } sub setChange { return 1 }
package T::Resp;
sub new { bless {}, shift } sub content { '{}' } sub error { '503 Service Unavailable' }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;
my $API = 'Plugins::Discography::API';
my $B   = 'Plugins::Discography::Browse';

# Only the edges are replaced. The network: every request is an event, answered
# by $RESPONDER, held open while $DEFER is set. The library, the list builder
# and the non-MusicBrainz legs: recorded, answered at once.
{
    no strict 'refs'; no warnings 'redefine';
    *{"${API}::_netGet"} = sub {
        my ($url, $ok, $err, %opt) = @_;
        push @EV, "GET $url" . ($opt{background} ? ' [bg]' : '');
        my $fire = sub {
            my $r = $RESPONDER->($url);
            return $err->(T::Resp->new) if !ref $r && $r eq 'FAIL';
            $DATA = $r;
            $ok->(T::Resp->new);
        };
        if ($DEFER) { push @DEFERRED, $fire } else { $fire->() }
    };
    *{"${API}::warmLocalReleases"} = sub {
        my ($class, $ids, $cb) = @_;
        push @EV, 'local ' . join(',', @{ $ids || [] });
        $cb->() if $cb;
    };
    *{"${API}::warmCollaborations"}      = sub { push @EV, 'collabs' };
    *{"${API}::sharesNameWithProminent"} = sub { 0 };
    *{'Plugins::Discography::Sources::localAlbums'} = sub { $main::LOCAL };
    *{'Plugins::Discography::Sources::peekPool'}    = sub { { cold => 0 } };
    *{"${B}::_warmArtistExtras"} = sub { $_[-1]->() };
    *{"${B}::_buildList"} = sub {
        my ($client, $opts, $mbid, $rgs, $bio, $local) = @_;
        push @EV, 'render';
        push @BUILT, { mbid => $mbid, rgs => $rgs, local => $local,
                       official => $API->peekOfficial($mbid) };
        return [ { name => 'row', type => 'text' } ];
    };
}
sub step {                       # one round of the replies held open
    my @d = @DEFERRED; @DEFERRED = ();
    $_->() for @d;
    return scalar @d;
}
sub flush { for (1 .. 30) { last unless step() } }

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
    local $/;
    return scalar <$fh>;
}
my $LH = '2e547c75-36c1-49d0-984e-b14498c936f0';
my $RH = 'a74b1b7f-71a5-4011-9441-d0b5e4122711';
my %READ = ($LH => slurp('mb_artist_ladyhawke_aliases_artistrels_releasegroups.json'),
            $RH => slurp('mb_artist_radiohead_aliases_artistrels_releasegroups.json'));
my $LH_BYID = slurp('mb_rg_byid_ladyhawke.json');
my @LH_IDS  = sort map { $_->{id} } @{ JSON::PP::decode_json($READ{$LH})->{'release-groups'} };
# The URL her by-id reply was captured from, 2026-09-29.
my $LH_URL  = 'https://musicbrainz.org/ws/2/release-group?query='
            . join('%20OR%20', map { "rgid%3A$_" } @LH_IDS) . '&limit=24&fmt=json';
# Radiohead's browse: 30 groups in the captured shape.
my @RH_GROUPS = map { sprintf('%08x-0000-4000-8000-%012x', 0x7000 + $_, $_) } 1 .. 30;

sub responder {
    my ($url) = @_;
    return JSON::PP::decode_json($READ{$1})
        if $url =~ m{/artist/([0-9a-f-]{36})\?inc=aliases\+artist-rels\+release-groups&fmt=json$};
    if ($url =~ m{/release-group\?artist=\Q$RH\E&limit=100&offset=0&inc=aliases&fmt=json$}) {
        return { 'release-group-count' => 30, 'release-groups' => [ map {
            { id => $RH_GROUPS[$_], title => "Group $_", 'primary-type' => 'Album',
              'secondary-types' => [], 'first-release-date' => '2000' } } 0 .. 29 ] };
    }
    if ($url =~ m{/release-group\?query=}) {
        return 'FAIL' if $FAIL_BYID;
        return JSON::PP::decode_json($LH_BYID) if $url eq $LH_URL;
        my @ids = $url =~ /rgid%3A([0-9a-f-]+)/g;
        return { count => scalar @ids, 'release-groups' => [ map {
            { id => $_, title => $_, count => 1,
              releases => [ { id => "$_-r", title => 'T', status => 'Official' } ] } } @ids ] };
    }
    return 'FAIL';
}

# The owned albums: one whose release the check maps, one tagged with a GROUP id
# on the page, one released on something off the page (twice: two copies), one
# with no tag.
my $lhByid  = JSON::PP::decode_json($LH_BYID);
my ($placedG) = grep { @{ $_->{releases} || [] } } @{ $lhByid->{'release-groups'} };
my $PLACED  = $placedG->{releases}[0]{id};
my $GROUPID = $LH_IDS[3];
my $OFFPAGE = 'ffffffff-0000-4000-8000-00000000000a';
my @LH_LOCAL = ({ _mbid => $PLACED, _albumid => 1 }, { _mbid => $GROUPID, _albumid => 2 },
                { _mbid => $OFFPAGE, _albumid => 3 }, { _mbid => $OFFPAGE, _albumid => 4 },
                { _albumid => 5 });

sub fresh {
    %CACHE = (); @EV = (); @DEFERRED = (); @TIMERS = (); @BUILT = ();
    $DEFER = 0; $FAIL_BYID = 0; $RESPONDER = \&responder;
    %PREF = (official_wait => 15, show_bio => 0, hide_unmatched => 0);
    $LOCAL = [ @LH_LOCAL ];
}
my @PAGES;
sub page {
    my ($mbid, $name, %o) = @_;
    my $got;
    $B->can('_discographyView')->(undef, sub { $got = shift; push @PAGES, $got },
        { mbid => $mbid, artist => $name, artist_id => 7, fresh => ($o{fresh} ? 1 : 0) });
    return \$got;
}
sub gets    { grep { /^GET / } @_ }
sub mbgets  { grep { m{^GET https://musicbrainz\.org/} } @_ }
sub upto    { my ($what, @ev) = @_; my @o; for (@ev) { last if $_ eq $what; push @o, $_ } @o }
sub after   { my ($what, @ev) = @_; my $seen; grep { my $k = $seen; $seen ||= ($_ eq $what); $k } @ev }
sub idx     { my ($re, @ev) = @_; for my $i (0 .. $#ev) { return $i if $ev[$i] =~ $re } return -1 }

# ---------------------------------------------------------------------------
# 1. COLD, UNDER 25 GROUPS (Ladyhawke, 24): the artist read, one by-id check,
#    the render. Nothing else before it.
# ---------------------------------------------------------------------------
fresh();
my $p1 = page($LH, 'Ladyhawke');
my @before = gets(upto('render', @EV));
ok(scalar(@before) == 2, '1: a cold 24-group page renders after TWO requests');
ok(scalar(($before[0] // '') =~ m{/artist/\Q$LH\E\?inc=aliases\+artist-rels\+release-groups&fmt=json$}),
   '1: ... first the artist read (bands, aliases AND her spine)');
ok(($before[1] // '') eq "GET $LH_URL", '1: ... then the by-id check, the exact URL her reply was captured from');
ok(scalar(!grep { m{release-group\?artist=|release\?query=reid|release\?artist=} } @EV),
   '1: no spine browse, no owned-album search, no release browse, at any point');
ok(scalar(@BUILT) == 1 && scalar(@{ $BUILT[0]{rgs} }) == 24, '1: the page is built once, from all 24 groups');
ok(ref $BUILT[0]{official} eq 'HASH' && scalar(keys %{ $BUILT[0]{official} }) == 24,
   '1: ... with the bootleg map already there (all 24 classified)');
ok(ref ${$p1} eq 'HASH', '1: ... and handed to the caller');
my @post = after('render', @EV);
ok(scalar(@post) == 2 && $post[0] eq "local $OFFPAGE" && $post[1] eq 'collabs',
   '1: AFTER the render: one lookup, for the one owned release the check did not place, then collaborations');
ok(idx(qr/^timer killed$/, @EV) >= 0 && idx(qr/^timer killed$/, @EV) < idx(qr/^render$/, @EV),
   '1: the deadline timer was cancelled by the check, before the render');

# ---------------------------------------------------------------------------
# 2. A WARM REVISIT sends nothing, and renders at once.
# ---------------------------------------------------------------------------
@EV = (); @BUILT = ();
page($LH, 'Ladyhawke');
ok(scalar(gets(@EV)) == 0, '2: a warm revisit sends no request');
ok(scalar(@BUILT) == 1 && ref $BUILT[0]{official} eq 'HASH', '2: ... and renders filtered');
ok(scalar(grep { $_ eq "local $OFFPAGE" } @EV) == 1,
   '2: ... and hands the lookups the same one release (they skip what they cached)');

# ---------------------------------------------------------------------------
# 3. TWENTY-FIVE LISTED (Radiohead): the read, then the browse, then the check.
# ---------------------------------------------------------------------------
fresh();
$LOCAL = [ { _mbid => "$RH_GROUPS[4]-r", _albumid => 1 } ];
page($RH, 'Radiohead');
# Since 0.56.7 the first list is asked for between the read and the browse;
# this responder gives none, so MusicBrainz's three requests are the subject.
my @g3 = mbgets(upto('render', @EV));
ok(scalar(@g3) == 3, '3: a cold page listing 25 in its read takes three requests');
ok(scalar(grep { m{api\.listenbrainz\.org/} } gets(@EV)) == 1
   && scalar(grep { m{api\.lms-community\.org/} } gets(@EV)) == 1,
   '3: ... after the first list was asked for (none came: the browse)');
ok(scalar($g3[0] =~ m{/artist/\Q$RH\E\?} && $g3[1] =~ m{/release-group\?artist=\Q$RH\E&}
          && $g3[2] =~ m{/release-group\?query=.*&limit=30&}),
   '3: ... the read, the browse, then all 30 groups by id');
ok(scalar(@BUILT) == 1 && scalar(@{ $BUILT[0]{rgs} }) == 30, "3: ... and the page is built from the browse's 30");
ok(scalar(grep { $_ eq 'local ' } after('render', @EV)) == 1,
   '3: an owned release the check mapped needs no lookup (an empty list is handed over)');

# ---------------------------------------------------------------------------
# 4. THE CHECK FAILS: the page still renders, unfiltered, and every owned album
#    (but the one tagged with a group id on the page) goes to the lookups.
# ---------------------------------------------------------------------------
fresh();
$FAIL_BYID = 1;
page($LH, 'Ladyhawke');
ok(scalar(@BUILT) == 1 && !defined $BUILT[0]{official}, '4: a failed check still renders, unfiltered');
ok(!defined $CACHE{"dsc:rgo:v5:$LH"}, '4: ... caching no bootleg map');
my @post4 = after('render', @EV);
ok(scalar(@post4) == 2 && $post4[0] eq "local $PLACED,$OFFPAGE" && $post4[1] eq 'collabs',
   '4: ... and every owned release goes to the lookups for the next visit, each once');

# ---------------------------------------------------------------------------
# 5. A REBUILD DURING A RUNNING CHECK renders at once, unfiltered, and leaves
#    the lookups to the visit whose check it is.
# ---------------------------------------------------------------------------
fresh();
$DEFER = 1;
page($LH, 'Ladyhawke');
step();                                    # the read answers; the check is sent
ok(scalar(grep { /release-group\?query=/ } @EV) == 1 && scalar(@DEFERRED) == 1,
   '5: first visit: the check is in flight');
my $mark = scalar @EV;
page($LH, 'Ladyhawke');                    # the rebuild
my @rebuild = @EV[$mark .. $#EV];
ok(scalar(gets(@rebuild)) == 0, '5: the rebuild sends nothing');
ok(scalar(grep { $_ eq 'render' } @rebuild) == 1 && !defined $BUILT[-1]{official},
   '5: ... renders at once, unfiltered');
ok(scalar(!grep { /^local / } @rebuild) && scalar(grep { $_ eq 'collabs' } @rebuild) == 1,
   '5: ... and leaves the owned-album lookups to the first visit');
flush();
my @rest = @EV[$mark + scalar(@rebuild) .. $#EV];
ok(scalar(grep { $_ eq 'render' } @rest) == 1 && ref $BUILT[-1]{official} eq 'HASH',
   '5: the first visit then renders, filtered');
ok(scalar(grep { $_ eq "local $OFFPAGE" } @rest) == 1, '5: ... and does the lookup itself');

# ---------------------------------------------------------------------------
# 6. official_wait 0 renders before the check; the deadline renders without it
#    and the check still finishes (and its lookups still run).
# ---------------------------------------------------------------------------
fresh();
$PREF{official_wait} = 0;
page($LH, 'Ladyhawke');
my $r6 = idx(qr/^render$/, @EV);
my $c6 = idx(qr{release-group\?query=}, @EV);
ok($r6 >= 0 && $c6 > $r6, '6: official_wait 0: the page renders BEFORE the check is sent');
ok(scalar(grep { $_ eq "local $OFFPAGE" } @EV) == 1 && $EV[-1] eq 'collabs',
   '6: ... and the check, the lookup and collaborations still follow');

fresh();
$DEFER = 1;
page($LH, 'Ladyhawke');
step();                                    # read answers; check in flight
ok(scalar(@BUILT) == 0 && scalar(@TIMERS) == 1, '6: the deadline is set while the check runs');
$TIMERS[0]->() if @TIMERS;                 # the deadline fires (a broken chain sets none)
ok(scalar(@BUILT) == 1 && !defined $BUILT[0]{official}, '6: the deadline renders without the map');
flush();
ok(scalar(@BUILT) == 1, '6: ... the check landing later does not render again');
ok(defined $CACHE{"dsc:rgo:v5:$LH"} && scalar(grep { $_ eq "local $OFFPAGE" } @EV) == 1,
   '6: ... but caches the map for the next visit, and its lookups run');

# ---------------------------------------------------------------------------
# 7. _unplacedReleases, directly: what the check cannot place, each once.
# ---------------------------------------------------------------------------
my $unpl = $B->can('_unplacedReleases');
my $rgs7 = [ { mbid => 'g1' }, { mbid => 'g2' } ];
my $loc7 = [ { _mbid => 'rel-a' }, { _mbid => 'g2' }, { _mbid => 'rel-b' }, { _mbid => 'rel-b' },
             { _albumid => 9 }, { _mbid => 'rel-c' } ];
ok(join(',', @{ $unpl->($loc7, $rgs7, { 'rel-a' => 'g1', 'rel-c' => 'g-off' }) }) eq 'rel-b',
   '7: a mapped release and a page group id are placed; the rest goes once');
ok(join(',', @{ $unpl->($loc7, $rgs7, undef) }) eq 'rel-a,rel-b,rel-c',
   '7: no map (the check failed): every owned release but the group id goes');
ok(scalar(@{ $unpl->([], $rgs7, {}) }) == 0, '7: nothing owned, nothing to look up');

# ---------------------------------------------------------------------------
# 8. THE FIRST LIST (0.56.7; analysis §A16). Radiohead's read lists 25, so the
#    page asks ListenBrainz and the community API. ListenBrainz: groups 0-28
#    and a group MusicBrainz has since dropped (STALE). The community: groups
#    0-26 (0-24 with an official release, 25 bootleg-only, 26 listed without
#    releases) and one group of its own (CMONLY). MusicBrainz's browse: 0-29.
# ---------------------------------------------------------------------------
my $STALE  = 'eeeeeeee-0000-4000-8000-000000000001';
my $CMONLY = 'eeeeeeee-0000-4000-8000-000000000002';
my @BYID8;
sub fast_responder {
    my ($url) = @_;
    if ($url =~ m{^https://api\.listenbrainz\.org/1/metadata/artist/\?artist_mbids=\Q$RH\E&inc=release_group$}) {
        return [ { artist_mbid => $RH, name => 'Radiohead', release_group => [
            (map { { mbid => $RH_GROUPS[$_], name => "Group $_", type => 'Album', date => '2000' } } 0 .. 28),
            { mbid => $STALE, name => 'Stale', type => 'Album', date => '1999' } ] } ];
    }
    if ($url =~ m{^https://api\.lms-community\.org/music/artist/[^/]+/discography\?mbid=\Q$RH\E&withReleases=1$}) {
        return { mbid => $RH, name => 'Radiohead', discography => [
            (map { { mbid => $RH_GROUPS[$_], title => "Group $_", primary_type => 'Album',
                     release_date => '2000', releases => { "$RH_GROUPS[$_]-r" => 'Official' } } } 0 .. 24),
            { mbid => $RH_GROUPS[25], title => 'Group 25', primary_type => 'Album',
              releases => { "$RH_GROUPS[25]-r" => 'Bootleg' } },
            { mbid => $RH_GROUPS[26], title => 'Group 26', primary_type => 'Album' },
            { mbid => $CMONLY, title => 'Community only', primary_type => 'Album',
              releases => { "$CMONLY-r" => 'Official' } } ] };
    }
    push @BYID8, scalar(() = $url =~ /rgid%3A/g) if $url =~ m{/release-group\?query=};
    return responder($url);
}
fresh();
@BYID8 = ();
$RESPONDER = \&fast_responder;
$LOCAL = [ { _mbid => "$RH_GROUPS[4]-r", _albumid => 1 } ];
page($RH, 'Radiohead');
my @pre8 = gets(upto('render', @EV));
ok(scalar(@pre8) == 4 && $pre8[0] =~ m{/artist/\Q$RH\E\?} && $pre8[1] =~ m{api\.listenbrainz\.org/}
   && $pre8[2] =~ m{api\.lms-community\.org/} && $pre8[3] =~ m{/release-group\?query=},
   '8: before the render: the read, ListenBrainz, the community API, ONE by-id request (no browse)');
ok(($BYID8[0] // 0) == 4,
   "8: ... the by-id request asks only for the 4 groups without the community's verdict");
my %drawn8 = map { $_->{mbid} => 1 } @{ $BUILT[0]{rgs} || [] };
ok(scalar(@BUILT) == 1 && scalar(keys %drawn8) == 31 && $drawn8{$STALE} && $drawn8{$CMONLY} && !$drawn8{ $RH_GROUPS[29] },
   "8: the page is drawn from the two lists together (31 groups)");
my $o8 = $BUILT[0]{official} || {};
ok(($o8->{ $RH_GROUPS[0] } // -1) == 1 && ($o8->{ $RH_GROUPS[25] } // -1) == 0
   && ($o8->{ $RH_GROUPS[27] } // -1) == 1 && ($o8->{$CMONLY} // -1) == 1,
   "8: ... filtered by the community's verdicts and the by-id answers (25 bootleg-only)");
my @post8 = after('render', @EV);
ok(scalar(@post8) == 4 && $post8[0] =~ m{/release-group\?artist=\Q$RH\E&.* \[bg\]$}
   && $post8[1] =~ m{/release-group\?query=.*&limit=30&.* \[bg\]$}
   && $post8[2] eq 'local ' && $post8[3] eq 'collabs',
   '8: AFTER the render: the browse and the by-id check as background work, then the lookups, then collaborations');
my $next8 = $CACHE{"dsc:rgnext:1:$RH"};
my %n8 = map { $_->{mbid} => 1 } @{ $next8 || [] };
ok(ref $next8 eq 'ARRAY' && scalar(@$next8) == 30 && $n8{ $RH_GROUPS[29] } && !$n8{$STALE} && !$n8{$CMONLY},
   "8: MusicBrainz's completed list is stored for the next entry: its 30 (the newest added, what it lacks dropped)");
ok(!defined $CACHE{"dsc:rgfast:1:$RH"} && !defined $CACHE{"dsc:cmdisco:1:$RH"}
   && scalar(@{ $CACHE{"dsc:rg:v2:$RH"} || [] }) == 31,
   '8: ... the first-list markers go, and the drawn list stays for the visit in progress');
ok(($API->peekOfficial($RH)->{ $RH_GROUPS[25] } // -1) == 1 && ($API->peekOfficial($RH)->{$CMONLY} // -1) == 1,
   "8: ... MusicBrainz's verdicts replace the community's where it gave one, the community's stay elsewhere");

@EV = (); @BUILT = ();
page($RH, 'Radiohead');                         # a rebuild (a walk, a toggle): not fresh
ok(scalar(gets(@EV)) == 0 && scalar(@{ $BUILT[0]{rgs} || [] }) == 31 && ref $CACHE{"dsc:rgnext:1:$RH"} eq 'ARRAY',
   '8: a rebuild that is not a fresh entry keeps the drawn list, and sends nothing');
@EV = (); @BUILT = ();
page($RH, 'Radiohead', fresh => 1);             # the next entry
ok(scalar(gets(@EV)) == 0 && scalar(@{ $BUILT[0]{rgs} || [] }) == 30 && !defined $CACHE{"dsc:rgnext:1:$RH"},
   "8: the next fresh entry draws MusicBrainz's completed list, and sends nothing");

# The completion failing keeps the first list's marker, so the next visit tries
# again; a page re-entered meanwhile does not start a second one.
fresh();
$RESPONDER = sub { $_[0] =~ /release-group\?artist=/ ? 'FAIL' : fast_responder($_[0]) };
page($RH, 'Radiohead');
ok(defined $CACHE{"dsc:rgfast:1:$RH"} && !defined $CACHE{"dsc:rgnext:1:$RH"}
   && scalar(grep { /^local / } @EV) == 1,
   '8: a failed completion stores nothing, keeps the marker, and the lookups still run');
fresh();
$RESPONDER = \&fast_responder;
$DEFER = 1;
page($RH, 'Radiohead');
step() for 1 .. 3;                              # read, both lists, the by-id request
my $m8 = scalar @EV;
page($RH, 'Radiohead');                         # re-entered while the completion runs
ok(scalar(grep { /\[bg\]$/ } @EV[$m8 .. $#EV]) == 0,
   '8: a page re-entered while the completion runs does not start another');
flush();

# ---------------------------------------------------------------------------
# 9. A REFRESH takes MusicBrainz's own list, awaited: no ListenBrainz, no
#    community list; the marker is used once.
# ---------------------------------------------------------------------------
fresh();
$RESPONDER = \&fast_responder;
$API->clearArtistCache(mbid => $RH, refresh => 1);
page($RH, 'Radiohead');
my @pre9 = gets(upto('render', @EV));
ok(scalar(@pre9) == 3 && $pre9[1] =~ m{/release-group\?artist=} && !grep({ m{listenbrainz|lms-community} } @pre9),
   '9: after a Refresh: the read, the browse, the check, as before 0.56.7');
ok(!defined $CACHE{"dsc:rgfull:1:$RH"} && !defined $CACHE{"dsc:rgfast:1:$RH"} && !grep({ /\[bg\]$/ } @EV),
   '9: ... the Refresh marker is used up, and nothing is left to complete');
{
    # The page's Refresh row is what sets the marker; no suite drives that row's
    # url, so its call is pinned on the source.
    open my $fh, '<', "$FindBin::Bin/../Discography/Browse.pm" or die $!;
    my $src = do { local $/; <$fh> };
    my ($body) = $src =~ /^(sub _refreshItem \{.*?^\})/ms;
    ok(scalar($body && $body =~ /clearArtistCache\(.*refresh\s*=>\s*1/s),
       "9: the page's Refresh row asks clearArtistCache for MusicBrainz's own list next (refresh => 1)");
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
