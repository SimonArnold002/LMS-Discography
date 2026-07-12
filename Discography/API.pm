package Plugins::Discography::API;

# Async MusicBrainz access for the Discography plugin.
#
# Two jobs:
#   1. Resolve an artist to a MusicBrainz artist MBID — library tag first
#      (contributor.musicbrainz_id, exact identity for free), MB name search as
#      fallback (port of the ListenBrainz Fresh Releases plugin's
#      getArtistMbidByName).
#   2. Fetch the artist's full RELEASE-GROUP list — the discography spine:
#      one entry per release (not per edition), with first-release-date and
#      primary/secondary types. Paginated serially at MusicBrainz's 1 req/s
#      etiquette; artwork comes from the Cover Art Archive by release-group
#      MBID (plain URL, no API call).

use strict;
use warnings;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Cache;
use Slim::Utils::PluginManager;
use Slim::Utils::Timers;
use JSON::XS::VersionOneAndTwo;

my $log   = logger('plugin.discography');
my $prefs = preferences('plugin.discography');
my $cache = Slim::Utils::Cache->new();

# MB resolution failures MUST go through this — "artist not found" with only
# info-level logging is undiagnosable in the field (Better Oblivion, 2026-07-09).
sub _dbg { Plugins::Discography::Plugin::dbg(@_) }

use constant MB_DEFAULT_BASE_URL => 'https://musicbrainz.org/ws/2/';
use constant CAA_RG_BASE_URL     => 'https://coverartarchive.org/release-group/';

# Auto-detect: when the user sets NO mb_base_url, a same-host musicbrainz-docker
# mirror is probed once at startup (autodetectMirror) and its base cached under
# this key so the SYNCHRONOUS _mbBase can pick it up. Value: a URL (mirror found),
# '' (probed, none found), or absent (never probed). Re-probed daily.
use constant MB_AUTO_KEY => 'dsc:mbmirror:v1';
use constant MB_AUTO_TTL => 86400;

# The MusicBrainz web-service base is a PREF (default = the public API) so the
# whole plugin can be pointed at a local mirror — e.g. a musicbrainz-docker
# instance at http://your-server:5000/ws/2/ — without touching code. The local server
# speaks the identical ws/2 API, so only the host changes. When the pref is
# blank, a same-host mirror auto-detected at startup is used if one was found;
# otherwise the public API. A missing trailing slash is tolerated.
# Note: the Cover Art Archive (CAA_RG_BASE_URL) is a SEPARATE service that
# musicbrainz-docker does NOT mirror, so it always stays on the public CAA.
sub _mbBase {
    my $u = $prefs->get('mb_base_url');
    unless (defined $u && $u =~ /\S/) {
        my $auto = $cache->get(MB_AUTO_KEY);
        $u = (defined $auto && length $auto) ? $auto : MB_DEFAULT_BASE_URL;
    }
    $u =~ s/\s+//g;
    $u .= '/' unless $u =~ m{/$};
    return $u;
}

# The <=1 req/s courtesy gap between paginated requests is MusicBrainz etiquette
# for THEIR servers only. A local mirror is our own hardware with no such limit,
# so pages there fetch back-to-back. True only when the base is the public host
# (incl. beta./test. subdomains); any other host (a mirror) returns false.
sub _mbThrottled {
    return _mbBase() =~ m{^https?://([^/]*\.)?musicbrainz\.org/}i ? 1 : 0;
}

# Inter-page gap: the given MB-etiquette default against the public API, 0 on a
# local mirror.
sub _mbGap { _mbThrottled() ? $_[0] : 0 }

# Auto-detect a LOCAL MusicBrainz mirror on the SAME host — the common
# musicbrainz-docker-alongside-LMS setup — so it works with zero config. Only
# runs when the user has set NO mb_base_url: probe a small FIXED same-host list
# and, if one answers as a genuine ws/2 endpoint, cache its base for _mbBase.
# Validation is the point: a known artist MBID must come back with the expected
# name, which proves the responder is MusicBrainz and not some other service on
# :5000 (macOS AirPlay, a Flask app, ...) — so a false positive is effectively
# impossible. A manually-set base always wins and skips the probe; the LAN is
# NEVER scanned (localhost only — a mirror on another host is typed in by hand).
use constant MB_PROBE_MBID => 'a74b1b7f-06a0-4672-a641-eb3353aa608d';   # Radiohead
use constant MB_PROBE_NAME => 'Radiohead';
my @MB_AUTO_CANDIDATES = (
    'http://localhost:5000/ws/2/',
    'http://127.0.0.1:5000/ws/2/',
);

sub autodetectMirror {
    my ($class, $cb) = @_;
    $cb ||= sub {};

    # Manual base set -> respect it, never probe.
    my $u = $prefs->get('mb_base_url');
    return $cb->() if defined $u && $u =~ /\S/;

    # Already probed within MB_AUTO_TTL (found a URL or confirmed none) -> done.
    return $cb->() if defined $cache->get(MB_AUTO_KEY);

    my $i = 0;
    my $try; $try = sub {
        if ($i >= @MB_AUTO_CANDIDATES) {
            eval { $cache->set(MB_AUTO_KEY, '', MB_AUTO_TTL); 1 };   # none; don't re-probe today
            return $cb->();
        }
        my $base = $MB_AUTO_CANDIDATES[$i++];
        Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $data = eval { from_json(shift->content) };
                if (!$@ && ref $data eq 'HASH' && ($data->{name} // '') eq MB_PROBE_NAME) {
                    eval { $cache->set(MB_AUTO_KEY, $base, MB_AUTO_TTL); 1 };
                    _dbg("autodetected local MusicBrainz mirror: $base");
                    return $cb->();
                }
                $try->();   # answered but not MusicBrainz -> next candidate
            },
            sub { $try->() },   # unreachable / error -> next candidate
            { timeout => 3 }
        )->get($base . 'artist/' . MB_PROBE_MBID . '?fmt=json',
               'Accept' => 'application/json', 'User-Agent' => USER_AGENT());
    };
    $try->();
    return;
}

