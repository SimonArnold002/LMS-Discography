#!/usr/bin/env perl
#
# THE TOP RESULT IS READIED WHILE THE RESULTS ARE READ (0.56.56; Simon,
# 2026-10-07: "may be start to cache the top hit after search? But would need to
# then stop and switch if a different one is picked ... start streaming matching
# sooner and not destroy performance as a use[r] may be playing music at same
# time").
#
# What this pins, on the REAL Browse.pm and API.pm (only the network, the
# timers, the library, the list builder and the streaming plugins replaced):
#   A. API::_fastSpine, ONE FIRST LIST PER ARTIST AT A TIME: a second caller
#      while ListenBrainz's and the community's lists are out sends nothing and
#      is answered from them; a page (foreground) joining a background one
#      moves its requests forward (_netPromote), another background caller does
#      not; every caller is answered under ITS OWN background flag; a failure
#      answers everyone and lets go, also one answered inside _netGet (a
#      backing-off bucket); two artists are two flights;
#   B. Browse::_prefetchTop: the page's own steps in the page's order (the
#      resolver's lookup with the library name, the read-first release groups,
#      _poolOpts, getCandidates, and beside the pool the band lookup then the
#      bootleg check marked `prefetch => 1`, since 0.56.57), every one as
#      background work, and nothing after them (no matching, no render, no
#      covers); an mbid row skips the
#      lookup; it stops at its next step when another artist is opened or a
#      search has another Top Result (or none), and carries on for the same
#      artist and the same results; it leaves alone what the page would not
#      ask (Various Artists, a composer's works page, a warm pool) and a library
#      tag with no release groups (the page's disambiguation);
#   C. a tap on the Top Result while its prefetch runs: the page JOINS it (one
#      artist read, one ListenBrainz and one community request in all), stays
#      foreground after joining (its bootleg check is not background work), and
#      asks the streaming pool with exactly the prefetch's name and options (so
#      Sources::_candFlight answers both from one fetch).
#   D. API::warmOfficial: a prefetch's check is JOINED; a page's is unchanged.
#   E. THE RELEASE-GROUP BROWSE (review 2026-10-08): the prefetch owns it when
#      its first list fails, and a tap on the Top Result joined it, then went
#      on as background work (its pool, its bootleg check, its completion) and
#      read the artist a second time. Each caller is now answered under its
#      own flag, a page joining moves the browse forward (every page of it),
#      and a read-path caller joins a browse started after a read without
#      reading again; one started without a read still gets the page's read.
#
# Standalone -- no LMS install needed:  perl tools/t_prefetch.pl
#
use strict;
use warnings;
use FindBin;
use JSON::PP ();

