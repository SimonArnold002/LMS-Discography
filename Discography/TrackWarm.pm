package Plugins::Discography::TrackWarm;

# THE TRACK MATCH'S LIBRARY PASS (0.56.62). The track match (Browse::_placements)
# puts an untagged owned album that no title claims on the one release whose
# tracklist it carries. 0.56.61 asked ListenBrainz for those tracklists on the
# page, before the draw, and the draw waited: measured live 2026-10-08, a slow
# ListenBrainz held Thievery Corporation's page 8.5 s past its bootleg check,
# and a first visit asked for albums the check then placed by id (Kraftwerk, 9
# tracklists). Simon: "We cant afford hangups but also cant slow things down",
# and not "so much being done on 2nd visits this will confuse users".
#
# THE ANSWER DEPENDS ON THE LIBRARY, NOT ON THE VISIT, so it is worked out before
# the visit and kept. This pass finds the artists whose library holds an album
# with no MusicBrainz release id (only those can need the track match; a tagged
# album is placed by its id), works out each one's page the page's own way
# (getArtistMbid, localAlbums, _placements over the page's groups, or
# ListenBrainz's list when no page has kept them yet) and asks ListenBrainz for
# the candidate groups' tracklists. They are kept in DB.pm's `keep` table, which
# a build does not empty. The page then only reads them: no request, no wait,
# the same answer on every visit.
#
# WHEN: once after startup (START_DELAY), after every library rescan, then
# daily. An artist is done once per RECHECK (MusicBrainz adds groups) or when
# its untagged albums change (a title, a track count, a length: the `sig`); one
# that failed (no artist found, ListenBrainz down) is tried again after
# RETRY_FAILED. Never while a scan runs.
#
# OFF THE PAGE'S WAY: every request is background work, so a page's request
# always goes first (API.pm, BACKGROUND JOBS YIELD), and an artist is not
# started while a page has a request waiting or out. One artist at a time,
# ARTIST_GAP apart, each bounded by ARTIST_TIMEOUT.
#
# A PAGE THAT FINDS ONE MISSING (an album added since the pass, an artist the
# pass could not reach) hands those groups here (want) and draws without them;
# they are asked for in the background, after WANT_DELAY.

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use Time::HiRes ();

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

my $log   = logger('plugin.discography');
my $prefs = preferences('plugin.discography');

use constant START_DELAY    => 300;          # after startup: let the server settle
use constant RESCAN_DELAY   => 60;           # after a rescan
use constant PASS_INTERVAL  => 86400;        # then daily
use constant SCAN_RETRY     => 120;          # a scan is running: look again
use constant BUSY_RETRY     => 3;            # a page has a request out: look again
use constant ARTIST_GAP     => 1;            # between two artists
use constant ARTIST_TIMEOUT => 120;          # one artist's requests, at most
use constant RECHECK        => 30 * 86400;   # an artist done is looked at again
use constant RETRY_FAILED   => 86400;        # ... or, when it failed, sooner
use constant WANT_DELAY     => 10;           # a page's missing groups, coalesced

my @queue;        # the pass's artists still to do: { id, name, sig }
my $running = 0;  # a pass is going
my $again   = 0;  # a rescan came during a pass: run once more after it
my (@want, %wanted, $wantArmed);
my %stat;

sub _dbg { Plugins::Discography::Plugin::dbg(@_) if Plugins::Discography::Plugin->can('dbg') }

my $store;
sub _store { $store ||= eval { Plugins::Discography::DB->store() } }

# The pass's mark per artist, kept: { sig, at, ok }. By the artist's NAME, as
# LMS renumbers contributors on a full rescan, AND its sig (v2, review
# 2026-10-08): two library artists of one name (Simon's library holds London
# Symphony Orchestra under two ids) each overwrote the other's mark under the
# name alone, so one of them was done again on every pass. A mark is kept RECHECK, the
# longest it is ever read for: one left behind when an artist's albums change
# (a new sig) goes with it. _markKey('') is the family's prefix (keepCurrent).
sub _markKey {
    my ($name, $sig) = @_;
    return 'dsc:trkwarm:2:' . lc($name // '') . (defined $sig && length $sig ? "|$sig" : '');
}

sub init {
    eval {
        Plugins::Discography::DB->keepCurrent(_markKey(''))
            if Plugins::Discography::DB->can('keepCurrent');
        1;
    };
    eval {
        Slim::Control::Request::unsubscribe(\&_onRescanDone);
        Slim::Control::Request::subscribe(\&_onRescanDone, [['rescan'], ['done']]);
        1;
    } or $log->warn("dsc: could not subscribe to rescans for the track match: $@");
    _armPass(START_DELAY);
    return;
}

sub _onRescanDone {
    if ($running) { $again = 1 } else { _armPass(RESCAN_DELAY) }
    return;
}

sub _armPass {
    my ($in) = @_;
    eval {
        Slim::Utils::Timers::killTimers(undef, \&_startPass);
        Slim::Utils::Timers::setTimer(undef, time() + $in, \&_startPass);
        1;
    } or $log->warn("dsc: could not arm the track match pass: $@");
    return;
}

sub _later {
    my ($in, $code) = @_;
    my $h;
    eval { $h = Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $in, $code); 1 }
        or $log->warn("dsc: track match timer failed: $@");
    return $h;
}