# Artist-MBID lookups: hits are stable for weeks. A MISS is cached only briefly
# — a "not found" is far more often a TRANSIENT infrastructure blip (a MB mirror
# whose search index is still building returns 0 for everything; a timeout) than
# a genuinely unknown artist, and pinning a transient miss for a whole day made a
# fixed mirror still look broken (field, 2026-07-11). 1h is long enough to avoid
# hammering on a genuine miss, short enough to self-heal. The error view also
# offers a Refresh that clears the miss immediately (clearArtistMbid).
use constant MBID_FOUND_TTL => 30 * 86400;
use constant MBID_EMPTY_TTL =>       3600;

# Release-group lists change rarely (a new release every few months at most).
# The browse view's Refresh action bypasses this.
use constant RG_TTL => 14 * 86400;

# MB pagination: 100/page max; pages fetched serially with a courtesy gap
# (MB asks for <=1 req/s). 6 pages = 600 release groups — beyond any artist
# this UI can usefully show; truncation is logged.
use constant RG_PAGE_SIZE => 100;
use constant RG_MAX_PAGES => 6;
use constant RG_PAGE_GAP  => 1.1;   # seconds between pages

# Bump when the cached release-group shape or filtering changes — versioned key
# invalidates every stale entry at once (the fleet's bump-every-layer rule).
use constant RG_CACHE_V => 'v1';

# UA per MB etiquette: identify the app + a contact URL. Version read from the
# plugin manifest so it can't drift.
my $_userAgent;
sub USER_AGENT {
    return $_userAgent if defined $_userAgent;
    my $ver = eval {
        Slim::Utils::PluginManager->dataForPlugin('Plugins::Discography::Plugin')->{version};
    };
    $ver = 'dev' unless defined $ver && length $ver;
    return $_userAgent =
        "LMS-Discography/$ver ( https://github.com/SimonArnold002/LMS-Discography )";
}

sub _rgKey { 'dsc:rg:' . RG_CACHE_V . ':' . $_[0] }

# ---------------------------------------------------------------------------
# Artist -> MBID
# ---------------------------------------------------------------------------

my $UUID_RE = qr/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

# getArtistMbid(artist_id => N, artist => 'Name', onDone => sub($mbid, $fromTag))
# Library tag wins (exact identity); MB name search otherwise. onDone always
# fires exactly once. $fromTag is 1 when the mbid came from the library tag, 0
# from a name search — the caller uses it to distinguish a trusted-but-possibly
# WRONG tag (a mis-tagged / merged same-name artist) from a name-search result,
# and to decide whether to try a fallback if the tag mbid has no discography.
sub getArtistMbid {
    my ($class, %a) = @_;
    my $onDone = $a{onDone} || sub {};

    if ($a{artist_id}) {
        my $mbid = eval {
            require Slim::Schema;
            my $c = Slim::Schema->find('Contributor', $a{artist_id});
            $c ? $c->musicbrainz_id : undef;
        };
        if ($mbid && $mbid =~ $UUID_RE) {
            _dbg("artist mbid from library tag: $mbid");
            $onDone->(lc $mbid, 1);
            return;
        }
    }

    $class->_artistMbidByName($a{artist}, sub { $onDone->($_[0], 0) });
}