our (%CACHE, $DATA, @SENT, @DEFERRED, $DEFER, %PREF, @TIMERS, @BUILT, @DBG,
     @PROMOTED, $SYNC_FAIL, %CONTRIB, $SENT_OUT, @COMPLETE, $BROWSE_OK);

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
    *{'Plugins::Discography::Plugin::dbg'} = sub { push @main::DBG, join('', @_) };
    *{'Slim::Utils::Strings::cstring'}     = sub { $_[1] };
    *{'Slim::Utils::Strings::string'}      = sub { $_[0] };
    # Timers are recorded, never fired: no deadline is this suite's subject.
    *{'Slim::Utils::Timers::setTimer'}     = sub { push @main::TIMERS, $_[2]; return };
    *{'Slim::Utils::Timers::killTimers'}   = sub { return };
    *{'Slim::Utils::Timers::killSpecific'} = sub { return };
    *{'Slim::Schema::find'} = sub {
        my ($class, $rs, $id) = @_;
        return defined $main::CONTRIB{ $id // '' } ? bless({ n => $main::CONTRIB{$id} }, 'T::Contrib') : undef;
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
package T::Contrib; sub name { $_[0]{n} }
package T::Client;  sub id { 'c1' }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;
my $API = 'Plugins::Discography::API';
my $B   = 'Plugins::Discography::Browse';
my $S   = 'Plugins::Discography::Sources';

my $RH  = 'a74b1b7f-71a5-4011-9441-d0b5e4122711';
my $OTH = '11111111-2222-3333-4444-555555555555';
sub id { sprintf('%08x-0000-4000-8000-%012x', 0x7000 + $_[0], $_[0]) }
my $READ = do {
    open my $fh, '<:raw', "$FindBin::Bin/fixtures/mb_artist_radiohead_aliases_artistrels_releasegroups.json"
        or die "fixture: $!";
    local $/; JSON::PP::decode_json(scalar <$fh>);
};

# The network: every request recorded with the background flag it went out
# with, and answered (now, or held while $DEFER) UNDER THAT FLAG, as the real
# queue answers a job (API: "A job's callbacks run with $NET_BG set to its own
# flag"). Returns a job, as the real _netGet does.
sub reply_for {
    my ($url) = @_;
    my ($mbid) = $url =~ /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/;
    $mbid = lc($mbid // '');
    return { %$READ, id => $mbid } if $url =~ m{/artist/[0-9a-f-]{36}\?inc=aliases};
    return [ { artist_mbid => $mbid, release_group => [ map {
        { mbid => id($_), name => "G$_", type => 'Album', date => '2000' } } 1 .. 30 ] } ]
        if $url =~ /listenbrainz/;
    # The community: verdicts for 28 of the 30, so the bootleg check asks two by id.
    return { mbid => $mbid, name => 'Radiohead', discography => [ map {
        { mbid => id($_), title => "G$_", primary_type => 'Album', release_date => '2000',
          releases => { "r$_" => 'Official' } } } 1 .. 28 ] }
        if $url =~ /lms-community/;
    # MusicBrainz's release-group browse (section E only): 150 groups, two pages.
    if ($main::BROWSE_OK && $url =~ m{/release-group\?artist=}) {
        my ($off) = $url =~ /offset=(\d+)/;
        $off //= 0;
        my @n = grep { $_ <= 150 } ($off + 1) .. ($off + 100);
        return { 'release-group-count' => 150, 'release-groups' => [ map {
            { id => id($_), title => "G$_", 'primary-type' => 'Album', 'first-release-date' => '2000',
              'secondary-types' => [] } } @n ] };
    }
    if ($url =~ m{/release-group\?query=}) {
        my @ids = $url =~ /rgid%3A([0-9a-f-]+)/g;
        return { count => scalar @ids, 'release-groups' => [ map {
            { id => $_, title => $_, count => 1,
              releases => [ { id => "$_-r", title => 'T', status => 'Official' } ] } } @ids ] };
    }
    return 'FAIL';
}
{
    no strict 'refs'; no warnings 'redefine';
    *{"${API}::_netGet"} = sub {
        my ($url, $ok, $err, %opt) = @_;
        my $bg  = ($opt{background} || $Plugins::Discography::API::NET_BG) ? 1 : 0;
        my $job = { url => $url, background => $bg };
        push @SENT, $job;
        if ($SYNC_FAIL && $url =~ $SYNC_FAIL) {    # a backing-off bucket answers inside the call
            local $Plugins::Discography::API::NET_BG = $bg;
            $err->(T::Resp->new, 'backing off', T::Resp->new);
            return $job;
        }
        my $fire = sub {
            my $r = reply_for($url);
            local $Plugins::Discography::API::NET_BG = $job->{background};
            return $err->(T::Resp->new, 'stub error', T::Resp->new) if !ref $r && $r eq 'FAIL';
            $DATA = $r;
            $ok->(T::Resp->new);
        };
        if ($DEFER) { push @DEFERRED, [ $url, $fire ] } else { $fire->() }
        return $job;
    };
    # The real one moves a queued job; here the job has no queue, so the move
    # is recorded and the flag flipped, which is all a caller can observe. With
    # $SENT_OUT every request is already on the wire: nothing can be recalled,
    # and its answer runs under the background flag it went out with.
    *{"${API}::_netPromote"} = sub {
        my ($job) = @_;
        return if $main::SENT_OUT;
        return unless ref $job eq 'HASH' && $job->{background};
        $job->{background} = 0;
        push @PROMOTED, $job->{url};
    };
    *{"${API}::sharesNameWithProminent"} = sub { 0 };
    *{"${API}::warmCollaborations"}      = sub { };
    *{"${API}::warmLocalReleases"}       = sub { $_[2]->() if $_[2] };
    # The page's after-work, once its check has answered: who ran it, under which flag.
    *{"${API}::completeArtist"}          = sub { push @main::COMPLETE, $Plugins::Discography::API::NET_BG ? 1 : 0 };
    *{"${S}::localAlbums"} = sub { [] };
    *{"${B}::_warmArtistExtras"} = sub { $_[-1]->() };
    *{"${B}::_buildList"} = sub { push @BUILT, $_[2]; return [ { name => 'row', type => 'text' } ] };
}
sub step  { my @d = @DEFERRED; @DEFERRED = (); $_->[1]->() for @d; return scalar @d }
sub step_only {
    my ($re) = @_;
    my @run = grep { $_->[0] =~ $re } @DEFERRED;
    @DEFERRED = grep { $_->[0] !~ $re } @DEFERRED;
    $_->[1]->() for @run;
    return scalar @run;
}
sub flush { for (1 .. 30) { last unless step() } }
sub sent  { my ($re) = @_; scalar grep { $_->{url} =~ $re } @SENT }
sub job   { my ($re) = @_; (grep { $_->{url} =~ $re } @SENT)[0] }

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}
sub section {
    my ($n, $code) = @_;
    eval { $code->(); 1 } or do { (my $e = $@) =~ s/\s+/ /g; ok(0, "$n: the section died: $e") };
}
sub fresh {
    %CACHE = (); @SENT = (); @DEFERRED = (); @TIMERS = (); @BUILT = (); @DBG = ();
    @PROMOTED = (); $DEFER = 0; $SYNC_FAIL = undef; %CONTRIB = (); $SENT_OUT = 0; @COMPLETE = ();
    $BROWSE_OK = 0;
    %PREF = (official_wait => 15, show_bio => 0, hide_unmatched => 0);
    my $fl = $API->can('_rgFlight')->(); $fl->_reset if ref $fl;
    # No prefetch left over from the section before.
    $B->can('_prefetchTop')->(undef, undef);
}
my $LBRE = qr/listenbrainz/;
my $CMRE = qr/lms-community/;

# ---------------------------------------------------------------------------
section('A', sub {
    my $fast = $API->can('_fastSpine');

    # A1. A background owner, a foreground caller joining it.
    fresh(); $DEFER = 1;
    my (@a, @b, $aBg, $bBg);
    {
        local $Plugins::Discography::API::NET_BG = 1;
        $fast->($RH, sub { push @a, shift; $aBg = $Plugins::Discography::API::NET_BG });
    }
    ok(scalar(sent($LBRE) == 1 && sent($CMRE) == 1 && job($LBRE)->{background} && job($CMRE)->{background}),
       'A1: a background caller sends its two lists as background work');
    $fast->($RH, sub { push @b, shift; $bBg = $Plugins::Discography::API::NET_BG });
    ok(scalar(sent($LBRE) == 1 && sent($CMRE) == 1),
       'A1: a second caller while they are out sends NOTHING (it was two more requests each)');
    ok(scalar(@PROMOTED == 2 && !job($LBRE)->{background} && !job($CMRE)->{background}),
       'A1: ... and, being a page (foreground), moves both forward (' . scalar(@PROMOTED) . ' promoted)');
    flush();
    ok(scalar(@a == 1 && @b == 1 && ref $a[0] eq 'ARRAY' && @{ $a[0] } == 30 && $a[0] == $b[0]),
       'A1: both answered once, with the one list (30 groups)');
    ok(scalar($aBg && !$bBg),
       'A1: each answered under its OWN flag: the background caller as background, the page as foreground');
    ok(scalar(!$API->can('_rgFlight')->()->inFlight(lc($RH) . '|first')), 'A1: the claim is released once it lands');

    # A2. A background caller joining a background one moves nothing.
    fresh(); $DEFER = 1;
    {
        local $Plugins::Discography::API::NET_BG = 1;
        $fast->($RH, sub { });
        $fast->($RH, sub { });
    }
    ok(scalar(sent($LBRE) == 1 && !@PROMOTED && job($LBRE)->{background}),
       'A2: a second background caller joins, sends nothing, promotes nothing');
    flush();

    # A3. A failure answers everyone, once, and lets go.
    fresh(); $DEFER = 1;
    my ($n1, $n2, $u1, $u2) = (0, 0);
    {
        no warnings 'redefine';
        my $orig = \&main::reply_for;
        local *main::reply_for = sub { $_[0] =~ $CMRE ? 'FAIL' : $orig->(@_) };
        $fast->($RH, sub { $u1 = shift; $n1++ });
        $fast->($RH, sub { $u2 = shift; $n2++ });
        flush();
    }
    ok(scalar($n1 == 1 && $n2 == 1 && !defined $u1 && !defined $u2),
       'A3: the community failing: both callers told "no list" (each then browses), once');
    ok(scalar(!$API->can('_rgFlight')->()->inFlight(lc($RH) . '|first')), 'A3: ... and the claim is released');
    @SENT = ();
    $fast->($RH, sub { });
    ok(scalar(sent($LBRE) == 1 && sent($CMRE) == 1), 'A3: the next caller asks again (nothing stuck)');
    flush();

    # A4. Answered inside _netGet (a backing-off bucket): no stale claim.
    fresh(); $DEFER = 1; $SYNC_FAIL = $LBRE;
    my $n4 = 0;
    $fast->($RH, sub { $n4++ });
    ok(scalar($n4 == 1), 'A4: a list refused inside the call answers the caller at once');
    $SYNC_FAIL = undef; flush(); @SENT = ();
    my $n5 = 0;
    $fast->($RH, sub { $n5++ });
    ok(scalar(sent($LBRE) == 1 && sent($CMRE) == 1), 'A4: ... and the next caller sends its own (no claim left behind)');
    flush();
    ok(scalar($n5 == 1), 'A4: ... and is answered');

    # A5. Two artists are two flights.
    fresh(); $DEFER = 1;
    $fast->($RH,  sub { });
    $fast->($OTH, sub { });
    ok(scalar(sent($LBRE) == 2 && sent($CMRE) == 2), 'A5: another artist sends its own two');
    flush();
});

# ---------------------------------------------------------------------------
# B. Browse::_prefetchTop, its steps stubbed one level down.
# ---------------------------------------------------------------------------
our (@STEPS, @MBQ, @RGQ, @POOLQ, @CANDQ, $COLD, $RGS, $TAG, $COMPOSER, @BANDQ, @CHECKQ, $HOLD_BANDS);
sub row { my (%p) = @_; return { name => $p{artist}, itemActions => { items => { command => ['discography', 'items'],
                                                   fixedParams => { %p } } } } }
sub stubs {
    no strict 'refs'; no warnings 'redefine';
    *{"${API}::getArtistMbid"} = sub {
        my ($class, %a) = @_;
        push @STEPS, 'lookup'; push @MBQ, { %a, bg => $Plugins::Discography::API::NET_BG ? 1 : 0 };
    };
    *{"${API}::getReleaseGroups"} = sub {
        my ($class, %a) = @_;
        push @STEPS, 'rgs'; push @RGQ, { %a, bg => $Plugins::Discography::API::NET_BG ? 1 : 0 };
    };
    *{"${S}::peekPool"} = sub { push @STEPS, 'peek'; { cold => $COLD } };
    *{"${B}::_poolOpts"} = sub {
        my ($artist, $mbid, $spine, $cb) = @_;
        push @STEPS, 'poolopts'; push @POOLQ, [ $artist, $mbid, join(',', sort keys %{ $spine || {} }) ];
        $cb->({ spine => $spine, mbid => $mbid, ambiguous => 0 });
    };
    *{"${S}::getCandidates"} = sub {
        my ($class, $client, $artist, $force, $cb, $opt) = @_;
        push @STEPS, 'pool'; push @CANDQ, [ $client, $artist, $force, $opt, $cb ];
    };
    *{"${API}::isVarious"} = sub { defined $_[2] && lc $_[2] eq '89ad4ac3-39f7-470e-963a-56509c546377' ? 1 : 0 };
    *{'Plugins::Discography::Classical::composer'} = sub { $main::COMPOSER && lc($_[1] // '') eq $main::COMPOSER ? {} : undef };
    # The band lookup answers at once (a cache hit after the read) unless held.
    *{"${API}::warmBandMembers"} = sub {
        my ($class, $mbid, $cb) = @_;
        push @STEPS, 'bands';
        return push @BANDQ, $cb if $main::HOLD_BANDS;
        $cb->();
    };
    *{"${API}::warmOfficial"} = sub {
        my ($class, $mbid, $rgs, $cb, %opt) = @_;
        push @STEPS, 'check';
        push @CHECKQ, { mbid => $mbid, rgs => $rgs, cb => $cb, opt => { %opt },
                        bg => $Plugins::Discography::API::NET_BG ? 1 : 0 };
    };
}
sub bfresh { fresh(); @STEPS = (); @MBQ = (); @RGQ = (); @POOLQ = (); @CANDQ = (); $COLD = 1;
             $RGS = [ { mbid => id(1), title => 'OK Computer' }, { mbid => id(2), title => 'Kid A' } ];
             $COMPOSER = undef; @BANDQ = (); @CHECKQ = (); $HOLD_BANDS = 0 }
sub pre    { $B->can('_prefetchTop')->(@_) }
sub yield  { $B->can('_prefetchYield')->(@_) }
sub mb_ans { my $q = shift @MBQ or die "no lookup was asked\n"; $q->{onDone}->(@_) }
sub rg_ans { my $q = shift @RGQ or die "no release groups were asked\n"; $q->{onDone}->(@_) }
my $CL = bless {}, 'T::Client';

section('B', sub {
    no strict 'refs'; no warnings 'redefine';
    local *{"${API}::getArtistMbid"}; local *{"${API}::getReleaseGroups"}; local *{"${S}::peekPool"};
    local *{"${B}::_poolOpts"}; local *{"${S}::getCandidates"}; local *{"${API}::isVarious"};
    local *{'Plugins::Discography::Classical::composer'};
    local *{"${API}::warmBandMembers"}; local *{"${API}::warmOfficial"};
    stubs();

    # B1. An owned search row: the page's steps, in its order, all background.
    bfresh(); %CONTRIB = (7 => 'Radiohead (library)');
    pre($CL, row(artist => 'Radiohead', artist_id => 7));
    ok(scalar("@STEPS" eq 'lookup' && $MBQ[0]{artist_id} == 7 && $MBQ[0]{artist} eq 'Radiohead (library)'
              && $MBQ[0]{fetch} == 15),
       "B1: first the resolver's lookup, as the page asks it: library id, the LIBRARY's name, 15 entries");
    mb_ans($RH, 0);
    ok(scalar("@STEPS" eq 'lookup rgs' && $RGQ[0]{mbid} eq $RH && $RGQ[0]{read}),
       'B1: then the release groups, the read first (read => 1), as the page asks them');
    rg_ans($RGS);
    ok(scalar("@STEPS" eq 'lookup rgs peek poolopts pool bands check'),
       'B1: then the pool (only when cold: _poolOpts, getCandidates), and beside it the band lookup, then the bootleg check');
    ok(scalar($POOLQ[0][0] eq 'Radiohead (library)' && $POOLQ[0][1] eq $RH && $POOLQ[0][2] eq 'kid a,ok computer'),
       "B1: _poolOpts gets the page's own inputs: the name, the mbid, the spine titles");
    ok(scalar($CANDQ[0][0] == $CL && $CANDQ[0][1] eq 'Radiohead (library)' && $CANDQ[0][2] == 0
              && ref $CANDQ[0][3] eq 'HASH' && $CANDQ[0][3]{mbid} eq $RH),
       "B1: getCandidates as the page calls it: the player, the name, not forced, _poolOpts' options");
    ok(scalar(@CHECKQ == 1 && $CHECKQ[0]{mbid} eq $RH && $CHECKQ[0]{rgs} == $RGS
              && $CHECKQ[0]{opt}{prefetch} && $CHECKQ[0]{bg}),
       "B1: the bootleg check as the page asks it (the mbid, the page's list), marked as a prefetch's, as background work");
    $CANDQ[0][4]->();
    ok(scalar(!grep { /: ready/ } @DBG), 'B1: the pool alone is not "ready": the check is still out');
    $CHECKQ[0]{cb}->();
    ok(scalar(grep { /prefetch of 'Radiohead \(library\)': ready \(streaming took .*; bootleg check took/ } @DBG),
       'B1: both answered: the log says it is ready, with both times');
    ok(scalar(@STEPS == 7), 'B1: and nothing after them: no owned-album lookups, no completion, no render');

    bfresh(); %CONTRIB = (7 => 'Radiohead');
    pre($CL, row(artist => 'Radiohead', artist_id => 7));
    my $lookBg = $MBQ[0]{bg};
    mb_ans($RH, 0);
    my $rgBg = $RGQ[0]{bg};
    ok(scalar($lookBg && $rgBg), 'B1: every step is asked as BACKGROUND work (the lookup, the release groups)');

    # B2. A MusicBrainz act's row: by its mbid, no lookup.
    bfresh();
    pre($CL, row(artist => 'Jandek', mbid => uc $OTH));
    ok(scalar("@STEPS" eq 'rgs' && $RGQ[0]{mbid} eq $OTH), 'B2: an mbid row skips the lookup (lower-cased, as the page)');

    # B3. Another artist opened between steps: it stops at the next.
    bfresh();
    pre($CL, row(artist => 'Radiohead'));
    yield(undef, 'Portishead', undef);
    mb_ans($RH, 0);
    ok(scalar("@STEPS" eq 'lookup'), 'B3: another artist opened during the lookup: no release groups are asked');
    ok(scalar(grep { /stopped - another artist was opened/ } @DBG), 'B3: ... and the log says why');
    bfresh();
    pre($CL, row(artist => 'Radiohead'));
    mb_ans($RH, 0);
    yield(5, 'Massive Attack', undef);
    rg_ans($RGS);
    ok(scalar("@STEPS" eq 'lookup rgs'), 'B3: another artist opened during the release groups: no pool, no check');
    bfresh(); $HOLD_BANDS = 1;
    pre($CL, row(artist => 'Radiohead', mbid => $RH));
    rg_ans($RGS);
    yield(undef, 'Portishead', undef);
    (shift @BANDQ)->();
    ok(scalar("@STEPS" eq 'rgs peek poolopts pool bands' && !@CHECKQ),
       'B3: another artist opened during the band lookup: no bootleg check');

    # B4. The same artist opened: it carries on (by name, by library id, by mbid).
    for my $w ([ undef, 'radiohead', undef, 'by name, any case' ], [ 7, 'Radiohead (library)', undef, 'by library id' ],
               [ undef, 'RH', uc $RH, 'by mbid' ]) {
        bfresh(); %CONTRIB = (7 => 'Radiohead');
        pre($CL, row(artist => 'Radiohead', artist_id => 7, ($w->[2] ? (mbid => $RH) : ())));
        yield(@$w[0 .. 2]);
        mb_ans($RH, 0) if @MBQ;
        rg_ans($RGS);
        ok(scalar("@STEPS" =~ /pool bands check$/), "B4: the same artist opened ($w->[3]): it carries on to the pool and the check");
    }

    # B5. A new search: the same results carry on; another Top Result, or none, stops it.
    bfresh();
    pre($CL, row(artist => 'Radiohead'));
    pre($CL, row(artist => 'Radiohead'));
    ok(scalar("@STEPS" eq 'lookup'), 'B5: the same results again (a view refresh): not started twice');
    pre($CL, row(artist => 'Portishead'));
    ok(scalar(@MBQ == 2 && $MBQ[1]{artist} eq 'Portishead'), 'B5: another Top Result: its own lookup');
    mb_ans($RH, 0);
    ok(scalar("@STEPS" eq 'lookup lookup'), "B5: ... and the first one's answer leads nowhere");
    mb_ans($OTH, 0);
    ok(scalar("@STEPS" eq 'lookup lookup rgs' && $RGQ[0]{mbid} eq $OTH), 'B5: ... while the new one goes on');
    bfresh();
    pre($CL, row(artist => 'Radiohead'));
    pre($CL, undef);
    mb_ans($RH, 0);
    ok(scalar("@STEPS" eq 'lookup'), 'B5: a search that found nothing stops it too');
    bfresh();
    pre($CL, { name => 'PLUGIN_DISCOGRAPHY_SEARCH_NONE', type => 'text' });
    ok(scalar(!@STEPS), 'B5: a text row (no tap params) starts nothing');

    # B6. What the page would not ask, the prefetch does not either.
    bfresh();
    pre(undef, row(artist => 'Radiohead'));
    ok(scalar(!@STEPS), 'B6: no player: nothing (the streaming plugins need one, as the page says)');
    bfresh();
    pre($CL, row(artist => 'Various', mbid => '89ad4ac3-39f7-470e-963a-56509c546377'));
    ok(scalar(!@STEPS), 'B6: Various Artists: nothing (its page asks nothing)');
    bfresh(); $COMPOSER = lc $OTH;
    pre($CL, row(artist => 'Bach', mbid => $OTH));
    ok(scalar(!@STEPS), "B6: a composer: nothing (his works page asks nothing)");
    bfresh(); $COLD = 0;
    pre($CL, row(artist => 'Radiohead', mbid => $RH));
    rg_ans($RGS);
    ok(scalar("@STEPS" eq 'rgs peek bands check'), 'B6: a pool already held: no streaming request (the check still runs)');
    $CHECKQ[0]{cb}->();
    ok(scalar(grep { /ready \(streaming already resolved; bootleg check took/ } @DBG),
       'B6: ... and it is ready once the check answers');
    bfresh();
    pre($CL, row(artist => 'Radiohead', mbid => $RH));
    rg_ans($RGS);
    $CHECKQ[0]{cb}->('failed');
    $CANDQ[0][4]->();
    ok(scalar(grep { /ready \(streaming took .*; bootleg check FAILED after/ } @DBG),
       'B6: a failed check is said so in the log (the page asks again: nothing was cached)');
    bfresh();
    pre($CL, row(artist => 'The Bees', artist_id => 9));
    mb_ans($OTH, 1);
    rg_ans([]);
    ok(scalar("@STEPS" eq 'lookup rgs'),
       "B6: a library tag with no release groups: left to the page (its disambiguation browses other acts)");
    bfresh();
    pre($CL, row(artist => 'Nobody'));
    mb_ans(undef, 0);
    ok(scalar("@STEPS" eq 'lookup'), 'B6: no MusicBrainz artist: stops');
    bfresh();
    pre($CL, row(artist => 'Radiohead', mbid => $RH));
    $RGQ[0]{onError}->('x');
    ok(scalar("@STEPS" eq 'rgs'), 'B6: no release groups (an error): stops');
    bfresh();
    pre($CL, row(artist => 'Zero', mbid => $OTH));
    rg_ans([]);
    ok(scalar("@STEPS" eq 'rgs peek poolopts pool bands check'),
       'B6: control: a name-resolved artist with no groups still gets its pool and check, as the page asks them');

    # B7. Done means done: a later page for another artist is not a "stop".
    bfresh();
    pre($CL, row(artist => 'Radiohead', mbid => $RH));
    rg_ans($RGS);
    $CANDQ[0][4]->();
    $CHECKQ[0]{cb}->();
    $CANDQ[0][4]->();    # a service answering twice
    ok(scalar(grep({ /: ready/ } @DBG) == 1), 'B7: "ready" is said once, whatever answers again');
    @DBG = ();
    yield(undef, 'Portishead', undef);
    ok(scalar(!grep { /stopped/ } @DBG), 'B7: once ready, opening another artist stops nothing');
    fresh();
});

# ---------------------------------------------------------------------------
# C. A tap on the Top Result while its prefetch runs: the REAL chain both ways.
# ---------------------------------------------------------------------------
section('C', sub {
    no strict 'refs'; no warnings 'redefine';
    my (@cands);
    local *{"${S}::peekPool"} = sub { { cold => 1 } };
    local *{"${S}::getCandidates"} = sub {
        my ($class, $client, $artist, $force, $cb, $opt) = @_;
        push @cands, { artist => $artist, opt => $opt, cb => $cb,
                       bg => $Plugins::Discography::API::NET_BG ? 1 : 0 };
    };
    local *{"${API}::getArtistCandidates"} = sub { $_[2]->([ { mbid => $RH, name => 'Radiohead' } ]) };

    fresh(); @cands = (); $DEFER = 1;
    pre($CL, row(artist => 'Radiohead', mbid => $RH));
    ok(scalar(@SENT == 1 && $SENT[0]{url} =~ m{/artist/\Q$RH\E\?} && $SENT[0]{background}),
       'C: the prefetch reads the artist, as background work');
    step();    # the read lands; the two lists go out
    ok(scalar(sent($LBRE) == 1 && sent($CMRE) == 1 && job($LBRE)->{background}),
       'C: then the two lists, as background work');

    # The tap arrives while they are out.
    my $got;
    $B->can('_discographyView')->($CL, sub { $got = shift },
        { mbid => $RH, artist => 'Radiohead', fresh => 1, force => 0 });
    ok(scalar(sent(qr{/ws/2/artist/}) == 1 && sent($LBRE) == 1 && sent($CMRE) == 1),
       'C: the page JOINS: still one artist read, one ListenBrainz and one community request');
    ok(scalar(!job($LBRE)->{background} && !job($CMRE)->{background}),
       "C: ... and the prefetch's lists, still queued, now go out as the page's (promoted)");
    flush();
    ok(scalar(@cands == 2), 'C: the prefetch and the page both ask for the pool (' . scalar(@cands) . ')');
    ok(scalar(@cands == 2 && $cands[0]{artist} eq $cands[1]{artist}
              && JSON::PP->new->canonical->encode($cands[0]{opt}) eq JSON::PP->new->canonical->encode($cands[1]{opt})),
       "C: ... with the SAME name and options, so the pool's flight answers both from one fetch");
    my $byid = job(qr{release-group\?query=});
    ok(scalar(sent(qr{release-group\?query=}) == 1 && $byid && !$byid->{background}),
       "C: ONE bootleg check in all: the page joined the prefetch's, and moved it forward");
    ok(scalar(defined $API->peekOfficial($RH)), 'C: ... and it has landed (the map is cached)');
    ok(scalar(!$got), 'C: the page waits for its pool (cold)');
    $_->{cb}->() for @cands;
    flush();
    ok(scalar(ref $got eq 'HASH' && @BUILT == 1), 'C: and draws once it lands');
    ok(scalar(@COMPLETE == 1 && !$COMPLETE[0]),
       "C: the after-work (the completion) runs ONCE, the page's, as the page's (the prefetch does none)");

    # The prefetch's lists already on the wire (nothing to recall): their answer
    # runs as background work, and the page must still go on as a page.
    fresh(); @cands = (); $DEFER = 1; undef $got;
    pre($CL, row(artist => 'Radiohead', mbid => $RH));
    step();
    $SENT_OUT = 1;
    $B->can('_discographyView')->($CL, sub { $got = shift },
        { mbid => $RH, artist => 'Radiohead', fresh => 1, force => 0 });
    ok(scalar(sent($LBRE) == 1 && job($LBRE)->{background} && !@PROMOTED),
       "C: lists already sent: the page still joins them (they stay background work, nothing to recall)");
    flush();
    my $byid2 = job(qr{release-group\?query=});
    ok(scalar(sent(qr{release-group\?query=}) == 1 && $byid2 && $byid2->{background}),
       "C: ... the page joins the prefetch's check too (one request, background: nothing to recall)");
    ok(scalar(@cands == 2 && grep({ !$_->{bg} } @cands) == 1),
       "C: ... of the two pool requests, the page's is the foreground one");
    ok(scalar(@COMPLETE == 1 && !$COMPLETE[0]),
       "C: ... and the check, landing as background work, hands the page its answer as the PAGE's (after-work foreground, once)");
    $_->{cb}->() for @cands;
    flush();
    ok(scalar(ref $got eq 'HASH'), 'C: ... and the page draws');

    # Earlier: the tap during the prefetch's artist read joins the read itself.
    fresh(); @cands = (); $DEFER = 1; undef $got;
    pre($CL, row(artist => 'Radiohead', mbid => $RH));
    $B->can('_discographyView')->($CL, sub { $got = shift },
        { mbid => $RH, artist => 'Radiohead', fresh => 1, force => 0 });
    ok(scalar(sent(qr{/ws/2/artist/}) == 1 && !job(qr{/ws/2/artist/})->{background}),
       "C: a tap during the prefetch's artist read joins it, and moves it forward");
    flush();
    ok(scalar(sent($LBRE) == 1 && sent($CMRE) == 1 && @cands == 2 && sent(qr{release-group\?query=}) == 1),
       'C: ... then one ListenBrainz, one community and one bootleg request for both, and both ask for the pool');
    $_->{cb}->() for @cands;
    flush();
    ok(scalar(ref $got eq 'HASH'), 'C: ... and the page draws');

    # Control: the same tap with no prefetch takes the same requests, foreground.
    fresh(); @cands = (); $DEFER = 1; undef $got;
    $B->can('_discographyView')->($CL, sub { $got = shift },
        { mbid => $RH, artist => 'Radiohead', fresh => 1, force => 0 });
    flush();
    ok(scalar(sent(qr{/ws/2/artist/}) == 1 && sent($LBRE) == 1 && sent($CMRE) == 1
              && !grep { $_->{background} } grep { $_->{url} =~ m{/artist/|listenbrainz|lms-community|query=} } @SENT),
       'C: control: with no prefetch, the page sends the same three and its check, all foreground');
    $_->{cb}->() for @cands;
    flush();
    ok(scalar(@COMPLETE == 1 && !$COMPLETE[0]), 'C: control: ... and its after-work once, foreground');
});

# ---------------------------------------------------------------------------
# D. API::warmOfficial: a prefetch's check is JOINED; a page's is unchanged.
# ---------------------------------------------------------------------------
section('D', sub {
    my $ids = sub { [ map { { mbid => id($_), title => "G$_" } } 1 .. $_[0] ] };
    my $q   = qr{release-group\?query=};
    my $bgNow = sub { $Plugins::Discography::API::NET_BG ? 1 : 0 };

    # D1. A page arriving during a prefetch's check waits for it.
    fresh(); $DEFER = 1;
    my (@own, @pg);
    { local $Plugins::Discography::API::NET_BG = 1;
      $API->warmOfficial($RH, $ids->(3), sub { push @own, [@_] }, prefetch => 1); }
    ok(scalar(sent($q) == 1 && job($q)->{background}), "D1: a prefetch's check: one by-id request, background");
    $API->warmOfficial($RH, $ids->(3), sub { push @pg, [@_] });
    ok(scalar(sent($q) == 1 && !@pg), "D1: a page arriving joins it: no second request, and no 'busy' - it waits");
    ok(scalar(!job($q)->{background} && @PROMOTED == 1), 'D1: ... and moves the queued request forward');
    flush();
    ok(scalar(@own == 1 && !@{ $own[0] } && @pg == 1 && !@{ $pg[0] }),
       'D1: both answered once, as a check done (no argument): the page draws filtered and does its after-work');
    ok(scalar(defined $API->peekOfficial($RH)), 'D1: the map is cached');

    # D2. Landing as background work: the first page gets its answer under its own
    # flag; a second page (a rebuild while it waited) gets 'busy', after the landing.
    fresh(); $DEFER = 1; $SENT_OUT = 1;
    my (@a, @b, $aBg);
    { local $Plugins::Discography::API::NET_BG = 1;
      $API->warmOfficial($RH, $ids->(3), sub { }, prefetch => 1); }
    $API->warmOfficial($RH, $ids->(3), sub { push @a, [@_]; $aBg = $bgNow->() });
    $API->warmOfficial($RH, $ids->(3), sub { push @b, [@_] });
    ok(scalar(!@a && !@b), "D2: two pages wait (neither is told 'busy' at once)");
    flush();
    ok(scalar(@a == 1 && !@{ $a[0] } && defined $aBg && !$aBg),
       "D2: the first: answered as a check done, under ITS flag (foreground), though the reply came in as background work");
    ok(scalar(@b == 1 && ($b[0][0] // '') eq 'busy'),
       "D2: the second: 'busy' once it lands (it draws filtered; the after-work stays the first's, as for a page's check)");

    # D3. A failure: nothing cached, every waiter told, the claim let go.
    fresh(); $DEFER = 1;
    {
        no warnings 'redefine';
        my $orig = \&main::reply_for;
        local *main::reply_for = sub { $_[0] =~ $q ? 'FAIL' : $orig->(@_) };
        my (@o, @p1, @p2);
        { local $Plugins::Discography::API::NET_BG = 1;
          $API->warmOfficial($RH, $ids->(3), sub { push @o, [@_] }, prefetch => 1); }
        $API->warmOfficial($RH, $ids->(3), sub { push @p1, [@_] });
        $API->warmOfficial($RH, $ids->(3), sub { push @p2, [@_] });
        flush();
        ok(scalar(($o[0][0] // '') eq 'failed' && ($p1[0][0] // '') eq 'failed' && ($p2[0][0] // '') eq 'busy'
                  && @o == 1 && @p1 == 1 && @p2 == 1),
           "D3: a failed check: the prefetch and the first page told 'failed' (it does every owned lookup), the second 'busy'");
        ok(scalar(!defined $API->peekOfficial($RH)), 'D3: nothing cached');
    }
    @SENT = ();
    my $n = 0;
    $API->warmOfficial($RH, $ids->(3), sub { $n++ });
    ok(scalar(sent($q) == 1), 'D3: the next caller asks again (the claim was let go)');
    flush();
    ok(scalar($n == 1), 'D3: ... and is answered');

    # D4. A PAGE's own check is unchanged: a second caller is told 'busy' at once.
    fresh(); $DEFER = 1;
    my @x;
    $API->warmOfficial($RH, $ids->(3), sub { push @x, [ 'first', @_ ] });
    $API->warmOfficial($RH, $ids->(3), sub { push @x, [ 'second', @_ ] });
    ok(scalar(@x == 1 && $x[0][0] eq 'second' && ($x[0][1] // '') eq 'busy' && sent($q) == 1),
       "D4: a page's check: a second caller gets 'busy' AT ONCE, as before");
    flush();
    ok(scalar(@x == 2 && $x[1][0] eq 'first' && !defined $x[1][1]), 'D4: ... and the first gets its answer');

    # D5. Two requests (150 groups): a page joining during the first sends the
    # second as the page's.
    fresh(); $DEFER = 1;
    { local $Plugins::Discography::API::NET_BG = 1;
      $API->warmOfficial($RH, $ids->(150), sub { }, prefetch => 1); }
    ok(scalar(sent($q) == 1), 'D5: 150 groups: the first of two requests');
    $API->warmOfficial($RH, $ids->(150), sub { });
    step();
    my @bq = grep { $_->{url} =~ $q } @SENT;
    ok(scalar(@bq == 2 && !$bq[0]{background} && !$bq[1]{background}),
       'D5: the first moved forward, and the second goes out as the page\'s too');
    flush();

    # D6. A background caller joining moves nothing.
    fresh(); $DEFER = 1;
    { local $Plugins::Discography::API::NET_BG = 1;
      $API->warmOfficial($RH, $ids->(3), sub { }, prefetch => 1);
      $API->warmOfficial($RH, $ids->(3), sub { }); }
    ok(scalar(!@PROMOTED && job($q)->{background}), 'D6: a background caller joins without moving anything forward');
    flush();
    fresh();
});

# ---------------------------------------------------------------------------
# E. The release-group browse: each caller under its own flag, a page joining
#    moves it forward, and a tap during the prefetch's browse neither reads
#    the artist again nor goes on as background work (review 2026-10-08).
# ---------------------------------------------------------------------------
section('E', sub {
    no strict 'refs'; no warnings 'redefine';
    my $BR   = qr{/release-group\?artist=};
    my $BR0  = qr{/release-group\?artist=.*offset=0};
    my $CK   = qr{release-group\?query=};
    my $READ = qr{/ws/2/artist/};
    my $bgNow = sub { $Plugins::Discography::API::NET_BG ? 1 : 0 };
    my $brs   = sub { grep { $_->{url} =~ $BR } @SENT };

    # E1. The flight itself: a background owner, a page joining.
    fresh(); $DEFER = 1; $BROWSE_OK = 1;
    my (@o, @p);
    { local $Plugins::Discography::API::NET_BG = 1;
      $API->getReleaseGroups(mbid => $RH, onDone => sub { push @o, [ scalar(@{ $_[0] }), $bgNow->() ] }); }
    ok(scalar(sent($BR) == 1 && job($BR)->{background}), 'E1: a background caller browses, as background work');
    $API->getReleaseGroups(mbid => $RH, onDone => sub { push @p, [ scalar(@{ $_[0] }), $bgNow->() ] });
    ok(scalar(sent($BR) == 1), 'E1: a page arriving joins it: no second request');
    ok(scalar(!job($BR)->{background} && grep({ $_ =~ $BR } @PROMOTED) == 1),
       'E1: ... and moves its queued request forward');
    step();
    my @br = $brs->();
    ok(scalar(@br == 2 && !$br[1]{background}), "E1: the browse's next page goes out as the page's (foreground)");
    flush();
    ok(scalar(@o == 1 && @p == 1 && $o[0][0] == 150 && $p[0][0] == 150), 'E1: both answered once, with the whole list');
    ok(scalar(@o && @p && $o[0][1] == 1 && $p[0][1] == 0),
       'E1: each under ITS OWN flag: the background caller as background work, the page as a page');

    # E1b. The first page already on the wire: nothing to recall, but the page
    # waiting moves the next one forward as soon as it is asked.
    fresh(); $DEFER = 1; $BROWSE_OK = 1; @p = ();
    { local $Plugins::Discography::API::NET_BG = 1;
      $API->getReleaseGroups(mbid => $RH, onDone => sub { }); }
    $SENT_OUT = 1;
    $API->getReleaseGroups(mbid => $RH, onDone => sub { push @p, $bgNow->() });
    ok(scalar(job($BR)->{background} && !@PROMOTED), 'E1b: page 1 already sent: it stays as it went (nothing to recall)');
    $SENT_OUT = 0;
    step();
    @br = $brs->();
    ok(scalar(@br == 2 && !$br[1]{background} && @PROMOTED == 1),
       'E1b: ... and page 2, asked as background work from page 1\'s answer, is moved forward at once');
    flush();
    ok(scalar(@p == 1 && !$p[0]), 'E1b: the page answered as a page');

    # E1c. A background caller joining moves nothing, and a page owning the
    # browse does not hand a background joiner its foreground flag.
    fresh(); $DEFER = 1; $BROWSE_OK = 1; @o = ();
    { local $Plugins::Discography::API::NET_BG = 1;
      $API->getReleaseGroups(mbid => $RH, onDone => sub { });
      $API->getReleaseGroups(mbid => $RH, onDone => sub { }); }
    ok(scalar(!@PROMOTED && job($BR)->{background}), 'E1c: a background caller joining moves nothing forward');
    flush();
    fresh(); $DEFER = 1; $BROWSE_OK = 1; @o = ();
    $API->getReleaseGroups(mbid => $RH, onDone => sub { });
    { local $Plugins::Discography::API::NET_BG = 1;
      $API->getReleaseGroups(mbid => $RH, onDone => sub { push @o, $bgNow->() }); }
    flush();
    ok(scalar(@o == 1 && $o[0] == 1), "E1c: a background caller joining a page's browse is answered as background work");

    # E1d. A failed browse: every caller told, each under its own flag.
    fresh(); $DEFER = 1;           # $BROWSE_OK off: the browse fails
    my (@oe, @pe);
    { local $Plugins::Discography::API::NET_BG = 1;
      $API->getReleaseGroups(mbid => $RH, onDone => sub { }, onError => sub { push @oe, $bgNow->() }); }
    $API->getReleaseGroups(mbid => $RH, onDone => sub { }, onError => sub { push @pe, $bgNow->() });
    flush();
    ok(scalar(@oe == 1 && @pe == 1 && $oe[0] == 1 && $pe[0] == 0),
       'E1d: a failed browse: both told once, the background caller as background work, the page as a page');

    # E2. THE TAP DURING THE PREFETCH'S BROWSE (the chain both ways).
    my @cands;
    local *{"${S}::peekPool"} = sub { { cold => 1 } };
    local *{"${S}::getCandidates"} = sub {
        my ($class, $client, $artist, $force, $cb, $opt) = @_;
        push @cands, { cb => $cb, bg => $bgNow->() };
    };
    fresh(); $DEFER = 1; $BROWSE_OK = 1; @cands = ();
    $SYNC_FAIL = $CMRE;            # the community backing off (after a search's row check)
    my $got;
    pre($CL, row(artist => 'Radiohead', mbid => $RH));
    step();                        # the read lands; ListenBrainz out, the community fails at once
    ok(scalar(sent($BR0) == 1 && job($BR)->{background}),
       "E2: the first list failed: the prefetch browses MusicBrainz, as background work");
    $B->can('_discographyView')->($CL, sub { $got = shift },
        { mbid => $RH, artist => 'Radiohead', fresh => 1, force => 0 });
    ok(scalar(sent($READ) == 1), 'E2: the tap joins the browse without reading the artist again (it read twice)');
    ok(scalar(sent($BR0) == 1 && !job($BR)->{background}), "E2: ... one browse, moved forward (the page's now)");
    flush();
    ok(scalar(sent($READ) == 1 && sent($LBRE) == 1 && sent($CMRE) == 1),
       'E2: all done: one artist read, one ListenBrainz and one community request in all (the first list not asked again)');
    ok(scalar(sent($BR0) == 1 && !grep { $_->{background} } $brs->()), 'E2: every page of it the page\'s');
    ok(scalar(@cands == 2 && grep({ !$_->{bg} } @cands) == 1),
       "E2: of the two pool requests, the page's is foreground (it was background)");
    my @ck = grep { $_->{url} =~ $CK } @SENT;
    ok(scalar(@ck && !grep { $_->{background} } @ck),
       'E2: the bootleg check the page waits on is foreground: it joined the prefetch\'s and moved it forward (it was background)');
    ok(scalar(@COMPLETE == 1 && !$COMPLETE[0]), "E2: the after-work runs once, as the page's (it ran as background work)");
    $_->{cb}->() for @cands;
    flush();
    ok(scalar(ref $got eq 'HASH'), 'E2: the page draws');

    # E3. Control: a browse started WITHOUT a read (the release page's way):
    # the page still reads the artist, then joins it.
    fresh(); $DEFER = 1; $BROWSE_OK = 1; @cands = (); undef $got;
    $SYNC_FAIL = $CMRE;
    { local $Plugins::Discography::API::NET_BG = 1;
      $API->getReleaseGroups(mbid => $RH, onDone => sub { }); }
    $B->can('_discographyView')->($CL, sub { $got = shift },
        { mbid => $RH, artist => 'Radiohead', fresh => 1, force => 0 });
    ok(scalar(sent($READ) == 1 && !job($READ)->{background}),
       'E3: a browse started without a read: the page still reads the artist (its aliases, name and bands are owed)');
    flush();
    ok(scalar(sent($BR0) == 1), 'E3: ... and then joins that browse (one browse in all)');
    ok(scalar(@cands == 1 && !$cands[0]{bg} && @COMPLETE == 1 && !$COMPLETE[0]),
       "E3: ... and goes on as the page: its pool and after-work foreground");
    $_->{cb}->() for @cands;
    flush();
    ok(scalar(ref $got eq 'HASH'), 'E3: the page draws');

    # E4. A browse whose claim was let go (the registry's watchdog) is not
    # joined by its stale record: the page reads, as with no browse at all.
    fresh(); $DEFER = 1; $BROWSE_OK = 1; @cands = (); undef $got;
    $SYNC_FAIL = $CMRE;
    pre($CL, row(artist => 'Radiohead', mbid => $RH));
    step();
    ok(scalar(sent($BR0) == 1), "E4: (the prefetch browses after its read)");
    $API->can('_rgFlight')->()->_reset;
    $B->can('_discographyView')->($CL, sub { $got = shift },
        { mbid => $RH, artist => 'Radiohead', fresh => 1, force => 0 });
    ok(scalar(sent($READ) == 2), 'E4: its claim let go: the page reads the artist itself');
    flush();
    $_->{cb}->() for @cands;
    flush();
    ok(scalar(ref $got eq 'HASH'), 'E4: ... and draws');
    fresh();
});

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