sub _scanning { return eval { Slim::Music::Import->stillScanning } ? 1 : 0 }

sub _pageBusy {
    my $busy = Plugins::Discography::API->can('_netFgBusy') or return 0;
    return $busy->() ? 1 : 0;
}

# ---------------------------------------------------------------------------
# The pass.

sub _startPass {
    return if $running;
    return _armPass(SCAN_RETRY) if _scanning();
    unless (($prefs->get('svc_priority_local') // 1) > 0) {    # the library is not used
        return _armPass(PASS_INTERVAL);
    }
    my $artists = _untaggedArtists();
    my $now = time();
    my @due = grep { _due($_, $now) } @$artists;
    _dbg('track match pass: ' . scalar(@$artists) . ' artist(s) with an untagged album, '
         . scalar(@due) . ' to do');
    %stat = ();
    @queue = @due;
    $running = 1;
    _next();
    return;
}

# Every artist whose library holds an album with no MusicBrainz release id, as
# its album artist: [ { id, name, sig } ]. Compilations (Various Artists) have
# no artist page. sig changes when a title, a track count or a length does.
sub _untaggedArtists {
    my $dbh = eval { require Slim::Schema; Slim::Schema->dbh } or return [];
    my $rows = eval { $dbh->selectall_arrayref(q{
        SELECT a.contributor, c.name, a.title, COUNT(t.id), CAST(COALESCE(SUM(t.secs), 0) AS INTEGER)
          FROM albums a
          JOIN contributors c ON c.id = a.contributor
          LEFT JOIN tracks t ON t.album = a.id
         WHERE (a.musicbrainz_id IS NULL OR a.musicbrainz_id = '')
           AND (a.compilation IS NULL OR a.compilation = 0)
         GROUP BY a.id
    }) };
    unless ($rows) {
        $log->warn("dsc: track match pass: could not read the library: $@") if $@;
        return [];
    }
    my $various = Plugins::Discography::API->can('isVarious');
    my %by;
    for my $r (@$rows) {
        my ($cid, $name, $title, $n, $secs) = @$r;
        next unless $cid && defined $name && length $name;
        for ($name, $title) { utf8::decode($_) if defined && !utf8::is_utf8($_) }
        next if $various && eval { Plugins::Discography::API->isVarious($name) };
        my $a = $by{$cid} ||= { id => $cid, name => $name, albums => [] };
        push @{ $a->{albums} }, lc($title // '') . "|$n|$secs";
    }
    my @out;
    for my $a (sort { lc $a->{name} cmp lc $b->{name} || $a->{id} <=> $b->{id} } values %by) {
        my $s = join "\n", sort @{ delete $a->{albums} };
        utf8::encode($s);
        $a->{sig} = md5_hex($s);
        push @out, $a;
    }
    return \@out;
}

sub _due {
    my ($a, $now) = @_;
    my $m = eval { _store()->get(_markKey($a->{name}, $a->{sig})) };
    return 1 unless ref $m eq 'HASH' && defined $m->{sig} && $m->{sig} eq $a->{sig};
    return ($now - ($m->{at} || 0)) >= ($m->{ok} ? RECHECK : RETRY_FAILED) ? 1 : 0;
}

sub _mark {
    my ($a, $ok) = @_;
    eval { _store()->set(_markKey($a->{name}, $a->{sig}),
                         { sig => $a->{sig}, at => time(), ok => $ok ? 1 : 0 }, RECHECK); 1 };
    return;
}

sub _next {
    unless (@queue) {
        _dbg('track match pass: done - ' . join(', ', map { "$_ $stat{$_}" } sort keys %stat))
            if %stat;
        $running = 0;
        if ($again) { $again = 0; _armPass(RESCAN_DELAY) } else { _armPass(PASS_INTERVAL) }
        return;
    }
    return _later(SCAN_RETRY, \&_next) if _scanning();
    return _later(BUSY_RETRY, \&_next) if _pageBusy();
    my $a = shift @queue;
    my ($settled, $watchdog) = (0, undef);
    my $done = sub {
        my ($ok, $what) = @_;
        return if $settled++;
        Slim::Utils::Timers::killSpecific($watchdog) if $watchdog;
        _mark($a, $ok);
        $stat{ $ok ? 'done' : 'to retry' }++;
        _dbg("track match pass: '$a->{name}': $what");
        _later(ARTIST_GAP, \&_next);
    };
    $watchdog = _later(ARTIST_TIMEOUT, sub { undef $watchdog; $done->(0, 'no answer in time') });
    eval { _artist($a, $done); 1 } or $done->(0, "failed: $@");
    return;
}

# One artist, the page's own way, every request as background work: its act,
# its groups (the page's kept list, else ListenBrainz's), its albums, the
# claims, and the tracklists of every group shortlisted for an untagged album
# no title claims. $done->($ok, $what) once.
sub _artist {
    my ($a, $done) = @_;
    my $API = 'Plugins::Discography::API';
    local $Plugins::Discography::API::NET_BG = 1;
    $API->getArtistMbid(artist_id => $a->{id}, artist => $a->{name}, onDone => sub {
        my ($mbid) = @_;
        return $done->(0, 'no MusicBrainz artist') unless $mbid;
        return $done->(1, 'not one artist') if $API->isVarious(undef, $mbid);
        my $go = sub {
            my ($rgs, $from) = @_;
            return $done->(0, "no release groups ($from)") unless ref $rgs eq 'ARRAY' && @$rgs;
            my $local = Plugins::Discography::Sources->localAlbums($a->{id}, $a->{name}, $mbid,
                                                                   { fallback => 'name' });
            my $B = 'Plugins::Discography::Browse';
            my %cands;
            $B->can('_placements')->(
                mbid => $mbid, artist => $a->{name}, rgs => $rgs, local => $local,
                relMap => { %{ $API->peekReleaseMap($mbid) || {} },
                            %{ $API->peekLocalReleaseMap([ map { $_->{_mbid} } grep { $_->{_mbid} } @$local ]) || {} } },
                editions => $B->can('_editionTitles')->($rgs, $API->peekEditions($mbid)),
                cands => \%cands);
            my @ask = grep { $API->groupTracksDue($_) } sort keys %cands;
            return $done->(1, scalar(keys %cands) . " candidate group(s) ($from), none to ask") unless @ask;
            $API->warmGroupTracks(\@ask, sub {
                my $missing = grep { !defined $API->peekGroupTracks($_) } @ask;
                $done->(!$missing, scalar(@ask) . " tracklist(s) asked ($from)"
                                   . ($missing ? ", $missing not answered" : ''));
            }, background => 1);
        };
        if (my $rgs = $API->peekReleaseGroups($mbid)) { return $go->($rgs, 'kept list') }
        $API->listenBrainzGroups($mbid, sub { $go->($_[0], 'ListenBrainz list') });
    });
    return;
}

# ---------------------------------------------------------------------------
# A page's missing groups (Browse::_buildList): asked for in the background,
# WANT_DELAY after the first, together. The page has drawn already.

sub want {
    my ($rgs) = @_;
    my $added = 0;
    for my $rg (@{ $rgs || [] }) {
        next if !defined $rg || $wanted{$rg}++;
        push @want, $rg;
        $added++;
    }
    return unless $added && !$wantArmed;
    $wantArmed = 1;
    _later(WANT_DELAY, \&_wantTick);
    return;
}

sub _wantTick {
    $wantArmed = 0;
    if (_scanning()) { $wantArmed = 1; _later(SCAN_RETRY, \&_wantTick); return }
    my @rgs = splice @want;
    %wanted = ();
    return unless @rgs;
    _dbg('track match: asking ListenBrainz for ' . scalar(@rgs) . ' tracklist(s) a page found missing (background)');
    local $Plugins::Discography::API::NET_BG = 1;
    Plugins::Discography::API->warmGroupTracks(\@rgs, undef, background => 1);
    return;
}

# For the suite.
sub _reset {
    @queue = (); $running = 0; $again = 0; @want = (); %wanted = (); $wantArmed = 0; %stat = ();
    undef $store;
    return;
}
sub _state { return { queue => [ @queue ], running => $running, again => $again, want => [ @want ] } }

1;