# Port of the ListenBrainz plugin's getArtistMbidByName: quoted artist query,
# top hit only, score gate >= 90 so a wrong same-name artist is rejected rather
# than adopted. '' is the cached "not found" sentinel.
#
# MIRROR SEARCH FALLBACK (field, 2026-07-10): a musicbrainz-docker mirror serves
# entity BROWSES (release-group?artist=<mbid>) straight from Postgres, but its
# SEARCH (?query=) goes through Solr — and a freshly imported mirror whose search
# indexes were never built returns count:0 for EVERY query while browses work
# perfectly. That silently fails every artist resolved by name (any contributor
# without a library MB tag), which is exactly how it presented ("Couldn't
# identify this artist" for Alison Krauss / Neil Hannon / Luke Haines while
# tagged artists worked). So when the configured base is a mirror and its search
# yields zero results (or is unreachable), we retry the SAME query ONCE against
# the public API before accepting a miss. The MBID is universal, so a public-
# resolved MBID then browses fine against the mirror.
sub _artistMbidByName {
    my ($class, $name, $onDone) = @_;

    $name = defined $name ? $name : '';
    $name =~ s/^\s+|\s+$//g;
    unless (length $name) { $onDone->(undef); return; }

    my $cacheKey = 'dsc:mbid:' . lc $name;
    utf8::encode($cacheKey) if utf8::is_utf8($cacheKey);
    if (defined(my $c = $cache->get($cacheKey))) {
        _dbg("artist mbid cache hit '$name': " . ($c || 'NOT-FOUND sentinel (retried daily)'));
        $onDone->($c || undef);
        return;
    }

    my $q = 'artist:"' . $name . '"';
    utf8::encode($q) if utf8::is_utf8($q);
    (my $safe = $q) =~ s/([^A-Za-z0-9])/sprintf("%%%02X",ord($1))/ge;
    my $query = 'artist?query=' . $safe . '&fmt=json&limit=1';

    # The configured base is a mirror when it is NOT the public host; only then is
    # the public retry available (and only once, guarded by $isFallback).
    my $mirror = !_mbThrottled();

    my $store = sub {
        my ($mbid) = @_;
        eval { $cache->set($cacheKey, $mbid, $mbid ? MBID_FOUND_TTL : MBID_EMPTY_TTL); 1 }
            or $log->warn("artist-mbid cache set failed: $@");
        $onDone->($mbid || undef);
    };

    # Pass the sub to itself ($self) rather than capturing $run lexically: a
    # self-capturing closure is a reference cycle Perl never reclaims, and this
    # resolver runs once per name-resolved artist, so each call would leak a little
    # memory. $self keeps the CV alive across the async gap (the in-flight callbacks
    # hold it) and frees when they finish. (Ported from LBF 0.9.95.)
    my $run = sub {
        my ($self, $base, $isFallback) = @_;
        my $url = $base . $query;
        $log->info("resolving artist name to MBID: $name" . ($isFallback ? ' (public fallback)' : ''));

        Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $resp = shift;
                my $data = eval { from_json($resp->content) };
                my $arts = (!$@ && ref $data eq 'HASH' && ref $data->{artists} eq 'ARRAY')
                           ? $data->{artists} : undef;

                # Zero results on a mirror = probable unbuilt search index -> retry
                # the public API once before caching a miss.
                if ($arts && !@$arts && $mirror && !$isFallback) {
                    _dbg("MB artist search '$name' => 0 results on mirror; retrying public API");
                    $self->($self, MB_DEFAULT_BASE_URL, 1);
                    return;
                }

                my $mbid = '';
                my $why  = 'no results';
                if ($arts && @$arts) {
                    my $a = $arts->[0];
                    if ($a->{id} && ($a->{score} // 0) >= 90) {
                        $mbid = lc $a->{id};
                    }
                    else {
                        $why = "top hit '" . ($a->{name} // '?') . "' score " . ($a->{score} // '?') . ' < 90';
                    }
                }
                elsif ($@) { $why = 'unparseable MB response' }
                _dbg("MB artist search '$name' => " . ($mbid || "NO MATCH ($why; cached 1d)")
                    . ($isFallback ? ' [via public fallback]' : ''));
                $store->($mbid);
            },
            sub {
                my $err = shift->error // '?';
                # A mirror unreachable for search: fall back to public once.
                if ($mirror && !$isFallback) {
                    _dbg("MB artist search '$name' => mirror error ($err); retrying public API");
                    $self->($self, MB_DEFAULT_BASE_URL, 1);
                    return;
                }
                $log->error("MB artist search failed: $err");
                _dbg("MB artist search '$name' => HTTP error ($err; not cached, retry works)");
                $onDone->(undef);
            },
            { timeout => 12 }
        )->get($url, 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
    };

    $run->($run, _mbBase(), 0);
}

# getArtistCandidates($name, sub(\@cands)) — the SAME-NAME candidate set for
# disambiguation: [{ mbid, name, score }] for every hit whose (lc, trimmed) name
# equals the searched name, score-sorted. Where _artistMbidByName takes the top
# hit, this returns them ALL so the caller can pick the one whose discography
# matches the user's library (title match — works when the files have no MBIDs).
# Same mirror->public fallback (an empty/dead mirror search must not starve
# disambiguation). NOT cached — it's only run on the rare wrong-tag path.
sub getArtistCandidates {
    my ($class, $name, $cb) = @_;
    $cb ||= sub {};
    $name = defined $name ? $name : '';
    $name =~ s/^\s+|\s+$//g;
    return $cb->([]) unless length $name;
    my $want = lc $name;

    my $q = 'artist:"' . $name . '"';
    utf8::encode($q) if utf8::is_utf8($q);
    (my $safe = $q) =~ s/([^A-Za-z0-9])/sprintf("%%%02X",ord($1))/ge;
    my $query  = 'artist?query=' . $safe . '&fmt=json&limit=15';
    my $mirror = !_mbThrottled();

    # Self-passing ($self) closure, not a lexical $run capture — avoids the
    # reference-cycle leak (same fix as _artistMbidByName, ported from LBF 0.9.95).
    my $run = sub {
        my ($self, $base, $isFb) = @_;
        Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $data = eval { from_json(shift->content) };
                my $arts = (!$@ && ref $data eq 'HASH' && ref $data->{artists} eq 'ARRAY')
                           ? $data->{artists} : undef;
                if ($arts && !@$arts && $mirror && !$isFb) {
                    return $self->($self, MB_DEFAULT_BASE_URL, 1);
                }
                my @out;
                for my $a (@{ $arts || [] }) {
                    next unless $a->{id} && lc($a->{name} // '') eq $want;
                    push @out, { mbid => lc $a->{id}, name => $a->{name}, score => $a->{score} // 0 };
                }
                @out = sort { $b->{score} <=> $a->{score} } @out;
                _dbg("artist candidates '$name': " . scalar(@out) . ' same-name'
                    . ($isFb ? ' [public fallback]' : ''));
                $cb->(\@out);
            },
            sub {
                my $err = shift->error // '?';
                return $self->($self, MB_DEFAULT_BASE_URL, 1) if $mirror && !$isFb;
                _dbg("artist candidates '$name' HTTP error ($err)");
                $cb->([]);
            },
            { timeout => 12 }
        )->get($base . $query, 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
    };
    $run->($run, _mbBase(), 0);
}

# Public throttle-aware inter-request gap (0 on a local mirror). Callers that
# make their OWN serial MB requests (the disambiguation probe) use it to keep to
# MusicBrainz's <=1 req/s etiquette on the public API.
sub mbGap { _mbGap($_[1] // 1.1) }

# ---------------------------------------------------------------------------
# MBID -> release groups
# ---------------------------------------------------------------------------

# getReleaseGroups(mbid => $m, force => 0|1, onDone => sub(\@rgs), onError => sub($msg))
# Each entry: { mbid, title, date ('YYYY[-MM[-DD]]' or ''), type (primary,
# may be ''), secondary => [..] }. Cached whole; force bypasses the read (the
# write still happens, so Refresh renews the entry).
sub getReleaseGroups {
    my ($class, %a) = @_;
    my $mbid    = $a{mbid} or do { ($a{onError} || sub {})->('no mbid'); return };
    my $onDone  = $a{onDone}  || sub {};
    my $onError = $a{onError} || sub { $onDone->([]) };

    my $key = _rgKey($mbid);
    if (!$a{force} && (my $c = $cache->get($key))) {
        $log->info("release-group cache hit: $key (" . scalar(@$c) . " entries)");
        $onDone->($c);
        return;
    }

    my @all;
    my $page = 0;

    my $fetchPage; $fetchPage = sub {
        my ($offset) = @_;
        my $url = _mbBase() . 'release-group?artist=' . $mbid
                . '&limit=' . RG_PAGE_SIZE . '&offset=' . $offset . '&fmt=json';

        $log->info("fetching release groups: $url");

        Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $resp = shift;
                my $data = eval { from_json($resp->content) };
                if ($@ || ref $data ne 'HASH' || ref $data->{'release-groups'} ne 'ARRAY') {
                    _dbg("MB release-group page unparseable for $mbid (offset $offset)");
                    $onError->('bad MB response'); return;
                }

                for my $rg (@{ $data->{'release-groups'} }) {
                    next unless $rg->{id} && defined $rg->{title};
                    push @all, {
                        mbid      => lc $rg->{id},
                        title     => $rg->{title},
                        date      => $rg->{'first-release-date'} // '',
                        type      => $rg->{'primary-type'}       // '',
                        secondary => ref $rg->{'secondary-types'} eq 'ARRAY'
                                       ? $rg->{'secondary-types'} : [],
                    };
                }

                my $total = $data->{'release-group-count'} // scalar @all;
                $page++;
                if ($offset + RG_PAGE_SIZE < $total && $page < RG_MAX_PAGES) {
                    # Serial + spaced: MB etiquette is <=1 req/s per client.
                    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + _mbGap(RG_PAGE_GAP),
                        sub { $fetchPage->($offset + RG_PAGE_SIZE) });
                    return;
                }

                $log->warn("release-group list truncated at " . scalar(@all) . " of $total for $mbid")
                    if $offset + RG_PAGE_SIZE < $total;

                eval { $cache->set($key, \@all, RG_TTL); 1 }
                    or $log->warn("release-group cache set failed: $@");
                $log->info("release groups for $mbid: " . scalar(@all) . " of $total");
                $onDone->(\@all);
            },
            sub {
                my $err = shift->error // 'HTTP error';
                $log->error("MB release-group fetch failed: $err");
                $onError->($err);
            },
            { timeout => 20 }
        )->get($url, 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
    };

    $fetchPage->(0);
}

sub clearReleaseGroups {
    my ($class, $mbid) = @_;
    $cache->remove(_rgKey($mbid)) if $mbid;
}

# Drop the cached artist-name -> MBID entry (found OR the '' miss sentinel), so
# the next lookup re-queries. Keyed exactly like _artistMbidByName. Used by the
# "not found" view's Refresh to bust a stale miss without waiting out the TTL.
sub clearArtistMbid {
    my ($class, $name) = @_;
    return unless defined $name && length $name;
    $name =~ s/^\s+|\s+$//g;
    return unless length $name;
    my $key = 'dsc:mbid:' . lc $name;
    utf8::encode($key) if utf8::is_utf8($key);
    $cache->remove($key);
}

# Clear ALL of an artist's cached MusicBrainz data in one shot: resolution (mbid,
# incl. the '' miss sentinel), release-group list, bootleg map, band members,
# and bio. Streaming candidates live in Sources — call Sources::clearCandidates
# alongside (the CLI command and the view Refresh both do). This is the "re-pull
# from MusicBrainz" primitive: a stale/poisoned cache (e.g. a miss pinned while a
# mirror's search index was still building) can always be busted, from the UI
# Refresh OR the HTTP `discography clearcache` command. Recovers the mbid from a
# cached HIT when the caller passes only a name (a MISS has no mbid-keyed caches
# to clear). Returns an arrayref of the cache classes touched, for logging.
sub clearArtistCache {
    my ($class, %a) = @_;
    my $name = $a{name};
    $name =~ s/^\s+|\s+$//g if defined $name;
    my $mbid = $a{mbid};

    if (!$mbid && defined $name && length $name) {
        my $ck = 'dsc:mbid:' . lc $name;
        utf8::encode($ck) if utf8::is_utf8($ck);
        my $c = $cache->get($ck);
        $mbid = $c if $c && $c =~ $UUID_RE;
    }
    $mbid = lc $mbid if $mbid;

    my @cleared;
    if (defined $name && length $name) {
        $class->clearArtistMbid($name);
        my $bk = 'dsc:bio:1:' . lc $name;
        utf8::encode($bk) if utf8::is_utf8($bk);
        $cache->remove($bk);
        push @cleared, qw(mbid bio);
    }
    if ($mbid) {
        $cache->remove(_rgKey($mbid));       push @cleared, 'rg';
        $cache->remove(_officialKey($mbid)); push @cleared, 'official';
        $cache->remove(_bandsKey($mbid));    push @cleared, 'bands';
    }
    _dbg("clearArtistCache name='" . ($name // '') . "' mbid='" . ($mbid // '')
        . "' -> " . (join(',', @cleared) || 'nothing'));
    return \@cleared;
}

# ---------------------------------------------------------------------------
# Release-group officialness ("is this a bootleg?").
#
# MusicBrainz gives bootlegs their OWN release-groups, indistinguishable from a
# real album on every field the release-group browse returns — title, primary
# type, no secondary types. The Beatles have 14 release-groups titled exactly
# "The Beatles" (7 with no official release) plus a 2000 bootleg titled
# "The Beatles (White Album)". The only distinguishing field is release STATUS.
#
# Status is NOT available on the release-group browse we build the spine from
# ("status is not a valid parameter unless releases are requested"), and
# `inc=releases` is rejected there too. It IS available, for every release-group
# at once, on the RELEASE browse: `release?artist=<arid>&inc=release-groups`
# returns each release's status alongside its release-group id. That is one pass
# over the artist's releases (33 pages for The Beatles, 1 for most artists) and
# classifies EVERY release-group — versus one 1-req/s lookup per suspicious
# group, which was both slower (96 requests for The Beatles) and blind to
# bootlegs whose title collides with nothing.
#
# FAIL-OPEN, deliberately, everywhere: a release-group we never saw (not yet
# warmed, HTTP failure, or beyond the page cap) shows, and so does one whose
# releases carry NO status. MB leaves status unset on plenty of obscure releases
# — the real White Album has 2 status-less releases among its 25 — and hiding a
# real album is far worse than showing a bootleg.
# ---------------------------------------------------------------------------

use constant OFFICIAL_TTL       => 14 * 86400;
use constant REL_PAGE_SIZE      => 100;
use constant REL_MAX_PAGES      => 40;     # 4000 releases; The Beatles need 33
use constant REL_PAGE_GAP       => 1.1;    # seconds between pages (MB etiquette)

sub _officialKey { 'dsc:rgo:v3:' . $_[0] }

# 1 unless the release carries an explicit non-official status. A status-less
# release counts as official (see FAIL-OPEN above).
sub _isOfficial {
    my ($status) = @_;
    return 1 if !defined $status || lc($status) eq 'official';
    return 0;
}

# Cache-only, sync, safe in the render path: returns the artist's
# { rg-mbid => 0|1 } map, or undef when not yet warmed. A release-group ABSENT
# from a present map was never seen in the release browse -> caller fails open.
sub peekOfficial {
    my ($class, $artistMbid) = @_;
    my $c = $cache->get(_officialKey($artistMbid)) or return undef;
    return $c->{o};
}

# { release-mbid => release-group-mbid } for the same artist, or undef. Falls
# out of the SAME browse as the officialness map (each release carries its
# group), so exact MBID matching of local albums costs no extra request. A
# library album tagged MUSICBRAINZ_ALBUMID holds a RELEASE mbid, and MB models
# reissues/box sets as releases under one group — which is exactly the mapping
# the title matcher can't do ("The Beatles and Esher Demos" -> White Album).
sub peekReleaseMap {
    my ($class, $artistMbid) = @_;
    my $c = $cache->get(_officialKey($artistMbid)) or return undef;
    return $c->{r};
}

# ---------------------------------------------------------------------------
# Targeted release -> release-group lookups for the LIBRARY's own albums.
#
# The artist-wide browse above resolves every release, but for a 3000-release
# artist it needs ~33 paginated requests (~36s) — past the first-render
# deadline, so on a big artist a library album's exact-MBID match wasn't ready
# and it fell into "Also in your library" until a re-entry (Simon's Esher Demos,
# 2026-07-10). The user owns only a handful of albums, so resolve THOSE release
# MBIDs directly instead: one `release/<mbid>?inc=release-groups` each, a few
# requests, done well inside the deadline. Cached per release (14d), so a
# revisit — or the full browse landing later — costs nothing.
# ---------------------------------------------------------------------------

use constant REL2RG_TTL => 14 * 86400;

sub _rel2rgKey { 'dsc:rel2rg:v1:' . $_[0] }

# Cache-only, sync: { release-mbid => release-group-mbid } for the given release
# MBIDs that are cached with a non-empty group. Safe in the render path.
sub peekLocalReleaseMap {
    my ($class, $mbids) = @_;
    my %map;
    for my $m (@{ $mbids || [] }) {
        next unless $m;
        my $rg = $cache->get(_rel2rgKey($m));
        $map{$m} = $rg if defined $rg && length $rg;
    }
    return \%map;
}

my %rel2rgInFlight;

# Resolve the uncached release MBIDs serially (1.1s gap), caching each release's
# group. $cb fires once when all are done (or immediately if none need doing).
# '' is cached for a release with no group / a 404 (e.g. the tag was actually a
# GROUP mbid — _mbidMatch handles that case directly, so no retry is wanted).
# HTTP failures cache nothing and are retried on a later visit.
sub warmLocalReleases {
    my ($class, $mbids, $cb) = @_;
    $cb ||= sub {};

    my @todo = grep { $_ && !defined $cache->get(_rel2rgKey($_)) && !$rel2rgInFlight{$_} }
               @{ $mbids || [] };
    return $cb->() unless @todo;

    $rel2rgInFlight{$_} = 1 for @todo;
    _dbg('local-release warm: ' . scalar(@todo) . ' release(s) to resolve directly');

    my $next; $next = sub {
        my $m = shift @todo;
        unless ($m) { $cb->(); return; }

        my $done = sub { delete $rel2rgInFlight{$m}; $next->(); };
        my $url  = _mbBase() . 'release/' . $m . '?inc=release-groups&fmt=json';

        Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $data = eval { from_json(shift->content) };
                if ($@ || ref $data ne 'HASH') {
                    _dbg("local-release: unparseable for $m (retry next visit)");
                    $done->(); return;      # nothing cached -> retried later
                }
                my $rg = ref $data->{'release-group'} eq 'HASH'
                       ? lc($data->{'release-group'}{id} // '') : '';
                eval { $cache->set(_rel2rgKey($m), $rg, REL2RG_TTL); 1 }
                    or $log->warn("local-release cache set failed: $@");
                _dbg("local-release: $m -> " . ($rg || 'no group'));
                $done->();
            },
            sub {
                my $err = shift->error // 'HTTP error';
                # A 404 means the mbid is not a valid release (often a GROUP id);
                # cache '' so we don't keep retrying — _mbidMatch matches a group
                # id directly anyway. Other errors cache nothing (retry later).
                if ($err =~ /\b404\b/) {
                    eval { $cache->set(_rel2rgKey($m), '', REL2RG_TTL); 1 };
                    _dbg("local-release: $m -> 404 (not a release mbid; cached empty)");
                }
                else {
                    _dbg("local-release: lookup failed for $m: $err (not cached)");
                }
                $done->();
            },
            { timeout => 15 }
        )->get($url, 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
    };

    $next->();
}

# ---------------------------------------------------------------------------
# Band membership — "show my band's albums under me".
#
# The library can't tell a band album from a write-only cover credit: a member
# is often tagged only as COMPOSER on their own band's record (Marc Almond is
# COMPOSER-only on Soft Cell's "Non-Stop Erotic Cabaret"), identical to Dylan
# writing one track on a covers comp. MusicBrainz DOES know, via the artist's
# "member of band" relationships. One cached call per artist yields the bands;
# Sources::bandAlbums then pulls each band's OWN (album-artist) library albums,
# which are clean by construction.
# ---------------------------------------------------------------------------

use constant BANDS_TTL => 14 * 86400;

sub _bandsKey { 'dsc:bands:v1:' . $_[0] }

# Cache-only, sync: arrayref of { mbid, name } bands the artist is a member of,
# or undef until warmed. Empty arrayref = warmed, no bands.
sub peekBands {
    my ($class, $artistMbid) = @_;
    return $cache->get(_bandsKey($artistMbid));
}

my %bandsInFlight;

# Resolve the artist's "member of band" relationships once and cache them.
# $cb fires exactly once (cache hit / done / failure / already in flight).
sub warmBandMembers {
    my ($class, $artistMbid, $cb) = @_;
    $cb ||= sub {};
    return $cb->() unless $artistMbid;
    return $cb->() if defined $cache->get(_bandsKey($artistMbid));
    return $cb->() if $bandsInFlight{$artistMbid};
    $bandsInFlight{$artistMbid} = 1;

    my $url = _mbBase() . 'artist/' . $artistMbid . '?inc=artist-rels&fmt=json';

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $data = eval { from_json(shift->content) };
            if ($@ || ref $data ne 'HASH') {
                _dbg("band-members: unparseable for $artistMbid (retry next visit)");
                delete $bandsInFlight{$artistMbid};
                return $cb->();          # nothing cached -> retried later
            }
            my %seen;
            my @bands;
            for my $rel (@{ ref $data->{relations} eq 'ARRAY' ? $data->{relations} : [] }) {
                next unless ($rel->{type} // '') eq 'member of band';
                # 'forward' = this artist is a member of the target group. (The
                # backward direction would be the group listing its members.)
                next unless ($rel->{direction} // '') eq 'forward';
                my $b = $rel->{artist} or next;
                my $id = lc($b->{id} // '') or next;
                next if $seen{$id}++;
                push @bands, { mbid => $id, name => $b->{name} };
            }
            eval { $cache->set(_bandsKey($artistMbid), \@bands, BANDS_TTL); 1 }
                or $log->warn("band-members cache set failed: $@");
            _dbg("band-members: $artistMbid -> " . scalar(@bands) . ' band(s): '
                 . join(', ', map { $_->{name} } @bands));
            delete $bandsInFlight{$artistMbid};
            $cb->();
        },
        sub {
            _dbg("band-members: lookup failed for $artistMbid: " . (shift->error // 'HTTP error'));
            delete $bandsInFlight{$artistMbid};
            $cb->();                     # not cached -> retried later
        },
        { timeout => 15 }
    )->get($url, 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
}

my %officialInFlight;

# One paginated pass over the artist's releases; builds the whole map, then
# caches it. Nothing is cached until the pass COMPLETES: a release-group is a
# bootleg only when NONE of its releases is official, so a partial map cannot
# prove bootleg-ness and must never be used to hide anything.
#
# $cb (optional) fires exactly once when the map is usable (or provably won't
# be): cache hit, pass complete, HTTP failure, or a chain already in flight for
# this artist. That lets the caller AWAIT the map before its first render — see
# Browse::_discographyView, which does so under a deadline.
sub warmOfficial {
    my ($class, $artistMbid, $cb) = @_;
    $cb ||= sub {};

    return $cb->() unless $artistMbid;
    return $cb->() if defined $cache->get(_officialKey($artistMbid));

    # Every rebuild (drill, sort, back) re-enters here; one chain per artist.
    # A caller arriving mid-pass renders unfiltered rather than waiting on
    # someone else's chain — the map lands for the next render either way.
    return $cb->() if $officialInFlight{$artistMbid};
    $officialInFlight{$artistMbid} = 1;

    my (%official, %rgOf);
    my $page = 0;

    my $fetchPage; $fetchPage = sub {
        my ($offset) = @_;
        my $url = _mbBase() . 'release?artist=' . $artistMbid
                . '&inc=release-groups&limit=' . REL_PAGE_SIZE
                . '&offset=' . $offset . '&fmt=json';

        Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $data = eval { from_json(shift->content) };
                if ($@ || ref $data ne 'HASH' || ref $data->{releases} ne 'ARRAY') {
                    _dbg("official-status: unparseable release page (offset $offset) - abandoning, nothing cached");
                    delete $officialInFlight{$artistMbid};
                    $cb->(); return;
                }

                for my $rel (@{ $data->{releases} }) {
                    my $rg = $rel->{'release-group'} or next;
                    my $id = lc($rg->{id} // '') or next;
                    # A release-group is official if ANY of its releases is.
                    $official{$id} ||= _isOfficial($rel->{status});
                    # ... and every release points back at its group, which is
                    # how a library album's MUSICBRAINZ_ALBUMID finds its tile.
                    $rgOf{ lc $rel->{id} } = $id if $rel->{id};
                }

                my $total = $data->{'release-count'} // 0;
                $page++;
                if ($offset + REL_PAGE_SIZE < $total && $page < REL_MAX_PAGES) {
                    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + _mbGap(REL_PAGE_GAP),
                        sub { $fetchPage->($offset + REL_PAGE_SIZE) });
                    return;
                }

                $log->warn("release list truncated at " . ($page * REL_PAGE_SIZE)
                           . " of $total for $artistMbid - unseen groups stay visible")
                    if $offset + REL_PAGE_SIZE < $total;

                eval { $cache->set(_officialKey($artistMbid),
                                   { o => \%official, r => \%rgOf }, OFFICIAL_TTL); 1 }
                    or $log->warn("official-status cache set failed: $@");

                my $boot = grep { !$official{$_} } keys %official;
                _dbg("official-status: $artistMbid -> " . scalar(keys %official)
                     . " release-groups, $boot bootleg-only, "
                     . scalar(keys %rgOf) . " releases mapped to groups");

                delete $officialInFlight{$artistMbid};
                $cb->();
            },
            sub {
                # Nothing cached: the view keeps showing everything and the pass
                # is retried on a later visit.
                _dbg("official-status: release browse failed: " . (shift->error // 'HTTP error'));
                delete $officialInFlight{$artistMbid};
                $cb->();
            },
            { timeout => 20 }
        )->get($url, 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
    };

    _dbg("official-status warm: starting release browse for $artistMbid");
    $fetchPage->(0);
}

sub clearOfficial {
    my ($class, $artistMbid) = @_;
    $cache->remove(_officialKey($artistMbid)) if $artistMbid;
}

# CAA cover by release-group MBID — a plain URL; CAA redirects to the front
# image of the group's representative release. A CAA miss 404s and the UI shows
# its default art, which is the honest state.
sub caaImage {
    my ($class, $rgMbid, $size) = @_;
    return CAA_RG_BASE_URL . $rgMbid . '/front-' . ($size || 250);
}

# ---------------------------------------------------------------------------
# Release-group external links (AllMusic, Discogs, Wikipedia, reviews, ...)
# via MB url-relationships. One extra MB call per detail open, heavily cached.
# ---------------------------------------------------------------------------

use constant URLS_FOUND_TTL => 30 * 86400;
use constant URLS_EMPTY_TTL =>  7 * 86400;

# Relation types worth a row, in display order. MB types not listed (streaming,
# purchase, lyrics, wikidata, ...) are skipped — link rows should be curated,
# not a dump.
my @URL_REL_TYPES = (
    [ 'allmusic'          => 'AllMusic'      ],
    [ 'discogs'           => 'Discogs'       ],
    [ 'wikipedia'         => 'Wikipedia'     ],
    [ 'review'            => 'Review'        ],
    [ 'official homepage' => 'Official site' ],
);

# getReleaseGroupUrls(mbid => $m, onDone => sub(\@links)) — each link is
# { label => 'AllMusic', url => 'https://...' }. Errors resolve to [] (the
# detail page must never stall on link decoration).
sub getReleaseGroupUrls {
    my ($class, %a) = @_;
    my $mbid   = $a{mbid} or do { ($a{onDone} || sub {})->([]); return };
    my $onDone = $a{onDone} || sub {};

    my $key = 'dsc:urls:1:' . $mbid;
    if (my $c = $cache->get($key)) {
        $onDone->($c);
        return;
    }

    my $url = _mbBase() . 'release-group/' . $mbid . '?inc=url-rels&fmt=json';
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            my @links;
            if (!$@ && ref $data eq 'HASH' && ref $data->{relations} eq 'ARRAY') {
                for my $want (@URL_REL_TYPES) {
                    my ($type, $label) = @$want;
                    for my $rel (@{ $data->{relations} }) {
                        next unless ($rel->{type} // '') eq $type
                                 && ref $rel->{url} eq 'HASH'
                                 && $rel->{url}{resource};
                        push @links, { label => $label, url => $rel->{url}{resource} };
                        last;   # one row per type
                    }
                }
            }
            eval { $cache->set($key, \@links, @links ? URLS_FOUND_TTL : URLS_EMPTY_TTL); 1 }
                or $log->warn("url-rels cache set failed: $@");
            $log->info("url-rels for $mbid: " . scalar(@links));
            $onDone->(\@links);
        },
        sub {
            $log->warn("MB url-rels fetch failed: " . (shift->error // '?'));
            $onDone->([]);
        },
        { timeout => 15 }
    )->get($url, 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
}

1;
